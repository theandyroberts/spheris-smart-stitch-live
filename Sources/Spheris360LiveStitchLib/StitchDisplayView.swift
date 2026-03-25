import AppKit
import CoreVideo
import Metal
import MetalKit
import CoreText

/// MTKView subclass that renders a real-time equirectangular stitch of 9 cameras
/// using precomputed UV remap lookup tables, with camera label overlays.
public final class StitchDisplayView: MTKView, @unchecked Sendable {
    private var textureCache: CVMetalTextureCache?
    private var stitchPipeline: MTLRenderPipelineState?
    private var overlayPipeline: MTLRenderPipelineState?
    private var overlayVertexBuffer: MTLBuffer?
    private var commandQueue: MTLCommandQueue?

    private var remapTexture: MTLTexture?
    private var sourceTextures: [Int: MTLTexture] = [:]
    private var sourceCVTextures: [Int: CVMetalTexture] = [:]

    // Camera label overlays
    private var labelTextures: [MTLTexture] = []
    private let cameraCount = 9

    // Streaming frame capture
    public var frameGrabber: FrameGrabber?

    /// cameraLabels: array of (label, normalizedU, normalizedV)
    public init(frame: CGRect, metalDevice: MTLDevice, remapTexture: MTLTexture,
                cameraLabels: [(String, Float, Float)] = []) {
        self.remapTexture = remapTexture
        super.init(frame: frame, device: metalDevice)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        isPaused = true
        enableSetNeedsDisplay = false
        setup(cameraLabels: cameraLabels)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    private func setup(cameraLabels: [(String, Float, Float)]) {
        guard let device = self.device else { fatalError("No Metal device") }

        commandQueue = device.makeCommandQueue()

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache

        // Compile stitch shaders
        guard let metalURL = Bundle.module.url(forResource: "StitchShaders", withExtension: "metal"),
              let source = try? String(contentsOf: metalURL, encoding: .utf8),
              let library = try? device.makeLibrary(source: source, options: nil)
        else { fatalError("Failed to compile StitchShaders.metal") }

        // Also compile grid shaders for overlay
        guard let gridURL = Bundle.module.url(forResource: "GridShaders", withExtension: "metal"),
              let gridSource = try? String(contentsOf: gridURL, encoding: .utf8),
              let gridLib = try? device.makeLibrary(source: gridSource, options: nil)
        else { fatalError("Failed to compile GridShaders.metal for overlay") }

        // Stitch pipeline (no vertex buffer, full-screen triangle)
        let stitchDesc = MTLRenderPipelineDescriptor()
        stitchDesc.vertexFunction = library.makeFunction(name: "stitchVertexShader")
        stitchDesc.fragmentFunction = library.makeFunction(name: "stitchFragmentShader")
        stitchDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        stitchPipeline = try! device.makeRenderPipelineState(descriptor: stitchDesc)

        // Overlay pipeline (alpha blend for labels, uses grid shaders)
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<Float>.size * 2
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<Float>.size * 4

        let overlayDesc = MTLRenderPipelineDescriptor()
        overlayDesc.vertexFunction = gridLib.makeFunction(name: "gridVertexShader")
        overlayDesc.fragmentFunction = gridLib.makeFunction(name: "gridFragmentShader")
        overlayDesc.vertexDescriptor = vertexDescriptor
        overlayDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        overlayDesc.colorAttachments[0].isBlendingEnabled = true
        overlayDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        overlayDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        overlayDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        overlayDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        overlayPipeline = try! device.makeRenderPipelineState(descriptor: overlayDesc)

        // Build label textures and vertex buffer
        buildLabels(cameraLabels, device: device)
    }

    // MARK: - Runtime calibration swap

    /// Hot-swap the remap LUT and camera labels without recreating the view.
    public func updateCalibration(remapTexture: MTLTexture, cameraLabels: [(String, Float, Float)]) {
        self.remapTexture = remapTexture
        labelTextures.removeAll()
        overlayVertexBuffer = nil
        if let device = self.device {
            buildLabels(cameraLabels, device: device)
        }
    }

    // MARK: - Label rendering

    private func buildLabels(_ labels: [(String, Float, Float)], device: MTLDevice) {
        guard !labels.isEmpty else { return }

        var vertices: [Float] = []
        let labelW: Float = 0.08  // NDC half-width
        let labelH: Float = 0.025

        for (text, u, v) in labels {
            // Render text to texture
            if let tex = renderTextTexture(text: text, device: device) {
                labelTextures.append(tex)
            }

            // NDC position: u=[0,1]→x=[-1,1], v=[0,1]→y=[-1,1]
            let cx = u * 2.0 - 1.0
            let cy = -(v * 2.0 - 1.0)  // flip Y for macOS window coordinates

            let x0 = cx - labelW, x1 = cx + labelW
            let y0 = cy - labelH, y1 = cy + labelH

            vertices += [x0, y0, 0, 1,  x1, y0, 1, 1,  x1, y1, 1, 0]
            vertices += [x0, y0, 0, 1,  x1, y1, 1, 0,  x0, y1, 0, 0]
        }

        overlayVertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
    }

    private func renderTextTexture(text: String, device: MTLDevice) -> MTLTexture? {
        let scale: CGFloat = 2.0
        let pxW = Int(120 * scale), pxH = Int(24 * scale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: pxW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        let bgRect = CGRect(x: 0, y: 0, width: pxW, height: pxH)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))
        ctx.addPath(CGPath(roundedRect: bgRect, cornerWidth: 4*scale, cornerHeight: 4*scale, transform: nil))
        ctx.fillPath()

        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 11 * scale, nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        ctx.textPosition = CGPoint(
            x: (CGFloat(pxW) - bounds.width) / 2 - bounds.origin.x,
            y: (CGFloat(pxH) - bounds.height) / 2 - bounds.origin.y
        )
        CTLineDraw(line, ctx)

        guard let data = ctx.data else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pxW, height: pxH, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, pxW, pxH), mipmapLevel: 0, withBytes: data, bytesPerRow: pxW * 4)
        return tex
    }

    // MARK: - Frame delivery

    public func updateFrames(_ buffers: [Int: CVPixelBuffer]) {
        guard let cache = textureCache else { return }
        for (slot, pb) in buffers {
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            var cvTex: CVMetalTexture?
            if CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex) == kCVReturnSuccess,
               let tex = cvTex {
                sourceCVTextures[slot] = tex
                sourceTextures[slot] = CVMetalTextureGetTexture(tex)
            }
        }
        draw()
    }

    // MARK: - Drawing

    override public func draw(_ rect: NSRect) {
        guard let stitchPipe = stitchPipeline,
              let commandQueue = commandQueue,
              let descriptor = currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor),
              let remap = remapTexture
        else { return }

        // Pass 1: Stitch composite
        encoder.setRenderPipelineState(stitchPipe)
        encoder.setFragmentTexture(remap, index: 0)
        for i in 0..<cameraCount {
            if let src = sourceTextures[i] {
                encoder.setFragmentTexture(src, index: 1 + i)
            }
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Pass 2: Camera labels
        if let overlayPipe = overlayPipeline, let vb = overlayVertexBuffer, !labelTextures.isEmpty {
            encoder.setRenderPipelineState(overlayPipe)
            encoder.setVertexBuffer(vb, offset: 0, index: 0)
            for (i, tex) in labelTextures.enumerated() {
                encoder.setFragmentTexture(tex, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: i * 6, vertexCount: 6)
            }
        }

        encoder.endEncoding()

        // Stream frame capture (throttled by FrameGrabber)
        if let grabber = frameGrabber, let drawable = currentDrawable {
            grabber.captureIfNeeded(commandBuffer: commandBuffer, sourceTexture: drawable.texture)
        }

        if let drawable = currentDrawable { commandBuffer.present(drawable) }
        commandBuffer.commit()
    }
}
