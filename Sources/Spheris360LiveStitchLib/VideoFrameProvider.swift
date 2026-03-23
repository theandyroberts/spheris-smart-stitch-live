import CoreVideo
import Foundation

/// Abstract interface for delivering decoded video frames.
/// Implementations: FilePlaybackProvider (file-based), DeckLinkProvider (live capture).
public protocol VideoFrameProvider: AnyObject, Sendable {
    /// Which camera slot this provider occupies (0-8).
    var slotIndex: Int { get }

    /// The native frame rate of the source.
    var frameRate: Double { get }

    /// Whether the provider is ready to deliver frames.
    var isReady: Bool { get }

    /// Begin frame production.
    func start() throws

    /// Stop frame production and release resources.
    func stop()

    /// Duration in seconds (0 if unknown/live).
    var duration: Double { get }

    /// Pull the next decoded frame. Returns nil if no frame is available yet.
    /// The returned CVPixelBuffer is IOSurface-backed and suitable for Metal texture creation.
    func copyNextPixelBuffer() -> CVPixelBuffer?

    /// Seek to a position (0.0 = start, 1.0 = end). Providers that don't support seeking can ignore.
    func seek(toFraction fraction: Double) throws
}
