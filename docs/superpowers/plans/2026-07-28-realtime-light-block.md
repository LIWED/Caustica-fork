# Realtime Minecraft Light Block Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make invisible vanilla `minecraft:light` blocks provide explicit point-light illumination during normal realtime path tracing without changing ordinary emissive blocks.

**Architecture:** Preserve Light-block sources in a section-keyed CPU sidecar, build a compact global weighted point-light CDF, and publish immutable GPU buffer generations retired through the graphics timeline. A distinct realtime shader flag samples this table at every eligible bounce, while true offline accumulation exclusively uses the existing full static-light table.

**Tech Stack:** Java 25 (`D:\program\java25`), Fabric/Minecraft 26.2, Slang, Vulkan 1.2 buffer device address, PowerShell behavior/contract tests, Gradle 9.5.

## Global Constraints

- Work only under `F:\mygit\test\Caustica_n\Caustica-fork`.
- Target version is 0.3.3; `gradle.properties` remains the only version source.
- Capture only vanilla `minecraft:light` levels 1 through 15 in the realtime table.
- Ordinary emissive blocks, LabPBR emission, glass/water guidance, and the offline estimator remain unchanged.
- Realtime Light-block sampling and offline full static-light sampling are mutually exclusive.
- Realtime table updates must not call `ctx.waitIdle()`.
- Do not execute Git operations.
- Do not copy a JAR into any game instance without explicit user authorization.
- After production changes, update `docs/PROJECT.md`, `docs/CHANGELOG.md`, and `docs/BUGS.md`; keep each concise and below 200 lines.

---

### Task 1: Preserve Section Light-Block Sources

**Files:**

- Create: `src/main/java/dev/comfyfluffy/caustica/rt/light/RealtimeLightBlockIndex.java`
- Create: `scripts/tests/RealtimeLightBlockBehaviorTest.java`
- Create: `scripts/test_realtime_light_blocks.ps1`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtTerrainMesher.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtTerrain.java`
- Create: `.superpowers/sdd/realtime-light-block/progress.md`
- Create: `.superpowers/sdd/realtime-light-block/task-1-report.md`

**Interfaces:**

- Produces:

```java
public final class RealtimeLightBlockIndex {
    public static final int GPU_RECORD_BYTES = 32;

    public record Source(float x, float y, float z, int level) {}

    public record Entry(
            float x, float y, float z,
            float intensity,
            float selectionWeight,
            float cumulativeWeight) {}

    public record Build(Entry[] entries, float totalWeight) {}

    public static Build build(
            Collection<Source> sources, int baseX, int baseY, int baseZ);

    public static boolean sameSources(Source[] left, Source[] right);

    public static float selectionPdf(Entry entry, float totalWeight);
}
```

- `Source` accepts finite coordinates and levels 0 through 15.
- `build` omits level 0, maps levels 1 through 15 with
  `OfflineStaticLightMath.pointIntensity(level)`, sorts by x/y/z/level, and rejects a
  non-finite cumulative total.
- `RtTerrainMesher.CpuSection` carries `Source[] lightBlocks` independently of
  renderable geometry.
- Existing offline `PackedSection.staticLights` continues receiving equivalent
  `CpuLight.point(...)` records.
- `RtTerrain.SectionResult` carries `Source[] lightBlocks` independently of its
  optional `PreparedSection`.

- [x] **Step 1: Write the failing pure behavior test**

Create `RealtimeLightBlockBehaviorTest` with assertions equivalent to:

```java
Build empty = RealtimeLightBlockIndex.build(
        List.of(new Source(0.5f, 0.5f, 0.5f, 0)), 0, 0, 0);
assertEquals(0, empty.entries().length, "level zero omitted");

Build levels = RealtimeLightBlockIndex.build(List.of(
        new Source(1.5f, 2.5f, 3.5f, 1),
        new Source(4.5f, 5.5f, 6.5f, 7),
        new Source(7.5f, 8.5f, 9.5f, 15)), 0, 0, 0);
