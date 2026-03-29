#include <metal_stdlib>
using namespace metal;

struct VCamVertexOut {
    float4 position [[position]];
};

struct VCamUniforms {
    float yaw;        // radians
    float pitch;      // radians
    float fovH;       // horizontal field of view in radians
    float aspect;     // width / height
    uint  remapW;     // output drawable width
    uint  remapH;     // output drawable height
    uint  lutEnabled; // 0 = off, 1 = on
    float exposure;   // stops of exposure compensation
    uint  vehicleType; // 0=none, 1=convertible, 2=sedan, 3=SUV
    float homeYaw;    // vehicle forward direction in radians
};

// ── Vehicle interior material ──

struct VehicleMaterial {
    float opacity;       // 0 = fully transparent (window), 1 = fully opaque (body)
    float reflectivity;  // 0 = matte, 1 = mirror
    float3 bodyColor;    // base color of the surface
    float tint;          // window tint (0 = clear, 1 = fully tinted)
};

// Compute vehicle-relative angles from world ray direction
float2 vehicleAngles(float3 worldDir, float homeYaw) {
    // Rotate ray into vehicle space (undo homeYaw)
    float cy = cos(-homeYaw), sy = sin(-homeYaw);
    float3 vd;
    vd.x = cy * worldDir.x + sy * worldDir.z;
    vd.y = worldDir.y;
    vd.z = -sy * worldDir.x + cy * worldDir.z;

    // Vehicle-space yaw: 0 = forward, positive = right
    float vYaw = atan2(vd.x, vd.z) * (180.0 / M_PI_F);  // [-180, 180]
    float vPitch = asin(clamp(vd.y, -1.0, 1.0)) * (180.0 / M_PI_F);  // [-90, 90]
    return float2(vYaw, vPitch);
}

// Smoothstep-based edge softening for window/pillar transitions
float softEdge(float val, float edge, float width) {
    return smoothstep(edge - width, edge + width, val);
}

// ── Vehicle type definitions ──
// Returns material for a given vehicle-space direction

VehicleMaterial convertibleInterior(float vYaw, float vPitch) {
    VehicleMaterial m;
    float absYaw = abs(vYaw);
    float3 darkGray = float3(0.06, 0.06, 0.07);
    float3 leather  = float3(0.08, 0.06, 0.05);
    float3 chrome   = float3(0.15, 0.15, 0.16);

    // Below the horizon = dashboard/body/floor
    if (vPitch < -18.0) {
        // Dashboard and lower body
        m.opacity = 1.0;
        m.reflectivity = 0.15;
        m.bodyColor = leather;
        m.tint = 0.0;
        // Instrument cluster glow (forward, low)
        if (absYaw < 25.0 && vPitch > -35.0) {
            m.bodyColor = darkGray;
            m.reflectivity = 0.25;
        }
        return m;
    }

    // Windshield frame (forward)
    if (absYaw < 55.0 && vPitch > -18.0) {
        // A-pillars at ±48-55°
        float pillarEdge = softEdge(absYaw, 50.0, 2.0);
        if (pillarEdge > 0.5) {
            m.opacity = 1.0;
            m.reflectivity = 0.05;
            m.bodyColor = darkGray;
            m.tint = 0.0;
            return m;
        }
        // Windshield header at top (> 28°)
        if (vPitch > 28.0) {
            m.opacity = 1.0;
            m.reflectivity = 0.05;
            m.bodyColor = darkGray;
            m.tint = 0.0;
            return m;
        }
        // Windshield glass — very clear with faint reflection
        m.opacity = 0.0;
        m.reflectivity = 0.08;
        m.bodyColor = float3(0);
        m.tint = 0.03;
        return m;
    }

    // Sides — convertible is open (no doors above dash line)
    if (absYaw >= 55.0 && absYaw < 160.0) {
        // Door panels (below horizon line)
        if (vPitch < -5.0) {
            float doorHeight = mix(-5.0, -12.0, (absYaw - 55.0) / 105.0);
            if (vPitch < doorHeight) {
                m.opacity = 1.0;
                m.reflectivity = 0.1;
                m.bodyColor = darkGray;
                m.tint = 0.0;
                return m;
            }
        }
        // Open air — no roof, no side glass
        m.opacity = 0.0;
        m.reflectivity = 0.0;
        m.bodyColor = float3(0);
        m.tint = 0.0;
        return m;
    }

    // Rear — rollbar/headrests area
    if (absYaw >= 160.0) {
        if (vPitch < 15.0) {
            m.opacity = 1.0;
            m.reflectivity = 0.05;
            m.bodyColor = darkGray;
            m.tint = 0.0;
            return m;
        }
        // Open above
        m.opacity = 0.0;
        m.reflectivity = 0.0;
        m.bodyColor = float3(0);
        m.tint = 0.0;
        return m;
    }

    // Fallback: transparent
    m.opacity = 0.0;
    m.reflectivity = 0.0;
    m.bodyColor = float3(0);
    m.tint = 0.0;
    return m;
}

