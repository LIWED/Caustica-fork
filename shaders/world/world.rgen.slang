// Perspective path tracer. invViewProj = inverse(proj * viewRot) maps clip to camera-relative world.
// Primary rays are reconstructed from two unprojected points (near and far plane) rather than assuming
// the eye is at the origin: Minecraft bakes view bobbing into the projection, so the effective eye comes
// from the matrix. camOffset shifts camera-relative space into the terrain's rebased coordinates. Depth
// is reversed-Z (near=1, far=0).
//
// Lighting is an iterative path-tracing loop in raygen, not recursion from closest-hit, so
// maxRayRecursionDepth stays 1. At each surface vertex:
//   * NEE toward the sun — a single analytic directional light, gated by one hit-object visibility query
//     (TerminateOnFirstHit | SkipClosestHit). Lambertian BRDF = albedo/PI.
//   * a cosine-weighted Lambertian continuation ray (throughput *= albedo; the PI and cos cancel).
// Sky / ambient light needs no separate AO pass: continuation rays that escape land in world.rmiss,
// which returns sky radiance — so soft sky fill and contact AO both fall out of the path integral.
// Russian roulette terminates deep paths. Output is HDR (R16G16B16A16_SFLOAT); the HDR -> LDR tonemap
// happens later at the display.comp seam.
//
// SER: the build emits EXT and NV shader-invocation-reorder variants from this source.
//
// Each frame emits a single SPP-averaged (still noisy) estimate; temporal convergence is the denoiser's
// job. With RR disabled the output is the raw noisy path trace — a reference view, not a converged image.
import world_common;
import celestial;
import surface_energy;
import indirect_regularization;
import water_celestial;
import interface_celestial;
import path_probe;

[[vk::push_constant]] PushAddr pcAddr;

[[vk::binding(0, 0)]] RaytracingAccelerationStructure topLevelAS;
// HDR trace target: linear radiance, may exceed 1. Tonemap happens later at the display.comp seam.
#ifdef CAUSTICA_OFFLINE_FP32
[[vk::binding(1, 0)]] [format("rgba32f")] RWTexture2D<float4> outImage;
#else
[[vk::binding(1, 0)]] [format("rgba16f")] RWTexture2D<float4> outImage;
#endif
[[vk::binding(2, 0)]] Sampler2D blockAtlas;
[[vk::binding(9, 0)]] Sampler2D blockSpecAtlas;
// Guide buffers — first-hit (primary-visibility) attributes consumed by the denoiser/DLSS-RR. Written
// every frame regardless of accumulation. gNormal.w carries roughness; gDepth carries HW reversed-Z depth.
[[vk::binding(3, 0)]] [format("rgba16f")] RWTexture2D<float4> gNormal;     // xyz world normal, w roughness
[[vk::binding(4, 0)]] [format("rgba16f")] RWTexture2D<float4> gAlbedo;     // rgb diffuse albedo
[[vk::binding(5, 0)]] [format("r32f")]    RWTexture2D<float>  gDepth;      // HW reversed-Z depth
[[vk::binding(6, 0)]] [format("rg16f")]   RWTexture2D<float2> gMotion;     // screen-space motion (render px)
[[vk::binding(7, 0)]] [format("rgba16f")] RWTexture2D<float4> gSpecAlbedo; // specular albedo (0 — diffuse-only)
[[vk::binding(8, 0)]] [format("rg16f")]   RWTexture2D<float2> gSpecMotion; // reflection MVs for RR

// Per-frame push data loaded once from the BDA buffer at the top of main() (same pattern as the GLSL
// `pc` global). Layout constants generated from this module's SPIR-V — see world_common.WorldPush.
static WorldPush pc;

// Ray payloads. Module-level statics so the helper functions (visibility / transmissionGuideHit /
// specularReflectionMotion / tracePath) can share them, mirroring the GLSL rayPayloadEXT globals.
static Payload payload;
static float4 shadowVis; // rgb = transmittance; a = nearest water-crossing t (-1 = none)

// First-hit (primary-visibility) guide attributes, captured at bounce 0 of tracePath. Realtime uses
// frame jitter; offline reconstructs an independent R2-jittered primary ray for every SPP. Offline
// display denoising consumes the final SPP's guides (not accumulated/noise-free guide averages).
static float3 gv_normal;
static float3 gv_albedo;
static float3 gv_specAlb; // specular albedo fed to DLSS-RR for specular demodulation (0 = pure diffuse).
// First-interface ownership for reflection motion. Glass/water keep this true even when their
// transmitted endpoint has no specular albedo or the bounded transmission guide falls back.
static bool gv_reflectionMotionValid;
static float gv_rough;
// Linear VIEW-SPACE depth guide inputs; sky resolves to a large far value (no negative sentinel).
static float gv_depth;
static float3 gv_hitCamRel;       // primary-surface hit position relative to the current camera
static float3 gv_motionHitCamRel; // motion-guide hit position; water tracks the refracted hit instead
static bool gv_motionUseRefracted; // true when the MV tracks the refracted hit (its own reprojection delta)
// World-space displacement of the motion-guide surface since the previous frame (0 for static
// terrain/sky, an entity's per-vertex/object motion for a dynamic hit).
static float3 gv_motionObjDisp;

static const uint PAYLOAD_MATERIAL_MASK = 3u;

static const uint MATERIAL_OPAQUE = 0u;
static const uint MATERIAL_WATER = 1u;
static const uint MATERIAL_PARTICLE = 2u;
static const uint MATERIAL_GLASS = 3u;

uint payloadMaterial() { return payload.flags & PAYLOAD_MATERIAL_MASK; }
// Set by world.rchit only on a MATERIAL_WATER hit (see PAYLOAD_WATER_ENTERING) — whether the ray was
// travelling into the water volume (vs. out of it) at this hit's face.
bool payloadWaterEntering() { return (payload.flags & PAYLOAD_WATER_ENTERING) != 0u; }
float payloadRoughness() { return unpackHalf2(payload.roughMetal).x; }
float payloadMetalness() { return unpackHalf2(payload.roughMetal).y; }
float payloadEmission() { return unpackHalf2(payload.emissionSss).x; }
float payloadSss() { return unpackHalf2(payload.emissionSss).y; }
uint payloadStaticLightIndex() { return payload.staticLightIndex; }
uint payloadSectionSlot() { return payload.sectionSlot; }
void payloadSetTraceState(bool showCelestial, float rayConeWidth, float rayConeSpread) {
    payload.flags = showCelestial ? PAYLOAD_SHOW_CELESTIAL : 0u;
#ifdef CAUSTICA_OFFLINE_FP32
    // A fixed glass texture footprint keeps NEE and continuation tint identical
    // even when their sampled lobes carry different ray cones.
    payload.flags |= PAYLOAD_OFFLINE_GLASS_LOD0;
#endif
    payload.rayCone = packHalf2(float2(rayConeWidth, rayConeSpread));
    payload.sectionSlot = 0xFFFFFFFFu;
}

static const float PI = 3.14159265359;
static const float INV_PI = 0.31830988618;

// The analytic sky (gradient + sun/moon discs + stars) is computed in world.rmiss. On a miss, raygen
// reads payload.albedo and accumulates that sky radiance. The directional NEE light is pushed separately
// as pc.lightDir / pc.lightRadiance / pc.sunDir.
static const float EMISSIVE_STRENGTH = 3.0; // HDR radiance of a full (level-15) emitter, modulated by albedo
static const float SURF_BIAS = 0.005;  // offset secondary-ray origins along the normal (anti-acne)
static const float RAY_TMIN = 0.001;   // tiny tmin: the normal offset already clears the surface

// Water is a smooth dielectric. IOR 1.333; absorption is per-block Beer-Lambert extinction.
static const float WATER_IOR = 1.333;
static const float WATER_GUIDE_ROUGH = 0.02;
static const float3 SKY_SPEC_ALBEDO = float3(0.5, 0.5, 0.5); // RR guide default for sky pixels.
static const float3 SKY_DIFF_ALBEDO = float3(0.5, 0.5, 0.5);

// Stained glass / ice (material 3): a thin colored dielectric. IOR ~1.5 (soda-lime glass).
static const float GLASS_IOR = 1.52;
static const float GLASS_GUIDE_ROUGH = 0.04;
// Transmitted-ray origin offset when crossing a glass face. Must be SMALLER than the terrain-side
// TRANSLUCENT_INSET (RtTerrain, 2e-4 blocks): glass is recessed into its block by that inset, so a face
        // touching a slab/stair leaves a tiny gap before the neighbour's surface. A large bias (SURF_BIAS) would
// restart the ray past that neighbour and see through it; this lands the ray inside the gap so the
// neighbour is still hit, while still clearing the glass surface to avoid self-intersection.
static const float GLASS_TRANSMIT_BIAS = 1.0e-4;
static const int MAX_TRANSMISSION_GUIDE_INTERFACES = 4;

// Ray-cone texture LOD: raygen tracks a one-pixel footprint along the path, and closest-hit converts it
// to texture mip levels from the local UV/world-space scale. Diffuse/glossy bounces widen the cone so
// indirect texture fetches don't keep sampling mip 0 through broad lobes.
static const float RAY_CONE_MIN_SPREAD = 1.0e-5;
static const float RAY_CONE_MIN_WIDTH = 1.0e-5;
static const float RAY_CONE_DIFFUSE_SPREAD = 0.25;
static const float RAY_CONE_GLOSSY_SPREAD_SCALE = 0.35;

// Per-channel Beer–Lambert extinction from a water body's biome tint (carried in payload.albedo for
// water hits, or pc.waterParams.xyz for the camera's own biome when starting submerged). A blue ocean
// tint (low red) absorbs red fastest → bluer with depth; swamp green-brown shifts the hue. The floor
// keeps even a white-tinted body very slightly absorbing so deep water never reads as clear vacuum.
static const float WATER_DENSITY = 0.05;
static const float3 WATER_ABSORB_FLOOR = float3(0.015, 0.010, 0.008);
float3 waterExtinction(float3 tint) {
    return WATER_ABSORB_FLOOR + WATER_DENSITY * (float3(1.0, 1.0, 1.0) - clamp(tint, 0.0, 1.0));
}

// Animated surface waves — a directional wave spectrum, gradient-only (the surface stays geometrically
// flat; only the normal tilts). Three things make it read as water rather than animated glass:
//  * Sharp-crested profile: each component is h = a·exp(S·(sin φ − 1)) — peaked crests, wide flat
//    troughs (pure sines look like rolling jelly). Still C∞ smooth with an exact analytic gradient.
//  * Real deep-water dispersion ω = √(g·k): long swell strides past (λ=14 m → ~4.7 m/s) while short
//    chop flutters nearly in place — wrong relative speeds are the biggest tell of fake water.
//  * Wind + meander: headings spread around a fixed wind direction (tight for the swell, wide for the
//    chop), and the largest components' phase is modulated along their crest (chain-ruled into the
//    gradient) so wavefronts wander instead of ruling straight periodic lines across the sea.
// The domain is world-anchored (see applyWaterWaves) so the pattern is pinned in world space, and the
// caustics (waterCaustic) differentiate this same field, so they stay in sync with the visible ripples.
static const float WATER_WAVE_STRENGTH = 0.3;  // slope scale (higher = choppier glints / more broken reflections)
static const float WAVE_SPEED = 0.8;           // global time scale; dispersion keeps relative speeds physical
static const int   WAVE_COUNT = 10;            // λ = 14 m … 0.38 m (each octave 1.5× shorter)
static const float WAVE_G = 9.81;
static const float2 WAVE_WIND = normalize(float2(1.0, 0.35)); // dominant travel direction
static const float WAVE_MEANDER = 1.1;         // crest phase-wobble amplitude (rad) on the long components
float2 waterWaveGrad(float2 p, float t) {
    // Per-wave steepness a·k: gentle in the long swell, concentrated in the mid/short chop.
    const float Q[WAVE_COUNT] = { 0.030, 0.035, 0.042, 0.050, 0.060, 0.065, 0.065, 0.058, 0.048, 0.038 };
    t *= WAVE_SPEED;
    float2 g = float2(0.0, 0.0);
    float lambda = 14.0;
    for (int i = 0; i < WAVE_COUNT; i++) {
        float k = 2.0 * PI / lambda;
        float w = sqrt(WAVE_G * k);   // deep-water dispersion: phase speed √(g/k)
        // Heading: deterministic irregular spread about the wind, widening down the spectrum.
        float spread = (0.15 + 0.11 * float(i)) * sin(float(i) * 2.4 + 1.3);
        float cs = cos(spread), sn = sin(spread);
        float2 d = float2(WAVE_WIND.x * cs - WAVE_WIND.y * sn, WAVE_WIND.x * sn + WAVE_WIND.y * cs);
        float ph = k * dot(d, p) - w * t + 1.7 * float(i) * float(i);
        float2 dph = k * d;
        if (i < 4) { // meander only the components whose fronts are long enough to read as lines
            float2 pd = float2(-d.y, d.x);
            float wph = 0.4 * k * dot(pd, p) + 0.5 * w * t;
            ph += WAVE_MEANDER * sin(wph);
            dph += (WAVE_MEANDER * cos(wph) * 0.4 * k) * pd;
        }
        float S = 1.2 + 0.12 * float(i); // crest sharpness: the short chop is choppier
        float e = exp(S * (sin(ph) - 1.0));
        g += (Q[i] / k) * (S * cos(ph) * e) * dph; // a = Q/k; ∇h = a·S·cos φ·e^{S(sin φ−1)}·∇φ
        lambda /= 1.5;
    }
    return g * WATER_WAVE_STRENGTH;
}

// Perturb a (near-)horizontal water surface normal by the wave field. Flowing side faces (|n.y| small)
// keep their flat geometric normal. `worldXZ` must be a world-stable coordinate (rebased hit + the pushed
// anchor) so the ripples stay pinned in the world. `nGeo` is already oriented toward the viewer, so the
// down-viewed underside (n.y < 0) takes the mirrored slope (-up).
float3 applyWaterWaves(float3 nGeo, float2 worldXZ, float t) {
    if (abs(nGeo.y) < 0.5) return nGeo;
    float2 grad = waterWaveGrad(worldXZ, t);
    float3 up = normalize(float3(-grad.x, 1.0, -grad.y));
    return nGeo.y >= 0.0 ? up : -up;
}

