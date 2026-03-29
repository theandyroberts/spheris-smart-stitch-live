import Foundation
import Metal
import MetalKit
import ModelIO
import simd

/// Material classification for vehicle submeshes.
public struct VehicleSubmeshMaterial {
    public var isGlass: Bool
    public var baseColor: SIMD3<Float>
    public var tintAmount: Float    // 0 = clear glass, 1 = fully tinted
    public var reflectivity: Float  // 0 = matte, 1 = mirror
}

/// A loaded vehicle model ready for Metal rendering.
public struct VehicleModel {
    public var meshes: [MTKMesh]
    public var materials: [[VehicleSubmeshMaterial]]  // parallel to meshes[i].submeshes
    public var name: String
}

/// Loads OBJ vehicle models from disk using ModelIO.
public final class VehicleModelLoader {

    /// Standard vertex descriptor: position (float3) + normal (float3) = 24 bytes.
    public static func vertexDescriptor() -> MDLVertexDescriptor {
        let desc = MDLVertexDescriptor()
        desc.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition,
            format: .float3, offset: 0, bufferIndex: 0
        )
        desc.attributes[1] = MDLVertexAttribute(
            name: MDLVertexAttributeNormal,
            format: .float3, offset: 12, bufferIndex: 0
        )
        desc.layouts[0] = MDLVertexBufferLayout(stride: 24)
        return desc
    }

    /// Load an OBJ file and return a VehicleModel.
    /// Materials with names containing "glass", "window", or "windshield" are treated as transparent.
    public static func load(objURL: URL, device: MTLDevice) throws -> VehicleModel {
        let allocator = MTKMeshBufferAllocator(device: device)
        let vDesc = vertexDescriptor()

        let asset = MDLAsset(
            url: objURL,
            vertexDescriptor: vDesc,
            bufferAllocator: allocator
        )

        // Ensure normals exist
        for obj in asset.childObjects(of: MDLMesh.self) {
            if let mesh = obj as? MDLMesh {
                mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
            }
        }

        let (mdlMeshes, mtkMeshes) = try MTKMesh.newMeshes(asset: asset, device: device)

        var allMaterials: [[VehicleSubmeshMaterial]] = []

        for (mdlMesh, _) in zip(mdlMeshes, mtkMeshes) {
            var submeshMats: [VehicleSubmeshMaterial] = []
            for sub in mdlMesh.submeshes as? [MDLSubmesh] ?? [] {
                let mat = classifyMaterial(sub.material)
                submeshMats.append(mat)
            }
            // If no submeshes had materials, add a default opaque material
            if submeshMats.isEmpty {
                submeshMats.append(VehicleSubmeshMaterial(
                    isGlass: false,
                    baseColor: SIMD3<Float>(0.05, 0.05, 0.06),
                    tintAmount: 0,
                    reflectivity: 0.04
                ))
            }
            allMaterials.append(submeshMats)
        }

        let name = objURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized

        // Print bounding box for debugging model scale/position
        for (i, mdlMesh) in mdlMeshes.enumerated() {
            let bb = mdlMesh.boundingBox
            let min = bb.minBounds
            let max = bb.maxBounds
            let size = max - min
            print("  Mesh \(i): bounds min=(\(String(format: "%.2f, %.2f, %.2f", min.x, min.y, min.z))) max=(\(String(format: "%.2f, %.2f, %.2f", max.x, max.y, max.z))) size=(\(String(format: "%.2f, %.2f, %.2f", size.x, size.y, size.z)))")
        }

        return VehicleModel(meshes: mtkMeshes, materials: allMaterials, name: name)
    }

    /// Classify a ModelIO material as glass or opaque based on its name.
    private static func classifyMaterial(_ material: MDLMaterial?) -> VehicleSubmeshMaterial {
        let name = (material?.name ?? "").lowercased()
        let isGlass = name.contains("glass") || name.contains("window") ||
                      name.contains("windshield") || name.contains("transparent")

        if isGlass {
            // Determine tint level from name hints
            let tint: Float = name.contains("tint") ? 0.15 :
                              name.contains("rear") ? 0.12 :
                              name.contains("side") ? 0.08 : 0.04
            return VehicleSubmeshMaterial(
                isGlass: true,
                baseColor: SIMD3<Float>(0, 0, 0),
                tintAmount: tint,
                reflectivity: 0.12
            )
        }

        // Try to extract base color from material
        var color = SIMD3<Float>(0.05, 0.05, 0.06)  // default dark gray
        if let prop = material?.property(with: .baseColor) {
            if prop.type == .float3 {
                color = prop.float3Value
            } else if prop.type == .color {
                let c = prop.color ?? .init(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
                color = SIMD3<Float>(Float(c.components?[0] ?? 0.05),
                                     Float(c.components?[1] ?? 0.05),
                                     Float(c.components?[2] ?? 0.06))
            }
        }

        // Leather/fabric vs metal based on name
        let reflectivity: Float = name.contains("chrome") || name.contains("metal") ? 0.4 :
                                  name.contains("leather") || name.contains("fabric") ? 0.03 :
                                  name.contains("dashboard") || name.contains("dash") ? 0.15 : 0.04

        return VehicleSubmeshMaterial(
            isGlass: false,
            baseColor: color,
            tintAmount: 0,
            reflectivity: reflectivity
        )
    }

    /// Supported 3D model file extensions.
    private static let supportedExtensions: Set<String> = ["obj", "usdz", "usd", "usda", "usdc"]

    /// List available 3D model files in the vehicles config directory.
    public static func availableModels(vehiclesDir: URL) -> [(name: String, url: URL)] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: vehiclesDir, includingPropertiesForKeys: nil
        ) else { return [] }

        return files
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let name = url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: "_", with: " ")
                    .capitalized
                return (name: name, url: url)
            }
    }
}
