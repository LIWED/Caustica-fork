$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$javaHome = 'D:\program\java25'
$javac = Join-Path $javaHome 'bin\javac.exe'
$java = Join-Path $javaHome 'bin\java.exe'
$outputDir = Join-Path ([System.IO.Path]::GetTempPath()) ('caustica-realtime-light-' + [guid]::NewGuid().ToString('N'))

if (-not (Test-Path -LiteralPath $javac) -or -not (Test-Path -LiteralPath $java)) {
    throw 'Java 25 is required at D:\program\java25.'
}

New-Item -ItemType Directory -Path $outputDir | Out-Null
& $javac --release 25 -d $outputDir `
    (Join-Path $projectRoot 'src\main\java\dev\comfyfluffy\caustica\rt\offline\OfflineStaticLightMath.java') `
    (Join-Path $projectRoot 'src\main\java\dev\comfyfluffy\caustica\rt\light\RealtimeLightBlockIndex.java') `
    (Join-Path $projectRoot 'scripts\tests\RealtimeLightBlockBehaviorTest.java')
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $java -cp $outputDir dev.comfyfluffy.caustica.rt.light.RealtimeLightBlockBehaviorTest
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $javac --release 25 -d $outputDir `
    (Join-Path $projectRoot 'src\main\java\dev\comfyfluffy\caustica\rt\terrain\DirtyGroupGenerationOwnership.java') `
    (Join-Path $projectRoot 'scripts\tests\DirtyGroupGenerationOwnershipBehaviorTest.java')
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $java -cp $outputDir dev.comfyfluffy.caustica.rt.terrain.DirtyGroupGenerationOwnershipBehaviorTest
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $javac --release 25 -d $outputDir `
    (Join-Path $projectRoot 'src\main\java\dev\comfyfluffy\caustica\rt\terrain\TerrainRebasePolicy.java') `
    (Join-Path $projectRoot 'scripts\tests\TerrainRebasePolicyBehaviorTest.java')
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $java -cp $outputDir dev.comfyfluffy.caustica.rt.terrain.TerrainRebasePolicyBehaviorTest
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$harnessRoot = Join-Path $outputDir 'harness-src'
$rtDir = Join-Path $harnessRoot 'dev\comfyfluffy\caustica\rt'
$accelDir = Join-Path $rtDir 'accel'
$terrainDir = Join-Path $rtDir 'terrain'
$lwjglSystemDir = Join-Path $harnessRoot 'org\lwjgl\system'
$lwjglVulkanDir = Join-Path $harnessRoot 'org\lwjgl\vulkan'
$jomlDir = Join-Path $harnessRoot 'org\joml'
New-Item -ItemType Directory -Path $accelDir, $terrainDir, $lwjglSystemDir, $lwjglVulkanDir, $jomlDir | Out-Null

@'
package dev.comfyfluffy.caustica.rt;

import dev.comfyfluffy.caustica.rt.accel.RtBuffer;

import java.util.ArrayList;
import java.util.List;

public final class RtContext {
    public final RtGpuExecutor executor = new RtGpuExecutor();
    public final List<RtBuffer> buffers = new ArrayList<>();
    public int createCalls;
    public int waitIdleCalls;
    public long lastSize;
    public int lastUsage;
    public boolean lastHostVisible;
    public String lastLabel;
    public boolean failNextAllocation;
    public boolean failNextFlush;
    public Runnable nextFlushHook;
    private static long nextAddress = 0x10000L;

    public RtBuffer createBuffer(long size, int usage, boolean hostVisible, String label) {
        createCalls++;
        lastSize = size;
        lastUsage = usage;
        lastHostVisible = hostVisible;
        lastLabel = label;
        if (failNextAllocation) {
            failNextAllocation = false;
            throw new IllegalStateException("injected allocation failure");
        }
        nextAddress += 0x1000L;
        RtBuffer result = new RtBuffer(nextAddress + 0x400L, nextAddress, size,
                failNextFlush, nextFlushHook, executor.events);
        failNextFlush = false;
        nextFlushHook = null;
        buffers.add(result);
        return result;
    }

    public RtGpuExecutor gpuExecutor() {
        return executor;
    }

    public void waitIdle() {
        waitIdleCalls++;
        throw new AssertionError("ordinary realtime Light-block publication must not wait idle");
    }
}
'@ | Set-Content -Encoding ascii -LiteralPath (Join-Path $rtDir 'RtContext.java')

@'
package dev.comfyfluffy.caustica.rt;

import java.util.ArrayList;
import java.util.List;

public final class RtGpuExecutor {
    public record Retired(long lastUseValue, Runnable destroy) {}

    public final List<String> events = new ArrayList<>();
    public final List<Retired> retired = new ArrayList<>();
    public long latestValue = 71L;
    public int latestCalls;
    public int markPublishedCalls;
    public Runnable latestHook;
    public Runnable enqueueHook;

    public long latestGraphicsUseValue() {
        events.add("latest");
        latestCalls++;
        if (latestHook != null) {
            latestHook.run();
        }
        return latestValue;
    }

    public void enqueueDestroyAfterGraphics(long lastUseValue, Runnable destroy) {
        events.add("enqueue");
        if (enqueueHook != null) {
            enqueueHook.run();
        }
        retired.add(new Retired(lastUseValue, destroy));
    }

    public void markPublished(Object ignored) {
        markPublishedCalls++;
        throw new AssertionError("realtime host writes must not be marked as GPU builds");
    }
}
'@ | Set-Content -Encoding ascii -LiteralPath (Join-Path $rtDir 'RtGpuExecutor.java')

@'
package dev.comfyfluffy.caustica.rt.accel;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;

public final class RtBuffer {
    private static final List<RtBuffer> ALL = new ArrayList<>();

    public final long deviceAddress;
    public final long mapped;
    public final long size;
    public boolean flushed;
    public boolean destroyed;
    private final byte[] bytes;
    private final boolean failFlush;
    private final Runnable flushHook;
    private final List<String> events;

    public RtBuffer(long deviceAddress, long mapped, long size, boolean failFlush,
                    Runnable flushHook, List<String> events) {
        this.deviceAddress = deviceAddress;
        this.mapped = mapped;
        this.size = size;
        this.bytes = new byte[Math.toIntExact(size)];
        this.failFlush = failFlush;
        this.flushHook = flushHook;
        this.events = events;
        ALL.add(this);
    }

    public void flush() {
        events.add("flush");
        if (flushHook != null) {
            flushHook.run();
        }
        if (failFlush) {
            throw new IllegalStateException("injected flush failure");
        }
        flushed = true;
    }

    public void destroy() {
        destroyed = true;
    }

    public float floatAt(int offset) {
        return ByteBuffer.wrap(bytes).order(ByteOrder.nativeOrder()).getFloat(offset);
    }

    public static void putFloat(long address, float value) {
        for (RtBuffer buffer : ALL) {
            long offset = address - buffer.mapped;
            if (offset >= 0L && offset + Float.BYTES <= buffer.size) {
                ByteBuffer.wrap(buffer.bytes).order(ByteOrder.nativeOrder())
                        .putFloat(Math.toIntExact(offset), value);
                return;
            }
        }
        throw new IllegalArgumentException("unknown mapped address " + address);
    }
}
'@ | Set-Content -Encoding ascii -LiteralPath (Join-Path $accelDir 'RtBuffer.java')

@'
package org.lwjgl.system;

import dev.comfyfluffy.caustica.rt.accel.RtBuffer;

public final class MemoryUtil {
    public static boolean failNextPut;

    private MemoryUtil() {}

    public static void memPutFloat(long address, float value) {
        if (failNextPut) {
            failNextPut = false;
            throw new IllegalStateException("injected mapped-write failure");
        }
        RtBuffer.putFloat(address, value);
    }
}
'@ | Set-Content -Encoding ascii -LiteralPath (Join-Path $lwjglSystemDir 'MemoryUtil.java')

@'
package org.lwjgl.vulkan;

public final class VK10 {
    public static final int VK_BUFFER_USAGE_STORAGE_BUFFER_BIT = 0x20;

    private VK10() {}
}
'@ | Set-Content -Encoding ascii -LiteralPath (Join-Path $lwjglVulkanDir 'VK10.java')

@'
package org.joml;

import java.nio.ByteBuffer;

public interface Matrix4fc {
    Matrix4fc get(int index, ByteBuffer destination);
}
'@ | Set-Content -Encoding ascii -LiteralPath (Join-Path $jomlDir 'Matrix4fc.java')

$generatedWorldPush = Join-Path $projectRoot 'build\generated\sources\shaderRecords\dev\comfyfluffy\caustica\rt\gen\WorldPushData.java'
if (-not (Test-Path -LiteralPath $generatedWorldPush -PathType Leaf)) {
    throw "Generated WorldPushData source is missing: $generatedWorldPush"
}

& $javac --release 25 -d $outputDir `
    (Join-Path $jomlDir 'Matrix4fc.java') `
    $generatedWorldPush `
    (Join-Path $projectRoot 'scripts\tests\WorldPushDataAbiBehaviorTest.java')
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $java -cp $outputDir dev.comfyfluffy.caustica.rt.gen.WorldPushDataAbiBehaviorTest
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

