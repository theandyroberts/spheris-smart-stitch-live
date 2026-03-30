import Foundation
import Metal
import MetalKit
import simd

/// Renders a loaded VehicleModel into the virtual camera view.
/// Handles opaque body surfaces and transparent glass with environment reflections.
public final class VehicleRenderer {
    private let device: MTLDevice
    private var opaquePipeline: MTLRenderPipelineState?
    private var glassPipeline: MTLRenderPipelineState?
    private var depthStateWrite: MTLDepthStencilState?
    private var depthStateRead: MTLDepthStencilState?
    private var vertexUniformBuffer: MTLBuffer?
    private var materialUniformBuffer: MTLBuffer?

    private var model: VehicleModel?

    // Matches VehicleShaders.metal
    struct VertexUniforms {
        var modelMatrix: simd_float4x4
        var viewMatrix: simd_float4x4
        var projectionMatrix: simd_float4x4
        var normalMatrix: simd_float3x3
        var _pad: Float = 0  // alignment
    }

    struct MaterialUniforms {
        var baseColor: SIMD3<Float>
        var reflectivity: Float
        var tintAmount: Float
        var isGlass: UInt32
        var lutEnabled: UInt32
        var exposure: Float
        var hasTexture: UInt32
    }

    public init(device: MTLDevice, colorFormat: MTLPixelFormat) {
        self.device = device

        guard let metalURL = Bundle.module.url(forResource: "VehicleShaders", withExtension: "metal", subdirectory: nil),
              let source = try? String(contentsOf: metalURL, encoding: .utf8),
              let library = try? device.makeLibrary(source: source, options: nil)
        else {
            print("VehicleRenderer: failed to compile VehicleShaders.metal")
            return
        }

        let vertexDesc = MTLVertexDescriptor()
        vertexDesc.attributes[0].format = .float3  // position
        vertexDesc.attributes[0].offset = 0
        vertexDesc.attributes[0].bufferIndex = 0
        vertexDesc.attributes[1].format = .float3  // normal
        vertexDesc.attributes[1].offset = 12
        vertexDesc.attributes[1].bufferIndex = 0
        vertexDesc.attributes[2].format = .float2  // texcoord
        vertexDesc.attributes[2].offset = 24
        vertexDesc.attributes[2].bufferIndex = 0
        vertexDesc.layouts[0].stride = 32

        // Opaque pipeline
        let opaqueDesc = MTLRenderPipelineDescriptor()
        opaqueDesc.vertexFunction = library.makeFunction(name: "vehicleVertexShader")
        opaqueDesc.fragmentFunction = library.makeFunction(name: "vehicleOpaqueFragmentShader")
        opaqueDesc.vertexDescriptor = vertexDesc
        opaqueDesc.colorAttachments[0].pixelFormat = colorFormat
        opaqueDesc.depthAttachmentPixelFormat = .depth32Float
        opaquePipeline = try? device.makeRenderPipelineState(descriptor: opaqueDesc)

        // Glass pipeline — alpha blending for any remaining transparency
        let glassDesc = MTLRenderPipelineDescriptor()
        glassDesc.vertexFunction = library.makeFunction(name: "vehicleVertexShader")
        glassDesc.fragmentFunction = library.makeFunction(name: "vehicleGlassFragmentShader")
        glassDesc.vertexDescriptor = vertexDesc
        glassDesc.colorAttachments[0].pixelFormat = colorFormat
        glassDesc.colorAttachments[0].isBlendingEnabled = true
        glassDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        glassDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        glassDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        glassDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        glassDesc.depthAttachmentPixelFormat = .depth32Float
        glassPipeline = try? device.makeRenderPipelineState(descriptor: glassDesc)

        // Depth states
        let depthWriteDesc = MTLDepthStencilDescriptor()
        depthWriteDesc.depthCompareFunction = .less
        depthWriteDesc.isDepthWriteEnabled = true
        depthStateWrite = device.makeDepthStencilState(descriptor: depthWriteDesc)

        let depthReadDesc = MTLDepthStencilDescriptor()
        depthReadDesc.depthCompareFunction = .less
        depthReadDesc.isDepthWriteEnabled = false
        depthStateRead = device.makeDepthStencilState(descriptor: depthReadDesc)

        vertexUniformBuffer = device.makeBuffer(length: MemoryLayout<VertexUniforms>.size, options: .storageModeShared)
        materialUniformBuffer = device.makeBuffer(length: MemoryLayout<MaterialUniforms>.size, options: .storageModeShared)
    }

