import CoreVideo
import Foundation
import Metal
import simd

/// Content-aware seam optimizer for 360 stitching.
/// Analyzes camera frames in overlap zones and computes optimal seam placement
/// using minimum-cost path finding. Updates the remap LUT weights so seams
/// avoid prominent features and follow regions where cameras agree.
public final class SeamOptimizer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    /// Scale factor for the seam computation (1/N resolution)
    private let downscale: Int = 8
    /// Width of the feathered blend zone along each seam, in full-res pixels
    private let featherWidth: Float = 80.0

    public init(device: MTLDevice) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
    }

    // MARK: - Public API

    /// Optimize seam placement given the current remap LUT and camera frames.
    /// Returns a NEW remap texture with updated blend weights.
    public func optimize(
        remapTexture: MTLTexture,
        cameraFrames: [Int: CVPixelBuffer]
    ) -> MTLTexture? {
        let width = remapTexture.width
        let height = remapTexture.height
        let sliceCount = remapTexture.arrayLength

        print("SeamOptimizer: starting (\(width)x\(height), \(sliceCount) cameras)")
        let startTime = CFAbsoluteTimeGetCurrent()

        // Step 1: Read remap LUT from GPU — work with raw UInt16 (Float16) buffers
        guard let rawSlices = readRemapRaw(remapTexture, width: width, height: height, slices: sliceCount)
        else {
            print("SeamOptimizer: failed to read remap texture")
            return nil
        }
        let t1 = CFAbsoluteTimeGetCurrent()
        print("  GPU readback: \(String(format: "%.1f", t1 - startTime))s")

        // Step 2: Read camera frame pixels
        let cameraPixels = readCameraFrames(cameraFrames)

        // Step 3: Find overlap pairs at downscaled resolution
        let dsW = width / downscale
        let dsH = height / downscale
        let overlapPairs = findOverlapPairs(rawSlices: rawSlices, width: width, height: height,
                                            slices: sliceCount, dsStep: downscale)
        print("  Found \(overlapPairs.count) overlap pairs")

        // Step 4: Build ownership map (which camera "owns" each pixel)
        var ownership = buildOwnershipMap(rawSlices: rawSlices, width: width, height: height, slices: sliceCount)

        // Step 5: For each pair, find optimal seam and update ownership
        for pair in overlapPairs {
            guard let costMap = buildCostMap(
                rawSlices: rawSlices, cameraPixels: cameraPixels,
                camA: pair.camA, camB: pair.camB,
                fullW: width, fullH: height, dsW: dsW, dsH: dsH
            ) else { continue }

            guard let seamPath = findSeamPath(costMap: costMap, width: dsW, height: dsH)
            else { continue }

            applySeam(seamPath: seamPath, ownership: &ownership,
                      rawSlices: rawSlices, camA: pair.camA, camB: pair.camB,
                      fullW: width, fullH: height, dsW: dsW, dsH: dsH)
        }
        let t2 = CFAbsoluteTimeGetCurrent()
        print("  Seam finding: \(String(format: "%.1f", t2 - t1))s")

        // Step 6: Apply feathered weights — modify raw buffers in-place
        var mutableSlices = rawSlices
        applyFeatheredWeights(ownership: ownership, rawSlices: &mutableSlices,
                              width: width, height: height, slices: sliceCount)
        let t3 = CFAbsoluteTimeGetCurrent()
        print("  Feathering: \(String(format: "%.1f", t3 - t2))s")

        // Step 7: Write back to GPU
        guard let newTexture = writeRemapRaw(mutableSlices, width: width, height: height, sliceCount: sliceCount)
        else {
            print("SeamOptimizer: failed to write updated remap texture")
            return nil
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("SeamOptimizer: complete in \(String(format: "%.1f", elapsed))s")
        return newTexture
    }

    // MARK: - Raw Float16 GPU ↔ CPU (no conversion)

    /// Read remap texture as raw UInt16 arrays (Float16 bits, 4 per pixel: R,G,B,A)
    private func readRemapRaw(_ texture: MTLTexture, width: Int, height: Int, slices: Int) -> [[UInt16]]? {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .rgba16Float
        desc.width = width
        desc.height = height
        desc.arrayLength = slices
        desc.usage = .shaderRead
        desc.storageMode = .managed

        guard let staging = device.makeTexture(descriptor: desc),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let blit = cmdBuf.makeBlitCommandEncoder()
        else { return nil }

        for s in 0..<slices {
            blit.copy(from: texture, sourceSlice: s, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: staging, destinationSlice: s, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        blit.synchronize(resource: staging)
        blit.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        let pixelCount = width * height
        let bytesPerRow = width * 8  // RGBA16Float = 8 bytes/pixel
        var result = [[UInt16]](repeating: [UInt16](repeating: 0, count: pixelCount * 4), count: slices)
        for s in 0..<slices {
            staging.getBytes(&result[s], bytesPerRow: bytesPerRow,
                             bytesPerImage: bytesPerRow * height,
                             from: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1)),
                             mipmapLevel: 0, slice: s)
        }
        return result
    }

    /// Write raw UInt16 arrays back to a new private GPU texture
    private func writeRemapRaw(_ slices: [[UInt16]], width: Int, height: Int, sliceCount: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .rgba16Float
        desc.width = width
        desc.height = height
        desc.arrayLength = sliceCount
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .managed

        guard let staging = device.makeTexture(descriptor: desc) else { return nil }
        let bytesPerRow = width * 8
        for s in 0..<sliceCount {
            slices[s].withUnsafeBufferPointer { ptr in
                staging.replace(
                    region: MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1)),
                    mipmapLevel: 0, slice: s,
                    withBytes: ptr.baseAddress!,
                    bytesPerRow: bytesPerRow, bytesPerImage: bytesPerRow * height)
            }
        }

        let privateDesc = MTLTextureDescriptor()
        privateDesc.textureType = .type2DArray
        privateDesc.pixelFormat = .rgba16Float
        privateDesc.width = width
        privateDesc.height = height
        privateDesc.arrayLength = sliceCount
        privateDesc.usage = [.shaderRead, .shaderWrite]
        privateDesc.storageMode = .private

        guard let privateTex = device.makeTexture(descriptor: privateDesc),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let blit = cmdBuf.makeBlitCommandEncoder()
        else { return nil }

        for s in 0..<sliceCount {
            blit.copy(from: staging, sourceSlice: s, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: privateTex, destinationSlice: s, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        blit.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        privateTex.label = "RemapLUT_SeamOptimized"
        return privateTex
    }

    // MARK: - Float16 Helpers (inline, no bulk conversion)

    @inline(__always)
    private func h2f(_ h: UInt16) -> Float {
        return Float(Float16(bitPattern: h))
    }

    @inline(__always)
    private func f2h(_ f: Float) -> UInt16 {
        return Float16(f).bitPattern
    }

    /// Read weight (channel B, index 2) from raw slice at pixel index
    @inline(__always)
    private func weight(_ slice: [UInt16], _ idx: Int) -> Float {
        h2f(slice[idx * 4 + 2])
    }

    /// Read active flag (channel A, index 3) from raw slice
    @inline(__always)
    private func active(_ slice: [UInt16], _ idx: Int) -> Bool {
        h2f(slice[idx * 4 + 3]) > 0.5
    }

    /// Read UV (channels R,G) from raw slice
    @inline(__always)
    private func readUV(_ slice: [UInt16], _ idx: Int) -> (u: Float, v: Float) {
        (h2f(slice[idx * 4]), h2f(slice[idx * 4 + 1]))
    }

    // MARK: - Camera Frame Reading

    private struct CamPixels {
        var pixels: UnsafeMutableBufferPointer<UInt8>
        var width: Int
        var height: Int
        var bytesPerRow: Int
        var buffer: CVPixelBuffer  // retain
    }

    private func readCameraFrames(_ frames: [Int: CVPixelBuffer]) -> [Int: CamPixels] {
        var result: [Int: CamPixels] = [:]
        for (slot, pb) in frames {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            guard let base = CVPixelBufferGetBaseAddress(pb) else {
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                continue
            }
            let ptr = UnsafeMutableBufferPointer(
                start: base.assumingMemoryBound(to: UInt8.self),
                count: bpr * h
            )
            result[slot] = CamPixels(pixels: ptr, width: w, height: h, bytesPerRow: bpr, buffer: pb)
        }
        return result
    }

    private func releaseCameraFrames(_ frames: [Int: CamPixels]) {
        for (_, cam) in frames {
            CVPixelBufferUnlockBaseAddress(cam.buffer, .readOnly)
        }
    }

    /// Sample camera frame at normalized UV. Returns RGB [0,1].
    @inline(__always)
    private func sampleCamera(_ cam: CamPixels, u: Float, v: Float) -> SIMD3<Float> {
        let ix = min(Int(u * Float(cam.width - 1)), cam.width - 1)
        let iy = min(Int(v * Float(cam.height - 1)), cam.height - 1)
        let offset = iy * cam.bytesPerRow + ix * 4
        guard offset + 2 < cam.pixels.count else { return .zero }
        return SIMD3(Float(cam.pixels[offset + 2]) / 255.0,  // R (BGRA)
                     Float(cam.pixels[offset + 1]) / 255.0,  // G
                     Float(cam.pixels[offset]) / 255.0)      // B
    }

    // MARK: - Overlap Detection

    private struct OverlapPair {
        var camA: Int
        var camB: Int
        var pixelCount: Int
    }

    private func findOverlapPairs(rawSlices: [[UInt16]], width: Int, height: Int,
                                   slices: Int, dsStep: Int) -> [OverlapPair] {
        var pairCounts: [Int: Int] = [:]
        for y in stride(from: 0, to: height, by: dsStep) {
            for x in stride(from: 0, to: width, by: dsStep) {
                let idx = y * width + x
                var activeList: [Int] = []
                for s in 0..<slices {
                    if active(rawSlices[s], idx) && weight(rawSlices[s], idx) > 0.01 {
                        activeList.append(s)
                    }
                }
                for i in 0..<activeList.count {
                    for j in (i+1)..<activeList.count {
                        let a = min(activeList[i], activeList[j])
                        let b = max(activeList[i], activeList[j])
                        pairCounts[a * slices + b, default: 0] += 1
                    }
                }
            }
        }
        return pairCounts.filter { $0.value >= 50 }
            .map { OverlapPair(camA: $0.key / slices, camB: $0.key % slices, pixelCount: $0.value) }
            .sorted { $0.pixelCount > $1.pixelCount }
    }

    // MARK: - Ownership Map

    private func buildOwnershipMap(rawSlices: [[UInt16]], width: Int, height: Int, slices: Int) -> [Int] {
        var ownership = [Int](repeating: -1, count: width * height)
        for idx in 0..<(width * height) {
            var bestSlice = -1
            var bestW: Float = 0
            for s in 0..<slices {
                let w = weight(rawSlices[s], idx)
                if active(rawSlices[s], idx) && w > bestW {
                    bestW = w
                    bestSlice = s
                }
            }
            ownership[idx] = bestSlice
        }
        return ownership
    }

    // MARK: - Cost Map

    private func buildCostMap(
        rawSlices: [[UInt16]], cameraPixels: [Int: CamPixels],
        camA: Int, camB: Int,
        fullW: Int, fullH: Int, dsW: Int, dsH: Int
    ) -> [Float]? {
        guard let pixA = cameraPixels[camA], let pixB = cameraPixels[camB] else { return nil }
        let sliceA = rawSlices[camA]
        let sliceB = rawSlices[camB]

        var costMap = [Float](repeating: Float.infinity, count: dsW * dsH)
        for dy in 0..<dsH {
            for dx in 0..<dsW {
                let fx = dx * downscale
                let fy = dy * downscale
                let idx = fy * fullW + fx

                guard active(sliceA, idx) && active(sliceB, idx) &&
                      weight(sliceA, idx) > 0.01 && weight(sliceB, idx) > 0.01
                else { continue }

                let uvA = readUV(sliceA, idx)
                let uvB = readUV(sliceB, idx)
                let colorA = sampleCamera(pixA, u: uvA.u, v: uvA.v)
                let colorB = sampleCamera(pixB, u: uvB.u, v: uvB.v)

                let diff = colorA - colorB
                costMap[dy * dsW + dx] = simd_dot(diff, diff)
            }
        }
        return costMap
    }

    // MARK: - Seam Finding (DP)

    private func findSeamPath(costMap: [Float], width: Int, height: Int) -> [Int]? {
        // Determine seam direction from overlap shape
        var rowCounts = [Int](repeating: 0, count: height)
        var colCounts = [Int](repeating: 0, count: width)
        for y in 0..<height {
            for x in 0..<width {
                if costMap[y * width + x] < Float.infinity {
                    rowCounts[y] += 1
                    colCounts[x] += 1
                }
            }
        }
        let avgRowWidth = Float(rowCounts.reduce(0, +)) / max(Float(rowCounts.filter { $0 > 0 }.count), 1)
        let avgColHeight = Float(colCounts.reduce(0, +)) / max(Float(colCounts.filter { $0 > 0 }.count), 1)

        if avgRowWidth >= avgColHeight {
            return findVerticalSeam(costMap: costMap, width: width, height: height)
        } else {
            var transposed = [Float](repeating: Float.infinity, count: width * height)
            for y in 0..<height { for x in 0..<width { transposed[x * height + y] = costMap[y * width + x] } }
            guard let seamX = findVerticalSeam(costMap: transposed, width: height, height: width) else { return nil }
            var result = [Int](repeating: width / 2, count: height)
            for x in 0..<min(width, seamX.count) {
                let y = seamX[x]
                if y >= 0 && y < height { result[y] = x }
            }
            return result
        }
    }

    private func findVerticalSeam(costMap: [Float], width: Int, height: Int) -> [Int]? {
        guard width > 0 && height > 0 else { return nil }
        var dp = [Float](repeating: Float.infinity, count: width * height)
        for x in 0..<width { dp[x] = costMap[x] }

        for y in 1..<height {
            for x in 0..<width {
                let cost = costMap[y * width + x]
                if cost >= Float.infinity { continue }
                var best = dp[(y-1) * width + x]
                if x > 0 { best = min(best, dp[(y-1) * width + (x-1)]) }
                if x < width-1 { best = min(best, dp[(y-1) * width + (x+1)]) }
                dp[y * width + x] = cost + best
            }
        }

        var minCost: Float = .infinity
        var minX = width / 2
        for x in 0..<width { if dp[(height-1) * width + x] < minCost { minCost = dp[(height-1) * width + x]; minX = x } }
        if minCost >= Float.infinity { return nil }

        var path = [Int](repeating: 0, count: height)
        path[height-1] = minX
        for y in stride(from: height-2, through: 0, by: -1) {
            let px = path[y+1]
            var bx = px, bc = dp[y * width + px]
            if px > 0 && dp[y * width + (px-1)] < bc { bc = dp[y * width + (px-1)]; bx = px-1 }
            if px < width-1 && dp[y * width + (px+1)] < bc { bx = px+1 }
            path[y] = bx
        }
        return path
    }

    // MARK: - Apply Seam

    private func applySeam(
        seamPath: [Int], ownership: inout [Int],
        rawSlices: [[UInt16]], camA: Int, camB: Int,
        fullW: Int, fullH: Int, dsW: Int, dsH: Int
    ) {
        // Determine which camera is "left" of the seam
        var sumXA: Float = 0, sumXB: Float = 0, countA: Float = 0, countB: Float = 0
        for dy in stride(from: 0, to: dsH, by: 2) {
            for dx in stride(from: 0, to: dsW, by: 2) {
                let idx = (dy * downscale) * fullW + (dx * downscale)
                let wA = weight(rawSlices[camA], idx)
                let wB = weight(rawSlices[camB], idx)
                if wA > wB { sumXA += Float(dx); countA += 1 }
                else if wB > 0 { sumXB += Float(dx); countB += 1 }
            }
        }
        let aIsLeft = (countA > 0 ? sumXA / countA : 0) <= (countB > 0 ? sumXB / countB : 0)

        for dy in 0..<dsH {
            guard dy < seamPath.count else { continue }
            let seamX = seamPath[dy]
            for dx in 0..<dsW {
                let fx = dx * downscale
                let fy = dy * downscale
                let idx = fy * fullW + fx
                guard active(rawSlices[camA], idx) && active(rawSlices[camB], idx) else { continue }

                let winner = ((dx < seamX) == aIsLeft) ? camA : camB
                for ry in 0..<downscale {
                    for rx in 0..<downscale {
                        let px = fx + rx, py = fy + ry
                        if px < fullW && py < fullH {
                            let fi = py * fullW + px
                            if active(rawSlices[camA], fi) && active(rawSlices[camB], fi) {
                                ownership[fi] = winner
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Feathered Weights

    private func applyFeatheredWeights(
        ownership: [Int], rawSlices: inout [[UInt16]],
        width: Int, height: Int, slices: Int
    ) {
        // BFS distance-to-seam
        var distToSeam = [Int16](repeating: Int16.max, count: width * height)
        var queue = [Int]()  // flat indices
        queue.reserveCapacity(width * 4)

        // Seed: pixels next to a different owner
        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                let owner = ownership[idx]
                if owner < 0 { continue }
                var isEdge = false
                if x > 0 { let n = ownership[idx-1]; if n >= 0 && n != owner { isEdge = true } }
                if !isEdge && x < width-1 { let n = ownership[idx+1]; if n >= 0 && n != owner { isEdge = true } }
                if !isEdge && y > 0 { let n = ownership[idx-width]; if n >= 0 && n != owner { isEdge = true } }
                if !isEdge && y < height-1 { let n = ownership[idx+width]; if n >= 0 && n != owner { isEdge = true } }
                if isEdge {
                    distToSeam[idx] = 0
                    queue.append(idx)
                }
            }
        }

        let maxDist = Int16(featherWidth) + 1
        var head = 0
        while head < queue.count {
            let ci = queue[head]; head += 1
            let cd = distToSeam[ci]
            if cd >= maxDist { continue }
            let nd = cd + 1
            let cx = ci % width, cy = ci / width
            if cx > 0     && nd < distToSeam[ci-1]     { distToSeam[ci-1] = nd; queue.append(ci-1) }
            if cx < width-1 && nd < distToSeam[ci+1]    { distToSeam[ci+1] = nd; queue.append(ci+1) }
            if cy > 0     && nd < distToSeam[ci-width]  { distToSeam[ci-width] = nd; queue.append(ci-width) }
            if cy < height-1 && nd < distToSeam[ci+width] { distToSeam[ci+width] = nd; queue.append(ci+width) }
        }

        // Read original weights for blending
        // Only process overlap pixels, skip single-camera
        for idx in 0..<(width * height) {
            let owner = ownership[idx]
            if owner < 0 { continue }

            // Count active cameras
            var activeCount = 0
            for s in 0..<slices { if active(rawSlices[s], idx) { activeCount += 1 } }
            if activeCount < 2 { continue }

            let dist = Float(distToSeam[idx])
            let t = min(dist / featherWidth, 1.0)
            let smooth = t * t * (3.0 - 2.0 * t)

            // Blend: at seam keep original weights, far from seam owner=1 others=0
            for s in 0..<slices {
                if !active(rawSlices[s], idx) { continue }
                let origW = h2f(rawSlices[s][idx * 4 + 2])
                let seamW: Float = (s == owner) ? 1.0 : 0.0
                let newW = origW * (1.0 - smooth) + seamW * smooth
                rawSlices[s][idx * 4 + 2] = f2h(newW)
            }
        }
    }

    // MARK: - Cleanup

    deinit {}
}
