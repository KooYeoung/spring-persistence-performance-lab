param(
    [string] $Action = 'help',
    [int] $SecurityLevel = 0,
    [string] $ProfileRunId = '',
    [switch] $AllowDownload,
    [switch] $AllowActualProfile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ProfilerWindowsDir = $PSScriptRoot
$ProfilerRoot = Split-Path -Parent $ProfilerWindowsDir
$Exp001Root = Split-Path -Parent $ProfilerRoot
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $Exp001Root)
$StateDir = Join-Path $ProfilerRoot '.state'
$SmokeStateFile = Join-Path $StateDir 'smoke-ready.json'
$LockFile = Join-Path $Exp001Root 'tools\async-profiler.lock'
$ConfigFile = Join-Path $ProfilerRoot 'shared\profile-config.json'
$OfficialManifestFile = Join-Path $ProfilerRoot 'shared\official-result-manifest.json'
$ValidateSummaryFilter = Join-Path $ProfilerRoot 'shared\validate-profile-summary.jq'
$AggregateFilter = Join-Path $ProfilerRoot 'shared\aggregate-collapsed.jq'
$DockerDir = Join-Path $ProfilerRoot 'docker'
$ComposeBase = Join-Path $DockerDir 'compose.yml'
$ComposeSeccomp = Join-Path $DockerDir 'compose.seccomp.yml'
$ComposeSysAdmin = Join-Path $DockerDir 'compose.sys-admin.yml'
$ComposeProject = 'exp001-profiler'
$RawRoot = Join-Path $ProjectRoot 'artifacts\exp-001\profiling'
$TrackedRoot = Join-Path $ProjectRoot 'results\exp-001\profiling'
$ExpectedRuntime = 'docker-linux-x64'
$ExpectedArchitecture = 'linux-x64'
$ExpectedJdkVersion = 'amazoncorretto:21.0.11-al2023'
$EngineVerificationPerfEvents = 'jfr-active-setting-engine:perf_events'
$EngineVerificationCtimer = 'jfr-active-setting-engine:ctimer'
$AsyncProfilerLockKeys = @(
    'version',
    'tag',
    'platform',
    'asset',
    'url',
    'sha256',
    'size',
    'archive_root',
    'install_dir',
    'asprof',
    'jfrconv',
    'library',
    'license'
)

. (Join-Path $Exp001Root 'windows\Common.ps1')

function Write-ProfileLog {
    param([string] $Message)
    $timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Host "[$timestamp] $Message"
}

function Stop-Profile {
    param([string] $Message)
    $timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    if ($env:EXP001_PROFILE_IMPORT_ONLY -eq '1') {
        throw $Message
    }
    [Console]::Error.WriteLine("[$timestamp] ERROR: $Message")
    exit 1
}

function Show-Help {
    Write-Host 'EXP-001 async-profiler Windows harness'
    Write-Host ''
    Write-Host '사용법:'
    Write-Host '  powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\exp-001\profiler\windows\exp001-profile.ps1 <action>'
    Write-Host ''
    Write-Host 'Actions:'
    Write-Host '  verify       lock/config/Docker policy/official result guard를 검증한다.'
    Write-Host '  prepare-tool mounted Linux async-profiler tool을 lock 기준으로 준비한다. 다운로드는 -AllowDownload 필요.'
    Write-Host '  smoke        Docker app JVM에 tiny cpu/ctimer/alloc attach smoke를 수행한다. 50,000-row endpoint는 호출하지 않는다.'
    Write-Host '  profile      smoke 통과 후 실제 Phase B profile을 수행한다. -AllowActualProfile 필요.'
    Write-Host '  validate     results/exp-001/profiling/<profile-run-id>/summary.json을 schema gate로 검증한다.'
    Write-Host '  help         도움말을 출력한다.'
    Write-Host ''
    Write-Host 'SecurityLevel: 0 기본 seccomp, 1 seccomp=unconfined, 2 seccomp=unconfined + SYS_ADMIN'
}

function Read-KeyValueLegacy {
    param([string] $Path)

    $values = @{}
    foreach ($rawLine in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $line = $rawLine.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) {
            continue
        }
        $separator = $line.IndexOf('=')
        if ($separator -lt 1) {
            Stop-Profile "KEY=VALUE 형식이 아닌 line입니다: $Path"
        }
        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            Stop-Profile "허용되지 않는 key 형식입니다: $key"
        }
        $values[$key] = $value
    }
    return $values
}

function Read-AsyncProfilerLockLegacy {
    $lock = Read-KeyValue -Path $LockFile
    foreach ($key in @(
        'version',
        'tag',
        'platform',
        'asset',
        'url',
        'sha256',
        'size',
        'archive_root',
        'install_dir',
        'asprof',
        'jfrconv',
        'library',
        'license'
    )) {
        if (-not $lock.ContainsKey($key)) {
            Stop-Profile "async-profiler lock에 필요한 key가 없습니다: $key"
        }
    }

    if ($lock['version'] -ne '4.5' -or $lock['tag'] -ne 'v4.5' -or $lock['platform'] -ne 'linux-x64') {
        Stop-Profile 'async-profiler lock이 EXP-001 Phase B pin과 일치하지 않습니다.'
    }
    if ($lock['sha256'] -notmatch '^[0-9a-f]{64}$') {
        Stop-Profile "async-profiler SHA-256 형식이 유효하지 않습니다: $($lock['sha256'])"
    }
    if ([int64] $lock['size'] -ne 447164) {
        Stop-Profile "async-profiler asset size가 pin과 다릅니다: $($lock['size'])"
    }

    return $lock
}

function Read-KeyValue {
    param(
        [string] $Path,
        [string[]] $AllowedKeys = @()
    )

    $allowed = @{}
    foreach ($allowedKey in $AllowedKeys) {
        $allowed[$allowedKey] = $true
    }

    $values = @{}
    $lineNumber = 0
    foreach ($rawLine in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $lineNumber++
        $line = $rawLine.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) {
            continue
        }
        $separator = $line.IndexOf('=')
        if ($separator -lt 1 -or $separator -ne $line.LastIndexOf('=')) {
            Stop-Profile "Invalid KEY=VALUE line in $Path at line $lineNumber"
        }
        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if ([string]::IsNullOrWhiteSpace($key)) {
            Stop-Profile "Empty lock key in $Path at line $lineNumber"
        }
        if ([string]::IsNullOrWhiteSpace($value)) {
            Stop-Profile "Empty lock value for key '$key' in $Path at line $lineNumber"
        }
        if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            Stop-Profile "Invalid lock key format: $key"
        }
        if ($AllowedKeys.Count -gt 0 -and -not $allowed.ContainsKey($key)) {
            Stop-Profile "Unknown lock key: $key"
        }
        if ($values.ContainsKey($key)) {
            Stop-Profile "Duplicate lock key: $key"
        }
        $values[$key] = $value
    }
    return $values
}

