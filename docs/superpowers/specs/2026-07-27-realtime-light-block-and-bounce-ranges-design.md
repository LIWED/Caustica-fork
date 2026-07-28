# Realtime Light Block and Bounce Ranges Design

**Date:** 2026-07-27  
**Target version:** 0.3.0  
**Status:** Approved for implementation planning

## Goal

Make vanilla Light blocks provide explicit ray-traced illumination during normal realtime rendering, expose realtime path bounces from 2 through 16, and add a separate offline path-bounce setting from 2 through 32.

The persistent grain and dirty spots seen after roughly 8000 SPP are explicitly deferred. This feature records that issue but does not change the offline estimator or add a luminance clamp.

## Confirmed User Decisions

- Realtime path-bounce range: 2–16.
- Offline path-bounce range: 2–32.
- Realtime Light blocks participate at every eligible path bounce.
- Use a dedicated realtime global point-light table, not the full offline static-light table.
- If realtime performance is insufficient, the player can lower path bounces.
- Do not execute Git operations or copy a JAR into a game instance without explicit permission.

## Terminology

- **SPP:** Number of independent paths processed per pixel in one frame. In offline mode it is a batch size; equal total accumulated samples use the same global sequence regardless of batch size.
- **Path bounces:** Maximum number of secondary surface interactions allowed for one path.
- **Eligible bounce:** A non-delta receiver where direct-light sampling has a meaningful BSDF value. Perfect specular glass/water steps do not perform diffuse point-light NEE, but the surface reached after the specular step remains eligible.
- **Light block:** The invisible vanilla `Blocks.LIGHT` block with a `LEVEL` value from 0 through 15.

## Bounce Settings

### Realtime

The existing `composite.max-bounces` setting remains the realtime setting:

- Range: 2–16.
- Default: 4.
- Used during normal rendering, camera movement, and offline waiting/stabilization frames.
- Remains immediately effective.

### Offline

Add `offline.max-bounces`:

- Range: 2–32.
- Default: 8.
- Used only when `OfflineAccumulationState.Decision.accumulate()` is true.
- Included in the offline render signature so changing it invalidates incompatible history.
- Reuses the existing `WorldPush.maxBounces`; no shader ABI field is added.

The video options screen shows both values with distinct labels and warnings. The offline tooltip states that high values, especially in water/glass scenes, can substantially reduce samples per second or cause long frames.

The SPP tooltip is corrected to explain that offline SPP controls per-frame batch size rather than quality at a fixed total sample count.

## Realtime Light-Block Source Data

`RtTerrainMesher` already detects `Blocks.LIGHT` before render-shape filtering and creates a point source at the block center. The new design preserves Light-block point sources separately from emissive triangle area lights:

- A section result carries an explicit Light-block point array regardless of whether the section also contains geometry.
- Area lights remain in the offline static-light collection.
- Terrain residency maintains a Light-block source map keyed by section.
- Level 0 is not published.
- Levels 1–15 use the same position, white color, and intensity calibration as the existing offline Light-block implementation.
- Empty-geometry sections containing Light blocks remain valid sources.
- Adding, removing, changing `LEVEL`, pruning, or rebasing updates the Light-block source revision.
- Equality is based on source contents, not empty-array object identity, avoiding meaningless revision churn.

## Dedicated Realtime GPU Table

Add a realtime Light-block table owned by terrain residency:

- Contains point-light records only; area-light records are rejected.
- Uses a single global brightness-weighted CDF because normal worlds contain few Light blocks.
- Does not build per-receiver local directories.
- Publishes a new immutable buffer generation when the Light-block source revision changes.
- Does not call `ctx.waitIdle()` during ordinary updates.
- Keeps the previous generation alive until the graphics timeline proves no in-flight frame can still reference its device address.
- Rebase republishes positions relative to the new terrain base exactly once.
- Empty state publishes address 0, count 0, and total weight 0.

The realtime record can use a compact point-light-only layout rather than the 128-byte offline area/point union, provided Java and Slang strides are contract-tested from one documented ABI.

## Shader and Frame Data

`WorldPush` gains realtime Light-block table address, count, and total weight, plus a distinct enable flag.

Realtime behavior:

- The realtime flag is enabled only when a valid table generation matches the current Light-block revision.
- At every eligible ordinary-material bounce, choose one Light block from the global weighted CDF.
- Evaluate inverse-square point-light radiance, the current diffuse/specular BSDF, and a visibility ray.
- Particle primary receivers also receive the point light with their existing oriented billboard normal semantics.
- Delta glass/water steps do not issue an invalid direct-light sample; later eligible hits do.
- The point source itself remains invisible and has no hittable geometry.

