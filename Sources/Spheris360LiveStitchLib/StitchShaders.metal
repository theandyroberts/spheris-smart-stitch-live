#include <metal_stdlib>
using namespace metal;

struct StitchVertexOut {
    float4 position [[position]];
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

// Composite 9 cameras using precomputed remap lookup tables
fragment float4 stitchFragmentShader(
    StitchVertexOut in [[stage_in]],
    texture2d_array<half> remaps [[texture(0)]],
    texture2d<float> s0 [[texture(1)]],
    texture2d<float> s1 [[texture(2)]],
    texture2d<float> s2 [[texture(3)]],
    texture2d<float> s3 [[texture(4)]],
    texture2d<float> s4 [[texture(5)]],
    texture2d<float> s5 [[texture(6)]],
    texture2d<float> s6 [[texture(7)]],
    texture2d<float> s7 [[texture(8)]],
    texture2d<float> s8 [[texture(9)]])
{
    uint2 pos = uint2(in.position.xy);
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
    return float4(color, 1.0);
}
