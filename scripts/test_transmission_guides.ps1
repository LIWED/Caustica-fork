$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$shaderPath = Join-Path $projectRoot 'shaders\world\world.rgen.slang'
$shaderText = Get-Content -Raw -LiteralPath $shaderPath

function Get-RequiredRegion {
    param(
        [string] $Text,
        [string] $StartMarker,
        [string] $EndMarker,
        [string] $Description
    )

    $start = $Text.IndexOf($StartMarker)
    $end = if ($start -ge 0) { $Text.IndexOf($EndMarker, $start) } else { -1 }
    if ($start -lt 0 -or $end -lt 0) {
        throw "Could not isolate $Description."
    }
    return $Text.Substring($start, $end - $start)
}

$helper = Get-RequiredRegion $shaderText 'void transmissionGuideHit(' '// One Monte Carlo path' 'the transmission-guide helper'
$tracePathStart = $shaderText.IndexOf('float3 tracePath(')
if ($tracePathStart -lt 0) {
    throw 'Could not isolate tracePath.'
}
$tracePath = $shaderText.Substring($tracePathStart)
$glassBranch = Get-RequiredRegion $tracePath 'if (material == MATERIAL_GLASS) {' '// Particles (material == 2)' 'the primary glass branch'
$particleBranch = Get-RequiredRegion $tracePath 'if (material == MATERIAL_PARTICLE) {' '// Water: smooth dielectric interface.' 'the primary particle branch'
$waterBranch = Get-RequiredRegion $tracePath 'if (material == MATERIAL_WATER) {' 'float3 albedo = payload.albedo;' 'the primary water branch'
$reflectionMotion = Get-RequiredRegion $shaderText 'float2 specularReflectionMotion(' '// Follow glass/water transmission' 'the reflection-motion helper'

if ($shaderText.Contains('void refractedGuideHit(')) {
    throw 'The one-interface refractedGuideHit helper must be replaced.'
}
if (-not $shaderText.Contains('static const int MAX_TRANSMISSION_GUIDE_INTERFACES = 4;')) {
    throw 'The transmission guide must define a four-interface traversal budget.'
}
if (-not $helper.Contains('uint surfaceMaterial,') -or
        -not $helper.Contains('bool waterEnteringAtSurface,') -or
        -not $helper.Contains('out bool transmitted,')) {
    throw 'transmissionGuideHit is missing required interface state or outputs.'
}
if (-not $shaderText.Contains('static bool gv_reflectionMotionValid;')) {
    throw 'Reflection motion must have a first-interface validity flag independent of endpoint specular albedo.'
}
if (-not $reflectionMotion.Contains('!gv_reflectionMotionValid') -or
        $reflectionMotion.Contains('max(gv_specAlb.r')) {
    throw 'Reflection motion must gate on first-interface validity, not transmitted endpoint specular albedo.'
}
if (-not $reflectionMotion.Contains('length(gv_normal) < 0.5') -or
        -not $reflectionMotion.Contains('gv_rough > 0.5')) {
    throw 'Reflection motion must retain its normal and roughness gates.'
}

$fallbackEnd = $helper.IndexOf('float3 guideDir = normalize(incidentDir);')
$fallback = if ($fallbackEnd -ge 0) { $helper.Substring(0, $fallbackEnd) } else { '' }
if (-not $fallback.Contains('hitCamRel = surfacePos - pc.camOffset;') -or
        -not $fallback.Contains('motionPrev = float3(0.0, 0.0, 0.0);') -or
        -not $fallback.Contains('transmitted = false;') -or
        -not $fallback.Contains('diffuseAlbedo = float3(0.0, 0.0, 0.0);')) {
    throw 'Transmission-guide failure paths must retain the first-surface, zero-guide fallback.'
}