VehicleMaterial sedanInterior(float vYaw, float vPitch) {
    VehicleMaterial m;
    float absYaw = abs(vYaw);
    float3 darkGray  = float3(0.05, 0.05, 0.06);
    float3 headliner = float3(0.07, 0.07, 0.07);
    float3 leather   = float3(0.06, 0.05, 0.04);

    // Floor / lower body (below -25°)
    if (vPitch < -25.0) {
        m.opacity = 1.0;
        m.reflectivity = 0.05;
        m.bodyColor = darkGray;
        m.tint = 0.0;
        return m;
    }

    // Dashboard (forward, below -8°)
    if (absYaw < 55.0 && vPitch < -8.0) {
        m.opacity = 1.0;
        m.reflectivity = 0.2;
        m.bodyColor = leather;
        m.tint = 0.0;
        return m;
    }

    // Door panels (sides, below -8°)
    if (absYaw >= 55.0 && absYaw < 160.0 && vPitch < -8.0) {
        m.opacity = 1.0;
        m.reflectivity = 0.08;
        m.bodyColor = leather;
        m.tint = 0.0;
        return m;
    }

    // Rear shelf (back, below 0°)
    if (absYaw >= 160.0 && vPitch < 0.0) {
        m.opacity = 1.0;
        m.reflectivity = 0.06;
        m.bodyColor = leather;
        m.tint = 0.0;
        return m;
    }

    // Roof (above 35°) with sunroof
    if (vPitch > 35.0) {
        // Sunroof opening: forward of center, narrow
        if (absYaw < 30.0 && vPitch > 55.0 && vPitch < 80.0) {
            // Sunroof glass — tinted
            m.opacity = 0.0;
            m.reflectivity = 0.1;
            m.bodyColor = float3(0);
            m.tint = 0.15;
            return m;
        }
        m.opacity = 1.0;
        m.reflectivity = 0.03;
        m.bodyColor = headliner;
        m.tint = 0.0;
        return m;
    }

    // Windshield (forward)
    if (absYaw < 48.0 && vPitch >= -8.0 && vPitch <= 35.0) {
        // A-pillars at edges
        float pillarL = softEdge(absYaw, 44.0, 1.5);
        if (pillarL > 0.5) {
            m.opacity = 1.0;
            m.reflectivity = 0.04;
            m.bodyColor = darkGray;
            m.tint = 0.0;
            return m;
        }
        // Windshield glass
        m.opacity = 0.0;
        m.reflectivity = 0.1;
        m.bodyColor = float3(0);
        m.tint = 0.04;
        return m;
    }

    // Side windows
    if (absYaw >= 48.0 && absYaw < 145.0 && vPitch >= -8.0 && vPitch <= 35.0) {
        // B-pillar at ~100°
        float bPillar = 1.0 - smoothstep(95.0, 98.0, absYaw) * (1.0 - smoothstep(102.0, 105.0, absYaw));
        if (absYaw > 95.0 && absYaw < 105.0) {
            m.opacity = 1.0;
            m.reflectivity = 0.04;
            m.bodyColor = darkGray;
            m.tint = 0.0;
            return m;
        }
        // C-pillar at ~140°
        if (absYaw > 138.0) {
            m.opacity = 1.0;
            m.reflectivity = 0.04;
            m.bodyColor = darkGray;
            m.tint = 0.0;
            return m;
        }
        // Side glass — slightly tinted
        m.opacity = 0.0;
        m.reflectivity = 0.12;
        m.bodyColor = float3(0);
        m.tint = 0.08;
        return m;
    }

    // Rear window
    if (absYaw >= 145.0 && vPitch >= 0.0 && vPitch <= 35.0) {
        // Rear glass — more tinted
        m.opacity = 0.0;
        m.reflectivity = 0.1;
        m.bodyColor = float3(0);
        m.tint = 0.12;
        return m;
    }

    // Body panels (anything else between windows)
    if (vPitch >= -8.0 && vPitch <= 35.0) {
        m.opacity = 1.0;
        m.reflectivity = 0.04;
        m.bodyColor = darkGray;
        m.tint = 0.0;
        return m;
    }

    // Fallback
    m.opacity = 0.0;
    m.reflectivity = 0.0;
    m.bodyColor = float3(0);
    m.tint = 0.0;
    return m;
}

