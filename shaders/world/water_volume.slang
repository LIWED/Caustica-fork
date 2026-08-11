// Bounded single-scattering integration for water. The view ray is divided into stable equal slices;
// each slice samples celestial visibility independently, so an occluder forms a continuous shaft instead
// of three displaced silhouettes. Only the directional term is distance-capped; full-path Beer absorption
// and the inexpensive ambient haze still cover the complete segment.

import world_common;
import world_core;
import math;
import medium;
import trace;

public static const uint WATER_VOLUME_SLICE_COUNT = 8u;
public static const float WATER_VOLUME_MAX_DISTANCE = 48.0;
public static const float3 WATER_SCATTERING_COEFFICIENT = float3(0.018, 0.018, 0.018);

public float3 waterEffectiveExtinction(float3 baseExtinction, bool water, bool waterFog,
                                       float waterFogStrength) {
    if (!water || !waterFog) return baseExtinction;
    float strength = clamp(waterFogStrength, 0.0, 2.0);
    return baseExtinction + WATER_SCATTERING_COEFFICIENT * strength;
}

public float3 waterScatterPalette(float3 transmittance) {
    float3 lostEnergy = clamp(1.0 - transmittance, 0.0, 1.0);
    float opticalAmount = dot(lostEnergy, float3(0.2126, 0.7152, 0.0722));
    float depthMix = smoothstep(0.05, 0.62, opticalAmount);
    float3 shallowEmerald = float3(0.08, 0.72, 0.46);
    float3 deepCyan = float3(0.04, 0.36, 0.68);
    return lerp(shallowEmerald, deepCyan, depthMix);
}

public float3 integrateWaterSingleScatter(float3 rayOrigin, float3 rayDir, float segmentDistance,
                                          float3 effectiveExtinction, float3 segmentTransmittance,
                                          float3 lightRadiance, float3 lightDir,
                                          float waterFogStrength, uint volumeSeed) {
    float strength = clamp(waterFogStrength, 0.0, 2.0);
    float3 normalizedLight = clamp(max(lightRadiance, 0.0) / 21.0, 0.0, 4.0);
    float daylight = clamp(dot(normalizedLight, float3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
    if (daylight <= 0.0 || strength <= 0.0) {
        return float3(0.0, 0.0, 0.0);
    }

    float3 scatteringCoefficient = WATER_SCATTERING_COEFFICIENT * strength;
    float3 scatteringFraction = clamp(scatteringCoefficient
            / max(effectiveExtinction, float3(1.0e-5, 1.0e-5, 1.0e-5)), 0.0, 1.0);
    float3 palette = waterScatterPalette(segmentTransmittance);
    float3 lostEnergy = clamp(1.0 - segmentTransmittance, 0.0, 1.0);
    float3 result = lostEnergy * scatteringFraction * palette * (0.080 * daylight);
    float3 scatteringBound = lostEnergy * palette * (0.22 * strength * daylight);

    float marchDistance = min(segmentDistance, WATER_VOLUME_MAX_DISTANCE);
    if (marchDistance <= 0.05) {
        return min(result, scatteringBound);
    }

    float stepLength = marchDistance / float(WATER_VOLUME_SLICE_COUNT);
    float3 stepTransmittance = exp(-effectiveExtinction * stepLength);
    float3 sliceLostEnergy = clamp(1.0 - stepTransmittance, 0.0, 1.0);
    float3 sliceScatteredEnergy = sliceLostEnergy * scatteringFraction;
    float3 viewTransmittance = float3(1.0, 1.0, 1.0);
    float phaseBoost = clamp(4.0 * PI * waterTyndallPhase(dot(rayDir, lightDir)), 0.15, 6.0);
    float3 directionalLight = normalizedLight * (0.125 * phaseBoost);

    for (uint slice = 0u; slice < WATER_VOLUME_SLICE_COUNT; ++slice) {
        // Independent strata move between frames and converge through the existing temporal denoiser.
        // This replaces persistent 6-block midpoint steps at the 48-block cap with a stable expectation.
        uint jitterSeed = volumeSeed ^ worldPush.frameIndex * 747796405u ^ slice * 2891336453u;
        float sliceJitter = (float(pcg(jitterSeed) & 0x00ffffffu) + 0.5) / 16777216.0;
        float sampleDistance = (float(slice) + sliceJitter) * stepLength;
        float3 samplePosition = rayOrigin + rayDir * sampleDistance;
        VisibilityResult shadow = visibility(samplePosition, lightDir, 10000.0);
        float3 lightPathTransmittance = shadow.waterHitT > 0.0
                ? exp(-effectiveExtinction * shadow.waterHitT)
                : float3(1.0, 1.0, 1.0);
        result += viewTransmittance * sliceScatteredEnergy * palette * directionalLight
                * clamp(shadow.transmittance, 0.0, 1.0) * lightPathTransmittance;
        viewTransmittance *= stepTransmittance;
    }

    return min(result, scatteringBound);
}
