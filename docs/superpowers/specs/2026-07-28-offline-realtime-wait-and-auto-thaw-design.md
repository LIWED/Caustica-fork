# Offline Realtime Wait and Auto-Thaw Design

**Status:** Approved for implementation  
**Date:** 2026-07-28  
**Target version:** 0.3.1

## Goal

When Offline Rendering is enabled, keep normal realtime rendering and game
time while the camera moves. After the camera remains continuously still for
two seconds, freeze game time and begin offline accumulation. Moving again
must immediately restore the realtime image and resume game time when
Caustica owns the freeze.

## Scope

Included:

- Replace the current three-frame stability gate with a two-second monotonic
  timer.
- Use the realtime FP16/DLSS-RR/Frame Generation path until accumulation
  actually begins.
- Switch to native-resolution FP32 offline rendering only after freeze
  confirmation.
- On movement, invalidate accumulation, switch back to realtime rendering in
  the same rendered frame, and asynchronously thaw a Caustica-owned freeze.
- Prevent stale asynchronous freeze requests from re-freezing the world after
  movement.

Deferred:

- Realtime Light-block illumination.
- Glass transmitted-background DLSS-RR guides.
- Water refraction motion-guide improvements.
- Keeping realtime and offline GPU resource sets resident simultaneously.

## Confirmed Root Cause

The current implementation treats `offline.enabled` as if the renderer were
already accumulating. It disables DLSS-RR and Frame Generation, selects the
native FP32 offline shader and creates offline resources before the state
machine decision is known. During movement, accumulation is correctly skipped,
but the raw single-frame path-traced image is copied directly to the display.

The stability gate is also frame-count based (`3` frames), so its wall-clock
delay varies with frame rate and is only tens of milliseconds in normal play.

## Selected Architecture

Use one GPU resource set and switch it at mode boundaries. This reuses the
existing `waitIdle`, destruction and recreation path, so the format and shader
variant remain consistent. A transition may cause one short hitch, but it does
not increase steady-state VRAM use.

The renderer distinguishes:

- **Offline requested:** the video option is enabled.
- **Offline accumulating:** the camera passed the two-second gate and the
  world freeze is confirmed.

Only `offline accumulating` selects the offline shader, FP32 trace/history,
native resolution, offline bounce count, offline static lights, and suppression
of DLSS-RR/Frame Generation.

## State and Timing

`OfflineAccumulationState.observe` receives an explicit monotonic `nowNanos`.
Production passes `System.nanoTime`; tests pass literal timestamps.

`STILL_DELAY_NANOS` is exactly `2_000_000_000L`.

- First observation, camera motion, projection/view change, render-signature
  change, disable, or world teardown resets `stableSinceNanos`.
- Elapsed time below two seconds remains `HOLD_STILL`.
- At exactly two seconds, a local world requests freeze once.
- `FREEZING` and `MANUAL_FREEZE_REQUIRED` still render through the realtime
  path.
- Only a confirmed frozen state returns `ACCUMULATING`.
- Movement from `ACCUMULATING` clears sample history immediately.

## Freeze Ownership and Races

Caustica may thaw only a freeze it created. A world already frozen by the user
or server is borrowed and is never automatically thawed.

When movement is detected after a Caustica-owned freeze:

1. Mark thaw pending before evaluating the frame state.
2. Invalidate outstanding freeze requests with a monotonically increasing
   request generation.
3. Publish non-accumulating mode immediately, so the current rendered frame
   uses realtime presentation.
4. Schedule integrated-server thaw asynchronously.
5. Clear ownership only after the thaw task succeeds.
6. If thaw fails, retain ownership so shutdown can still restore safely.

While thaw is pending, the controller reports the world as not eligible for
accumulation even if the client has not yet observed the unfreeze. This prevents
the old frozen state from restarting accumulation.

Every asynchronous freeze/thaw task captures both session token and request
generation. A stale task returns without mutating the server or newer request
state.

## Frame Data Flow

The frame decision moves before GPU output and pipeline selection:

1. Capture current camera and scene signature.
2. Call `beforeTrace` and publish the accumulating snapshot.
3. Call `ensureOutput(..., accumulating)`.
4. Call `ensureWorld(..., accumulating)`.
5. Record the frame using the same decision.

DLSS-RR and Frame Generation read the published accumulating snapshot, not the
offline preference. User preferences remain unchanged:

- Preference on + realtime phase: feature on.
- Preference off + realtime phase: feature remains off.
- Any preference + accumulating phase: temporal features suppressed.

## Testing

Pure Java behavior tests cover:

- `1_999_999_999 ns` does not freeze; `2_000_000_000 ns` does.
- Results do not depend on observation frequency.
- Motion, projection change and signature change restart the timer.
- Freeze confirmation is required before accumulation.
- Movement clears samples and returns a realtime frame immediately.
- Owned freezes request thaw; borrowed freezes do not.
- Stale freeze/thaw generations cannot mutate current state.
- User-disabled DLSS-RR/Frame Generation are never force-enabled.

Source/integration contracts cover:

- State decision occurs before output and pipeline selection.
- FP16/realtime and FP32/offline shader/image modes use the same accumulating
  boolean.
- Waiting, freezing and manual-wait frames use realtime bounces and RR/FG
  policy.
- Accumulating frames alone use offline bounces, history and static-light NEE.

Full verification includes focused scripts, Java 25 compilation, native NGX
shim build, all four raygen variants, SPIR-V validation, JAR metadata and
embedded-resource checks.

## Delivery Constraints

- Work only under `F:\mygit\test\Caustica_n\Caustica-main`.
- Do not execute Git add, commit, push, reset, checkout or worktree commands.
- Do not copy the JAR to `caustica_test` or any other game instance.
- Do not modify `E:\Minecraft\.minecraft\versions\Caustica26.2`.
- Keep the glass/water fix out of version 0.3.1.
