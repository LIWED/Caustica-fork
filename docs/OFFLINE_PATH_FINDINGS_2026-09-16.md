# GPU path evidence: proposal-edge weights and unsupported water paths

## Capture and validity

- Input: test instance `logs/caustica-paths-20260916-145550-251.jsonl`, version0.3.9, SHA256 `68f9877e8fdef4faef8eb06c04e07754ef747075e313daaef022e443e3d6d3af`.
- All256 bounded records decoded. Original source RGB agrees with replay within maximum relative error `2.40e-7`. This validates these captured source contributions, not full-frame pixel equivalence.
- One camera, source view0, samples257–3045. Actual maxBounces24 and flags34: PBR/static NEE enabled, procedural water waves disabled. Earlier8-bounce reproduction settings do not describe this capture.
- Capture is thresholded (>=256 single-sample linear magnitude) and capped. Counts below are not proportions of all image noise or all paths.
- Reproducible summary: `scripts/analyze_offline_paths.py LOG --output build/path-probe/analysis-0.3.9.json`.

## Confirmed defect: selected proposal loses its own density

- 171 records have a protected final leg; all171 have a submerged ordinary-scattering direction within2e-4 relative distance of the proposal-square boundary. Median peak695.95, maximum2329.49.
- The sampler first generates an air direction and refracts it into water. The continuation evaluator then reconstructs the air direction in FP32 and tests the square support again. Rounding can put this known generated sample just outside, returning guidePDF0.
- The selected-guide flag still protects roulette, but the mixture denominator then contains only the small BSDF term. The generated solar sample receives an excessive weight even without roulette amplification.
- Example pixel341,160/sample435: ordinary-scattering blue throughput becomes0.0589786, then0.0576441 after water absorption, with no roulette rescaling. Solar escape contributes2329.49.
- New regression uses the recorded light frame and deliberately samples the four proposal edges. Old production evaluation rejects20747/40000 generated samples; this is an edge stress-test rate, not a whole-frame failure rate.
- Prior tests stressed the emitter boundary inside the wider proposal. They missed the proposal's own boundary; tilted exits can redirect those boundary samples into the actual emitter. The5% margin therefore did not prevent this observed failure.

## Separate remaining issue: horizontal proposal misses actual connections

- 85 unprotected records: median peak30514.63, maximum40415.76.54 start by entering water;21 are dry-surface→water-reflection→sky paths, and10 are dry-surface→water-transmission→sky paths.
- The captured water normals tilt up to7.54 degrees from vertical despite procedural waves being off. Fluid mesh generation computes normals from corner heights, so disabling shader waves does not guarantee a horizontal optical interface.
- For submerged unprotected paths, the outgoing direction lies outside the flat-water solar proposal but actual tilted-interface refraction reaches the sun. Dry reflective/refractive chains are also outside submerged-receiver guiding.
- Example pixel490,75/sample1419: blue throughput before exit0.0464789, roulette probability0.0464789, surviving throughput1.0. Solar source becomes40415.76. This one sample alone contributes about4.04 linear units to a10000-sample mean, explaining why a late rare event can remain visible.
- Roulette compensation preserves expectation, but adds large variance here. This evidence does not justify deleting valid refracted/reflected light or imposing an arbitrary brightness clamp.
- Mesh quads also currently share their first-triangle normal between both triangles; whether that changes a particular recorded hit needs geometry/triangle evidence. Do not conflate it with the confirmed PDF defect.

## 0.3.10 bounded correction and next work

- For a selected proposal sample, retain its density from the generated air direction: `qAir=1/(4*t*t*cos^3)`, then multiply by the forward Snell solid-angle Jacobian. Mix this with the BSDF density for throughput and subsequent MIS state.
- Arbitrary BSDF/NEE directions retain the original support-tested evaluator. No new RNG, clamp, source brightness, water geometry or roulette policy changes.
- Edge regression passes all40000 cases; maximum relative error against the independent density expression is1.80e-7. Restoring old inverse evaluation makes it fail again.
- This repairs the newly confirmed numerical weighting defect. It does not solve the85 captured unsupported paths or establish full-scene convergence. Next transport design must use actual interface geometry and cover reflection/transmission chains, with matching densities and independent mean tests.
- GPU verification should compare protected-view20/log group1 against this capture; source dots from unprotected paths can remain. Keep camera,24 bounces, material pack and wave setting fixed for that comparison.

