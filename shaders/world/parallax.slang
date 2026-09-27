// Bounded texture-space POM. No ray queries, resource bindings or geometry displacement.
// The height provider keeps the solver shared between material pages and analytic CPU tests.
public interface IParallaxHeight {
    float height(float2 uv);
};

public static const uint PARALLAX_ENABLED = 1u << 8u;
public static const uint PARALLAX_DEPTH_SHIFT = 16u;

public float2 parallaxFootprintInset(float2 textureSize, float lod) {
    // Trilinear filtering touches ceil(lod), not just a footprint of exp2(lod).
    return min(float2(0.5), 0.5 * exp2(ceil(max(lod, 0.0))) / max(textureSize, float2(1.0)));
}

// Wrap within one sprite, then keep the complete bilinear footprint inside its own tile.
public float2 parallaxWrapUv(float2 uv, float2 inset) {
    inset = clamp(inset, float2(0.0), float2(0.5));
    return clamp(frac(uv), inset, 1.0 - inset);
}

// UV derivatives retain mirrored/rotated winding and non-uniform triangle scale. A normalized
// tangent frame alone would lose the relationship between texture extent and world distance.
public float2 parallaxProjectedRay(float3 p0, float3 p1, float3 p2,
        float2 uv0, float2 uv1, float2 uv2, float3 n, float3 view,
        float depth) {
    float NoV = dot(n, view);
    if (depth <= 0.0 || NoV <= 0.0) return float2(0.0);

    float2 g1 = uv1 - uv0;
    float2 g2 = uv2 - uv0;
    float det = g1.x * g2.y - g1.y * g2.x;
    if (abs(det) <= 1.0e-10) return float2(0.0);
    float3 du = ((p1 - p0) * g2.y - (p2 - p0) * g1.y) / det;
    float3 dv = ((p2 - p0) * g1.x - (p1 - p0) * g2.x) / det;
    float a = dot(du, du);
    float b = dot(du, dv);
    float c = dot(dv, dv);
    float metricDet = a * c - b * b;
    if (metricDet <= 1.0e-12) return float2(0.0);
    float vu = dot(view, du);
    float vv = dot(view, dv);
    float2 uvView = float2(c * vu - b * vv, a * vv - b * vu) / metricDet;
    float2 ray = -uvView * (depth * sqrt(min(a, c)) / max(NoV, 0.05));
    // Prevent extreme UV travel on thin/skewed triangles and grazing views.
    return ray * min(1.0, 0.5 / max(length(ray), 1.0e-6));
}

public float2 parallaxRayOffset(float3 p0, float3 p1, float3 p2,
        float2 uv0, float2 uv1, float2 uv2, float3 n, float3 view,
        float strength, float lod) {
    return parallaxProjectedRay(p0, p1, p2, uv0, uv1, uv2, n, view,
            parallaxDepth(strength, lod, dot(n, view)));
}

public float parallaxDepth(float strength, float lod, float NoV) {
    float fade = (1.0 - smoothstep(1.0, 4.0, lod)) * smoothstep(0.05, 0.15, NoV);
    return 0.25 * clamp(strength, 0.0, 2.0) * fade;
}

// Crossed texels, rather than just the view angle, set the required search resolution.
// At least 1.5 steps per texel prevents narrow ridges from being skipped by the first-hit search.
public uint parallaxStepCount(float2 rayUv, float2 textureSize, uint requestedSteps) {
    float crossed = length(rayUv * textureSize);
    return uint(clamp(max(float(requestedSteps), ceil(crossed * 1.5)), 8.0, 128.0));
}

public float2 parallaxTrace<T : IParallaxHeight>(T field, float2 uv, float2 rayUv, uint requestedSteps) {
    if (dot(rayUv, rayUv) <= 1.0e-12) return uv;
    float low = 0.0;
    float lowGap = 1.0 - saturate(field.height(uv));
    if (lowGap <= 0.0) return uv; // white alpha is the undisplaced top surface
    uint steps = clamp(requestedSteps, 8u, 128u);
    float high = 1.0;
    float highGap = 0.0;
    for (uint i = 1u; i <= steps; ++i) {
        high = float(i) / float(steps);
        highGap = 1.0 - saturate(field.height(uv + rayUv * high)) - high;
        if (highGap <= 0.0) break;
        low = high;
        lowGap = highGap;
    }
    // Refine only the first bracket; later layers may lie behind an occluding ridge.
    for (uint j = 0u; j < 5u; ++j) {
        float mid = (low + high) * 0.5;
        float gap = 1.0 - saturate(field.height(uv + rayUv * mid)) - mid;
        if (gap > 0.0) { low = mid; lowGap = gap; }
        else { high = mid; highGap = gap; }
    }
    float weight = saturate(lowGap / max(lowGap - highGap, 1.0e-6));
    return uv + rayUv * lerp(low, high, weight);
}

// The displaced height field has its own tangent plane. Recover its world normal from
// height derivatives in the triangle's UV metric; this makes a steep groove wall shade
// as a wall instead of as another flat slice carrying the top-face normal map.
public float3 parallaxReliefNormal<T : IParallaxHeight>(T field, float2 hitUv,
        float2 texelUv, float3 p0, float3 p1, float3 p2,
        float2 uv0, float2 uv1, float2 uv2, float3 n, float depth) {
    if (depth <= 0.0 || any(texelUv <= float2(0.0))) return n;
    float2 g1 = uv1 - uv0;
    float2 g2 = uv2 - uv0;
    float det = g1.x * g2.y - g1.y * g2.x;
    if (abs(det) <= 1.0e-10) return n;
    float3 du = ((p1 - p0) * g2.y - (p2 - p0) * g1.y) / det;
    float3 dv = ((p2 - p0) * g1.x - (p1 - p0) * g2.x) / det;
    float a = dot(du, du);
    float b = dot(du, dv);
    float c = dot(dv, dv);
    float metricDet = a * c - b * b;
    if (metricDet <= 1.0e-12) return n;
    float dhdu = (field.height(hitUv + float2(texelUv.x * 0.5, 0.0))
            - field.height(hitUv - float2(texelUv.x * 0.5, 0.0))) / texelUv.x;
    float dhdv = (field.height(hitUv + float2(0.0, texelUv.y * 0.5))
            - field.height(hitUv - float2(0.0, texelUv.y * 0.5))) / texelUv.y;
    float3 gradient = ((c * du - b * dv) * dhdu + (a * dv - b * du) * dhdv)
            / metricDet;
    return normalize(n - depth * sqrt(min(a, c)) * gradient);
}

// Trace from the camera-visible height toward the light, in the same local height field.
// inwardLightRay is the full-depth UV offset away from the light.
public float parallaxSelfShadow<T : IParallaxHeight>(T field, float2 hitUv,
        float hitDepth, float2 inwardLightRay, uint requestedSteps) {
    if (hitDepth <= 0.0 || dot(inwardLightRay, inwardLightRay) <= 1.0e-12) return 1.0;
    uint steps = clamp(requestedSteps, 4u, 20u);
    float visibility = 1.0;
    for (uint i = 0u; i < steps; ++i) {
        float progress = (float(i) + 0.5) / float(steps);
        float travel = hitDepth * progress;
        float rayHeight = 1.0 - hitDepth + travel;
        float blocker = saturate(field.height(hitUv - inwardLightRay * travel)) - rayHeight;
        visibility = min(visibility, 1.0 - smoothstep(0.015, 0.06, blocker));
        if (visibility < 0.001) break;
    }
    return visibility;
}
