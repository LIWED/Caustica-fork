# Caustica Project Status

## Current source version

- 2026-09-20 ITRP comparison: offline accumulation is also a running HDR mean; irradiance-cache reuse and simplified/clipped reflection transport are the larger differences. Stable offline mode bypasses several image denoisers while retaining cache lighting. Follow-up0.3.14 adds the optional experiment below; the geometric-normal/origin audit remains open. See `docs/OFFLINE_ITRP_COMPARISON_2026-09-20.md`.

- Source version: 0.3.17 (default-off adaptive offline reconstruction; rejected0.3.16 fixed smoothing replaced; raw accumulation retained).
- `gradle.properties` is the only version source; Gradle expands the Fabric metadata version.
- Java, native NGX shim, reflected shader records, and packaged resources have completed automated code/build verification.
- Glass/water transmission guides now retain the first interface normal, roughness, and depth while using transmitted opaque/sky albedo and ordinary motion; the bounded walker crosses at most four transparent interfaces.
- Water auxiliary-guide tracing now restores the full primary payload and uses the cached entering state, restoring the Beer-Lambert depth-absorption medium transition.
- Glass is code-complete for the current renderer path: realtime Light specular NEE is glass-only, the first-interface RR identity remains stable, glass tint uses square-root transmission, and reconstruction guides carry tint plus Beer attenuation.
- Water is code-complete for the current renderer path: refraction follows the geometric normal, TIR reflects safely, and both primary radiance and guide misses attenuate the current medium over the `10000.0` trace horizon rather than consuming the `-1` sentinel.
- Ordinary materials retain their reconstruction guides; shared GGX evaluation and the offline celestial estimator have subsequent corrections documented below.
- Offline dark-scene visual acceptance failed in user testing of 0.3.4 and 0.3.5. Other game-level visual/performance validation remains pending.

## Realtime Light blocks

- `minecraft:light` levels 1 through 15 use a dedicated realtime point-source table.
- Level 0 does not publish a source; empty-geometry sections retain captured Light sources.
- Ordinary emissive blocks retain their existing realtime behavior.
- One brightness-weighted Light source is sampled for each eligible realtime bounce.
- The realtime point-light flag and the offline full static-light flag are mutually exclusive.
- Immutable GPU table generations retire through the graphics timeline; ordinary update paths do not call `waitIdle()`.
- Multi-section dirty rebuilds keep per-section generation ownership through queued, in-flight, and staged phases.
- Idle pure-Light windows can rebase without geometry publication; a source-bearing rebase advances the Light revision once.

## Offline convergence restart — 2026-09-09

- User reproduction: persistent bright noise in low-light scenes across light and block types; not limited to water, glass or sunlight.
- Corrected shared GGX D/G1 scalar formulas: removed distribution-changing epsilon terms and stabilized the D peak denominator. Normal/G1 cosines are clamped to their valid range.
- New regression executes extracted production scalar functions with Java float arithmetic. Old source failed 12 checks; corrected source passes point values, boundary and NDF/VNDF density integration checks.
- Existing offline, glass/water, realtime Light, frame-stat and video-option contracts passed. Full 0.3.4 native/Java/shader build passed; packaged realtime/offline EXT/NV shaders match generated outputs.
- Offline contribution views 8–12 separate static direct light, emitter hits, celestial direct light, sky misses and bounce-depth contributions without changing path sampling. Production-policy tests, nine bypass mutations and 169 view-reset transitions pass.
- This is not proof that GPU VNDF sampling or dark-scene convergence is correct. Existing grazing-view PDF guards and the separate celestial lighting/disc models need further evaluation.
- Plan and evidence: `docs/superpowers/plans/2026-09-09-offline-convergence-restart.md`.
- Test candidate: `build/libs/caustica-0.3.4.jar`; the agent did not install it. User-provided game screenshots are now available. Usage: `docs/OFFLINE_DIAGNOSTICS.md`.
- User supplied 18 diagnostic screenshots after testing: low-light convergence is not accepted. Focus shifts to the celestial estimator (view 10), while view 12 overlaps all deeper-path sources. See `docs/superpowers/specs/2026-09-09-dark-scene-evidence-and-wavefront-assessment.md`.

