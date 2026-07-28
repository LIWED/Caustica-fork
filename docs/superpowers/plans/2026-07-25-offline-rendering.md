# Offline Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add native-resolution progressive HDR accumulation with automatic single-player tick freezing, multiplayer manual-freeze detection, live video settings, and sample-status HUD.

**Architecture:** A pure Java state machine decides when a camera is stable and whether a frame may accumulate. A client freeze controller owns integrated-server freeze/restore semantics, while a small Vulkan compute pipeline performs SPP-weighted averaging into an RGBA32F history image and resolves into the existing display path.

**Tech Stack:** Java 25, Minecraft 26.2, Fabric API, JOML, Vulkan 1.2/LWJGL, GLSL/SPIR-V, NightConfig TOML, PowerShell behavior and contract tests.

## Global Constraints

- Do not execute `git add`, `git commit`, `git push`, or create a commit.
- Offline Rendering temporarily suppresses DLSS-RR and Frame Generation without changing their saved preferences.
- Automatic tick freezing is limited to the integrated single-player server.
- Remote multiplayer must never receive an automatic command.
- Accumulation runs at native display resolution and uses an RGBA32F history image.
- Camera stability requires three consecutive stable render frames.
- Existing unrelated files and localization damage remain untouched.

---

## File Structure

- Create `src/main/java/dev/comfyfluffy/caustica/rt/offline/OfflineAccumulationState.java`: dependency-free stability/sample state machine.
- Create `src/main/java/dev/comfyfluffy/caustica/rt/offline/RtOfflineController.java`: config gate, camera comparison, server freeze ownership, render-signature resets, frozen sky/water state, and HUD snapshot.
- Create `src/main/java/dev/comfyfluffy/caustica/rt/pipeline/RtOfflineAccumulationPipeline.java`: Vulkan descriptors, compute pipeline, push constants, and dispatch.
- Create `shaders/display/offline_accumulate.comp`: weighted RGBA32F accumulation and RGBA16F resolve.
- Create `src/main/java/dev/comfyfluffy/caustica/rt/offline/OfflineModePolicy.java`: dependency-free temporal-feature and native-resolution policy.
- Create `src/main/java/dev/comfyfluffy/caustica/rt/offline/OfflineFreezeOwnership.java`: dependency-free freeze/restore ownership state.
- Create `src/main/java/dev/comfyfluffy/caustica/rt/offline/OfflineSampleWeights.java`: dependency-free Vulkan push-weight sanitization.
- Create `scripts/tests/OfflineRenderingBehaviorTest.java`: executable behavior tests without a test framework.
- Create `scripts/test_offline_rendering_behavior.ps1`: compiles and runs the offline behavior tests with Java 25.
- Modify `src/main/java/dev/comfyfluffy/caustica/CausticaConfig.java`: persisted Offline Rendering boolean.
- Modify `src/main/java/dev/comfyfluffy/caustica/client/RtVideoOptions.java`: live Offline Rendering option.
- Modify `src/main/java/dev/comfyfluffy/caustica/client/CausticaClient.java`: controller lifecycle and HUD registration.
- Modify `src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java`: native offline path, reset signatures, accumulation dispatch, frozen render inputs, and cleanup.
- Modify `src/main/java/dev/comfyfluffy/caustica/rt/pipeline/RtDlssRr.java`: effective offline suppression.
- Modify `src/main/java/dev/comfyfluffy/caustica/rt/pipeline/RtDlssFg.java`: effective offline suppression.
- Modify `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtTerrain.java`: monotonic published-scene revision.
- Modify `src/main/resources/assets/caustica/lang/en_us.json`: English option, tooltip, and HUD messages.
- Modify `src/main/resources/assets/caustica/lang/zh_cn.json`: Simplified Chinese option, tooltip, and HUD messages.

### Task 1: Offline State Machine

**Files:**

- Create: `src/main/java/dev/comfyfluffy/caustica/rt/offline/OfflineAccumulationState.java`
- Create: `scripts/tests/OfflineRenderingBehaviorTest.java`
- Create: `scripts/test_offline_rendering_behavior.ps1`

**Interfaces:**