VehicleMaterial suvInterior(float vYaw, float vPitch) {
    VehicleMaterial m;
    float absYaw = abs(vYaw);
    float3 darkGray  = float3(0.04, 0.04, 0.05);
    float3 headliner = float3(0.06, 0.06, 0.06);
    float3 leather   = float3(0.05, 0.04, 0.03);

    // Higher viewpoint = more of the scene is below horizon
    // Floor / lower body (below -30°)
    if (vPitch < -30.0) {
        m.opacity = 1.0;
        m.reflectivity = 0.04;
        m.bodyColor = darkGray;
        m.tint = 0.0;
        return m;
    }

    // Dashboard — taller, more prominent
    if (absYaw < 55.0 && vPitch < -10.0) {
        m.opacity = 1.0;
        m.reflectivity = 0.18;
        m.bodyColor = leather;
        m.tint = 0.0;
        return m;
    }

    // Door panels (higher than sedan)
    if (absYaw >= 55.0 && absYaw < 155.0 && vPitch < -5.0) {
        m.opacity = 1.0;
        m.reflectivity = 0.06;
        m.bodyColor = leather;
        m.tint = 0.0;
        return m;
    }

    // Rear cargo area
    if (absYaw >= 155.0 && vPitch < 5.0) {
        m.opacity = 1.0;
        m.reflectivity = 0.04;
        m.bodyColor = darkGray;
        m.tint = 0.0;
        return m;
    }

    // Roof (above 38°) with sunroof
    if (vPitch > 38.0) {
        // Sunroof
        if (absYaw < 28.0 && vPitch > 55.0 && vPitch < 78.0) {
            m.opacity = 0.0;
            m.reflectivity = 0.1;
            m.bodyColor = float3(0);
            m.tint = 0.12;
            return m;
        }
        m.opacity = 1.0;
        m.reflectivity = 0.03;
        m.bodyColor = headliner;
        m.tint = 0.0;
        return m;
    }

    // Windshield — taller than sedan
    if (absYaw < 50.0 && vPitch >= -10.0 && vPitch <= 38.0) {
        // Thick A-pillars
        if (absYaw > 44.0) {
            m.opacity = 1.0;
            m.reflectivity = 0.04;
            m.bodyColor = darkGray;
            m.tint = 0.0;
            return m;
        }
        m.opacity = 0.0;
        m.reflectivity = 0.1;
        m.bodyColor = float3(0);
        m.tint = 0.05;
        return m;
    }

    // Side windows — taller
    if (absYaw >= 50.0 && absYaw < 148.0 && vPitch >= -5.0 && vPitch <= 38.0) {
        // B-pillar (thicker)
        if (absYaw > 93.0 && absYaw < 107.0) {
            m.opacity = 1.0;
            m.reflectivity = 0.04;
            m.bodyColor = darkGray;
            m.tint = 0.0;
            return m;
        }
        // D-pillar at back
        if (absYaw > 140.0) {
            m.opacity = 1.0;
            m.reflectivity = 0.04;
            m.bodyColor = darkGray;
            m.tint = 0.0;
            return m;
        }
        // Side glass — darker tint
        m.opacity = 0.0;
        m.reflectivity = 0.12;
        m.bodyColor = float3(0);
        m.tint = 0.12;
        return m;
    }

    // Rear window — small, high, tinted
    if (absYaw >= 148.0 && vPitch >= 5.0 && vPitch <= 38.0) {
        m.opacity = 0.0;
        m.reflectivity = 0.1;
        m.bodyColor = float3(0);
        m.tint = 0.18;
        return m;
    }

    // Body panels
    if (vPitch >= -5.0 && vPitch <= 38.0) {
        m.opacity = 1.0;
        m.reflectivity = 0.04;
        m.bodyColor = darkGray;
        m.tint = 0.0;
        return m;
    }

    m.opacity = 0.0;
    m.reflectivity = 0.0;
    m.bodyColor = float3(0);
    m.tint = 0.0;
    return m;
}

VehicleMaterial getVehicleMaterial(uint vehicleType, float3 worldDir, float homeYaw) {
    if (vehicleType == 0) {
        VehicleMaterial m;
        m.opacity = 0.0; m.reflectivity = 0.0;
        m.bodyColor = float3(0); m.tint = 0.0;
        return m;
    }
    float2 va = vehicleAngles(worldDir, homeYaw);
    if (vehicleType == 1) return convertibleInterior(va.x, va.y);
    if (vehicleType == 2) return sedanInterior(va.x, va.y);
    return suvInterior(va.x, va.y);
}

// ── Sampling helpers ──

float3 vcamApplyLUT(float3 color, texture3d<float> lut) {
    constexpr sampler lutSamp(filter::linear, address::clamp_to_edge);
    float3 clamped = clamp(color, 0.0, 1.0);
    return lut.sample(lutSamp, clamped).rgb;
}

