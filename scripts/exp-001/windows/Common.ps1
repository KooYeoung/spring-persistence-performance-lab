Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Script:Utf8NoBom
$OutputEncoding = $Script:Utf8NoBom

$Script:Exp001WindowsDir = $PSScriptRoot
$Script:Exp001Root = Split-Path -Parent $Script:Exp001WindowsDir
$Script:EnvFile = Join-Path $Script:Exp001Root '.env'
$Script:StateDir = Join-Path $Script:Exp001Root '.state'
$Script:ToolsDir = Join-Path $Script:Exp001Root '.tools'
$Script:ApplicationStateFile = Join-Path $Script:StateDir 'application.json'
$Script:ApplicationStdoutLog = Join-Path $Script:StateDir 'application.out.log'
$Script:ApplicationStderrLog = Join-Path $Script:StateDir 'application.err.log'
$Script:JqLockFile = Join-Path $Script:Exp001Root 'tools\jq.lock'
$Script:JdkLockFile = Join-Path $Script:Exp001Root 'tools\jdk.lock'
$Script:ValidateResponseFilter = Join-Path $Script:Exp001Root 'shared\validate-response.jq'
$Script:SummaryFilter = Join-Path $Script:Exp001Root 'shared\summary.jq'
$Script:PostgresService = 'persistence-lab-postgres'
$Script:PlatformName = 'windows'
$Script:Config = @{}
$Script:ProjectRootAbs = $null
$Script:ResultRootAbs = $null
$Script:JdkRuntime = $null

function Write-Log {
    param([string] $Message)
    $timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Host "[$timestamp] $Message"
}

function Write-Warn {
    param([string] $Message)
    $timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Warning "[$timestamp] $Message"
}

function Stop-Exp001 {
    param([string] $Message)
    $timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    [Console]::Error.WriteLine("[$timestamp] ERROR: $Message")
    exit 1
}

function Read-KeyValueFile {
    param([string] $Path)

    $values = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $values
    }

    foreach ($rawLine in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $line = $rawLine.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) {
            continue
        }

        $equalsIndex = $line.IndexOf('=')
        if ($equalsIndex -lt 1) {
            throw "KEY=VALUE 형식이 아닌 line입니다: $Path"
        }

        $key = $line.Substring(0, $equalsIndex).Trim()
        $value = $line.Substring($equalsIndex + 1).Trim()
        if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "허용되지 않는 key 형식입니다: $key"
        }

        $values[$key] = $value
    }

    return $values
}

function Initialize-Exp001 {
    $defaults = @{
        PROJECT_ROOT = '../..'
        BASE_URL = 'http://localhost:8080'
        SERVER_PORT = ''
        DB_HOST = 'localhost'
        DB_PORT = '55432'
        DB_NAME = 'persistence_lab'
        DB_USER = 'lab_user'
        DB_PASSWORD = 'lab_password'
        SPRING_PROFILE = 'exp001'
        EXPECTED_INPUT_COUNT = '50000'
        OFFICIAL_ROUNDS = '6'
        COOLDOWN_SECONDS = '10'
        REQUEST_TIMEOUT_SECONDS = '600'
        STARTUP_TIMEOUT_SECONDS = '180'
        STOP_TIMEOUT_SECONDS = '20'
        ALLOW_DESTRUCTIVE_RESET = 'false'
        RESULT_ROOT = 'results/exp-001'
    }

    $Script:Config = $defaults.Clone()
    $envValues = Read-KeyValueFile -Path $Script:EnvFile
    foreach ($key in $envValues.Keys) {
        $Script:Config[$key] = $envValues[$key]
    }

    $projectRootCandidate = Join-Path $Script:Exp001Root $Script:Config['PROJECT_ROOT']
    $Script:ProjectRootAbs = (Resolve-Path -LiteralPath $projectRootCandidate).ProviderPath
    $Script:ResultRootAbs = Resolve-SafeResultRootPath -ProjectRoot $Script:ProjectRootAbs -ResultRoot $Script:Config['RESULT_ROOT']
}

function Get-ConfigValue {
    param([string] $Key)
    return [string] $Script:Config[$Key]
}

function Remove-TrailingDirectorySeparator {
    param([string] $Path)

    $trimmed = [System.IO.Path]::GetFullPath($Path)
    while ($trimmed.Length -gt 3 -and ($trimmed.EndsWith('\') -or $trimmed.EndsWith('/'))) {
        $trimmed = $trimmed.Substring(0, $trimmed.Length - 1)
    }
    return $trimmed
}

function Assert-NoReparsePointInResultPath {
    param(
        [string] $ProjectRoot,
        [string] $Candidate
    )

    $root = Remove-TrailingDirectorySeparator -Path $ProjectRoot
    $candidatePath = Remove-TrailingDirectorySeparator -Path $Candidate
    $rootPrefix = $root + [System.IO.Path]::DirectorySeparatorChar
    $relativePath = $candidatePath.Substring($rootPrefix.Length)
    $current = $root

    foreach ($segment in $relativePath.Split([System.IO.Path]::DirectorySeparatorChar)) {
        if ([string]::IsNullOrEmpty($segment)) {
            continue
        }

        $current = [System.IO.Path]::Combine($current, $segment)
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (-not $item.PSIsContainer) {
                Stop-Exp001 "RESULT_ROOT 경로에 directory가 아닌 항목이 있습니다: $current"
            }
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Stop-Exp001 "RESULT_ROOT 경로에 symlink 또는 junction이 포함되어 있습니다: $current"
            }
        }
    }
}