## Primary references

- [PBRT: Sampling Reflection Functions](https://www.pbr-book.org/3ed-2018/Light_Transport_I_Surface_Reflection/Sampling_Reflection_Functions) distinguishes the density returned for a generated sample from evaluation for an arbitrary direction. This informed retaining the generated proposal density; the concrete bug above is established by local GPU data and the extracted regression.
- [Hanika et al., Manifold Next Event Estimation](https://onlinelibrary.wiley.com/doi/full/10.1111/cgf.12681) addresses connecting surfaces to lights across refractive interfaces. It is a reference for remaining geometry-aware connection work, not a claim that this renderer now implements MNEE.

- Verification: full native/Java/Slang/SPIR-V build passed (55s), focused edge and existing water/diagnostic/celestial/probe contracts passed, independent review found no blocking issue. Verified all23 packaged shaders/locales; installed0.3.10 with destination hash80ad899e8a1929efe4e06dc900443627baca2e65c9aed2c2eb05039060c2ffeb and retained0.3.9 as `.jar.disabled`. GPU acceptance of this correction is pending.

## Second capture: 0.3.10 after levelling the pool

- Input: `caustica-paths-20260916-151728-879.jsonl`, SHA256 `43b282798281039c86aea05933b4604a1df4db9d018de763f2ec2d1f64180d87`. User reports somewhat fewer dots and a levelled surface.
- 256 records, samples322–10266, source view0,24 bounces, flags34. Replay/source maximum relative error2.37e-7. All256 are unprotected; no protected boundary outlier above the256 threshold was captured this time. This does not prove zero errors at all magnitudes.
- Water normals now tilt at most0.426 degrees, versus7.54 previously. Resolution changed854x480→1063x628, camera moved, and sun direction changed. This is not a controlled version-only convergence comparison, and the two capped logs cannot yield a noise-reduction percentage.
- Paths:123 ordinary→water transmission→sun;108 ordinary→water reflection→sun;22 entry→ordinary→exit→sun;2 additional ordinary-bounce paths;1 water reflection→ordinary→water reflection→sun. The largest remaining sample is39667.27, still an unprotected underwater exit with roulette amplification.

## Confirmed incident-medium defect

- All123 ordinary→water transmission records approach the pool's upper interface from below, yet carry historical `inWater=false`. The entry/exit flag comes from the unflipped outward mesh normal, while old Fresnel/refraction selected its IOR pair solely from this stale historical boolean.
- Recomputing the logged directions with air→water eta reproduces their false exits within1.30e-7. Using water→air eta gives a negative Snell discriminant in all123 cases (range-0.7383 to-0.6454): these interface events require total internal reflection.
- Example pixel487,316/sample4259: water hit distance0.0016423, incoming(-0.8130613,0.2270184,0.5360912), toward-viewer normal(0,-0.9999788,0.0065168). Wrong eta0.75019 sends the ray toward the sun; correct eta1.333 has no transmitted ray.
- The reconstructed secondary origin equals the preceding wall hit plus its *shading* normal times0.005 within4.17e-7. In122/123 records the wall hit is above the local water-triangle plane while this biased origin is below it. This strongly identifies the origin offset as a contributor to the stale medium; checking finite-triangle geometry and replacing shading-normal offsets still requires a separate geometry change.
- Earlier labels such as “dry transmission” describe recorded historical state, not proof that the ray was physically in air. These123 paths are specifically inconsistent at the water interface; the108 reflected paths are a separate sampling class.

## 0.3.11 correction and remaining boundary

- Correct incident state to `!waterEntering` before choosing IOR/Fresnel/refraction. Reflection retains that incident medium; successful transmission still adopts `waterEntering`. Apply the same rule to the initial and subsequent water interfaces in the transmission guide.
- Existing consistent states are unchanged. The captured false-exit regression fails old code and passes the corrected radiance/initial-guide/nested-guide consumers; independently removing each correction fails the test.
- This does not reconstruct a skipped earlier interface or retroactively correct its absorption/Fresnel weight. Geometric origin offsets, tiny surface slopes and missing explicit reflection/refraction sampling remain open; no full-frame convergence claim.
- Physical reference: [PBRT, Specular Reflection and Transmission](https://www.pbr-book.org/4ed/Reflection_Models/Specular_Reflection_and_Transmission). The local GPU observations and extracted decision regression establish this renderer's particular mismatch.

- Verification: full native/Java/Slang/SPIR-V build passed (52s); captured incident-medium, transmission-guide, water proposal/edge, diagnostic and probe checks passed. Independent review found no blocking issue. Package version,23 shader hashes and locales verified; installed0.3.11 with hash `c4747b9266aa79ed6efb7e2dedece119497ee9dd37120b99b32e61f07aace82d`, preserving0.3.10 as `.jar.disabled`. New GPU verification remains pending.

## 0.3.11 follow-up: pool-rim reflection and small tilted exits

- Inputs: `caustica-paths-20260916-154657-487.jsonl`, SHA256 `5e95421d324c53ddc4bcdafad15a98bdeb2bbea570a6c0affc351dac4487b148`; `caustica-paths-20260916-155159-172.jsonl`, SHA256 `c8fb984b4e70b9df959cd9fd2ea8697faca46e3743509516ea935b93d2e12c1a`.
- A:117 records, samples265–5216, source view0, resolutions1359x802/854x480. B:256 records, samples269–7181,854x480, multiple debug views. Both24 bounces, flags34 (waves off), max water tilt0.426°. Replay errors<=2.75e-7. All records are unprotected; no protected outlier above the256 threshold was captured.
- A contains86 ordinary→water-reflection→sun and27 entry→ordinary→exit→sun records; B contains185 and64 respectively. Every B reflection receiver is on the pool wall at z≈-7, and none of those185 paths has roulette amplification. The earlier underwater-only proposal simply does not target this reflection class.
- Largest B exit: pixel238,188/sample5795, blue throughput0.023281 after the bottom bounce and0.0226626 at exit. Unprotected roulette raises a survivor to1.0, yielding41288.61 solar contribution. Its exit normal(-0.003583885,-0.99999356,0) is only slightly tilted, but this is enough to leave the old narrow horizontal guide.
- Remaining ordinary→water-transmission records are physically allowed at the current interface: using the corrected eta reproduces their directions within5e-8 and gives positive discriminants. They are not recurrence of the0.3.10 impossible exits; prior-segment origin/medium recovery remains unresolved.
- B changes debug views and includes repeated pixel/sample/seed records. Capture occurs before debug filtering, so a log row tagged view20 can legitimately describe an unprotected event. Neither log gives an unbiased frequency, unique dot count or matched version-only noise percentage.

## 0.3.12: use the sampled interface normal as a direction proposal

- Before vertex RNG, trace one horizontal-center pilot and restore the complete payload. Select a matching water entry for dry reflection, or exit for submerged refraction. Use wave-adjusted reflection normals and geometric refraction normals, as actual transport does.
- Map the expanded solar square through that fixed normal; reflection has unit solid-angle Jacobian, refraction uses eta²*cosWater/cosAir. Retain known forward density on sampled proposal edges. Share the context in BSDF/guide mixture, static-light and celestial NEE competitors, and existing roulette protection.
- Failed wet pilots fall back to the old horizontal proposal, dry pilots to BSDF only. All proposals retain50% full BSDF support; actual rays still decide visibility and interface events. This is not a separate NEE estimator or a manifold solver.
- Extracted FP32 tests and24 planar transport cases pass; observed means differ from independent integrals by<0.3% in these runs. The large measured planar variance reduction is not a prediction for the user's scene. Pilot selection tests stub intersection/waves; real traversal coverage and cost need GPU testing.
- Full build (65s), existing targeted regressions and independent review pass;23 packaged shaders and locales match generated/source bytes. Restart and compare source view at the unchanged pool-rim camera, resolution, exposure, waves and sun. Record both equal-SPP appearance and time. Since more paths can become protected, view20/21 membership changes; source-image convergence is the acceptance criterion.
