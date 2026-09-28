module indirect_regularization;

// Optional biased path regularization, after non-delta transport only. The
// caller must use this one effective roughness for f, sampling and every PDF.
// Camera-visible surfaces and ideal-only chains retain the authored material.
public float regularizedPathRoughness(float rough, bool hasNonDeltaBounce, uint mode) {
    if (!hasNonDeltaBounce || mode == 0u) return rough;
    float alpha = rough * rough;
    if (alpha >= 0.3) return rough;
    float floorAlpha = mode == 1u ? 0.04 : 0.1;
    return sqrt(clamp(2.0 * alpha, floorAlpha, 0.3));
}
