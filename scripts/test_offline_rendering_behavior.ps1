[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$javaHome = 'D:\program\java25'
$javac = Join-Path $javaHome 'bin\javac.exe'
$java = Join-Path $javaHome 'bin\java.exe'
$testSource = Join-Path $PSScriptRoot 'tests\OfflineRenderingBehaviorTest.java'
$productionRoot = Join-Path $projectRoot 'src\main\java'
$stateSource = Join-Path $productionRoot 'dev\comfyfluffy\caustica\rt\offline\OfflineAccumulationState.java'
$policySource = Join-Path $productionRoot 'dev\comfyfluffy\caustica\rt\offline\OfflineModePolicy.java'
$freezeSource = Join-Path $productionRoot 'dev\comfyfluffy\caustica\rt\offline\OfflineFreezeOwnership.java'
$weightsSource = Join-Path $productionRoot 'dev\comfyfluffy\caustica\rt\offline\OfflineSampleWeights.java'
$signatureSource = Join-Path $productionRoot 'dev\comfyfluffy\caustica\rt\offline\OfflineRenderSignature.java'
$bouncePolicySource = Join-Path $productionRoot 'dev\comfyfluffy\caustica\rt\offline\PathBouncePolicy.java'
$staticLightMathSource = Join-Path $productionRoot 'dev\comfyfluffy\caustica\rt\offline\OfflineStaticLightMath.java'
$lightMixtureMathSource = Join-Path $productionRoot 'dev\comfyfluffy\caustica\rt\offline\OfflineLightMixtureMath.java'
$localLightIndexSource = Join-Path $productionRoot 'dev\comfyfluffy\caustica\rt\offline\OfflineLocalLightIndex.java'
$sampleSequenceSource = Join-Path $productionRoot 'dev\comfyfluffy\caustica\rt\offline\OfflineSampleSequence.java'
$outputDir = Join-Path $projectRoot 'build\offline-behavior-test'

if (-not (Test-Path -LiteralPath $javac -PathType Leaf)) {
    throw "Java 25 compiler not found: $javac"
}

if (Test-Path -LiteralPath $outputDir) {
    Remove-Item -LiteralPath $outputDir -Recurse -Force
}
New-Item -ItemType Directory -Path $outputDir | Out-Null

$sources = @($stateSource)
foreach ($optionalSource in @($policySource, $freezeSource, $weightsSource, $signatureSource, $staticLightMathSource, $lightMixtureMathSource)) {
    if (Test-Path -LiteralPath $optionalSource -PathType Leaf) {
        $sources += $optionalSource
    }
}
$sources += $bouncePolicySource
$sources += $localLightIndexSource
$sources += $sampleSequenceSource
$sources += $testSource

& $javac -encoding UTF-8 -d $outputDir @sources
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $java -ea -cp $outputDir OfflineRenderingBehaviorTest
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$raygenSource = Join-Path $projectRoot 'shaders\world\world.rgen.slang'
$raygenText = Get-Content -Raw -LiteralPath $raygenSource
$particleMatch = [regex]::Match(
        $raygenText,
        'if \(material == MATERIAL_PARTICLE\) \{(?<body>.*?)\n\s*if \(material == MATERIAL_WATER\)',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
if (-not $particleMatch.Success) {
    throw 'Could not extract the particle material branch from world.rgen.slang.'
}
$particleBody = $particleMatch.Groups['body'].Value
$eligibilityIndex = $particleBody.IndexOf('previousStaticLightNeeEligible = false')
$continuationIndex = $particleBody.IndexOf('previousDelta = false')
if ($eligibilityIndex -lt 0 -or $continuationIndex -lt 0 -or $eligibilityIndex -gt $continuationIndex) {
    throw 'Particle continuation must disable reciprocal static-light MIS when no matching NEE ran.'
}

$emissionMatch = [regex]::Match(
        $raygenText,
        'if \(emission > 0\.0\) \{(?<body>.*?)L \+= throughput \* albedo \* emission',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$emissionContractValid = $emissionMatch.Success -and
        $emissionMatch.Groups['body'].Value -match '!previousDelta' -and
        $emissionMatch.Groups['body'].Value -match 'previousStaticLightNeeEligible'
if (-not $emissionContractValid) {
    throw 'BSDF-hit reciprocal static-light MIS must require a non-delta path with matching previous-vertex NEE.'
}

$ordinaryNeeMatch = [regex]::Match(
        $raygenText,
        'L\s*\+=\s*throughput\s*\*\s*sampleStaticDirect\((?<args>.*?)\);',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$ordinaryEligibilityMatch = [regex]::Match(
        $raygenText,
        'previousStaticLightNeeEligible\s*=\s*\(pc\.flags & 32u\) != 0u\s*&&\s*pc\.staticLightCount > 0u\s*&&\s*pc\.staticLightTotalWeight > 0\.0;')
$ordinaryEligibilityValid = $ordinaryNeeMatch.Success -and
        $ordinaryEligibilityMatch.Success -and
        $ordinaryEligibilityMatch.Index -gt $ordinaryNeeMatch.Index
if (-not $ordinaryEligibilityValid) {
    throw 'Ordinary material continuation must enable reciprocal MIS only after evaluating static-light NEE.'
}

$glassMatch = [regex]::Match(
        $raygenText,
        'if \(material == MATERIAL_GLASS\) \{(?<body>.*?)\n\s*// Particles',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$waterMatch = [regex]::Match(
        $raygenText,
        'if \(material == MATERIAL_WATER\) \{(?<body>.*?)\n\s*float3 albedo = payload\.albedo;',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
foreach ($deltaBranch in @($glassMatch, $waterMatch)) {
    $deltaContractValid = $deltaBranch.Success -and
            $deltaBranch.Groups['body'].Value -match 'previousDelta = true;' -and
            $deltaBranch.Groups['body'].Value -match 'continue;'
    if (-not $deltaContractValid) {
        throw 'Glass and water delta continuations must remain ineligible for reciprocal static-light MIS.'
    }
}

$commonSource = Join-Path $projectRoot 'shaders\world\world_common.slang'
$commonText = Get-Content -Raw -LiteralPath $commonSource
if ($commonText -notmatch 'public uint\s+localDirectoryCount;') {
    throw 'WorldPush must publish the local-light directory count.'
}
$directoryHelperMatch = [regex]::Match(
        $raygenText,
        'bool receiverLocalDirectory\(.*?\) \{(?<body>.*?)\n\}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$directoryContractValid = $directoryHelperMatch.Success -and
        $directoryHelperMatch.Groups['body'].Value -match 'receiverSlot >= pc\.localDirectoryCount'
if (-not $directoryContractValid) {
    throw 'Local-light directory lookup must reject receiver slots outside the published directory count.'
}

$staticLightsSource = Join-Path $productionRoot 'dev\comfyfluffy\caustica\rt\terrain\RtStaticLights.java'
$staticLightsText = Get-Content -Raw -LiteralPath $staticLightsSource
if ($staticLightsText -notmatch 'cumulative \+= light\.weight;\s*if \(!Float\.isFinite\(cumulative\)\)') {
    throw 'Global static-light CDF construction must reject non-finite cumulative weight.'
}

$terrainSource = Join-Path $productionRoot 'dev\comfyfluffy\caustica\rt\terrain\RtTerrain.java'
$terrainText = Get-Content -Raw -LiteralPath $terrainSource
$compositeSource = Join-Path $productionRoot 'dev\comfyfluffy\caustica\rt\RtComposite.java'
$compositeText = Get-Content -Raw -LiteralPath $compositeSource
$controllerSource = Join-Path $productionRoot 'dev\comfyfluffy\caustica\rt\offline\RtOfflineController.java'
$controllerText = Get-Content -Raw -LiteralPath $controllerSource
$rrSource = Join-Path $productionRoot 'dev\comfyfluffy\caustica\rt\pipeline\RtDlssRr.java'
$rrText = Get-Content -Raw -LiteralPath $rrSource
$fgSource = Join-Path $productionRoot 'dev\comfyfluffy\caustica\rt\pipeline\RtDlssFg.java'
$fgText = Get-Content -Raw -LiteralPath $fgSource
$bindWorldTexturesMatch = [regex]::Match(
        $compositeText,
        'private void bindWorldTextures\(RtContext ctx\) \{(?<body>.*?)\r?\n    \}\r?\n\r?\n    private void refreshMaterialBindingsIfNeeded',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$bindWorldTexturesBody = if ($bindWorldTexturesMatch.Success) {
    $bindWorldTexturesMatch.Groups['body'].Value
} else {
    ''
}
$materialSourceDecisionMatch = [regex]::Match(
        $bindWorldTexturesBody,
        'boolean rebuildBlockMaterials = boundAtlasHandle != atlasView\s*\|\|\s*RtBlockMaterials\.INSTANCE\.viewS\(\) == 0L\s*\|\|\s*RtBlockMaterials\.INSTANCE\.viewN\(\) == 0L;')
$boundAtlasAssignmentIndex = $bindWorldTexturesBody.IndexOf('boundAtlasHandle = atlasView')
$materialRebuildBranchMatch = [regex]::Match(
        $bindWorldTexturesBody,
        'if \(rebuildBlockMaterials\) \{(?<body>.*?)\r?\n\s*\}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$materialRebuildBody = if ($materialRebuildBranchMatch.Success) {
    $materialRebuildBranchMatch.Groups['body'].Value
} else {
    ''
}
$materialRebuildBranchEnd = if ($materialRebuildBranchMatch.Success) {
    $materialRebuildBranchMatch.Index + $materialRebuildBranchMatch.Length
} else {
    -1
}
$reuseSpecViewIndex = $bindWorldTexturesBody.IndexOf(
        'long specView = RtBlockMaterials.INSTANCE.viewS()',
        [Math]::Max(0, $materialRebuildBranchEnd))
$reuseNormalViewIndex = $bindWorldTexturesBody.IndexOf(
        'long normalView = RtBlockMaterials.INSTANCE.viewN()',
        [Math]::Max(0, $reuseSpecViewIndex + 1))
$bindSpecViewIndex = $bindWorldTexturesBody.IndexOf(
        'worldPipeline.setBlockSpecAtlas(specView != 0L ? specView : atlasView, sampler)',
        [Math]::Max(0, $reuseNormalViewIndex + 1))
$bindNormalViewIndex = $bindWorldTexturesBody.IndexOf(
        'worldPipeline.setBlockNormalAtlas(normalView != 0L ? normalView : atlasView, sampler)',
        [Math]::Max(0, $bindSpecViewIndex + 1))
$sourceAwareMaterialRebindValid =
        $bindWorldTexturesMatch.Success -and
        $materialSourceDecisionMatch.Success -and
        $materialSourceDecisionMatch.Index -lt $boundAtlasAssignmentIndex -and
        $materialRebuildBranchMatch.Success -and
        $materialRebuildBody -match 'RtBlockMaterials\.INSTANCE\.reset\(\);' -and
        $materialRebuildBody -match 'RtBlockMaterials\.INSTANCE\.prepareAll\(\);' -and
        $materialRebuildBody -match 'RtTerrain\.markAllDirty\(\);' -and
        ([regex]::Matches($bindWorldTexturesBody, 'RtBlockMaterials\.INSTANCE\.reset\(\);')).Count -eq 1 -and
        ([regex]::Matches($bindWorldTexturesBody, 'RtBlockMaterials\.INSTANCE\.prepareAll\(\);')).Count -eq 1 -and
        ([regex]::Matches($bindWorldTexturesBody, 'RtTerrain\.markAllDirty\(\);')).Count -eq 1 -and
        $materialRebuildBranchEnd -lt $reuseSpecViewIndex -and
        $reuseSpecViewIndex -lt $reuseNormalViewIndex -and
        $reuseNormalViewIndex -lt $bindSpecViewIndex -and
        $bindSpecViewIndex -lt $bindNormalViewIndex
if (-not $sourceAwareMaterialRebindValid) {
    throw 'World-pipeline recreation must rebind existing block-material views without rebuilding unchanged material sources.'
}
$snapshotPublishesDirectoryCount =
        $staticLightsText -match 'long localDirectoryAddress, int localDirectoryCount' -and
        $staticLightsText -match 'localDirectoryBuffer == null \? 0 : slotCapacity'
$terrainForwardsDirectoryCount =
        $terrainText -match 'long localDirectoryAddress, int localDirectoryCount' -and
        $terrainText -match 'value\.localDirectoryAddress\(\), value\.localDirectoryCount\(\)'
$compositeForwardsDirectoryCount =
        $compositeText -match 'staticLights\.localDirectoryAddress\(\),\s*staticLights\.localReferenceAddress\(\),\s*staticLights\.localDirectoryCount\(\),\s*staticLights\.localReferenceCount\(\)'
$cpuDirectoryCountValid = $snapshotPublishesDirectoryCount -and
        $terrainForwardsDirectoryCount -and
        $compositeForwardsDirectoryCount
if (-not $cpuDirectoryCountValid) {
    throw 'CPU static-light snapshot chain must forward localDirectoryCount into WorldPush.'
}

$buildText = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'build.gradle')
$shaderVariantsValid =
        $buildText -match 'world_offline\.rgen\.spv' -and
        $buildText -match 'world_offline_nv\.rgen\.spv' -and
        $buildText -match 'CAUSTICA_OFFLINE_FP32' -and
        $buildText -match 'spvShaderInvocationReorderEXT' -and
        $buildText -match 'spvShaderInvocationReorderNV'
if (-not $shaderVariantsValid) {
    throw 'The shader build must emit realtime/offline EXT/NV raygen artifacts from world.rgen.slang.'
}

$raygenFormatsValid =
        $raygenText -match '#ifdef CAUSTICA_OFFLINE_FP32\s*\r?\n\[\[vk::binding\(1, 0\)\]\] \[format\("rgba32f"\)\]' -and
        $raygenText -match '#else\s*\r?\n\[\[vk::binding\(1, 0\)\]\] \[format\("rgba16f"\)\]'
$accumulateText = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'shaders\display\offline_accumulate.comp')
$offlineFormatsValid =
        $raygenFormatsValid -and
        $accumulateText -match 'layout\(binding = 0, rgba32f\)' -and
        $accumulateText -match 'layout\(binding = 1, rgba32f\)' -and
        $accumulateText -match 'layout\(binding = 2, rgba16f\)'
if (-not $offlineFormatsValid) {
    throw 'Offline trace/current and history must be RGBA32F while resolve/display remains RGBA16F.'
}

$bringupText = Get-Content -Raw -LiteralPath (Join-Path $productionRoot 'dev\comfyfluffy\caustica\rt\RtDeviceBringup.java')
$serEnumMatch = [regex]::Match(
        $bringupText,
        'private enum SerBackend \{(?<body>.*?)\r?\n    \}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$serEnumBody = if ($serEnumMatch.Success) { $serEnumMatch.Groups['body'].Value } else { '' }
$variantMethodMatch = [regex]::Match(
        $bringupText,
        'public static String worldRaygenShader\(boolean offlineFp32\) \{(?<body>.*?)\r?\n    \}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$variantSelectionValid =
        $serEnumMatch.Success -and
        $serEnumBody -match 'NV\("NV",\s*VK_NV_RAY_TRACING_INVOCATION_REORDER_EXTENSION_NAME,\s*"world_nv\.rgen\.spv",\s*"world_offline_nv\.rgen\.spv"\)' -and
        $serEnumBody -match 'EXT\("EXT",\s*VK_EXT_RAY_TRACING_INVOCATION_REORDER_EXTENSION_NAME,\s*"world\.rgen\.spv",\s*"world_offline\.rgen\.spv"\)' -and
        $variantMethodMatch.Success -and
        $variantMethodMatch.Groups['body'].Value -match 'offlineFp32\s*\?\s*serBackend\.offlineWorldRaygenShader\s*:\s*serBackend\.worldRaygenShader'
if (-not $variantSelectionValid) {
    throw 'RtDeviceBringup must select the matching realtime/offline shader for the active SER backend.'
}

$ensureOutputMatch = [regex]::Match(
        $compositeText,
        'private void ensureOutput\(\s*RtContext ctx,\s*int width,\s*int height,\s*boolean offlineAccumulating\) \{(?<body>.*?)\r?\n    \}\r?\n\r?\n    private void destroyOfflineResources',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$ensureOutputBody = if ($ensureOutputMatch.Success) { $ensureOutputMatch.Groups['body'].Value } else { '' }
$waitIdleIndex = $ensureOutputBody.IndexOf('ctx.waitIdle()')
$mismatchIndex = $ensureOutputBody.IndexOf('worldPipelineOfflineFp32 != offlineAccumulating')
$worldDestroyIndex = $ensureOutputBody.IndexOf('worldPipeline.destroy()', $mismatchIndex + 1)
$offlineDescriptorDestroyIndex = $ensureOutputBody.IndexOf('destroyOfflineResources()', $worldDestroyIndex + 1)
$outputDestroyIndex = $ensureOutputBody.IndexOf('output.destroy()', $offlineDescriptorDestroyIndex + 1)
$traceFormatIndex = $ensureOutputBody.IndexOf('int traceFormat = offlineAccumulating', $outputDestroyIndex + 1)
$outputCreateIndex = $ensureOutputBody.IndexOf('output = ctx.createStorageImage', $traceFormatIndex + 1)
$historyCreateIndex = $ensureOutputBody.IndexOf('offlineHistory = ctx.createStorageImage', $outputCreateIndex + 1)
$offlinePipelineCreateIndex = $ensureOutputBody.IndexOf('offlinePipeline = RtOfflineAccumulationPipeline.create(ctx)', $historyCreateIndex + 1)
$offlineSetImagesIndex = $ensureOutputBody.IndexOf('offlinePipeline.setImages(output.view, offlineHistory.view, rrOutput.view)', $offlinePipelineCreateIndex + 1)
$compositeMethodMatch = [regex]::Match(
        $compositeText,
        'public boolean composite\(GpuTexture nativeColor, int width, int height\) \{(?<body>.*?)\r?\n    \}\r?\n\r?\n    private static long offlineRenderSignature',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$compositeBody = if ($compositeMethodMatch.Success) { $compositeMethodMatch.Groups['body'].Value } else { '' }
$decisionCallIndex = $compositeBody.IndexOf('RtOfflineController.INSTANCE.beforeTrace(')
$sharedModeIndex = $compositeBody.IndexOf('boolean offlineAccumulating = offlineDecision != null && offlineDecision.accumulate()', $decisionCallIndex + 1)
$ensureOutputCallIndex = $compositeBody.IndexOf('ensureOutput(ctx, width, height, offlineAccumulating)', $sharedModeIndex + 1)
$ensureWorldCallIndex = $compositeBody.IndexOf('RtPipeline active = ensureWorld(ctx, offlineAccumulating)', $ensureOutputCallIndex + 1)
$recordFrameCallIndex = $compositeBody.IndexOf('recordFrame(ctx, active, nativeColor, offlineDecision)', $ensureWorldCallIndex + 1)
$pipelineAndImageValid =
        $ensureOutputMatch.Success -and
        0 -le $waitIdleIndex -and $waitIdleIndex -lt $mismatchIndex -and
        $mismatchIndex -lt $worldDestroyIndex -and
        $worldDestroyIndex -lt $offlineDescriptorDestroyIndex -and
        $offlineDescriptorDestroyIndex -lt $outputDestroyIndex -and
        $outputDestroyIndex -lt $traceFormatIndex -and
        $traceFormatIndex -lt $outputCreateIndex -and
        $outputCreateIndex -lt $historyCreateIndex -and
        $historyCreateIndex -lt $offlinePipelineCreateIndex -and
        $offlinePipelineCreateIndex -lt $offlineSetImagesIndex -and
        $ensureOutputBody -match 'offlineAccumulating\s*\?\s*VK10\.VK_FORMAT_R32G32B32A32_SFLOAT\s*:\s*VK10\.VK_FORMAT_R16G16B16A16_SFLOAT' -and
        $ensureOutputBody -match 'if \(offlineAccumulating\)' -and
        $compositeMethodMatch.Success -and 0 -le $decisionCallIndex -and
        $decisionCallIndex -lt $sharedModeIndex -and
        $sharedModeIndex -lt $ensureOutputCallIndex -and
        $ensureOutputCallIndex -lt $ensureWorldCallIndex -and
        $ensureWorldCallIndex -lt $recordFrameCallIndex -and
        $compositeText -match 'worldRaygenShader\(offlineFp32\)'
if (-not $pipelineAndImageValid) {
    throw 'The frame decision must drive shared realtime/offline resource selection before recording.'
}

$phaseDrivenPipelineValid =
        $controllerText -match 'private volatile boolean\s+currentFrameAccumulating;' -and
        $controllerText -match 'public static boolean accumulating\(\) \{\s*return INSTANCE\.currentFrameAccumulating;\s*\}' -and
        $controllerText -match 'accumulation\.observe\(\s*true,\s*cameraChanged,\s*System\.nanoTime\(\),' -and
        $controllerText -match 'currentFrameAccumulating\s*=\s*decision\.accumulate\(\);' -and
        $compositeText -match 'ensureWorld\(ctx,\s*RtOfflineController\.accumulating\(\)\)' -and
        $compositeText -match 'private RtPipeline ensureWorld\(RtContext ctx,\s*boolean offlineAccumulating\)' -and
        $compositeText -match 'boolean offlineFp32 = offlineAccumulating;' -and
        $rrText -match 'temporalFeatureEnabled\(\s*CausticaConfig\.Rt\.DlssRr\.ENABLED\.value\(\),\s*RtOfflineController\.accumulating\(\)\)' -and
        $fgText -match 'temporalFeatureEnabled\(\s*CausticaConfig\.Rt\.Fg\.ENABLED\.value\(\),\s*RtOfflineController\.accumulating\(\)\)'
if (-not $phaseDrivenPipelineValid) {
    throw 'FP32/native resources and temporal-feature gates must follow actual accumulation, not the setting.'
}

$freezeTaskMatch = [regex]::Match(
        $controllerText,
        'private void requestIntegratedServerFreeze\(IntegratedServer server\) \{(?<body>.*?)\r?\n    \}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$freezeTaskBody = if ($freezeTaskMatch.Success) { $freezeTaskMatch.Groups['body'].Value } else { '' }
$movementMatch = [regex]::Match(
        $controllerText,
        'if \(cameraChanged\) \{(?<body>.*?)\r?\n        \}\r?\n        if \(!hasRenderSignature',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$movementBody = if ($movementMatch.Success) { $movementMatch.Groups['body'].Value } else { '' }
$pendingGuardIndex = $movementBody.IndexOf('if (!thawPending)')
$movementGenerationIndex = $movementBody.IndexOf('freezeGeneration++', $pendingGuardIndex + 1)
$movementThawMarkerClearIndex = $movementBody.IndexOf('thawRequestScheduled = false', $pendingGuardIndex + 1)
$movementOwnershipIndex = $movementBody.IndexOf('freezeOwnership.ownsFreeze()', $pendingGuardIndex + 1)
$movementKeepsQueuedThawValid =
        $movementMatch.Success -and 0 -le $pendingGuardIndex -and
        $pendingGuardIndex -lt $movementGenerationIndex -and
        $pendingGuardIndex -lt $movementThawMarkerClearIndex -and
        $pendingGuardIndex -lt $movementOwnershipIndex
if (-not $movementKeepsQueuedThawValid) {
    throw 'Once thaw is pending, continuous movement must preserve its generation and scheduled marker.'
}

$thawTaskMatch = [regex]::Match(
        $controllerText,
        'private void requestIntegratedServerThaw\(IntegratedServer server\) \{(?<body>.*?)\r?\n    \}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$thawTaskBody = if ($thawTaskMatch.Success) { $thawTaskMatch.Groups['body'].Value } else { '' }
$thawTokenCheckIndex = $thawTaskBody.IndexOf('requestToken != sessionToken')
$thawGenerationCheckIndex = $thawTaskBody.IndexOf('requestGeneration != freezeGeneration')
$thawSetIndex = $thawTaskBody.IndexOf('setFrozen(false)')
$thawConsumeIndex = $thawTaskBody.IndexOf('freezeOwnership.consumeRestoreRequired()', $thawSetIndex + 1)
$staleThawCannotConsumeOwnership =
        $thawTaskMatch.Success -and 0 -le $thawTokenCheckIndex -and
        0 -le $thawGenerationCheckIndex -and
        $thawTokenCheckIndex -lt $thawSetIndex -and
        $thawGenerationCheckIndex -lt $thawSetIndex -and
        $thawSetIndex -lt $thawConsumeIndex
if (-not $staleThawCannotConsumeOwnership) {
    throw 'A thaw from an old session/generation must not unfreeze or consume current ownership.'
}

$autoThawValid =
        $controllerText -match 'private volatile long\s+freezeGeneration;' -and
        $controllerText -match 'private volatile boolean\s+thawPending;' -and
        $controllerText -match '(?s)if \(cameraChanged\).*?freezeGeneration\+\+.*?currentFrameAccumulating\s*=\s*false' -and
        $controllerText -match '(?s)freezeOwnership\.ownsFreeze\(\).*?requestIntegratedServerThaw' -and
        $controllerText -match 'thawPending\s*\?\s*false\s*:\s*OfflineModePolicy\.worldFrozen' -and
        $freezeTaskBody -match 'requestGeneration\s*=\s*freezeGeneration;' -and
        $freezeTaskBody -match 'requestGeneration != freezeGeneration' -and
        $controllerText -match '(?s)setFrozen\(false\).*?freezeOwnership\.consumeRestoreRequired\(\)' -and
        $controllerText -match '(?s)catch \(Throwable t\) \{.*?thawRequestScheduled\s*=\s*false;.*?could not thaw'
if (-not $autoThawValid) {
    throw 'Owned freezes must auto-thaw with token/generation stale-task protection and retryable ownership.'
}

$frozenInputsValid =
        $compositeText -match 'float waterTime = offlineAccumulating\s*\?\s*RtOfflineController\.INSTANCE\.waterTime\(liveWaterTime\)\s*:\s*liveWaterTime;' -and
        $compositeText -match 'if \(offlineAccumulating && offlineSkyCaptured\)' -and
        $compositeText -notmatch 'if \(offlinePath && offlineSkyCaptured\)'
if (-not $frozenInputsValid) {
    throw 'Water and sky snapshots must be frozen only during actual accumulation.'
}

$sampleAbiValid =
        $commonText -match 'public uint64_t\s+offlineSampleBase;' -and
        $compositeText -match 'offlineDecision\.previousSamples\(\)' -and
        $raygenText -match 'pc\.offlineSampleBase \+ uint64_t\(s\)'
if (-not $sampleAbiValid) {
    throw 'WorldPush must carry Decision.previousSamples as the per-SPP global offline sample base.'
}

$r2HelperMatch = [regex]::Match(
        $raygenText,
        'float2 offlineR2Sample\(uint pixelHash, uint64_t globalSampleIndex\) \{(?<body>.*?)\r?\n\}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$r2Body = if ($r2HelperMatch.Success) { $r2HelperMatch.Groups['body'].Value } else { '' }
$seedHelperMatch = [regex]::Match(
        $raygenText,
        'uint offlinePathSeed\(uint pixelHash, uint64_t globalSampleIndex\) \{(?<body>.*?)\r?\n\}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$offlineMainMatch = [regex]::Match(
        $raygenText,
        '#ifdef CAUSTICA_OFFLINE_FP32\s*\r?\n\[shader\("raygeneration"\)\]\s*\r?\nvoid main\(\) \{(?<body>.*?)\r?\n\}\s*\r?\n#else\s*\r?\n\[shader\("raygeneration"\)\]',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$offlineMainBody = if ($offlineMainMatch.Success) { $offlineMainMatch.Groups['body'].Value } else { '' }
$offlineLoopMatch = [regex]::Match(
        $offlineMainBody,
        'for \(uint s = 0u; s < spp; s\+\+\) \{(?<body>.*?)\r?\n    \}',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)
$offlineLoopBody = if ($offlineLoopMatch.Success) { $offlineLoopMatch.Groups['body'].Value } else { '' }
$sampleIndexInLoop = $offlineLoopBody.IndexOf('pc.offlineSampleBase + uint64_t(s)')
$samplePositionInLoop = $offlineLoopBody.IndexOf('offlineR2Sample(pixelHash, globalSampleIndex)', $sampleIndexInLoop + 1)
$nearRayInLoop = $offlineLoopBody.IndexOf('float4 nearH =', $samplePositionInLoop + 1)
$farRayInLoop = $offlineLoopBody.IndexOf('float4 farH =', $nearRayInLoop + 1)
$originInLoop = $offlineLoopBody.IndexOf('origin = nearP + pc.camOffset', $farRayInLoop + 1)
$directionInLoop = $offlineLoopBody.IndexOf('dir = normalize(farP - nearP)', $originInLoop + 1)
$coneInLoop = $offlineLoopBody.IndexOf('primaryRayConeSpread(jndc, size, dir)', $directionInLoop + 1)
$seedInLoop = $offlineLoopBody.IndexOf('offlinePathSeed(pixelHash, globalSampleIndex)', $coneInLoop + 1)
$traceInLoop = $offlineLoopBody.IndexOf('tracePath(origin, dir, rayConeSpread, seed)', $seedInLoop + 1)
$sanitizeInOfflineMain = $offlineMainBody.IndexOf('frameRadiance = sanitizeRadiance')
$storeInOfflineMain = $offlineMainBody.IndexOf('outImage[pix] = float4(frameRadiance, 1.0)', $sanitizeInOfflineMain + 1)
$perSppPrimaryValid =
        $r2HelperMatch.Success -and
        $r2Body -match '0xC13FA9A902A6328F' -and
        $r2Body -match '0x91E10DA5C79E7B1D' -and
        $r2Body -match '0x68bc21ebu' -and
        $r2Body -match '0x02e5be93u' -and
        $r2Body -match '0x967a889bu' -and
        $r2Body -match '0x368cc8b7u' -and
        $r2Body -match 'phaseX >> 40' -and
        $r2Body -match 'phaseY >> 40' -and
        $r2Body -match 'float\(uint\(phaseX >> 40\)\) \* high24ToUnit' -and
        $r2Body -match 'float\(uint\(phaseY >> 40\)\) \* high24ToUnit' -and
        $r2Body -notmatch '\+\s*0\.5' -and
        $r2Body -notmatch 'float\(globalSampleIndex\)' -and
        $seedHelperMatch.Success -and
        $seedHelperMatch.Groups['body'].Value -match 'uint\(globalSampleIndex\)' -and
        $seedHelperMatch.Groups['body'].Value -match 'uint\(globalSampleIndex >> 32\)' -and
        $offlineMainMatch.Success -and $offlineLoopMatch.Success -and
        0 -le $sampleIndexInLoop -and $sampleIndexInLoop -lt $samplePositionInLoop -and
        $samplePositionInLoop -lt $nearRayInLoop -and $nearRayInLoop -lt $farRayInLoop -and
        $farRayInLoop -lt $originInLoop -and $originInLoop -lt $directionInLoop -and
        $directionInLoop -lt $coneInLoop -and $coneInLoop -lt $seedInLoop -and
        $seedInLoop -lt $traceInLoop -and
        0 -le $sanitizeInOfflineMain -and $sanitizeInOfflineMain -lt $storeInOfflineMain
if (-not $perSppPrimaryValid) {
    throw 'Each offline SPP must reconstruct an R2-jittered primary ray and seed from low/high global sample bits.'
}

$radianceSanitizationValid =
        $raygenText -match 'float sanitizeRadianceComponent\(float value\) \{\s*return isfinite\(value\) && value >= 0\.0 \? value : 0\.0;\s*\}' -and
        0 -le $sanitizeInOfflineMain -and $sanitizeInOfflineMain -lt $storeInOfflineMain -and
        $raygenText -notmatch 'fireflyClamp|luminanceClamp'
if (-not $radianceSanitizationValid) {
    throw 'Final radiance must clear negative/NaN/Inf components without a luminance clamp.'
}

Write-Output 'Offline FP32 trace, shader variant, sample ABI, and per-SPP contracts: PASS'
exit 0