$initialGlassStart = $helper.IndexOf('if (surfaceMaterial == MATERIAL_GLASS)')
$initialWaterStart = $helper.IndexOf('} else if (surfaceMaterial == MATERIAL_WATER)', $initialGlassStart)
$initialEnd = $helper.IndexOf('bool waterWaves =', $initialWaterStart)
if ($initialGlassStart -lt 0 -or $initialWaterStart -lt 0 -or $initialEnd -lt 0) {
    throw 'Could not isolate initial glass/water transmission setup.'
}
$initialGlass = $helper.Substring($initialGlassStart, $initialWaterStart - $initialGlassStart)
$initialWater = $helper.Substring($initialWaterStart, $initialEnd - $initialWaterStart)
if (-not $initialGlass.Contains('ro = surfacePos - guideNormal * GLASS_TRANSMIT_BIAS;') -or
        $initialGlass.Contains('refract(')) {
    throw 'Initial glass transmission must continue straight without refraction.'
}
$initialWaterRefract = $initialWater.IndexOf('guideDir = refract(')
$initialWaterTir = $initialWater.IndexOf('if (dot(guideDir, guideDir) <= 0.0)')
$initialWaterState = $initialWater.IndexOf('guideInWater = waterEnteringAtSurface;')
$initialTirBlock = if ($initialWaterTir -ge 0 -and $initialWaterState -gt $initialWaterTir) {
    $initialWater.Substring($initialWaterTir, $initialWaterState - $initialWaterTir)
} else { '' }
if ($initialWaterRefract -lt 0 -or $initialWaterTir -lt $initialWaterRefract -or
        $initialWaterState -lt $initialWaterTir -or
        -not $initialTirBlock.Contains('return;') -or $initialTirBlock.Contains('transmitted = true;')) {
    throw 'Initial water must refract, return safely on TIR, then adopt waterEnteringAtSurface.'
}

if (-not $helper.Contains('int crossedInterfaceCount = 1;') -or
        -not $helper.Contains('guideTraceIndex < MAX_TRANSMISSION_GUIDE_INTERFACES')) {
    throw 'The helper must count the crossed first surface and retain a bounded endpoint trace.'
}
if (-not $helper.Contains('traceRadianceReordered(CULL_SECONDARY, ro, RAY_TMIN,')) {
    throw 'Transmission guides must use the secondary cull mask, RAY_TMIN, and radiance trace helper.'
}

$loopStart = $helper.IndexOf('guideTraceIndex < MAX_TRANSMISSION_GUIDE_INTERFACES')
$budgetGuard = $helper.IndexOf('if (crossedInterfaceCount >= MAX_TRANSMISSION_GUIDE_INTERFACES)', $loopStart)
$loopGlass = $helper.IndexOf('if (material == MATERIAL_GLASS)', $loopStart)
$loopWater = $helper.IndexOf('if (material == MATERIAL_WATER)', $loopStart)
if ($budgetGuard -lt 0 -or $loopGlass -lt $budgetGuard -or $loopWater -lt $budgetGuard) {
    throw 'A terminal transparent hit must stop before crossing a fifth interface.'
}
$loopGlassBlock = $helper.Substring($loopGlass, $loopWater - $loopGlass)
$loopWaterBlock = $helper.Substring($loopWater)
$glassCross = $loopGlassBlock.IndexOf('ro = hitPos - payload.normal * GLASS_TRANSMIT_BIAS;')
$glassIncrement = $loopGlassBlock.IndexOf('crossedInterfaceCount++;')
if ($glassCross -lt 0 -or $glassIncrement -lt $glassCross) {
    throw 'A traversed glass interface must increment the transparent-interface count.'
}

