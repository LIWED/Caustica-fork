package dev.comfyfluffy.caustica.rt.material;

/** POM frame flags; matches parallax.slang without growing the WorldPush ABI. */
public final class RtParallax {
    private RtParallax() {}

    public static int flags(boolean enabled, float depth) {
        if (!enabled || !Float.isFinite(depth)) return 0;
        int percent = Math.round(Math.clamp(depth, 0.0f, 2.0f) * 100.0f);
        return percent == 0 ? 0 : (1 << 8) | (percent << 16);
    }
}
