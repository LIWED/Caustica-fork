# Bug Record

## Resolved in code

### Fixed offline filter erased stable fine detail

- 0.3.16 user acceptance failed. Fixed multiscale smoothing lacked temporal uncertainty; same-surface reflection detail is invisible to first-hit guides. A noise-free checker retained only0.371211 contrast.
- 0.3.17 removes unconditional multiscale smoothing, adds separate weighted sample moments and local adaptive reconstruction, and defaults Off under a new key. Stable/unknown pixels pass through. Tests now include fine low-contrast reflections and genuine point highlights; CPU improvement is not GPU acceptance.
- Moment finiteness must be checked before max/clamp and on reset; NaN/Inf/overflow negative cases previously bypassed validity. Corrected without changing the raw mean expression.

### Ordinary-lobe sampling ignored the offline diffuse energy budget

- GPU0.3.14 room records contain repeated high-F0 ordinary surfaces with near-half reflection selection and path weights up to26.174. The old sampler/PDF agree, but unnecessarily large single-step compensation can amplify variance.
- 0.3.15 allocates offline samples from conservative per-lobe weight bounds and shares the probability with the PDF/guided posterior.45RGB cases and old-proposal negative control pass; BRDF and smoothing strength are unchanged.
- This corrects a demonstrated efficiency limitation, not all fireflies. Fixed-material mean tests do not cover lobe-conditioned downstream texture LOD; GPU convergence remains open. See `docs/OFFLINE_LOBE_SAMPLING_2026-09-20.md`.

### Diagnostic capture missed ordinary lighting and later scenes

- Before0.3.13 only water-related celestial paths qualified and256 records exhausted the renderer capture quota. The0.3.12 file ended before the reflective-room screenshot and cannot explain that scene.
- 0.3.13 captures computed direct lighting and secondary emitter/sky/celestial events at threshold32; rearm on accumulation reset and tag generations. Per-run/lifetime/byte caps remain bounded. Stale reads retain GPU ownership but cannot charge the new run; budget and observer/replay tests pass.

### Water-side incidence could use air-side IOR after an origin offset

- 0.3.10 GPU evidence:123 pool-top backface hits carry historical air state. The old air/water ratio reproduces their escape directions; all require TIR with the correct water/air ratio.122 preceding shading-normal offsets cross the local water plane.
- Resolution in0.3.11: derive incident state from the outward-interface entering flag before radiance/guide IOR selection, retaining corrected state on reflection. Captured-case and three-consumer negative controls pass.
- Root geometric-offset correction and recovery of skipped prior interface/absorption remain open; this repair only reconciles the current interface and its continuation.

### Generated water-guide samples could lose their own PDF at the proposal boundary

- GPU evidence: all171 protected high-value records lie at the guide boundary; replay matches original source. FP32 inverse Snell/support testing sometimes returns zero for a direction the guide just generated, leaving only the small BSDF component in the denominator.
- Resolution in0.3.10: preserve generated air-direction density times the forward Snell Jacobian, then form the full mixture. No radiance clamp or new random draw.40000 boundary cases pass and old inverse-evaluation negative control fails.
- This concerns the proposal boundary itself; the earlier wider-proposal fix only guarded the emitter boundary. Actual tilted interfaces can direct the problematic proposal-edge rays into the sun.

### LabPBR linear roughness was squared a second time

- Cause: decodeSpec produced `(1-s)^2`, while GGX/PDF/VNDF expected perceptual roughness and squared again.
- Resolution in 0.3.6: payload retains `1-s`; existing downstream conversion remains. Extracted production tests cover FP16 and the roughness floor; old material tests failed before correction.

### Translucent average alpha was used as a normal-map flag

- Cause: translucent `mat.w` stores alpha, but normal decoding ran before the glass early return.
- Resolution in 0.3.6: exclude translucent material flags from terrain normal-map gating. Boundary tests exercise alpha>.5 without normal textures; source condition mutations are checked.

