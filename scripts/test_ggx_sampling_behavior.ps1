[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$javaHome = 'D:\program\java25'
$javac = Join-Path $javaHome 'bin\javac.exe'
$java = Join-Path $javaHome 'bin\java.exe'
$outputDir = Join-Path $projectRoot 'build\ggx-sampling-behavior'
$shader = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'shaders\world\world.rgen.slang')
if (-not (Test-Path -LiteralPath $javac -PathType Leaf)) { throw "Java compiler missing: $javac" }

# Deliberately supports only these scalar functions. Unknown Slang syntax/helpers fail javac.
# Read production bodies on every run, so tests cannot silently exercise a stale CPU copy.
$methods = foreach ($name in @('ggxD', 'ggxG1')) {
    $matches = [regex]::Matches($shader, "float\s+$name\s*\(float\s+\w+,\s*float\s+\w+\)\s*\{")
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
    $body = [regex]::Replace($body, '(?<![\w.])(\d+\.\d*(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+)(?![\w.])', '${1}f')
    'static ' + $body
}
$generated = @"
final class ExtractedGgx {
    static final float PI = (float)Math.PI;
    static float sqrt(float x) { return (float)Math.sqrt(x); }
    static float max(float x, float y) { return Math.max(x, y); }
    static float min(float x, float y) { return Math.min(x, y); }
    static float clamp(float x, float lo, float hi) { return Math.min(Math.max(x, lo), hi); }
    $($methods -join "`n")
}
"@
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$generatedPath = Join-Path $outputDir 'ExtractedGgx.java'
[IO.File]::WriteAllText($generatedPath, $generated)
& $javac -encoding UTF-8 -d $outputDir $generatedPath (Join-Path $PSScriptRoot 'tests\GgxSamplingBehaviorTest.java')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $java -ea -cp $outputDir GgxSamplingBehaviorTest
exit $LASTEXITCODE