// ---- Water caustics. Sunlight refracting through the waved surface converges/diverges before it
// reaches an underwater receiver; the analytic wave field makes the true focusing factor computable
// instead of faked with a scrolling texture. Where the shadow ray of an underwater NEE vertex crossed
// water (recorded by world.rahit in shadowVis.a), evaluate the horizontal landing position of the
// refracted sun ray as a function of surface position and finite-difference it: the caustic intensity is
// the inverse Jacobian determinant of that surface→floor mapping (area compression = brightening, real
// fold caustics where det → 0). Because this uses the SAME wave field as the visible surface normals,
// the caustic pattern stays in sync with the ripples, and the per-sample sun-quad jitter (sampleSquare)
// shifts the pattern per sample → caustics physically blur with depth under DLSS-RR accumulation.
static const float CAUSTIC_EPS = 0.25; // finite-difference step (m); also low-passes sub-step wave detail
static const float CAUSTIC_MAX = 6.0;  // focusing clamp: keeps fold-line singularities from becoming fireflies

// Horizontal landing offset of a refracted sun ray entering the surface at world-stable xz, intersected
// with the receiver plane h metres below. inc = sunlight travel direction (downward, unit).
float2 causticLanding(float2 xz, float t, float3 inc, float h) {
    float2 g = waterWaveGrad(xz, t);
    float3 nw = normalize(float3(-g.x, 1.0, -g.y));
    float3 rdw = refract(inc, nw, 1.0 / WATER_IOR); // air→water: never TIR
    return xz + rdw.xz * (h / max(-rdw.y, 0.05));
}

float waterCaustic(float3 exitPos, float3 lightDir, float waterDist) {
    // Grazing light: the receiver-plane intersection degenerates and caustics vanish in reality anyway
    // (long slant paths absorb + the pattern smears out) — fade the effect to neutral 1.0.
    float fade = smoothstep(0.06, 0.18, lightDir.y);
    if (fade <= 0.0) return 1.0;
    float h = max(waterDist * lightDir.y, 0.05); // vertical depth of the receiver below the exit point
    float t = pc.waterParams.w;
    float3 inc = -lightDir;
    float2 base = exitPos.xz + pc.waterAnchor.xy;  // world-stable wave domain (same as applyWaterWaves)
    float2 p0 = causticLanding(base, t, inc, h);
    float2 px = causticLanding(base + float2(CAUSTIC_EPS, 0.0), t, inc, h);
    float2 pz = causticLanding(base + float2(0.0, CAUSTIC_EPS), t, inc, h);
    float det = abs((px.x - p0.x) * (pz.y - p0.y) - (px.y - p0.y) * (pz.x - p0.x));
    // Flat water ⇒ all landings displace identically ⇒ det = eps² ⇒ focus = 1 (energy-neutral); the
    // clamp bounds the fold-line spikes whose energy the surrounding darkening already paid for.
    float focus = (CAUSTIC_EPS * CAUSTIC_EPS) / max(det, 1.0e-5);
    return lerp(1.0, min(focus, CAUSTIC_MAX), fade);
}

// GGX BRDF. Roughness is clamped away from 0 so the delta sun's specular highlight stays finite
// and the VNDF sample is well-conditioned. alpha = roughness^2 (perceptual -> GGX) throughout.
static const float MIN_ROUGH = 0.045;

float luminance(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

// GGX normal distribution, matched to sampleGGXVNDF. All callers use rough >= MIN_ROUGH.
float ggxD(float ndh, float rough) {
    ndh = clamp(ndh, 0.0, 1.0);
    float a = rough * rough;
    float a2 = a * a;
    // Avoid cancellation near the peak without changing the distribution with an epsilon floor.
    float d = (1.0 - ndh) * (1.0 + ndh) + ndh * ndh * a2;
    return a2 / (PI * d * d);
}

// Smith GGX masking term for one direction (separable form; G2 = G1(v) * G1(l)).
float ggxG1(float ndx, float rough) {
    ndx = clamp(ndx, 0.0, 1.0);
    float a = rough * rough;
    float a2 = a * a;
    // Positive roughness keeps the denominator positive, including at grazing incidence.
    return 2.0 * ndx / (ndx + sqrt(a2 + (1.0 - a2) * ndx * ndx));
}

float3 fresnelSchlick(float cosT, float3 f0) {
    float m = clamp(1.0 - cosT, 0.0, 1.0);
    float m2 = m * m;
    return f0 + (1.0 - f0) * (m2 * m2 * m);
}

// Henyey–Greenstein phase function (with 4π normalisation so it integrates to 1 over the sphere).
// g=0 → isotropic; g>0 → forward-scatter peak at cosT=1 (light and view aligned through a thin slab).
static const float SSS_G        = 0.6; // forward-scatter anisotropy; leaves/grass are quite directional
static const float SSS_STRENGTH = 1.0; // 1.0 ≈ 2.5× the Lambertian at peak (sss=1, cosT=1, backNdl=1)
static const int   MAX_SSS_BOUNCE = 1; // fire the transmission shadow ray on primary + first indirect hit only
float hg(float cosT, float g) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * PI * pow(max(0.0, 1.0 + g2 - 2.0 * g * cosT), 1.5));
}

// NVIDIA RR guide-buffer helper: integrated/view-dependent specular reflectivity, not raw F0.
// alpha is GGX alpha (perceptual roughness squared), NoV is the first-hit view cosine.
float3 rrSpecularAlbedo(float3 specularColor, float alpha, float NoV) {
    NoV = abs(NoV);
    float NoV2 = NoV * NoV;
    float alpha2 = alpha * alpha;
    float4 X = float4(1.0, NoV, NoV2, NoV * NoV2);
    float4 Y = float4(1.0, alpha, alpha2, alpha * alpha2);

    float2 m1 = float2(
            dot(float2(0.99044, -1.28514), X.xy),
            dot(float2(1.29678, -0.755907), X.xy));
    float3 Xxyw = float3(X.x, X.y, X.w);
    float3 m2 = float3(
            dot(float3(1.0, 2.92338, 59.4188), Xxyw),
            dot(float3(20.3225, -27.0302, 222.592), Xxyw),
            dot(float3(121.563, 626.13, 316.627), Xxyw));
    float bias = dot(m1, Y.xy) / max(dot(m2, float3(Y.x, Y.y, Y.w)), 1.0e-7);

    float2 m3 = float2(
            dot(float2(0.0365463, 3.32707), X.xy),
            dot(float2(9.0632, -9.04756), X.xy));
    float3 Xxzw = float3(X.x, X.z, X.w);
    float3 m4 = float3(
            dot(float3(1.0, 3.59685, -1.36772), Xxzw),
            dot(float3(9.04401, -16.3174, 9.22949), Xxzw),
            dot(float3(5.56589, 19.7886, -20.2123), Xxzw));
    float scale = dot(m3, Y.xy) / max(dot(m4, float3(Y.x, Y.y, Y.w)), 1.0e-7);

    bias *= clamp(specularColor.g * 50.0, 0.0, 1.0);
    return specularColor * max(0.0, scale) + float3(max(0.0, bias), max(0.0, bias), max(0.0, bias));
}

// Exact (unpolarized) Fresnel reflectance for a dielectric interface. cosI is the incidence cosine on
// the incoming side; etaI/etaT are the IORs the ray travels from / into. Returns 1.0 on total internal
// reflection (sin of the transmitted angle >= 1), which matches refract() returning the zero vector —
// so reflect/refract selection and TIR stay consistent.
float fresnelDielectric(float cosI, float etaI, float etaT) {
    float sinT2 = (etaI * etaI) / (etaT * etaT) * max(0.0, 1.0 - cosI * cosI);
    if (sinT2 >= 1.0) {
        return 1.0;
    }
    float cosT = sqrt(1.0 - sinT2);
    float rs = (etaI * cosI - etaT * cosT) / (etaI * cosI + etaT * cosT);
    float rp = (etaI * cosT - etaT * cosI) / (etaI * cosT + etaT * cosI);
    return 0.5 * (rs * rs + rp * rp);
}

// PCG hash RNG.
uint pcg(inout uint s) {
    s = s * 747796405u + 2891336453u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}
// High 24 bits are exactly representable; converting all 32 first can round up to 1.
float rndf(inout uint s) { return float(pcg(s) >> 8u) * (1.0 / 16777216.0); }

// Stable 32-bit finalizer shared with OfflineSampleSequence.hash32().
uint offlineHash32(uint value) {
    uint x = value;
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}

uint64_t offlineRotation64(uint pixelHash, uint highSalt, uint lowSalt) {
    uint64_t high = uint64_t(offlineHash32(pixelHash ^ highSalt)) << 32;
    uint64_t low = uint64_t(offlineHash32(pixelHash ^ lowSalt));
    return high | low;
}

// 64-bit fixed-point R2/Weyl recurrence with a per-pixel Cranley-Patterson rotation.
// Taking the phase's high 24 bits gives an exactly representable float lattice without converting
// the large sample index to float. Do not add a half-bin offset: integer+0.5 is not representable
// across the upper half of float's 24-bit integer range, and the highest bin could round to 1.0.
float2 offlineR2Sample(uint pixelHash, uint64_t globalSampleIndex) {
    const uint64_t stepX = 0xC13FA9A902A6328FULL;
    const uint64_t stepY = 0x91E10DA5C79E7B1DULL;
    uint64_t sampleNumber = globalSampleIndex + uint64_t(1);
    uint64_t phaseX = offlineRotation64(
            pixelHash, 0x68bc21ebu, 0x02e5be93u) + sampleNumber * stepX;
    uint64_t phaseY = offlineRotation64(
            pixelHash, 0x967a889bu, 0x368cc8b7u) + sampleNumber * stepY;
    const float high24ToUnit = 1.0 / 16777216.0;
    return float2(
            float(uint(phaseX >> 40)) * high24ToUnit,
            float(uint(phaseY >> 40)) * high24ToUnit);
}

uint offlinePathSeed(uint pixelHash, uint64_t globalSampleIndex) {
    uint lowBits = uint(globalSampleIndex);
    uint highBits = uint(globalSampleIndex >> 32);
    return offlineHash32(pixelHash ^ offlineHash32(lowBits)
            ^ offlineHash32(highBits ^ 0x9e3779b9u));
}

float sanitizeRadianceComponent(float value) {
    return isfinite(value) && value >= 0.0 ? value : 0.0;
}

float3 sanitizeRadiance(float3 value) {
    return float3(
            sanitizeRadianceComponent(value.x),
            sanitizeRadianceComponent(value.y),
            sanitizeRadianceComponent(value.z));
}

float3 primaryRayDir(float2 ndc) {
    float4 nearH = mul(pc.invViewProj, float4(ndc.x, ndc.y, 1.0, 1.0));
    float4 farH = mul(pc.invViewProj, float4(ndc.x, ndc.y, 0.0, 1.0));
    float3 nearP = nearH.xyz / nearH.w;
    float3 farP = farH.xyz / farH.w;
    return normalize(farP - nearP);
}

float primaryRayConeSpread(float2 ndc, float2 size, float3 dir) {
    float2 onePixelNdc = 2.0 / size;
    float3 dx = primaryRayDir(ndc + float2(onePixelNdc.x, 0.0));
    float3 dy = primaryRayDir(ndc + float2(0.0, onePixelNdc.y));
    return max(max(length(cross(dir, dx)), length(cross(dir, dy))), RAY_CONE_MIN_SPREAD);
}

// Cosine-weighted hemisphere sample about n (Malley's method). For a Lambertian BRDF this is the
// importance-sampling match: BRDF*cos/pdf = (albedo/PI)*cos / (cos/PI) = albedo, so the continuation
// throughput is just *= albedo with no PI/cos bookkeeping left over.
float3 cosineDir(float3 n, inout uint s) {
    float u1 = rndf(s);
    float u2 = rndf(s);
    float r = sqrt(u1);
    float phi = 6.2831853 * u2;
    float3 t = normalize(abs(n.x) > 0.9 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0));
    float3 b = normalize(cross(n, t));
    t = cross(b, n);
    float3 local = float3(r * cos(phi), r * sin(phi), sqrt(max(0.0, 1.0 - u1)));
    return normalize(local.x * t + local.y * b + local.z * n);
}

// Soft shadows: sample a direction within the light's SQUARE angular extent about `axis`. MC's
// sun/moon are square quads, so the NEE shadow ray samples a square (not a cone) — the same square the
// visible disc in world.rmiss uses, built from the same celestial tangent frame (right = arc-travel
// direction, from pc.celestial.xyz). Averaged over frames by DLSS-RR this yields soft penumbrae that
// widen with occluder distance (contact-hardening) for free. halfAngle <= 0 ⇒ exact direction (hard).
float3 sampleSquare(float3 axis, float halfAngle, inout uint s) {
#ifdef CAUSTICA_OFFLINE_FP32
    // Explicit draws preserve RNG order; sample and PDF use the same frame and angle bounds.
    float first = rndf(s);
    float second = rndf(s);
    return sampleCelestialSquare(axis, pc.celestial.xyz, halfAngle, float2(first, second));
#else
    float3 right = normalize(cross(axis, pc.celestial.xyz));
    float3 up = cross(right, axis);
    float t = tan(halfAngle);
    float u = (rndf(s) * 2.0 - 1.0) * t;
    float v = (rndf(s) * 2.0 - 1.0) * t;
    return normalize(axis + u * right + v * up);
#endif
}

