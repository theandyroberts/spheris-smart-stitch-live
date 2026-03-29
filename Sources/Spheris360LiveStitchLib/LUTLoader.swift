import Foundation
import Metal

/// Parses .cube 3D LUT files and creates Metal 3D textures for GPU color grading.
public final class LUTLoader {

    /// Load a .cube file and return a Metal 3D texture.
    /// The texture is RGBA16Float, dimension = LUT_3D_SIZE on each axis.
    public static func load(cubeURL: URL, device: MTLDevice) -> MTLTexture? {
        guard let contents = try? String(contentsOf: cubeURL, encoding: .utf8) else {
            print("LUTLoader: failed to read \(cubeURL.lastPathComponent)")
            return nil
        }

        var size = 0
        var data: [Float] = []

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("LUT_3D_SIZE") {
                let parts = trimmed.split(separator: " ")
                if parts.count >= 2, let s = Int(parts[1]) { size = s }
                continue
            }

            // Skip other header lines
            if trimmed.hasPrefix("TITLE") || trimmed.hasPrefix("DOMAIN") { continue }

            // Parse RGB triplet
            let parts = trimmed.split(separator: " ")
            guard parts.count >= 3,
                  let r = Float(parts[0]),
                  let g = Float(parts[1]),
                  let b = Float(parts[2])
            else { continue }

            data.append(r)
            data.append(g)
            data.append(b)
            data.append(1.0)  // alpha
        }

        guard size > 0 else {
            print("LUTLoader: no LUT_3D_SIZE found in \(cubeURL.lastPathComponent)")
            return nil
        }

        let expected = size * size * size
        let got = data.count / 4
        guard got == expected else {
            print("LUTLoader: expected \(expected) entries, got \(got)")
            return nil
        }

        // Convert Float to Float16 for the texture
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba16Float
        desc.width = size
        desc.height = size
        desc.depth = size
        desc.usage = .shaderRead
        desc.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: desc) else {
            print("LUTLoader: failed to create 3D texture")
            return nil
        }

        // Convert to Float16 and upload
        var float16Data = [UInt16](repeating: 0, count: data.count)
        for i in 0..<data.count {
            float16Data[i] = floatToHalf(data[i])
        }

        let bytesPerRow = size * 4 * MemoryLayout<UInt16>.size
        let bytesPerImage = bytesPerRow * size

        texture.replace(
            region: MTLRegionMake3D(0, 0, 0, size, size, size),
            mipmapLevel: 0,
            slice: 0,
            withBytes: float16Data,
            bytesPerRow: bytesPerRow,
            bytesPerImage: bytesPerImage
        )

        print("LUTLoader: loaded \(cubeURL.lastPathComponent) (\(size)x\(size)x\(size))")
        return texture
    }

    /// List available .cube files in the luts directory.
    public static func availableLUTs(lutsDir: URL) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: lutsDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "cube" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Float16 conversion

    private static func floatToHalf(_ value: Float) -> UInt16 {
        var f = value
        var h: UInt16 = 0
        withUnsafeBytes(of: &f) { fBytes in
            let bits = fBytes.load(as: UInt32.self)
            let sign = (bits >> 31) & 1
            let exp = Int((bits >> 23) & 0xFF) - 127
            let mantissa = bits & 0x7FFFFF

            if exp > 15 {
                // Overflow → max half
                h = UInt16(sign << 15) | 0x7BFF
            } else if exp < -14 {
                // Underflow → zero
                h = UInt16(sign << 15)
            } else {
                let halfExp = UInt16(exp + 15)
                let halfMantissa = UInt16(mantissa >> 13)
                h = UInt16(sign << 15) | (halfExp << 10) | halfMantissa
            }
        }
        return h
    }
}