function Read-AsyncProfilerLock {
    param([string] $Path = $LockFile)

    $lock = Read-KeyValue -Path $Path -AllowedKeys $AsyncProfilerLockKeys
    foreach ($key in $AsyncProfilerLockKeys) {
        if (-not $lock.ContainsKey($key)) {
            Stop-Profile "Missing async-profiler lock key: $key"
        }
    }

    $expectedAsset = "async-profiler-$($lock['version'])-linux-x64.tar.gz"
    $expectedRoot = "async-profiler-$($lock['version'])-linux-x64"
    $expectedUrl = "https://github.com/async-profiler/async-profiler/releases/download/$($lock['tag'])/$expectedAsset"
    $expectedInstallDir = "scripts/exp-001/.tools/async-profiler/linux-x64/$($lock['version'])/$expectedRoot"

    if ($lock['version'] -ne '4.5') {
        Stop-Profile "Invalid async-profiler version: $($lock['version'])"
    }
    if ($lock['tag'] -ne "v$($lock['version'])") {
        Stop-Profile "Invalid async-profiler tag: $($lock['tag'])"
    }
    if ($lock['platform'] -ne 'linux-x64') {
        Stop-Profile "Invalid async-profiler platform: $($lock['platform'])"
    }
    if ($lock['asset'] -ne $expectedAsset) {
        Stop-Profile "Invalid async-profiler asset: $($lock['asset'])"
    }
    if ($lock['url'] -ne $expectedUrl -or $lock['url'] -notmatch '^https://') {
        Stop-Profile "Invalid async-profiler URL: $($lock['url'])"
    }
    if ($lock['sha256'] -notmatch '^[0-9a-f]{64}$') {
        Stop-Profile "Invalid async-profiler SHA-256: $($lock['sha256'])"
    }
    if ($lock['sha256'] -ne '89546fbb9ee0fc5496c7edd4099b0709489bc78b0d8057ccbb4b801f6b032b62') {
        Stop-Profile "async-profiler SHA-256 does not match the EXP-001 pin: $($lock['sha256'])"
    }
    $size = 0L
    if (-not [int64]::TryParse($lock['size'], [ref] $size) -or $size -le 0 -or $size -ne 447164) {
        Stop-Profile "Invalid async-profiler asset size: $($lock['size'])"
    }
    if ($lock['archive_root'] -ne $expectedRoot) {
        Stop-Profile "Invalid async-profiler archive root: $($lock['archive_root'])"
    }
    if ($lock['install_dir'] -ne $expectedInstallDir) {
        Stop-Profile "Invalid async-profiler install_dir: $($lock['install_dir'])"
    }
    if ($lock['asprof'] -ne 'bin/asprof' -or $lock['jfrconv'] -ne 'bin/jfrconv' -or $lock['library'] -ne 'lib/libasyncProfiler.so') {
        Stop-Profile 'Invalid async-profiler tool relative paths.'
    }
    if ($lock['license'] -ne 'Apache-2.0') {
        Stop-Profile "Invalid async-profiler license: $($lock['license'])"
    }

    return $lock
}

