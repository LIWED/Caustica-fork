$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)]
        [bool] $Condition,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$buildScript = Join-Path $PSScriptRoot 'build_local.ps1'
Assert-Condition (Test-Path -LiteralPath $buildScript -PathType Leaf) "Expected build script at: $buildScript"

$result = & $buildScript -CheckOnly
Assert-Condition ($null -ne $result) 'CheckOnly did not return an environment result.'
Assert-Condition ($result.JavaMajorVersion -eq 25) "Expected Java 25, got $($result.JavaMajorVersion)."
Assert-Condition ($result.PathVariableCount -eq 1) "Expected one Path variable, got $($result.PathVariableCount)."
Assert-Condition $result.VulkanSdkExists "Vulkan SDK was not found at $($result.VulkanSdk)."
Assert-Condition $result.DlssSdkExists "DLSS SDK was not found at $($result.DlssSdk)."
Assert-Condition $result.LocalGradleExists "Local Gradle was not found at $($result.LocalGradle)."
Assert-Condition $result.CMakeExists "CMake was not found at $($result.CMake)."

Write-Host 'Local build environment contract: PASS'