// Sample a GGX visible-normal (VNDF, Heitz 2018) about geometric normal n for view ve, returning the
// sampled microfacet normal (half-vector) in world space. alpha = rough^2. Paired with the separable
// Smith term, the importance-sampling weight reduces to F * G1(NdotL) (applied by the caller).
float3 sampleGGXVNDF(float3 n, float3 ve, float rough, inout uint s) {
    float3 t = normalize(abs(n.x) > 0.9 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0));
    float3 b = normalize(cross(n, t));
    t = cross(b, n);
    float3 Ve = float3(dot(ve, t), dot(ve, b), dot(ve, n)); // view in tangent space (z = n)
    float a = rough * rough;
    float3 Vh = normalize(float3(a * Ve.x, a * Ve.y, Ve.z));
    float lensq = Vh.x * Vh.x + Vh.y * Vh.y;
    float3 T1 = lensq > 0.0 ? float3(-Vh.y, Vh.x, 0.0) * rsqrt(lensq) : float3(1.0, 0.0, 0.0);
    float3 T2 = cross(Vh, T1);
    float u1 = rndf(s);
    float u2 = rndf(s);
    float r = sqrt(u1);
    float phi = 6.2831853 * u2;
    float p1 = r * cos(phi);
    float p2 = r * sin(phi);
    float ss = 0.5 * (1.0 + Vh.z);
    p2 = (1.0 - ss) * sqrt(1.0 - p1 * p1) + ss * p2;
    float3 Nh = p1 * T1 + p2 * T2 + sqrt(max(0.0, 1.0 - p1 * p1 - p2 * p2)) * Vh;
    float3 Ne = normalize(float3(a * Nh.x, a * Nh.y, max(0.0, Nh.z))); // microfacet normal, tangent space
    return normalize(Ne.x * t + Ne.y * b + Ne.z * n);                 // -> world space
}

// TLAS instance-mask bits (set on the Java side, ANDed against these per-ray cull masks):
//   bit 0 (0x01) — secondary rays: shadows, GI bounces, reflections.
//   bit 1 (0x02) — the primary camera ray.
// Terrain / entities / block entities keep 0xFF (both bits). Particles use 0x02: primary-visible
// receiver billboards only. The first-person camera owner uses 0x01 (secondary only).
static const uint CULL_SECONDARY = 0x01u;
static const uint CULL_PRIMARY = 0x02u;
static const uint TERRAIN_BUCKETS = 4u;
static const uint SBT_RADIANCE = 0u;
static const uint SBT_SHADOW = TERRAIN_BUCKETS;
static const uint SBT_STRIDE_BUCKET = 1u;

RayDesc makeRay(float3 origin, float tmin, float3 dir, float tmax) {
    RayDesc r;
    r.Origin = origin;
    r.TMin = tmin;
    r.Direction = dir;
    r.TMax = tmax;
    return r;
}

// SER radiance trace: trace into a hit object, reorder threads by hit coherence, THEN invoke the
// hit/miss shader — this is where the divergent Section/Prim shading work (world.rchit/world.rahit)
// actually happens, so reordering before it is what pays for the reorder's own cost.
void traceRadianceReordered(uint cullMask, float3 ro, float tmin, float3 rd, float tmax) {
    HitObject hObj = HitObject::TraceRay(topLevelAS, RAY_FLAG_NONE, cullMask,
            SBT_RADIANCE, SBT_STRIDE_BUCKET, 0u, makeRay(ro, tmin, rd, tmax), payload);
    ReorderThread(hObj);
    HitObject::Invoke(topLevelAS, hObj, payload);
}

float3 visibility(float3 origin, float3 dir, float tmax) {
    shadowVis = float4(1.0, 1.0, 1.0, -1.0); // a = water-crossing sentinel, filled by the water any-hit
    // Shadow SBT records run any-hit only for cutout/translucent/water. Cutout alpha-tests; translucent
    // and water tint shadowVis.rgb and pass through. Solid blocks terminate traversal. There is no closest
    // or miss shader worth executing, so use a hit object only as the traversal result.
    HitObject hObj = HitObject::TraceRay(topLevelAS,
            RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
            CULL_SECONDARY, SBT_SHADOW, SBT_STRIDE_BUCKET, 0u,
            makeRay(origin, RAY_TMIN, dir, tmax), shadowVis);
    return hObj.IsMiss() ? shadowVis.rgb : float3(0.0, 0.0, 0.0);
}

// Connect through the same thin, straight-transmitting glass interfaces as tracePath.
// Water bends the ray and cannot be connected by this straight-line estimator.
float3 celestialVisibility(float3 origin, float3 dir, float tmax, uint bounce,
                           float rayConeWidth, float rayConeSpread) {
#ifdef CAUSTICA_OFFLINE_FP32
    Payload savedPayload = payload;
    float3 transmission = float3(1.0);
    float3 result = float3(0.0);
    uint crossed = 0u;
    while (true) {
        payload.hitT = -1.0;
        payloadSetTraceState(false, rayConeWidth, rayConeSpread);
        traceRadianceReordered(CULL_SECONDARY, origin, 0.0, dir, tmax);
        if (payload.hitT < 0.0) {
            result = transmission;
            break;
        }
        // The ordinary continuation needs one loop iteration to miss after the final
        // pane. Direct illumination without any pane remains valid at the last vertex.
        if (payloadMaterial() != MATERIAL_GLASS || bounce + crossed + 1u >= pc.maxBounces) break;
        float F = fresnelDielectric(clamp(dot(-dir, payload.normal), 0.0, 1.0), 1.0, GLASS_IOR);
        transmission *= (1.0 - F) * sqrt(clamp(payload.albedo, 0.0, 1.0));
        rayConeWidth = max(rayConeWidth + rayConeSpread * max(payload.hitT, 0.0), RAY_CONE_MIN_WIDTH);
        origin += dir * payload.hitT - payload.normal * GLASS_TRANSMIT_BIAS;
        tmax -= payload.hitT;
        crossed++;
        if (!(tmax > 0.0)) break;
    }
    payload = savedPayload;
    return result;
#else
    return visibility(origin, dir, tmax);
#endif
}

// Allocate samples using bounds on each lobe's f*cos/p, including the offline
// diffuse energy budget. This changes the proposal only, not the BRDF. Choosing
// U/(U+D) minimizes max(U/ps,D/(1-ps)) before the support-preserving clamps.
float surfaceSpecularProbability(float3 n, float3 v, float3 diffAlb, float3 f0) {
#ifdef CAUSTICA_OFFLINE_FP32
    float a = surfaceDiffuseTransmission(dot(n, v));
    float tx = 1.0 - clamp(f0.x, 0.0, 1.0);
    float ty = 1.0 - clamp(f0.y, 0.0, 1.0);
    float tz = 1.0 - clamp(f0.z, 0.0, 1.0);
    float specularBound = max(1.0 - tx * a, max(1.0 - ty * a, 1.0 - tz * a));
    // A(L)<=1; use the same upward-rounded normalization as surface_energy.
    float diffuseBound = max(max(0.0, diffAlb.x) * tx,
            max(max(0.0, diffAlb.y) * ty, max(0.0, diffAlb.z) * tz)) * a / 0.8411881;
    if (diffuseBound <= 0.0) return 1.0;
    if (specularBound <= 0.0) return 0.0;
    return clamp(specularBound / (specularBound + diffuseBound), 0.0001, 0.9999);
#else
    return clamp(luminance(f0) / (luminance(f0) + luminance(diffAlb) + 1.0e-4), 0.1, 0.9);
#endif
}

float3 evaluateSurfaceBrdf(float3 n, float3 v, float3 l, float3 diffAlb,
                           float3 f0, float rough, bool pbr) {
    float ndl = max(0.0, dot(n, l));
    if (ndl <= 0.0) {
        return float3(0.0, 0.0, 0.0);
    }
    float3 brdf = diffAlb * INV_PI;
    if (pbr) {
        float3 h = normalize(l + v);
        float ndh = max(0.0, dot(n, h));
        float ndv = dot(n, v);
        if (!(ndv > 0.0)) return float3(0.0);
#ifdef CAUSTICA_OFFLINE_FP32
        // Allocate a reciprocal diffuse complement to the GGX reflection budget.
        // Sampling still uses the same full mixture PDF; this changes f, not p.
        // Realtime keeps its current BRDF/guide pair until RR is validated together.
        brdf *= float3(surfaceDiffuseEnergyBudget(ndv, ndl, f0.r),
                       surfaceDiffuseEnergyBudget(ndv, ndl, f0.g),
                       surfaceDiffuseEnergyBudget(ndv, ndl, f0.b));
#endif
        float vdh = max(0.0, dot(v, h));
        float D = ggxD(ndh, rough);
        float G = ggxG1(ndv, rough) * ggxG1(ndl, rough);
        brdf += (D * G) * fresnelSchlick(vdh, f0) / (4.0 * ndv * ndl);
    }
    return brdf;
}

float surfaceBsdfPdf(float3 n, float3 v, float3 l, float3 diffAlb,
                     float3 f0, float rough, bool pbr) {
    float ndl = max(0.0, dot(n, l));
    if (ndl <= 0.0) {
        return 0.0;
    }
    float diffusePdf = ndl * INV_PI;
    if (!pbr) {
        return diffusePdf;
    }
    float ndv = dot(n, v);
    if (!(ndv > 0.0)) return 0.0;
    float3 h = normalize(v + l);
    float ndh = max(0.0, dot(n, h));
    float specularPdf = ggxD(ndh, rough) * ggxG1(ndv, rough) / (4.0 * ndv);
    float ps = surfaceSpecularProbability(n, v, diffAlb, f0);
    return (1.0 - ps) * diffusePdf + ps * specularPdf;
}

// Given a guided direction, retain the old BSDF sampler's conditional lobe
// distribution for ray-cone filtering at subsequent textured intersections.
float surfaceSpecularPosterior(float3 n, float3 v, float3 l, float3 diffAlb,
                               float3 f0, float rough) {
    float basePdf = surfaceBsdfPdf(n, v, l, diffAlb, f0, rough, true);
    if (!(basePdf > 0.0)) return 0.0;
    float ps = surfaceSpecularProbability(n, v, diffAlb, f0);
    float diffuseMass = (1.0 - ps) * max(0.0, dot(n, l)) * INV_PI;
    return clamp(1.0 - diffuseMass / basePdf, 0.0, 1.0);
}

float offlineWaterGuideMix(bool submerged) {
#ifdef CAUSTICA_OFFLINE_FP32
    return waterCelestialGuideMix(submerged, pc.lightDir.w, pc.lightDir.y,
            max(pc.lightRadiance.x, max(pc.lightRadiance.y, pc.lightRadiance.z)));
#else
    return 0.0;
#endif
}

// Choose a deterministic proposal context before consuming any vertex RNG.
// The pilot only locates a likely interface; real continuation rays still decide
// visibility, Fresnel, absorption and whether the mapped direction reaches the sun.
float offlineInterfaceGuide(float3 p, float3 n, bool submerged, int bounce, int maxBounces,
                            float rayConeWidth, float rayConeSpread,
                            out float3 guideNormal, out bool guideReflection) {
    guideNormal = float3(0.0, 1.0, 0.0);
    guideReflection = false;
#ifdef CAUSTICA_OFFLINE_FP32
    if (bounce >= maxBounces) return 0.0;
    float strength = max(pc.lightRadiance.x, max(pc.lightRadiance.y, pc.lightRadiance.z));
    if (!(waterCelestialGuideMix(true, pc.lightDir.w, pc.lightDir.y, strength) > 0.0)) return 0.0;
    float guideMix = offlineWaterGuideMix(submerged);
    float3 pilotDir = interfaceCelestialDirection(pc.lightDir.xyz, guideNormal, WATER_IOR, !submerged);
    if (!(dot(n, pilotDir) > 0.0)) return guideMix;

    Payload savedPayload = payload;
    payload.hitT = -1.0;
    payloadSetTraceState(false, rayConeWidth, rayConeSpread);
    traceRadianceReordered(CULL_SECONDARY, p, 0.0, pilotDir, 10000.0);
    if (payload.hitT >= 0.0 && payloadMaterial() == MATERIAL_WATER
            && payloadWaterEntering() == !submerged) {
        float3 interfaceNormal = submerged ? -payload.normal : payload.normal;
        if (!submerged && (pc.flags & 16u) != 0u) {
            float3 pilotPos = p + pilotDir * payload.hitT;
            interfaceNormal = applyWaterWaves(interfaceNormal, pilotPos.xz + pc.waterAnchor.xy, pc.waterParams.w);
        }
        interfaceNormal = normalize(interfaceNormal);
        float candidateMix = waterCelestialGuideMix(true, pc.lightDir.w,
                dot(pc.lightDir.xyz, interfaceNormal), strength);
        if (candidateMix > 0.0) {
            guideNormal = interfaceNormal;
            guideReflection = !submerged;
            guideMix = candidateMix;
        }
    }
    payload = savedPayload;
    return guideMix;
#else
    return 0.0;
#endif
}

float surfaceContinuationPdf(float3 n, float3 v, float3 l, float3 diffAlb,
                             float3 f0, float rough, bool pbr, float waterGuideMix,
                             float3 waterGuideNormal, bool waterGuideReflection) {
    float basePdf = surfaceBsdfPdf(n, v, l, diffAlb, f0, rough, pbr);
    if (!(waterGuideMix > 0.0)) return basePdf;
    if (!(dot(n, l) > 0.0)) return 0.0;
    float guidePdf = interfaceCelestialPdf(pc.lightDir.xyz, pc.celestial.xyz, pc.lightDir.w,
            l, waterGuideNormal, WATER_IOR, waterGuideReflection);
    return waterCelestialMixturePdf(basePdf, guidePdf, waterGuideMix);
}

float powerHeuristic(float a, float b) {
    float aa = a * a;
    float bb = b * b;
    return aa / max(aa + bb, 1.0e-20);
}

static const float LOCAL_MIX = 0.9;

bool receiverLocalDirectory(uint receiverSlot, out LocalLightDirectory directory) {
    directory.referenceOffset = 0u;
    directory.referenceCount = 0u;
    directory.totalWeight = 0.0;
    directory.reserved = 0.0;
    if (receiverSlot == 0xFFFFFFFFu || pc.localDirectoryAddr == 0
            || pc.localReferenceAddr == 0 || pc.localDirectoryCount == 0u
            || pc.localReferenceCount == 0u || receiverSlot >= pc.localDirectoryCount) {
        return false;
    }
    directory = ConstPtr<LocalLightDirectory>(pc.localDirectoryAddr)[receiverSlot];
    if (directory.referenceCount == 0u || !(directory.totalWeight > 0.0)
            || directory.referenceOffset > pc.localReferenceCount
            || directory.referenceCount > pc.localReferenceCount - directory.referenceOffset) {
        return false;
    }
    return true;
}

