$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$outputDir = Join-Path $projectRoot 'build\path-probe\tests'
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$source = Join-Path $projectRoot 'src\main\java\dev\comfyfluffy\caustica\rt\offline'
& 'D:\program\java25\bin\javac.exe' --release 25 -d $outputDir `
    (Join-Path $source 'OfflinePathProbeCodec.java') `
    (Join-Path $source 'OfflinePathProbeOwnership.java') `
    (Join-Path $source 'OfflinePathProbeBudget.java') `
    (Join-Path $PSScriptRoot 'tests\OfflinePathProbeBehaviorTest.java') `
    (Join-Path $PSScriptRoot 'tests\OfflinePathProbeBudgetTest.java')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& 'D:\program\java25\bin\java.exe' -cp $outputDir OfflinePathProbeBehaviorTest
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& 'D:\program\java25\bin\java.exe' -cp $outputDir OfflinePathProbeBudgetTest
exit $LASTEXITCODE
