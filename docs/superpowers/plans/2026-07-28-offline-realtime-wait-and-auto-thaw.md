# Offline Realtime Wait and Auto-Thaw Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development or superpowers:executing-plans.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep normal realtime rendering and running game time while the
camera moves, then freeze and enter offline accumulation only after two
continuous seconds of stillness.

**Architecture:** Replace the three-frame gate with a monotonic-time state
machine. Publish one per-frame accumulating decision before GPU resource
selection, and use it consistently for shader format, DLSS-RR, Frame
Generation, bounces, sky/water freezing and accumulation. Automatically thaw
only freezes owned by Caustica and invalidate stale asynchronous freeze tasks.

**Tech Stack:** Java 25 (`D:\program\java25`), Fabric/Minecraft 26.2, Vulkan,
Slang, PowerShell behavior/contract tests, Gradle 9.5.

## Global Constraints

- Work only under `F:\mygit\test\Caustica_n\Caustica-main`.
- Do not execute Git add, commit, push, reset, checkout or worktree commands.
- Do not copy a JAR to a game instance.
- Do not modify `E:\Minecraft\.minecraft\versions\Caustica26.2`.
- Target version is 0.3.1.
- `STILL_DELAY_NANOS` is exactly `2_000_000_000L`.
- Moving, `HOLD_STILL`, `FREEZING` and `MANUAL_FREEZE_REQUIRED` use realtime
  FP16 rendering and preserve the user's DLSS-RR/Frame Generation preferences.
- Only `Decision.accumulate() == true` uses native FP32 offline rendering,
  offline bounces, history accumulation and offline static-light sampling.
- Movement immediately clears history and publishes realtime mode before
  asynchronous thaw completes.
- Thaw only a freeze owned by Caustica; never thaw a borrowed/manual freeze.
- Glass/water guide fixes and realtime Light-block work are out of scope.
- Update `docs/PROJECT.md`, `docs/CHANGELOG.md`, and `docs/BUGS.md`, keeping
  each under 200 lines.

---

### Task 1: Two-Second Stability State Machine

**Files:**

- Modify: `scripts/tests/OfflineRenderingBehaviorTest.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/offline/OfflineAccumulationState.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/offline/OfflineFreezeOwnership.java`

**Interfaces:**

- `OfflineAccumulationState` produces:

```java
public static final long STILL_DELAY_NANOS = 2_000_000_000L;

public Decision observe(
        boolean enabled,
        boolean cameraChanged,
        long nowNanos,
        long nextRenderSignature,
        boolean localAutoFreezeAvailable,
        boolean frozen,
        int spp);
```

- `OfflineFreezeOwnership` adds:

```java
public synchronized boolean ownsFreeze();
```

- Existing `consumeRestoreRequired()` remains for shutdown. Successful
  mid-session thaw calls `clearWithoutRestore()` only after the server reports
  success.

- [x] **Step 1: Replace frame-based tests with literal timestamp tests**

Use a `start = 10_000_000_000L` fixture. Assert:

```java
state.observe(true, true, start, 10L, true, false, 4);
assertEquals(Phase.HOLD_STILL,
        state.observe(true, false, start + 1_999_999_999L,
                10L, true, false, 4).phase(),
        "less than two seconds must remain realtime");
Decision arm = state.observe(true, false, start + 2_000_000_000L,
        10L, true, false, 4);
assertEquals(Phase.FREEZING, arm.phase(),
        "exactly two seconds requests freeze");
assertTrue(arm.requestFreeze(), "freeze is requested once");
```

Add independent assertions that sparse and dense observation schedules reach
the same result at exactly two seconds, and that movement at `start + 1.9s`
restarts the full delay.

- [x] **Step 2: Add failure/reset tests**

Assert projection-equivalent `cameraChanged`, render-signature change, disable
and teardown-style `clear()` reset the timer and accumulated sample count.
Assert a world already frozen cannot accumulate before two seconds.

- [x] **Step 3: Add ownership observation tests**

