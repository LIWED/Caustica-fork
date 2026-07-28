package dev.comfyfluffy.caustica.rt.offline;

/** Stable hash of every non-camera input that changes traced radiance. */
public final class OfflineRenderSignature {
    private static final long FNV_OFFSET = 0xcbf29ce484222325L;
    private static final long FNV_PRIME = 0x100000001b3L;

    private OfflineRenderSignature() {
    }

    public static long create(int width, int height, long worldIdentity, long terrainRevision,
                              int debugView, int maxBounces, int featureFlags,
                              int sunRadiusBits, int moonRadiusBits, int sunTiltBits) {
        long hash = FNV_OFFSET;
        hash = add(hash, width);
        hash = add(hash, height);
        hash = add(hash, worldIdentity);
        hash = add(hash, terrainRevision);
        hash = add(hash, debugView);
        hash = add(hash, maxBounces);
        hash = add(hash, featureFlags);
        hash = add(hash, sunRadiusBits);
        hash = add(hash, moonRadiusBits);
        return add(hash, sunTiltBits);
    }

    private static long add(long hash, long value) {
        hash ^= value;
        return hash * FNV_PRIME;
    }
}