assertTrue(levels.entries()[0].intensity() > 0.0f, "level 1 positive");
assertTrue(levels.entries()[0].intensity() < levels.entries()[1].intensity(),
        "level 7 brighter than level 1");
assertTrue(levels.entries()[1].intensity() < levels.entries()[2].intensity(),
        "level 15 brighter than level 7");
assertPdfSum(levels, 1.0f, 1.0e-5f);

Build rebased = RealtimeLightBlockIndex.build(
        List.of(new Source(100.5f, 64.5f, -20.5f, 15)), 96, 64, -32);
assertEquals(4.5f, rebased.entries()[0].x(), "rebase x");
assertEquals(0.5f, rebased.entries()[0].y(), "rebase y");
assertEquals(11.5f, rebased.entries()[0].z(), "rebase z");
```

Also assert deterministic reversed-input output, `sameSources` content equality,
position/level inequality, invalid-coordinate rejection, invalid-level rejection,
and zero PDF for invalid totals.

- [x] **Step 2: Add the focused runner and verify RED**

Compile `OfflineStaticLightMath.java`, `RealtimeLightBlockIndex.java`, and the new
test into a temporary directory using Java 25, then run the test main class.

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_realtime_light_blocks.ps1
```

Expected: compilation fails because `RealtimeLightBlockIndex.java` does not exist.

- [x] **Step 3: Implement the minimal index builder**

Implement the exact public API above. Use intensity as selection weight, compute a
monotonic cumulative weight, and return:

```java
return new Build(entries.toArray(Entry[]::new), cumulative);
```

`selectionPdf` returns zero unless the entry weight and total are finite and
positive.

- [x] **Step 4: Verify the pure behavior test is GREEN**

Run `scripts/test_realtime_light_blocks.ps1`.

Expected: all pure behavior assertions pass.

- [x] **Step 5: Extend the runner with failing source-flow contracts**

Require the following current-source facts:

- `Blocks.LIGHT` capture occurs before the `RenderShape` filter.
- `CpuSection.lightBlocks()` is returned for empty and non-empty geometry.
- `PackedSection.staticLights` still receives converted point sources.
- `SectionResult` carries `lightBlocks` even when `PreparedSection` is null.
- `RtTerrain` owns `Long2ObjectOpenHashMap<Source[]> realtimeLightBlockSources`.
- Revision changes use `RealtimeLightBlockIndex.sameSources`, not array identity.
- Empty-to-empty updates do not advance the realtime revision or `sceneRevision`.
- Dirty-group Light changes stage until the complete group publishes.
- Pruning removes source keys outside the residency window.
- Rebase advances the realtime revision only when sources exist.

Run the focused script and expect failure on the missing sidecar and revision flow.

- [x] **Step 6: Implement terrain source capture and publication**

Change mesher point-light capture to:

```java
mesh.pointLights.add(new RealtimeLightBlockIndex.Source(
        wx + 0.5f, wy + 0.5f, wz + 0.5f, level));
```

Create one `Source[] lightBlocks` per CPU section. Return it for both empty and
non-empty branches. Convert each source to `CpuLight.point(...)` only when building
the existing offline static-light arrays.

Add to `RtTerrain`:

```java
private final Long2ObjectOpenHashMap<RealtimeLightBlockIndex.Source[]>
        realtimeLightBlockSources = new Long2ObjectOpenHashMap<>();
private long realtimeLightBlockRevision;
```

Stage per-key source arrays in `DirtyGroup`, apply them atomically when
`remaining == 0`, and discard them on cancellation. Normalize absent values to a
shared empty array before content comparison.

