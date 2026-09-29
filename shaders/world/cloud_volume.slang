// Analytic layered cloud planes. View shading and world-space shadows share the
// same weather-driven coverage field; only fine view detail is perspective-filtered.
module cloud_volume;
import world_common;

public struct VolumeCloudResult {
    public float transmittance;
    public float3 radiance;
};

// Two finite-height sheets, in rebased world blocks. These are original Caustica
// tuning values, not shader-pack constants. All samples are deterministic.
public static const float CLOUD_FAR = 32768.0;
static const float CLOUD_FADE_START = 27852.8;
static const float CLOUD_LOW_OFFSET = -8.0;
static const float CLOUD_HIGH_OFFSET = 212.0;
static const float CLOUD_LOW_SCALE = 0.0032;
static const float CLOUD_HIGH_SCALE = 0.0019;
static const float2 CLOUD_LOW_WIND = float2(0.0113, -0.0067);
static const float2 CLOUD_HIGH_WIND = float2(-0.0071, -0.0106);
static const float CLOUD_EXTINCTION = 2.45;
static const float CLOUD_DETAIL_COMPRESSION = 0.00035;
static const float CLOUD_DETAIL_WARP = 28.0;
static const float CLOUD_MIN_ELEVATION = 0.22;
static const float CLOUD_SCATTER_G = 0.55;

