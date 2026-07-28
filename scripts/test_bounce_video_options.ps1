[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $projectRoot 'src\main\java\dev\comfyfluffy\caustica\CausticaConfig.java'
$optionsPath = Join-Path $projectRoot 'src\main\java\dev\comfyfluffy\caustica\client\RtVideoOptions.java'
$compositePath = Join-Path $projectRoot 'src\main\java\dev\comfyfluffy\caustica\rt\RtComposite.java'
$localeRoot = Join-Path $projectRoot 'src\main\resources\assets\caustica\lang'

function Assert-Match {
    param([string] $Text, [string] $Pattern, [string] $Message)
    if (-not [regex]::IsMatch(
            $Text,
            $Pattern,
            [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
        throw $Message
    }
}

$config = Get-Content -Raw -Encoding utf8 -LiteralPath $configPath
$options = Get-Content -Raw -Encoding utf8 -LiteralPath $optionsPath
$composite = Get-Content -Raw -Encoding utf8 -LiteralPath $compositePath

Assert-Match $config `
    'MAX_BOUNCES\s*=\s*clampedInt\("caustica\.rt\.maxBounces",\s*"composite\.max-bounces",\s*4,\s*2,\s*16\)' `
    'Realtime bounce configuration must be caustica.rt.maxBounces/composite.max-bounces, default 4, range 2..16.'
Assert-Match $config `
    'class Offline.*?MAX_BOUNCES\s*=\s*clampedInt\("caustica\.rt\.offline\.maxBounces",\s*"offline\.max-bounces",\s*8,\s*2,\s*32\)' `
    'Offline bounce configuration must be caustica.rt.offline.maxBounces/offline.max-bounces, default 8, range 2..32.'
Assert-Match $config `
    'ensureRegistered\(\).*?Rt\.Offline\.ENABLED.*?Rt\.Offline\.MAX_BOUNCES' `
    'Offline max bounces must be registered for config persistence.'

Assert-Match $options `
    'maxBounces\(\),\s*offlineMaxBounces\(\),' `
    'Realtime and offline bounce controls must be adjacent in the Video Settings list.'
Assert-Match $options `
    'maxBounces\(\).*?Rt\.Composite\.MAX_BOUNCES.*?new OptionInstance\.IntRange\(2,\s*16\).*?Math\.clamp\(setting\.value\(\),\s*2,\s*16\)' `
    'Realtime Video Settings control must bind the 2..16 realtime setting.'
Assert-Match $options `
    'offlineMaxBounces\(\).*?Rt\.Offline\.MAX_BOUNCES.*?new OptionInstance\.IntRange\(2,\s*32\).*?Math\.clamp\(setting\.value\(\),\s*2,\s*32\)' `
    'Offline Video Settings control must bind the 2..32 offline setting.'

Assert-Match $composite `
    'PathBouncePolicy\.effective\(\s*offlineAccumulating,\s*realtimeMaxBounces\(\),\s*offlineMaxBounces\(\)\s*\)' `
    'The renderer must select offline bounces only while it is truly accumulating.'
Assert-Match $composite `
    'OfflineRenderSignature\.create\(.*?offlineMaxBounces\(\)' `
    'Offline history signature must include the offline bounce setting.'

$requiredKeys = @(
    'caustica.options.rt.maxBounces',
    'caustica.options.rt.maxBounces.tooltip',
    'caustica.options.rt.offlineMaxBounces',
    'caustica.options.rt.offlineMaxBounces.tooltip'
)
foreach ($localePath in Get-ChildItem -LiteralPath $localeRoot -Filter '*.json') {
    $locale = Get-Content -Raw -Encoding utf8 -LiteralPath $localePath.FullName | ConvertFrom-Json
    foreach ($key in $requiredKeys) {
        $property = $locale.PSObject.Properties[$key]
        if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string] $property.Value)) {
            throw "Missing or empty localization key '$key' in '$($localePath.Name)'."
        }
    }
}

$english = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $localeRoot 'en_us.json') | ConvertFrom-Json
$chinese = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $localeRoot 'zh_cn.json') | ConvertFrom-Json
if ($english.'caustica.options.rt.spp.tooltip' -notmatch '(?i)offline' -or
        $english.'caustica.options.rt.spp.tooltip' -notmatch '(?i)batch' -or
        $english.'caustica.options.rt.spp.tooltip' -notmatch '(?i)total samples') {
    throw 'English SPP tooltip must explain the offline per-frame batch and total-sample behavior.'
}
if ($chinese.'caustica.options.rt.spp.tooltip' -notmatch '\u79bb\u7ebf' -or
        $chinese.'caustica.options.rt.spp.tooltip' -notmatch '\u6bcf\u5e27' -or
        $chinese.'caustica.options.rt.spp.tooltip' -notmatch '\u6279\u91cf' -or
        $chinese.'caustica.options.rt.spp.tooltip' -notmatch '\u603b\u6837\u672c') {
    throw 'Chinese SPP tooltip must explain the offline per-frame batch and total-sample behavior.'
}

Write-Output 'Bounce video options contract: PASS'
