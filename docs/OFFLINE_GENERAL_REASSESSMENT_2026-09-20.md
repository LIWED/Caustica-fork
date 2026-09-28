# General firefly reassessment — 2026-09-20

## Failed acceptance and capture limits

- User reports0.3.12 pool improvement at noon/night, recurrence with low-angle sun (source/17/18/21), and widespread dots in ordinary scenes without water/glass/direct sunlight. Roof-opening reflective room screenshot `2026-09-16_23.04.13.png` shows dense noise at3761SPP. Overall convergence acceptance remains failed; narrow pool success is insufficient.
- Earlier incident-IOR and generated-PDF defects were established by recorded paths. Their repairs remain valid, but do not establish a general convergence solution.
- Latest input `caustica-paths-20260916-220324-202.jsonl`, SHA256 `3e4b0ccc86f938ab007cd3bea36b3cf0205281d0d0a3fc376d47fb24f110c847`: version0.3.12,256 records, samples257–32696,24 bounces, flags34. Replay/source error<=2.62e-7. All records unprotected; median peak5509.73, max28356.90.
- 255/256 records fall below the proposal's eligibility limit `lightDir.y > 0.1 + 2*tan(guideHalfAngle)`; minimum cosine0.06810 (about3.9° elevation). The guide is deliberately disabled there. This explains loss of the optimization for these captured low-sun water paths, not every scene or every oblique solar angle.
- 205 records are ordinary→water reflection→sun. Two camera positions and changing sunlight prevent unbiased frequency or matched version comparisons.
- Old capture admitted only category14 with water history and exhausted its256-record lifetime quota. File modification ended22:22, before the23:04 room screenshot. It cannot diagnose the room or rule out ordinary-material defects.

## General sampler audit

- `scripts/test_bsdf_vector_sampling.py` extracts actual production FP32 VNDF vector sampling, BSDF density, BRDF, energy budget and conditional lobe probability. Independent double NDF integrals check directional moments and reflectance.
- 324 material cases and108 distribution cases pass: roughness.045–1, incoming cosine1e-4–1, three normals and three materials; about51.84 million samples. Maximum one-step weight9.66346 is within the analytic mixture bound; maximum furnace mean1.00101 is within statistical tolerance.
- Wrong-PDF and wrong-sampler-roughness negative controls fail. No specific GGX sampling/PDF bug was demonstrated. This does not validate GPU execution, texture filtering, geometry/origin offsets, multi-bounce variance or image accumulation.
- The reviewed FP32 accumulation expression is a sample-weighted mean without an obvious low-SPP count error. Existing accumulation/ABI tests pass; this is not proof of GPU synchronization or image correctness.

## 0.3.13 diagnostic correction

- Observe direct surface lighting (8/10 at all depths), secondary emitter hits9, atmosphere13 and celestial14 independently of water/glass history. Exclude primary visible emitters/sky to avoid spending the bounded capture on ordinarily bright source pixels.
- Single-contribution threshold256→32; capture still activates at256SPP. Select the largest eligible contribution per path before debug filtering. This is a bounded tail capture, not an unbiased histogram.
- Restore256-record quota when accumulation restarts; retain2048 records per renderer lifetime and16MB file cap. Records carry `captureGeneration`; late GPU results cannot charge a new generation, and timeline-based buffer ownership is unchanged.
- Transport, scene appearance, RNG and accumulation are unchanged. This is an evidence-gathering release, not a noise fix. Finite subthreshold noise, primary-source aliasing and final-display artifacts may require other instrumentation.
- Build, diagnostic/quota/offline regressions and independent source review pass. Next GPU capture: start with the actual reflective room in source view after restart, then the no-water/no-glass artificial-light scene if needed. Existing local logs collect evidence automatically.

## Research and decisions

- [PBRT: Path Regularization](https://pbr-book.org/4ed/Light_Transport_I_Surface_Reflection/A_Better_Path_Tracer#PathRegularization) documents high variance when indirect samples reach a small bright source through a smooth reflector. This is plausible here, not a diagnosis established by a screenshot.
- [PBRT: Microfacet Theory](https://www.pbr-book.org/4ed/Reflection_Models/Roughness_Using_Microfacet_Theory) provides visible-normal sampling/PDF reference formulas. Numerical checks did not justify replacing the current formulas.
- First separate implementation defects from difficult but correctly weighted paths. Then choose a concrete correction, broader indirect sampling, or optional regularization with an acknowledged change to indirect appearance. Do not silently clamp samples or globally dull materials.
- Retain the pool as one regression case; add low-sun pool, reflective room, opaque artificial-light room and original dark game scene. Compare equal-SPP appearance, equal-time quality and overall brightness; one scene cannot establish acceptance.
