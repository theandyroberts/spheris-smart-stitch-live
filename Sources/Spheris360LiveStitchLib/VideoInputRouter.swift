import AppKit
import CoreVideo
import Foundation
import QuartzCore

/// Wrapper to shuttle CVPixelBuffer dicts across isolation boundaries.
private struct FramePayload: @unchecked Sendable {
    let originals: [Int: CVPixelBuffer]
    let cleans: [Int: CVPixelBuffer]
    let tallyCrops: [Int: CVPixelBuffer]
    let bottomBarCrops: [Int: CVPixelBuffer]
}

public final class VideoInputRouter: @unchecked Sendable {
    public static let slotCount = 9

    private let lock = NSLock()
    private var providers: [VideoFrameProvider?] = Array(repeating: nil, count: 9)
    private var displayLink: CVDisplayLink?
    private weak var displayView: GridDisplayView?
    private weak var stitchView: StitchDisplayView?
    private weak var vcamView: VirtualCameraView?

    private var cropEngine: CropEngine?
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

    public func setVirtualCameraView(_ view: VirtualCameraView) {
        lock.lock(); self.vcamView = view; lock.unlock()
    }

    public func setCropEngine(_ engine: CropEngine) {
        lock.lock(); self.cropEngine = engine; lock.unlock()
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
        var originalBuffers: [Int: CVPixelBuffer] = [:]
        var cleanBuffers: [Int: CVPixelBuffer] = [:]
        var tallyCrops: [Int: CVPixelBuffer] = [:]
        var bottomBarCrops: [Int: CVPixelBuffer] = [:]

        lock.lock()
        let engine = cropEngine
        let currentFrame = frameNumber
        let view = displayView
        let stitch = stitchView
        let vcam = vcamView
        lock.unlock()

        for provider in providersCopy {
            guard let provider = provider, provider.isReady else { continue }
            if let pb = provider.copyNextPixelBuffer() {
                let slot = provider.slotIndex
                originalBuffers[slot] = pb
                if let engine = engine, let cropped = engine.process(pb) {
                    cleanBuffers[slot] = cropped.cleanFrame
                    tallyCrops[slot] = cropped.tallyCrop
                    bottomBarCrops[slot] = cropped.bottomBarCrop
                } else {
                    cleanBuffers[slot] = pb
                }
            }
        }

        let payload = FramePayload(originals: originalBuffers, cleans: cleanBuffers,
                                    tallyCrops: tallyCrops, bottomBarCrops: bottomBarCrops)
        DispatchQueue.main.async {
            view?.updateFrames(payload.originals, frameNumber: currentFrame)
            stitch?.updateFrames(payload.cleans)
            stitch?.updateMetadata(tallyCrops: payload.tallyCrops, bottomBarCrops: payload.bottomBarCrops)
            vcam?.updateFrames(payload.cleans)
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
        let vcam = self.vcamView
        lock.unlock()

        var originalBuffers: [Int: CVPixelBuffer] = [:]
        var cleanBuffers: [Int: CVPixelBuffer] = [:]
        var tallyCrops: [Int: CVPixelBuffer] = [:]
        var bottomBarCrops: [Int: CVPixelBuffer] = [:]

        lock.lock()
        let engine = cropEngine
        lock.unlock()

        for provider in providers {
            guard let provider = provider, provider.isReady else { continue }
            if let pb = provider.copyNextPixelBuffer() {
                let slot = provider.slotIndex
                originalBuffers[slot] = pb
                if let engine = engine, let cropped = engine.process(pb) {
                    cleanBuffers[slot] = cropped.cleanFrame
                    tallyCrops[slot] = cropped.tallyCrop
                    bottomBarCrops[slot] = cropped.bottomBarCrop
                } else {
                    cleanBuffers[slot] = pb
                }
            }
        }

        guard !originalBuffers.isEmpty else { return }

        let payload = FramePayload(originals: originalBuffers, cleans: cleanBuffers,
                                    tallyCrops: tallyCrops, bottomBarCrops: bottomBarCrops)
        DispatchQueue.main.async {
            view?.updateFrames(payload.originals, frameNumber: currentFrame)
            stitch?.updateFrames(payload.cleans)
            stitch?.updateMetadata(tallyCrops: payload.tallyCrops, bottomBarCrops: payload.bottomBarCrops)
            vcam?.updateFrames(payload.cleans)
        }
    }
}

public enum RouterError: Error {
    case displayLinkCreationFailed
}
