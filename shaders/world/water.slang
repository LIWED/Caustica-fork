// Water surface: the wave spectrum (with its analytic time derivative), the normal perturbation it
// drives, and the caustic term that differentiates the same field. Depends on core.


// Animated surface waves — a non-harmonic directional spectrum, gradient-only (the surface stays
// geometrically flat; only the normal tilts). Three things make it read as water rather than glass:
//  * Sharp-crested profile: each component is h = a·exp(S·(sin φ − 1)) — peaked crests, wide flat
//    troughs (pure sines look like rolling jelly). Still C∞ smooth with an exact analytic gradient.
//  * Real deep-water dispersion ω = √(g·k): long swell strides past (λ=14 m → ~4.7 m/s) while short
//    chop flutters nearly in place — wrong relative speeds are the biggest tell of fake water.
//  * Wind + independent meander: every wavelength has its own heading, phase and transverse bending.
//    Incommensurate wavelengths and analytic 2-D crest curvature prevent a moving periodic lattice.
// The domain is world-anchored (see applyWaterWaves) so the pattern is pinned in world space, and the
// caustics (waterCaustic) differentiate this same field, so they stay in sync with the visible ripples.

import world_common;
import world_core;

public static const float WATER_WAVE_STRENGTH = 0.3;  // slope scale (higher = choppier glints / more broken reflections)
public static const float WAVE_SPEED = 0.8;           // global time scale; dispersion keeps relative speeds physical
public static const float WATER_TEMPORAL_LINEAR_LIMIT = 0.05; // seconds; beyond this, evaluate the old phase exactly
public static const int   WAVE_COMPONENT_COUNT = 12; // unified non-harmonic swell-to-ripple spectrum
public static const float WATER_SURFACE_GAIN = 1.50;
public static const float WATER_REFRACTION_GAIN = 0.45;
public static const float WATER_CAUSTIC_GAIN = 1.35;
public static const float WATER_SURFACE_MAX_SLOPE = 0.35;
public static const float WATER_REFRACTION_MAX_SLOPE = 0.12;
public static const float WATER_CAUSTIC_MAX_SLOPE = 0.45;
public static const int WATER_REFRACTION_COMPONENT_COUNT = 8;
public static const float WATER_REFRACTION_MIN_FOOTPRINT = 0.35;
public static const float WAVE_G = 9.81;
public static const float2 WAVE_WIND = normalize(float2(1.0, 0.35)); // dominant travel direction
public float waterWaveLodWeight(float wavelength, float footprint) {
    float cyclesPerPixel = max(footprint, 0.0) / max(wavelength, 1.0e-4);
    return 1.0 - smoothstep(0.25, 0.5, cyclesPerPixel);
}

