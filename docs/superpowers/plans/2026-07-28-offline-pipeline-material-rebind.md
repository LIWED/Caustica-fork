# Offline Pipeline Material Rebind Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the 2 SPP offline-rendering reset loop by preventing ordinary FP16/FP32 pipeline switches from rebuilding material atlases and dirtying all terrain.

**Architecture:** Treat pipeline descriptor binding and material-source rebuilding as separate operations. Reuse valid LabPBR atlas views when the Minecraft block-atlas handle is unchanged; rebuild atlases and re-extract terrain only on first initialization or an actual source-atlas change.

**Tech Stack:** Java 25 (`D:\program\java25`), Fabric/Minecraft 26.2, Vulkan, PowerShell contract tests, Gradle 9.5.

## Global Constraints

- Work only under `F:\mygit\test\Caustica_n\Caustica-main`.
- Do not execute Git commands.
- Do not copy a JAR to a game instance.
- Do not modify `E:\Minecraft\.minecraft\versions\Caustica26.2`.
- Target version is `0.3.2`.
- Keep `sceneRevision` in the offline render signature.
- Real terrain or light changes must continue to reset accumulation.
- Resource-pack reloads must continue rebuilding LabPBR atlases and terrain material flags.
- Do not change timing, freeze/thaw ownership, bounce settings, glass/water guides, or light-block behavior.
- Update `docs/PROJECT.md`, `docs/CHANGELOG.md`, and `docs/BUGS.md`; keep each under 200 lines.

---

### Task 1: Source-Aware Material Rebinding

**Files:**

- Modify: `scripts/test_offline_rendering_behavior.ps1`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java`

**Interfaces:**

- Consumes: `boundAtlasHandle`, `RtBlockMaterials.INSTANCE.viewS()`,
  `RtBlockMaterials.INSTANCE.viewN()`, and the current block-atlas view.
- Produces: a local decision equivalent to:

```java
boolean rebuildBlockMaterials = boundAtlasHandle != atlasView
        || RtBlockMaterials.INSTANCE.viewS() == 0L
        || RtBlockMaterials.INSTANCE.viewN() == 0L;
```

- [x] **Step 1: Add the failing regression contract**

Extend `test_offline_rendering_behavior.ps1` to require that
`bindWorldTextures` computes whether the block material source changed before
overwriting `boundAtlasHandle`, and that `RtBlockMaterials.reset()`,
`prepareAll()`, and `RtTerrain.markAllDirty()` occur only inside the rebuild
branch. Require the unchanged-source branch to bind the existing `viewS()` and
`viewN()` handles.

- [x] **Step 2: Run the test and verify RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
```

Expected: the Java behavior suite passes and the source contract fails because
0.3.1 rebuilds material atlases and dirties terrain unconditionally.

- [x] **Step 3: Implement the minimal source-aware branch**

In `bindWorldTextures`, capture the current block-atlas view and determine
whether material source data must be rebuilt before assigning
`boundAtlasHandle`.

Always bind the block atlas, entity fallback, LabPBR views, and celestial
atlas to the new pipeline. Only when `rebuildBlockMaterials` is true:

```java
RtBlockMaterials.INSTANCE.reset();
RtBlockMaterials.INSTANCE.prepareAll();
RtTerrain.markAllDirty();
```

When false, reuse `viewS()` and `viewN()` without resetting their caches or
requesting terrain re-extraction.

- [x] **Step 4: Verify GREEN and compile**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
& '.\scripts\build_local.ps1' -SkipNative -GradleArgs @('compileJava')
```

Both commands must exit zero.

- [x] **Step 5: Independently review the fix**

Confirm the test detects the original unconditional invalidation, resource
reloads still take the rebuild branch, unchanged FP16/FP32 switches do not
dirty terrain, and real `sceneRevision` changes still reset accumulation.

---

### Task 2: Version 0.3.2, Records, and Deliverable

**Files:**

- Modify: `gradle.properties`
- Modify: `docs/PROJECT.md`
- Modify: `docs/CHANGELOG.md`
- Modify: `docs/BUGS.md`
- Modify: `docs/superpowers/plans/2026-07-28-offline-pipeline-material-rebind.md`
- Create: `.superpowers/sdd/2026-07-28-offline-pipeline-material-rebind/progress.md`
- Create: `.superpowers/sdd/2026-07-28-offline-pipeline-material-rebind/task-1-report.md`
- Create: `.superpowers/sdd/2026-07-28-offline-pipeline-material-rebind/task-2-report.md`

**Interfaces:**

- Produces: `build/libs/caustica-0.3.2.jar`.

- [x] **Step 1: Update the version and project records**

Set `mod_version=0.3.2`. Record the 2 SPP loop, its internal
material-rebind/`sceneRevision` cause, the source-aware fix, and pending
in-game verification. Do not mark glass/water blur resolved.

- [x] **Step 2: Run all focused regressions**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_bounce_video_options.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_frame_generation_video_toggle.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_frame_stats_stage_contract.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_local_build_environment.ps1
```

- [x] **Step 3: Run the complete build**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build_local.ps1
```

- [x] **Step 4: Verify both JARs**

For `caustica-0.3.2.jar`, record exact bytes, SHA-256, embedded version, four
world raygen SPIR-V resources, and
`caustica/natives/windows-x64/ngxshim.dll`.

For `caustica-0.3.2-sources.jar`, record bytes and SHA-256, require Java
sources and zero `.class` files, and label it non-installable.

- [x] **Step 5: Final independent review**

Check design compliance, test evidence, documentation accuracy, version/JAR
identity, the no-Git/no-copy constraints, and the explicit need for an in-game
static-camera smoke test.