$skyStart = $helper.IndexOf('if (payload.hitT < 0.0)', $loopStart)
$opaqueStart = $helper.IndexOf('if (material == MATERIAL_OPAQUE)', $skyStart)
$skyBlock = if ($skyStart -ge 0 -and $opaqueStart -gt $skyStart) {
    $helper.Substring($skyStart, $opaqueStart - $skyStart)
} else { '' }
if (-not $skyBlock.Contains('hitCamRel = (ro + guideDir * 1.0e6) - pc.camOffset;') -or
        -not $skyBlock.Contains('motionPrev = float3(0.0, 0.0, 0.0);') -or
        -not $skyBlock.Contains('diffuseAlbedo =') -or
        -not $skyBlock.Contains('transmitted = true;')) {
    throw 'A sky endpoint must publish far-hit, motion, albedo, and transmitted guides.'
}
$opaqueBlock = if ($opaqueStart -ge 0 -and $budgetGuard -gt $opaqueStart) {
    $helper.Substring($opaqueStart, $budgetGuard - $opaqueStart)
} else { '' }
if (-not $opaqueBlock.Contains('hitCamRel = hitPos - pc.camOffset;') -or
        -not $opaqueBlock.Contains('motionPrev = payload.motionPrev;') -or
        -not $opaqueBlock.Contains('diffuseAlbedo =') -or
        -not $opaqueBlock.Contains('transmitted = true;')) {
    throw 'An opaque endpoint must publish hit, object motion, PBR albedo, and transmitted guides.'
}

$guideTransmissionInitIndex = $helper.IndexOf('float3 guideTransmission = initialGlassTransmission;')
$guideGlassTransmissionIndex = $loopGlassBlock.IndexOf(
        'guideTransmission *= sqrt(clamp(payload.albedo, 0.0, 1.0));')
$guideTraceIndex = $helper.IndexOf('traceRadianceReordered(CULL_SECONDARY, ro, RAY_TMIN,', $loopStart)
$guideSegmentDistanceMatch = [regex]::Match(
        $helper,
        'float\s+guideSegmentDistance\s*=\s*payload\.hitT\s*<\s*0\.0\s*\?\s*10000\.0\s*:\s*payload\.hitT\s*;')
$guideSegmentDistanceIndex = if ($guideSegmentDistanceMatch.Success) {
    $guideSegmentDistanceMatch.Index
} else {
    -1
}
$guideWaterBeerMatch = [regex]::Match(
        $helper,
        '(?s)if\s*\(\s*guideInWater\s*\)\s*\{\s*guideTransmission\s*\*=\s*exp\(\s*-guideWaterExt\s*\*\s*guideSegmentDistance\s*\);\s*\}')
$guideWaterBeerIndex = if ($guideWaterBeerMatch.Success) { $guideWaterBeerMatch.Index } else { -1 }
$guideMediumUpdateBeforeBeer = if ($guideTraceIndex -ge 0 -and $guideWaterBeerIndex -gt $guideTraceIndex) {
    $helper.Substring($guideTraceIndex, $guideWaterBeerIndex - $guideTraceIndex) -match 'guideInWater\s*='
} else {
    $true
}
$guideUsesUnsafeHitDistance = $helper -match
        'exp\(\s*-guideWaterExt\s*\*\s*payload\.hitT\s*\)'
$skyGuideTransmissionIndex = $skyBlock.IndexOf('diffuseAlbedo = guideTransmission * SKY_DIFF_ALBEDO;')
$opaqueGuideTransmissionIndex = $opaqueBlock.IndexOf('diffuseAlbedo = guideTransmission *')
if (-not $helper.Contains('float3 initialGlassTransmission,') -or
        -not $helper.Contains('float3 guideWaterExt,') -or
        $guideTransmissionInitIndex -lt 0 -or
        $guideGlassTransmissionIndex -lt 0 -or
        $guideTraceIndex -lt 0 -or
        $guideSegmentDistanceIndex -lt $guideTraceIndex -or
        $guideWaterBeerIndex -lt 0 -or
        $guideWaterBeerIndex -lt $guideSegmentDistanceIndex -or
        $guideWaterBeerIndex -ge $skyStart -or
        $guideMediumUpdateBeforeBeer -or
        $guideUsesUnsafeHitDistance -or
        $skyGuideTransmissionIndex -lt 0 -or
        $opaqueGuideTransmissionIndex -lt 0) {
    throw 'Transmission-guide attenuation must use hit distance or a 10000-unit miss horizon without amplifying sky guides.'
}