Offline behavior:

- Disable the realtime Light-block flag.
- Continue using the existing full offline static-light table, which already includes Light blocks and emissive area lights.
- Never evaluate both tables in the same path, preventing duplicate Light-block energy.

Realtime Light blocks do not enable direct-light sampling for torches, glowstone, lanterns, lava, or LabPBR-only emission. Those sources retain their existing realtime behavior and remain part of the full offline table where supported.

## Failure and Boundary Handling

- Reject non-finite or non-positive point weights during CPU table construction.
- Validate table address, count, total weight, and selected index before GPU access.
- A missing, stale, or empty realtime table produces zero additional Light-block radiance rather than reading stale memory.
- Buffer construction failure leaves the last complete generation active when its source revision is still valid; otherwise the feature safely disables until a later rebuild.
- Source updates never destroy a buffer still referenced by an in-flight frame.
- Realtime and offline flags are mutually exclusive by contract.

## Performance Model

Every eligible bounce may add one point-light selection and one visibility ray. Cost therefore grows with:

- render resolution,
- SPP,
- actual surviving path length,
- and the number of eligible non-delta bounces.

The number of Light blocks affects table rebuild and selection distribution but does not add one shadow ray per light. One weighted light is sampled per eligible bounce.

The design intentionally avoids:

- the offline table's area lights,
- receiver-local directory rebuilding,
- `waitIdle()` on Light-block edits,
- and scanning every light in the shader.

## Tests

### Pure Java behavior

- Realtime bounce clamping preserves 2 and 16 and clamps outside values into that range.
- Offline bounce clamping preserves 2 and 32 and clamps outside values into that range.
- Effective bounce policy uses realtime values outside true accumulation and offline values during accumulation.
- Changing offline bounces changes the offline render signature.
- SPP batch behavior remains sequence-contiguous.
- Light levels 1, 7, and 15 produce finite strictly increasing weights; level 0 is absent.
- Point sources from geometry and empty-geometry sections are represented exactly once.
- Realtime table construction rejects every area-light kind.
- Weighted CDF selection and PDF normalization are correct.
- Content-equal empty/source arrays do not advance the Light-block revision.
- Rebase translates a point exactly once.

### Source and ABI contracts

- Realtime and offline bounce ranges and option bindings are distinct.
- `WorldPush.maxBounces` receives the effective policy output.
- Realtime Light-block and offline full-static-light flags are mutually exclusive.
- Realtime table access validates address, count, weight, and selected index.
- The realtime shader path is reached at every eligible ordinary-material bounce.
- Delta paths skip direct point-light NEE and later eligible hits resume it.
- CPU and GPU realtime point-record stride and offsets match.
- New buffer generations retire through timeline completion without `waitIdle()`.

### Build verification

- Run all existing focused PowerShell tests.
- Compile Java and regenerate reflected shader records.
- Compile and validate realtime/offline EXT and NV raygen variants.
- Run the full native and Gradle build.
- Verify `caustica-0.3.0.jar`, embedded `fabric.mod.json`, required SPIR-V resources, file size, and SHA-256.

### Required game validation

Use `caustica_test`, only after explicit authorization to copy/install:

- Realtime mode, offline disabled.
- `/setblock` Light levels 1, 7, and 15 in a dark 2×2×2 room.
- Place, remove, and change `LEVEL`; illumination must update.
- Test sources in empty and geometry-containing sections and across section boundaries.
- A wall must occlude the Light block.
- Test through one and multiple mirrors/glass/water paths.
- Realtime bounce values 2, 4, 8, 12, and 16.
- Confirm enabling offline rendering does not double Light-block brightness.
- Confirm torches, glowstone, lanterns, and lava are not accidentally added to the realtime point table.
- Record FPS, GPU power, longest frame, and visible stability with 0, 64, and 512 Light blocks.

## Deferred Issues

- Persistent grain and dirty spots after approximately 8000 SPP.
- Whether a future estimator, adaptive sampling, outlier analysis, or reconstruction filter is needed.
- Realtime direct-light tables for ordinary emissive blocks or LabPBR-only emission.
- Incremental publication of the full offline area-light table.

These remain open in `docs/BUGS.md`; this feature must not claim they are solved.