Assert `ownsFreeze()` is false initially, true after
`onFreezeConfirmed(false)`, false for `onFreezeConfirmed(true)`, remains true
until a successful clear/consume, and borrowed freezes never request restore.

- [x] **Step 4: Run the behavior test and verify RED**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
```

Expected: Java compilation fails because the new timestamp signature and
`ownsFreeze()` do not exist.

- [x] **Step 5: Implement monotonic timing**

Remove `STABLE_FRAMES` and `stableFrames`. Store `stableSinceNanos` and
`hasStableSince`. On first observation or any invalidation, set the timestamp
to `nowNanos`. Before subtracting, treat `nowNanos < stableSinceNanos` as a
fresh start. Do not request freeze until:

```java
nowNanos - stableSinceNanos >= STILL_DELAY_NANOS
```

Preserve all existing accumulation weights and reset-history semantics.

- [x] **Step 6: Implement ownership observation**

Add the synchronized `ownsFreeze()` query without changing shutdown consume
semantics.

- [x] **Step 7: Update every test call and verify GREEN**

Pass literal increasing timestamps to all `observe` calls. Run the behavior
test and require both Java behavior and shader contracts to print `PASS`.

---

### Task 2: Auto-Thaw and Phase-Driven Rendering

**Files:**

- Modify: `scripts/tests/OfflineRenderingBehaviorTest.java`
- Modify: `scripts/test_offline_rendering_behavior.ps1`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/offline/RtOfflineController.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/offline/OfflineModePolicy.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/pipeline/RtDlssRr.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/pipeline/RtDlssFg.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java`

**Interfaces:**

- `RtOfflineController` produces:

```java
public static boolean accumulating();
```

The result is a volatile snapshot updated from the current frame's
`Decision.accumulate()` and reset to false on session end.

- `OfflineModePolicy` continues to expose:

```java
public static boolean temporalFeatureEnabled(
        boolean preference, boolean offlineAccumulating);
public static boolean nativeResolutionRequired(boolean offlineAccumulating);
```

The second argument means actual accumulation, not the video-option value.

- `RtComposite` changes:

```java
private RtPipeline ensureWorld(RtContext ctx, boolean offlineAccumulating);
private void ensureOutput(
        RtContext ctx, int width, int height, boolean offlineAccumulating);
```

- [x] **Step 1: Add failing frame-mode policy assertions**

In the pure behavior test, assert enabled RR/FG preferences remain enabled
while `offlineAccumulating == false`, are suppressed only when true, and a
disabled preference remains disabled in both modes.

- [x] **Step 2: Add failing source integration contracts**

Extend `test_offline_rendering_behavior.ps1` to require:

- `beforeTrace(...)` occurs before `ensureOutput(...)` and `ensureWorld(...)`.
- The same local `offlineAccumulating` is passed to both ensure methods and
  `recordFrame`.
- `RtDlssRr.enabled()` and `RtDlssFg.enabled()` use
  `RtOfflineController.accumulating()`, not `Offline.ENABLED`.
- `ensureOutput` chooses FP32 and native resolution only from its accumulating
  argument.
- `ensureWorld` chooses the offline raygen only from its accumulating argument.
- Waiting frames cannot dispatch offline history or enable static-light NEE.
- Frozen water time and captured sky are used only while accumulating.

- [x] **Step 3: Run focused tests and verify RED**

Expected: source contract fails because pipeline selection still uses
`RtOfflineController.enabled()` and the decision is still computed after
resource selection.

- [x] **Step 4: Publish current accumulating state**

In `beforeTrace`, pass `System.nanoTime()` to the state machine and publish the
returned `decision.accumulate()` to a volatile field before returning. Reset
the field in `clientTick` session initialization and `endSession`.

- [x] **Step 5: Implement owned mid-session thaw**

When `cameraChanged` is true:

