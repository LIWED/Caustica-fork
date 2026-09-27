// Rain puddles are world-anchored material changes, not extra geometry. Terrain primitives are
// marked as rain-exposed by the CPU mesher; closest-hit must not issue additional sky ray queries.
module rain_surface;

import world_common;
import math;

float rainHash(int2 cell) {
    uint seed = asuint(cell.x) * 1664525u ^ asuint(cell.y) * 1013904223u;
    return float(pcg(seed) >> 8u) * (1.0 / 16777216.0);
}

float rainNoise(float2 p) {
    int2 cell = int2(floor(p));
    float2 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = lerp(rainHash(cell), rainHash(cell + int2(1, 0)), f.x);
    float b = lerp(rainHash(cell + int2(0, 1)), rainHash(cell + int2(1, 1)), f.x);
    return lerp(a, b, f.y);
}

public float rainPuddle(float3 hitPos, float3 geometricNormal, float wetness, float rain, float2 worldAnchor) {
    if ((wetness <= 0.001 && rain <= 0.02) || geometricNormal.y < 0.85) return 0.0;
    float wet = saturate(wetness);
    float2 worldXZ = hitPos.xz + worldAnchor;
    float noise = rainNoise(worldXZ * 0.42);
    // Preserve the small puddles visible as soon as rain starts; the persistent wetness
    // then spreads those patches and eventually covers all exposed ground.
    float initial = saturate(rain) * smoothstep(0.58, 0.70, noise);
    // Puddles spread from local depressions to the whole exposed surface as rain continues.
    float threshold = lerp(0.70, 0.18, wet);
    float patch = smoothstep(threshold - 0.07, threshold + 0.07, noise);
    return max(initial, lerp(wet * patch, wet, smoothstep(0.85, 1.0, wet)));
}

public float3 rainRipple(float2 worldXZ, float time, float strength) {
    float2 cell = floor(worldXZ * 0.75);
    int2 icell = int2(cell);
    float2 center = (cell + 0.25 + 0.5 * float2(
            rainHash(icell), rainHash(icell + int2(19, 47)))) / 0.75;
    float2 delta = worldXZ - center;
    float radius = length(delta);
    float phase = radius * 22.0 - time * 12.0 + rainHash(icell + int2(83, 17)) * 6.2831853;
    float slope = cos(phase) * exp(-radius * 6.0) * (0.025 * strength);
    float2 horizontal = delta / max(radius, 0.001) * slope;
    return float3(horizontal.x, 0.0, horizontal.y);
}