// One spectrum walk is shared by normals, temporal reprojection and physical caustics. Long waves stay
// near the wind while progressively shorter waves fan out. None of the wavelengths form one geometric
// series, and every crest bends with a distinct transverse phase, scale and velocity.
public void waterWaveSpectrum<let WITH_DT : int>(float2 p, float t, float footprint, int componentLimit,
                                          out float2 grad, out float2 gradDt) {
    const float wavelength[WAVE_COMPONENT_COUNT] = {
        18.70, 13.10, 9.40, 6.20, 4.70, 3.15,
        2.38, 1.54, 1.17, 0.73, 0.52, 0.37
    };
    const float directionOffset[WAVE_COMPONENT_COUNT] = {
        -0.12, 0.19, -0.48, 0.72, -0.93, 1.17,
        -1.36, 0.44, 1.53, -0.69, 1.94, -1.71
    };
    const float energy[WAVE_COMPONENT_COUNT] = {
        0.028, 0.031, 0.030, 0.029, 0.027, 0.025,
        0.022, 0.019, 0.016, 0.013, 0.010, 0.008
    };
    const float phaseOffset[WAVE_COMPONENT_COUNT] = {
        0.37, 2.11, 4.73, 1.28, 5.41, 3.02,
        0.83, 4.16, 2.67, 5.92, 1.74, 3.58
    };
    const float sharpness[WAVE_COMPONENT_COUNT] = {
        1.10, 1.18, 1.27, 1.34, 1.40, 1.46,
        1.52, 1.58, 1.64, 1.70, 1.76, 1.82
    };
    const float meanderAmplitude[WAVE_COMPONENT_COUNT] = {
        0.95, 0.82, 0.73, 0.66, 0.58, 0.51,
        0.45, 0.39, 0.34, 0.29, 0.25, 0.21
    };
    const float meanderScale[WAVE_COMPONENT_COUNT] = {
        0.23, 0.31, 0.27, 0.36, 0.29, 0.41,
        0.33, 0.38, 0.26, 0.43, 0.35, 0.30
    };
    const float meanderSpeed[WAVE_COMPONENT_COUNT] = {
        0.38, -0.27, 0.44, -0.32, 0.24, -0.41,
        0.35, -0.22, 0.47, -0.30, 0.28, -0.39
    };
    const float meanderOffset[WAVE_COMPONENT_COUNT] = {
        1.13, 4.29, 2.54, 5.77, 0.68, 3.91,
        1.86, 4.97, 2.21, 5.38, 0.34, 3.46
    };
    t *= WAVE_SPEED;
    grad = float2(0.0, 0.0);
    gradDt = float2(0.0, 0.0);
    for (int i = 0; i < componentLimit; i++) {
        float lambda = wavelength[i];
        float lodWeight = waterWaveLodWeight(lambda, footprint);
        if (lodWeight <= 0.0) continue;
        float k = 2.0 * PI / lambda;
        float w = sqrt(WAVE_G * k);
        float angle = directionOffset[i];
        float cs = cos(angle), sn = sin(angle);
        float2 d = float2(WAVE_WIND.x * cs - WAVE_WIND.y * sn,
                          WAVE_WIND.x * sn + WAVE_WIND.y * cs);
        float2 perpendicular = float2(-d.y, d.x);
        float phase = k * dot(d, p) - w * t + phaseOffset[i];
        float2 phaseGradient = k * d;
        float phaseDt = -w;
        float2 phaseGradientDt = float2(0.0, 0.0);

        float meanderSpatialRate = meanderScale[i] * k;
        float meanderPhaseDt = meanderSpeed[i] * w;
        float meanderPhase = meanderSpatialRate * dot(perpendicular, p)
                            + meanderPhaseDt * t + meanderOffset[i];
        phase += meanderAmplitude[i] * sin(meanderPhase);
        phaseGradient += meanderAmplitude[i] * cos(meanderPhase)
                       * meanderSpatialRate * perpendicular;
        if (WITH_DT != 0) {
            phaseDt += meanderAmplitude[i] * cos(meanderPhase) * meanderPhaseDt;
            phaseGradientDt += -meanderAmplitude[i] * sin(meanderPhase)
                             * meanderPhaseDt * meanderSpatialRate * perpendicular;
        }

        float S = sharpness[i];
        float sinPh = sin(phase);
        float cosPh = cos(phase);
        float e = exp(S * (sinPh - 1.0));
        float amplitude = lodWeight * (energy[i] / k) * S;
        grad += amplitude * cosPh * e * phaseGradient;
        if (WITH_DT != 0) {
            gradDt += amplitude * e
                    * (phaseDt * (-sinPh + S * cosPh * cosPh) * phaseGradient
                    + cosPh * phaseGradientDt);
        }
    }
    grad *= WATER_WAVE_STRENGTH;
    gradDt *= WATER_WAVE_STRENGTH;
}

public float2 waterWaveGrad(float2 p, float t, float footprint) {
    float2 grad, gradDt;
    waterWaveSpectrum<0>(p, t, footprint, WAVE_COMPONENT_COUNT, grad, gradDt);
    return grad;
}

public float2 waterWaveGrad(float2 p, float t) {
    return waterWaveGrad(p, t, 0.0);
}