### Offline diffuse and specular reflection could create excess energy

- Cause: full Lambert was added to positive Fresnel GGX without a shared energy budget.
- Resolution in 0.3.6: normalized reciprocal diffuse complement based on a conservative GGX reflection bound. Seventy-five white-furnace cases pass (maximum 0.999770704), plus scalar and production-binding negative controls.
- Boundary: ordinary offline PBR, valid directions and per-channel albedo/F0<=1. SSS, shading-normal transport and realtime BRDF energy remain outside the guarantee; grazing materials can become darker.

### Glass celestial NEE had no matching transparent connection

- Cause: 0.3.5 blocked even straight-transmitting thin glass, leaving rare celestial escapes to carry its illumination.
- Resolution in 0.3.6: bounded radiance walker multiplies `(1-F)*sqrt(tint)` per glass interface; water/opaque hits stop. Independent celestial MIS state survives straight transmission and resets on reflection/refraction.
- Follow-up fix: NEE and continuation used different ray-cone LODs. Offline glass now uses LOD0 and a fixed overlay footprint, through a trace-only payload flag. Existing realtime filtering and payload layout remain intact.
- Verification: extracted walker, multi-interface mean/variance experiments, depth/blocker/payload restoration tests and four behavioral mutations pass. Full GPU noise and performance validation remains open.

### Offline celestial NEE and glossy escape used incompatible light models

- Cause: NEE used integrated directional strength while secondary misses saw independently sized/tinted decorative discs, without reciprocal MIS. Restoring the GGX peak exposed large direct-light variance.
- Resolution: one offline angular density with `Le = strength * PDF`, complementary direct/escape weights, and primary-only decorative discs. Water/glass block celestial NEE while actual dielectric continuations carry those paths.
- Verification: CPU numerical integration/paired sampling and compiled weight=1 mutation, source-routing probes, existing regressions and full build passed. This does not prove scene-level noise elimination; refractive caustics remain difficult to sample.

### RNG conversion could return the excluded endpoint 1

- Cause: converting a full 32-bit uint to float rounded its highest values to 2^32 before scaling, so probability/Fresnel tests could violate their `[0,1)` assumption.
- Resolution: convert high 24 bits and multiply by 2^-24. Two extracted-expression boundary assertions failed before the fix and pass afterward; PCG stepping is unchanged.

### Grazing-view BRDF/PDF used a different view cosine from VNDF sampling

- Cause: evaluation floored NdotV at 1e-4 while sampling used the actual view direction.
- Resolution: evaluate with the actual positive cosine and reject nonpositive views. Source review/build passed; GPU extreme-grazing material validation remains pending.

### GGX density did not match the sampled normal distribution

- Cause: `ggxD` added `1e-7` to its denominator while VNDF sampling retained standard GGX. At roughness 0.045, the old peak was about 41 instead of 77625; numerical projected mass was about 0.036 instead of 1.
- Resolution: use a cancellation-resistant equivalent denominator without epsilon; remove the G1 epsilon and clamp cosine inputs. Existing positive roughness keeps denominators finite.
- Verification: extracted production scalar tests failed 12 checks before the fix and pass after it; full 0.3.4 build and existing regressions passed. Dark-scene visual acceptance remains open.

### Water depth absorption lost its primary medium state

- Cause: auxiliary guide tracing reused and overwrote the primary water payload before its entering flag was consumed, so the path did not enter the water medium.
- Resolution: cache the entering flag, restore the complete primary payload after guide tracing, and use the cached state for the Beer-Lambert depth-absorption transition.
- Verification boundary: automated transmission-guide contracts, shader compilation, and the full build passed; game-level DLSS-RR validation remains pending.

### Glass and water reconstruction guides stopped at the wrong identity

