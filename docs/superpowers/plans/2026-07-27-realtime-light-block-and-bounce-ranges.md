# Realtime Light Block and Bounce Ranges Implementation Plan

> **Scope update (2026-07-27):** At the user's request, only Task 1 and its 0.3.0
> build/delivery work are being implemented now. Realtime Light-block Tasks 2–4
> are deferred and must not be treated as part of this version.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add realtime ray-traced illumination from vanilla Light blocks at every eligible path bounce, expose realtime bounces 2–16 and offline bounces 2–32, and build a verified 0.3.0 JAR.

**Architecture:** Keep the existing full static-light table offline-only. Preserve every section's Light-block point sources in a separate CPU sidecar and publish a compact global weighted point-light CDF for realtime rendering. Replace this buffer by immutable generation and retire the previous generation through the existing graphics timeline, never `waitIdle()` on the update path.

**Tech Stack:** Java 25 (`D:\program\java25`), Fabric/Minecraft 26.2, Slang, Vulkan 1.2 BDA, PowerShell contract tests, Gradle 9.5.

## Global Constraints

- Work only under `F:\mygit\test\Caustica_n\Caustica-main`.
- Do not run Git add, commit, push, reset, checkout, or worktree commands.
- Do not modify or copy files into `E:\Minecraft\.minecraft\versions\Caustica26.2`.
- Do not copy a JAR into `caustica_test` without explicit user authorization.
- Do not copy from the sibling paid shader pack.
- Realtime bounces are 2–16 with default 4.
- Offline bounces are 2–32 with default 8 and apply only while truly accumulating.
- Realtime Light blocks participate at every eligible path bounce.
- Realtime Light blocks use a dedicated global point-light table; ordinary emissive area lights remain outside that table.
- Offline mode uses only the existing full static-light table, preventing duplicate Light-block energy.
- Do not change the offline estimator, add a luminance clamp, or claim the 8000+ SPP grain issue is solved.
- Keep `gradle.properties` as the only version source; change it to 0.3.0 only in the final task.
- After production changes, update `docs/PROJECT.md`, `docs/CHANGELOG.md`, and `docs/BUGS.md`; each stays under 200 lines.

---

### Task 1: Realtime and Offline Bounce Policies

**Files:**

- Create: `src/main/java/dev/comfyfluffy/caustica/rt/offline/PathBouncePolicy.java`
- Create: `scripts/test_bounce_video_options.ps1`
- Modify: `scripts/tests/OfflineRenderingBehaviorTest.java`
- Modify: `scripts/test_offline_rendering_behavior.ps1`
- Modify: `src/main/java/dev/comfyfluffy/caustica/CausticaConfig.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/client/RtVideoOptions.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java`
- Modify: `src/main/resources/assets/caustica/lang/en_us.json`
- Modify: `src/main/resources/assets/caustica/lang/zh_cn.json`
- Modify: the other nine files under `src/main/resources/assets/caustica/lang/`
- Modify: `docs/PROJECT.md`
- Modify: `docs/CHANGELOG.md`
- Modify: `docs/BUGS.md`

**Interfaces:**

- Produces:

```java
public final class PathBouncePolicy {
    public static final int REALTIME_MIN = 2;
    public static final int REALTIME_MAX = 16;
    public static final int OFFLINE_MIN = 2;
    public static final int OFFLINE_MAX = 32;

    public static int clampRealtime(int value);
    public static int clampOffline(int value);
    public static int effective(boolean accumulating, int realtime, int offline);
}
```

- Adds `CausticaConfig.Rt.Offline.MAX_BOUNCES` with system property `caustica.rt.offline.maxBounces`, TOML path `offline.max-bounces`, default 8, range 2–32.
- Keeps `CausticaConfig.Rt.Composite.MAX_BOUNCES` keys/default unchanged but expands the upper bound to 16.
- `RtComposite.offlineRenderSignature(...)` hashes the offline bounce setting.
- `WorldPushData.maxBounces` receives `PathBouncePolicy.effective(offlineAccumulating, realtime, offline)`.

- [x] **Step 1: Add failing pure-Java bounce assertions**

Add these assertions to `OfflineRenderingBehaviorTest` and register them from `main`:

