package dev.comfyfluffy.caustica.rt.offline;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;

/** Dependency-free builder for per-section offline static-light neighborhoods. */
public final class OfflineLocalLightIndex {
    public static final int NEIGHBOR_RADIUS = 2;

    private static final Directory EMPTY_DIRECTORY = new Directory(0, 0, 0.0f);

    private OfflineLocalLightIndex() {
    }

    public record Source(int globalIndex, int sx, int sy, int sz, float weight) {
    }

    public record Receiver(int slot, int sx, int sy, int sz) {
    }

    public record Directory(int offset, int count, float totalWeight) {
    }

    public record Reference(int globalIndex, float cumulativeWeight) {
    }

    public record Build(Directory[] directories, Reference[] references) {
    }

    public static Build build(int slotCapacity, Receiver[] receivers, Source[] sources) {
        if (slotCapacity < 0) {
            throw new IllegalArgumentException("slot capacity must not be negative");
        }
        if (receivers == null || sources == null) {
            throw new IllegalArgumentException("receiver and source arrays must not be null");
        }

        Source[] orderedSources = sources.clone();
        boolean[] globalIndices = new boolean[orderedSources.length];
        for (Source source : orderedSources) {
            if (source == null) {
                throw new IllegalArgumentException("source must not be null");
            }
            int globalIndex = source.globalIndex();
            if (globalIndex < 0 || globalIndex >= orderedSources.length || globalIndices[globalIndex]) {
                throw new IllegalArgumentException("invalid or duplicate global light index " + globalIndex);
            }
            if (!(source.weight() > 0.0f) || !Float.isFinite(source.weight())) {
                throw new IllegalArgumentException("source weight must be finite and positive");
            }
            globalIndices[globalIndex] = true;
        }
        Arrays.sort(orderedSources, Comparator.comparingInt(Source::globalIndex));

        Directory[] directories = new Directory[slotCapacity];
        Arrays.fill(directories, EMPTY_DIRECTORY);
        boolean[] receiverSlots = new boolean[slotCapacity];
        ArrayList<Reference> references = new ArrayList<>();

        for (Receiver receiver : receivers) {
            if (receiver == null) {
                throw new IllegalArgumentException("receiver must not be null");
            }
            int slot = receiver.slot();
            if (slot < 0 || slot >= slotCapacity || receiverSlots[slot]) {
                throw new IllegalArgumentException("invalid or duplicate receiver slot " + slot);
            }
            receiverSlots[slot] = true;

            int offset = references.size();
            float cumulative = 0.0f;
            for (Source source : orderedSources) {
                if (!local(receiver, source)) {
                    continue;
                }
                cumulative += source.weight();
                if (!Float.isFinite(cumulative)) {
                    throw new IllegalArgumentException("local source weight total must be finite");
                }
                references.add(new Reference(source.globalIndex(), cumulative));
            }
            int count = references.size() - offset;
            if (count > 0) {
                directories[slot] = new Directory(offset, count, cumulative);
            }
        }

        return new Build(directories, references.toArray(Reference[]::new));
    }

    private static boolean local(Receiver receiver, Source source) {
        return absoluteDifference(receiver.sx(), source.sx()) <= NEIGHBOR_RADIUS
                && absoluteDifference(receiver.sy(), source.sy()) <= NEIGHBOR_RADIUS
                && absoluteDifference(receiver.sz(), source.sz()) <= NEIGHBOR_RADIUS;
    }

    private static long absoluteDifference(int a, int b) {
        return Math.abs((long) a - b);
    }
}
