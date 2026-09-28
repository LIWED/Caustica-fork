[CmdletBinding()]
param(
    [string] $SourceJar,
    [string] $ModsDirectory = 'E:\Minecraft\.minecraft\versions\caustica_test\mods'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

function Read-ModMetadata([string] $Path) {
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $archive.GetEntry('fabric.mod.json')
        if ($null -eq $entry) { return $null }
        $reader = New-Object IO.StreamReader($entry.Open())
        try { return ($reader.ReadToEnd() | ConvertFrom-Json) }
        finally { $reader.Dispose() }
    }
    finally { $archive.Dispose() }
}

function Assert-NoReparsePoint([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Deployment refuses a symbolic link or junction: $($item.FullName)"
        }
        $item = if ($item -is [IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
    }
}

function Assert-TargetPath([string] $Path) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($fullPath), $targetRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Deployment path is outside the selected mods directory: $Path"
    }
    if (Test-Path -LiteralPath $fullPath) { Assert-NoReparsePoint $fullPath }
    return $fullPath
}

$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$properties = @{}
foreach ($line in Get-Content -LiteralPath (Join-Path $projectRoot 'gradle.properties')) {
    if ($line -match '^\s*(mod_version|archives_base_name)\s*=\s*(.*?)\s*$') {
        $properties[$Matches[1]] = $Matches[2]
    }
}
foreach ($key in @('mod_version', 'archives_base_name')) {
    if (-not $properties.ContainsKey($key) -or $properties[$key] -notmatch '^[A-Za-z0-9][A-Za-z0-9._+\-]*$') {
        throw "Missing or unsafe $key in gradle.properties."
    }
}
$expectedVersion = $properties['mod_version']
$runtimeName = "$($properties['archives_base_name'])-$expectedVersion.jar"
if ([string]::IsNullOrWhiteSpace($SourceJar)) { $SourceJar = Join-Path $projectRoot "build\libs\$runtimeName" }
if (-not (Test-Path -LiteralPath $SourceJar -PathType Leaf)) { throw "Runtime JAR was not found: $SourceJar" }
$sourcePath = (Resolve-Path -LiteralPath $SourceJar).Path
if ([IO.Path]::GetFileName($sourcePath) -cne $runtimeName) { throw "Expected runtime artifact $runtimeName, received $sourcePath" }
$metadata = Read-ModMetadata $sourcePath
if ($null -eq $metadata -or $metadata.id -cne 'caustica' -or $metadata.version -cne $expectedVersion) {
    throw "Runtime JAR must declare mod ID caustica and source version $expectedVersion."
}
$sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
if (-not (Test-Path -LiteralPath $ModsDirectory -PathType Container)) { throw "Test mods directory was not found: $ModsDirectory" }
Assert-NoReparsePoint $ModsDirectory
$targetRoot = (Resolve-Path -LiteralPath $ModsDirectory).Path.TrimEnd('\', '/')
$destination = Assert-TargetPath (Join-Path $targetRoot $runtimeName)
if ([string]::Equals($sourcePath, $destination, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Source JAR must be outside the destination mods directory.'
}
$activeMods = @()
foreach ($jar in Get-ChildItem -LiteralPath $targetRoot -Filter '*.jar' -File) {
    $jarPath = Assert-TargetPath $jar.FullName
    try { $installed = Read-ModMetadata $jarPath }
    catch { continue } # Invalid archives cannot identify themselves as a Caustica mod.
    if ($null -ne $installed -and $null -ne $installed.PSObject.Properties['id'] -and $installed.id -ceq 'caustica') {
        $activeMods += $jarPath
    }
}
if ((Test-Path -LiteralPath $destination) -and $activeMods -notcontains $destination) {
    throw "The runtime filename is occupied by a non-Caustica file: $destination"
}
if ($activeMods.Count -eq 1 -and $activeMods[0] -eq $destination -and (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -eq $sourceHash) {
    return [PSCustomObject]@{ Status = 'AlreadyCurrent'; Path = $destination; Version = $expectedVersion; SHA256 = $sourceHash; Disabled = @() }
}

$staged = Assert-TargetPath (Join-Path $targetRoot ('.caustica-' + [guid]::NewGuid().ToString('N') + '.staged'))
$renamed = New-Object 'System.Collections.Generic.List[object]'
$activated = $false
try {
    Copy-Item -LiteralPath $sourcePath -Destination $staged
    if ((Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash -ne $sourceHash) { throw 'Staged JAR hash does not match the runtime artifact.' }
    foreach ($oldPath in $activeMods) {
        $null = Assert-TargetPath $oldPath
        $disabled = Assert-TargetPath "$oldPath.disabled"
        while (Test-Path -LiteralPath $disabled) {
            $disabled = Assert-TargetPath (Join-Path $targetRoot ([IO.Path]::GetFileNameWithoutExtension($oldPath) + '.' + [guid]::NewGuid().ToString('N') + '.jar.disabled'))
        }
        Rename-Item -LiteralPath $oldPath -NewName ([IO.Path]::GetFileName($disabled))
        $renamed.Add([PSCustomObject]@{ Original = $oldPath; Disabled = $disabled })
    }
    $null = Assert-TargetPath $destination
    Rename-Item -LiteralPath $staged -NewName $runtimeName
    $activated = $true
    if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $sourceHash) { throw 'Activated JAR hash does not match the runtime artifact.' }
}
catch {
    $deploymentError = $_
    $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
    if ($activated) {
        try {
            $null = Assert-TargetPath $destination
            Rename-Item -LiteralPath $destination -NewName ([IO.Path]::GetFileName($staged))
        }
        catch { $rollbackErrors.Add($_.Exception.Message) }
    }
    for ($index = $renamed.Count - 1; $index -ge 0; $index--) {
        try {
            $previous = $renamed[$index]
            $null = Assert-TargetPath $previous.Disabled
            $null = Assert-TargetPath $previous.Original
            Rename-Item -LiteralPath $previous.Disabled -NewName ([IO.Path]::GetFileName($previous.Original))
        }
        catch { $rollbackErrors.Add($_.Exception.Message) }
    }
    if ($rollbackErrors.Count -gt 0) {
        throw "Deployment failed: $($deploymentError.Exception.Message). Some originals could not be restored; their disabled backups are retained. Rollback errors: $($rollbackErrors -join '; ')"
    }
    throw $deploymentError
}
finally {
    if (Test-Path -LiteralPath $staged -PathType Leaf) {
        $null = Assert-TargetPath $staged
        Remove-Item -LiteralPath $staged
    }
}

[PSCustomObject]@{
    Status = 'Deployed'
    Path = $destination
    Version = $expectedVersion
    SHA256 = $sourceHash
    Disabled = @($renamed | ForEach-Object { $_.Disabled })
}
