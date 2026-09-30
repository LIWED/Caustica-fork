// Analytic exponential-height air attenuation plus a tightly bounded camera-ray shaft estimate.
// Ambient fog is analytic on every eligible air segment. Expensive celestial visibility is reserved
// for the single Pass A camera segment, so neither SPP nor later bounces multiply its four rays.

import world_common;
import world_core;
import math;
import trace;
import cloud_volume;

public struct AirVolumeResult {
    public float3 transmittance;
    public float3 radiance;
};

public static const uint AIR_VOLUME_SLICE_COUNT = 4u;
public static const float AIR_VOLUME_MIE_G = 0.68;
public static const float AIR_VOLUME_AMBIENT = 0.55;
public static const float AIR_VOLUME_DIRECTIONAL = 0.80;
public static const float AIR_VOLUME_SHAFT_DENSITY = 0.0015;
public static const float AIR_VOLUME_SHAFT_DISTANCE = 96.0;

// Slang has no expm1 intrinsic. Preserve precision for nearly horizontal rays with the local series,
// then use exp(x)-1 once cancellation is no longer significant.
public float airExpm1(float x) {
    if (abs(x) < 1.0e-3) {
        return x * (1.0 + x * (0.5 + x / 6.0));
    }
    return exp(x) - 1.0;
}

public float heightOpticalDepth(float3 ro, float3 rd, float distance,
                                float baseDensity, float heightFalloff,
                                float baseHeight) {
    float densityAtOrigin = baseDensity
            * exp(clamp(-heightFalloff * (ro.y - baseHeight), -12.0, 12.0));
    float slope = heightFalloff * rd.y;
    // Select the horizontal limit by the dimensionless exponent, not by slope alone. A slope-only
    // threshold creates a visible band because its error grows with the (up to 512-block) segment.
    float integral = abs(slope * distance) < 1.0e-4
            ? densityAtOrigin * distance
            : densityAtOrigin * (-airExpm1(-slope * distance)) / slope;
    return clamp(integral, 0.0, 32.0);
}

