[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $projectRoot 'src\main\java'
$statsSource = Join-Path $sourceRoot 'dev\comfyfluffy\caustica\rt\RtFrameStats.java'
$statsText = Get-Content -Raw -LiteralPath $statsSource
$frameMatch = [regex]::Match(
        $statsText,
        'public static final Profile FRAME = new Profile\("frame",\s*new String\[\] \{(?<stages>.*?)\},\s*new String\[\]',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)

if (-not $frameMatch.Success) {
    throw 'Could not extract the RtFrameStats.FRAME stage-name array.'
}

$registered = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($match in [regex]::Matches($frameMatch.Groups['stages'].Value, '"(?<name>[^"]+)"')) {
    [void] $registered.Add($match.Groups['name'].Value)
}

$called = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
Get-ChildItem -LiteralPath $sourceRoot -Filter '*.java' -Recurse | ForEach-Object {
    $source = Get-Content -Raw -LiteralPath $_.FullName
    foreach ($match in [regex]::Matches($source, 'RtFrameStats\.FRAME\.stage\("(?<name>[^"]+)"\)')) {
        [void] $called.Add($match.Groups['name'].Value)
    }
}

$missing = @($called | Where-Object { -not $registered.Contains($_) } | Sort-Object)
if ($missing.Count -gt 0) {
    throw "FRAME stage names called but not registered: $($missing -join ', ')"
}

Write-Output "Frame stats stage contract: PASS ($($called.Count) literal calls registered)"
