package dev.comfyfluffy.caustica.rt.offline;

import dev.comfyfluffy.caustica.CausticaMod;
import dev.comfyfluffy.caustica.rt.RtContext;
import dev.comfyfluffy.caustica.rt.accel.RtBuffer;
import net.fabricmc.loader.api.FabricLoader;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;
import org.lwjgl.vulkan.VkCommandBuffer;
import org.lwjgl.vulkan.VkDependencyInfo;
import org.lwjgl.vulkan.VkMemoryBarrier2;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

import static org.lwjgl.vulkan.KHRSynchronization2.*;
import static org.lwjgl.vulkan.VK10.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;

/** Bounded diagnostic readback. No transport changes and no render-thread disk writes or GPU waits. */
public final class RtOfflinePathProbe {
    public static final float THRESHOLD = 32.0f;
    private static final int MAX_RECORDS = 256;
    private static final int MAX_PROCESS_RECORDS = 2048;
    private static final long MAX_BYTES = 16L * 1024 * 1024;
    private final Slot[] slots = new Slot[3];
    private volatile boolean disabled = !Boolean.parseBoolean(System.getProperty("caustica.offline.pathProbe", "true"));
    private Slot recording;
    private final OfflinePathProbeBudget budget = new OfflinePathProbeBudget(MAX_RECORDS, MAX_PROCESS_RECORDS);
    private long writtenBytes;
    private ThreadPoolExecutor writer;
    private Path output;

    private static final class Slot {
        final RtBuffer buffer;
        final OfflinePathProbeOwnership ownership = new OfflinePathProbeOwnership();
        String metadata;
        long generation;
        Slot(RtBuffer buffer) { this.buffer = buffer; }
    }

    /** Called only on the render thread; completed timeline values, never frame counts, release slots. */
    public void poll(RtContext ctx) {
        try {
            boolean inFlight = false;
            for (Slot slot : slots) if (slot != null && !slot.ownership.available()) inFlight = true;
            if (!inFlight) return;
            drain(ctx.gpuExecutor().completedGraphicsValue());
        } catch (Throwable t) { disable(t); }
    }

    private void drain(long completed) {
        for (Slot slot : slots) {
            if (slot == null || !slot.ownership.readable(completed)) continue;
            if (!disabled && budget.remaining(slot.generation) > 0) {
                slot.buffer.invalidate();
                ByteBuffer bytes = MemoryUtil.memByteBuffer(slot.buffer.mapped, OfflinePathProbeCodec.BUFFER_BYTES);
                List<String> records = OfflinePathProbeCodec.decode(bytes, slot.metadata, budget.remaining(slot.generation));
                if (!records.isEmpty()) {
                    ensureWriter();
                    writer.execute(() -> write(records));
                    budget.accept(slot.generation, records.size());
                }
            }
            slot.ownership.release(completed);
        }
    }

    public long begin(RtContext ctx, boolean accumulating, long samples, String metadata) {
        budget.observe(accumulating, samples);
        if (disabled || !accumulating || samples < 256 || budget.remaining(budget.generation()) == 0) return 0L;
        try {
            // An unsubmitted recording is retained until device-idle teardown, never recycled by guesswork.
            if (recording != null) return 0L;
            for (int i = 0; i < slots.length; i++) {
                if (slots[i] == null) slots[i] = new Slot(ctx.createBuffer(OfflinePathProbeCodec.BUFFER_BYTES,
                        VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, true, "offline path probe " + i));
                Slot slot = slots[i];
                if (!slot.ownership.available()) continue;
                if (slot.buffer.mapped == 0L) throw new IllegalStateException("Probe buffer is not mapped");
                MemoryUtil.memSet(slot.buffer.mapped, 0, OfflinePathProbeCodec.BUFFER_BYTES);
                MemoryUtil.memByteBuffer(slot.buffer.mapped, OfflinePathProbeCodec.BUFFER_BYTES)
                        .order(ByteOrder.LITTLE_ENDIAN).putInt(4, OfflinePathProbeCodec.CAPACITY);
                slot.buffer.flush();
                slot.generation = budget.generation();
                slot.metadata = "\"captureGeneration\":" + slot.generation + "," + metadata;
                slot.ownership.acquire();
                recording = slot;
                if (writer == null) {
                    ensureWriter();
                    // A session file also proves the probe activated when no path crossed the threshold.
                    writer.execute(() -> write(List.of()));
                }
                return slot.buffer.deviceAddress;
            }
        } catch (Throwable t) { disable(t); }
        return 0L;
    }

