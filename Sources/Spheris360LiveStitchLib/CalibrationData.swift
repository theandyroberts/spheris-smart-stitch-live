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
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CalibrationData.self, from: data)
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

public struct DistortionParams: Codable {
    public let k1: Double
    public let k2: Double
}
