# Detail-preserving offline reconstruction experiment

**Goal:** Withdraw failed fixed-strength0.3.16 reconstruction and require measured sample uncertainty before altering a pixel. Retain raw history, default Off, no game-quality claim before user validation.
**Evidence:** User reports most detail lost. New production-kernel regression shows a noise-free .45/.55 checker with identical first-hit guides retains only0.371211 contrast. Previous tests checked large boundaries, not stable fine reflection detail or genuine point highlights.
**Design:** Accumulate separate weighted RGB Welford moments from frame means, count frames K, weight W=sum SPP. Estimate mean variance as M2/((K-1)*W) under independent equal per-sample variance. Preserve raw weighted mean exactly. Use a variance-confirmed isolated-peak stage and one radius2 spatial stage with shrinkage set by noise/observed contrast. Remove fixed three-scale smoothing. Insufficient/invalid statistics and zero variance pass through. No claim of detecting every bias or rare tail; frame means contain correlated subpixel sampling.
**Defaults:** New `offline.denoise-adaptive` key, false; do not inherit persistedtrue from rejected `offline.denoise`. Preserve old config as inert legacy data. UI identifies experimental adaptive denoise. Existing enabled regularization remains independent.
**Resources:** Reuse second scratch allocation as persistent moments, reducing final reconstruction to2 immutable descriptor sets; history+moments written only by accumulation, moment input readonly in denoiser. Keep raw exposure before reconstruction and no-reset toggle. Track moments even while disabled so later toggle has statistics. Same resize/reset/destruction lifecycle.
**Validation:** production numerical kernel tests and independent weighted statistics, variableSPP/reset/constant/outlier/nonfinite boundaries; stable fine details and point lights preserved, stochastic grain/outliers reduced, old fixed-filter negative control. Build/review/package/deploy follows existing authorization. Save original0.3.16 test/artifacts for comparison.

- [x] Prove fixed-filter detail failure and add statistics/quality regression cases.
- [x] Implement separate moments and matching host binding/reset/total weights.
- [x] Replace unconditional smoothing with variance-dependent local reconstruction; new default-off option.
- [x] Run focused CPU/host/build checks and independent review; record limitations and rejected0.3.16 acceptance.
- [x] Update PROJECT/CHANGELOG/BUGS, install0.3.17 and preserve disabled0.3.16 with verified hashes.