- [x] **Step 7: Run focused regression tests**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_realtime_light_blocks.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
```

Expected: both pass; existing offline point-light behavior remains intact.

- [x] **Step 8: Record Task 1 evidence**

Create `task-1-report.md` with modified files, RED/GREEN commands, exact exit codes,
and remaining risks. Mark Task 1 complete in `progress.md` only after an independent
spec and quality review reports no Critical or Important findings.

---

### Task 2: Publish a Timeline-Retired Realtime GPU Table

**Files:**

- Create: `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtRealtimeLightBlocks.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtTerrain.java`
- Modify: `scripts/test_realtime_light_blocks.ps1`
- Create: `.superpowers/sdd/realtime-light-block/task-2-report.md`

**Interfaces:**

- Consumes `RealtimeLightBlockIndex.Source`, `Build`, `Entry`, and
  `GPU_RECORD_BYTES`.
- Produces:

```java
final class RtRealtimeLightBlocks {
    record Snapshot(long address, int count, float totalWeight, long revision) {
        static final Snapshot EMPTY =
                new Snapshot(0L, 0, 0.0f, Long.MIN_VALUE);
    }

    Snapshot ensure(
            RtContext ctx,
            Collection<RealtimeLightBlockIndex.Source[]> sectionSources,
            long wantedRevision,
            int baseX, int baseY, int baseZ);

    Snapshot current();
    void destroy();
}
```

- `RtTerrain` produces:

```java
public record RealtimeLightBlockSnapshot(
        long address, int count, float totalWeight, long revision) {}

public RealtimeLightBlockSnapshot realtimeLightBlocks(
        RtContext ctx, boolean required);

public long realtimeLightBlockRevision();
```

- [x] **Step 1: Add failing ABI and lifecycle contracts**

Require:

- `GPU_RECORD_BYTES == 32`.
- Every record writes all eight float lanes at offsets 0 through 28.
- Only `RealtimeLightBlockIndex.Build` entries enter the buffer.
- `ensure` contains no `waitIdle`.
- Publication captures `ctx.gpuExecutor().latestGraphicsUseValue()`.
- Old buffers retire through:

```java
ctx.gpuExecutor().enqueueDestroyAfterGraphics(lastGraphicsUse, old::destroy);
```

- Empty generations publish zero address/count/weight at `wantedRevision`.
- Failed construction leaves the last complete generation intact.
- `RtTerrain` never enables or returns a stale revision as current.

Run `scripts/test_realtime_light_blocks.ps1`.

Expected: failure because `RtRealtimeLightBlocks` does not exist.

- [x] **Step 2: Implement immutable buffer generation publication**

Flatten all section source arrays, call `RealtimeLightBlockIndex.build`, and allocate:

```java
ctx.createBuffer(
        (long) build.entries().length * RealtimeLightBlockIndex.GPU_RECORD_BYTES,
        VK10.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        true,
        "realtime Light blocks");
```

Write and flush the complete next buffer before replacing the current snapshot.
Capture the last graphics use immediately before publication, then enqueue the old
buffer for timeline destruction. Publish an empty snapshot without allocating a
zero-sized buffer.

- [x] **Step 3: Integrate the table with terrain lifecycle**

Add:

```java
private final RtRealtimeLightBlocks realtimeLightTable =
        new RtRealtimeLightBlocks();
```

`realtimeLightBlocks(ctx, true)` ensures the current revision; `required == false`
returns `current()`. Clear the CPU source map and destroy the table only after the
existing graphics-drain point in `RtTerrain.clear`.

- [x] **Step 4: Run focused tests and Java compilation**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_realtime_light_blocks.ps1
& '.\scripts\build_local.ps1' -SkipNative -GradleArgs @('compileJava')
```

Expected: contracts pass and Java compilation succeeds.

- [x] **Step 5: Record Task 2 evidence**

Create `task-2-report.md`. Mark Task 2 complete only after independent spec and
quality review confirms timeline safety, stale-revision handling, complete record
writes, and absence of update-path `waitIdle()`.

---

### Task 3: Add Realtime Shader Sampling

**Files:**

