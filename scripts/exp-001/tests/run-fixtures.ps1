Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$TestDir = $PSScriptRoot
$ExpRoot = Split-Path -Parent $TestDir
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $ExpRoot)
$FixturesDir = Join-Path $TestDir 'fixtures'
$ExpectedDir = Join-Path $TestDir 'expected'

. (Join-Path $ExpRoot 'windows\Common.ps1')

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

function Assert-ThrowsLike {
    param(
        [scriptblock] $Action,
        [string] $Pattern
    )

    try {
        & $Action
    } catch {
        $message = $_.Exception.Message
        if ($message -notlike "*$Pattern*") {
            Fail-Fixture "unexpected exception. pattern=$Pattern actual=$message"
        }
        return
    }

    Fail-Fixture "expected failure did not occur: $Pattern"
}

function Invoke-NativeProcessToMemoryBytes {
    param(
        [string] $FilePath,
        [string[]] $Arguments
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = Join-ProcessArguments -Arguments $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $memory = New-Object System.IO.MemoryStream

    try {
        [void] $process.Start()
        $stdoutCopy = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $stderrRead = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [void] $stdoutCopy.GetAwaiter().GetResult()
        $stderrText = $stderrRead.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "reference process failed: exit=$($process.ExitCode) stderr=$stderrText"
        }
        return $memory.ToArray()
    } finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

function Invoke-ValidationExitCode {
    param(
        [string] $Mode,
        [string] $ExpectedPath,
        [string] $FilePath
    )

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Jq -e --arg mode $Mode --arg expectedPath $ExpectedPath --argjson expectedCount 50000 -f $Script:ValidateResponseFilter $FilePath 1>$null 2>$null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }
}

function Assert-ValidationFails {
    param(
        [string] $Mode,
        [string] $ExpectedPath,
        [string] $FilePath
    )

    $exitCode = Invoke-ValidationExitCode -Mode $Mode -ExpectedPath $ExpectedPath -FilePath $FilePath
    Assert-True ($exitCode -ne 0) "validation unexpectedly passed: mode=$Mode file=$FilePath"
}

function Invoke-SummaryToFile {
    param(
        [string[]] $Files,
        [string[]] $OfficialFileNames,
        [string] $DestinationPath
    )

    $officialFileNamesJson = @($OfficialFileNames) | ConvertTo-Json -Compress
    $summaryArguments = @(
        '-r',
        '--argjson', 'expectedCount', '50000',
        '--argjson', 'officialFileNames', $officialFileNamesJson,
        '-s',
        '-f', $Script:SummaryFilter
    ) + $Files
    Invoke-JqToFile -Arguments $summaryArguments -DestinationPath $DestinationPath
}

function Assert-SummaryFails {
    param(
        [string[]] $Files,
        [string[]] $OfficialFileNames,
        [string] $DestinationPath
    )

    Assert-ThrowsLike -Pattern 'native process failed' -Action {
        Invoke-SummaryToFile -Files $Files -OfficialFileNames $OfficialFileNames -DestinationPath $DestinationPath
    }
    Assert-True (-not (Test-Path -LiteralPath $DestinationPath)) "failed summary left partial file: $DestinationPath"
}

function Write-JsonBytes {
    param(
        [string] $Path,
        [string] $Text
    )

    [System.IO.File]::WriteAllText($Path, $Text, $Script:Utf8NoBom)
}

