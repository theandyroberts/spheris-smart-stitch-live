import Foundation
@preconcurrency import Metal
import CoreGraphics

/// Captures frames from the stitch render at a throttled rate for streaming.
/// Copies the drawable to a CPU-readable staging texture, then delivers
/// raw pixel data on a background queue.
public final class FrameGrabber: @unchecked Sendable {
    private let device: MTLDevice
    private var stagingTexture: MTLTexture?
    private var currentWidth: Int = 0
    private var currentHeight: Int = 0

    private let lock = NSLock()
    private var lastGrabTime: CFAbsoluteTime = 0
    private var targetInterval: Double
    private var _enabled: Bool = false

    private let streamWidth: Int
    private let streamHeight: Int

    /// Called on a background queue with raw BGRA pixel data
    public var onFrame: (@Sendable (Data, Int, Int) -> Void)?

    private let grabQueue = DispatchQueue(label: "com.spheris.framegrab", qos: .userInitiated)

    public init(device: MTLDevice, width: Int, height: Int, fps: Int) {
        self.device = device
        self.streamWidth = width
        self.streamHeight = height
        self.targetInterval = 1.0 / Double(max(1, fps))
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

    /// Ensure staging texture matches the source drawable size.
    private func ensureStagingTexture(width: Int, height: Int) {
        if currentWidth == width && currentHeight == height, stagingTexture != nil { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .managed
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        tex.label = "FrameGrabStaging"
        stagingTexture = tex
        currentWidth = width
        currentHeight = height
    }

    /// Called from StitchDisplayView.draw() after the stitch render pass.
    /// Copies the full drawable at native resolution; ffmpeg handles scaling.
    public func captureIfNeeded(commandBuffer: MTLCommandBuffer, sourceTexture: MTLTexture) {
        lock.lock()
        guard _enabled else { lock.unlock(); return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastGrabTime >= targetInterval else { lock.unlock(); return }
        lastGrabTime = now
        lock.unlock()

        let srcW = sourceTexture.width
        let srcH = sourceTexture.height
        ensureStagingTexture(width: srcW, height: srcH)
        guard let staging = stagingTexture else { return }

        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: sourceTexture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: srcW, height: srcH, depth: 1),
                  to: staging, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.synchronize(resource: staging)
        blit.endEncoding()

        let bpr = srcW * 4
        let callback = onFrame

        commandBuffer.addCompletedHandler { _ in
            self.grabQueue.async {
                var pixelData = Data(count: bpr * srcH)
                pixelData.withUnsafeMutableBytes { ptr in
                    staging.getBytes(ptr.baseAddress!, bytesPerRow: bpr,
                                     from: MTLRegionMake2D(0, 0, srcW, srcH), mipmapLevel: 0)
                }
                callback?(pixelData, srcW, srcH)
            }
        }
    }
}
