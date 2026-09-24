function Assert-VanessaFeatureResult {
    param(
        [Parameter(Mandatory=$true)]$Launch,
        [Parameter(Mandatory=$true)][string]$Iteration,
        [Parameter(Mandatory=$true)][string]$FeaturePath
    )

    $evidence = [ordered]@{
        schemaVersion = 1
        jobId = $Launch.jobId
        pid = $Launch.pid
        startedAt = $Launch.startedAt
        exitedAt = $Launch.exitedAt
        exitCodeState = $Launch.exitCodeState
        exitCode = $Launch.exitCode
        featurePath = [IO.Path]::GetFullPath($FeaturePath)
        managerBase = $Launch.infoBase
        status = 'unavailable'
        junit = 'unavailable'
        outcome = 'failed'
    }
    $started = [DateTime]::Parse([string]$Launch.startedAt).ToUniversalTime()
    $statusPath = Join-Path $Iteration 'vanessa-status.txt'
    $junitPath = Join-Path $Iteration 'junit.xml'
    try {
        if (-not $Launch.exitedAt) { throw 'VANESSA_MANAGER_EXIT_UNCONFIRMED' }
        if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) { throw 'VANESSA_STATUS_MISSING' }
        if ((Get-Item -LiteralPath $statusPath).LastWriteTimeUtc -lt $started) { throw 'VANESSA_STATUS_STALE' }
        $status = (Read-Utf8Text -Path $statusPath).Trim()
        $evidence.status = $status
        if ($status -ne '0') { throw ('VANESSA_STATUS_FAILED: ' + $status) }

        if (-not (Test-Path -LiteralPath $junitPath -PathType Leaf)) { throw 'VANESSA_JUNIT_MISSING' }
        if ((Get-Item -LiteralPath $junitPath).LastWriteTimeUtc -lt $started) { throw 'VANESSA_JUNIT_STALE' }
        $readerSettings = [Xml.XmlReaderSettings]::new()
        $readerSettings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $readerSettings.XmlResolver = $null
        $reader = [Xml.XmlReader]::Create($junitPath, $readerSettings)
        try {
            $document = [Xml.XmlDocument]::new()
            $document.XmlResolver = $null
            $document.Load($reader)
        } finally { $reader.Dispose() }
        $suites = @($document.SelectNodes('/*[local-name()="testsuite"] | /*[local-name()="testsuites"]/*[local-name()="testsuite"]'))
        if ($suites.Count -eq 0) { throw 'VANESSA_JUNIT_INVALID' }
        $tests = 0; $failures = 0; $errors = 0
        foreach ($suite in $suites) {
            foreach ($name in @('tests', 'failures', 'errors')) {
                if (-not $suite.Attributes[$name] -or [string]$suite.Attributes[$name].Value -notmatch '^\d+$') {
                    throw 'VANESSA_JUNIT_INVALID'
                }
            }
            $tests += [int]$suite.Attributes['tests'].Value
            $failures += [int]$suite.Attributes['failures'].Value
            $errors += [int]$suite.Attributes['errors'].Value
        }
        $cases = @($document.SelectNodes('//*[local-name()="testcase"]'))
        $failedCases = @($document.SelectNodes('//*[local-name()="testcase"]/*[local-name()="failure" or local-name()="error"]'))
        $passedCases = @($document.SelectNodes('//*[local-name()="testcase" and not(*[local-name()="skipped" or local-name()="failure" or local-name()="error"])]'))
        $evidence.junit = [ordered]@{ tests=$tests; failures=$failures; errors=$errors; cases=$cases.Count; passedCases=$passedCases.Count }
        if ($tests -lt 1 -or $cases.Count -lt 1 -or $passedCases.Count -lt 1 -or
            $failures -ne 0 -or $errors -ne 0 -or $failedCases.Count -ne 0) { throw 'VANESSA_JUNIT_FAILED' }
        if ($Launch.exitCodeState -eq 'available' -and $null -ne $Launch.exitCode -and [int]$Launch.exitCode -ne 0) {
            throw ('VANESSA_MANAGER_FAILED: ' + $Launch.exitCode)
        }
        if ($Launch.exitCodeState -notin @('available', 'unavailable')) { throw 'VANESSA_MANAGER_EXIT_UNCONFIRMED' }
        if ($Launch.exitCodeState -eq 'available' -and $null -eq $Launch.exitCode) { throw 'VANESSA_MANAGER_EXIT_UNCONFIRMED' }
        $evidence.outcome = 'passed'
        $evidence.completionBasis = 'owned-process-exit+fresh-vanessa-status+fresh-junit'
    } catch {
        $evidence.error = $_.Exception.Message
    }
    Write-Utf8TextAtomic -Path (Join-Path $Iteration 'manager-result.json') -Value ($evidence | ConvertTo-Json -Depth 8)
    if ($evidence.outcome -ne 'passed') { throw $evidence.error }
    return [pscustomobject]$evidence
}

function Get-VanessaFeaturePortPreflight {
    param([Parameter(Mandatory=$true)]$Settings)

    $rangeText = [string]$Settings.ДиапазонПортовTestclient
    $match = [regex]::Match($rangeText, '^\s*(\d+)(?:-(\d+))?\s*$')
    $range = [ordered]@{ value=$rangeText; kind='unknown'; first=$null; last=$null }
    if ($match.Success) {
        $first = 0; $last = 0
        $validFirst = [int]::TryParse($match.Groups[1].Value, [ref]$first)
        $validLast = $(if ($match.Groups[2].Success) {
            [int]::TryParse($match.Groups[2].Value, [ref]$last)
        } else { $last = $first; $true })
        if ($validFirst -and $validLast -and $first -ge 1 -and $last -le 65535 -and $last -ge $first) {
            $range.first = $first
            $range.last = $last
            $range.kind = $(if ($first -eq $last) { 'single-port' } else { 'range' })
        }
    }
    $profiles = @()
    foreach ($profile in @($Settings.КлиентТестирования.ДанныеКлиентовТестирования)) {
        if ($null -eq $profile) { continue }
        $port = 0
        $validPort = [int]::TryParse([string]$profile.ПортЗапускаТестКлиента, [ref]$port)
        $profiles += [ordered]@{
            name = [string]$profile.Имя
            port = $(if ($validPort) { $port } else { $null })
            rangeRelation = $(if (-not $validPort -or $range.kind -eq 'unknown') { 'unknown' }
                              elseif ($port -ge $range.first -and $port -le $range.last) { 'inside' }
                              else { 'outside' })
        }
    }
    return [pscustomobject]@{ schemaVersion=1; range=$range; profiles=$profiles;
        diagnosis=$(if ($range.kind -eq 'single-port') { 'single-port-range-configured' }
                    elseif ($range.kind -eq 'unknown') { 'port-range-unavailable' }
                    else { 'configured-range' }) }
}
