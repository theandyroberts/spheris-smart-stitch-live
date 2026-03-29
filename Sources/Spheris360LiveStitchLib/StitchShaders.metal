#include <metal_stdlib>
using namespace metal;

struct StitchVertexOut {
    float4 position [[position]];
};

struct StitchUniforms {
    uint  lutEnabled;  // 0 = off, 1 = on
    float exposure;    // stops of exposure compensation (0 = neutral)
    uint  drawableW;   // current drawable width
    uint  drawableH;   // current drawable height
};

// Full-screen triangle (3 vertices cover entire viewport, no vertex buffer needed)
vertex StitchVertexOut stitchVertexShader(uint vid [[vertex_id]]) {
    StitchVertexOut out;
    // Generate a full-screen triangle from vertex ID
    float2 pos;
    pos.x = (vid == 1) ? 3.0 : -1.0;
    pos.y = (vid == 2) ? 3.0 : -1.0;
    out.position = float4(pos, 0.0, 1.0);
    return out;
}

// Apply 3D LUT color grading
float3 applyLUT(float3 color, texture3d<float> lut) {
    constexpr sampler lutSamp(filter::linear, address::clamp_to_edge);
    // Clamp input and sample the 3D LUT (trilinear interpolation)
    float3 clamped = clamp(color, 0.0, 1.0);
    return lut.sample(lutSamp, clamped).rgb;
}

// Composite 9 cameras using precomputed remap lookup tables
fragment float4 stitchFragmentShader(
    StitchVertexOut in [[stage_in]],
    constant StitchUniforms &uniforms [[buffer(0)]],
    texture2d_array<half> remaps [[texture(0)]],
    texture2d<float> s0 [[texture(1)]],
    texture2d<float> s1 [[texture(2)]],
    texture2d<float> s2 [[texture(3)]],
    texture2d<float> s3 [[texture(4)]],
    texture2d<float> s4 [[texture(5)]],
    texture2d<float> s5 [[texture(6)]],
    texture2d<float> s6 [[texture(7)]],
    texture2d<float> s7 [[texture(8)]],
    texture2d<float> s8 [[texture(9)]],
    texture3d<float> lut [[texture(10)]])
{
    // Scale fragment position to remap texture dimensions so the full stitch
    // is visible regardless of drawable/window size
    float2 normPos = in.position.xy / float2(uniforms.drawableW, uniforms.drawableH);
    uint remapW = remaps.get_width();
    uint remapH = remaps.get_height();
    uint2 pos = uint2(clamp(normPos * float2(remapW, remapH), float2(0), float2(remapW - 1, remapH - 1)));
    constexpr sampler samp(filter::linear, address::clamp_to_edge);
    float3 color = float3(0);
    float tw = 0;
    half4 r; float2 uv; float w;

    // Camera 0
    r = remaps.read(pos, 0);
    if (r.a > 0.5h) { uv = float2(r.rg); w = float(r.b); color += s0.sample(samp, uv).rgb * w; tw += w; }

    // Camera 1
    r = remaps.read(pos, 1);
    if (r.a > 0.5h) { uv = float2(r.rg); w = float(r.b); color += s1.sample(samp, uv).rgb * w; tw += w; }

    // Camera 2
    r = remaps.read(pos, 2);
    if (r.a > 0.5h) { uv = float2(r.rg); w = float(r.b); color += s2.sample(samp, uv).rgb * w; tw += w; }

    // Camera 3
    r = remaps.read(pos, 3);
    if (r.a > 0.5h) { uv = float2(r.rg); w = float(r.b); color += s3.sample(samp, uv).rgb * w; tw += w; }

    // Camera 4
    r = remaps.read(pos, 4);
    if (r.a > 0.5h) { uv = float2(r.rg); w = float(r.b); color += s4.sample(samp, uv).rgb * w; tw += w; }

    // Camera 5
    r = remaps.read(pos, 5);
    if (r.a > 0.5h) { uv = float2(r.rg); w = float(r.b); color += s5.sample(samp, uv).rgb * w; tw += w; }

    // Camera 6
    r = remaps.read(pos, 6);
    if (r.a > 0.5h) { uv = float2(r.rg); w = float(r.b); color += s6.sample(samp, uv).rgb * w; tw += w; }

    // Camera 7
    r = remaps.read(pos, 7);
    if (r.a > 0.5h) { uv = float2(r.rg); w = float(r.b); color += s7.sample(samp, uv).rgb * w; tw += w; }

    // Camera 8
    r = remaps.read(pos, 8);
    if (r.a > 0.5h) { uv = float2(r.rg); w = float(r.b); color += s8.sample(samp, uv).rgb * w; tw += w; }

    if (tw > 0.0) color /= tw;

    // Apply color grade if enabled
    if (uniforms.lutEnabled != 0) {
        // Exposure in log space: adding in log = multiplying in linear
        // REDLog3G10 uses B=0.6 scaling, so 1 stop = +0.6*log10(2) ≈ +0.1806 in code value
        float logShift = uniforms.exposure * 0.1806;
        color = clamp(color + logShift, 0.0, 1.0);
        color = applyLUT(color, lut);
    }

    return float4(color, 1.0);
}
