Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$TestDir = $PSScriptRoot
$ExpRoot = Split-Path -Parent $TestDir
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $ExpRoot)
$ProfilerRoot = Join-Path $ExpRoot 'profiler'
$ProfilerFixturesDir = Join-Path $TestDir 'profiler\fixtures'
$ProfilerExpectedDir = Join-Path $TestDir 'profiler\expected'
$AggregateFilter = Join-Path $ProfilerRoot 'shared\aggregate-collapsed.jq'
$ValidateSummaryFilter = Join-Path $ProfilerRoot 'shared\validate-profile-summary.jq'
$ConfigFile = Join-Path $ProfilerRoot 'shared\profile-config.json'
$OfficialManifestFileOriginal = Join-Path $ProfilerRoot 'shared\official-result-manifest.json'
$AsyncProfilerLockFile = Join-Path $ExpRoot 'tools\async-profiler.lock'
$DockerDir = Join-Path $ProfilerRoot 'docker'
$ContainerRunner = Join-Path $ProfilerRoot 'container\exp001-profile.sh'
$WindowsOrchestrator = Join-Path $ProfilerRoot 'windows\exp001-profile.ps1'

. (Join-Path $ExpRoot 'windows\Common.ps1')

$env:EXP001_PROFILE_IMPORT_ONLY = '1'
. $WindowsOrchestrator

function Fail-Fixture {
    param([string] $Message)
    throw $Message
}

function Assert-True {
    param(
        [bool] $Condition,
        [string] $Message
    )

    if (-not $Condition) {
        Fail-Fixture $Message
    }
}

function Assert-Fails {
    param(
        [scriptblock] $Block,
        [string] $Message
    )

    $failed = $false
    try {
        & $Block | Out-Null
    } catch {
        $failed = $true
    }
    Assert-True $failed $Message
}

function Assert-BytesEqual {
    param(
        [string] $ExpectedPath,
        [string] $ActualPath
    )

    $expected = [System.IO.File]::ReadAllBytes($ExpectedPath)
    $actual = [System.IO.File]::ReadAllBytes($ActualPath)
    Assert-True ($expected.Length -eq $actual.Length) "byte length mismatch: expected=$ExpectedPath actual=$ActualPath"
    for ($index = 0; $index -lt $expected.Length; $index++) {
        if ($expected[$index] -ne $actual[$index]) {
            Fail-Fixture "byte mismatch at offset ${index}: expected=$ExpectedPath actual=$ActualPath"
        }
    }
}

function Write-Utf8File {
    param(
        [string] $Path,
        [string] $Text
    )

    [System.IO.File]::WriteAllText($Path, $Text, $Script:Utf8NoBom)
}

function Write-JsonFile {
    param(
        [string] $Path,
        [object] $Value
    )

    Write-Utf8File -Path $Path -Text (($Value | ConvertTo-Json -Depth 32) + "`n")
}

function Copy-JsonObject {
    param([object] $Value)
    return ($Value | ConvertTo-Json -Depth 32 | ConvertFrom-Json)
}

function Invoke-JqExitCode {
    param([string[]] $Arguments)

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Jq @Arguments 1>$null 2>$null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
}

function Assert-ProfileSummaryValid {
    param([string] $Path)

    $exitCode = Invoke-JqExitCode -Arguments @('-e', '-f', $ValidateSummaryFilter, $Path)
    Assert-True ($exitCode -eq 0) "profile summary validation failed: $Path"
}

function Assert-ProfileSummaryInvalid {
    param([string] $Path)

    $exitCode = Invoke-JqExitCode -Arguments @('-e', '-f', $ValidateSummaryFilter, $Path)
    Assert-True ($exitCode -ne 0) "profile summary unexpectedly passed: $Path"
}

function New-LockText {
    return @'
version=4.5
tag=v4.5
platform=linux-x64
asset=async-profiler-4.5-linux-x64.tar.gz
url=https://github.com/async-profiler/async-profiler/releases/download/v4.5/async-profiler-4.5-linux-x64.tar.gz
sha256=89546fbb9ee0fc5496c7edd4099b0709489bc78b0d8057ccbb4b801f6b032b62
size=447164
archive_root=async-profiler-4.5-linux-x64
install_dir=scripts/exp-001/.tools/async-profiler/linux-x64/4.5/async-profiler-4.5-linux-x64
asprof=bin/asprof
jfrconv=bin/jfrconv
library=lib/libasyncProfiler.so
license=Apache-2.0
'@
}

function Write-LockFixture {
    param(
        [string] $Name,
        [string] $Text
    )

    $path = Join-Path $tempRoot $Name
    Write-Utf8File -Path $path -Text ($Text.Trim() + "`n")
    return $path
}