```java
assertEquals(2, PathBouncePolicy.clampRealtime(1), "realtime lower clamp");
assertEquals(2, PathBouncePolicy.clampRealtime(2), "realtime lower bound");
assertEquals(16, PathBouncePolicy.clampRealtime(16), "realtime upper bound");
assertEquals(16, PathBouncePolicy.clampRealtime(17), "realtime upper clamp");
assertEquals(2, PathBouncePolicy.clampOffline(1), "offline lower clamp");
assertEquals(32, PathBouncePolicy.clampOffline(32), "offline upper bound");
assertEquals(32, PathBouncePolicy.clampOffline(33), "offline upper clamp");
assertEquals(12, PathBouncePolicy.effective(false, 12, 24), "waiting uses realtime");
assertEquals(24, PathBouncePolicy.effective(true, 12, 24), "accumulating uses offline");
assertEquals(2, PathBouncePolicy.effective(false, -1, 99), "effective realtime is defensive");
assertEquals(32, PathBouncePolicy.effective(true, -1, 99), "effective offline is defensive");
```

Also compare two `OfflineRenderSignature.create(...)` calls differing only in offline bounce 8 versus 9 and assert different signatures. Preserve the existing assertion that changing SPP batch size does not enter the render signature.

- [x] **Step 2: Run the behavior test and verify RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
```

Expected: compilation fails because `PathBouncePolicy.java` does not exist or assertions cannot resolve the class.

- [x] **Step 3: Implement the dependency-free policy and compile it in the script**

Implement the exact API above using `Math.max/min`, and add its source path to the `javac` source list in `test_offline_rendering_behavior.ps1`.

- [x] **Step 4: Add a failing video-option/configuration contract**

Create `test_bounce_video_options.ps1`, following `test_frame_generation_video_toggle.ps1`, and require:

```text
Composite.MAX_BOUNCES:
  caustica.rt.maxBounces
  composite.max-bounces
  default 4
  range 2..16

Offline.MAX_BOUNCES:
  caustica.rt.offline.maxBounces
  offline.max-bounces
  default 8
  range 2..32
  present in ensureRegistered()
```

Require `maxBounces()` to bind the realtime setting with `IntRange(2, 16)` and `offlineMaxBounces()` to bind the offline setting with `IntRange(2, 32)`. Require all eleven locale JSON files to contain non-empty labels/tooltips for both settings.

For `en_us`, require the SPP tooltip to contain the concepts `offline`, `batch`, and `total samples`. For `zh_cn`, require `离线`, `每帧`, `批量`, and `总样本`.

- [x] **Step 5: Run the option contract and verify RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_bounce_video_options.ps1
```

Expected: failure because the old realtime range is 2–8 and the offline setting/keys do not exist.

- [x] **Step 6: Implement configuration, options, translations, and effective push selection**

Use these helpers in `RtComposite`:

```java
private static int realtimeMaxBounces() {
    return CausticaConfig.Rt.Composite.MAX_BOUNCES.value();
}

private static int offlineMaxBounces() {
    return CausticaConfig.Rt.Offline.MAX_BOUNCES.value();
}
```

When building the offline render signature, pass `offlineMaxBounces()` unconditionally. After computing `offlineAccumulating`, compute once:

```java
int effectiveMaxBounces = PathBouncePolicy.effective(
        offlineAccumulating, realtimeMaxBounces(), offlineMaxBounces());
```

Pass `effectiveMaxBounces` to `WorldPushData`. Do not use `RtOfflineController.enabled()` as the selector: offline waiting/movement frames must use the realtime value.

Keep SPP out of the signature. Update its tooltip only.

- [x] **Step 7: Run Task 1 tests to GREEN**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_bounce_video_options.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_frame_generation_video_toggle.ps1
```

Expected: all PASS.

- [x] **Step 8: Update the three project documents**

Record the new ranges, the distinct accumulating/waiting behavior, the corrected SPP meaning, and the performance warning. Keep the 8000+ SPP grain issue open.

---

### Task 2: Preserve All Section Light-Block Sources

**Files:**

- Create: `src/main/java/dev/comfyfluffy/caustica/rt/light/RealtimeLightBlockIndex.java`
- Create: `scripts/tests/RealtimeLightBlockBehaviorTest.java`
- Create: `scripts/test_realtime_light_blocks.ps1`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtTerrainMesher.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtTerrain.java`
- Modify: `docs/PROJECT.md`
- Modify: `docs/CHANGELOG.md`
- Modify: `docs/BUGS.md`

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

