package dev.comfyfluffy.caustica.rt.terrain;

public final class TerrainRebasePolicyBehaviorTest {
    private TerrainRebasePolicyBehaviorTest() {
    }

    public static void main(String[] args) {
        zeroGeometryLightCompletionStillAppliesRequiredRebase();
        completelyIdlePureLightWindowDoesNotReturnBeforeRebase();
        baseTranslationAndLightRevisionAdvanceExactlyOnce();
        emptyWorldRebaseDoesNotAdvanceLightRevision();
        System.out.println("Terrain pure-Light rebase behavior: PASS");
    }

    private static void zeroGeometryLightCompletionStillAppliesRequiredRebase() {
        check(TerrainRebasePolicy.shouldApplyBuildChanges(false, false, true),
                "rebase alone must enter applyBuildChanges when built and removal lists are empty");
    }

    private static void completelyIdlePureLightWindowDoesNotReturnBeforeRebase() {
        check(!TerrainRebasePolicy.shouldReturnIdle(false, true),
                "an idle stream must remain reachable when the player crossed the rebase threshold");
        check(TerrainRebasePolicy.shouldReturnIdle(false, false),
                "a truly idle stream with no rebase may return");
    }

    private static void baseTranslationAndLightRevisionAdvanceExactlyOnce() {
        TerrainRebasePolicy.State initial =
                new TerrainRebasePolicy.State(0, 64, 0, 41L);
        TerrainRebasePolicy.State first = TerrainRebasePolicy.applyRebase(
                initial, 513, 80, -513, true, true);
        TerrainRebasePolicy.State second = TerrainRebasePolicy.applyRebase(
                first, 513, 80, -513, false, true);

        check(first.blockX() == 513 && first.blockY() == 80 && first.blockZ() == -513,
                "the required rebase must translate all terrain-base coordinates");
        check(first.realtimeLightRevision() == 42L,
                "a pure-Light rebase must advance its revision once");
        check(second.equals(first),
                "a following non-rebase frame must not translate or advance the revision again");
    }

    private static void emptyWorldRebaseDoesNotAdvanceLightRevision() {
        TerrainRebasePolicy.State initial =
                new TerrainRebasePolicy.State(0, 0, 0, 9L);
        TerrainRebasePolicy.State rebased = TerrainRebasePolicy.applyRebase(
                initial, 1025, 0, 1025, true, false);

        check(rebased.blockX() == 1025 && rebased.blockZ() == 1025,
                "an empty world still updates the terrain base");
        check(rebased.realtimeLightRevision() == 9L,
                "a rebase with no Light sources must not advance the realtime Light revision");
    }

    private static void check(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