@'
package dev.comfyfluffy.caustica.rt.terrain;

import dev.comfyfluffy.caustica.rt.RtContext;
import dev.comfyfluffy.caustica.rt.accel.RtBuffer;
import dev.comfyfluffy.caustica.rt.light.RealtimeLightBlockIndex;
import dev.comfyfluffy.caustica.rt.light.RealtimeLightBlockIndex.Source;
import org.lwjgl.system.MemoryUtil;
import org.lwjgl.vulkan.VK10;

import java.util.Arrays;
import java.util.Collection;
import java.util.List;

public final class RtRealtimeLightBlocksBehaviorTest {
    private static final float EPSILON = 1.0e-6f;
    private static final float LEVEL_15_INTENSITY = 0.5890486f;

    private RtRealtimeLightBlocksBehaviorTest() {}

    public static void main(String[] args) {
        writesExactRecordAndCachesMatchingRevision();
        replacementPublishesBeforeTimelineRetirement();
        emptyBuildPublishesWithoutZeroSizeAllocation();
        failuresPreservePreviousGeneration();
        destroyDropsTheCurrentGeneration();
        System.out.println("Realtime Light-block GPU table behavior: PASS");
    }

    private static void writesExactRecordAndCachesMatchingRevision() {
        RtContext ctx = new RtContext();
        RtRealtimeLightBlocks table = new RtRealtimeLightBlocks();
        Collection<Source[]> sections = Arrays.asList(
                new Source[]{new Source(100.5f, 64.5f, -20.5f, 15)},
                new Source[]{new Source(1.5f, 2.5f, 3.5f, 0)});

        RtRealtimeLightBlocks.Snapshot snapshot = table.ensure(ctx, sections, 4L, 96, 64, -32);
        RtBuffer buffer = ctx.buffers.get(0);

        check(ctx.createCalls == 1, "one non-empty generation must allocate once");
        check(ctx.lastSize == RealtimeLightBlockIndex.GPU_RECORD_BYTES,
                "one entry must allocate exactly one 32-byte record");
        check(ctx.lastUsage == VK10.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                "the table must request storage-buffer usage");
        check(ctx.lastHostVisible, "the table must be host-visible");
        check("realtime Light blocks".equals(ctx.lastLabel), "the allocation label must match the contract");
        check(buffer.flushed, "the complete candidate must be flushed before return");
        check(snapshot.address() == buffer.deviceAddress, "snapshot must publish the candidate BDA");
        check(snapshot.count() == 1, "level zero must not enter the GPU table");
        close(snapshot.totalWeight(), LEVEL_15_INTENSITY, "published total weight");
        check(snapshot.revision() == 4L, "snapshot must publish the requested revision");
        close(buffer.floatAt(0), 4.5f, "lane 0 relative x");
        close(buffer.floatAt(4), 0.5f, "lane 1 relative y");
        close(buffer.floatAt(8), 11.5f, "lane 2 relative z");
        close(buffer.floatAt(12), LEVEL_15_INTENSITY, "lane 3 cumulative weight");
        close(buffer.floatAt(16), LEVEL_15_INTENSITY, "lane 4 radiance R");
        close(buffer.floatAt(20), LEVEL_15_INTENSITY, "lane 5 radiance G");
        close(buffer.floatAt(24), LEVEL_15_INTENSITY, "lane 6 radiance B");
        close(buffer.floatAt(28), LEVEL_15_INTENSITY, "lane 7 selection weight");

        RtRealtimeLightBlocks.Snapshot cached = table.ensure(ctx,
                List.<Source[]>of(new Source[]{new Source(999.5f, 999.5f, 999.5f, 1)}),
                4L, 0, 0, 0);
        check(cached == snapshot, "a matching revision must return the current immutable snapshot");
        check(ctx.createCalls == 1, "a matching revision must not rebuild");
        check(ctx.waitIdleCalls == 0, "ordinary publication must not call waitIdle");
        check(ctx.executor.markPublishedCalls == 0, "host writes must not call markPublished");
    }

    private static void replacementPublishesBeforeTimelineRetirement() {
        RtContext ctx = new RtContext();
        RtRealtimeLightBlocks table = new RtRealtimeLightBlocks();
        RtRealtimeLightBlocks.Snapshot oldSnapshot = table.ensure(ctx, oneSource(1.5f), 1L, 0, 0, 0);
        RtBuffer oldBuffer = ctx.buffers.get(0);
        ctx.executor.events.clear();
        ctx.executor.latestValue = 93L;
        ctx.nextFlushHook = () -> check(table.current() == oldSnapshot,
                "candidate flush must happen before publication");
        ctx.executor.latestHook = () -> check(table.current() == oldSnapshot,
                "graphics-use value must be captured immediately before publication");
        ctx.executor.enqueueHook = () -> check(table.current().revision() == 2L,
                "old generation must be enqueued only after the replacement is published");

        RtRealtimeLightBlocks.Snapshot replacement = table.ensure(ctx, oneSource(2.5f), 2L, 0, 0, 0);

        check(replacement.revision() == 2L, "replacement revision");
        check(ctx.executor.events.equals(List.of("flush", "latest", "enqueue")),
                "replacement ordering must be flush, graphics capture, publication, retirement enqueue");
        check(ctx.executor.retired.size() == 1, "one old generation must be retired");
        check(ctx.executor.retired.get(0).lastUseValue() == 93L,
                "retirement must use the captured graphics timeline value");
        check(!oldBuffer.destroyed, "timeline retirement must not destroy the old buffer immediately");
        ctx.executor.retired.get(0).destroy().run();
        check(oldBuffer.destroyed, "retirement callback must destroy the old generation");
    }

