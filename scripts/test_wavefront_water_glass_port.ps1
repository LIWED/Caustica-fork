[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$primaryPath = Join-Path $projectRoot 'shaders\world\world_primary.rgen.slang'
$secondaryPath = Join-Path $projectRoot 'shaders\world\world.rgen.slang'
$guidesPath = Join-Path $projectRoot 'shaders\world\guides.slang'
$waterPath = Join-Path $projectRoot 'shaders\world\water.slang'
$mediumPath = Join-Path $projectRoot 'shaders\world\medium.slang'
$waterVolumePath = Join-Path $projectRoot 'shaders\world\water_volume.slang'
$worldCommonPath = Join-Path $projectRoot 'shaders\world\world_common.slang'
$tracePath = Join-Path $projectRoot 'shaders\world\trace.slang'
$configPath = Join-Path $projectRoot 'src\main\java\dev\comfyfluffy\caustica\CausticaConfig.java'
$videoOptionsPath = Join-Path $projectRoot 'src\main\java\dev\comfyfluffy\caustica\client\RtVideoOptions.java'
$compositePath = Join-Path $projectRoot 'src\main\java\dev\comfyfluffy\caustica\rt\RtComposite.java'
$englishPath = Join-Path $projectRoot 'src\main\resources\assets\caustica\lang\en_us.json'
$chinesePath = Join-Path $projectRoot 'src\main\resources\assets\caustica\lang\zh_cn.json'
$gradlePropertiesPath = Join-Path $projectRoot 'gradle.properties'
$generatedWorldPushPath = Join-Path $projectRoot 'build\generated\sources\shaderRecords\dev\comfyfluffy\caustica\rt\gen\WorldPushData.java'

$primary = Get-Content -LiteralPath $primaryPath -Raw
$secondary = Get-Content -LiteralPath $secondaryPath -Raw
$guides = Get-Content -LiteralPath $guidesPath -Raw
$water = Get-Content -LiteralPath $waterPath -Raw
$medium = Get-Content -LiteralPath $mediumPath -Raw
$waterVolume = Get-Content -LiteralPath $waterVolumePath -Raw
$worldCommon = Get-Content -LiteralPath $worldCommonPath -Raw
$trace = Get-Content -LiteralPath $tracePath -Raw
$config = Get-Content -LiteralPath $configPath -Raw
$videoOptions = Get-Content -LiteralPath $videoOptionsPath -Raw
$composite = Get-Content -LiteralPath $compositePath -Raw
$english = Get-Content -LiteralPath $englishPath -Raw
$chinese = Get-Content -LiteralPath $chinesePath -Raw
$gradleProperties = Get-Content -LiteralPath $gradlePropertiesPath -Raw
$generatedWorldPush = if (Test-Path -LiteralPath $generatedWorldPushPath -PathType Leaf) {
    Get-Content -LiteralPath $generatedWorldPushPath -Raw
} else {
    ''
}
$allShaderTexts = @(
    Get-ChildItem -LiteralPath (Join-Path $projectRoot 'shaders') -Recurse -File -Filter '*.slang' |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
)
$failures = [System.Collections.Generic.List[string]]::new()

function Get-Section {
    param(
        [string] $Text,
        [string] $StartMarker,
        [string] $EndMarker
    )

    $start = $Text.IndexOf($StartMarker, [StringComparison]::Ordinal)
    $end = $Text.IndexOf($EndMarker, $start + $StartMarker.Length, [StringComparison]::Ordinal)
    if ($start -lt 0 -or $end -le $start) {
        throw "Unable to isolate source section: $StartMarker"
    }
    return $Text.Substring($start, $end - $start)
}

function Get-FunctionSection {
    param(
        [string] $Text,
        [string] $Signature
    )

    $start = $Text.IndexOf($Signature, [StringComparison]::Ordinal)
    if ($start -lt 0) {
        throw "Unable to isolate source function: $Signature"
    }
    $openBrace = $Text.IndexOf('{', $start)
    if ($openBrace -lt 0) {
        throw "Unable to find source function body: $Signature"
    }
    $depth = 0
    for ($index = $openBrace; $index -lt $Text.Length; ++$index) {
        if ($Text[$index] -eq '{') { ++$depth }
        if ($Text[$index] -eq '}') { --$depth }
        if ($depth -eq 0) {
            return $Text.Substring($start, $index - $start + 1)
        }
    }
    throw "Unable to find source function end: $Signature"
}

function Remove-SourceComments {
    param([string] $Text)

    $withoutBlockComments = [regex]::Replace($Text, '(?s)/\*.*?\*/', '')
    return [regex]::Replace($withoutBlockComments, '(?m)//.*$', '')
}

function Get-ExecutableCallCount {
    param(
        [string[]] $Texts,
        [string] $FunctionName
    )

    $escapedName = [regex]::Escape($FunctionName)
    $declarationPattern = "(?m)^[ \t]*(?:public[ \t]+)?[A-Za-z_][A-Za-z0-9_<>,]*[ \t]+$escapedName[ \t]*\("
    $callPattern = "(?<![A-Za-z0-9_])$escapedName[ \t]*\("
    $count = 0
    foreach ($text in $Texts) {
        $code = Remove-SourceComments -Text $text
        $codeWithoutDeclarations = [regex]::Replace($code, $declarationPattern, '')
        $count += [regex]::Matches($codeWithoutDeclarations, $callPattern).Count
    }
    return $count
}

function Require-Match {
    param(
        [string] $Text,
        [string] $Pattern,
        [string] $Message
    )

    if ($Text -notmatch $Pattern) {
        $failures.Add($Message)
    }
}

function Require-NoMatch {
    param(
        [string] $Text,
        [string] $Pattern,
        [string] $Message
    )

    if ($Text -match $Pattern) {
        $failures.Add($Message)
    }
}

function Require-Count {
    param(
        [string] $Text,
        [string] $Pattern,
        [int] $Expected,
        [string] $Message
    )

    if ([regex]::Matches($Text, $Pattern).Count -ne $Expected) {
        $failures.Add($Message)
    }
}

function Require-FloatArrayCount {
    param(
        [string] $Text,
        [string] $Name,
        [int] $Expected,
        [string] $Message
    )

    $escapedName = [regex]::Escape($Name)
    $match = [regex]::Match(
        $Text,
        "const\s+float\s+$escapedName\[WAVE_COMPONENT_COUNT\]\s*=\s*\{(?<body>.*?)\};",
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $match.Success) {
        $failures.Add($Message)
        return
    }
    $numberPattern = '(?<![A-Za-z_])[-+]?(?:\d+\.\d+|\d+)(?:[eE][-+]?\d+)?'
    if ([regex]::Matches($match.Groups['body'].Value, $numberPattern).Count -ne $Expected) {
        $failures.Add($Message)
    }
}

function Require-ExactFloatArray {
    param(
        [string] $Text,
        [string] $Name,
        [string] $DeclaredSize,
        [double[]] $Expected,
        [string] $Message
    )

    $escapedName = [regex]::Escape($Name)
    $escapedSize = [regex]::Escape($DeclaredSize)
    $match = [regex]::Match(
        $Text,
        "const\s+float\s+$escapedName\[$escapedSize\]\s*=\s*\{(?<body>.*?)\};",
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $match.Success) {
        $failures.Add($Message)
        return
    }

    $numberPattern = '(?<![A-Za-z_])[-+]?(?:\d+\.\d+|\d+)(?:[eE][-+]?\d+)?'
    $numbers = [regex]::Matches($match.Groups['body'].Value, $numberPattern)
    if ($numbers.Count -ne $Expected.Count) {
        $failures.Add($Message)
        return
    }

    $culture = [Globalization.CultureInfo]::InvariantCulture
    for ($index = 0; $index -lt $Expected.Count; ++$index) {
        $actual = [double]::Parse($numbers[$index].Value, $culture)
        if ([Math]::Abs($actual - $Expected[$index]) -gt 1.0e-12) {
            $failures.Add($Message)
            return
        }
    }
}

function Get-OptionalFunctionSection {
    param(
        [string] $Text,
        [string] $Signature
    )

    try {
        return Get-FunctionSection -Text $Text -Signature $Signature
    } catch {
        return ''
    }
}

$guideWalker = Get-Section -Text $guides `
    -StartMarker 'public void resolveTransmissionGuide' `
    -EndMarker '// Resolve the captured gv_* guide state'
$guideTirGuard = Get-Section -Text $guideWalker `
    -StartMarker 'bool entering = payloadDielectricEntering()' `
    -EndMarker 'if (entering)'
$guideWalkerCode = Remove-SourceComments -Text $guideWalker
$guideTirGuardCode = Remove-SourceComments -Text $guideTirGuard
$waterSpectrum = Get-Section -Text $water `
    -StartMarker 'public void waterWaveSpectrum' `
    -EndMarker 'public float2 waterWaveGrad'
$waterTemporal = Get-Section -Text $water `
    -StartMarker 'public void waterWaveGradTemporal' `
    -EndMarker '// Perturb a (near-)horizontal water surface normal'
$waterCode = Remove-SourceComments -Text $water
$waterCausticDetailCode = Get-OptionalFunctionSection -Text $waterCode `
    -Signature 'public void waterCausticDetailSpectrum'
$waterCausticGradCode = Get-FunctionSection -Text $waterCode `
    -Signature 'public float2 waterCausticGrad'
$causticLandingCode = Get-FunctionSection -Text $waterCode `
    -Signature 'public float2 causticLanding'
$waterCausticCode = Get-FunctionSection -Text $waterCode `
    -Signature 'public float waterCaustic'
$waterSurfaceGradCode = Get-FunctionSection -Text $waterCode `
    -Signature 'public float2 waterSurfaceGrad'
$waterSurfaceTemporalCode = Get-FunctionSection -Text $waterCode `
    -Signature 'public void waterSurfaceGradTemporal'
$waterRefractionGradCode = Get-FunctionSection -Text $waterCode `
    -Signature 'public float2 waterRefractionGrad'
$waterRefractionTemporalCode = Get-FunctionSection -Text $waterCode `
    -Signature 'public void waterRefractionGradTemporal'
$mediumCode = Remove-SourceComments -Text $medium
$waterVolumeCode = Remove-SourceComments -Text $waterVolume
$waterEffectiveExtinctionCode = Get-FunctionSection -Text $waterVolumeCode `
    -Signature 'public float3 waterEffectiveExtinction'
$waterScatterPaletteCode = Get-FunctionSection -Text $waterVolumeCode `
    -Signature 'public float3 waterScatterPalette'
$integrateWaterSingleScatterCode = Get-FunctionSection -Text $waterVolumeCode `
    -Signature 'public float3 integrateWaterSingleScatter'
# Pass B must attenuate both finite hits and its finite sky horizon before either branch consumes radiance.
Require-Match -Text $secondary -Pattern '(?s)float segmentDistance = payload\.hitT < 0\.0 \? 10000\.0 : payload\.hitT;.*?float3 effectiveExtinction = waterEffectiveExtinction\(\s*medium\.current\.extinction, medium\.current\.water, waterFog, waterFogStrength\);.*?float3 segmentTransmittance = exp\(-effectiveExtinction \* segmentDistance\);.*?throughput \*= segmentTransmittance;.*?if \(payload\.hitT < 0\.0\)' -Message 'Pass B does not apply effective water extinction before the hit/miss split.'
Require-NoMatch -Text $secondary -Pattern 'medium\.current\.extinction \* payload\.hitT' -Message 'Pass B still contains the old finite-hit-only Beer attenuation.'

# The deterministic transmission guide owns the attenuation for every segment it walks.
Require-Match -Text $guideWalkerCode -Pattern '(?s)float segmentDistance = payload\.hitT > 0\.0 \? payload\.hitT : 10000\.0;.*?float3 effectiveExtinction = waterEffectiveExtinction\(\s*medium\.current\.extinction, medium\.current\.water, waterFog, waterFogStrength\);.*?guideFilter \*= exp\(-effectiveExtinction \* segmentDistance\);.*?if \(payload\.hitT <= 0\.0\)' -Message 'Transmission guide does not use the same effective water extinction as radiance paths.'
Require-NoMatch -Text $guideWalkerCode -Pattern '(?m)^\s*guideFilter\s*=.*payload\.albedo.*$|^\s*guideFilter\s*\*=.*payload\.albedo.*$' -Message 'Transmission guide still double-counts dielectric tint at an interface.'
Require-Match -Text $primary -Pattern '(?s)resolveTransmissionGuide\(hitPos, transmittedDir, previousTransmittedDir, geometricNormal,\s*guideMedium, transmitBias, rayConeWidth, rayConeSpread,\s*float3\(1\.0, 1\.0, 1\.0\)\);' -Message 'Pass A does not seed the transmission guide with current/previous directions and a neutral interface filter.'

# A finite Guide segment advances the same cone as Pass B before either material or water-footprint work.
# Current and previous optical directions then choose their own water LOD footprint on the sole walk.
Require-Match -Text $guideWalkerCode -Pattern '(?s)if \(payload\.hitT <= 0\.0\) \{.*?return;\s*\}\s*rayConeWidth = max\(rayConeWidth \+ rayConeSpread \* max\(payload\.hitT, 0\.0\),\s*RAY_CONE_MIN_WIDTH\);\s*uint material = payloadMaterial\(\);' -Message 'Transmission guide does not advance its cone after a finite hit and before material processing.'
Require-Match -Text $guideWalkerCode -Pattern 'float waterFootprint = rayConeWidth\s*/ max\(abs\(dot\(-direction, geometricNormal\)\), 0\.2\);' -Message 'Transmission guide does not derive the current water footprint from direction and the advanced cone.'
Require-Match -Text $guideWalkerCode -Pattern 'float previousWaterFootprint = rayConeWidth\s*/ max\(abs\(dot\(-previousDirection, geometricNormal\)\), 0\.2\);' -Message 'Transmission guide does not derive a distinct previous-frame water footprint from previousDirection.'
Require-Match -Text $guideWalkerCode -Pattern '(?s)float3 previousRefractionNormal = isWater \? waterRefractionNormal\(\s*geometricNormal, previousInterfacePos\.xz \+ worldPush\.waterAnchor\.xy,\s*worldPush\.waterAnchor\.z, previousWaterFootprint, waterWaveStrength\)' -Message 'Transmission guide does not pass the previous-direction footprint to the previous water refraction helper.'

# All three Snell paths use the bounded low-frequency refraction role. Reflection remains on the
# independently calibrated animated surface normal.
foreach ($entry in @(
    @{ Name = 'Pass A'; Text = $primary; Normal = 'n'; Ray = 'rd' },
    @{ Name = 'Pass B'; Text = $secondary; Normal = 'n'; Ray = 'rd' },
    @{ Name = 'Transmission guide'; Text = $guideWalkerCode; Normal = 'interfaceNormal'; Ray = 'direction' }
)) {
    Require-Match -Text $entry.Text -Pattern 'refractionNormal = (?:isWater \? )?waterRefractionNormal\(' -Message "$($entry.Name) does not use waterRefractionNormal for water Snell refraction."
    Require-Match -Text $entry.Text -Pattern "refract\($($entry.Ray), refractionNormal," -Message "$($entry.Name) does not use the selected refraction normal for Snell refraction."
    Require-NoMatch -Text $entry.Text -Pattern 'float3 refractionNormal = isWater \? geometricNormal' -Message "$($entry.Name) still selects the geometric water normal for Snell refraction."
    Require-NoMatch -Text $entry.Text -Pattern "refract\($($entry.Ray), $($entry.Normal)," -Message "$($entry.Name) still refracts directly with the animated/interface normal."
}

Require-Match -Text $primary -Pattern '(?s)float F = fresnelDielectric\(.*?\);.*?float3 transmittedDir.*?if \(dot\(transmittedDir, transmittedDir\) <= 0\.0\) \{\s*F = 1\.0;\s*\}.*?bool splitEligible' -Message 'Pass A does not convert TIR into guaranteed reflection before selecting a continuation.'
Require-Match -Text $secondary -Pattern '(?s)float F = fresnelDielectric\(.*?\);\s*float3 refractionNormal.*?float3 transmittedDir.*?if \(dot\(transmittedDir, transmittedDir\) <= 0\.0\) \{\s*F = 1\.0;\s*\}.*?bool chooseReflection' -Message 'Pass B does not convert TIR into guaranteed reflection before selecting a continuation.'
Require-Match -Text $guideWalkerCode -Pattern '(?s)float3 nextDirection = refract\(.*?\);\s*if \(dot\(nextDirection, nextDirection\) <= 0\.0\) \{.*?return;\s*\}.*?if \(entering\) \{\s*mediumPush' -Message 'Transmission guide may update the medium stack before terminating TIR.'
Require-NoMatch -Text $guideTirGuardCode -Pattern 'medium(Push|Pop)\s*\(' -Message 'Transmission guide updates the medium stack before the TIR guard returns.'
Require-Count -Text $guideWalkerCode -Pattern 'mediumPush\s*\(' -Expected 1 -Message 'Transmission guide must push its medium exactly once, only after successful refraction.'
Require-Count -Text $guideWalkerCode -Pattern 'mediumPop\s*\(' -Expected 1 -Message 'Transmission guide must pop its medium exactly once, only after successful refraction.'
Require-Count -Text $guideWalkerCode -Pattern 'traceGuide\s*\(' -Expected 1 -Message 'Transmission guide must keep exactly one current-path traceGuide call.'
Require-Match -Text $guideWalkerCode -Pattern '(?s)bool previousOpticalValid = dot\(previousTransmittedDir, previousTransmittedDir\) > 0\.0;.*?float3 previousDirection = previousOpticalValid\s*\? normalize\(previousTransmittedDir\) : direction;.*?float3 previousRo = offsetSurfaceOrigin\(' -Message 'Transmission guide does not initialize the previous optical ray alongside the current ray.'
Require-Match -Text $guideWalkerCode -Pattern 'float3 previousInterfacePos = previousRo \+ previousDirection \* payload\.hitT;' -Message 'Transmission guide does not estimate the previous interface with the current payload.hitT.'
Require-Match -Text $guideWalkerCode -Pattern '(?s)float3 previousNextDirection = refract\(\s*previousDirection, previousRefractionNormal,.*?previousOpticalValid = false;.*?previousDirection = normalize\(nextDirection\);' -Message 'Transmission guide does not invalidate previous-only TIR while continuing the sole current walk.'
Require-Match -Text $guideWalkerCode -Pattern '(?s)if \(previousOpticalValid\).*?previousDirection = normalize\(previousNextDirection\);.*?previousRo = offsetSurfaceOrigin\(previousInterfacePos,' -Message 'Transmission guide does not advance a valid previous optical ray across each shared interface.'
Require-Match -Text $guideWalkerCode -Pattern '(?s)if \(!previousOpticalValid\) previousInterfacePos = interfacePos;.*?setTransmissionGuide\(' -Message 'Transmission guide does not neutralize invalid wave optical motion at the final endpoint.'
Require-Match -Text $guides -Pattern 'public static float3 gv_previousHitCamRel' -Message 'Transmission guide has no storage for the previous optical endpoint.'
Require-Match -Text $guides -Pattern '(?s)float3 previousMotionCamRel = gv_motionUseRefracted\s*\? gv_previousHitCamRel : gv_hitCamRel;.*?previousMotionCamRel \+ worldPush\.camDelta - gv_motionObjDisp' -Message 'Transmission motion does not project the previous optical endpoint with independent object motion.'

# Surface detail must use one non-harmonic spectrum. Reintroducing the old macro/micro direction
# families restores the moving lattice that the physical Jacobian amplifies into a caustic grid.
Require-Match -Text $water -Pattern 'public static const int\s+WAVE_COMPONENT_COUNT\s*=\s*12;' -Message 'Water does not define the unified twelve-component spectrum.'
Require-Match -Text $water -Pattern 'const float wavelength\[WAVE_COMPONENT_COUNT\]' -Message 'Unified spectrum has no explicit non-harmonic wavelengths.'
Require-Match -Text $water -Pattern 'const float directionOffset\[WAVE_COMPONENT_COUNT\]' -Message 'Unified spectrum has no independent directions.'
Require-Match -Text $water -Pattern 'const float energy\[WAVE_COMPONENT_COUNT\]' -Message 'Unified spectrum has no independent energy distribution.'
Require-Match -Text $water -Pattern 'const float phaseOffset\[WAVE_COMPONENT_COUNT\]' -Message 'Unified spectrum has no independent initial phases.'
Require-Match -Text $water -Pattern 'const float sharpness\[WAVE_COMPONENT_COUNT\]' -Message 'Unified spectrum has no independent crest sharpness.'
Require-Match -Text $water -Pattern 'const float meanderAmplitude\[WAVE_COMPONENT_COUNT\]' -Message 'Unified spectrum has no independent meander amplitudes.'
Require-Match -Text $water -Pattern 'const float meanderScale\[WAVE_COMPONENT_COUNT\]' -Message 'Unified spectrum has no independent meander scales.'
Require-Match -Text $water -Pattern 'const float meanderSpeed\[WAVE_COMPONENT_COUNT\]' -Message 'Unified spectrum has no independent meander speeds.'
Require-Match -Text $water -Pattern 'const float meanderOffset\[WAVE_COMPONENT_COUNT\]' -Message 'Unified spectrum has no independent meander phases.'
foreach ($arrayName in @('wavelength', 'directionOffset', 'energy', 'phaseOffset', 'sharpness', 'meanderAmplitude', 'meanderScale', 'meanderSpeed', 'meanderOffset')) {
    Require-FloatArrayCount -Text $waterSpectrum -Name $arrayName -Expected 12 -Message "Unified spectrum array '$arrayName' does not contain exactly twelve numeric parameters."
}
Require-Match -Text $water -Pattern 'phase \+= meanderAmplitude\[i\] \* sin\(meanderPhase\);' -Message 'Wave crests are not bent independently in two dimensions.'
Require-Match -Text $water -Pattern 'phaseGradient \+=' -Message 'Meander spatial derivatives are not propagated to the water gradient.'
Require-Match -Text $water -Pattern 'phaseDt \+= meanderAmplitude\[i\] \* cos\(meanderPhase\) \* meanderPhaseDt;' -Message 'Meander time derivatives are not propagated to the wave phase.'
Require-Match -Text $water -Pattern '(?s)phaseGradientDt \+= -meanderAmplitude\[i\] \* sin\(meanderPhase\).*?meanderPhaseDt \* meanderSpatialRate \* perpendicular;' -Message 'Meander time derivatives are not propagated to the spatial gradient.'
Require-Match -Text $waterSpectrum -Pattern '(?s)gradDt \+= amplitude \* e\s*\* \(phaseDt \* \(-sinPh \+ S \* cosPh \* cosPh\) \* phaseGradient\s*\+ cosPh \* phaseGradientDt\);' -Message 'The sharp-crest gradient does not preserve the complete time chain rule.'
Require-NoMatch -Text $water -Pattern 'MACRO_WAVE_COUNT|MICRO_RIPPLE_COUNT|waterMacroWaveSpectrum|waterMicroRippleSpectrum|lambda /= 1\.5|crossAngle' -Message 'The old regular macro/micro direction families are still present.'
Require-Match -Text $water -Pattern 'public static const float WATER_TEMPORAL_LINEAR_LIMIT = 0\.05;' -Message 'Water temporal reprojection has no bounded linearization interval.'
Require-Match -Text $waterTemporal -Pattern '(?s)if \(abs\(frameDelta\) <= WATER_TEMPORAL_LINEAR_LIMIT\).*?previousGrad = currentGrad - frameDelta \* WAVE_SPEED \* gradDt;.*?else.*?previousGrad = waterWaveGrad\(p, previousT, footprint\);' -Message 'Long water frame intervals do not fall back to an exact previous-phase evaluation.'

# Task 3 separates visible reflection waves, low-frequency Snell waves, and physical caustic waves.
Require-Match -Text $water -Pattern 'public static const float WATER_SURFACE_GAIN = 1\.50;' -Message 'Surface-wave role gain is missing.'
Require-Match -Text $water -Pattern 'public static const float WATER_REFRACTION_GAIN = 0\.45;' -Message 'Refraction-wave role gain is missing.'
Require-Match -Text $water -Pattern 'public static const float WATER_CAUSTIC_GAIN = 1\.35;' -Message 'Caustic-wave role gain is missing.'
Require-Match -Text $water -Pattern 'public static const float WATER_SURFACE_MAX_SLOPE = 0\.35;' -Message 'Surface-wave slope bound is missing.'
Require-Match -Text $water -Pattern 'public static const float WATER_REFRACTION_MAX_SLOPE = 0\.12;' -Message 'Refraction-wave slope bound is missing.'
Require-Match -Text $water -Pattern 'public static const float WATER_CAUSTIC_MAX_SLOPE = 0\.45;' -Message 'Caustic-wave slope bound is missing.'
Require-Match -Text $water -Pattern 'public static const int WATER_REFRACTION_COMPONENT_COUNT = 8;' -Message 'Refraction-wave component limit is missing.'
Require-Match -Text $water -Pattern 'public static const float WATER_REFRACTION_MIN_FOOTPRINT = 0\.35;' -Message 'Refraction-wave minimum footprint is missing.'
Require-Match -Text $water -Pattern 'public void waterWaveSpectrum<let WITH_DT : int>\(float2 p, float t, float footprint, int componentLimit,' -Message 'The shared spectrum has no explicit componentLimit.'
Require-Match -Text $waterSpectrum -Pattern 'for \(int i = 0; i < componentLimit; i\+\+\)' -Message 'The shared spectrum does not honor componentLimit.'
Require-Match -Text $water -Pattern 'public float2 waterSurfaceGrad\(float2 p, float t, float footprint, float strength\)' -Message 'waterSurfaceGrad role helper is missing.'
Require-Match -Text $water -Pattern 'public void waterSurfaceGradTemporal\(float2 p, float currentT, float previousT,\s*float footprint, float strength, out float2 currentGrad, out float2 previousGrad\)' -Message 'Surface temporal role helper is missing.'
Require-Match -Text $water -Pattern 'public float2 waterRefractionGrad\(float2 p, float t, float footprint, float strength\)' -Message 'waterRefractionGrad role helper is missing.'
Require-Match -Text $water -Pattern 'public void waterRefractionGradTemporal\(float2 p, float currentT, float previousT,\s*float footprint, float strength, out float2 currentGrad, out float2 previousGrad\)' -Message 'Refraction temporal role helper is missing.'
Require-Match -Text $water -Pattern 'public float3 waterRefractionNormal\(float3 geometricNormal, float2 worldXZ,\s*float t, float footprint, float strength\)' -Message 'waterRefractionNormal role helper is missing.'
Require-Match -Text $water -Pattern '(?s)public float3 applyWaterWaves\(.*?float strength\).*?if \(strength <= 0\.0\) return nGeo;' -Message 'Disabled surface waves do not return the geometric normal immediately.'
Require-Match -Text $water -Pattern '(?s)public float3 waterRefractionNormal\(.*?\).*?if \(strength <= 0\.0\) return geometricNormal;' -Message 'Disabled refraction waves do not return the geometric normal immediately.'
# A zero or infinitesimal role gradient must perturb the complete mesh normal, not rebuild a canonical
# vertical normal. Otherwise sloped water jumps at the 0% slider boundary even though the explicit
# strength<=0 branches look correct.
Require-Match -Text $water -Pattern '(?s)public float3 waterNormalFromGrad\(float3 geometricNormal, float2 boundedGrad\).*?if \(abs\(geometricNormal\.y\) < 0\.5\) return geometricNormal;.*?if \(dot\(boundedGrad, boundedGrad\) <= 0\.0\) return geometricNormal;.*?float orientation = geometricNormal\.y >= 0\.0 \? 1\.0 : -1\.0;.*?return normalize\(geometricNormal \+ orientation\s*\* float3\(-boundedGrad\.x, 0\.0, -boundedGrad\.y\)\);' -Message 'Gradient-to-normal conversion does not preserve exact zero or continuously perturb the complete geometric water normal.'
Require-NoMatch -Text $water -Pattern '(?s)public float3 waterNormalFromGrad\(.*?float3 up = normalize\(float3\(-boundedGrad\.x, 1\.0, -boundedGrad\.y\)\);' -Message 'Gradient-to-normal conversion still collapses sloped water to a canonical vertical normal.'
Require-Match -Text $water -Pattern '(?s)public float3 applyWaterWaves\(.*?float2 grad = waterSurfaceGrad\(.*?\);\s*return waterNormalFromGrad\(nGeo, grad\);' -Message 'Five-parameter surface waves do not share the geometric-normal-preserving conversion.'
Require-Match -Text $water -Pattern '(?s)public void waterSurfaceGradTemporal\(.*?if \(abs\(frameDelta\) <= WATER_TEMPORAL_LINEAR_LIMIT\).*?else.*?previousGrad = waterSurfaceGrad\(p, previousT, footprint, strength\);.*?public float2 waterRefractionGrad' -Message 'Long surface-wave frame intervals do not evaluate the exact previous phase.'
Require-Match -Text $water -Pattern '(?s)public void waterRefractionGradTemporal\(.*?if \(abs\(frameDelta\) <= WATER_TEMPORAL_LINEAR_LIMIT\).*?else.*?previousGrad = waterRefractionGrad\(p, previousT, footprint, strength\);.*?public float3 waterRefractionNormal' -Message 'Long refraction-wave frame intervals do not evaluate the exact previous phase.'
Require-Match -Text $water -Pattern '(?s)public float2 waterSurfaceGrad\(.*?clamp\(strength, 0\.0, 2\.0\).*?WATER_SURFACE_GAIN.*?WATER_SURFACE_MAX_SLOPE' -Message 'Surface role does not independently clamp strength, apply gain, and bound slope.'
Require-Match -Text $water -Pattern '(?s)public float2 waterRefractionGrad\(.*?max\(footprint, WATER_REFRACTION_MIN_FOOTPRINT\).*?WATER_REFRACTION_COMPONENT_COUNT.*?clamp\(strength, 0\.0, 2\.0\).*?WATER_REFRACTION_GAIN.*?WATER_REFRACTION_MAX_SLOPE' -Message 'Refraction role does not use its filtered eight-layer amplitude and slope calibration.'
Require-Match -Text $primary -Pattern '(?s)float waterWaveStrength = waterWaves \? clamp\(worldPush\.waterTuning\.x, 0\.0, 2\.0\) : 0\.0;.*?waterSurfaceGradTemporal\(.*?waterWaveStrength,.*?waterRefractionGradTemporal\(.*?waterWaveStrength,.*?float3 previousTransmittedDir = refract\(\s*rd, previousRefractionNormal,' -Message 'Pass A does not compute current/previous surface and refraction directions from the shared frame phases.'
Require-Match -Text $primary -Pattern '(?s)n = waterNormalFromGrad\(geometricNormal, currentGrad\);\s*previousNormal = waterNormalFromGrad\(geometricNormal, previousGrad\);.*?refractionNormal = waterRefractionNormal\(geometricNormal, currentRefractionGrad\);\s*previousRefractionNormal = waterRefractionNormal\(\s*geometricNormal, previousRefractionGrad\);' -Message 'Pass A does not derive all four temporal water normals from the complete geometric normal.'
Require-Match -Text $secondary -Pattern '(?s)float waterWaveStrength = waterWaves \? clamp\(worldPush\.waterTuning\.x, 0\.0, 2\.0\) : 0\.0;.*?waterRefractionNormal\(' -Message 'Pass B does not apply the live wave amplitude to bounded refraction.'

# Versioned builds must be distinguishable during visual iteration.
Require-Match -Text $gradleProperties -Pattern '(?m)^mod_version=0\.4\.3\s*$' -Message 'The reference-water and dense-caustics update is not versioned as 0.4.3.'

# Caustics add a deterministic high-frequency spectrum without changing the visible surface or the
# bounded low-frequency Snell role. Assertions are comment-stripped and function-scoped so comments or
# unused declarations cannot satisfy the data-flow contract.
Require-NoMatch -Text $waterCode -Pattern 'CAUSTIC_PATTERN_LAYER_COUNT|waterCausticPattern\(' -Message 'The removed periodic artistic grid is still present.'
Require-Match -Text $waterCode -Pattern 'public static const int CAUSTIC_DETAIL_COMPONENT_COUNT = 6;' -Message 'Caustics do not define exactly six detail-only components.'
Require-Match -Text $waterCausticDetailCode -Pattern 'public void waterCausticDetailSpectrum\(float2 p, float t, float footprint, out float2 grad\)' -Message 'The caustic-only detail spectrum helper is missing.'
$causticDetailArrays = @{
    wavelength       = @(0.95, 0.68, 0.49, 0.34, 0.24, 0.18)
    directionOffset  = @(2.36, -2.05, 0.98, -0.22, 1.71, -1.31)
    energy           = @(0.0315, 0.0294, 0.0273, 0.0231, 0.0189, 0.0147)
    meanderAmplitude = @(0.52, 0.61, 0.47, 0.68, 0.56, 0.73)
    phaseOffset      = @(5.11, 1.37, 3.92, 0.58, 4.46, 2.73)
    sharpness        = @(0.86, 0.90, 0.94, 0.98, 1.02, 1.06)
    meanderScale     = @(0.37, 0.43, 0.31, 0.47, 0.35, 0.41)
    meanderSpeed     = @(0.33, -0.28, 0.42, -0.37, 0.25, -0.45)
    meanderOffset    = @(0.91, 3.44, 5.26, 2.08, 4.79, 1.62)
}
foreach ($arrayName in $causticDetailArrays.Keys) {
    Require-ExactFloatArray -Text $waterCausticDetailCode -Name $arrayName `
        -DeclaredSize 'CAUSTIC_DETAIL_COMPONENT_COUNT' -Expected $causticDetailArrays[$arrayName] `
        -Message "Caustic detail array '$arrayName' does not match the six approved values exactly."
}
Require-Match -Text $waterCausticDetailCode -Pattern '(?s)float2 warp = 0\.22 \* float2\(\s*sin\(dot\(p, float2\(0\.31, 0\.17\)\) - 0\.21 \* t \+ 0\.41\),\s*sin\(dot\(p, float2\(-0\.19, 0\.29\)\) \+ 0\.17 \* t \+ 2\.13\)\);' -Message 'Caustic detail does not use the exact approved analytic warp.'
Require-Match -Text $waterCausticDetailCode -Pattern '(?s)float2 warpedP = p \+ warp;.*?float2 warpDx = 0\.22 \* float2\(0\.31 \* cosWarpX, -0\.19 \* cosWarpY\);.*?float2 warpDz = 0\.22 \* float2\(0\.17 \* cosWarpX, 0\.29 \* cosWarpY\);' -Message 'Caustic detail does not propagate the analytic warp derivatives.'
Require-Match -Text $waterCausticDetailCode -Pattern '(?s)float2 warp = 0\.22 \* float2\(.*?\);.*?t \*= WAVE_SPEED;.*?for \(int i = 0; i < CAUSTIC_DETAIL_COMPONENT_COUNT; i\+\+\).*?float lambda = wavelength\[i\];.*?float lodWeight = waterWaveLodWeight\(lambda, footprint\);.*?float k = 2\.0 \* PI / lambda;.*?float w = sqrt\(WAVE_G \* k\);.*?float angle = directionOffset\[i\];.*?float phase = k \* dot\(d, warpedP\) - w \* t \+ phaseOffset\[i\];.*?float meanderSpatialRate = meanderScale\[i\] \* k;.*?float meanderPhaseDt = meanderSpeed\[i\] \* w;.*?float meanderPhase = meanderSpatialRate \* dot\(perpendicular, warpedP\).*?\+ meanderPhaseDt \* t \+ meanderOffset\[i\];.*?phase \+= meanderAmplitude\[i\] \* sin\(meanderPhase\);' -Message 'Caustic detail does not consume every approved component through raw-time warp, deep-water dispersion, LOD, direction, and analytic meander.'
Require-Match -Text $waterCausticDetailCode -Pattern '(?s)float2 warpedPhaseGradient = k \* d;.*?warpedPhaseGradient \+= meanderAmplitude\[i\] \* cos\(meanderPhase\).*?float2 phaseGradient = float2\(\s*dot\(warpedPhaseGradient, float2\(1\.0, 0\.0\) \+ warpDx\),\s*dot\(warpedPhaseGradient, float2\(0\.0, 1\.0\) \+ warpDz\)\);.*?grad \+= amplitude \* cosPh \* e \* phaseGradient;.*?grad \*= WATER_WAVE_STRENGTH;' -Message 'Caustic detail does not carry the warped phase derivative into its raw gradient.'
Require-Match -Text $waterCausticDetailCode -Pattern '(?s)float S = sharpness\[i\];.*?float e = exp\(S \* \(sinPh - 1\.0\)\);.*?float amplitude = lodWeight \* \(energy\[i\] / k\) \* S;' -Message 'Caustic detail does not consume its approved energy and sharpness through the sharp-crest profile.'
Require-NoMatch -Text $waterCausticDetailCode -Pattern '\b(?:strength|CAUSTIC_DETAIL_GAIN|WATER_CAUSTIC_GAIN|WATER_CAUSTIC_MAX_SLOPE|waterBoundRoleGrad)\b' -Message 'Caustic detail applies an extra detail/role gain, strength, or slope bound before base/detail combination.'

$detailCallCount = Get-ExecutableCallCount -Texts $allShaderTexts -FunctionName 'waterCausticDetailSpectrum'
if ($detailCallCount -ne 1) {
    $failures.Add("Executable waterCausticDetailSpectrum call count is $detailCallCount; expected 1 in waterCausticGrad only.")
}
Require-Count -Text $waterCausticGradCode -Pattern 'waterCausticDetailSpectrum\s*\(' -Expected 1 -Message 'waterCausticGrad must consume the caustic detail spectrum exactly once.'
Require-NoMatch -Text ($waterSurfaceGradCode + $waterSurfaceTemporalCode + $waterRefractionGradCode + $waterRefractionTemporalCode) -Pattern 'waterCausticDetailSpectrum\s*\(' -Message 'Surface or refraction code consumes the caustic-only detail spectrum.'
Require-Match -Text $waterCausticGradCode -Pattern '(?s)waterWaveSpectrum<0>\(p, t, footprint, WAVE_COMPONENT_COUNT, baseGrad, gradDt\);.*?waterCausticDetailSpectrum\(p, t, footprint, detailGrad\);.*?float2 rawGrad = baseGrad \+ detailGrad;.*?float amplitudeResponse = clamp\(strength, 0\.0, 2\.0\);.*?return waterBoundRoleGrad\(\s*rawGrad, amplitudeResponse \* WATER_CAUSTIC_GAIN, WATER_CAUSTIC_MAX_SLOPE\);' -Message 'Caustic gradients do not combine base and detail before applying strength, gain, and slope bound once.'
Require-Count -Text $waterCausticGradCode -Pattern 'waterBoundRoleGrad\s*\(' -Expected 1 -Message 'Caustic gradients must apply their amplitude/gain/slope bound exactly once.'

Require-NoMatch -Text $waterCode -Pattern 'CAUSTIC_NEAR_EPS|CAUSTIC_FAR_EPS' -Message 'The obsolete shared caustic epsilon constants remain.'
Require-Match -Text $waterCode -Pattern 'public static const float CAUSTIC_JACOBIAN_EPS = 0\.06;' -Message 'Caustics do not use the exact 0.06 Jacobian epsilon.'
Require-Match -Text $waterCode -Pattern 'public static const float CAUSTIC_LOD_NEAR = 0\.06;' -Message 'Caustics do not use the exact 0.06 near LOD footprint.'
Require-Match -Text $waterCode -Pattern 'public static const float CAUSTIC_LOD_FAR = 0\.28;' -Message 'Caustics do not use the exact 0.28 far LOD footprint.'
Require-Match -Text $causticLandingCode -Pattern 'public float2 causticLanding\(float2 xz, float t, float3 inc, float h, float lodFootprint,\s*float strength\)' -Message 'causticLanding does not receive the isolated LOD footprint role.'
Require-Match -Text $causticLandingCode -Pattern 'waterCausticGrad\(xz, t, lodFootprint, strength\)' -Message 'causticLanding does not use lodFootprint exclusively for spectrum filtering.'
Require-NoMatch -Text $causticLandingCode -Pattern 'CAUSTIC_(?:JACOBIAN_EPS|LOD_NEAR|LOD_FAR)' -Message 'causticLanding mixes Jacobian or depth-LOD constants into its spectrum input.'
Require-Match -Text $waterCausticCode -Pattern 'float lodFootprint = lerp\(CAUSTIC_LOD_NEAR, CAUSTIC_LOD_FAR, depthBlur\);' -Message 'Caustic spectrum filtering is not depth adaptive through the split LOD role.'
Require-Match -Text $waterCausticCode -Pattern '(?s)float2 p0 = causticLanding\(base, t, inc, h, lodFootprint, strength\);\s*float2 px = causticLanding\(base \+ float2\(CAUSTIC_JACOBIAN_EPS, 0\.0\), t, inc, h, lodFootprint, strength\);\s*float2 pz = causticLanding\(base \+ float2\(0\.0, CAUSTIC_JACOBIAN_EPS\), t, inc, h, lodFootprint, strength\);' -Message 'Caustic landing samples do not separate fixed Jacobian offsets from the shared LOD footprint.'
Require-Match -Text $waterCausticCode -Pattern 'float physicalFocus = \(CAUSTIC_JACOBIAN_EPS \* CAUSTIC_JACOBIAN_EPS\) / max\(det, 1\.0e-5\);' -Message 'Physical focus does not use the fixed Jacobian epsilon in its area numerator.'
Require-Match -Text $waterCode -Pattern 'public static const float CAUSTIC_SHALLOW_CONTRAST = 1\.65;' -Message 'Shallow physical focus has no bounded contrast recovery.'
Require-Match -Text $waterCode -Pattern 'public static const float CAUSTIC_MIN = 0\.45;' -Message 'The approved caustic minimum bound changed.'
Require-Match -Text $waterCode -Pattern 'public static const float CAUSTIC_MAX = 3\.2;' -Message 'The approved caustic maximum bound changed.'
Require-Match -Text $waterCode -Pattern 'public static const float CAUSTIC_FADE_START = 12\.0;' -Message 'The approved deep-caustic fade start changed.'
Require-Match -Text $waterCode -Pattern 'public static const float CAUSTIC_FADE_END = 42\.0;' -Message 'The approved deep-caustic fade end changed.'
Require-Match -Text $waterCausticCode -Pattern 'float fade = smoothstep\(0\.06, 0\.18, stableLightDir\.y\);' -Message 'The approved grazing-light fade changed.'
Require-Match -Text $waterCausticCode -Pattern 'float shallowWeight = 1\.0 - smoothstep\(0\.25, 3\.5, h\);' -Message 'Shallow caustic recovery is not limited to near water.'
Require-Match -Text $waterCausticCode -Pattern 'if \(strength <= 0\.0\) return 1\.0;' -Message 'Disabled caustics do not return the neutral value immediately.'
Require-Match -Text $waterCausticCode -Pattern '(?s)float amplitudeResponse = clamp\(strength, 0\.0, 2\.0\);\s*float shapedFocus = 1\.0 \+ \(softFocus - 1\.0\)\s*\* shallowContrast \* amplitudeResponse;' -Message 'Caustic focusing is not shaped around neutral by the live amplitude.'
Require-Match -Text $waterCausticCode -Pattern 'float focus = clamp\(shapedFocus, CAUSTIC_MIN, CAUSTIC_MAX\);' -Message 'The softened physical caustic factor is not bounded.'
Require-Match -Text $waterCausticCode -Pattern '(?s)float deepFade = smoothstep\(CAUSTIC_FADE_START, CAUSTIC_FADE_END, h\);\s*return lerp\(1\.0, focus, fade \* \(1\.0 - deepFade\)\);' -Message 'The approved 12-to-42-block deep caustic fade changed.'
Require-Match -Text $waterCausticCode -Pattern 'float stableLightDistance = depth / max\(stableLightDir\.y, 0\.05\);' -Message 'Caustics do not reconstruct stable slant distance from vertical water depth.'
Require-Match -Text $waterCausticCode -Pattern 'receiverPos\.xz \+ stableLightDir\.xz \* stableLightDistance \+ worldPush\.waterAnchor\.xy' -Message 'The caustic pattern is not anchored from the receiver using stable depth and light direction.'
$causticPathCode = $waterCausticDetailCode + $waterCausticGradCode + $causticLandingCode + $waterCausticCode
Require-NoMatch -Text $causticPathCode -Pattern '(?i)(?:\btexture\w*\s*\(|\bsampler\w*\b|\.\s*Sample(?:Cmp|Level|Grad)?\s*\(|\btexelFetch\s*\(|\bimageLoad\s*\()' -Message 'The caustic path introduces texture sampling.'
Require-NoMatch -Text $causticPathCode -Pattern '\b(?:traceGuide|traceRadiance|visibility)\s*\(' -Message 'The caustic helpers introduce a new ray or visibility call.'
Require-Match -Text $secondary -Pattern '(?s)float3 causticLightDir = normalize\(worldPush\.lightDir\.xyz\);\s*float3 lightDir = causticLightDir;' -Message 'Pass B does not establish a stable celestial direction before jittering NEE visibility.'
Require-Match -Text $secondary -Pattern 'float causticDepth = shadow\.waterHitT \* max\(lightDir\.y, 0\.0\);' -Message 'Front-face caustics do not recover vertical depth from the sampled shadow ray.'
Require-Match -Text $secondary -Pattern 'vis \*= waterCaustic\(p, causticLightDir, causticDepth, waterWaveStrength\);' -Message 'Pass B does not apply amplitude-aware stable-direction caustics to the existing visibility term.'
Require-Match -Text $secondary -Pattern 'float causticDepthBack = shadowBack\.waterHitT \* max\(lightDir\.y, 0\.0\);' -Message 'SSS back-face caustics do not recover vertical depth from the sampled shadow ray.'
Require-Match -Text $secondary -Pattern 'visB \*= waterCaustic\(\s*hitPos, causticLightDir, causticDepthBack, waterWaveStrength\);' -Message 'SSS back-face caustics do not share the amplitude-aware stable receiver interface.'
Require-NoMatch -Text $secondary -Pattern 'waterCaustic\([^;]*, lightDir, shadow\.waterHitT\)' -Message 'Pass B still drives caustic motion with the jittered NEE direction.'
Require-NoMatch -Text $secondary -Pattern 'waterCaustic\([^;]*shadow(Back)?\.waterHitT\)' -Message 'A caustic call still passes sampled slant distance instead of recovered vertical depth.'

# Direct absorption stays visibly clear nearby, becomes cyan with depth, and is independent of Water Fog Strength.
$approvedWaterBase = @(0.118, 0.052, 0.058)
$defaultTint = @(0.25, 0.46, 0.90)
$waterAbsorptionBaseMatch = [regex]::Match(
    $mediumCode,
    'public\s+static\s+const\s+float3\s+WATER_ABSORPTION_BASE\s*=\s*float3\(\s*(?<red>\d+\.\d+)\s*,\s*(?<green>\d+\.\d+)\s*,\s*(?<blue>\d+\.\d+)\s*\);'
)
$waterBiomeAbsorptionMatch = [regex]::Match(
    $mediumCode,
    'public\s+static\s+const\s+float\s+WATER_BIOME_ABSORPTION\s*=\s*(?<value>\d+\.\d+)\s*;'
)
if (-not $waterAbsorptionBaseMatch.Success -or -not $waterBiomeAbsorptionMatch.Success) {
    $failures.Add('Production water absorption constants could not be parsed for the depth anchors.')
} else {
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $productionWaterBase = @(
        [double]::Parse($waterAbsorptionBaseMatch.Groups['red'].Value, $culture),
        [double]::Parse($waterAbsorptionBaseMatch.Groups['green'].Value, $culture),
        [double]::Parse($waterAbsorptionBaseMatch.Groups['blue'].Value, $culture)
    )
    $productionBiomeAbsorption = [double]::Parse($waterBiomeAbsorptionMatch.Groups['value'].Value, $culture)
    $productionExtinction = 0..2 | ForEach-Object {
        $productionWaterBase[$_] + $productionBiomeAbsorption * (1.0 - $defaultTint[$_])
    }
    $productionTransmission = @{}
    foreach ($distance in @(1, 5, 10, 20)) {
        $values = @($productionExtinction | ForEach-Object { [Math]::Exp(-$_ * $distance) })
        $productionTransmission[$distance] = $values
        Write-Host ('Water transmission {0,2} block(s): R={1:F6}, G={2:F6}, B={3:F6}' -f `
                $distance, $values[0], $values[1], $values[2])
    }

    $oneBlock = $productionTransmission[1]
    if ($oneBlock[0] -le 0.85 -or $oneBlock[1] -le 0.85 -or $oneBlock[2] -le 0.85) {
        $failures.Add('One-block water transmission must be greater than 0.85 in every channel.')
    }
    $tenBlocks = $productionTransmission[10]
    if ($tenBlocks[0] -lt 0.20 -or $tenBlocks[0] -gt 0.27) { $failures.Add('Ten-block red transmission is outside 0.20..0.27.') }
    if ($tenBlocks[1] -lt 0.44 -or $tenBlocks[1] -gt 0.54) { $failures.Add('Ten-block green transmission is outside 0.44..0.54.') }
    if ($tenBlocks[2] -lt 0.49 -or $tenBlocks[2] -gt 0.60) { $failures.Add('Ten-block blue transmission is outside 0.49..0.60.') }
    $twentyBlocks = $productionTransmission[20]
    if ($twentyBlocks[0] -lt 0.04 -or $twentyBlocks[0] -gt 0.07) { $failures.Add('Twenty-block red transmission is outside 0.04..0.07.') }
    if ($twentyBlocks[1] -lt 0.19 -or $twentyBlocks[1] -gt 0.29) { $failures.Add('Twenty-block green transmission is outside 0.19..0.29.') }
    if ($twentyBlocks[2] -lt 0.24 -or $twentyBlocks[2] -gt 0.35) { $failures.Add('Twenty-block blue transmission is outside 0.24..0.35.') }

    foreach ($distance in @(1, 5, 10, 20)) {
        $values = $productionTransmission[$distance]
        if (-not ($values[2] -gt $values[1] -and $values[1] -gt $values[0])) {
            $failures.Add("Water transmission at $distance block(s) is not ordered B > G > R.")
        }
    }
    foreach ($channel in 0..2) {
        if (-not ($productionTransmission[1][$channel] -gt $productionTransmission[5][$channel] `
                -and $productionTransmission[5][$channel] -gt $productionTransmission[10][$channel] `
                -and $productionTransmission[10][$channel] -gt $productionTransmission[20][$channel])) {
            $channelName = @('red', 'green', 'blue')[$channel]
            $failures.Add("Water $channelName transmission does not strictly decrease across 1/5/10/20 blocks.")
        }
    }
}