- Produces: `OfflineAccumulationState.Phase`
- Produces: `OfflineAccumulationState.Decision`
- Produces: `Decision observe(boolean enabled, boolean cameraChanged, long renderSignature, boolean localAutoFreezeAvailable, boolean frozen, int spp)`
- Produces: `void clear()`, `long accumulatedSamples()`, and `Phase phase()`

- [x] **Step 1: Write the failing behavior test**

Create an executable test that verifies:

```java
OfflineAccumulationState state = new OfflineAccumulationState();

assert state.observe(true, true, 10L, true, false, 4).phase()
        == OfflineAccumulationState.Phase.HOLD_STILL;
assert state.observe(true, false, 10L, true, false, 4).phase()
        == OfflineAccumulationState.Phase.HOLD_STILL;
OfflineAccumulationState.Decision arm =
        state.observe(true, false, 10L, true, false, 4);
assert arm.phase() == OfflineAccumulationState.Phase.FREEZING;
assert arm.requestFreeze();

OfflineAccumulationState.Decision first =
        state.observe(true, false, 10L, true, true, 4);
assert first.accumulate() && first.resetHistory();
assert first.previousSamples() == 0L && first.currentSamples() == 4;
assert state.accumulatedSamples() == 4L;

OfflineAccumulationState.Decision second =
        state.observe(true, false, 10L, true, true, 8);
assert second.accumulate() && !second.resetHistory();
assert second.previousSamples() == 4L && second.currentSamples() == 8;
assert state.accumulatedSamples() == 12L;

OfflineAccumulationState.Decision moved =
        state.observe(true, true, 10L, true, true, 8);
assert !moved.accumulate() && moved.resetHistory();
assert state.accumulatedSamples() == 0L;

OfflineAccumulationState remote = new OfflineAccumulationState();
remote.observe(true, true, 10L, false, false, 1);
remote.observe(true, false, 10L, false, false, 1);
assert remote.observe(true, false, 10L, false, false, 1).phase()
        == OfflineAccumulationState.Phase.MANUAL_FREEZE_REQUIRED;

state.observe(true, false, 11L, true, true, 2);
assert state.accumulatedSamples() == 0L;
state.observe(false, false, 11L, true, true, 2);
assert state.phase() == OfflineAccumulationState.Phase.DISABLED;
```

- [x] **Step 2: Run the focused test and verify RED**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
```

Expected: non-zero exit because `OfflineAccumulationState.java` does not exist.

- [x] **Step 3: Implement the minimal state machine**

Implement:

```java
public final class OfflineAccumulationState {
    public static final int STABLE_FRAMES = 3;
    public enum Phase {
        DISABLED, HOLD_STILL, FREEZING, MANUAL_FREEZE_REQUIRED, ACCUMULATING
    }
    public record Decision(Phase phase, boolean requestFreeze,
                           boolean accumulate, boolean resetHistory,
                           long previousSamples, int currentSamples) {}
}
```

`observe(...)` resets on enable, camera change, or render-signature change;
requests local freezing after three stable observations; requires `frozen`
before accumulation; and adds sanitized `Math.max(1, spp)` to the sample total.

- [x] **Step 4: Run the focused test and verify GREEN**

Run the same PowerShell test.

Expected: exit code `0` and `Offline rendering behavior: PASS`.

- [x] **Step 5: Review checkpoint**

Inspect the diff for Task 1 and confirm it contains no Minecraft, Fabric, Vulkan,
or JOML dependency in `OfflineAccumulationState`.

### Task 2: Configuration, Effective DLSS Gates, and Video Option

**Files:**

- Create: `src/main/java/dev/comfyfluffy/caustica/rt/offline/OfflineModePolicy.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/CausticaConfig.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/client/RtVideoOptions.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/pipeline/RtDlssRr.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/pipeline/RtDlssFg.java`
- Modify: `src/main/resources/assets/caustica/lang/en_us.json`
- Modify: `src/main/resources/assets/caustica/lang/zh_cn.json`

**Interfaces:**

- Consumes: `CausticaConfig.BooleanSetting`
- Produces: `CausticaConfig.Rt.Offline.ENABLED`
- Produces: `RtOfflineController.enabled()`
- Produces: `private static OptionInstance<Boolean> offlineRendering()`
- Produces: `OfflineModePolicy.temporalFeatureEnabled(boolean preference, boolean offlineEnabled)`
- Produces: `OfflineModePolicy.nativeResolutionRequired(boolean offlineEnabled)`

- [x] **Step 1: Extend the failing behavior test**

Add assertions derived from the approved mutual-exclusion behavior:

```java
assert OfflineModePolicy.temporalFeatureEnabled(true, false);
assert !OfflineModePolicy.temporalFeatureEnabled(true, true);
assert !OfflineModePolicy.temporalFeatureEnabled(false, false);
assert OfflineModePolicy.nativeResolutionRequired(true);
assert !OfflineModePolicy.nativeResolutionRequired(false);
```

- [x] **Step 2: Run the behavior test and verify RED**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
```

