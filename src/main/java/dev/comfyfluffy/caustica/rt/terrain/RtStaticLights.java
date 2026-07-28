package dev.comfyfluffy.caustica.rt.terrain;

import dev.comfyfluffy.caustica.rt.RtContext;
import dev.comfyfluffy.caustica.rt.accel.RtBuffer;
import dev.comfyfluffy.caustica.rt.material.RtBlockMaterials;
import dev.comfyfluffy.caustica.rt.offline.OfflineLightMixtureMath;
import dev.comfyfluffy.caustica.rt.offline.OfflineLocalLightIndex;
import dev.comfyfluffy.caustica.rt.offline.OfflineStaticLightMath;
import it.unimi.dsi.fastutil.longs.Long2ObjectMap;
import net.minecraft.client.renderer.texture.TextureAtlasSprite;
import org.lwjgl.system.MemoryUtil;
import org.lwjgl.vulkan.VK10;

import java.util.ArrayList;
import java.util.Collection;
/** CPU/GPU static-light data owned by terrain residency. */
final class RtStaticLights {
    static final int AREA = 0;
    static final int POINT = 1;
    static final int NO_LIGHT = -1;

    private static final int GPU_RECORD_BYTES = 128;
    private static final int LOCAL_DIRECTORY_BYTES = 16;
    private static final int LOCAL_REFERENCE_BYTES = 8;
    private RtBuffer buffer;
    private RtBuffer localDirectoryBuffer;
    private RtBuffer localReferenceBuffer;
    private Snapshot snapshot = Snapshot.EMPTY;

    record Snapshot(long address, int count, float totalWeight,
                    long localDirectoryAddress, int localDirectoryCount,
                    long localReferenceAddress, int localReferenceCount,
                    long revision) {
        static final Snapshot EMPTY = new Snapshot(0L, 0, 0.0f, 0L, 0, 0L, 0, Long.MIN_VALUE);
    }

    Snapshot ensure(RtContext ctx, Collection<RtSectionTable.SectionGeom> sections,
                    Long2ObjectMap<CpuLight[]> lightOnlySections, int slotCapacity,
                    long sceneRevision, int baseX, int baseY, int baseZ) {
        if (snapshot.revision == sceneRevision) {
            return snapshot;
        }
        ctx.waitIdle();
        rebuild(ctx, sections, lightOnlySections, slotCapacity, sceneRevision, baseX, baseY, baseZ);
        return snapshot;
    }

    Snapshot current() {
        return snapshot;
    }

    void invalidate() {
        snapshot = Snapshot.EMPTY;
    }

    void destroy() {
        destroyBuffers();
        snapshot = Snapshot.EMPTY;
    }