- Increment `freezeRequestGeneration`.
- Clear the current freeze-request-scheduled marker.
- If `freezeOwnership.ownsFreeze()` and no thaw is scheduled, mark thaw pending
  and enqueue `setFrozen(false)` on the integrated server.
- While thaw is pending, pass `false` as the effective frozen input to
  `accumulation.observe`.
- On successful thaw, call `freezeOwnership.clearWithoutRestore()` and clear
  thaw pending.
- On failure, retain ownership, clear thaw pending and log a warning so a
  later frame can retry.

Every freeze task captures `sessionToken` and `freezeRequestGeneration`; it
must return before reading or changing server freeze state if either value is
stale. A stale task must not clear a newer request marker.

- [x] **Step 6: Reorder frame decision and resource selection**

In `composite`:

1. Compute the offline decision first.
2. Derive `boolean offlineAccumulating`.
3. Call `ensureOutput(ctx, width, height, offlineAccumulating)`.
4. Refresh/create the matching pipeline with
   `ensureWorld(ctx, offlineAccumulating)`.
5. Pass the unchanged decision to `recordFrame`.

`ensureResourcesReady` uses `RtOfflineController.accumulating()` for early
pipeline creation.

- [x] **Step 7: Change temporal gates**

Both NVIDIA feature classes call:

```java
OfflineModePolicy.temporalFeatureEnabled(
        userPreference,
        RtOfflineController.accumulating());
```

Do not modify the stored user preference.

- [x] **Step 8: Remove waiting-phase offline presentation state**

Use `offlineAccumulating`, not merely non-null `offlineDecision`, for frozen
water time and frozen sky. On a movement frame, clear the captured offline sky
so the realtime path uses the live sky immediately.

- [x] **Step 9: Run focused tests and Java compilation**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_bounce_video_options.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_frame_generation_video_toggle.ps1
& '.\scripts\build_local.ps1' -SkipNative -GradleArgs @('compileJava')
```

All commands must exit zero.

---

### Task 3: Version 0.3.1, Documentation and Delivery

**Files:**

- Modify: `gradle.properties`
- Modify: `docs/PROJECT.md`
- Modify: `docs/CHANGELOG.md`
- Modify: `docs/BUGS.md`
- Modify: `docs/superpowers/plans/2026-07-28-offline-realtime-wait-and-auto-thaw.md`
- Create:
  `.superpowers/sdd/2026-07-28-offline-realtime-wait-and-auto-thaw/progress.md`
- Create:
  `.superpowers/sdd/2026-07-28-offline-realtime-wait-and-auto-thaw/task-3-report.md`

**Interfaces:**

- Produces `build/libs/caustica-0.3.1.jar`.
- Leaves all game instances untouched.

- [x] **Step 1: Change the single version source**

Change only:

```properties
mod_version=0.3.1
```

- [x] **Step 2: Update concise project records**

`PROJECT.md` records the two-second realtime wait, automatic owned thaw,
phase-driven RR/FG and pending game validation.

`CHANGELOG.md` records version 0.3.1 and the root-cause fix.

`BUGS.md` marks moving raw-noise presentation and three-frame delay resolved,
records the one-time mode-switch hitch as a known limitation, and keeps
glass/water blur open with its confirmed RR-guide cause.

- [x] **Step 3: Run every focused regression script**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_bounce_video_options.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_frame_generation_video_toggle.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_frame_stats_stage_contract.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test_local_build_environment.ps1
```

- [x] **Step 4: Run the complete native and Gradle build**

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build_local.ps1
```

- [x] **Step 5: Verify the deliverable**

For `caustica-0.3.1.jar`, record exact bytes, SHA-256, embedded
`fabric.mod.json` version, four world raygen SPIR-V resources and
`caustica/natives/windows-x64/ngxshim.dll`.

Verify `caustica-0.3.1-sources.jar` has Java sources and no `.class` files;
label it non-installable.

- [x] **Step 6: Write the modification report**

Record behavior, RED/GREEN evidence, build evidence, JAR identity, pending
game-test matrix, no Git operations and no game-instance copy.
