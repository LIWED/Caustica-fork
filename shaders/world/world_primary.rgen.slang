// Primary/guide pass (pass A of the wavefront split — see docs/WAVEFRONT_PLAN.md).
//
// Traces one camera radiance ray, captures DLSS-RR guides, and writes one or two resumable
// continuations per pixel. At the first eligible dielectric it queues both post-interface branches and
// stops; every later radiance trace belongs to Pass B. Deterministic guide probes may continue through
// refraction, but Pass A does no NEE, RIS, SSS, or BSDF sampling.
//
// Perspective setup: invViewProj = inverse(proj * viewRot) maps clip to camera-relative world. Primary
// rays are reconstructed from two unprojected points (near and far plane) rather than assuming the eye
// is at the origin, because Minecraft bakes view bobbing into the projection, so the effective eye comes
// from the matrix. camOffset shifts camera-relative space into the terrain's rebased coordinates. Depth
// is reversed-Z (near=1, far=0).
//
// Pass A deliberately uses ordinary TraceRay. Its short, visually coherent direct/interface walk is
// latency-sensitive and does not amortize an SER reorder barrier.
import world_common;
import world_core;
import math;
import medium;
import segment;
import water;
import trace;
import water_volume;
import air_volume;
import cloud_volume;
import guides;

public PathSegment tracePrimary(PathSegment seg,
                                DevicePtr<PackedPathSegment> queue,
                                uint splitRecord,
                                uint pixelIndex,
                                out uint nextRecord,
                                out float3 prefixRadiance) {
    float3 ro = seg.ro;
    float3 rd = seg.rd;
    float3 throughput = seg.throughput;
    MediumStack medium = seg.medium;
    float rayConeWidth = seg.rayConeWidth;
    float rayConeSpread = max(seg.rayConeSpread, RAY_CONE_MIN_SPREAD);
    uint seed = seg.seed;
    bool showCelestial = seg.showCelestial;
    bool waterWaves = (worldPush.flags & 16u) != 0u;
    float waterWaveStrength = waterWaves ? clamp(worldPush.waterTuning.x, 0.0, 2.0) : 0.0;
    bool waterFog = (worldPush.flags & 32u) != 0u;
    float waterFogStrength = clamp(worldPush.waterAnchor.w, 0.0, 2.0);
    nextRecord = PATH_NO_NEXT;
    prefixRadiance = float3(0.0, 0.0, 0.0);

    {
        int bounce = seg.bounce;
        PathSegment terminal = makePathSegment(ro, rd, throughput, medium,
                                               rayConeWidth, rayConeSpread, seed, bounce,
                                               showCelestial);
        traceRadiance(CULL_PRIMARY, ro, 0.0, rd, 10000.0,
                      showCelestial, rayConeWidth, rayConeSpread);

        float segmentDistance = payload.hitT < 0.0 ? 10000.0 : max(payload.hitT, 0.0);
        if (mediumIsAir(medium.current)) {
            uint airSeed = seed ^ pixelIndex * 2246822519u ^ uint(bounce) * 3266489917u
                    ^ worldPush.frameIndex * 668265263u;
            AirVolumeResult air = integrateAirVolume(ro, rd, segmentDistance, true, airSeed);
            prefixRadiance += throughput * air.radiance;
            throughput *= air.transmittance;
            terminal.throughput = throughput;
        }

        // A miss already composites clouds over the sky. For a terrain hit, the same
        // cloud segment must be composited before the surface when viewed from above.
        if (payload.hitT >= 0.0 && mediumIsAir(medium.current)
                && (worldPush.flags & (1u << 9u)) != 0u) {
            float rain = clamp(worldPush.weather.x, 0.0, 1.0);
            float thunder = clamp(worldPush.weather.y, 0.0, 1.0);
            float direct = clamp(1.0 - rain * 0.72 - thunder * 0.18, 0.10, 1.0);
            float lightning = thunder * smoothstep(0.78, 1.0, worldPush.weather.z);
            float weatherSky = clamp(direct + lightning * (1.0 - direct) * 0.80, 0.10, 1.0);
            VolumeCloudResult cloud = integrateVolumetricCloud(
                    worldPush, ro, rd, payload.hitT, weatherSky);
            prefixRadiance += throughput * cloud.radiance;
            throughput *= cloud.transmittance;
            terminal.throughput = throughput;
        }

        if (payload.hitT < 0.0) {
            if (bounce == 0) {
                gv_normal = float3(0.0, 0.0, 0.0);
                gv_albedo = SKY_DIFF_ALBEDO;
                gv_rough = 1.0;
                gv_hitCamRel = rd * 1.0e6;
                gv_motionUseRefracted = false;
                gv_motionObjDisp = float3(0.0, 0.0, 0.0);
                gv_spec = makeSpecSurface(gv_hitCamRel, gv_normal, 1.0, SKY_SPEC_ALBEDO);
            }
            return terminal;
        }

        float3 n = payload.normal;
        float3 hitPos = ro + rd * payload.hitT;
        uint material = payloadMaterial();
        if (material != MATERIAL_WATER && material != MATERIAL_DIELECTRIC) {
            float rough = material == MATERIAL_PARTICLE
                    ? 1.0 : clamp(payloadRoughness(), 0.0, 1.0);
            bool exactSpecular = material == MATERIAL_OPAQUE && isDeltaAlpha(rough);
            rough = exactSpecular ? 0.0 : rough;
            float metal = material == MATERIAL_PARTICLE
                    ? 0.0 : clamp(payloadMetalness(), 0.0, 1.0);
            float3 diffAlb = material == MATERIAL_PARTICLE
                    ? float3(payload.albedo) : float3(payload.albedo) * (1.0 - metal);
            if (bounce == 0) {
                gv_normal = n;
                gv_hitCamRel = hitPos - worldPush.camOffset;
                gv_motionUseRefracted = false;
                gv_motionObjDisp = payload.motionPrev;
                if (material == MATERIAL_PARTICLE) {
                    gv_albedo = payload.albedo;
                    gv_rough = 1.0;
                    gv_spec = makeSpecSurface(gv_hitCamRel, n, 1.0,
                                              float3(0.0, 0.0, 0.0));
                } else {
                    float3 v = -rd;
                    gv_albedo = diffAlb;
                    gv_rough = rough;
                    gv_spec = makeSpecSurface(gv_hitCamRel, n, float3(payload.motionPrev), rough,
                                              rrSpecularAlbedo(payload.f0, rough, dot(n, v)));
                }
            }

            return terminal;
        }

        // This hit is consumed in pass A, so carry its travelled-medium absorption and cone growth into
        // the record for the next trace. The terminal hit above is deliberately not consumed here.
        if (any(medium.current.extinction > 0.0)) {
            float3 effectiveExtinction = waterEffectiveExtinction(
                    medium.current.extinction, medium.current.water, worldPush.waterTuning.y);
            float3 segmentTransmittance = exp(-effectiveExtinction * payload.hitT);
            if (medium.current.water && waterFog && waterFogStrength > 0.0) {
                float3 rawLightDirForWater = worldPush.lightDir.xyz;
                float lightDirLengthSq = dot(rawLightDirForWater, rawLightDirForWater);
                float3 lightDirForWater = rawLightDirForWater * rsqrt(max(lightDirLengthSq, 1.0e-8));
                prefixRadiance += throughput * integrateWaterSingleScatter(
                        ro, rd, payload.hitT, medium.current.extinction, effectiveExtinction, segmentTransmittance,
                        worldPush.lightRadiance.xyz, lightDirForWater, waterFogStrength, seed);
            }
            throughput *= segmentTransmittance;
        }
        rayConeWidth = max(rayConeWidth + rayConeSpread * max(payload.hitT, 0.0),
                           RAY_CONE_MIN_WIDTH);

        bool isWater = material == MATERIAL_WATER;
        bool entering = payloadDielectricEntering();
        float3 geometricNormal = n;
        float3 previousNormal = n;
        float2 waterDomain = hitPos.xz + worldPush.waterAnchor.xy;
        float waterFootprint = rayConeWidth / max(abs(dot(-rd, geometricNormal)), 0.2);
        float3 refractionNormal = n;
        float3 previousRefractionNormal = n;
        if (isWater) {
            if (bounce == 0 && abs(geometricNormal.y) >= 0.5) {
                float2 currentGrad;
                float2 previousGrad;
                waterSurfaceGradTemporal(waterDomain, worldPush.waterParams.w,
                        worldPush.waterAnchor.z, waterFootprint, waterWaveStrength,
                        currentGrad, previousGrad);
                n = waterNormalFromGrad(geometricNormal, currentGrad);
                previousNormal = waterNormalFromGrad(geometricNormal, previousGrad);
            } else {
                n = applyWaterWaves(geometricNormal, waterDomain,
                        worldPush.waterParams.w, waterFootprint, waterWaveStrength);
                previousNormal = n;
            }
            float2 currentRefractionGrad;
            float2 previousRefractionGrad;
            waterRefractionGradTemporal(waterDomain, worldPush.waterParams.w,
                    worldPush.waterAnchor.z, waterFootprint, waterWaveStrength,
                    currentRefractionGrad, previousRefractionGrad);
            refractionNormal = waterRefractionNormal(geometricNormal, currentRefractionGrad);
            previousRefractionNormal = waterRefractionNormal(
                    geometricNormal, previousRefractionGrad);
        }

        float transmission = clamp(payloadTransmission(), 0.0, 1.0);
        Medium entered = makeDielectricMedium(isWater, max(payloadIor(), 1.0),
                                              payload.albedo, transmission);
        float etaI = medium.current.ior;
        float etaT = entering ? entered.ior : medium.outer.ior;
        float F = fresnelDielectric(clamp(dot(-rd, n), 0.0, 1.0), etaI, etaT);
        float3 transmittedDir = refract(rd, refractionNormal, etaI / etaT);
        float3 previousTransmittedDir = refract(
                rd, previousRefractionNormal, etaI / etaT);
        if (dot(transmittedDir, transmittedDir) <= 0.0) {
            F = 1.0;
        }
        float transmitBias = isWater ? SURF_BIAS : INSET_TRANSMIT_BIAS;

        if (bounce == 0) {
            gv_normal = n;
            gv_rough = 0.0;
            gv_albedo = float3(0.0, 0.0, 0.0);
            gv_hitCamRel = hitPos - worldPush.camOffset;
            gv_motionUseRefracted = false;
            gv_motionObjDisp = isWater ? float3(0.0, 0.0, 0.0) : payload.motionPrev;
            gv_spec = makeSpecSurface(gv_hitCamRel, n, previousNormal, geometricNormal,
                                      isWater ? float3(0.0, 0.0, 0.0) : float3(payload.motionPrev),
                                      gv_rough, float3(F, F, F));
            if (dot(transmittedDir, transmittedDir) > 0.0) {
                MediumStack guideMedium = medium;
                if (entering) {
                    mediumPush(guideMedium, entered);
                } else {
                    mediumPop(guideMedium);
                }
                resolveTransmissionGuide(hitPos, transmittedDir, previousTransmittedDir, geometricNormal,
                        guideMedium, transmitBias, rayConeWidth, rayConeSpread,
                        float3(1.0, 1.0, 1.0));
            }
        }

        // Split once, write both post-interface continuations, and stop Pass A radiance traversal.
        // Pass B owns every radiance trace after this point.
        bool splitEligible = dot(transmittedDir, transmittedDir) > 0.0
                && F > 0.0 && F < 1.0;
        if (splitEligible) {
            MediumStack transmittedMedium = medium;
            if (entering) {
                mediumPush(transmittedMedium, entered);
            } else {
                mediumPop(transmittedMedium);
            }
            float3 deferredDir = normalize(transmittedDir);
            PathSegment deferred = makePathSegment(
                    offsetSurfaceOrigin(hitPos, geometricNormal, deferredDir, transmitBias),
                    deferredDir, throughput * (1.0 - F), transmittedMedium,
                    rayConeWidth, rayConeSpread, seed, bounce + 1,
                    true);
            PackedPathSegment packedDeferred = packPathSegment(deferred, PATH_NO_NEXT);
            packedDeferred.pathFlags |= PATH_AIR_VOLUME_CONSUMED;
            queue[splitRecord] = packedDeferred;
            nextRecord = splitRecord;
            float3 reflectedDir = reflect(rd, n);
            PathSegment reflected = makePathSegment(
                    offsetSurfaceOrigin(hitPos, geometricNormal, reflectedDir, SURF_BIAS),
                    reflectedDir, throughput * F, medium,
                    rayConeWidth, rayConeSpread, seed ^ 0xa511e9b3u, bounce + 1,
                    true);
            return reflected;
        }

        bool hasTransmission = dot(transmittedDir, transmittedDir) > 0.0;
        PathSegment continuation;
        if (!hasTransmission || F >= 1.0) {
            float3 reflectedDir = reflect(rd, n);
            continuation = makePathSegment(
                    offsetSurfaceOrigin(hitPos, geometricNormal, reflectedDir, SURF_BIAS),
                    reflectedDir, throughput * F, medium,
                    rayConeWidth, rayConeSpread, seed, bounce + 1,
                    true);
        } else {
            float3 deferredDir = normalize(transmittedDir);
            if (entering) {
                mediumPush(medium, entered);
            } else {
                mediumPop(medium);
            }
            continuation = makePathSegment(
                    offsetSurfaceOrigin(hitPos, geometricNormal, deferredDir, transmitBias),
                    deferredDir, throughput * (1.0 - F), medium,
                    rayConeWidth, rayConeSpread, seed, bounce + 1,
                    true);
        }
        return continuation;
    }
}

