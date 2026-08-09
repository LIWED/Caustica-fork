// Analytic exponential-height air attenuation plus a tightly bounded camera-ray shaft estimate.
// Ambient fog is analytic on every eligible air segment. Expensive celestial visibility is reserved
// for the single Pass A camera segment, so neither SPP nor later bounces multiply its four rays.

import world_common;
import world_core;
import math;
import trace;

public struct AirVolumeResult {
    public float3 transmittance;
    public float3 radiance;
};

public static const uint AIR_VOLUME_SLICE_COUNT = 4u;
public static const float AIR_VOLUME_MIE_G = 0.78;
public static const float AIR_VOLUME_AMBIENT = 0.55;
public static const float AIR_VOLUME_DIRECTIONAL = 0.18;

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
    if ((worldPush.flags & (1u << 6u)) == 0u) {
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
    float rain = clamp(worldPush.weather.x, 0.0, 1.0);
    float thunder = clamp(worldPush.weather.y, 0.0, 1.0);
    float weatherDensity = min(1.0 + rain * 0.65 + thunder * 0.35, 2.0);
    float baseDensity = max(worldPush.airVolume.x, 0.0) * weatherDensity;
    float heightFalloff = max(worldPush.airVolume.y, 0.0);
    float opticalDepth = heightOpticalDepth(
            ro, rd, safeDistance, baseDensity, heightFalloff, worldPush.airVolume.z);
    float transmittance = exp(-opticalDepth);
    result.transmittance = float3(transmittance, transmittance, transmittance);

    float3 fogColor = max(worldPush.weatherColor.xyz, 0.0);
    float ambientLightningLift = 1.0 + 0.35 * clamp(worldPush.weather.z, 0.0, 1.0);
    result.radiance = fogColor * (1.0 - transmittance)
            * (AIR_VOLUME_AMBIENT * ambientLightningLift);

    bool shaftsEnabled = sampleShafts && (worldPush.flags & (1u << 7u)) != 0u;
    float3 rawLightDir = worldPush.lightDir.xyz;
    float lightLengthSq = dot(rawLightDir, rawLightDir);
    float3 rawLightRadiance = max(worldPush.lightRadiance.xyz, 0.0);
    float lightEnergy = dot(rawLightRadiance, float3(0.2126, 0.7152, 0.0722));
    bool activeCelestial = lightLengthSq > 1.0e-8 && lightEnergy > 1.0e-6;
    if (!shaftsEnabled || !activeCelestial || baseDensity <= 0.0 || safeDistance <= 0.05) {
        return result;
    }

    float3 lightDir = rawLightDir * rsqrt(lightLengthSq);
    float3 normalizedLight = clamp(rawLightRadiance / 21.0, 0.0, 4.0);
    float phase = clamp(4.0 * PI * hg(dot(rd, lightDir), AIR_VOLUME_MIE_G), 0.05, 12.0);
    for (uint slice = 0u; slice < AIR_VOLUME_SLICE_COUNT; ++slice) {
        uint jitterSeed = seed ^ worldPush.frameIndex * 747796405u ^ slice * 2891336453u;
        float stratum = (float(slice) + rndf(jitterSeed)) / float(AIR_VOLUME_SLICE_COUNT);
        float sampleDistance = stratum * safeDistance;
        float sliceBegin = float(slice) * safeDistance / float(AIR_VOLUME_SLICE_COUNT);
        float sliceEnd = float(slice + 1u) * safeDistance / float(AIR_VOLUME_SLICE_COUNT);
        float opticalBefore = heightOpticalDepth(
                ro, rd, sliceBegin, baseDensity, heightFalloff, worldPush.airVolume.z);
        float opticalAfter = heightOpticalDepth(
                ro, rd, sliceEnd, baseDensity, heightFalloff, worldPush.airVolume.z);
        float sliceOpticalDepth = max(opticalAfter - opticalBefore, 0.0);
        float sliceScattered = 1.0 - exp(-sliceOpticalDepth);
        float3 samplePosition = ro + rd * sampleDistance;
        VisibilityResult shadow = visibility(samplePosition, lightDir, 10000.0);
        result.radiance += exp(-opticalBefore) * sliceScattered * fogColor
                * normalizedLight * (AIR_VOLUME_DIRECTIONAL * phase)
                * clamp(shadow.transmittance, 0.0, 1.0);
    }
    return result;
}