    private void rebuild(RtContext ctx, Collection<RtSectionTable.SectionGeom> sections,
                         Long2ObjectMap<CpuLight[]> lightOnlySections, int slotCapacity,
                         long sceneRevision, int baseX, int baseY, int baseZ) {
        ArrayList<ResolvedLight> resolved = new ArrayList<>();
        ArrayList<OfflineLocalLightIndex.Source> sources = new ArrayList<>();
        ArrayList<OfflineLocalLightIndex.Receiver> receivers = new ArrayList<>(sections.size());
        for (RtSectionTable.SectionGeom section : sections) {
            receivers.add(new OfflineLocalLightIndex.Receiver(
                    section.slot, section.sx >> 4, section.sy >> 4, section.sz >> 4));
            MemoryUtil.memSet(section.lightIndices.mapped, 0xFF, section.lightIndices.size);
            for (CpuLight light : section.staticLights) {
                ResolvedLight value = resolve(light,
                        section.sx - baseX, section.sy - baseY, section.sz - baseZ,
                        baseX, baseY, baseZ);
                if (value == null) {
                    continue;
                }
                int index = resolved.size();
                resolved.add(value);
                sources.add(new OfflineLocalLightIndex.Source(index,
                        section.sx >> 4, section.sy >> 4, section.sz >> 4, value.weight));
                if (light.kind == AREA) {
                    MemoryUtil.memPutInt(section.lightIndices.mapped
                            + (long) light.triangleIndex * Integer.BYTES, index);
                }
            }
            section.lightIndices.flush();
        }
        for (Long2ObjectMap.Entry<CpuLight[]> entry : lightOnlySections.long2ObjectEntrySet()) {
            int sx = sectionX(entry.getLongKey());
            int sy = sectionY(entry.getLongKey());
            int sz = sectionZ(entry.getLongKey());
            CpuLight[] lights = entry.getValue();
            for (CpuLight light : lights) {
                ResolvedLight value = resolve(light, 0.0f, 0.0f, 0.0f, baseX, baseY, baseZ);
                if (value != null) {
                    int index = resolved.size();
                    resolved.add(value);
                    sources.add(new OfflineLocalLightIndex.Source(index, sx, sy, sz, value.weight));
                }
            }
        }

        if (resolved.isEmpty()) {
            destroyBuffers();
            snapshot = new Snapshot(0L, 0, 0.0f, 0L, 0, 0L, 0, sceneRevision);
            return;
        }

        OfflineLocalLightIndex.Build local = OfflineLocalLightIndex.build(
                slotCapacity,
                receivers.toArray(OfflineLocalLightIndex.Receiver[]::new),
                sources.toArray(OfflineLocalLightIndex.Source[]::new));

        RtBuffer nextGlobal = null;
        RtBuffer nextDirectories = null;
        RtBuffer nextReferences = null;
        float cumulative = 0.0f;
        try {
            nextGlobal = ctx.createBuffer((long) resolved.size() * GPU_RECORD_BYTES,
                    VK10.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, true, "offline static lights");
            for (int i = 0; i < resolved.size(); i++) {
                ResolvedLight light = resolved.get(i);
                cumulative += light.weight;
                if (!Float.isFinite(cumulative)) {
                    throw new IllegalArgumentException(
                            "global static-light cumulative weight must remain finite");
                }
                write(nextGlobal.mapped + (long) i * GPU_RECORD_BYTES, light, cumulative);
            }
            nextGlobal.flush();

            OfflineLocalLightIndex.Reference[] references = local.references();
            if (slotCapacity > 0 && references.length > 0) {
                nextDirectories = ctx.createBuffer((long) slotCapacity * LOCAL_DIRECTORY_BYTES,
                        VK10.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, true, "offline local light directories");
                MemoryUtil.memSet(nextDirectories.mapped, 0, nextDirectories.size);
                OfflineLocalLightIndex.Directory[] directories = local.directories();
                for (int i = 0; i < directories.length; i++) {
                    writeDirectory(nextDirectories.mapped + (long) i * LOCAL_DIRECTORY_BYTES, directories[i]);
                }
                nextDirectories.flush();
            }

            if (references.length > 0) {
                nextReferences = ctx.createBuffer((long) references.length * LOCAL_REFERENCE_BYTES,
                        VK10.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, true, "offline local light references");
                for (int i = 0; i < references.length; i++) {
                    writeReference(nextReferences.mapped + (long) i * LOCAL_REFERENCE_BYTES, references[i]);
                }
                nextReferences.flush();
            }
        } catch (Throwable t) {
            destroy(nextReferences);
            destroy(nextDirectories);
            destroy(nextGlobal);
            throw t;
        }

        destroyBuffers();
        buffer = nextGlobal;
        localDirectoryBuffer = nextDirectories;
        localReferenceBuffer = nextReferences;
        snapshot = new Snapshot(
                buffer.deviceAddress, resolved.size(), cumulative,
                localDirectoryBuffer == null ? 0L : localDirectoryBuffer.deviceAddress,
                localDirectoryBuffer == null ? 0 : slotCapacity,
                localReferenceBuffer == null ? 0L : localReferenceBuffer.deviceAddress,
                local.references().length, sceneRevision);
    }

    private static ResolvedLight resolve(CpuLight light, float ox, float oy, float oz,
                                         int baseX, int baseY, int baseZ) {
        if (light.kind == POINT) {
            float intensity = OfflineStaticLightMath.pointIntensity(Math.round(light.emission * 15.0f));
            if (!(intensity > 0.0f)) {
                return null;
            }
            return new ResolvedLight(POINT,
                    light.p0x - baseX, light.p0y - baseY, light.p0z - baseZ,
                    0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0,
                    1, 1, 1, light.emission, false, intensity, intensity, 0.0f);
        }
        float e1x = light.p1x - light.p0x;
        float e1y = light.p1y - light.p0y;
        float e1z = light.p1z - light.p0z;
        float e2x = light.p2x - light.p0x;
        float e2y = light.p2y - light.p0y;
        float e2z = light.p2z - light.p0z;
        float cx = e1y * e2z - e1z * e2y;
        float cy = e1z * e2x - e1x * e2z;
        float cz = e1x * e2y - e1y * e2x;
        float area = 0.5f * (float) Math.sqrt(cx * cx + cy * cy + cz * cz);
        float weight = OfflineLightMixtureMath.alphaCoverageWeight(
                area, light.emission, RtTerrainMesher.alphaCoverage(light.sprite));
        if (!(weight > 0.0f)) {
            return null;
        }
        boolean hasS = light.sprite != null
                && (RtBlockMaterials.INSTANCE.ensure(light.sprite) & RtBlockMaterials.HAS_S) != 0;
        return new ResolvedLight(AREA,
                light.p0x + ox, light.p0y + oy, light.p0z + oz,
                e1x, e1y, e1z, e2x, e2y, e2z,
                light.u0, light.v0, light.u1, light.v1, light.u2, light.v2,
                light.tintR, light.tintG, light.tintB, light.emission, hasS, 0.0f, weight, area);
    }

