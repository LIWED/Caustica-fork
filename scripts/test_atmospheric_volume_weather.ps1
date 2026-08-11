$ErrorActionPreference = 'Stop'

$project = Split-Path -Parent $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()

function Read-ProjectFile([string] $relativePath) {
    $path = Join-Path $project $relativePath
    if (-not [System.IO.File]::Exists($path)) {
        return ''
    }
    return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
}

function Require-Match([string] $name, [string] $text, [string] $pattern) {
    if ($text -notmatch $pattern) {
        $failures.Add($name)
    }
}

function Require-NoMatch([string] $name, [string] $text, [string] $pattern) {
    if ($text -match $pattern) {
        $failures.Add($name)
    }
}

function Require-JsonValue([string] $name, [object] $json, [string] $property, [string] $expected) {
    $actual = $json.PSObject.Properties[$property].Value
    if ($actual -ne $expected) {
        $failures.Add("$name (expected '$expected', got '$actual')")
    }
}

$gradle = Read-ProjectFile 'gradle.properties'
$world = Read-ProjectFile 'shaders/world/world_common.slang'
$worldMiss = Read-ProjectFile 'shaders/world/world.rmiss.slang'
$airVolume = Read-ProjectFile 'shaders/world/air_volume.slang'
$segment = Read-ProjectFile 'shaders/world/segment.slang'
$primary = Read-ProjectFile 'shaders/world/world_primary.rgen.slang'
$secondary = Read-ProjectFile 'shaders/world/world.rgen.slang'
$clientLevelInvoker = Read-ProjectFile 'src/main/java/dev/comfyfluffy/caustica/mixin/ClientLevelInvoker.java'
$mixins = Read-ProjectFile 'src/main/resources/caustica.mixins.json'
$medium = Read-ProjectFile 'shaders/world/medium.slang'
$waterVolume = Read-ProjectFile 'shaders/world/water_volume.slang'
$config = Read-ProjectFile 'src/main/java/dev/comfyfluffy/caustica/CausticaConfig.java'
$options = Read-ProjectFile 'src/main/java/dev/comfyfluffy/caustica/client/RtVideoOptions.java'
$composite = Read-ProjectFile 'src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java'
$levelRendererMixin = Read-ProjectFile 'src/main/java/dev/comfyfluffy/caustica/mixin/LevelRendererMixin.java'
$weatherSnapshot = Read-ProjectFile 'src/main/java/dev/comfyfluffy/caustica/rt/entity/RtWeatherSnapshot.java'
$entities = Read-ProjectFile 'src/main/java/dev/comfyfluffy/caustica/rt/entity/RtEntities.java'
$entityTextures = Read-ProjectFile 'src/main/java/dev/comfyfluffy/caustica/rt/entity/RtEntityTextures.java'
$anyHit = Read-ProjectFile 'shaders/world/world.rahit.slang'
$en = (Read-ProjectFile 'src/main/resources/assets/caustica/lang/en_us.json') | ConvertFrom-Json
$zh = (Read-ProjectFile 'src/main/resources/assets/caustica/lang/zh_cn.json') | ConvertFrom-Json

Require-Match 'version is 0.4.4' $gradle '(?m)^mod_version=0\.4\.4$'
Require-Match 'WorldPush weather float4 ABI' $world '(?m)^\s*public float4\s+weather\s*;'
Require-Match 'WorldPush weatherColor float4 ABI' $world '(?m)^\s*public float4\s+weatherColor\s*;'
Require-Match 'WorldPush airVolume float4 ABI' $world '(?m)^\s*public float4\s+airVolume\s*;'
Require-Match '0.4.3 water absorption baseline' $medium 'public static const float3 WATER_ABSORPTION_BASE\s*=\s*float3\(0\.118,\s*0\.052,\s*0\.058\);'
Require-Match '0.4.3 water scattering coefficient' $waterVolume 'public static const float3 WATER_SCATTERING_COEFFICIENT\s*=\s*float3\(0\.018,\s*0\.018,\s*0\.018\);'
Require-Match '0.4.3 water ambient scattering coefficient' $waterVolume 'float3 result\s*=\s*lostEnergy \* scatteringFraction \* palette \* \(0\.080 \* daylight\);'
Require-Match '0.4.3 water directional scattering coefficient' $waterVolume 'float3 directionalLight\s*=\s*normalizedLight \* \(0\.125 \* phaseBoost\);'