function Assert-OfficialResultManifest {
    $manifest = Get-Content -LiteralPath $OfficialManifestFile -Encoding UTF8 -Raw | ConvertFrom-Json
    $resultRoot = Join-Path $ProjectRoot (($manifest.officialResultPath).Replace('/', '\'))
    $actualFiles = @(Get-ChildItem -LiteralPath $resultRoot -Recurse -File)
    Assert-True ($actualFiles.Count -eq [int] $manifest.expectedFileCount) "official result file count changed: $($actualFiles.Count)"

    foreach ($entry in @($manifest.files)) {
        $path = Join-Path $ProjectRoot (($entry.path).Replace('/', '\'))
        Assert-True (Test-Path -LiteralPath $path) "official result file missing: $($entry.path)"
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-True ($actual -eq [string] $entry.sha256) "official result SHA changed: $($entry.path)"
    }
}

function Git-CheckIgnored {
    param([string] $Path)
    & git -C $ProjectRoot check-ignore -q -- $Path
    return $LASTEXITCODE -eq 0
}

function Assert-GitIgnored {
    param([string] $Path)
    Assert-True (Git-CheckIgnored -Path $Path) "path should be ignored: $Path"
}

function Assert-GitNotIgnored {
    param([string] $Path)
    Assert-True (-not (Git-CheckIgnored -Path $Path)) "path should not be ignored: $Path"
}

function Assert-GitAttr {
    param(
        [string] $Path,
        [string] $Attribute,
        [string] $ExpectedValue
    )

    $output = & git -C $ProjectRoot check-attr $Attribute -- $Path
    if ($LASTEXITCODE -ne 0) {
        Fail-Fixture "git check-attr failed: $Path $Attribute"
    }
    $actual = ($output -replace '^.*: [^:]+: ', '').Trim()
    Assert-True ($actual -eq $ExpectedValue) "git attr mismatch: path=$Path attr=$Attribute expected=$ExpectedValue actual=$actual"
}

function Assert-DockerPolicy {
    foreach ($path in @(
        (Join-Path $DockerDir 'compose.yml'),
        (Join-Path $DockerDir 'compose.seccomp.yml'),
        (Join-Path $DockerDir 'compose.sys-admin.yml')
    )) {
        $text = Get-Content -LiteralPath $path -Encoding UTF8 -Raw
        Assert-True ($text -notmatch '(?m)^\s*privileged\s*:\s*true\s*$') "privileged true is forbidden: $path"
        Assert-True ($text -notmatch '(?m)^\s*pid\s*:\s*host\s*$') "host pid is forbidden: $path"
        Assert-True ($text -notmatch '(?m)^\s*container_name\s*:') "fixed container_name is forbidden: $path"
        Assert-True ($text -notmatch '/var/run/docker\.sock') "Docker socket mount is forbidden: $path"
        Assert-True ($text -notmatch 'SYS_PTRACE') "SYS_PTRACE is not part of the default plan: $path"
    }
    $base = Get-Content -LiteralPath (Join-Path $DockerDir 'compose.yml') -Encoding UTF8 -Raw
    Assert-True ($base -notmatch 'SYS_ADMIN') 'Level 0 compose must not include SYS_ADMIN'
    Assert-True ($base -notmatch 'seccomp=unconfined') 'Level 0 compose must not include seccomp override'
    Assert-True ($base -match '\.\./\.\./\.tools/async-profiler/linux-x64/4\.5/async-profiler-4\.5-linux-x64:/opt/async-profiler:ro') 'async-profiler tool mount path mismatch'
    $level2 = Get-Content -LiteralPath (Join-Path $DockerDir 'compose.sys-admin.yml') -Encoding UTF8 -Raw
    Assert-True ($level2 -match 'SYS_ADMIN') 'Level 2 override must include SYS_ADMIN'
}

function New-AggregationManifest {
    return [ordered] @{
        aggregationFormatVersion = 1
        profileId = 'cpu-jpa'
        event = 'cpu'
        cpuEngine = 'cpu'
        strategy = 'jpa'
        interval = '10ms'
        counterKind = 'cpuSamples'
        repetitions = 2
        rowsPerInvocation = 50000
        totalRows = 100000
        expectedChunkCount = 2
        chunks = @(
            [ordered] @{
                sequence = 1
                filename = '001-jpa-cpu.collapsed'
                event = 'cpu'
                strategy = 'jpa'
                counterKind = 'cpuSamples'
                rows = 50000
                workloadValid = $true
                sourceArtifactSha256 = ('a' * 64)
                collapsedContent = "com.example.persistencebenchmark.persistence.jpa.JpaBenchmarkRecordPersistenceService.saveAll;org.hibernate.engine.spi.ActionQueue.executeActions 3`ncom.example.persistencebenchmark.persistence.jdbc.JdbcBatchBenchmarkRecordPersistenceService.saveAll;org.postgresql.core.v3.QueryExecutorImpl.execute 4`n"
            }
            [ordered] @{
                sequence = 2
                filename = '002-jpa-cpu.collapsed'
                event = 'cpu'
                strategy = 'jpa'
                counterKind = 'cpuSamples'
                rows = 50000
                workloadValid = $true
                sourceArtifactSha256 = ('b' * 64)
                collapsedContent = "com.example.persistencebenchmark.persistence.jpa.JpaBenchmarkRecordPersistenceService.saveAll;org.hibernate.engine.spi.ActionQueue.executeActions 2`njava.lang.Thread.run 1`n"
            }
        )
    }
}

function Assert-AggregationInvalid {
    param([object] $Manifest, [string] $Name)

    $path = Join-Path $tempRoot "$Name.json"
    Write-JsonFile -Path $path -Value $Manifest
    $exitCode = Invoke-JqExitCode -Arguments @('-f', $AggregateFilter, $path)
    Assert-True ($exitCode -ne 0) "aggregation manifest unexpectedly passed: $Name"
}

function Convert-ToGitBashPath {
    param([string] $Path)

    $full = [System.IO.Path]::GetFullPath($Path).Replace('\', '/')
    if ($full -match '^([A-Za-z]):/(.*)$') {
        return ('/' + $Matches[1].ToLowerInvariant() + '/' + $Matches[2])
    }
    return $full
}

function Invoke-ContainerFixture {
    param(
        [string[]] $Arguments,
        [string] $ProcRoot = '',
        [string] $JcmdListFile = ''
    )

    $bash = 'C:\Program Files\Git\usr\bin\bash.exe'
    Assert-True (Test-Path -LiteralPath $bash) 'Git Bash is required for container helper fixtures'
    function Quote-BashArgument {
        param([string] $Value)
        return "'" + $Value.Replace("'", "'\''") + "'"
    }
    $oldProc = $env:EXP001_PROC_ROOT
    $oldJcmd = $env:EXP001_JCMD_LIST_FILE
    $oldProfile = $env:SPRING_PROFILES_ACTIVE
    $oldPath = $env:PATH
    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $env:PATH = "C:\Program Files\Git\usr\bin;$oldPath"
        if ($ProcRoot.Length -gt 0) {
            $env:EXP001_PROC_ROOT = Convert-ToGitBashPath -Path $ProcRoot
        }
        if ($JcmdListFile.Length -gt 0) {
            $env:EXP001_JCMD_LIST_FILE = Convert-ToGitBashPath -Path $JcmdListFile
        }
        $env:SPRING_PROFILES_ACTIVE = 'exp001'
        $commandParts = @((Quote-BashArgument -Value (Convert-ToGitBashPath -Path $ContainerRunner)))
        foreach ($argument in $Arguments) {
            $commandParts += (Quote-BashArgument -Value $argument)
        }
        & $bash -lc ($commandParts -join ' ') 1>$null 2>$null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
        $env:EXP001_PROC_ROOT = $oldProc
        $env:EXP001_JCMD_LIST_FILE = $oldJcmd
        $env:SPRING_PROFILES_ACTIVE = $oldProfile
        $env:PATH = $oldPath
    }
}

function New-FakeProc {
    param(
        [string] $Root,
        [string] $PidValue,
        [string] $Uid,
        [string] $Jar = '/app/app.jar',
        [string] $Profile = 'exp001',
        [string] $Start = '987654'
    )

    $pidDir = Join-Path $Root $PidValue
    New-Item -ItemType Directory -Force -Path $pidDir | Out-Null
    Write-Utf8File -Path (Join-Path $pidDir 'cmdline') -Text "java -jar $Jar --spring.profiles.active=$Profile"
    Write-Utf8File -Path (Join-Path $pidDir 'environ') -Text "SPRING_PROFILES_ACTIVE=$Profile`n"
    Write-Utf8File -Path (Join-Path $pidDir 'status') -Text "Name:`tjava`nUid:`t$Uid`t$Uid`t$Uid`t$Uid`n"
    $fields = @('123', '(java)', 'S') + (@('0') * 18) + @($Start)
    Write-Utf8File -Path (Join-Path $pidDir 'stat') -Text (($fields -join ' ') + "`n")
}

function New-SmokeResultFixture {
    param(
        [object] $Context,
        [string] $SelectedCpuEngine = 'cpu',
        [string] $EngineVerification = $EngineVerificationPerfEvents,
        [int64] $CpuSampleCount = 50,
        [int64] $AllocationSampleCount = 8,
        [int64] $AllocationSampledBytes = 4194304
    )

    return [ordered] @{
        markerFormatVersion = 2
        smokeSuccess = $true
        selectedCpuEngine = $SelectedCpuEngine
        smokeProtocolVersion = $Context['smokeProtocolVersion']
        cpuWorkloadVersion = $Context['cpuWorkloadVersion']
        allocationWorkloadVersion = $Context['allocationWorkloadVersion']
        cpuSampleCount = $CpuSampleCount
        allocationSampleCount = $AllocationSampleCount
        allocationSampledBytes = $AllocationSampledBytes
        engineVerification = $EngineVerification
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "exp001-profiler-fixtures-$PID"
if (Test-Path -LiteralPath $tempRoot) {
    Fail-Fixture "temp directory already exists: $tempRoot"
}
New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    $Jq = Require-Jq

    Read-AsyncProfilerLock -Path $AsyncProfilerLockFile | Out-Null
    Read-AsyncProfilerLock -Path (Write-LockFixture -Name 'valid.lock' -Text (New-LockText)) | Out-Null
    Assert-Fails { Read-AsyncProfilerLock -Path (Write-LockFixture -Name 'duplicate.lock' -Text ((New-LockText) + "`nversion=4.5`n")) } 'duplicate lock key should fail'
    Assert-Fails { Read-AsyncProfilerLock -Path (Write-LockFixture -Name 'unknown.lock' -Text ((New-LockText) + "`nextra=value`n")) } 'unknown lock key should fail'
    Assert-Fails { Read-AsyncProfilerLock -Path (Write-LockFixture -Name 'missing.lock' -Text ((New-LockText) -replace "license=Apache-2.0`r?`n?", '')) } 'missing lock key should fail'
    Assert-Fails { Read-AsyncProfilerLock -Path (Write-LockFixture -Name 'bad-sha.lock' -Text ((New-LockText) -replace '89546fbb9ee0fc5496c7edd4099b0709489bc78b0d8057ccbb4b801f6b032b62', 'BAD')) } 'malformed SHA should fail'
    Assert-Fails { Read-AsyncProfilerLock -Path (Write-LockFixture -Name 'bad-size.lock' -Text ((New-LockText) -replace 'size=447164', 'size=1')) } 'size mismatch should fail'

    Assert-ArchiveMemberSafe -Member 'async-profiler-4.5-linux-x64/bin/asprof' -ExpectedRoot 'async-profiler-4.5-linux-x64'
    Assert-Fails { Assert-ArchiveMemberSafe -Member '../escape' -ExpectedRoot 'async-profiler-4.5-linux-x64' } 'archive traversal should fail'
    Assert-Fails { Assert-ArchiveMemberSafe -Member '/absolute' -ExpectedRoot 'async-profiler-4.5-linux-x64' } 'absolute archive member should fail'
    Assert-Fails { Assert-ArchiveMemberSafe -Member 'C:\escape' -ExpectedRoot 'async-profiler-4.5-linux-x64' } 'drive-qualified archive member should fail'
    Assert-Fails { Assert-ArchiveMemberSafe -Member 'other-root/bin/asprof' -ExpectedRoot 'async-profiler-4.5-linux-x64' } 'unexpected archive root should fail'

    Assert-DockerPolicy
    Assert-ProfileConfig | Out-Null

    $markerPath = Join-Path $tempRoot 'smoke-ready.json'
    $oldSmokeStateFile = $SmokeStateFile
    $SmokeStateFile = $markerPath
    $context = Get-SmokeContext
    $validSmokeResult = New-SmokeResultFixture -Context $context
    $containerSmokePath = Join-Path $tempRoot 'container-smoke-result.json'
    Write-JsonFile -Path $containerSmokePath -Value $validSmokeResult
    $readContainerSmoke = Read-SmokeResult -SmokeResultPath $containerSmokePath
    Assert-True ([string] $readContainerSmoke.engineVerification -eq $EngineVerificationPerfEvents) 'container smoke result should pass'
    Write-SmokeMarker -Context $context -SmokeResult $readContainerSmoke
    $state = Assert-SmokeReady
    Assert-True ([int] $state.markerFormatVersion -eq 2) 'marker v2 should pass'
    Assert-True ([string] $state.selectedCpuEngine -eq 'cpu') 'cpu marker should pass'
    Assert-Fails { Write-SmokeMarker -Context $context -SmokeResult $readContainerSmoke } 'smoke marker no-clobber should fail'
    $badContainerSmoke = New-SmokeResultFixture -Context $context -CpuSampleCount 49
    Write-JsonFile -Path $containerSmokePath -Value $badContainerSmoke
    Assert-Fails { Read-SmokeResult -SmokeResultPath $containerSmokePath } 'container smoke CPU sample threshold should fail'

    foreach ($case in @(
        @{ Name = 'v1-rejected'; Key = 'markerFormatVersion'; Value = 1 },
        @{ Name = 'source-mismatch'; Key = 'sourceRevision'; Value = '0000000000000000000000000000000000000000' },
        @{ Name = 'harness-mismatch'; Key = 'harnessRevision'; Value = '0000000000000000000000000000000000000000' },
        @{ Name = 'version-mismatch'; Key = 'profilerVersion'; Value = '0.0' },
        @{ Name = 'sha-mismatch'; Key = 'profilerAssetSha256'; Value = ('0' * 64) },
        @{ Name = 'level-mismatch'; Key = 'securityLevel'; Value = 2 },
        @{ Name = 'engine-mismatch'; Key = 'selectedCpuEngine'; Value = 'wall' },
        @{ Name = 'engine-verification-mismatch'; Key = 'engineVerification'; Value = $EngineVerificationCtimer },
        @{ Name = 'cpu-sample-threshold'; Key = 'cpuSampleCount'; Value = 49 },
        @{ Name = 'allocation-sample-threshold'; Key = 'allocationSampleCount'; Value = 7 },
        @{ Name = 'allocation-byte-threshold'; Key = 'allocationSampledBytes'; Value = 4194303 },
        @{ Name = 'success-false'; Key = 'smokeSuccess'; Value = $false }
    )) {
        Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
        $bad = [ordered] @{
            markerFormatVersion = $context['markerFormatVersion']
            sourceRevision = $context['sourceRevision']
            harnessRevision = $context['harnessRevision']
            profilerVersion = $context['profilerVersion']
            profilerAssetSha256 = $context['profilerAssetSha256']
            securityLevel = $context['securityLevel']
            selectedCpuEngine = 'cpu'
            runtime = $context['runtime']
            architecture = $context['architecture']
            jdkVersion = $context['jdkVersion']
            smokeProtocolVersion = $context['smokeProtocolVersion']
            cpuWorkloadVersion = $context['cpuWorkloadVersion']
            allocationWorkloadVersion = $context['allocationWorkloadVersion']
            cpuSampleCount = 50
            allocationSampleCount = 8
            allocationSampledBytes = 4194304
            engineVerification = $EngineVerificationPerfEvents
            smokeSuccess = $true
            createdAtUtc = '2026-07-28T00:00:00Z'
        }
        $bad[$case.Key] = $case.Value
        Write-JsonFile -Path $markerPath -Value $bad
        Assert-Fails { Assert-SmokeReady } "smoke marker should fail: $($case.Name)"
    }
    Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
    Assert-Fails { Assert-SmokeReady } 'missing smoke marker should fail'
    $SmokeStateFile = $oldSmokeStateFile

    Assert-True ((Resolve-ProfileEventForChunk -Profile ([pscustomobject] @{ event = 'cpu' }) -CpuEngine 'ctimer') -eq 'ctimer') 'ctimer marker must propagate to CPU chunk'
    Assert-True ((Resolve-ProfileEventForChunk -Profile ([pscustomobject] @{ event = 'cpu' }) -CpuEngine 'cpu') -eq 'cpu') 'cpu marker must propagate to CPU chunk'
    Assert-True ((Resolve-ProfileEventForChunk -Profile ([pscustomobject] @{ event = 'alloc' }) -CpuEngine 'ctimer') -eq 'alloc') 'alloc chunks must keep alloc event'

    $oldRawRoot = $RawRoot
    $oldStateDir = $StateDir
    $RawRoot = Join-Path $tempRoot 'raw-cleanup'
    $StateDir = Join-Path $tempRoot 'state-cleanup'
    try {
        $smokeRaw = Join-Path $RawRoot 'smoke-demo\raw\smoke'
        New-Item -ItemType Directory -Force -Path $smokeRaw, $StateDir | Out-Null
        $rawTemp = Join-Path $smokeRaw 'cpu.jfr.tmp.123'
        $rawFinal = Join-Path $smokeRaw 'cpu.jfr'
        $stateTemp = Join-Path $StateDir 'smoke-ready.json.tmp.123'
        Write-Utf8File -Path $rawTemp -Text 'partial'
        Write-Utf8File -Path $rawFinal -Text 'final'
        Write-Utf8File -Path $stateTemp -Text 'partial'
        Clear-ProfilerPartialArtifacts
        Assert-True (-not (Test-Path -LiteralPath $rawTemp)) 'raw temp artifact should be removed'
        Assert-True (-not (Test-Path -LiteralPath $stateTemp)) 'state temp marker should be removed'
        Assert-True (Test-Path -LiteralPath $rawFinal) 'final artifact should remain'
        Assert-Fails { Assert-ProfilerCleanupPath -Path (Join-Path $tempRoot 'escape.tmp') -Root $RawRoot } 'cleanup path escape should fail'
    } finally {
        $RawRoot = $oldRawRoot
        $StateDir = $oldStateDir
    }

    $aggregateManifest = New-AggregationManifest
    $aggregateManifestPath = Join-Path $tempRoot 'aggregate-manifest.json'
    Write-JsonFile -Path $aggregateManifestPath -Value $aggregateManifest
    $aggregateActual = Join-Path $tempRoot 'sample-aggregate.json'
    Invoke-JqToFile -Arguments @('-f', $AggregateFilter, $aggregateManifestPath) -DestinationPath $aggregateActual
    Assert-TextFileLfUtf8NoBomFinalNewline -Path $aggregateActual
    Assert-BytesEqual -ExpectedPath (Join-Path $ProfilerExpectedDir 'sample-aggregate.json') -ActualPath $aggregateActual

    $invalidAggregationCases = @(
        @{ Name = 'duplicate-sequence'; Mutate = { param($m) $m.chunks[1].sequence = 1 } },
        @{ Name = 'missing-sequence'; Mutate = { param($m) $m.chunks[1].sequence = 3 } },
        @{ Name = 'duplicate-filename'; Mutate = { param($m) $m.chunks[1].filename = $m.chunks[0].filename } },
        @{ Name = 'expected-count'; Mutate = { param($m) $m.expectedChunkCount = 3 } },
        @{ Name = 'event-mismatch'; Mutate = { param($m) $m.chunks[1].event = 'alloc' } },
        @{ Name = 'strategy-mismatch'; Mutate = { param($m) $m.chunks[1].strategy = 'jdbc' } },
        @{ Name = 'counter-kind-mismatch'; Mutate = { param($m) $m.chunks[1].counterKind = 'allocationBytes' } },
        @{ Name = 'workload-invalid'; Mutate = { param($m) $m.chunks[1].workloadValid = $false } },
        @{ Name = 'rows-mismatch'; Mutate = { param($m) $m.totalRows = 1 } },
        @{ Name = 'sha-malformed'; Mutate = { param($m) $m.chunks[1].sourceArtifactSha256 = 'bad' } },
        @{ Name = 'malformed-line'; Mutate = { param($m) $m.chunks[1].collapsedContent = "no-counter`n" } },
        @{ Name = 'zero-counter'; Mutate = { param($m) $m.chunks[1].collapsedContent = "java.lang.Thread.run 0`n" } },
        @{ Name = 'cpu-allocation-mix'; Mutate = { param($m) $m.counterKind = 'allocationBytes' } }
    )
    foreach ($case in $invalidAggregationCases) {
        $bad = Copy-JsonObject -Value $aggregateManifest
        & $case.Mutate $bad
        Assert-AggregationInvalid -Manifest $bad -Name $case.Name
    }

    $allocManifest = Copy-JsonObject -Value $aggregateManifest
    $allocManifest.profileId = 'alloc-jpa'
    $allocManifest.event = 'alloc'
    $allocManifest.cpuEngine = $null
    $allocManifest.strategy = 'jpa'
    $allocManifest.interval = '512k'
    $allocManifest.counterKind = 'allocationBytes'
    $allocManifest.chunks[0].event = 'alloc'
    $allocManifest.chunks[0].strategy = 'jpa'
    $allocManifest.chunks[0].counterKind = 'allocationBytes'
    $allocManifest.chunks[0].collapsedContent = "com.example.persistencebenchmark.persistence.jpa.JpaBenchmarkRecordPersistenceService.saveAll 100`n"
    $allocManifest.chunks[1].event = 'alloc'
    $allocManifest.chunks[1].strategy = 'jpa'
    $allocManifest.chunks[1].counterKind = 'allocationBytes'
    $allocManifest.chunks[1].collapsedContent = "com.example.persistencebenchmark.persistence.jpa.JpaBenchmarkRecordPersistenceService.saveAll 300`n"
    $allocPath = Join-Path $tempRoot 'alloc-manifest.json'
    $allocActual = Join-Path $tempRoot 'alloc-aggregate.json'
    Write-JsonFile -Path $allocPath -Value $allocManifest
    Invoke-JqToFile -Arguments @('-f', $AggregateFilter, $allocPath) -DestinationPath $allocActual
    $allocSummary = Get-Content -LiteralPath $allocActual -Encoding UTF8 -Raw | ConvertFrom-Json
    Assert-True ($allocSummary.normalizedSampledValuePer50000Rows -eq 200) 'allocation normalization mismatch'

    Assert-ProfileSummaryValid -Path (Join-Path $ProfilerFixturesDir 'valid-summary.json')
    Assert-ProfileSummaryInvalid -Path (Join-Path $ProfilerFixturesDir 'invalid-engine-summary.json')
    $validSummary = Get-Content -LiteralPath (Join-Path $ProfilerFixturesDir 'valid-summary.json') -Encoding UTF8 -Raw | ConvertFrom-Json
    foreach ($case in @(
        @{ Name = 'root-hostname'; Mutate = { param($s) $s | Add-Member -NotePropertyName hostname -NotePropertyValue 'host01' } },
        @{ Name = 'profile-pid'; Mutate = { param($s) $s.profiles[0] | Add-Member -NotePropertyName pid -NotePropertyValue 1234 } },
        @{ Name = 'workload-command'; Mutate = { param($s) $s.profiles[0].workloadGate | Add-Member -NotePropertyName commandLine -NotePropertyValue 'java -jar app.jar' } },
        @{ Name = 'artifact-absolute'; Mutate = { param($s) $s.profiles[0].artifactManifest[0].fileName = 'C:\Users\name\profile.jfr' } },
        @{ Name = 'nested-unknown'; Mutate = { param($s) $s.profiles[0].topPackages[0] | Add-Member -NotePropertyName extra -NotePropertyValue 'x' } },
        @{ Name = 'windows-path'; Mutate = { param($s) $s.phase = 'C:\Users\name\file.txt' } },
        @{ Name = 'unix-path'; Mutate = { param($s) $s.phase = '/home/user/file.txt' } },
        @{ Name = 'required-missing'; Mutate = { param($s) $s.PSObject.Properties.Remove('phase') } }
    )) {
        $badSummary = Copy-JsonObject -Value $validSummary
        & $case.Mutate $badSummary
        $path = Join-Path $tempRoot "$($case.Name)-summary.json"
        Write-JsonFile -Path $path -Value $badSummary
        Assert-ProfileSummaryInvalid -Path $path
    }

    $OfficialManifestFile = $OfficialManifestFileOriginal
    Assert-OfficialResultManifest
    $badManifest = Get-Content -LiteralPath $OfficialManifestFileOriginal -Encoding UTF8 -Raw | ConvertFrom-Json
    $badManifest.files[0].sha256 = ('0' * 64)
    $badManifestPath = Join-Path $tempRoot 'bad-official-sha.json'
    Write-JsonFile -Path $badManifestPath -Value $badManifest
    $OfficialManifestFile = $badManifestPath
    Assert-Fails { Assert-OfficialResultManifest } 'bad official SHA should fail'
    $badManifest = Get-Content -LiteralPath $OfficialManifestFileOriginal -Encoding UTF8 -Raw | ConvertFrom-Json
    $badManifest.files[0].path = 'results/exp-001/20260727T053643Z-2d76b26/missing.json'
    $badManifestPath = Join-Path $tempRoot 'missing-official-file.json'
    Write-JsonFile -Path $badManifestPath -Value $badManifest
    $OfficialManifestFile = $badManifestPath
    Assert-Fails { Assert-OfficialResultManifest } 'missing official file should fail'
    $OfficialManifestFile = $OfficialManifestFileOriginal

    $bash = 'C:\Program Files\Git\usr\bin\bash.exe'
    if (Test-Path -LiteralPath $bash) {
        $uid = (& $bash -lc 'id -u').Trim()
        $fakeProc = Join-Path $tempRoot 'proc'
        New-FakeProc -Root $fakeProc -PidValue '123' -Uid $uid
        $jcmd = Join-Path $tempRoot 'jcmd.txt'
        Write-Utf8File -Path $jcmd -Text "123 /app/app.jar`n"
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-find-pid') -ProcRoot $fakeProc -JcmdListFile $jcmd) -eq 0) 'exact target JVM should pass'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-verify-identity', '123', '987654') -ProcRoot $fakeProc -JcmdListFile $jcmd) -eq 0) 'exact JVM identity should pass'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-verify-identity', '123', '1') -ProcRoot $fakeProc -JcmdListFile $jcmd) -ne 0) 'stale start identity should fail'
        Write-Utf8File -Path $jcmd -Text ''
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-find-pid') -ProcRoot $fakeProc -JcmdListFile $jcmd) -ne 0) 'zero candidate should fail'
        Write-Utf8File -Path $jcmd -Text "123 /app/app.jar`n124 /app/app.jar`n"
        New-FakeProc -Root $fakeProc -PidValue '124' -Uid $uid
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-find-pid') -ProcRoot $fakeProc -JcmdListFile $jcmd) -ne 0) 'multiple candidates should fail'
        $wrongProc = Join-Path $tempRoot 'wrong-proc'
        New-FakeProc -Root $wrongProc -PidValue '123' -Uid $uid -Jar '/app/wrong.jar'
        Write-Utf8File -Path $jcmd -Text "123 /app/wrong.jar`n"
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-find-pid') -ProcRoot $wrongProc -JcmdListFile $jcmd) -ne 0) 'wrong jar should fail'
        $wrongProfileProc = Join-Path $tempRoot 'wrong-profile-proc'
        New-FakeProc -Root $wrongProfileProc -PidValue '123' -Uid $uid -Profile 'dev'
        Write-Utf8File -Path $jcmd -Text "123 /app/app.jar`n"
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-find-pid') -ProcRoot $wrongProfileProc -JcmdListFile $jcmd) -ne 0) 'wrong Spring profile should fail'
        $wrongUidProc = Join-Path $tempRoot 'wrong-uid-proc'
        New-FakeProc -Root $wrongUidProc -PidValue '123' -Uid '999999'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-find-pid') -ProcRoot $wrongUidProc -JcmdListFile $jcmd) -ne 0) 'wrong UID should fail'

        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-validate-inputs', 'cpu-jpa', 'cpu', 'cpu', 'jpa', '10ms', '1', '50000')) -eq 0) 'valid input gate should pass'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-validate-inputs', 'cpu-jpa', 'wall', 'cpu', 'jpa', '10ms', '1', '50000')) -ne 0) 'unknown event should fail'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-validate-inputs', 'cpu-jpa', 'cpu', 'cpu', 'orm', '10ms', '1', '50000')) -ne 0) 'unknown strategy should fail'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-validate-inputs', 'cpu-jpa', 'cpu', 'wall', 'jpa', '10ms', '1', '50000')) -ne 0) 'unknown engine should fail'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-validate-inputs', 'cpu-jpa', 'cpu', 'cpu', 'jpa', '11ms', '1', '50000')) -ne 0) 'bad interval should fail'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-validate-inputs', 'cpu-jpa', 'cpu', 'cpu', 'jpa', '10ms', '0', '50000')) -ne 0) 'invalid repetition should fail'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-validate-inputs', 'cpu-jpa', 'cpu', 'cpu', 'jpa', '10ms', '1', '49999')) -ne 0) 'count mismatch should fail'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-validate-output', '/tmp/escape.response.raw')) -ne 0) 'output traversal should fail'

        $readyResponse = Join-Path $tempRoot 'smoke-ready-response.json'
        $cpuResponse = Join-Path $tempRoot 'smoke-cpu-response.json'
        $allocationResponse = Join-Path $tempRoot 'smoke-allocation-response.json'
        Write-Utf8File -Path $readyResponse -Text '{"status":"READY","phase":"EXP001_SMOKE"}'
        Write-Utf8File -Path $cpuResponse -Text '{"success":true,"workload":"cpu","iterations":1000,"durationMillis":2500,"checksum":"0123456789abcdef"}'
        Write-Utf8File -Path $allocationResponse -Text '{"success":true,"workload":"allocation","allocatedBytes":67108864,"chunkBytes":1048576,"chunks":64,"checksum":"fedcba9876543210"}'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-assert-ready-response', (Convert-ToGitBashPath -Path $readyResponse))) -eq 0) 'smoke ready response parser should pass'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-assert-cpu-response', (Convert-ToGitBashPath -Path $cpuResponse))) -eq 0) 'CPU smoke response parser should pass'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-assert-allocation-response', (Convert-ToGitBashPath -Path $allocationResponse))) -eq 0) 'allocation smoke response parser should pass'
        foreach ($case in @(
            @{ Name = 'ready-status-missing'; Text = '{"phase":"EXP001_SMOKE"}' },
            @{ Name = 'ready-status-wrong'; Text = '{"status":"STARTING","phase":"EXP001_SMOKE"}' },
            @{ Name = 'ready-phase-missing'; Text = '{"status":"READY"}' },
            @{ Name = 'ready-phase-wrong'; Text = '{"status":"READY","phase":"POSTGRESQL_READY"}' },
            @{ Name = 'ready-unknown-field'; Text = '{"status":"READY","phase":"EXP001_SMOKE","extra":"x"}' },
            @{ Name = 'ready-malformed'; Text = '{"status":"READY","phase":' }
        )) {
            $badReady = Join-Path $tempRoot "$($case.Name).json"
            Write-Utf8File -Path $badReady -Text $case.Text
            Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-assert-ready-response', (Convert-ToGitBashPath -Path $badReady))) -ne 0) "smoke ready response parser should fail: $($case.Name)"
        }
        $badCpuResponse = Join-Path $tempRoot 'smoke-cpu-response-low-duration.json'
        Write-Utf8File -Path $badCpuResponse -Text '{"success":true,"workload":"cpu","iterations":1000,"durationMillis":2499,"checksum":"0123456789abcdef"}'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-assert-cpu-response', (Convert-ToGitBashPath -Path $badCpuResponse))) -ne 0) 'low CPU smoke duration should fail'

        $counterGood = Join-Path $tempRoot 'counter-good.collapsed'
        $counterZero = Join-Path $tempRoot 'counter-zero.collapsed'
        $counterMalformed = Join-Path $tempRoot 'counter-malformed.collapsed'
        $counterOverflow = Join-Path $tempRoot 'counter-overflow.collapsed'
        Write-Utf8File -Path $counterGood -Text "a;b 1`nc 2`n"
        Write-Utf8File -Path $counterZero -Text "a;b 0`n"
        Write-Utf8File -Path $counterMalformed -Text "a;b nope`n"
        Write-Utf8File -Path $counterOverflow -Text "a;b 9007199254740992`n"
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-collapsed-total', (Convert-ToGitBashPath -Path $counterGood))) -eq 0) 'collapsed counter parser should pass'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-collapsed-total', (Convert-ToGitBashPath -Path $counterZero))) -ne 0) 'zero collapsed counter should fail'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-collapsed-total', (Convert-ToGitBashPath -Path $counterMalformed))) -ne 0) 'malformed collapsed counter should fail'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-collapsed-total', (Convert-ToGitBashPath -Path $counterOverflow))) -ne 0) 'overflow collapsed counter should fail'

        $engineGood = Join-Path $tempRoot 'engine-good.json'
        $engineCtimer = Join-Path $tempRoot 'engine-ctimer.json'
        $engineConflicting = Join-Path $tempRoot 'engine-conflicting.json'
        $engineNoActiveSetting = Join-Path $tempRoot 'engine-no-active-setting.json'
        $engineMissing = Join-Path $tempRoot 'engine-missing.json'
        $engineUnknown = Join-Path $tempRoot 'engine-unknown.json'
        $engineUnrelated = Join-Path $tempRoot 'engine-unrelated.json'
        $engineStackOnly = Join-Path $tempRoot 'engine-stack-only.json'
        $engineMalformed = Join-Path $tempRoot 'engine-malformed.json'
        Write-Utf8File -Path $engineGood -Text '{"recording":{"events":[{"type":"jdk.ActiveSetting","values":{"name":"engine","value":"perf_events"}}]}}'
        Write-Utf8File -Path $engineCtimer -Text '{"recording":{"events":[{"type":"jdk.ActiveSetting","values":{"name":"engine","value":"ctimer"}}]}}'
        Write-Utf8File -Path $engineConflicting -Text '{"recording":{"events":[{"type":"jdk.ActiveSetting","values":{"name":"engine","value":"perf_events"}},{"type":"jdk.ActiveSetting","values":{"name":"engine","value":"ctimer"}}]}}'
        Write-Utf8File -Path $engineNoActiveSetting -Text '{"recording":{"events":[{"type":"jdk.CPULoad","values":{"name":"engine","value":"perf_events"}}]}}'
        Write-Utf8File -Path $engineMissing -Text '{"recording":{"events":[{"type":"jdk.ActiveSetting","values":{"name":"period","value":"10 ms"}}]}}'
        Write-Utf8File -Path $engineUnknown -Text '{"recording":{"events":[{"type":"jdk.ActiveSetting","values":{"name":"engine","value":"itimer"}}]}}'
        Write-Utf8File -Path $engineUnrelated -Text '{"recording":{"events":[{"type":"com.example.StackFrame","values":{"method":"com.example.ctimer.Engine","engine":"ctimer"}},{"type":"jdk.ActiveSetting","values":{"name":"engine","value":"perf_events"}}]}}'
        Write-Utf8File -Path $engineStackOnly -Text '{"recording":{"events":[{"type":"com.example.StackFrame","values":{"method":"com.example.ctimer.Engine","engine":"ctimer"}}]}}'
        Write-Utf8File -Path $engineMalformed -Text '{"recording":{"events":[{"type":"jdk.ActiveSetting","values":{"name":"engine","value":"perf_events"}}]'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-parse-engine', (Convert-ToGitBashPath -Path $engineGood))) -eq 0) 'perf_events parser should pass'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-parse-engine', (Convert-ToGitBashPath -Path $engineCtimer))) -eq 0) 'ctimer parser should pass'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-parse-engine', (Convert-ToGitBashPath -Path $engineUnrelated))) -eq 0) 'unrelated engine field should be ignored'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-parse-engine', (Convert-ToGitBashPath -Path $engineConflicting))) -ne 0) 'conflicting engine parser should fail'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-parse-engine', (Convert-ToGitBashPath -Path $engineNoActiveSetting))) -ne 0) 'missing ActiveSetting parser should fail'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-parse-engine', (Convert-ToGitBashPath -Path $engineMissing))) -ne 0) 'missing engine parser should fail'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-parse-engine', (Convert-ToGitBashPath -Path $engineUnknown))) -ne 0) 'unknown engine parser should fail'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-parse-engine', (Convert-ToGitBashPath -Path $engineStackOnly))) -ne 0) 'stack string engine parser should fail'
        Assert-True ((Invoke-ContainerFixture -Arguments @('fixture-parse-engine', (Convert-ToGitBashPath -Path $engineMalformed))) -ne 0) 'malformed engine parser should fail'
    }

    foreach ($path in @(
        'scripts/exp-001/tests/profiler/fixtures/valid-summary.json',
        'scripts/exp-001/tests/profiler/fixtures/sample.collapsed',
        'scripts/exp-001/tests/profiler/expected/sample-aggregate.json',
        'scripts/exp-001/tests/profiler/expected/metadata-snippet.md'
    )) {
        Assert-GitAttr -Path $path -Attribute 'text' -ExpectedValue 'set'
        Assert-GitAttr -Path $path -Attribute 'eol' -ExpectedValue 'lf'
    }

    Assert-GitAttr -Path 'results/exp-001/20260727T053643Z-2d76b26/summary.md' -Attribute 'text' -ExpectedValue 'unset'
    Assert-GitAttr -Path 'results/exp-001/20260727T053643Z-2d76b26/summary.md' -Attribute 'whitespace' -ExpectedValue 'cr-at-eol'
    Assert-GitIgnored -Path 'artifacts/exp-001/profiling/demo/raw/cpu.jfr'
    Assert-GitIgnored -Path 'results/exp-001/profiling/demo/cpu.jfr'
    Assert-GitNotIgnored -Path 'results/exp-001/profiling/demo/summary.json'
    Assert-GitNotIgnored -Path 'results/exp-001/profiling/demo/metadata.md'
    Assert-GitNotIgnored -Path 'results/exp-001/profiling/demo/analysis.md'
    Assert-GitNotIgnored -Path 'results/exp-001/profiling/demo/manifest.md'
} finally {
    $env:EXP001_PROFILE_IMPORT_ONLY = $null
    $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
    $allowedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolvedTempRoot.StartsWith($allowedTempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'EXP-001 profiler fixture tests passed.'
