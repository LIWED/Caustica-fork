# Offline Convergence and Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Improve offline convergence at high render distance by adding unbiased local/global light sampling, FP32 trace accumulation, and per-SPP low-discrepancy primary rays.

**Architecture:** Keep the existing global light CDF and add per-section packed neighborhood references mixed at 90% local / 10% global. Compile an offline-only FP32 raygen variant and drive every offline SPP from a global sample index, while preserving the existing realtime and DLSS paths.

**Tech Stack:** Java 25, Fabric/Minecraft 26.2, Slang, GLSL, Vulkan 1.2, PowerShell contract tests, Gradle 9.5.

## Global Constraints

- Work only under `F:\mygit\test\Caustica_n\Caustica-main`.
- Do not modify `E:\Minecraft\.minecraft\versions\Caustica26.2`.
- Do not execute Git add, commit, push, reset, checkout, or worktree operations.
- Realtime Light block support is out of scope.
- Do not copy code from the sibling paid shader pack.
- Keep all light-selection probabilities unbiased; no distance cutoff.
- Do not add a default firefly luminance clamp.
- Use `mod_version=0.2.0` for the completed feature build.
- After code changes, update `docs/PROJECT.md`, `docs/CHANGELOG.md`, and `docs/BUGS.md`.

---

### Task 1: Sampling Math and Frame-Stats Safety

**Files:**

- Create: `src/main/java/dev/comfyfluffy/caustica/rt/offline/OfflineLightMixtureMath.java`
- Modify: `scripts/tests/OfflineRenderingBehaviorTest.java`
- Modify: `scripts/test_offline_rendering_behavior.ps1`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/RtFrameStats.java`
- Create: `scripts/test_frame_stats_stage_contract.ps1`

**Interfaces:**

- Produces: `OfflineLightMixtureMath.selectionPdf(float weight, float globalTotal, boolean local, float localTotal)`
- Produces: `OfflineLightMixtureMath.areaSolidAnglePdf(float selectionPdf, float distanceSquared, float cosLight, float area)`
- Produces: `OfflineLightMixtureMath.alphaCoverageWeight(float area, float emission, float alphaCoverage)`
- Uses exact local mixture probability `0.9f`.

- [x] Write failing Java assertions for global-only, local, non-local, normalization, area PDF, and alpha coverage.
- [x] Run `powershell -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1` and verify RED.
- [x] Implement the dependency-free math class and include it in the PowerShell compile list.
- [x] Re-run the behavior test and verify GREEN.
- [x] Write a failing PowerShell contract that extracts every `RtFrameStats.FRAME.stage("...")` call and checks it against the FRAME stage-name array.
- [x] Register `frame.offlineAccumulate` and run the contract to GREEN.
- [x] Update project docs with the confirmed frame-stats bug and Task 1 status.

### Task 2: Unbiased Local/Global Static-Light Sampling

**Files:**

- Create: `src/main/java/dev/comfyfluffy/caustica/rt/offline/OfflineLocalLightIndex.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtStaticLights.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtTerrain.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtTerrainMesher.java`
- Modify: `shaders/world/world_common.slang`
- Modify: `shaders/world/world.rgen.slang`
- Modify: `shaders/world/world.rchit.slang`
- Modify: `shaders/world/world.rmiss.slang`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java`
- Modify: `scripts/tests/OfflineRenderingBehaviorTest.java`

**Interfaces:**

- Produces packed 16-byte `LocalLightDirectory` entries indexed by terrain section slot.
- Produces packed 8-byte `LocalLightReference` entries sorted by global light index.
- Extends `RtTerrain.StaticLightSnapshot` with directory/reference addresses and counts.
- Extends `Payload` with terrain `sectionSlot`, using `0xFFFFFFFF` for entity/miss.
- Uses a Chebyshev neighborhood radius of 2 sections.

- [x] Add failing pure-Java tests for neighborhood membership, sorted references, cumulative weights, empty slots, and mixed selection PDFs.
- [x] Run the focused behavior test and verify RED.
- [x] Implement the CPU local index builder without Minecraft or Vulkan dependencies.
- [x] Run the focused test and verify GREEN.
- [x] Add alpha-coverage estimation through the existing `SpriteContentsAccessor` and apply it to area-light weights.
- [x] Build global light records, per-slot directories, and packed local references in one scene-revision snapshot.
- [x] Extend WorldPush and ray payload ABIs; regenerate Java shader records through Gradle.
- [x] Implement local/global branch sampling and the exact mixture PDF in raygen.
- [x] Carry the previous receiver section slot into BSDF-hit MIS.
- [x] Compile both EXT and NV Slang variants and run SPIR-V validation.
- [x] Update project docs and mark Task 2 status.

### Task 3: Offline FP32 Trace and Per-SPP Primary Sampling

**Files:**

- Modify: `build.gradle`
- Modify: `shaders/world/world.rgen.slang`
- Modify: `shaders/display/offline_accumulate.comp`
- Modify: `shaders/world/world_common.slang`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/RtDeviceBringup.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/pipeline/RtOfflineAccumulationPipeline.java`
- Create: `src/main/java/dev/comfyfluffy/caustica/rt/offline/OfflineSampleSequence.java`
- Modify: `scripts/tests/OfflineRenderingBehaviorTest.java`

**Interfaces:**

- Produces `RtDeviceBringup.worldRaygenShader(boolean offlineFp32)`.
- Produces `OfflineSampleSequence.sample2D(int pixelHash, long globalSampleIndex)` as a CPU reference for shader contract tests.
- Adds a WorldPush offline sample-base field sourced from `Decision.previousSamples()`.
- Offline image formats: trace RGBA32F, history RGBA32F, display resolve RGBA16F.

- [x] Add failing tests proving no 32-phase repeat across 6000 primary samples and distinct per-SPP positions.
- [x] Implement the CPU reference low-discrepancy sequence and run focused tests GREEN.
- [x] Add offline EXT/NV raygen compilation from the same Slang source with `CAUSTICA_OFFLINE_FP32`.
- [x] Select/recreate the world pipeline variant when Offline Rendering toggles.
- [x] Allocate the offline trace image as RGBA32F while preserving realtime RGBA16F.
- [x] Reconstruct origin/direction inside the SPP loop from the per-sample low-discrepancy offset.
- [x] Derive each path seed from pixel and global sample index.
- [x] Reject non-finite or negative final radiance before imageStore without applying luminance clamp.
- [x] Compile shaders, validate SPIR-V, and update project docs.

### Task 4: Version, Full Verification, and Handoff

**Files:**

- Modify: `gradle.properties`
- Modify: `docs/PROJECT.md`
- Modify: `docs/CHANGELOG.md`
- Modify: `docs/BUGS.md`
- Modify: `docs/superpowers/plans/2026-07-26-offline-static-light-sampling.md`
- Modify: `docs/superpowers/plans/2026-07-26-offline-convergence-performance.md`

**Interfaces:**

- Produces `build/libs/caustica-0.2.0.jar`.
- Keeps `gradle.properties` as the only source version.

- [x] Change `mod_version` from `0.1.0` to `0.2.0`.
- [x] Run all four focused PowerShell tests.
- [x] Run `powershell -ExecutionPolicy Bypass -File .\scripts\build_local.ps1`.
- [x] Verify the non-sources JAR filename, file size, SHA-256, and embedded `fabric.mod.json` version.
- [x] Review every design acceptance criterion against test/build evidence.
- [x] Finish all project documents with concise resolved/open status.
- [x] Produce the user-facing modification report; do not copy the JAR into either game instance without explicit authorization.