- `Source` accepts finite coordinates and level 0–15. `build` omits level 0 and maps levels 1–15 through `OfflineStaticLightMath.pointIntensity(level)`.
- `build` sorts deterministically by x, y, z, and level before computing the CDF.
- `RtTerrainMesher.CpuSection` carries `Source[] lightBlocks` for both empty and non-empty geometry.
- Existing offline `PackedSection.staticLights` continues to include converted Light-block `CpuLight.point(...)` records, preserving offline behavior.
- `RtTerrain` adds `Long2ObjectOpenHashMap<Source[]> realtimeLightBlockSources` and `long realtimeLightBlockRevision`.
- `RtTerrain.SectionResult` carries `Source[] lightBlocks` independently of its optional prepared geometry.

- [ ] **Step 1: Write failing index/math tests**

In `RealtimeLightBlockBehaviorTest`, assert:

```java
Build empty = build(List.of(new Source(0, 0, 0, 0)), 0, 0, 0);
assertEquals(0, empty.entries().length);

Build levels = build(List.of(
        new Source(1.5f, 2.5f, 3.5f, 1),
        new Source(4.5f, 5.5f, 6.5f, 7),
        new Source(7.5f, 8.5f, 9.5f, 15)), 0, 0, 0);
assertTrue(levels.entries()[0].intensity() > 0.0f);
assertTrue(levels.entries()[0].intensity() < levels.entries()[1].intensity());
assertTrue(levels.entries()[1].intensity() < levels.entries()[2].intensity());
assertFinitePositive(levels.totalWeight());
assertPdfSum(levels, 1.0f, 1.0e-5f);
```

Also assert deterministic output for reversed input order, `sameSources` true for content-equal arrays and false for level/position changes, finite-coordinate validation, and one-time rebase:

```java
Build rebased = build(List.of(new Source(100.5f, 64.5f, -20.5f, 15)), 96, 64, -32);
assertEquals(4.5f, rebased.entries()[0].x());
assertEquals(0.5f, rebased.entries()[0].y());
assertEquals(11.5f, rebased.entries()[0].z());
```

- [ ] **Step 2: Run the realtime Light-block test and verify RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_realtime_light_blocks.ps1
```

Expected: failure because `RealtimeLightBlockIndex.java` is missing.

- [ ] **Step 3: Implement the pure index builder to GREEN**

Use `OfflineStaticLightMath.pointIntensity(level)` for both `intensity` and `selectionWeight`. Reject a non-finite cumulative total. Compute `selectionPdf = selectionWeight / totalWeight`, returning 0 for invalid totals.

- [ ] **Step 4: Add failing terrain source-flow contracts**

Extend `test_realtime_light_blocks.ps1` with scoped source assertions:

- Light blocks are captured before the `RenderShape` filter.
- `CpuSection.lightBlocks()` is populated for both empty and non-empty sections.
- `PackedSection.staticLights` still receives converted point sources for offline use.
- `SectionResult` carries Light-block sources even when a GPU geometry build exists.
- `RtTerrain` updates `realtimeLightBlockSources` by contents, not array identity.
- Empty-to-empty updates do not advance either realtime revision or `sceneRevision`.
- Dirty-group Light-block changes are staged and published only when the whole group completes.
- Prune removes out-of-window source keys.
- Rebase advances the realtime revision only when sources exist.

- [ ] **Step 5: Run the source-flow contract and verify RED**

Expected: failure on the current non-empty-section `new CpuLight[0]`, identity comparison, and missing dedicated map/revision.

- [ ] **Step 6: Implement the source sidecar and revision updates**

Change `SectionMesh.pointLights` to `ArrayList<RealtimeLightBlockIndex.Source>`. At capture:

```java
mesh.pointLights.add(new Source(wx + 0.5f, wy + 0.5f, wz + 0.5f, level));
```

Create `Source[] lightBlocks` once in `buildCpuSection`. Return it for both branches. While packing the offline static-light array, convert each source with `CpuLight.point(x, y, z, level)`.

Carry `lightBlocks` directly from `CpuSection` into `SectionResult`, independently of `PreparedSection`, and update `realtimeLightBlockSources` for both built and empty sections. Normalize absent arrays to a shared empty array before `sameSources`, so an empty result does not create revision churn.

Add a per-dirty-group map of staged Light-block arrays. Apply it atomically when `remaining == 0`; discard it on group cancellation.

Preserve the existing `lightOnly` map for empty-section sources needed by the offline full table. Convert `Source[]` to `CpuLight.point(...)` only for that map, and replace its `previous != pointLights` identity comparison with content comparison.

- [ ] **Step 7: Run Task 2 tests to GREEN**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_realtime_light_blocks.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
```

