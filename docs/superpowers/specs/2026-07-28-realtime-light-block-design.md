# Realtime Minecraft Light Block Design

**Date:** 2026-07-28  
**Target version:** 0.3.3  
**Status:** Implemented; automated verification complete; game validation pending

## Goal

Make the invisible vanilla `minecraft:light` block provide explicit ray-traced
illumination during normal realtime rendering.

Ordinary emissive blocks such as glowstone, torches, lanterns, lava, and
LabPBR-defined emission keep their current realtime behavior. Offline static-light
sampling also remains unchanged.

## Confirmed Scope

- Capture `minecraft:light` levels 1 through 15 as invisible point sources.
- Level 0 does not publish a source.
- Sample one weighted Light-block source at every eligible realtime path bounce.
- Keep realtime Light-block sampling and offline full static-light sampling mutually
  exclusive.
- Preserve current realtime/offline bounce settings and offline accumulation behavior.
- Do not change ordinary emissive-block sampling, glass/water guidance, or the
  offline estimator.
- Do not execute Git operations or copy a JAR into a game instance without explicit
  authorization.

## Architecture

### CPU source sidecar

`RtTerrainMesher` captures every `minecraft:light` before render-shape filtering and
stores it separately from area-light geometry. A section result carries its Light
sources even when the section has no renderable geometry.

`RtTerrain` owns a section-keyed Light-source map and an independent revision. Source
contents, not array identity, determine whether the revision changes. Adding,
removing, changing `LEVEL`, pruning a section, or rebasing coordinates updates the
published source state.

Dirty-group results stage Light-source changes and publish them atomically with the
corresponding terrain update. Cancelled groups discard staged changes.

### Dedicated realtime GPU table

The realtime table contains point records only:

```text
offset  0: float3 positionRelativeToTerrainBase
offset 12: float cumulativeWeight
offset 16: float3 radiance
offset 28: float selectionWeight
stride: 32 bytes
```

The table uses a single brightness-weighted global CDF. One source is selected per
eligible bounce, so the number of Light blocks affects table size and selection
distribution but does not create one shadow ray per light.

Every rebuilt table is an immutable buffer generation. Publication records the last
graphics timeline value that could reference the previous generation and retires the
old buffer only after that value completes. Ordinary Light-block updates must not
call `ctx.waitIdle()`.

An empty source set publishes address 0, count 0, and total weight 0 without
allocating a zero-sized buffer.

## Frame and Shader Data Flow

`WorldPush` receives the realtime table address, count, total weight, and a distinct
enable flag.

During realtime rendering:

1. Terrain requests a table snapshot for the current Light-source revision.
2. Java enables realtime Light-block sampling only when the snapshot is valid,
   revision-matched, finite, and non-empty.
3. Each eligible ordinary-material bounce selects one point from the CDF.
4. The shader evaluates inverse-square radiance, the current surface BRDF, and one
   visibility ray.
5. Particle primary receivers use their existing oriented billboard-normal
   semantics.

Perfect delta glass or water steps do not perform diffuse point-light sampling.
Later eligible surface hits resume sampling normally.

During true offline accumulation, the realtime flag is disabled and the existing
full static-light table remains active. Both flags must never be enabled together,
preventing duplicate Light-block energy.

## Failure Handling

- Reject non-finite coordinates, intensity, weights, and cumulative totals.
- Validate address, count, total weight, and selected index before GPU access.
- A missing, stale, failed, or empty table safely contributes no additional light.
- Failed construction does not publish an incomplete buffer.
- If the previous generation no longer matches the current source revision, the
  feature remains disabled until a complete matching generation is available.
- No buffer may be destroyed while an in-flight frame can still reference its device
  address.

## Testing

### Pure behavior

- Levels 1, 7, and 15 produce finite, strictly increasing intensity and weight.
- Level 0 is omitted.
- CDF selection and normalized selection PDF are correct.
- Source ordering is deterministic.
- Content-equal source arrays do not advance the revision.
- Empty-geometry sections retain Light sources.
- Rebase translates each point exactly once.

### Source, ABI, and lifecycle contracts

- Capture occurs before render-shape filtering.
- CPU and Slang record layouts both use the documented 32-byte stride.
- Dirty groups publish Light-source changes atomically.
- Pruning and rebasing update source state correctly.
- Buffer generation replacement uses graphics-timeline retirement and contains no
  update-path `waitIdle()`.
- Realtime and offline light-sampling flags are mutually exclusive.
- Shader access validates every table boundary and denominator.
- Ordinary-material sampling remains inside the path loop without a fixed
  bounce-index cap.

### Build verification

- Run focused Light-block, offline behavior, bounce-option, frame-generation, and
  frame-stat contract tests.
- Compile Java and regenerate reflected shader records.
- Compile and validate realtime/offline EXT and NV raygen variants.
- Run the complete native and Gradle build.
- Verify the 0.3.3 JAR version and required shader/native resources.

### Required game validation

After explicit authorization to install into `caustica_test`:

- Test Light levels 1, 7, and 15 in a dark room.
- Add, remove, and change `LEVEL`; illumination must update.
- Verify sources in empty and geometry-containing sections.
- Verify walls occlude the point source.
- Verify illumination after glass, water, and mirror path steps.
- Confirm offline accumulation does not double Light-block brightness.
- Confirm ordinary emissive blocks retain their current realtime behavior.
- Record FPS, GPU power, longest frame, and stability with 0, 64, and 512 Light
  blocks.

## Documentation and Delivery

Implementation updates `docs/PROJECT.md`, `docs/CHANGELOG.md`, and `docs/BUGS.md`,
keeping each concise. Automatic tests and builds do not count as game-level visual
or performance acceptance.

This specification supersedes only the deferred realtime Light-block Tasks 2 through
4 in the 2026-07-27 combined Light-block/bounce plan. The already completed bounce
policy work remains unchanged.