$cachedEntering = $helper.IndexOf('bool waterEntering = payloadWaterEntering();', $loopWater)
$waterRefraction = $helper.IndexOf('refract(', $cachedEntering)
$waterTir = $helper.IndexOf('if (dot(nextDir, nextDir) <= 0.0)', $waterRefraction)
$waterMediumUpdate = $helper.IndexOf('guideInWater = waterEntering;', $cachedEntering)
$waterCross = $helper.IndexOf('ro = hitPos - n * SURF_BIAS;', $waterMediumUpdate)
$waterIncrement = $helper.IndexOf('crossedInterfaceCount++;', $waterCross)
$waterContinue = $helper.IndexOf('continue;', $waterIncrement)
$laterWaterRefresh = [regex]::Match(
        $helper,
        '(?s)if\s*\(\s*waterEntering\s*\)\s*\{\s*guideWaterExt\s*=\s*waterExtinction\(\s*payload\.albedo\s*\)\s*;\s*\}')
$laterWaterRefreshCount = [regex]::Matches(
        $helper,
        'guideWaterExt\s*=\s*waterExtinction\(\s*payload\.albedo\s*\)\s*;').Count
if ($loopWater -lt 0 -or $cachedEntering -lt 0) {
    throw 'Every traversed water interface must cache its entering flag.'
}
if ($waterRefraction -lt 0 -or $waterTir -lt $waterRefraction -or $waterMediumUpdate -lt 0 -or
        $cachedEntering -gt $waterRefraction -or
        $waterRefraction -gt $waterMediumUpdate -or $waterCross -lt $waterMediumUpdate -or
        $waterIncrement -lt $waterCross) {
    throw 'A traversed water entering flag must be cached before refraction and consumed before the next trace.'
}
if (-not $laterWaterRefresh.Success -or $laterWaterRefreshCount -ne 1 -or
        $laterWaterRefresh.Index -le $guideWaterBeerIndex -or
        $laterWaterRefresh.Index -ge $waterMediumUpdate -or
        $laterWaterRefresh.Index -ge $waterContinue) {
    throw 'Later-water extinction must refresh only on entering, after prior-segment attenuation and before medium continuation.'
}
$waterTirBlock = $helper.Substring($waterTir, $waterMediumUpdate - $waterTir)
if (-not $waterTirBlock.Contains('return;') -or $waterTirBlock.Contains('transmitted = true;')) {
    throw 'Traversed-water TIR must return with the initialized first-surface fallback.'
}
$initialGuideRefraction = [regex]::Match(
        $initialWater,
        'refract\(guideDir,\s*guideNormal,\s*etaI\s*/\s*etaT\)')
$initialGuideUsesWaves = $initialWater.Contains('applyWaterWaves(')
$guideWaterRefraction = [regex]::Match(
        $loopWaterBlock,
        '(?s)float3\s+(?<normal>[A-Za-z_]\w*)\s*=\s*payload\.normal;.*?float3\s+nextDir\s*=\s*refract\(guideDir,\s*\k<normal>,\s*etaI\s*/\s*etaT\)')
$guideRefractionNormal = if ($guideWaterRefraction.Success) {
    $guideWaterRefraction.Groups['normal'].Value
} else {
    ''
}
$guideRefractionUsesWaves = $guideRefractionNormal -ne '' -and
        $loopWaterBlock -match ('applyWaterWaves\(\s*' + [regex]::Escape($guideRefractionNormal) + '\s*,')
if (-not $initialGuideRefraction.Success -or $initialGuideUsesWaves -or
        -not $guideWaterRefraction.Success -or $guideRefractionUsesWaves) {
    throw 'Initial and traversed water transmission guides must refract through unanimated geometric normals.'
}

