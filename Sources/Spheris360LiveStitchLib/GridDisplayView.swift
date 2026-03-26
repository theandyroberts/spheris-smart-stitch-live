import AppKit
import CoreVideo
import Metal
import MetalKit

/// MTKView subclass that renders 9 video textures in a 3x3 grid using Metal,
/// with camera label and timecode overlays on each cell.
public final class GridDisplayView: MTKView, @unchecked Sendable {
    private var textureCache: CVMetalTextureCache?
    private var videoPipelineState: MTLRenderPipelineState?
    private var overlayPipelineState: MTLRenderPipelineState?
    private var videoVertexBuffer: MTLBuffer?
    private var overlayVertexBuffer: MTLBuffer?
    private var commandQueue: MTLCommandQueue?

    // Current frame textures (retained to keep CVMetalTexture alive)
    private var currentTextures: [Int: MTLTexture] = [:]
    private var currentCVTextures: [Int: CVMetalTexture] = [:]

    // Overlay textures
    private var cameraLabelTextures: [Int: MTLTexture] = [:]
    private var timecodeTexture: MTLTexture?

    // Timing
    private var currentFrameNumber: Int = 0
    private var lastRenderedTimecodeFrame: Int = -1

    // Grid layout
    private let gridCols = 3
    private let gridRows = 3

    // Camera names matching grid slot order: G H J / A B C / D E F
    private let cameraNames = ["CAM G", "CAM H", "CAM J", "CAM A", "CAM B", "CAM C", "CAM D", "CAM E", "CAM F"]

    // Label visibility (off by default)
    public var showLabels: Bool = false

    // RED overlay simulator
    private var overlaySimulator: OverlaySimulator?
    private var overlayBarVertexBuffer: MTLBuffer?
    private var overlayTallyState: CropEngine.TallyState = .idle

    public func setOverlaySimulator(_ sim: OverlaySimulator) {
        self.overlaySimulator = sim
        buildOverlayBarVertices()
    }

    public init(frame: CGRect, metalDevice: MTLDevice) {
        super.init(frame: frame, device: metalDevice)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1.0)
        isPaused = true
        enableSetNeedsDisplay = false
        setup()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func setup() {
        guard let device = self.device else {
            fatalError("No Metal device")
        }

        commandQueue = device.makeCommandQueue()

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache

        // Compile shaders from bundled .metal source
        guard let metalURL = Bundle.module.url(forResource: "GridShaders", withExtension: "metal"),
              let shaderSource = try? String(contentsOf: metalURL, encoding: .utf8),
              let library = try? device.makeLibrary(source: shaderSource, options: nil)
        else {
            fatalError("Failed to compile Metal shaders from Bundle.module")
        }

        let vertexFunc = library.makeFunction(name: "gridVertexShader")
        let fragmentFunc = library.makeFunction(name: "gridFragmentShader")
        let overlayFragFunc = library.makeFunction(name: "overlayFragmentShader")

        // Vertex descriptor (shared by both pipelines)
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2  // position
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2  // texCoord
        vertexDescriptor.attributes[1].offset = MemoryLayout<Float>.size * 2
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<Float>.size * 4

        // Video pipeline (opaque)
        let videoPipelineDesc = MTLRenderPipelineDescriptor()
        videoPipelineDesc.vertexFunction = vertexFunc
        videoPipelineDesc.fragmentFunction = fragmentFunc
        videoPipelineDesc.vertexDescriptor = vertexDescriptor
        videoPipelineDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        videoPipelineState = try! device.makeRenderPipelineState(descriptor: videoPipelineDesc)

        // Overlay pipeline (alpha blending for text on transparent bg)
        let overlayPipelineDesc = MTLRenderPipelineDescriptor()
        overlayPipelineDesc.vertexFunction = vertexFunc
        overlayPipelineDesc.fragmentFunction = overlayFragFunc
        overlayPipelineDesc.vertexDescriptor = vertexDescriptor
        overlayPipelineDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        overlayPipelineDesc.colorAttachments[0].isBlendingEnabled = true
        overlayPipelineDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        overlayPipelineDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        overlayPipelineDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        overlayPipelineDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        overlayPipelineState = try! device.makeRenderPipelineState(descriptor: overlayPipelineDesc)

        buildVideoVertexBuffer()
        buildOverlayVertexBuffer()
        buildCameraLabelTextures()
    }

