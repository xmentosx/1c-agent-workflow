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

    It "atomically replaces a stale cache file on Windows PowerShell" {
        $directory = Join-Path $TestDrive (([char]0x041A).ToString() + " cache with spaces")
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $source = Join-Path $directory "source.bin"
        $destination = Join-Path $directory "destination.bin"
        [IO.File]::WriteAllBytes($source, $script:Payload)
        [IO.File]::WriteAllText($destination, "stale payload", [Text.UTF8Encoding]::new($false))

        $result = Invoke-ItlImmutableFileAcquire -Source $source -DestinationPath $destination -ExpectedSha256 $script:PayloadSha256

        $result.published | Should -BeTrue
        (Get-ItlImmutableFileSha256 -Path $destination) | Should -Be $script:PayloadSha256
        @(Get-ChildItem -LiteralPath $directory -Filter "*.backup" -Force) | Should -BeNullOrEmpty
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
        $definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -in @("Get-DeliveryRemoteAssetDigest", "Get-DeliveryRemoteAssetState") }, $true))
        $definitions.Count | Should -Be 2
        foreach ($definition in $definitions) { Invoke-Expression $definition.Extent.Text }

        Mock Invoke-ItlImmutableFileDownload {
            $script:RequestCount++
            if ($script:RequestCount -le 7) {
                $failure = [Exception]::new("not yet visible")
                $failure.Data["StatusCode"] = 404
                throw $failure
            }
            return [pscustomobject]@{ sha256 = $script:PayloadSha256 }
        }
        $result = Get-DeliveryRemoteAssetState -Url "https://example.invalid/asset.bin" -ExpectedSha256 $script:PayloadSha256 -AvailabilityAttempts 12
        $result.status | Should -Be "matched"
        $script:RequestCount | Should -Be 8
        $script:SleepDelays.ToArray() | Should -Be @(2, 4, 6, 8, 10, 10, 10)

        $script:RequestCount = 0
        Mock Invoke-ItlImmutableFileDownload {
            $script:RequestCount++
            throw [IO.InvalidDataException]::new("identity mismatch")
        }
        {
            Get-DeliveryRemoteAssetState -Url "https://example.invalid/asset.bin" -ExpectedSha256 $script:PayloadSha256 -AvailabilityAttempts 12
        } | Should -Throw "*identity mismatch*"
        $script:RequestCount | Should -Be 1
    }

    It "routes every pinned artifact, cache migration, and post-gate verification GET through the policy" {
        $vanessa = Get-Content -LiteralPath (Join-Path $script:RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1") -Raw -Encoding UTF8
        $roctup = Get-Content -LiteralPath (Join-Path $script:RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.roctup-mcp.ps1") -Raw -Encoding UTF8
        $readiness = Get-Content -LiteralPath (Join-Path $script:RepoRoot "scripts\test-release-readiness.ps1") -Raw -Encoding UTF8
        $delivery = Get-Content -LiteralPath (Join-Path $script:RepoRoot "scripts\source-delivery-component.ps1") -Raw -Encoding UTF8
        $shards = Get-Content -LiteralPath (Join-Path $script:RepoRoot "scripts\invoke-pester-shards.ps1") -Raw -Encoding UTF8

        $vanessaTokens = $null
        $vanessaErrors = $null
        $vanessaAst = [Management.Automation.Language.Parser]::ParseInput($vanessa, [ref]$vanessaTokens, [ref]$vanessaErrors)
        @($vanessaErrors).Count | Should -Be 0
        $acquires = @($vanessaAst.FindAll({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-ItlImmutableFileAcquire'
        }, $true))
        $acquireOwners = @($acquires | ForEach-Object {
            $owner = $_.Parent
            while ($owner -and $owner -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $owner = $owner.Parent }
            $owner.Name
        })
        $legacyAcquireOwners = @(
            'Save-VanessaAutomationArchive', 'Install-VanessaAutomation',
            'Save-VanessaMcpPairedSourceBuildArtifact', 'Save-VanessaMcpArtifact', 'Install-VanessaMcpArtifact'
        )
        $acquires.Count | Should -Be 6
        @($acquireOwners | Where-Object { $_ -cne 'Save-VanessaMcpClientSourceBuildArtifact' } | Sort-Object) |
            Should -Be @($legacyAcquireOwners | Sort-Object)
        @($acquireOwners | Where-Object { $_ -ceq 'Save-VanessaMcpClientSourceBuildArtifact' }).Count | Should -Be 1

        # The approved scoped client CFE provider is an additional immutable route,
        # not a replacement of the five archive/cache/URL routes above.
        $sourceBuildOwners = @($vanessaAst.FindAll({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Save-VanessaMcpClientSourceBuildArtifact'
        }, $true))
        $sourceBuildOwners.Count | Should -Be 1
        $sourceBuildText = $sourceBuildOwners[0].Body.Extent.Text
        $sourceBuildText | Should -Match "GetEnvironmentVariable\('ITL_VANESSA_MCP_CLIENT_SOURCE_BUILD_CFE', 'Process'\)"
        $sourceBuildText | Should -Match ([regex]::Escape("`$Definition.lockKey -cne 'clientMcp'"))
        $sourceBuildText | Should -Match ([regex]::Escape("-Path 'source' -Default '') -cne 'workflow-pinned'"))
        $sourceBuildText | Should -Match ([regex]::Escape("`$lock -Path 'sha256' -Default ''"))
        $sourceBuildText | Should -Match ([regex]::Escape("Invoke-ItlImmutableFileAcquire -Source `$sourcePath -DestinationPath `$TargetPath -ExpectedSha256 `$expected -Label 'Vanessa UI MCP artifact clientMcp'"))
        $sourceBuildText | Should -Not -Match 'Invoke-WebRequest|Invoke-RestMethod|Start-BitsTransfer|Copy-Item|Move-Item|WriteAllBytes|WriteAllText|System\.Net\.WebClient'
        @([regex]::Matches($roctup, 'Invoke-ItlImmutableFileAcquire -Source')).Count | Should -Be 2
        $readiness | Should -Match 'Invoke-ItlImmutableFileDownload -Uri \(\[string\]\$Lock\.url\)'
        $delivery | Should -Match 'Invoke-ItlImmutableFileDownload -Uri \$Url'
        $delivery | Should -Match 'Get-DeliveryRemoteAssetState.*-AvailabilityAttempts 12'
        $shards | Should -Match 'Invoke-ItlImmutableFileDownload -Uri \$url.*-ExpectedSha256 \$expected'
        $yaxunit = Get-Content -LiteralPath (Join-Path $script:RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.yaxunit.ps1") -Raw -Encoding UTF8
        $yaxunit | Should -Match 'Get-ItlSharedArtifactPath -Family "yaxunit"'
        $yaxunit | Should -Match 'Invoke-ItlImmutableFileAcquire -Source \(ConvertFrom-FileUri -Value \(\[string\]\$entry\.url\)\) -DestinationPath \$cachePath'
        $yaxunit | Should -Not -Match 'Invoke-WebRequest|Invoke-RestMethod'
        $ondemand = Get-Content -LiteralPath (Join-Path $script:RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.ondemand-mcp.ps1") -Raw -Encoding UTF8
        $ondemand | Should -Match 'Invoke-ItlImmutableFileAcquire -Source \$url -DestinationPath \$targetPath'
        $ondemand | Should -Not -Match 'Invoke-WebRequest -Uri \$url'
    }

    It "maps a helper-only delta to every required consumer integration owner test" {
        . (Join-Path $script:RepoRoot "scripts\quality-contracts.ps1")
        $catalog = Get-QualityContractCatalog -RepositoryRoot $script:RepoRoot
        $selection = Resolve-QualityContractsForPaths -Catalog $catalog -Paths @(".agents/skills/1c-workflow/scripts/lib/agent-1c.immutable-download.ps1")

        # These consumers call the shared immutable download boundary directly.
        @($selection.contracts.id | Sort-Object) | Should -Be @("immutable-download", "pester-cache-compatibility", "pester-shard-identity", "release-readiness-tests")
        foreach ($testPath in @(
            "tests/pester/PesterCacheCompatibility.Tests.ps1",
            "tests/pester/PesterShardIdentity.Tests.ps1",
            "tests/pester/DependencyLocks.Tests.ps1",
            "tests/pester/GitHubDependencyFallback.Tests.ps1",
            "tests/pester/LocalQualityGate.Tests.ps1",
            "tests/pester/ReleaseReadiness.Tests.ps1",
            "tests/pester/RoctupPortLifecycle.Tests.ps1",
            "tests/pester/VanessaArtifactIntegration.Tests.ps1"
        )) { @($selection.tests) | Should -Contain $testPath }
    }
}

Describe "GitHub release asset API route" {
    BeforeAll {
        $script:GitHubUrl = "https://github.com/example-owner/example.repo/releases/download/v1.0%2Bitl/asset%20name.cfe"
        $script:ApiRepository = "https://api.github.com/repos/example-owner/example.repo"
        $script:CdnUrl = "https://release-assets.example.invalid/blob?sig=1"
        function New-ReleaseMetadata {
            param([string]$Digest = ("sha256:" + $script:PayloadSha256), [string]$Name = "asset name.cfe")
            return [pscustomobject]@{ assets = @([pscustomobject]@{ name = $Name; url = "$script:ApiRepository/releases/assets/42"; digest = $Digest }) }
        }
        function Get-UriText {
            param($Value)
            if ($Value -is [Uri]) { return $Value.OriginalString }
            return [string]$Value
        }
        function New-HttpFailure {
            param([int]$StatusCode, [string]$Message = "HTTP failure")
            $failure = [Exception]::new($Message)
            $failure.Data["StatusCode"] = $StatusCode
            return $failure
        }
    }

    BeforeEach {
        $script:SavedTokens = @{ GITHUB_TOKEN = [Environment]::GetEnvironmentVariable("GITHUB_TOKEN", "Process"); GH_TOKEN = [Environment]::GetEnvironmentVariable("GH_TOKEN", "Process") }
        [Environment]::SetEnvironmentVariable("GITHUB_TOKEN", $null, "Process")
        [Environment]::SetEnvironmentVariable("GH_TOKEN", $null, "Process")
        $script:ApiCalls = New-Object System.Collections.Generic.List[object]
        $script:RedirectCalls = New-Object System.Collections.Generic.List[object]
        $script:WebCalls = New-Object System.Collections.Generic.List[string]
        Mock Start-Sleep {}
        Mock Invoke-RestMethod { param($Uri, $Headers, $TimeoutSec) $script:ApiCalls.Add([pscustomobject]@{ uri = (Get-UriText $Uri); headers = $Headers.Clone() }) | Out-Null; New-ReleaseMetadata }
        Mock Get-ItlGitHubAssetRedirectLocation { param($Uri, $Headers, $TimeoutSeconds) $script:RedirectCalls.Add([pscustomobject]@{ uri = (Get-UriText $Uri); headers = $Headers.Clone() }) | Out-Null; $script:CdnUrl }
        Mock Invoke-WebRequest {
            param($Uri, $OutFile, $TimeoutSec, $Headers)
            $script:WebCalls.Add((Get-UriText $Uri)) | Out-Null
            if ($null -ne $Headers) { throw "body requests must not carry headers" }
            [IO.File]::WriteAllBytes($OutFile, $script:Payload)
        }
    }

    AfterEach {
        foreach ($name in $script:SavedTokens.Keys) { [Environment]::SetEnvironmentVariable($name, $script:SavedTokens[$name], "Process") }
    }

    It "downloads through the API without touching a failing web endpoint" {
        $destination = Join-Path $TestDrive "Кэш с пробелом\api.cfe"
        $result = Invoke-ItlImmutableFileDownload -Uri $script:GitHubUrl -DestinationPath $destination -ExpectedSha256 $script:PayloadSha256

        $result.route | Should -Be "api"
        $result.attempts | Should -Be 1
        $script:ApiCalls[0].uri | Should -BeExactly "$script:ApiRepository/releases/tags/v1.0%2Bitl"
        $script:RedirectCalls[0].uri | Should -BeExactly "$script:ApiRepository/releases/assets/42"
        $script:RedirectCalls[0].headers["Accept"] | Should -Be "application/octet-stream"
        @($script:WebCalls) | Should -Be @($script:CdnUrl)
        (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $script:PayloadSha256
    }

    It "keeps non-GitHub HTTPS sources on the direct route" {
        $result = Invoke-ItlImmutableFileDownload -Uri "https://example.invalid/releases/download/v1/asset.bin" -DestinationPath (Join-Path $TestDrive "direct.bin") -ExpectedSha256 $script:PayloadSha256
        $result.route | Should -Be "web"
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        @($script:WebCalls) | Should -Be @("https://example.invalid/releases/download/v1/asset.bin")
    }

    It "sends no credentials without a token and confines GITHUB_TOKEN to the API host" {
        [void](Invoke-ItlImmutableFileDownload -Uri $script:GitHubUrl -DestinationPath (Join-Path $TestDrive "anonymous.cfe") -ExpectedSha256 $script:PayloadSha256)
        $script:ApiCalls[0].headers.ContainsKey("Authorization") | Should -BeFalse
        $script:RedirectCalls[0].headers.ContainsKey("Authorization") | Should -BeFalse

        $script:ApiCalls.Clear(); $script:RedirectCalls.Clear()
        [Environment]::SetEnvironmentVariable("GITHUB_TOKEN", "primary-secret", "Process")
        [Environment]::SetEnvironmentVariable("GH_TOKEN", "secondary-secret", "Process")
        [void](Invoke-ItlImmutableFileDownload -Uri $script:GitHubUrl -DestinationPath (Join-Path $TestDrive "token.cfe") -ExpectedSha256 $script:PayloadSha256)
        $script:ApiCalls[0].headers["Authorization"] | Should -BeExactly "Bearer primary-secret"
        $script:RedirectCalls[0].headers["Authorization"] | Should -BeExactly "Bearer primary-secret"
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly -ParameterFilter { $null -eq $Headers -and (Get-UriText $Uri) -ceq $script:CdnUrl }
    }

    It "uses the same token precedence as the core GitHub API headers" {
        $core = Get-Content -LiteralPath (Join-Path $script:RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.core.ps1") -Raw -Encoding UTF8
        $core | Should -Match '(?s)function Get-GitHubApiHeaders.*?"GITHUB_TOKEN".*?"GH_TOKEN"'
        [Environment]::SetEnvironmentVariable("GH_TOKEN", "secondary-only", "Process")
        Get-ItlGitHubApiToken | Should -BeExactly "secondary-only"
    }

    It "falls back to the locked URL once when the API route fails with <case>" -TestCases @(
        @{ case = "a rate limit"; mode = "rest"; status = 403 }
        @{ case = "a secondary limit"; mode = "rest"; status = 429 }
        @{ case = "a server error"; mode = "rest"; status = 503 }
        @{ case = "a missing asset"; mode = "missing"; status = 0 }
        @{ case = "a failed redirect"; mode = "redirect"; status = 502 }
    ) {
        param($case, $mode, $status)
        [Environment]::SetEnvironmentVariable("GITHUB_TOKEN", "fallback-secret", "Process")
        $script:FailureMode = $mode; $script:FailureStatus = $status
        Mock Invoke-RestMethod {
            if ($script:FailureMode -eq "rest") { throw (New-HttpFailure -StatusCode $script:FailureStatus -Message "API refused fallback-secret") }
            if ($script:FailureMode -eq "missing") { return (New-ReleaseMetadata -Name "other.cfe") }
            New-ReleaseMetadata
        }
        Mock Get-ItlGitHubAssetRedirectLocation { throw (New-HttpFailure -StatusCode $script:FailureStatus -Message "bad gateway") }

        $result = Invoke-ItlImmutableFileDownload -Uri $script:GitHubUrl -DestinationPath (Join-Path $TestDrive "fallback-$mode-$status.cfe") -ExpectedSha256 $script:PayloadSha256 -WarningVariable warnings -WarningAction SilentlyContinue

        $result.route | Should -Be "web"
        @($script:WebCalls) | Should -Be @($script:GitHubUrl)
        @($warnings).Count | Should -Be 1
        [string]$warnings[0] | Should -Match "falling back to the locked release URL"
        [string]$warnings[0] | Should -Not -Match "fallback-secret"
    }

    It "fails closed before any body request when the GitHub digest disagrees with the lock" {
        Mock Invoke-RestMethod { New-ReleaseMetadata -Digest ("sha256:" + ("0" * 64)) }
        { Invoke-ItlImmutableFileDownload -Uri $script:GitHubUrl -DestinationPath (Join-Path $TestDrive "digest.cfe") -ExpectedSha256 $script:PayloadSha256 } |
            Should -Throw "*SHA256 mismatch*github-digest*"
        Should -Invoke Get-ItlGitHubAssetRedirectLocation -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It "names both routes, keeps the web status and preserves the target when both fail" {
        $destination = Join-Path $TestDrive "both-fail.cfe"
        [IO.File]::WriteAllBytes($destination, [byte[]](9, 9, 9))
        Mock Invoke-RestMethod { throw (New-HttpFailure -StatusCode 503 -Message "api unavailable") }
        Mock Invoke-WebRequest { $script:WebCalls.Add((Get-UriText $Uri)) | Out-Null; throw (New-HttpFailure -StatusCode 504 -Message "gateway timeout") }

        $failure = $null
        try { Invoke-ItlImmutableFileDownload -Uri $script:GitHubUrl -DestinationPath $destination -ExpectedSha256 $script:PayloadSha256 -WarningAction SilentlyContinue } catch { $failure = $_ }

        $failure | Should -Not -BeNullOrEmpty
        $failure.Exception.Message | Should -Match "both routes"
        $failure.Exception.Message | Should -Match "GitHub API route HTTP 503"
        $failure.Exception.Message | Should -Match "locked release URL HTTP 504"
        Get-ItlHttpFailureStatusCode -ErrorRecord $failure | Should -Be 504
        $script:WebCalls.Count | Should -Be 3
        [IO.File]::ReadAllBytes($destination) | Should -Be ([byte[]](9, 9, 9))

        Mock Invoke-WebRequest { throw (New-HttpFailure -StatusCode 404 -Message "not found") }
        $missing = $null
        try { Invoke-ItlImmutableFileDownload -Uri $script:GitHubUrl -DestinationPath (Join-Path $TestDrive "missing.cfe") -ExpectedSha256 $script:PayloadSha256 -WarningAction SilentlyContinue } catch { $missing = $_ }
        Get-ItlHttpFailureStatusCode -ErrorRecord $missing | Should -Be 404
        Test-ItlTransientImmutableDownloadFailure -ErrorRecord $missing | Should -BeFalse
    }
}

Describe "GitHub asset redirect primitive" {
    It "reads the asset redirect without following it and sends API headers to the API endpoint" {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $runspace = [powershell]::Create()
        try {
            $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
            [void]$runspace.AddScript({
                param($Listener)
                $client = $Listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $buffer = New-Object byte[] 8192
                    $request = ""
                    while ($request -notmatch "`r`n`r`n") { $read = $stream.Read($buffer, 0, $buffer.Length); if ($read -le 0) { break }; $request += [Text.Encoding]::ASCII.GetString($buffer, 0, $read) }
                    $response = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 302 Found`r`nLocation: https://release-assets.example.invalid/blob?sig=1`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                    $stream.Write($response, 0, $response.Length)
                    $stream.Flush()
                    return $request
                } finally { $client.Close() }
            }).AddArgument($listener)
            $pending = $runspace.BeginInvoke()
            $headers = @{ "User-Agent" = "1c-agent-workflow"; "Accept" = "application/octet-stream"; "Authorization" = "Bearer listener-secret"; "X-GitHub-Api-Version" = "2022-11-28" }

            $location = Get-ItlGitHubAssetRedirectLocation -Uri "http://127.0.0.1:$port/repos/o/r/releases/assets/42" -Headers $headers -TimeoutSeconds 10
            $request = [string]($runspace.EndInvoke($pending) | Select-Object -Last 1)

            $location | Should -BeExactly "https://release-assets.example.invalid/blob?sig=1"
            $request | Should -Match "(?m)^Authorization: Bearer listener-secret\r?$"
            $request | Should -Match "(?m)^Accept: application/octet-stream\r?$"
        } finally {
            $runspace.Dispose()
            $listener.Stop()
        }
    }
}
