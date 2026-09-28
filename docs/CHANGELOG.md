# Changelog

## [0.3.17] - 2026-09-21

- Full build/24-shader package checks passed. Automatically installed0.3.17 and disabled/preserved0.3.16; active and backup hashes verified. Only accumulation/denoise shader binaries changed.

- Record failed0.3.16 acceptance: fixed spatial smoothing destroys fine detail even without noise. Replace it with uncertainty-gated peak filtering and one local adaptive pass, backed by separate weighted temporal moments; raw mean and exposure remain independent.
- Default Off under new `offline.denoise-adaptive` key; persisted old denoise=true cannot silently enable it. Stable, insufficient-history and invalid-statistics pixels bypass reconstruction. Existing diagnostic views stay raw.
- Add fine reflection/point-highlight/low-noise detail tests, real accumulation-kernel variableSPP statistics, reset/cap/nonfinite tests and fixed-strength negative control. Related regressions and independent review pass; full game visual acceptance remains pending. See `docs/OFFLINE_DETAIL_RECOVERY_2026-09-21.md`.

## [0.3.16] - 2026-09-21

- Full build and24-shader package verification passed;23 existing shader binaries unchanged. Automatically installed0.3.16 and retained0.3.15 disabled; destination and backup hashes verified.

- Record failed perceptual acceptance of0.3.15; user now authorizes optional display reconstruction. Add default-on Offline Image Denoising: compatible-neighbor outlier filter followed by three normal/depth/material/color-aware smoothing stages, source view0 only.
- Preserve raw FP32 history and raw exposure; toggling does not reset accumulation. Add independent scratch images, immutable pass descriptors, barriers/cleanup, bilingual settings and existing-stage timing. Tiny true highlights and texture details may be softened; no integrator change or true-convergence claim.
- Production GLSL CPU fixtures cover grain/fireflies/HDR/borders/material/geometry/reflection edges and negative controls; routing and existing offline regressions pass. Evidence and retest: `docs/OFFLINE_DENOISE_2026-09-21.md`.

## [0.3.15] - 2026-09-20

- Automatically installed the verified runtime to the authorized test instance; retained0.3.14 disabled and verified both destination/backup hashes.

- Use offline ordinary-lobe weight bounds including the diffuse energy budget to allocate reflection/diffuse samples. Sampling, PDF and guided posterior share one probability; preserve BRDF, smoothing strength and realtime probability expression.
- Diagnose ordinary-only GPU paths with weight26.174 after repeated high-F0 scattering. Add45RGB numerical cases, independent means and old-allocation negative control; affected regressions, independent review and full build/package checks pass. Single-step variance improvement is not a game speed claim; downstream texture filtering and rare lighting tails remain limitations.
- Preserve0.3.14 experiment data and record partial user improvement at30000SPP. Details: `docs/OFFLINE_LOBE_SAMPLING_2026-09-20.md`.

## [0.3.14] - 2026-09-20

- Add an optional offline indirect-reflection smoothing experiment (Off/Mild/Stronger, default Off). Track non-delta history and regularize only subsequent ordinary PBR with matched evaluation/sampling/PDF/MIS. Reuse push-flag bits; mode changes reset history. Realtime and ideal water/glass interfaces unchanged.
- Added production-extracted policy/transport experiments, primary-roughening negative control, shader wiring and nine history-transition checks. Existing BSDF/offline/diagnostic/probe/interface checks and independent review pass. Report documents biased brightness shifts and an underconverged grazing baseline; no GPU convergence claim.
- Full native/Java/shader build and package verification passed. Automatically installed0.3.14 to the test instance with verified hash, preserving0.3.13 disabled. See `docs/OFFLINE_REGULARIZATION_EXPERIMENT_2026-09-20.md` for source-view A/B instructions.

## Research — 2026-09-20 (no version change)

