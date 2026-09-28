package dev.comfyfluffy.caustica.rt.terrain;

import dev.comfyfluffy.caustica.rt.RtContext;
import dev.comfyfluffy.caustica.rt.accel.RtBuffer;
import dev.comfyfluffy.caustica.rt.light.RealtimeLightBlockIndex;
import dev.comfyfluffy.caustica.rt.light.RealtimeLightBlockIndex.Entry;
import dev.comfyfluffy.caustica.rt.light.RealtimeLightBlockIndex.Source;
import org.lwjgl.system.MemoryUtil;
import org.lwjgl.vulkan.VK10;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.Objects;

/** Host-visible BDA table containing only the current invisible vanilla Light-block sources. */
final class RtRealtimeLightBlocks {
    private RtBuffer buffer;
    private Snapshot snapshot = Snapshot.EMPTY;

    record Snapshot(long address, int count, float totalWeight, long revision) {
        static final Snapshot EMPTY = new Snapshot(0L, 0, 0.0f, Long.MIN_VALUE);
    }

    Snapshot ensure(RtContext ctx, Collection<Source[]> sectionSources,
                    long wantedRevision, int baseX, int baseY, int baseZ) {
        if (snapshot.revision() == wantedRevision) {
            return snapshot;
        }

        Objects.requireNonNull(sectionSources, "sectionSources");
        ArrayList<Source> sources = new ArrayList<>();
        for (Source[] section : sectionSources) {
            Collections.addAll(sources, Objects.requireNonNull(section, "sectionSources entry"));
        }
        RealtimeLightBlockIndex.Build build =
                RealtimeLightBlockIndex.build(sources, baseX, baseY, baseZ);

        RtBuffer candidate = null;
        if (build.entries().length != 0) {
            try {
                candidate = ctx.createBuffer(
                        (long) build.entries().length * RealtimeLightBlockIndex.GPU_RECORD_BYTES,
                        VK10.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                        true,
                        "realtime Light blocks");
                for (int i = 0; i < build.entries().length; i++) {
                    write(candidate.mapped
                            + (long) i * RealtimeLightBlockIndex.GPU_RECORD_BYTES,
                            build.entries()[i]);
                }
                candidate.flush();
            } catch (Throwable t) {
                destroy(candidate);
                throw t;
            }
        }

        long lastGraphicsUse;
        try {
            lastGraphicsUse = ctx.gpuExecutor().latestGraphicsUseValue();
        } catch (Throwable t) {
            destroy(candidate);
            throw t;
        }

        RtBuffer old = buffer;
        Snapshot next = new Snapshot(
                candidate == null ? 0L : candidate.deviceAddress,
                build.entries().length,
                build.totalWeight(),
                wantedRevision);
        buffer = candidate;
        snapshot = next;
        if (old != null) {
            ctx.gpuExecutor().enqueueDestroyAfterGraphics(lastGraphicsUse, old::destroy);
        }
        return next;
    }

    Snapshot current() {
        return snapshot;
    }

    void destroy() {
        destroy(buffer);
        buffer = null;
        snapshot = Snapshot.EMPTY;
    }

    private static void write(long address, Entry entry) {
        MemoryUtil.memPutFloat(address, entry.x());
        MemoryUtil.memPutFloat(address + 4, entry.y());
        MemoryUtil.memPutFloat(address + 8, entry.z());
        MemoryUtil.memPutFloat(address + 12, entry.cumulativeWeight());
        MemoryUtil.memPutFloat(address + 16, entry.intensity());
        MemoryUtil.memPutFloat(address + 20, entry.intensity());
        MemoryUtil.memPutFloat(address + 24, entry.intensity());
        MemoryUtil.memPutFloat(address + 28, entry.selectionWeight());
    }

    private static void destroy(RtBuffer value) {
        if (value != null) {
            value.destroy();
        }
    }
}
