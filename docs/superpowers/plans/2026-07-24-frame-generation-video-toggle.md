# Frame Generation Video Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an immediately applied 2x DLSS Frame Generation boolean to Caustica's existing Ray Tracing section in Minecraft Video Settings.

**Architecture:** Reuse `RtVideoOptions` and its existing boolean-setting adapter. Bind the new widget directly to `CausticaConfig.Rt.Fg.ENABLED`; existing per-frame FG checks provide immediate behavior and the existing screen-removal hook persists the setting.

**Tech Stack:** Java 25, Fabric/Mixin, Minecraft `OptionInstance`, NightConfig TOML, PowerShell contract test.

## Global Constraints

- Do not execute `git add`, `git commit`, or push.
- Expose only an enabled/disabled switch; do not expose `MULTI_FRAME_COUNT`.
- The supported mode is 2x: one generated frame per real frame.
- Do not implement offline rendering in this change.
- Do not repair unrelated existing Simplified Chinese localization corruption.
- Do not claim Gradle test/build verification until the Vulkan, shader, CMake, and DLSS SDK environment is configured.

---

## File Structure

- Create `scripts/test_frame_generation_video_toggle.ps1`: focused source/resource contract test runnable without the native Caustica build toolchain.
- Modify `src/main/java/dev/comfyfluffy/caustica/client/RtVideoOptions.java`: add and order the FG boolean widget.
- Modify `src/main/resources/assets/caustica/lang/en_us.json`: add English caption and tooltip.
- Modify `src/main/resources/assets/caustica/lang/zh_cn.json`: add only the two new Simplified Chinese entries.

### Task 1: Frame Generation Video Option

**Files:**

- Create: `scripts/test_frame_generation_video_toggle.ps1`
- Modify: `src/main/java/dev/comfyfluffy/caustica/client/RtVideoOptions.java`
- Modify: `src/main/resources/assets/caustica/lang/en_us.json`
- Modify: `src/main/resources/assets/caustica/lang/zh_cn.json`

**Interfaces:**

- Consumes: `CausticaConfig.Rt.Fg.ENABLED`, `RtVideoOptions.bool(String, BooleanSetting)`
- Produces: `private static OptionInstance<Boolean> frameGeneration()` and translation keys `caustica.options.rt.frameGeneration[.tooltip]`

- [x] **Step 1: Write the failing contract test**

Create a PowerShell test that:

1. loads `RtVideoOptions.java`;
2. requires `frameGeneration(),` immediately after `dlssQuality(),`;
3. requires the method to bind `caustica.options.rt.frameGeneration` to `CausticaConfig.Rt.Fg.ENABLED`;
4. parses both localization JSON files;
5. requires a non-empty caption and tooltip in both locales;
6. fails if `MULTI_FRAME_COUNT` appears in `RtVideoOptions.java`.

- [x] **Step 2: Run the focused test and verify RED**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test_frame_generation_video_toggle.ps1
```

Expected: non-zero exit with a message that `frameGeneration()` is missing from the runtime option order.

- [x] **Step 3: Add the minimal Java option**

Insert:

```java
dlssQuality(),
frameGeneration(),
hdrEnabled(),
```

Add:

```java
private static OptionInstance<Boolean> frameGeneration() {
    return bool("caustica.options.rt.frameGeneration", CausticaConfig.Rt.Fg.ENABLED);
}
```

Do not reference `MULTI_FRAME_COUNT`.

- [x] **Step 4: Add English and Simplified Chinese text**

Add these English meanings:

```text
Frame Generation
Inserts one generated frame between rendered frames (2x). Requires a supported NVIDIA RTX GPU and driver. Higher multipliers are not exposed because they are currently unstable. Cannot be used with Offline Rendering.
```

Add equivalent Simplified Chinese text describing 2x-only support, RTX/driver requirements, unstable higher multipliers, and future offline-rendering incompatibility.

- [x] **Step 5: Run the focused test and verify GREEN**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test_frame_generation_video_toggle.ps1
```

Expected: exit code `0` and `Frame Generation video toggle contract: PASS`.

- [x] **Step 6: Perform available static verification**

Run:

```powershell
java -version
Get-Content .\src\main\resources\assets\caustica\lang\en_us.json -Raw | ConvertFrom-Json | Out-Null
Get-Content .\src\main\resources\assets\caustica\lang\zh_cn.json -Raw | ConvertFrom-Json | Out-Null
```

Expected: Java 25 and both JSON parses succeed.

- [ ] **Step 7: Record deferred build verification**

After the native build environment is configured, run:

```powershell
$env:GRADLE_USER_HOME = "$PWD\.gradle-user-home"
.\gradlew.bat test
.\gradlew.bat build
```

Expected later: both commands exit `0`. Until then report them as not run or blocked, never as passing.