Require-Match 'AIR_FOG persisted setting' $config 'public static final BooleanSetting AIR_FOG\s*='
Require-Match 'AIR_FOG_STRENGTH persisted setting' $config 'public static final FloatSetting AIR_FOG_STRENGTH\s*='
Require-Match 'air fog strength range 0..2 and default 1' $config 'clampedFloat\("caustica\.rt\.airFogStrength",\s*"composite\.air-fog-strength",\s*1\.0f,\s*0\.0f,\s*2\.0f\)'
Require-Match 'VOLUMETRIC_LIGHT persisted setting' $config 'public static final BooleanSetting VOLUMETRIC_LIGHT\s*='

Require-Match 'air fog video toggle' $options 'bool\("caustica\.options\.rt\.airFog",\s*CausticaConfig\.Rt\.Composite\.AIR_FOG\)'
Require-Match 'air fog strength video slider' $options 'CausticaConfig\.Rt\.Composite\.AIR_FOG_STRENGTH'
Require-Match 'volumetric light video toggle' $options 'bool\("caustica\.options\.rt\.volumetricLight",\s*CausticaConfig\.Rt\.Composite\.VOLUMETRIC_LIGHT\)'

Require-JsonValue 'English air fog label' $en 'caustica.options.rt.airFog' 'Atmospheric Fog'
Require-JsonValue 'English air fog strength label' $en 'caustica.options.rt.airFogStrength' 'Atmospheric Fog Strength'
Require-JsonValue 'English volumetric light label' $en 'caustica.options.rt.volumetricLight' 'Volumetric Light'
$zhAirFog = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('56m65rCU5L2T56ev6Zu+'))
$zhAirFogStrength = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('56m65rCU6Zu+5by65bqm'))
$zhVolumetricLight = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('5L2T56ev5YWJ'))
Require-JsonValue 'Chinese air fog label' $zh 'caustica.options.rt.airFog' $zhAirFog
Require-JsonValue 'Chinese air fog strength label' $zh 'caustica.options.rt.airFogStrength' $zhAirFogStrength
Require-JsonValue 'Chinese volumetric light label' $zh 'caustica.options.rt.volumetricLight' $zhVolumetricLight

Require-Match 'rain level consumption' $composite '\.getRainLevel\(partial\)'
Require-Match 'thunder level consumption' $composite '\.getThunderLevel\(partial\)'
foreach ($attribute in @('FOG_COLOR', 'CLOUD_COLOR', 'CLOUD_HEIGHT')) {
    Require-Match "EnvironmentAttributes.$attribute consumption" $composite "EnvironmentAttributes\.$attribute"
}
Require-Match 'packed colours converted from sRGB to linear' $composite 'srgbToLinear\('
Require-Match 'AIR_FOG flag bit 6' $composite 'flags\s*\|=\s*1\s*<<\s*6'
Require-Match 'VOLUMETRIC_LIGHT flag bit 7' $composite 'flags\s*\|=\s*1\s*<<\s*7'
Require-Match 'WorldPush weather constructor argument' $composite 'sky\.weather\(\)'
Require-Match 'WorldPush weatherColor constructor argument' $composite 'sky\.weatherColor\(\)'
Require-Match 'WorldPush airVolume constructor argument' $composite 'airVolume'
Require-Match 'sky push receives terrain rebase' $composite 'SkyPush sky\s*=\s*skyPush\(terrain\);'
Require-Match 'cloud height is terrain rebased' $composite 'cloudHeight\s*-\s*terrain\.blockY'

