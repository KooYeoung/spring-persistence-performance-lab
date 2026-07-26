param(
    [string] $Action = 'help',
    [string] $RunDirectory = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')
Initialize-Exp001

function Show-Help {
    Write-Host 'EXP-001 Windows harness'
    Write-Host ''
    Write-Host '사용법: scripts\exp-001\windows\exp001.cmd <action> [run-directory]'
    Write-Host ''
    Write-Host 'Actions:'
    Write-Host '  prepare    .env, .state, result root, portable jq와 locked JDK를 준비한다.'
    Write-Host '  start      bootJar를 생성하고 exp001 profile application JVM을 시작한다.'
    Write-Host '  check      endpoint, Docker Compose PostgreSQL identity와 Safety Gate를 확인한다.'
    Write-Host '  benchmark  warm-up과 official 6 round를 실행한다.'
    Write-Host '  summary    official JSON 12개를 검증한 뒤 summary.md를 생성한다.'
    Write-Host '  stop       state가 가리키는 exp001 application JVM만 종료한다.'
    Write-Host '  help       도움말을 출력한다.'
}

function Invoke-Prepare {
    Assert-ProjectRoot
    Ensure-Directories
    Require-Command 'git'

    if (-not (Test-Path -LiteralPath $Script:EnvFile)) {
        Copy-Item -LiteralPath (Join-Path $Script:Exp001Root '.env.example') -Destination $Script:EnvFile
        Write-Log ".env 파일을 생성했습니다: $Script:EnvFile"
    } else {
        Write-Log "기존 .env 파일을 보존합니다: $Script:EnvFile"
    }

    Install-OrVerify-Jq | Out-Null
    Resolve-LockedJdk -AllowDownload | Out-Null
    Require-DockerCompose
    Write-Log '공식 실행 전 .env 값을 확인하세요. destructive reset은 ALLOW_DESTRUCTIVE_RESET=true일 때만 허용됩니다.'
}

function Invoke-Start {
    Assert-ProjectRoot
    Ensure-Directories
    $jdk = Resolve-LockedJdk
    Require-Command 'git'
    Require-DockerCompose
    Require-Jq | Out-Null

    if ((Get-ConfigValue 'SPRING_PROFILE') -ne 'exp001') {
        Stop-Exp001 "EXP-001 application은 exp001 profile로만 시작할 수 있습니다: $(Get-ConfigValue 'SPRING_PROFILE')"
    }

    $state = Read-ApplicationState
    if ($null -ne $state) {
        if (Test-ExpectedApplicationProcess -State $state) {
            Stop-Exp001 "이미 실행 중인 EXP-001 application PID가 있습니다: $($state.pid)"
        }

        $liveProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($state.pid)" -ErrorAction SilentlyContinue
        if ($null -ne $liveProcess) {
            Stop-Exp001 "stale 또는 mismatched state입니다. PID 재사용 가능성이 있어 시작하지 않습니다: $Script:ApplicationStateFile"
        }

        Clear-ApplicationState
    }

    $currentStatus = Get-HttpStatus -Url "$(Get-ConfigValue 'BASE_URL')/internal/exp-001/jpa"
    if ($currentStatus -ne '000') {
        Stop-Exp001 "BASE_URL에 이미 응답하는 process가 있습니다. HTTP status: $currentStatus"
    }

    $gradleWrapper = Join-Path $Script:ProjectRootAbs 'gradlew.bat'
    if (-not (Test-Path -LiteralPath $gradleWrapper)) {
        Stop-Exp001 "Gradle Wrapper를 찾을 수 없습니다: $gradleWrapper"
    }

    Write-Log 'bootJar를 생성합니다.'
    Invoke-WithJdkEnvironment -Jdk $jdk -Command {
        & $gradleWrapper --no-daemon --max-workers=1 bootJar
    }
    if ($LASTEXITCODE -ne 0) {
        Stop-Exp001 'bootJar 생성에 실패했습니다.'
    }

    $jarDir = Join-Path $Script:ProjectRootAbs 'build\libs'
    $bootJars = @(Get-ChildItem -LiteralPath $jarDir -Filter '*.jar' -File | Where-Object { $_.Name -notlike '*plain.jar' } | Sort-Object Name)
    if ($bootJars.Count -ne 1) {
        Stop-Exp001 "실행 가능한 boot jar가 정확히 하나가 아닙니다: $($bootJars.Count)"
    }
    $bootJar = (Resolve-Path -LiteralPath $bootJars[0].FullName).ProviderPath

    $serverPort = Get-ServerPort
    $oldServerPort = [Environment]::GetEnvironmentVariable('SERVER_PORT')
    [Environment]::SetEnvironmentVariable('SERVER_PORT', $serverPort, 'Process')

    try {
        $argumentList = @(
            '-Xms2g',
            '-Xmx2g',
            '-XX:+UseG1GC',
            '-Duser.timezone=UTC',
            '-jar',
            (Quote-ProcessArgument -Value $bootJar),
            "--spring.profiles.active=$(Get-ConfigValue 'SPRING_PROFILE')"
        ) -join ' '

        Write-Log "application을 exp001 profile로 시작합니다. stdout: $Script:ApplicationStdoutLog stderr: $Script:ApplicationStderrLog"
        $process = Start-Process -FilePath $jdk.JavaPath `
            -ArgumentList $argumentList `
            -WorkingDirectory $Script:ProjectRootAbs `
            -RedirectStandardOutput $Script:ApplicationStdoutLog `
            -RedirectStandardError $Script:ApplicationStderrLog `
            -WindowStyle Hidden `
            -PassThru
    } finally {
        if ([string]::IsNullOrEmpty($oldServerPort)) {
            [Environment]::SetEnvironmentVariable('SERVER_PORT', $null, 'Process')
        } else {
            [Environment]::SetEnvironmentVariable('SERVER_PORT', $oldServerPort, 'Process')
        }
    }

    Start-Sleep -Milliseconds 500
    $applicationState = $null
    try {
        $applicationState = New-ApplicationState -PidValue $process.Id -JarPath $bootJar -Profile (Get-ConfigValue 'SPRING_PROFILE')
        Write-ApplicationState -State $applicationState
    } catch {
        $failureMessage = "application state 생성에 실패했습니다: $($_.Exception.Message)"
        Invoke-StartupFailureCleanup -Reason $failureMessage `
            -State $applicationState `
            -PidValue $process.Id `
            -JarPath $bootJar `
            -Profile (Get-ConfigValue 'SPRING_PROFILE')
        Stop-Exp001 $failureMessage
    }
    Write-Log "application PID: $($process.Id)"

    $deadline = [DateTime]::UtcNow.AddSeconds([int] (Get-ConfigValue 'STARTUP_TIMEOUT_SECONDS'))
    while ([DateTime]::UtcNow -lt $deadline) {
        if ((Get-HttpStatus -Url "$(Get-ConfigValue 'BASE_URL')/internal/exp-001/jpa") -eq '405') {
            Write-Log 'exp001 profiling endpoint 등록을 확인했습니다.'
            return
        }
        if (-not (Test-ExpectedApplicationProcess -State (Read-ApplicationState))) {
            $failureMessage = "application process가 시작 중 종료되었거나 identity가 변경되었습니다. log를 확인하세요: $Script:ApplicationStderrLog"
            Invoke-StartupFailureCleanup -Reason $failureMessage
            Stop-Exp001 $failureMessage
        }
        Start-Sleep -Seconds 2
    }

    $failureMessage = "startup timeout이 발생했습니다. log를 확인하세요: $Script:ApplicationStderrLog"
    Invoke-StartupFailureCleanup -Reason $failureMessage
    Stop-Exp001 $failureMessage
}

function Invoke-Check {
    Assert-ProjectRoot
    Ensure-Directories
    Resolve-LockedJdk | Out-Null
    Require-Command 'git'
    Require-DockerCompose
    Require-Jq | Out-Null

    Write-Log "project root: $Script:ProjectRootAbs"
    Write-Log "result root: $Script:ResultRootAbs"
    Write-Log "PostgreSQL service: $Script:PostgresService"

    Assert-AppEndpointRegistered
    Write-Log "application reachable: $(Get-ConfigValue 'BASE_URL')"

    Assert-DbIdentityGate
    Write-Log 'PostgreSQL configured identity와 actual identity를 확인했습니다.'
    Write-Log 'official timing 중 debugger, SQL logging, Hibernate statistics, profiler는 OFF 상태로 운영하세요.'
}

function Invoke-BenchmarkStep {
    param(
        [string] $PathName,
        [string] $OutputPath,
        [string] $Label
    )

    if (Test-Path -LiteralPath $OutputPath) {
        Stop-Exp001 "final output file이 이미 존재합니다: $OutputPath"
    }

    Reset-BenchmarkTable
    Assert-BenchmarkTableEmpty
    Write-Log "${Label}: $PathName endpoint 호출"
    Invoke-BenchmarkEndpoint -PathName $PathName -OutputPath $OutputPath -Count ([int] (Get-ConfigValue 'EXPECTED_INPUT_COUNT'))
    Invoke-Cooldown
}

function Invoke-Benchmark {
    Assert-ProjectRoot
    Ensure-Directories
    Resolve-LockedJdk | Out-Null
    Require-Command 'git'
    Require-DockerCompose
    Require-Jq | Out-Null
    Assert-OfficialSettings
    Assert-AppEndpointRegistered

    $runId = New-RunId
    $runDir = Join-Path $Script:ResultRootAbs $runId
    if (Test-Path -LiteralPath $runDir) {
        Stop-Exp001 "run directory가 이미 존재합니다: $runDir"
    }
    $warmupDir = Join-Path $runDir 'warmup'
    $officialDir = Join-Path $runDir 'official'
    New-Item -ItemType Directory -Force -Path $warmupDir, $officialDir | Out-Null

    Write-Log "EXP-001 run ID: $runId"
    Write-Log 'warm-up 시작'
    Invoke-BenchmarkStep -PathName 'jpa' -OutputPath (Join-Path $warmupDir '01-jpa-warmup.json') -Label 'warm-up JPA'
    Invoke-BenchmarkStep -PathName 'jdbc' -OutputPath (Join-Path $warmupDir '02-jdbc-warmup.json') -Label 'warm-up JDBC'

    Write-Log 'official rounds 시작'
    for ($round = 1; $round -le 6; $round++) {
        $roundText = '{0:D2}' -f $round
        if (($round % 2) -eq 1) {
            Invoke-BenchmarkStep -PathName 'jpa' -OutputPath (Join-Path $officialDir "round-$roundText-01-jpa.json") -Label "round $round position 1"
            Invoke-BenchmarkStep -PathName 'jdbc' -OutputPath (Join-Path $officialDir "round-$roundText-02-jdbc.json") -Label "round $round position 2"
        } else {
            Invoke-BenchmarkStep -PathName 'jdbc' -OutputPath (Join-Path $officialDir "round-$roundText-01-jdbc.json") -Label "round $round position 1"
            Invoke-BenchmarkStep -PathName 'jpa' -OutputPath (Join-Path $officialDir "round-$roundText-02-jpa.json") -Label "round $round position 2"
        }
    }

    Write-Log "official JSON 저장 완료: $officialDir"
}

function Get-LatestRunDirectory {
    if (-not (Test-Path -LiteralPath $Script:ResultRootAbs)) {
        return ''
    }
    $dirs = @(Get-ChildItem -LiteralPath $Script:ResultRootAbs -Directory | Sort-Object Name)
    if ($dirs.Count -eq 0) {
        return ''
    }
    return $dirs[$dirs.Count - 1].FullName
}

function Invoke-Summary {
    Assert-ProjectRoot
    Ensure-Directories
    Require-Jq | Out-Null
    Assert-OfficialSettings

    $runDir = $RunDirectory
    if ([string]::IsNullOrWhiteSpace($runDir)) {
        $runDir = Get-LatestRunDirectory
    }
    if ([string]::IsNullOrWhiteSpace($runDir)) {
        Stop-Exp001 'summary를 생성할 run directory를 찾지 못했습니다.'
    }
    $runDir = (Resolve-Path -LiteralPath $runDir).ProviderPath
    $officialDir = Join-Path $runDir 'official'
    if (-not (Test-Path -LiteralPath $officialDir)) {
        Stop-Exp001 "official JSON directory가 없습니다: $officialDir"
    }

    $jsonFiles = @(Get-ChildItem -LiteralPath $officialDir -Filter '*.json' -File | Sort-Object Name)
    if ($jsonFiles.Count -ne 12) {
        Stop-Exp001 "official JSON 파일 수가 정확히 12개가 아닙니다: $($jsonFiles.Count)"
    }

    $summaryFile = Join-Path $runDir 'summary.md'
    $tempSummary = "$summaryFile.tmp.$PID"
    Remove-Item -LiteralPath $tempSummary -Force -ErrorAction SilentlyContinue

    try {
        $jq = Require-Jq
        $summaryLines = @(& $jq -r --argjson expectedCount ([int] (Get-ConfigValue 'EXPECTED_INPUT_COUNT')) -s -f $Script:SummaryFilter @($jsonFiles.FullName))
        $jqExitCode = $LASTEXITCODE
        if ($jqExitCode -ne 0) {
            Stop-Exp001 'official JSON gate 또는 summary 계산에 실패했습니다.'
        }
        $newline = [Environment]::NewLine
        $summaryText = [string]::Join($newline, [string[]] $summaryLines)
        if ($summaryLines.Count -gt 0) {
            $summaryText += $newline
        }
        [System.IO.File]::WriteAllText($tempSummary, $summaryText, $Script:Utf8NoBom)
        Move-Item -LiteralPath $tempSummary -Destination $summaryFile -Force
    } catch {
        Remove-Item -LiteralPath $tempSummary -Force -ErrorAction SilentlyContinue
        throw
    }

    Write-Log "summary 생성 완료: $summaryFile"
}

function New-StopReadinessResult {
    param(
        [ValidateSet('READY', 'PROCESS_FOUND', 'PROCESS_UNKNOWN', 'PORT_TARGET_PID', 'PORT_OTHER_PID', 'PORT_UNKNOWN')] [string] $Status,
        [string] $Message = ''
    )

    return [pscustomobject] ([ordered] @{
        status = $Status
        message = $Message
    })
}

function Get-StopReadiness {
    param([int] $PidValue)

    $processQuery = Get-Exp001ProcessQuery -PidValue $PidValue -VerifyWithGetProcess
    if ($processQuery.status -eq 'UNKNOWN') {
        return New-StopReadinessResult -Status 'PROCESS_UNKNOWN' -Message "process 조회 상태를 확정할 수 없습니다: $($processQuery.error)"
    }
    if ($processQuery.status -eq 'FOUND') {
        return New-StopReadinessResult -Status 'PROCESS_FOUND' -Message "target process가 아직 실행 중입니다: $PidValue"
    }

    $serverPort = Get-ServerPort
    $portQuery = Get-Exp001PortQuery -Port $serverPort -TargetPid $PidValue
    if ($portQuery.status -eq 'UNKNOWN') {
        return New-StopReadinessResult -Status 'PORT_UNKNOWN' -Message "port $serverPort listener 상태를 확정할 수 없습니다: $($portQuery.error)"
    }
    if ($portQuery.status -eq 'FREE') {
        return New-StopReadinessResult -Status 'READY' -Message "target process가 없고 port $serverPort listener가 없습니다."
    }

    $ownerText = Format-Exp001PortOwnerPids -OwnerPids $portQuery.ownerPids
    if ($portQuery.status -eq 'TARGET_PID') {
        return New-StopReadinessResult -Status 'PORT_TARGET_PID' -Message "target PID가 port $serverPort listener를 유지하고 있습니다: $ownerText"
    }

    return New-StopReadinessResult -Status 'PORT_OTHER_PID' -Message "다른 PID가 port $serverPort listener를 소유하고 있습니다: $ownerText"
}

function Complete-StopCleanup {
    param([string] $Message)

    Clear-ApplicationState
    if (Test-Path -LiteralPath $Script:ApplicationStateFile) {
        Stop-Exp001 "application state 삭제를 확인하지 못했습니다: $Script:ApplicationStateFile"
    }

    Write-Log $Message
}

function Complete-StopIfReady {
    param(
        [int] $PidValue,
        [string] $SuccessMessage,
        [string] $FailurePrefix
    )

    $readiness = Get-StopReadiness -PidValue $PidValue
    if ($readiness.status -eq 'READY') {
        Complete-StopCleanup -Message $SuccessMessage
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($FailurePrefix)) {
        Stop-Exp001 "$FailurePrefix $($readiness.message)"
    }

    return $false
}

function Invoke-Stop {
    Ensure-Directories

    $state = Read-ApplicationState
    if ($null -eq $state) {
        Write-Log 'application state 파일이 없습니다. 종료할 application process가 없습니다.'
        return
    }

    $pidValue = [int] $state.pid
    $processQuery = Get-Exp001ProcessQuery -PidValue $pidValue -VerifyWithGetProcess
    if ($processQuery.status -eq 'UNKNOWN') {
        Stop-Exp001 "PID 상태를 확인하지 못해 state를 보존합니다: $pidValue ($($processQuery.error))"
    }
    if ($processQuery.status -eq 'ABSENT') {
        Complete-StopIfReady -PidValue $pidValue `
            -SuccessMessage "PID가 실행 중이 아니고 port가 비어 있어 state를 정리했습니다: $pidValue" `
            -FailurePrefix "PID는 실행 중이 아니지만 cleanup 완료 조건이 충족되지 않아 state를 보존합니다:" | Out-Null
        return
    }

    if (-not (Test-ExpectedApplicationProcessInfo -State $state -Process $processQuery.process)) {
        Stop-Exp001 "PID가 기대한 EXP-001 application JVM과 일치하지 않습니다. PID 재사용 가능성이 있어 signal을 보내지 않습니다: $pidValue"
    }

    Write-Log "application 정상 종료 signal을 보냅니다. PID: $pidValue"
    try {
        Stop-Process -Id $pidValue -ErrorAction Stop
    } catch {
        $stopError = $_.Exception.Message
        Complete-StopIfReady -PidValue $pidValue `
            -SuccessMessage 'application이 signal 전송 race 중 이미 종료되어 state를 정리했습니다.' `
            -FailurePrefix "application 정상 종료 signal 전송에 실패했고 cleanup 완료도 확인되지 않았습니다: $stopError;" | Out-Null
        return
    }

    $deadline = [DateTime]::UtcNow.AddSeconds([int] (Get-ConfigValue 'STOP_TIMEOUT_SECONDS'))
    while ([DateTime]::UtcNow -lt $deadline) {
        $readiness = Get-StopReadiness -PidValue $pidValue
        if ($readiness.status -eq 'READY') {
            Complete-StopCleanup -Message 'application이 정상 종료되었습니다.'
            return
        }
        if ($readiness.status -ne 'PROCESS_FOUND') {
            Stop-Exp001 "application cleanup 완료 조건이 충족되지 않아 state를 보존합니다: $($readiness.message)"
        }

        $processQuery = Get-Exp001ProcessQuery -PidValue $pidValue -VerifyWithGetProcess
        if ($processQuery.status -eq 'UNKNOWN') {
            Stop-Exp001 "종료 대기 중 PID 상태를 확인하지 못해 state를 보존합니다: $pidValue ($($processQuery.error))"
        }
        if ($processQuery.status -eq 'FOUND' -and -not (Test-ExpectedApplicationProcessInfo -State $state -Process $processQuery.process)) {
            Stop-Exp001 "종료 대기 중 PID가 기대한 process와 달라졌습니다. 강제 종료하지 않습니다: $pidValue"
        }
        Start-Sleep -Seconds 1
    }

    $processQuery = Get-Exp001ProcessQuery -PidValue $pidValue -VerifyWithGetProcess
    if ($processQuery.status -eq 'UNKNOWN') {
        Stop-Exp001 "강제 종료 직전 PID 상태를 확인하지 못해 state를 보존합니다: $pidValue ($($processQuery.error))"
    }
    if ($processQuery.status -eq 'ABSENT') {
        Complete-StopIfReady -PidValue $pidValue `
            -SuccessMessage 'application이 force fallback 전에 종료되어 state를 정리했습니다.' `
            -FailurePrefix 'application process는 종료되었지만 cleanup 완료 조건이 충족되지 않아 state를 보존합니다:' | Out-Null
        return
    }
    if (-not (Test-ExpectedApplicationProcessInfo -State $state -Process $processQuery.process)) {
        Stop-Exp001 "강제 종료 직전 PID가 기대한 process와 달라졌습니다. 강제 종료하지 않습니다: $pidValue"
    }

    Write-Warn "정상 종료 timeout으로 강제 종료합니다. PID: $pidValue"
    try {
        Stop-Process -Id $pidValue -Force -ErrorAction Stop
    } catch {
        $forceError = $_.Exception.Message
        Complete-StopIfReady -PidValue $pidValue `
            -SuccessMessage 'application이 force signal race 중 이미 종료되어 state를 정리했습니다.' `
            -FailurePrefix "application 강제 종료에 실패했고 cleanup 완료도 확인되지 않았습니다: $forceError;" | Out-Null
        return
    }

    $forceDeadline = [DateTime]::UtcNow.AddSeconds([int] (Get-ConfigValue 'STOP_TIMEOUT_SECONDS'))
    while ([DateTime]::UtcNow -lt $forceDeadline) {
        $readiness = Get-StopReadiness -PidValue $pidValue
        if ($readiness.status -eq 'READY') {
            Complete-StopCleanup -Message 'application을 강제 종료하고 state를 정리했습니다.'
            return
        }
        if ($readiness.status -ne 'PROCESS_FOUND') {
            Stop-Exp001 "application 강제 종료 후 cleanup 완료 조건이 충족되지 않아 state를 보존합니다: $($readiness.message)"
        }

        $processQuery = Get-Exp001ProcessQuery -PidValue $pidValue -VerifyWithGetProcess
        if ($processQuery.status -eq 'UNKNOWN') {
            Stop-Exp001 "강제 종료 후 PID 상태를 확인하지 못해 state를 보존합니다: $pidValue ($($processQuery.error))"
        }
        if ($processQuery.status -eq 'FOUND' -and -not (Test-ExpectedApplicationProcessInfo -State $state -Process $processQuery.process)) {
            Stop-Exp001 "강제 종료 후 PID가 기대한 process와 달라졌습니다. state를 보존합니다: $pidValue"
        }
        Start-Sleep -Seconds 1
    }

    $readiness = Get-StopReadiness -PidValue $pidValue
    Stop-Exp001 "application 종료 timeout 이후에도 cleanup 완료 조건이 충족되지 않아 state를 보존합니다: $($readiness.message)"
}

try {
    switch ($Action.ToLowerInvariant()) {
        'prepare' { Invoke-Prepare }
        'start' { Invoke-Start }
        'check' { Invoke-Check }
        'benchmark' { Invoke-Benchmark }
        'summary' { Invoke-Summary }
        'stop' { Invoke-Stop }
        'help' { Show-Help }
        default {
            Show-Help
            Stop-Exp001 "알 수 없는 action입니다: $Action"
        }
    }
} catch {
    Stop-Exp001 $_.Exception.Message
}
