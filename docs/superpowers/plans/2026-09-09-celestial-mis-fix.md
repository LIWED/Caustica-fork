# Celestial estimator correction — implementation and evidence

## Approved scope

User requested fixing the current celestial path after 0.3.4 dark-scene screenshots failed visual acceptance.
Work in Caustica-fork; preserve existing edits and sibling projects. No deployment or Git publication.
Use systematic diagnosis, test-first numerical checks and independent review. Target version 0.3.5.

## Design

- Correct the offline FP32 path first; realtime's artistic display remains as before.
- Existing active sun/moon direction, angular half-size and RGB integrated strength remain authoritative.
- Uniform tangent-plane square sampling has solid-angle PDF `q=(1+u*u+v*v)^(3/2)/(4*t*t)` on `[-t,t]^2`, `t=tan(halfAngle)`.
- Define incident radiance `Le(direction)=strength*q(direction)`. This modest directional variation preserves the old NEE `Le/q=strength`, rather than reusing unrelated decorative-disc radiance.
- Shared shader module owns tangent frame, sample direction, direction PDF and stable power heuristic.
- Ordinary surface and particle NEE use complementary light/BSDF MIS; full diffuse+GGX mixture PDF matches continuation.
- On an offline secondary miss, existing miss shader returns base atmosphere/stars only. Raygen adds active analytic celestial Le with BSDF-side MIS; base sky is never weighted by this MIS.
- Primary camera still displays the original decorative sun/moon. Secondary reflected/refracted discs use the active lighting model, so their apparent size/brightness can change.
- Ideal dielectric continuations keep weight 1. Zero radius is a delta direct light: NEE weight 1, no finite-density secondary disc.
- Positive half-angle is bounded consistently in sample/evaluate/PDF to `[1e-4,1.4]` radians. No luminance clamp.
- At the last permitted vertex, no competing continuation exists, so NEE weight is 1.
- Offline celestial NEE accepts water/glass shadow hits as occlusion, using a separate alpha sentinel; actual dielectric continuations carry these paths. This avoids combining incompatible straight-through tint shadows with refracted/reflected transport. Realtime/static-light shadows retain their existing tint behavior.
- Thin SSS remains an approximation. The old direct water-focus multiplier has no crossed-water connection in this offline visibility policy; actual refractive caustics can have high variance. This is not a fully physical dielectric/caustic integrator.
- Diagnostics 10/11 continue to distinguish direct celestial evaluation from escaped-sky/analytic-celestial hits; 12 overlaps deeper paths.

## Tasks

- [x] Establish production-extracted scalar PDF/MIS regression; observe RED before helper exists.
- [x] Validate PDF normalization, support, delta/angle bounds, complementary MIS and narrow-lobe energy/variance against independent integration.
- [x] Implement shared module and offline raygen integration; preserve default diagnostics and realtime celestial policy.
- [x] Validate reciprocal miss weighting, primary-only artistic disc gating, delta and terminal handling with negative source probes.
- [x] Independent mathematical/code review; resolve important findings.
- [x] Run all affected standalone regressions plus full Java/native/Slang/SPIR-V build and package hash checks.
- [x] Update PROJECT/CHANGELOG/BUGS and diagnostic instructions; document actual limits and game test matrix.

## Game acceptance

Use the supplied dark scene, 8 bounces, manual +0.4 EV, 1500/3000/6000 SPP.
Compare source, 10, 11, 12 together: MIS transfers energy between 10 and 11, so a cleaner 10 alone is not success.
Require stable average lighting, reduced persistent bright tails in combined output, and no reflection/transparent regression.
No game deployment has been performed by this task. Subsequent user testing failed acceptance; see the follow-up below.

## References

- [PBRT environment MIS](https://pbr-book.org/4ed/Light_Transport_I_Surface_Reflection/A_Better_Path_Tracer)
- [Upstream documented celestial/GGX issue](https://raw.githubusercontent.com/ComfyFluffy/Caustica/5d6bf6222807bc9d09065190ed036c836134af90/shaders/world/math.slang)

## Evidence ledger

- Start: 0.3.4, prior GGX scalar/diagnostic regressions and package verified, screenshot acceptance failed.
- RED: scalar extraction failed on missing module; integration failed on missing import before any production edits.
- First numerical GREEN: normal-incidence GGX toy reference 2.740553, light-only mean 2.750838, paired MIS mean 2.739998; variances 105.537210 vs 0.925375. CPU estimator test, not GPU or user-scene measurement.
- First integration GREEN: primary/secondary gate, sky data-flow, particle/last-bounce weights and opaque dielectric shadow policy; five negative probes rejected.
- Removed the old 1e-4 NdotV floor in shared BRDF/PDF evaluation to match actual VNDF view; this minor grazing-view correction also affects realtime surfaces.
- RNG endpoint regression reproduced two failures for high uint values before switching to high24/2^24; extracted-expression tests pass after the change. This changes sample values slightly in both realtime/offline, not RNG advance count.
- Extended experiments at roughness 0.045 and sun half-angle 0.6 degrees: aligned reference 2031.915120 vs paired 2031.477199; offset-axis reference 1631.672104 vs paired 1629.187068. An actual compiled weight=1 mutation fails the energy oracle with approximately doubled estimates.
- Source integration probes are token/placement guards, not runtime GPU tests. CPU sampling experiments use independent reference direction sampling and actual extracted scalar functions, not the full shader integrator.
- Realtime Light test initially failed because it ended tracePath at the first `#ifdef`; function-internal offline branches required using the next raygeneration entry as the boundary. Original output-placement and discarded-return checks remain and pass.
- Final independent review found no must-fix issue; RNG/test-harness incremental review also passed. Transparent-caustic variance and changed reflected-disc appearance remain explicit visual risks.
- Final full build completed in 45s. Log: `build/celestial-mis-20260909/build-0.3.5.log`; numerical evidence: `numerical-tests.log` in the same directory.
- Final package: `build/libs/caustica-0.3.5.jar`, 20,506,776 bytes, SHA-256 `59D0A3861769A73F01245B84F4D6BC9C8FB678BC610B4FA4D0F34742FE6CECA3`. Embedded version and all 23 generated SPIR-V hashes match; `package-verification.json` records the check.
- Completed code/package verification on 2026-09-10. No deployment or game visual acceptance performed; next step is the same dark-scene combined-output matrix above.

## Failed game acceptance — follow-up

- [x] Record user `035_10/11/12.png` evidence and persistent/reappearing bright points above 10000 SPP; 0.3.5 is not a successful convergence fix.
- [x] Re-audit beyond celestial MIS using primary references and independent source review. Confirm roughness double conversion, translucent alpha/normal-flag collision and BRDF energy issue.
- [x] Document the limits of the single-surface numerical oracle and the glass/water shadow policy in `../specs/2026-09-10-firefly-path-reassessment.md`.
- [ ] Add material-boundary and white-furnace regressions, then isolate each confirmed correction.
- [ ] Add source/path/terminal contribution diagnostics and linear bright-tail evidence.
- [ ] Design consistent thin-glass transmission NEE; evaluate harder indirect paths with multi-bounce regressions.
- [ ] Re-run controlled combined-output game acceptance with SPP and equal-time comparisons.
