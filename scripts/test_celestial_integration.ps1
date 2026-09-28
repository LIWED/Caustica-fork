[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$raygen = (Get-Content -Raw -LiteralPath (Join-Path $root 'shaders/world/world.rgen.slang')).Replace("`r`n", "`n")
function Assert-CelestialPath([string] $source) {
    $required = @(
        'import celestial;',
        'payloadSetTraceState(bounce == 0, rayConeWidth, rayConeSpread);',
        'celestialSky = pc.lightRadiance.xyz * lightPdf * celestialEscapeMisWeight(',
        'previousCelestialBsdfPdf, lightPdf, previousCelestialDelta);',
        'float particlePdf = max(0.0, dot(n, lightDir)) * INV_PI;',
        'celestialDirectMisWeight(lightPdf, particlePdf, bounce < maxBounces)',
        'celestialDirectMisWeight(lightPdf, bsdfPdf, bounce < maxBounces)',
        'float3 celestialVisibility(',
        'Payload savedPayload = payload;',
        'payload = savedPayload;',
        'payloadMaterial() != MATERIAL_GLASS || bounce + crossed + 1u >= pc.maxBounces',
        'transmission *= (1.0 - F) * sqrt(clamp(payload.albedo, 0.0, 1.0));'
    )
    foreach ($token in $required) {
        if (-not $source.Contains($token)) { throw "Missing celestial integration: $token" }
    }
    if (-not [regex]::IsMatch($source, '(?s)#ifdef CAUSTICA_OFFLINE_FP32\s+payloadSetTraceState\(bounce == 0,.*?#else\s+payloadSetTraceState\(showCelestial,')) {
        throw 'Primary-only decorative discs must be offline-only.'
    }
    if (-not [regex]::IsMatch($source, '(?s)#ifdef CAUSTICA_OFFLINE_FP32\s+if \(bounce > 0\) \{.*?celestialSky = pc.lightRadiance.xyz.*?\}\s+#endif')) {
        throw 'Analytic disc must feed secondary sky only, before diagnostic output.'
    }
    if ([regex]::Matches($source, 'celestialVisibility\(').Count -ne 4) { throw 'All three celestial shadow sites must use the coherent visibility policy.' }
    if (-not $source.Contains('L += offlineContribution(throughput * celestialSky, 14u, bounce,')) { throw 'Weighted celestial sky must reach split diagnostic output.' }
}
Assert-CelestialPath $raygen
foreach ($token in @('celestialSky = pc.lightRadiance.xyz * lightPdf', 'previousCelestialBsdfPdf, lightPdf, previousCelestialDelta);', 'celestialDirectMisWeight(lightPdf, bsdfPdf, bounce < maxBounces)', 'payloadSetTraceState(bounce == 0, rayConeWidth, rayConeSpread);', 'payload = savedPayload;', 'transmission *= (1.0 - F) * sqrt(clamp(payload.albedo, 0.0, 1.0));')) {
    $mutant = $raygen.Replace($token, 'DISCONNECTED_CELESTIAL')
    $rejected = $false
    try { Assert-CelestialPath $mutant } catch { $rejected = $true }
    if (-not $rejected) { throw "Disconnected celestial mutation survived: $token" }
}
Write-Host 'Celestial source integration and six disconnect probes: PASS (not GPU execution)'