- Cause: one-interface guide tracing could retain a transparent surface rather than reaching the transmitted opaque/sky target, while shared guide identity did not distinguish the first interface from transmitted content.
- Resolution: use a bounded four-transparent-interface walker; retain first-interface normal, roughness, and depth, and publish transmitted opaque/sky albedo with ordinary motion while preserving reflection-specific motion.
- Verification boundary: automated contracts and shader/build verification passed; visual DLSS-RR quality still requires the approved in-game matrix.

### Glass reflection was missing from the realtime Light path

- Cause: realtime Light sampling did not provide a glass-only specular NEE contribution, so reflected Light energy could be absent from glass.
- Resolution: add the targeted glass specular NEE path while leaving ordinary block lighting unchanged.
- Verification boundary: source contracts, shader compilation, and the full package build passed; in-game reflection validation remains pending.

### Stained-glass and water temporal guides produced ink artifacts

- Cause: guide data mixed first-interface identity with transmitted content and could apply invalid transmission/refraction state after misses.
- Resolution: retain first-interface RR identity, publish transmitted tint/Beer attenuation, use square-root glass tint, and guard water TIR/miss paths.
- Verification boundary: automated transmission-guide contracts, shader compilation, and full packaging passed; the visual matrix remains pending.

### Water refraction could emit a zero direction

- Cause: a degenerate refracted vector could reach the ray path instead of taking the reflection fallback.
- Resolution: reject zero-length refraction directions and use the safe reflection branch.
- Verification boundary: transmission-guide contract and shader compilation passed.

### Beer attenuation treated a `-1` miss sentinel as a valid depth

- Cause: guide attenuation consumed the `-1` miss sentinel as path length, while the primary radiance path skipped current-water absorption entirely when a submerged ray missed.
- Resolution: after each primary or guide trace, use `payload.hitT` for finite hits and the `10000.0` trace horizon for misses, then apply guarded Beer-Lambert attenuation once before the hit/miss split.
- Verification boundary: transmission-guide contract and shader compilation passed.

### Realtime `minecraft:light` blocks lacked explicit illumination

- Cause: the existing static-light table and sampling path were enabled only for true offline accumulation.
- Resolution: capture Light levels 1 through 15 into a dedicated realtime point-source table and sample one weighted source at every eligible realtime bounce.
- Verification boundary: automated verification is complete; game-level validation remains pending.

### Pure-Light sources were not rebased correctly

- Cause: zero-geometry Light completion populated neither geometry publication list, while `stream()` returned at its idle gate before computing rebase; the correct internal rebase branch was unreachable.
- Resolution: compute rebase before idle, treat rebase as independent terrain work, enter `applyBuildChanges` for rebase-only passes, and apply the tested exact-once base/revision transition.
- Verification boundary: automated verification is complete; game-level validation remains pending.

### Dirty-group generations could publish after cancellation or desired-window removal

- Cause: ownership existed only in queue/in-flight maps and was removed before staging; cancellation did not stale every unfinished token, so late grouped results could fall through to standalone publication and old geometry could gain two retirement owners.
- Resolution: retain authoritative section-to-generation ownership through terminal publication/cancellation, revalidate generation and desired membership at completion, stale all cancelled tokens, deduplicate desired requeue, and transfer resident-to-empty retirement once.
- Verification boundary: automated verification is complete; game-level validation remains pending.

### Refracted solar guiding could create new FP32 edge fireflies during development

- Cause: mapping a sampled solar direction into water and reconstructing it for the proposal PDF differs by ulps from the actual `refract()` escape direction. At square edges the PDF could fall to zero while traced solar radiance remained positive, leaving only the small BSDF density in the mixture.
- Resolution in 0.3.7: sample/evaluate a consistently 5% wider proposal around the unchanged source; disable this proposal close to the horizon. Guided ray-cone filtering also retains the original BSDF lobe posterior.
- Verification: deliberate emitter-edge stress with actual FP32 refraction passes; removing the angular margin fails the numerical regression. No GPU confirmation yet.

## Open

