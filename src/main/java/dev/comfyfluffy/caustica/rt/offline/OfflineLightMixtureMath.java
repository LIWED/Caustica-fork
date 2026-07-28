package dev.comfyfluffy.caustica.rt.offline;

/** Dependency-free probability helpers shared by offline light-sampling paths. */
public final class OfflineLightMixtureMath {
    public static final float LOCAL_MIX = 0.9f;

    private OfflineLightMixtureMath() {
    }

    public static float selectionPdf(float weight, float globalTotal, boolean local, float localTotal) {
        if (!positiveFinite(weight) || !positiveFinite(globalTotal) || !Float.isFinite(localTotal)
                || localTotal < 0.0f || (local && !positiveFinite(localTotal))) {
            return 0.0f;
        }

        float globalPdf = weight / globalTotal;
        if (localTotal == 0.0f) {
            return positiveFinite(globalPdf) ? globalPdf : 0.0f;
        }

        float pdf = (1.0f - LOCAL_MIX) * globalPdf;
        if (local) {
            pdf += LOCAL_MIX * (weight / localTotal);
        }
        return positiveFinite(pdf) ? pdf : 0.0f;
    }

    public static float areaSolidAnglePdf(
            float selectionPdf, float distanceSquared, float cosLight, float area) {
        if (!positiveFinite(selectionPdf) || !positiveFinite(distanceSquared)
                || !positiveFinite(cosLight) || !positiveFinite(area)) {
            return 0.0f;
        }

        float pdf = selectionPdf * distanceSquared / (cosLight * area);
        return positiveFinite(pdf) ? pdf : 0.0f;
    }

    public static float alphaCoverageWeight(float area, float emission, float alphaCoverage) {
        if (!positiveFinite(area) || !positiveFinite(emission) || !Float.isFinite(alphaCoverage)) {
            return 0.0f;
        }

        float weight = area * emission * Math.clamp(alphaCoverage, 0.0f, 1.0f);
        return Float.isFinite(weight) && weight >= 0.0f ? weight : 0.0f;
    }

    private static boolean positiveFinite(float value) {
        return Float.isFinite(value) && value > 0.0f;
    }
}