Expected: both PASS; offline static Light-block behavior remains covered.

- [ ] **Step 8: Update project documents**

Record the fixed empty-array revision churn bug and the new all-section Light-block source sidecar. Do not mark realtime illumination complete until Tasks 3 and 4 pass.

---

### Task 3: Timeline-Retired Realtime Point-Light Buffer

**Files:**

- Create: `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtRealtimeLightBlocks.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtTerrain.java`
- Modify: `scripts/test_realtime_light_blocks.ps1`
- Modify: `docs/PROJECT.md`
- Modify: `docs/CHANGELOG.md`
- Modify: `docs/BUGS.md`

**Interfaces:**

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

- GPU record, stride 32 bytes:

```text
offset  0: float3 positionRelativeToBase
offset 12: float cumulativeWeight
offset 16: float3 radiance
offset 28: float selectionWeight
```

- `RtTerrain` produces:

```java
public record RealtimeLightBlockSnapshot(
        long address, int count, float totalWeight, long revision) {}

RealtimeLightBlockSnapshot realtimeLightBlocks(RtContext ctx, boolean required);
long realtimeLightBlockRevision();
```

- [ ] **Step 1: Add failing lifecycle/ABI source contracts**

Require:

- `GPU_RECORD_BYTES == 32`.
- All eight float lanes are explicitly written.
- Only point sources from `RealtimeLightBlockIndex.Build` enter the buffer.
- `ensure` has no `waitIdle` call.
- Publication captures `ctx.gpuExecutor().latestGraphicsUseValue()`.
- Old non-null buffers retire with:

```java
ctx.gpuExecutor().enqueueDestroyAfterGraphics(lastGraphicsUse, old::destroy);
```

- Empty generation publishes zero address/count/weight with the requested revision and retires the old buffer.
- Failed construction does not overwrite the last complete generation.
- A stale snapshot revision is not presented as enabled by `RtTerrain`.

- [ ] **Step 2: Run the contract and verify RED**

Run `test_realtime_light_blocks.ps1`.

Expected: failure because `RtRealtimeLightBlocks` does not exist.

- [ ] **Step 3: Implement generation-safe buffer publication**

Build a flattened source list and call `RealtimeLightBlockIndex.build`. Allocate with:

```java
ctx.createBuffer(
        (long) build.entries().length * RealtimeLightBlockIndex.GPU_RECORD_BYTES,
        VK10.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        true,
        "realtime Light blocks");
```

Write/flush the complete next buffer before replacing fields. Capture `lastGraphicsUse` immediately before publication. Publish new `buffer/snapshot`, then enqueue the old buffer for timeline destruction.

If the build is empty, publish a zero snapshot at `wantedRevision` and retire the previous buffer without allocating a zero-size buffer.

Do not call `markPublished`: this host-visible table is not produced by the asynchronous compute build queue.

- [ ] **Step 4: Integrate with terrain lifecycle**

Add fields:

```java
private final RtRealtimeLightBlocks realtimeLightTable = new RtRealtimeLightBlocks();
```

`realtimeLightBlocks(ctx, true)` calls `ensure` with current sources/revision/base; `required == false` returns `current()`.