- 0.3.17 adaptive reconstruction remains experimental: correlated samples, heavy tails and last-sample transparent/reflection guides can still misclassify detail. Raw fireflies/convergence remain unresolved; user0.3.16 feedback invalidates its prior visual-smoothing success assumption.

- 0.3.15 failed user perceptual acceptance: speed and noise look similar to0.3.14.0.3.16 adds explicitly accepted display denoising while keeping raw history; it does not resolve the underlying transport variance or establish game-quality acceptance. Tiny genuine highlights can be removed, fine detail softened, and last-sample/transparent guides can leave edge noise. See `docs/OFFLINE_DENOISE_2026-09-21.md`.

- 0.3.14 user test at30000SPP: Mild improves on Off and Strong is smoothest, but obvious residual points/grain and slow convergence remain.0.3.15 addresses ordinary-lobe allocation separately; no general visual acceptance or GPU speedup has been established.

- 0.3.14 adds an optional ordinary indirect-path regularization experiment, not a proven general noise repair. Default Off retains the reference. CPU planar tests reduce observed variance but alter reference brightness (up to about13.1% in the tested grazing strong case); rare baseline tails remain underconverged. Primary-surface noise, water/glass interface variance and geometry/origin risks remain open. Preserve matched effective BSDF/PDF and game A/B acceptance; see `docs/OFFLINE_REGULARIZATION_EXPERIMENT_2026-09-20.md`.

- ITRP comparison does not establish another sampler defect or an accumulation fix: its cache-based secondary lighting, screen reuse and clipped reflection distribution solve a different approximate transport problem. Stable offline image denoisers are bypassed. General-scene fireflies remain unresolved; separate geometry/origin correctness from optional biased variance reduction. Evidence and boundaries: `docs/OFFLINE_ITRP_COMPARISON_2026-09-20.md`.

- Overall0.3.12 acceptance failed in low-sun pools, reflective interiors and reported no-water/no-glass scenes.255/256 latest captures are below the water-guide horizon gate; blindly removing this guard would not address general lighting. Vector-BSDF audit did not establish a sampler/PDF defect.0.3.13 broadens diagnostics without a noise-reduction claim; geometry/texture/GPU-history defects and difficult indirect-path variance remain separate hypotheses. See `docs/OFFLINE_GENERAL_REASSESSMENT_2026-09-20.md`.

- 0.3.11 pool-rim residual: capture155159-172 has185 ordinary-wall→water-reflection→sun records, all without roulette amplification, and64 entry→ordinary→exit→sun records. The old submerged horizontal guide misses reflection and tiny tilted exits.0.3.12 uses a deterministic interface pilot plus matched actual-normal reflection/refraction proposal densities.24 planar cases and payload/context regressions pass; scene acceptance and trace cost remain open. A single pilot does not solve spatially varying or multiple interfaces, nor skipped-interface origin-offset defects.

- 0.3.9 GPU log:85 unprotected high-value records remain, including tilted water exits and dry-surface water reflections/transmissions. Normals tilt up to7.54 degrees with shader waves off; the horizontal submerged proposal does not cover these connections. Exit roulette produces a measured40415.76 sample.0.3.10 does not fix this coverage/variance problem; full-scene acceptance remains open. See `docs/OFFLINE_PATH_FINDINGS_2026-09-16.md`.

- 0.3.8 acceptance failed: views20/21 both retain bright points;21 reaches18714SPP. Earlier roulette correction is insufficient, and screenshots do not locate the first problematic event. 0.3.9 records actual water-celestial paths without changing transport. Logs are bounded and thresholded, so missing path classes do not prove their correctness. GPU evidence was collected on2026-09-16 and is analyzed in `docs/OFFLINE_PATH_FINDINGS_2026-09-16.md`.

