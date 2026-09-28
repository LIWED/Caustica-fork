[CmdletBinding()]
param(
    [switch] $CheckOnly,
    [switch] $SkipNative,
    [switch] $SkipDeploy,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $GradleArgs = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Test-ShouldDeploy {
    param([string[]] $Arguments)

    $packagingRequested = $false
    $valueOptions = @('-P', '--project-prop', '-D', '--system-prop', '-g', '--gradle-user-home', '-I', '--init-script', '--include-build', '--console', '--warning-mode', '--max-workers', '--priority', '--project-cache-dir', '--configuration-cache-problems', '--dependency-verification', '--write-verification-metadata')
    for ($index = 0; $index -lt $Arguments.Count; $index++) {
        $argument = $Arguments[$index]
        if ($argument -in @('--dry-run', '-m', '--help', '-h', '-?', '--version', '-v')) { return $false }
        # A different project/build definition cannot establish that this project's JAR was built.
        if ($argument -cmatch '^(?:-p|-c|-b)(?:.*)$|^--(?:project-dir|settings-file|build-file)(?:=|$)') { return $false }
        if ($argument -in @('-x', '--exclude-task') -or $argument.StartsWith('--exclude-task=') -or $argument.StartsWith('-x')) {
            if ($argument.StartsWith('--exclude-task=')) { $excluded = $argument.Substring('--exclude-task='.Length) }
            elseif ($argument.StartsWith('-x') -and $argument.Length -gt 2) { $excluded = $argument.Substring(2) }
            else {
                $index++
                if ($index -ge $Arguments.Count) { return $false }
                $excluded = $Arguments[$index]
            }
            if (($excluded -split ':')[-1] -in @('build', 'assemble', 'jar')) { return $false }
            continue
        }
        if ($argument -cin $valueOptions) { $index++; continue }
        if ($argument.StartsWith('-')) { continue }
        if ($argument -cin @('build', 'assemble', 'jar', ':build', ':assemble', ':jar')) { $packagingRequested = $true }
    }
    return $packagingRequested
}

function Require-Path {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Description,

        [ValidateSet('Any', 'Container', 'Leaf')]
        [string] $PathType = 'Any'
    )

    $exists = switch ($PathType) {
        'Container' { Test-Path -LiteralPath $Path -PathType Container }
        'Leaf' { Test-Path -LiteralPath $Path -PathType Leaf }
        default { Test-Path -LiteralPath $Path }
    }

    if (-not $exists) {
        throw "$Description was not found at: $Path"
    }
}

function Resolve-Java {
    $candidateHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Process')
    if (-not [string]::IsNullOrWhiteSpace($candidateHome)) {
        $candidateJava = Join-Path $candidateHome 'bin\java.exe'
        if (Test-Path -LiteralPath $candidateJava -PathType Leaf) {
            return [PSCustomObject]@{
                Home = (Resolve-Path -LiteralPath $candidateHome).Path
                Java = (Resolve-Path -LiteralPath $candidateJava).Path
            }
        }
    }

    $javaCommand = Get-Command java.exe -ErrorAction Stop
    $javaPath = $javaCommand.Source
    $javaHome = Split-Path -Parent (Split-Path -Parent $javaPath)

    return [PSCustomObject]@{
        Home = (Resolve-Path -LiteralPath $javaHome).Path
        Java = (Resolve-Path -LiteralPath $javaPath).Path
    }
}

function Reset-ProcessPath {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Prepend
    )

    $originalPath = [Environment]::GetEnvironmentVariable('Path', 'Process')
    if ([string]::IsNullOrWhiteSpace($originalPath)) {
        $originalPath = [Environment]::GetEnvironmentVariable('PATH', 'Process')
    }

    $ordered = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($Prepend) + @($originalPath -split ';')) {
        if (-not [string]::IsNullOrWhiteSpace($entry) -and $seen.Add($entry)) {
            $ordered.Add($entry)
        }
    }

    [Environment]::SetEnvironmentVariable('PATH', $null, 'Process')
    [Environment]::SetEnvironmentVariable('Path', $null, 'Process')
    [Environment]::SetEnvironmentVariable('Path', ($ordered -join ';'), 'Process')
}

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$java = Resolve-Java
$previousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $javaVersionText = (& $java.Java -version 2>&1 | Out-String)
    $javaVersionExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}

if ($javaVersionExitCode -ne 0) {
    throw "Java version check failed with exit code ${javaVersionExitCode}: $javaVersionText"
}

if ($javaVersionText -notmatch 'version\s+"(?<major>\d+)') {
    throw "Unable to parse Java version from: $javaVersionText"
}

$javaMajorVersion = [int] $Matches.major
if ($javaMajorVersion -ne 25) {
    throw "Caustica requires Java 25, but Java $javaMajorVersion was found at: $($java.Java)"
}