foreach ($caller in @(
        @{ Name = 'glass'; Text = $glassBranch },
        @{ Name = 'water'; Text = $waterBranch }
    )) {
    $call = $caller.Text.IndexOf('transmissionGuideHit(')
    $save = $caller.Text.IndexOf('Payload primaryPayload = payload;')
    $restore = if ($call -ge 0) { $caller.Text.IndexOf('payload = primaryPayload;', $call) } else { -1 }
    $callEnd = if ($call -ge 0) { $caller.Text.IndexOf(');', $call) } else { -1 }
    if ($call -lt 0) {
        throw "The primary $($caller.Name) branch must call transmissionGuideHit."
    }
    if ($save -lt 0 -or $save -gt $call) {
        throw "The primary $($caller.Name) payload must be saved before transmissionGuideHit."
    }
    if ($restore -lt 0) {
        throw "The primary $($caller.Name) payload must be restored after transmissionGuideHit."
    }
    if ($callEnd -lt 0 -or $restore -lt $callEnd -or
            $caller.Text.Substring($callEnd + 2, $restore - ($callEnd + 2)) -notmatch '^\s*$') {
        throw "The primary $($caller.Name) payload restore must be the first statement after guide tracing."
    }
    $guideCallText = $caller.Text.Substring($call, $callEnd - $call)
    if (-not $guideCallText.Contains('gv_motionHitCamRel, gv_motionObjDisp, gv_motionUseRefracted')) {
        throw "The primary $($caller.Name) ordinary motion guide must use the helper endpoint."
    }
}

$glassGuideCall = $glassBranch.IndexOf('transmissionGuideHit(')
$glassGuideCallEnd = if ($glassGuideCall -ge 0) { $glassBranch.IndexOf(');', $glassGuideCall) } else { -1 }
$glassGuideCallText = if ($glassGuideCallEnd -gt $glassGuideCall) {
    $glassBranch.Substring($glassGuideCall, $glassGuideCallEnd - $glassGuideCall)
} else {
    ''
}
$glassRestore = $glassBranch.IndexOf('payload = primaryPayload;', $glassGuideCall)
$glassGuideAssignment = $glassBranch.IndexOf('gv_normal = n;', $glassGuideCall)
if ($glassRestore -lt 0 -or $glassGuideAssignment -lt 0 -or $glassRestore -gt $glassGuideAssignment) {
    throw 'The glass primary payload must be restored immediately after guide tracing.'
}
if (-not $glassBranch.Contains('gv_hitCamRel = hitPos - pc.camOffset;') -or
        -not $glassBranch.Contains('gv_normal = n;') -or
        -not $glassBranch.Contains('gv_rough = GLASS_GUIDE_ROUGH;')) {
    throw 'Glass normal, roughness, and depth identity must remain on the first surface.'
}
if (-not $glassBranch.Contains('gv_albedo = transmittedAlbedo;')) {
    throw 'Glass diffuse albedo must remain sourced from transmitted content.'
}
if ($glassGuideCallText -notmatch 'sqrt\(clamp\(glassTint,\s*0\.0,\s*1\.0\)\)' -or
        -not $glassGuideCallText.Contains('waterExt')) {
    throw 'Primary glass must seed transmission-guide tint and water extinction from the first interface.'
}
if ($glassBranch -notmatch '(?s)gv_specAlb\s*=\s*rrSpecularAlbedo\(\s*glassF0,\s*GLASS_GUIDE_ROUGH\s*\*\s*GLASS_GUIDE_ROUGH,\s*cosI\s*\);' -or
        $glassBranch.Contains('gv_specAlb = transmittedSpecAlbedo;')) {
    throw 'Glass specular guide must use first-interface dielectric F0, guide roughness, and view cosine rather than the transmitted endpoint.'
}
$glassFresnelBranch = $glassBranch.IndexOf('if (rndf(seed) < F)')
$glassTransmissionElse = $glassBranch.IndexOf('} else {', $glassFresnelBranch)
$glassFresnelEnd = $glassBranch.IndexOf('showCelestial = true;', $glassTransmissionElse)
if ($glassFresnelBranch -lt 0 -or $glassTransmissionElse -lt 0 -or $glassFresnelEnd -lt 0) {
    throw 'Could not isolate the glass Fresnel reflection/transmission continuation.'
}
$glassBeforeFresnel = $glassBranch.Substring(0, $glassFresnelBranch)
$glassReflectionContinuation =
        $glassBranch.Substring($glassFresnelBranch, $glassTransmissionElse - $glassFresnelBranch)
$glassTransmissionContinuation =
        $glassBranch.Substring($glassTransmissionElse, $glassFresnelEnd - $glassTransmissionElse)
