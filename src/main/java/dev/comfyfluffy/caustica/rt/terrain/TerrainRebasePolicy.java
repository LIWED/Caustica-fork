package dev.comfyfluffy.caustica.rt.terrain;

/** Dependency-free stream reachability and state transition policy for terrain rebasing. */
final class TerrainRebasePolicy {
    private TerrainRebasePolicy() {
    }

    record State(int blockX, int blockY, int blockZ, long realtimeLightRevision) {
    }

    static boolean shouldReturnIdle(boolean hasTerrainWork, boolean rebase) {
        return !hasTerrainWork && !rebase;
    }

    static boolean shouldApplyBuildChanges(
            boolean hasPrepared, boolean hasRemoved, boolean rebase) {
        return hasPrepared || hasRemoved || rebase;
    }

    static State applyRebase(
            State current,
            int blockX,
            int blockY,
            int blockZ,
            boolean rebase,
            boolean hasLightSources) {
        if (!rebase) {
            return current;
        }
        return new State(
                blockX,
                blockY,
                blockZ,
                current.realtimeLightRevision() + (hasLightSources ? 1L : 0L));
    }
}