## Offline celestial correction — 0.3.5

- Offline NEE and secondary celestial escape now share angular support, radiance and complementary MIS. Base atmosphere/stars are not weighted by celestial MIS.
- Decorative sun/moon sprites remain camera-visible; offline reflections/refractions use the active analytic lighting disc, so appearance can change.
- Offline celestial shadow rays stop at water/glass; actual dielectric paths carry transmission/reflection. Realtime/static-light tint shadows retain their earlier behavior. Transmissive caustics may still converge slowly.
- Last-vertex NEE, delta escape and particle-backside handling are explicit. Shared BRDF/PDF no longer floor NdotV at 1e-4; this grazing correction also affects realtime.
- PCG conversion uses its high 24 bits, guaranteeing `[0,1)` without changing the number of RNG state advances.
- Production-extracted scalar regressions, independent integration/paired sampling, a compiled unweighted-MIS negative control, integration source probes and existing regressions pass. Full native/Java/Slang/SPIR-V build passes; all 23 packaged shader hashes match generated output.
- Candidate `build/libs/caustica-0.3.5.jar` passed code/package checks but failed user dark-scene acceptance. No agent deployment. Plan: `docs/superpowers/plans/2026-09-09-celestial-mis-fix.md`.

## Failed 0.3.5 acceptance and reassessment — 2026-09-10

- User supplied `035_10/11/12.png`; reports persistent/reappearing fireflies above 10000 SPP and worse view 11. Different framing/resolution prevents a controlled pixelwise comparison with earlier images.
- Confirmed source defects: LabPBR linear roughness is squared again downstream; translucent average alpha is read as a normal-map flag before the glass branch; full Lambert plus GGX lacks energy allocation.
- Strict celestial shadow occlusion leaves transparent/specular chains poorly sampled. Current glass transmits straight, so a matching transmission NEE deserves separate design; water refraction and mirror chains remain harder.
- Single-surface numerical MIS tests do not cover material decoding, multi-bounce energy, transparent chains or GPU history. Current code correctness checks are not scene acceptance.
- Next: material-boundary/white-furnace regressions and targeted corrections, path/source tail diagnostics, then consistent thin-glass NEE and measured indirect-path variance reduction.
- Research and execution order: `docs/superpowers/specs/2026-09-10-firefly-path-reassessment.md`. Research-only update; source remains 0.3.5.

## Current limitations

- 0.3.6/0.3.7 implement the follow-up corrections below; game visual acceptance is still open. Do not inherit a convergence claim from CPU/build checks.
- 2026-09-14 pool A/B reproduction: user reports no visible bright points in the empty pool, but many in the sunlit part after adding water. Views 17 (2083 SPP) and 18 (4141 SPP) both contain celestial points. Water-related celestial transport is now a focused reproduction; this does not establish the cause of every older dark-scene point. See `docs/OFFLINE_DIAGNOSTICS.md`.

- Ordinary emissive blocks do not yet receive dedicated realtime explicit NEE.
- DLSS-RR visual validation for glass and water remains pending: single/stacked clear and stained glass, shallow/deep water, mixed interfaces, camera movement, waves, realtime/offline modes, and Frame Generation combinations.
- Full offline static-light-table rebuilds can still stall while waiting for GPU idle.
- Offline convergence and performance need game-level measurement.
- Realtime/offline resource transitions can cause a brief one-time stall.
- Game validation is pending for Light levels, source edits, section boundaries, occlusion, transmissive paths, duplicate-energy prevention, and 0/64/512-source performance.

## Material and transparent-path adjustment — 0.3.6, 2026-09-14

