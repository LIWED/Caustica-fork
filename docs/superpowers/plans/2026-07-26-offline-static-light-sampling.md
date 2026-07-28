# Offline Static Light Sampling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Subagents and Git operations are forbidden for this workspace.

**Goal:** Add offline-only explicit sampling for static emitting terrain and invisible Minecraft light blocks, with MIS preventing double-counted area-light emission.

**Architecture:** Terrain workers collect per-section area-light triangles and invisible point lights alongside the existing mesh. The render thread publishes a compact weighted GPU light list plus per-triangle light-index sidecars, and the ray-generation shader performs one direct-light sample at each ordinary surface while combining area-light and BSDF paths with the power heuristic.

**Tech Stack:** Java 25, Minecraft 26.2, Fabric, LWJGL Vulkan 1.2 buffer device addresses, Slang/SPIR-V ray tracing, PowerShell behavior tests.

## Implementation Status (2026-07-26)

- Tasks 1-5 are implemented and covered by focused source/behavior contracts plus Java, EXT/NV Slang, and SPIR-V builds.
- The later convergence plan extends this implementation with unbiased local/global sampling, alpha coverage, FP32 offline trace, and independent per-SPP primary rays.
- Commands written with the obsolete `-Tasks` parameter were executed through the supported `-GradleArgs` interface instead.
- No in-game visual or performance validation has been performed; Task 6 automation cannot establish image quality.

## Global Constraints

- Do not execute `git add`, `git commit`, `git push`, create a branch, or create a worktree.
- Do not read from or copy code in the sibling paid shader pack.
- Enable static-light sampling only during active Offline Rendering accumulation.
- First phase includes vanilla static terrain emitters, lava, and `Blocks.LIGHT`.
- First phase excludes entities, held lights, and blocks whose vanilla light emission is zero.
- Existing maximum-bounce and Russian-roulette behavior remains unchanged.
- Every code-editing turn ends with a concise change report.

---

## File Structure

- Create `src/main/java/dev/comfyfluffy/caustica/rt/offline/OfflineStaticLightMath.java`: dependency-free light strength, CDF selection, MIS, and readiness rules.
- Create `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtStaticLights.java`: per-section light records, compact GPU list, sidecar patching, scene-version publication, and lifecycle.
- Modify `scripts/tests/OfflineRenderingBehaviorTest.java`: observable math/readiness behavior tests.
- Modify `scripts/test_offline_rendering_behavior.ps1`: compile the new dependency-free class.
- Modify `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtTerrainMesher.java`: capture emitting triangles and invisible light blocks.
- Modify `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtSectionBuilder.java`: allocate/fill the light-index sidecar and carry CPU candidates.
- Modify `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtSectionTable.java`: publish the sidecar address and retain section light candidates.
- Modify `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtTerrain.java`: rebuild/publish static lights with terrain changes and expose a frame snapshot.
- Modify `shaders/world/world_common.slang`: add light-list fields, light records, section sidecar address, and payload light index.
- Modify `shaders/world/world.rchit.slang`: fetch the hit triangle's static-light index.
- Modify `shaders/world/world.rmiss.slang`: initialize the new payload lane on misses.
- Modify `shaders/world/world.rgen.slang`: sample static lights, evaluate direct lighting, and apply two-sided MIS weights.
- Modify `src/main/java/dev/comfyfluffy/caustica/rt/pipeline/RtPipeline.java`: make block albedo and `_s` samplers visible to raygen.
- Modify `src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java`: gate sampling on active offline accumulation and serialize the current light snapshot.

### Task 1: Dependency-Free Light Math and Readiness

**Files:**

- Create: `src/main/java/dev/comfyfluffy/caustica/rt/offline/OfflineStaticLightMath.java`
- Modify: `scripts/tests/OfflineRenderingBehaviorTest.java`
- Modify: `scripts/test_offline_rendering_behavior.ps1`

**Interfaces:**

- Produces: `float pointIntensity(int level)`
- Produces: `float areaWeight(float area, float emission)`
- Produces: `int selectCdf(float[] cumulativeWeights, float unitRandom)`
- Produces: `float powerHeuristic(float a, float b)`
- Produces: `boolean mayAccumulate(boolean offlineAccumulating, long lightRevision, long sceneRevision)`

- [x] **Step 1: Write failing tests**

Add literal expectations:

```java
assertEquals(0.0f, OfflineStaticLightMath.pointIntensity(0), 1.0e-6f, "level zero");
assertEquals(0.5890486f, OfflineStaticLightMath.pointIntensity(15), 1.0e-6f, "level fifteen");
assertTrue(OfflineStaticLightMath.pointIntensity(1)
        < OfflineStaticLightMath.pointIntensity(8), "point intensity must increase");
assertEquals(1.0f, OfflineStaticLightMath.areaWeight(2.0f, 0.5f), 1.0e-6f, "area weight");
assertEquals(0, OfflineStaticLightMath.selectCdf(new float[]{1f, 3f, 6f}, 0f), "cdf start");
assertEquals(1, OfflineStaticLightMath.selectCdf(new float[]{1f, 3f, 6f}, 0.49f), "cdf middle");
assertEquals(2, OfflineStaticLightMath.selectCdf(new float[]{1f, 3f, 6f}, 0.999999f), "cdf end");
assertEquals(0.5f, OfflineStaticLightMath.powerHeuristic(2f, 2f), 1.0e-6f, "equal PDFs");
assertTrue(OfflineStaticLightMath.mayAccumulate(true, 9L, 9L), "matching revisions");
assertFalse(OfflineStaticLightMath.mayAccumulate(true, 8L, 9L), "stale lights");
```

- [x] **Step 2: Run the focused test and verify RED**

Run `powershell -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1`.

Expected: compilation fails because `OfflineStaticLightMath` is absent.

- [x] **Step 3: Implement the minimum real math**

Use:

```java
private static final float EMISSIVE_STRENGTH = 3.0f;
private static final float LIGHT_BLOCK_RADIUS = 0.25f;

public static float pointIntensity(int level) {
    int clamped = Math.max(0, Math.min(15, level));
    return EMISSIVE_STRENGTH * (clamped / 15.0f)
            * (float) Math.PI * LIGHT_BLOCK_RADIUS * LIGHT_BLOCK_RADIUS;
}
```

CDF selection clamps the random value to `[0, nextDown(1)]`, multiplies by the last cumulative weight, and returns the first element strictly greater than the target. Invalid/empty input returns `-1`. The power heuristic returns `a²/(a²+b²)` with finite zero handling.

- [x] **Step 4: Run the focused test and verify GREEN**

Expected: `Offline rendering behavior: PASS`.

### Task 2: Collect Per-Section Static Lights

**Files:**

- Create: `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtStaticLights.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtTerrainMesher.java`

**Interfaces:**

- Produces: `RtStaticLights.CpuLight`
- Produces: `PackedSection.staticLights()`
- Produces: `PackedSection.triangleCount()`

- [x] **Step 1: Add pure record validation to the focused test**

Test the dependency-free pack helper exposed from `OfflineStaticLightMath` for point kind, area kind, non-negative weight, and `NO_LIGHT = 0xFFFFFFFF`. Run and observe RED.

- [x] **Step 2: Capture invisible light blocks before render-shape filtering**

During the existing 16³ state scan:

```java
if (state.is(Blocks.LIGHT)) {
    int level = state.getLightEmission();
    if (level > 0) {
        mesh.addPointLight(lx + 0.5f, ly + 0.5f, lz + 0.5f, level);
    }
}
```

The normal `RenderShape.MODEL` check remains unchanged, so the block stays invisible.

- [x] **Step 3: Capture area-light triangles**

When `QuadCapture.emit` or `FluidCapture.emitQuad` emits two triangles and emission is greater than zero, append two aligned `CpuLight.area(...)` records containing positions, UVs, tint, emission, material sprite, and packed triangle index.

The packed triangle index must follow the same concatenated bucket order as `triBase`, not the temporary per-bucket index.

- [x] **Step 4: Compile Java**

Run `powershell -ExecutionPolicy Bypass -File .\scripts\build_local.ps1 -Tasks compileJava`.

Expected: exit `0`.

### Task 3: Publish GPU Light Data and Triangle Sidecars

**Files:**

- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtStaticLights.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtSectionBuilder.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtSectionTable.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtTerrain.java`
- Modify: `shaders/world/world_common.slang`

**Interfaces:**

- Produces: `RtStaticLights.Snapshot(long address, int count, float totalWeight, long revision)`
- Produces: `RtTerrain.staticLights(boolean required)`
- Produces: `Section.lightIndexAddr`

- [x] **Step 1: Allocate the sidecar**

`RtSectionBuilder.prepare` allocates a host-visible storage buffer of `triangleCount * 4` bytes, fills it with `NO_LIGHT`, flushes it, and includes it in `PreparedSection`.

- [x] **Step 2: Extend section ownership**

`SectionGeom` owns/destroys the sidecar and retains the immutable CPU light array. `RtSectionTable.write` changes the table ABI to:

```text
u64 primAddr
u64 uvAddr
u64 lightIndexAddr
u32 triBase[4]
```

Set `SECTION_ENTRY_BYTES` to 40 in Java and make the Slang `Section` match exactly.

- [x] **Step 3: Build a compact weighted light buffer**

`RtStaticLights.rebuild` iterates published sections, resolves `HAS_S`, converts section-local positions to current rebased coordinates, writes fixed-size GPU records and cumulative weights, assigns global indices into each sidecar, and publishes one complete `Snapshot`.

Use a 128-byte std430 record:

```text
float4 p0_kind
float4 edge1_weight
float4 edge2_area
float4 uv01
float4 uv2_emission
float4 tint_hasS
float4 pointData
float4 reserved
```

The point record stores center in `p0_kind.xyz`, kind `1`, and point intensity. The area record stores kind `0`, triangle edges, UVs, tint, original emission, area, cumulative weight, and `hasS`.

- [x] **Step 4: Publish atomically with scene revision**

Call the rebuild after `applyBuildChanges` has completed table and instance publication. Only return a snapshot whose revision equals `sceneRevision`; otherwise return an empty/not-ready snapshot. Retire the old light buffer through the graphics timeline.

- [x] **Step 5: Compile Java and regenerate shader records**

Run `build_local.ps1 -Tasks compileJava`.

Expected: generated `WorldPushData` and all manual table offsets compile.

### Task 4: World Pipeline ABI and Offline Gate

**Files:**

- Modify: `shaders/world/world_common.slang`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/pipeline/RtPipeline.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java`