# Lightning uses ClientLevel's hideLightningFlash-aware private getter, never SKY_LIGHT_FACTOR's day baseline.
Require-Match 'ClientLevel lightning invoker target' $clientLevelInvoker '@Invoker\("getSkyFlashTime"\)'
Require-Match 'ClientLevel lightning invoker signature' $clientLevelInvoker 'int caustica\$getSkyFlashTime\(\);'
Require-Match 'ClientLevel lightning invoker registered' $mixins '"ClientLevelInvoker"'
Require-Match 'lightning flash read through invoker' $composite '\(\(ClientLevelInvoker\) level\)\.caustica\$getSkyFlashTime\(\)'
Require-Match 'lightning flash normalized to 0..1' $composite 'Mth\.clamp\(skyFlashTime / 2\.0f, 0\.0f, 1\.0f\)'
Require-Match 'WorldPush weather z is lightning flash' $composite 'new Float4\(rain, thunder, lightningFlash, cloudTime\)'
Require-NoMatch 'SKY_LIGHT_FACTOR must not drive lightning pulse' $composite 'new Float4\(rain, thunder, skyLightFactor, cloudTime\)'

# Task 3: weather-driven thick cloud sheet and a shared CPU/Slang direct-light contract.
foreach ($contract in @(
    @{ Name = 'rain attenuation constant'; Pattern = 'WEATHER_RAIN_ATTENUATION\s*=\s*0\.72' },
    @{ Name = 'thunder attenuation constant'; Pattern = 'WEATHER_THUNDER_ATTENUATION\s*=\s*0\.18' },
    @{ Name = 'minimum weather transmittance'; Pattern = 'WEATHER_MIN_TRANSMITTANCE\s*=\s*0\.10' }
)) {
    Require-Match "CPU $($contract.Name)" $composite $contract.Pattern
    Require-Match "Slang $($contract.Name)" $worldMiss $contract.Pattern
}
foreach ($cloudContract in @(
    @{ Name = 'cloud spatial scale'; Pattern = 'CLOUD_SPATIAL_SCALE\s*=\s*0\.0032' },
    @{ Name = 'cloud wind x'; Pattern = 'CLOUD_WIND_X\s*=\s*0\.0113' },
    @{ Name = 'cloud wind z'; Pattern = 'CLOUD_WIND_Z\s*=\s*-0\.0067' },
    @{ Name = 'clear cloud coverage'; Pattern = 'CLOUD_CLEAR_COVERAGE\s*=\s*0\.24' },
    @{ Name = 'clear cloud thickness'; Pattern = 'CLOUD_CLEAR_THICKNESS\s*=\s*0\.12' },
    @{ Name = 'cloud rain coverage'; Pattern = 'CLOUD_RAIN_COVERAGE\s*=\s*0\.56' },
    @{ Name = 'cloud thunder coverage'; Pattern = 'CLOUD_THUNDER_COVERAGE\s*=\s*0\.20' },
    @{ Name = 'cloud rain thickness'; Pattern = 'CLOUD_RAIN_THICKNESS\s*=\s*0\.60' },
    @{ Name = 'cloud thunder thickness'; Pattern = 'CLOUD_THUNDER_THICKNESS\s*=\s*0\.28' },
    @{ Name = 'cloud extinction'; Pattern = 'CLOUD_EXTINCTION\s*=\s*2\.45' },
    @{ Name = 'cloud max distance'; Pattern = 'CLOUD_MAX_DISTANCE\s*=\s*32768\.0' },
    @{ Name = 'cloud distance fade start'; Pattern = 'CLOUD_DISTANCE_FADE_START\s*=\s*27852\.8' },
    @{ Name = 'cloud horizon fade end'; Pattern = 'CLOUD_HORIZON_FADE_END\s*=\s*0\.035' }
)) {
    Require-Match "CPU $($cloudContract.Name)" $composite $cloudContract.Pattern
    Require-Match "Slang $($cloudContract.Name)" $worldMiss $cloudContract.Pattern
}
Require-Match 'CPU cloud direct transmittance helper' $composite 'cloudDirectTransmittance\(float rain, float thunder\)'
Require-Match 'CPU cloud direct transmittance formula' $composite 'Mth\.clamp\(1\.0f\s*-\s*rain\s*\*\s*WEATHER_RAIN_ATTENUATION\s*-\s*thunder\s*\*\s*WEATHER_THUNDER_ATTENUATION,\s*WEATHER_MIN_TRANSMITTANCE,\s*1\.0f\)'
Require-Match 'CPU active celestial radiance weather attenuation' $composite '(?s)float cloudDirect = cloudDirectTransmittance\(rain, thunder\);.*?rr \*= cloudDirect;\s*rg \*= cloudDirect;\s*rb \*= cloudDirect;'
Require-Match 'CPU local cloud transmittance helper' $composite 'cloudLocalTransmittance\('
Require-Match 'CPU active light uses local cloud transmittance' $composite '(?s)float localCloud = cloudLocalTransmittance\(.*?rr \*= localCloud;\s*rg \*= localCloud;\s*rb \*= localCloud;'
Require-Match 'CPU mirrors three octave irregular cloud noise' $composite '(?s)cloudNoise3\(.*?valueNoise2\(.*?valueNoise2\(.*?valueNoise2\('
Require-Match 'Slang cloud direct transmittance formula' $worldMiss 'clamp\(1\.0\s*-\s*rain\s*\*\s*WEATHER_RAIN_ATTENUATION\s*-\s*thunder\s*\*\s*WEATHER_THUNDER_ATTENUATION,\s*WEATHER_MIN_TRANSMITTANCE,\s*1\.0\)'
Require-Match 'weather cloud result carries transmittance and radiance' $worldMiss '(?s)struct WeatherCloudResult\s*\{.*?float transmittance;.*?float3 radiance;.*?\}'
Require-Match 'clear weather retains sparse cloud coverage' $worldMiss 'CLOUD_CLEAR_COVERAGE\s*=\s*0\.24'
Require-Match 'clear weather retains thin cloud thickness' $worldMiss 'CLOUD_CLEAR_THICKNESS\s*=\s*0\.12'
Require-Match 'clear cloud baseline feeds coverage' $worldMiss 'float coverage\s*=\s*clamp\(CLOUD_CLEAR_COVERAGE\s*\+'
Require-Match 'clear cloud baseline feeds thickness' $worldMiss 'float thickness\s*=\s*clamp\(CLOUD_CLEAR_THICKNESS\s*\+'
Require-NoMatch 'clear weather must not disable clouds' $worldMiss 'if\s*\(rain\s*\+\s*thunder\s*<=\s*1\.0e-3\)'
Require-Match 'WorldPush cloud anchor float4 ABI' $world 'public float4\s+cloudAnchor\s*;'
Require-Match 'cloud anchor publishes full terrain XZ' $composite 'new Float4\(terrain\.blockX, terrain\.blockZ, 0\.0f, 0\.0f\)'
Require-Match 'WorldPush cloud anchor constructor argument' $composite 'cloudAnchor'
Require-Match 'cloud field uses dedicated full world anchor' $worldMiss 'cloudPoint \+= worldPush\.cloudAnchor\.xy;'
Require-NoMatch 'cloud field must not reuse modulo water anchor' $worldMiss 'cloudPoint \+= worldPush\.waterAnchor\.xy;'
Require-Match 'cloud layer uses weatherColor height plane intersection' $worldMiss 'float tCloud\s*=\s*\(worldPush\.weatherColor\.w\s*-\s*rayOrigin\.y\)\s*/\s*dir\.y;'
Require-Match 'cloud field is world and time anchored' $worldMiss '(?s)float2 cloudPoint\s*=\s*rayOrigin\.xz\s*\+\s*dir\.xz\s*\*\s*tCloud;.*?worldPush\.weather\.w'
Require-Match 'cloud noise uses exactly three irregular octaves' $worldMiss '(?s)float cloudNoise3\(float2 p\).*?valueNoise2\(p\).*?valueNoise2\(float2\(.*?\).*?valueNoise2\(float2\(.*?\)'
Require-Match 'rain and thunder control cloud coverage' $worldMiss 'float coverage\s*=\s*clamp\([^;]+rain\s*\*[^;]+thunder\s*\*'
Require-Match 'rain and thunder control cloud thickness' $worldMiss 'float thickness\s*=\s*clamp\([^;]+rain\s*\*[^;]+thunder\s*\*'
Require-Match 'weather cloud function returns cloud result' $worldMiss 'WeatherCloudResult weatherCloud\('
Require-Match 'lightning-aware weather sky factor uses lightningFlash z' $worldMiss '(?s)float weatherSkyFactor\(float4 weather\).*?weather\.z'
Require-Match 'main keeps non-lightning direct weather factor' $worldMiss 'float weatherDirect\s*=\s*cloudDirectTransmittance\(worldPush\.weather\.x, worldPush\.weather\.y\);'
Require-Match 'cloud horizon visibility fades smoothly' $worldMiss 'smoothstep\(0\.0, CLOUD_HORIZON_FADE_END, dir\.y\)'
Require-Match 'cloud intersection distance is bounded' $worldMiss 'tCloud\s*>\s*CLOUD_MAX_DISTANCE'
Require-Match 'Slang cloud max distance fades continuously' $worldMiss '1\.0\s*-\s*smoothstep\(CLOUD_DISTANCE_FADE_START, CLOUD_MAX_DISTANCE, tCloud\)'
Require-Match 'CPU cloud max distance fades continuously' $composite '1\.0f\s*-\s*smoothstep\(CLOUD_DISTANCE_FADE_START, CLOUD_MAX_DISTANCE, tCloud\)'
Require-Match 'sky atmosphere weather attenuation' $worldMiss 'col\s*\*=\s*weatherSky;'
Require-Match 'stars use direct weather attenuation without lightning lift' $worldMiss 'stars\([^;]+\)\s*\*\s*weatherDirect'
Require-Match 'sun disc uses direct weather attenuation without lightning lift' $worldMiss 'SUN_DISC_RADIANCE[^;]+\*\s*weatherDirect'
Require-Match 'moon disc uses direct weather attenuation without lightning lift' $worldMiss 'MOON_DISC_RADIANCE[^;]+\*\s*weatherDirect'
Require-NoMatch 'sun disc must not use lightning-lifted weather sky' $worldMiss 'SUN_DISC_RADIANCE[^;]+\*\s*weatherSky'
Require-NoMatch 'moon disc must not use lightning-lifted weather sky' $worldMiss 'MOON_DISC_RADIANCE[^;]+\*\s*weatherSky'
Require-Match 'cloud bottom composited with weather colour' $worldMiss 'cloud\.radiance'

