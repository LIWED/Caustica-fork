# Water celestial continuation guiding — implementation plan

**Goal:** Reduce the reproduced sunlit-pool bright tail without discarding solar energy.

**Architecture:** Add an offline-only 50/50 mixture of the existing surface BSDF sampler and a solar-direction proposal refracted through a horizontal air/water interface. This is direction guiding, not a new NEE contribution or a general MNEE solver. Existing traversal still handles actual interfaces, occlusion, Fresnel choices, absorption and bounce limits. A poor proposal on non-horizontal water affects efficiency rather than replacing geometry.

**Tech stack:** Slang ray generation, production-extracted CPU regression, existing Gradle/SPIR-V build.

## Design and constraints

- Follow the user-approved water-path direction; preserve the current uncommitted workspace and keep realtime sampling unchanged.
- An air direction a with a.y>0 maps to w=(a.x/eta, sqrt(1-(a.x²+a.z²)/eta²), a.z/eta), eta=1.333. For unit directions the density is qWater=qAir*eta²*w.y/a.y. Below-horizon solar samples become null events, not resampled/renormalized silently.
- Eligibility: underwater ordinary receivers and positive celestial radiance/half-angle; axis elevation must exceed `0.1+2*tan(guideHalfAngle)`. The guide half-angle is 1.05 times the clamped source half-angle, placing the unchanged source inside the proposal despite FP32 roundtrip errors. Mixture density is (1-m)*pBSDF+m*qWater in the receiver's valid hemisphere. Retain 50% BSDF support for every old path.
- Use that same mixture density for continuation throughput, saved emitter/sky MIS state, and static/celestial direct-light competitors. Delta water escape still has weight one: the guide is already accounted for in continuation sampling.
- No extra radiance contribution or shadow transparency change. Guided contributions retain diagnostic14/17/18 classification; unlike a separate NEE implementation, they do not move into10.
- A selected guided leg avoids Russian roulette until the next ordinary scattering decision, including intermediate water/glass interfaces. Otherwise its tiny throughput before reaching the bright sun would trigger 98% termination and undo much of the variance reduction. Bounce limits still apply; unsupported/blocked rays still trace normally.
- Guided PBR directions choose the ray-cone lobe using `p(specular|direction)` from the original BSDF sampler, so downstream texture filtering does not default to diffuse solely because this proposal was selected.
- Do not change the existing eta-throughput convention or wave-normal model in this patch. These remain separate transport-model limitations; comparisons target the existing model's mean.
- Alternatives considered: general MNEE needs geometric solvers and connection MIS; straight-through water shadows change transport; sample clamping biases energy. Direction guiding is the smallest compatible first step.

## Execution

- [x] Add a failing production-extracted mapping/PDF and finite-pool estimator test. Check Snell roundtrip, numerical solid-angle Jacobian, normalization, null horizon samples, Fresnel/absorption/blockers, mixture mean and variance, and integration/negative controls.
- [x] Implement `water_celestial.slang` and integrate the mixture and bounded roulette policy in `world.rgen.slang`.
- [x] Run targeted and existing material/energy/celestial/transmission/offline/static-light regressions. Review every source-contract change against the new behavior.
- [x] Update PROJECT/CHANGELOG/BUGS/diagnostics; bump to0.3.7; build and verify package metadata and shader hashes.
- [ ] User GPU acceptance: same pool/source/17/18 at equal SPP and exposure, then original city/dark scene. Check mean illumination and time, not just point count.

## Validation boundary

CPU transport experiments are simplified analytic scenes, not Vulkan/game evidence. The patch targets refracted solar lighting at submerged receivers; primary water reflections, dry-surface mirror chains, normal-map/wave aliasing and arbitrary refractive caustics may remain noisy.

## 0.3.8 follow-up — 2026-09-15

- User reports source fireflies roughly unchanged; supplied17/18 still show points, second HUD5078SPP. First sample count unspecified. 0.3.7 game acceptance failed.
- Confirmed variance hole: BSDF-selected directions inside the refracted-solar proposal use the same tiny mixture throughput as guide-selected samples, but only the latter skip roulette. Two min-probability survival steps can multiply an otherwise modest sample by2500 without changing its mean.
- Extend protection to either a selected guide or any eligible direction with positive guide density. Reset at each ordinary scattering and retain the existing bounce cap and compensation for other paths.
- Add views20/21 as a disjoint partition of water-related celestial contributions according to whether the final leg was protected. These are not proof of a last-event type; reflection can occur on a protected leg. Keep all path sampling independent of the view.
- Test first: reject branch-only protection numerically and in source flow; reject old diagnostic policy. Then verify compensation/variance, all484 view transitions and final-leg flag wiring, rebuild0.3.8, and retain game acceptance as pending.
- Completed: old code rejected by both new tests; protection/mean regression and five numerical negative controls pass, as do484 diagnostic resets and final-bit mutations. Independent review found no blocker; no claim that the screenshots all share this mechanism.
- Build0.3.8 passed in1m22s. Package20540166 bytes, SHA256 `4bf183573146c02915b989816f3a40fb5ca54d2991de5180c8047be0c59b13fa`;23 shader hashes and22 view labels in both locales verified. Evidence: `build/water-celestial/water-0.3.8.log`, `build-0.3.8.log`, `package-0.3.8-verification.json`. Game acceptance remains pending.

- Independent review found an FP32 edge-support blocker in the first implementation. Expanded proposal plus conservative horizon eligibility fixed it; deleting the expansion now fails the actual-refraction boundary test. The review also prompted the conditional ray-cone lobe correction.
- Six analytic pool means differ from independent quadrature by at most 0.24%; these tests use the current renderer's transport convention. Tests also execute the production Lambert/PBR continuation PDF, old-lobe posterior, constant-environment support and compensated branch-dependent roulette. Four numerical mutants (Jacobian, mixture, angular margin, lobe posterior) are rejected.
- Final build passed in1m59s; independent review reports no remaining blocker after the edge and ray-cone corrections. Existing celestial numerical/integration, transmission-guide, offline rendering/diagnostics, material-boundary, GGX, energy and realtime-Light regressions pass. Pure PowerShell scripts are run as child processes to avoid treating an unset/stale native exit variable as their result.
- Evidence: `build/water-celestial/water-final.log`, `energy-final.log`, `build-0.3.7-final.log`, `package-verification.json`. Jar size20533710 bytes; SHA256 `2c8fc0e32178daf4a131d12d48605730a81f3016eab48779f68e2ef1010d1c9a`; version0.3.7, all23 generated/package shader hashes and both locales match. Build/game deployment not performed by the agent beyond producing the local jar.
