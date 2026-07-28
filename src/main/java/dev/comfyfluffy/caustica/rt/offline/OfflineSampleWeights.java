package dev.comfyfluffy.caustica.rt.offline;

/**
 * Sanitized integer weights passed to the float-based GPU accumulation shader.
 */
public record OfflineSampleWeights(int previousSamples, int currentSamples) {
    public static final int MAX_EXACT_FLOAT_WEIGHT = 16_777_208;

    public static OfflineSampleWeights of(long previousSamples, int currentSamples, boolean resetHistory) {
        long previous = resetHistory ? 0L : previousSamples;
        int safePrevious = (int) Math.clamp(previous, 0L, MAX_EXACT_FLOAT_WEIGHT);
        int safeCurrent = (int) Math.clamp((long) currentSamples, 1L, MAX_EXACT_FLOAT_WEIGHT);
        return new OfflineSampleWeights(safePrevious, safeCurrent);
    }
}