bool localDirectoryContains(LocalLightDirectory directory, uint globalLightIndex) {
    ConstPtr<LocalLightReference> references =
            ConstPtr<LocalLightReference>(pc.localReferenceAddr);
    uint lo = directory.referenceOffset;
    uint hi = lo + directory.referenceCount;
    while (lo < hi) {
        uint mid = (lo + hi) >> 1u;
        uint candidate = references[mid].globalLightIndex;
        if (candidate < globalLightIndex) {
            lo = mid + 1u;
        } else {
            hi = mid;
        }
    }
    uint end = directory.referenceOffset + directory.referenceCount;
    return lo < end && references[lo].globalLightIndex == globalLightIndex;
}

float staticLightSelectionPdf(uint lightIndex, StaticLight light, uint receiverSlot) {
    float globalPdf = light.uv2_emission.w / pc.staticLightTotalWeight;
    LocalLightDirectory directory;
    if (!receiverLocalDirectory(receiverSlot, directory)) {
        return globalPdf;
    }
    float selectionPdf = (1.0 - LOCAL_MIX) * globalPdf;
    if (localDirectoryContains(directory, lightIndex)) {
        selectionPdf += LOCAL_MIX * light.uv2_emission.w / directory.totalWeight;
    }
    return selectionPdf;
}

uint selectGlobalStaticLight(ConstPtr<StaticLight> lights, float target) {
    uint lo = 0u;
    uint hi = pc.staticLightCount - 1u;
    while (lo < hi) {
        uint mid = (lo + hi) >> 1u;
        if (lights[mid].edge1_weight.w > target) {
            hi = mid;
        } else {
            lo = mid + 1u;
        }
    }
    return lo;
}

uint selectRealtimeLightBlock(
        ConstPtr<RealtimeLightBlock> lights, float target) {
    uint lo = 0u;
    uint hi = pc.realtimeLightBlockCount - 1u;
    while (lo < hi) {
        uint mid = (lo + hi) >> 1u;
        if (lights[mid].positionCdf.w > target) {
            hi = mid;
        } else {
            lo = mid + 1u;
        }
    }
    return lo;
}

uint selectLocalStaticLight(LocalLightDirectory directory, float target) {
    ConstPtr<LocalLightReference> references =
            ConstPtr<LocalLightReference>(pc.localReferenceAddr);
    uint lo = directory.referenceOffset;
    uint hi = lo + directory.referenceCount - 1u;
    while (lo < hi) {
        uint mid = (lo + hi) >> 1u;
        if (references[mid].cumulativeWeight > target) {
            hi = mid;
        } else {
            lo = mid + 1u;
        }
    }
    return references[lo].globalLightIndex;
}

float staticAreaLightPdf(uint lightIndex, float distance, float3 directionToLight,
                         uint receiverSlot) {
    if ((pc.flags & 32u) == 0u || lightIndex >= pc.staticLightCount
            || !(pc.staticLightTotalWeight > 0.0)) {
        return 0.0;
    }
    ConstPtr<StaticLight> lights = ConstPtr<StaticLight>(pc.staticLightAddr);
    StaticLight light = lights[lightIndex];
    if (light.p0_kind.w > 0.5 || !(light.edge2_area.w > 0.0)) {
        return 0.0;
    }
    float3 lightNormal = normalize(cross(light.edge1_weight.xyz, light.edge2_area.xyz));
    // Minecraft cutout emitters (notably torch flame planes) are visible from either side, so their
    // sampling density must use the same two-sided convention as closest-hit emission.
    float cosLight = abs(dot(lightNormal, -directionToLight));
    if (cosLight <= 0.0) {
        return 0.0;
    }
    float selectionPdf = staticLightSelectionPdf(lightIndex, light, receiverSlot);
    return selectionPdf * distance * distance / (cosLight * light.edge2_area.w);
}

// One weighted next-event sample from static terrain emitters. Area-light samples and naturally
// BSDF-hit emitters use reciprocal power-heuristic MIS weights in tracePath.
float3 sampleStaticDirect(float3 p, float3 n, float3 v, float3 diffAlb,
                          float3 f0, float rough, bool pbr, uint receiverSlot,
                          float waterGuideMix, float3 waterGuideNormal, bool waterGuideReflection, inout uint seed) {
    if ((pc.flags & 32u) == 0u || pc.staticLightCount == 0u
            || !(pc.staticLightTotalWeight > 0.0)) {
        return float3(0.0, 0.0, 0.0);
    }
    ConstPtr<StaticLight> lights = ConstPtr<StaticLight>(pc.staticLightAddr);
    uint lightIndex;
    LocalLightDirectory directory;
    float branchSample = rndf(seed);
    if (receiverLocalDirectory(receiverSlot, directory)) {
        if (branchSample < LOCAL_MIX) {
            lightIndex = selectLocalStaticLight(
                    directory, (branchSample / LOCAL_MIX) * directory.totalWeight);
        } else {
            lightIndex = selectGlobalStaticLight(
                    lights, ((branchSample - LOCAL_MIX) / (1.0 - LOCAL_MIX))
                            * pc.staticLightTotalWeight);
        }
    } else {
        lightIndex = selectGlobalStaticLight(lights, branchSample * pc.staticLightTotalWeight);
    }
    StaticLight light = lights[lightIndex];
    float selectionPdf = staticLightSelectionPdf(lightIndex, light, receiverSlot);
    if (!(selectionPdf > 0.0)) {
        return float3(0.0, 0.0, 0.0);
    }

    if (light.p0_kind.w > 0.5) {
        float3 toLight = light.p0_kind.xyz - p;
        float dist2 = max(dot(toLight, toLight), 0.0625);
        float dist = sqrt(dist2);
        float3 l = toLight / dist;
        float ndl = max(0.0, dot(n, l));
        if (ndl <= 0.0) {
            return float3(0.0, 0.0, 0.0);
        }
        float3 vis = visibility(p, l, max(RAY_TMIN, dist - SURF_BIAS));
        return evaluateSurfaceBrdf(n, v, l, diffAlb, f0, rough, pbr)
                * (light.pointData.x / (dist2 * selectionPdf)) * ndl * vis;
    }

    float su = sqrt(rndf(seed));
    float b1 = 1.0 - su;
    float b2 = rndf(seed) * su;
    float3 lightPos = light.p0_kind.xyz + b1 * light.edge1_weight.xyz + b2 * light.edge2_area.xyz;
    float2 lightUv = light.uv01.xy
            + b1 * (light.uv01.zw - light.uv01.xy)
            + b2 * (light.uv2_emission.xy - light.uv01.xy);
    float3 toLight = lightPos - p;
    float dist2 = dot(toLight, toLight);
    if (!(dist2 > 1.0e-8)) {
        return float3(0.0, 0.0, 0.0);
    }
    float dist = sqrt(dist2);
    float3 l = toLight / dist;
    float3 lightNormal = normalize(cross(light.edge1_weight.xyz, light.edge2_area.xyz));
    float cosLight = abs(dot(lightNormal, -l));
    float ndl = max(0.0, dot(n, l));
    if (cosLight <= 0.0 || ndl <= 0.0 || !(light.edge2_area.w > 0.0)) {
        return float3(0.0, 0.0, 0.0);
    }
    float4 texel = blockAtlas.SampleLevel(lightUv, 0.0);
    if (texel.a < 0.5) {
        return float3(0.0, 0.0, 0.0);
    }
    float emission = light.uv2_emission.z;
    if (light.tint_hasS.w > 0.5) {
        float a = blockSpecAtlas.SampleLevel(lightUv, 0.0).a * 255.0;
        emission = a < 254.5 ? a / 254.0 : 0.0;
    }
    if (!(emission > 0.0)) {
        return float3(0.0, 0.0, 0.0);
    }
    float lightPdf = selectionPdf * dist2 / (cosLight * light.edge2_area.w);
    float bsdfPdf = surfaceContinuationPdf(n, v, l, diffAlb, f0, rough, pbr, waterGuideMix, waterGuideNormal, waterGuideReflection);
    float misWeight = powerHeuristic(lightPdf, bsdfPdf);
    float3 vis = visibility(p, l, max(RAY_TMIN, dist - SURF_BIAS));
    float3 radiance = srgbToLinear(texel.rgb) * light.tint_hasS.xyz
            * emission * EMISSIVE_STRENGTH;
    return evaluateSurfaceBrdf(n, v, l, diffAlb, f0, rough, pbr)
            * radiance * ndl * vis * misWeight / max(lightPdf, 1.0e-8);
}

float3 sampleRealtimeLightBlockDirect(
        float3 p, float3 n, float3 v,
        float3 diffAlb, float3 f0, float rough, bool pbr,
        inout uint seed) {
    if ((pc.flags & 64u) == 0u || pc.realtimeLightBlockAddr == 0
            || pc.realtimeLightBlockCount == 0u
            || !isfinite(pc.realtimeLightBlockTotalWeight)
            || !(pc.realtimeLightBlockTotalWeight > 0.0)) {
        return float3(0.0, 0.0, 0.0);
    }
    ConstPtr<RealtimeLightBlock> lights =
            ConstPtr<RealtimeLightBlock>(pc.realtimeLightBlockAddr);
    float target = rndf(seed) * pc.realtimeLightBlockTotalWeight;
    if (!(target < pc.realtimeLightBlockTotalWeight)) {
        target = 0.0;
    }
    uint lightIndex = selectRealtimeLightBlock(lights, target);
    if (lightIndex >= pc.realtimeLightBlockCount) {
        return float3(0.0, 0.0, 0.0);
    }
    RealtimeLightBlock light = lights[lightIndex];
    if (!isfinite(light.radianceWeight.w) || !(light.radianceWeight.w > 0.0)) {
        return float3(0.0, 0.0, 0.0);
    }
    float selectionPdf =
            light.radianceWeight.w / pc.realtimeLightBlockTotalWeight;
    if (!isfinite(selectionPdf) || !(selectionPdf > 0.0)) {
        return float3(0.0, 0.0, 0.0);
    }
    float3 toLight = light.positionCdf.xyz - p;
    float dist2 = max(dot(toLight, toLight), 0.0625);
    float dist = sqrt(dist2);
    float3 l = toLight / dist;
    float ndl = max(0.0, dot(n, l));
    if (ndl <= 0.0) {
        return float3(0.0, 0.0, 0.0);
    }
    float3 vis = visibility(p, l, max(RAY_TMIN, dist - SURF_BIAS));
    return evaluateSurfaceBrdf(n, v, l, diffAlb, f0, rough, pbr)
            * light.radianceWeight.xyz
            * (ndl / (dist2 * selectionPdf))
            * vis;
}

float3 sampleRealtimeLightBlockParticle(
        float3 hitPos, float3 n, float3 albedo,
        inout uint seed) {
    if ((pc.flags & 64u) == 0u || pc.realtimeLightBlockAddr == 0
            || pc.realtimeLightBlockCount == 0u
            || !isfinite(pc.realtimeLightBlockTotalWeight)
            || !(pc.realtimeLightBlockTotalWeight > 0.0)) {
        return float3(0.0, 0.0, 0.0);
    }
    ConstPtr<RealtimeLightBlock> lights =
            ConstPtr<RealtimeLightBlock>(pc.realtimeLightBlockAddr);
    float target = rndf(seed) * pc.realtimeLightBlockTotalWeight;
    if (!(target < pc.realtimeLightBlockTotalWeight)) {
        target = 0.0;
    }
    uint lightIndex = selectRealtimeLightBlock(lights, target);
    if (lightIndex >= pc.realtimeLightBlockCount) {
        return float3(0.0, 0.0, 0.0);
    }
    RealtimeLightBlock light = lights[lightIndex];
    if (!isfinite(light.radianceWeight.w) || !(light.radianceWeight.w > 0.0)) {
        return float3(0.0, 0.0, 0.0);
    }
    float selectionPdf =
            light.radianceWeight.w / pc.realtimeLightBlockTotalWeight;
    if (!isfinite(selectionPdf) || !(selectionPdf > 0.0)) {
        return float3(0.0, 0.0, 0.0);
    }
    float3 toLight = light.positionCdf.xyz - hitPos;
    float dist2 = max(dot(toLight, toLight), 0.0625);
    float dist = sqrt(dist2);
    float3 l = toLight / dist;
    float signedNdl = dot(n, l);
    float ndl = abs(signedNdl);
    if (ndl <= 0.0) {
        return float3(0.0, 0.0, 0.0);
    }
    float3 shadowOrigin =
            hitPos + (signedNdl >= 0.0 ? n : -n) * SURF_BIAS;
    float3 vis =
            visibility(shadowOrigin, l, max(RAY_TMIN, dist - SURF_BIAS));
    return albedo * INV_PI
            * light.radianceWeight.xyz
            * (ndl / (dist2 * selectionPdf))
            * vis;
}

float2 projectPrevNdc(float3 worldPos) {
    float4 clip = mul(pc.prevViewProj, float4(worldPos - pc.camOffset + pc.camDelta, 1.0));
    return clip.xy / clip.w;
}

// Previous-frame screen position of a planar reflection. The reflected image of a world point P seen
// in a planar reflector is the MIRROR image V = mirror(P) across the surface plane: the eye sees V
// along a straight line, so the reflection appears at proj(V). Project the mirror image directly.
// Gotcha: intersecting a reflection ray with the surface plane divides by dot(mirrorDir, n), which
// explodes at grazing angles and produces non-zero MV in a static scene. Mirroring is division-free, so
// static MV is bit-exact zero at any incidence. The reflector is assumed static (terrain / water);
// reflectedMotionPrev carries the reflected content's own displacement.
float2 previousReflectionNdc(float3 surfacePos, float3 surfaceNormal, float3 reflectedWorldPos, float3 reflectedMotionPrev) {
    float3 n = normalize(surfaceNormal); // mirror(P) is orientation-independent, so no viewer flip needed
    float3 prevHit = reflectedWorldPos - reflectedMotionPrev;
    float3 mirroredHit = prevHit - 2.0 * n * dot(prevHit - surfacePos, n);
    return projectPrevNdc(mirroredHit);
}