function Write-SummaryRecord {
    param(
        [string] $Path,
        [string] $Strategy,
        [long] $ElapsedNanos,
        [bool] $V2,
        [string] $Checksum
    )

    $record = [ordered] @{}
    if ($V2) {
        $record.resultFormatVersion = 2
    }
    $record.path = $Strategy
    $record.inputCount = 50000
    $record.savedCount = 50000
    $record.elapsedNanos = $ElapsedNanos
    if ($V2) {
        $record.elapsedSeconds = $ElapsedNanos / 1000000000
    }
    $record.elapsedMillis = $ElapsedNanos / 1000000
    $record.valid = $true
    $record.rowCount = 50000
    $record.distinctBusinessKeyCount = 50000
    $record.missingKeyCount = 0
    $record.unexpectedKeyCount = 0
    $record.duplicateKeyCount = 0
    $record.expectedChecksum = $Checksum
    $record.actualChecksum = $Checksum

    Write-JsonBytes -Path $Path -Text ($record | ConvertTo-Json -Depth 4)
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

function Assert-OfficialResultSha {
    $manifest = [ordered] @{
        'results/exp-001/20260727T053643Z-2d76b26/metadata.md' = '52116dca40b7834dac8a6f868e8030677665b885d90743605c8d2299f74ad2ac'
        'results/exp-001/20260727T053643Z-2d76b26/official/round-01-01-jpa.json' = '82d1ef9c3fcf9c148d36980bc03aad0ad2a6e3b9f49cb79f3c750bce3cbb3734'
        'results/exp-001/20260727T053643Z-2d76b26/official/round-01-02-jdbc.json' = 'a3a02fba1cb0c6ed81a77fd537853d59b91e9e8f094c22ef3d568c116548ee51'
        'results/exp-001/20260727T053643Z-2d76b26/official/round-02-01-jdbc.json' = 'ebec41d3feb15efe2211a8bf93eaa4477062b8d7539b51f94f89f01d39961d7a'
        'results/exp-001/20260727T053643Z-2d76b26/official/round-02-02-jpa.json' = '6179a1dfbaa3e8b9b56e812b795d4f8880b2791ca9f2a5638ee9ac8c16297065'
        'results/exp-001/20260727T053643Z-2d76b26/official/round-03-01-jpa.json' = 'ef44140747df9786eefb9d194c30074e9780cc0678335e35664da32ed7594cc2'
        'results/exp-001/20260727T053643Z-2d76b26/official/round-03-02-jdbc.json' = '63b11a2d48bdf7344f0f148e46ef9cab4ac6f99267a2423f0432d6f84bd2d1fe'
        'results/exp-001/20260727T053643Z-2d76b26/official/round-04-01-jdbc.json' = 'ad3272786a4f19ac8a6aa349beb39c6ff2abb9da5f00a7de6910a149941c2e5f'
        'results/exp-001/20260727T053643Z-2d76b26/official/round-04-02-jpa.json' = '791e819059c2f8bd539005caad2291100974b3f96477fa96c40edacb90abf8b3'
        'results/exp-001/20260727T053643Z-2d76b26/official/round-05-01-jpa.json' = '5f7b93343438b1db1c1d4290f57bda04dae1120ca805896122df67c0f890c1e8'
        'results/exp-001/20260727T053643Z-2d76b26/official/round-05-02-jdbc.json' = '74f6b0bb1e672381c00c1ed56897aa6d6c60be35e18be54faa953776aef1addc'
        'results/exp-001/20260727T053643Z-2d76b26/official/round-06-01-jdbc.json' = '7321a74581900a3ad3d6ec1f3bc30eb32be3d4aa005f54a456fdf1add9e96117'
        'results/exp-001/20260727T053643Z-2d76b26/official/round-06-02-jpa.json' = '47039a6a0ff8c03bde0687a751fc602bb27a99c7da701a66e3b0f6bc3d359d96'
        'results/exp-001/20260727T053643Z-2d76b26/summary.md' = '4acf86bf224859b02635db879c04f5cb92af306cdfe2cddcc3de9ffac53cb6df'
        'results/exp-001/20260727T053643Z-2d76b26/warmup/01-jpa-warmup.json' = 'ca6754161d2888f0f6afa8a2a00dab85f3c8e6e279327ee0d063254958307fd2'
        'results/exp-001/20260727T053643Z-2d76b26/warmup/02-jdbc-warmup.json' = '94e6533c7ed9691b6aaba93caa9b176b969949e998c635ab3b507015a033014c'
    }

    $resultRoot = Join-Path $ProjectRoot 'results/exp-001/20260727T053643Z-2d76b26'
    $actualFiles = @(Get-ChildItem -LiteralPath $resultRoot -Recurse -File)
    Assert-True ($actualFiles.Count -eq 16) "official result file count changed: $($actualFiles.Count)"

    foreach ($entry in $manifest.GetEnumerator()) {
        $path = Join-Path $ProjectRoot $entry.Key
        Assert-True (Test-Path -LiteralPath $path) "official result file missing: $($entry.Key)"
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-True ($actual -eq $entry.Value) "official result SHA changed: $($entry.Key)"
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "exp 001 fixtures $PID"
if (Test-Path -LiteralPath $tempRoot) {
    Fail-Fixture "temp directory already exists: $tempRoot"
}
New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    $Jq = Require-Jq
    $legacy = Join-Path $FixturesDir 'legacy-compact-valid.json'
    $v2 = Join-Path $FixturesDir 'v2-pretty-valid.json'
    $invalidSeconds = Join-Path $FixturesDir 'v2-invalid-seconds.json'
    $ambiguous = Join-Path $FixturesDir 'ambiguous-versionless-seconds.json'

    Invoke-ResponseValidation -Mode raw -ExpectedPath 'jpa' -FilePath $legacy -ExpectedCount 50000
    Invoke-ResponseValidation -Mode artifact -ExpectedPath 'jpa' -FilePath $legacy -ExpectedCount 50000
    Invoke-ResponseValidation -Mode v2 -ExpectedPath 'jdbc' -FilePath $v2 -ExpectedCount 50000
    Invoke-ResponseValidation -Mode artifact -ExpectedPath 'jdbc' -FilePath $v2 -ExpectedCount 50000
    Assert-ValidationFails -Mode artifact -ExpectedPath 'jdbc' -FilePath $invalidSeconds
    Assert-ValidationFails -Mode artifact -ExpectedPath 'jpa' -FilePath $ambiguous
    Assert-ValidationFails -Mode raw -ExpectedPath 'jdbc' -FilePath $v2

    $formatted = Join-Path $tempRoot 'formatted output.json'
    Invoke-JqToFile -Arguments @(
        '--arg', 'expectedPath', 'jpa',
        '--argjson', 'expectedCount', '50000',
        '-f', $Script:FormatResponseFilter,
        $legacy
    ) -DestinationPath $formatted
    Assert-BytesEqual -ExpectedPath (Join-Path $ExpectedDir 'v2-formatted.json') -ActualPath $formatted
    Invoke-ResponseValidation -Mode v2 -ExpectedPath 'jpa' -FilePath $formatted -ExpectedCount 50000
    Assert-TextFileLfUtf8NoBomFinalNewline -Path $formatted
    Assert-FormattedResponseSemanticEquality -RawPath $legacy -FormattedPath $formatted

    $edgeNanosValues = @(
        1L,
        999L,
        1000000L,
        999999999L,
        1000000000L,
        60000000000L,
        80000000000L,
        75857631900L,
        1234567890L
    )
    foreach ($nanos in $edgeNanosValues) {
        $edgeRaw = Join-Path $tempRoot "edge-$nanos.raw.json"
        $edgeFormatted = Join-Path $tempRoot "edge-$nanos.formatted.json"
        Invoke-JqToFile -Arguments @(
            '--argjson', 'nanos', ([string] $nanos),
            '.elapsedNanos = $nanos | .elapsedMillis = ($nanos / 1000000)',
            $legacy
        ) -DestinationPath $edgeRaw
        Invoke-ResponseValidation -Mode raw -ExpectedPath 'jpa' -FilePath $edgeRaw -ExpectedCount 50000
        Invoke-JqToFile -Arguments @(
            '--arg', 'expectedPath', 'jpa',
            '--argjson', 'expectedCount', '50000',
            '-f', $Script:FormatResponseFilter,
            $edgeRaw
        ) -DestinationPath $edgeFormatted
        Invoke-ResponseValidation -Mode v2 -ExpectedPath 'jpa' -FilePath $edgeFormatted -ExpectedCount 50000
        Assert-TextFileLfUtf8NoBomFinalNewline -Path $edgeFormatted
        Assert-FormattedResponseSemanticEquality -RawPath $edgeRaw -FormattedPath $edgeFormatted
    }

    $badFormatted = Join-Path $tempRoot 'bad formatted.json'
    Assert-ThrowsLike -Pattern 'raw response schema validation failed' -Action {
        Invoke-JqToFile -Arguments @(
            '--arg', 'expectedPath', 'jpa',
            '--argjson', 'expectedCount', '50000',
            '-f', $Script:FormatResponseFilter,
            $ambiguous
        ) -DestinationPath $badFormatted
    }
    Assert-True (-not (Test-Path -LiteralPath $badFormatted)) "failed formatter left partial file: $badFormatted"

    $millisMismatch = Join-Path $tempRoot 'millis mismatch.json'
    Invoke-JqToFile -Arguments @('.elapsedMillis = 1', $legacy) -DestinationPath $millisMismatch
    Assert-ValidationFails -Mode raw -ExpectedPath 'jpa' -FilePath $millisMismatch

    $unknownVersion = Join-Path $tempRoot 'unknown version.json'
    Invoke-JqToFile -Arguments @('.resultFormatVersion = 3', $v2) -DestinationPath $unknownVersion
    Assert-ValidationFails -Mode artifact -ExpectedPath 'jdbc' -FilePath $unknownVersion

    foreach ($case in @(
        @('missing seconds', 'del(.elapsedSeconds)'),
        @('string seconds', '.elapsedSeconds = "1"'),
        @('null seconds', '.elapsedSeconds = null'),
        @('negative seconds', '.elapsedSeconds = -1')
    )) {
        $variant = Join-Path $tempRoot "v2 $($case[0]).json"
        Invoke-JqToFile -Arguments @($case[1], $v2) -DestinationPath $variant
        Assert-ValidationFails -Mode artifact -ExpectedPath 'jdbc' -FilePath $variant
    }

    foreach ($case in @(
        @('checksum mismatch', '.actualChecksum = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"'),
        @('saved count mismatch', '.savedCount = 49999'),
        @('row count mismatch', '.rowCount = 49999'),
        @('valid false', '.valid = false')
    )) {
        $variant = Join-Path $tempRoot "legacy $($case[0]).json"
        Invoke-JqToFile -Arguments @($case[1], $legacy) -DestinationPath $variant
        Assert-ValidationFails -Mode raw -ExpectedPath 'jpa' -FilePath $variant
    }

    $emptyJson = Join-Path $tempRoot 'empty.json'
    [System.IO.File]::WriteAllBytes($emptyJson, [byte[]] @())
    Assert-ValidationFails -Mode artifact -ExpectedPath 'jpa' -FilePath $emptyJson

    $partialJson = Join-Path $tempRoot 'partial.json'
    Write-JsonBytes -Path $partialJson -Text '{"path":"jpa"'
    Assert-ValidationFails -Mode artifact -ExpectedPath 'jpa' -FilePath $partialJson

    $unicodeMessage = ([string] [char] 0xD55C) + ([string] [char] 0xAE00) + ' value'
    $nativeArgs = @(
        '-n',
        '--arg', 'message', $unicodeMessage,
        '--arg', 'path', 'space path',
        '{message:$message,path:$path}'
    )
    $nativeOut = Join-Path $tempRoot 'native unicode.json'
    $referenceBytes = Invoke-NativeProcessToMemoryBytes -FilePath $Jq -Arguments (@('-b') + $nativeArgs)
    Invoke-NativeProcessToFile -FilePath $Jq -Arguments (@('-b') + $nativeArgs) -DestinationPath $nativeOut
    [System.IO.File]::WriteAllBytes((Join-Path $tempRoot 'native reference.json'), $referenceBytes)
    Assert-BytesEqual -ExpectedPath (Join-Path $tempRoot 'native reference.json') -ActualPath $nativeOut
    Assert-TextFileLfUtf8NoBomFinalNewline -Path $nativeOut

    $failureOut = Join-Path $tempRoot 'native failure.json'
    Assert-ThrowsLike -Pattern 'planned failure' -Action {
        Invoke-NativeProcessToFile -FilePath $Jq -Arguments @('-n', 'error("planned failure")') -DestinationPath $failureOut
    }
    Assert-True (-not (Test-Path -LiteralPath $failureOut)) "failed native process left partial file: $failureOut"

    $overwrite = Join-Path $tempRoot 'overwrite.json'
    Write-JsonBytes -Path $overwrite -Text "keep`n"
    $overwriteBefore = (Get-FileHash -LiteralPath $overwrite -Algorithm SHA256).Hash
    Assert-ThrowsLike -Pattern 'destination file' -Action {
        Invoke-NativeProcessToFile -FilePath $Jq -Arguments @('-n', '{}') -DestinationPath $overwrite
    }
    $overwriteAfter = (Get-FileHash -LiteralPath $overwrite -Algorithm SHA256).Hash
    Assert-True ($overwriteBefore -eq $overwriteAfter) "overwrite rejection changed destination bytes"

    $summaryDir = Join-Path $tempRoot 'official mixed'
    New-Item -ItemType Directory -Path $summaryDir | Out-Null
    $shaA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $shaB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $summaryRecords = @(
        @('round-01-01-jpa.json', 'jpa', 1000000000, $false, $shaA),
        @('round-01-02-jdbc.json', 'jdbc', 500000000, $true, $shaB),
        @('round-02-01-jdbc.json', 'jdbc', 600000000, $false, $shaB),
        @('round-02-02-jpa.json', 'jpa', 2000000000, $true, $shaA),
        @('round-03-01-jpa.json', 'jpa', 3000000000, $false, $shaA),
        @('round-03-02-jdbc.json', 'jdbc', 700000000, $true, $shaB),
        @('round-04-01-jdbc.json', 'jdbc', 800000000, $false, $shaB),
        @('round-04-02-jpa.json', 'jpa', 4000000000, $true, $shaA),
        @('round-05-01-jpa.json', 'jpa', 5000000000, $false, $shaA),
        @('round-05-02-jdbc.json', 'jdbc', 900000000, $true, $shaB),
        @('round-06-01-jdbc.json', 'jdbc', 1000000000, $false, $shaB),
        @('round-06-02-jpa.json', 'jpa', 6000000000, $true, $shaA)
    )
    $summaryFiles = @()
    foreach ($record in $summaryRecords) {
        $path = Join-Path $summaryDir $record[0]
        Write-SummaryRecord -Path $path -Strategy $record[1] -ElapsedNanos ([long] $record[2]) -V2 ([bool] $record[3]) -Checksum $record[4]
        $summaryFiles += $path
    }
    $officialFileNames = @($summaryRecords | ForEach-Object { [string] $_[0] })

    $summaryActual = Join-Path $tempRoot 'summary actual.md'
    Invoke-SummaryToFile -Files $summaryFiles -OfficialFileNames $officialFileNames -DestinationPath $summaryActual
    Assert-TextFileLfUtf8NoBomFinalNewline -Path $summaryActual
    Assert-BytesEqual -ExpectedPath (Join-Path $ExpectedDir 'summary-mixed.md') -ActualPath $summaryActual

    $jpaFirstIndexes = @(0, 3, 4, 7, 8, 11, 1, 2, 5, 6, 9, 10)
    Assert-SummaryFails `
        -Files @($jpaFirstIndexes | ForEach-Object { $summaryFiles[$_] }) `
        -OfficialFileNames @($jpaFirstIndexes | ForEach-Object { $officialFileNames[$_] }) `
        -DestinationPath (Join-Path $tempRoot 'summary grouped order.md')

    $swappedIndexes = @(1, 0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11)
    Assert-SummaryFails `
        -Files @($swappedIndexes | ForEach-Object { $summaryFiles[$_] }) `
        -OfficialFileNames @($swappedIndexes | ForEach-Object { $officialFileNames[$_] }) `
        -DestinationPath (Join-Path $tempRoot 'summary swapped order.md')

    $duplicateNames = @($officialFileNames)
    $duplicateNames[1] = $duplicateNames[0]
    Assert-SummaryFails -Files $summaryFiles -OfficialFileNames $duplicateNames -DestinationPath (Join-Path $tempRoot 'summary duplicate basename.md')

    Assert-SummaryFails -Files @($summaryFiles | Select-Object -First 11) -OfficialFileNames @($officialFileNames | Select-Object -First 11) -DestinationPath (Join-Path $tempRoot 'summary missing basename.md')

    $unexpectedNames = @($officialFileNames)
    $unexpectedNames[11] = 'round-06-02-saveall.json'
    Assert-SummaryFails -Files $summaryFiles -OfficialFileNames $unexpectedNames -DestinationPath (Join-Path $tempRoot 'summary unexpected basename.md')

    $strategyMismatchFiles = @($summaryFiles)
    $strategyMismatchFile = Join-Path $tempRoot 'round-01-01-jpa-strategy-mismatch.json'
    Invoke-JqToFile -Arguments @('.path = "jdbc"', $summaryFiles[0]) -DestinationPath $strategyMismatchFile
    $strategyMismatchFiles[0] = $strategyMismatchFile
    Assert-SummaryFails -Files $strategyMismatchFiles -OfficialFileNames $officialFileNames -DestinationPath (Join-Path $tempRoot 'summary strategy mismatch.md')

    $humanDir = Join-Path $tempRoot 'official human duration'
    New-Item -ItemType Directory -Path $humanDir | Out-Null
    $humanNanos = @(
        647975450L,
        8783400000L,
        75857631900L,
        76684628950L,
        3000000000L,
        700000000L,
        800000000L,
        4000000000L,
        5000000000L,
        900000000L,
        1000000000L,
        6000000000L
    )
    $humanFiles = @()
    for ($index = 0; $index -lt $summaryRecords.Count; $index++) {
        $record = $summaryRecords[$index]
        $path = Join-Path $humanDir $record[0]
        Write-SummaryRecord -Path $path -Strategy $record[1] -ElapsedNanos ([long] $humanNanos[$index]) -V2 ([bool] $record[3]) -Checksum $record[4]
        $humanFiles += $path
    }
    $humanSummary = Join-Path $tempRoot 'summary human duration.md'
    Invoke-SummaryToFile -Files $humanFiles -OfficialFileNames $officialFileNames -DestinationPath $humanSummary
    $humanText = Get-Content -LiteralPath $humanSummary -Raw -Encoding UTF8
    Assert-True ($humanText.Contains('647.975ms')) 'human duration sub-second display mismatch'
    Assert-True ($humanText.Contains('8.783s')) 'human duration seconds display mismatch'
    Assert-True ($humanText.Contains('1m 15.858s')) 'human duration minute display mismatch'
    Assert-True ($humanText.Contains('1m 16.685s')) 'human duration minute rounding mismatch'

    foreach ($path in @(
        'scripts/exp-001/tests/fixtures/legacy-compact-valid.json',
        'scripts/exp-001/tests/expected/v2-formatted.json',
        'scripts/exp-001/tests/expected/summary-mixed.md'
    )) {
        Assert-GitAttr -Path $path -Attribute 'text' -ExpectedValue 'set'
        Assert-GitAttr -Path $path -Attribute 'eol' -ExpectedValue 'lf'
    }
    Assert-GitAttr -Path 'results/exp-001/20260727T053643Z-2d76b26/summary.md' -Attribute 'text' -ExpectedValue 'unset'
    Assert-GitAttr -Path 'results/exp-001/20260727T053643Z-2d76b26/summary.md' -Attribute 'whitespace' -ExpectedValue 'cr-at-eol'
    Assert-OfficialResultSha
} finally {
    $resolvedTempRoot = [System.IO.Path]::GetFullPath($tempRoot)
    $allowedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolvedTempRoot.StartsWith($allowedTempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'EXP-001 fixture tests passed.'