function Resolve-SafeResultRootPath {
    param(
        [string] $ProjectRoot,
        [string] $ResultRoot
    )

    $value = ([string] $ResultRoot).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        Stop-Exp001 'RESULT_ROOT는 비어 있을 수 없습니다.'
    }
    if ($value -eq '.') {
        Stop-Exp001 'RESULT_ROOT는 project root 자체를 가리킬 수 없습니다.'
    }
    if ($value.StartsWith('~')) {
        Stop-Exp001 "RESULT_ROOT는 home shortcut으로 시작할 수 없습니다: $value"
    }
    if ($value.Contains('\')) {
        Stop-Exp001 "RESULT_ROOT는 forward slash만 사용할 수 있습니다: $value"
    }
    if ($value.StartsWith('/') -or $value.StartsWith('//')) {
        Stop-Exp001 "RESULT_ROOT는 absolute path 또는 UNC path일 수 없습니다: $value"
    }
    if ($value -match '^[A-Za-z]:') {
        Stop-Exp001 "RESULT_ROOT는 Windows drive path일 수 없습니다: $value"
    }
    if ([System.IO.Path]::IsPathRooted($value)) {
        Stop-Exp001 "RESULT_ROOT는 repository-relative path여야 합니다: $value"
    }

    foreach ($segment in $value.Split('/')) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            Stop-Exp001 "RESULT_ROOT에는 빈 path segment가 포함될 수 없습니다: $value"
        }
        if ($segment -eq '.' -or $segment -eq '..') {
            Stop-Exp001 "RESULT_ROOT에는 . 또는 .. path segment가 포함될 수 없습니다: $value"
        }
    }

    $projectRootFull = Remove-TrailingDirectorySeparator -Path $ProjectRoot
    $candidate = Remove-TrailingDirectorySeparator -Path ([System.IO.Path]::Combine($projectRootFull, $value))
    if ($candidate.Equals($projectRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-Exp001 'RESULT_ROOT는 project root 자체를 가리킬 수 없습니다.'
    }

    $projectRootPrefix = $projectRootFull + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($projectRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-Exp001 "RESULT_ROOT는 project root 내부여야 합니다: $value"
    }

    Assert-NoReparsePointInResultPath -ProjectRoot $projectRootFull -Candidate $candidate
    return $candidate
}

function Require-Command {
    param([string] $Name)
    if ($null -eq (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Stop-Exp001 "필수 command를 찾을 수 없습니다: $Name"
    }
}

function Invoke-VersionCommand {
    param(
        [string] $FilePath,
        [string] $Arguments = '-version'
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        [void] $process.Start()
    } catch {
        Stop-Exp001 "$FilePath $Arguments 실행에 실패했습니다: $($_.Exception.Message)"
    }

    try {
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()

        return [pscustomobject] @{
            Stdout = $stdout
            Stderr = $stderr
            ExitCode = $process.ExitCode
        }
    } finally {
        $process.Dispose()
    }
}

function Join-VersionOutput {
    param([object] $Result)

    return (@($Result.Stdout, $Result.Stderr) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() } |
        Out-String).Trim()
}

function Get-JavaVersionNumber {
    param([string] $VersionText)

    if ([string]::IsNullOrWhiteSpace($VersionText)) {
        return $null
    }

    $match = [regex]::Match($VersionText, 'version\s+"([0-9]+(?:[._][0-9]+)*(?:[-+][^"]*)?)"')
    if (-not $match.Success) {
        $match = [regex]::Match($VersionText, 'javac\s+([0-9]+(?:[._][0-9]+)*(?:[-+][^\s]*)?)')
    }
    if (-not $match.Success) {
        return $null
    }

    return $match.Groups[1].Value
}

function Get-JavaMajorVersion {
    param([string] $VersionText)

    $version = Get-JavaVersionNumber -VersionText $VersionText
    if ([string]::IsNullOrWhiteSpace($version)) {
        return $null
    }

    $major = 0
    $majorText = ($version -split '[._]')[0]
    if (-not [int]::TryParse($majorText, [ref] $major)) {
        return $null
    }
    return $major
}

function Read-JdkLock {
    $lock = Read-KeyValueFile -Path $Script:JdkLockFile
    foreach ($key in @(
        'vendor',
        'java_version',
        'asset_version',
        'windows_x64_url',
        'windows_x64_sha256',
        'windows_x64_archive_type',
        'windows_x64_jdk_home',
        'macos_x64_url',
        'macos_x64_sha256',
        'macos_x64_archive_type',
        'macos_x64_jdk_home',
        'macos_arm64_url',
        'macos_arm64_sha256',
        'macos_arm64_archive_type',
        'macos_arm64_jdk_home'
    )) {
        if (-not $lock.ContainsKey($key)) {
            Stop-Exp001 "JDK lock에 필요한 key가 없습니다: $key"
        }
    }
    if ($lock['vendor'] -ne 'Amazon Corretto') {
        Stop-Exp001 "지원하지 않는 JDK vendor입니다: $($lock['vendor'])"
    }
    return $lock
}

function Get-JdkPlatformKey {
    $arch = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE')
    if ($arch -ne 'AMD64') {
        Stop-Exp001 "지원하지 않는 Windows JDK architecture입니다: $arch"
    }
    return 'windows_x64'
}

function Get-JdkRuntimeRoot {
    return Join-Path $Script:ToolsDir 'jdk\windows-x64'
}

