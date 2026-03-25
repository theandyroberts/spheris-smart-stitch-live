import Foundation

/// Streaming configuration, persisted to UserDefaults.
public final class StreamSettings: @unchecked Sendable {
    private let lock = NSLock()

    public var rtmpURL: String          // e.g. "rtmp://your-vps.com/live/streamkey"
    public var streamFPS: Int           // target stream frame rate (default 6)
    public var streamWidth: Int         // output width (default 1920)
    public var streamHeight: Int        // output height (default 960)
    public var videoBitrate: String     // ffmpeg bitrate string (default "2500k")
    public var recordingOnlyMode: Bool  // only stream when recording

    public init() {
        let defs: [String: Any] = [
            "stream_rtmpURL": "rtmp://localhost/live/spheris",
            "stream_fps": 6,
            "stream_width": 1920,
            "stream_height": 960,
            "stream_bitrate": "2500k",
            "stream_recordingOnly": false,
        ]
        defs.forEach { UserDefaults.standard.register(defaults: [$0.key: $0.value]) }
        let ud = UserDefaults.standard
        self.rtmpURL = ud.string(forKey: "stream_rtmpURL") ?? "rtmp://localhost/live/spheris"
        self.streamFPS = ud.integer(forKey: "stream_fps")
        self.streamWidth = ud.integer(forKey: "stream_width")
        self.streamHeight = ud.integer(forKey: "stream_height")
        self.videoBitrate = ud.string(forKey: "stream_bitrate") ?? "2500k"
        self.recordingOnlyMode = ud.bool(forKey: "stream_recordingOnly")
    }

    public func save() {
        lock.lock(); defer { lock.unlock() }
        let ud = UserDefaults.standard
        ud.set(rtmpURL, forKey: "stream_rtmpURL")
        ud.set(streamFPS, forKey: "stream_fps")
        ud.set(streamWidth, forKey: "stream_width")
        ud.set(streamHeight, forKey: "stream_height")
        ud.set(videoBitrate, forKey: "stream_bitrate")
        ud.set(recordingOnlyMode, forKey: "stream_recordingOnly")
    }
}