Expected: non-zero exit because `OfflineModePolicy` is absent.

- [x] **Step 3: Implement the policy, persisted setting, and live option**

Add:

```java
public static final class Offline {
    public static final BooleanSetting ENABLED =
            bool("caustica.rt.offline", "offline.enabled", false);
    private Offline() {}
}
```

Add `offlineRendering()` before `dlssQuality()` and bind it with the existing
`bool(...)` helper.

- [x] **Step 4: Route effective DLSS suppression through the tested policy**

Make both runtime gates preserve preferences:

```java
return OfflineModePolicy.temporalFeatureEnabled(
        CausticaConfig.Rt.DlssRr.ENABLED.value(),
        RtOfflineController.enabled());
```

```java
return OfflineModePolicy.temporalFeatureEnabled(
        CausticaConfig.Rt.Fg.ENABLED.value(),
        RtOfflineController.enabled());
```

- [x] **Step 5: Add localized UI text**

Add caption, tooltip, and four HUD state messages in English and Simplified
Chinese, including the literal `/tick freeze` in the multiplayer message.

- [x] **Step 6: Run the behavior test and compile integration**

Run the behavior test, then:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_local.ps1 -Tasks compileJava
```

Expected: both commands exit `0`.

- [x] **Step 7: Review checkpoint**

Confirm no call sets either persisted DLSS setting to false when Offline
Rendering changes.

### Task 3: Automatic Single-Player Freeze and HUD State

**Files:**

- Create: `src/main/java/dev/comfyfluffy/caustica/rt/offline/RtOfflineController.java`
- Modify: `src/main/java/dev/comfyfluffy/caustica/client/CausticaClient.java`

**Interfaces:**

- Consumes: `OfflineAccumulationState.observe(...)`
- Consumes: `Minecraft.getSingleplayerServer()`
- Consumes: `Minecraft.level.tickRateManager().isFrozen()`
- Produces: `FrameDecision beforeTrace(Matrix4fc projection, Matrix4fc viewRotation, double x, double y, double z, long renderSignature, int spp)`
- Produces: `void clientTick(Minecraft client)`, `void shutdown()`
- Produces: `Component hudText()`, `long accumulatedSamples()`
- Produces: `float frozenWaterTime(float liveTime)`

- [x] **Step 1: Add failing freeze-ownership behavior tests**

Create `OfflineFreezeOwnership` tests:

```java
OfflineFreezeOwnership owned = new OfflineFreezeOwnership();
assert owned.onFreezeConfirmed(false);
assert owned.consumeRestoreRequired();
assert !owned.consumeRestoreRequired();