During normal clear, call `realtimeLightTable.destroy()` only after the existing `waitForLatestGraphicsAndFlush()` point. During device-idle shutdown, direct destruction is safe. Clear the source map and reset its revision state consistently.

- [ ] **Step 5: Run Task 3 tests and Java compilation**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_realtime_light_blocks.ps1
& '.\scripts\build_local.ps1' -SkipNative -GradleArgs @('compileJava')
```

Expected: contracts PASS and `compileJava` succeeds.

- [ ] **Step 6: Update project documents**

Record timeline-retired publication and explicitly state that ordinary edits do not wait for device idle.

---

### Task 4: Realtime Shader Sampling and Mutual Exclusion

**Files:**

- Modify: `shaders/world/world_common.slang`
- Modify: `shaders/world/world.rgen.slang`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java`
- Modify: `scripts/test_realtime_light_blocks.ps1`
- Modify: `scripts/test_offline_rendering_behavior.ps1`
- Modify: `docs/PROJECT.md`
- Modify: `docs/CHANGELOG.md`
- Modify: `docs/BUGS.md`

**Interfaces:**

- Adds to `WorldPush`:

```slang
uint64_t realtimeLightBlockAddr;
uint realtimeLightBlockCount;
float realtimeLightBlockTotalWeight;
```

- Adds:

```slang
public struct RealtimeLightBlock {
    public float4 positionCdf;
    public float4 radianceWeight;
};
```

- Defines flag bit 6 (`64u`) for realtime Light-block NEE. Existing offline full-static-light NEE remains bit 5 (`32u`).
- Produces shader helpers:

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

- [ ] **Step 1: Add failing ABI and shader-behavior contracts**

Require:

- `RealtimeLightBlock` is two `float4` fields and therefore 32 bytes.
- `WorldPush` has address/count/total fields.
- The shader validates flag, non-zero address/count, positive finite total, and selected index.
- Selection uses binary search over `positionCdf.w`.
- Selection PDF is `radianceWeight.w / realtimeLightBlockTotalWeight`.
- Contribution uses inverse-square distance, surface BRDF, selection PDF, and `visibility`.
- Ordinary-material code calls `sampleRealtimeLightBlockDirect` inside the path loop with no bounce-index cap.
- Particle code calls `sampleRealtimeLightBlockParticle`.
- Glass and water branches continue before either ordinary direct-light call.
- Realtime and offline flags cannot both be set by Java.
- Offline accumulation uses the full table only; realtime waiting/movement uses the realtime table.

- [ ] **Step 2: Run shader contracts and verify RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_realtime_light_blocks.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
```

Expected: failure because the push fields, struct, flag, and shader calls are absent.

- [ ] **Step 3: Extend the reflected ABI and regenerate records**

Place the realtime fields adjacent to the existing static-light fields in `WorldPush`. Never hand-edit generated `WorldPushData.java`.

Run:

```powershell
& '.\scripts\build_local.ps1' -SkipNative -GradleArgs @('generateShaderRecords','compileJava')
```

Update `RtComposite` constructor arguments to the generated order.

- [ ] **Step 4: Integrate mutually exclusive frame snapshots**

In `recordFrame`:

```java
StaticLightSnapshot offlineLights = terrain.staticLights(ctx, offlineAccumulating);
RealtimeLightBlockSnapshot realtimeLights =
        terrain.realtimeLightBlocks(ctx, !offlineAccumulating);