- Compared local ITRP offline accumulation, cache propagation, reflection sampling and stable-frame filter bypasses against0.3.13. Documented why its approximate transport cannot serve as an equivalent full-path convergence baseline, and why copying its clipped GGX random domain would invalidate current PDFs.
- Recorded separate next experiments for geometric-normal/origin correctness and optional indirect-path regularization, with cache reuse as a larger follow-up. Source findings are not GPU acceptance; renderer/package unchanged. See `docs/OFFLINE_ITRP_COMPARISON_2026-09-20.md`.

## [0.3.13] - 2026-09-20

- Recorded failed general-scene acceptance;255/256 latest water captures fall below the solar guide's horizon gate. Old capture does not cover the later reflective room.
- Broaden bounded observation to direct lighting and secondary emissive/sky sources, threshold32. Rearm256-record quota per accumulation with generation isolation,2048 lifetime records and16MB cap. No transport/appearance change.
- Added actual FP32 vector-BSDF audit and capture-rearming regressions;324 material/108 distribution cases and numerical negative controls pass. Analyzer reports source/generation/nonfinite counts and restricts legacy horizontal-edge analysis to applicable versions. Build and diagnostic/offline tests pass; GPU scene diagnosis remains pending.
- Installed verified0.3.13 automatically to the test instance, preserving0.3.12 as a disabled backup; destination hash and23 packaged shaders/locales verified.

## [0.3.12] - 2026-09-16

- Analyzed0.3.11 captures: remaining pool-rim solar paths are mainly ordinary-wall→water reflection, outside the old submerged-only proposal; tilted underwater exits also persist.
- Add a bounded deterministic offline pilot to select the actual water normal for reflected/refracted solar proposals. Preserve full payload and use the fixed context in continuation and both NEE competitors; retain generated-sample forward density and complete BSDF support.
- Added extracted FP32 mapping/edge/Jacobian tests,24 independent planar transport cases and pilot isolation/fallback regressions. Realtime performs no pilot. Full build, relevant old/new tests and independent review pass; all23 packaged shaders and locales verified. GPU variance and runtime cost still need acceptance.
- Automatically installed the verified0.3.12 runtime package to the test instance, preserving0.3.11 as `.jar.disabled`; destination hash verified.

## [0.3.11] - 2026-09-16

- Analyzed the second GPU capture: protected boundary outliers are absent above threshold, while123 false water exits expose stale incident-medium state. Scene changes prevent a controlled noise-reduction estimate.
- Reconcile incident medium with water entry/exit orientation before IOR selection in radiance and both transmission-guide paths; preserve that state on reflection.
- Added an extracted-policy regression using a captured false exit, consistent/stale-state checks and three independently removed-correction controls. Prior-segment recovery and remaining sampling variance stay open.

- Full build and targeted regressions passed; verified0.3.11 installed to the test instance and0.3.10 preserved as a disabled backup. GPU verification remains pending.

## [0.3.10] - 2026-09-16

- Analyzed the first actual GPU path log; verified replay/source agreement and separated selected-guide boundary outliers from unsupported tilted-water/dry-interface paths.
- Fixed FP32 inverse-Snell support rejection dropping a generated sample’s own proposal density: preserve its forward density in continuation throughput/MIS. Arbitrary-direction support checks remain unchanged.
- Added40000 generated-edge regressions with the recorded light frame and old-code negative control, plus reproducible log analysis. Remaining unprotected-path variance is explicitly open.

- Full build and targeted regressions passed; runtime version,23 shaders and locales verified. Automatically installed0.3.10, preserving0.3.9 as a disabled backup; GPU image verification remains pending.

## [0.3.9] - 2026-09-16

- Recorded failed0.3.8 image acceptance; retained its transport for diagnosis.
- Added bounded GPU water-celestial path observation and same-seed replay with guide restoration, graphics-timeline readback and local asynchronous JSONL logs. Session log starts after256 samples, including runs without qualifying events.
- Added shader ABI/isolation contracts, host decoder/lifetime tests, and updated reflected WorldPush ABI to640 bytes. GPU replay consistency and scene convergence remain pending.
- Added automatic runtime JAR deployment to the authorized test instance with metadata-based old-version disabling, reversible backups, hash verification and rollback tests.