- LabPBR stores perceptual roughness in the payload; GGX alpha is squared once downstream. Translucent average alpha no longer enables a nonexistent terrain normal map. Both corrections apply to realtime and offline.
- Offline ordinary PBR uses a reciprocal, normalized diffuse budget bounded against Schlick/Smith GGX energy. Realtime keeps its existing BRDF/guide pair; SSS and particle shading are outside this energy guarantee.
- Offline celestial NEE traces a bounded thin-glass connection using actual per-hit Fresnel/tint; water/opaque geometry blocks it. Celestial MIS state is independent of static-light state and survives glass straight transmission.
- Offline glass tint uses fixed LOD0 (and a fixed breaking-overlay footprint), matching the two sampling strategies. Payload layout is unchanged. Distant patterned glass may show more aliasing.
- Views 13–19 expose base sky, analytic celestial escape, four transparent interface histories, and terminal celestial direct contributions; 11 remains the sum of 13/14.
- Numerical, boundary and source-flow regressions passed; final native/Java/Slang/SPIR-V build succeeded in 51 seconds. Candidate `build/libs/caustica-0.3.6.jar` has verified metadata and all 23 shader hashes. Evidence: `docs/superpowers/plans/2026-09-12-material-and-transparent-convergence.md`.
- Thin-glass NEE costs additional radiance traversal/shading; throughput, dark-scene convergence and appearance need game measurement. GPU path readback and raw HDR tail statistics remain future work.

## Water-pool convergence adjustment — 0.3.7, 2026-09-14

- Offline submerged ordinary receivers mix the original BSDF sampler with a solar proposal refracted through a horizontal interface. Full mixture PDFs feed throughput and static/celestial MIS; actual tracing retains geometry, Fresnel, absorption and bounce limits. This is continuation guiding, not additional NEE energy or general MNEE.
- The proposal is 5% wider than the unchanged emitter and disabled near the horizon to avoid FP32 inverse-refraction support errors. Guided legs defer roulette until another ordinary scattering decision; ray-cone lobe selection follows the original direction-conditioned BSDF distribution.
- Production-extracted FP32 tests cover Snell/Jacobian, actual-refraction emitter edges, six solar-height/occlusion integrals, Lambert/PBR density consumers, environment support, roulette compensation and four numerical negative controls. Simplified pool means match independent quadrature within 0.24%; this is not game evidence.
- GPU acceptance remains open: compare the retained empty/filled pool, then city/dark scenes. Primary water reflection, dry mirror chains and arbitrary caustics are outside this targeted improvement. Plan/evidence: `docs/superpowers/plans/2026-09-14-water-celestial-guiding.md`.
- Full native/Java/Slang/SPIR-V build passed (1m59s); final water/energy and existing celestial/transmission/offline/material/realtime-Light regressions passed. Candidate `build/libs/caustica-0.3.7.jar` has verified metadata, both locales and all 23 shader hashes; `build/water-celestial/package-verification.json` records the package. No agent game installation or GPU acceptance.

## Remaining water fireflies — 0.3.8, 2026-09-15

- User reports source fireflies roughly unchanged after0.3.7; new17/18 screenshots retain bright points, second HUD5078SPP. First sample count unspecified. 0.3.7 failed game acceptance.
- Fixed a demonstrated variance mechanism: BSDF-selected directions within the water guide receive the same roulette protection as guide-selected directions. Two minimum-probability roulette survivals previously amplified such samples by2500; the numerical regression preserves the mean while removing that conditional amplification.
- Views20/21 partition water-related celestial escape by final-leg protection; interface histories remain unchanged. Protected paths can retain variance from earlier segments, and unprotected paths are not necessarily erroneous. This is not proof of the screenshots' complete cause.
- Water transport/protection tests and484 diagnostic view transitions pass; independent review found no remaining blocker. Game acceptance remains pending for0.3.8.
- Full build passed in1m22s. Candidate `build/libs/caustica-0.3.8.jar` has verified version,23 shader hashes and both locales including20/21; evidence `build/water-celestial/package-0.3.8-verification.json`. No agent deployment or game validation.

## Actual-path evidence collection — 0.3.9, 2026-09-16