public AirVolumeResult integrateAirVolume(float3 ro, float3 rd, float distance, bool sampleShafts, uint seed) {
    AirVolumeResult result;
    result.transmittance = float3(1.0, 1.0, 1.0);
    result.radiance = float3(0.0, 0.0, 0.0);
    bool fogEnabled = (worldPush.flags & (1u << 6u)) != 0u;
    bool shaftsEnabled = sampleShafts && (worldPush.flags & (1u << 7u)) != 0u;
    if (!fogEnabled && !shaftsEnabled) {
        return result;
    }
    if (!(distance > 0.0)) {
        return result;
    }

    float maxDistance = worldPush.airVolume.w;
    if (!(maxDistance > 0.0)) {
        return result;
    }
    float safeDistance = min(distance, worldPush.airVolume.w);
    // Density is assembled on the CPU (fog strength x base x weather x time of day) so every factor is a
    // user-facing setting; this pass consumes the result. cloudTuning.z carries the same product without
    // the base coefficient, which is what the shafts scale their brightness by so fog and beams stay one
    // medium instead of two independent knobs.
    float densityScale = max(worldPush.cloudTuning.z, 0.0);
    float baseDensity = max(worldPush.airVolume.x, 0.0);
    float heightFalloff = max(worldPush.airVolume.y, 0.0);
    float3 fogColor = max(worldPush.weatherColor.xyz, 0.0);
    if (fogEnabled && baseDensity > 0.0) {
        float opticalDepth = heightOpticalDepth(
                ro, rd, safeDistance, baseDensity, heightFalloff, worldPush.airVolume.z);
        float transmittance = exp(-opticalDepth);
        result.transmittance = float3(transmittance, transmittance, transmittance);
        float ambientLightningLift = 1.0 + 0.35 * clamp(worldPush.weather.z, 0.0, 1.0);
        result.radiance = fogColor * (1.0 - transmittance)
                * (AIR_VOLUME_AMBIENT * ambientLightningLift);
    }

    float3 rawLightDir = worldPush.lightDir.xyz;
    float lightLengthSq = dot(rawLightDir, rawLightDir);
    float3 rawLightRadiance = max(worldPush.lightRadiance.xyz, 0.0);
    float lightEnergy = dot(rawLightRadiance, float3(0.2126, 0.7152, 0.0722));
    bool activeCelestial = lightLengthSq > 1.0e-8 && lightEnergy > 1.0e-6;
    if (!shaftsEnabled || !activeCelestial || safeDistance <= 0.05) {
        return result;
    }

    float3 lightDir = rawLightDir * rsqrt(lightLengthSq);
    // Cloud has to shade the shafts exactly as it shades the sun. Without this an overcast sky still
    // scatters the full celestial radiance: the direct light under cloud drops to a few percent while
    // the shafts do not, so they stand out *more* under a cloud shadow than in clear weather. That is
    // the glowing haze that survives turning ambient fog off, because that switch only gates the
    // analytic fog term above and leaves these shafts running.
    float cloudShade = cloudSunTransmittance(worldPush, ro, lightDir);
    if (cloudShade <= 0.001) {
        return result;
    }
    float3 normalizedLight = clamp(rawLightRadiance / 21.0, 0.0, 4.0) * cloudShade;
    float phase = clamp(4.0 * PI * hg(dot(rd, lightDir), AIR_VOLUME_MIE_G), 0.05, 5.0);
    float absorption = clamp(worldPush.waterTuning.w, 0.0, 2.0);
    // One medium, two effects: the shafts share the fog's density rather than carrying their own, so
    // wherever the air is thick enough to see haze it also catches a beam. Denser air scatters more of
    // the intercepted light toward the eye, so thicker fog makes a shaft *brighter* rather than
    // dimmer — that is what puts visible columns in morning and rain while noon has almost none.
    float fogGain = clamp(densityScale, 0.0, 3.0);
    float scatterShare = 2.0 / (1.0 + absorption) * (0.35 + 0.65 * fogGain);
    float shaftDensity = AIR_VOLUME_SHAFT_DENSITY * densityScale;
    float shaftDistance = min(safeDistance, AIR_VOLUME_SHAFT_DISTANCE);
    for (uint slice = 0u; slice < AIR_VOLUME_SLICE_COUNT; ++slice) {
        uint jitterSeed = seed ^ worldPush.frameIndex * 747796405u ^ slice * 2891336453u;
        // Quadratic strata spend the same four visibility rays near the camera, where trees
        // and windows create the visible contrast; analytic fog still covers the full ray.
        float t0 = float(slice) / float(AIR_VOLUME_SLICE_COUNT);
        float t1 = float(slice + 1u) / float(AIR_VOLUME_SLICE_COUNT);
        float sliceBegin = t0 * t0 * shaftDistance;
        float sliceEnd = t1 * t1 * shaftDistance;
        float sampleDistance = lerp(sliceBegin, sliceEnd, rndf(jitterSeed));
        float opticalBefore = heightOpticalDepth(
                ro, rd, sliceBegin, shaftDensity, heightFalloff, worldPush.airVolume.z);
        float opticalAfter = heightOpticalDepth(
                ro, rd, sliceEnd, shaftDensity, heightFalloff, worldPush.airVolume.z);
        float sliceOpticalDepth = max(opticalAfter - opticalBefore, 0.0);
        float sliceScattered = 1.0 - exp(-sliceOpticalDepth);
        float3 samplePosition = ro + rd * sampleDistance;
        VisibilityResult shadow = visibility(samplePosition, lightDir, 10000.0);
        result.radiance += exp(-opticalBefore * absorption) * sliceScattered * fogColor
                * normalizedLight * (AIR_VOLUME_DIRECTIONAL * phase * scatterShare)
                * clamp(shadow.transmittance, 0.0, 1.0);
    }
    return result;
}