- Full build and targeted regressions passed; verified package installed automatically to the test instance, with0.3.8 disabled and preserved. Actual GPU capture remains pending.

## [0.3.8] - 2026-09-15

- Recorded failed0.3.7 game acceptance: user reports source white points roughly unchanged and remaining17/18 points.
- Extended roulette protection to BSDF-selected directions with positive eligible water-guide density, preventing repeated survival amplification on the same solar directions already protected for guide-selected samples.
- Added views20/21 for water celestial contributions with protected/unprotected final legs; expanded UI/locales and tested all484 view transitions plus final-leg flag mutations.
- Added a deterministic two-roulette mean/variance regression and a branch-only negative control. Independent review confirms the state lifetime and partition; visual acceptance remains pending.
- Full native/Java/shader build passed; water, diagnostic, offline, celestial, transmission, bounce-option and realtime-Light checks passed. Version,23 shader hashes and both locales verified in `build/libs/caustica-0.3.8.jar`.

## [0.3.7] - 2026-09-14

- Added offline water celestial continuation guiding: a 50/50 refracted-solar/BSDF mixture with matched throughput and static/celestial MIS probabilities. Actual water/obstacle tracing remains responsible for transport.
- Protected guided dielectric legs from premature roulette; preserved conditional glossy/diffuse ray-cone filtering on guided PBR directions.
- Added a 5% proposal-only angular margin and conservative horizon gate after reproducing FP32 solar-edge PDF/escape disagreement. Solar size/radiance are unchanged.
- Added production-extracted water proposal/transport regressions, actual-refraction edge stress, full-support and roulette checks, and four numerical negative controls. Updated two existing source contracts for the shared continuation evaluator and area-light mixture argument.
- Full native/Java/Slang/SPIR-V build and relevant standalone regressions passed. Package version, 23 shader hashes and both locale resources match final outputs; candidate `build/libs/caustica-0.3.7.jar`.
- GPU pool/city/dark-scene validation and timing remain pending; no claim that all water reflections or complex caustics are resolved.

## Investigation follow-up - 2026-09-14

- Recorded the empty/water-filled pool A/B reproduction and water-transmission/reflection celestial views; 0.3.6 visual acceptance remains open.
- Confirmed that offline direct celestial connections stop at water while water continuation resets celestial MIS to delta. The pool therefore exposes missing explicit refracted-light sampling; overlapping path-history views do not prove two independent defects.
- Documentation only; no shader changes, version bump, new package or deployment.

## [0.3.6] - 2026-09-14

- Fixed LabPBR roughness double conversion and translucent alpha being interpreted as a normal-map flag.
- Added an offline-only reciprocal diffuse energy budget; ordinary dielectric reflection no longer adds full Lambert on top of GGX. Realtime BRDF/guide policy is unchanged.
- Replaced fully blocked offline glass shadows with bounded thin-glass celestial connections matching Fresnel, texture tint and remaining bounce budget; separated celestial MIS state from static lights.
- Unified offline glass texture footprints with LOD0 and a trace-only payload bit without changing ABI; disabled stale water-focus shadow data in offline celestial evaluation.
- Added diagnostic views 13–19 and material/energy/multi-interface regression tests with negative controls; updated previous source contracts for the expanded contribution interface.
- Full native/Java/Slang/SPIR-V build and standalone regressions passed; package metadata, 23 shader hashes and both diagnostic locales verified.
- GPU scene acceptance is pending. Grazing diffuse appearance, distant glass aliasing and the cost of additional connection traces require user testing.

## Unreleased investigation - 2026-09-10

