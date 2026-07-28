package dev.comfyfluffy.caustica.rt.offline;

/** Pure runtime policy shared by the offline renderer and NVIDIA temporal feature gates. */
public final class OfflineModePolicy {
    private OfflineModePolicy() {
    }

    public static boolean temporalFeatureEnabled(boolean preference, boolean offlineAccumulating) {
        return preference && !offlineAccumulating;
    }

    public static boolean nativeResolutionRequired(boolean offlineAccumulating) {
        return offlineAccumulating;
    }

    /** The latest server-synchronized tick state is authoritative; confirmations are never latched. */
    public static boolean worldFrozen(boolean serverSynchronizedFrozen) {
        return serverSynchronizedFrozen;
    }
}