$glassSqrtThroughputPattern =
        'throughput\s*\*=\s*sqrt\(\s*clamp\(\s*glassTint,\s*0\.0,\s*1\.0\s*\)\s*\)\s*;'
if ($glassBeforeFresnel -match $glassSqrtThroughputPattern -or
        $glassReflectionContinuation -match $glassSqrtThroughputPattern -or
        [regex]::Matches($glassTransmissionContinuation, $glassSqrtThroughputPattern).Count -ne 1 -or
        $glassBranch -match 'throughput\s*\*=\s*glassTint\s*;') {
    throw 'Glass square-root tint must apply exactly once inside successful Fresnel transmission and never on reflection.'
}
if (-not $glassBranch.Contains('gv_reflectionMotionValid = true;')) {
    throw 'Primary glass must retain reflection motion even when the transmission guide falls back.'
}
if (-not $particleBranch.Contains('gv_reflectionMotionValid = false;')) {
    throw 'Primary particles must explicitly disable reflection motion.'
}

$waterGuideCall = $waterBranch.IndexOf('transmissionGuideHit(')
$waterGuideCallEnd = if ($waterGuideCall -ge 0) { $waterBranch.IndexOf(');', $waterGuideCall) } else { -1 }
$waterGuideCallText = if ($waterGuideCallEnd -gt $waterGuideCall) {
    $waterBranch.Substring($waterGuideCall, $waterGuideCallEnd - $waterGuideCall)
} else {
    ''
}
$waterEntering = $waterBranch.IndexOf('bool waterEntering = payloadWaterEntering();')
$primaryWaterExtRefresh =
        $waterBranch.IndexOf('waterExt = waterExtinction(payload.albedo);')
$waterRestore = $waterBranch.IndexOf('payload = primaryPayload;', $waterGuideCall)
$waterEta = $waterBranch.IndexOf('float etaI = inWater ? WATER_IOR : 1.0;')
if ($waterEntering -lt 0 -or $waterEntering -gt $waterGuideCall) {
    throw 'The primary water entering flag must be cached before transmissionGuideHit.'
}
if ($primaryWaterExtRefresh -lt 0 -or $primaryWaterExtRefresh -ge $waterGuideCall) {
    throw 'Primary water extinction must refresh from its interface payload before auxiliary guide tracing.'
}
if ($waterRestore -lt 0 -or $waterRestore -gt $waterEta) {
    throw 'The primary water payload must be restored immediately after the guide and before continuation reads.'
}
if ($waterGuideCallText -notmatch 'float3\(1\.0' -or -not $waterGuideCallText.Contains('waterExt')) {
    throw 'Primary water must seed transmission-guide neutral tint and its current water extinction.'
}
$primaryWaterGeometry = [regex]::Match(
        $waterBranch,
        'float3\s+(?<normal>[A-Za-z_]\w*)\s*=\s*(?:n|payload\.normal)\s*;')
$primaryTransmissionNormal = if ($primaryWaterGeometry.Success) {
    $primaryWaterGeometry.Groups['normal'].Value
} else {
    ''
}
$primaryCachedRefraction = if ($primaryTransmissionNormal -ne '') {
    $cachedRefractionPattern =
            'float3\s+(?<direction>[A-Za-z_]\w*)\s*=\s*refract\(\s*rd,\s*{0},\s*etaI\s*/\s*etaT\s*\)\s*;' -f
            [regex]::Escape($primaryTransmissionNormal)
    [regex]::Match($waterBranch, $cachedRefractionPattern)
} else {
    [regex]::Match('', 'never')
}
$primaryTransmissionDirection = if ($primaryCachedRefraction.Success) {
    $primaryCachedRefraction.Groups['direction'].Value
} else {
    ''
}
$primaryRefractionUsesWaves = $primaryTransmissionNormal -ne '' -and
        $waterBranch -match ('applyWaterWaves\(\s*' + [regex]::Escape($primaryTransmissionNormal) + '\s*,')