function Get-JdkHomeRelativePath {
    param(
        [hashtable] $Lock,
        [string] $PlatformKey = (Get-JdkPlatformKey)
    )

    return ([string] $Lock["${PlatformKey}_jdk_home"]).Replace('/', '\')
}

function Get-JdkRuntimeDir {
    param([hashtable] $Lock)

    return Join-Path (Get-JdkRuntimeRoot) (Get-JdkHomeRelativePath -Lock $Lock)
}

function Get-JdkTopLevelRuntimeDir {
    param([hashtable] $Lock)

    $relativeHome = Get-JdkHomeRelativePath -Lock $Lock
    $topLevelName = ($relativeHome -split '[\\/]')[0]
    return Join-Path (Get-JdkRuntimeRoot) $topLevelName
}

function Get-JdkReleaseValue {
    param(
        [string] $ReleaseFile,
        [string] $Key
    )

    $pattern = '^' + [regex]::Escape($Key) + '=(.*)$'
    foreach ($rawLine in Get-Content -LiteralPath $ReleaseFile -Encoding UTF8) {
        $match = [regex]::Match($rawLine, $pattern)
        if ($match.Success) {
            $value = $match.Groups[1].Value.Trim()
            if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
                return $value.Substring(1, $value.Length - 2)
            }
            return $value
        }
    }

    return ''
}

