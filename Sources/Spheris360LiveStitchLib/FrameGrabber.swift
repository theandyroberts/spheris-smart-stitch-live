import Foundation
@preconcurrency import Metal
import CoreGraphics

/// Captures frames from the stitch render at a throttled rate for streaming.
/// Blits the stitch output to a CPU-readable staging texture, then delivers
/// raw pixel data on a background queue.
public final class FrameGrabber: @unchecked Sendable {
    private let device: MTLDevice
    private let stagingTexture: MTLTexture
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int

    private let lock = NSLock()
    private var lastGrabTime: CFAbsoluteTime = 0
    private var targetInterval: Double
    private var _enabled: Bool = false

    /// Called on a background queue with raw BGRA pixel data (width × height × 4 bytes)
    public var onFrame: (@Sendable (Data, Int, Int) -> Void)?

    private let grabQueue = DispatchQueue(label: "com.spheris.framegrab", qos: .userInitiated)

    public init(device: MTLDevice, width: Int, height: Int, fps: Int) {
        self.device = device
        self.width = width
        self.height = height
        self.bytesPerRow = width * 4
        self.targetInterval = 1.0 / Double(max(1, fps))

        // CPU-readable staging texture
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .managed
        guard let tex = device.makeTexture(descriptor: desc) else {
            fatalError("Failed to create staging texture for frame grabber")
        }
        self.stagingTexture = tex
        stagingTexture.label = "FrameGrabStaging"
    }

    public var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; lock.unlock() }
    }

    public func updateFPS(_ fps: Int) {
        lock.lock()
        targetInterval = 1.0 / Double(max(1, fps))
        lock.unlock()
    }

    /// Called from StitchDisplayView.draw() after the stitch render pass.
    /// If enough time has elapsed, blits the source texture to the staging texture
    /// and schedules a pixel readback on the background queue.
    public func captureIfNeeded(commandBuffer: MTLCommandBuffer, sourceTexture: MTLTexture) {
        lock.lock()
        guard _enabled else { lock.unlock(); return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastGrabTime >= targetInterval else { lock.unlock(); return }
        lastGrabTime = now
        lock.unlock()

        // Blit from source (drawable) to staging texture, with scaling if sizes differ
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        let srcSize = MTLSize(width: min(sourceTexture.width, width),
                              height: min(sourceTexture.height, height), depth: 1)
        // If source is larger, we copy the top-left portion at staging size
        // For proper scaling, we'd use a render pass, but for matching sizes this works
        if sourceTexture.width == width && sourceTexture.height == height {
            blit.copy(from: sourceTexture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: srcSize,
                      to: stagingTexture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        } else {
            // Different sizes — use a simple copy of what fits
            let copyW = min(sourceTexture.width, width)
            let copyH = min(sourceTexture.height, height)
            blit.copy(from: sourceTexture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                      to: stagingTexture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        blit.synchronize(resource: stagingTexture)
        blit.endEncoding()

        // After GPU completes, read back pixels on background queue
        let w = width, h = height, bpr = bytesPerRow
        let staging = stagingTexture
        let callback = onFrame

        commandBuffer.addCompletedHandler { _ in
            self.grabQueue.async {
                var pixelData = Data(count: bpr * h)
                pixelData.withUnsafeMutableBytes { ptr in
                    staging.getBytes(ptr.baseAddress!, bytesPerRow: bpr,
                                     from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
                }
                callback?(pixelData, w, h)
            }
        }
    }
}
