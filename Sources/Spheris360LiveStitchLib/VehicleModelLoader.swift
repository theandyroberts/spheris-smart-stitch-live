import Foundation
import Metal
import MetalKit
import ModelIO
import simd

/// Material classification for vehicle submeshes.
public struct VehicleSubmeshMaterial: @unchecked Sendable {
    public var isGlass: Bool
    public var baseColor: SIMD3<Float>
    public var tintAmount: Float    // 0 = clear glass, 1 = fully tinted
    public var reflectivity: Float  // 0 = matte, 1 = mirror
    public var diffuseTexture: MTLTexture?  // albedo/diffuse map (nil = use baseColor)
}

/// A loaded vehicle model ready for Metal rendering.
public struct VehicleModel: @unchecked Sendable {
    public var meshes: [MTKMesh]
    public var materials: [[VehicleSubmeshMaterial]]  // parallel to meshes[i].submeshes
    public var name: String
}

/// Loads OBJ vehicle models from disk using ModelIO.
public final class VehicleModelLoader {

    /// Standard vertex descriptor: position (float3) + normal (float3) + texcoord (float2) = 32 bytes.
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
        desc.attributes[2] = MDLVertexAttribute(
            name: MDLVertexAttributeTextureCoordinate,
            format: .float2, offset: 24, bufferIndex: 0
        )
        desc.layouts[0] = MDLVertexBufferLayout(stride: 32)
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

        // Texture cache to avoid loading the same image file twice
        var textureCache: [String: MTLTexture] = [:]

        var allMaterials: [[VehicleSubmeshMaterial]] = []

        for (mdlMesh, _) in zip(mdlMeshes, mtkMeshes) {
            var submeshMats: [VehicleSubmeshMaterial] = []
            for sub in mdlMesh.submeshes as? [MDLSubmesh] ?? [] {
                let mat = classifyMaterial(
                    sub.material, device: device, objURL: objURL,
                    textureCache: &textureCache
                )
                submeshMats.append(mat)
            }
            // If no submeshes had materials, add a default opaque material
            if submeshMats.isEmpty {
                submeshMats.append(VehicleSubmeshMaterial(
                    isGlass: false,
                    baseColor: SIMD3<Float>(0.15, 0.15, 0.16),
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

        print("  Loaded \(textureCache.count) diffuse texture(s)")
        return VehicleModel(meshes: mtkMeshes, materials: allMaterials, name: name)
    }

    // MARK: - Texture loading

    /// Load the diffuse/albedo texture referenced by a material's baseColor property.
    private static func loadDiffuseTexture(
        _ material: MDLMaterial?,
        device: MTLDevice,
        objURL: URL,
        textureCache: inout [String: MTLTexture]
    ) -> MTLTexture? {
        guard let material = material,
              let prop = material.property(with: .baseColor)
        else { return nil }

        let texURL: URL?
        switch prop.type {
        case .string:
            guard let path = prop.stringValue, !path.isEmpty else { return nil }
            texURL = objURL.deletingLastPathComponent().appendingPathComponent(path)
        case .URL:
            texURL = prop.urlValue
        default:
            return nil
        }

        guard let url = texURL else { return nil }

        // Check cache
        let key = url.path
        if let cached = textureCache[key] { return cached }

        guard FileManager.default.fileExists(atPath: url.path) else {
            print("    Texture not found: \(url.lastPathComponent)")
            return nil
        }

        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .SRGB: true,
            .generateMipmaps: true
        ]
        do {
            let tex = try loader.newTexture(URL: url, options: options)
            textureCache[key] = tex
            print("    Loaded texture: \(url.lastPathComponent) (\(tex.width)x\(tex.height))")
            return tex
        } catch {
            print("    Failed to load texture \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Material classification

    /// Classify a ModelIO material as glass or opaque based on its name.
    /// Loads diffuse texture if available.
    private static func classifyMaterial(
        _ material: MDLMaterial?,
        device: MTLDevice,
        objURL: URL,
        textureCache: inout [String: MTLTexture]
    ) -> VehicleSubmeshMaterial {
        let name = (material?.name ?? "").lowercased()
        print("  Material: \"\(material?.name ?? "<none>")\" properties: \(material?.count ?? 0)")

        // Try to load diffuse texture
        let diffuseTex = loadDiffuseTexture(material, device: device, objURL: objURL,
                                            textureCache: &textureCache)

        let isGlass = name.contains("glass") || name.contains("window") ||
                      name.contains("windshield") || name.contains("transparent")

        if isGlass {
            let tint: Float = name.contains("tint") ? 0.15 :
                              name.contains("rear") ? 0.12 :
                              name.contains("side") ? 0.08 : 0.04
            return VehicleSubmeshMaterial(
                isGlass: true,
                baseColor: SIMD3<Float>(0.9, 0.92, 0.95),
                tintAmount: tint,
                reflectivity: 0.12,
                diffuseTexture: diffuseTex
            )
        }

        // Fallback color when no texture: use material name hints
        let color: SIMD3<Float>
        if diffuseTex != nil {
            color = SIMD3<Float>(1, 1, 1)  // white fallback (texture provides real color)
        } else {
            // Heuristic colors for untextured models
            let isInterior = name.contains("interior") || name.contains("seat") ||
                             name.contains("dashboard") || name.contains("fabric") ||
                             name.contains("leather") || name.contains("carpet")
            let isBlack = name.contains("rubber") || name.contains("tire") || name.contains("tyre") ||
                          name.contains("grill") || name.contains("grille")
            let isChrome = name.contains("chrome") || name.contains("metal") ||
                           name.contains("wheel") || name.contains("rim")
            if isInterior {
                color = SIMD3<Float>(0.08, 0.06, 0.05)
            } else if isBlack {
                color = SIMD3<Float>(0.03, 0.03, 0.03)
            } else if isChrome {
                color = SIMD3<Float>(0.7, 0.7, 0.72)
            } else {
                color = SIMD3<Float>(0.7, 0.05, 0.03)  // Rosso Corsa red
            }
        }

        let reflectivity: Float = name.contains("chrome") || name.contains("metal") ? 0.4 :
                                  name.contains("leather") || name.contains("fabric") ? 0.03 :
                                  name.contains("rubber") || name.contains("tire") ? 0.02 : 0.15

        return VehicleSubmeshMaterial(
            isGlass: false,
            baseColor: color,
            tintAmount: 0,
            reflectivity: reflectivity,
            diffuseTexture: diffuseTex
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