# Task 4: analytic air height fog plus exactly four visibility samples on Pass A's camera air segment.
Require-Match 'air volume result contract' $airVolume '(?s)public struct AirVolumeResult\s*\{.*?float3 transmittance;.*?float3 radiance;.*?\}'
Require-Match 'air volume integration signature' $airVolume 'public AirVolumeResult integrateAirVolume\(float3 ro, float3 rd, float distance, bool sampleShafts, uint seed\)'
Require-Match 'air volume stable local expm1 helper' $airVolume '(?s)public float airExpm1\(float x\).*?abs\(x\) < 1\.0e-3.*?return exp\(x\) - 1\.0;'
Require-Match 'air volume analytic exponential height integral' $airVolume '(?s)float heightOpticalDepth\(.*?exp\(.*?heightFalloff.*?\).*?airExpm1'
Require-Match 'air volume horizontal-ray stable limit uses dimensionless exponent' $airVolume 'abs\(slope \* distance\)\s*<\s*1\.0e-4'
Require-NoMatch 'air volume must not branch on slope alone' $airVolume 'abs\(slope\)\s*<\s*1\.0e-4'
Require-Match 'air volume distance capped by ABI' $airVolume 'min\(distance, worldPush\.airVolume\.w\)'
Require-Match 'air volume rejects invalid non-positive distance' $airVolume 'if \(!\(distance > 0\.0\)\)'
Require-Match 'air fog bit 6 is a complete gate' $airVolume '\(worldPush\.flags & \(1u << 6u\)\) == 0u'
Require-Match 'volumetric light bit 7 gates shaft visibility' $airVolume 'sampleShafts\s*&&\s*\(worldPush\.flags & \(1u << 7u\)\) != 0u'
Require-Match 'air fog density uses pushed strength' $airVolume 'worldPush\.airVolume\.x'
Require-Match 'rain and thunder increase density with a cap' $airVolume 'min\(1\.0 \+ rain \* 0\.65 \+ thunder \* 0\.35, 2\.0\)'
Require-Match 'lightning lifts only ambient environment scattering' $airVolume 'ambientLightningLift\s*=\s*1\.0 \+ 0\.35 \* clamp\(worldPush\.weather\.z, 0\.0, 1\.0\)'
Require-Match 'weather colour drives linear fog scattering' $airVolume 'max\(worldPush\.weatherColor\.xyz, 0\.0\)'
Require-Match 'air shaft slice count is four' $airVolume 'AIR_VOLUME_SLICE_COUNT\s*=\s*4u'
Require-Match 'air shafts use stratified jitter' $airVolume '\(float\(slice\) \+ rndf\(jitterSeed\)\) / float\(AIR_VOLUME_SLICE_COUNT\)'
Require-Match 'air shaft jitter includes frame' $airVolume 'worldPush\.frameIndex \* 747796405u'
Require-Match 'air shafts query visibility once per slice' $airVolume 'VisibilityResult shadow\s*=\s*visibility\(samplePosition, lightDir, 10000\.0\);'
Require-Match 'air shafts use forward HG phase' $airVolume 'hg\(dot\(rd, lightDir\), AIR_VOLUME_MIE_G\)'
Require-Match 'air shafts require active celestial light' $airVolume 'lightLengthSq\s*>\s*1\.0e-8.*?lightEnergy\s*>\s*1\.0e-6'
Require-Match 'air shaft energy follows fog optical strength' $airVolume 'sliceScattered\s*=\s*1\.0 - exp\(-sliceOpticalDepth\)'

