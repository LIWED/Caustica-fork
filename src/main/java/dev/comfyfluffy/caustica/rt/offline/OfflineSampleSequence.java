package dev.comfyfluffy.caustica.rt.offline;

/**
 * Dependency-free CPU reference for the offline primary-ray sample sequence.
 *
 * <p>The shader uses the same 64-bit fixed-point R2/Weyl recurrence and
 * per-pixel Cranley-Patterson rotation. Taking the phase's high 24 bits avoids
 * the adjacent-index collapse caused by converting a large 64-bit index to
 * float before multiplication.
 */
public final class OfflineSampleSequence {
    private static final long STEP_X = 0xC13FA9A902A6328FL;
    private static final long STEP_Y = 0x91E10DA5C79E7B1DL;
    private static final double HIGH_24_TO_UNIT = 1.0 / 16_777_216.0;

    public record Sample(double x, double y) {
    }

    private OfflineSampleSequence() {
    }

    public static Sample sample2D(int pixelHash, long globalSampleIndex) {
        if (globalSampleIndex < 0L) {
            throw new IllegalArgumentException("globalSampleIndex must be non-negative");
        }
        long sampleNumber = globalSampleIndex + 1L;
        long rotationX = rotation64(pixelHash, 0x68bc21eb, 0x02e5be93);
        long rotationY = rotation64(pixelHash, 0x967a889b, 0x368cc8b7);
        long phaseX = rotationX + sampleNumber * STEP_X;
        long phaseY = rotationY + sampleNumber * STEP_Y;
        return new Sample(
                phaseToUnit(phaseX),
                phaseToUnit(phaseY));
    }

    /**
     * Converts an unsigned fixed-point phase to the exact 24-bit float lattice.
     *
     * <p>There is deliberately no half-bin offset: values above {@code 2^23}
     * cannot represent {@code integer + 0.5} exactly in float, and the highest
     * centered bin could round to 1.0.
     */
    public static double phaseToUnit(long phase) {
        return (phase >>> 40) * HIGH_24_TO_UNIT;
    }

    public static int hash32(int value) {
        int x = value;
        x ^= x >>> 16;
        x *= 0x7feb352d;
        x ^= x >>> 15;
        x *= 0x846ca68b;
        x ^= x >>> 16;
        return x;
    }

    private static long rotation64(int pixelHash, int highSalt, int lowSalt) {
        long high = (long) hash32(pixelHash ^ highSalt) << 32;
        long low = Integer.toUnsignedLong(hash32(pixelHash ^ lowSalt));
        return high | low;
    }
}