// Evaluate the current gradient and linearly rewind it to the previous phase in one spectrum walk.
// Frame deltas are bounded on the CPU, so this avoids a second set of trigonometric/exponential work
// while remaining accurate over the sub-frame interval used by reflection reprojection.
public void waterWaveGradTemporal(float2 p, float currentT, float previousT, float footprint,
                           out float2 currentGrad, out float2 previousGrad) {
    float2 gradDt;
    waterWaveSpectrum<1>(p, currentT, footprint, WAVE_COMPONENT_COUNT, currentGrad, gradDt);
    float frameDelta = currentT - previousT;
    if (abs(frameDelta) <= WATER_TEMPORAL_LINEAR_LIMIT) {
        previousGrad = currentGrad - frameDelta * WAVE_SPEED * gradDt;
    } else {
        // The shortest components can advance several radians during a stall. Their first-order
        // rewind would then produce a worse motion vector than one exact, uniformly branched lookup.
        previousGrad = waterWaveGrad(p, previousT, footprint);
    }
}

public float2 waterBoundRoleGrad(float2 grad, float roleScale, float maxSlope) {
    float2 scaledGrad = grad * roleScale;
    float slope = length(scaledGrad);
    return slope > maxSlope ? scaledGrad * (maxSlope / slope) : scaledGrad;
}

public float2 waterSurfaceGrad(float2 p, float t, float footprint, float strength) {
    float2 grad, gradDt;
    waterWaveSpectrum<0>(p, t, footprint, WAVE_COMPONENT_COUNT, grad, gradDt);
    float amplitudeResponse = clamp(strength, 0.0, 2.0);
    return waterBoundRoleGrad(
            grad, amplitudeResponse * WATER_SURFACE_GAIN, WATER_SURFACE_MAX_SLOPE);
}

public void waterSurfaceGradTemporal(float2 p, float currentT, float previousT,
        float footprint, float strength, out float2 currentGrad, out float2 previousGrad) {
    float2 rawCurrentGrad, rawGradDt;
    waterWaveSpectrum<1>(p, currentT, footprint, WAVE_COMPONENT_COUNT,
            rawCurrentGrad, rawGradDt);
    float amplitudeResponse = clamp(strength, 0.0, 2.0);
    currentGrad = waterBoundRoleGrad(
            rawCurrentGrad, amplitudeResponse * WATER_SURFACE_GAIN, WATER_SURFACE_MAX_SLOPE);
    float frameDelta = currentT - previousT;
    if (abs(frameDelta) <= WATER_TEMPORAL_LINEAR_LIMIT) {
        float2 rawPreviousGrad = rawCurrentGrad - frameDelta * WAVE_SPEED * rawGradDt;
        previousGrad = waterBoundRoleGrad(
                rawPreviousGrad, amplitudeResponse * WATER_SURFACE_GAIN, WATER_SURFACE_MAX_SLOPE);
    } else {
        previousGrad = waterSurfaceGrad(p, previousT, footprint, strength);
    }
}

public float2 waterRefractionGrad(float2 p, float t, float footprint, float strength) {
    float filteredFootprint = max(footprint, WATER_REFRACTION_MIN_FOOTPRINT);
    float2 grad, gradDt;
    waterWaveSpectrum<0>(p, t, filteredFootprint, WATER_REFRACTION_COMPONENT_COUNT,
            grad, gradDt);
    float amplitudeResponse = clamp(strength, 0.0, 2.0);
    return waterBoundRoleGrad(
            grad, amplitudeResponse * WATER_REFRACTION_GAIN, WATER_REFRACTION_MAX_SLOPE);
}

public void waterRefractionGradTemporal(float2 p, float currentT, float previousT,
        float footprint, float strength, out float2 currentGrad, out float2 previousGrad) {
    float filteredFootprint = max(footprint, WATER_REFRACTION_MIN_FOOTPRINT);
    float2 rawCurrentGrad, rawGradDt;
    waterWaveSpectrum<1>(p, currentT, filteredFootprint, WATER_REFRACTION_COMPONENT_COUNT,
            rawCurrentGrad, rawGradDt);
    float amplitudeResponse = clamp(strength, 0.0, 2.0);
    currentGrad = waterBoundRoleGrad(
            rawCurrentGrad, amplitudeResponse * WATER_REFRACTION_GAIN,
            WATER_REFRACTION_MAX_SLOPE);
    float frameDelta = currentT - previousT;
    if (abs(frameDelta) <= WATER_TEMPORAL_LINEAR_LIMIT) {
        float2 rawPreviousGrad = rawCurrentGrad - frameDelta * WAVE_SPEED * rawGradDt;
        previousGrad = waterBoundRoleGrad(
                rawPreviousGrad, amplitudeResponse * WATER_REFRACTION_GAIN,
                WATER_REFRACTION_MAX_SLOPE);
    } else {
        previousGrad = waterRefractionGrad(p, previousT, footprint, strength);
    }
}

