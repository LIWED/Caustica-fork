[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$deployScript = Join-Path $PSScriptRoot 'deploy_test_mod.ps1'
$testRoot = Join-Path $projectRoot ('build\deployment-tests\' + [guid]::NewGuid().ToString('N'))
$mods = Join-Path $testRoot 'mods'
$null = New-Item -ItemType Directory -Path $mods -Force
$version = ((Get-Content -LiteralPath (Join-Path $projectRoot 'gradle.properties') | Where-Object { $_ -match '^mod_version=' }) -split '=', 2)[1].Trim()

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}

function New-FixtureJar([string] $Path, [string] $Id, [string] $Version, [string] $Payload = 'fixture') {
    $archive = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $archive.CreateEntry('fabric.mod.json')
        $writer = New-Object IO.StreamWriter($entry.Open())
        try { $writer.Write((@{ schemaVersion = 1; id = $Id; version = $Version; name = $Payload } | ConvertTo-Json -Compress)) }
        finally { $writer.Dispose() }
    }
    finally { $archive.Dispose() }
}

function Assert-Rejected([scriptblock] $Action, [string] $Message) {
    $rejected = $false
    try { & $Action | Out-Null }
    catch { $rejected = $true }
    Assert-True $rejected $Message
}

Assert-True (Test-Path -LiteralPath $deployScript -PathType Leaf) 'Deployment must be implemented.'
$source = Join-Path $testRoot "caustica-$version.jar"
$old = Join-Path $mods 'renamed-renderer.jar'
$other = Join-Path $mods 'caustica-looking-unrelated.jar'
New-FixtureJar $source 'caustica' $version
New-FixtureJar $old 'caustica' 'old'
New-FixtureJar $other 'another_mod' '1.0'
$otherHash = (Get-FileHash -LiteralPath $other).Hash
$oldHash = (Get-FileHash -LiteralPath $old).Hash
Set-Content -LiteralPath "$old.disabled" -Value 'existing backup'
$backupHash = (Get-FileHash -LiteralPath "$old.disabled").Hash

$result = & $deployScript -SourceJar $source -ModsDirectory $mods
$active = Join-Path $mods (Split-Path -Leaf $source)
Assert-True ($result.Status -eq 'Deployed') 'First deployment must activate the runtime JAR.'
Assert-True ((Get-FileHash -LiteralPath $active).Hash -eq (Get-FileHash -LiteralPath $source).Hash) 'Deployed bytes must match the build.'
Assert-True (-not (Test-Path -LiteralPath $old)) 'Caustica metadata must disable an old JAR even under an unrelated filename.'
Assert-True ((Get-FileHash -LiteralPath $other).Hash -eq $otherHash) 'Name matching must not disable unrelated mods.'
Assert-True ((Get-FileHash -LiteralPath "$old.disabled").Hash -eq $backupHash) 'Existing disabled backups must survive name collisions.'
Assert-True (@(Get-ChildItem -LiteralPath $mods -Filter '*.disabled' | Where-Object { (Get-FileHash -LiteralPath $_.FullName).Hash -eq $oldHash }).Count -eq 1) 'Old bytes must be preserved in a collision-safe disabled backup.'
$beforeRepeat = @(Get-ChildItem -LiteralPath $mods).Count
$result = & $deployScript -SourceJar $source -ModsDirectory $mods
Assert-True ($result.Status -eq 'AlreadyCurrent') 'Identical repeated deployment must be a no-op.'
Assert-True (@(Get-ChildItem -LiteralPath $mods).Count -eq $beforeRepeat) 'Idempotence must not accumulate disabled files.'

$replacementDirectory = Join-Path $testRoot 'replacement'
$null = New-Item -ItemType Directory -Path $replacementDirectory
$replacement = Join-Path $replacementDirectory (Split-Path -Leaf $source)
New-FixtureJar $replacement 'caustica' $version 'rebuilt with changed bytes'
$result = & $deployScript -SourceJar $replacement -ModsDirectory $mods
Assert-True ((Get-FileHash -LiteralPath $active).Hash -eq (Get-FileHash -LiteralPath $replacement).Hash) 'A same-version rebuild must replace changed bytes.'
Assert-True ((Get-FileHash -LiteralPath "$active.disabled").Hash -eq (Get-FileHash -LiteralPath $source).Hash) 'A same-version rebuild must preserve the previous build.'

$badDirectory = Join-Path $testRoot 'wrong-version'
$null = New-Item -ItemType Directory -Path $badDirectory
$bad = Join-Path $badDirectory (Split-Path -Leaf $source)
New-FixtureJar $bad 'caustica' 'wrong'
Assert-Rejected { & $deployScript -SourceJar $bad -ModsDirectory $mods } 'Wrong source version must be rejected.'
$wrongIdDirectory = Join-Path $testRoot 'wrong-id'
$null = New-Item -ItemType Directory -Path $wrongIdDirectory
$wrongId = Join-Path $wrongIdDirectory (Split-Path -Leaf $source)
New-FixtureJar $wrongId 'another_mod' $version
Assert-Rejected { & $deployScript -SourceJar $wrongId -ModsDirectory $mods } 'Wrong source mod ID must be rejected.'
$sources = Join-Path $testRoot "caustica-$version-sources.jar"
New-FixtureJar $sources 'caustica' $version
Assert-Rejected { & $deployScript -SourceJar $sources -ModsDirectory $mods } 'Sources JARs must never be deployed.'

