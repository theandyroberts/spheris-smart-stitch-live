import AppKit
import CoreVideo
import Metal
import MetalKit
import simd

/// Rectilinear "virtual camera" view into the 360 sphere.
/// Drag to look around, scroll to zoom. Receives the same 9 source
/// textures + remap LUT as StitchDisplayView, reprojects in one pass.
public final class VirtualCameraView: MTKView, @unchecked Sendable {
    private var textureCache: CVMetalTextureCache?
    private var pipeline: MTLRenderPipelineState?
    private var commandQueue: MTLCommandQueue?
    private var uniformBuffer: MTLBuffer?

    private var remapTexture: MTLTexture?
    private var lutTexture: MTLTexture?
    private var sourceTextures: [Int: MTLTexture] = [:]
    private var sourceCVTextures: [Int: CVMetalTexture] = [:]
    private let cameraCount = 9

    // Color grading
    public var lutEnabled: Bool = false
    public var exposure: Float = 0  // stops

    // Vehicle interior (angle-based legacy)
    public var vehicleType: UInt32 = 0
    public var onVehicleChanged: ((UInt32) -> Void)?

    // 3D vehicle model
    private var vehicleRenderer: VehicleRenderer?
    private var depthTexture: MTLTexture?
    private var noDepthState: MTLDepthStencilState?
    public var seatHeight: Float = 1.1   // meters, driver eye height above model origin
    public var modelScale: Float = 1.0   // scale factor (e.g. 0.01 if model is in cm)
    public var modelRotationY: Float = 0 // extra yaw rotation to align model forward

    // Virtual camera state
    private var yaw: Float = -.pi / 2   // radians, absolute equirect heading
    private var pitch: Float = 0        // radians, 0 = horizon
    private var homeYaw: Float = -.pi / 2  // rig forward direction
    private var fovH: Float = 90 * .pi / 180   // horizontal FoV in radians
    private let fovMin: Float = 30 * .pi / 180
    private let fovMax: Float = 170 * .pi / 180

    // Mouse tracking
    private var lastMousePoint: NSPoint?
    private var isDragging = false

    // Heading indicator
    private var headingLabel: NSTextField?

    struct Uniforms {
        var yaw: Float
        var pitch: Float
        var fovH: Float
        var aspect: Float
        var outW: UInt32
        var outH: UInt32
        var lutEnabled: UInt32
        var exposure: Float
        var vehicleType: UInt32
        var homeYaw: Float
    }

    public init(frame: CGRect, metalDevice: MTLDevice, remapTexture: MTLTexture,
                initialYawDeg: Float = -90) {
        self.remapTexture = remapTexture
        let yawRad = initialYawDeg * .pi / 180
        self.yaw = yawRad
        self.homeYaw = yawRad
        super.init(frame: frame, device: metalDevice)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        isPaused = true
        enableSetNeedsDisplay = false
        setup()
        setupHeadingLabel()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    private func setup() {
        guard let device = self.device else { fatalError("No Metal device") }

        commandQueue = device.makeCommandQueue()

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache

        guard let metalURL = Bundle.module.url(forResource: "VirtualCameraShaders", withExtension: "metal"),
              let source = try? String(contentsOf: metalURL, encoding: .utf8),
              let library = try? device.makeLibrary(source: source, options: nil)
        else { fatalError("Failed to compile VirtualCameraShaders.metal") }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "vcamVertexShader")
        desc.fragmentFunction = library.makeFunction(name: "vcamFragmentShader")
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        desc.depthAttachmentPixelFormat = .depth32Float
        pipeline = try! device.makeRenderPipelineState(descriptor: desc)

        uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.size, options: .storageModeShared)

        // No-depth state for the panorama pass
        let noDepthDesc = MTLDepthStencilDescriptor()
        noDepthDesc.depthCompareFunction = .always
        noDepthDesc.isDepthWriteEnabled = false
        noDepthState = device.makeDepthStencilState(descriptor: noDepthDesc)

