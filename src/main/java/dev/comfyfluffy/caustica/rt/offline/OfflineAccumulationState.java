package dev.comfyfluffy.caustica.rt.offline;

/**
 * Dependency-free state machine for progressive offline accumulation.
 *
 * <p>The caller owns camera comparison and game-tick freezing. This class only
 * decides when the camera has remained stable long enough, whether an
 * automatic freeze should be requested, and how many path samples belong to
 * the current weighted-average step.
 */
public final class OfflineAccumulationState {
    public static final long STILL_DELAY_NANOS = 2_000_000_000L;

    public enum Phase {
        DISABLED,
        HOLD_STILL,
        FREEZING,
        MANUAL_FREEZE_REQUIRED,
        ACCUMULATING
    }

    public record Decision(
            Phase phase,
            boolean requestFreeze,
            boolean accumulate,
            boolean resetHistory,
            long previousSamples,
            int currentSamples) {
    }

    private Phase phase = Phase.DISABLED;
    private boolean active;
    private boolean hasRenderSignature;
    private boolean freezeRequested;
    private boolean hasStableSince;
    private long renderSignature;
    private long accumulatedSamples;
    private long stableSinceNanos;

    public Decision observe(boolean enabled, boolean cameraChanged, long nowNanos,
                            long nextRenderSignature,
                            boolean localAutoFreezeAvailable, boolean frozen, int spp) {
        if (!enabled) {
            clear();
            return idleDecision(Phase.DISABLED, false);
        }

        if (!active || cameraChanged || !hasRenderSignature || renderSignature != nextRenderSignature) {
            active = true;
            hasRenderSignature = true;
            renderSignature = nextRenderSignature;
            stableSinceNanos = nowNanos;
            hasStableSince = true;
            accumulatedSamples = 0L;
            freezeRequested = false;
            phase = Phase.HOLD_STILL;
            return idleDecision(phase, true);
        }

        if (!hasStableSince || nowNanos < stableSinceNanos) {
            stableSinceNanos = nowNanos;
            hasStableSince = true;
            accumulatedSamples = 0L;
            freezeRequested = false;
            phase = Phase.HOLD_STILL;
            return idleDecision(phase, true);
        }

        if (nowNanos - stableSinceNanos < STILL_DELAY_NANOS) {
            phase = Phase.HOLD_STILL;
            return idleDecision(phase, false);
        }

        if (!frozen) {
            if (localAutoFreezeAvailable) {
                boolean requestFreeze = !freezeRequested;
                freezeRequested = true;
                phase = Phase.FREEZING;
                return new Decision(phase, requestFreeze, false, false, 0L, 0);
            }
            phase = Phase.MANUAL_FREEZE_REQUIRED;
            return idleDecision(phase, false);
        }

        int currentSamples = Math.max(1, spp);
        long previousSamples = accumulatedSamples;
        accumulatedSamples += currentSamples;
        phase = Phase.ACCUMULATING;
        return new Decision(phase, false, true, previousSamples == 0L,
                previousSamples, currentSamples);
    }

    public void clear() {
        phase = Phase.DISABLED;
        active = false;
        hasRenderSignature = false;
        freezeRequested = false;
        hasStableSince = false;
        renderSignature = 0L;
        accumulatedSamples = 0L;
        stableSinceNanos = 0L;
    }

    public long accumulatedSamples() {
        return accumulatedSamples;
    }

    public Phase phase() {
        return phase;
    }

    private static Decision idleDecision(Phase phase, boolean resetHistory) {
        return new Decision(phase, false, false, resetHistory, 0L, 0);
    }
}
