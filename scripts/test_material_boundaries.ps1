[CmdletBinding()]
param([string]$Python = 'F:\AiStudy\AiSoftware\aiconda\python.exe')
$ErrorActionPreference = 'Stop'
& $Python (Join-Path $PSScriptRoot 'tests\test_material_boundaries.py')
exit $LASTEXITCODE