    public func loadModel(_ model: VehicleModel?) {
        self.model = model
    }

    /// Encode vehicle draw calls into the existing render encoder.
    /// Call this AFTER the 360 panorama pass within the same render encoder.
    public func encode(
        encoder: MTLRenderCommandEncoder,
        viewMatrix: simd_float4x4,
        projectionMatrix: simd_float4x4,
        modelMatrix: simd_float4x4,
        remapTexture: MTLTexture,
        sourceTextures: [Int: MTLTexture],
        lutTexture: MTLTexture?,
        lutEnabled: Bool,
        exposure: Float
    ) {
        guard let model = model,
              let opaquePipe = opaquePipeline,
              let glassPipe = glassPipeline,
              let vBuf = vertexUniformBuffer,
              let mBuf = materialUniformBuffer
        else { return }

        // Compute normal matrix
        let modelInv = modelMatrix.inverse
        let normalMat = simd_float3x3(
            SIMD3(modelInv.columns.0.x, modelInv.columns.1.x, modelInv.columns.2.x),
            SIMD3(modelInv.columns.0.y, modelInv.columns.1.y, modelInv.columns.2.y),
            SIMD3(modelInv.columns.0.z, modelInv.columns.1.z, modelInv.columns.2.z)
        )

        var vertUniforms = VertexUniforms(
            modelMatrix: modelMatrix,
            viewMatrix: viewMatrix,
            projectionMatrix: projectionMatrix,
            normalMatrix: normalMat
        )
        memcpy(vBuf.contents(), &vertUniforms, MemoryLayout<VertexUniforms>.size)

        // Bind 360 textures for reflections/glass
        encoder.setFragmentTexture(remapTexture, index: 0)
        for i in 0..<9 {
            if let src = sourceTextures[i] {
                encoder.setFragmentTexture(src, index: 1 + i)
            }
        }
        if let lut = lutTexture {
            encoder.setFragmentTexture(lut, index: 10)
        }

        // Pass 1: Opaque submeshes
        encoder.setRenderPipelineState(opaquePipe)
        encoder.setDepthStencilState(depthStateWrite)
        encoder.setVertexBuffer(vBuf, offset: 0, index: 1)

        for (meshIdx, mesh) in model.meshes.enumerated() {
            encoder.setVertexBuffer(mesh.vertexBuffers[0].buffer,
                                     offset: mesh.vertexBuffers[0].offset,
                                     index: 0)
            let mats = model.materials[meshIdx]
            for (subIdx, submesh) in mesh.submeshes.enumerated() {
                let mat = subIdx < mats.count ? mats[subIdx] : mats[0]
                if mat.isGlass { continue }
                var matU = MaterialUniforms(
                    baseColor: mat.baseColor,
                    reflectivity: mat.reflectivity,
                    tintAmount: mat.tintAmount,
                    isGlass: 0,
                    lutEnabled: lutEnabled ? 1 : 0,
                    exposure: exposure,
                    hasTexture: mat.diffuseTexture != nil ? 1 : 0
                )
                memcpy(mBuf.contents(), &matU, MemoryLayout<MaterialUniforms>.size)
                encoder.setFragmentBuffer(mBuf, offset: 0, index: 0)
                if let diffTex = mat.diffuseTexture {
                    encoder.setFragmentTexture(diffTex, index: 11)
                }
                encoder.drawIndexedPrimitives(
                    type: submesh.primitiveType,
                    indexCount: submesh.indexCount,
                    indexType: submesh.indexType,
                    indexBuffer: submesh.indexBuffer.buffer,
                    indexBufferOffset: submesh.indexBuffer.offset
                )
            }
        }

        // Pass 2: Glass submeshes (drawn after opaque for correct blending)
        encoder.setRenderPipelineState(glassPipe)
        encoder.setDepthStencilState(depthStateRead)  // read depth but don't write

        for (meshIdx, mesh) in model.meshes.enumerated() {
            encoder.setVertexBuffer(mesh.vertexBuffers[0].buffer,
                                     offset: mesh.vertexBuffers[0].offset,
                                     index: 0)
            let mats = model.materials[meshIdx]
            for (subIdx, submesh) in mesh.submeshes.enumerated() {
                let mat = subIdx < mats.count ? mats[subIdx] : mats[0]
                if !mat.isGlass { continue }
                var matU = MaterialUniforms(
                    baseColor: mat.baseColor,
                    reflectivity: mat.reflectivity,
                    tintAmount: mat.tintAmount,
                    isGlass: 1,
                    lutEnabled: lutEnabled ? 1 : 0,
                    exposure: exposure,
                    hasTexture: mat.diffuseTexture != nil ? 1 : 0
                )
                memcpy(mBuf.contents(), &matU, MemoryLayout<MaterialUniforms>.size)
                encoder.setFragmentBuffer(mBuf, offset: 0, index: 0)
                if let diffTex = mat.diffuseTexture {
                    encoder.setFragmentTexture(diffTex, index: 11)
                }
                encoder.drawIndexedPrimitives(
                    type: submesh.primitiveType,
                    indexCount: submesh.indexCount,
                    indexType: submesh.indexType,
                    indexBuffer: submesh.indexBuffer.buffer,
                    indexBufferOffset: submesh.indexBuffer.offset
                )
            }
        }
    }