```

Enable bit 5 only when `offlineAccumulating`, the full snapshot revision matches `sceneRevision`, and it is non-empty.

Enable bit 6 only when not accumulating, the realtime snapshot revision matches `realtimeLightBlockRevision`, and it is non-empty.

Use named Java constants for both bits. Add an assertion or contract that `(flags & OFFLINE_STATIC_LIGHTS) == 0 || (flags & REALTIME_LIGHT_BLOCKS) == 0`.

- [ ] **Step 5: Implement weighted point-light sampling**

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

Validate every denominator before use. The call belongs next to `sampleStaticDirect` in the ordinary-material branch and executes at every surviving eligible bounce.

For particles, use `abs(dot(n,l))`, choose the shadow-origin side from the sign, use `albedo * INV_PI`, and keep particles excluded from shadow geometry as today.

Do not add reciprocal MIS for Light blocks: they have no hittable geometry and cannot be reached by the BSDF-hit technique.

- [ ] **Step 6: Compile all shader variants and validate SPIR-V**

Run:

```powershell
& '.\scripts\build_local.ps1' -SkipNative -GradleArgs @('compileJava','compileShaders','--rerun-tasks')
```

Expected:

- realtime EXT `world.rgen.spv` validates,
- realtime NV `world_nv.rgen.spv` validates,
- offline EXT `world_offline.rgen.spv` validates,
- offline NV `world_offline_nv.rgen.spv` validates,
- generated Java records and `RtComposite` compile.

- [ ] **Step 7: Run all focused contracts**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_realtime_light_blocks.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_bounce_video_options.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_frame_generation_video_toggle.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_frame_stats_stage_contract.ps1
```

Expected: all PASS.

- [ ] **Step 8: Update project documents**

Mark realtime Light-block code complete but retain game validation as pending. Record the all-eligible-bounce cost and mutual-exclusion guarantee.

---

### Task 5: Version 0.3.0, Full Build, and Handoff

**Files:**

- Modify: `gradle.properties`
- Modify: `docs/PROJECT.md`
- Modify: `docs/CHANGELOG.md`
- Modify: `docs/BUGS.md`
- Modify: `docs/superpowers/specs/2026-07-27-realtime-light-block-and-bounce-ranges-design.md`
- Modify: `docs/superpowers/plans/2026-07-27-realtime-light-block-and-bounce-ranges.md`
- Create: `.superpowers/sdd/realtime-light-block-and-bounce-ranges/progress.md`
- Create: `.superpowers/sdd/realtime-light-block-and-bounce-ranges/task-5-report.md`

**Interfaces:**

- Produces `build/libs/caustica-0.3.0.jar`.
- Keeps the sources JAR separate and non-installable.
- Leaves all game instances untouched.

- [ ] **Step 1: Change the single version source**

Change only:

```properties
mod_version=0.3.0
```

Do not hand-edit `fabric.mod.json`; Gradle expands `${version}`.

- [ ] **Step 2: Run every focused test**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_realtime_light_blocks.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_bounce_video_options.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_frame_generation_video_toggle.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_local_build_environment.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_frame_stats_stage_contract.ps1
```

Expected: all exit 0.

- [ ] **Step 3: Run the complete native and Gradle build**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build_local.ps1
```

Expected: CMake/NGX shim Release and Gradle build both succeed.

- [ ] **Step 4: Verify the deliverable**

For `build/libs/caustica-0.3.0.jar`, record:

- exact byte size,
- SHA-256,
- embedded `fabric.mod.json` version `0.3.0`,
- presence of `world.rgen.spv`,
- presence of `world_nv.rgen.spv`,
- presence of `world_offline.rgen.spv`,
- presence of `world_offline_nv.rgen.spv`,
- presence of the native NGX shim.

For `caustica-0.3.0-sources.jar`, verify it contains Java sources and no `.class` files. Clearly label it non-installable.

- [ ] **Step 5: Complete concise documentation**

`PROJECT.md` must state:

- realtime bounces 2–16,
- offline bounces 2–32,
- realtime Light blocks use all eligible bounces,
- ordinary emissive blocks are not in the realtime point table,
- game testing has not occurred.

`CHANGELOG.md` records 0.3.0 implementation and validation.

`BUGS.md`:

- marks realtime Light-block gating and empty-array revision churn resolved,
- keeps 8000+ SPP grain/dirty spots open,
- keeps high-render-distance and runtime performance validation open.

Keep each document below 200 lines.

- [ ] **Step 6: Perform final independent review**

Review spec compliance, source quality, BDA lifetime, CPU/GPU stride, flag mutual exclusion, all-bounce placement, bounce option semantics, test evidence, and JAR contents. Resolve Critical/Important findings before handoff.

- [ ] **Step 7: Produce the modification report**

Report:

- modified behavior,
- exact test/build evidence,
- JAR path/size/hash,
- remaining game-validation matrix,
- no Git operations,
- no game-instance copy.