- Modify: `shaders/world/world_common.slang`
- Modify: `shaders/world/world.rgen.slang`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java`
- Modify: `scripts/test_realtime_light_blocks.ps1`
- Modify: `scripts/test_offline_rendering_behavior.ps1`
- Create: `.superpowers/sdd/realtime-light-block/task-3-report.md`

**Interfaces:**

- Adds to `WorldPush`:

```slang
uint64_t realtimeLightBlockAddr;
uint realtimeLightBlockCount;
float realtimeLightBlockTotalWeight;
```

- Adds:

```slang
public struct RealtimeLightBlock
{
    public float4 positionCdf;
    public float4 radianceWeight;
};
```

- Defines flag bit 6 (`64u`) for realtime Light-block NEE. Existing offline full
  static-light NEE remains bit 5 (`32u`).
- Produces:

```slang
uint selectRealtimeLightBlock(
        ConstPtr<RealtimeLightBlock> lights, float target);

float3 sampleRealtimeLightBlockDirect(
        float3 p, float3 n, float3 v,
        float3 diffAlb, float3 f0, float rough, bool pbr,
        inout uint seed);

float3 sampleRealtimeLightBlockParticle(
        float3 hitPos, float3 n, float3 albedo,
        inout uint seed);
```

- [x] **Step 1: Add failing shader and frame-policy contracts**

Require:

- `RealtimeLightBlock` is two `float4` values.
- `WorldPush` includes address/count/total fields.
- The shader validates the flag, non-zero address/count, positive finite total, and
  selected index.
- Selection uses binary search over `positionCdf.w`.
- Selection PDF is
  `radianceWeight.w / realtimeLightBlockTotalWeight`.
- Contribution uses inverse-square distance, surface BRDF, selection PDF, and
  `visibility`.
- Ordinary-material code calls `sampleRealtimeLightBlockDirect` inside the path loop
  without a bounce-index cap.
- Particle code calls `sampleRealtimeLightBlockParticle`.
- Delta glass/water branches continue before ordinary direct-light sampling.
- Java cannot enable realtime and offline light flags together.
- Offline accumulation requests the full table only; realtime, movement, and waiting
  frames request the point table only.

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_realtime_light_blocks.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
```

Expected: failure on missing ABI fields, flag, and shader helpers.

- [x] **Step 2: Extend the reflected ABI**

Place the realtime fields adjacent to the existing static-light fields in
`WorldPush`. Never hand-edit generated `WorldPushData.java`.

Run:

```powershell
& '.\scripts\build_local.ps1' -SkipNative -GradleArgs @('generateShaderRecords','compileJava')
```

Update the `RtComposite` `WorldPushData` constructor arguments to the generated
order.

- [x] **Step 3: Integrate mutually exclusive snapshots and named flags**

In `RtComposite.recordFrame`:

```java
StaticLightSnapshot offlineLights =
        terrain.staticLights(ctx, offlineAccumulating);
RealtimeLightBlockSnapshot realtimeLights =
        terrain.realtimeLightBlocks(ctx, !offlineAccumulating);
```

Enable bit 5 only when true accumulation is active and the full snapshot matches
`sceneRevision`. Enable bit 6 only when not accumulating and the realtime snapshot
matches `realtimeLightBlockRevision`. Use named Java constants and assert/contract
that both flags are never simultaneously set.

- [x] **Step 4: Implement weighted point-light sampling**

For ordinary surfaces:

```slang
float3 toLight = light.positionCdf.xyz - p;
float dist2 = max(dot(toLight, toLight), 0.0625);
float dist = sqrt(dist2);
float3 l = toLight / dist;
float ndl = max(0.0, dot(n, l));
float selectionPdf =
        light.radianceWeight.w / pc.realtimeLightBlockTotalWeight;
float3 vis = visibility(p, l, max(RAY_TMIN, dist - SURF_BIAS));
return evaluateSurfaceBrdf(n, v, l, diffAlb, f0, rough, pbr)
        * light.radianceWeight.xyz
        * (ndl / (dist2 * selectionPdf))
        * vis;
```

Validate every denominator and selected index before access. Put the call beside
existing direct-light sampling in the ordinary-material path loop.

For particles, use `abs(dot(n, l))`, choose the shadow-origin side from its sign,
and use `albedo * INV_PI`. Do not add reciprocal MIS because invisible Light blocks
have no hittable geometry.