public float3 waterNormalFromGrad(float3 geometricNormal, float2 boundedGrad) {
    if (abs(geometricNormal.y) < 0.5) return geometricNormal;
    if (dot(boundedGrad, boundedGrad) <= 0.0) return geometricNormal;
    float orientation = geometricNormal.y >= 0.0 ? 1.0 : -1.0;
    return normalize(geometricNormal + orientation
            * float3(-boundedGrad.x, 0.0, -boundedGrad.y));
}

public float3 waterRefractionNormal(float3 geometricNormal, float2 boundedGrad) {
    return waterNormalFromGrad(geometricNormal, boundedGrad);
}

public float3 waterRefractionNormal(float3 geometricNormal, float2 worldXZ,
        float t, float footprint, float strength) {
    if (strength <= 0.0) return geometricNormal;
    return waterRefractionNormal(
            geometricNormal, waterRefractionGrad(worldXZ, t, footprint, strength));
}

// Perturb a (near-)horizontal water surface normal by the wave field. Flowing side faces (|n.y| small)
// keep their flat geometric normal. `worldXZ` must be a world-stable coordinate (rebased hit + the pushed
// anchor) so the ripples stay pinned in the world. `nGeo` is already oriented toward the viewer, so the
// down-viewed underside (n.y < 0) takes the mirrored slope (-up).
public float3 applyWaterWaves(float3 nGeo, float2 worldXZ, float t, float footprint, float strength) {
    if (strength <= 0.0) return nGeo;
    if (abs(nGeo.y) < 0.5) return nGeo;
    float2 grad = waterSurfaceGrad(worldXZ, t, footprint, strength);
    return waterNormalFromGrad(nGeo, grad);
}

// ---- Water caustics. Sunlight refracting through the waved surface converges/diverges before it
// reaches an underwater receiver; the analytic wave field makes the true focusing factor computable
// instead of faked with a scrolling texture. Where the shadow ray of an underwater NEE vertex crossed
// water (returned by visibility() as VisibilityResult.waterHitT), evaluate the horizontal landing
// position of the refracted sun ray as a function of surface position and finite-difference it. The
// caustic intensity is the inverse Jacobian determinant of that surface→floor mapping (area compression = brightening, real
// fold caustics where det → 0). Because this uses the SAME wave field as the visible surface normals,
// the caustic pattern stays in sync with the ripples. A depth-dependent finite-difference footprint
// broadens the physical fold lines without introducing a second periodic pattern.
public static const int CAUSTIC_DETAIL_COMPONENT_COUNT = 6;
public static const float CAUSTIC_JACOBIAN_EPS = 0.06;
public static const float CAUSTIC_LOD_NEAR = 0.06;
public static const float CAUSTIC_LOD_FAR = 0.28;
public static const float CAUSTIC_SHALLOW_CONTRAST = 1.65;
public static const float CAUSTIC_MIN = 0.45;
public static const float CAUSTIC_MAX = 3.2;
public static const float CAUSTIC_FADE_START = 12.0;
public static const float CAUSTIC_FADE_END = 42.0;

