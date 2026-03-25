import Foundation

/// Manages an ffmpeg subprocess that encodes raw BGRA frames to H.264
/// and pushes via RTMP to a remote server.
public final class RTMPStreamer: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var pipe: Pipe?
    private var _isStreaming = false
    private let settings: StreamSettings

    public init(settings: StreamSettings) {
        self.settings = settings
    }

    public var isStreaming: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isStreaming
    }

    /// Start the ffmpeg RTMP push process.
    public func start() throws {
        lock.lock()
        guard !_isStreaming else { lock.unlock(); return }
        lock.unlock()

        let ffmpegPath = findFFmpeg()
        guard let ffmpeg = ffmpegPath else {
            throw StreamError.ffmpegNotFound
        }

        let inputPipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpeg)
        proc.arguments = [
            // Input: raw BGRA from stdin
            "-f", "rawvideo",
            "-pixel_format", "bgra",
            "-video_size", "\(settings.streamWidth)x\(settings.streamHeight)",
            "-framerate", "\(settings.streamFPS)",
            "-i", "pipe:0",
            // H.264 encoding
            "-c:v", "libx264",
            "-preset", "ultrafast",
            "-tune", "zerolatency",
            "-b:v", settings.videoBitrate,
            "-maxrate", settings.videoBitrate,
            "-bufsize", "\(Int((Double(settings.videoBitrate.dropLast()) ?? 2500) * 2))k",
            "-pix_fmt", "yuv420p",
            "-g", "\(settings.streamFPS * 2)",  // keyframe every 2 seconds
            // Output: RTMP with FLV container
            "-f", "flv",
            settings.rtmpURL,
        ]
        proc.standardInput = inputPipe
        // Suppress ffmpeg stderr noise in release, show in debug
        #if DEBUG
        proc.standardError = FileHandle.standardError
        #else
        proc.standardError = FileHandle.nullDevice
        #endif
        proc.standardOutput = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] _ in
            self?.lock.lock()
            self?._isStreaming = false
            self?.lock.unlock()
            print("RTMP streamer process terminated")
        }

        try proc.run()

        lock.lock()
        self.process = proc
        self.pipe = inputPipe
        self._isStreaming = true
        lock.unlock()

        print("RTMP streaming started → \(settings.rtmpURL)")
    }

    /// Stop the ffmpeg process.
    public func stop() {
        lock.lock()
        let proc = process
        let p = pipe
        process = nil
        pipe = nil
        _isStreaming = false
        lock.unlock()

        p?.fileHandleForWriting.closeFile()
        if proc?.isRunning == true {
            proc?.terminate()
        }
        print("RTMP streaming stopped")
    }

    /// Feed a raw BGRA frame to ffmpeg's stdin.
    /// Called from FrameGrabber's background queue.
    public func pushFrame(_ data: Data) {
        lock.lock()
        guard _isStreaming, let p = pipe else { lock.unlock(); return }
        lock.unlock()

        do {
            try p.fileHandleForWriting.write(contentsOf: data)
        } catch {
            print("RTMP write error: \(error) — stopping stream")
            stop()
        }
    }

    // MARK: - Private

    private func findFFmpeg() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        // Try `which`
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["ffmpeg"]
        let out = Pipe()
        which.standardOutput = out
        try? which.run()
        which.waitUntilExit()
        let result = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result?.isEmpty == false ? result : nil
    }

    public enum StreamError: Error, LocalizedError {
        case ffmpegNotFound
        public var errorDescription: String? {
            switch self {
            case .ffmpegNotFound: return "ffmpeg not found. Install with: brew install ffmpeg"
            }
        }
    }
}