function Test-LockedJdkHome {
    param(
        [string] $JdkHome,
        [hashtable] $Lock
    )

    if ([string]::IsNullOrWhiteSpace($JdkHome)) {
        return $null
    }

    $resolvedHome = [System.IO.Path]::GetFullPath($JdkHome)
    $javaPath = Join-Path $resolvedHome 'bin\java.exe'
    $javacPath = Join-Path $resolvedHome 'bin\javac.exe'
    $releaseFile = Join-Path $resolvedHome 'release'
    if (-not (Test-Path -LiteralPath $resolvedHome) `
        -or -not (Test-Path -LiteralPath $javaPath) `
        -or -not (Test-Path -LiteralPath $javacPath) `
        -or -not (Test-Path -LiteralPath $releaseFile)) {
        return $null
    }

    if ((Get-JdkReleaseValue -ReleaseFile $releaseFile -Key 'IMPLEMENTOR') -ne 'Amazon.com Inc.') {
        return $null
    }
    if ((Get-JdkReleaseValue -ReleaseFile $releaseFile -Key 'IMPLEMENTOR_VERSION') -ne "Corretto-$($Lock['asset_version'])") {
        return $null
    }
    if ((Get-JdkReleaseValue -ReleaseFile $releaseFile -Key 'JAVA_VERSION') -ne $Lock['java_version']) {
        return $null
    }

    $javaResult = Invoke-VersionCommand -FilePath $javaPath
    $javaText = Join-VersionOutput -Result $javaResult
    if ($javaResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($javaText)) {
        return $null
    }

    $javacResult = Invoke-VersionCommand -FilePath $javacPath
    $javacText = Join-VersionOutput -Result $javacResult
    if ($javacResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($javacText)) {
        return $null
    }

    $javaVersion = Get-JavaVersionNumber -VersionText $javaText
    $javacVersion = Get-JavaVersionNumber -VersionText $javacText
    if ($javaVersion -ne $Lock['java_version'] -or $javacVersion -ne $Lock['java_version']) {
        return $null
    }
    if ((Get-JavaMajorVersion -VersionText $javaText) -ne 21 -or (Get-JavaMajorVersion -VersionText $javacText) -ne 21) {
        return $null
    }

    return [pscustomobject] @{
        Home = $resolvedHome
        JavaPath = $javaPath
        JavacPath = $javacPath
        VersionText = $javaText
    }
}

function Assert-LockedJdkHome {
    param(
        [string] $JdkHome,
        [hashtable] $Lock
    )

    $jdk = Test-LockedJdkHome -JdkHome $JdkHome -Lock $Lock
    if ($null -eq $jdk) {
        Stop-Exp001 "JDK lock과 일치하지 않는 JDK입니다: $JdkHome"
    }
    return $jdk
}

function Find-LocalLockedJdk {
    param([hashtable] $Lock)

    $candidateHomes = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($env:JAVA_HOME)) {
        $candidateHomes.Add($env:JAVA_HOME)
    }

    foreach ($command in @(Get-Command 'java.exe' -CommandType Application -All -ErrorAction SilentlyContinue)) {
        if (-not [string]::IsNullOrWhiteSpace($command.Path)) {
            $candidateHomes.Add((Split-Path -Parent (Split-Path -Parent $command.Path)))
        }
    }

    foreach ($root in @(
        (Join-Path $env:USERPROFILE '.jdks'),
        'C:\Program Files\Amazon Corretto',
        'C:\Program Files\Eclipse Adoptium',
        'C:\Program Files\Microsoft',
        'C:\Program Files\Java'
    )) {
        if (Test-Path -LiteralPath $root) {
            foreach ($java in @(Get-ChildItem -LiteralPath $root -Recurse -Filter 'java.exe' -ErrorAction SilentlyContinue)) {
                if ($java.FullName -match '\\bin\\java\.exe$') {
                    $candidateHomes.Add((Split-Path -Parent (Split-Path -Parent $java.FullName)))
                }
            }
        }
    }

    $seen = @{}
    foreach ($candidate in $candidateHomes) {
        $full = [System.IO.Path]::GetFullPath($candidate)
        if ($seen.ContainsKey($full)) {
            continue
        }
        $seen[$full] = $true
        $jdk = Test-LockedJdkHome -JdkHome $full -Lock $Lock
        if ($null -ne $jdk) {
            return $jdk
        }
    }

    return $null
}

function Find-ExtractedJdkHome {
    param(
        [string] $ExtractDir,
        [hashtable] $Lock
    )

    $expectedHome = Join-Path $ExtractDir (Get-JdkHomeRelativePath -Lock $Lock)
    return Test-LockedJdkHome -JdkHome $expectedHome -Lock $Lock
}

function Install-LockedJdk {
    param([hashtable] $Lock)

    $platformKey = Get-JdkPlatformKey
    $url = [string] $Lock["${platformKey}_url"]
    $expectedSha = [string] $Lock["${platformKey}_sha256"]
    $archiveType = [string] $Lock["${platformKey}_archive_type"]
    if ($archiveType -ne 'zip') {
        Stop-Exp001 "지원하지 않는 Windows JDK archive type입니다: $archiveType"
    }

    $runtimeDir = Get-JdkRuntimeDir -Lock $Lock
    $runtimeRoot = Get-JdkRuntimeRoot
    $runtimeTopLevelDir = Get-JdkTopLevelRuntimeDir -Lock $Lock
    New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null

    if (Test-Path -LiteralPath $runtimeDir) {
        return Assert-LockedJdkHome -JdkHome $runtimeDir -Lock $Lock
    }

    $archive = Join-Path $runtimeRoot "amazon-corretto-$($Lock['asset_version'])-$platformKey.$archiveType.tmp.$PID"
    $extractDir = Join-Path $runtimeRoot "extract-$PID"
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Log "Amazon Corretto JDK $($Lock['java_version']) 다운로드: $platformKey"
        Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing -ErrorAction Stop

        if (-not (Test-Path -LiteralPath $archive)) {
            Stop-Exp001 "JDK archive 다운로드 결과 파일이 없습니다: $archive"
        }

        $actualSha = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualSha -ne $expectedSha) {
            Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
            Stop-Exp001 "downloaded JDK checksum이 일치하지 않습니다. expected=$expectedSha actual=$actualSha"
        }

        New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
        Expand-Archive -LiteralPath $archive -DestinationPath $extractDir -Force
        $extractedJdk = Find-ExtractedJdkHome -ExtractDir $extractDir -Lock $Lock
        if ($null -eq $extractedJdk) {
            Stop-Exp001 '압축 해제된 JDK가 lock 조건과 일치하지 않습니다.'
        }
        if (Test-Path -LiteralPath $runtimeDir) {
            Stop-Exp001 "JDK final runtime directory가 이미 존재합니다: $runtimeDir"
        }
        if (Test-Path -LiteralPath $runtimeTopLevelDir) {
            Stop-Exp001 "JDK final runtime top-level directory가 이미 존재합니다: $runtimeTopLevelDir"
        }

        $sourceTopLevelDir = Join-Path $extractDir (($Lock["${platformKey}_jdk_home"] -split '[\\/]')[0])
        Move-Item -LiteralPath $sourceTopLevelDir -Destination $runtimeTopLevelDir
        $verifiedJdk = Assert-LockedJdkHome -JdkHome $runtimeDir -Lock $Lock
        Write-Log "locked JDK 준비 완료: $runtimeDir"
        return $verifiedJdk
    } catch {
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-LockedJdk {
    param([switch] $AllowDownload)

    if ($null -ne $Script:JdkRuntime) {
        return $Script:JdkRuntime
    }

    $lock = Read-JdkLock
    $localJdk = Find-LocalLockedJdk -Lock $lock
    if ($null -ne $localJdk) {
        Write-Log "local locked JDK 확인 완료: $($localJdk.Home)"
        $Script:JdkRuntime = $localJdk
        return $Script:JdkRuntime
    }

    $runtimeDir = Get-JdkRuntimeDir -Lock $lock
    if (Test-Path -LiteralPath $runtimeDir) {
        $Script:JdkRuntime = Assert-LockedJdkHome -JdkHome $runtimeDir -Lock $lock
        Write-Log "cached locked JDK 확인 완료: $runtimeDir"
        return $Script:JdkRuntime
    }

    if ($AllowDownload) {
        $Script:JdkRuntime = Install-LockedJdk -Lock $lock
        return $Script:JdkRuntime
    }

    Stop-Exp001 "lock과 일치하는 Amazon Corretto JDK $($lock['java_version'])를 찾지 못했습니다. 먼저 prepare를 실행하세요."
}

function Assert-Java21 {
    Resolve-LockedJdk | Out-Null
}

function Invoke-WithJdkEnvironment {
    param(
        [object] $Jdk,
        [scriptblock] $Command
    )

    $oldJavaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Process')
    $oldPath = [Environment]::GetEnvironmentVariable('PATH', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('JAVA_HOME', $Jdk.Home, 'Process')
        [Environment]::SetEnvironmentVariable('PATH', "$(Join-Path $Jdk.Home 'bin');$oldPath", 'Process')
        & $Command
    } finally {
        [Environment]::SetEnvironmentVariable('JAVA_HOME', $oldJavaHome, 'Process')
        [Environment]::SetEnvironmentVariable('PATH', $oldPath, 'Process')
    }
}

function Require-DockerCompose {
    $docker = Get-Command 'docker' -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $docker) {
        $os = [Environment]::OSVersion.VersionString
        Stop-Exp001 "Docker command를 찾을 수 없습니다. Docker Desktop 설치가 필요합니다. 현재 운영체제: $os"
    }

    & docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Stop-Exp001 'Docker Engine에 연결할 수 없습니다. Docker Desktop을 실행하세요. 권한 또는 Engine 연결 문제일 수 있습니다.'
    }

    & docker compose version *> $null
    if ($LASTEXITCODE -ne 0) {
        Stop-Exp001 'docker compose를 사용할 수 없습니다. Docker Desktop의 Compose plugin을 확인하세요.'
    }

    $composeFile = Join-Path $Script:ProjectRootAbs 'docker-compose.yml'
    $services = & docker compose -f $composeFile config --services 2>$null
    if ($LASTEXITCODE -ne 0 -or @($services) -notcontains $Script:PostgresService) {
        Stop-Exp001 "Docker Compose PostgreSQL service를 확인할 수 없습니다: $Script:PostgresService"
    }

    $containerIds = @(& docker compose -f $composeFile ps -q $Script:PostgresService 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($LASTEXITCODE -ne 0 -or $containerIds.Count -eq 0) {
        Stop-Exp001 "Docker Compose PostgreSQL service가 실행 중이 아닙니다. 먼저 docker compose up -d를 실행하세요: $Script:PostgresService"
    }

    $containerId = ([string] $containerIds[0]).Trim()
    $runningOutput = @(& docker inspect --format '{{.State.Running}}' $containerId 2>$null)
    if ($LASTEXITCODE -ne 0 -or $runningOutput.Count -eq 0) {
        Stop-Exp001 "Docker Compose PostgreSQL container 상태를 확인할 수 없습니다: $Script:PostgresService"
    }
    $running = ([string] $runningOutput[0]).Trim()
    if ($running -ne 'true') {
        Stop-Exp001 "Docker Compose PostgreSQL service가 running 상태가 아닙니다: $Script:PostgresService"
    }

    $healthOutput = @(& docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' $containerId 2>$null)
    if ($LASTEXITCODE -ne 0 -or $healthOutput.Count -eq 0) {
        Stop-Exp001 "Docker Compose PostgreSQL health를 확인할 수 없습니다: $Script:PostgresService"
    }
    $health = ([string] $healthOutput[0]).Trim()
    if ($health -ne 'healthy') {
        Stop-Exp001 "Docker Compose PostgreSQL service health가 healthy가 아닙니다: $Script:PostgresService ($health)"
    }
}

function Ensure-Directories {
    New-Item -ItemType Directory -Force -Path $Script:StateDir, $Script:ToolsDir, $Script:ResultRootAbs | Out-Null
}

function Assert-ProjectRoot {
    if (-not (Test-Path -LiteralPath (Join-Path $Script:ProjectRootAbs 'settings.gradle'))) {
        Stop-Exp001 "project root에서 settings.gradle을 찾을 수 없습니다: $Script:ProjectRootAbs"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Script:ProjectRootAbs 'AGENTS.md'))) {
        Stop-Exp001 "project root에서 AGENTS.md를 찾을 수 없습니다: $Script:ProjectRootAbs"
    }
}

function Get-ServerPort {
    $serverPort = Get-ConfigValue 'SERVER_PORT'
    if ([string]::IsNullOrWhiteSpace($serverPort)) {
        $serverPort = [Environment]::GetEnvironmentVariable('SERVER_PORT')
    }
    if (-not [string]::IsNullOrWhiteSpace($serverPort)) {
        return $serverPort
    }

    try {
        $uri = [Uri] (Get-ConfigValue 'BASE_URL')
        if ($uri.IsDefaultPort) {
            return '8080'
        }
        return [string] $uri.Port
    } catch {
        Stop-Exp001 "BASE_URL을 URI로 해석할 수 없습니다: $(Get-ConfigValue 'BASE_URL')"
    }
}

function Read-JqLock {
    $lock = Read-KeyValueFile -Path $Script:JqLockFile
    foreach ($key in @('version', 'windows_x64_url', 'windows_x64_sha256')) {
        if (-not $lock.ContainsKey($key)) {
            Stop-Exp001 "jq lock에 필요한 key가 없습니다: $key"
        }
    }
    return $lock
}

function Get-JqPath {
    return Join-Path $Script:ToolsDir 'windows-x64\jq.exe'
}

function Assert-JqChecksum {
    param(
        [string] $Path,
        [string] $ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Stop-Exp001 "portable jq를 찾을 수 없습니다. 먼저 prepare를 실행하세요: $Path"
    }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedSha256) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        Stop-Exp001 "portable jq checksum이 일치하지 않아 삭제했습니다. expected=$ExpectedSha256 actual=$actual"
    }
}

function Install-OrVerify-Jq {
    $lock = Read-JqLock
    $arch = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE')
    if ($arch -ne 'AMD64') {
        Stop-Exp001 "지원하지 않는 Windows architecture입니다: $arch"
    }

    $target = Get-JqPath
    $targetDir = Split-Path -Parent $target
    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

    if (Test-Path -LiteralPath $target) {
        Assert-JqChecksum -Path $target -ExpectedSha256 $lock['windows_x64_sha256']
        Write-Log "portable jq checksum 확인 완료: $target"
        return $target
    }

    $temp = "$target.tmp.$PID"
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Log "portable jq를 다운로드합니다: jq $($lock['version']) windows-x64"
        Invoke-WebRequest -Uri $lock['windows_x64_url'] -OutFile $temp -UseBasicParsing -ErrorAction Stop
        $actual = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $lock['windows_x64_sha256']) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            Stop-Exp001 "downloaded jq checksum이 일치하지 않습니다. expected=$($lock['windows_x64_sha256']) actual=$actual"
        }
        if (Test-Path -LiteralPath $target) {
            Stop-Exp001 "portable jq final path가 이미 존재합니다: $target"
        }
        [System.IO.File]::Move($temp, $target)
        Write-Log "portable jq 준비 완료: $target"
        return $target
    } catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Require-Jq {
    $lock = Read-JqLock
    $target = Get-JqPath
    Assert-JqChecksum -Path $target -ExpectedSha256 $lock['windows_x64_sha256']
    return $target
}

function Get-HttpStatus {
    param([string] $Url)

    try {
        $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        return [string] [int] $response.StatusCode
    } catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            return [string] [int] $_.Exception.Response.StatusCode
        }
        return '000'
    }
}

function Assert-AppEndpointRegistered {
    $url = "$(Get-ConfigValue 'BASE_URL')/internal/exp-001/jpa"
    $statusCode = Get-HttpStatus -Url $url
    if ($statusCode -ne '405') {
        Stop-Exp001 "exp001 profiling endpoint가 확인되지 않습니다. expected HTTP 405, actual HTTP $statusCode"
    }
}

function Assert-ConfiguredDbIdentity {
    $dbHost = Get-ConfigValue 'DB_HOST'
    if ($dbHost -ne 'localhost' -and $dbHost -ne '127.0.0.1') {
        Stop-Exp001 "DB_HOST가 허용된 local host가 아닙니다: $dbHost"
    }

    if ((Get-ConfigValue 'DB_PORT') -ne '55432') {
        Stop-Exp001 "DB_PORT가 55432가 아닙니다: $(Get-ConfigValue 'DB_PORT')"
    }
    if ((Get-ConfigValue 'DB_NAME') -ne 'persistence_lab') {
        Stop-Exp001 "DB_NAME이 persistence_lab이 아닙니다: $(Get-ConfigValue 'DB_NAME')"
    }
    if ((Get-ConfigValue 'DB_USER') -ne 'lab_user') {
        Stop-Exp001 "DB_USER가 lab_user가 아닙니다: $(Get-ConfigValue 'DB_USER')"
    }
}

function Assert-DestructiveResetApproved {
    if ((Get-ConfigValue 'ALLOW_DESTRUCTIVE_RESET') -ne 'true') {
        Stop-Exp001 'ALLOW_DESTRUCTIVE_RESET가 true가 아니므로 reset과 run을 중단합니다.'
    }
}

function Invoke-Psql {
    param(
        [string] $Sql,
        [switch] $Query
    )

    $composeFile = Join-Path $Script:ProjectRootAbs 'docker-compose.yml'
    $arguments = @(
        'compose',
        '-f', $composeFile,
        'exec',
        '-T',
        $Script:PostgresService,
        'psql',
        '--username', (Get-ConfigValue 'DB_USER'),
        '--dbname', (Get-ConfigValue 'DB_NAME'),
        '--no-psqlrc',
        '--set', 'ON_ERROR_STOP=1'
    )

    if ($Query) {
        $arguments += @('--no-align', '--tuples-only')
    }

    $arguments += @('--command', $Sql)

    $output = & docker @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        Stop-Exp001 "container 내부 psql 실행에 실패했습니다. Docker Compose service를 확인하세요: $Script:PostgresService"
    }

    if ($Query) {
        return (($output -join "`n").Trim())
    }

    return ''
}

