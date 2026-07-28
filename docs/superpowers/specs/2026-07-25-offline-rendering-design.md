# Offline Rendering Design

## Goal

Add a live Offline Rendering mode to Caustica. While the camera is stationary,
the renderer must bypass DLSS Ray Reconstruction and DLSS Frame Generation,
trace at native display resolution, and progressively average independent path
tracing samples into a high-precision HDR image.

The intended result is a stable, increasingly converged image with richer
indirect light, emissive lighting, soft shadows, reflections, and refractions
than the real-time denoised path.

## User-Approved Behavior

The selected behavior is automatic game-tick freezing in a single-player
integrated server:

1. Enabling Offline Rendering does not immediately freeze the world.
2. Three consecutive camera-stable render frames arm accumulation.
3. Caustica asks the integrated server's `ServerTickRateManager` to freeze.
4. Accumulation starts only after the freeze request is confirmed.
5. Minecraft's frozen-tick behavior still permits the player and a ridden
   entity to move, so the player can recompose the view.
6. Moving the camera clears the accumulated image but leaves the world frozen.
7. Disabling Offline Rendering restores the server's pre-existing frozen state.
   A world that was already frozen before Caustica intervened remains frozen.

On a remote multiplayer server Caustica must not send commands or attempt to
change server state. It waits for the client level to report that game ticks are
frozen and shows a `Run /tick freeze` status until then.

## Runtime Compatibility

Offline Rendering and NVIDIA temporal features are mutually exclusive at
runtime:

- `RtDlssRr.enabled()` returns false while Offline Rendering is enabled.
- `RtDlssFg.enabled()` returns false while Offline Rendering is enabled.
- The saved DLSS-RR and Frame Generation preferences are not overwritten.
- Turning Offline Rendering off restores their effective behavior immediately.

Since RR is effectively disabled, `RtComposite.ensureOutput(...)` selects the
existing native-resolution no-RR render size. The offline path never upscales a
lower-resolution trace.

## Accumulation Pipeline

The existing world ray-generation shader produces one HDR estimate per frame:

```text
frame estimate = sum(path samples) / current SPP
```

Offline Rendering adds:

- a native-resolution `R32G32B32A32_SFLOAT` history image;
- a compute pass that reads the current `R16G16B16A16_SFLOAT` trace;
- the existing display-resolution `rrOutput` image as the resolved
  `R16G16B16A16_SFLOAT` output.

For `P` previously accumulated samples and `C` current-frame samples:

```text
newAverage = (oldAverage * P + frameEstimate * C) / (P + C)
```

The current SPP is therefore a weight, not merely a frame counter. Changing SPP
does not bias an existing accumulation.

The compute pass writes both the full-precision history and the half-precision
resolved image. Exposure and display mapping continue to consume `rrOutput`, so
SDR/HDR output behavior remains shared with the real-time path.

## Camera Stability and Resets

Camera stability compares:

- camera X/Y/Z with a `1e-7` block tolerance;
- all projection-matrix elements with a `1e-6` tolerance;
- all view-rotation-matrix elements with a `1e-6` tolerance.

The projection comparison makes FOV, view bobbing, and projection changes reset
the image automatically.

The history is reset when any of these changes:

- camera position, rotation, projection, or dimension;
- output width or height;
- terrain scene revision after section publication/removal/rebase;
- debug view;
- maximum bounce count;
- entity, particle, water-wave, PBR, or celestial-light settings that affect
  traced radiance;
- Offline Rendering transitions from disabled to enabled.

SPP does not reset history because the weighted average handles it correctly.

## Frozen Render Inputs

`/tick freeze` freezes game ticks, but Caustica's water animation currently uses
`System.nanoTime()`. Caustica therefore captures the water-animation time when
the freeze is confirmed and reuses it for the entire offline session.

The celestial `SkyPush` is also captured at freeze confirmation and reused.
This prevents partial-tick interpolation or client timing from moving the sky
while samples are being accumulated.

Terrain changes still increment a scene revision and clear the history. This
covers block edits and late terrain-stream publication even when the world is
otherwise frozen.

## User Interface

Add an immediately applied `Offline Rendering` boolean to the existing Ray
Tracing section of Video Settings, before the DLSS quality option.

The tooltip states:

- the mode freezes single-player game ticks after the camera becomes still;
- DLSS Ray Reconstruction and Frame Generation are temporarily bypassed;
- multiplayer servers require a manual `/tick freeze`;
- moving the camera resets accumulated samples.

Add a small top-left HUD status while Offline Rendering is enabled:

- `Offline: hold camera still`
- `Offline: freezing game ticks`
- `Offline: run /tick freeze`
- `Offline: N samples`

The HUD uses Fabric's `HudElementRegistry` and disappears immediately when the
mode is disabled.

## Failure and Cleanup

- Failure to access or freeze an integrated server leaves the renderer in the
  waiting state and logs one bounded warning; it does not accumulate changing
  frames.
- Remote multiplayer never receives an automatic command.
- Shutdown, RT disable, world exit, and Offline Rendering disable all call the
  freeze controller's restore path.
- GPU accumulation images and the compute pipeline are destroyed with the
  existing composite resources.
- No Git staging, commit, or push is part of this work.

## Acceptance Criteria

- Offline Rendering appears in Video Settings and takes effect without restart.
- DLSS-RR and Frame Generation are effectively inactive whenever it is enabled,
  without erasing their saved settings.
- The trace runs at display resolution in Offline Rendering mode.
- Three stable camera frames cause an integrated single-player server to
  freeze; accumulation starts only after confirmation.
- Camera movement clears the sample count and accumulated image.
- A pre-frozen single-player server is not un-frozen when Offline Rendering is
  disabled.
- Remote multiplayer requires and detects a manual `/tick freeze`.
- Static frames use weighted HDR accumulation and the HUD reports the sample
  count.
- Frozen sky and water animation do not drift across accumulated frames.
- Terrain publication and relevant runtime setting changes reset accumulation.
- Focused tests and the complete local build pass.