float planarHash(float3 p) {
    p = frac(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return frac((p.x + p.y) * p.z);
}
float planarNoise2(float2 p) {
    float2 i = floor(p), f = frac(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = planarHash(float3(i, 0.0));
    float b = planarHash(float3(i + float2(1.0, 0.0), 0.0));
    float c = planarHash(float3(i + float2(0.0, 1.0), 0.0));
    float d = planarHash(float3(i + float2(1.0, 1.0), 0.0));
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}
// One 3D tap at medium/high quality bends only fine edges, never the
// world-pinned coverage used to cast shadows.
float planarNoise3(float3 p) {
    float3 i = floor(p), f = frac(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    float a = lerp(planarHash(i), planarHash(i + float3(1,0,0)), u.x);
    float b = lerp(planarHash(i + float3(0,1,0)), planarHash(i + float3(1,1,0)), u.x);
    float c = lerp(planarHash(i + float3(0,0,1)), planarHash(i + float3(1,0,1)), u.x);
    float d = lerp(planarHash(i + float3(0,1,1)), planarHash(i + float3(1,1,1)), u.x);
    return lerp(lerp(a,b,u.y), lerp(c,d,u.y), u.z);
}
float cloudPlaneHeight(WorldPush push, int layer) {
    float rain = clamp(push.weather.x, 0.0, 1.0);
    return push.weatherColor.w + (layer == 0 ? CLOUD_LOW_OFFSET - rain * 10.0
                                                : CLOUD_HIGH_OFFSET + rain * 8.0);
}
float cloudCover(WorldPush push, int layer) {
    float rain = clamp(push.weather.x, 0.0, 1.0);
    float thunder = clamp(push.weather.y, 0.0, 1.0);
    float base = layer == 0 ? 0.24 + 0.56 * rain + 0.20 * thunder
                            : 0.16 + 0.18 * rain + 0.12 * thunder;
    return clamp(base * push.cloudAnchor.z, 0.0, 1.0);
}
float cloudDepth(WorldPush push, int layer) {
    float rain = clamp(push.weather.x, 0.0, 1.0);
    float thunder = clamp(push.weather.y, 0.0, 1.0);
    return layer == 0 ? 0.12 + 0.60 * rain + 0.28 * thunder
                      : 0.08 + 0.15 * rain + 0.08 * thunder;
}
float2 cloudCoordinates(WorldPush push, float2 worldXZ, int layer) {
    float time = push.weather.w * push.cloudAnchor.w;
    float2 wind = layer == 0 ? CLOUD_LOW_WIND : CLOUD_HIGH_WIND;
    float2 p = (worldXZ + push.cloudAnchor.xy)
             * (layer == 0 ? CLOUD_LOW_SCALE : CLOUD_HIGH_SCALE)
             + wind * time * (layer == 0 ? 1.0 : 1.55);
    // Cirrus is elongated across its dominant wind direction.
    return layer == 0 ? p : float2(p.x * 1.42 + p.y * 0.31, p.y * 0.47 - p.x * 0.08);
}
float cloudCoverageField(WorldPush push, float2 worldXZ, int layer) {
    return planarNoise2(cloudCoordinates(push, worldXZ, layer));
}
float cloudLayerDensity(WorldPush push, float2 worldXZ, int layer, int quality,
                        bool viewDetail, float3 origin, float3 dir, float distance) {
    float cover = cloudCover(push, layer);
    if (cover <= 0.0) return 0.0;
    float2 p = cloudCoordinates(push, worldXZ, layer);
    float body = planarNoise2(p);
    float threshold = 1.0 - cover;
    if (body < threshold - 0.13) return 0.0;
    float detail = 0.5, fine = 0.5;
    if (quality >= 1) {
        float2 detailXZ = worldXZ;
        if (viewDetail) {
            // Compress only the high-frequency detail toward the camera, keeping
            // the coverage and its shadow fixed in world space.
            float2 relative = worldXZ - push.camOffset.xz;
            detailXZ = push.camOffset.xz + relative / (1.0 + distance * CLOUD_DETAIL_COMPRESSION);
            float warpEnvelope = (1.0 - exp(-distance / 300.0)) / (1.0 + distance / 3500.0);
            float3 probe = float3((worldXZ + push.cloudAnchor.xy) * 0.008,
                                  distance * 0.0018 + push.weather.w * 0.01);
            detailXZ += dir.xz * ((planarNoise3(probe) - 0.5)
                                 * CLOUD_DETAIL_WARP * warpEnvelope);
        }
        float2 q = cloudCoordinates(push, detailXZ, layer);
        detail = planarNoise2(float2(q.x * 2.11 - q.y * 0.73,
                                      q.x * 0.73 + q.y * 2.11) + 17.3);
        if (quality >= 2) fine = planarNoise2(q * 4.17 - 9.7);
    }
    float humidity = clamp(push.weather.x * 0.7 + push.weather.y * 0.3, 0.0, 1.0);
    float shaped = body + (detail - 0.5) * (quality >= 1 ? 0.19 : 0.0)
                        + (fine - 0.5) * (quality >= 2 ? 0.07 : 0.0)
                        + humidity * 0.025;
    float mask = smoothstep(threshold - 0.07, threshold + 0.09, shaped);
    // A dark, uneven underside and an adjacent broad anvil hint at vertical
    // structure without sampling an actual volume.
    float tower = layer == 0 ? smoothstep(0.52, 0.79, body) : 0.0;
    float anvil = layer == 0 ? smoothstep(0.46, 0.70, body + (detail - 0.5) * 0.10) : 0.0;
    return clamp(mask * (layer == 0 ? 0.74 + 0.18 * tower + 0.08 * anvil
                                    : 0.52 + 0.32 * detail), 0.0, 1.0);
}
bool cloudPlaneHit(WorldPush push, float3 origin, float3 dir, float limit,
                   int layer, out float t, out float2 worldXZ) {
    t = 0.0;
    worldXZ = origin.xz;
    if (abs(dir.y) < 0.00001) return false;
    t = (cloudPlaneHeight(push, layer) - origin.y) / dir.y;
    if (t <= 0.0 || t >= min(limit, CLOUD_FAR)) return false;
    worldXZ = origin.xz + dir.xz * t;
    return true;
}
float cloudDistanceFade(float t) {
    if (t <= CLOUD_FADE_START) return 1.0;
    float x = clamp((CLOUD_FAR - t) / (CLOUD_FAR - CLOUD_FADE_START), 0.0, 1.0);
    return (1.0 - exp(-2.5 * x * x)) / (1.0 - exp(-2.5));
}
float cloudPhase(float mu) {
    float g = CLOUD_SCATTER_G;
    return (1.0 - g * g) / pow(max(1.0 + g * g - 2.0 * g * mu, 0.01), 1.5);
}
// No camera position, camera ray, or global local-cloud uniform is used here.
public float cloudSunTransmittance(WorldPush push, float3 worldPos, float3 lightDir) {
    // Surface NEE jitters lightDir for geometric soft shadows. Cloud coverage uses
    // the canonical light direction so a stationary cloud shadow never flickers.
    float3 stableDir = push.lightDir.xyz;
    if ((push.flags & (1u << 9u)) == 0u || stableDir.y <= 0.00001) return 1.0;
    int layers = clamp(int(push.cloudTuning.x), 1, 2);
    int quality = int((push.flags >> 10u) & 3u);
    float strength = float((push.flags >> 24u) & 255u) * 0.01;
    float opticalDepth = 0.0;
    for (int layer = 0; layer < layers; ++layer) {
        float t; float2 xz;
        if (!cloudPlaneHit(push, worldPos, stableDir, CLOUD_FAR, layer, t, xz)) continue;
        float density = cloudLayerDensity(push, xz, layer, quality, false,
                                          worldPos, stableDir, t);
        opticalDepth += CLOUD_EXTINCTION * cloudDepth(push, layer) * density
                      * strength / max(stableDir.y, 0.22);
    }
    return exp(-opticalDepth);
}
public VolumeCloudResult integrateVolumetricCloud(WorldPush push, float3 origin,
                                                   float3 dir, float limit, float weatherSky) {
    VolumeCloudResult result;
    result.transmittance = 1.0;
    result.radiance = float3(0.0, 0.0, 0.0);
    if ((push.flags & (1u << 9u)) == 0u) return result;
    int layers = clamp(int(push.cloudTuning.x), 1, 2);
    int quality = int((push.flags >> 10u) & 3u);
    float strength = float((push.flags >> 24u) & 255u) * 0.01;
    float sunPhase = cloudPhase(dot(dir, push.lightDir.xyz));
    // 0: one coverage tap/layer, no lighting probes.
    // 1: +detail and two sun/sky probes. 2: +fine detail and three or
    // four sun/sky probes, bounded by the existing sample-budget field.
    int probes = quality == 0 ? 0 : (quality == 1 ? 2
                 : (push.cloudTuning.y >= 48.0 ? 4 : 3));
    for (int order = 0; order < layers; ++order) {
        int layer = dir.y < 0.0 ? layers - 1 - order : order;
        float t; float2 xz;
        if (!cloudPlaneHit(push, origin, dir, limit, layer, t, xz)) continue;
        float density = cloudLayerDensity(push, xz, layer, quality, true, origin, dir, t);
        if (density <= 0.0) continue;
        float elevation = CLOUD_MIN_ELEVATION
                        + (1.0 - CLOUD_MIN_ELEVATION)
                        * smoothstep(0.0, 0.14, abs(dir.y));
        float opticalDepth = CLOUD_EXTINCTION * cloudDepth(push, layer)
                           * density * strength * elevation;
        float opacity = (1.0 - exp(-opticalDepth)) * cloudDistanceFade(t);
        float sunFlux = 1.0, skyFlux = 1.0;
        if (layer == 0 && probes > 0) {
            float2 sunStep = push.lightDir.xz * (26.0 / max(push.lightDir.y, 0.22));
            for (int i = 1; i <= probes; ++i) {
                float sunCover = cloudCoverageField(push, xz + sunStep * float(i), layer);
                float skyCover = cloudCoverageField(push, xz + float2(-17.0, 23.0) * float(i), layer);
                sunFlux *= exp(-0.28 * smoothstep(1.0 - cloudCover(push, layer),
                                                  1.10 - cloudCover(push, layer), sunCover));
                skyFlux *= exp(-0.12 * smoothstep(1.0 - cloudCover(push, layer),
                                                  1.10 - cloudCover(push, layer), skyCover));
            }
        }
        float underside = dir.y > 0.0 ? 0.66 : 1.05;
        float silver = smoothstep(0.10, 0.45, density)
                     * (1.0 - smoothstep(0.45, 0.88, density));
        float sunset = 1.0 + 0.65 * clamp(push.sunDir.w, 0.0, 1.0)
                     * (1.0 - smoothstep(0.05, 0.35, abs(push.sunDir.y)));
        float3 ambient = push.weatherColor.xyz * (0.16 + 0.22 * weatherSky)
                       * skyFlux * underside;
        float3 direct = push.lightRadiance.xyz * 0.012 * sunPhase
                      * sunFlux * (0.52 + silver * 0.44 * sunset);
        result.radiance += result.transmittance * opacity * (ambient + direct);
        result.transmittance *= 1.0 - opacity;
    }
    return result;
}
