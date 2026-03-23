import AppKit
import CoreVideo
import Foundation
import QuartzCore

public final class VideoInputRouter: @unchecked Sendable {
    public static let slotCount = 9

    private let lock = NSLock()
    private var providers: [VideoFrameProvider?] = Array(repeating: nil, count: 9)
    private var displayLink: CVDisplayLink?
    private weak var displayView: GridDisplayView?
    private weak var stitchView: StitchDisplayView?

    private var frameInterval: Double = 1.0 / 24.0
    private var accumulatedTime: Double = 0.0
    private var lastTimestamp: Double = 0.0
    private var frameNumber: Int = 0
    private var paused: Bool = false

    public init() {}

    public func setProvider(_ provider: VideoFrameProvider, slot: Int) {
        precondition(slot >= 0 && slot < Self.slotCount)
        lock.lock()
        providers[slot] = provider
        frameInterval = 1.0 / provider.frameRate
        lock.unlock()
    }

    public func setDisplayView(_ view: GridDisplayView) {
        lock.lock(); self.displayView = view; lock.unlock()
    }

    public func setStitchView(_ view: StitchDisplayView) {
        lock.lock(); self.stitchView = view; lock.unlock()
    }

    public func startAll() throws {
        lock.lock()
        let providersCopy = providers
        lock.unlock()
        for provider in providersCopy { try provider?.start() }
        try startDisplayLink()
    }

    public func stopAll() {
        stopDisplayLink()
        lock.lock()
        let providersCopy = providers
        lock.unlock()
        for provider in providersCopy { provider?.stop() }
    }

    // MARK: - Playback control

    public var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    public var clipDuration: Double {
        lock.lock(); defer { lock.unlock() }
        return providers.compactMap { $0?.duration }.first ?? 0
    }

    public var currentFraction: Double {
        lock.lock(); defer { lock.unlock() }
        guard let dur = providers.compactMap({ $0?.duration }).first, dur > 0 else { return 0 }
        let fps = 1.0 / frameInterval
        return Double(frameNumber) / (dur * fps)
    }

    public func togglePause() {
        lock.lock()
        paused = !paused
        lock.unlock()
    }

    public func seek(toFraction fraction: Double) {
        lock.lock()
        let providersCopy = providers
        paused = true
        let fps = 1.0 / frameInterval
        let dur = providersCopy.compactMap({ $0?.duration }).first ?? 0
        frameNumber = Int(fraction * dur * fps)
        lock.unlock()

        // Seek all providers
        for provider in providersCopy {
            try? provider?.seek(toFraction: fraction)
        }

        // Pull one frame from each and display
        var buffers: [Int: CVPixelBuffer] = [:]
        for provider in providersCopy {
            guard let provider = provider, provider.isReady else { continue }
            if let pb = provider.copyNextPixelBuffer() {
                buffers[provider.slotIndex] = pb
            }
        }

        lock.lock()
        let currentFrame = frameNumber
        let view = displayView
        let stitch = stitchView
        lock.unlock()

        DispatchQueue.main.async {
            view?.updateFrames(buffers, frameNumber: currentFrame)
            stitch?.updateFrames(buffers)
        }
    }

    // MARK: - Display link

    private func startDisplayLink() throws {
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let displayLink = dl else { throw RouterError.displayLinkCreationFailed }

        lock.lock()
        self.displayLink = displayLink
        lock.unlock()

        let callback: CVDisplayLinkOutputCallback = {
            (_, inNow, inOutputTime, _, _, userInfo) -> CVReturn in
            let router = Unmanaged<VideoInputRouter>.fromOpaque(userInfo!).takeUnretainedValue()
            router.displayLinkFired(now: inNow.pointee, outputTime: inOutputTime.pointee)
            return kCVReturnSuccess
        }

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(displayLink, callback, pointer)
        CVDisplayLinkStart(displayLink)
    }

    private func stopDisplayLink() {
        lock.lock()
        if let dl = displayLink { CVDisplayLinkStop(dl); displayLink = nil }
        lock.unlock()
    }

    private func displayLinkFired(now: CVTimeStamp, outputTime: CVTimeStamp) {
        let currentTime = Double(outputTime.videoTime) / Double(outputTime.videoTimeScale)

        lock.lock()
        if paused { lock.unlock(); return }

        let providers = self.providers
        let frameInterval = self.frameInterval

        if lastTimestamp == 0 { lastTimestamp = currentTime; lock.unlock(); return }

        let delta = currentTime - lastTimestamp
        lastTimestamp = currentTime
        accumulatedTime += delta

        guard accumulatedTime >= frameInterval else { lock.unlock(); return }
        accumulatedTime -= frameInterval
        frameNumber += 1
        let currentFrame = frameNumber
        let view = self.displayView
        let stitch = self.stitchView
        lock.unlock()

        var buffers: [Int: CVPixelBuffer] = [:]
        for provider in providers {
            guard let provider = provider, provider.isReady else { continue }
            if let pb = provider.copyNextPixelBuffer() {
                buffers[provider.slotIndex] = pb
            }
        }

        guard !buffers.isEmpty else { return }

        DispatchQueue.main.async {
            view?.updateFrames(buffers, frameNumber: currentFrame)
            stitch?.updateFrames(buffers)
        }
    }
}

public enum RouterError: Error {
    case displayLinkCreationFailed
}
