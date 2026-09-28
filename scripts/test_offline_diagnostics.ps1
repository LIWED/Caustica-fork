[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$outputDir = Join-Path $root 'build/offline-diagnostics-behavior'
$shader = Get-Content -Raw -LiteralPath (Join-Path $root 'shaders/world/world.rgen.slang')
$match = [regex]::Match($shader, '(?s)bool offlineContributionVisible\(uint view, uint category, int bounce(?:, uint pathFlags, int maxBounces)?\)\s*\{(.*?)\n\}')
if (-not $match.Success) { throw 'Missing production scalar contribution policy (RED)' }
$body = $match.Groups[1].Value -replace '(\d+)u\b', '$1' -replace '\buint\b', 'int'
$mutant = $body -replace '\bpathFlags\b', '0'
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$generatedPath = Join-Path $outputDir 'ExtractedOfflineDiagnostic.java'
[IO.File]::WriteAllText($generatedPath, "final class ExtractedOfflineDiagnostic { static boolean offlineContributionVisible(int view, int category, int bounce, int pathFlags, int maxBounces) {$body} static boolean missingFlags(int view, int category, int bounce, int pathFlags, int maxBounces) {$mutant} }")
& 'D:/program/java25/bin/javac.exe' -encoding UTF-8 -d $outputDir $generatedPath (Join-Path $root 'src/main/java/dev/comfyfluffy/caustica/rt/offline/OfflineRenderSignature.java') (Join-Path $root 'src/main/java/dev/comfyfluffy/caustica/rt/offline/OfflineAccumulationState.java') (Join-Path $PSScriptRoot 'tests/OfflineDiagnosticsBehaviorTest.java')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& 'D:/program/java25/bin/java.exe' -ea -cp $outputDir OfflineDiagnosticsBehaviorTest $root
exit $LASTEXITCODE