function Assert-ActualDbGate {
    $actualDatabase = Invoke-Psql -Sql 'SELECT current_database();' -Query
    $actualUser = Invoke-Psql -Sql 'SELECT current_user;' -Query
    $actualIsolation = Invoke-Psql -Sql 'SHOW transaction_isolation;' -Query

    if ($actualDatabase -ne 'persistence_lab') {
        Stop-Exp001 "current_database()가 persistence_lab이 아닙니다: $actualDatabase"
    }
    if ($actualUser -ne 'lab_user') {
        Stop-Exp001 "current_user가 lab_user가 아닙니다: $actualUser"
    }
    if ($actualIsolation -ne 'read committed') {
        Stop-Exp001 "transaction isolation이 read committed가 아닙니다: $actualIsolation"
    }
}

function Assert-DbIdentityGate {
    Assert-ConfiguredDbIdentity
    Assert-ActualDbGate
}

function Assert-DestructiveResetGate {
    Assert-DestructiveResetApproved
    Assert-ConfiguredDbIdentity
    Assert-ActualDbGate
}

function Reset-BenchmarkTable {
    Assert-DestructiveResetGate
    Invoke-Psql -Sql 'TRUNCATE TABLE benchmark_record RESTART IDENTITY;' | Out-Null
}

function Assert-BenchmarkTableEmpty {
    $rowCount = Invoke-Psql -Sql 'SELECT COUNT(*) FROM benchmark_record;' -Query
    if ($rowCount -ne '0') {
        Stop-Exp001 "reset 이후 benchmark_record row count가 0이 아닙니다: $rowCount"
    }
}

