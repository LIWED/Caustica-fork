# Transmission Guides and Water Absorption Implementation Plan

> **Superseded:** Historical plan retained without rewriting its execution record.
> Continue with [Glass Reflection and Stable Water Transmission](2026-07-30-glass-reflection-and-stable-water-transmission.md).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore depth-dependent water absorption and reduce realtime RR blur through glass and multi-interface water.

**Architecture:** Preserve the primary radiance payload across auxiliary guide rays, then replace the one-interface water guide with a bounded transparent-interface walker shared by glass and water. Keep first-interface depth/normal for reflection and Frame Generation while background albedo/motion follows the transmitted opaque or sky hit.

**Tech Stack:** Slang ray-generation shaders, Vulkan ray tracing, NVIDIA DLSS Ray Reconstruction, PowerShell contract tests, Gradle shader compilation.

## Global Constraints

- Work only under `F:\mygit\test\Caustica_n\Caustica-fork`.
- Do not execute Git operations.
- Do not copy a JAR into a game instance.
- Keep ordinary opaque, emissive, particle, and realtime `minecraft:light` behavior unchanged.
- Keep shared primary depth/normal on the first transparent interface.
- Limit auxiliary guide traversal to four transparent interfaces.
- Preserve all primary `Payload` fields across auxiliary guide tracing.
- Update `docs/PROJECT.md`, `docs/CHANGELOG.md`, and `docs/BUGS.md`; keep each below 200 lines.

---

### Task 1: Protect Water Medium State

**Files:**

- Create: `scripts/test_transmission_guides.ps1`
- Modify: `shaders/world/world.rgen.slang`
- Create: `.superpowers/sdd/2026-07-30-transmission-guides-and-water-absorption/task-1-report.md`

**Interfaces:**

- The primary water hit produces a cached `bool waterEntering`.
- Auxiliary guide tracing may overwrite the global `payload`.
- The caller restores a full `Payload primaryPayload` before Fresnel continuation.
- Successful transmission assigns `inWater = waterEntering`.

- [ ] **Step 1: Write the failing focused contract**

Require the primary water branch to cache `payloadWaterEntering()` and the full `Payload` before the guide helper, restore `payload` after the helper, and update `inWater` only from the cached Boolean.

- [ ] **Step 2: Run the focused contract and verify RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_transmission_guides.ps1
```

Expected: failure because the water entering state is still read from the overwritten helper payload.

- [ ] **Step 3: Implement the minimal payload/state preservation**

Cache the primary payload and entering flag before the helper call, restore the payload immediately afterward, and use the cached flag on water transmission.

- [ ] **Step 4: Run the focused contract and shader compilation**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_transmission_guides.ps1
& '.\scripts\build_local.ps1' -SkipNative -GradleArgs @('compileShaders','--rerun-tasks')
```

Expected: both commands exit 0.

---

### Task 2: Add Bounded Glass/Water Transmission Guides

**Files:**

- Modify: `scripts/test_transmission_guides.ps1`
- Modify: `shaders/world/world.rgen.slang`
- Create: `.superpowers/sdd/2026-07-30-transmission-guides-and-water-absorption/task-2-report.md`

**Interfaces:**

- Replace `refractedGuideHit` with:

```slang
void transmissionGuideHit(
        float3 surfacePos,
        float3 incidentDir,
        float3 surfaceNormal,
        uint surfaceMaterial,
        bool inWaterAtSurface,
        bool waterEnteringAtSurface,
        float rayConeWidth,
        float rayConeSpread,
        out float3 hitCamRel,
        out float3 motionPrev,
        out bool transmitted,
        out float3 diffuseAlbedo,
        out float3 specAlbedo);
```

- Define `MAX_TRANSMISSION_GUIDE_INTERFACES = 4`.
- Glass starts with straight transmission.
- Water starts with refraction and updates the local water state from the cached entering flag.
- Later glass/water hits continue until opaque, sky, TIR, or the interface cap.

- [ ] **Step 1: Extend the focused contract and verify RED**

Require the shared helper, four-interface cap, both material branches calling it, full payload restore in both callers, opaque/sky guide output, and water-state advancement across later water hits.

- [ ] **Step 2: Implement the bounded guide walker**

Use the existing radiance SBT and `CULL_SECONDARY`. Compute opaque diffuse/specular guides with the existing PBR formulas. Return sky constants on a miss. Keep surface fallbacks when no transmitted target exists.

- [ ] **Step 3: Integrate the glass caller**

Keep glass normal/roughness/depth on the glass surface. Populate background albedo/specular albedo/motion through `transmissionGuideHit`, then restore the primary payload before the Fresnel path branch.

- [ ] **Step 4: Integrate the water caller**

Replace the one-interface helper call while retaining the Task 1 cached entering state and primary-payload restore.

- [ ] **Step 5: Run focused and regression verification**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_transmission_guides.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_realtime_light_blocks.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_bounce_video_options.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_frame_generation_video_toggle.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_frame_stats_stage_contract.ps1
& '.\scripts\build_local.ps1' -SkipNative -GradleArgs @('compileShaders','compileJava','--rerun-tasks')
```

Expected: every command exits 0.

---

### Task 3: Documentation, Full Build, and Review

**Files:**

- Modify: `docs/PROJECT.md`
- Modify: `docs/CHANGELOG.md`
- Modify: `docs/BUGS.md`
- Modify: `docs/superpowers/specs/2026-07-30-transmission-guides-and-water-absorption-design.md`
- Modify: `.superpowers/sdd/2026-07-30-transmission-guides-and-water-absorption/progress.md`
- Create: `.superpowers/sdd/2026-07-30-transmission-guides-and-water-absorption/task-3-report.md`

**Interfaces:**

- Records code-complete behavior without claiming game-level visual validation.
- Produces the current-version JAR under `build/libs`.

- [ ] **Step 1: Update required project records**

Record the water payload overwrite cause, the restored Beer-Lambert medium transition, the bounded guide walker, automated verification, and remaining game validation.

- [ ] **Step 2: Run the complete local build**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build_local.ps1
```

Expected: native NGX shim and Gradle build exit 0.

- [ ] **Step 3: Verify artifact contents**

Record the exact current-version JAR name, byte size, SHA-256, Fabric metadata version, four ray-generation shader resources, and native NGX shim.

- [ ] **Step 4: Perform final review**

Review payload preservation, medium transitions, interface-cap termination, guide fallbacks, glass/water caller integration, unchanged FG depth resources, test evidence, and documentation accuracy. Resolve all Critical and Important findings.