// Sample the 360 sphere at a given world direction using the remap LUT
float3 sampleSphere(float3 worldDir,
                    texture2d_array<half> remaps,
                    texture2d<float> s0, texture2d<float> s1, texture2d<float> s2,
                    texture2d<float> s3, texture2d<float> s4, texture2d<float> s5,
                    texture2d<float> s6, texture2d<float> s7, texture2d<float> s8) {
    float lon = atan2(worldDir.x, worldDir.z);
    float lat = asin(clamp(worldDir.y, -1.0, 1.0));
    float eqU = (lon + M_PI_F) / (2.0 * M_PI_F);
    float eqV = (M_PI_F / 2.0 - lat) / M_PI_F;

    uint remapWidth = remaps.get_width();
    uint remapHeight = remaps.get_height();
    uint2 rpos = uint2(clamp(uint(eqU * float(remapWidth)), 0u, remapWidth - 1),
                        clamp(uint(eqV * float(remapHeight)), 0u, remapHeight - 1));

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

// ── Shaders ──

vertex VCamVertexOut vcamVertexShader(uint vid [[vertex_id]]) {
    VCamVertexOut out;
    float2 pos;
    pos.x = (vid == 1) ? 3.0 : -1.0;
    pos.y = (vid == 2) ? 3.0 : -1.0;
    out.position = float4(pos, 0.0, 1.0);
    return out;
}

fragment float4 vcamFragmentShader(
    VCamVertexOut in [[stage_in]],
    constant VCamUniforms &u [[buffer(0)]],
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
    float2 pixelPos = in.position.xy;
    float outW = float(u.remapW);
    float outH = float(u.remapH);

    float halfTanH = tan(u.fovH * 0.5);
    float halfTanV = halfTanH / u.aspect;

    // Camera-local ray direction
    float3 dir;
    dir.x = (2.0 * pixelPos.x / outW - 1.0) * halfTanH;
    dir.y = (1.0 - 2.0 * pixelPos.y / outH) * halfTanV;
    dir.z = 1.0;
    dir = normalize(dir);

    // Rotate by yaw then pitch
    float cy = cos(u.yaw), sy = sin(u.yaw);
    float cp = cos(u.pitch), sp = sin(u.pitch);

    float3 d1;
    d1.x = cy * dir.x + sy * dir.z;
    d1.y = dir.y;
    d1.z = -sy * dir.x + cy * dir.z;

    float3 d2;
    d2.x = d1.x;
    d2.y = cp * d1.y - sp * d1.z;
    d2.z = sp * d1.y + cp * d1.z;

    // Sample the 360 sphere
    float3 color = sampleSphere(d2, remaps, s0, s1, s2, s3, s4, s5, s6, s7, s8);

    // Apply color grade
    if (u.lutEnabled != 0) {
        float logShift = u.exposure * 0.1806;
        color = clamp(color + logShift, 0.0, 1.0);
        color = vcamApplyLUT(color, lut);
    }

    // Apply vehicle interior
    if (u.vehicleType != 0) {
        VehicleMaterial mat = getVehicleMaterial(u.vehicleType, d2, u.homeYaw);

        if (mat.opacity > 0.001 || mat.reflectivity > 0.001 || mat.tint > 0.001) {
            // Compute reflection direction (reflect d2 across surface normal)
            // For flat surfaces, approximate normal as pointing inward (toward center)
            // This gives a simple environment reflection
            float3 normal = -normalize(d2);  // inward-facing
            normal.y = 0;  // keep reflections horizontal
            normal = normalize(normal);
            float3 reflected = reflect(d2, normal);
            reflected = normalize(reflected);

            float3 reflColor = float3(0);
            if (mat.reflectivity > 0.01) {
                reflColor = sampleSphere(reflected, remaps, s0, s1, s2, s3, s4, s5, s6, s7, s8);
                if (u.lutEnabled != 0) {
                    float logShift = u.exposure * 0.1806;
                    reflColor = clamp(reflColor + logShift, 0.0, 1.0);
                    reflColor = vcamApplyLUT(reflColor, lut);
                }
            }

            // Window tint: darken the video slightly
            float3 tintedVideo = color * (1.0 - mat.tint * 0.7);

            // Blend reflection into video (for glass surfaces)
            float3 glassColor = mix(tintedVideo, reflColor, mat.reflectivity);

            // Blend between glass (transparent) and body (opaque)
            float3 bodyWithRefl = mix(mat.bodyColor, reflColor, mat.reflectivity * 0.5);
            color = mix(glassColor, bodyWithRefl, mat.opacity);
        }
    }

    return float4(color, 1.0);
}