OfflineFreezeOwnership borrowed = new OfflineFreezeOwnership();
assert !borrowed.onFreezeConfirmed(true);
assert !borrowed.consumeRestoreRequired();
```

Run the behavior test and expect failure because `OfflineFreezeOwnership` is
absent.

- [x] **Step 2: Implement camera stability and frame decisions**

Copy the latest camera matrices and position into controller-owned state.
`beforeTrace(...)` computes `cameraChanged`, queries freeze state, calls
`OfflineAccumulationState.observe(...)`, and requests a local freeze exactly
once when `Decision.requestFreeze()` is true.

- [x] **Step 3: Implement freeze ownership and restoration**

On the integrated server thread:

```java
boolean alreadyFrozen = server.tickRateManager().isFrozen();
freezeOwnership.onFreezeConfirmed(alreadyFrozen);
server.tickRateManager().setFrozen(true);
freezeConfirmed = true;
```

On disable/shutdown, execute `setFrozen(false)` only when `ownsFreeze` is true
and the same integrated server is still alive. Clear ownership after scheduling
the restore so repeated ticks cannot unfreeze twice.

- [x] **Step 4: Freeze render-local time inputs**

On the first confirmed frozen frame, capture the supplied water time. Keep it
until Offline Rendering is disabled. Expose whether the caller should capture
and reuse its `SkyPush`.

- [x] **Step 5: Register the HUD element**

Use:

```java
HudElementRegistry.attachElementAfter(
        VanillaHudElements.MISC_OVERLAYS,
        Identifier.fromNamespaceAndPath("caustica", "offline_status"),
        (graphics, deltaTracker) -> {
            Component text = RtOfflineController.INSTANCE.hudText();
            if (text != null) {
                graphics.text(client.font, text, 4, 4, 0xFFFFFFFF, true);
            }
        });
```

Call `clientTick(client)` from `START_CLIENT_TICK` and `shutdown()` before RT
teardown.

- [x] **Step 6: Run focused behavior test and compile integration**

Run the behavior test and `build_local.ps1 -Tasks compileJava`.

Expected: both commands exit `0`.

- [x] **Step 7: Review checkpoint**

Confirm the controller never sends chat text or a command packet and never
touches a remote `MinecraftServer`.

### Task 4: Terrain Scene Revision

**Files:**

- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtTerrain.java`

**Interfaces:**

- Produces: `public long sceneRevision()`

- [x] **Step 1: Add the scene revision and its consumer in one compile-checked change**

Add a monotonic `sceneRevision` field, public getter, and an increment from
`applyBuildChanges(...)` whenever prepared sections, removed sections, or a
rebase changes the published traced scene.

- [x] **Step 2: Compile the integration**

Run `build_local.ps1 -Tasks compileJava`.

Expected: exit code `0`. The consumer must call `sceneRevision()`, so deleting
or renaming the getter breaks compilation.

- [x] **Step 3: Review checkpoint**

Confirm the revision increments after changes are applied and does not increment
on an unchanged streaming pass.

### Task 5: Vulkan HDR Accumulation Pipeline

**Files:**

- Create: `shaders/display/offline_accumulate.comp`
- Create: `src/main/java/dev/comfyfluffy/caustica/rt/pipeline/RtOfflineAccumulationPipeline.java`
- Create: `src/main/java/dev/comfyfluffy/caustica/rt/offline/OfflineSampleWeights.java`

**Interfaces:**

- Produces: `RtOfflineAccumulationPipeline.create(RtContext ctx)`
- Produces: `void setImages(long currentView, long historyView, long resolvedView)`
- Produces: `void dispatch(VkCommandBuffer cmd, int width, int height, long previousSamples, int currentSamples, boolean reset)`
- Produces: `void destroy()`

- [x] **Step 1: Add failing sample-weight behavior tests**

Assert that current samples clamp to at least one and previous samples clamp to
`16_777_208L`, including zero, negative, normal, and oversized inputs.

- [x] **Step 2: Run the behavior test and verify RED**

Expected: failure because `OfflineSampleWeights` is absent.

- [x] **Step 3: Implement sample weights and the compute shader**

Use:

```glsl
#version 450
layout(local_size_x = 16, local_size_y = 16) in;
layout(binding = 0, rgba16f) uniform readonly image2D currentImage;
layout(binding = 1, rgba32f) uniform image2D historyImage;
layout(binding = 2, rgba16f) uniform writeonly image2D resolvedImage;
layout(push_constant) uniform Push {
    uint previousSamples;
    uint currentSamples;
    uint resetHistory;
} pc;

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    if (any(greaterThanEqual(pixel, imageSize(currentImage)))) return;
    vec4 current = imageLoad(currentImage, pixel);
    uint previous = pc.resetHistory != 0u ? 0u : pc.previousSamples;
    float total = float(previous + pc.currentSamples);
    vec4 average = previous == 0u
            ? current
            : (imageLoad(historyImage, pixel) * float(previous)
                    + current * float(pc.currentSamples)) / total;
    imageStore(historyImage, pixel, average);
    imageStore(resolvedImage, pixel, average);
}
```