- 0.3.8 failed visual acceptance: user still sees dots in protected view20 and unprotected view21 (18714 SPP). The remaining cause is unconfirmed; this release makes no noise-reduction claim.
- Offline capture starts after256 samples. Observe water-related celestial-hit contributions >=256 linear units before view filtering; replay a bounded subset with the same ray/seed, discard its radiance and restore guides. Record material/normal/medium/throughput/roulette/event data without changing the estimator.
- Three mapped buffers use actual graphics completion, host visibility/invalidation and a bounded asynchronous local JSONL writer. Up to32 paths per dispatch and256 per process, maximum16MB. Session log is created even if no path qualifies; disable via `-Dcaustica.offline.pathProbe=false`.
- Logs: instance `logs/caustica-paths-*.jsonl`. Run the existing pool in source view after restarting; GPU capture and image equivalence are still unverified until a game run. Ordinary normal-map hits record the shading normal, not the lost geometric normal; normal solar reflections can consume the finite capture budget.
- Successful runtime packaging with `scripts/build_local.ps1` now deploys to `E:/Minecraft/.minecraft/versions/caustica_test/mods`, disables old metadata-identified Caustica jars reversibly, and verifies hashes. `-SkipDeploy` builds without installation. No unrelated mods are disabled.

- Verification: full native/Java/Slang/SPIR-V build passed (50s); probe decoder/ownership, shader isolation, water, offline/diagnostic, celestial, material/energy, transmission and reflected ABI checks passed. All23 packaged shader hashes/locales verified. Installed0.3.9 in the authorized test mods directory, SHA256 `c917e004c867dc25885a0213afad360de4ac9c546a9b887a743d274a0869cb44`;0.3.8 retained as `.jar.disabled`. GPU logging and convergence still await a game run.

## GPU-guided follow-up — 0.3.10, 2026-09-16

- Actual0.3.9 log contains256 captured paths with replay/source agreement within2.40e-7;171 protected outliers all lie near the proposal boundary. Confirmed inverse-Snell FP32 support rejection dropped the selected component from the mixture denominator.
- Selected water-guide samples now retain their generated forward density and Jacobian; arbitrary-direction evaluation keeps its support test.40000 edge cases pass; the old evaluator fails20747 deliberately stressed cases. No clamp or extra RNG.
- 85 unprotected records remain a separate sampling problem: actual water surfaces tilt up to7.54 degrees with procedural waves disabled, and dry-water reflection/transmission paths are not covered. The largest roulette-compensated event is40415.76. No full-scene convergence claim.
- Actual capture settings:24 bounces, source view0, PBR enabled, shader waves off. Findings, reproduction and references: `docs/OFFLINE_PATH_FINDINGS_2026-09-16.md`.

- Verification: full native/Java/Slang/SPIR-V build passed (55s), focused edge and existing water/diagnostic/celestial/probe contracts passed, independent review found no blocking issue. Verified all23 packaged shaders/locales; installed0.3.10 with destination hash80ad899e8a1929efe4e06dc900443627baca2e65c9aed2c2eb05039060c2ffeb and retained0.3.9 as `.jar.disabled`. GPU acceptance of this correction is pending.

## Water interface state — 0.3.11, 2026-09-16

- User reports fewer dots after0.3.10 and levelling water. New256-record log has no protected high-value paths, but geometry/camera/resolution/sun differ, so no version-only improvement percentage is established. Water tilt is now<=0.426 degrees; unprotected peaks still reach39667.27.
- 123 captures use air-side IOR while exiting the top water interface from below; all123 should TIR. In122/123, the shading-normal origin offset crosses the local water plane, contributing to stale medium state.
- Correct incident medium from cached interface orientation before radiance and both guide IOR decisions. Reflection retains corrected incident state; transmission keeps the existing far-side transition. The old captured-case regression fails, corrected consumers and three removal controls pass.
- Geometric offset/previously skipped interface recovery and remaining reflection/refraction sampling are open. Details: `docs/OFFLINE_PATH_FINDINGS_2026-09-16.md`.

