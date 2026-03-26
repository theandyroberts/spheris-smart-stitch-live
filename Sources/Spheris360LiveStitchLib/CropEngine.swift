import CoreVideo
import Foundation

/// Processes raw SDI frames to separate clean video from RED overlay metadata.
///
/// Given a 1920x1080 frame with RED Advanced Overlay bars:
/// - Top bar: rows 0-52 (53px)
/// - Bottom bar: rows 1029-1079 (51px)
/// - Tally dot: top-right corner ~60x53px
///
/// Produces:
/// - cleanFrame: overlay bars replaced with edge-extended video pixels (for stitching)
/// - topBarCrop, bottomBarCrop, tallyCrop: extracted regions (for metadata display)
public final class CropEngine: @unchecked Sendable {
    // Fixed crop regions (RED Komodo SDI overlay layout)
    public static let topBarHeight = 53
    public static let bottomBarStart = 1029
    public static let bottomBarHeight = 51
    public static let tallyRect = (x: 1855, y: 0, w: 60, h: 53)

    private var cleanPool: CVPixelBufferPool?
    private var topBarPool: CVPixelBufferPool?
    private var bottomBarPool: CVPixelBufferPool?
    private var tallyPool: CVPixelBufferPool?
    private var frameWidth: Int = 0
    private var frameHeight: Int = 0

    public struct CroppedFrame {
        public let cleanFrame: CVPixelBuffer
        public let topBarCrop: CVPixelBuffer
        public let bottomBarCrop: CVPixelBuffer
        public let tallyCrop: CVPixelBuffer
    }

    public init() {}

    /// Process a raw SDI frame. Returns nil if the frame can't be processed.
    public func process(_ pixelBuffer: CVPixelBuffer) -> CroppedFrame? {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        // Create pools if needed (first frame or resolution change)
        if w != frameWidth || h != frameHeight {
            frameWidth = w
            frameHeight = h
            createPools(width: w, height: h)
        }

        guard let cleanPool, let topBarPool, let bottomBarPool, let tallyPool else { return nil }

        // Allocate output buffers from pools
        var cleanBuf: CVPixelBuffer?
        var topBuf: CVPixelBuffer?
        var bottomBuf: CVPixelBuffer?
        var tallyBuf: CVPixelBuffer?

        CVPixelBufferPoolCreatePixelBuffer(nil, cleanPool, &cleanBuf)
        CVPixelBufferPoolCreatePixelBuffer(nil, topBarPool, &topBuf)
        CVPixelBufferPoolCreatePixelBuffer(nil, bottomBarPool, &bottomBuf)
        CVPixelBufferPoolCreatePixelBuffer(nil, tallyPool, &tallyBuf)

        guard let clean = cleanBuf, let top = topBuf, let bottom = bottomBuf, let tally = tallyBuf else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(clean, [])
        CVPixelBufferLockBaseAddress(top, [])
        CVPixelBufferLockBaseAddress(bottom, [])
        CVPixelBufferLockBaseAddress(tally, [])

        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(clean, [])
            CVPixelBufferUnlockBaseAddress(top, [])
            CVPixelBufferUnlockBaseAddress(bottom, [])
            CVPixelBufferUnlockBaseAddress(tally, [])
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer),
              let cleanBase = CVPixelBufferGetBaseAddress(clean),
              let topBase = CVPixelBufferGetBaseAddress(top),
              let bottomBase = CVPixelBufferGetBaseAddress(bottom),
              let tallyBase = CVPixelBufferGetBaseAddress(tally)
        else { return nil }

        let srcBPR = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let cleanBPR = CVPixelBufferGetBytesPerRow(clean)
        let topBPR = CVPixelBufferGetBytesPerRow(top)
        let bottomBPR = CVPixelBufferGetBytesPerRow(bottom)
        let tallyBPR = CVPixelBufferGetBytesPerRow(tally)

        let bpp = 4  // BGRA
        let topH = min(Self.topBarHeight, h)
        let botStart = min(Self.bottomBarStart, h)
        let botH = min(Self.bottomBarHeight, h - botStart)

