[CmdletBinding()]
param([switch]$LegacyBaseline, [switch]$RequireIntegration)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root 'build\surface-energy-behavior'
$raygen = Get-Content -Raw (Join-Path $root 'shaders\world\world.rgen.slang')
if ($LegacyBaseline) {
    $source = 'float surfaceDiffuseEnergyBudget(float noV, float noL, float f0) { return 1.0; }'
    $names = @('surfaceDiffuseEnergyBudget')
} else {
    $source = Get-Content -Raw (Join-Path $root 'shaders\world\surface_energy.slang')
    $names = @('surfaceDiffuseTransmission', 'surfaceFresnelUpperBound', 'surfaceDiffuseEnergyBudget')
}
$source += "`n" + $raygen
$names += 'ggxG1'
$methods = foreach ($name in $names) {
    $match = [regex]::Match($source, "float\s+$name\s*\([^)]*\)\s*\{")
    if (-not $match.Success) { throw "Missing scalar function $name" }
    $end=$match.Index+$match.Length; $depth=1
    while ($depth -gt 0 -and $end -lt $source.Length) {
        if ($source[$end] -eq '{') { $depth++ }
        if ($source[$end] -eq '}') { $depth-- }
        $end++
    }
    $body=$source.Substring($match.Index,$end-$match.Index)
    $body=[regex]::Replace($body,'(?s)/\*.*?\*/|//[^\r\n]*','')
    $body=[regex]::Replace($body,'(?<![\w.])(\d+\.\d*(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+)(?![\w.])','${1}f')
    'static '+$body
}
$code=@"
final class ExtractedSurfaceEnergy {
static float sqrt(float x) { return (float)Math.sqrt(x); }
static float max(float x,float y) { return Math.max(x,y); }
static float clamp(float x,float a,float b) { return Math.max(a,Math.min(b,x)); }
$($methods -join "`n")
}
"@
New-Item -ItemType Directory -Force $out | Out-Null
$generated=Join-Path $out 'ExtractedSurfaceEnergy.java'
[IO.File]::WriteAllText($generated,$code)
& 'D:\program\java25\bin\javac.exe' -encoding UTF-8 -d $out $generated (Join-Path $PSScriptRoot 'tests\SurfaceEnergyBehaviorTest.java')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& 'D:\program\java25\bin\java.exe' -cp $out SurfaceEnergyBehaviorTest
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
# These are explicit source/data-flow contracts, separate from the numerical tests above.
# Remove comments before checking so dead calls in comments cannot satisfy integration.
function Assert-EnergyIntegration([string]$text) {
    $clean = [regex]::Replace($text, '(?s)/\*.*?\*/|//[^\r\n]*', '')
    $flat = [regex]::Replace($clean, '\s+', '')
    if ($flat -notmatch 'importsurface_energy;') { throw 'Missing energy module import' }
    $start = $flat.IndexOf('float3evaluateSurfaceBrdf(')
    $end = $flat.IndexOf('floatsurfaceBsdfPdf(', $start)
    if ($start -lt 0 -or $end -le $start) { throw 'Cannot isolate BRDF evaluator' }
    $body = $flat.Substring($start, $end - $start)
    $init = 'float3brdf=diffAlb*INV_PI;'
    $binding = 'brdf*=float3(surfaceDiffuseEnergyBudget(ndv,ndl,f0.r),surfaceDiffuseEnergyBudget(ndv,ndl,f0.g),surfaceDiffuseEnergyBudget(ndv,ndl,f0.b));'
    $specular = 'brdf+=(D*G)*fresnelSchlick(vdh,f0)/(4.0*ndv*ndl);'
    $a=$body.IndexOf($init); $b=$body.IndexOf($binding); $c=$body.IndexOf($specular)
    if ($a -lt 0 -or $b -le $a -or $c -le $b) { throw 'Diffuse RGB multiplication must precede GGX addition' }
    if ([regex]::Matches($body,'brdf(?:\*=|\+=|=)').Count -ne 3) { throw 'Unexpected BRDF overwrite/bypass' }
    if (-not $body.EndsWith('returnbrdf;}')) { throw 'Evaluator output bypasses BRDF' }
    $direct = 'returnevaluateSurfaceBrdf(n,v,l,diffAlb,f0,rough,pbr)'
    if ([regex]::Matches($flat,[regex]::Escape($direct)).Count -ne 3) {
        throw 'Static point/area and realtime direct evaluators must all return shared BRDF'
    }
    $celestial = 'float3brdf=evaluateSurfaceBrdf(n,v,lightDir,diffAlb,F0,rough,pbr);'
    if (-not $flat.Contains($celestial)) { throw 'Celestial direct BRDF bypass' }
    # Guided and original directions share the same evaluator; PBR is now a runtime argument.
    $continuation = 'throughput*=evaluateSurfaceBrdf(n,v,nextDir,diffAlb,F0,rough,pbr)*max(0.0,dot(n,nextDir))/previousBsdfPdf;'
    if (-not $flat.Contains($continuation)) { throw 'Continuation throughput BRDF/PDF bypass' }
}
$integrated=$false
try { Assert-EnergyIntegration $raygen; $integrated=$true }
catch { if ($RequireIntegration) { throw }; Write-Warning "Integration not accepted: $_" }
if ($integrated) {
    $bindingPattern='brdf\s*\*=\s*float3\(surfaceDiffuseEnergyBudget\(ndv,\s*ndl,\s*f0\.r\),\s*surfaceDiffuseEnergyBudget\(ndv,\s*ndl,\s*f0\.g\),\s*surfaceDiffuseEnergyBudget\(ndv,\s*ndl,\s*f0\.b\)\);'
    $bindingMatch=[regex]::Match($raygen,$bindingPattern)
    if (-not $bindingMatch.Success) { throw 'Missing mutation target' }
    $binding=$bindingMatch.Value
    $mutations=@(
        $raygen.Replace($binding,''),
        $raygen.Replace($binding,$binding.Replace('*=','+=')),
        $raygen.Replace($binding,$binding.Replace('f0.g','f0.r')),
        $raygen.Replace('return brdf;','return diffAlb * INV_PI;')
    )
    $specMatch=[regex]::Match($raygen,'brdf\s*\+=\s*\(D\s*\*\s*G\)[^;]+;')
    $mutations += $raygen.Replace($binding,'').Replace($specMatch.Value,$specMatch.Value+"`n"+$binding)
    # Each real output call is independently removed, rather than adding unrelated fake tokens.
    $calls=[regex]::Matches($raygen,'evaluateSurfaceBrdf\(n,\s*v,\s*(?:l|lightDir|nextDir),[^;\r\n]+?\)')
    if ($calls.Count -ne 5) { throw "Expected 5 surface output call mutation targets; got $($calls.Count)" }
    foreach($call in $calls) {
        $mutations += $raygen.Remove($call.Index,$call.Length).Insert($call.Index,'float3(0.0)')
    }
    foreach($mutant in $mutations) {
        $rejected=$false
        try { Assert-EnergyIntegration $mutant } catch { $rejected=$true }
        if (-not $rejected) { throw 'An actual BRDF bypass mutation survived integration checks' }
    }
    Write-Output "PASS: RGB diffuse binding before GGX, 5 output calls, $($mutations.Count) rejected bypass mutations (source contracts, not GPU execution)"
} else { Write-Output 'Energy helper numerical checks passed, but raygen integration is NOT verified' }
