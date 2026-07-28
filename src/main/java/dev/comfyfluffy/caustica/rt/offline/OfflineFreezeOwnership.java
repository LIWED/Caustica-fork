package dev.comfyfluffy.caustica.rt.offline;

/**
 * Tracks whether Caustica changed a running game into a frozen game.
 *
 * <p>A pre-frozen world is borrowed, not owned, and must never be unfrozen by
 * Offline Rendering cleanup.
 */
public final class OfflineFreezeOwnership {
    private boolean ownsFreeze;

    public synchronized boolean onFreezeConfirmed(boolean alreadyFrozen) {
        ownsFreeze = ownsFreeze || !alreadyFrozen;
        return ownsFreeze;
    }

    public synchronized boolean consumeRestoreRequired() {
        boolean restore = ownsFreeze;
        ownsFreeze = false;
        return restore;
    }

    public synchronized boolean ownsFreeze() {
        return ownsFreeze;
    }

    public synchronized void clearWithoutRestore() {
        ownsFreeze = false;
    }
}
