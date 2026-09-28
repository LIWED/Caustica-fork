# Offline display denoise implementation plan

**Goal:** Prioritize visible firefly/grain reduction with a reversible display filter, after user acceptance of possible small-detail loss. Preserve the raw progressive estimate for immediate comparison.
**Architecture:** Raw FP32 accumulation remains untouched. After raw exposure metering, run a robust outlier pass and three edge-aware spatial passes (steps1/2/4) into separate FP32 scratch images, then the existing FP16 display target. Only source view0 during offline accumulation; default enabled, UI toggle without reset. No temporal feedback, integrator or RNG changes.
**Tech stack:** Existing GLSL compute/Vulkan Java pipeline, two scratch images, no external runtime dependency. This is an experimental spatial filter, not OIDN or an ITRP cache implementation.

## Evidence and choices

- User sees no meaningful0.3.15 improvement; their priority is noise/appearance, with performance monitoring secondary. Accepted a switchable denoising option on2026-09-21.
- Latest GPU log171336-149 contains768 thresholded paths across three modes, all category10, no transparent history. Captures stop near256SPP, so they cannot characterize final30000SPP image noise or prove the only cause.
- Alternatives: keep modifying transport (previous changes insufficient), integrate OIDN (new native dependency/readback/backend lifecycle), or add contained spatial reconstruction now. Choose the last; keep future native denoising/caching as separate work.
- Neighborhood rank statistics reject isolated extreme brightness; normal, reversed-Z depth and material-color compatibility reduce boundary leakage. Subsequent bilateral color/guide weighting smooths grain. True tiny lights/highlights can be rejected too; show this limitation in UI/docs.
- Guide buffers are last-sample attributes and have transparent-surface limitations; no claim of perfectly stable edges, reflection preservation or unbiased reconstruction. No filtering of diagnostic views. Raw exposure metering avoids toggle-driven global exposure shifts.
- Read-only raw history is bound only as input. Four preallocated descriptor sets avoid changing descriptors in recorded/in-flight dispatches. All stages separated by existing GPU barriers; resources use existing output resize/retirement lifecycle.

## Tasks

- [x] Add failing tests: execute production GLSL algorithm through a CPU image shim on constant fields, grain, fireflies, HDR, boundaries, tiny images and reflective-detail fixtures. Include bypass/edge-guard negative controls.
- [x] Add `shaders/display/offline_denoise.comp`, pipeline and scratch lifecycle; reuse existing pipeline conventions without unrelated refactoring.
- [x] Add enabled-by-default boolean setting, bilingual tooltip and no-reset source-only dispatch after exposure. Verify routing, no history writes and barriers; retain automatic stage timing.
- [x] Run focused numerical/integration regressions, shader/native/Java build, code review and package checks. No GPU quality claim from CPU fixtures.
- [x] Update PROJECT/CHANGELOG/BUGS and experiment record; deploy0.3.16 reversibly and verify both active/disabled hashes. User can compare enabled/disabled within the same continuing accumulation without resetting samples.