- Verification: full native/Java/Slang/SPIR-V build passed (52s); captured incident-medium, transmission-guide, water proposal/edge, diagnostic and probe checks passed. Independent review found no blocking issue. Package version,23 shader hashes and locales verified; installed0.3.11 with hash `c4747b9266aa79ed6efb7e2dedece119497ee9dd37120b99b32e61f07aace82d`, preserving0.3.10 as `.jar.disabled`. New GPU verification remains pending.

## Actual-interface solar proposal — 0.3.12, 2026-09-16

- User reports fewer dots overall, little improvement close to the pool rim, almost clean20 and improved21. Two0.3.11 logs contain117/256 unprotected high-value records. The latter includes185 ordinary-wall→water-reflection→sun records without roulette amplification; tiny tilted exits also remain. These are bounded records, not unbiased image frequencies.
- Eligible offline ordinary vertices trace one deterministic pilot to select a water normal. Guide both dry reflection and submerged refraction; preserve full payload, retain the original BSDF with50% weight, and share the fixed context across all competing PDFs. Failed wet pilots retain horizontal guiding; failed dry pilots retain BSDF sampling.
- Reflection uses the actual wave-adjusted normal, refraction the geometric normal. Forward sampled density preserves the0.3.10 boundary correction. Actual traversal remains authoritative for Fresnel, absorption and visibility; realtime performs no pilot.
- Full build passed (65s). Extracted FP32 tests cover tilted mapping, boundary support, Jacobian/normalization and24 independent planar transport cases. Pilot isolation/fallback, medium, MIS, material, diagnostics/probe, offline and realtime regressions pass; independent review found no blocker. Runtime version,23 shader bytes and both locales verified.
- GPU convergence and added trace cost remain unmeasured. Spatially varying interfaces, pilot misses, multi-interface chains and geometric origin offsets are still open. Plan: `docs/superpowers/plans/2026-09-16-interface-celestial-guiding.md`.
- Installed0.3.12 to the authorized test mods directory; SHA256 `328cb4bcebff2e1a44632b827184fecbcf065d99c8f5280b79ea1a783e1e59df`. Verified destination bytes and0.3.11 `.jar.disabled` backup; restart Minecraft to load the candidate.

## General-scene reassessment — 0.3.13, 2026-09-20

- User rejects overall convergence: low-sun pools, reflective room at3761SPP and reported scenes without water/glass/direct sunlight retain dots.255/256 latest captures are below the water-guide horizon gate. Old water-only capture ended before the later room screenshot.
- Actual FP32 vector-BSDF audit passes324 material and108 distribution cases plus two numerical negative controls. No sampler/PDF bug established; GPU geometry, textures, accumulation execution and multi-bounce variance remain open.
- Diagnostics now admit all computed direct lighting and secondary emitter/sky/celestial sources at threshold32, with256 records per accumulation and2048 per renderer lifetime (16MB cap). Generation IDs isolate stale GPU readbacks. Transport/RNG unchanged.
- Full build (57s), diagnostic/quota/offline tests and independent review pass. This gathers evidence and is not a claimed noise fix. Findings/references/acceptance scenes: `docs/OFFLINE_GENERAL_REASSESSMENT_2026-09-20.md`.
- Verified0.3.13 installed to the authorized test mods directory, SHA256 `61ff2d269f58e4045bc8328d9e6d65c1ed61ab2fab62edf6a580bf686bd20365`;0.3.12 retained as `.jar.disabled`. All23 packaged shader bytes/locales match; actual room capture remains pending.

## Optional indirect-reflection experiment — 0.3.14, 2026-09-20

