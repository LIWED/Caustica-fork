package dev.comfyfluffy.caustica.rt.offline;

/** Shares the mode encoding between the history signature and world push flags. */
public final class OfflineRegularizationPolicy {
    private OfflineRegularizationPolicy() {}

    public static int flags(int mode, boolean accumulating) {
        return accumulating ? Math.clamp(mode, 0, 2) << 7 : 0;
    }
}