[shader("raygeneration")]
void main() {
    worldPush = ConstPtr<WorldPush>(pc.worldPushAddr)[0];
    uint2 dispatchIndex = DispatchRaysIndex().xy;
    uint2 dimensions = DispatchRaysDimensions().xy;
    int2 pix = int2(dispatchIndex);
    float2 size = float2(dimensions);
    float2 uv = (float2(pix) + 0.5) / size;
    float2 jndc = (uv + worldPush.jitter / size) * 2.0 - 1.0;
    float4 nearH = mul(worldPush.invViewProj, float4(jndc.x, jndc.y, 1.0, 1.0));
    float4 farH = mul(worldPush.invViewProj, float4(jndc.x, jndc.y, 0.0, 1.0));
    float3 nearP = nearH.xyz / nearH.w;
    float3 farP = farH.xyz / farH.w;
    float3 origin = nearP + worldPush.camOffset;
    float3 dir = normalize(farP - nearP);
    float rayConeSpread = primaryRayConeSpread(jndc, size, dir);
    uint seed = (dispatchIndex.x * 1973u + dispatchIndex.y * 9277u + 26699u)
            ^ (worldPush.frameIndex * 2654435761u);
    MediumStack cameraMedium = makeMediumStack((worldPush.flags & 1u) != 0u
            ? makeDielectricMedium(true, WATER_IOR, worldPush.waterParams.xyz, 1.0)
            : airMedium());
    uint pixelIndex = dispatchIndex.y * dimensions.x + dispatchIndex.x;
    uint baseRecordCount = dimensions.x * dimensions.y;
    uint splitRecord = baseRecordCount + pixelIndex;
    DevicePtr<PackedPathSegment> queue = DevicePtr<PackedPathSegment>(pc.pathQueueAddr);

    seed = pcg(seed);
    PathSegment current = makePathSegment(origin, dir, float3(1.0, 1.0, 1.0),
            cameraMedium, 0.0, rayConeSpread, seed, 0, true);
    uint nextRecord;
    float3 prefixRadiance;
    PathSegment terminal = tracePrimary(
            current, queue, splitRecord, pixelIndex, nextRecord, prefixRadiance);
    outImage[pix] = float4(prefixRadiance, 1.0);
    PackedPathSegment packedTerminal = packPathSegment(terminal, nextRecord);
    packedTerminal.pathFlags |= PATH_AIR_VOLUME_CONSUMED;
    queue[pixelIndex] = packedTerminal;

    writeGuides(pix, dir, jndc, size, rayConeSpread);
    if (pc.debugView != 0u) {
        writeDebugView(pix);
    }
}
