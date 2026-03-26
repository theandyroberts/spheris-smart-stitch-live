import AppKit
import Metal

/// Loads RED Advanced Overlay reference screenshots and extracts the top/bottom
/// bar regions as Metal textures for compositing onto clean video frames in the grid view.
///
/// Three states: idle (not recording), recording, transferring.
/// Each state has a top-bar and bottom-bar texture extracted from the reference PNG.
public final class OverlaySimulator {
    public struct BarTextures {
        public let topBar: MTLTexture
        public let bottomBar: MTLTexture
    }

    private let idleBars: BarTextures
    private let recordingBars: BarTextures
    private let transferringBars: BarTextures

    public let topBarHeight: Int = CropEngine.topBarHeight     // 53
    public let bottomBarHeight: Int = CropEngine.bottomBarHeight // 51

    /// Load overlay textures from reference screenshots in the given directory.
    /// Returns nil if any reference image is missing.
    public init?(device: MTLDevice, referenceDir: URL) {
        guard let idle = Self.loadBars(device: device, referenceDir: referenceDir,
                                        filename: "NotRecordingSHD_0044.png"),
              let rec = Self.loadBars(device: device, referenceDir: referenceDir,
                                      filename: "ActiveRecordingSHD_0045.png"),
              let xfer = Self.loadBars(device: device, referenceDir: referenceDir,
                                        filename: "TransferingDataSHD_0046.png")
        else { return nil }

        self.idleBars = idle
        self.recordingBars = rec
        self.transferringBars = xfer
        print("OverlaySimulator loaded: 3 states × 2 bars")
    }

    /// Get the bar textures for a given tally state.
    public func bars(for state: CropEngine.TallyState) -> BarTextures {
        switch state {
        case .idle: return idleBars
        case .recording: return recordingBars
        case .transferring: return transferringBars
        }
    }

    // MARK: - Private

    private static func loadBars(device: MTLDevice, referenceDir: URL,
                                  filename: String) -> BarTextures? {
        let url = referenceDir.appendingPathComponent(filename)
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            print("OverlaySimulator: failed to load \(filename)")
            return nil
        }

        let w = cgImage.width   // 1920
        let topH = CropEngine.topBarHeight     // 53
        let botStart = CropEngine.bottomBarStart // 1029
        let botH = CropEngine.bottomBarHeight   // 51

        guard let topCG = cgImage.cropping(to: CGRect(x: 0, y: 0, width: w, height: topH)),
              let botCG = cgImage.cropping(to: CGRect(x: 0, y: botStart, width: w, height: botH))
        else { return nil }

        guard let topTex = textureFromCGImage(topCG, device: device),
              let botTex = textureFromCGImage(botCG, device: device)
        else { return nil }

        topTex.label = "\(filename)-topBar"
        botTex.label = "\(filename)-bottomBar"
        return BarTextures(topBar: topTex, bottomBar: botTex)
    }

    private static func textureFromCGImage(_ cgImage: CGImage, device: MTLDevice) -> MTLTexture? {
        let w = cgImage.width, h = cgImage.height
        let bpr = w * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(data: nil, width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: bpr,
                                   space: colorSpace,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                               CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: data, bytesPerRow: bpr)
        return tex
    }
}