function Get-AsyncProfilerInstallDir {
    param([hashtable] $Lock)
    return Join-Path $ProjectRoot (($Lock['install_dir']).Replace('/', '\'))
}

function Assert-AsyncProfilerInstalled {
    $lock = Read-AsyncProfilerLock
    $installDir = Get-AsyncProfilerInstallDir -Lock $lock
    foreach ($relative in @($lock['asprof'], $lock['jfrconv'], $lock['library'])) {
        $path = Join-Path $installDir ($relative.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $path)) {
            Stop-Profile "async-profiler tool이 준비되지 않았습니다: $path"
        }
        if ((Get-Item -LiteralPath $path).Length -le 0) {
            Stop-Profile "async-profiler tool 파일이 비어 있습니다: $path"
        }
    }
    return $installDir
}

function Assert-ArchiveMemberSafe {
    param(
        [string] $Member,
        [string] $ExpectedRoot
    )

    if ([string]::IsNullOrWhiteSpace($Member)) {
        Stop-Profile 'Archive contains an empty member.'
    }
    if ($Member -match '[\x00-\x1f]') {
        Stop-Profile "Archive member contains a control character: $Member"
    }
    if ($Member.StartsWith('/') -or $Member.StartsWith('\')) {
        Stop-Profile "Archive member is absolute: $Member"
    }
    if ($Member -match '^[A-Za-z]:[\\/]') {
        Stop-Profile "Archive member is drive-qualified: $Member"
    }
    if ($Member -match '^\\\\') {
        Stop-Profile "Archive member is UNC-qualified: $Member"
    }

    $parts = @($Member -split '[\\/]' | Where-Object { $_.Length -gt 0 })
    if ($parts.Count -eq 0) {
        Stop-Profile 'Archive member has no path segment.'
    }
    if ($parts[0] -ne $ExpectedRoot) {
        Stop-Profile "Archive member has unexpected top-level root: $Member"
    }
    foreach ($part in $parts) {
        if ($part -eq '..') {
            Stop-Profile "Archive member escapes the expected root: $Member"
        }
    }
}

function Assert-ArchiveMembersSafe {
    param(
        [string] $ArchivePath,
        [string] $ExpectedRoot
    )

    $members = & tar -tzf $ArchivePath
    if ($LASTEXITCODE -ne 0) {
        Stop-Profile 'async-profiler archive listing failed.'
    }
    $memberList = @($members | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($memberList.Count -eq 0) {
        Stop-Profile 'async-profiler archive is empty.'
    }
    foreach ($member in $memberList) {
        Assert-ArchiveMemberSafe -Member $member -ExpectedRoot $ExpectedRoot
    }
}

function Assert-ExtractedTreeSafe {
    param(
        [string] $ExtractDir,
        [string] $ExpectedRoot
    )

    $extractRoot = (Get-Item -LiteralPath $ExtractDir).FullName
    $expectedRootItem = Get-Item -LiteralPath $ExpectedRoot
    if (($expectedRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-Profile "Archive root is a reparse point: $ExpectedRoot"
    }

    $topEntries = @(Get-ChildItem -LiteralPath $ExtractDir -Force)
    if ($topEntries.Count -ne 1 -or $topEntries[0].Name -ne (Split-Path -Leaf $ExpectedRoot)) {
        Stop-Profile 'Archive extraction produced unexpected top-level entries.'
    }

    foreach ($entry in Get-ChildItem -LiteralPath $ExtractDir -Recurse -Force) {
        if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-Profile "Archive contains a reparse point: $($entry.Name)"
        }
        $full = $entry.FullName
        if (-not $full.StartsWith($extractRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            Stop-Profile "Archive extraction escaped the temporary directory: $($entry.Name)"
        }
    }
}

function Install-AsyncProfilerTool {
    $lock = Read-AsyncProfilerLock
    $installDir = Get-AsyncProfilerInstallDir -Lock $lock
    if (Test-Path -LiteralPath $installDir) {
        Assert-AsyncProfilerInstalled | Out-Null
        Write-ProfileLog "기존 async-profiler tool을 확인했습니다: $installDir"
        return
    }
    if (-not $AllowDownload) {
        Stop-Profile 'tool download는 이 action에서 명시적으로 -AllowDownload를 전달한 경우에만 허용됩니다.'
    }

    $runtimeRoot = Split-Path -Parent $installDir
    $archive = Join-Path $runtimeRoot "$($lock['asset']).tmp.$PID"
    $extractDir = Join-Path $runtimeRoot "extract-$PID"
    $expectedRoot = Join-Path $extractDir $lock['archive_root']
    New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-ProfileLog "async-profiler $($lock['version']) linux-x64 asset을 다운로드합니다."
        Invoke-WebRequest -Uri $lock['url'] -OutFile $archive -UseBasicParsing -ErrorAction Stop
        $actualSize = (Get-Item -LiteralPath $archive).Length
        if ($actualSize -ne [int64] $lock['size']) {
            Stop-Profile "downloaded async-profiler size가 일치하지 않습니다. expected=$($lock['size']) actual=$actualSize"
        }
        $actualSha = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualSha -ne $lock['sha256']) {
            Stop-Profile "downloaded async-profiler checksum이 일치하지 않습니다. expected=$($lock['sha256']) actual=$actualSha"
        }

        Assert-ArchiveMembersSafe -ArchivePath $archive -ExpectedRoot $lock['archive_root']
        New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
        & tar -xzf $archive -C $extractDir
        if ($LASTEXITCODE -ne 0) {
            Stop-Profile 'async-profiler archive 압축 해제에 실패했습니다.'
        }
        if (-not (Test-Path -LiteralPath $expectedRoot)) {
            Stop-Profile "archive root가 lock과 일치하지 않습니다: $expectedRoot"
        }
        Assert-ExtractedTreeSafe -ExtractDir $extractDir -ExpectedRoot $expectedRoot
        if (Test-Path -LiteralPath $installDir) {
            Stop-Profile "async-profiler final directory가 이미 존재합니다: $installDir"
        }
        Move-Item -LiteralPath $expectedRoot -Destination $installDir
    } catch {
        Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Assert-AsyncProfilerInstalled | Out-Null
    Write-ProfileLog "async-profiler tool 준비 완료: $installDir"
}

function Read-ProfileConfig {
    return Get-Content -LiteralPath $ConfigFile -Encoding UTF8 -Raw | ConvertFrom-Json
}

function Assert-ProfileConfig {
    $config = Read-ProfileConfig
    if ($config.profileConfigVersion -ne 1 -or $config.experiment -ne 'EXP-001') {
        Stop-Profile 'profile-config.json header가 유효하지 않습니다.'
    }
    if ($config.rowsPerInvocation -ne 50000) {
        Stop-Profile "rowsPerInvocation은 50000이어야 합니다: $($config.rowsPerInvocation)"
    }
    if ($config.smoke.smokeProtocolVersion -ne 'exp001-smoke-v1') {
        Stop-Profile "Invalid smoke protocol version: $($config.smoke.smokeProtocolVersion)"
    }
    if ([int] $config.smoke.responseMaxBytes -ne 4096) {
        Stop-Profile "Invalid smoke response size limit: $($config.smoke.responseMaxBytes)"
    }
    if ($config.smoke.cpuWorkload.version -ne 'cpu-v1' -or [int] $config.smoke.cpuWorkload.successLowerBoundMillis -ne 2500) {
        Stop-Profile 'Invalid CPU smoke workload config.'
    }
    if ([int] $config.smoke.cpuWorkload.minimumSamples -ne 50 -or [int] $config.smoke.cpuWorkload.recommendedSamples -lt [int] $config.smoke.cpuWorkload.minimumSamples) {
        Stop-Profile 'Invalid CPU smoke sample thresholds.'
    }
    if ($config.smoke.allocationWorkload.version -ne 'allocation-v1' -or [int64] $config.smoke.allocationWorkload.allocatedBytes -ne 67108864) {
        Stop-Profile 'Invalid allocation smoke workload config.'
    }
    if ([int64] $config.smoke.allocationWorkload.minimumSampledBytes -ne 4194304 -or [int64] $config.smoke.allocationWorkload.recommendedSampledBytes -lt [int64] $config.smoke.allocationWorkload.minimumSampledBytes) {
        Stop-Profile 'Invalid allocation smoke byte thresholds.'
    }

    $profileIds = @($config.profileOrder)
    if ($profileIds.Count -ne 4) {
        Stop-Profile "profileOrder 수가 정확히 4개가 아닙니다: $($profileIds.Count)"
    }

    $allowedEvents = @('cpu', 'ctimer', 'alloc')
    foreach ($profile in @($config.profiles)) {
        if ($allowedEvents -notcontains [string] $profile.event) {
            Stop-Profile "허용되지 않는 event입니다: $($profile.event)"
        }
        if (@('jpa', 'jdbc') -notcontains [string] $profile.strategy) {
            Stop-Profile "허용되지 않는 strategy입니다: $($profile.strategy)"
        }
        if ([int] $profile.repetitions -le 0) {
            Stop-Profile "profile repetition은 positive integer여야 합니다: $($profile.id)"
        }
        if ([int] $profile.minimumSamples -le 0 -or [int] $profile.recommendedSamples -lt [int] $profile.minimumSamples) {
            Stop-Profile "sample threshold가 유효하지 않습니다: $($profile.id)"
        }
    }

    $level0 = @($config.runtime.dockerSecurityLevels | Where-Object { [int] $_.level -eq 0 })
    if ($level0.Count -ne 1 -or @($level0[0].capAdd).Count -ne 0 -or @($level0[0].securityOpt).Count -ne 0) {
        Stop-Profile 'Docker security Level 0은 추가 capability/security_opt 없이 시작해야 합니다.'
    }

    return $config
}

function Assert-DockerSecurityConfig {
    foreach ($path in @($ComposeBase, $ComposeSeccomp, $ComposeSysAdmin)) {
        if (-not (Test-Path -LiteralPath $path)) {
            Stop-Profile "Compose 파일이 없습니다: $path"
        }
        $text = Get-Content -LiteralPath $path -Encoding UTF8 -Raw
        if ($text -match '(?m)^\s*privileged\s*:\s*true\s*$') {
            Stop-Profile "privileged container는 금지합니다: $path"
        }
        if ($text -match '(?m)^\s*pid\s*:\s*host\s*$') {
            Stop-Profile "host PID namespace는 금지합니다: $path"
        }
        if ($text -match '/var/run/docker\.sock') {
            Stop-Profile "Docker socket mount는 금지합니다: $path"
        }
        if ($text -match 'SYS_PTRACE') {
            Stop-Profile "SYS_PTRACE는 기본 profiler harness capability가 아닙니다: $path"
        }
        if ($text -match '(?m)^\s*container_name\s*:') {
            Stop-Profile "Fixed container_name is forbidden: $path"
        }
    }

    $baseText = Get-Content -LiteralPath $ComposeBase -Encoding UTF8 -Raw
    if ($baseText -match 'SYS_ADMIN' -or $baseText -match 'seccomp=unconfined') {
        Stop-Profile 'Level 0 compose.yml에는 SYS_ADMIN 또는 seccomp=unconfined가 없어야 합니다.'
    }
    $sysAdminText = Get-Content -LiteralPath $ComposeSysAdmin -Encoding UTF8 -Raw
    if ($sysAdminText -notmatch 'SYS_ADMIN') {
        Stop-Profile 'Level 2 override에는 SYS_ADMIN이 있어야 합니다.'
    }
}

function Assert-OfficialResultGuard {
    $manifest = Get-Content -LiteralPath $OfficialManifestFile -Encoding UTF8 -Raw | ConvertFrom-Json
    $resultRoot = Join-Path $ProjectRoot (($manifest.officialResultPath).Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $resultRoot)) {
        Stop-Profile "official result directory가 없습니다: $($manifest.officialResultPath)"
    }
    $actualFiles = @(Get-ChildItem -LiteralPath $resultRoot -Recurse -File)
    if ($actualFiles.Count -ne [int] $manifest.expectedFileCount) {
        Stop-Profile "official result file count가 변경되었습니다: $($actualFiles.Count)"
    }
    foreach ($entry in @($manifest.files)) {
        $path = Join-Path $ProjectRoot (($entry.path).Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $path)) {
            Stop-Profile "official result file이 없습니다: $($entry.path)"
        }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne [string] $entry.sha256) {
            Stop-Profile "official result SHA가 변경되었습니다: $($entry.path)"
        }
    }

    $attrText = & git -C $ProjectRoot check-attr text whitespace -- 'results/exp-001/20260727T053643Z-2d76b26/summary.md'
    if ($LASTEXITCODE -ne 0 -or ($attrText -join "`n") -notmatch 'text: unset' -or ($attrText -join "`n") -notmatch 'whitespace: cr-at-eol') {
        Stop-Profile 'official result Git attribute가 보존되지 않았습니다.'
    }
}

