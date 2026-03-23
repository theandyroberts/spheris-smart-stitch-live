#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut gridVertexShader(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

fragment float4 gridFragmentShader(VertexOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    return tex.sample(s, in.texCoord);
}

// Overlay fragment shader: samples RGBA texture with premultiplied alpha
fragment float4 overlayFragmentShader(VertexOut in [[stage_in]],
                                       texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    return tex.sample(s, in.texCoord);
}
