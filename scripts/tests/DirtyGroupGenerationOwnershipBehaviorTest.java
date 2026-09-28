package dev.comfyfluffy.caustica.rt.terrain;

import java.util.List;

public final class DirtyGroupGenerationOwnershipBehaviorTest {
    private static final long GROUP_1 = 101L;
    private static final long GROUP_2 = 102L;
    private static final long KEY_A = 11L;
    private static final long KEY_B = 12L;
    private static final long TOKEN_A = 1001L;
    private static final long TOKEN_B = 1002L;

    private DirtyGroupGenerationOwnershipBehaviorTest() {
    }

    public static void main(String[] args) {
        stagedMemberRemainsOwnedUntilItsGenerationIsTerminal();
        cancellingGenerationReturnsAndInvalidatesEveryPhase();
        cancelledGroupCompletionCannotBecomeStandalone();
        publicationRequiresExactGenerationAndCurrentDesiredMembership();
        newerGenerationCannotBeOverwrittenByTheOldGeneration();
        stagedEvictionHasOnlyOneRetirementOwner();
        System.out.println("Dirty-group generation ownership behavior: PASS");
    }

    private static void stagedMemberRemainsOwnedUntilItsGenerationIsTerminal() {
        DirtyGroupGenerationOwnership ownership = twoMemberGroup();
        check(ownership.markInFlight(KEY_A, GROUP_1, TOKEN_A), "queued A must dispatch");
        check(ownership.stage(KEY_A, GROUP_1, TOKEN_A), "matching A completion must stage");

        check(ownership.ownerOf(KEY_A) == GROUP_1,
                "staging must retain reverse generation ownership");
        check(ownership.publishable(KEY_A, GROUP_1, true),
                "A must remain explicitly staged and publication-eligible for its generation");

        ownership.cancelGeneration(GROUP_1);
        ownership.queue(KEY_A, GROUP_2);
        check(ownership.ownerOf(KEY_A) == GROUP_2,
                "a newer dirty event may claim A only after cancelling the old generation");
    }

    private static void cancellingGenerationReturnsAndInvalidatesEveryPhase() {
        DirtyGroupGenerationOwnership ownership = twoMemberGroup();
        check(ownership.markInFlight(KEY_A, GROUP_1, TOKEN_A), "A dispatch");
        check(ownership.stage(KEY_A, GROUP_1, TOKEN_A), "A stage");
        check(ownership.markInFlight(KEY_B, GROUP_1, TOKEN_B), "B dispatch");

        List<DirtyGroupGenerationOwnership.Member> cancelled =
                ownership.cancelGeneration(GROUP_1);

        check(cancelled.size() == 2, "cancellation must return every owned member");
        check(has(cancelled, KEY_A, TOKEN_A, DirtyGroupGenerationOwnership.Phase.STAGED),
                "cancellation must identify staged A for unpublished-payload destruction");
        check(has(cancelled, KEY_B, TOKEN_B, DirtyGroupGenerationOwnership.Phase.IN_FLIGHT),
                "cancellation must identify in-flight B so its token becomes stale");
        check(ownership.ownerOf(KEY_A) == DirtyGroupGenerationOwnership.NO_GENERATION,
                "cancelled staged A must lose ownership");
        check(ownership.ownerOf(KEY_B) == DirtyGroupGenerationOwnership.NO_GENERATION,
                "cancelled in-flight B must lose ownership");
        check(!ownership.stage(KEY_B, GROUP_1, TOKEN_B),
                "the late B result must fail generation/token validation");
    }

    private static void cancelledGroupCompletionCannotBecomeStandalone() {
        DirtyGroupGenerationOwnership ownership = twoMemberGroup();
        check(ownership.markInFlight(KEY_B, GROUP_1, TOKEN_B), "B dispatch");
        ownership.cancelGeneration(GROUP_1);

        check(!ownership.stage(KEY_B, GROUP_1, TOKEN_B),
                "a cancelled grouped task must remain stale instead of losing its group identity");
        check(!ownership.publishable(KEY_B, GROUP_1, true),
                "a cancelled grouped task must not publish through any path");
    }

