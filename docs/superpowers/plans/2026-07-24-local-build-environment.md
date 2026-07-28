# Local Build Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one reproducible Windows PowerShell entry point that builds the NGX shim and Caustica JAR using the already installed project-local SDKs and Gradle distribution.

**Architecture:** `scripts/build_local.ps1` resolves every dependency from the project or the Visual Studio installation, repairs the inherited duplicate `PATH`/`Path` variables inside its own process, then runs CMake and Gradle. A separate PowerShell contract test exercises the non-building `-CheckOnly` path before the full build is attempted.

**Tech Stack:** Windows PowerShell 5.1, Java 25, Visual Studio 2022 Build Tools, CMake, Vulkan SDK 1.4.350.0, DLSS SDK 310.7.0, Gradle 9.5.0.

## Global Constraints

- Do not install or download anything from the script.
- Do not persist user or machine environment variables.
- Do not stage, commit, or push files.
- Default Gradle invocation is `build --no-daemon`.
- Generated toolchain and cache directories must stay out of Git status.

---

### Task 1: Environment validation contract

**Files:**
- Create: `scripts/test_local_build_environment.ps1`
- Test: `scripts/test_local_build_environment.ps1`

**Interfaces:**
- Consumes: `scripts/build_local.ps1 -CheckOnly`
- Produces: assertions for Java 25, required local paths, and exactly one process Path variable

- [ ] **Step 1: Write the failing test**

Create a PowerShell test that requires `scripts/build_local.ps1`, invokes it with `-CheckOnly`, and asserts:

```powershell
$result.JavaMajorVersion -eq 25
$result.PathVariableCount -eq 1
$result.VulkanSdkExists
$result.DlssSdkExists
$result.LocalGradleExists
$result.CMakeExists
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```powershell
.\scripts\test_local_build_environment.ps1
```

Expected: FAIL because `scripts/build_local.ps1` does not exist.

### Task 2: Local build entry point

**Files:**
- Create: `scripts/build_local.ps1`
- Modify: `.gitignore`
- Test: `scripts/test_local_build_environment.ps1`

**Interfaces:**
- Consumes: `-CheckOnly`, `-SkipNative`, and `-GradleArgs <string[]>`
- Produces: a check result object or a completed native/Gradle build

- [ ] **Step 1: Implement dependency discovery**

Resolve the repository from `$PSScriptRoot`, discover Java from a valid `JAVA_HOME` or `Get-Command java`, locate Visual Studio with `vswhere.exe`, and validate the fixed project-local Vulkan, DLSS, and Gradle paths.

- [ ] **Step 2: Implement process-only Path repair**

Preserve the current Path value, remove both possible case variants twice, and create a single `Path` containing Java, Vulkan, and CMake:

```powershell
[Environment]::SetEnvironmentVariable('PATH', $null, 'Process')
[Environment]::SetEnvironmentVariable('Path', $null, 'Process')
[Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'Process')
```

- [ ] **Step 3: Implement check and build modes**

`-CheckOnly` returns the validated environment object. Normal mode configures and builds `native/ngx_shim`, then invokes the local Gradle distribution. `-SkipNative` requires the existing `ngxshim.dll`.

- [ ] **Step 4: Ignore generated local dependencies**

Append these root-relative entries to `.gitignore`:

```gitignore
/.toolchain/
/.toolchain-downloads/
/.gradle-user-home/
```

- [ ] **Step 5: Run test to verify it passes**

Run:

```powershell
.\scripts\test_local_build_environment.ps1
```

Expected: PASS with Java 25 and one Path variable.

### Task 3: End-to-end verification

**Files:**
- Verify: `scripts/build_local.ps1`
- Verify: `build/native/ngx_shim/release/ngxshim.dll`
- Verify: `build/libs/*.jar`

**Interfaces:**
- Consumes: the completed build script
- Produces: a verified native shim and JAR

- [ ] **Step 1: Run focused feature contract**

```powershell
.\scripts\test_frame_generation_video_toggle.ps1
```

Expected: `Frame Generation video toggle contract: PASS`.

- [ ] **Step 2: Run the complete local build**

```powershell
.\scripts\build_local.ps1
```

Expected: CMake and Gradle both succeed.

- [ ] **Step 3: Verify artifacts**

Confirm `ngxshim.dll` and at least one non-source JAR exist, then report their full paths and sizes.

No commit step is included because the user explicitly prohibited commits until requested.