$primaryFirstWaveIndex = $waterBranch.IndexOf('applyWaterWaves(')
$primaryGeometryDeclarationCount = if ($primaryTransmissionNormal -ne '') {
    [regex]::Matches(
            $waterBranch,
            ('\bfloat3\s+' + [regex]::Escape($primaryTransmissionNormal) + '\s*=')).Count
} else {
    0
}
$primaryGeometryReassignmentCount = if ($primaryTransmissionNormal -ne '') {
    [regex]::Matches(
            $waterBranch,
            ('(?m)^\s*' + [regex]::Escape($primaryTransmissionNormal) + '\s*=')).Count
} else {
    0
}
$guideUsesPrimaryTransmissionNormal = $primaryTransmissionNormal -ne '' -and
        $waterGuideCallText -match ('(?<![A-Za-z0-9_])' + [regex]::Escape($primaryTransmissionNormal) + '(?![A-Za-z0-9_])')
if (-not $primaryWaterGeometry.Success -or -not $primaryCachedRefraction.Success -or
        $primaryFirstWaveIndex -lt 0 -or
        $primaryWaterGeometry.Index -ge $primaryFirstWaveIndex -or
        $primaryWaterGeometry.Index -ge $waterGuideCall -or
        $primaryWaterGeometry.Index -ge $primaryCachedRefraction.Index -or
        $primaryGeometryDeclarationCount -ne 1 -or
        $primaryGeometryReassignmentCount -ne 0 -or
        $primaryRefractionUsesWaves -or -not $guideUsesPrimaryTransmissionNormal) {
    throw 'Primary water must cache a geometric transmission direction shared with its unanimated auxiliary guide.'
}
if (-not $waterBranch.Contains('gv_albedo = transmittedAlbedo;')) {
    throw 'Water diffuse albedo must remain sourced from transmitted content.'
}
if ($waterBranch -notmatch '(?s)gv_specAlb\s*=\s*rrSpecularAlbedo\(\s*waterF0,\s*WATER_GUIDE_ROUGH\s*\*\s*WATER_GUIDE_ROUGH,\s*cosI\s*\);' -or
        $waterBranch.Contains('gv_specAlb = transmittedSpecAlbedo;')) {
    throw 'Water specular guide must use first-interface dielectric F0, guide roughness, and view cosine rather than the transmitted endpoint.'
}
if (-not $waterBranch.Contains('gv_hitCamRel = hitPos - pc.camOffset;') -or
        -not $waterBranch.Contains('gv_normal = n;') -or
        -not $waterBranch.Contains('gv_rough = WATER_GUIDE_ROUGH;')) {
    throw 'Water normal, roughness, and depth identity must remain on the first surface.'
}
if (-not $waterBranch.Contains('gv_reflectionMotionValid = true;')) {
    throw 'Primary water must retain reflection motion even when the transmission guide falls back.'
}

$fresnelBranch = $waterBranch.IndexOf('if (rndf(seed) < F)')
$transmissionElse = $waterBranch.IndexOf('} else {', $fresnelBranch)
$fresnelEnd = $waterBranch.IndexOf('// Specular interface', $transmissionElse)
if ($fresnelBranch -lt 0 -or $transmissionElse -lt 0 -or $fresnelEnd -lt 0) {
    throw 'Could not isolate the primary water Fresnel continuation.'
}
$reflectionContinuation = $waterBranch.Substring($fresnelBranch, $transmissionElse - $fresnelBranch)
$transmissionContinuation = $waterBranch.Substring($transmissionElse, $fresnelEnd - $transmissionElse)
$geometricTirGuard = if ($primaryTransmissionDirection -ne '') {
    $tirGuardPattern =
            '(?s)if\s*\(\s*dot\(\s*{0}\s*,\s*{0}\s*\)\s*<=\s*0\.0\s*\)\s*\{{\s*F\s*=\s*1\.0\s*;\s*\}}' -f
            [regex]::Escape($primaryTransmissionDirection)
    [regex]::Match($waterBranch, $tirGuardPattern)
} else {
    [regex]::Match('', 'never')
}
if (-not $geometricTirGuard.Success -or
        $primaryCachedRefraction.Index -ge $fresnelBranch -or
        $geometricTirGuard.Index -le $primaryCachedRefraction.Index -or
        $geometricTirGuard.Index -ge $fresnelBranch -or
        -not $reflectionContinuation.Contains('rd = reflect(rd, n);') -or
        -not $transmissionContinuation.Contains("rd = $primaryTransmissionDirection;") -or
        $transmissionContinuation -match 'rd\s*=\s*refract\(') {
    throw 'Geometric water TIR must force the animated-normal reflection branch and never assign a zero transmission direction.'
}
if ($reflectionContinuation.Contains('inWater = waterEntering;') -or
        -not $transmissionContinuation.Contains('inWater = waterEntering;')) {
    throw 'inWater must update from waterEntering only in the successful Fresnel transmission branch.'
}