    private static void write(long p, ResolvedLight l, float cumulative) {
        put4(p, l.p0x, l.p0y, l.p0z, l.kind);
        put4(p + 16, l.e1x, l.e1y, l.e1z, cumulative);
        put4(p + 32, l.e2x, l.e2y, l.e2z, l.area);
        put4(p + 48, l.u0, l.v0, l.u1, l.v1);
        put4(p + 64, l.u2, l.v2, l.emission, l.weight);
        put4(p + 80, l.tintR, l.tintG, l.tintB, l.hasS ? 1.0f : 0.0f);
        put4(p + 96, l.intensity, 0, 0, 0);
        put4(p + 112, 0, 0, 0, 0);
    }

    private static void writeDirectory(long p, OfflineLocalLightIndex.Directory directory) {
        MemoryUtil.memPutInt(p, directory.offset());
        MemoryUtil.memPutInt(p + 4, directory.count());
        MemoryUtil.memPutFloat(p + 8, directory.totalWeight());
        MemoryUtil.memPutFloat(p + 12, 0.0f);
    }

    private static void writeReference(long p, OfflineLocalLightIndex.Reference reference) {
        MemoryUtil.memPutInt(p, reference.globalIndex());
        MemoryUtil.memPutFloat(p + 4, reference.cumulativeWeight());
    }

    private void destroyBuffers() {
        destroy(localReferenceBuffer);
        destroy(localDirectoryBuffer);
        destroy(buffer);
        localReferenceBuffer = null;
        localDirectoryBuffer = null;
        buffer = null;
    }

    private static void destroy(RtBuffer value) {
        if (value != null) {
            value.destroy();
        }
    }

    private static int sectionX(long key) {
        return (int) (key << 38 >> 38);
    }

    private static int sectionZ(long key) {
        return (int) (key << 12 >> 38);
    }

    private static int sectionY(long key) {
        return (int) (key >> 52);
    }

    private static void put4(long p, float x, float y, float z, float w) {
        MemoryUtil.memPutFloat(p, x);
        MemoryUtil.memPutFloat(p + 4, y);
        MemoryUtil.memPutFloat(p + 8, z);
        MemoryUtil.memPutFloat(p + 12, w);
    }

    private record ResolvedLight(int kind,
                                 float p0x, float p0y, float p0z,
                                 float e1x, float e1y, float e1z,
                                 float e2x, float e2y, float e2z,
                                 float u0, float v0, float u1, float v1, float u2, float v2,
                                 float tintR, float tintG, float tintB, float emission,
                                 boolean hasS, float intensity, float weight, float area) {
    }

    /**
     * Immutable light candidate. Area-light positions are section-local and reference their packed
     * terrain triangle; invisible point-light positions are world-space and use {@link #NO_LIGHT}.
     */
    record CpuLight(
            int kind,
            int triangleIndex,
            float p0x, float p0y, float p0z,
            float p1x, float p1y, float p1z,
            float p2x, float p2y, float p2z,
            float u0, float v0, float u1, float v1, float u2, float v2,
            float tintR, float tintG, float tintB,
            float emission,
            TextureAtlasSprite sprite
    ) {
        CpuLight {
            if (kind != AREA && kind != POINT) {
                throw new IllegalArgumentException("unknown static light kind " + kind);
            }
            if (kind == AREA && triangleIndex < 0) {
                throw new IllegalArgumentException("area light requires a packed triangle index");
            }
            if (!(emission > 0.0f) || !Float.isFinite(emission)) {
                throw new IllegalArgumentException("static light emission must be finite and positive");
            }
        }

        static CpuLight point(float x, float y, float z, int level) {
            int clamped = Math.max(1, Math.min(15, level));
            return new CpuLight(POINT, NO_LIGHT,
                    x, y, z, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0,
                    1, 1, 1, clamped / 15.0f, null);
        }

        static CpuLight area(int triangleIndex,
                             float p0x, float p0y, float p0z,
                             float p1x, float p1y, float p1z,
                             float p2x, float p2y, float p2z,
                             float u0, float v0, float u1, float v1, float u2, float v2,
                             float tintR, float tintG, float tintB, float emission,
                             TextureAtlasSprite sprite) {
            return new CpuLight(AREA, triangleIndex,
                    p0x, p0y, p0z, p1x, p1y, p1z, p2x, p2y, p2z,
                    u0, v0, u1, v1, u2, v2,
                    tintR, tintG, tintB, emission, sprite);
        }

        CpuLight withTriangleOffset(int offset) {
            if (kind != AREA || offset == 0) {
                return this;
            }
            return new CpuLight(kind, Math.addExact(triangleIndex, offset),
                    p0x, p0y, p0z, p1x, p1y, p1z, p2x, p2y, p2z,
                    u0, v0, u1, v1, u2, v2,
                    tintR, tintG, tintB, emission, sprite);
        }
    }
}
