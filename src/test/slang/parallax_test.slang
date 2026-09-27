// Executes the production solver with analytic height fields, without Minecraft or a GPU.
import parallax;

struct TestHeight : IParallaxHeight {
    uint kind;
    float height(float2 uv) {
        if (kind == 0u) return 1.0;
        if (kind == 1u) return 0.0;
        if (kind == 2u) return 0.5;
        if (kind == 3u) return uv.x;
        if (kind == 5u) return uv.x > 0.55 && uv.x < 0.65 ? 1.0 : 0.5;
        return uv.x <= 0.42 ? 1.0 : 0.0;
    }
};

RWStructuredBuffer<float2> results;

[shader("compute")]
[numthreads(1, 1, 1)]
void parallaxTests(uint3 tid : SV_DispatchThreadID) {
    uint i = tid.x;
    TestHeight field;
    field.kind = i;
    if (i == 28u || i == 29u || i == 30u || i == 33u || i == 34u) {
        field.kind = i == 29u ? 4u : i == 30u ? 2u : 3u;
        float2 hitUv = i == 29u ? float2(0.42, 0.5) : float2(0.5);
        float2 uv1 = i == 33u ? float2(-1, 0) : i == 34u ? float2(0, 1) : float2(1, 0);
        float2 uv2 = i == 34u ? float2(1, 0) : float2(0, 1);
        float3 normal = parallaxReliefNormal(field, hitUv, float2(0.01),
                float3(0, 0, 0), float3(1, 0, 0), float3(0, 1, 0),
                float2(0, 0), uv1, uv2,
                float3(0, 0, 1), 0.25);
        results[i] = float2(i == 34u ? normal.y : normal.x, normal.z);
        return;
    }
    if (i == 31u || i == 32u) {
        results[i] = float2(parallaxStepCount(float2(0.5, 0.0),
                float2(i == 31u ? 128.0 : 512.0), 32u), 0.0);
        return;
    }
    if (i == 27u) {
        results[i] = parallaxProjectedRay(float3(0, 0, 0), float3(1, 0, 0),
                float3(0, 1, 0), float2(0, 0), float2(1, 0), float2(0, 1),
                float3(0, 0, 1), normalize(float3(1, 0, 0.04)), 0.25);
        return;
    }
    if (i >= 23u) {
        field.kind = i == 23u ? 5u : 2u;
        float2 lightRay = i == 25u ? float2(0.4, 0.0) : float2(-0.4, 0.0);
        float depth = i == 26u ? 0.0 : 0.5;
        results[i] = float2(parallaxSelfShadow(field, float2(0.5, 0.5),
                depth, lightRay, 16u), 0.0);
        return;
    }
    if (i == 22u) {
        results[i] = parallaxFootprintInset(float2(16, 32), 1.2);
        return;
    }
    if (i == 15u) {
        results[i] = parallaxWrapUv(float2(-0.02, 1.02), float2(0.03125));
        return;
    }
    if (i == 16u) {
        results[i] = parallaxWrapUv(float2(0.01, 0.99), float2(0.5));
        return;
    }
    if (i == 17u || i == 18u) {
        field.kind = 3u;
        results[i] = parallaxTrace(field, float2(0.5), float2(-0.2, 0), i == 17u ? 0u : 1000u);
        return;
    }
    if (i < 5u) {
        results[i] = parallaxTrace(field, float2(0.5, 0.5), float2(-0.2, 0.0), 32u);
        return;
    }
    float3 p0 = float3(0, 0, 0);
    float3 p1 = float3(1, 0, 0);
    float3 p2 = float3(0, 1, 0);
    float2 uv0 = float2(0, 0);
    float2 uv1 = float2(1, 0);
    float2 uv2 = float2(0, 1);
    float3 view = normalize(float3(1, 0, 1));
    float strength = 1.0;
    float lod = 0.0;
    if (i == 6u) uv1.x = -1.0;
    if (i == 7u) { uv1 = float2(0, 1); uv2 = float2(1, 0); }
    if (i == 8u) strength = 0.0;
    if (i == 9u) uv1 = uv2;
    if (i == 10u) p1 = p2;
    if (i == 11u) lod = 4.0;
    if (i == 12u) view = float3(1, 0, 0);
    if (i == 13u) { p1 *= 2.0; p2 *= 2.0; }
    if (i == 14u) view = float3(0, 0, 1);
    if (i == 19u) strength = 2.0;
    if (i == 20u) { p1.x = 2.0; }
    if (i == 21u) { p2.x = 0.5; }
    results[i] = parallaxRayOffset(p0, p1, p2, uv0, uv1, uv2,
            float3(0, 0, 1), view, strength, lod);
}