    // MARK: - Matrix helpers

    public static func perspectiveMatrix(fovRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1.0 / tan(fovRadians * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4(x,   0,  0,  0),
            SIMD4(0,   y,  0,  0),
            SIMD4(0,   0,  z, -1),
            SIMD4(0,   0,  z * near,  0)
        ))
    }

    public static func viewMatrix(yaw: Float, pitch: Float) -> simd_float4x4 {
        // Inverse camera rotation: rotate world by -pitch then -yaw
        let cp = cos(-pitch), sp = sin(-pitch)
        let cy = cos(-yaw), sy = sin(-yaw)

        let rotX = simd_float4x4(columns: (
            SIMD4(1,  0,   0,  0),
            SIMD4(0,  cp, sp,  0),
            SIMD4(0, -sp, cp,  0),
            SIMD4(0,  0,   0,  1)
        ))
        let rotY = simd_float4x4(columns: (
            SIMD4(cy,  0, -sy,  0),
            SIMD4(0,   1,  0,   0),
            SIMD4(sy,  0,  cy,  0),
            SIMD4(0,   0,  0,   1)
        ))
        return rotX * rotY
    }

    /// Build model matrix with full transform chain:
    /// 1. Scale the model (handles cm→m conversion etc.)
    /// 2. Rotate model to align its forward direction with +Z
    /// 3. Rotate by homeYaw to align with the rig's forward
    /// 4. Translate so camera is at driver eye position
    public static func modelMatrix(
        homeYaw: Float,
        seatOffset: SIMD3<Float> = SIMD3(0, -1.1, 0),
        modelScale: Float = 1.0,
        modelRotationY: Float = 0  // extra rotation to align model forward with +Z
    ) -> simd_float4x4 {
        let s = modelScale
        let scale = simd_float4x4(columns: (
            SIMD4(s, 0, 0, 0),
            SIMD4(0, s, 0, 0),
            SIMD4(0, 0, s, 0),
            SIMD4(0, 0, 0, 1)
        ))

        let cr = cos(modelRotationY), sr = sin(modelRotationY)
        let modelRot = simd_float4x4(columns: (
            SIMD4(cr,  0, sr, 0),
            SIMD4(0,   1, 0,  0),
            SIMD4(-sr, 0, cr, 0),
            SIMD4(0,   0, 0,  1)
        ))

        let cy = cos(homeYaw), sy = sin(homeYaw)
        let worldRot = simd_float4x4(columns: (
            SIMD4(cy,  0, sy, 0),
            SIMD4(0,   1, 0,  0),
            SIMD4(-sy, 0, cy, 0),
            SIMD4(0,   0, 0,  1)
        ))

        let translation = simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(seatOffset.x, seatOffset.y, seatOffset.z, 1)
        ))

        return translation * worldRot * modelRot * scale
    }
}
