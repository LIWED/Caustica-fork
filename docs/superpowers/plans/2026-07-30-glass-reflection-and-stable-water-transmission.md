# Glass Reflection and Stable Water Transmission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make strong realtime Light sources produce stable glass highlights and eliminate the stained-glass/water temporal ink artifact without changing ordinary block lighting.

**Architecture:** Keep reflection reconstruction data on the first dielectric interface while ordinary albedo and motion follow a tint/absorption-adjusted transmitted endpoint. Add a glass-only specular direct estimator for the dedicated realtime Light table, and stop using time-varying wave normals for refraction until refracted optical flow is available.

**Tech Stack:** Slang ray-generation shaders, Vulkan ray tracing, NVIDIA DLSS Ray Reconstruction guides, PowerShell regression contracts, Gradle shader compilation.

## Global Constraints

- Work only under `F:\mygit\test\Caustica_n\Caustica-fork`.
- Do not execute Git operations.
- Do not copy a JAR into a game instance.
- Keep the source version at `0.3.3`.
- Keep ordinary opaque, emissive, particle, and water direct-light behavior unchanged.
- Do not increase glass Fresnel reflectivity or add diffuse glass lighting.
- Keep the four-transparent-interface guide cap and full primary-payload restore.
- Keep animated water waves on reflection/highlights/caustics, but not refraction.
- Update `docs/PROJECT.md`, `docs/CHANGELOG.md`, and `docs/BUGS.md`; keep each below 200 lines.

---

### Task 1: Regression Contracts for Dielectric Guide Identity and Stable Transmission

**Files:**

- Modify: `scripts/test_transmission_guides.ps1`
- Modify: `scripts/test_realtime_light_blocks.ps1`
- Create: `.superpowers/sdd/2026-07-30-glass-reflection-and-stable-water-transmission/task-1-report.md`

**Interfaces:**

- `transmissionGuideHit` publishes only transmitted ordinary albedo/motion identity.
- Glass/water `gv_specAlb` is computed with `rrSpecularAlbedo` from dielectric F0 and first-interface view cosine.
- The glass direct estimator calls `sampleRealtimeLightBlockDirect` with zero diffuse albedo.
- Primary and auxiliary water refraction use geometric normals; wave normals remain in reflection/Fresnel paths.

- [x] **Step 1: Add the glass realtime-Light regression**

Extend `test_realtime_light_blocks.ps1` so removing the glass-only `sampleRealtimeLightBlockDirect` call, giving it nonzero diffuse albedo, or placing it outside the glass branch fails the contract.

- [x] **Step 2: Add the reconstruction/transmission regressions**

Extend `test_transmission_guides.ps1` so the test fails when glass/water specular guides use transmitted endpoint specular albedo, transmitted diffuse albedo omits accumulated tint/Beer attenuation, glass uses full tint per interface, or water refraction uses `applyWaterWaves`.

- [x] **Step 3: Run both focused contracts and verify RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_transmission_guides.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_realtime_light_blocks.ps1
```

Expected: both fail for the newly required behavior while their existing assertions still execute.

---

### Task 2: Implement Glass Highlight and Stable Dielectric Guides

**Files:**

- Modify: `shaders/world/world.rgen.slang`
- Create: `.superpowers/sdd/2026-07-30-glass-reflection-and-stable-water-transmission/task-2-report.md`

**Interfaces:**

- Define dielectric F0 as `((ior - 1) / (ior + 1))^2`.
- `transmissionGuideHit` accepts initial glass transmission and current water extinction, accumulates `guideTransmission`, and multiplies only the transmitted diffuse endpoint albedo. A finite hit uses `payload.hitT`; a miss uses the `10000.0` trace horizon, never the `-1` miss sentinel.
- Glass direct Light contribution uses `sampleRealtimeLightBlockDirect(hitPos, n, -rd, float3(0.0), glassF0, GLASS_GUIDE_ROUGH, true, seed)`.
- Glass/water `gv_specAlb` uses `rrSpecularAlbedo(interfaceF0, guideRoughness^2, cosI)`.
- Water uses a wave-perturbed reflection normal and an unperturbed geometric transmission normal.

- [x] **Step 1: Add transmitted-guide attenuation**

Initialize guide transmission from the primary surface, multiply `sqrt(clamp(payload.albedo, 0, 1))` on later glass crossings, and multiply `exp(-guideWaterExt * guideSegmentDistance)` for every guide segment traced inside water before publishing opaque or sky albedo. `guideSegmentDistance` is a positive hit distance or the `10000.0` trace horizon on miss.

- [x] **Step 2: Align first-interface RR guides**

Keep transmitted ordinary albedo/motion, but set glass and water specular albedo from their first-interface dielectric F0, guide roughness, and view cosine.

- [x] **Step 3: Add glass-only realtime Light direct specular**

Accumulate the existing realtime point-source estimator inside the glass branch with zero diffuse input. Preserve the existing realtime/offline flag gate and leave ordinary emission and other NEE unchanged.

- [x] **Step 4: Stabilize stained-glass transmission**

Use square-root tint per transmitted glass interface in both the radiance path and guide walker.

- [x] **Step 5: Stabilize water refraction**

Use the geometric water normal for primary and guide refraction. Retain the animated normal for reflection direction, interface specular guides, and existing caustics. If geometric refraction is TIR, force Fresnel reflection and retain the current medium.

- [x] **Step 6: Run focused GREEN verification**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_transmission_guides.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_realtime_light_blocks.ps1
& '.\scripts\build_local.ps1' -SkipNative -GradleArgs @('compileShaders','--rerun-tasks')
```

Expected: all commands exit 0.

---

### Task 3: Regression Suite, Documentation, and Full Build

**Files:**

- Modify: `docs/PROJECT.md`
- Modify: `docs/CHANGELOG.md`
- Modify: `docs/BUGS.md`
- Modify: `.superpowers/sdd/2026-07-30-glass-reflection-and-stable-water-transmission/progress.md`
- Create: `.superpowers/sdd/2026-07-30-glass-reflection-and-stable-water-transmission/task-3-report.md`

**Interfaces:**

- Records code-complete behavior without claiming game-level visual validation.
- Produces the current `0.3.3` JAR under `build/libs`.

- [x] **Step 1: Run all focused regressions and compilation**

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

- [x] **Step 2: Update required project records**

Record the missing point-source reflection cause, mismatched RR guide identity, un-reprojectable animated refraction, tint/Beer guide mismatch, conservative resolution, automated evidence, and pending game validation.

- [x] **Step 3: Run the complete local build**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build_local.ps1
```

Expected: native NGX shim and Gradle build exit 0.

- [x] **Step 4: Verify artifact and final review**

Record the exact JAR name, byte size, SHA-256, Fabric metadata version, ray-generation resources, native NGX shim, and resolve all Critical/Important review findings.
