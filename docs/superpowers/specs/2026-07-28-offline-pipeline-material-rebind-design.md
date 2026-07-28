# Offline Pipeline Material Rebind Design

## Problem

Caustica 0.3.1 enters offline accumulation for one frame, reaches the current
2 SPP, then returns to `HOLD_STILL`. The cycle repeats every two seconds.

The FP16/FP32 transition destroys and recreates the world ray-tracing
pipeline. Pipeline creation calls `bindWorldTextures`, which currently
recreates the LabPBR atlases and unconditionally calls
`RtTerrain.markAllDirty()`. Published terrain rebuilds increment
`sceneRevision`; because that revision is part of the offline render
signature, the state machine correctly treats it as a scene change and
restarts the two-second wait. Switching back to realtime repeats the same
internal invalidation.

## Approved Design

Separate two operations that are currently coupled:

1. Binding texture descriptors into a newly created ray-tracing pipeline.
2. Recreating material atlases and re-extracting terrain after the underlying
   Minecraft block atlas actually changes.

When realtime and offline pipelines switch while the block-atlas handle is
unchanged and existing LabPBR views are valid, bind those existing views to
the new pipeline. Do not call `RtBlockMaterials.reset()`, `prepareAll()`, or
`RtTerrain.markAllDirty()`.

On first initialization, a changed block-atlas handle, or missing LabPBR
views, rebuild the material atlases and request terrain re-extraction exactly
as before.

## Safety Properties

- Keep `sceneRevision` in `OfflineRenderSignature`; real geometry and light
  changes must still reset accumulated samples.
- A resource-pack reload must still rebuild LabPBR atlases and re-extract
  terrain.
- FP16/FP32 mode switches may recreate output images and the world pipeline,
  but must not change the static scene identity by themselves.
- Do not change offline timing, automatic freeze/thaw ownership, bounce
  settings, glass/water guides, or light-block behavior.
- The target release is `0.3.2`.
- Do not execute Git commands or copy a JAR into a game instance.

## Verification

Add a source/behavior contract that fails on the 0.3.1 unconditional material
reset and terrain invalidation. It must require:

- a source-change decision before rebuilding block material atlases;
- descriptor-only reuse when the existing atlas is unchanged;
- `markAllDirty()` only on the rebuild branch;
- `sceneRevision` remains part of the offline signature.

Run all existing offline, video-option, frame-stat, and local-environment
tests, compile Java, then perform the complete native and Gradle build.
Verify the 0.3.2 installable JAR and sources JAR independently.