Require-Match -Text $mediumCode -Pattern 'public static const float3 WATER_ABSORPTION_BASE = float3\(0\.118, 0\.052, 0\.058\);' -Message 'Water absorption is not calibrated to the approved emerald/cyan spectral baseline.'
Require-Match -Text $mediumCode -Pattern 'public static const float WATER_BIOME_ABSORPTION = 0\.035;' -Message 'Biome colour is not constrained to the unchanged subtle absorption influence.'
Require-Match -Text $mediumCode -Pattern '(?s)return WATER_ABSORPTION_BASE \+ WATER_BIOME_ABSORPTION\s*\* \(float3\(1\.0, 1\.0, 1\.0\) - clamp\(tint, 0\.0, 1\.0\)\);' -Message 'Water extinction does not combine the spectral baseline with the subtle biome term.'
Require-Match -Text $medium -Pattern 'public float waterTyndallPhase\(float cosTheta\)' -Message 'Water has no directional phase response for the Tyndall effect.'
Require-Match -Text $waterVolume -Pattern 'public static const uint WATER_VOLUME_SLICE_COUNT = 8u;' -Message 'Water volume integration does not use eight stable view-ray slices.'
Require-Match -Text $waterVolume -Pattern 'public static const float WATER_VOLUME_MAX_DISTANCE = 48\.0;' -Message 'Water volume shadow integration is not capped at 48 blocks.'
Require-NoMatch -Text $waterVolumeCode -Pattern 'WATER_TURBIDITY_EXTINCTION' -Message 'The obsolete turbidity-extinction constant name remains in production code.'
Require-Match -Text $waterVolumeCode -Pattern 'public static const float3 WATER_SCATTERING_COEFFICIENT = float3\(0\.018, 0\.018, 0\.018\);' -Message 'Water scattering has no explicitly named coefficient.'
Require-Match -Text $waterEffectiveExtinctionCode -Pattern '(?s)^public float3 waterEffectiveExtinction\(.*?\)\s*\{\s*return baseExtinction;\s*\}$' -Message 'Effective extinction still depends on Water Fog state or strength.'
Require-Match -Text $waterScatterPaletteCode -Pattern 'float3 shallowEmerald = float3\(0\.08, 0\.72, 0\.46\);' -Message 'Water volume does not use the approved shallow emerald palette endpoint.'
Require-Match -Text $waterScatterPaletteCode -Pattern 'float3 deepCyan = float3\(0\.04, 0\.36, 0\.68\);' -Message 'Water volume does not use the approved deep cyan palette endpoint.'
Require-Match -Text $waterScatterPaletteCode -Pattern 'return lerp\(shallowEmerald, deepCyan, depthMix\);' -Message 'Water volume does not interpolate the approved emerald/cyan palette endpoints.'
Require-Match -Text $waterVolume -Pattern '(?s)float marchDistance = min\(segmentDistance, WATER_VOLUME_MAX_DISTANCE\);.*?float stepLength = marchDistance / float\(WATER_VOLUME_SLICE_COUNT\);.*?float3 stepTransmittance = exp\(-effectiveExtinction \* stepLength\);.*?for \(uint slice = 0u; slice < WATER_VOLUME_SLICE_COUNT; \+\+slice\)' -Message 'Water scattering is not integrated over eight bounded, equal view-ray slices.'
Require-Match -Text $waterVolume -Pattern '(?s)uint jitterSeed = volumeSeed \^ worldPush\.frameIndex.*?pcg\(jitterSeed\).*?float sampleDistance = \(float\(slice\) \+ sliceJitter\) \* stepLength;' -Message 'Water volume slices are not decorrelated per path and frame, so moving silhouettes cannot converge cleanly.'
Require-Match -Text $waterVolume -Pattern '(?s)VisibilityResult shadow = visibility\(samplePosition, lightDir, 10000\.0\);.*?shadow\.waterHitT.*?exp\(-effectiveExtinction \* shadow\.waterHitT\)' -Message 'Each water slice does not apply geometric visibility plus underwater light-path Beer attenuation.'
Require-Match -Text $waterVolume -Pattern '(?s)float3 viewTransmittance = float3\(1\.0, 1\.0, 1\.0\);.*?viewTransmittance \*= stepTransmittance;' -Message 'Water volume integration does not recursively carry camera-to-slice transmittance.'
Require-Match -Text $waterVolume -Pattern 'result \+= viewTransmittance \* sliceScatteredEnergy' -Message 'Water slice energy does not use the exact slice-start transmittance.'
Require-NoMatch -Text $waterVolume -Pattern 'halfStepTransmittance|viewToSample' -Message 'Water slice energy still applies a duplicate half-step attenuation.'
Require-Match -Text $integrateWaterSingleScatterCode -Pattern '(?s)float strength = clamp\(waterFogStrength, 0\.0, 2\.0\);.*?float daylight = clamp\(.*?\);.*?if \(daylight <= 0\.0 \|\| strength <= 0\.0\) \{\s*return float3\(0\.0, 0\.0, 0\.0\);\s*\}' -Message 'Water scattering does not clamp strength or return zero for zero strength/daylight.'
Require-Match -Text $integrateWaterSingleScatterCode -Pattern '(?s)float3 scatteringCoefficient = WATER_SCATTERING_COEFFICIENT \* strength;.*?float3 scatteringFraction = clamp\(scatteringCoefficient\s*/ max\(effectiveExtinction, float3\(1\.0e-5.*?sliceScatteredEnergy = sliceLostEnergy \* scatteringFraction;' -Message 'Water volume does not keep its scattering coefficient separate from direct absorption.'
Require-Match -Text $waterVolume -Pattern '(?s)float3 normalizedLight = clamp\(max\(lightRadiance, 0\.0\) / 21\.0, 0\.0, 4\.0\);.*?normalizedLight.*?clamp\(shadow\.transmittance' -Message 'Directional water scattering does not preserve the actual sun/moon light spectrum and intensity.'
Require-Match -Text $integrateWaterSingleScatterCode -Pattern 'float3 result = lostEnergy \* scatteringFraction \* palette \* \(0\.080 \* daylight\);' -Message 'Water ambient scattering is not calibrated to 0.080 at 100% strength.'
Require-Match -Text $integrateWaterSingleScatterCode -Pattern 'float3 directionalLight = normalizedLight \* \(0\.125 \* phaseBoost\);' -Message 'Water directional scattering is not calibrated to 0.125 at 100% strength.'
Require-Match -Text $integrateWaterSingleScatterCode -Pattern 'float3 scatteringBound = lostEnergy \* palette \* \(0\.22 \* strength \* daylight\);' -Message 'Water scattering does not derive the approved component-wise energy bound.'
Require-Count -Text $integrateWaterSingleScatterCode -Pattern 'return min\(result, scatteringBound\);' -Expected 2 -Message 'Every integrated water-scattering return must apply the component-wise energy bound.'
Require-NoMatch -Text $integrateWaterSingleScatterCode -Pattern 'return result;' -Message 'Water scattering still has an unbounded result return.'
Require-NoMatch -Text $trace -Pattern 'waterSegmentLightVisibility(Sample)?\(' -Message 'The obsolete three-silhouette water visibility helpers remain in trace.slang.'
Require-Match -Text $config -Pattern 'WATER_FOG\s*=\s*\r?\n?\s*bool\("caustica\.rt\.waterFog", "composite\.water-fog", true\);' -Message 'Water Fog is not a persisted default-on runtime setting.'
Require-Match -Text $config -Pattern 'WATER_FOG_STRENGTH\s*=\s*\r?\n?\s*clampedFloat\("caustica\.rt\.waterFogStrength", "composite\.water-fog-strength", 1\.0f, 0\.0f, 2\.0f\);' -Message 'Water Fog Strength is not persisted and clamped to 0-200 percent.'
Require-Match -Text $config -Pattern 'WATER_WAVE_STRENGTH\s*=\s*\r?\n?\s*clampedFloat\("caustica\.rt\.waterWaveStrength", "composite\.water-wave-strength", 1\.0f, 0\.0f, 2\.0f\);' -Message 'Water Wave Strength is not persisted and clamped to 0-200 percent.'
Require-Match -Text $videoOptions -Pattern '(?s)waterWaves\(\),\s*waterWaveStrength\(\),\s*waterFog\(\),' -Message 'Water Fog is not exposed beside Animated Water and Water Wave Strength in Video Settings.'
Require-Match -Text $videoOptions -Pattern '(?s)waterWaves\(\),\s*waterWaveStrength\(\),\s*waterFog\(\),\s*waterFogStrength\(\),' -Message 'Water Wave Strength is not ordered beside Animated Water and Water Fog controls in Video Settings.'
Require-Match -Text $videoOptions -Pattern '(?s)waterFog\(\),\s*waterFogStrength\(\),' -Message 'Water Fog Strength is not exposed beside the Water Fog toggle.'
Require-Match -Text $videoOptions -Pattern '(?s)private static OptionInstance<Integer> waterFogStrength\(\).*?new OptionInstance\.IntRange\(0, 200\).*?setting\.set\(percent / 100\.0f\)' -Message 'Water Fog Strength is not a live 0-200 percent slider.'
Require-Match -Text $videoOptions -Pattern '(?s)private static OptionInstance<Integer> waterWaveStrength\(\).*?new OptionInstance\.IntRange\(0, 200\).*?setting\.set\(percent / 100\.0f\)' -Message 'Water Wave Strength is not a live 0-200 percent slider.'
Require-Match -Text $composite -Pattern '(?s)private static boolean waterFog\(\).*?WATER_FOG\.value\(\);' -Message 'The renderer does not re-read the Water Fog setting at runtime.'
Require-Match -Text $composite -Pattern '(?s)private static float waterWaveStrength\(\).*?WATER_WAVE_STRENGTH\.value\(\);' -Message 'The renderer does not re-read Water Wave Strength at runtime.'
Require-Match -Text $composite -Pattern 'flags \|= 0b100000;\s*// W2: water-medium fog and Tyndall scattering' -Message 'Water Fog is not published through its dedicated world flag.'
Require-Match -Text $composite -Pattern 'new Float4\(terrain\.blockX & WATER_ANCHOR_MASK,\s*terrain\.blockZ & WATER_ANCHOR_MASK, priorWaterWaveTime, waterFogStrength\(\)\)' -Message 'Water Fog Strength is not published every frame through waterAnchor.w.'
Require-Match -Text $composite -Pattern 'new Float4\(waterWaveStrength\(\), 0\.0f, 0\.0f, 0\.0f\)' -Message 'Water Wave Strength is not published every frame through waterTuning.x.'
Require-Match -Text $worldCommon -Pattern 'bit0 submerged, bit4 waves, bit5 water fog' -Message 'The WorldPush flag contract does not reserve bit 5 for water fog.'
Require-Match -Text $worldCommon -Pattern 'public float4\s+waterTuning;\s*// x wave strength 0\.\.2, yzw reserved' -Message 'WorldPush waterTuning does not declare the reserved wave-strength lane.'
Require-Match -Text $worldCommon -Pattern '(?s)public float4\s+waterAnchor;.*?public float4\s+waterTuning;.*?public float4x4\s+curViewProj;' -Message 'WorldPush waterTuning is not positioned between waterAnchor and curViewProj.'
Require-Match -Text $composite -Pattern '(?s)waterAnchor,\s*new Float4\(waterWaveStrength\(\), 0\.0f, 0\.0f, 0\.0f\),\s*mvCurProjView,' -Message 'RtComposite does not serialize waterTuning in the WorldPush ABI order.'
Require-Match -Text $generatedWorldPush -Pattern '(?m)^\s*public static final int BYTE_SIZE = 672;\s*$' -Message 'Generated WorldPushData BYTE_SIZE is not 672.'
Require-Match -Text $generatedWorldPush -Pattern '(?m)^\s*dst\.putFloat\(384, waterTuning\(\)\.x\(\)\);\s*$' -Message 'Generated waterTuning.x is not stored at byte 384.'
Require-Match -Text $generatedWorldPush -Pattern '(?m)^\s*dst\.putFloat\(384 \+ 4, waterTuning\(\)\.y\(\)\);\s*$' -Message 'Generated waterTuning.y is not stored at byte 388.'
Require-Match -Text $generatedWorldPush -Pattern '(?m)^\s*dst\.putFloat\(384 \+ 8, waterTuning\(\)\.z\(\)\);\s*$' -Message 'Generated waterTuning.z is not stored at byte 392.'
Require-Match -Text $generatedWorldPush -Pattern '(?m)^\s*dst\.putFloat\(384 \+ 12, waterTuning\(\)\.w\(\)\);\s*$' -Message 'Generated waterTuning.w is not stored at byte 396.'
Require-Match -Text $generatedWorldPush -Pattern '(?m)^\s*curViewProj\(\)\.get\(400, dst\);\s*$' -Message 'Generated curViewProj does not begin at byte 400.'