    // MARK: - Video vertex buffer (9 full-cell quads)

    private func buildVideoVertexBuffer() {
        var vertices: [Float] = []
        let cellW: Float = 2.0 / Float(gridCols)
        let cellH: Float = 2.0 / Float(gridRows)

        for row in 0..<gridRows {
            for col in 0..<gridCols {
                let x0 = -1.0 + Float(col) * cellW
                let x1 = x0 + cellW
                let y1 = 1.0 - Float(row) * cellH
                let y0 = y1 - cellH

                let pad: Float = 0.003
                let px0 = x0 + pad, px1 = x1 - pad
                let py0 = y0 + pad, py1 = y1 - pad

                // Two triangles per quad
                vertices += [px0, py0, 0, 1,
                             px1, py0, 1, 1,
                             px1, py1, 1, 0]
                vertices += [px0, py0, 0, 1,
                             px1, py1, 1, 0,
                             px0, py1, 0, 0]
            }
        }

        videoVertexBuffer = device!.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
    }

    // MARK: - Overlay vertex buffer (label per cell + single timecode on CAM B)

    // Vertex layout: 9 label quads (slots 0-8), then 1 timecode quad (for slot 1 / CAM B)
    private let timecodeSlot = 1  // CAM B
    private let timecodeVertexIndex = 9  // after 9 label quads

    private func buildOverlayVertexBuffer() {
        var vertices: [Float] = []
        let cellW: Float = 2.0 / Float(gridCols)
        let cellH: Float = 2.0 / Float(gridRows)

        let labelW: Float = cellW * 0.22
        let labelH: Float = cellH * 0.08
        let tcW: Float = cellW * 0.35
        let tcH: Float = cellH * 0.08
        let margin: Float = 0.008
        let pad: Float = 0.003

        // 9 camera label quads (one per cell, bottom-right)
        for row in 0..<gridRows {
            for col in 0..<gridCols {
                let cellX0 = -1.0 + Float(col) * cellW
                let cellY1 = 1.0 - Float(row) * cellH
                let cellY0 = cellY1 - cellH

                let lx1 = cellX0 + cellW - pad - margin
                let lx0 = lx1 - labelW
                let ly0 = cellY0 + pad + margin
                let ly1 = ly0 + labelH

                vertices += [lx0, ly0, 0, 1,
                             lx1, ly0, 1, 1,
                             lx1, ly1, 1, 0]
                vertices += [lx0, ly0, 0, 1,
                             lx1, ly1, 1, 0,
                             lx0, ly1, 0, 0]
            }
        }

        // 1 timecode quad on CAM B (slot 1 = row 0, col 1), top-center
        let tcRow = timecodeSlot / gridCols
        let tcCol = timecodeSlot % gridCols
        let tcCellX0 = -1.0 + Float(tcCol) * cellW
        let tcCellY1 = 1.0 - Float(tcRow) * cellH
        let tcCenterX = tcCellX0 + cellW * 0.5
        let tx0 = tcCenterX - tcW * 0.5
        let tx1 = tcCenterX + tcW * 0.5
        let ty1 = tcCellY1 - pad - margin
        let ty0 = ty1 - tcH

        vertices += [tx0, ty0, 0, 1,
                     tx1, ty0, 1, 1,
                     tx1, ty1, 1, 0]
        vertices += [tx0, ty0, 0, 1,
                     tx1, ty1, 1, 0,
                     tx0, ty1, 0, 0]

        overlayVertexBuffer = device!.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
    }

    // MARK: - RED Overlay bar vertices