public void waterCausticDetailSpectrum(float2 p, float t, float footprint, out float2 grad) {
    const float wavelength[CAUSTIC_DETAIL_COMPONENT_COUNT] = {
        0.95, 0.68, 0.49, 0.34, 0.24, 0.18
    };
    const float directionOffset[CAUSTIC_DETAIL_COMPONENT_COUNT] = {
        2.36, -2.05, 0.98, -0.22, 1.71, -1.31
    };
    const float energy[CAUSTIC_DETAIL_COMPONENT_COUNT] = {
        0.0315, 0.0294, 0.0273, 0.0231, 0.0189, 0.0147
    };
    const float meanderAmplitude[CAUSTIC_DETAIL_COMPONENT_COUNT] = {
        0.52, 0.61, 0.47, 0.68, 0.56, 0.73
    };
    const float phaseOffset[CAUSTIC_DETAIL_COMPONENT_COUNT] = {
        5.11, 1.37, 3.92, 0.58, 4.46, 2.73
    };
    const float sharpness[CAUSTIC_DETAIL_COMPONENT_COUNT] = {
        0.86, 0.90, 0.94, 0.98, 1.02, 1.06
    };
    const float meanderScale[CAUSTIC_DETAIL_COMPONENT_COUNT] = {
        0.37, 0.43, 0.31, 0.47, 0.35, 0.41
    };
    const float meanderSpeed[CAUSTIC_DETAIL_COMPONENT_COUNT] = {
        0.33, -0.28, 0.42, -0.37, 0.25, -0.45
    };
    const float meanderOffset[CAUSTIC_DETAIL_COMPONENT_COUNT] = {
        0.91, 3.44, 5.26, 2.08, 4.79, 1.62
    };

    float warpPhaseX = dot(p, float2(0.31, 0.17)) - 0.21 * t + 0.41;
    float warpPhaseZ = dot(p, float2(-0.19, 0.29)) + 0.17 * t + 2.13;
    float2 warp = 0.22 * float2(
            sin(dot(p, float2(0.31, 0.17)) - 0.21 * t + 0.41),
            sin(dot(p, float2(-0.19, 0.29)) + 0.17 * t + 2.13));
    float cosWarpX = cos(warpPhaseX);
    float cosWarpY = cos(warpPhaseZ);
    float2 warpedP = p + warp;
    float2 warpDx = 0.22 * float2(0.31 * cosWarpX, -0.19 * cosWarpY);
    float2 warpDz = 0.22 * float2(0.17 * cosWarpX, 0.29 * cosWarpY);

    t *= WAVE_SPEED;
    grad = float2(0.0, 0.0);
    for (int i = 0; i < CAUSTIC_DETAIL_COMPONENT_COUNT; i++) {
        float lambda = wavelength[i];
        float lodWeight = waterWaveLodWeight(lambda, footprint);
        if (lodWeight <= 0.0) continue;
        float k = 2.0 * PI / lambda;
        float w = sqrt(WAVE_G * k);
        float angle = directionOffset[i];
        float cs = cos(angle), sn = sin(angle);
        float2 d = float2(WAVE_WIND.x * cs - WAVE_WIND.y * sn,
                          WAVE_WIND.x * sn + WAVE_WIND.y * cs);
        float2 perpendicular = float2(-d.y, d.x);
        float phase = k * dot(d, warpedP) - w * t + phaseOffset[i];
        float2 warpedPhaseGradient = k * d;

        float meanderSpatialRate = meanderScale[i] * k;
        float meanderPhaseDt = meanderSpeed[i] * w;
        float meanderPhase = meanderSpatialRate * dot(perpendicular, warpedP)
                            + meanderPhaseDt * t + meanderOffset[i];
        phase += meanderAmplitude[i] * sin(meanderPhase);
        warpedPhaseGradient += meanderAmplitude[i] * cos(meanderPhase)
                             * meanderSpatialRate * perpendicular;
        float2 phaseGradient = float2(
                dot(warpedPhaseGradient, float2(1.0, 0.0) + warpDx),
                dot(warpedPhaseGradient, float2(0.0, 1.0) + warpDz));

        float S = sharpness[i];
        float sinPh = sin(phase);
        float cosPh = cos(phase);
        float e = exp(S * (sinPh - 1.0));
        float amplitude = lodWeight * (energy[i] / k) * S;
        grad += amplitude * cosPh * e * phaseGradient;
    }
    grad *= WATER_WAVE_STRENGTH;
}

