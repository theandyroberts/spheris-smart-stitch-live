import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Reads a ProRes MOV file via AVAssetReader, delivering decoded CVPixelBuffer frames.
/// Supports looping and seeking.
public final class FilePlaybackProvider: VideoFrameProvider, @unchecked Sendable {
    public let slotIndex: Int
    public private(set) var frameRate: Double = 24.0
    public private(set) var isReady: Bool = false
    public private(set) var duration: Double = 0.0

    private let fileURL: URL
    private var asset: AVURLAsset?
    private var videoTrack: AVAssetTrack?
    private var reader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?
    private let looping: Bool

    public init(fileURL: URL, slotIndex: Int, looping: Bool = true) {
        self.fileURL = fileURL
        self.slotIndex = slotIndex
        self.looping = looping
    }

    public func start() throws {
        let asset = AVURLAsset(url: fileURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])
        self.asset = asset

        guard let track = asset.tracks(withMediaType: .video).first else {
            throw FilePlaybackError.noVideoTrack
        }
        self.videoTrack = track
        self.frameRate = Double(track.nominalFrameRate)
        self.duration = CMTimeGetSeconds(asset.duration)

        try setupReader(startTime: .zero)
        isReady = true
    }

    public func stop() {
        isReady = false
        reader?.cancelReading()
        reader = nil
        trackOutput = nil
    }

    public func seek(toFraction fraction: Double) throws {
        guard let asset = self.asset else { return }
        let clamped = max(0, min(1, fraction))
        let targetTime = CMTimeMultiplyByFloat64(asset.duration, multiplier: clamped)

        reader?.cancelReading()
        reader = nil
        trackOutput = nil

        try setupReader(startTime: targetTime)
    }

    public func copyNextPixelBuffer() -> CVPixelBuffer? {
        guard isReady else { return nil }

        if let sampleBuffer = trackOutput?.copyNextSampleBuffer() {
            return CMSampleBufferGetImageBuffer(sampleBuffer)
        }

        if looping, reader?.status == .completed {
            reader?.cancelReading()
            reader = nil
            trackOutput = nil
            do {
                try setupReader(startTime: .zero)
            } catch {
                print("[\(slotIndex)] Failed to loop: \(error)")
                isReady = false
            }
            if let sampleBuffer = trackOutput?.copyNextSampleBuffer() {
                return CMSampleBufferGetImageBuffer(sampleBuffer)
            }
        }

        if let error = reader?.error {
            print("[\(slotIndex)] AVAssetReader error: \(error)")
            isReady = false
        }

        return nil
    }

    private func setupReader(startTime: CMTime) throws {
        guard let asset = self.asset, let track = self.videoTrack else {
            throw FilePlaybackError.noVideoTrack
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        let reader = try AVAssetReader(asset: asset)
        if startTime != .zero {
            reader.timeRange = CMTimeRange(start: startTime, end: .positiveInfinity)
        }
        guard reader.canAdd(output) else {
            throw FilePlaybackError.cannotAddOutput
        }
        reader.add(output)

        guard reader.startReading() else {
            throw FilePlaybackError.startFailed(reader.error)
        }

        self.reader = reader
        self.trackOutput = output
    }
}

public enum FilePlaybackError: Error, CustomStringConvertible {
    case noVideoTrack
    case cannotAddOutput
    case startFailed(Error?)

    public var description: String {
        switch self {
        case .noVideoTrack: return "No video track found in file"
        case .cannotAddOutput: return "Cannot add track output to reader"
        case .startFailed(let err): return "Reader failed to start: \(err?.localizedDescription ?? "unknown")"
        }
    }
}