function Assert-ProfilerHarness {
    Read-AsyncProfilerLock | Out-Null
    Assert-ProfileConfig | Out-Null
    Assert-DockerSecurityConfig
    Assert-OfficialResultGuard
    Write-ProfileLog 'profiler harness static guard를 통과했습니다.'
}

function Get-ComposeFiles {
    if ($SecurityLevel -eq 0) {
        return @($ComposeBase)
    }
    if ($SecurityLevel -eq 1) {
        return @($ComposeBase, $ComposeSeccomp)
    }
    if ($SecurityLevel -eq 2) {
        return @($ComposeBase, $ComposeSysAdmin)
    }
    Stop-Profile "지원하지 않는 SecurityLevel입니다: $SecurityLevel"
}

function Invoke-Compose {
    param([string[]] $Arguments)

    $composeArgs = @()
    foreach ($file in Get-ComposeFiles) {
        $composeArgs += @('-f', $file)
    }
    $composeArgs += @('-p', $ComposeProject)
    $composeArgs += $Arguments

    & docker compose @composeArgs
    if ($LASTEXITCODE -ne 0) {
        Stop-Profile "docker compose 실행에 실패했습니다: $($Arguments -join ' ')"
    }
}

function Invoke-ComposeCapture {
    param([string[]] $Arguments)

    $composeArgs = @()
    foreach ($file in Get-ComposeFiles) {
        $composeArgs += @('-f', $file)
    }
    $composeArgs += @('-p', $ComposeProject)
    $composeArgs += $Arguments

    $output = & docker compose @composeArgs
    if ($LASTEXITCODE -ne 0) {
        Stop-Profile "docker compose 실행에 실패했습니다: $($Arguments -join ' ')"
    }
    return $output
}

function Invoke-ComposeDownForCleanup {
    $composeArgs = @()
    foreach ($file in Get-ComposeFiles) {
        $composeArgs += @('-f', $file)
    }
    $composeArgs += @('-p', $ComposeProject, 'down', '-v', '--remove-orphans')

    & docker compose @composeArgs
    if ($LASTEXITCODE -ne 0) {
        throw 'docker compose down cleanup failed.'
    }
}

