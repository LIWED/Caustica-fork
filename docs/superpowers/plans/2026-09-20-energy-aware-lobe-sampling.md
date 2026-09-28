# Energy-aware ordinary BSDF sampling

**Goal:** Reduce the ordinary-path weight amplification demonstrated by0.3.14 GPU logs, without further roughening materials or clamping contributions.
**Evidence:** Matched-position/resolution/light capture generations1/2/3 use modes0/1/2, all256 records per generation have no transparent interface history. Strong mode's largest recorded path reaches throughput26.17 before its final ordinary bounce; repeated high-F0 surfaces use specular probabilities near0.5 despite a small energy-limited diffuse component.
**Design:** Offline only, derive conservative channel-maximum bounds for `f_i*cos/p_i`: specular U=max(1-(1-F0)*A(V)); diffuse D=max(diffAlb*(1-F0))*A(V)/C, with existing A and C=.8411881. Choose U/(U+D), preserving nonzero components with interior clamps and allowing pure-lobe endpoints. Use one helper for sampling, full PDF and guided lobe posterior. Keep BRDF, roughness policy, geometry, light radiance, roulette and RNG draw counts unchanged. Realtime returns its old probability expression.
**Rationale:** Away from support clamps, this minimizes max(U/p,D/(1-p)) over this conservative bound, to U+D. It does not guarantee globally optimal lighting variance or unchanged finite-SPP image noise. Pure-metal diffuse lobe is zero and can safely receive zero probability.
**Validation:** Extract actual production code; independent NDF/diffuse integrals, RGB materials, boundary probabilities, old-proposal negative control and PDF-mismatch negative control; compare measured variance at recorded material states. Update dependent old tests to sample the actual shared probability. Preserve0.3.14 numerical artifacts.
**Authorization/scope:** Continue user's authorized convergence work based on returned test evidence. No new UI/settings, no cache/denoiser change, no commit or unrelated cleanup. Build/deploy only after checks; retain disabled0.3.14. General GPU image acceptance remains open.

**Review boundary:** Existing lobe-conditioned ray cones select different downstream texture LODs. Changing the selection probability can change that filtering distribution; unchanged mean is established for the fixed homogeneous BRDF/incoming-radiance tests, not all textured GPU scenes. Do not claim full-renderer unbiased equivalence from this experiment.

- [x] Record capture evidence and create failing numerical/integration checks.
- [x] Add shared offline probability and update all three consumers; keep realtime unchanged.
- [x] Verify matched mean, per-step bounds and variance on representative captured materials; update dependent regressions.
- [x] Run affected regressions, source review and full build/package verification.
- [x] Update PROJECT/CHANGELOG/BUGS and deploy0.3.15 reversibly.