    private static void emptyBuildPublishesWithoutZeroSizeAllocation() {
        RtContext ctx = new RtContext();
        RtRealtimeLightBlocks table = new RtRealtimeLightBlocks();
        table.ensure(ctx, oneSource(1.5f), 1L, 0, 0, 0);
        RtBuffer oldBuffer = ctx.buffers.get(0);
        int allocationsBefore = ctx.createCalls;
        ctx.executor.events.clear();
        ctx.executor.retired.clear();
        ctx.executor.latestValue = 101L;
        ctx.executor.latestHook = () -> check(table.current().revision() == 1L,
                "empty replacement must capture graphics use before publication");
        ctx.executor.enqueueHook = () -> check(table.current().revision() == 2L,
                "empty replacement must publish before retiring the old generation");

        RtRealtimeLightBlocks.Snapshot empty = table.ensure(ctx, List.of(), 2L, 0, 0, 0);

        check(ctx.createCalls == allocationsBefore, "an empty build must not allocate a zero-size buffer");
        check(empty.address() == 0L && empty.count() == 0 && empty.totalWeight() == 0.0f,
                "empty publication must expose the zero table");
        check(empty.revision() == 2L, "empty publication must retain the requested revision");
        check(ctx.executor.events.equals(List.of("latest", "enqueue")),
                "empty replacement must capture then retire without a flush");
        check(ctx.executor.retired.get(0).lastUseValue() == 101L,
                "empty replacement retirement must use the captured timeline value");
        check(!oldBuffer.destroyed, "empty publication must defer old destruction");
    }

    private static void failuresPreservePreviousGeneration() {
        RtContext ctx = new RtContext();
        RtRealtimeLightBlocks table = new RtRealtimeLightBlocks();
        RtRealtimeLightBlocks.Snapshot baseline = table.ensure(ctx, oneSource(1.5f), 1L, 0, 0, 0);
        RtBuffer baselineBuffer = ctx.buffers.get(0);
        int retiredBefore = ctx.executor.retired.size();

        ctx.failNextAllocation = true;
        expectFailure(() -> table.ensure(ctx, oneSource(2.5f), 2L, 0, 0, 0),
                "allocation failure must escape");
        assertPreserved(table, baseline, baselineBuffer, ctx, retiredBefore,
                "allocation failure");

        int buffersBeforeWrite = ctx.buffers.size();
        MemoryUtil.failNextPut = true;
        expectFailure(() -> table.ensure(ctx, oneSource(3.5f), 3L, 0, 0, 0),
                "mapped-write failure must escape");
        check(ctx.buffers.size() == buffersBeforeWrite + 1, "write failure must have one candidate");
        check(ctx.buffers.get(ctx.buffers.size() - 1).destroyed,
                "write failure must destroy only its unpublished candidate");
        assertPreserved(table, baseline, baselineBuffer, ctx, retiredBefore, "write failure");

        int buffersBeforeFlush = ctx.buffers.size();
        ctx.failNextFlush = true;
        expectFailure(() -> table.ensure(ctx, oneSource(4.5f), 4L, 0, 0, 0),
                "flush failure must escape");
        check(ctx.buffers.size() == buffersBeforeFlush + 1, "flush failure must have one candidate");
        check(ctx.buffers.get(ctx.buffers.size() - 1).destroyed,
                "flush failure must destroy only its unpublished candidate");
        assertPreserved(table, baseline, baselineBuffer, ctx, retiredBefore, "flush failure");

        int allocationsBeforeBuild = ctx.createCalls;
        expectFailure(() -> table.ensure(ctx,
                        List.<Source[]>of(new Source[]{null}), 5L, 0, 0, 0),
                "build failure must escape");
        check(ctx.createCalls == allocationsBeforeBuild,
                "build failure must occur before candidate allocation");
        assertPreserved(table, baseline, baselineBuffer, ctx, retiredBefore, "build failure");
    }

    private static void destroyDropsTheCurrentGeneration() {
        RtContext ctx = new RtContext();
        RtRealtimeLightBlocks table = new RtRealtimeLightBlocks();
        table.ensure(ctx, oneSource(1.5f), 1L, 0, 0, 0);
        RtBuffer buffer = ctx.buffers.get(0);

        table.destroy();

        check(buffer.destroyed, "destroy must free the current table after the caller's graphics drain");
        check(table.current().equals(RtRealtimeLightBlocks.Snapshot.EMPTY),
                "destroy must restore the stale EMPTY snapshot");
    }

    private static Collection<Source[]> oneSource(float x) {
        return List.<Source[]>of(new Source[]{new Source(x, 2.5f, 3.5f, 15)});
    }

    private static void assertPreserved(RtRealtimeLightBlocks table,
                                        RtRealtimeLightBlocks.Snapshot baseline,
                                        RtBuffer baselineBuffer, RtContext ctx,
                                        int retiredBefore, String phase) {
        check(table.current() == baseline, phase + " must preserve the previous complete snapshot");
        check(!baselineBuffer.destroyed, phase + " must not destroy the published generation");
        check(ctx.executor.retired.size() == retiredBefore,
                phase + " must not enqueue the published generation for retirement");
    }

    private static void expectFailure(Runnable action, String message) {
        try {
            action.run();
        } catch (RuntimeException expected) {
            return;
        }
        throw new AssertionError(message);
    }

    private static void close(float actual, float expected, String message) {
        check(Math.abs(actual - expected) <= EPSILON,
                message + ": expected " + expected + ", got " + actual);
    }