// Reflection (specular) motion vector for DLSS-RR. Covers smooth specular blocks (metals / LabPBR _s)
// and water reflections including underwater total-internal-reflection — any primary surface with a
// sharp specular lobe (first-interface reflection valid, roughness <= 0.5). A sky miss is treated as a reflected
// hit at infinity along the reflected direction, so the same mirror-image reprojection handles surface
// and sky reflections uniformly (continuous as the reflected distance -> infinity).
float2 specularReflectionMotion(float3 surfacePos, float3 primaryDir, float2 currentNdc, float2 size, float primaryConeSpread) {
    if (!gv_reflectionMotionValid || length(gv_normal) < 0.5 || gv_rough > 0.5) {
        return float2(0.0, 0.0);
    }

    float3 n = normalize(gv_normal);
    float3 specDir = reflect(primaryDir, n);
    // The bias is ONLY for the trace origin (so the reflection ray doesn't self-intersect the surface it
    // leaves). The hit is then reconstructed from the TRUE surface point `surfacePos`, NOT the biased
    // origin: reconstructing from `surfacePos + n*SURF_BIAS` bakes a constant `-n*SURF_BIAS` world offset
    // into the mirrored virtual point, and that offset's screen projection blows up at grazing angles (n
    // lies in the screen plane there) -> a non-zero MV in a static scene. Reconstructing from surfacePos
    // cancels the term so the mirror lands exactly on the view ray (static MV = bit-exact zero) WITHOUT
    // zeroing the trace bias the main path tracer needs to avoid surface acne.
    payload.hitT = -1.0;
    payloadSetTraceState(false,
            max(length(surfacePos - pc.camOffset) * primaryConeSpread, RAY_CONE_MIN_WIDTH),
            max(primaryConeSpread, RAY_CONE_MIN_SPREAD));
    traceRadianceReordered(CULL_SECONDARY, surfacePos + n * SURF_BIAS, RAY_TMIN, specDir, 10000.0);

    float3 reflectedHit;
    float3 reflectedMotionPrev;
    if (payload.hitT > 0.0) {
        reflectedHit = surfacePos + specDir * payload.hitT;
        // Reflected water/fluid is a static dielectric (its chit MV lane is repurposed); only opaque
        // geometry carries a real per-vertex displacement. Particles are off secondary rays (cull mask).
        reflectedMotionPrev = payloadMaterial() == MATERIAL_OPAQUE ? payload.motionPrev : float3(0.0, 0.0, 0.0);
    } else {
        reflectedHit = surfacePos + specDir * 1.0e6; // sky reflection: virtual image at infinity along specDir
        reflectedMotionPrev = float3(0.0, 0.0, 0.0);
    }
    float2 prevNdc = previousReflectionNdc(surfacePos, n, reflectedHit, reflectedMotionPrev);
    return (prevNdc - currentNdc) * 0.5 * size;
}

// Follow glass/water transmission through a small, fixed number of interfaces and report the first
// opaque or sky feature behind them. Normal, roughness, and depth remain owned by the primary surface;
// only albedo and ordinary motion use this transmitted feature. The module payload is scratch here, so
// every primary caller must restore its complete payload immediately after this helper returns.
void transmissionGuideHit(
        float3 surfacePos,
        float3 incidentDir,
        float3 surfaceNormal,
        uint surfaceMaterial,
        bool inWaterAtSurface,
        bool waterEnteringAtSurface,
        float3 initialGlassTransmission,
        float3 guideWaterExt,
        float rayConeWidth,
        float rayConeSpread,
        out float3 hitCamRel,
        out float3 motionPrev,
        out bool transmitted,
        out float3 diffuseAlbedo) {
    hitCamRel = surfacePos - pc.camOffset;
    motionPrev = float3(0.0, 0.0, 0.0);
    transmitted = false;
    diffuseAlbedo = float3(0.0, 0.0, 0.0);

    float3 guideDir = normalize(incidentDir);
    float3 guideNormal = normalize(surfaceNormal);
    float3 guideTransmission = initialGlassTransmission;
    float3 ro;
    bool guideInWater = inWaterAtSurface;
    if (surfaceMaterial == MATERIAL_GLASS) {
        ro = surfacePos - guideNormal * GLASS_TRANSMIT_BIAS;
    } else if (surfaceMaterial == MATERIAL_WATER) {
        guideInWater = !waterEnteringAtSurface;
        float etaI = guideInWater ? WATER_IOR : 1.0;
        float etaT = guideInWater ? 1.0 : WATER_IOR;
        guideDir = refract(guideDir, guideNormal, etaI / etaT);
        if (dot(guideDir, guideDir) <= 0.0) {
            return;
        }
        guideDir = normalize(guideDir);
        guideInWater = waterEnteringAtSurface;
        ro = surfacePos - guideNormal * SURF_BIAS;
    } else {
        return;
    }

    bool waterWaves = (pc.flags & 16u) != 0u;
    // The caller already crossed the first surface. Four bounded traces are enough to cross interfaces
    // two through four and still inspect the opaque/sky endpoint beyond interface four. If that endpoint
    // is a fifth transparent interface, the budget guard returns without crossing it.
    int crossedInterfaceCount = 1;
    for (int guideTraceIndex = 0; guideTraceIndex < MAX_TRANSMISSION_GUIDE_INTERFACES; guideTraceIndex++) {
        payload.hitT = -1.0;
        payloadSetTraceState(false, rayConeWidth, rayConeSpread);
        traceRadianceReordered(CULL_SECONDARY, ro, RAY_TMIN, guideDir, 10000.0);
        float guideSegmentDistance = payload.hitT < 0.0 ? 10000.0 : payload.hitT;
        if (guideInWater) {
            guideTransmission *= exp(-guideWaterExt * guideSegmentDistance);
        }
        if (payload.hitT < 0.0) {
            hitCamRel = (ro + guideDir * 1.0e6) - pc.camOffset;
            motionPrev = float3(0.0, 0.0, 0.0);
            diffuseAlbedo = guideTransmission * SKY_DIFF_ALBEDO;
            transmitted = true;
            return;
        }

        float3 hitPos = ro + guideDir * payload.hitT;
        uint material = payloadMaterial();
        if (material == MATERIAL_OPAQUE) {
            hitCamRel = hitPos - pc.camOffset;
            motionPrev = payload.motionPrev;
            bool pbr = (pc.flags & 2u) != 0u;
            float3 endpointDiffuseAlbedo = pbr
                    ? payload.albedo * (1.0 - clamp(payloadMetalness(), 0.0, 1.0))
                    : payload.albedo;
            diffuseAlbedo = guideTransmission * endpointDiffuseAlbedo;
            transmitted = true;
            return;
        }

        if (material != MATERIAL_GLASS && material != MATERIAL_WATER) {
            return;
        }
        if (crossedInterfaceCount >= MAX_TRANSMISSION_GUIDE_INTERFACES) {
            return;
        }

        if (material == MATERIAL_GLASS) {
            guideTransmission *= sqrt(clamp(payload.albedo, 0.0, 1.0));
            ro = hitPos - payload.normal * GLASS_TRANSMIT_BIAS;
            crossedInterfaceCount++;
            continue;
        }

        if (material == MATERIAL_WATER) {
            float3 n = payload.normal;
            bool waterEntering = payloadWaterEntering();
            guideInWater = !waterEntering;
            float etaI = guideInWater ? WATER_IOR : 1.0;
            float etaT = guideInWater ? 1.0 : WATER_IOR;
            float3 nextDir = refract(guideDir, n, etaI / etaT);
            if (dot(nextDir, nextDir) <= 0.0) {
                return;
            }
            guideDir = normalize(nextDir);
            if (waterEntering) {
                guideWaterExt = waterExtinction(payload.albedo);
            }
            guideInWater = waterEntering;
            ro = hitPos - n * SURF_BIAS;
            crossedInterfaceCount++;
            continue;
        }
    }
}

// Diagnostic observer never samples RNG or modifies transport. Only a bounded replay writes steps.
static uint64_t probeRecordAddr;
static float probePeak;
static float3 probeSource;
static uint3 probeEvent;

float pathProbeMagnitude(float3 value) {
    return all(isfinite(value)) ? max(abs(value.x), max(abs(value.y), abs(value.z))) : 3.402823e38;
}
void pathProbeBegin(int bounce, float3 ro, float3 rd, float3 beta, bool inWater, bool protectedLeg) {
#ifdef CAUSTICA_OFFLINE_FP32
    if (probeRecordAddr == 0 || bounce > 32) return;
    ProbePtr<PathProbeRecord> record = ProbePtr<PathProbeRecord>(probeRecordAddr);
    PathProbeStep step = {};
    bool hit = payload.hitT >= 0.0;
    step.position_hitT = float4(ro + rd * max(payload.hitT, 0.0), payload.hitT);
    step.incoming_inWater = float4(rd, inWater ? 1.0 : 0.0);
    // For ordinary normal-mapped surfaces this is the returned shading normal; water is geometric.
    step.geometricNormal_material = float4(hit ? payload.normal : float3(0.0), hit ? float(payloadMaterial()) : -1.0);
    step.throughputBefore_protected = float4(beta, protectedLeg ? 1.0 : 0.0);
    step.albedo_perceptualRoughness = float4(hit ? payload.albedo : float3(0.0), hit ? payloadRoughness() : 0.0);
    step.F0_metal = float4(hit ? payload.f0 : float3(0.0), hit ? payloadMetalness() : 0.0);
    step.effectiveNormal_rouletteProbability = float4(step.geometricNormal_material.xyz, 1.0);
    step.throughputAfter_survived = float4(beta, -1.0);
    record[0].steps[bounce] = step;
    record[0].state.x = uint(bounce + 1);
#endif
}
void pathProbeEnd(int bounce, float3 beta, float3 rd, float3 n, float q, float survived, float eventType) {
#ifdef CAUSTICA_OFFLINE_FP32
    if (probeRecordAddr == 0 || bounce > 32) return;
    ProbePtr<PathProbeRecord> record = ProbePtr<PathProbeRecord>(probeRecordAddr);
    record[0].steps[bounce].effectiveNormal_rouletteProbability = float4(n, q);
    record[0].steps[bounce].throughputAfter_survived = float4(beta, survived);
    record[0].steps[bounce].outgoing_event = float4(rd, eventType);
#endif
}
bool pathProbeEligible(uint category, int bounce) {
    // Primary visible emitters/sky are normally bright without a transport fault;
    // keep them from exhausting the bounded indirect-light diagnostic capture.
    return category == 8u || category == 10u
            || (bounce > 0 && (category == 9u || category == 13u || category == 14u));
}
void pathProbeObserve(float3 value, uint category, int bounce, uint pathFlags) {
#ifdef CAUSTICA_OFFLINE_FP32
    if (pc.pathProbeAddr == 0) return;
    float peak = pathProbeMagnitude(value);
    if (probeRecordAddr != 0) {
        if (bounce <= 32 && pathProbeEligible(category, bounce)) {
            ProbePtr<PathProbeRecord> record = ProbePtr<PathProbeRecord>(probeRecordAddr);
            if (peak > pathProbeMagnitude(record[0].steps[bounce].maxContribution_category.xyz))
                record[0].steps[bounce].maxContribution_category = float4(value, float(category));
        }
        return;
    }
    if (pathProbeEligible(category, bounce) && peak > probePeak) {
        probePeak = peak;
        probeSource = value;
        probeEvent = uint3(category, uint(bounce), pathFlags);
    }
#endif
}

// One Monte Carlo path from (ro, rd). Returns accumulated radiance along the path.
// Views 8..11 classify the source at every depth; view 12 selects all bounce > 0
// contributions (path depth, not a complete physical indirect-light decomposition).
// Filter the evaluated value only: sampling, visibility and RNG remain identical.
bool offlineContributionVisible(uint view, uint category, int bounce, uint pathFlags, int maxBounces) {
    if (view < 8u) return true;
    if (view == 11u) return category == 13u || category == 14u;
    if (view == 12u) return bounce > 0;
    if (view >= 15u && view <= 18u) return category == 14u && (pathFlags & (1u << (view - 15u))) != 0u;
    if (view == 19u) return category == 10u && bounce == maxBounces;
    if (view == 20u || view == 21u) return category == 14u && (pathFlags & 12u) != 0u
            && (((pathFlags & 16u) != 0u) == (view == 20u));
    return view == category;
}

