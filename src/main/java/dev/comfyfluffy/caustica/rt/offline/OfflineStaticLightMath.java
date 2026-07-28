package dev.comfyfluffy.caustica.rt.offline;

/** Pure calculations shared by offline static-light publication and its behavior tests. */
public final class OfflineStaticLightMath {
    public static final int NO_LIGHT = -1;
    public static final int AREA_LIGHT = 0;
    public static final int POINT_LIGHT = 1;

    private static final float EMISSIVE_STRENGTH = 3.0f;
    private static final float LIGHT_BLOCK_RADIUS = 0.25f;

    private OfflineStaticLightMath() {
    }

    /**
     * Radiant intensity of an invisible light block, modelled as a hidden white sphere solely for
     * determining energy. The actual shader evaluates it as a delta point light.
     */
    public static float pointIntensity(int level) {
        int clamped = Math.max(0, Math.min(15, level));
        return EMISSIVE_STRENGTH * (clamped / 15.0f)
                * (float) Math.PI * LIGHT_BLOCK_RADIUS * LIGHT_BLOCK_RADIUS;
    }

    /** Selection weight for a uniformly sampled emitting triangle. */
    public static float areaWeight(float area, float emission) {
        if (!Float.isFinite(area) || !Float.isFinite(emission)) {
            return 0.0f;
        }
        return Math.max(0.0f, area) * Math.max(0.0f, emission);
    }

    /**
     * Select the first cumulative weight strictly greater than a normalized random target.
     * Returns {@link #NO_LIGHT} for an empty, malformed, or zero-weight distribution.
     */
    public static int selectCdf(float[] cumulativeWeights, float unitRandom) {
        if (cumulativeWeights == null || cumulativeWeights.length == 0) {
            return NO_LIGHT;
        }
        float total = cumulativeWeights[cumulativeWeights.length - 1];
        if (!(total > 0.0f) || !Float.isFinite(total)) {
            return NO_LIGHT;
        }
        float u = Float.isFinite(unitRandom) ? unitRandom : 0.0f;
        u = Math.max(0.0f, Math.min(Math.nextDown(1.0f), u));
        float target = u * total;
        int lo = 0;
        int hi = cumulativeWeights.length - 1;
        while (lo < hi) {
            int mid = (lo + hi) >>> 1;
            if (cumulativeWeights[mid] > target) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        return cumulativeWeights[lo] > target ? lo : NO_LIGHT;
    }

    /** Power-heuristic MIS weight for the technique whose probability density is {@code a}. */
    public static float powerHeuristic(float a, float b) {
        double aa = Math.max(0.0, a);
        double bb = Math.max(0.0, b);
        double a2 = aa * aa;
        double b2 = bb * bb;
        double sum = a2 + b2;
        return sum > 0.0 && Double.isFinite(sum) ? (float) (a2 / sum) : 0.0f;
    }

    /** A frame may enter history only when its light list represents the same published terrain. */
    public static boolean mayAccumulate(boolean offlineAccumulating, long lightRevision, long sceneRevision) {
        return offlineAccumulating && lightRevision == sceneRevision;
    }
}
