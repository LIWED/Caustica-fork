package dev.comfyfluffy.caustica.rt.terrain;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.LongPredicate;

/**
 * Render-thread ownership policy for one dirty-group generation.
 *
 * <p>A grouped section stays present from queueing through staging. Only terminal
 * publication or cancellation removes its reverse ownership, so a newer dirty event
 * or window eviction can always find and invalidate the whole old generation.
 */
final class DirtyGroupGenerationOwnership {
    static final long NO_GENERATION = 0L;
    private static final long NO_TOKEN = Long.MIN_VALUE;

    enum Phase {
        QUEUED,
        IN_FLIGHT,
        STAGED
    }

    record Member(long sectionKey, long generation, long token, Phase phase) {
    }

    private final Map<Long, Member> bySection = new LinkedHashMap<>();

    long ownerOf(long sectionKey) {
        Member member = bySection.get(sectionKey);
        return member == null ? NO_GENERATION : member.generation();
    }

    void queue(long sectionKey, long generation) {
        requireGeneration(generation);
        Member previous = bySection.get(sectionKey);
        if (previous != null) {
            if (previous.generation() == generation && previous.phase() == Phase.QUEUED) {
                return;
            }
            throw new IllegalStateException(
                    "section " + sectionKey + " is already owned by dirty generation "
                            + previous.generation() + " in phase " + previous.phase());
        }
        bySection.put(sectionKey, new Member(sectionKey, generation, NO_TOKEN, Phase.QUEUED));
    }

    boolean markInFlight(long sectionKey, long generation, long token) {
        Member member = bySection.get(sectionKey);
        if (member == null
                || member.generation() != generation
                || member.phase() != Phase.QUEUED) {
            return false;
        }
        bySection.put(sectionKey, new Member(sectionKey, generation, token, Phase.IN_FLIGHT));
        return true;
    }

    boolean stage(long sectionKey, long generation, long token) {
        Member member = bySection.get(sectionKey);
        if (member == null
                || member.generation() != generation
                || member.phase() != Phase.IN_FLIGHT
                || member.token() != token) {
            return false;
        }
        bySection.put(sectionKey, new Member(sectionKey, generation, token, Phase.STAGED));
        return true;
    }

    boolean publishable(long sectionKey, long generation, boolean desired) {
        Member member = bySection.get(sectionKey);
        return desired
                && member != null
                && member.generation() == generation
                && member.phase() == Phase.STAGED;
    }

    List<Member> cancelGeneration(long generation) {
        requireGeneration(generation);
        ArrayList<Member> cancelled = new ArrayList<>();
        for (var iterator = bySection.entrySet().iterator(); iterator.hasNext(); ) {
            Map.Entry<Long, Member> entry = iterator.next();
            if (entry.getValue().generation() == generation) {
                cancelled.add(entry.getValue());
                iterator.remove();
            }
        }
        return List.copyOf(cancelled);
    }

    /**
     * Atomically validate and release a complete staged generation for publication.
     * A failed validation leaves every ownership entry intact so the caller can cancel.
     */
    boolean releaseForPublication(
            long generation, long[] sectionKeys, LongPredicate desired) {
        requireGeneration(generation);
        Set<Long> uniqueKeys = new HashSet<>();
        for (long sectionKey : sectionKeys) {
            if (!uniqueKeys.add(sectionKey)
                    || !publishable(sectionKey, generation, desired.test(sectionKey))) {
                return false;
            }
        }
        int generationMembers = 0;
        for (Member member : bySection.values()) {
            if (member.generation() == generation) {
                generationMembers++;
            }
        }
        if (generationMembers != uniqueKeys.size()) {
            return false;
        }
        for (long sectionKey : sectionKeys) {
            bySection.remove(sectionKey);
        }
        return true;
    }

    void clear() {
        bySection.clear();
    }

    private static void requireGeneration(long generation) {
        if (generation == NO_GENERATION) {
            throw new IllegalArgumentException("dirty generation 0 is reserved");
        }
    }
}
