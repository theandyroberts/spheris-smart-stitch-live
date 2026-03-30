#include <metal_stdlib>
using namespace metal;

// ── Uniforms ──

struct VehicleVertexUniforms {
    float4x4 modelMatrix;
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float3x3 normalMatrix;
};

struct VehicleMaterialUniforms {
    float3   baseColor;
    float    reflectivity;
    float    tintAmount;
    uint     isGlass;
    uint     lutEnabled;
    float    exposure;
    uint     hasTexture;
};

// ── Vertex I/O ──

struct VehicleVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 texcoord [[attribute(2)]];
};

struct VehicleVertexOut {
    float4 clipPosition [[position]];
    float3 worldPosition;
    float3 worldNormal;
    float3 viewDir;
    float2 texcoord;
};

// ── Sphere sampling (duplicated from VirtualCameraShaders for glass reflections) ──

float3 vehicleSampleSphere(float3 worldDir,
                            texture2d_array<half> remaps,
                            texture2d<float> s0, texture2d<float> s1, texture2d<float> s2,
                            texture2d<float> s3, texture2d<float> s4, texture2d<float> s5,
                            texture2d<float> s6, texture2d<float> s7, texture2d<float> s8) {
    float lon = atan2(worldDir.x, worldDir.z);
    float lat = asin(clamp(worldDir.y, -1.0, 1.0));
    float eqU = (lon + M_PI_F) / (2.0 * M_PI_F);
    float eqV = (M_PI_F / 2.0 - lat) / M_PI_F;

    uint rW = remaps.get_width();
    uint rH = remaps.get_height();
    uint2 rpos = uint2(clamp(uint(eqU * float(rW)), 0u, rW - 1),
                        clamp(uint(eqV * float(rH)), 0u, rH - 1));

    constexpr sampler samp(filter::linear, address::clamp_to_edge);
    float3 color = float3(0);
    float tw = 0;
    half4 r; float2 uv; float w;

    r = remaps.read(rpos, 0); if (r.a > 0.5h) { uv = float2(r.rg); w = float(r.b); color += s0.sample(samp, uv).rgb * w; tw += w; }
    r = remaps.read(rpos, 1); if (r.a > 0.5h) { uv = float2(r.rg); w = float(r.b); color += s1.sample(samp, uv).rgb * w; tw += w; }
    r = remaps.read(rpos, 2); if (r.a > 0.5h) { uv = float2(r.rg); w = float(r.b); color += s2.sample(samp, uv).rgb * w; tw += w; }
    r = remaps.read(rpos, 3); if (r.a > 0.5h) { uv = float2(r.rg); w = float(r.b); color += s3.sample(samp, uv).rgb * w; tw += w; }
    r = remaps.read(rpos, 4); if (r.a > 0.5h) { uv = float2(r.rg); w = float(r.b); color += s4.sample(samp, uv).rgb * w; tw += w; }
    r = remaps.read(rpos, 5); if (r.a > 0.5h) { uv = float2(r.rg); w = float(r.b); color += s5.sample(samp, uv).rgb * w; tw += w; }
    r = remaps.read(rpos, 6); if (r.a > 0.5h) { uv = float2(r.rg); w = float(r.b); color += s6.sample(samp, uv).rgb * w; tw += w; }
    r = remaps.read(rpos, 7); if (r.a > 0.5h) { uv = float2(r.rg); w = float(r.b); color += s7.sample(samp, uv).rgb * w; tw += w; }
    r = remaps.read(rpos, 8); if (r.a > 0.5h) { uv = float2(r.rg); w = float(r.b); color += s8.sample(samp, uv).rgb * w; tw += w; }

    if (tw > 0.0) color /= tw;
    return color;
}

float3 vehicleApplyLUT(float3 color, texture3d<float> lut) {
    constexpr sampler lutSamp(filter::linear, address::clamp_to_edge);
    return lut.sample(lutSamp, clamp(color, 0.0, 1.0)).rgb;
}

// ── Vertex shader ──

vertex VehicleVertexOut vehicleVertexShader(
    VehicleVertexIn in [[stage_in]],
    constant VehicleVertexUniforms &u [[buffer(1)]])
{
    VehicleVertexOut out;
    float4 worldPos = u.modelMatrix * float4(in.position, 1.0);
    out.worldPosition = worldPos.xyz;
    out.worldNormal = normalize(u.normalMatrix * in.normal);
    out.clipPosition = u.projectionMatrix * u.viewMatrix * worldPos;
    out.viewDir = normalize(-worldPos.xyz);  // camera at origin
    out.texcoord = in.texcoord;
    return out;
}

// ── Opaque fragment shader ──