function Assert-ProfilerComposeResourcesCleaned {
    $filter = "label=com.docker.compose.project=$ComposeProject"
    $containers = @(& docker ps -a -q --filter $filter | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($LASTEXITCODE -ne 0) {
        throw 'docker container residual check failed.'
    }
    $networks = @(& docker network ls -q --filter $filter | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($LASTEXITCODE -ne 0) {
        throw 'docker network residual check failed.'
    }
    $volumes = @(& docker volume ls -q --filter $filter | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($LASTEXITCODE -ne 0) {
        throw 'docker volume residual check failed.'
    }
    if ($containers.Count -ne 0 -or $networks.Count -ne 0 -or $volumes.Count -ne 0) {
        throw "Residual Docker resources remain: containers=$($containers.Count) networks=$($networks.Count) volumes=$($volumes.Count)"
    }
}

function Assert-ProfilerCleanupPath {
    param(
        [string] $Path,
        [string] $Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $rootPrefix = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    if ($fullPath -ne $fullRoot -and -not $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "cleanup path escapes root: $Path"
    }
}

function Clear-ProfilerPartialArtifacts {
    if (Test-Path -LiteralPath $StateDir) {
        foreach ($file in @(Get-ChildItem -LiteralPath $StateDir -File -Filter 'smoke-ready.json.tmp.*' -ErrorAction SilentlyContinue)) {
            Assert-ProfilerCleanupPath -Path $file.FullName -Root $StateDir
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }
    if (Test-Path -LiteralPath $RawRoot) {
        foreach ($file in @(Get-ChildItem -LiteralPath $RawRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like '*.tmp.*' -or $_.Name -like '.tmp.*' -or $_.Name -like '*.partial'
        })) {
            Assert-ProfilerCleanupPath -Path $file.FullName -Root $RawRoot
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }
}

function Invoke-ProfilerCleanup {
    param([string] $FailureCode = 'SMOKE_CLEANUP_FAILED')

    $errors = New-Object System.Collections.Generic.List[string]
    try {
        Invoke-ComposeDownForCleanup
    } catch {
        $errors.Add($_.Exception.Message)
    }
    try {
        Assert-ProfilerComposeResourcesCleaned
    } catch {
        $errors.Add($_.Exception.Message)
    }
    try {
        Clear-ProfilerPartialArtifacts
    } catch {
        $errors.Add($_.Exception.Message)
    }
    if ($errors.Count -ne 0) {
        throw "$FailureCode`: $($errors -join '; ')"
    }
}

function Invoke-Cleanup {
    Invoke-ProfilerCleanup -FailureCode 'TOOL_CLEANUP_FAILED'
    Write-ProfileLog 'profiler cleanup completed.'
}

function Assert-DockerReady {
    Require-DockerCompose
    Assert-AsyncProfilerInstalled | Out-Null
}

function Get-SourceRevision {
    $revision = (& git -C $ProjectRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $revision -notmatch '^[0-9a-f]{40}$') {
        Stop-Profile 'Unable to resolve source revision.'
    }
    return $revision
}

function Get-HarnessRevision {
    $relativeFiles = @(
        'scripts/exp-001/tools/async-profiler.lock',
        'scripts/exp-001/profiler/shared/profile-config.json',
        'scripts/exp-001/profiler/shared/validate-profile-summary.jq',
        'scripts/exp-001/profiler/shared/aggregate-collapsed.jq',
        'scripts/exp-001/profiler/shared/official-result-manifest.json',
        'scripts/exp-001/profiler/docker/Dockerfile',
        'scripts/exp-001/profiler/docker/compose.yml',
        'scripts/exp-001/profiler/docker/compose.seccomp.yml',
        'scripts/exp-001/profiler/docker/compose.sys-admin.yml',
        'scripts/exp-001/profiler/windows/exp001-profile.ps1',
        'scripts/exp-001/profiler/container/exp001-profile.sh',
        'scripts/exp-001/tests/run-profiler-fixtures.ps1',
        'scripts/exp-001/tests/run-profiler-fixtures.sh'
    )
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($relative in $relativeFiles) {
        $path = Join-Path $ProjectRoot ($relative.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $path)) {
            Stop-Profile "Harness revision input is missing: $relative"
        }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines.Add("$relative $hash")
    }
    $payload = [Text.Encoding]::UTF8.GetBytes(($lines.ToArray() -join "`n"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($payload))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-SmokeContext {
    $lock = Read-AsyncProfilerLock
    $config = Read-ProfileConfig
    return [ordered] @{
        markerFormatVersion = 2
        sourceRevision = Get-SourceRevision
        harnessRevision = Get-HarnessRevision
        profilerVersion = [string] $lock['version']
        profilerAssetSha256 = [string] $lock['sha256']
        securityLevel = $SecurityLevel
        runtime = $ExpectedRuntime
        architecture = $ExpectedArchitecture
        jdkVersion = $ExpectedJdkVersion
        smokeProtocolVersion = [string] $config.smoke.smokeProtocolVersion
        cpuWorkloadVersion = [string] $config.smoke.cpuWorkload.version
        allocationWorkloadVersion = [string] $config.smoke.allocationWorkload.version
    }
}

function Assert-JsonExactKeys {
    param(
        [object] $Object,
        [string[]] $Keys,
        [string] $Name
    )

    $actual = @($Object.PSObject.Properties.Name | Sort-Object)
    $expected = @($Keys | Sort-Object)
    if ($actual.Count -ne $expected.Count) {
        Stop-Profile "$Name schema key count mismatch."
    }
    for ($i = 0; $i -lt $expected.Count; $i++) {
        if ($actual[$i] -ne $expected[$i]) {
            Stop-Profile "$Name schema key mismatch. expected=$($expected -join ',') actual=$($actual -join ',')"
        }
    }
}

function Read-SmokeResult {
    param([string] $SmokeResultPath)

    if (-not (Test-Path -LiteralPath $SmokeResultPath)) {
        Stop-Profile "Smoke result file is missing: $SmokeResultPath"
    }
    $result = Get-Content -LiteralPath $SmokeResultPath -Encoding UTF8 -Raw | ConvertFrom-Json
    Assert-JsonExactKeys -Object $result -Keys @(
        'markerFormatVersion',
        'smokeSuccess',
        'selectedCpuEngine',
        'smokeProtocolVersion',
        'cpuWorkloadVersion',
        'allocationWorkloadVersion',
        'cpuSampleCount',
        'allocationSampleCount',
        'allocationSampledBytes',
        'engineVerification'
    ) -Name 'container smoke result'
    if ([int] $result.markerFormatVersion -ne 2) {
        Stop-Profile "Container smoke result markerFormatVersion is invalid: $($result.markerFormatVersion)"
    }
    if ($result.smokeSuccess -ne $true) {
        Stop-Profile 'Container smoke result is not successful.'
    }
    if (@('cpu', 'ctimer') -notcontains [string] $result.selectedCpuEngine) {
        Stop-Profile "Invalid selected CPU engine in smoke result: $($result.selectedCpuEngine)"
    }
    $config = Read-ProfileConfig
    if ([string] $result.smokeProtocolVersion -ne [string] $config.smoke.smokeProtocolVersion) {
        Stop-Profile 'Container smoke protocol version mismatch.'
    }
    if ([string] $result.cpuWorkloadVersion -ne [string] $config.smoke.cpuWorkload.version) {
        Stop-Profile 'Container CPU smoke workload version mismatch.'
    }
    if ([string] $result.allocationWorkloadVersion -ne [string] $config.smoke.allocationWorkload.version) {
        Stop-Profile 'Container allocation smoke workload version mismatch.'
    }
    $cpuSampleCount = 0L
    $allocationSampleCount = 0L
    $allocationSampledBytes = 0L
    if (-not [int64]::TryParse([string] $result.cpuSampleCount, [ref] $cpuSampleCount) -or $cpuSampleCount -lt [int64] $config.smoke.cpuWorkload.minimumSamples) {
        Stop-Profile "Container CPU smoke sample count is below threshold: $($result.cpuSampleCount)"
    }
    if (-not [int64]::TryParse([string] $result.allocationSampleCount, [ref] $allocationSampleCount) -or $allocationSampleCount -lt [int64] $config.smoke.allocationWorkload.minimumSamples) {
        Stop-Profile "Container allocation smoke sample count is below threshold: $($result.allocationSampleCount)"
    }
    if (-not [int64]::TryParse([string] $result.allocationSampledBytes, [ref] $allocationSampledBytes) -or $allocationSampledBytes -lt [int64] $config.smoke.allocationWorkload.minimumSampledBytes) {
        Stop-Profile "Container allocation smoke sampled bytes are below threshold: $($result.allocationSampledBytes)"
    }
    if ([string] $result.selectedCpuEngine -eq 'cpu' -and [string] $result.engineVerification -ne $EngineVerificationPerfEvents) {
        Stop-Profile "selectedCpuEngine=cpu requires engineVerification=$EngineVerificationPerfEvents."
    }
    if ([string] $result.selectedCpuEngine -eq 'ctimer' -and [string] $result.engineVerification -ne $EngineVerificationCtimer) {
        Stop-Profile "selectedCpuEngine=ctimer requires engineVerification=$EngineVerificationCtimer."
    }
    return $result
}

function Write-SmokeMarker {
    param(
        [object] $Context,
        [object] $SmokeResult
    )

    $SelectedCpuEngine = [string] $SmokeResult.selectedCpuEngine
    if (@('cpu', 'ctimer') -notcontains $SelectedCpuEngine) {
        Stop-Profile "Invalid selected CPU engine: $SelectedCpuEngine"
    }
    if (Test-Path -LiteralPath $SmokeStateFile) {
        Stop-Profile "Smoke marker already exists and will not be overwritten: $SmokeStateFile"
    }
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $temp = "$SmokeStateFile.tmp.$PID"
    if (Test-Path -LiteralPath $temp) {
        Stop-Profile "Smoke marker temporary file already exists: $temp"
    }
    $state = [ordered] @{
        markerFormatVersion = $Context['markerFormatVersion']
        sourceRevision = $Context['sourceRevision']
        harnessRevision = $Context['harnessRevision']
        profilerVersion = $Context['profilerVersion']
        profilerAssetSha256 = $Context['profilerAssetSha256']
        securityLevel = $Context['securityLevel']
        selectedCpuEngine = $SelectedCpuEngine
        runtime = $Context['runtime']
        architecture = $Context['architecture']
        jdkVersion = $Context['jdkVersion']
        smokeProtocolVersion = $Context['smokeProtocolVersion']
        cpuWorkloadVersion = $Context['cpuWorkloadVersion']
        allocationWorkloadVersion = $Context['allocationWorkloadVersion']
        cpuSampleCount = [int64] $SmokeResult.cpuSampleCount
        allocationSampleCount = [int64] $SmokeResult.allocationSampleCount
        allocationSampledBytes = [int64] $SmokeResult.allocationSampledBytes
        engineVerification = [string] $SmokeResult.engineVerification
        smokeSuccess = $true
        createdAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    [System.IO.File]::WriteAllText($temp, (($state | ConvertTo-Json -Depth 4) + "`n"), $Script:Utf8NoBom)
    $tempState = Get-Content -LiteralPath $temp -Encoding UTF8 -Raw | ConvertFrom-Json
    Assert-JsonExactKeys -Object $tempState -Keys @(
        'markerFormatVersion',
        'sourceRevision',
        'harnessRevision',
        'profilerVersion',
        'profilerAssetSha256',
        'securityLevel',
        'selectedCpuEngine',
        'runtime',
        'architecture',
        'jdkVersion',
        'smokeProtocolVersion',
        'cpuWorkloadVersion',
        'allocationWorkloadVersion',
        'cpuSampleCount',
        'allocationSampleCount',
        'allocationSampledBytes',
        'engineVerification',
        'smokeSuccess',
        'createdAtUtc'
    ) -Name 'smoke marker candidate'
    Move-Item -LiteralPath $temp -Destination $SmokeStateFile
}

function Invoke-Smoke {
    Assert-ProfilerHarness
    Assert-DockerReady
    New-Item -ItemType Directory -Force -Path $RawRoot, $StateDir | Out-Null
    $context = Get-SmokeContext
    if (Test-Path -LiteralPath $SmokeStateFile) {
        Stop-Profile "Smoke marker already exists and will not be overwritten: $SmokeStateFile"
    }
    $smokeId = 'smoke-' + [DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'")
    $smokeResultPath = Join-Path $RawRoot "$smokeId\raw\smoke\smoke-ready.json"

    Write-ProfileLog "Docker profile runtime을 시작합니다. security level: $SecurityLevel"
    Invoke-Compose -Arguments @('up', '-d', '--build', 'postgres', 'app')
    Invoke-Compose -Arguments @('exec', '-T', 'app', '/opt/exp001/exp001-profile.sh', 'require-tool')
    Invoke-Compose -Arguments @('exec', '-T', '-e', "EXP001_SMOKE_ID=$smokeId", 'app', '/opt/exp001/exp001-profile.sh', 'smoke')

    $smokeResult = Read-SmokeResult -SmokeResultPath $smokeResultPath
    Write-SmokeMarker -Context $context -SmokeResult $smokeResult
    Write-ProfileLog "smoke 통과 상태를 기록했습니다: $SmokeStateFile"
}

function Assert-SmokeReadyLegacy {
    if (-not (Test-Path -LiteralPath $SmokeStateFile)) {
        Stop-Profile 'actual profile은 smoke 통과 상태 파일이 있을 때만 실행할 수 있습니다. 먼저 smoke action을 실행하세요.'
    }
    $state = Get-Content -LiteralPath $SmokeStateFile -Encoding UTF8 -Raw | ConvertFrom-Json
    if ($state.smokeReady -ne $true) {
        Stop-Profile 'smoke state가 ready가 아닙니다.'
    }
    if ([int] $state.securityLevel -ne $SecurityLevel) {
        Stop-Profile "smoke security level과 현재 security level이 다릅니다: smoke=$($state.securityLevel) current=$SecurityLevel"
    }
}

function Assert-SmokeReady {
    if (-not (Test-Path -LiteralPath $SmokeStateFile)) {
        Stop-Profile 'Actual profile requires a successful smoke marker.'
    }
    $state = Get-Content -LiteralPath $SmokeStateFile -Encoding UTF8 -Raw | ConvertFrom-Json
    Assert-JsonExactKeys -Object $state -Keys @(
        'markerFormatVersion',
        'sourceRevision',
        'harnessRevision',
        'profilerVersion',
        'profilerAssetSha256',
        'securityLevel',
        'selectedCpuEngine',
        'runtime',
        'architecture',
        'jdkVersion',
        'smokeProtocolVersion',
        'cpuWorkloadVersion',
        'allocationWorkloadVersion',
        'cpuSampleCount',
        'allocationSampleCount',
        'allocationSampledBytes',
        'engineVerification',
        'smokeSuccess',
        'createdAtUtc'
    ) -Name 'smoke marker'

    $context = Get-SmokeContext
    foreach ($key in @(
        'markerFormatVersion',
        'sourceRevision',
        'harnessRevision',
        'profilerVersion',
        'profilerAssetSha256',
        'securityLevel',
        'runtime',
        'architecture',
        'jdkVersion',
        'smokeProtocolVersion',
        'cpuWorkloadVersion',
        'allocationWorkloadVersion'
    )) {
        if ([string] $state.$key -ne [string] $context[$key]) {
            Stop-Profile "Smoke marker mismatch for $key."
        }
    }
    if ($state.smokeSuccess -ne $true) {
        Stop-Profile 'Smoke marker is not successful.'
    }
    if (@('cpu', 'ctimer') -notcontains [string] $state.selectedCpuEngine) {
        Stop-Profile "Smoke marker selectedCpuEngine is invalid: $($state.selectedCpuEngine)"
    }
    $config = Read-ProfileConfig
    if ([int64] $state.cpuSampleCount -lt [int64] $config.smoke.cpuWorkload.minimumSamples) {
        Stop-Profile "Smoke marker CPU sample count is below threshold: $($state.cpuSampleCount)"
    }
    if ([int64] $state.allocationSampleCount -lt [int64] $config.smoke.allocationWorkload.minimumSamples) {
        Stop-Profile "Smoke marker allocation sample count is below threshold: $($state.allocationSampleCount)"
    }
    if ([int64] $state.allocationSampledBytes -lt [int64] $config.smoke.allocationWorkload.minimumSampledBytes) {
        Stop-Profile "Smoke marker allocation sampled bytes are below threshold: $($state.allocationSampledBytes)"
    }
    if ([string] $state.selectedCpuEngine -eq 'cpu' -and [string] $state.engineVerification -ne $EngineVerificationPerfEvents) {
        Stop-Profile "Smoke marker selectedCpuEngine=cpu requires engineVerification=$EngineVerificationPerfEvents."
    }
    if ([string] $state.selectedCpuEngine -eq 'ctimer' -and [string] $state.engineVerification -ne $EngineVerificationCtimer) {
        Stop-Profile "Smoke marker selectedCpuEngine=ctimer requires engineVerification=$EngineVerificationCtimer."
    }
    if ($state.createdAtUtc -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$') {
        Stop-Profile "Smoke marker createdAtUtc is invalid: $($state.createdAtUtc)"
    }
    return $state
}

function Invoke-Smoke {
    $oldImportOnly = $env:EXP001_PROFILE_IMPORT_ONLY
    $failureMessage = ''
    $cleanupFailure = ''
    $context = $null
    $smokeResult = $null

    try {
        $env:EXP001_PROFILE_IMPORT_ONLY = '1'
        try {
            Assert-ProfilerHarness
            Assert-DockerReady
            New-Item -ItemType Directory -Force -Path $RawRoot, $StateDir | Out-Null
            $context = Get-SmokeContext
            if (Test-Path -LiteralPath $SmokeStateFile) {
                Stop-Profile "Smoke marker already exists and will not be overwritten: $SmokeStateFile"
            }
            Invoke-ProfilerCleanup -FailureCode 'SMOKE_CLEANUP_FAILED'

            $smokeId = 'smoke-' + [DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'")
            $smokeResultPath = Join-Path $RawRoot "$smokeId\raw\smoke\smoke-ready.json"

            Write-ProfileLog "Docker profile runtime을 시작합니다. security level: $SecurityLevel"
            Invoke-Compose -Arguments @('up', '-d', '--build', 'postgres', 'app')
            Invoke-Compose -Arguments @('exec', '-T', 'app', '/opt/exp001/exp001-profile.sh', 'require-tool')
            Invoke-Compose -Arguments @('exec', '-T', '-e', "EXP001_SMOKE_ID=$smokeId", 'app', '/opt/exp001/exp001-profile.sh', 'smoke')

            $smokeResult = Read-SmokeResult -SmokeResultPath $smokeResultPath
        } catch {
            $failureMessage = $_.Exception.Message
        } finally {
            try {
                Invoke-ProfilerCleanup -FailureCode 'SMOKE_CLEANUP_FAILED'
            } catch {
                $cleanupFailure = $_.Exception.Message
            }
        }
    } finally {
        $env:EXP001_PROFILE_IMPORT_ONLY = $oldImportOnly
    }

    if (-not [string]::IsNullOrWhiteSpace($cleanupFailure)) {
        if (-not [string]::IsNullOrWhiteSpace($failureMessage)) {
            Stop-Profile "$cleanupFailure; original failure: $failureMessage"
        }
        Stop-Profile $cleanupFailure
    }
    if (-not [string]::IsNullOrWhiteSpace($failureMessage)) {
        Stop-Profile $failureMessage
    }
    if ($null -eq $context -or $null -eq $smokeResult) {
        Stop-Profile 'Smoke transaction did not produce a marker candidate.'
    }

    Write-SmokeMarker -Context $context -SmokeResult $smokeResult
    Write-ProfileLog "smoke 통과 상태를 기록했습니다: $SmokeStateFile"
}

function Show-Help {
    Write-Host 'EXP-001 async-profiler Windows harness'
    Write-Host ''
    Write-Host '사용법:'
    Write-Host '  powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\exp-001\profiler\windows\exp001-profile.ps1 <action>'
    Write-Host ''
    Write-Host 'Actions:'
    Write-Host '  verify       lock/config/Docker policy/official result guard를 검증한다.'
    Write-Host '  prepare-tool mounted Linux async-profiler tool을 lock 기준으로 준비한다. 다운로드는 -AllowDownload가 필요하다.'
    Write-Host '  smoke        Docker app JVM에 DB-free CPU/allocation smoke workload를 attach한다.'
    Write-Host '  cleanup      Docker profiler project resource와 partial artifact를 정리한다.'
    Write-Host '  profile      smoke 통과 후 실제 Phase B profile을 실행한다. -AllowActualProfile이 필요하다.'
    Write-Host '  validate     results/exp-001/profiling/<profile-run-id>/summary.json을 schema gate로 검증한다.'
    Write-Host '  help         이 도움말을 출력한다.'
    Write-Host ''
    Write-Host 'SecurityLevel: 0 기본 seccomp, 1 seccomp=unconfined, 2 seccomp=unconfined + SYS_ADMIN'
}

function New-ProfileRunId {
    $sha = (& git -C $ProjectRoot rev-parse --short=12 HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $sha -notmatch '^[0-9a-f]{7,12}$') {
        Stop-Profile 'Git short SHA를 확인하지 못했습니다.'
    }
    return ([DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'") + "-$sha")
}

function Reset-ProfilerDb {
    Invoke-Compose -Arguments @(
        'exec',
        '-T',
        'postgres',
        'psql',
        '-U',
        'lab_user',
        '-d',
        'persistence_lab',
        '-v',
        'ON_ERROR_STOP=1',
        '-c',
        'TRUNCATE TABLE benchmark_record RESTART IDENTITY;'
    )
}

function Assert-ProfilerDbEmpty {
    $output = Invoke-ComposeCapture -Arguments @(
        'exec',
        '-T',
        'postgres',
        'psql',
        '-U',
        'lab_user',
        '-d',
        'persistence_lab',
        '-t',
        '-A',
        '-c',
        'SELECT COUNT(*) FROM benchmark_record;'
    )
    $count = (($output | Out-String).Trim())
    if ($count -ne '0') {
        Stop-Profile "benchmark_record table이 비어 있지 않습니다: $count"
    }
}

function Invoke-ContainerCall {
    param(
        [string] $RunId,
        [string] $Strategy,
        [string] $Label
    )

    $responsePath = "/artifacts/exp-001/profiling/$RunId/raw/warmup/$Label-$Strategy.response.raw"
    Invoke-Compose -Arguments @(
        'exec',
        '-T',
        '-e',
        "EXP001_STRATEGY=$Strategy",
        '-e',
        "EXP001_RESPONSE_OUTPUT=$responsePath",
        'app',
        '/opt/exp001/exp001-profile.sh',
        'call'
    )
}

function Resolve-ProfileEventForChunk {
    param(
        [object] $Profile,
        [string] $CpuEngine
    )

    if (@('cpu', 'ctimer') -notcontains $CpuEngine) {
        Stop-Profile "Invalid CPU engine: $CpuEngine"
    }
    $event = [string] $Profile.event
    if ($event -eq 'cpu') {
        return $CpuEngine
    }
    if ($event -eq 'alloc') {
        return 'alloc'
    }
    Stop-Profile "Invalid profile event: $event"
}

function Invoke-ProfileChunk {
    param(
        [string] $RunId,
        [object] $Profile,
        [int] $ChunkIndex,
        [string] $CpuEngine
    )

    $event = Resolve-ProfileEventForChunk -Profile $Profile -CpuEngine $CpuEngine

    Invoke-Compose -Arguments @(
        'exec',
        '-T',
        '-e',
        "EXP001_PROFILE_RUN_ID=$RunId",
        '-e',
        "EXP001_PROFILE_ID=$($Profile.id)",
        '-e',
        "EXP001_EVENT=$event",
        '-e',
        "EXP001_CPU_ENGINE=$CpuEngine",
        '-e',
        "EXP001_STRATEGY=$($Profile.strategy)",
        '-e',
        "EXP001_INTERVAL=$($Profile.interval)",
        '-e',
        "EXP001_CHUNK_INDEX=$ChunkIndex",
        'app',
        '/opt/exp001/exp001-profile.sh',
        'record-chunk'
    )
}

function Invoke-Profile {
    if (-not $AllowActualProfile) {
        Stop-Profile 'actual 50,000-row profile execution은 -AllowActualProfile을 명시한 경우에만 허용됩니다.'
    }
    Assert-ProfilerHarness
    Assert-DockerReady
    $smokeState = Assert-SmokeReady

    $dirty = (& git -C $ProjectRoot status --short)
    if ($LASTEXITCODE -ne 0) {
        Stop-Profile 'Git status를 확인하지 못했습니다.'
    }
    if (-not [string]::IsNullOrWhiteSpace(($dirty | Out-String))) {
        Stop-Profile 'actual profile execution은 clean working tree에서만 허용됩니다.'
    }

    $config = Read-ProfileConfig
    $runId = $ProfileRunId
    if ([string]::IsNullOrWhiteSpace($runId)) {
        $runId = New-ProfileRunId
    }
    if ($runId -notmatch '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{7,12}$') {
        Stop-Profile "profile run ID 형식이 유효하지 않습니다: $runId"
    }

    $rawRunDir = Join-Path $RawRoot $runId
    if (Test-Path -LiteralPath $rawRunDir) {
        Stop-Profile "raw profile run directory가 이미 존재합니다: $rawRunDir"
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $rawRunDir 'raw\warmup') | Out-Null

    Write-ProfileLog "Phase B profiler run을 시작합니다: $runId"
    Invoke-Compose -Arguments @('up', '-d', 'postgres', 'app')

    for ($i = 1; $i -le [int] $config.warmup.jpaRepetitions; $i++) {
        Reset-ProfilerDb
        Assert-ProfilerDbEmpty
        Invoke-ContainerCall -RunId $runId -Strategy 'jpa' -Label ("jpa-{0:D2}" -f $i)
    }
    for ($i = 1; $i -le [int] $config.warmup.jdbcRepetitions; $i++) {
        Reset-ProfilerDb
        Assert-ProfilerDbEmpty
        Invoke-ContainerCall -RunId $runId -Strategy 'jdbc' -Label ("jdbc-{0:D2}" -f $i)
    }

    $cpuEngine = [string] $smokeState.selectedCpuEngine
    foreach ($profileId in @($config.profileOrder)) {
        $profile = @($config.profiles | Where-Object { [string] $_.id -eq [string] $profileId })
        if ($profile.Count -ne 1) {
            Stop-Profile "profile config를 찾지 못했습니다: $profileId"
        }
        for ($chunk = 1; $chunk -le [int] $profile[0].repetitions; $chunk++) {
            Reset-ProfilerDb
            Assert-ProfilerDbEmpty
            Invoke-ProfileChunk -RunId $runId -Profile $profile[0] -ChunkIndex $chunk -CpuEngine $cpuEngine
        }
    }

    Write-ProfileLog "raw profile artifact 생성 완료: $rawRunDir"
    Write-ProfileLog 'summary.json/metadata.md/analysis.md/manifest.md publication은 raw artifact 검토 후 별도 evidence 단계에서 수행하세요.'
}

function Invoke-ValidatePublication {
    Assert-ProfilerHarness
    Require-Jq | Out-Null

    $runId = $ProfileRunId
    if ([string]::IsNullOrWhiteSpace($runId)) {
        Stop-Profile 'validate action에는 -ProfileRunId가 필요합니다.'
    }

    $trackedRunDir = Join-Path $TrackedRoot $runId
    $summary = Join-Path $trackedRunDir 'summary.json'
    if (-not (Test-Path -LiteralPath $summary)) {
        Stop-Profile "summary.json이 없습니다: $summary"
    }

    $jq = Require-Jq
    & $jq -e -f $ValidateSummaryFilter $summary | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Stop-Profile "profile summary schema gate를 통과하지 못했습니다: $summary"
    }

    foreach ($allow in @('metadata.md', 'summary.json', 'analysis.md', 'manifest.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $trackedRunDir $allow))) {
            Stop-Profile "tracked publication allowlist 파일이 없습니다: $allow"
        }
    }

    $unexpected = @(Get-ChildItem -LiteralPath $trackedRunDir -File | Where-Object { @('metadata.md', 'summary.json', 'analysis.md', 'manifest.md') -notcontains $_.Name })
    if ($unexpected.Count -ne 0) {
        Stop-Profile "tracked publication allowlist 밖 파일이 있습니다: $($unexpected.Name -join ', ')"
    }

    Write-ProfileLog "profile publication 검증 완료: $trackedRunDir"
}

if ($env:EXP001_PROFILE_IMPORT_ONLY -eq '1') {
    return
}

try {
    switch ($Action.ToLowerInvariant()) {
        'verify' { Assert-ProfilerHarness }
        'prepare-tool' { Install-AsyncProfilerTool }
        'smoke' { Invoke-Smoke }
        'cleanup' { Invoke-Cleanup }
        'profile' { Invoke-Profile }
        'validate' { Invoke-ValidatePublication }
        'help' { Show-Help }
        default {
            Show-Help
            Stop-Profile "알 수 없는 action입니다: $Action"
        }
    }
} catch {
    Stop-Profile $_.Exception.Message
}
