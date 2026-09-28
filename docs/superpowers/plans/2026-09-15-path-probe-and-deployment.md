# Actual-path capture and automatic test deployment

**Goal:** Obtain bounded GPU path evidence after0.3.8 failed image acceptance, and automate the user's authorized mod replacement.

## Design

- No new transport estimator or denoising change. Capture water-related category14 contributions above a linear threshold before diagnostic filtering. Replay only a bounded number of qualifying paths with the same seed and ray; discard replay radiance and restore guide outputs.
- Append optional BDA address/threshold to reflected WorldPush; realtime address is zero. GPU header16 bytes, up to32 records per frame, each64 header +33 steps of160 bytes. No per-invocation path array; only qualifying replays write step data.
- Record pixel/global sample/seed/source and each hit's position, incoming direction, medium, geometric/effective normals, material parameters, throughput before/after, roulette probability, outgoing event/direction and contribution. Completion marker is published only after replay returns.
- Host uses mapped buffers owned by actual graphics timeline values, shader-write→host-read dependency, invalidate before reading, and bounded asynchronous JSONL output under instance logs. Avoid per-frame waitIdle and frame-count retirement guesses. Probe failures disable logging rather than rendering.
- Automatically copy future successful runtime jars to `E:/Minecraft/.minecraft/versions/caustica_test/mods` and disable prior jars whose metadata ID iscaustica. Stage/hash-check before switching, preserve other mods and disabled backups, roll back failed activation. Deployment is explicitly user-authorized; rendering capture does not change the image estimator.

## Work and verification

- [x] Test/implement automatic deployment independently with fixture jars, idempotence and rollback tests.
- [x] Test/implement shader trigger, record ABI and deterministic replay wiring; no extra RNG or radiance contribution.
- [x] Implement timeline-owned host readback, bounded decoder/JSON output and lifecycle tests.
- [x] Run existing offline/diagnostic/celestial/material contracts, generated ABI checks, full build; verify runtime jar metadata/shaders and deploy with hash check.
- [ ] User runs the existing scene; read actual log records before another estimator change. GPU capture/visual acceptance remain pending until that run.

## Evidence motivating change

- User's21 view `2026-09-15_19.51.36.png` contains points at18714SPP;20 view `19.55.31.png` also contains points, sample count unspecified. These partitions do not reveal where earlier path weights became large. Repeated screenshot-only inference and simplified mean tests have not delivered acceptable convergence.
- 0.3.9 is a diagnostic candidate, not another claimed firefly fix. Transport remains0.3.8 so logged evidence corresponds to the failing behavior.

## Verification — 2026-09-16

- Full native/Java/shader build passed (50s); targeted probe, deployment, water, offline/diagnostic, celestial, material/energy, transmission and generated ABI checks passed. Fixed the initial compilation error to match the installed void VMA invalidate binding.
- Verified runtime version, probe classes, all23 shader hashes and locales. Installed0.3.9 automatically;0.3.8 remains as `.jar.disabled`. Destination hash matches `c917e004c867dc25885a0213afad360de4ac9c546a9b887a743d274a0869cb44`.
- Actual GPU capture and image equivalence remain pending. The bounded first-come logger may be dominated by normal solar reflections; absence of another path class does not clear it.
