import Foundation
import Metal
import simd

/// GPU buffer struct matching CameraParams in RemapCompute.metal.
/// float3x3 is 48 bytes (3 columns × 16 bytes each), followed by 5 × float2 (8 bytes each).
struct CameraParamsBuffer {
    var rotationInverse: simd_float3x3  // 48 bytes
    var focal: SIMD2<Float>             // 8 bytes
    var principal: SIMD2<Float>         // 8 bytes
    var distortion: SIMD2<Float>        // 8 bytes
    var imageSize: SIMD2<Float>         // 8 bytes
    var outputSize: SIMD2<Float>        // 8 bytes
}

/// Generates UV remap lookup textures for all 9 cameras using a Metal compute shader.
/// Output: a texture2d_array<half> with 9 slices at the equirectangular output resolution.
/// Each pixel stores (u, v, weight, valid) in RGBA16Float.
public final class RemapGenerator {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let computePipeline: MTLComputePipelineState

    public init(device: MTLDevice) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!

        // Compile compute shader from bundled .metal source
        guard let metalURL = Bundle.module.url(forResource: "RemapCompute", withExtension: "metal"),
              let source = try? String(contentsOf: metalURL, encoding: .utf8),
              let library = try? device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: "generateRemap")
        else {
            fatalError("Failed to compile RemapCompute.metal")
        }
        self.computePipeline = try! device.makeComputePipelineState(function: function)
    }

    /// Generate remap texture array for 9 grid slots.
    /// - Parameters:
    ///   - calibration: The loaded calibration data
    ///   - gridSlotCameraIDs: Camera ID for each grid slot, e.g. ["G","H","J","A","B","C","D","E","F"]
    ///   - outputWidth: Equirectangular output width (e.g. 3840)
    ///   - outputHeight: Equirectangular output height (e.g. 1920)
    /// - Returns: texture2d_array with 9 slices
    public func generate(calibration: CalibrationData,
                         gridSlotCameraIDs: [String],
                         outputWidth: Int,
                         outputHeight: Int) -> MTLTexture {
        // Create texture array
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .rgba16Float
        desc.width = outputWidth
        desc.height = outputHeight
        desc.arrayLength = gridSlotCameraIDs.count
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private

        guard let remapArray = device.makeTexture(descriptor: desc) else {
            fatalError("Failed to create remap texture array")
        }
        remapArray.label = "RemapLUT"

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            fatalError("Failed to create compute encoder")
        }

        encoder.setComputePipelineState(computePipeline)
        encoder.setTexture(remapArray, index: 0)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (outputWidth + 15) / 16,
            height: (outputHeight + 15) / 16,
            depth: 1
        )

        for (slotIndex, cameraID) in gridSlotCameraIDs.enumerated() {
            guard let cam = calibration.camera(forID: cameraID) else {
                print("Warning: camera \(cameraID) not found in calibration, slot \(slotIndex) will be empty")
                continue
            }

            var params = CameraParamsBuffer(
                rotationInverse: cam.rotationInverse,
                focal: SIMD2(Float(cam.focalLengthPx), Float(cam.focalLengthPx)),
                principal: SIMD2(Float(cam.cx), Float(cam.cy)),
                distortion: SIMD2(Float(cam.distortion.k1), Float(cam.distortion.k2)),
                imageSize: SIMD2(Float(cam.imageWidth), Float(cam.imageHeight)),
                outputSize: SIMD2(Float(outputWidth), Float(outputHeight))
            )
            var slice = UInt32(slotIndex)

            encoder.setBytes(&params, length: MemoryLayout<CameraParamsBuffer>.size, index: 0)
            encoder.setBytes(&slice, length: MemoryLayout<UInt32>.size, index: 1)
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        }

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        print("Remap LUT generated: \(outputWidth)x\(outputHeight) × \(gridSlotCameraIDs.count) slices")
        return remapArray
    }
}