- Adds Off/Mild/Stronger offline regularization, default Off. After non-delta scattering, later ordinary PBR uses one adjusted roughness for evaluation/sampling/PDF/MIS; first visible ordinary surfaces and ideal-only chains retain authored roughness. Realtime and water/glass BSDFs stay unchanged. Mode switches reset accumulation.
- Extracted FP32 policy and12 analytic transport cases show reduced observed variance with measurable reference-mean shifts; the grazing baseline remains underconverged. This is biased variance reduction, not a general firefly fix or GPU speedup claim. Report: `docs/OFFLINE_REGULARIZATION_EXPERIMENT_2026-09-20.md`.
- New mode/history tests, previous BSDF/offline/probe/interface regressions and independent review pass. Full native/Java/shader build passed using cached dependencies;23 packaged shaders, runtime metadata and locales verified.
- Installed0.3.14 automatically and preserved0.3.13 as `.jar.disabled`; SHA256 `db2abdc9cd8f484744bec22f0a2b404efeb57d2920609d1f3fca74b9f7f0e465`. Restart, then select Mild explicitly for source-view A/B in the original reflective room. GPU acceptance remains pending.

## Ordinary-path sampling allocation — 0.3.15, 2026-09-20

- User reports partial smoothing improvement at30000SPP, with slow convergence and residual grain. Matching room captures contain ordinary-only chains whose throughput reaches26.174; old lobe selection ignores the reduced diffuse energy budget.
- Offline sampling, full PDF and guided posterior now share per-lobe weight-bound allocation. BRDF, smoothing strength and realtime probability expression remain unchanged. Fixed-material means pass independent integration; existing lobe-conditioned texture filtering prevents a blanket full-scene equivalence claim.
- New45RGB cases and old-proposal negative control, affected BSDF/water/energy/diagnostic/probe regressions, independent review and full build/package checks pass. Game acceptance remains open. Evidence and short source-view retest: `docs/OFFLINE_LOBE_SAMPLING_2026-09-20.md`.
- Installed0.3.15 to the authorized test mods directory; destination SHA256 `8da068577da7b5c2f48cb97f4bf057653e001f087bf289293d161e423c4eee05`.0.3.14 retained disabled with its original hash.

## Offline display reconstruction — 0.3.16, 2026-09-21

- User reports no perceptible0.3.15 speed/image improvement and prioritizes fireflies/grain. Latest bounded room captures remain ordinary-only category10; not final-image noise statistics.
- User accepted a switchable image denoiser. Add robust isolated-peak handling plus three guided spatial passes after raw exposure metering, only in offline source view0. Raw FP32 history remains untouched; toggle does not reset samples. Default enabled, with documented fine-highlight/texture loss.
- Production-kernel CPU image fixtures and bypass/edge negative controls, routing/lifecycle checks, previous accumulation/diagnostics/regularization regressions and independent review pass. GPU appearance and cost remain unverified; this is reconstruction, not proof of transport convergence. Details: `docs/OFFLINE_DENOISE_2026-09-21.md`.
- Full build and24 packaged shader/locale checks pass;23 existing shader binaries unchanged. Installed0.3.16, SHA256 `12f8475788856226e3ea2a04c4389ef989adb5da49dc864881f024d4f8f866c6`; retained0.3.15 disabled and verified both hashes.

## Detail recovery — 0.3.17, 2026-09-21

- User rejects0.3.16 for severe detail loss. A new noise-free low-contrast reflection fixture retains only0.371211 contrast with the old kernel; previous checks omitted this failure class.
- Replace fixed three-scale smoothing with measured temporal moments, uncertainty-confirmed peak handling and one radius2 adaptive pass. Zero/insufficient/invalid variance bypasses; raw-history contrast and raw mean remain independent of filtering. New default-off configuration ignores old denoise=true.
- New stable/low-noise fine-detail, true-point, weighted-moment/reset/overflow tests and related regressions pass. Independent review correction for masked nonfinite moments included. General convergence and game detail acceptance remain open; see `docs/OFFLINE_DETAIL_RECOVERY_2026-09-21.md`.
- Full build/24-shader verification passed; only accumulation/denoise shader binaries changed. Installed0.3.17 with SHA256 `2fd632033395b4466e19162d2c4eac9596b489bcc1df029144d38367577d42d2`;0.3.16 retained disabled, both hashes verified.
