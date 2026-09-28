// Offline active celestial light. The pushed RGB value is integrated angular strength I.
// Uniform tangent-plane sampling defines q_omega; Le = I*q_omega preserves Le/q = I.
// Camera-only decorative sprites are deliberately not this transport light.
public float celestialTangentHalfAngle(float halfAngle) {
    if (!(halfAngle > 0.0)) return 0.0;
    return tan(clamp(halfAngle, 1.0e-4, 1.4));
}

public float celestialPlanePdf(float u, float v, float t) {
    if (!(t > 0.0) || abs(u) > t || abs(v) > t) return 0.0;
    float squaredLength = 1.0 + u * u + v * v;
    return squaredLength * sqrt(squaredLength) / (4.0 * t * t);
}

public float celestialPowerHeuristic(float a, float b) {
    float scale = max(a, b);
    if (!(scale > 0.0)) return 0.0;
    float x = a / scale;
    float y = b / scale;
    return x * x / (x * x + y * y);
}

public float celestialDirectMisWeight(float lightPdf, float bsdfPdf, bool canContinue) {
    if (!(lightPdf > 0.0) || !canContinue) return 1.0;
    return celestialPowerHeuristic(lightPdf, bsdfPdf);
}

public float celestialEscapeMisWeight(float bsdfPdf, float lightPdf, bool delta) {
    if (delta) return 1.0;
    return celestialPowerHeuristic(bsdfPdf, lightPdf);
}

void celestialFrame(float3 axis, float3 pole, out float3 forward, out float3 right, out float3 up) {
    forward = dot(axis, axis) > 0.0 ? normalize(axis) : float3(0.0, 1.0, 0.0);
    right = cross(forward, pole);
    if (dot(right, right) < 1.0e-8) {
        float3 fallback = abs(forward.y) < 0.9 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
        right = cross(forward, fallback);
    }
    right = normalize(right);
    up = cross(right, forward);
}

public float3 sampleCelestialSquare(float3 axis, float3 pole, float halfAngle, float2 sample) {
    float3 forward, right, up;
    celestialFrame(axis, pole, forward, right, up);
    float t = celestialTangentHalfAngle(halfAngle);
    float2 plane = (sample * 2.0 - 1.0) * t;
    return normalize(forward + plane.x * right + plane.y * up);
}

public float celestialDirectionPdf(float3 axis, float3 pole, float halfAngle, float3 direction) {
    float3 forward, right, up;
    celestialFrame(axis, pole, forward, right, up);
    float cosine = dot(direction, forward);
    if (!(cosine > 0.0)) return 0.0;
    return celestialPlanePdf(dot(direction, right) / cosine, dot(direction, up) / cosine,
            celestialTangentHalfAngle(halfAngle));
}