float3 offlineContribution(float3 value, uint category, int bounce, uint pathFlags) {
    pathProbeObserve(value, category, bounce, pathFlags);
#ifdef CAUSTICA_OFFLINE_FP32
    if (!offlineContributionVisible(pc.debugView, category, bounce, pathFlags, int(pc.maxBounces))) return float3(0.0);
#endif
    return value;
}
float3 tracePath(float3 ro, float3 rd, float primaryConeSpread, inout uint seed) {
    float3 L = float3(0.0, 0.0, 0.0);
    float3 throughput = float3(1.0, 1.0, 1.0);
    float rayConeWidth = 0.0;
    float rayConeSpread = max(primaryConeSpread, RAY_CONE_MIN_SPREAD);
    int maxBounces = int(pc.maxBounces);
    int rrStart = maxBounces <= 3 ? 1 : 2;
    bool pbr = (pc.flags & 2u) != 0u; // GGX BRDF + material guides, else Lambertian fallback
    // Start submerged if the camera is in water so the first segment gets the right medium orientation
    // and absorption when the eye is underwater.
    bool inWater = (pc.flags & 1u) != 0u;
    bool previousDelta = true;
    bool hasNonDeltaBounce = false;
    float previousBsdfPdf = 0.0;
    // Celestial NEE crosses thin glass with the actual transport model. Static
    // lights still use tint shadows, so their MIS state must remain separate.
    bool previousCelestialDelta = true;
    float previousCelestialBsdfPdf = 0.0;
    uint pathFlags = 0u; // ever crossed: glass transmission/reflection, water transmission/reflection
    // Guided legs have small throughput before reaching the bright sun. Do not roulette
    // them away at intervening dielectric interfaces; the existing bounce cap still applies.
    bool waterCelestialGuidedLeg = false;
    uint previousReceiverSlot = 0xFFFFFFFFu;
    bool previousStaticLightNeeEligible = false;
    // Current medium extinction. Defaults to the camera-biome tint (correct when the eye starts
    // submerged, before any water surface is hit); refreshed to the hit water body's tint on each crossing.
    float3 waterExt = waterExtinction(pc.waterParams.xyz);
    bool waterWaves = (pc.flags & 16u) != 0u; // animated wave-normal perturbation
    // Realtime sky-disc gate (see world.rmiss): discs are shown to primary rays and rays spawned
    // by a specular/dielectric bounce (mirror reflections + refractions of the sun/moon), but hidden from
    // diffuse-sampled continuation rays — those are already covered by the sun NEE, so the tiny disc
    // would be a double-counted firefly. Offline overrides this with camera-only decorative discs
    // and evaluates the analytic celestial escape contribution with MIS below.
    bool showCelestial = true;
    for (int bounce = 0; bounce <= maxBounces; bounce++) {
        payload.hitT = -1.0;
#ifdef CAUSTICA_OFFLINE_FP32
        payloadSetTraceState(bounce == 0, rayConeWidth, rayConeSpread);
#else
        payloadSetTraceState(showCelestial, rayConeWidth, rayConeSpread);
#endif
        // Radiance SBT records run any-hit only for true alpha cutout. Translucent/water go straight to
        // closest-hit for dielectric handling. Geometry is double-sided; the chit flips the normal.
        // Primary (bounce 0) is the camera ray (CULL_PRIMARY): sees particles but not the first-person
        // player. Bounce rays are secondary (CULL_SECONDARY): exclude particles, include the player.
        traceRadianceReordered(bounce == 0 ? CULL_PRIMARY : CULL_SECONDARY, ro, 0.0, rd, 10000.0);

        // Attenuate every segment travelled inside water. Misses retain the -1 sentinel, so use the
        // finite trace horizon rather than treating that sentinel as a negative distance.
        float primarySegmentDistance = payload.hitT < 0.0 ? 10000.0 : payload.hitT;
        if (inWater) {
            throughput *= exp(-waterExt * primarySegmentDistance);
        }

        pathProbeBegin(bounce, ro, rd, throughput, inWater, waterCelestialGuidedLeg);
        float probeEventType = 0.0;
        if (payload.hitT < 0.0) {
            // Set only at the final miss: low four bits remain sticky interface history.
            if (waterCelestialGuidedLeg) pathFlags |= 16u;
            // world.rmiss writes sky radiance (gradient + sun/moon disc + stars) into payload.albedo. The
            // packed show-celestial flag decides whether this path segment may see the bright disc.
            float3 sky = payload.albedo;
            float3 celestialSky = float3(0.0);
#ifdef CAUSTICA_OFFLINE_FP32
            if (bounce > 0) {
                // The miss shader supplied atmosphere/stars only. Add the same active
                // transport light sampled by NEE; never weight the unrelated base sky.
                float lightPdf = celestialDirectionPdf(pc.lightDir.xyz, pc.celestial.xyz, pc.lightDir.w, rd);
                celestialSky = pc.lightRadiance.xyz * lightPdf * celestialEscapeMisWeight(
                        previousCelestialBsdfPdf, lightPdf, previousCelestialDelta);
            }
#endif
            if (bounce == 0) { // primary ray hit sky: guides describe "no surface"
                gv_normal = float3(0.0, 0.0, 0.0);
                // Flat mid-grey albedo guide for sky (NOT the bright sky radiance): demodulating DLSS-RR
                // by the huge sun-disc radiance rings/artifacts around the sun. A constant albedo keeps
                // the brightness in the lighting channel where RR resolves it cleanly.
                gv_albedo = SKY_DIFF_ALBEDO;
                gv_specAlb = SKY_SPEC_ALBEDO;
                gv_reflectionMotionValid = false;
                gv_rough = 1.0;
                gv_hitCamRel = rd * 1.0e6; // sky at infinity: only rotation parallax (-> large far depth)
                gv_motionHitCamRel = gv_hitCamRel;
                gv_motionUseRefracted = false;
                gv_motionObjDisp = float3(0.0, 0.0, 0.0); // sky is static
            }
            L += offlineContribution(throughput * sky, 13u, bounce, pathFlags);
            L += offlineContribution(throughput * celestialSky, 14u, bounce, pathFlags);
            pathProbeEnd(bounce, throughput, rd, float3(0.0), 1.0, 1.0, 6.0);
            break;
        }

        float3 n = payload.normal; // oriented toward the incoming ray by the closest-hit
        float3 hitPos = ro + rd * payload.hitT;
        rayConeWidth = max(rayConeWidth + rayConeSpread * max(payload.hitT, 0.0), RAY_CONE_MIN_WIDTH);
        uint material = payloadMaterial();

        // Stained glass / ice (material 3): a thin colored dielectric. Stochastically reflect (Fresnel
        // glint) or transmit; each crossed interface applies square-root tint, so a paired pane applies
        // its full tint. payload.albedo is the transmission tint (texel rgb mixed toward
        // white by 1 − opacity). Treated as a thin pane, so the transmitted ray continues straight (no
        // refraction bend) — the instance stays double-sided and the normal already faces the incoming ray.
        if (material == MATERIAL_GLASS) {
            previousDelta = true;
            previousBsdfPdf = 0.0;
            float3 glassTint = payload.albedo;
            float cosI = clamp(dot(-rd, n), 0.0, 1.0);
            float3 glassF0 = float3((GLASS_IOR - 1.0) / (GLASS_IOR + 1.0));
            glassF0 *= glassF0;
            float F = fresnelDielectric(cosI, 1.0, GLASS_IOR);
            if (bounce == 0) { // primary glass hit: feed RR a smooth dielectric specular surface
                Payload primaryPayload = payload;
                float3 transmittedAlbedo;
                transmissionGuideHit(hitPos, rd, n, material, inWater, false,
                        sqrt(clamp(glassTint, 0.0, 1.0)), waterExt,
                        rayConeWidth, rayConeSpread,
                        gv_motionHitCamRel, gv_motionObjDisp, gv_motionUseRefracted,
                        transmittedAlbedo);
                payload = primaryPayload;
                gv_normal = n;
                gv_rough = GLASS_GUIDE_ROUGH;
                gv_hitCamRel = hitPos - pc.camOffset;
                gv_albedo = transmittedAlbedo;
                gv_specAlb = rrSpecularAlbedo(
                        glassF0, GLASS_GUIDE_ROUGH * GLASS_GUIDE_ROUGH, cosI);
                gv_reflectionMotionValid = true;
            }
            L += offlineContribution(throughput * sampleRealtimeLightBlockDirect(
                    hitPos, n, -rd, float3(0.0), glassF0, GLASS_GUIDE_ROUGH, true, seed), 8u, bounce, pathFlags);
            if (rndf(seed) < F) {
                previousCelestialDelta = true;
                previousCelestialBsdfPdf = 0.0;
                pathFlags |= 2u;
                probeEventType = 3.0;
                rd = reflect(rd, n);
                ro = hitPos + n * SURF_BIAS;       // reflected ray stays on the incidence side
            } else {
                pathFlags |= 1u;
                probeEventType = 4.0;
                throughput *= sqrt(clamp(glassTint, 0.0, 1.0));
                ro = hitPos - n * GLASS_TRANSMIT_BIAS; // cross to the far side without overshooting a close neighbour
            }
            showCelestial = true;                  // specular interface: the continuation ray may see the disc
            pathProbeEnd(bounce, throughput, rd, n, 1.0, 1.0, probeEventType);
            if (bounce >= rrStart && !waterCelestialGuidedLeg) {
                float q = clamp(max(throughput.r, max(throughput.g, throughput.b)), 0.02, 1.0);
                if (rndf(seed) > q) {
                    pathProbeEnd(bounce, throughput, rd, n, q, 0.0, probeEventType);
                    break;
                }
                throughput /= q;
                pathProbeEnd(bounce, throughput, rd, n, q, 1.0, probeEventType);
            }
            continue;
        }

        // Particles (material == 2): camera-facing receiver billboard. The instance mask keeps particles
        // off secondary rays, so this only fires at bounce 0; they receive direct light and one diffuse
        // path continuation into the scene, but never appear in shadows/reflections/GI or emit radiance.
        if (material == MATERIAL_PARTICLE) {
            float3 albedo = payload.albedo;
            gv_normal = n;
            gv_albedo = albedo; // RR demodulation target = the particle texel (keeps it sharp)
            gv_specAlb = float3(0.0, 0.0, 0.0);
            gv_reflectionMotionValid = false;
            gv_rough = 1.0;
            gv_hitCamRel = hitPos - pc.camOffset;
            gv_motionHitCamRel = gv_hitCamRel;
            gv_motionUseRefracted = false;
            gv_motionObjDisp = payload.motionPrev; // per-particle MV: de-ghost moving particles

            float3 lightDir = pc.lightDir.xyz;
            float lightHalfAngle = pc.lightDir.w;
            if (lightHalfAngle > 0.0) {
                lightDir = sampleSquare(lightDir, lightHalfAngle, seed);
            }
            // Billboards are effectively two-sided receivers. Bias from the side facing the light; shadow
            // rays exclude particles anyway, but this keeps the origin sane when the light is behind the
            // camera side.
            float signedNdl = dot(n, lightDir);
            float ndl = abs(signedNdl);
            if (ndl > 0.0) {
                float3 shadowOrigin = hitPos + (signedNdl >= 0.0 ? n : -n) * SURF_BIAS;
                float3 vis = celestialVisibility(shadowOrigin, lightDir, 10000.0, bounce, rayConeWidth, rayConeSpread);
                if (max(vis.r, max(vis.g, vis.b)) > 0.0) {
                    float misWeight = 1.0;
#ifdef CAUSTICA_OFFLINE_FP32
                    float lightPdf = celestialDirectionPdf(pc.lightDir.xyz, pc.celestial.xyz, pc.lightDir.w, lightDir);
                    // Particle NEE is two-sided, but its cosine continuation samples the front only.
                    float particlePdf = max(0.0, dot(n, lightDir)) * INV_PI;
                    misWeight = celestialDirectMisWeight(lightPdf, particlePdf, bounce < maxBounces);
#endif
                    L += offlineContribution(throughput * albedo * INV_PI * pc.lightRadiance.xyz * ndl * vis * misWeight, 10u, bounce, pathFlags);
                }
            }

            L += offlineContribution(throughput * sampleRealtimeLightBlockParticle(hitPos, n, albedo, seed), 8u, bounce, pathFlags);

            if (bounce >= maxBounces) {
                break;
            }
            throughput *= albedo;
            hasNonDeltaBounce = true;
            ro = hitPos + n * SURF_BIAS;
            rd = cosineDir(n, seed);
            previousStaticLightNeeEligible = false;
            previousDelta = false;
            previousBsdfPdf = max(0.0, dot(n, rd)) * INV_PI;
            previousCelestialDelta = false;
            previousCelestialBsdfPdf = previousBsdfPdf;
            previousReceiverSlot = 0xFFFFFFFFu;
            rayConeSpread = max(rayConeSpread, RAY_CONE_DIFFUSE_SPREAD);
            pathProbeEnd(bounce, throughput, rd, n, 1.0, 1.0, 5.0);
            showCelestial = false; // diffuse receiver: direct sun/moon was handled by NEE above
            continue;
        }

        // Water: smooth dielectric interface. Choose reflection or refraction stochastically by the
        // Fresnel reflectance F — sampling by F leaves the throughput unchanged (lossless interface), so
        // there is no diffuse albedo multiply and no sun NEE here (the surface is specular). On
        // transmission, the new medium is read from this hit's face orientation (payloadWaterEntering),
        // not toggled — see PAYLOAD_WATER_ENTERING. The bounce cap bounds stacked refractions.
        if (material == MATERIAL_WATER) {
            previousCelestialDelta = true;
            previousCelestialBsdfPdf = 0.0;
            previousDelta = true;
            previousBsdfPdf = 0.0;
            float3 geometricNormal = n;
            // Ripple the (near-flat) surface normal before any Fresnel/guide use → glints, broken
            // reflections, and the first-interface RR guide; transmission keeps the geometric normal stable.
            // This water body's biome tint (carried in payload.albedo
            // for water hits) sets the absorption applied to the next submerged segment.
            if (waterWaves) {
                // World-stable wave domain: rebased hit XZ + the pushed anchor (terrain origin mod 4096)
                // reconstructs a world-pinned coordinate that survives the per-move terrain rebase.
                n = applyWaterWaves(n, hitPos.xz + pc.waterAnchor.xy, pc.waterParams.w);
            }
            waterExt = waterExtinction(payload.albedo);
            float cosI = clamp(dot(-rd, n), 0.0, 1.0);
            float3 waterF0 = float3((WATER_IOR - 1.0) / (WATER_IOR + 1.0));
            waterF0 *= waterF0;
            Payload primaryPayload = payload;
            bool waterEntering = payloadWaterEntering();
            if (bounce == 0) { // primary water hit: feed RR a smooth dielectric specular surface
                gv_normal = n;
                gv_rough = WATER_GUIDE_ROUGH;
                gv_hitCamRel = hitPos - pc.camOffset; // depth + reflection start at the water surface
                // Diffuse albedo and ordinary MV track the refracted hit (floor/shore seen through the
                // surface) so refracted content stops ghosting; depth and first-interface specular albedo
                // remain on the animated water surface.
                float3 transmittedAlbedo;
                transmissionGuideHit(hitPos, rd, geometricNormal, material, inWater, waterEntering,
                        float3(1.0), waterExt,
                        rayConeWidth, rayConeSpread,
                        gv_motionHitCamRel, gv_motionObjDisp, gv_motionUseRefracted,
                        transmittedAlbedo);
                payload = primaryPayload;
                gv_albedo = transmittedAlbedo;
                gv_specAlb = rrSpecularAlbedo(
                        waterF0, WATER_GUIDE_ROUGH * WATER_GUIDE_ROUGH, cosI);
                gv_reflectionMotionValid = true;
            }
            // The outward interface orientation owns the incident medium too.
            // A near-boundary origin offset/missed face can leave historical state
            // stale; using it here can turn a required water-side TIR into an exit.
            // Reflection retains this incident state; transmission adopts the far side.
            inWater = !waterEntering;
            float etaI = inWater ? WATER_IOR : 1.0;
            float etaT = inWater ? 1.0 : WATER_IOR;
            float F = fresnelDielectric(cosI, etaI, etaT);
            float3 geometricTransmissionDir = refract(rd, geometricNormal, etaI / etaT);
            if (dot(geometricTransmissionDir, geometricTransmissionDir) <= 0.0) {
                F = 1.0;
            }
            if (rndf(seed) < F) {
                pathFlags |= 8u;
                probeEventType = 1.0;
                rd = reflect(rd, n);
                ro = hitPos + n * SURF_BIAS; // reflected ray stays on the incidence side
            } else {
                pathFlags |= 4u;
                probeEventType = 2.0;
                rd = geometricTransmissionDir;
                ro = hitPos - geometricNormal * SURF_BIAS;       // transmitted ray crosses to the far side
                // Derived from this hit's face orientation, not toggled — self-corrects instead of a
                // stray/missing face corrupting the medium for the rest of the path (see PAYLOAD_WATER_ENTERING).
                inWater = waterEntering;
            }
            // Specular interface (mirror reflect / clear refract): the continuation ray should see the
            // sun/moon disc directly — no NEE happened here to double-count it.
            showCelestial = true;
            pathProbeEnd(bounce, throughput, rd, n, 1.0, 1.0, probeEventType);
            if (bounce >= rrStart && !waterCelestialGuidedLeg) {
                float q = clamp(max(throughput.r, max(throughput.g, throughput.b)), 0.02, 1.0);
                if (rndf(seed) > q) {
                    pathProbeEnd(bounce, throughput, rd, n, q, 0.0, probeEventType);
                    break;
                }
                throughput /= q;
                pathProbeEnd(bounce, throughput, rd, n, q, 1.0, probeEventType);
            }
            continue;
        }

        float3 albedo = payload.albedo;
        float sss = payloadSss(); // LabPBR SSS strength (0 when absent)
        float3 p = hitPos + n * SURF_BIAS;
        float3 v = -rd; // view direction (toward the camera / incoming ray)

        // Material split. Metals tint F0 by albedo and have no diffuse lobe; dielectrics use a fixed
        // 0.04 F0. With PBR disabled this collapses to the Lambertian fallback.
        float rough = pbr ? clamp(payloadRoughness(), MIN_ROUGH, 1.0) : 1.0;
#ifdef CAUSTICA_OFFLINE_FP32
        rough = regularizedPathRoughness(rough, hasNonDeltaBounce, (pc.flags >> 7u) & 3u);
#endif
        float metal = pbr ? clamp(payloadMetalness(), 0.0, 1.0) : 0.0;
        float3 diffAlb = albedo * (1.0 - metal);
        // F0 comes from the chit: dielectric 0.04, a LabPBR custom/metal F0, or albedo for metals.
        float3 F0 = pbr ? payload.f0 : lerp(float3(0.04, 0.04, 0.04), albedo, metal);

        if (bounce == 0) { // primary-visibility surface: capture the denoiser guide buffers
            gv_normal = n;
            gv_albedo = pbr ? diffAlb : albedo;  // RR diffuse-albedo demodulation target
            gv_rough = rough;
            gv_specAlb = pbr ? rrSpecularAlbedo(F0, rough * rough, dot(n, v)) : float3(0.0, 0.0, 0.0);
            gv_reflectionMotionValid = max(gv_specAlb.r, max(gv_specAlb.g, gv_specAlb.b)) > 0.001;
            gv_hitCamRel = ro + rd * payload.hitT - pc.camOffset; // camera-relative hit position
            gv_motionHitCamRel = gv_hitCamRel;
            gv_motionUseRefracted = false;
            gv_motionObjDisp = payload.motionPrev; // per-vertex world motion (0 for static terrain/sky)
        }

        // Emissive surfaces stay visible to camera/specular paths. For a registered static area light
        // reached by an ordinary BSDF sample, use the reciprocal MIS weight of the direct-light sample.
        float emission = payloadEmission();
        uint staticLightIndex = payloadStaticLightIndex();
        if (emission > 0.0) {
            float emissionWeight = 1.0;
            if (!previousDelta && previousStaticLightNeeEligible
                    && staticLightIndex != 0xFFFFFFFFu && (pc.flags & 32u) != 0u) {
                float lightPdf = staticAreaLightPdf(
                        staticLightIndex, payload.hitT, rd, previousReceiverSlot);
                emissionWeight = powerHeuristic(previousBsdfPdf, lightPdf);
            }
            L += offlineContribution(throughput * albedo * emission * EMISSIVE_STRENGTH * emissionWeight, 9u, bounce, pathFlags);
        }

        float3 waterGuideNormal;
        bool waterGuideReflection;
        float waterGuideMix = offlineInterfaceGuide(p, n, inWater, bounce, maxBounces,
                rayConeWidth, rayConeSpread, waterGuideNormal, waterGuideReflection);
        L += offlineContribution(throughput * sampleStaticDirect(
                p, n, v, diffAlb, F0, rough, pbr, payloadSectionSlot(), waterGuideMix, waterGuideNormal, waterGuideReflection, seed), 8u, bounce, pathFlags);
        L += offlineContribution(throughput * sampleRealtimeLightBlockDirect(
                p, n, v, diffAlb, F0, rough, pbr, seed), 8u, bounce, pathFlags);

        // NEE: direct light from the dominant celestial body (sun by day, moon by night) — Lambert
        // diffuse + GGX specular, one shadow ray. Jitter the light direction within its square angular
        // extent (pc.lightDir.w half-angle) so the shadow ray samples the light's quad — soft penumbrae
        // over accumulation. The same sampled direction drives ndl, the shadow ray, and the specular
        // half-vector.
        float3 lightDir = pc.lightDir.xyz;
        float lightHalfAngle = pc.lightDir.w;
        if (lightHalfAngle > 0.0) {
            lightDir = sampleSquare(lightDir, lightHalfAngle, seed);
        }
        float ndl = max(0.0, dot(n, lightDir));
        if (ndl > 0.0) {
            float3 vis = celestialVisibility(p, lightDir, 10000.0, bounce, rayConeWidth, rayConeSpread);
            // Underwater receiver whose shadow ray crossed a water surface: scale the direct light by
            // the wave-refraction caustic at the exit point. Focusing scales the incident irradiance,
            // so it applies to the whole NEE term (diffuse + specular).
#ifndef CAUSTICA_OFFLINE_FP32
            if (inWater && waterWaves && shadowVis.a > 0.0) {
                vis *= waterCaustic(p + lightDir * shadowVis.a, lightDir, shadowVis.a);
            }
#endif
            if (max(vis.r, max(vis.g, vis.b)) > 0.0) {
                float3 brdf = evaluateSurfaceBrdf(n, v, lightDir, diffAlb, F0, rough, pbr);
                float misWeight = 1.0;
#ifdef CAUSTICA_OFFLINE_FP32
                float lightPdf = celestialDirectionPdf(pc.lightDir.xyz, pc.celestial.xyz, pc.lightDir.w, lightDir);
                float bsdfPdf = surfaceContinuationPdf(n, v, lightDir, diffAlb, F0, rough, pbr, waterGuideMix, waterGuideNormal, waterGuideReflection);
                misWeight = celestialDirectMisWeight(lightPdf, bsdfPdf, bounce < maxBounces);
#endif
                L += offlineContribution(throughput * brdf * pc.lightRadiance.xyz * ndl * vis * misWeight, 10u, bounce, pathFlags);
            }
        }

        // Thin-surface SSS transmission. Light entering from the back face scatters through toward the
        // viewer via a forward-biased HG phase (leaves/grass backlit by the sun glow when you look
        // through them toward the light source). Shadow ray fires from the back face to avoid
        // self-occlusion. cosT = dot(lightDir, rd): rd tracks the ray toward the sun when the sun is
        // behind the slab, giving cosT ≈ 1 → forward-scatter peak.
        if (sss > 0.0 && bounce <= MAX_SSS_BOUNCE) {
            float backNdl = max(0.0, dot(-n, lightDir));
            if (backNdl > 0.0) {
                float3 visB = celestialVisibility(hitPos - n * SURF_BIAS, lightDir, 10000.0, bounce, rayConeWidth, rayConeSpread);
                // Same caustic as the front-face NEE — underwater kelp/seagrass transmission should
                // flicker with the same light bands as the floor around it.
#ifndef CAUSTICA_OFFLINE_FP32
                if (inWater && waterWaves && shadowVis.a > 0.0) {
                    visB *= waterCaustic(hitPos + lightDir * shadowVis.a, lightDir, shadowVis.a);
                }
#endif
                if (max(visB.r, max(visB.g, visB.b)) > 0.0) {
                    float cosT = dot(lightDir, rd);
                    L += offlineContribution(throughput * diffAlb * sss * SSS_STRENGTH * hg(cosT, SSS_G) * backNdl * pc.lightRadiance.xyz * visB, 10u, bounce, pathFlags);
                }
            }
        }

        // The offline proposal aims through the pilot-selected water reflection/exit at the sun.
        // It is mixed with the entire original BSDF distribution, retaining all old path support.
        bool chooseWaterGuide = false;
#ifdef CAUSTICA_OFFLINE_FP32
        if (waterGuideMix > 0.0) chooseWaterGuide = rndf(seed) < waterGuideMix;
#endif
        float3 nextDir;
        float sampledWaterGuidePdf = 0.0;
        if (chooseWaterGuide) {
            float guideHalfAngle = waterCelestialGuideHalfAngle(pc.lightDir.w);
            float3 guidedAirDir = sampleSquare(pc.lightDir.xyz, guideHalfAngle, seed);
            nextDir = interfaceCelestialDirection(guidedAirDir, waterGuideNormal, WATER_IOR, waterGuideReflection);
            sampledWaterGuidePdf = interfaceCelestialSamplePdf(pc.lightDir.xyz, pc.celestial.xyz,
                    pc.lightDir.w, guidedAirDir, nextDir, waterGuideNormal, WATER_IOR, waterGuideReflection);
            // Null samples at the solar horizon or below the receiver are not resampled.
            if (!(dot(n, nextDir) > 0.0)) break;
            bool guidedGlossyCone = false;
            if (pbr) {
                float glossyChance = surfaceSpecularPosterior(n, v, nextDir, diffAlb, F0, rough);
                guidedGlossyCone = rndf(seed) < glossyChance;
            }
            float guidedSpread = guidedGlossyCone
                    ? rough * rough * RAY_CONE_GLOSSY_SPREAD_SCALE : RAY_CONE_DIFFUSE_SPREAD;
            rayConeSpread = max(rayConeSpread, guidedSpread);
            showCelestial = true;
        } else if (pbr) {
            float ps = surfaceSpecularProbability(n, v, diffAlb, F0);
            if (rndf(seed) < ps) {
                float3 h = sampleGGXVNDF(n, v, rough, seed);
                float3 l = reflect(rd, h); // rd = -v: reflect the incoming ray about the microfacet normal
                float ndl2 = dot(n, l);
                if (ndl2 <= 0.0) {
                    break; // microfacet reflects below the surface: terminate this path
                }
                nextDir = l;
                rayConeSpread = max(rayConeSpread, rough * rough * RAY_CONE_GLOSSY_SPREAD_SCALE);
                showCelestial = true; // specular lobe: this ray is a (glossy) mirror — show the disc
            } else {
                nextDir = cosineDir(n, seed);
                rayConeSpread = max(rayConeSpread, RAY_CONE_DIFFUSE_SPREAD);
                showCelestial = false; // diffuse lobe: disc covered by NEE, hide it (anti-firefly)
            }
        } else {
            showCelestial = false; // diffuse bounce: hide the disc (covered by NEE)
            nextDir = cosineDir(n, seed);
            rayConeSpread = max(rayConeSpread, RAY_CONE_DIFFUSE_SPREAD);
        }
        float nextGuidePdf = 0.0;
#ifdef CAUSTICA_OFFLINE_FP32
        if (waterGuideMix > 0.0) {
            nextGuidePdf = interfaceCelestialPdf(pc.lightDir.xyz, pc.celestial.xyz,
                    pc.lightDir.w, nextDir, waterGuideNormal, WATER_IOR, waterGuideReflection);
        }
#endif
        waterCelestialGuidedLeg = waterCelestialProtectLeg(chooseWaterGuide, waterGuideMix, nextGuidePdf);
        previousBsdfPdf = surfaceContinuationPdf(n, v, nextDir, diffAlb, F0, rough, pbr, waterGuideMix, waterGuideNormal, waterGuideReflection);
        if (chooseWaterGuide) {
            // Retain the generated sample's density across the FP32 Snell round trip.
            previousBsdfPdf = waterCelestialMixturePdf(
                    surfaceBsdfPdf(n, v, nextDir, diffAlb, F0, rough, pbr), sampledWaterGuidePdf, waterGuideMix);
        }
        if (!(previousBsdfPdf > 0.0)) break;
        if (!pbr && !(waterGuideMix > 0.0)) {
            throughput *= albedo; // Preserve the old Lambertian cancellation when guiding is off.
        } else {
            throughput *= evaluateSurfaceBrdf(n, v, nextDir, diffAlb, F0, rough, pbr)
                    * max(0.0, dot(n, nextDir)) / previousBsdfPdf;
        }
        ro = p;
        rd = nextDir;
        // All ordinary lobes have finite roughness. Ideal water/glass branches
        // preserve this state; the first ordinary surface stays unregularized.
        hasNonDeltaBounce = true;
        previousReceiverSlot = payloadSectionSlot();
        previousStaticLightNeeEligible = (pc.flags & 32u) != 0u
                && pc.staticLightCount > 0u && pc.staticLightTotalWeight > 0.0;
        previousDelta = false;
        previousCelestialDelta = false;
        previousCelestialBsdfPdf = previousBsdfPdf;

        // Russian roulette on deeper bounces: survive with prob = max channel, rescale survivors.
        pathProbeEnd(bounce, throughput, rd, n, 1.0, 1.0, probeEventType);
            if (bounce >= rrStart && !waterCelestialGuidedLeg) {
            float q = clamp(max(throughput.r, max(throughput.g, throughput.b)), 0.02, 1.0);
            if (rndf(seed) > q) {
                    pathProbeEnd(bounce, throughput, rd, n, q, 0.0, probeEventType);
                break;
            }
            throughput /= q;
                pathProbeEnd(bounce, throughput, rd, n, q, 1.0, probeEventType);
        }
    }
    return L;
}