    private static void check(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
'@ | Set-Content -Encoding ascii -LiteralPath (Join-Path $terrainDir 'RtRealtimeLightBlocksBehaviorTest.java')

& $javac --release 25 -d $outputDir `
    (Join-Path $projectRoot 'src\main\java\dev\comfyfluffy\caustica\rt\offline\OfflineStaticLightMath.java') `
    (Join-Path $projectRoot 'src\main\java\dev\comfyfluffy\caustica\rt\light\RealtimeLightBlockIndex.java') `
    (Join-Path $harnessRoot 'dev\comfyfluffy\caustica\rt\RtContext.java') `
    (Join-Path $harnessRoot 'dev\comfyfluffy\caustica\rt\RtGpuExecutor.java') `
    (Join-Path $harnessRoot 'dev\comfyfluffy\caustica\rt\accel\RtBuffer.java') `
    (Join-Path $harnessRoot 'org\lwjgl\system\MemoryUtil.java') `
    (Join-Path $harnessRoot 'org\lwjgl\vulkan\VK10.java') `
    (Join-Path $projectRoot 'src\main\java\dev\comfyfluffy\caustica\rt\terrain\RtRealtimeLightBlocks.java') `
    (Join-Path $harnessRoot 'dev\comfyfluffy\caustica\rt\terrain\RtRealtimeLightBlocksBehaviorTest.java')
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $java -cp $outputDir dev.comfyfluffy.caustica.rt.terrain.RtRealtimeLightBlocksBehaviorTest
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

# These are narrow source contracts for render-thread terrain flow. A Minecraft client is required to
# execute that flow, so the contracts assert the two state-ordering guarantees at its internal boundary.
$terrainText = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'src\main\java\dev\comfyfluffy\caustica\rt\terrain\RtTerrain.java')
$failures = [System.Collections.Generic.List[string]]::new()

$ownershipFieldValid =
        $terrainText -match 'private final DirtyGroupGenerationOwnership\s+dirtyGroupOwnership\s*=\s*new DirtyGroupGenerationOwnership\(\);'
if (-not $ownershipFieldValid) {
    $failures.Add('RtTerrain must consume the persistent dirty-group generation ownership policy')
}

$dirtySectionMatch = [regex]::Match(
        $terrainText,
        'private boolean handleDirtySection\(long key, long dirtyGroup\) \{(?<body>.*?)\r?\n    \}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$dirtySectionBody = if ($dirtySectionMatch.Success) { $dirtySectionMatch.Groups['body'].Value } else { '' }
$redirtyCancelIndex = $dirtySectionBody.IndexOf('cancelOwnedDirtyGroup(key)')
$redirtyInvalidateIndex = $dirtySectionBody.IndexOf('invalidateInFlight(key)')
if (-not $dirtySectionMatch.Success -or
        $redirtyCancelIndex -lt 0 -or
        $redirtyInvalidateIndex -lt 0 -or
        $redirtyCancelIndex -gt $redirtyInvalidateIndex) {
    $failures.Add('a new dirty event must cancel staged generation ownership before invalidating/queueing newer work')
}

$groupEligibilityMatch = [regex]::Match(
        $terrainText,
        'private boolean canGroupDirtySection\(long key\) \{(?<body>.*?)\r?\n    \}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$groupEligibilityBody = if ($groupEligibilityMatch.Success) {
    $groupEligibilityMatch.Groups['body'].Value
} else {
    ''
}
if (-not $groupEligibilityMatch.Success -or
        $groupEligibilityBody -notmatch 'dirtyGroupOwnership\.ownerOf\(key\)\s*!=\s*NO_DIRTY_GROUP') {
    $failures.Add('a staged-only owned key must remain eligible for the newer multi-section dirty generation')
}

$removeColumnMatch = [regex]::Match(
        $terrainText,
        'private void removeDesiredColumnSections\(.*?\) \{(?<body>.*?)\r?\n    \}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$removeColumnBody = if ($removeColumnMatch.Success) { $removeColumnMatch.Groups['body'].Value } else { '' }
$leaveDesiredIndex = $removeColumnBody.IndexOf('desired.remove(key)')
$leaveCancelIndex = $removeColumnBody.IndexOf('cancelOwnedDirtyGroup(key)')
$leaveResidentIndex = $removeColumnBody.IndexOf('resident.remove(key)')
if (-not $removeColumnMatch.Success -or
        $leaveDesiredIndex -lt 0 -or
        $leaveCancelIndex -lt $leaveDesiredIndex -or
        $leaveResidentIndex -lt $leaveCancelIndex) {
    $failures.Add('leaving desired must cancel staged ownership before resident geometry gains global retirement ownership')
}

$pruneMatch = [regex]::Match(
        $terrainText,
        'private void pruneUndesired\(List<SectionGeom> removed\) \{(?<body>.*?)\r?\n    \}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$pruneBody = if ($pruneMatch.Success) { $pruneMatch.Groups['body'].Value } else { '' }
$pruneCancelIndex = $pruneBody.IndexOf('cancelDirtyGroupsNotInDesired()')
$pruneResidentIndex = $pruneBody.IndexOf('resident.long2ObjectEntrySet()')
if (-not $pruneMatch.Success -or
        $pruneCancelIndex -lt 0 -or
        $pruneResidentIndex -lt 0 -or
        $pruneCancelIndex -gt $pruneResidentIndex) {
    $failures.Add('window rebuild pruning must cancel undesired staged owners before resident retirement')
}

$queueMethodMatch = [regex]::Match(
        $terrainText,
        'private void setQueuedGroup\(long key, long groupId\) \{(?<body>.*?)\r?\n    \}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$queueMethodBody = if ($queueMethodMatch.Success) { $queueMethodMatch.Groups['body'].Value } else { '' }
if (-not $queueMethodMatch.Success -or
        $queueMethodBody -notmatch 'dirtyGroupOwnership\.queue\(key, groupId\)') {
    $failures.Add('queued grouped work must claim persistent generation ownership')
}

$enqueueMissingStart = $terrainText.IndexOf('private boolean enqueueMissingIfNeeded(long key) {')
$enqueueMissingEnd = $terrainText.IndexOf(
        'private boolean enqueueMissing(long key, long dirtyGroup)',
        $enqueueMissingStart)
$enqueueMissingBody = if ($enqueueMissingStart -ge 0 -and $enqueueMissingEnd -gt $enqueueMissingStart) {
    $terrainText.Substring($enqueueMissingStart, $enqueueMissingEnd - $enqueueMissingStart)
} else {
    ''
}
$enqueueSetGroupIndex = $enqueueMissingBody.IndexOf('setQueuedGroup(key, NO_DIRTY_GROUP)')
$enqueuePostCancelGuardIndex = $enqueueMissingBody.IndexOf(
        'if (missingIndex.get(key) != NO_MISSING_INDEX)',
        [Math]::Max(0, $enqueueSetGroupIndex + 1))
$enqueueInsertIndex = $enqueueMissingBody.IndexOf(
        'missingIndex.put(key, missing.size())',
        [Math]::Max(0, $enqueueSetGroupIndex + 1))
if ($enqueueSetGroupIndex -lt 0 -or
        $enqueuePostCancelGuardIndex -lt $enqueueSetGroupIndex -or
        $enqueueInsertIndex -lt $enqueuePostCancelGuardIndex) {
    $failures.Add('ordinary missing enqueue must recheck the index after group cancellation can requeue the same key')
}

$dispatchMethodMatch = [regex]::Match(
        $terrainText,
        'private void dispatchSectionBuild\(.*?\) \{(?<body>.*?)\r?\n    \}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$dispatchMethodBody = if ($dispatchMethodMatch.Success) { $dispatchMethodMatch.Groups['body'].Value } else { '' }
if (-not $dispatchMethodMatch.Success -or
        $dispatchMethodBody -notmatch 'dirtyGroupOwnership\.ownerOf\(key\)' -or
        $dispatchMethodBody -notmatch 'dirtyGroupOwnership\.markInFlight\(key, dirtyGroup, token\)') {
    $failures.Add('dispatch must carry the authoritative group generation and token into the in-flight phase')
}

$drainMethodMatch = [regex]::Match(
        $terrainText,
        'private void drainCompletedBuilds\(.*?\) \{(?<body>.*?)\r?\n    \}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$drainMethodBody = if ($drainMethodMatch.Success) { $drainMethodMatch.Groups['body'].Value } else { '' }
$taskGroupIndex = $drainMethodBody.IndexOf('task.dirtyGroup')
$stageIndex = $drainMethodBody.IndexOf('dirtyGroupOwnership.stage(task.key, dirtyGroup, task.token)')
$staleContinueIndex = $drainMethodBody.IndexOf('continue;', [Math]::Max(0, $stageIndex))
if (-not $drainMethodMatch.Success -or
        $taskGroupIndex -lt 0 -or
        $stageIndex -lt $taskGroupIndex -or
        $staleContinueIndex -lt $stageIndex) {
    $failures.Add('grouped completion must validate immutable generation/token before staging and reject stale results')
}

$cancelMethodMatch = [regex]::Match(
        $terrainText,
        'private void cancelDirtyGroup\(long groupId\) \{(?<body>.*?)\r?\n    \}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$cancelMethodBody = if ($cancelMethodMatch.Success) { $cancelMethodMatch.Groups['body'].Value } else { '' }
$cancelGenerationIndex = $cancelMethodBody.IndexOf('dirtyGroupOwnership.cancelGeneration(groupId)')
$cancelTokenIndex = $cancelMethodBody.IndexOf('inFlight.remove(member.sectionKey())', [Math]::Max(0, $cancelGenerationIndex))
$cancelRequeueIndex = $cancelMethodBody.IndexOf('requeueCancelledGroupMember(key)', [Math]::Max(0, $cancelTokenIndex))
if (-not $cancelMethodMatch.Success -or
        $cancelGenerationIndex -lt 0 -or
        $cancelTokenIndex -lt $cancelGenerationIndex -or
        $cancelRequeueIndex -lt $cancelTokenIndex) {
    $failures.Add('cancellation must stale every owned in-flight token before requeueing still-desired extraction')
}

$completeGroupMatch = [regex]::Match(
        $terrainText,
        'private void completeDirtyGroupMember\(.*?\) \{(?<body>.*?)\r?\n    \}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$completeGroupBody = if ($completeGroupMatch.Success) { $completeGroupMatch.Groups['body'].Value } else { '' }
if (-not $completeGroupMatch.Success -or
        $completeGroupBody -notmatch 'dirtyGroupOwnership\.releaseForPublication\(' -or
        $completeGroupBody -notmatch 'desired::contains' -or
        $completeGroupBody -notmatch 'resident\.remove\(key\)' -or
        $completeGroupBody -notmatch 'empty\.add\(key\)') {
    $failures.Add('atomic group publication must revalidate generation/desired and transfer empty retirement once')
}

if ($terrainText -match 'group\.removed') {
    $failures.Add('old geometry must not be owned simultaneously by dirty-group and global removal collections')
}

$streamStart = $terrainText.IndexOf('private void stream(RtContext ctx) {')
$streamEnd = $terrainText.IndexOf('private void syncDesiredWindow(', $streamStart)
$streamBody = if ($streamStart -ge 0 -and $streamEnd -gt $streamStart) {
    $terrainText.Substring($streamStart, $streamEnd - $streamStart)
} else {
    ''
}
$streamPlayerIndex = $streamBody.IndexOf('int pbx = mc.player.getBlockX();')
$streamRebaseIndex = $streamBody.IndexOf('boolean rebase = shouldRebase(pbx, pby, pbz);')
$streamIdleIndex = $streamBody.IndexOf('TerrainRebasePolicy.shouldReturnIdle(hasTerrainWork, rebase)')
$streamDrainIndex = $streamBody.IndexOf('drainCompletedBuilds(')
$streamApplyGateIndex = $streamBody.IndexOf(
        'TerrainRebasePolicy.shouldApplyBuildChanges(',
        [Math]::Max(0, $streamDrainIndex))
$streamApplyCallIndex = $streamBody.IndexOf(
        'applyBuildChanges(ctx, prepared, removed, rebase, pbx, pby, pbz)',
        [Math]::Max(0, $streamApplyGateIndex))
$streamRebaseReachable =
        $streamStart -ge 0 -and
        0 -le $streamPlayerIndex -and
        $streamPlayerIndex -lt $streamRebaseIndex -and
        $streamRebaseIndex -lt $streamIdleIndex -and
        $streamIdleIndex -lt $streamDrainIndex -and
        $streamDrainIndex -lt $streamApplyGateIndex -and
        $streamApplyGateIndex -lt $streamApplyCallIndex
if (-not $streamRebaseReachable) {
    $failures.Add('stream must compute rebase before idle and apply rebase even when both publish lists stay empty')
}

$applyBuildStart = $terrainText.IndexOf('private void applyBuildChanges(')
$applyBuildEnd = $terrainText.IndexOf('private void ensureEmptyTableReady(', $applyBuildStart)
$applyBuildBody = if ($applyBuildStart -ge 0 -and $applyBuildEnd -gt $applyBuildStart) {
    $terrainText.Substring($applyBuildStart, $applyBuildEnd - $applyBuildStart)
} else {
    ''
}
$rebaseStateIndex = $applyBuildBody.IndexOf('TerrainRebasePolicy.applyRebase(')
$rebaseStateArgumentsValid =
        $applyBuildBody -match '(?s)TerrainRebasePolicy\.applyRebase\(\s*new TerrainRebasePolicy\.State\(.*?\),\s*rbx,\s*rby,\s*rbz,\s*rebase,\s*!lightBlocks\.isEmpty\(\)\)'
$baseXAssignIndex = $applyBuildBody.IndexOf('blockX = rebaseState.blockX()', [Math]::Max(0, $rebaseStateIndex))
$baseYAssignIndex = $applyBuildBody.IndexOf('blockY = rebaseState.blockY()', [Math]::Max(0, $baseXAssignIndex))
$baseZAssignIndex = $applyBuildBody.IndexOf('blockZ = rebaseState.blockZ()', [Math]::Max(0, $baseYAssignIndex))
$revisionAssignIndex = $applyBuildBody.IndexOf(
        'realtimeLightBlockRevision = rebaseState.realtimeLightRevision()',
        [Math]::Max(0, $baseZAssignIndex))
$rebaseStateApplied =
        $applyBuildStart -ge 0 -and
        0 -le $rebaseStateIndex -and
        $rebaseStateArgumentsValid -and
        $rebaseStateIndex -lt $baseXAssignIndex -and
        $baseXAssignIndex -lt $baseYAssignIndex -and
        $baseYAssignIndex -lt $baseZAssignIndex -and
        $baseZAssignIndex -lt $revisionAssignIndex
if (-not $rebaseStateApplied) {
    $failures.Add('applyBuildChanges must consume the exact-once base/realtime-revision rebase state policy')
}

$emptyResidentIndex = $terrainText.IndexOf('if (resident.isEmpty()) {')
$rebaseStateAbsoluteIndex = if ($rebaseStateIndex -ge 0) {
    $applyBuildStart + $rebaseStateIndex
} else {
    -1
}
$revisionAssignAbsoluteIndex = if ($revisionAssignIndex -ge 0) {
    $applyBuildStart + $revisionAssignIndex
} else {
    -1
}
if ($emptyResidentIndex -lt 0 -or
        $rebaseStateAbsoluteIndex -lt 0 -or
        $revisionAssignAbsoluteIndex -lt $rebaseStateAbsoluteIndex -or
        $revisionAssignAbsoluteIndex -gt $emptyResidentIndex) {
    $failures.Add('rebase must run before the empty-resident return so pure Light sections update base and revision')
}

$stagedApplyStart = $terrainText.IndexOf('private void applyLightBlockChanges(Long2ObjectOpenHashMap<Source[]> staged) {')
$stagedApplyEnd = $terrainText.IndexOf('private void realtimeLightBlocksChanged()', $stagedApplyStart)
if ($stagedApplyStart -lt 0 -or $stagedApplyEnd -lt 0) {
    $failures.Add('staged Light-source apply method is missing')
} else {
    $stagedApplyBody = $terrainText.Substring($stagedApplyStart, $stagedApplyEnd - $stagedApplyStart)
    $desiredGuardIndex = $stagedApplyBody.IndexOf('if (!desired.contains(entry.getLongKey()))')
    $sourceComparisonIndex = $stagedApplyBody.IndexOf('RealtimeLightBlockIndex.sameSources')
    if ($desiredGuardIndex -lt 0 -or $sourceComparisonIndex -lt 0 -or $desiredGuardIndex -gt $sourceComparisonIndex) {
        $failures.Add('staged Light sources must skip sections that left the desired window before writing the map')
    }
}

$realtimeFieldIndex = $terrainText.IndexOf('private final RtRealtimeLightBlocks realtimeLightTable = new RtRealtimeLightBlocks();')
if ($realtimeFieldIndex -lt 0) {
    $failures.Add('terrain must own exactly one realtime Light-block GPU table')
}

if ($terrainText -notmatch '(?s)public record RealtimeLightBlockSnapshot\(\s*long address, int count, float totalWeight, long revision\)') {
    $failures.Add('terrain must expose the realtime Light-block snapshot record')
}

$realtimeMethodStart = $terrainText.IndexOf('public RealtimeLightBlockSnapshot realtimeLightBlocks(')
$revisionMethodStart = $terrainText.IndexOf('public long realtimeLightBlockRevision()', $realtimeMethodStart)
if ($realtimeMethodStart -lt 0 -or $revisionMethodStart -lt 0) {
    $failures.Add('terrain realtime table accessors are missing')
} else {
    $realtimeMethodBody = $terrainText.Substring(
            $realtimeMethodStart, $revisionMethodStart - $realtimeMethodStart)
    if ($realtimeMethodBody -notmatch '(?s)required\s*\?\s*realtimeLightTable\.ensure\(\s*ctx,\s*lightBlocks\.values\(\),\s*realtimeLightBlockRevision,\s*blockX,\s*blockY,\s*blockZ\)\s*:\s*realtimeLightTable\.current\(\)') {
        $failures.Add('required=true must ensure the current sources/revision/base while required=false returns current without building')
    }
    $revisionTail = $terrainText.Substring($revisionMethodStart,
            [Math]::Min(240, $terrainText.Length - $revisionMethodStart))
    if ($revisionTail -notmatch '(?s)return realtimeLightBlockRevision;') {
        $failures.Add('terrain realtime revision accessor must return the current source revision')
    }
}

$clearStart = $terrainText.IndexOf('private void clear(RtContext ctx, boolean shutdown) {')
$graphicsDrainIndex = $terrainText.IndexOf('ctx.gpuExecutor().waitForLatestGraphicsAndFlush();', $clearStart)
$realtimeDestroyIndex = $terrainText.IndexOf('realtimeLightTable.destroy();', $clearStart)
$tableDrainIndex = $terrainText.IndexOf('table.destroyRecycledGenerations();', $clearStart)
$lightMapClearIndex = $terrainText.IndexOf('lightBlocks.clear();', $clearStart)
$realtimeResetIndex = $terrainText.IndexOf('realtimeLightBlockRevision = 0L;', $clearStart)
if ($clearStart -lt 0 -or $graphicsDrainIndex -lt 0 -or $realtimeDestroyIndex -lt 0 -or
        $tableDrainIndex -lt 0 -or $realtimeDestroyIndex -lt $graphicsDrainIndex -or
        $realtimeDestroyIndex -gt $tableDrainIndex) {
    $failures.Add('clear must destroy the realtime table after the existing graphics drain')
}
if ($lightMapClearIndex -lt $realtimeDestroyIndex -or $realtimeResetIndex -lt $lightMapClearIndex) {
    $failures.Add('clear must clear realtime sources and reset their revision after table teardown')
}

$commonText = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'shaders\world\world_common.slang')
$worldPushMatch = [regex]::Match(
        $commonText,
        'public struct WorldPush\s*\{(?<body>.*?)\r?\n\};',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$worldPushBody = if ($worldPushMatch.Success) { $worldPushMatch.Groups['body'].Value } else { '' }
$realtimeAbiOrderValid =
        $worldPushMatch.Success -and
        $worldPushBody -match '(?s)public uint64_t\s+staticLightAddr;.*?public uint\s+staticLightCount;.*?public float\s+staticLightTotalWeight;.*?public uint64_t\s+realtimeLightBlockAddr;.*?public uint\s+realtimeLightBlockCount;.*?public float\s+realtimeLightBlockTotalWeight;'
if (-not $realtimeAbiOrderValid) {
    $failures.Add('WorldPush must expose realtime Light-block address/count/total immediately beside the static-light fields')
}

$realtimeStructMatch = [regex]::Match(
        $commonText,
        'public struct RealtimeLightBlock\s*\{(?<body>.*?)\r?\n\};',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$realtimeStructBody = if ($realtimeStructMatch.Success) {
    $realtimeStructMatch.Groups['body'].Value
} else {
    ''
}
$realtimeStructValid =
        $realtimeStructMatch.Success -and
        $realtimeStructBody -match '^\s*public float4\s+positionCdf;\s*public float4\s+radianceWeight;\s*$' -and
        ([regex]::Matches($realtimeStructBody, 'public\s+float4\s+')).Count -eq 2
if (-not $realtimeStructValid) {
    $failures.Add('RealtimeLightBlock must remain exactly two float4 lanes (32 bytes)')
}

$compositeText = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'src\main\java\dev\comfyfluffy\caustica\rt\RtComposite.java')
$namedFlagsValid =
        $compositeText -match 'private static final int\s+FLAG_OFFLINE_STATIC_LIGHT_NEE\s*=\s*1\s*<<\s*5;' -and
        $compositeText -match 'private static final int\s+FLAG_REALTIME_LIGHT_BLOCK_NEE\s*=\s*1\s*<<\s*6;'
if (-not $namedFlagsValid) {
    $failures.Add('RtComposite must name the offline bit-5 and realtime bit-6 NEE flags')
}

$recordFrameStart = $compositeText.IndexOf('private void recordFrame(')
$recordFrameEnd = $compositeText.IndexOf('private BreakEntry[] breakingEntries(', $recordFrameStart)
$recordFrameBody = if ($recordFrameStart -ge 0 -and $recordFrameEnd -gt $recordFrameStart) {
    $compositeText.Substring($recordFrameStart, $recordFrameEnd - $recordFrameStart)
} else {
    ''
}
$offlineSnapshotMatch = [regex]::Match(
        $recordFrameBody,
        'RtTerrain\.StaticLightSnapshot offlineLights\s*=\s*terrain\.staticLights\(ctx, offlineAccumulating\);')
$offlineSnapshotIndex = if ($offlineSnapshotMatch.Success) { $offlineSnapshotMatch.Index } else { -1 }
$realtimeSnapshotIndex = $recordFrameBody.IndexOf(
        'RtTerrain.RealtimeLightBlockSnapshot realtimeLights =')
$realtimeRequiredIndex = $recordFrameBody.IndexOf(
        'terrain.realtimeLightBlocks(ctx, !offlineAccumulating);',
        [Math]::Max(0, $realtimeSnapshotIndex))
$offlineGateMatch = [regex]::Match(
        $recordFrameBody,
        'if \(offlineAccumulating\s*&&(?<body>.*?)\) \{\s*flags \|= FLAG_OFFLINE_STATIC_LIGHT_NEE;',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$offlineGateBody = if ($offlineGateMatch.Success) { $offlineGateMatch.Groups['body'].Value } else { '' }
$realtimeGateMatch = [regex]::Match(
        $recordFrameBody,
        'if \(!offlineAccumulating\s*&&(?<body>.*?)\) \{\s*flags \|= FLAG_REALTIME_LIGHT_BLOCK_NEE;',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$realtimeGateBody = if ($realtimeGateMatch.Success) { $realtimeGateMatch.Groups['body'].Value } else { '' }
$framePolicyValid =
        $recordFrameStart -ge 0 -and
        0 -le $offlineSnapshotIndex -and
        $offlineSnapshotIndex -lt $realtimeSnapshotIndex -and
        $realtimeSnapshotIndex -lt $realtimeRequiredIndex -and
        $offlineGateMatch.Success -and
        $offlineGateBody -match 'offlineLights\.revision\(\)\s*==\s*terrain\.sceneRevision\(\)' -and
        $offlineGateBody -match 'offlineLights\.address\(\)\s*!=\s*0L' -and
        $offlineGateBody -match 'offlineLights\.count\(\)\s*>\s*0' -and
        $offlineGateBody -match 'Float\.isFinite\(offlineLights\.totalWeight\(\)\)' -and
        $offlineGateBody -match 'offlineLights\.totalWeight\(\)\s*>\s*0\.0f' -and
        $realtimeGateMatch.Success -and
        $realtimeGateBody -match 'realtimeLights\.revision\(\)\s*==\s*terrain\.realtimeLightBlockRevision\(\)' -and
        $realtimeGateBody -match 'realtimeLights\.address\(\)\s*!=\s*0L' -and
        $realtimeGateBody -match 'realtimeLights\.count\(\)\s*>\s*0' -and
        $realtimeGateBody -match 'Float\.isFinite\(realtimeLights\.totalWeight\(\)\)' -and
        $realtimeGateBody -match 'realtimeLights\.totalWeight\(\)\s*>\s*0\.0f'
if (-not $framePolicyValid) {
    $failures.Add('frame policy must request only the active table and gate each flag by mode, revision, address, count, and finite positive total')
}

$mutualExclusionValid =
        $recordFrameBody -match '\(flags & FLAG_OFFLINE_STATIC_LIGHT_NEE\) != 0\s*&&\s*\(flags & FLAG_REALTIME_LIGHT_BLOCK_NEE\) != 0' -and
        $recordFrameBody -match 'throw new IllegalStateException\("Offline and realtime Light NEE flags are mutually exclusive"\);'
if (-not $mutualExclusionValid) {
    $failures.Add('frame flags must include a focused runtime mutual-exclusion contract')
}

$constructorOrderValid =
        $recordFrameBody -match '(?s)new WorldPushData\(.*?offlineLights\.address\(\),\s*offlineLights\.count\(\),\s*offlineLights\.totalWeight\(\),\s*realtimeLights\.address\(\),\s*realtimeLights\.count\(\),\s*realtimeLights\.totalWeight\(\),'
if (-not $constructorOrderValid) {
    $failures.Add('WorldPushData construction must pass offline then realtime address/count/total in reflected order')
}

$raygenText = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'shaders\world\world.rgen.slang')
$selectMatch = [regex]::Match(
        $raygenText,
        'uint selectRealtimeLightBlock\(\s*ConstPtr<RealtimeLightBlock> lights,\s*float target\)\s*\{(?<body>.*?)\r?\n\}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$selectBody = if ($selectMatch.Success) { $selectMatch.Groups['body'].Value } else { '' }
$binarySelectionValid =
        $selectMatch.Success -and
        $selectBody -match 'uint lo = 0u;' -and
        $selectBody -match 'uint hi = pc\.realtimeLightBlockCount - 1u;' -and
        $selectBody -match 'while \(lo < hi\)' -and
        $selectBody -match 'uint mid = \(lo \+ hi\) >> 1u;' -and
        $selectBody -match 'lights\[mid\]\.positionCdf\.w > target' -and
        $selectBody -match 'return lo;'
if (-not $binarySelectionValid) {
    $failures.Add('realtime Light-block selection must binary-search positionCdf.w')
}

$directMatch = [regex]::Match(
        $raygenText,
        'float3 sampleRealtimeLightBlockDirect\(\s*float3 p,\s*float3 n,\s*float3 v,\s*float3 diffAlb,\s*float3 f0,\s*float rough,\s*bool pbr,\s*inout uint seed\)\s*\{(?<body>.*?)\r?\n\}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$directBody = if ($directMatch.Success) { $directMatch.Groups['body'].Value } else { '' }
$directGuardIndex = $directBody.IndexOf('(pc.flags & 64u) == 0u')
$directPointerIndex = $directBody.IndexOf('ConstPtr<RealtimeLightBlock>(pc.realtimeLightBlockAddr)')
$directTargetIndex = $directBody.IndexOf('float target = rndf(seed) * pc.realtimeLightBlockTotalWeight;')
$directTargetRangeIndex = $directBody.IndexOf('if (!(target < pc.realtimeLightBlockTotalWeight))')
$directSelectIndex = $directBody.IndexOf('selectRealtimeLightBlock(')
$directBoundsIndex = $directBody.IndexOf('lightIndex >= pc.realtimeLightBlockCount')
$directReadIndex = $directBody.IndexOf('RealtimeLightBlock light = lights[lightIndex]')
$directValidationValid =
        $directMatch.Success -and
        0 -le $directGuardIndex -and $directGuardIndex -lt $directPointerIndex -and
        $directBody -match 'pc\.realtimeLightBlockAddr == 0' -and
        $directBody -match 'pc\.realtimeLightBlockCount == 0u' -and
        $directBody -match '!isfinite\(pc\.realtimeLightBlockTotalWeight\)' -and
        $directBody -match '!\(pc\.realtimeLightBlockTotalWeight > 0\.0\)' -and
        $directBody -match 'float target = rndf\(seed\) \* pc\.realtimeLightBlockTotalWeight;' -and
        0 -le $directTargetIndex -and $directTargetIndex -lt $directTargetRangeIndex -and
        $directTargetRangeIndex -lt $directSelectIndex -and
        $directBody -match '(?s)if \(!\(target < pc\.realtimeLightBlockTotalWeight\)\) \{\s*target = 0\.0;\s*\}' -and
        0 -le $directSelectIndex -and $directSelectIndex -lt $directBoundsIndex -and
        $directBoundsIndex -lt $directReadIndex -and
        $directBody -match '!isfinite\(light\.radianceWeight\.w\)' -and
        $directBody -match '!\(light\.radianceWeight\.w > 0\.0\)' -and
        $directBody -match 'float selectionPdf\s*=\s*light\.radianceWeight\.w\s*/\s*pc\.realtimeLightBlockTotalWeight;' -and
        $directBody -match '!isfinite\(selectionPdf\)' -and
        $directBody -match '!\(selectionPdf > 0\.0\)'
if (-not $directValidationValid) {
    $failures.Add('ordinary realtime sampling must validate flag/address/count/finite total/index/weight and normalized PDF before use')
}

$directEstimatorValid =
        $directMatch.Success -and
        $directBody -match 'float3 toLight = light\.positionCdf\.xyz - p;' -and
        $directBody -match 'float dist2 = max\(dot\(toLight, toLight\), 0\.0625\);' -and
        $directBody -match 'float dist = sqrt\(dist2\);' -and
        $directBody -match 'float3 l = toLight / dist;' -and
        $directBody -match 'float ndl = max\(0\.0, dot\(n, l\)\);' -and
        $directBody -match 'float3 vis = visibility\(p, l, max\(RAY_TMIN, dist - SURF_BIAS\)\);' -and
        $directBody -match '(?s)return evaluateSurfaceBrdf\(n, v, l, diffAlb, f0, rough, pbr\)\s*\* light\.radianceWeight\.xyz\s*\* \(ndl / \(dist2 \* selectionPdf\)\)\s*\* vis;'
if (-not $directEstimatorValid) {
    $failures.Add('ordinary realtime sampling must use the inverse-square BRDF visibility estimator')
}

$particleMatch = [regex]::Match(
        $raygenText,
        'float3 sampleRealtimeLightBlockParticle\(\s*float3 hitPos,\s*float3 n,\s*float3 albedo,\s*inout uint seed\)\s*\{(?<body>.*?)\r?\n\}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$particleBody = if ($particleMatch.Success) { $particleMatch.Groups['body'].Value } else { '' }
$particleGuardIndex = $particleBody.IndexOf('(pc.flags & 64u) == 0u')
$particlePointerIndex = $particleBody.IndexOf('ConstPtr<RealtimeLightBlock>(pc.realtimeLightBlockAddr)')
$particleTargetIndex = $particleBody.IndexOf('float target = rndf(seed) * pc.realtimeLightBlockTotalWeight;')
$particleTargetRangeIndex = $particleBody.IndexOf('if (!(target < pc.realtimeLightBlockTotalWeight))')
$particleSelectIndex = $particleBody.IndexOf('selectRealtimeLightBlock(')
$particleBoundsIndex = $particleBody.IndexOf('lightIndex >= pc.realtimeLightBlockCount')
$particleReadIndex = $particleBody.IndexOf('RealtimeLightBlock light = lights[lightIndex]')
$particleValid =
        $particleMatch.Success -and
        0 -le $particleGuardIndex -and $particleGuardIndex -lt $particlePointerIndex -and
        $particleBody -match 'pc\.realtimeLightBlockAddr == 0' -and
        $particleBody -match 'pc\.realtimeLightBlockCount == 0u' -and
        $particleBody -match '!isfinite\(pc\.realtimeLightBlockTotalWeight\)' -and
        $particleBody -match '!\(pc\.realtimeLightBlockTotalWeight > 0\.0\)' -and
        0 -le $particleTargetIndex -and $particleTargetIndex -lt $particleTargetRangeIndex -and
        $particleTargetRangeIndex -lt $particleSelectIndex -and
        $particleBody -match '(?s)if \(!\(target < pc\.realtimeLightBlockTotalWeight\)\) \{\s*target = 0\.0;\s*\}' -and
        0 -le $particleSelectIndex -and $particleSelectIndex -lt $particleBoundsIndex -and
        $particleBoundsIndex -lt $particleReadIndex -and
        $particleBody -match '!isfinite\(light\.radianceWeight\.w\)' -and
        $particleBody -match '!\(light\.radianceWeight\.w > 0\.0\)' -and
        $particleBody -match 'float selectionPdf\s*=\s*light\.radianceWeight\.w\s*/\s*pc\.realtimeLightBlockTotalWeight;' -and
        $particleBody -match '!isfinite\(selectionPdf\)' -and
        $particleBody -match '!\(selectionPdf > 0\.0\)' -and
        $particleBody -match 'float3 toLight = light\.positionCdf\.xyz - hitPos;' -and
        $particleBody -match 'float dist2 = max\(dot\(toLight, toLight\), 0\.0625\);' -and
        $particleBody -match 'float dist = sqrt\(dist2\);' -and
        $particleBody -match 'float3 l = toLight / dist;' -and
        $particleBody -match 'float signedNdl = dot\(n, l\);' -and
        $particleBody -match 'float ndl = abs\(signedNdl\);' -and
        $particleBody -match 'float3 shadowOrigin\s*=\s*hitPos \+ \(signedNdl >= 0\.0 \? n : -n\) \* SURF_BIAS;' -and
        $particleBody -match '(?s)float3 vis\s*=\s*visibility\(shadowOrigin, l, max\(RAY_TMIN, dist - SURF_BIAS\)\);' -and
        $particleBody -match 'albedo \* INV_PI' -and
        $particleBody -match 'ndl / \(dist2 \* selectionPdf\)' -and
        $particleBody -match '(?s)return\s+albedo\s*\*\s*INV_PI\s*\*\s*light\.radianceWeight\.xyz\s*\*\s*\(ndl / \(dist2 \* selectionPdf\)\)\s*\*\s*vis;'
if (-not $particleValid) {
    $failures.Add('particle realtime sampling must validate the table and multiply the final radiance by both radianceWeight.xyz and visibility')
}

$traceStart = $raygenText.IndexOf('float3 tracePath(')
$traceEnd = if ($traceStart -ge 0) { $raygenText.IndexOf('[shader("raygeneration")]', $traceStart) } else { -1 }
$traceBody = if ($traceStart -ge 0 -and $traceEnd -gt $traceStart) {
    $raygenText.Substring($traceStart, $traceEnd - $traceStart)
} else {
    ''
}
$glassIndex = $traceBody.IndexOf('if (material == MATERIAL_GLASS)')
$particleBranchIndex = $traceBody.IndexOf('if (material == MATERIAL_PARTICLE)')
$waterIndex = $traceBody.IndexOf('if (material == MATERIAL_WATER)')
$ordinaryPairMatch = [regex]::Match(
        $traceBody,
        '(?s)L \+= offlineContribution\(throughput \* sampleStaticDirect\((?<staticArgs>.*?)\), 8u, bounce, pathFlags\);\s*L \+= offlineContribution\(throughput \* sampleRealtimeLightBlockDirect\(\s*p, n, v, diffAlb, F0, rough, pbr, seed\), 8u, bounce, pathFlags\);')
$ordinaryRealtimeIndex = if ($ordinaryPairMatch.Success) { $ordinaryPairMatch.Index } else { -1 }
$pathLoopIndex = $traceBody.IndexOf('for (int bounce = 0; bounce <= maxBounces; bounce++) {')
$ordinaryLoopPrefix = if ($pathLoopIndex -ge 0 -and $ordinaryRealtimeIndex -gt $pathLoopIndex) {
    $traceBody.Substring($pathLoopIndex, $ordinaryRealtimeIndex - $pathLoopIndex)
} else {
    ''
}
$ordinaryBraceDepth =
        ([regex]::Matches($ordinaryLoopPrefix, '\{')).Count -
        ([regex]::Matches($ordinaryLoopPrefix, '\}')).Count
$particleCallIndex = $traceBody.IndexOf(
        'L += offlineContribution(throughput * sampleRealtimeLightBlockParticle(hitPos, n, albedo, seed), 8u, bounce, pathFlags);',
        [Math]::Max(0, $particleBranchIndex))
$pathPlacementValid =
        $traceStart -ge 0 -and
        0 -le $pathLoopIndex -and $pathLoopIndex -lt $ordinaryRealtimeIndex -and
        $ordinaryBraceDepth -eq 1 -and
        0 -le $glassIndex -and $glassIndex -lt $ordinaryRealtimeIndex -and
        0 -le $waterIndex -and $waterIndex -lt $ordinaryRealtimeIndex -and
        $ordinaryPairMatch.Success -and
        $ordinaryPairMatch.Groups['staticArgs'].Value -match 'payloadSectionSlot\(\), waterGuideMix, waterGuideNormal, waterGuideReflection, seed' -and
        0 -le $particleBranchIndex -and $particleBranchIndex -lt $particleCallIndex -and
        $particleCallIndex -lt $waterIndex
if (-not $pathPlacementValid) {
    $failures.Add('glass/water delta branches must precede all-bounce ordinary realtime NEE, and particles must call their helper')
}

$traceBodyNoLineComments = [regex]::Replace($traceBody, '(?m)//.*$', '')
$glassCodeIndex = $traceBodyNoLineComments.IndexOf('if (material == MATERIAL_GLASS)')
$glassBranchEnd = if ($glassCodeIndex -ge 0) { $traceBodyNoLineComments.IndexOf('if (material == MATERIAL_PARTICLE)', $glassCodeIndex) } else { -1 }
$glassDirectPattern = '(?s)L\s*\+=\s*offlineContribution\(throughput\s*\*\s*(?<call>sampleRealtimeLightBlockDirect\(\s*hitPos,\s*n,\s*-rd,\s*float3\(0\.0\),\s*glassF0,\s*GLASS_GUIDE_ROUGH,\s*true,\s*seed\s*\)), 8u, bounce, pathFlags\)\s*;'
$glassDirectCalls = [regex]::Matches($traceBodyNoLineComments, $glassDirectPattern)
$glassDirectIndex = if ($glassDirectCalls.Count -eq 1) { $glassDirectCalls[0].Index } else { -1 }
$discardedGlassDirectMutation = [regex]::Replace(
        $traceBodyNoLineComments, $glassDirectPattern, '${call};', 1)
$discardedMutationRejected =
        [regex]::Matches($discardedGlassDirectMutation, $glassDirectPattern).Count -eq 0
$glassDirectContractValid =
        $glassCodeIndex -ge 0 -and
        $glassBranchEnd -gt $glassCodeIndex -and
        $glassDirectCalls.Count -eq 1 -and
        $glassDirectIndex -gt $glassCodeIndex -and
        $glassDirectIndex -lt $glassBranchEnd -and
        $discardedMutationRejected
if (-not $glassDirectContractValid) {
    $failures.Add('primary glass must accumulate exactly one zero-diffuse realtime Light direct estimator using its dielectric guide BRDF')
}

if ($failures.Count -ne 0) {
    throw ('Realtime Light-block contract failure: ' + ($failures -join '; '))
}

Write-Output 'Glass realtime-Light discarded-return mutation guard: PASS'
Write-Output 'Realtime Light-block terrain, ABI, frame-policy, and shader contracts: PASS'
exit 0