$vulkanSdk = Join-Path $projectRoot '.toolchain\VulkanSDK\1.4.350.0'
$dlssSdk = Join-Path $projectRoot 'third_party\DLSS'
$localGradle = Join-Path $projectRoot '.toolchain\gradle\gradle-9.5.0\bin\gradle.bat'
$gradleUserHome = Join-Path $projectRoot '.gradle-user-home'

Require-Path $vulkanSdk 'Vulkan SDK 1.4.350.0' 'Container'
Require-Path (Join-Path $vulkanSdk 'Bin\glslangValidator.exe') 'glslangValidator' 'Leaf'
Require-Path (Join-Path $vulkanSdk 'Bin\slangc.exe') 'slangc' 'Leaf'
Require-Path (Join-Path $vulkanSdk 'Bin\spirv-val.exe') 'spirv-val' 'Leaf'
Require-Path $dlssSdk 'DLSS SDK' 'Container'
Require-Path (Join-Path $dlssSdk 'include\nvsdk_ngx.h') 'DLSS SDK header' 'Leaf'
Require-Path (Join-Path $dlssSdk 'lib\Windows_x86_64\x64\nvsdk_ngx_d.lib') 'DLSS SDK Windows library' 'Leaf'
Require-Path $localGradle 'Gradle 9.5.0' 'Leaf'

$programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)', 'Process')
$vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
Require-Path $vswhere 'Visual Studio Installer vswhere' 'Leaf'

$visualStudioPath = (& $vswhere `
    -products Microsoft.VisualStudio.Product.BuildTools `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($visualStudioPath)) {
    throw 'Visual Studio 2022 Build Tools with MSVC x64/x86 was not found.'
}

$visualStudioPath = $visualStudioPath.Trim()
$cmake = Join-Path $visualStudioPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
Require-Path $cmake 'Visual Studio CMake' 'Leaf'

[Environment]::SetEnvironmentVariable('JAVA_HOME', $java.Home, 'Process')
[Environment]::SetEnvironmentVariable('VULKAN_SDK', $vulkanSdk, 'Process')
[Environment]::SetEnvironmentVariable('VK_SDK_PATH', $vulkanSdk, 'Process')
[Environment]::SetEnvironmentVariable('DLSS_SDK', $dlssSdk, 'Process')
[Environment]::SetEnvironmentVariable('GRADLE_USER_HOME', $gradleUserHome, 'Process')

Reset-ProcessPath @(
    (Join-Path $java.Home 'bin'),
    (Join-Path $vulkanSdk 'Bin'),
    (Split-Path -Parent $cmake)
)

$pathVariableCount = @(
    cmd.exe /d /c set |
        Where-Object { $_ -cmatch '^(Path|PATH)=' }
).Count

$environmentResult = [PSCustomObject]@{
    ProjectRoot = $projectRoot
    JavaHome = $java.Home
    JavaMajorVersion = $javaMajorVersion
    VulkanSdk = $vulkanSdk
    VulkanSdkExists = Test-Path -LiteralPath $vulkanSdk -PathType Container
    DlssSdk = $dlssSdk
    DlssSdkExists = Test-Path -LiteralPath $dlssSdk -PathType Container
    LocalGradle = $localGradle
    LocalGradleExists = Test-Path -LiteralPath $localGradle -PathType Leaf
    CMake = $cmake
    CMakeExists = Test-Path -LiteralPath $cmake -PathType Leaf
    PathVariableCount = $pathVariableCount
}

if ($CheckOnly) {
    return $environmentResult
}

if ($pathVariableCount -ne 1) {
    throw "Expected one process Path variable after normalization, found $pathVariableCount."
}

$nativeBuildDirectory = Join-Path $projectRoot 'build\cmake\ngx_shim-vs2022'
$nativeLibrary = Join-Path $projectRoot 'build\native\ngx_shim\release\ngxshim.dll'
$effectiveGradleArgs = @($GradleArgs)
if ($effectiveGradleArgs.Count -eq 0) {
    $effectiveGradleArgs = @('build', '--no-daemon')
}
elseif ($effectiveGradleArgs -notcontains '--no-daemon') {
    $effectiveGradleArgs += '--no-daemon'
}

Push-Location $projectRoot
try {
    if ($SkipNative) {
        Require-Path $nativeLibrary 'Prebuilt NGX shim' 'Leaf'
    }
    else {
        Write-Host 'Configuring NGX shim...'
        & $cmake `
            -S 'native/ngx_shim' `
            -B $nativeBuildDirectory `
            -G 'Visual Studio 17 2022' `
            -A x64
        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }

        Write-Host 'Building NGX shim...'
        & $cmake --build $nativeBuildDirectory --config Release
        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
    }

    Write-Host "Running Gradle $($effectiveGradleArgs -join ' ')..."
    & $localGradle @effectiveGradleArgs
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    if (-not $SkipDeploy -and (Test-ShouldDeploy -Arguments $effectiveGradleArgs)) {
        Write-Host 'Deploying Caustica to the test Minecraft mods directory...'
        & (Join-Path $PSScriptRoot 'deploy_test_mod.ps1')
    }
}
finally {
    Pop-Location
}