        // ── Clean frame: copy entire frame, then overwrite bar regions ──
        // Copy full frame
        for y in 0..<h {
            let src = srcBase.advanced(by: y * srcBPR)
            let dst = cleanBase.advanced(by: y * cleanBPR)
            memcpy(dst, src, min(srcBPR, cleanBPR))
        }
        // Edge-extend: overwrite top bar rows with first clean row
        let firstCleanRow = cleanBase.advanced(by: topH * cleanBPR)
        for y in 0..<topH {
            let dst = cleanBase.advanced(by: y * cleanBPR)
            memcpy(dst, firstCleanRow, w * bpp)
        }
        // Edge-extend: overwrite bottom bar rows with last clean row
        let lastCleanRow = cleanBase.advanced(by: (botStart - 1) * cleanBPR)
        for y in botStart..<(botStart + botH) {
            let dst = cleanBase.advanced(by: y * cleanBPR)
            memcpy(dst, lastCleanRow, w * bpp)
        }

        // ── Top bar crop ──
        for y in 0..<topH {
            let src = srcBase.advanced(by: y * srcBPR)
            let dst = topBase.advanced(by: y * topBPR)
            memcpy(dst, src, w * bpp)
        }

        // ── Bottom bar crop ──
        for y in 0..<botH {
            let src = srcBase.advanced(by: (botStart + y) * srcBPR)
            let dst = bottomBase.advanced(by: y * bottomBPR)
            memcpy(dst, src, w * bpp)
        }

        // ── Tally crop (top-right corner) ──
        let tallyX = min(Self.tallyRect.x, w - Self.tallyRect.w)
        let tallyW = Self.tallyRect.w
        let tallyH = min(Self.tallyRect.h, h)
        for y in 0..<tallyH {
            let src = srcBase.advanced(by: y * srcBPR + tallyX * bpp)
            let dst = tallyBase.advanced(by: y * tallyBPR)
            memcpy(dst, src, tallyW * bpp)
        }

        return CroppedFrame(cleanFrame: clean, topBarCrop: top, bottomBarCrop: bottom, tallyCrop: tally)
    }

    // MARK: - Tally State Detection

    public enum TallyState {
        case idle, recording, transferring
    }

    /// Detect tally state by sampling the center of the tally crop region.
    public static func detectTallyState(from tallyCrop: CVPixelBuffer) -> TallyState {
        let w = CVPixelBufferGetWidth(tallyCrop)
        let h = CVPixelBufferGetHeight(tallyCrop)
        CVPixelBufferLockBaseAddress(tallyCrop, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(tallyCrop, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(tallyCrop) else { return .idle }
        let bpr = CVPixelBufferGetBytesPerRow(tallyCrop)

        // Sample a 10x10 region around center
        let cx = w / 2, cy = h / 2
        var totalR = 0, totalG = 0, totalB = 0, count = 0
        for dy in -5..<5 {
            for dx in -5..<5 {
                let x = cx + dx, y = cy + dy
                guard x >= 0, x < w, y >= 0, y < h else { continue }
                let ptr = base.advanced(by: y * bpr + x * 4)
                let b = Int(ptr.load(fromByteOffset: 0, as: UInt8.self))
                let g = Int(ptr.load(fromByteOffset: 1, as: UInt8.self))
                let r = Int(ptr.load(fromByteOffset: 2, as: UInt8.self))
                totalR += r; totalG += g; totalB += b; count += 1
            }
        }
        guard count > 0 else { return .idle }
        let avgR = totalR / count, avgG = totalG / count, avgB = totalB / count

        if avgR > 150 && avgG < 80 && avgB < 80 { return .recording }
        if avgR > 180 && avgG > 170 && avgB < 80 { return .transferring }
        return .idle
    }

    // MARK: - Private

    private func createPools(width: Int, height: Int) {
        cleanPool = makePool(width: width, height: height)
        topBarPool = makePool(width: width, height: Self.topBarHeight)
        bottomBarPool = makePool(width: width, height: Self.bottomBarHeight)
        tallyPool = makePool(width: Self.tallyRect.w, height: Self.tallyRect.h)
    }

    private func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
        ]
        let bufAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, bufAttrs as CFDictionary, &pool)
        return pool
    }
}