function Invoke-ResponseValidation {
    param(
        [string] $ExpectedPath,
        [string] $FilePath,
        [int] $ExpectedCount
    )

    $jq = Require-Jq
    & $jq -e --arg expectedPath $ExpectedPath --argjson expectedCount $ExpectedCount -f $Script:ValidateResponseFilter $FilePath *> $null
    if ($LASTEXITCODE -ne 0) {
        Stop-Exp001 "response JSON gate를 통과하지 못했습니다: $FilePath"
    }
}

function Invoke-BenchmarkEndpoint {
    param(
        [string] $PathName,
        [string] $OutputPath,
        [int] $Count
    )

    if (Test-Path -LiteralPath $OutputPath) {
        Stop-Exp001 "final output file이 이미 존재합니다: $OutputPath"
    }

    $tempPath = "$OutputPath.tmp.$PID"
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue

    try {
        $url = "$(Get-ConfigValue 'BASE_URL')/internal/exp-001/$PathName"
        $body = "{`"count`":$Count}"
        $response = Invoke-WebRequest -Uri $url `
            -Method Post `
            -ContentType 'application/json' `
            -Body $body `
            -TimeoutSec ([int] (Get-ConfigValue 'REQUEST_TIMEOUT_SECONDS')) `
            -UseBasicParsing `
            -ErrorAction Stop

        if ([int] $response.StatusCode -lt 200 -or [int] $response.StatusCode -ge 300) {
            Stop-Exp001 "HTTP status가 성공 범위가 아닙니다: $($response.StatusCode)"
        }

        $null = $response.Content | ConvertFrom-Json
        [System.IO.File]::WriteAllText($tempPath, [string] $response.Content, $Script:Utf8NoBom)
        Invoke-ResponseValidation -ExpectedPath $PathName -FilePath $tempPath -ExpectedCount $Count

        if (Test-Path -LiteralPath $OutputPath) {
            Stop-Exp001 "검증 후 final output file이 이미 존재합니다: $OutputPath"
        }

        [System.IO.File]::Move($tempPath, $OutputPath)
    } catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Invoke-Cooldown {
    $seconds = [int] (Get-ConfigValue 'COOLDOWN_SECONDS')
    if ($seconds -gt 0) {
        Write-Log "cooldown ${seconds}s"
        Start-Sleep -Seconds $seconds
    }
}

function Get-ShortGitSha {
    $sha = & git -C $Script:ProjectRootAbs rev-parse --short HEAD
    if ($LASTEXITCODE -ne 0) {
        Stop-Exp001 'short Git SHA를 확인하지 못했습니다.'
    }
    return $sha.Trim()
}

function New-RunId {
    $timestamp = [DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'")
    return "$timestamp-$(Get-ShortGitSha)"
}

function Quote-ProcessArgument {
    param([string] $Value)
    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function Convert-ProcessCreationDateToUtcTicks {
    param([AllowNull()] [object] $CreationDate)

    if ($null -eq $CreationDate) {
        throw 'process CreationDate가 비어 있습니다.'
    }

    if ($CreationDate -is [DateTime]) {
        $utcDateTime = ([DateTime] $CreationDate).ToUniversalTime()
    } elseif ($CreationDate -is [DateTimeOffset]) {
        $utcDateTime = ([DateTimeOffset] $CreationDate).UtcDateTime
    } elseif ($CreationDate -is [string]) {
        $value = ([string] $CreationDate).Trim()
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw 'process CreationDate 문자열이 비어 있습니다.'
        }
        if ($value -notmatch '^\d{14}\.\d{6}[\+\-]\d{3}$') {
            throw "process CreationDate가 DMTF date 형식이 아닙니다: $value"
        }

        try {
            $utcDateTime = [System.Management.ManagementDateTimeConverter]::ToDateTime($value).ToUniversalTime()
        } catch {
            throw "process CreationDate DMTF 값을 UTC로 변환할 수 없습니다: $value ($($_.Exception.Message))"
        }
    } else {
        throw "지원하지 않는 process CreationDate type입니다: $($CreationDate.GetType().FullName)"
    }

    return $utcDateTime.Ticks.ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function New-ProcessStartIdentity {
    param(
        [AllowNull()] [object] $CreationDate,
        [string] $ProcessName,
        [string] $CommandLine
    )

    if ([string]::IsNullOrWhiteSpace($ProcessName)) {
        throw 'process name이 비어 있어 identity를 생성할 수 없습니다.'
    }
    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        throw 'process command line이 비어 있어 identity를 생성할 수 없습니다.'
    }

    $startTimeUtcTicks = Convert-ProcessCreationDateToUtcTicks -CreationDate $CreationDate
    return [pscustomobject] @{
        StartTimeUtcTicks = $startTimeUtcTicks
        Value = "$startTimeUtcTicks|$ProcessName|$CommandLine"
    }
}

function Get-LiveJavaProcessInfo {
    param([int] $PidValue)

    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$PidValue" -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return $null
    }

    $processName = [string] $process.Name
    $commandLine = [string] $process.CommandLine
    if ($processName -notmatch '^java(w)?\.exe$' -or [string]::IsNullOrWhiteSpace($commandLine)) {
        return $null
    }

    $identity = New-ProcessStartIdentity -CreationDate $process.CreationDate -ProcessName $processName -CommandLine $commandLine

    return [pscustomobject] @{
        Pid = [int] $process.ProcessId
        ProcessName = $processName
        CommandLine = $commandLine
        StartTimeUtcTicks = $identity.StartTimeUtcTicks
        ProcessStartIdentity = $identity.Value
    }
}

function New-ApplicationState {
    param(
        [int] $PidValue,
        [string] $JarPath,
        [string] $Profile = ''
    )

    if ([string]::IsNullOrWhiteSpace($Profile)) {
        $Profile = Get-ConfigValue 'SPRING_PROFILE'
    }

    $processInfo = Get-LiveJavaProcessInfo -PidValue $PidValue
    if ($null -eq $processInfo) {
        throw "시작한 PID가 Java application으로 확인되지 않습니다: $PidValue"
    }

    return [pscustomobject] ([ordered] @{
        pid = $PidValue
        processStartIdentity = $processInfo.ProcessStartIdentity
        jarPath = $JarPath
        profile = $Profile
        baseUrl = (Get-ConfigValue 'BASE_URL')
        platform = $Script:PlatformName
    })
}

function Write-ApplicationState {
    param([object] $State)

    if ($null -eq $State) {
        throw 'application state metadata가 비어 있습니다.'
    }

    $tempPath = "$Script:ApplicationStateFile.tmp.$PID"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue

    try {
        [System.IO.File]::WriteAllText($tempPath, ($State | ConvertTo-Json -Depth 3), $utf8NoBom)
        if (Test-Path -LiteralPath $Script:ApplicationStateFile) {
            throw "application state final path가 이미 존재합니다: $Script:ApplicationStateFile"
        }
        [System.IO.File]::Move($tempPath, $Script:ApplicationStateFile)
    } catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Read-ApplicationState {
    if (-not (Test-Path -LiteralPath $Script:ApplicationStateFile)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $Script:ApplicationStateFile -Encoding UTF8 -Raw | ConvertFrom-Json
    } catch {
        Stop-Exp001 "application state JSON을 읽을 수 없습니다. signal을 보내지 않습니다: $Script:ApplicationStateFile"
    }
}

function Clear-ApplicationState {
    Remove-Item -LiteralPath $Script:ApplicationStateFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Script:StateDir 'app.pid') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Script:StateDir 'application.metadata') -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Script:StateDir) {
        Get-ChildItem -LiteralPath $Script:StateDir -Filter 'application.json.tmp.*' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

function Test-ExpectedApplicationProcess {
    param([object] $State)

    if ($null -eq $State) {
        return $false
    }
    if ([string] $State.platform -ne $Script:PlatformName) {
        return $false
    }
    if ([string] $State.profile -ne 'exp001') {
        return $false
    }
    if ([string] $State.baseUrl -ne (Get-ConfigValue 'BASE_URL')) {
        return $false
    }

    $processInfo = Get-LiveJavaProcessInfo -PidValue ([int] $State.pid)
    if ($null -eq $processInfo) {
        return $false
    }
    if ($processInfo.ProcessStartIdentity -ne [string] $State.processStartIdentity) {
        return $false
    }
    if ($processInfo.CommandLine.IndexOf([string] $State.jarPath, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        return $false
    }
    if ($processInfo.CommandLine.IndexOf("--spring.profiles.active=$($State.profile)", [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        return $false
    }

    return $true
}

function Invoke-StartupFailureCleanup {
    param(
        [string] $Reason,
        [object] $State = $null,
        [int] $PidValue = 0,
        [string] $JarPath = '',
        [string] $Profile = ''
    )

    Write-Warn "startup 실패로 시작한 JVM 정리를 시도합니다: $Reason"
    $cleanupState = $State
    if ($null -eq $cleanupState) {
        $cleanupState = Read-ApplicationState
    }
    if ($null -eq $cleanupState -and $PidValue -gt 0 -and -not [string]::IsNullOrWhiteSpace($JarPath)) {
        try {
            $cleanupState = New-ApplicationState -PidValue $PidValue -JarPath $JarPath -Profile $Profile
        } catch {
            Clear-ApplicationState
            Write-Warn "state 없이 시작한 JVM identity를 확인하지 못해 cleanup signal을 보내지 않습니다: $($_.Exception.Message)"
            return
        }
    }
    if ($null -eq $cleanupState) {
        Write-Warn 'application state가 없어 cleanup할 process를 확인할 수 없습니다.'
        return
    }

    $pidValue = [int] $cleanupState.pid
    $liveProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$pidValue" -ErrorAction SilentlyContinue
    if ($null -eq $liveProcess) {
        Clear-ApplicationState
        Write-Warn "startup 실패 시점에 PID가 이미 종료되어 state를 정리했습니다: $pidValue"
        return
    }

    if (-not (Test-ExpectedApplicationProcess -State $cleanupState)) {
        Write-Warn "PID가 기대한 EXP-001 application JVM과 일치하지 않아 signal을 보내지 않습니다: $pidValue"
        return
    }

    try {
        Stop-Process -Id $pidValue -ErrorAction Stop
    } catch {
        Write-Warn "startup cleanup 정상 종료 signal 전송에 실패했습니다: $($_.Exception.Message)"
        return
    }

    $deadline = [DateTime]::UtcNow.AddSeconds([int] (Get-ConfigValue 'STOP_TIMEOUT_SECONDS'))
    while ([DateTime]::UtcNow -lt $deadline) {
        $liveProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$pidValue" -ErrorAction SilentlyContinue
        if ($null -eq $liveProcess) {
            Clear-ApplicationState
            Write-Warn 'startup 실패 후 application JVM을 정상 종료하고 state를 정리했습니다.'
            return
        }
        if (-not (Test-ExpectedApplicationProcess -State $cleanupState)) {
            Write-Warn "startup cleanup 대기 중 PID가 기대한 process와 달라져 강제 종료하지 않습니다: $pidValue"
            return
        }
        Start-Sleep -Seconds 1
    }

    if (-not (Test-ExpectedApplicationProcess -State $cleanupState)) {
        Write-Warn "startup cleanup 강제 종료 직전 PID가 기대한 process와 달라져 강제 종료하지 않습니다: $pidValue"
        return
    }

    try {
        Stop-Process -Id $pidValue -Force -ErrorAction Stop
        Clear-ApplicationState
        Write-Warn 'startup 실패 후 application JVM을 강제 종료하고 state를 정리했습니다.'
    } catch {
        Write-Warn "startup cleanup 강제 종료에 실패했습니다: $($_.Exception.Message)"
    }
}

function Assert-OfficialSettings {
    if ([int] (Get-ConfigValue 'EXPECTED_INPUT_COUNT') -ne 50000) {
        Stop-Exp001 "official EXPECTED_INPUT_COUNT는 정확히 50000이어야 합니다: $(Get-ConfigValue 'EXPECTED_INPUT_COUNT')"
    }
    if ([int] (Get-ConfigValue 'OFFICIAL_ROUNDS') -ne 6) {
        Stop-Exp001 "official OFFICIAL_ROUNDS는 정확히 6이어야 합니다: $(Get-ConfigValue 'OFFICIAL_ROUNDS')"
    }
}