Require-Match 'packed path bit 11 has a named consume guard' $segment 'public static const uint PATH_AIR_VOLUME_CONSUMED\s*=\s*1u << 11u;'
Require-Match 'Pass A imports air volume' $primary '(?m)^import air_volume;'
Require-Match 'Pass A integrates the camera air segment' $primary 'integrateAirVolume\(ro, rd, segmentDistance, true, airSeed\)'
Require-Match 'air medium predicate excludes glass and water' $medium '(?s)public bool mediumIsAir\(Medium medium\).*?!medium\.water.*?abs\(medium\.ior - 1\.0\).*?medium\.extinction'
Require-Match 'Pass A applies air volume only in actual air' $primary 'if \(mediumIsAir\(medium\.current\)\)'
Require-Match 'Pass A accumulates fog only into radiance and throughput' $primary '(?s)prefixRadiance \+= throughput \* air\.radiance;\s*throughput \*= air\.transmittance;'
Require-Match 'Pass A seed decorrelates pixel path and frame' $primary '(?s)uint airSeed\s*=\s*seed \^ pixelIndex.*?worldPush\.frameIndex'
Require-Match 'Pass A marks primary terminal consumed' $primary 'packedTerminal\.pathFlags \|= PATH_AIR_VOLUME_CONSUMED;'
Require-Match 'Pass A marks split continuation consumed' $primary 'packedDeferred\.pathFlags \|= PATH_AIR_VOLUME_CONSUMED;'
Require-Match 'Pass B checks packed consume guard before SPP loop' $secondary '(?s)bool airVolumeConsumed\s*=\s*\(packed\.pathFlags & PATH_AIR_VOLUME_CONSUMED\) != 0u;\s*for \(uint s = 0u; s < spp; \+\+s\)'
Require-Match 'Pass B trace receives consume state' $secondary 'tracePath\(segment, uint2\(pix\), s \+ leaf \* spp, airVolumeConsumed\)'
Require-Match 'Pass B never samples shaft visibility' $secondary 'integrateAirVolume\(ro, rd, segmentDistance, false, seed\)'
Require-Match 'Pass B applies analytic air volume only in actual air' $secondary 'if \(mediumIsAir\(medium\.current\) && !skipConsumedCameraSegment\)'
Require-NoMatch 'air fog must not write diffuse guide' $airVolume 'gAlbedo|gv_albedo'
Require-NoMatch 'air fog must not write specular guide' $airVolume 'gSpecAlbedo|gv_spec'