$primaryTraceIndex = $tracePath.IndexOf(
        'traceRadianceReordered(bounce == 0 ? CULL_PRIMARY : CULL_SECONDARY, ro, 0.0, rd, 10000.0);')
$primarySegmentDistanceMatch = [regex]::Match(
        $tracePath,
        'float\s+primarySegmentDistance\s*=\s*payload\.hitT\s*<\s*0\.0\s*\?\s*10000\.0\s*:\s*payload\.hitT\s*;')
$primarySegmentDistanceIndex = if ($primarySegmentDistanceMatch.Success) {
    $primarySegmentDistanceMatch.Index
} else {
    -1
}
$primaryWaterBeerMatch = [regex]::Match(
        $tracePath,
        '(?s)if\s*\(\s*inWater\s*\)\s*\{\s*throughput\s*\*=\s*exp\(\s*-waterExt\s*\*\s*primarySegmentDistance\s*\);\s*\}')
$primaryWaterBeerIndex = if ($primaryWaterBeerMatch.Success) {
    $primaryWaterBeerMatch.Index
} else {
    -1
}
$primarySkyStart = $tracePath.IndexOf('if (payload.hitT < 0.0)')
$primaryUsesUnsafeHitDistance = $tracePath -match
        'throughput\s*\*=\s*exp\(\s*-waterExt\s*\*\s*payload\.hitT\s*\)'
if ($primaryTraceIndex -lt 0 -or
        -not $tracePath.Contains('bool inWater = (pc.flags & 1u) != 0u;') -or
        -not $tracePath.Contains('float3 waterExt = waterExtinction(pc.waterParams.xyz);') -or
        $primarySegmentDistanceIndex -lt $primaryTraceIndex -or
        $primaryWaterBeerIndex -lt $primarySegmentDistanceIndex -or
        $primaryWaterBeerIndex -ge $primarySkyStart -or
        $primaryUsesUnsafeHitDistance) {
    throw 'Primary radiance attenuation must use hit distance or the 10000-unit miss horizon before publishing sky or hit results.'
}
$primarySkyEnd = $tracePath.IndexOf('float3 n = payload.normal;', $primarySkyStart)
$primarySky = if ($primarySkyStart -ge 0 -and $primarySkyEnd -gt $primarySkyStart) {
    $tracePath.Substring($primarySkyStart, $primarySkyEnd - $primarySkyStart)
} else { '' }
if (-not $primarySky.Contains('gv_reflectionMotionValid = false;')) {
    throw 'Primary sky must explicitly disable reflection motion.'
}

$opaqueCaptureStart = $tracePath.IndexOf('if (bounce == 0) { // primary-visibility surface')
$opaqueCaptureEnd = $tracePath.IndexOf('// Emissive surfaces', $opaqueCaptureStart)
$opaqueCapture = if ($opaqueCaptureStart -ge 0 -and $opaqueCaptureEnd -gt $opaqueCaptureStart) {
    $tracePath.Substring($opaqueCaptureStart, $opaqueCaptureEnd - $opaqueCaptureStart)
} else { '' }
if (-not $opaqueCapture.Contains('gv_reflectionMotionValid = max(gv_specAlb.r')) {
    throw 'Primary opaque surfaces must derive reflection-motion validity from their own specular guide.'
}

Write-Output 'Bounded glass/water transmission-guide contract: PASS'
