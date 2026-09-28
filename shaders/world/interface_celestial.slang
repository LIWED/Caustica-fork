// A local planar proposal only; actual water geometry and Fresnel remain traced.
// normal is unit length and points from water into air. eta = water IOR / air IOR.
import celestial;
import water_celestial;

public float3 interfaceCelestialDirection(float3 airDir, float3 normal, float eta, bool reflection) {
    float airCos = dot(airDir, normal);
    if (!(airCos > 0.0)) return float3(0.0);
    if (reflection) return airDir - 2.0 * airCos * normal;
    if (!(eta > 0.0)) return float3(0.0);
    float3 tangent = (airDir - airCos * normal) / eta;
    float cosSquared = 1.0 - dot(tangent, tangent);
    if (!(cosSquared > 0.0)) return float3(0.0);
    return tangent + sqrt(cosSquared) * normal;
}

public float3 interfaceCelestialAirDirection(float3 direction, float3 normal, float eta, bool reflection) {
    float cosine = dot(direction, normal);
    if (reflection) {
        if (!(cosine < 0.0)) return float3(0.0);
        return direction - 2.0 * cosine * normal;
    }
    if (!(cosine > 0.0) || !(eta > 0.0)) return float3(0.0);
    float3 tangent = (direction - cosine * normal) * eta;
    float cosSquared = 1.0 - dot(tangent, tangent);
    if (!(cosSquared > 0.0)) return float3(0.0);
    return tangent + sqrt(cosSquared) * normal;
}

public float interfaceCelestialPdf(float3 axis, float3 pole, float halfAngle,
                                   float3 direction, float3 normal, float eta, bool reflection) {
    float3 airDir = interfaceCelestialAirDirection(direction, normal, eta, reflection);
    float airCos = dot(airDir, normal);
    if (!(airCos > 0.0)) return 0.0;
    float airPdf = celestialDirectionPdf(axis, pole, waterCelestialGuideHalfAngle(halfAngle), airDir);
    return reflection ? airPdf : airPdf * waterCelestialJacobian(airCos, dot(direction, normal), eta);
}

// The forward sample establishes proposal membership. Never inverse-map this
// known sample to test its square edge: FP32 reflection and Snell both lose ulps.
public float interfaceCelestialSamplePdf(float3 axis, float3 pole, float halfAngle,
                                         float3 airDir, float3 direction, float3 normal, float eta, bool reflection) {
    float airCos = dot(airDir, normal);
    float waterCos = dot(direction, normal);
    if (!(airCos > 0.0) || (reflection ? !(waterCos < 0.0) : !(waterCos > 0.0))) return 0.0;
    float cosine = dot(normalize(axis), airDir);
    float t = celestialTangentHalfAngle(waterCelestialGuideHalfAngle(halfAngle));
    if (!(cosine > 0.0) || !(t > 0.0)) return 0.0;
    float airPdf = 1.0 / (4.0 * t * t * cosine * cosine * cosine);
    return reflection ? airPdf : airPdf * waterCelestialJacobian(airCos, waterCos, eta);
}