$expectedExecutableCalls = @{ traceGuide = 2; traceRadiance = 2; visibility = 6 }
foreach ($functionName in $expectedExecutableCalls.Keys) {
    $actualCount = Get-ExecutableCallCount -Texts $allShaderTexts -FunctionName $functionName
    if ($actualCount -ne $expectedExecutableCalls[$functionName]) {
        $failures.Add("Executable $functionName call count is $actualCount; expected $($expectedExecutableCalls[$functionName]).")
    }
}
Require-Match -Text $secondary -Pattern 'bool waterFog = \(worldPush\.flags & 32u\) != 0u;' -Message 'Pass B does not read the dedicated Water Fog flag.'
Require-Match -Text $secondary -Pattern '(?s)float3 rawLightDirForWater = worldPush\.lightDir\.xyz;.*?float lightDirLengthSq = dot\(rawLightDirForWater, rawLightDirForWater\);.*?float3 lightDirForWater = rawLightDirForWater \* rsqrt\(max\(lightDirLengthSq, 1\.0e-8\)\);' -Message 'Water Tyndall light direction is not normalized safely for a zero-light frame.'
Require-NoMatch -Text $secondary -Pattern 'float3 lightDirForWater = normalize\(worldPush\.lightDir\.xyz\)' -Message 'Water Tyndall still uses undefined zero-vector normalization.'
Require-Match -Text $secondary -Pattern '(?s)import water_volume;.*?float3 effectiveExtinction = waterEffectiveExtinction\(.*?\);.*?L \+= throughput \* integrateWaterSingleScatter\(\s*ro, rd, segmentDistance, effectiveExtinction, segmentTransmittance,.*?waterFogStrength, seed\);.*?throughput \*= segmentTransmittance;' -Message 'Pass B does not integrate continuous water scattering before its matching Beer attenuation.'
Require-Match -Text $secondary -Pattern '(?s)integrateWaterSingleScatter\(.*?waterFogStrength, seed\)' -Message 'Pass B does not provide a per-path seed for water-volume decorrelation.'
# Pass A consumes the camera-to-first-dielectric segment. Its water scattering is written once as a
# per-pixel prefix; Pass B reads that prefix before averaging the split continuations, avoiding omission
# for a submerged camera and avoiding double-counting across reflection/refraction branches.
Require-Match -Text $primary -Pattern '(?s)public PathSegment tracePrimary\(.*?out float3 prefixRadiance\).*?prefixRadiance = float3\(0\.0, 0\.0, 0\.0\);' -Message 'Pass A does not expose a single per-pixel prefix-radiance accumulator.'
Require-Match -Text $primary -Pattern '(?s)import water_volume;.*?float3 effectiveExtinction = waterEffectiveExtinction\(.*?\);.*?prefixRadiance \+= throughput \* integrateWaterSingleScatter\(\s*ro, rd, payload\.hitT, effectiveExtinction, segmentTransmittance,.*?waterFogStrength, seed\);.*?throughput \*= segmentTransmittance;' -Message 'Pass A does not add continuous water scattering before absorbing its consumed camera segment.'
Require-Match -Text $primary -Pattern '(?s)integrateWaterSingleScatter\(.*?waterFogStrength, seed\)' -Message 'Pass A does not provide a per-pixel path seed for water-volume decorrelation.'
Require-Match -Text $primary -Pattern '(?s)float3 prefixRadiance;\s*PathSegment terminal = tracePrimary\(\s*current, queue, splitRecord, pixelIndex, nextRecord, prefixRadiance\);\s*outImage\[pix\] = float4\(prefixRadiance, 1\.0\);' -Message 'Pass A does not publish the consumed-segment radiance exactly once for Pass B.'
Require-Match -Text $secondary -Pattern 'float3 prefixRadiance = outImage\[pix\]\.xyz;' -Message 'Pass B does not recover Pass A consumed-segment radiance.'
Require-Match -Text $secondary -Pattern 'outImage\[pix\] = float4\(prefixRadiance \+ frameRadiance / float\(spp\), 1\.0\);' -Message 'Pass B does not add the Pass A prefix after averaging its continuation samples.'
Require-Match -Text $guides -Pattern 'import water_volume;' -Message 'Transmission guides do not share the effective water extinction implementation.'
Require-NoMatch -Text $guides -Pattern 'integrateWaterSingleScatter\(' -Message 'Transmission guides must remain radiance-free and contain absorption only.'
Require-Match -Text $english -Pattern ([regex]::Escape('"caustica.options.rt.waterFogStrength.tooltip": "Scales underwater emerald/cyan haze and Tyndall shafts. Direct water absorption and deep-water transmission stay fixed."')) -Message 'English Water Fog Strength tooltip does not describe scattering-only control.'
Require-Match -Text $chinese -Pattern ([regex]::Escape('"caustica.options.rt.waterFogStrength.tooltip": "调整水下翠绿/青蓝雾气和丁达尔光束；水体直接吸收与深水透射保持不变。"')) -Message 'Chinese Water Fog Strength tooltip does not describe scattering-only control.'
Require-Match -Text $english -Pattern '"caustica\.options\.rt\.waterWaveStrength": "Water Wave Strength"' -Message 'English Water Wave Strength name is missing.'
Require-Match -Text $english -Pattern '"caustica\.options\.rt\.waterWaveStrength\.tooltip"' -Message 'English Water Wave Strength tooltip is missing.'
Require-Match -Text $chinese -Pattern '"caustica\.options\.rt\.waterWaveStrength": "水波幅度"' -Message 'Chinese Water Wave Strength name is missing.'
Require-Match -Text $chinese -Pattern '"caustica\.options\.rt\.waterWaveStrength\.tooltip"' -Message 'Chinese Water Wave Strength tooltip is missing.'

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-Error $failure -ErrorAction Continue
    }
    exit 1
}

Write-Host 'Wavefront water/glass port contract passed.'