# A copy error must be caught before any currently active package is disabled.
$beforeCorruption = (Get-FileHash -LiteralPath $active).Hash
& {
    function Copy-Item {
        [CmdletBinding()]
        param([string] $LiteralPath, [string] $Destination)
        Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination
        Add-Content -LiteralPath $Destination -Value 'injected copy corruption'
    }
    Assert-Rejected { & $deployScript -SourceJar $source -ModsDirectory $mods } 'Staged copy corruption must reject deployment.'
}
Assert-True ((Get-FileHash -LiteralPath $active).Hash -eq $beforeCorruption) 'Staging failure must leave the active build unchanged.'

# Only activation is fault-injected; old files are renamed and restored on disk.
$beforeFailure = (Get-FileHash -LiteralPath $active).Hash
& {
    function Rename-Item {
        [CmdletBinding()]
        param([string] $LiteralPath, [string] $NewName)
        if ($LiteralPath.EndsWith('.staged')) { throw 'Injected activation failure' }
        Microsoft.PowerShell.Management\Rename-Item -LiteralPath $LiteralPath -NewName $NewName
    }
    Assert-Rejected { & $deployScript -SourceJar $source -ModsDirectory $mods } 'Activation failure must be surfaced.'
}
Assert-True ((Get-FileHash -LiteralPath $active).Hash -eq $beforeFailure) 'Activation failure must restore the former active JAR.'
Assert-True ((Get-FileHash -LiteralPath $other).Hash -eq $otherHash) 'Rollback must preserve unrelated mods.'
Assert-True (@(Get-ChildItem -LiteralPath $mods -Force -Filter '*.staged').Count -eq 0) 'Failed deployment must clean its staging file.'

# Failure after activation must also restore the former active package.
& {
    function Get-FileHash {
        [CmdletBinding()]
        param([string] $LiteralPath, [string] $Algorithm = 'SHA256')
        $hash = Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath -Algorithm $Algorithm
        if ($LiteralPath -eq $active) { $hash.Hash = 'injected activated hash mismatch' }
        return $hash
    }
    Assert-Rejected { & $deployScript -SourceJar $source -ModsDirectory $mods } 'Activated copy corruption must reject deployment.'
}
Assert-True ((Get-FileHash -LiteralPath $active).Hash -eq $beforeFailure) 'Post-activation verification failure must restore the former active JAR.'
Assert-True (@(Get-ChildItem -LiteralPath $mods -Force -Filter '*.staged').Count -eq 0) 'Post-activation rollback must clean its staging file.'

$collisionMods = Join-Path $testRoot 'collision-mods'
$null = New-Item -ItemType Directory -Path $collisionMods
$collision = Join-Path $collisionMods (Split-Path -Leaf $source)
New-FixtureJar $collision 'another_mod' '1.0'
$collisionHash = (Get-FileHash -LiteralPath $collision).Hash
Assert-Rejected { & $deployScript -SourceJar $source -ModsDirectory $collisionMods } 'A target name occupied by another mod must be rejected.'
Assert-True ((Get-FileHash -LiteralPath $collision).Hash -eq $collisionHash) 'Target collisions must preserve the other mod.'

# Even an identical current build must disable any additional active Caustica package.
$duplicate = Join-Path $mods 'another-caustica.jar'
New-FixtureJar $duplicate 'caustica' 'older'
$null = & $deployScript -SourceJar $replacement -ModsDirectory $mods
Assert-True (-not (Test-Path -LiteralPath $duplicate)) 'Duplicate old Caustica JARs must be disabled even when the current hash matches.'
Assert-True ((Get-FileHash -LiteralPath $active).Hash -eq $beforeFailure) 'Duplicate cleanup must preserve the requested current build.'

$linkedMods = Join-Path $testRoot 'linked-mods'
$null = New-Item -ItemType Junction -Path $linkedMods -Target $mods
Assert-Rejected { & $deployScript -SourceJar $source -ModsDirectory $linkedMods } 'A junction must not redirect deployment outside the selected physical mods directory.'

# Exercise the actual build wrapper's packaging decision without invoking a full native build.
$parseErrors = $null
$tokens = $null
$buildAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'build_local.ps1'), [ref] $tokens, [ref] $parseErrors)
$predicate = $buildAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-ShouldDeploy' }, $true)
Assert-True ($null -ne $predicate) 'Build wrapper must gate deployment on actual packaging requests.'
. ([scriptblock]::Create($predicate.Extent.Text))
foreach ($arguments in @(@('build'), @(':jar'), @('assemble', '--no-daemon'), @('build', '-x', 'test'))) {
    Assert-True (Test-ShouldDeploy -Arguments $arguments) "Packaging request must deploy: $arguments"
}
foreach ($arguments in @(@('test'), @('check'), @('tasks'), @('build', '--dry-run'), @('jar', '-m'), @('build', '--help'), @('build', '-x', 'jar'), @('build', '-xjar'), @('build', '--exclude-task=jar'), @('test', '--project-dir', 'build'), @('test', '-Pnote=build'), @('test', '-P', 'build'), @(':other:build'), @('build', '-p', 'another-project'), @('build', '--project-dir=another-project'), @('build', '-banother.gradle'), @('test', '--system-prop', 'build'))) {
    Assert-True (-not (Test-ShouldDeploy -Arguments $arguments)) "Non-packaging invocation must not deploy: $arguments"
}

Write-Host "PASS: deployment, metadata selection, hash verification, backup collisions, idempotence, same-version replacement, validation, rollback, unrelated-mod protection, packaging task gating. Fixtures: $testRoot"
