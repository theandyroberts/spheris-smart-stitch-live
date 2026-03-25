#include <metal_stdlib>
using namespace metal;

struct CameraParams {
    float3x3 R_inv;        // World-to-camera rotation (R^T)
    float2 focal;           // (fx, fy) in pixels
    float2 principal;       // (cx, cy) in pixels
    float3 distABC;         // PTGui polynomial (a, b, c)
    float2 distDE;          // PTGui shift (d, e) in pixels
    float2 imageSize;       // (width, height) of source image
    float2 outputSize;      // (width, height) of equirectangular output
};

kernel void generateRemap(
    texture2d_array<half, access::write> remapArray [[texture(0)]],
    constant CameraParams& cam [[buffer(0)]],
    constant uint& sliceIndex [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(cam.outputSize.x) || gid.y >= uint(cam.outputSize.y)) return;

    float outW = cam.outputSize.x;
    float outH = cam.outputSize.y;

    // Pixel center → equirectangular → spherical coordinates
    float lon = ((float(gid.x) + 0.5) / outW) * 2.0 * M_PI_F - M_PI_F;
    float lat = ((float(gid.y) + 0.5) / outH) * M_PI_F - M_PI_F / 2.0;

    // Spherical → 3D ray direction (world space)
    float3 ray = float3(
        cos(lat) * sin(lon),
        sin(lat),
        cos(lat) * cos(lon)
    );

    // World → camera space
    float3 camRay = cam.R_inv * ray;

    // Behind camera check
    if (camRay.z <= 0.0) {
        remapArray.write(half4(0, 0, 0, 0), gid, sliceIndex);
        return;
    }

    // Rectilinear projection (normalized)
    float xn = camRay.x / camRay.z;
    float yn = camRay.y / camRay.z;

    // PTGui radial distortion: r' = a*r^4 + b*r^3 + c*r^2 + (1-a-b-c)*r
    // where r is normalized radius (1.0 = image half-diagonal mapped to focal)
    float r = sqrt(xn * xn + yn * yn);
    float a = cam.distABC.x;
    float b = cam.distABC.y;
    float c = cam.distABC.z;

    float scale;
    if (r > 0.0001) {
        float r2 = r * r;
        float r3 = r2 * r;
        float r4 = r2 * r2;
        float r_corrected = a * r4 + b * r3 + c * r2 + (1.0 - a - b - c) * r;
        scale = r_corrected / r;
    } else {
        scale = 1.0 - a - b - c;  // limit as r→0
    }

    float xd = xn * scale;
    float yd = yn * scale;

    // Pixel coordinates (d/e shift applied)
    float u = cam.focal.x * xd + cam.principal.x + cam.distDE.x;
    float v = cam.focal.y * yd + cam.principal.y + cam.distDE.y;

    // Bounds check with small margin
    float margin = 2.0;
    if (u < margin || u >= cam.imageSize.x - margin ||
        v < margin || v >= cam.imageSize.y - margin) {
        remapArray.write(half4(0, 0, 0, 0), gid, sliceIndex);
        return;
    }

    // Normalized UV for texture sampling [0, 1]
    float nu = u / cam.imageSize.x;
    float nv = v / cam.imageSize.y;

    // Blend weight: independent horizontal and vertical falloffs
    // Wide feather zones for smooth sky↔horizontal transitions
    float dx = abs(u - cam.principal.x) / (cam.imageSize.x * 0.5);  // 0 at center, 1 at edge
    float dy = abs(v - cam.principal.y) / (cam.imageSize.y * 0.5);

    // Horizontal edges: moderate feather (30% of half-width)
    float wx = smoothstep(1.0, 0.7, dx);
    // Vertical edges: very wide feather (60% of half-height) for sky↔horizontal blend
    float wy = smoothstep(1.0, 0.4, dy);

    float weight = wx * wy;

    remapArray.write(half4(half(nu), half(nv), half(weight), half(1.0)), gid, sliceIndex);
}
