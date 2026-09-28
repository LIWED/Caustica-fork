# Offline Convergence Restart Implementation Plan

> Execute the approved design with test-driven development and independent review. Preserve this checkout's existing edits.

**Goal:** Restart offline convergence work with a verified GGX correction and an evidence-based continuation plan.

**Architecture:** Keep the existing renderer and light tables. Correct shared scalar GGX math without changing the sampler, then validate CPU numerical behavior and all shader variants.

**Tech Stack:** Java 25, Slang, Vulkan/SPIR-V, PowerShell, Gradle.

## Constraints

- Work only in `F:\mygit\test\Caustica_n\Caustica-fork`.
- Preserve pre-existing edits; no Git commits, deployments, credentials or game-instance changes.
- No default luminance clamp or wholesale renderer port.
- Source/test/build success is not game-level convergence acceptance.

## Task 1: Baseline and regression tests

Files: `scripts/test_ggx_sampling_behavior.ps1`, `scripts/tests/GgxSamplingBehaviorTest.java`.

- [x] Run existing offline behavior and transmission regressions; record baseline.
- [x] Extract actual `ggxD` and `ggxG1` scalar bodies into a temporary Java float class; fail closed if extraction fails.
- [x] Compare D against independent double GGX reference at roughness 0.045/0.1/0.3/1 and normal/grazing angles.
- [x] Verify distribution mass with sampling-aware integration rather than a uniform grid that misses narrow peaks.
- [x] Run `powershell -NoProfile -File scripts/test_ggx_sampling_behavior.ps1` and record expected RED before edits.

## Task 2: Minimal production correction

File: `shaders/world/world.rgen.slang`.

- [x] Replace cancellation-prone `NdotH²*(a²-1)+1` with `(1-NdotH)*(1+NdotH)+NdotH²*a²`.
- [x] Remove the distribution-changing `+1e-7` from D; retain the existing positive roughness boundary.
- [x] Check G1 against the exact visible-normal model and correct only if needed.
- [x] Re-run numerical regression GREEN; independently review the patch and test linkage.

## Task 2b: Dark-scene contribution diagnostics

Files: `world.rgen.slang`, `RtComposite.java`, `RtVideoOptions.java`, English/Chinese localization, `scripts/test_offline_diagnostics.ps1` and its behavior test.

- [x] Observe RED for missing contribution selection and output linkage.
- [x] Add debug views 8–12: static direct, emission hit, celestial direct, sky miss, bounce>0.
- [x] Filter contribution values only after their computations, keeping RNG and tracing unchanged; compile realtime as identity.
- [x] Preserve guide views 1–7; diagnostic selections show regular realtime output while waiting/moving.
- [x] Verify contribution partition, indirect overlap, signature reset and output linkage; reject discarded-return mutation.
- [x] Independently review diagnostics and final integration.

## Task 3: Integration verification and continuation

Files: `docs/PROJECT.md`, `docs/CHANGELOG.md`, `docs/BUGS.md`, this plan.

- [x] Run offline behavior, transmission guides, realtime Light and frame-stat contracts (rerun after diagnostics; video-option contracts also pass).
- [x] Run `scripts/build_local.ps1` with Java 25; verify Slang/SPIR-V variants and packaged resources.
- [x] Record test results and material limits in the three project documents (each under 200 lines).
- [x] Document next-stage celestial model/diagnostic design and unresolved game reproduction requirements.

## Evidence ledger

- Initial source: 0.3.3; existing dirty files include the raygen shader and three project docs.
- Previous turn's numeric probe found D peak ~77624.72 versus ~40.98 at roughness 0.045.
- GGX RED: 12 numerical failures; roughness 0.045 projected D mass 0.0355687; roughness 0.1 mass 0.593986.
- GGX GREEN: extracted D/G1 reference and distribution checks pass, with point tolerances 2e-6 and cosine boundary probes.
- Independent GGX review: no required fixes; existing extreme-grazing NdotV PDF floor remains outside the scalar correction.
- GGX-stage full build: SUCCESS in 57s, native shim plus all shader variants; Gradle has no Java test sources, so standalone regression scripts are required.
- Build log: `build/offline-restart-20260909/build.log`; pre-fix shader snapshot: `build/offline-restart-20260909/world.rgen.before-ggx.slang`.
- User clarified that noise affects low-light scenes across light/block types. Diagnostics promoted into this round; final version 0.3.4 package verification passed.
- Diagnostic RED: missing production scalar contribution policy. GREEN: full view/category/bounce policy matrix, nine output-bypass mutations and 169 transitions through the actual accumulation state.
- Independent diagnostic review found no blocking logic issue; documented finite-value/rounding limits of contribution additivity before frame sanitization.
- Final build: SUCCESS in 58s; log `build/offline-restart-20260909/build-0.3.4.log`. Java emits an existing deprecated-API notice in RtComposite; no compilation failure.
- Package: `build/libs/caustica-0.3.4.jar`, 20,497,904 bytes; SHA-256 `20841AED837F8BC01669FB24C25E18D66838DA061DB4AD923F4E8D8C820AFD7B`.
- Verified JAR metadata 0.3.4, realtime/offline EXT/NV raygen plus accumulation SPIR-V byte hashes against generated output, and both diagnostic locales; machine-readable evidence in `build/offline-restart-20260909/package-verification.json`.
- All first-round implementation tasks complete. Game deployment and visual convergence remain unperformed; do not mark the original low-light symptom resolved.
- Resume: obtain fixed-exposure diagnostic views with SPP/bounces from the actual dark scene using `docs/OFFLINE_DIAGNOSTICS.md`; prioritize the observed source category, not the old documentation's assumed cause.
- Screenshot follow-up received: 18 images, 1500/3000/6000 SPP, 8 bounces, +0.4 EV; view 10 remains strongly noisy, 12 overlaps deeper sources. Visual acceptance failed; analysis recorded in `../specs/2026-09-09-dark-scene-evidence-and-wavefront-assessment.md`.
- Next implementation unit: coherent celestial radiance/PDF/MIS, not a standalone D edit. Wavefront is a separate migration decision; official 5d6bf62 still contains the same documented celestial issue.
- 0.3.5 follow-up: celestial correction passed local numerical/build checks but failed user screenshots above 10000 SPP. Reassessment expands to material decoding, BSDF energy and full-path variance; see `../specs/2026-09-10-firefly-path-reassessment.md` and the reopened celestial plan.
