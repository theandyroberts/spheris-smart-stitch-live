import Foundation
import simd

/// Parsed calibration data from config/calibration.json
public struct CalibrationData: Codable {
    public let rigName: String
    public let created: String
    public let outputProjection: String
    public let outputSize: [Int]
    public let cameras: [CameraCalibration]

    enum CodingKeys: String, CodingKey {
        case rigName = "rig_name"
        case created
        case outputProjection = "output_projection"
        case outputSize = "output_size"
        case cameras
    }

    public var outputWidth: Int { outputSize[0] }
    public var outputHeight: Int { outputSize[1] }

    public func camera(forID id: String) -> CameraCalibration? {
        cameras.first { $0.id == id }
    }

    public static func load(from url: URL) throws -> CalibrationData {
        if url.pathExtension.lowercased() == "pts" {
            return try loadFromPTS(url: url)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CalibrationData.self, from: data)
    }

    // MARK: - PTGui .pts import

    /// Default sensor dimensions (RED Komodo 6K S35 in 2K mode)
    private static let defaultSensorWidthMM = 22.56

    /// Load calibration from a PTGui .pts project file (JSON format).
    public static func loadFromPTS(url: URL) throws -> CalibrationData {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let project = root["project"] as? [String: Any],
              let outputSize = project["outputsize"] as? [String: Any],
              let outW = outputSize["w"] as? Int,
              let outH = outputSize["h"] as? Int,
              let imageGroups = root["imagegroups"] as? [[String: Any]]
        else {
            throw PTSError.invalidFormat
        }

        // Collect all images from all image groups
        var cameras: [CameraCalibration] = []
        for group in imageGroups {
            guard let images = group["images"] as? [[String: Any]] else { continue }
            for img in images {
                guard let filename = img["filename"] as? String,
                      let width = img["width"] as? Int,
                      let height = img["height"] as? Int,
                      let hfov = img["hfov"] as? Double,
                      let yaw = img["yaw"] as? Double,
                      let pitch = img["pitch"] as? Double,
                      let roll = img["roll"] as? Double
                else { continue }

                // Skip excluded images
                if let include = img["include"] as? Bool, !include { continue }

                let lenstype = img["lenstype"] as? String ?? "rectilinear"

                // Derive camera ID from first letter of filename
                let id = String(filename.prefix(1)).uppercased()

                // Compute focal length in pixels from hfov
                let hfovRad = hfov * .pi / 180.0
                let focalPx = Double(width) / (2.0 * tan(hfovRad / 2.0))

                // Compute focal length in mm (assume RED Komodo sensor)
                let focalMm = focalPx * defaultSensorWidthMM / Double(width)

                // Vertical FOV
                let vfov = 2.0 * atan(Double(height) / (2.0 * focalPx)) * 180.0 / .pi

                // Infer group from pitch
                let camGroup = abs(pitch) > 30.0 ? "upward" : "horizontal"

                // Lens name from focal length
                let lensName = String(format: "%.0fmm %@", focalMm, lenstype)

                // PTGui distortion coefficients — pass through directly
                let ptsA = img["a"] as? Double ?? 0.0
                let ptsB = img["b"] as? Double ?? 0.0
                let ptsC = img["c"] as? Double ?? 0.0
                let ptsD = img["d"] as? Double ?? 0.0
                let ptsE = img["e"] as? Double ?? 0.0

                // Image file: strip extension
                let imageFile = (filename as NSString).deletingPathExtension

                let cam = CameraCalibration(
                    id: id,
                    imageFile: imageFile,
                    group: camGroup,
                    lens: lensName,
                    imageSize: [width, height],
                    projection: lenstype,
                    focalLengthPx: round(focalPx * 100) / 100,
                    focalLengthMm: round(focalMm * 10) / 10,
                    fovHDeg: round(hfov * 100) / 100,
                    fovVDeg: round(vfov * 100) / 100,
                    yawDeg: yaw,
                    pitchDeg: pitch,
                    rollDeg: roll,
                    distortion: DistortionParams(a: ptsA, b: ptsB, c: ptsC, d: ptsD, e: ptsE),
                    principalPoint: [Double(width) / 2.0, Double(height) / 2.0]
                )
                cameras.append(cam)
            }
        }

        guard !cameras.isEmpty else {
            throw PTSError.noCameras
        }

        return CalibrationData(
            rigName: "PTGui Import",
            created: ISO8601DateFormatter().string(from: Date()),
            outputProjection: "equirectangular",
            outputSize: [outW, outH],
            cameras: cameras
        )
    }

    enum PTSError: Error, LocalizedError {
        case invalidFormat
        case noCameras
        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "Invalid PTGui .pts file format"
            case .noCameras: return "No camera images found in .pts file"
            }
        }
    }
}

public struct CameraCalibration: Codable {
    public let id: String
    public let imageFile: String
    public let group: String
    public let lens: String
    public let imageSize: [Int]
    public let projection: String
    public let focalLengthPx: Double
    public let focalLengthMm: Double
    public let fovHDeg: Double
    public let fovVDeg: Double
    public let yawDeg: Double
    public let pitchDeg: Double
    public let rollDeg: Double
    public let distortion: DistortionParams
    public let principalPoint: [Double]

    enum CodingKeys: String, CodingKey {
        case id
        case imageFile = "image_file"
        case group
        case lens
        case imageSize = "image_size"
        case projection
        case focalLengthPx = "focal_length_px"
        case focalLengthMm = "focal_length_mm"
        case fovHDeg = "fov_h_deg"
        case fovVDeg = "fov_v_deg"
        case yawDeg = "yaw_deg"
        case pitchDeg = "pitch_deg"
        case rollDeg = "roll_deg"
        case distortion
        case principalPoint = "principal_point"
    }

    public var imageWidth: Int { imageSize[0] }
    public var imageHeight: Int { imageSize[1] }
    public var cx: Double { principalPoint[0] }
    public var cy: Double { principalPoint[1] }

    /// Rotation matrix R (camera-to-world): R = Ry * Rx * Rz
    public var rotationMatrix: simd_float3x3 {
        let y = Float(yawDeg * .pi / 180)
        let p = Float(pitchDeg * .pi / 180)
        let r = Float(rollDeg * .pi / 180)

        let ry = simd_float3x3(rows: [
            SIMD3(cos(y), 0, sin(y)),
            SIMD3(0, 1, 0),
            SIMD3(-sin(y), 0, cos(y))
        ])
        let rx = simd_float3x3(rows: [
            SIMD3(1, 0, 0),
            SIMD3(0, cos(p), -sin(p)),
            SIMD3(0, sin(p), cos(p))
        ])
        let rz = simd_float3x3(rows: [
            SIMD3(cos(r), -sin(r), 0),
            SIMD3(sin(r), cos(r), 0),
            SIMD3(0, 0, 1)
        ])
        return ry * rx * rz
    }

    /// Inverse rotation (world-to-camera) = R^T
    public var rotationInverse: simd_float3x3 {
        rotationMatrix.transpose
    }
}

/// PTGui-compatible distortion: r' = a*r^4 + b*r^3 + c*r^2 + (1-a-b-c)*r
/// d/e are horizontal/vertical pixel shift.
public struct DistortionParams: Codable {
    public let a: Double
    public let b: Double
    public let c: Double
    public let d: Double
    public let e: Double

    public init(a: Double = 0, b: Double = 0, c: Double = 0, d: Double = 0, e: Double = 0) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.e = e
    }
}