**Interfaces:**

- Adds to `WorldPush`: `uint64_t staticLightAddr`, `uint staticLightCount`, `float staticLightTotalWeight`
- Adds flag bit 5: offline static-light sampling active

- [x] **Step 1: Widen sampler stage visibility**

Binding 2 block atlas and binding 9 `_s` atlas include `VK_SHADER_STAGE_RAYGEN_BIT_KHR`. Binding 10 normal atlas remains closest-hit-only.

- [x] **Step 2: Gate accumulation on light readiness**

Before serializing `WorldPushData`, request `terrain.staticLights(offlineAccumulating)`. Use `OfflineStaticLightMath.mayAccumulate(...)`; if the list is stale, do not dispatch offline accumulation for that frame.

- [x] **Step 3: Serialize the snapshot**

Set flag bit 5 only when the current frame may accumulate and the snapshot count is positive. Always serialize a safe address/count/weight tuple; count zero prevents dereference.

- [x] **Step 4: Compile Java and shaders**

Run `build_local.ps1 -Tasks compileJava compileShaders`.

Expected: Java compile, both SER variants, and SPIR-V validation pass.

### Task 5: Direct Light Sampling and MIS

**Files:**

- Modify: `shaders/world/world.rgen.slang`
- Modify: `shaders/world/world.rchit.slang`
- Modify: `shaders/world/world.rmiss.slang`

**Interfaces:**

- Produces shader helpers: `sampleStaticLight`, `staticLightPdf`, `powerHeuristic`, `bsdfPdf`
- Payload carries `uint staticLightIndex`

- [x] **Step 1: Propagate hit light identity**

Closest-hit loads `sec.lightIndexAddr[pid]` into the payload. Entity hits, particles, glass/water early returns, and misses write `NO_LIGHT`.

- [x] **Step 2: Implement weighted light selection**

Binary-search cumulative weights, uniformly sample triangle area with the square-root barycentric transform, decode atlas/PBR emission, and produce direction, distance, radiance/intensity, and solid-angle PDF.

- [x] **Step 3: Evaluate direct lighting**

At opaque/cutout ordinary surfaces, evaluate the existing diffuse plus GGX BRDF toward the sampled light. Use the existing tinted visibility ray with `tmax = distance - SURF_BIAS`.

- [x] **Step 4: Apply MIS to NEE**

For triangle lights:

```text
lightPdf = selectionPdf * distance² / (cosAtLight * area)
weight = lightPdf² / (lightPdf² + bsdfPdf²)
```

Point lights use weight `1` and inverse-square intensity.

- [x] **Step 5: Apply MIS to BSDF-hit emission**

Track prior material PDF and delta status in `tracePath`. Camera-visible and delta-path emission keeps weight `1`; registered area-light hits after non-delta sampling use the reciprocal MIS weight based on the same selection and solid-angle PDFs.

- [x] **Step 6: Compile and validate shaders**

Run `build_local.ps1 -Tasks compileShaders`.

Expected: EXT SER, NV SER, and `spirv-val` all exit `0`.

### Task 6: Regression Verification and Artifact

**Files:**

- Verify all files above.

- [x] **Step 1: Run all focused behavior tests**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\test_frame_generation_video_toggle.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\test_local_build_environment.ps1
```

- [x] **Step 2: Run the complete build**

Run `powershell -ExecutionPolicy Bypass -File .\scripts\build_local.ps1`.

Result: exit `0` and the feature-version artifact `build/libs/caustica-0.2.0.jar` exists. The original `0.1.0` expectation was superseded by the approved convergence-plan version.

- [x] **Step 3: Inspect scope without Git mutation**

List files modified after the recorded baseline time and verify they all reside under `F:\mygit\test\Caustica_n\Caustica-main`. Do not use Git status as the source of truth because the directory is untracked inside the unrelated parent repository.

- [x] **Step 4: Write the concise code-change report**

Report modified behavior, files, exact verification commands/results, known limitations, and the required in-game comparison scenes. Explicitly state that no Git operation occurred.