- [x] **Step 4: Implement the Vulkan wrapper**

Follow `RtDisplayPipeline` ownership and debug-label conventions with three
storage-image descriptors and 12 push-constant bytes. Use the tested
`OfflineSampleWeights` sanitizer before writing push constants.

- [x] **Step 5: Compile and validate shaders**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_local.ps1 -Tasks compileShaders
```

Expected: shader compiler and `spirv-val` exit `0`, and
`build/generated/shaders/caustica/rt/offline_accumulate.comp.spv` exists.

- [x] **Step 6: Run behavior tests and compile Java integration**

Expected: the behavior test and `build_local.ps1 -Tasks compileJava` exit `0`.

- [x] **Step 7: Review checkpoint**

Confirm every pixel reads and writes only its own history texel and the command
barrier after the ray trace makes the current trace visible to compute.

### Task 6: Composite Integration and Cleanup

**Files:**

- Modify: `src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java`

**Interfaces:**

- Consumes: `RtOfflineController.beforeTrace(...)`
- Consumes: `RtOfflineAccumulationPipeline`
- Consumes: `RtTerrain.sceneRevision()`
- Produces: the existing `rrOutput` as either DLSS-RR, fallback, or offline accumulated output.

- [x] **Step 1: Add failing render-signature behavior tests**

Create a dependency-free signature builder and assert:

```java
long base = OfflineRenderSignature.create(1920, 1080, 7L, 0, 4,
        true, true, true, true, 1, 2);
assert base == OfflineRenderSignature.create(1920, 1080, 7L, 0, 4,
        true, true, true, true, 1, 2);
assert base != OfflineRenderSignature.create(1280, 720, 7L, 0, 4,
        true, true, true, true, 1, 2);
assert base != OfflineRenderSignature.create(1920, 1080, 8L, 0, 4,
        true, true, true, true, 1, 2);
```

- [x] **Step 2: Run the behavior test and verify RED**

Expected: failure because `OfflineRenderSignature` is absent.

- [x] **Step 3: Allocate and bind offline resources**

Lazily create:

```java
offlineHistory = ctx.createStorageImage(
        width, height, VK10.VK_FORMAT_R32G32B32A32_SFLOAT,
        "offline accumulation " + width + "x" + height);
offlinePipeline = RtOfflineAccumulationPipeline.create(ctx);
offlinePipeline.setImages(output.view, offlineHistory.view, rrOutput.view);
```

Rebind after any output resize. Destroy the history in the sized-image cleanup
and destroy the pipeline in `destroy()`.

- [x] **Step 4: Build the reset signature and freeze inputs**

Call the controller after terrain streaming and camera capture are valid. Hash
all traced-radiance settings except SPP. When freeze becomes confirmed, cache
the current `SkyPush` and water animation time; clear caches when Offline
Rendering turns off or the world changes.

- [x] **Step 5: Select the offline output path**

After `active.trace(...)` and its memory barrier:

```java
if (offlineDecision.accumulate()) {
    offlinePipeline.dispatch(cmd, displayW, displayH,
            offlineDecision.previousSamples(),
            offlineDecision.currentSamples(),
            offlineDecision.resetHistory());
    offlineDone = true;
}
```

Skip DLSS-RR whenever Offline Rendering is enabled. If `offlineDone` is false,
perform the existing 1:1 fallback blit so movement and waiting states remain
visible.

- [x] **Step 6: Make cleanup restore the tick state**

Call `RtOfflineController.INSTANCE.shutdown()` from client shutdown and any
runtime RT teardown path before GPU resources are destroyed.

- [x] **Step 7: Run all focused tests**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test_offline_rendering_behavior.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\test_frame_generation_video_toggle.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\test_local_build_environment.ps1
```

Expected: all three exit `0`.

- [x] **Step 8: Run the complete build**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_local.ps1
```

Expected: exit `0`, shader validation succeeds, Java compilation succeeds,
native NGX shim succeeds, and `build/libs/caustica-0.1.0.jar` is produced.

- [x] **Step 9: Inspect the final diff without committing**

Run read-only status/diff checks. Verify only the planned Caustica files changed,
no file under `F:\mygit\learning` changed, and no Git index or commit operation
was performed.