- 0.3.7 visual acceptance failed (2026-09-15): user reports source fireflies roughly unchanged and supplies17/18 screenshots, second at5078SPP. Confirmed variance hole: only guide-selected directions skipped roulette, although BSDF-selected directions inside the guide have the same tiny mixture throughput. Two .02-survival steps amplify a surviving example by2500. 0.3.8 protects either selected-guide or positive-guide-density directions; extracted regression preserves the mean and rejects the old branch-only policy. Views20/21 split protected/unprotected final water-celestial legs. Screenshot causality remains unconfirmed; earlier-segment variance and uncovered mirror chains can remain.
- 0.3.6 water-pool reproduction (2026-09-14): empty pool reportedly clean; adding water produces bright points mainly in sunlit areas, including view 17 at 2083 SPP and view 18 at 4141 SPP. `celestialVisibility` rejects water, and water continuation sets `previousCelestialDelta=true`, so refracted solar illumination of the bottom relies on rare continuation hits. This confirmed sampling-coverage limitation is consistent with the reproduction; exact GPU paths and any additional weight/normal defects remain unmeasured. Next: validate an explicit refracted celestial connection for a planar water interface against independent means/PDFs, with matching continuation MIS. Do not simply pass straight shadow rays through water or suppress delta escape. Details: `docs/OFFLINE_DIAGNOSTICS.md`.
- 0.3.7 implements that direction as continuation guiding rather than separate connection NEE: 50% original BSDF support remains, all relevant PDFs use the mixture, and tracing performs the real interface/occlusion checks. Six analytic pool tests pass without altering the existing eta-throughput or wave model. Game convergence, arbitrary water-reflection chains and runtime cost remain open.
- 0.3.5 visual acceptance failed: user screenshots `035_10/11/12.png` show remaining fireflies, with reported worsening in 11 and new spikes above 10000 SPP. Single-surface MIS tests did not validate full-path convergence. Evidence: `docs/superpowers/specs/2026-09-10-firefly-path-reassessment.md`.
- 0.3.6 corrects the material input defects and offline ordinary-BRDF energy in code; their contribution to the user's scene remains unmeasured. Realtime retains the prior BRDF until its guide/appearance policy is evaluated together.
- Celestial variance remains open after thin-glass NEE: water refraction/mirror chains still lack a straight connection, while terminal NEE has no continuation competitor. No default sample clamp or path regularization has been added.
- Static area-light terminal NEE still applies MIS without a matching continuation, causing downward bias. Separate from the bright-tail symptom; not yet fixed.
- Shading-normal overwrite loses the original geometric normal for hemisphere/bias decisions, creating a possible self-intersection/backside-lighting risk. Scene causality not established.
- Persistent low-light bright noise: 18 user screenshots (1500/3000/6000 SPP, 8 bounces, +0.4 EV) confirm residual bright points, especially views 10 and 12. Some grain decreases, but view 10 improves little from 3000 to 6000. GGX correction alone did not achieve visual acceptance.
- Official commit 5d6bf62 math.slang explicitly documents that its GGX epsilon suppresses an unweighted celestial NEE/glossy double-count and variance problem. The scalar correction must be paired with a coherent celestial estimator; switching to wavefront alone does not fix this.
- The 0.3.5 single-connection estimator correction is implemented but did not resolve the symptom; realtime retains its old artistic celestial model. Continue evaluating combined output and path histories, not only source views 10/11/12.
- Offline GPU history weight is capped at 16,777,208 while the HUD/sample sequence continues. Beyond this limit accumulation approximates a fixed-weight running average, not an all-samples average; no evidence links it to ordinary low-SPP noise.

- Ordinary emissive blocks still lack dedicated realtime explicit NEE.
- In-game glass/water visual validation remains pending, including clear/stained and stacked glass, shallow/deep water, motion, waves, and Frame Generation combinations.
- Full offline static-light-table rebuilds can stall while waiting for GPU idle.
- Offline convergence and performance require game-level validation.
- Realtime/offline resource transitions may cause a brief one-time stall.
- High bounce counts and higher-than-2x frame generation remain performance/stability concerns.