    /// Build vertex quads for the top and bottom overlay bars on each grid cell.
    /// Layout: 9 top-bar quads followed by 9 bottom-bar quads = 18 quads total.
    private func buildOverlayBarVertices() {
        guard let device = self.device else { return }
        let cellW: Float = 2.0 / Float(gridCols)
        let cellH: Float = 2.0 / Float(gridRows)
        let topFrac: Float = Float(CropEngine.topBarHeight) / 1080.0   // 53/1080
        let botFrac: Float = Float(CropEngine.bottomBarHeight) / 1080.0 // 51/1080

        var vertices: [Float] = []
        // Top bars for 9 cells
        for row in 0..<gridRows {
            for col in 0..<gridCols {
                let x0 = -1.0 + Float(col) * cellW
                let x1 = x0 + cellW
                let y1 = 1.0 - Float(row) * cellH           // cell top
                let y0 = y1 - cellH * topFrac                // bar bottom
                // pos.xy, tex.uv
                vertices += [x0, y0, 0, 1,  x1, y0, 1, 1,  x1, y1, 1, 0]
                vertices += [x0, y0, 0, 1,  x1, y1, 1, 0,  x0, y1, 0, 0]
            }
        }
        // Bottom bars for 9 cells
        for row in 0..<gridRows {
            for col in 0..<gridCols {
                let x0 = -1.0 + Float(col) * cellW
                let x1 = x0 + cellW
                let y0 = 1.0 - Float(row + 1) * cellH        // cell bottom
                let y1 = y0 + cellH * botFrac                 // bar top
                vertices += [x0, y0, 0, 1,  x1, y0, 1, 1,  x1, y1, 1, 0]
                vertices += [x0, y0, 0, 1,  x1, y1, 1, 0,  x0, y1, 0, 0]
            }
        }
        overlayBarVertexBuffer = device.makeBuffer(
            bytes: vertices, length: vertices.count * MemoryLayout<Float>.size,
            options: .storageModeShared)
    }

    // MARK: - Text rendering via Core Graphics

    private func buildCameraLabelTextures() {
        for (i, name) in cameraNames.enumerated() {
            cameraLabelTextures[i] = renderTextTexture(
                text: name,
                fontSize: 13,
                width: 120,
                height: 28
            )
        }
    }

    private func renderTimecodeTexture(frameNumber: Int) {
        let fps = 24
        let totalFrames = frameNumber
        let ff = totalFrames % fps
        let totalSeconds = totalFrames / fps
        let ss = totalSeconds % 60
        let mm = (totalSeconds / 60) % 60
        let hh = totalSeconds / 3600
        let tc = String(format: "%02d:%02d:%02d:%02d", hh, mm, ss, ff)

        timecodeTexture = renderTextTexture(
            text: tc,
            fontSize: 12,
            width: 160,
            height: 28
        )
    }