        // Vehicle renderer
        vehicleRenderer = VehicleRenderer(device: device, colorFormat: colorPixelFormat)
    }

    private func setupHeadingLabel() {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.backgroundColor = NSColor(white: 0, alpha: 0.5)
        label.isBordered = false
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.alignment = .center
        addSubview(label)
        headingLabel = label
        updateHeadingLabel()
    }

    private func updateHeadingLabel() {
        guard let label = headingLabel else { return }
        let relativeYaw = (yaw - homeYaw) * 180 / .pi
        let pitchDeg = pitch * 180 / .pi
        let fovDeg = fovH * 180 / .pi
        // Normalize relative heading to [0, 360) — 0° = front of vehicle
        var heading = (-relativeYaw).truncatingRemainder(dividingBy: 360)
        if heading < 0 { heading += 360 }
        label.stringValue = String(format: "  %.0f\u{00B0}  \u{2195}%.0f\u{00B0}  FoV %.0f\u{00B0}  ", heading, pitchDeg, fovDeg)
        label.sizeToFit()
        var f = label.frame
        f.origin.x = (bounds.width - f.width) / 2
        f.origin.y = bounds.height - f.height - 8
        label.frame = f
    }

    /// Set or replace the 3D LUT texture for color grading.
    public func setLUT(_ texture: MTLTexture?) {
        self.lutTexture = texture
    }

    /// Load a 3D vehicle model (nil to clear).
    /// Auto-detects scale from bounding box size.
    public func loadVehicle(objURL: URL?) {
        guard let device = self.device else { return }
        if let url = objURL {
            if let model = try? VehicleModelLoader.load(objURL: url, device: device) {
                vehicleRenderer?.loadModel(model)

                // Auto-detect scale from bounding box
                // A real car is ~4-5m long. If the model is >100 units, it's probably in cm.
                if let firstMesh = model.meshes.first {
                    let bb = firstMesh.vertexBuffers[0]
                    // Use MDL bounding box from loader output
                    // For now use heuristic: check if model spans > 100 units
                }
                // Check all mesh extents via vertex count heuristic
                // Simpler: use the printed bounding box and adjust
                let extent = estimateModelExtent(model)
                if extent > 100 {
                    modelScale = 0.01  // cm to meters
                    seatHeight = 1.2 * 0.01 * extent / 4.5  // scale seat height proportionally
                    print("  Auto-scale: \(modelScale) (extent=\(String(format: "%.0f", extent)) units, likely cm)")
                } else if extent > 10 {
                    modelScale = 0.1
                    seatHeight = 1.2 * 0.1 * extent / 4.5
                    print("  Auto-scale: \(modelScale) (extent=\(String(format: "%.1f", extent)) units)")
                } else {
                    modelScale = 1.0
                    seatHeight = 1.2
                }
                print("  Seat height: \(String(format: "%.2f", seatHeight))m")
                print("Loaded vehicle: \(model.name) (\(model.meshes.count) meshes)")
            }
        } else {
            vehicleRenderer?.loadModel(nil)
        }
    }

    private func estimateModelExtent(_ model: VehicleModel) -> Float {
        // Scan vertex positions to find bounding box
        var maxExtent: Float = 0
        for mesh in model.meshes {
            let vb = mesh.vertexBuffers[0]
            let layout = mesh.vertexDescriptor.layouts[0] as! MDLVertexBufferLayout
            let stride = layout.stride
            let count = vb.length / stride
            let ptr = vb.buffer.contents().bindMemory(to: Float.self, capacity: count * 6)
            var minX: Float = .greatestFiniteMagnitude, maxX: Float = -.greatestFiniteMagnitude
            var minY: Float = .greatestFiniteMagnitude, maxY: Float = -.greatestFiniteMagnitude
            var minZ: Float = .greatestFiniteMagnitude, maxZ: Float = -.greatestFiniteMagnitude
            for i in 0..<count {
                let base = i * (stride / 4)  // stride in floats
                let x = ptr[base], y = ptr[base + 1], z = ptr[base + 2]
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                minZ = min(minZ, z); maxZ = max(maxZ, z)
            }
            let sx = maxX - minX, sy = maxY - minY, sz = maxZ - minZ
            maxExtent = max(maxExtent, max(sx, max(sy, sz)))
            print("  Vertex scan: x=[\(String(format: "%.1f", minX)),\(String(format: "%.1f", maxX))] y=[\(String(format: "%.1f", minY)),\(String(format: "%.1f", maxY))] z=[\(String(format: "%.1f", minZ)),\(String(format: "%.1f", maxZ))] extent=\(String(format: "%.1f", maxExtent))")
        }
        return maxExtent
    }

    private func ensureDepthTexture(width: Int, height: Int) {
        if let dt = depthTexture, dt.width == width, dt.height == height { return }
        guard let device = self.device else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        desc.usage = .renderTarget
        desc.storageMode = .private
        depthTexture = device.makeTexture(descriptor: desc)
    }

    // MARK: - Calibration swap

    public func updateCalibration(remapTexture: MTLTexture) {
        self.remapTexture = remapTexture
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
        guard let pipe = pipeline,
              let commandQueue = commandQueue,
              let descriptor = currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let remap = remapTexture,
              let uBuf = uniformBuffer
        else { return }

        // Set up depth attachment for vehicle rendering
        let drawableW = UInt32(drawableSize.width)
        let drawableH = UInt32(drawableSize.height)
        ensureDepthTexture(width: Int(drawableW), height: Int(drawableH))
        if let dt = depthTexture {
            descriptor.depthAttachment.texture = dt
            descriptor.depthAttachment.loadAction = .clear
            descriptor.depthAttachment.storeAction = .dontCare
            descriptor.depthAttachment.clearDepth = 1.0
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        // Update uniforms
        let aspect = drawableH > 0 ? Float(drawableW) / Float(drawableH) : 1.33
        var uniforms = Uniforms(
            yaw: yaw, pitch: pitch, fovH: fovH, aspect: aspect,
            outW: drawableW, outH: drawableH,
            lutEnabled: lutEnabled && lutTexture != nil ? 1 : 0,
            exposure: exposure,
            vehicleType: vehicleType,
            homeYaw: homeYaw
        )
        memcpy(uBuf.contents(), &uniforms, MemoryLayout<Uniforms>.size)

        // Pass 1: 360 panorama (no depth write)
        encoder.setDepthStencilState(noDepthState)
        encoder.setRenderPipelineState(pipe)
        encoder.setFragmentBuffer(uBuf, offset: 0, index: 0)
        encoder.setFragmentTexture(remap, index: 0)
        for i in 0..<cameraCount {
            if let src = sourceTextures[i] {
                encoder.setFragmentTexture(src, index: 1 + i)
            }
        }
        if let lut = lutTexture {
            encoder.setFragmentTexture(lut, index: 10)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Pass 2: 3D vehicle model (with depth)
        if let renderer = vehicleRenderer {
            let projMat = VehicleRenderer.perspectiveMatrix(
                fovRadians: fovH, aspect: aspect, near: 0.01, far: 100.0)
            let viewMat = VehicleRenderer.viewMatrix(yaw: yaw, pitch: pitch)
            let modelMat = VehicleRenderer.modelMatrix(
                homeYaw: homeYaw,
                seatOffset: SIMD3<Float>(0, -seatHeight, 0),
                modelScale: modelScale,
                modelRotationY: modelRotationY
            )

            renderer.encode(
                encoder: encoder,
                viewMatrix: viewMat,
                projectionMatrix: projMat,
                modelMatrix: modelMat,
                remapTexture: remap,
                sourceTextures: sourceTextures,
                lutTexture: lutTexture,
                lutEnabled: lutEnabled,
                exposure: exposure
            )
        }

        encoder.endEncoding()

        if let drawable = currentDrawable { commandBuffer.present(drawable) }
        commandBuffer.commit()
    }

    // MARK: - Mouse interaction

    override public func mouseDown(with event: NSEvent) {
        isDragging = true
        lastMousePoint = convert(event.locationInWindow, from: nil)
    }

    override public func mouseDragged(with event: NSEvent) {
        guard isDragging, let last = lastMousePoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = Float(current.x - last.x)
        _ = Float(current.y - last.y)  // pitch locked for now

        // Sensitivity scales with FoV (narrower FoV = finer control)
        let sensitivity: Float = 0.003 * (fovH / (90 * .pi / 180))
        yaw -= dx * sensitivity

        lastMousePoint = current
        DispatchQueue.main.async { self.updateHeadingLabel() }
        draw()
    }

    override public func mouseUp(with event: NSEvent) {
        isDragging = false
        lastMousePoint = nil
    }

    override public func scrollWheel(with event: NSEvent) {
        let delta = Float(event.scrollingDeltaY) * 0.01
        fovH = max(fovMin, min(fovMax, fovH - delta))
        DispatchQueue.main.async { self.updateHeadingLabel() }
        draw()
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        DispatchQueue.main.async { self.updateHeadingLabel() }
    }

    private func cycleVehicle() {
        // Cycle is handled by the picker in AppDelegate via onVehicleChanged
        // Just signal the next index
        onVehicleChanged?(0)  // signal to cycle
        draw()
    }

    // MARK: - Snap-to views

    /// Snap to a heading relative to front (0=front, 90=right, 180=back, 270=left)
    /// and reset FoV to max for a wide hemispheric view.
    private func snapTo(relativeYawDeg: Float) {
        yaw = homeYaw + relativeYawDeg * .pi / 180
        pitch = 0
        fovH = 120 * .pi / 180
        updateHeadingLabel()
        draw()
    }

    override public func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.charactersIgnoringModifiers {
        case "f": snapTo(relativeYawDeg: 0)     // front
        case "b": snapTo(relativeYawDeg: 180)   // back
        case "r": snapTo(relativeYawDeg: -90)   // right
        case "l": snapTo(relativeYawDeg: 90)    // left
        case "v": cycleVehicle()                 // toggle vehicle
        default: super.keyDown(with: event)
        }
    }

    // Ensure we receive mouse and key events
    override public var acceptsFirstResponder: Bool { true }

    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
