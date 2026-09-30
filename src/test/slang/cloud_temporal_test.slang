// Run the production cloud functions on CPU, including the actual noise and mask.
import cloud_volume;
import world_common;

RWStructuredBuffer<float4> results;

[shader("compute")]
[numthreads(1, 1, 1)]
void cloudTemporalTests(uint3 tid : SV_DispatchThreadID) {
    uint i = tid.x;
    WorldPush push = {};
    push.flags = (1u << 9u) | (2u << 10u) | (100u << 24u);
    push.cloudAnchor = float4(0, 0, 1, 1);
    push.cloudTuning = float4(2, 24, 0, 0);
    push.weatherColor.w = 128.0;
    float2 xz = float2(float(i % 128u) * 37.1 - 2400.0,
                       float((i / 128u) % 128u) * 41.3 - 2600.0);
    float h = float(i % 31u) * (46.0 / 30.0);
    float d0 = cloudLayerDensity(push, xz, h, 0, 2, false, float3(0), float3(0, 1, 0), 1);
    float d1 = cloudLayerDensityReference(push, xz, h, 0, 2, false,
                                float3(0), float3(0, 1, 0), 1);
    // One 60 Hz step at the reported sun-elevation rate, across the whole grazing range.
    float y = 0.005 + float((i / 16384u) % 32u) * (0.245 / 31.0);
    push.lightDir = float4(sqrt(1.0 - y * y), y, 0, 0);
    float a = cloudSunTransmittance(push, float3(xz.x, 0, xz.y), push.lightDir.xyz);
    y += 0.005 / 60.0;
    push.lightDir = float4(sqrt(1.0 - y * y), y, 0, 0);
    float b = cloudSunTransmittance(push, float3(xz.x, 0, xz.y), push.lightDir.xyz);
    results[i] = float4(d0, d1, a, b);
}

[shader("compute")]
[numthreads(1, 1, 1)]
void cloudInvariantTests(uint3 tid : SV_DispatchThreadID) {
    WorldPush push = {};
    push.flags = (1u << 9u) | (2u << 10u) | (100u << 24u);
    push.cloudAnchor = float4(0, 0, 1, 1);
    push.cloudTuning = float4(2, 24, 0, 0);
    push.weatherColor.w = 128.0;
    push.lightDir = float4(normalize(float3(1, 0.1, 0.2)), 0);
    float3 pos = float3(float(tid.x) * 37.0 - 1200.0, 0, 570.0);
    float base = cloudSunTransmittance(push, pos, push.lightDir.xyz);
    float jittered = cloudSunTransmittance(push, pos, normalize(push.lightDir.xyz + float3(0.1, -0.2, 0.1)));
    float above = cloudSunTransmittance(push, float3(pos.x, 1000, pos.z), push.lightDir.xyz);
    push.frameIndex = 423u;
    push.camOffset = float3(1300, 220, -410);
    push.cloudAnchor.xy += float2(256, -512);
    push.weatherColor.w -= 256;
    pos -= float3(256, 256, -512);
    float rebased = cloudSunTransmittance(push, pos, push.lightDir.xyz);
    push.flags &= ~(1u << 9u);
    float disabled = cloudSunTransmittance(push, pos, push.lightDir.xyz);
    results[tid.x] = float4(disabled, above, rebased - base, jittered - base);
}