fragment float4 vehicleOpaqueFragmentShader(
    VehicleVertexOut in [[stage_in]],
    constant VehicleMaterialUniforms &mat [[buffer(0)]],
    texture2d_array<half> remaps [[texture(0)]],
    texture2d<float> s0 [[texture(1)]], texture2d<float> s1 [[texture(2)]],
    texture2d<float> s2 [[texture(3)]], texture2d<float> s3 [[texture(4)]],
    texture2d<float> s4 [[texture(5)]], texture2d<float> s5 [[texture(6)]],
    texture2d<float> s6 [[texture(7)]], texture2d<float> s7 [[texture(8)]],
    texture2d<float> s8 [[texture(9)]],
    texture3d<float> lut [[texture(10)]],
    texture2d<float> diffuseMap [[texture(11)]])
{
    float3 N = normalize(in.worldNormal);
    float3 V = normalize(in.viewDir);
    float NdotV = max(dot(N, V), 0.0);

    // Surface color: sample diffuse texture or use flat baseColor
    float3 surfaceColor;
    if (mat.hasTexture != 0) {
        constexpr sampler texSamp(filter::linear, mip_filter::linear, address::repeat);
        surfaceColor = diffuseMap.sample(texSamp, in.texcoord).rgb;
    } else {
        surfaceColor = mat.baseColor;
    }

    // Ambient + directional lighting
    float3 lightDir = normalize(float3(0.2, 1.0, 0.3));
    float diffuse = max(dot(N, lightDir), 0.0) * 0.5;
    float ambient = 0.35;

    float3 color = surfaceColor * (ambient + diffuse);

    // Environment reflection for metallic/glossy surfaces
    if (mat.reflectivity > 0.01) {
        float3 reflected = reflect(-V, N);
        float3 envColor = vehicleSampleSphere(reflected, remaps, s0, s1, s2, s3, s4, s5, s6, s7, s8);
        if (mat.lutEnabled != 0) {
            float logShift = mat.exposure * 0.1806;
            envColor = clamp(envColor + logShift, 0.0, 1.0);
            envColor = vehicleApplyLUT(envColor, lut);
        }
        // Fresnel
        float fresnel = mat.reflectivity + (1.0 - mat.reflectivity) * pow(1.0 - NdotV, 5.0);
        color = mix(color, envColor, fresnel * 0.5);
    }

    return float4(color, 1.0);
}

// ── Glass fragment shader ──

fragment float4 vehicleGlassFragmentShader(
    VehicleVertexOut in [[stage_in]],
    constant VehicleMaterialUniforms &mat [[buffer(0)]],
    texture2d_array<half> remaps [[texture(0)]],
    texture2d<float> s0 [[texture(1)]], texture2d<float> s1 [[texture(2)]],
    texture2d<float> s2 [[texture(3)]], texture2d<float> s3 [[texture(4)]],
    texture2d<float> s4 [[texture(5)]], texture2d<float> s5 [[texture(6)]],
    texture2d<float> s6 [[texture(7)]], texture2d<float> s7 [[texture(8)]],
    texture2d<float> s8 [[texture(9)]],
    texture3d<float> lut [[texture(10)]],
    texture2d<float> diffuseMap [[texture(11)]])
{
    float3 N = normalize(in.worldNormal);
    float3 V = normalize(in.viewDir);
    float NdotV = max(dot(N, V), 0.0);

    // Sample the 360 video "through" the glass
    float3 throughDir = normalize(in.worldPosition);
    float3 throughColor = vehicleSampleSphere(throughDir, remaps, s0, s1, s2, s3, s4, s5, s6, s7, s8);

    // Apply LUT to through-glass view
    if (mat.lutEnabled != 0) {
        float logShift = mat.exposure * 0.1806;
        throughColor = clamp(throughColor + logShift, 0.0, 1.0);
        throughColor = vehicleApplyLUT(throughColor, lut);
    }

    // Modulate with diffuse texture if present (e.g. tinted glass texture)
    if (mat.hasTexture != 0) {
        constexpr sampler texSamp(filter::linear, mip_filter::linear, address::repeat);
        float4 texColor = diffuseMap.sample(texSamp, in.texcoord);
        throughColor *= texColor.rgb;
    }

    // Apply window tint
    throughColor *= (1.0 - mat.tintAmount * 0.7);

    // Reflection
    float3 reflected = reflect(-V, N);
    float3 reflColor = vehicleSampleSphere(reflected, remaps, s0, s1, s2, s3, s4, s5, s6, s7, s8);
    if (mat.lutEnabled != 0) {
        float logShift = mat.exposure * 0.1806;
        reflColor = clamp(reflColor + logShift, 0.0, 1.0);
        reflColor = vehicleApplyLUT(reflColor, lut);
    }

    // Fresnel reflection
    float R0 = 0.04;
    float fresnel = R0 + (1.0 - R0) * pow(1.0 - NdotV, 5.0);
    fresnel *= mat.reflectivity / 0.12;

    float3 color = mix(throughColor, reflColor, clamp(fresnel, 0.0, 0.5));

    return float4(color, 1.0);
}