public float2 waterCausticGrad(float2 p, float t, float footprint, float strength) {
    float2 baseGrad, gradDt;
    waterWaveSpectrum<0>(p, t, footprint, WAVE_COMPONENT_COUNT, baseGrad, gradDt);
    float2 detailGrad;
    waterCausticDetailSpectrum(p, t, footprint, detailGrad);
    float2 rawGrad = baseGrad + detailGrad;
    float amplitudeResponse = clamp(strength, 0.0, 2.0);
    return waterBoundRoleGrad(
            rawGrad, amplitudeResponse * WATER_CAUSTIC_GAIN, WATER_CAUSTIC_MAX_SLOPE);
}

// Horizontal landing offset of a refracted sun ray entering the surface at world-stable xz, intersected
// with the receiver plane h metres below. inc = sunlight travel direction (downward, unit).
public float2 causticLanding(float2 xz, float t, float3 inc, float h, float lodFootprint,
        float strength) {
    float2 g = waterCausticGrad(xz, t, lodFootprint, strength);
    float3 nw = normalize(float3(-g.x, 1.0, -g.y));
    float3 rdw = refract(inc, nw, 1.0 / WATER_IOR); // air→water: never TIR
    return xz + rdw.xz * (h / max(-rdw.y, 0.05));
}

public float waterCaustic(float3 receiverPos, float3 stableLightDir, float depth, float strength) {
    if (strength <= 0.0) return 1.0;
    // Grazing light: the receiver-plane intersection degenerates and caustics vanish in reality anyway
    // (long slant paths absorb + the pattern smears out) — fade the effect to neutral 1.0.
    float fade = smoothstep(0.06, 0.18, stableLightDir.y);
    if (fade <= 0.0) return 1.0;
    float h = max(depth, 0.05);
    float t = worldPush.waterParams.w;
    float3 inc = -stableLightDir;
    float stableLightDistance = depth / max(stableLightDir.y, 0.05);
    float2 base = receiverPos.xz + stableLightDir.xz * stableLightDistance + worldPush.waterAnchor.xy;
    float depthBlur = smoothstep(0.0, CAUSTIC_FADE_START, h);
    float lodFootprint = lerp(CAUSTIC_LOD_NEAR, CAUSTIC_LOD_FAR, depthBlur);
    float2 p0 = causticLanding(base, t, inc, h, lodFootprint, strength);
    float2 px = causticLanding(base + float2(CAUSTIC_JACOBIAN_EPS, 0.0), t, inc, h, lodFootprint, strength);
    float2 pz = causticLanding(base + float2(0.0, CAUSTIC_JACOBIAN_EPS), t, inc, h, lodFootprint, strength);
    float det = abs((px.x - p0.x) * (pz.y - p0.y) - (px.y - p0.y) * (pz.x - p0.x));
    // Flat water ⇒ all landings displace identically ⇒ det = eps² ⇒ focus = 1 (energy-neutral); the
    // clamp bounds the fold-line spikes whose energy the surrounding darkening already paid for.
    float physicalFocus = (CAUSTIC_JACOBIAN_EPS * CAUSTIC_JACOBIAN_EPS) / max(det, 1.0e-5);
    float softFocus = pow(max(physicalFocus, 1.0e-4), 0.72);
    // Very shallow mappings remain close to the identity even when short ripples carry visible
    // curvature. Recover only their deviation from neutral, so a flat surface still returns 1.0.
    float shallowWeight = 1.0 - smoothstep(0.25, 3.5, h);
    float shallowContrast = lerp(1.0, CAUSTIC_SHALLOW_CONTRAST, shallowWeight);
    float amplitudeResponse = clamp(strength, 0.0, 2.0);
    float shapedFocus = 1.0 + (softFocus - 1.0)
            * shallowContrast * amplitudeResponse;
    float focus = clamp(shapedFocus, CAUSTIC_MIN, CAUSTIC_MAX);
    float deepFade = smoothstep(CAUSTIC_FADE_START, CAUSTIC_FADE_END, h);
    return lerp(1.0, focus, fade * (1.0 - deepFade));
}
