[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$javaHome = 'D:\program\java25'
$outputDir = Join-Path $projectRoot 'build\celestial-sampling-behavior'
$celestial = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'shaders\world\celestial.slang')
$world = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'shaders\world\world.rgen.slang')
# Compile the current production scalar bodies, never a maintained CPU implementation.
$methods = foreach ($name in @('celestialTangentHalfAngle', 'celestialPlanePdf', 'celestialPowerHeuristic', 'celestialDirectMisWeight', 'celestialEscapeMisWeight', 'ggxD', 'ggxG1')) {
    $shader = if ($name.StartsWith('celestial')) { $celestial } else { $world }
    $matches = [regex]::Matches($shader, "(?:public\s+)?float\s+$name\s*\([^)]*\)\s*\{")
    if ($matches.Count -ne 1) { throw "Expected exactly one scalar definition of $name" }
    $start = $matches[0].Index
    $end = $start + $matches[0].Length
    $depth = 1
    while ($end -lt $shader.Length -and $depth -gt 0) {
        if ($shader[$end] -eq '{') { $depth++ }
        if ($shader[$end] -eq '}') { $depth-- }
        $end++
    }
    if ($depth -ne 0) { throw "Unclosed function body: $name" }
    $body = $shader.Substring($start, $end - $start)
    $body = [regex]::Replace($body, '(?s)/\*.*?\*/|//[^\r\n]*', '')
    $body = [regex]::Replace($body, '\bpublic\s+', '')
    $body = [regex]::Replace($body, '\bbool\b', 'boolean')
    $body = [regex]::Replace($body, '(?<![\w.])(\d+\.\d*(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+)(?![\w.])', '${1}f')
    'static ' + $body
}
$rngMatch = [regex]::Match($world, 'float rndf\(inout uint s\)\s*\{\s*return (?<expression>[^;]+);\s*\}')
if (-not $rngMatch.Success) { throw 'Could not extract production rndf conversion.' }
$rngExpression = $rngMatch.Groups['expression'].Value.Replace('pcg(s)', 'bits').Replace('float(', 'uintFloat(').Replace('>>', '>>>')
$rngExpression = [regex]::Replace($rngExpression, '(\d+)u\b', '$1')
$rngExpression = [regex]::Replace($rngExpression, '(?<![\w.])(\d+\.\d*(?:[eE][+-]?\d+)?)(?![\w.])', '${1}f')
$generated = @"
final class ExtractedCelestial {
    static final float PI = (float)Math.PI;
    static float tan(float x) { return (float)Math.tan(x); }
    static float sqrt(float x) { return (float)Math.sqrt(x); }
    static float abs(float x) { return Math.abs(x); }
    static float max(float a, float b) { return Math.max(a, b); }
    static float min(float a, float b) { return Math.min(a, b); }
    static float clamp(float x, float a, float b) { return Math.min(Math.max(x, a), b); }
    static float uintFloat(int value) { return (float)Integer.toUnsignedLong(value); }
    static float rndFromBits(int bits) { return $rngExpression; }
    $($methods -join "`n")
}
"@
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$generatedPath = Join-Path $outputDir 'ExtractedCelestial.java'
[IO.File]::WriteAllText($generatedPath, $generated)
& (Join-Path $javaHome 'bin\javac.exe') -encoding UTF-8 -d $outputDir $generatedPath (Join-Path $PSScriptRoot 'tests\CelestialSamplingBehaviorTest.java')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& (Join-Path $javaHome 'bin\java.exe') -ea -cp $outputDir CelestialSamplingBehaviorTest
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
# Behavioral negative control: compile the same extracted functions with only the
# two transport weights reverted to 1, and require the energy oracle to reject it.
$mutant = $generated
foreach ($method in $methods) {
    if ($method -match '^static float celestial(Direct|Escape)MisWeight') {
        $mutant = $mutant.Replace($method, $method.Substring(0, $method.IndexOf('{')) + '{ return 1.0f; }')
    }
}
$mutantDir = Join-Path $outputDir 'unweighted-negative-control'
New-Item -ItemType Directory -Path $mutantDir -Force | Out-Null
$mutantPath = Join-Path $mutantDir 'ExtractedCelestial.java'
[IO.File]::WriteAllText($mutantPath, $mutant)
& (Join-Path $javaHome 'bin\javac.exe') -encoding UTF-8 -d $mutantDir $mutantPath (Join-Path $PSScriptRoot 'tests\CelestialSamplingBehaviorTest.java')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$savedErrorPreference = $ErrorActionPreference
try {
    # Windows PowerShell 5 wraps redirected native stderr in ErrorRecord objects.
    # This subprocess is expected to fail; verify its explicit exit code and oracle below.
    $ErrorActionPreference = 'Continue'
    $mutantOutput = & (Join-Path $javaHome 'bin\java.exe') -ea -cp $mutantDir CelestialSamplingBehaviorTest --energy-only 2>&1
    $mutantExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $savedErrorPreference
}
if ($mutantExitCode -eq 0 -or -not (($mutantOutput -join "`n") -match 'FAIL paired MIS energy')) {
    throw "Energy regression did not reject unweighted transport: $mutantOutput"
}
Write-Output 'PASS negative control: actual weight=1 mutation rejected by paired energy regression'
exit 0