    private func renderTextTexture(text: String, fontSize: CGFloat, width: Int, height: Int) -> MTLTexture? {
        guard let device = self.device else { return nil }

        let scale: CGFloat = 2.0  // Retina
        let pxW = Int(CGFloat(width) * scale)
        let pxH = Int(CGFloat(height) * scale)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: pxW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Black background with rounded rect
        let bgRect = CGRect(x: 0, y: 0, width: pxW, height: pxH)
        let cornerRadius: CGFloat = 4.0 * scale
        let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.75))
        ctx.addPath(bgPath)
        ctx.fillPath()

        // White text, centered
        let scaledFontSize = fontSize * scale
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, scaledFontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let attrStr = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attrStr)
        let lineBounds = CTLineGetBoundsWithOptions(line, [])

        let textX = (CGFloat(pxW) - lineBounds.width) / 2.0 - lineBounds.origin.x
        let textY = (CGFloat(pxH) - lineBounds.height) / 2.0 - lineBounds.origin.y

        ctx.textPosition = CGPoint(x: textX, y: textY)
        CTLineDraw(line, ctx)

        // Create Metal texture from bitmap
        guard let data = ctx.data else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: pxW,
            height: pxH,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        texture.replace(
            region: MTLRegionMake2D(0, 0, pxW, pxH),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: pxW * 4
        )

        return texture
    }

    // MARK: - Frame delivery

    /// Called by VideoInputRouter to deliver new frames and current frame number.
    public func updateFrames(_ buffers: [Int: CVPixelBuffer], frameNumber: Int) {
        guard let cache = textureCache else { return }

        currentFrameNumber = frameNumber

        for (slot, pixelBuffer) in buffers {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)

            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, pixelBuffer, nil,
                .bgra8Unorm,
                width, height, 0,
                &cvTexture
            )

            if status == kCVReturnSuccess, let cvTex = cvTexture {
                currentCVTextures[slot] = cvTex
                currentTextures[slot] = CVMetalTextureGetTexture(cvTex)
            }
        }

        // Update timecode texture if frame changed
        if currentFrameNumber != lastRenderedTimecodeFrame {
            renderTimecodeTexture(frameNumber: currentFrameNumber)
            lastRenderedTimecodeFrame = currentFrameNumber
        }

        draw()
    }

    // MARK: - Drawing

    override public func draw(_ rect: NSRect) {
        guard let videoPipeline = videoPipelineState,
              let overlayPipeline = overlayPipelineState,
              let commandQueue = commandQueue,
              let descriptor = currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let verticesPerQuad = 6

        // Pass 1: Draw video quads
        encoder.setRenderPipelineState(videoPipeline)
        encoder.setVertexBuffer(videoVertexBuffer, offset: 0, index: 0)

        for slot in 0..<(gridRows * gridCols) {
            if let texture = currentTextures[slot] {
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: slot * verticesPerQuad,
                    vertexCount: verticesPerQuad
                )
            }
        }

        // Pass 2: Draw overlay quads (camera labels, toggled via showLabels)
        if showLabels {
            encoder.setRenderPipelineState(overlayPipeline)
            encoder.setVertexBuffer(overlayVertexBuffer, offset: 0, index: 0)

            for slot in 0..<(gridRows * gridCols) {
                guard currentTextures[slot] != nil else { continue }

                if let labelTex = cameraLabelTextures[slot] {
                    encoder.setFragmentTexture(labelTex, index: 0)
                    encoder.drawPrimitives(
                        type: .triangle,
                        vertexStart: slot * verticesPerQuad,
                        vertexCount: verticesPerQuad
                    )
                }
            }
        }

        // Pass 3: RED overlay bars (simulator)
        if let sim = overlaySimulator, let barVB = overlayBarVertexBuffer {
            let bars = sim.bars(for: overlayTallyState)
            encoder.setRenderPipelineState(videoPipeline)  // opaque pipeline for dark bars
            encoder.setVertexBuffer(barVB, offset: 0, index: 0)
            // Top bars: 9 quads starting at vertex 0
            encoder.setFragmentTexture(bars.topBar, index: 0)
            for slot in 0..<(gridRows * gridCols) {
                guard currentTextures[slot] != nil else { continue }
                encoder.drawPrimitives(type: .triangle, vertexStart: slot * verticesPerQuad, vertexCount: verticesPerQuad)
            }
            // Bottom bars: 9 quads starting at vertex 9*6=54
            encoder.setFragmentTexture(bars.bottomBar, index: 0)
            for slot in 0..<(gridRows * gridCols) {
                guard currentTextures[slot] != nil else { continue }
                encoder.drawPrimitives(type: .triangle, vertexStart: (9 + slot) * verticesPerQuad, vertexCount: verticesPerQuad)
            }
        }

        // Single timecode on CAM B (follows label toggle)
        if showLabels, currentTextures[timecodeSlot] != nil, let tcTex = timecodeTexture {
            encoder.setFragmentTexture(tcTex, index: 0)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: timecodeVertexIndex * verticesPerQuad,
                vertexCount: verticesPerQuad
            )
        }

        encoder.endEncoding()

        if let drawable = currentDrawable {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }
}
