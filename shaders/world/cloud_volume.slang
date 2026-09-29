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
// Vertical structure. A single height per layer made the deck read as painted paper: one plane
// intersection and one 2D mask, with no way for the top and bottom of a cloud to differ. Each layer
// is now a short stack of horizontal slices taken through a 3D noise field, so the slices have
// parallax against each other and each carries its own outline. This stays a handful of analytic
// plane intersections, not a raymarch.
static const float CLOUD_LOW_THICKNESS = 46.0;
static const float CLOUD_HIGH_THICKNESS = 18.0;
static const float CLOUD_VERTICAL_SCALE = 0.052;
// Minimum optical-thickness factor at grazing view angles. This used to be 0.22, which is what kept
// the deck looking thin: most of the time the camera looks near-horizontally, so the sheet was being
// attenuated to a fifth of its opacity exactly where it fills the screen. Raising it also makes the
// horizon band denser, which is what a real cloud deck does.
static const float CLOUD_MIN_ELEVATION = 0.50;
static const float CLOUD_SCATTER_G = 0.55;
// Vertical optical depth of the deck as seen by the ground shadow. This is deliberately independent of
// the depth that drives visual opacity: a deck looks solid at od ~ 1.6, but a real convected deck has
// an optical depth of 10-50, which is why overcast casts no discernible shadows. Keeping them separate
// matters because the sun's radiance is ~21 here, so even 9% of it outshines the ambient term by an
// order of magnitude and leaves object shadows crisp — the exact thing that reads as "no cloud shadow".
static const float CLOUD_SHADOW_OPTICAL_DEPTH = 12.0;

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
    // Clear weather still needs a populated sky: the previous cover left the sheets around 20%
    // opaque, which reads as haze rather than cloud. Rain now approaches full overcast.
    float base = layer == 0 ? 0.50 + 0.46 * rain + 0.16 * thunder
                            : 0.32 + 0.26 * rain + 0.14 * thunder;
    return clamp(base * push.cloudAnchor.z, 0.0, 1.0);
}
float cloudDepth(WorldPush push, int layer) {
    float rain = clamp(push.weather.x, 0.0, 1.0);
    float thunder = clamp(push.weather.y, 0.0, 1.0);
    // This is the thickness that feeds opacity directly. At 0.12 (the old clear-weather value) a
    // 0.74-density sample came out at ~0.20 opacity, i.e. a sky you could see straight through.
    return layer == 0 ? 0.60 + 0.38 * rain + 0.22 * thunder
                      : 0.34 + 0.26 * rain + 0.14 * thunder;
}
// Vertical extent of the deck in blocks. Convective weather builds the low deck upwards; cirrus stays
// a thin sheet.
float cloudLayerThickness(WorldPush push, int layer) {
    float rain = clamp(push.weather.x, 0.0, 1.0);
    float thunder = clamp(push.weather.y, 0.0, 1.0);
    float growth = 1.0 + 0.55 * rain + 0.55 * thunder;
    return (layer == 0 ? CLOUD_LOW_THICKNESS : CLOUD_HIGH_THICKNESS) * growth;
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
// `heightOffset` selects the slice through the deck. The coarse shape stays on the 2D field so the
// ground shadow — which samples one representative height — keeps lining up with the clouds you can
// see; the detail octaves move with height, which is what gives the stack its depth.
float cloudLayerDensity(WorldPush push, float2 worldXZ, float heightOffset, int layer, int quality,
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
        // Third dimension is height, so slices at different altitudes get different outlines.
        float3 v = float3(q, heightOffset * CLOUD_VERTICAL_SCALE);
        detail = planarNoise3(float3(v.x * 2.11 - v.y * 0.73,
                                     v.x * 0.73 + v.y * 2.11,
                                     v.z) + 17.3);
        if (quality >= 2) fine = planarNoise3(v * 4.17 - 9.7);
    }
    float humidity = clamp(push.weather.x * 0.7 + push.weather.y * 0.3, 0.0, 1.0);
    float shaped = body + (detail - 0.5) * (quality >= 1 ? 0.30 : 0.0)
                        + (fine - 0.5) * (quality >= 2 ? 0.09 : 0.0)
                        + humidity * 0.025;
    float mask = smoothstep(threshold - 0.07, threshold + 0.09, shaped);
    // A dark, uneven underside and an adjacent broad anvil hint at vertical
    // structure without sampling an actual volume.
    float tower = layer == 0 ? smoothstep(0.52, 0.79, body) : 0.0;
    float anvil = layer == 0 ? smoothstep(0.46, 0.70, body + (detail - 0.5) * 0.10) : 0.0;
    return clamp(mask * (layer == 0 ? 0.74 + 0.18 * tower + 0.08 * anvil
                                    : 0.52 + 0.32 * detail), 0.0, 1.0);
}
// Ray/slab intersection for the deck's vertical extent. Marching is parameterised by distance along
// the ray rather than by height: with a fixed *height* spacing the steps fan apart as the view
// approaches horizontal (each step's t scales by 1/dir.y), which is exactly the horizontal banding
// visible at range. Equal *distance* steps keep the on-screen sampling density even at every angle.
bool cloudSlabIntersect(float3 origin, float3 dir, float baseHeight, float thickness, float limit,
                        out float enterT, out float exitT) {
    enterT = 0.0;
    exitT = 0.0;
    if (abs(dir.y) < 1.0e-5) return false;
    float bottom = (baseHeight - origin.y) / dir.y;
    float top = (baseHeight + thickness - origin.y) / dir.y;
    float near = max(min(bottom, top), 0.0);
    float far = min(max(bottom, top), min(limit, CLOUD_FAR));
    if (far <= near) return false;
    enterT = near;
    exitT = far;
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
        // Intersect the layer's mid-plane rather than its base. The visible deck is a slab, so the
        // midpoint is what the shadow should correspond to; sampling the base plane instead also makes
        // the shadow slide whenever the weather-driven deck height moves, which reads as stepping.
        float midOffset = cloudLayerThickness(push, layer) * 0.5;
        if (abs(stableDir.y) < 1.0e-5) continue;
        float t = (cloudPlaneHeight(push, layer) + midOffset - worldPos.y) / stableDir.y;
        if (t <= 0.0 || t >= CLOUD_FAR) continue;
        float2 xz = worldPos.xz + stableDir.xz * t;
        float density = cloudLayerDensity(push, xz, midOffset, layer, quality, false,
                                          worldPos, stableDir, t);
        // The 1/sin(sun) path stretch is floored well above the true grazing value: with the thicker
        // decks above, a nearly-horizontal sun would take clear-weather ground light below 10%, which
        // reads as the world switching off at sunset rather than as cloud shading.
        opticalDepth += CLOUD_SHADOW_OPTICAL_DEPTH
                      * cloudDepth(push, layer) * density
                      * strength / max(stableDir.y, 0.35);
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
    // Steps per deck: the vertical-resolution knob. Few steps plus a jittered start is the standard
    // cheap volumetric recipe (Toft et al. 2016 report comparable results at ~1/16 the steps) — the
    // residual noise is what the temporal filter downstream is for. Rides the existing quality budget
    // rather than adding a setting.
    int steps = quality == 0 ? 4 : (push.cloudTuning.y >= 40.0 ? 10
              : (push.cloudTuning.y >= 20.0 ? 8 : 6));
    bool belowDeck = dir.y < 0.0;
    // Per-ray and per-frame start offset. Both axes are needed: a per-frame-only offset would leave
    // every pixel marching in lockstep (banding no filter can remove), and a per-ray-only offset would
    // freeze the banding in place instead of letting time average it away.
    float3 jitterSeed = float3(dir.x * 977.0, dir.y * 977.0 + dir.z * 131.0,
                               float(push.frameIndex & 1023u) * 0.6180340);
    float jitterBase = planarHash(jitterSeed);
    for (int order = 0; order < layers; ++order) {
        int layer = belowDeck ? layers - 1 - order : order;
        float baseHeight = cloudPlaneHeight(push, layer);
        float thickness = cloudLayerThickness(push, layer);
        float enterT, exitT;
        if (!cloudSlabIntersect(origin, dir, baseHeight, thickness, limit, enterT, exitT)) continue;
        // Cirrus is a thin sheet and does not need the cumulus deck's step count.
        int count = layer == 0 ? steps : max(2, steps - 2);
        // Split the deck's optical depth across the steps: N steps of depth/N transmit the same total
        // as one of depth, so density stays a per-step property and the silhouette softens instead of
        // changing brightness.
        float stepDepth = cloudDepth(push, layer) / float(count);
        // Sun/sky occlusion is a property of the deck above this point, not of one step, so it is
        // evaluated once per layer at the march midpoint and reused by every step in it.
        float sunFlux = 1.0, skyFlux = 1.0;
        if (layer == 0 && probes > 0) {
            float2 midXZ = origin.xz + dir.xz * ((enterT + exitT) * 0.5);
            float2 sunStep = push.lightDir.xz * (26.0 / max(push.lightDir.y, 0.22));
            for (int i = 1; i <= probes; ++i) {
                float sunCover = cloudCoverageField(push, midXZ + sunStep * float(i), layer);
                float skyCover = cloudCoverageField(push, midXZ + float2(-17.0, 23.0) * float(i), layer);
                sunFlux *= exp(-0.45 * smoothstep(1.0 - cloudCover(push, layer),
                                                  1.10 - cloudCover(push, layer), sunCover));
                skyFlux *= exp(-0.12 * smoothstep(1.0 - cloudCover(push, layer),
                                                  1.10 - cloudCover(push, layer), skyCover));
            }
        }
        // Decorrelate the two decks' offsets so their banding patterns never line up.
        float jitter = frac(jitterBase + float(order) * 0.7548776662);
        float span = exitT - enterT;
        for (int s = 0; s < count; ++s) {
            float t = enterT + ((float(s) + jitter) / float(count)) * span;
            float3 samplePos = origin + dir * t;
            float heightOffset = samplePos.y - baseHeight;
            float density = cloudLayerDensity(push, samplePos.xz, heightOffset, layer,
                                              quality, true, origin, dir, t);
            if (density <= 0.0) continue;
            // Light grazing trim only. The march already lengthens the path toward the horizon, so
            // this merely takes the edge off the densest band instead of (as the old fixed floor did)
            // erasing the deck exactly where it fills the screen.
            float grazing = lerp(0.85, 1.0, smoothstep(0.0, 0.10, abs(dir.y)));
            float opticalDepth = CLOUD_EXTINCTION * stepDepth * density * strength * grazing;
            float opacity = (1.0 - exp(-opticalDepth)) * cloudDistanceFade(t);
            // Looking up at the deck sees its underside, which is in its own shadow and much darker
            // than the sky it hides. That matters far beyond looks: every ambient ray a ground point
            // casts ends here, so this factor is what actually dims the world under a cloud — the
            // direct-light shadow alone leaves the overall brightness almost unchanged.
            float underside = dir.y > 0.0 ? 0.40 : 1.05;
            float silver = smoothstep(0.10, 0.45, density)
                         * (1.0 - smoothstep(0.45, 0.88, density));
            float sunset = 1.0 + 0.65 * clamp(push.sunDir.w, 0.0, 1.0)
                         * (1.0 - smoothstep(0.05, 0.35, abs(push.sunDir.y)));
            // Overcast also has to *dim*, not just whiten. Cloud albedo sends most of the sunlight back
            // out to space, and a ground point only ever sees the deck's underside: measured zenith
            // radiance for an overcast deck is roughly a third of a clear sky. weatherColor comes from
            // the rain/thunder blend in Java and knows nothing about cloud cover, so the cover term has
            // to be applied here, or the aggregate radiance a ground point receives stays near its
            // clear-sky value and the world never dims under full cover however opaque the deck looks.
            // Rain and thunder dim the deck further, thunder heaviest, so the three weathers read as
            // three brightness levels instead of one. Driven by rain/thunder rather than cover because
            // cover saturates: a rainstorm and a thunderstorm both reach full cover, so it cannot tell
            // them apart.
            float gloom = clamp(push.weather.x * 0.40 + push.weather.y * 0.35, 0.0, 1.0);
            float overcast = (1.0 - 0.60 * cloudCover(push, layer)) * (1.0 - gloom);
            float3 ambient = push.weatherColor.xyz * (0.50 + 0.45 * weatherSky)
                           * skyFlux * underside * overcast;
            float3 direct = push.lightRadiance.xyz * 0.030 * sunPhase
                          * sunFlux * (0.55 + silver * 0.60 * sunset);
            result.radiance += result.transmittance * opacity * (ambient + direct);
            result.transmittance *= 1.0 - opacity;
        }
    }
    return result;
}
