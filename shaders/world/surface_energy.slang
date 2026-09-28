// Conservative diffuse budget for additive Schlick / single-scatter Smith GGX.
// For upper-hemisphere V,L, V.H >= sqrt((1-sin(thetaV))/2).
// White Smith GGX integrates to <=1, so Schlick at this minimum bounds its
// directional reflectance. The rationalized root stays stable near grazing.
public float surfaceDiffuseTransmission(float noV) {
    noV = clamp(noV, 0.0, 1.0);
    float sinV = sqrt(max(0.0, (1.0 - noV) * (1.0 + noV)));
    float minVoH = noV / sqrt(2.0 * (1.0 + sinV));
    float m = 1.0 - minVoH;
    // 1-m^5 factored to retain tiny positive grazing transmission.
    return minVoH * (1.0 + m * (1.0 + m * (1.0 + m * (1.0 + m))));
}

public float surfaceFresnelUpperBound(float noV, float f0) {
    return 1.0 - (1.0 - clamp(f0, 0.0, 1.0)) * surfaceDiffuseTransmission(noV);
}

// Reciprocal normalized diffuse complement. C = integral 2*cosTheta*A(cosTheta)
// = -15/8 + 121*sqrt(2)/63 = 0.841187953129277792..., rounded upward below.
// For albedo<=1, its integral <=(1-F0)*A(V)=1-U(V); GGX integral <=U(V).
// The coefficient can exceed 1: do not clamp it (the integral is bounded).
// Uses an upper bound, not exact directional GGX albedo or full multiscattering.
public float surfaceDiffuseEnergyBudget(float noV, float noL, float f0) {
    float symmetricTransmission = surfaceDiffuseTransmission(noV) * surfaceDiffuseTransmission(noL);
    return (1.0 - clamp(f0, 0.0, 1.0)) * symmetricTransmission / 0.8411881;
}