    /** Host reset is flushed before submission; make raygen writes available to later host reads. */
    public void afterTrace(VkCommandBuffer cmd, MemoryStack stack, long address) {
        if (address == 0L) return;
        VkMemoryBarrier2.Buffer barrier = VkMemoryBarrier2.calloc(1, stack);
        barrier.get(0).sType$Default()
                .srcStageMask(VK_PIPELINE_STAGE_2_RAY_TRACING_SHADER_BIT_KHR)
                .srcAccessMask(VK_ACCESS_2_SHADER_WRITE_BIT_KHR)
                .dstStageMask(VK_PIPELINE_STAGE_2_HOST_BIT_KHR)
                .dstAccessMask(VK_ACCESS_2_HOST_READ_BIT_KHR);
        vkCmdPipelineBarrier2KHR(cmd, VkDependencyInfo.calloc(stack).sType$Default().pMemoryBarriers(barrier));
    }

    public void submitted(long graphicsUse) {
        if (recording == null) return;
        recording.ownership.submitted(graphicsUse);
        recording = null;
    }

    public void signalAttached(long graphicsUse) {
        for (Slot slot : slots) if (slot != null) slot.ownership.signalAttached(graphicsUse);
    }

    private void ensureWriter() {
        if (writer != null) return;
        output = FabricLoader.getInstance().getGameDir().resolve("logs").resolve("caustica-paths-"
                + LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss-SSS")) + ".jsonl");
        writer = new ThreadPoolExecutor(1, 1, 0L, TimeUnit.MILLISECONDS, new ArrayBlockingQueue<>(8), task -> {
            Thread thread = new Thread(task, "caustica-path-probe-writer");
            thread.setDaemon(true);
            return thread;
        });
    }

    private void write(List<String> records) {
        if (disabled) return;
        try {
            if (writtenBytes == 0L) {
                Files.createDirectories(output.getParent());
                String version = FabricLoader.getInstance().getModContainer("caustica").orElseThrow()
                        .getMetadata().getVersion().getFriendlyString();
                String header = "{\"type\":\"session\",\"version\":\"" + version.replace("\\", "\\\\").replace("\"", "\\\"")
                        + "\",\"threshold\":" + THRESHOLD + ",\"maxRecords\":" + MAX_RECORDS
                        + ",\"maxProcessRecords\":" + MAX_PROCESS_RECORDS
                        + ",\"captureScope\":\"surface direct lighting and secondary emitter/sky/celestial contributions; primary visible sources excluded; quota resets with accumulation\""
                        + ",\"normalSemantics\":\"geometricNormal_material holds returned shading normal for ordinary normal-mapped hits; geometric normal for water\"}\n";
                byte[] data = header.getBytes(StandardCharsets.UTF_8);
                Files.write(output, data, StandardOpenOption.CREATE_NEW);
                writtenBytes += data.length;
                CausticaMod.LOGGER.info("Offline path probe log: {}", output);
            }
            StringBuilder text = new StringBuilder();
            for (String record : records) text.append(record).append('\n');
            byte[] data = text.toString().getBytes(StandardCharsets.UTF_8);
            if (writtenBytes + data.length > MAX_BYTES) {
                disabled = true;
                CausticaMod.LOGGER.info("Offline path probe reached its byte budget: {}", output);
                return;
            }
            Files.write(output, data, StandardOpenOption.APPEND);
            writtenBytes += data.length;
        } catch (Throwable t) { disable(t); }
    }

    private void disable(Throwable t) {
        if (!disabled) CausticaMod.LOGGER.warn("Offline path probe disabled; rendering continues", t);
        disabled = true;
    }

    /** Only called by existing device-idle renderer teardown; pending reads are copied before freeing. */
    public void destroyAfterDeviceIdle() {
        try { drain(Long.MAX_VALUE); } catch (Throwable t) { disable(t); }
        for (int i = 0; i < slots.length; i++) {
            if (slots[i] != null) slots[i].buffer.destroy();
            slots[i] = null;
        }
        recording = null;
        if (writer != null) writer.shutdown();
    }
}
