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
$Script:ValidateResponseFilter = Join-Path $Script:Exp001Root 'shared\validate-response.jq'
$Script:SummaryFilter = Join-Path $Script:Exp001Root 'shared\summary.jq'
$Script:PostgresService = 'persistence-lab-postgres'
$Script:PlatformName = 'windows'
$Script:Config = @{}
$Script:ProjectRootAbs = $null
$Script:ResultRootAbs = $null

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

function Get-JavaExecutablePath {
    $commands = @(Get-Command 'java.exe' -CommandType Application -ErrorAction SilentlyContinue)
    if ($commands.Count -eq 0) {
        Stop-Exp001 '필수 command를 찾을 수 없습니다: java'
    }

    $command = $commands[0]
    $javaPath = [string] $command.Path
    if ([string]::IsNullOrWhiteSpace($javaPath)) {
        $javaPath = [string] $command.Source
    }
    if ([string]::IsNullOrWhiteSpace($javaPath)) {
        $javaPath = [string] $command.Definition
    }
    if ([string]::IsNullOrWhiteSpace($javaPath) -or -not (Test-Path -LiteralPath $javaPath)) {
        Stop-Exp001 "java.exe 경로를 확인할 수 없습니다: $javaPath"
    }

    return $javaPath
}

function Invoke-JavaVersionCommand {
    param([string] $JavaPath)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $JavaPath
    $startInfo.Arguments = '-version'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        [void] $process.Start()
    } catch {
        Stop-Exp001 "java -version 실행에 실패했습니다: $($_.Exception.Message)"
    }

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject] @{
        Stdout = $stdout
        Stderr = $stderr
        ExitCode = $process.ExitCode
    }
}

function Get-JavaMajorVersion {
    param([string] $VersionText)

    if ([string]::IsNullOrWhiteSpace($VersionText)) {
        return $null
    }

    $match = [regex]::Match($VersionText, 'version\s+"([0-9]+)(?:[._][^"]*)?"')
    if (-not $match.Success) {
        return $null
    }

    $major = 0
    if (-not [int]::TryParse($match.Groups[1].Value, [ref] $major)) {
        return $null
    }

    return $major
}

function Require-DockerCompose {
    Require-Command 'docker'
    & docker compose version *> $null
    if ($LASTEXITCODE -ne 0) {
        Stop-Exp001 'docker compose를 사용할 수 없습니다. Docker Desktop과 Compose plugin을 확인하세요.'
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

function Assert-Java21 {
    $javaPath = Get-JavaExecutablePath
    $result = Invoke-JavaVersionCommand -JavaPath $javaPath
    $versionText = @($result.Stdout, $result.Stderr) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() } |
        Out-String
    $versionText = $versionText.Trim()

    if ($result.ExitCode -ne 0) {
        Stop-Exp001 "java -version 실행이 실패했습니다. exit code: $($result.ExitCode), output: $versionText"
    }

    $majorVersion = Get-JavaMajorVersion -VersionText $versionText
    if ($null -eq $majorVersion) {
        Stop-Exp001 "Java version 문자열을 해석할 수 없습니다: $versionText"
    }
    if ($majorVersion -ne 21) {
        Stop-Exp001 "Java 21 runtime이 필요합니다. 현재 java -version: $versionText"
    }
}

function Get-ServerPort {
    $serverPort = [Environment]::GetEnvironmentVariable('SERVER_PORT')
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

function Assert-ConfiguredDbGate {
    if ((Get-ConfigValue 'ALLOW_DESTRUCTIVE_RESET') -ne 'true') {
        Stop-Exp001 'ALLOW_DESTRUCTIVE_RESET가 true가 아니므로 reset과 run을 중단합니다.'
    }

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

function Assert-DbSafetyGate {
    Assert-ConfiguredDbGate
    Assert-ActualDbGate
}

function Reset-BenchmarkTable {
    Assert-DbSafetyGate
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

    $startTime = [System.Management.ManagementDateTimeConverter]::ToDateTime($process.CreationDate).ToUniversalTime().ToString('o')
    $identity = "$startTime|$processName|$commandLine"

    return [pscustomobject] @{
        Pid = [int] $process.ProcessId
        ProcessName = $processName
        CommandLine = $commandLine
        StartTimeUtc = $startTime
        ProcessStartIdentity = $identity
    }
}

function Write-ApplicationState {
    param(
        [int] $PidValue,
        [string] $JarPath
    )

    $processInfo = Get-LiveJavaProcessInfo -PidValue $PidValue
    if ($null -eq $processInfo) {
        Stop-Exp001 "시작한 PID가 Java application으로 확인되지 않습니다: $PidValue"
    }

    $state = [ordered] @{
        pid = $PidValue
        processStartIdentity = $processInfo.ProcessStartIdentity
        jarPath = $JarPath
        profile = (Get-ConfigValue 'SPRING_PROFILE')
        baseUrl = (Get-ConfigValue 'BASE_URL')
        platform = $Script:PlatformName
    }

    $tempPath = "$Script:ApplicationStateFile.tmp.$PID"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempPath, ($state | ConvertTo-Json -Depth 3), $utf8NoBom)
    if (Test-Path -LiteralPath $Script:ApplicationStateFile) {
        Remove-Item -LiteralPath $Script:ApplicationStateFile -Force
    }
    [System.IO.File]::Move($tempPath, $Script:ApplicationStateFile)
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
    param([string] $Reason)

    Write-Warn "startup 실패로 시작한 JVM 정리를 시도합니다: $Reason"
    $state = Read-ApplicationState
    if ($null -eq $state) {
        Write-Warn 'application state가 없어 cleanup할 process를 확인할 수 없습니다.'
        return
    }

    $pidValue = [int] $state.pid
    $liveProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$pidValue" -ErrorAction SilentlyContinue
    if ($null -eq $liveProcess) {
        Clear-ApplicationState
        Write-Warn "startup 실패 시점에 PID가 이미 종료되어 state를 정리했습니다: $pidValue"
        return
    }

    if (-not (Test-ExpectedApplicationProcess -State $state)) {
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
        if (-not (Test-ExpectedApplicationProcess -State $state)) {
            Write-Warn "startup cleanup 대기 중 PID가 기대한 process와 달라져 강제 종료하지 않습니다: $pidValue"
            return
        }
        Start-Sleep -Seconds 1
    }

    if (-not (Test-ExpectedApplicationProcess -State $state)) {
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