struct PathProbeGuides {
    float3 normal;
    float3 albedo;
    float3 specAlb;
    bool reflectionMotionValid;
    float rough;
    float depth;
    float3 hitCamRel;
    float3 motionHitCamRel;
    bool motionUseRefracted;
    float3 motionObjDisp;
    void restore() {
        gv_normal = normal;
        gv_albedo = albedo;
        gv_specAlb = specAlb;
        gv_reflectionMotionValid = reflectionMotionValid;
        gv_rough = rough;
        gv_depth = depth;
        gv_hitCamRel = hitCamRel;
        gv_motionHitCamRel = motionHitCamRel;
        gv_motionUseRefracted = motionUseRefracted;
        gv_motionObjDisp = motionObjDisp;
    }
};

void replayPathProbe(float3 origin, float3 direction, float spread, uint initialSeed, int2 pix, uint64_t sampleIndex) {
#ifdef CAUSTICA_OFFLINE_FP32
    if (pc.pathProbeAddr == 0 || !(probePeak >= pc.pathProbeThreshold)) return;
    ProbePtr<uint> header = ProbePtr<uint>(pc.pathProbeAddr);
    uint index;
    InterlockedAdd(header[0], 1u, index);
    if (index >= min(header[1], 32u)) return;
    probeRecordAddr = pc.pathProbeAddr + uint64_t(16) + uint64_t(index) * uint64_t(5344);
    ProbePtr<PathProbeRecord> record = ProbePtr<PathProbeRecord>(probeRecordAddr);
    record[0].pixel_sample = uint4(uint2(pix), uint(sampleIndex), uint(sampleIndex >> 32));
    record[0].source = uint4(probeEvent, (probeEvent.z & 16u) != 0u ? 1u : 0u);
    record[0].peak_rgb = float4(probePeak, probeSource);
    record[0].state = uint4(0u, initialSeed, 1u, 0u);
    PathProbeGuides savedGuides;
    savedGuides.normal = gv_normal;
    savedGuides.albedo = gv_albedo;
    savedGuides.specAlb = gv_specAlb;
    savedGuides.reflectionMotionValid = gv_reflectionMotionValid;
    savedGuides.rough = gv_rough;
    savedGuides.depth = gv_depth;
    savedGuides.hitCamRel = gv_hitCamRel;
    savedGuides.motionHitCamRel = gv_motionHitCamRel;
    savedGuides.motionUseRefracted = gv_motionUseRefracted;
    savedGuides.motionObjDisp = gv_motionObjDisp;
    uint replaySeed = initialSeed;
    tracePath(origin, direction, spread, replaySeed);
    savedGuides.restore();
    record[0].state.w = 1u;
    probeRecordAddr = 0;
#endif
}