- Recorded failed 0.3.5 user acceptance, including persistent/reappearing bright points above 10000 SPP and reported worsening in view 11.
- Re-audited material-to-BSDF data flow, transparent/specular chains, terminal sampling and accumulation against primary technical sources.
- Documented confirmed roughness double conversion, translucent alpha/normal-flag collision and non-conserving diffuse/specular energy, with numerical counterexamples and an ordered validation plan.
- Documentation only; no rendering code change, version bump, new package or deployment.

## [0.3.5] - 2026-09-10

- Unified offline active celestial radiance, direction PDF and NEE/BSDF MIS; preserved camera-visible decorative discs and unweighted base sky.
- Stopped offline celestial shadow connections at glass/water to avoid overlapping the incompatible tint-shadow and dielectric transport models.
- Handled terminal vertices, delta continuations and particle-backside PDFs; removed shared grazing-view PDF/BRDF flooring.
- Fixed PCG float conversion occasionally returning 1; high-24-bit conversion keeps sampling in `[0,1)`.
- Added production-extracted numerical tests, paired-estimator energy/variance checks and unweighted-MIS mutation control; preserved diagnostic and realtime Light regression coverage.
- Full build and 23 packaged shader hash checks passed. Subsequent user dark-scene testing failed visual acceptance; transparent/specular-path convergence remains unresolved.

## [0.3.4] - 2026-09-09

- Restarted offline convergence work from current source evidence and the reported low-light reproduction, rather than assuming historical docs prove correctness.
- Corrected GGX D/G1 scalar formulas and cosine bounds; added production-extracted numerical regressions.
- Added the restart design, execution plan and unresolved celestial/grazing/long-accumulation findings.
- Added five offline contribution views with per-sample filtering, preserved realtime waiting behavior, view-change history reset, and English/Chinese labels.
- Diagnostic policy, all nine output-bypass mutations and 169 view-reset transitions pass. Full native/Java/Slang/SPIR-V build, existing regressions and package resource checks pass; no game-level noise-elimination claim.

## [0.3.3] - 2026-07-30

- Added glass-only realtime Light specular NEE, while keeping ordinary blocks on their unchanged lighting path.
- Kept first-interface RR specular identity stable through transparent guide walking.
- Applied square-root glass tint, guide tint, and Beer-Lambert attenuation to glass/water transmission guides.
- Switched water refraction to the geometric normal, forced safe reflection on TIR, and made primary/guide water misses attenuate over the `10000.0` trace horizon before miss publication.
- Fixed water depth absorption: auxiliary guide tracing no longer overwrites the primary payload before its entering flag is consumed; cached state and full-payload restore re-enable the Beer-Lambert medium transition.
- Added a shared four-transparent-interface glass/water guide walker. First-interface normal, roughness, and depth remain stable, while transmitted opaque/sky albedo and ordinary motion are used for reconstruction guides.
- Completed automated contract, shader, and full-build verification. Game-level DLSS-RR visual validation remains pending.
- Added a `minecraft:light` source sidecar, including support for sections with empty render geometry.
- Added source revision tracking for add/remove/`LEVEL` changes, pruning, rebasing, and atomic dirty-group publication.
- Fixed dirty-group generation ownership across queued, in-flight, and staged members, including cancellation, deduplicated requeue, stale-result rejection, desired-window pruning, and single-owner geometry retirement.
- Made rebasing independently reachable for completely idle pure-Light windows; base translation and source revision now advance exactly once without changing empty-world Light revision.
- Added the 32-byte realtime point table with graphics-timeline retirement of immutable GPU generations.
- Added realtime shader sampling of one weighted Light source per eligible bounce.
- Made realtime point sampling and offline full static-light sampling mutually exclusive.
- Completed automated source/build verification; game visual and performance validation remains pending.

## [0.3.2] - 2026-07-28

- Stabilized offline accumulation across FP16/FP32 pipeline transitions.

## [0.3.1] - 2026-07-28

- Added the two-second offline idle transition and frame-policy controls.

## [0.3.0] - 2026-07-27

- Added independent realtime and offline path-bounce settings.