- [x] **Step 5: Compile and validate all shader variants**

Run:

```powershell
& '.\scripts\build_local.ps1' -SkipNative -GradleArgs @('compileJava','compileShaders','--rerun-tasks')
```

Expected: realtime/offline EXT and NV raygen variants compile and SPIR-V validation
passes.

- [x] **Step 6: Run all focused contracts**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_realtime_light_blocks.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_bounce_video_options.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_frame_generation_video_toggle.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_frame_stats_stage_contract.ps1
```

Expected: all commands exit 0.

- [x] **Step 7: Record Task 3 evidence**

Create `task-3-report.md`. Mark Task 3 complete only after independent spec and
quality review confirms ABI agreement, safe BDA access, all-bounce placement,
particle behavior, and flag mutual exclusion.

---

### Task 4: Version 0.3.3, Documentation, Full Build, and Handoff

**Files:**

- Modify: `gradle.properties`
- Modify: `docs/PROJECT.md`
- Modify: `docs/CHANGELOG.md`
- Modify: `docs/BUGS.md`
- Modify: `docs/superpowers/specs/2026-07-28-realtime-light-block-design.md`
- Modify: `.superpowers/sdd/realtime-light-block/progress.md`
- Create: `.superpowers/sdd/realtime-light-block/task-4-report.md`

**Interfaces:**

- Produces `build/libs/caustica-0.3.3.jar`.
- Keeps the sources JAR separate and explicitly non-installable.
- Leaves all game instances untouched.

- [x] **Step 1: Change the single version source**

Change only:

```properties
mod_version=0.3.3
```

Do not hand-edit `fabric.mod.json`; Gradle expands `${version}`.

- [x] **Step 2: Update required project records**

`PROJECT.md` records code-complete behavior, realtime/offline mutual exclusion,
timeline retirement, automatic verification boundaries, and required game tests.

`CHANGELOG.md` adds 0.3.3 with the point-only realtime table, shader sampling,
lifecycle guarantees, and test/build boundary.

`BUGS.md` marks the realtime `minecraft:light` gating issue resolved in code while
keeping game validation, ordinary emissive realtime NEE, glass/water blur, and
unrelated performance issues open.

Update the design status to implemented after all automated verification passes.

- [x] **Step 3: Run every focused test**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_realtime_light_blocks.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_bounce_video_options.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_frame_generation_video_toggle.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_local_build_environment.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_frame_stats_stage_contract.ps1
```

Expected: every command exits 0.

- [x] **Step 4: Run the complete native and Gradle build**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build_local.ps1
```

Expected: native NGX shim Release build and Gradle build both succeed.

- [x] **Step 5: Verify the deliverable**

For `build/libs/caustica-0.3.3.jar`, record exact byte size, SHA-256, embedded
`fabric.mod.json` version, all four realtime/offline EXT/NV raygen resources, and
the native NGX shim.

Verify the sources JAR contains Java sources and no `.class` files. Label it
non-installable.

- [x] **Step 6: Perform final independent review**

Review specification compliance, CPU/GPU stride, BDA lifetime, source revision
semantics, dirty-group atomicity, shader bounds, flag mutual exclusion, test
evidence, documentation accuracy, and JAR contents. Resolve all Critical and
Important findings.

- [x] **Step 7: Complete the SDD ledger**

Create `task-4-report.md` with exact commands, exit codes, JAR size/hash/content
evidence, confirmation of no Git operations, and confirmation that no game instance
was modified. Preserve this pending `caustica_test` validation matrix:

- Light levels 1, 7, and 15 in a dark room.
- Add, remove, and change `LEVEL`.
- Empty and geometry-containing sections, including a section boundary.
- Wall occlusion and paths through glass, water, and mirrors.
- No doubled Light-block brightness during offline accumulation.
- Ordinary emissive blocks retain their previous realtime behavior.
- FPS, GPU power, longest frame, and stability with 0, 64, and 512 Light blocks.

Mark `progress.md` complete only after the final review is clean.
