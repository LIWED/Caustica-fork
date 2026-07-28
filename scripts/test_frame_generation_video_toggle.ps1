$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$optionsPath = Join-Path $repoRoot "src\main\java\dev\comfyfluffy\caustica\client\RtVideoOptions.java"
$englishPath = Join-Path $repoRoot "src\main\resources\assets\caustica\lang\en_us.json"
$chinesePath = Join-Path $repoRoot "src\main\resources\assets\caustica\lang\zh_cn.json"

function Assert-True {
    param(
        [bool] $Condition,
        [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$optionsSource = Get-Content -LiteralPath $optionsPath -Raw -Encoding utf8
$singleline = [System.Text.RegularExpressions.RegexOptions]::Singleline

Assert-True ([regex]::IsMatch(
        $optionsSource,
        "dlssQuality\(\),\s*frameGeneration\(\),\s*hdrEnabled\(\),",
        $singleline)) `
    "frameGeneration() must appear immediately after dlssQuality() in runtimeOptions()."

Assert-True ([regex]::IsMatch(
        $optionsSource,
        'private\s+static\s+OptionInstance<Boolean>\s+frameGeneration\(\)\s*\{\s*return\s+bool\(\s*"caustica\.options\.rt\.frameGeneration"\s*,\s*CausticaConfig\.Rt\.Fg\.ENABLED\s*\);\s*\}',
        $singleline)) `
    "frameGeneration() must bind caustica.options.rt.frameGeneration to CausticaConfig.Rt.Fg.ENABLED."

Assert-True (-not $optionsSource.Contains("MULTI_FRAME_COUNT")) `
    "The Video Settings UI must not expose the unstable multi-frame generation count."

$requiredKeys = @(
    "caustica.options.rt.frameGeneration",
    "caustica.options.rt.frameGeneration.tooltip"
)

foreach ($localePath in @($englishPath, $chinesePath)) {
    $locale = Get-Content -LiteralPath $localePath -Raw -Encoding utf8 | ConvertFrom-Json
    foreach ($key in $requiredKeys) {
        $property = $locale.PSObject.Properties[$key]
        Assert-True ($null -ne $property) "Missing localization key '$key' in '$localePath'."
        Assert-True (-not [string]::IsNullOrWhiteSpace([string] $property.Value)) `
            "Localization key '$key' is empty in '$localePath'."
    }
}

Write-Output "Frame Generation video toggle contract: PASS"
