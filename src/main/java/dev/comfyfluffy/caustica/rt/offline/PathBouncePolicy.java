package dev.comfyfluffy.caustica.rt.offline;

/** Bounds and selects the path-bounce budget for realtime and offline frames. */
public final class PathBouncePolicy {
    public static final int REALTIME_MIN = 2;
    public static final int REALTIME_MAX = 16;
    public static final int OFFLINE_MIN = 2;
    public static final int OFFLINE_MAX = 32;

    private PathBouncePolicy() {
    }

    public static int clampRealtime(int value) {
        return Math.max(REALTIME_MIN, Math.min(REALTIME_MAX, value));
    }

    public static int clampOffline(int value) {
        return Math.max(OFFLINE_MIN, Math.min(OFFLINE_MAX, value));
    }

    public static int effective(boolean accumulating, int realtime, int offline) {
        return accumulating ? clampOffline(offline) : clampRealtime(realtime);
    }
}
