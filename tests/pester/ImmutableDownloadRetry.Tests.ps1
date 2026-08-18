BeforeAll {
    . (Join-Path $PSScriptRoot "TestSupport.ps1")
    $context = Initialize-WorkflowPesterContext
    $script:RepoRoot = $context.RepoRoot
    $script:HelperPath = Join-Path $script:RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.immutable-download.ps1"
    . $script:HelperPath

    $script:Payload = [Text.Encoding]::UTF8.GetBytes("immutable test payload")
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $script:PayloadSha256 = ([BitConverter]::ToString($sha.ComputeHash($script:Payload))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

Describe "Immutable asset download retry policy" {
    BeforeEach {
        $script:RequestCount = 0
        $script:SleepDelays = New-Object System.Collections.Generic.List[int]
        Mock Start-Sleep { param([int]$Seconds) $script:SleepDelays.Add($Seconds) | Out-Null }
    }

    It "retries a bounded transient transport failure and preserves exact SHA identity" {
        $destination = Join-Path $TestDrive "transport.bin"
        Mock Invoke-WebRequest {
            param($Uri, $OutFile, $TimeoutSec)
            $script:RequestCount++
            if ($script:RequestCount -lt 3) {
                throw [Net.WebException]::new("connection failed", $null, [Net.WebExceptionStatus]::ConnectFailure, $null)
            }
            [IO.File]::WriteAllBytes($OutFile, $script:Payload)
        }

        $result = Invoke-ItlImmutableFileDownload -Uri "https://example.invalid/asset.bin" -DestinationPath $destination -ExpectedSha256 $script:PayloadSha256

        $result.attempts | Should -Be 3
        $result.sha256 | Should -Be $script:PayloadSha256
        (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $script:PayloadSha256
        $script:SleepDelays.ToArray() | Should -Be @(1, 2)
    }

    It "discards a partial OutFile before retrying an admitted transport failure" {
        $destination = Join-Path $TestDrive "partial-transport.bin"
        Mock Invoke-WebRequest {
            param($Uri, $OutFile, $TimeoutSec)
            $script:RequestCount++
            if ($script:RequestCount -eq 1) {
                [IO.File]::WriteAllBytes($OutFile, [Text.Encoding]::UTF8.GetBytes("partial response"))
                throw [Net.WebException]::new("receive failed", $null, [Net.WebExceptionStatus]::ReceiveFailure, $null)
            }
            Test-Path -LiteralPath $OutFile | Should -BeFalse
            [IO.File]::WriteAllBytes($OutFile, $script:Payload)
        }

        $result = Invoke-ItlImmutableFileDownload -Uri "https://example.invalid/asset.bin" -DestinationPath $destination -ExpectedSha256 $script:PayloadSha256

        $result.attempts | Should -Be 2
        $script:RequestCount | Should -Be 2
        $script:SleepDelays.ToArray() | Should -Be @(1)
        (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $script:PayloadSha256
    }

    It "retries only admitted HTTP server statuses and never HTTP 4xx" {
        foreach ($statusCode in @(500, 502, 503, 504)) {
            $failure = [Exception]::new("HTTP $statusCode")
            $failure.Data["StatusCode"] = $statusCode
            $errorRecord = [Management.Automation.ErrorRecord]::new($failure, "server", [Management.Automation.ErrorCategory]::ConnectionError, $null)
            Test-ItlTransientImmutableDownloadFailure -ErrorRecord $errorRecord | Should -BeTrue
        }
        $serverErrorDestination = Join-Path $TestDrive "server-error.bin"
        Mock Invoke-WebRequest {
            param($Uri, $OutFile, $TimeoutSec)
            $script:RequestCount++
            if ($script:RequestCount -eq 1) {
                $failure = [Exception]::new("service unavailable")
                $failure.Data["StatusCode"] = 503
                throw $failure
            }
            [IO.File]::WriteAllBytes($OutFile, $script:Payload)
        }

        (Invoke-ItlImmutableFileDownload -Uri "https://example.invalid/asset.bin" -DestinationPath $serverErrorDestination -ExpectedSha256 $script:PayloadSha256).attempts | Should -Be 2
        $script:RequestCount | Should -Be 2

        $script:RequestCount = 0
        Mock Invoke-WebRequest {
            $script:RequestCount++
            $failure = [Exception]::new("not found")
            $failure.Data["StatusCode"] = 404
            throw $failure
        }
        {
            Invoke-ItlImmutableFileDownload -Uri "https://example.invalid/missing.bin" -DestinationPath (Join-Path $TestDrive "missing.bin") -ExpectedSha256 $script:PayloadSha256
        } | Should -Throw "*not found*"
        $script:RequestCount | Should -Be 1

        foreach ($statusCode in @(501, 505, 408, 429)) {
            $script:RequestCount = 0
            Mock Invoke-WebRequest {
                $script:RequestCount++
                $failure = [Exception]::new("HTTP $statusCode")
                $failure.Data["StatusCode"] = $statusCode
                throw $failure
            }
            {
                Invoke-ItlImmutableFileDownload -Uri "https://example.invalid/rejected.bin" -DestinationPath (Join-Path $TestDrive "rejected-$statusCode.bin") -ExpectedSha256 $script:PayloadSha256
            } | Should -Throw "*HTTP $statusCode*"
            $script:RequestCount | Should -Be 1
        }
    }

    It "admits only the explicit PowerShell 5.1 transport statuses" {
        foreach ($status in @(
            [Net.WebExceptionStatus]::ConnectFailure,
            [Net.WebExceptionStatus]::ConnectionClosed,
            [Net.WebExceptionStatus]::KeepAliveFailure,
            [Net.WebExceptionStatus]::NameResolutionFailure,
            [Net.WebExceptionStatus]::PipelineFailure,
            [Net.WebExceptionStatus]::ProxyNameResolutionFailure,
            [Net.WebExceptionStatus]::ReceiveFailure,
            [Net.WebExceptionStatus]::SendFailure,
            [Net.WebExceptionStatus]::Timeout
        )) {
            $errorRecord = [Management.Automation.ErrorRecord]::new([Net.WebException]::new("transient", $null, $status, $null), "transient", [Management.Automation.ErrorCategory]::ConnectionError, $null)
            Test-ItlTransientImmutableDownloadFailure -ErrorRecord $errorRecord | Should -BeTrue
        }
        foreach ($socketCode in @(
            [Net.Sockets.SocketError]::ConnectionReset,
            [Net.Sockets.SocketError]::HostNotFound,
            [Net.Sockets.SocketError]::NetworkUnreachable,
            [Net.Sockets.SocketError]::TimedOut
        )) {
            $socket = [Net.Sockets.SocketException]::new([int]$socketCode)
            $wrapper = [Exception]::new("transport wrapper", $socket)
            $errorRecord = [Management.Automation.ErrorRecord]::new($wrapper, "socket", [Management.Automation.ErrorCategory]::ConnectionError, $null)
            Test-ItlTransientImmutableDownloadFailure -ErrorRecord $errorRecord | Should -BeTrue
        }
        foreach ($status in @(
            [Net.WebExceptionStatus]::RequestCanceled,
            [Net.WebExceptionStatus]::TrustFailure,
            [Net.WebExceptionStatus]::SecureChannelFailure,
            [Net.WebExceptionStatus]::ServerProtocolViolation,
            [Net.WebExceptionStatus]::UnknownError
        )) {
            $errorRecord = [Management.Automation.ErrorRecord]::new([Net.WebException]::new("permanent", $null, $status, $null), "permanent", [Management.Automation.ErrorCategory]::InvalidOperation, $null)
            Test-ItlTransientImmutableDownloadFailure -ErrorRecord $errorRecord | Should -BeFalse
        }
        Add-Type -AssemblyName System.Net.Http
        foreach ($exception in @(
            (New-Object System.Net.Http.HttpRequestException("connection reset by peer")),
            [OperationCanceledException]::new("request cancelled")
        )) {
            $errorRecord = [Management.Automation.ErrorRecord]::new($exception, "permanent", [Management.Automation.ErrorCategory]::OperationStopped, $null)
            Test-ItlTransientImmutableDownloadFailure -ErrorRecord $errorRecord | Should -BeFalse
        }
    }

    It "does not retry non-network or SHA validation failures" {
        $destination = Join-Path $TestDrive "wrong-hash.bin"
        Mock Invoke-WebRequest {
            param($Uri, $OutFile, $TimeoutSec)
            $script:RequestCount++
            [IO.File]::WriteAllBytes($OutFile, [Text.Encoding]::UTF8.GetBytes("wrong payload"))
        }
        {
            Invoke-ItlImmutableFileDownload -Uri "https://example.invalid/asset.bin" -DestinationPath $destination -ExpectedSha256 $script:PayloadSha256
        } | Should -Throw "*SHA256 mismatch*"
        $script:RequestCount | Should -Be 1
        Test-Path -LiteralPath $destination | Should -BeFalse

        $script:RequestCount = 0
        Mock Invoke-WebRequest { $script:RequestCount++; throw [InvalidOperationException]::new("connection reset by peer") }
        {
            Invoke-ItlImmutableFileDownload -Uri "https://example.invalid/asset.bin" -DestinationPath $destination -ExpectedSha256 $script:PayloadSha256
        } | Should -Throw "*connection reset by peer*"
        $script:RequestCount | Should -Be 1
    }

    It "stages local candidates and preserves an existing exact target on mismatch" {
        $source = Join-Path $TestDrive "local-source.bin"
        $destination = Join-Path $TestDrive "local-target.bin"
        [IO.File]::WriteAllBytes($source, $script:Payload)
        [IO.File]::WriteAllBytes($destination, $script:Payload)
        $before = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()

        (Invoke-ItlImmutableFileAcquire -Source $source -DestinationPath $destination -ExpectedSha256 $script:PayloadSha256).sha256 | Should -Be $script:PayloadSha256
        (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $before

        [IO.File]::WriteAllText($source, "wrong local candidate", [Text.UTF8Encoding]::new($false))
        { Invoke-ItlImmutableFileAcquire -Source $source -DestinationPath $destination -ExpectedSha256 $script:PayloadSha256 } | Should -Throw "*SHA256 mismatch*"
        (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $before
    }

    It "hashes and publishes exact bytes without Get-FileHash autoload" {
        $directory = Join-Path $TestDrive (([char]0x041A).ToString() + " catalog with spaces")
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $source = Join-Path $directory (([char]0x0418).ToString() + " source file.bin")
        $destination = Join-Path $directory (([char]0x041E).ToString() + " published file.bin")
        [IO.File]::WriteAllBytes($source, $script:Payload)
        Mock Get-FileHash { throw "Get-FileHash must not be used" }

        $result = Invoke-ItlImmutableFileAcquire -Source $source -DestinationPath $destination -ExpectedSha256 $script:PayloadSha256

        $result.sha256 | Should -Be $script:PayloadSha256
        $result.published | Should -BeTrue
        (Get-ItlImmutableFileSha256 -Path $destination) | Should -Be $script:PayloadSha256
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($destination)) | Should -Be ([Convert]::ToBase64String($script:Payload))
        Assert-MockCalled Get-FileHash -Times 0
    }

    It "accepts concurrent same-SHA publishers without exposing a partial target" {
        $source = Join-Path $TestDrive "race-source.bin"
        $destination = Join-Path $TestDrive "race-target.bin"
        [IO.File]::WriteAllBytes($source, $script:Payload)
        $jobScript = {
            param($HelperPath, $Source, $Destination, $Expected)
            . $HelperPath
            Invoke-ItlImmutableFileAcquire -Source $Source -DestinationPath $Destination -ExpectedSha256 $Expected | Out-Null
        }
        $jobs = @(
            Start-Job -ScriptBlock $jobScript -ArgumentList $script:HelperPath, $source, $destination, $script:PayloadSha256
            Start-Job -ScriptBlock $jobScript -ArgumentList $script:HelperPath, $source, $destination, $script:PayloadSha256
        )
        try {
            $jobs | Wait-Job | Out-Null
            @($jobs | Where-Object State -ne "Completed") | Should -BeNullOrEmpty
            foreach ($job in $jobs) { Receive-Job -Job $job -ErrorAction Stop | Out-Null }
            (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $script:PayloadSha256
        } finally { $jobs | Remove-Job -Force -ErrorAction SilentlyContinue }
    }

    It "preserves the existing target when atomic replacement cannot publish" {
        $staged = Join-Path $TestDrive "publish-failure.partial"
        $destination = Join-Path $TestDrive "publish-failure.bin"
        [IO.File]::WriteAllBytes($staged, $script:Payload)
        [IO.File]::WriteAllText($destination, "existing good cache entry", [Text.UTF8Encoding]::new($false))
        $before = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        [IO.File]::SetAttributes($destination, [IO.FileAttributes]::ReadOnly)
        try {
            { Publish-ItlImmutableStagedFile -StagedPath $staged -DestinationPath $destination -ExpectedSha256 $script:PayloadSha256 } | Should -Throw
        } finally { [IO.File]::SetAttributes($destination, [IO.FileAttributes]::Normal) }
        (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $before
    }

    It "fails before network access when immutable identity is incomplete" {
        Mock Invoke-WebRequest { throw "must not run" }
        {
            Invoke-ItlImmutableFileDownload -Uri "https://example.invalid/asset.bin" -DestinationPath (Join-Path $TestDrive "invalid.bin") -ExpectedSha256 "invalid"
        } | Should -Throw "*invalid expected SHA256*"
        Assert-MockCalled Invoke-WebRequest -Times 0
    }

    It "keeps 404 availability polling bounded to the explicit post-upload call" {
        $deliveryPath = Join-Path $script:RepoRoot "scripts\source-delivery-component.ps1"
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($deliveryPath, [ref]$tokens, [ref]$errors)
        @($errors) | Should -BeNullOrEmpty
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Get-DeliveryRemoteAssetState" }, $true)
        Invoke-Expression $definition.Extent.Text

        Mock Invoke-ItlImmutableFileDownload {
            $script:RequestCount++
            if ($script:RequestCount -le 2) {
                $failure = [Exception]::new("not yet visible")
                $failure.Data["StatusCode"] = 404
                throw $failure
            }
            return [pscustomobject]@{ sha256 = $script:PayloadSha256 }
        }
        $result = Get-DeliveryRemoteAssetState -Url "https://example.invalid/asset.bin" -ExpectedSha256 $script:PayloadSha256 -AvailabilityAttempts 6
        $result.status | Should -Be "matched"
        $script:RequestCount | Should -Be 3
        $script:SleepDelays.ToArray() | Should -Be @(2, 4)

        $script:RequestCount = 0
        Mock Invoke-ItlImmutableFileDownload {
            $script:RequestCount++
            throw [IO.InvalidDataException]::new("identity mismatch")
        }
        {
            Get-DeliveryRemoteAssetState -Url "https://example.invalid/asset.bin" -ExpectedSha256 $script:PayloadSha256 -AvailabilityAttempts 6
        } | Should -Throw "*identity mismatch*"
        $script:RequestCount | Should -Be 1
    }

    It "routes only pinned artifact and post-gate verification GETs through the policy" {
        $vanessa = Get-Content -LiteralPath (Join-Path $script:RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1") -Raw -Encoding UTF8
        $roctup = Get-Content -LiteralPath (Join-Path $script:RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.roctup-mcp.ps1") -Raw -Encoding UTF8
        $readiness = Get-Content -LiteralPath (Join-Path $script:RepoRoot "scripts\test-release-readiness.ps1") -Raw -Encoding UTF8
        $delivery = Get-Content -LiteralPath (Join-Path $script:RepoRoot "scripts\source-delivery-component.ps1") -Raw -Encoding UTF8
        $shards = Get-Content -LiteralPath (Join-Path $script:RepoRoot "scripts\invoke-pester-shards.ps1") -Raw -Encoding UTF8

        @([regex]::Matches($vanessa, 'Invoke-ItlImmutableFileAcquire -Source')).Count | Should -Be 2
        @([regex]::Matches($roctup, 'Invoke-ItlImmutableFileAcquire -Source')).Count | Should -Be 1
        $readiness | Should -Match 'Invoke-ItlImmutableFileDownload -Uri \(\[string\]\$Lock\.url\)'
        $delivery | Should -Match 'Invoke-ItlImmutableFileDownload -Uri \$Url'
        $delivery | Should -Match 'Get-DeliveryRemoteAssetState.*-AvailabilityAttempts 6'
        $shards | Should -Match 'Invoke-ItlImmutableFileDownload -Uri \$url.*-ExpectedSha256 \$expected'
    }

    It "maps a helper-only delta to every required consumer integration owner test" {
        . (Join-Path $script:RepoRoot "scripts\quality-contracts.ps1")
        $catalog = Get-QualityContractCatalog -RepositoryRoot $script:RepoRoot
        $selection = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @(".agents/skills/1c-workflow/scripts/lib/agent-1c.immutable-download.ps1")

        @($selection.contracts.id) | Should -Be @("immutable-download")
        foreach ($testPath in @(
            "tests/pester/DependencyLocks.Tests.ps1",
            "tests/pester/GitHubDependencyFallback.Tests.ps1",
            "tests/pester/LocalQualityGate.Tests.ps1",
            "tests/pester/ReleaseReadiness.Tests.ps1",
            "tests/pester/RoctupPortLifecycle.Tests.ps1",
            "tests/pester/VanessaArtifactIntegration.Tests.ps1"
        )) { @($selection.tests) | Should -Contain $testPath }
    }
}