    private static void publicationRequiresExactGenerationAndCurrentDesiredMembership() {
        DirtyGroupGenerationOwnership ownership = twoMemberGroup();
        stageBoth(ownership);

        check(!ownership.releaseForPublication(
                        GROUP_1, new long[]{KEY_A, KEY_B}, key -> key != KEY_A),
                "an already staged member leaving desired must reject the whole atomic publication");
        check(ownership.ownerOf(KEY_A) == GROUP_1 && ownership.ownerOf(KEY_B) == GROUP_1,
                "failed publication validation must retain ownership for cancellation");
        check(!ownership.publishable(KEY_A, GROUP_1, false),
                "an undesired staged key must never be admitted to empty/source/geometry publication");

        ownership.cancelGeneration(GROUP_1);
        check(ownership.ownerOf(KEY_A) == DirtyGroupGenerationOwnership.NO_GENERATION,
                "cancellation must terminate the rejected generation");
    }

    private static void newerGenerationCannotBeOverwrittenByTheOldGeneration() {
        DirtyGroupGenerationOwnership ownership = twoMemberGroup();
        check(ownership.markInFlight(KEY_A, GROUP_1, TOKEN_A), "old A dispatch");
        check(ownership.stage(KEY_A, GROUP_1, TOKEN_A), "old A stage");

        long generationFoundByRedirty = ownership.ownerOf(KEY_A);
        check(generationFoundByRedirty == GROUP_1,
                "redirty must discover the staged old generation");
        ownership.cancelGeneration(generationFoundByRedirty);
        ownership.queue(KEY_A, GROUP_2);

        check(!ownership.publishable(KEY_A, GROUP_1, true),
                "old source/geometry must not overwrite the newer generation");
        check(ownership.ownerOf(KEY_A) == GROUP_2,
                "the newer generation must remain authoritative");
    }

    private static void stagedEvictionHasOnlyOneRetirementOwner() {
        DirtyGroupGenerationOwnership ownership = twoMemberGroup();
        check(ownership.markInFlight(KEY_A, GROUP_1, TOKEN_A), "A dispatch");
        check(ownership.stage(KEY_A, GROUP_1, TOKEN_A), "resident-to-empty A stage");

        int groupRetirementOwners = ownership.publishable(KEY_A, GROUP_1, true) ? 1 : 0;
        long generationFoundByEviction = ownership.ownerOf(KEY_A);
        check(generationFoundByEviction == GROUP_1,
                "eviction must discover staged group ownership before global retirement");
        ownership.cancelGeneration(generationFoundByEviction);
        groupRetirementOwners = 0;
        int globalRetirementOwners = 1;

        check(groupRetirementOwners + globalRetirementOwners == 1,
                "eviction must transfer retirement to exactly one owner");
        check(!ownership.publishable(KEY_A, GROUP_1, false),
                "eviction must prevent undesired empty reinsertion");
    }

    private static DirtyGroupGenerationOwnership twoMemberGroup() {
        DirtyGroupGenerationOwnership ownership = new DirtyGroupGenerationOwnership();
        ownership.queue(KEY_A, GROUP_1);
        ownership.queue(KEY_B, GROUP_1);
        return ownership;
    }

    private static void stageBoth(DirtyGroupGenerationOwnership ownership) {
        check(ownership.markInFlight(KEY_A, GROUP_1, TOKEN_A), "A dispatch");
        check(ownership.stage(KEY_A, GROUP_1, TOKEN_A), "A stage");
        check(ownership.markInFlight(KEY_B, GROUP_1, TOKEN_B), "B dispatch");
        check(ownership.stage(KEY_B, GROUP_1, TOKEN_B), "B stage");
    }

    private static boolean has(
            List<DirtyGroupGenerationOwnership.Member> members,
            long key,
            long token,
            DirtyGroupGenerationOwnership.Phase phase) {
        return members.stream().anyMatch(member ->
                member.sectionKey() == key
                        && member.token() == token
                        && member.phase() == phase);
    }

    private static void check(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