#ifdef CAUSTICA_OFFLINE_FP32
[shader("raygeneration")]
void main() {
    pc = ConstPtr<WorldPush>(pcAddr.worldPushAddr)[0];
    int2 pix = int2(DispatchRaysIndex().xy);
    float2 size = float2(DispatchRaysDimensions().xy);

    float2 jndc = float2(0.0, 0.0);
    float3 origin = float3(0.0, 0.0, 0.0);
    float3 dir = float3(0.0, 0.0, 1.0);
    float rayConeSpread = RAY_CONE_MIN_SPREAD;
    uint spp = max(pc.spp, 1u);
    float3 frameRadiance = float3(0.0, 0.0, 0.0);
    uint pixelHash = offlineHash32(
            uint(pix.x) * 0x8da6b343u ^ uint(pix.y) * 0xd8163841u ^ 0xcb1ab31fu);

    for (uint s = 0u; s < spp; s++) {
        uint64_t globalSampleIndex = pc.offlineSampleBase + uint64_t(s);
        float2 subpixel = offlineR2Sample(pixelHash, globalSampleIndex);
        float2 sampleUv = (float2(pix) + subpixel) / size;
        jndc = sampleUv * 2.0 - 1.0;

        float4 nearH = mul(pc.invViewProj, float4(jndc.x, jndc.y, 1.0, 1.0));
        float4 farH = mul(pc.invViewProj, float4(jndc.x, jndc.y, 0.0, 1.0));
        float3 nearP = nearH.xyz / nearH.w;
        float3 farP = farH.xyz / farH.w;
        origin = nearP + pc.camOffset;
        dir = normalize(farP - nearP);
        rayConeSpread = primaryRayConeSpread(jndc, size, dir);

        // The last sample supplies finite representative guides to offline display denoising.
        gv_normal = float3(0.0, 0.0, 0.0);
        gv_albedo = SKY_DIFF_ALBEDO;
        gv_specAlb = SKY_SPEC_ALBEDO;
        gv_reflectionMotionValid = false;
        gv_rough = 1.0;
        gv_hitCamRel = dir * 1.0e6;
        gv_motionHitCamRel = gv_hitCamRel;
        gv_motionUseRefracted = false;
        gv_motionObjDisp = float3(0.0, 0.0, 0.0);

        uint seed = offlinePathSeed(pixelHash, globalSampleIndex);
        uint initialSeed = seed;
        probeRecordAddr = 0;
        probePeak = 0.0;
        probeSource = float3(0.0);
        probeEvent = uint3(0u);
        frameRadiance += tracePath(origin, dir, rayConeSpread, seed);
        replayPathProbe(origin, dir, rayConeSpread, initialSeed, pix, globalSampleIndex);
    }
    frameRadiance = sanitizeRadiance(frameRadiance / float(spp));

    float4 curClip = mul(pc.curViewProj, float4(gv_hitCamRel, 1.0));
    gv_depth = curClip.w > 0.0 ? curClip.z / curClip.w : 0.0;
    gNormal[pix] = float4(gv_normal, gv_rough);
    gAlbedo[pix] = float4(gv_albedo, 1.0);
    gDepth[pix] = gv_depth;
    gSpecAlbedo[pix] = float4(gv_specAlb, 1.0);

    float4 prevClip = mul(pc.prevViewProj,
            float4(gv_motionHitCamRel + pc.camDelta - gv_motionObjDisp, 1.0));
    float2 prevNdc = prevClip.xy / prevClip.w;
    float2 curNdc = jndc;
    if (gv_motionUseRefracted) {
        float4 curClipRefr = mul(pc.curViewProj, float4(gv_motionHitCamRel, 1.0));
        curNdc = curClipRefr.xy / curClipRefr.w;
    }
    float2 motion = (prevNdc - curNdc) * 0.5 * size;
    gMotion[pix] = motion;
    float2 specMotion = specularReflectionMotion(
            gv_hitCamRel + pc.camOffset, dir, jndc, size, rayConeSpread);
    gSpecMotion[pix] = specMotion;

    if (pc.debugView >= 1u && pc.debugView <= 7u) {
        float3 dbg;
        if (pc.debugView == 1u) {
            dbg = gv_normal * 0.5 + 0.5;
        } else if (pc.debugView == 2u) {
            dbg = gv_albedo;
        } else if (pc.debugView == 3u) {
            dbg = float3(gv_depth, gv_depth, gv_depth);
        } else if (pc.debugView == 4u) {
            dbg = float3(gv_rough, gv_rough, gv_rough);
        } else if (pc.debugView == 6u) {
            dbg = gv_specAlb;
        } else if (pc.debugView == 7u) {
            dbg = float3(clamp(0.5 + specMotion * 0.05, 0.0, 1.0), 0.5);
        } else {
            dbg = float3(clamp(0.5 + motion * 0.05, 0.0, 1.0), 0.5);
        }
        outImage[pix] = float4(dbg, 1.0);
        return;
    }

    outImage[pix] = float4(frameRadiance, 1.0);
}
#else
[shader("raygeneration")]
void main() {
    pc = ConstPtr<WorldPush>(pcAddr.worldPushAddr)[0]; // load the per-frame push data from the BDA buffer
    int2 pix = int2(DispatchRaysIndex().xy);
    float2 size = float2(DispatchRaysDimensions().xy);
    float2 uv = (float2(pix) + 0.5) / size;
    float2 ndc = uv * 2.0 - 1.0; // unjittered pixel centre — the motion vector reprojects this

    // Offset the primary ray within the pixel by the sub-pixel jitter reported to DLSS-RR, so
    // successive frames sample different positions and RR can resolve detail above render resolution.
    // The guide buffers below come from this jittered first hit (they must match the jittered colour);
    // only the motion vector stays on the unjittered centre, which DLSS expects.
    float2 jndc = (uv + pc.jitter / size) * 2.0 - 1.0;

    float4 nearH = mul(pc.invViewProj, float4(jndc.x, jndc.y, 1.0, 1.0));
    float4 farH = mul(pc.invViewProj, float4(jndc.x, jndc.y, 0.0, 1.0));
    float3 nearP = nearH.xyz / nearH.w;
    float3 farP = farH.xyz / farH.w;

    float3 origin = nearP + pc.camOffset;
    float3 dir = normalize(farP - nearP);
    float rayConeSpread = primaryRayConeSpread(jndc, size, dir);

    uint seed = (uint(pix.x) * 1973u + uint(pix.y) * 9277u + 26699u) ^ (pc.frameIndex * 2654435761u);

    uint spp = max(pc.spp, 1u);
    float3 frameRadiance = float3(0.0, 0.0, 0.0);
    for (uint s = 0u; s < spp; s++) {
        seed = pcg(seed); // decorrelate per-sample paths (shared camera ray, no AA jitter yet)
        frameRadiance += tracePath(origin, dir, rayConeSpread, seed);
    }
    frameRadiance /= float(spp);
    frameRadiance = sanitizeRadiance(frameRadiance);

    // Hardware (non-linear, reversed-Z) depth for DLSS-RR + Frame Generation: project the camera-relative
    // primary hit through the forward view-projection and take ndc z/w — exactly the value a rasterizer
    // would write. Reversed-Z (near=1, far=0), so DLSS gets the DepthInverted flag; sky's far hit -> ~0.
    // Depth follows the primary surface (water included); only the MV tracks the refracted hit.
    float4 curClip = mul(pc.curViewProj, float4(gv_hitCamRel, 1.0));
    gv_depth = curClip.w > 0.0 ? curClip.z / curClip.w : 0.0;

    // Guide buffers: first-hit attributes for the denoiser / DLSS-RR (written every frame).
    gNormal[pix] = float4(gv_normal, gv_rough);
    gAlbedo[pix] = float4(gv_albedo, 1.0);
    gDepth[pix] = gv_depth;
    gSpecAlbedo[pix] = float4(gv_specAlb, 1.0); // specular albedo for RR demodulation

    // Motion vector: reproject this guide point through the previous frame's view-projection.
    // The primary ray was cast through the JITTERED ndc (jndc), so this hit's current screen position is
    // jndc, NOT the pixel centre. Subtract jndc so the MV is jitter-free (= 0 when static), which is
    // what DLSS expects with MVJittered unset. Scaled from NDC into render-pixel space.
    // For a dynamic surface, previous-frame position is the current point minus its world-space
    // displacement; subtracting gv_motionObjDisp de-cameras the MV.
    float4 prevClip = mul(pc.prevViewProj, float4(gv_motionHitCamRel + pc.camDelta - gv_motionObjDisp, 1.0));
    float2 prevNdc = prevClip.xy / prevClip.w;
    float2 curNdc = jndc; // primary hit's current screen position is exactly the jittered ray ndc
    // Water MV guide: track the one-refraction hit (the floor seen through the surface), not the water
    // surface, so refracted content stops ghosting. That hit is its own feature: its screen motion is
    // its own reprojection delta (prev - current projection) — bit-exact zero when static, no Snell
    // solve needed. The constant per-frame refraction offset cancels out of prev - current.
    if (gv_motionUseRefracted) {
        float4 curClipRefr = mul(pc.curViewProj, float4(gv_motionHitCamRel, 1.0));
        curNdc = curClipRefr.xy / curClipRefr.w;
    }
    float2 motion = (prevNdc - curNdc) * 0.5 * size;
    gMotion[pix] = motion;
    float2 specMotion = specularReflectionMotion(gv_hitCamRel + pc.camOffset, dir, jndc, size, rayConeSpread);
    gSpecMotion[pix] = specMotion;

    // Debug guide-buffer visualization: bypass accumulation and show a guide directly.
    if (pc.debugView >= 1u && pc.debugView <= 7u) {
        float3 dbg;
        if (pc.debugView == 1u) {
            dbg = gv_normal * 0.5 + 0.5;            // world normal -> [0,1]
        } else if (pc.debugView == 2u) {
            dbg = gv_albedo;                        // diffuse albedo
        } else if (pc.debugView == 3u) {
            dbg = float3(gv_depth, gv_depth, gv_depth); // HW reversed-Z depth (near=white, far/sky=black)
        } else if (pc.debugView == 4u) {
            dbg = float3(gv_rough, gv_rough, gv_rough); // roughness
        } else if (pc.debugView == 6u) {
            dbg = gv_specAlb;                       // specular albedo
        } else if (pc.debugView == 7u) {
            dbg = float3(clamp(0.5 + specMotion * 0.05, 0.0, 1.0), 0.5); // reflection motion
        } else {
            dbg = float3(clamp(0.5 + motion * 0.05, 0.0, 1.0), 0.5); // motion: red=+x, green=+y
        }
        outImage[pix] = float4(dbg, 1.0);
        return;
    }

    // Single noisy estimate; the denoiser (DLSS-RR) handles temporal convergence.
    outImage[pix] = float4(frameRadiance, 1.0);
}
#endif