# Task 5: cancellation-time immutable weather capture and primary-only RT weather geometry.
Require-Match 'weather snapshot copies rain columns' $weatherSnapshot 'List\.copyOf\(copyColumns\(state\.rainColumns\)\)'
Require-Match 'weather snapshot copies snow columns' $weatherSnapshot 'List\.copyOf\(copyColumns\(state\.snowColumns\)\)'
Require-Match 'weather snapshot carries frame id' $weatherSnapshot 'long frameId'
Require-Match 'weather snapshot preserves light coordinates' $weatherSnapshot 'column\.lightCoords\(\)'
Require-Match 'weather mesh applies terrain rebase' $weatherSnapshot 'column\.x\(\) \+ 0\.5f - rbx'
Require-Match 'weather mesh receives camera position' $weatherSnapshot 'mesh\(int rbx, int rby, int rbz, double cameraX, double cameraZ\)'
Require-Match 'weather distance fade matches vanilla radius squared' $weatherSnapshot 'Math\.min\(\(dx \* dx \+ dz \* dz\) / \(\(double\) radius \* radius\), 1\.0\)'
Require-Match 'weather alpha lerps kind factor toward half' $weatherSnapshot '\(kindFactor \+ distanceNorm \* \(0\.5f - kindFactor\)\) \* intensity'
Require-Match 'snow alpha factor is 0.8' $weatherSnapshot 'kind == Kind\.RAIN \? 1\.0f : 0\.8f'
Require-Match 'zero radius is safe' $weatherSnapshot 'if \(radius <= 0\)'
Require-Match 'weather half width matches vanilla column width' $weatherSnapshot 'float halfWidth = 0\.5f;'
Require-Match 'weather mesh preserves vanilla animated V offset once' $weatherSnapshot 'column\.bottomY\(\) \* 0\.25f \+ column\.vOffset\(\)'
Require-NoMatch 'weather mesh must not double-animate vanilla V offset' $weatherSnapshot 'column\.vOffset\(\) \+ animation'
Require-Match 'weather uses crossed quads' $weatherSnapshot 'appendCrossedQuads'
Require-Match 'weather mesh declares particle instance bit' $weatherSnapshot 'RtEntities\.PARTICLE_BIT'
Require-Match 'weather mesh declares primary-only mask' $weatherSnapshot 'RtEntities\.PARTICLE_MASK'
Require-Match 'weather mesh declares zero first-frame motion' $weatherSnapshot 'new Motion\(0\.0f, 0\.0f, 0\.0f\)'
Require-Match 'cancel hook captures weather before cancellation' $levelRendererMixin '(?s)captureWeather\(this\.levelRenderState\.weatherRenderState\).*?ci\.cancel\(\)'
Require-Match 'cancel hook remains behind RT cancellation gate' $levelRendererMixin '(?s)if \(!VanillaRenderController\.INSTANCE\.shouldCancelLevelRenderer\(waitingForRtPlayerSection\)\) \{\s*return;\s*\}.*?captureWeather'
Require-Match 'rain standalone texture' $entities '(?s)"minecraft",\s*"textures/environment/rain\.png"'
Require-Match 'snow standalone texture' $entities '(?s)"minecraft",\s*"textures/environment/snow\.png"'
Require-Match 'standalone weather texture resolver' $entityTextures 'slotForTexture\(Identifier textureLocation\)'
Require-Match 'weather never falls back to block atlas slot zero' $entities 'if \(textureSlot == 0\)'
Require-Match 'weather geometry uses any-hit bucket' $entities '(?s)captureWeatherMesh.*?ENTITY_BUCKET_ANY_HIT'
Require-Match 'weather geometry reuses particle instance path' $entities 'PARTICLE_BIT, PARTICLE_MASK'
Require-Match 'particle any-hit reads stochastic material feature' $anyHit '(?s)MaterialHeader materialHeader = ConstPtr<MaterialHeader>\(pc\.materialTableAddr\)\[epr\.materialId\];.*?MATERIAL_FEATURE_STOCHASTIC_ALPHA'
Require-NoMatch 'RT weather must not call vanilla WeatherEffectRenderer' $entities 'WeatherEffectRenderer\s*[.(]'

if ($failures.Count -gt 0) {
    Write-Host "Atmospheric volume/weather contract: FAIL ($($failures.Count))" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host " - $failure"
    }
    exit 1
}

Write-Host 'Atmospheric volume/weather contract: PASS' -ForegroundColor Green
