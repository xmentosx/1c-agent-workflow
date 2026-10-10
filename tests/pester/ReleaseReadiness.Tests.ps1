$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$RunnerPath = Join-Path $RepoRoot "scripts\test-release-readiness.ps1"

Describe "Deterministic Release readiness" {
    BeforeAll {
        $script:ReadinessRunnerPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "scripts\test-release-readiness.ps1"
        . (Join-Path (Split-Path -Parent $script:ReadinessRunnerPath) 'stand-env-identity.ps1')
        function Write-Utf8Json {
            param([string]$Path, [object]$Value)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
            [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
        }

        function New-ReadinessFixture {
            param([string]$Root)
            New-Item -ItemType Directory -Force -Path $Root | Out-Null
            & git -C $Root init -b master | Out-Null
            & git -C $Root config user.email "tests@example.invalid"
            & git -C $Root config user.name "Release Tests"
            [System.IO.File]::WriteAllText((Join-Path $Root ".gitignore"), "build/`n", [System.Text.UTF8Encoding]::new($false))
            $assetName = "vanessa-test.zip"
            $assetPath = Join-Path $Root "build\third-party\vanessa-automation\1.2.3-itl-r1\$assetName"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $assetPath) | Out-Null
            $assetStage = Join-Path $Root "build\fixture-stage"
            New-Item -ItemType Directory -Force -Path $assetStage | Out-Null
            $epfPath = Join-Path $assetStage "vanessa-automation-single.epf"
            [System.IO.File]::WriteAllBytes($epfPath, [byte[]](1, 2, 3, 4, 5))
            $epfSha = (Get-FileHash -LiteralPath $epfPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $pairedExtensionName = "VAExtension.1.32-itl-r1.cfe"
            $pairedExtensionPath = Join-Path $assetStage $pairedExtensionName
            [System.IO.File]::WriteAllBytes($pairedExtensionPath, [byte[]](6, 7, 8, 9))
            $pairedExtensionSha = (Get-FileHash -LiteralPath $pairedExtensionPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $patchSha = ("3" * 64)
            $upstreamCommit = ("4" * 40)
            $provenance = [ordered]@{
                compatibilityVersion = "1.2.3"
                downstreamRevision = "itl-r1"
                upstream = [ordered]@{ commit = $upstreamCommit }
                patch = [ordered]@{ sha256 = $patchSha }
                artifact = [ordered]@{ fileName = $assetName; entryPoint = "vanessa-automation-single.epf" }
                pairedExtension = [ordered]@{ required = $true; fileName = $pairedExtensionName; protocol = "itl-file-code-v1" }
            }
            Write-Utf8Json -Path (Join-Path $assetStage "ITL-PROVENANCE.json") -Value $provenance
            [System.IO.File]::WriteAllText((Join-Path $assetStage "ITL-NOTICE.txt"), "fixture`n", [System.Text.UTF8Encoding]::new($false))
            Compress-Archive -Path (Join-Path $assetStage "*") -DestinationPath $assetPath
            $assetSha = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifestSha = (Get-FileHash -LiteralPath (Join-Path $assetStage "ITL-PROVENANCE.json") -Algorithm SHA256).Hash.ToLowerInvariant()
            $vanessa = [ordered]@{
                version = "1.2.3"
                compatibilityVersion = "1.2.3"
                downstreamRevision = "itl-r1"
                assetName = $assetName
                releaseTag = "vanessa-test"
                url = "https://example.invalid/$assetName"
                sha256 = $assetSha
                epfSha256 = $epfSha
                manifestSha256 = $manifestSha
                patchSha256 = $patchSha
                upstreamCommit = $upstreamCommit
                source = "workflow-pinned"
            }
            $lock = [ordered]@{
                schemaVersion = 1
                dependencies = [ordered]@{
                    workflowPackage = [ordered]@{ repo = "https://example.invalid/workflow.git"; ref = "master"; commit = "" }
                    aiRules1c = [ordered]@{ ref = "itl-test"; commit = ("5" * 40) }
                    vanessaAutomation = $vanessa
                    vanessaMcp = [ordered]@{ vaExtension = [ordered]@{
                        version = "1.2.3"; assetName = $pairedExtensionName; releaseTag = "vanessa-test"
                        url = "https://example.invalid/$pairedExtensionName"; sha256 = $pairedExtensionSha
                        protocol = "itl-file-code-v1"; source = "workflow-pinned"
                    } }
                }
            }
            Write-Utf8Json -Path (Join-Path $Root "templates\dependency-lock.json") -Value $lock
            $compatibility = [ordered]@{
                families = [ordered]@{
                    "vanessa-ui" = [ordered]@{
                        backendVersions = [ordered]@{ vanessaAutomation = $vanessa.compatibilityVersion; vaExtension = "1.2.3" }
                        backendRevisions = [ordered]@{ vanessaAutomation = $vanessa.downstreamRevision }
                        vanessaAutomationArtifact = [ordered]@{
                            archiveSha256 = $vanessa.sha256
                            epfSha256 = $vanessa.epfSha256
                            manifestSha256 = $vanessa.manifestSha256
                            patchSha256 = $vanessa.patchSha256
                            upstreamCommit = $vanessa.upstreamCommit
                        }
                        pairedExtensionArtifact = [ordered]@{ assetName = $pairedExtensionName; sha256 = $pairedExtensionSha; protocol = "itl-file-code-v1" }
                    }
                }
            }
            Write-Utf8Json -Path (Join-Path $Root ".agents\skills\1c-workflow\assets\ondemand-mcp\compatibility.json") -Value $compatibility
            New-Item -ItemType Directory -Force -Path (Join-Path $Root ".agents\skills\1c-workflow\scripts") | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $Root ".agents\skills\1c-workflow\scripts\agent-1c.ps1"), "param()`n", [System.Text.UTF8Encoding]::new($false))
            New-Item -ItemType Directory -Force -Path (Join-Path $Root "scripts") | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $Root "scripts\invoke-release-e2e.ps1"), "param()`n", [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $Root "AGENT-INSTALL.md"), "fixture`n", [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $Root "install-agent-1c-workflow.ps1"), "param()`n", [System.Text.UTF8Encoding]::new($false))
            & git -C $Root add -- .
            & git -C $Root commit -m "fixture" | Out-Null
            $commit = (& git -C $Root rev-parse HEAD).Trim()
            $lock.dependencies.workflowPackage.commit = $commit
            Write-Utf8Json -Path (Join-Path $Root "templates\dependency-lock.json") -Value $lock
            & git -C $Root add -- templates/dependency-lock.json
            & git -C $Root commit -m "pin fixture" | Out-Null
            & git -C $Root update-ref refs/remotes/origin/master HEAD
            return [pscustomobject]@{ root = $Root; assetPath = $assetPath; pairedExtensionPath = $pairedExtensionPath; lock = $lock; compatibility = $compatibility }
        }

        function Invoke-ReadinessFixture {
            param([string]$Root, [string]$OutputPath, [string]$Mode = "Full", [string]$E2EProjectRoot = "", [string]$ResumeMode = "Auto")
            $quote = { param([string]$Value) '"' + $Value.Replace('"', '\"') + '"' }
            $arguments = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (& $quote $script:ReadinessRunnerPath), "-Mode", (& $quote $Mode), "-RepositoryRoot", (& $quote $Root), "-OutputPath", (& $quote $OutputPath), "-ResumeMode", (& $quote $ResumeMode), "-Offline")
            if ($E2EProjectRoot) { $arguments += @("-E2EProjectRoot", (& $quote $E2EProjectRoot)) }
            $stdoutPath = $OutputPath + ".stdout.log"
            $stderrPath = $OutputPath + ".stderr.log"
            $process = Start-Process -FilePath "powershell.exe" -ArgumentList ($arguments -join " ") -WindowStyle Hidden `
                -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
            $null = $process.Handle
            $process.WaitForExit()
            $process.Refresh()
            if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
                $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { "" }
                $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { "" }
                throw "Readiness child produced no context; exit=$([int]$process.ExitCode); stdout=$stdout; stderr=$stderr"
            }
            return [int]$process.ExitCode
        }
    }

    It "allows stand commit continuation only with exact Targeted proof outside develop scope" {
        $runner = Get-Content -LiteralPath $script:ReadinessRunnerPath -Raw -Encoding UTF8
        $runner | Should -Match 'Get-WorkflowContinuationProof.*-QualifiedCommit \$installedWorkflowCommit'
        $runner | Should -Match 'standContinuation\.scopes.*-contains "develop"'
        $runner | Should -Match 'Test-ManagedPackageAgreement -ExpectedInventory \$managedInventory'
        $encodingBody = [regex]::Match($runner, '(?s)function Test-PowerShellEncoding \{(?<body>.*?)\n\}').Groups['body'].Value
        $encodingBody | Should -Match 'test-powershell-encoding\.ps1'
        $encodingBody | Should -Match 'ReportOnly'
        $encodingRunner = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $script:ReadinessRunnerPath) "test-powershell-encoding.ps1") -Raw -Encoding UTF8
        @([regex]::Matches($encodingRunner, 'Start-Process -FilePath "powershell\.exe"')).Count | Should -Be 1
        $encodingRunner.IndexOf('Start-Process -FilePath "powershell.exe"') | Should -BeLessThan $encodingRunner.IndexOf('foreach ($relativePath')
    }

    It "resolves the canonical immutable archive and writes a passed Full context" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-release-readiness-pass-" + [guid]::NewGuid().ToString("N"))
        try {
            $fixture = New-ReadinessFixture -Root (Join-Path $tempRoot "workflow")
            $outputPath = Join-Path $tempRoot "release-context.json"
            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath | Out-Null
            $context = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $context.status | Should -Be "passed"
            $context.artifacts.vanessaAutomation.path | Should -Be $fixture.assetPath
            @($context.issues).Count | Should -Be 0
        } finally {
            if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
        }
    }

    It "aggregates missing archive and compatibility drift before Pester" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-release-readiness-drift-" + [guid]::NewGuid().ToString("N"))
        try {
            $fixture = New-ReadinessFixture -Root (Join-Path $tempRoot "workflow")
            Remove-Item -LiteralPath $fixture.assetPath -Force
            $fixture.compatibility.families.'vanessa-ui'.backendRevisions.vanessaAutomation = "itl-stale"
            Write-Utf8Json -Path (Join-Path $fixture.root ".agents\skills\1c-workflow\assets\ondemand-mcp\compatibility.json") -Value $fixture.compatibility
            $outputPath = Join-Path $tempRoot "release-context.json"
            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath | Out-Null
            $context = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $context.status | Should -Be "failed"
            $codes = @($context.issues.code)
            $codes | Should -Contain "RELEASE_VANESSA_ARCHIVE_MISSING"
            $codes | Should -Contain "RELEASE_COMPATIBILITY_LOCK_DRIFT"
        } finally {
            if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
        }
    }

    It "rejects an archive whose internal EPF differs from the immutable lock" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-release-readiness-epf-" + [guid]::NewGuid().ToString("N"))
        try {
            $fixture = New-ReadinessFixture -Root (Join-Path $tempRoot "workflow")
            $lockPath = Join-Path $fixture.root "templates\dependency-lock.json"
            $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $lock.dependencies.vanessaAutomation.epfSha256 = ("0" * 64)
            Write-Utf8Json -Path $lockPath -Value $lock
            $compatibilityPath = Join-Path $fixture.root ".agents\skills\1c-workflow\assets\ondemand-mcp\compatibility.json"
            $compatibility = Get-Content -LiteralPath $compatibilityPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $compatibility.families.'vanessa-ui'.vanessaAutomationArtifact.epfSha256 = ("0" * 64)
            Write-Utf8Json -Path $compatibilityPath -Value $compatibility
            $outputPath = Join-Path $tempRoot "release-context.json"
            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath | Out-Null
            $context = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $context.status | Should -Be "failed"
            @($context.issues.code) | Should -Contain "RELEASE_VANESSA_EPF_HASH_MISMATCH"
        } finally {
            if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
        }
    }

    It "rejects a paired VAExtension whose bytes differ from its immutable lock" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-release-readiness-cfe-" + [guid]::NewGuid().ToString("N"))
        try {
            $fixture = New-ReadinessFixture -Root (Join-Path $tempRoot "workflow")
            $lockPath = Join-Path $fixture.root "templates\dependency-lock.json"
            $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $lock.dependencies.vanessaMcp.vaExtension.sha256 = ("0" * 64)
            Write-Utf8Json -Path $lockPath -Value $lock
            $compatibilityPath = Join-Path $fixture.root ".agents\skills\1c-workflow\assets\ondemand-mcp\compatibility.json"
            $compatibility = Get-Content -LiteralPath $compatibilityPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $compatibility.families.'vanessa-ui'.pairedExtensionArtifact.sha256 = ("0" * 64)
            Write-Utf8Json -Path $compatibilityPath -Value $compatibility
            $outputPath = Join-Path $tempRoot "release-context.json"
            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath | Out-Null
            $context = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $context.status | Should -Be "failed"
            @($context.issues.code) | Should -Contain "RELEASE_VANESSA_PAIRED_EXTENSION_HASH_MISMATCH"
        } finally {
            if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
        }
    }

    It "rejects stale Release stand state, checkpoint identity, fixture boundary, and verification before 1C" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-release-readiness-stand-" + [guid]::NewGuid().ToString("N"))
        try {
            $fixture = New-ReadinessFixture -Root (Join-Path $tempRoot "workflow")
            $e2eRoot = Join-Path $tempRoot "e2e"
            $worktreeRoot = Join-Path $tempRoot "e2e-worktree"
            New-Item -ItemType Directory -Force -Path $e2eRoot, $worktreeRoot | Out-Null
            $config = [ordered]@{ schemaVersion = 1; devBranchName = "release-test"; worktreePath = $worktreeRoot }
            Write-Utf8Json -Path (Join-Path $e2eRoot ".agent-1c\release-e2e.json") -Value $config
            foreach ($root in @($e2eRoot, $worktreeRoot)) {
                & git -C $root init -b $(if ($root -eq $worktreeRoot) { "itldev/release-test" } else { "master" }) | Out-Null
                & git -C $root config user.email "tests@example.invalid"
                & git -C $root config user.name "Release Tests"
                Copy-Item -LiteralPath (Join-Path $fixture.root ".agents") -Destination $root -Recurse
                Copy-Item -LiteralPath (Join-Path $fixture.root "templates") -Destination $root -Recurse
                Copy-Item -LiteralPath (Join-Path $fixture.root "AGENT-INSTALL.md") -Destination $root
                Copy-Item -LiteralPath (Join-Path $fixture.root "install-agent-1c-workflow.ps1") -Destination $root
                [System.IO.File]::WriteAllText((Join-Path $root ".agents\skills\1c-workflow\scripts\agent-1c.ps1"), "param()`r`n", [System.Text.UTF8Encoding]::new($false))
                [System.IO.File]::WriteAllText((Join-Path $root "AGENT-INSTALL.md"), "fixture`r`n", [System.Text.UTF8Encoding]::new($false))
                [System.IO.File]::WriteAllText((Join-Path $root "install-agent-1c-workflow.ps1"), "param()`r`n", [System.Text.UTF8Encoding]::new($false))
                $staleLock = $fixture.lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
                $staleLock.dependencies.workflowPackage.commit = ("0" * 40)
                $staleLock.dependencies.vanessaAutomation.downstreamRevision = "itl-stale"
                Write-Utf8Json -Path (Join-Path $root ".agent-1c\dependency-lock.json") -Value $staleLock
                Write-Utf8Json -Path (Join-Path $root ".agent-1c\project.json") -Value ([ordered]@{ schemaVersion = 1; fixture = $true })
                [System.IO.File]::WriteAllText((Join-Path $root ".gitignore"), ".agent-1c/dev-branches/`n.agent-1c/runs/`n", [System.Text.UTF8Encoding]::new($false))
                & git -C $root add -- .
                & git -C $root commit -m "stand" | Out-Null
            }
            Write-Utf8Json -Path (Join-Path $worktreeRoot ".agent-1c\dev-branches\release-test.json") -Value ([ordered]@{ unsafeActionProtectionConfirmed = $false })
            $checkpointRoot = Join-Path $worktreeRoot ".agent-1c\runs\release-e2e\release-test"
            $savedStatePath = Join-Path $checkpointRoot "state\post-config.json"
            Write-Utf8Json -Path $savedStatePath -Value ([ordered]@{ lastVerificationStatus = "passed"; lastVerifiedAt = "2020-01-01T00:00:00Z" })
            $candidateCommit = (& git -C $fixture.root rev-parse HEAD).Trim()
            $candidateTree = (& git -C $fixture.root rev-parse 'HEAD^{tree}').Trim()
            $canonicalSha = {
                param([string]$Path)
                $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false)).Replace("`r`n", "`n").Replace("`r", "`n")
                $sha = [Security.Cryptography.SHA256]::Create()
                try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
            }
            $outsideFixturePath = Join-Path $tempRoot "outside\ITLReleaseFourFlat.feature"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outsideFixturePath) | Out-Null
            [IO.File]::WriteAllText($outsideFixturePath, "fixture`n", [Text.UTF8Encoding]::new($false))
            Write-Utf8Json -Path (Join-Path $checkpointRoot "checkpoint.json") -Value ([ordered]@{
                schemaVersion = 3
                createdAt = [DateTime]::UtcNow.ToString("o")
                expectedHead = ("f" * 40)
                identity = [ordered]@{
                    projectRoot = $e2eRoot; worktreePath = $worktreeRoot; branch = "itldev/release-test"
                    workflowCommit = $candidateCommit; workflowTree = $candidateTree
                    runnerSha256 = (& $canonicalSha (Join-Path $fixture.root "scripts\invoke-release-e2e.ps1"))
                    aiRulesCommit = ""
                    helperSha256 = (& $canonicalSha (Join-Path $fixture.root ".agents\skills\1c-workflow\scripts\agent-1c.ps1"))
                    projectConfigSha256 = (Get-FileHash -LiteralPath (Join-Path $worktreeRoot ".agent-1c\project.json") -Algorithm SHA256).Hash.ToLowerInvariant()
                    clientSelection = Get-SourceE2EClientIdentity -ProjectRoot $e2eRoot
                }
                configEvidence = [ordered]@{ featurePath = $outsideFixturePath }
                snapshots = [ordered]@{ baseline = [ordered]@{ path = (Join-Path $checkpointRoot 'snapshots\baseline.dt'); sha256 = ('a' * 64) } }
                stages = [ordered]@{ "verification-refresh" = [ordered]@{ status = "passed" } }
                stateFiles = [ordered]@{ postConfig = [ordered]@{ stateCopyPath = $savedStatePath } }
            })
            $outputPath = Join-Path $tempRoot "release-context.json"
            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath -Mode "Release" -E2EProjectRoot $e2eRoot | Out-Null
            $context = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $context.status | Should -Be "failed"
            $codes = @($context.issues.code)
            $codes | Should -Contain "RELEASE_DEPENDENCY_LOCK_DRIFT"
            $codes | Should -Contain "RELEASE_STAND_WORKFLOW_COMMIT_DRIFT"
            $codes | Should -Contain "RELEASE_STAND_UNSAFE_ACTION_PROTECTION_UNCONFIRMED"
            $codes | Should -Contain "RELEASE_STAND_WORKTREE_FOREIGN"
            $codes | Should -Contain "RELEASE_CHECKPOINT_HEAD_MISMATCH"
            $codes | Should -Contain "RELEASE_CHECKPOINT_FIXTURE_INVALID"
            $codes | Should -Contain "RELEASE_CHECKPOINT_SNAPSHOT_INVALID"
            $codes | Should -Contain "RELEASE_CHECKPOINT_VERIFICATION_STALE"
            $codes | Should -Contain "RELEASE_STAND_MARKER_MISSING"
            $codes | Should -Not -Contain "RELEASE_STAND_MANAGED_PACKAGE_DRIFT"
            (Get-Content -LiteralPath (Join-Path $checkpointRoot "checkpoint.json") -Raw -Encoding UTF8 | ConvertFrom-Json).expectedHead | Should -Be ("f" * 40)

            $checkpoint = Get-Content -LiteralPath (Join-Path $checkpointRoot "checkpoint.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $checkpoint.configEvidence.featurePath = Join-Path $worktreeRoot "tests\features\missing.feature"
            Write-Utf8Json -Path (Join-Path $checkpointRoot "checkpoint.json") -Value $checkpoint
            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath -Mode "Release" -E2EProjectRoot $e2eRoot | Out-Null
            $context = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            @($context.issues.code) | Should -Contain "RELEASE_CHECKPOINT_FIXTURE_INVALID"

            $checkpoint.identity.runnerSha256 = ("0" * 64)
            Write-Utf8Json -Path (Join-Path $checkpointRoot "checkpoint.json") -Value $checkpoint
            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath -Mode "Release" -E2EProjectRoot $e2eRoot | Out-Null
            $context = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            @($context.issues.code) | Should -Not -Contain "RELEASE_CHECKPOINT_HEAD_MISMATCH"
            @($context.issues.code) | Should -Contain 'RELEASE_CHECKPOINT_TRANSITION_UNPROVEN'

            $checkpoint.schemaVersion = 2
            Write-Utf8Json -Path (Join-Path $checkpointRoot "checkpoint.json") -Value $checkpoint
            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath -Mode "Release" -E2EProjectRoot $e2eRoot | Out-Null
            $context = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            @($context.issues.code) | Should -Contain "RELEASE_CHECKPOINT_UPGRADE_REQUIRED"

            $candidateCommit = (& git -C $fixture.root rev-parse HEAD).Trim()
            $masterLock = $fixture.lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
            $masterLock.dependencies.workflowPackage.commit = $candidateCommit
            Write-Utf8Json -Path (Join-Path $e2eRoot ".agent-1c\dependency-lock.json") -Value $masterLock
            [IO.File]::WriteAllText((Join-Path $worktreeRoot "AGENT-INSTALL.md"), "stale release branch`n", [Text.UTF8Encoding]::new($false))
            & git -C $worktreeRoot add -- AGENT-INSTALL.md
            & git -C $worktreeRoot commit -m "make release branch stale" | Out-Null

            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath -Mode "Release" -E2EProjectRoot $e2eRoot | Out-Null
            $context = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            @($context.issues.code) | Should -Contain "RELEASE_STAND_MANAGED_PACKAGE_DRIFT"
            @($context.issues.code) | Should -Contain "RELEASE_DEPENDENCY_LOCK_DRIFT"
            @($context.issues.code) | Should -Contain "RELEASE_STAND_WORKFLOW_COMMIT_DRIFT"

            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath -Mode "Release" -E2EProjectRoot $e2eRoot -ResumeMode "Restart" | Out-Null
            $context = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            @($context.issues.code) | Should -Not -Contain "RELEASE_STAND_MANAGED_PACKAGE_DRIFT"
            @($context.issues.code) | Should -Not -Contain "RELEASE_DEPENDENCY_LOCK_DRIFT"
            @($context.issues.code) | Should -Not -Contain "RELEASE_STAND_WORKFLOW_COMMIT_DRIFT"
        } finally {
            if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
        }
    }

    It "allows the runner to refresh a clean owned Release branch before creating a checkpoint" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-release-refresh-" + [guid]::NewGuid().ToString('N'))
        try {
            $fixture = New-ReadinessFixture -Root (Join-Path $tempRoot 'workflow')
            $e2eRoot = Join-Path $tempRoot 'e2e'
            $worktreeRoot = Join-Path $tempRoot 'e2e-release'
            New-Item -ItemType Directory -Force -Path $e2eRoot | Out-Null
            & git -C $e2eRoot init -b master | Out-Null
            & git -C $e2eRoot config user.email 'tests@example.invalid'
            & git -C $e2eRoot config user.name 'Release Tests'
            foreach ($name in @('.agents', 'templates', 'scripts', 'AGENT-INSTALL.md', 'install-agent-1c-workflow.ps1')) {
                Copy-Item -LiteralPath (Join-Path $fixture.root $name) -Destination $e2eRoot -Recurse
            }
            $lock = $fixture.lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
            $lock.dependencies.workflowPackage.commit = (& git -C $fixture.root rev-parse HEAD).Trim()
            Write-Utf8Json -Path (Join-Path $e2eRoot '.agent-1c\dependency-lock.json') -Value $lock
            Write-Utf8Json -Path (Join-Path $e2eRoot '.agent-1c\project.json') -Value ([ordered]@{ masterBranch='master' })
            [IO.File]::WriteAllText((Join-Path $e2eRoot '.gitignore'), ".agent-1c/dev-branches/`n.agent-1c/runs/`n.agent-1c/release-e2e.json`n", [Text.UTF8Encoding]::new($false))
            & git -C $e2eRoot add -- .
            & git -C $e2eRoot commit -m 'stand baseline' | Out-Null
            & git -C $e2eRoot worktree add --quiet -b 'itldev/release-refresh' $worktreeRoot master
            Write-Utf8Json -Path (Join-Path $e2eRoot '.agent-1c\release-e2e.json') -Value ([ordered]@{
                schemaVersion=1; devBranchName='release-refresh'; worktreePath=$worktreeRoot
            })
            Write-Utf8Json -Path (Join-Path $worktreeRoot '.agent-1c\dev-branches\release-refresh.json') -Value ([ordered]@{
                unsafeActionProtectionConfirmed=$true
            })
            $markerPath = Join-Path $e2eRoot 'tests\features\workflow-release-e2e.feature'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $markerPath) | Out-Null
            [IO.File]::WriteAllText($markerPath, "# release marker`n", [Text.UTF8Encoding]::new($false))
            & git -C $e2eRoot add -- tests/features/workflow-release-e2e.feature
            & git -C $e2eRoot commit -m 'fixture marker' | Out-Null
            $outputPath = Join-Path $tempRoot 'release-context.json'
            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath -Mode Release -E2EProjectRoot $e2eRoot | Out-Null
            $context = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $codes = @($context.issues.code)
            $codes | Should -Not -Contain 'RELEASE_STAND_MANAGED_PACKAGE_DRIFT'
            $codes | Should -Not -Contain 'RELEASE_STAND_WORKFLOW_COMMIT_DRIFT'
            $codes | Should -Not -Contain 'RELEASE_STAND_MARKER_MISSING'
            $context.stand.checkpoint.status | Should -Be 'absent'

            [IO.File]::AppendAllText((Join-Path $worktreeRoot 'AGENT-INSTALL.md'), "dirty`n", [Text.Encoding]::UTF8)
            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath -Mode Release -E2EProjectRoot $e2eRoot | Out-Null
            $dirty = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            @($dirty.issues.code) | Should -Contain 'RELEASE_STAND_DIRTY'
            @($dirty.issues.code) | Should -Contain 'RELEASE_STAND_MARKER_MISSING'

            & git -C $worktreeRoot restore -- AGENT-INSTALL.md
            [IO.File]::WriteAllText((Join-Path $worktreeRoot 'untracked-note.txt'), "unexpected`n", [Text.UTF8Encoding]::new($false))
            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath -Mode Release -E2EProjectRoot $e2eRoot | Out-Null
            $untracked = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            @($untracked.issues.code) | Should -Contain 'RELEASE_STAND_DIRTY'
            @($untracked.issues.code) | Should -Contain 'RELEASE_STAND_MARKER_MISSING'
        } finally {
            if (Test-Path -LiteralPath $e2eRoot) { & git -C $e2eRoot worktree remove --force $worktreeRoot 2>$null | Out-Null }
            if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
        }
    }

    It "compares managed Python sources independently of generated caches for <Kind>" -TestCases @(
        @{ Kind = 'cache-only'; ExpectedDrift = $false },
        @{ Kind = 'modified-source'; ExpectedDrift = $true },
        @{ Kind = 'missing-source'; ExpectedDrift = $true },
        @{ Kind = 'extra-source'; ExpectedDrift = $true }
    ) {
        param([string]$Kind, [bool]$ExpectedDrift)
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-package-cache проверка " + [guid]::NewGuid().ToString('N'))
        try {
            $fixture = New-ReadinessFixture -Root (Join-Path $tempRoot 'workflow исходники')
            $relativeSource = '.agents/skills/itl-remote-runner/scripts/itl_remote/probe.py'
            $sourcePath = Join-Path $fixture.root $relativeSource
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sourcePath) | Out-Null
            $sourceBytes = [Text.Encoding]::UTF8.GetBytes("# проверка пакета`r`nvalue = 7`r`n")
            [IO.File]::WriteAllBytes($sourcePath, $sourceBytes)
            & git -C $fixture.root add -- $relativeSource
            & git -C $fixture.root commit -m 'owned Python package source' | Out-Null
            $candidateCommit = (& git -C $fixture.root rev-parse HEAD).Trim()
            $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
            $e2eRoot = Join-Path $tempRoot 'e2e стенд'
            $worktreeRoot = Join-Path $tempRoot 'e2e ветка'
            New-Item -ItemType Directory -Force -Path $e2eRoot | Out-Null
            & git -C $e2eRoot init -b master | Out-Null
            & git -C $e2eRoot config user.email 'tests@example.invalid'
            & git -C $e2eRoot config user.name 'Release Tests'
            foreach ($name in @('.agents', 'templates', 'scripts', 'AGENT-INSTALL.md', 'install-agent-1c-workflow.ps1')) {
                Copy-Item -LiteralPath (Join-Path $fixture.root $name) -Destination $e2eRoot -Recurse
            }
            $lock = $fixture.lock | ConvertTo-Json -Depth 12 | ConvertFrom-Json
            $lock.dependencies.workflowPackage.commit = $candidateCommit
            Write-Utf8Json -Path (Join-Path $e2eRoot '.agent-1c/dependency-lock.json') -Value $lock
            Write-Utf8Json -Path (Join-Path $e2eRoot '.agent-1c/project.json') -Value ([ordered]@{ masterBranch='master' })
            [IO.File]::WriteAllText((Join-Path $e2eRoot '.gitignore'), ".agent-1c/dev-branches/`n.agent-1c/runs/`n.agent-1c/release-e2e.json`n__pycache__/`n*.pyc`n", [Text.UTF8Encoding]::new($false))
            $cacheRelative = '.agents/skills/itl-remote-runner/scripts/itl_remote/__pycache__/probe.cpython-313.pyc'
            $cachePath = Join-Path $e2eRoot $cacheRelative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cachePath) | Out-Null
            [IO.File]::WriteAllBytes($cachePath, [byte[]](243,13,13,10,0,0,0,0,1,0,0,0,7,0,0,0,128,0))
            # Reproduce the actual stand: a generated cache can already be tracked by an older package commit.
            & git -C $e2eRoot add -- .
            & git -C $e2eRoot add -f -- $cacheRelative
            & git -C $e2eRoot commit -m 'stand baseline including historical Python cache' | Out-Null
            & git -C $e2eRoot worktree add --quiet -b 'itldev/package-cache' $worktreeRoot master
            Write-Utf8Json -Path (Join-Path $e2eRoot '.agent-1c/release-e2e.json') -Value ([ordered]@{
                schemaVersion=1; devBranchName='package-cache'; worktreePath=$worktreeRoot
            })
            Write-Utf8Json -Path (Join-Path $worktreeRoot '.agent-1c/dev-branches/package-cache.json') -Value ([ordered]@{
                unsafeActionProtectionConfirmed=$true
            })
            $markerPath = Join-Path $e2eRoot 'tests/features/workflow-release-e2e.feature'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $markerPath) | Out-Null
            [IO.File]::WriteAllText($markerPath, "# release marker`n", [Text.UTF8Encoding]::new($false))
            & git -C $e2eRoot add -- tests/features/workflow-release-e2e.feature
            & git -C $e2eRoot commit -m 'fixture marker' | Out-Null
            $installedSource = Join-Path $e2eRoot $relativeSource
            switch ($Kind) {
                'modified-source' { [IO.File]::WriteAllText($installedSource, "# changed source`r`nvalue = 14`r`n", [Text.UTF8Encoding]::new($false)) }
                'missing-source' { Remove-Item -LiteralPath $installedSource }
                'extra-source' { [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $installedSource) 'foreign.py'), "value = 99`n", [Text.UTF8Encoding]::new($false)) }
            }
            if ($Kind -ne 'cache-only') {
                & git -C $e2eRoot add -- .agents/skills/itl-remote-runner
                & git -C $e2eRoot commit -m "stand $Kind difference" | Out-Null
            }
            $outputPath = Join-Path $tempRoot 'release-context.json'
            $beforeCacheHash = (Get-FileHash -LiteralPath $cachePath -Algorithm SHA256).Hash.ToLowerInvariant()
            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath -Mode Release -E2EProjectRoot $e2eRoot | Out-Null
            $context = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($ExpectedDrift) {
                @($context.issues.code) | Should -Contain 'RELEASE_STAND_MANAGED_PACKAGE_DRIFT'
                ($context.issues | Where-Object code -eq 'RELEASE_STAND_MANAGED_PACKAGE_DRIFT' | Select-Object -First 1).message | Should -Match (([regex]::Escape($(if ($Kind -eq 'extra-source') { '.agents/skills/itl-remote-runner/scripts/itl_remote/foreign.py' } else { $relativeSource }))) + '(?:$|,)')
            } else {
                @($context.issues.code) | Should -Not -Contain 'RELEASE_STAND_MANAGED_PACKAGE_DRIFT'
            }
            @($context.issues.code) | Should -Not -Contain 'RELEASE_STAND_WORKFLOW_COMMIT_DRIFT'
            $context.stand.projectRoot | Should -BeExactly $e2eRoot
            (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $sourceHash
            (Get-FileHash -LiteralPath $cachePath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $beforeCacheHash
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($sourcePath)) | Should -BeExactly ([Convert]::ToBase64String($sourceBytes))
        } finally {
            if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
        }
    }
    It "rejects invalid UTF-8 in changed PowerShell before test execution" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-release-readiness-encoding-" + [guid]::NewGuid().ToString("N"))
        try {
            $fixture = New-ReadinessFixture -Root (Join-Path $tempRoot "workflow")
            $badPath = Join-Path $fixture.root "scripts\bad-encoding.ps1"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $badPath) | Out-Null
            [System.IO.File]::WriteAllBytes($badPath, [byte[]](0xFF, 0xFE, 0x00))
            & git -C $fixture.root add -- scripts/bad-encoding.ps1
            & git -C $fixture.root commit -m "bad encoding" | Out-Null
            $outputPath = Join-Path $tempRoot "release-context.json"
            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath | Out-Null
            $context = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $context.status | Should -Be "failed"
            @($context.issues.code) | Should -Contain "RELEASE_POWERSHELL_ENCODING_INVALID"
        } finally {
            if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
        }
    }

    It "uses the real Windows PowerShell 5.1 decoder and rejects UTF-8 without BOM mojibake" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl release readiness кодировка " + [guid]::NewGuid().ToString("N"))
        try {
            $fixture = New-ReadinessFixture -Root (Join-Path $tempRoot "workflow")
            $badPath = Join-Path $fixture.root "scripts\utf8-without-bom.ps1"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $badPath) | Out-Null
            [System.IO.File]::WriteAllText($badPath, "`$value = 'Привет'`n", [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $fixture.root "scripts\ascii-safe.ps1"), "`$value = 'hello'`n", [System.Text.UTF8Encoding]::new($false))
            & git -C $fixture.root add -- scripts/utf8-without-bom.ps1 scripts/ascii-safe.ps1
            & git -C $fixture.root commit -m "utf8 without bom" | Out-Null
            $outputPath = Join-Path $tempRoot "release-context.json"
            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath | Out-Null
            $context = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $context.status | Should -Be "failed"
            @($context.issues.code) | Should -Contain "RELEASE_POWERSHELL_ENCODING_INVALID"
            $encodingIssue = @($context.issues | Where-Object code -eq "RELEASE_POWERSHELL_ENCODING_INVALID")[0]
            $encodingIssue.message | Should -Match "utf8-without-bom.ps1"
            $encodingIssue.message | Should -Not -Match "batch decode preflight failed"
            $context.encoding.contract | Should -Be "windows-powershell-5.1-default-decode-plus-strict-utf8-and-ast"
        } finally {
            if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
        }
    }

    It "preflights a distinct existing Develop worktree and its configured branch" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-develop-readiness-stand-" + [guid]::NewGuid().ToString("N"))
        try {
            $fixture = New-ReadinessFixture -Root (Join-Path $tempRoot "workflow")
            $e2eRoot = Join-Path $tempRoot "e2e"
            $developRoot = Join-Path $tempRoot "develop-worktree"
            New-Item -ItemType Directory -Force -Path $e2eRoot | Out-Null
            & git -C $e2eRoot init -b master | Out-Null
            & git -C $e2eRoot config user.email "tests@example.invalid"
            & git -C $e2eRoot config user.name "Release Tests"
            [IO.File]::WriteAllText((Join-Path $e2eRoot "README.md"), "fixture`n", [Text.UTF8Encoding]::new($false))
            & git -C $e2eRoot add -- .
            & git -C $e2eRoot commit -m "e2e stand" | Out-Null
            & git -C $e2eRoot worktree add -b "itldev/develop-test" $developRoot | Out-Null
            $configPath = Join-Path $e2eRoot ".agent-1c\release-e2e.json"
            $config = [ordered]@{
                schemaVersion = 1
                developDevBranchName = "develop-test"
                developWorktreePath = $developRoot
                devBranchName = "release-test"
                worktreePath = Join-Path $tempRoot "release-worktree"
            }
            Write-Utf8Json -Path $configPath -Value $config
            $outputPath = Join-Path $tempRoot "develop-context.json"
            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath -Mode "Develop" -E2EProjectRoot $e2eRoot | Out-Null
            $context = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $context.status | Should -Be "passed"
            $context.stand.devBranchName | Should -Be "develop-test"

            $unrelatedRoot = Join-Path $tempRoot "unrelated-repository"
            New-Item -ItemType Directory -Force -Path $unrelatedRoot | Out-Null
            & git -C $unrelatedRoot init -b "itldev/develop-test" | Out-Null
            & git -C $unrelatedRoot config user.email "tests@example.invalid"
            & git -C $unrelatedRoot config user.name "Release Tests"
            [IO.File]::WriteAllText((Join-Path $unrelatedRoot "README.md"), "fixture`n", [Text.UTF8Encoding]::new($false))
            & git -C $unrelatedRoot add -- .
            & git -C $unrelatedRoot commit -m "unrelated" | Out-Null
            $config.developWorktreePath = $unrelatedRoot
            Write-Utf8Json -Path $configPath -Value $config
            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath -Mode "Develop" -E2EProjectRoot $e2eRoot | Out-Null
            $context = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            @($context.issues.code) | Should -Contain "DEVELOP_E2E_ISOLATED_STAND_REQUIRED"

            $config.developWorktreePath = $developRoot
            $config.worktreePath = $developRoot
            Write-Utf8Json -Path $configPath -Value $config
            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath -Mode "Develop" -E2EProjectRoot $e2eRoot | Out-Null
            $context = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            @($context.issues.code) | Should -Contain "DEVELOP_E2E_ISOLATED_STAND_REQUIRED"

            $config.worktreePath = Join-Path $tempRoot "release-worktree"
            $config.developWorktreePath = Join-Path $tempRoot "missing-develop-worktree"
            Write-Utf8Json -Path $configPath -Value $config
            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath -Mode "Develop" -E2EProjectRoot $e2eRoot | Out-Null
            $context = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            @($context.issues.code) | Should -Contain "DEVELOP_E2E_ISOLATED_STAND_REQUIRED"

            $config.developWorktreePath = $developRoot
            $config.developDevBranchName = "wrong-branch"
            Write-Utf8Json -Path $configPath -Value $config
            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath -Mode "Develop" -E2EProjectRoot $e2eRoot | Out-Null
            $context = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            @($context.issues.code) | Should -Contain "DEVELOP_E2E_ISOLATED_STAND_REQUIRED"
        } finally {
            if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
        }
    }
}

Describe 'Shared Release early admission' -Tag 'ReleaseAdmissionContract' {
    BeforeAll {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
        . (Join-Path $RepoRoot 'scripts/release-qualification.ps1')
        . (Join-Path $RepoRoot 'scripts/stand-env-identity.ps1')
        . (Join-Path $RepoRoot 'scripts/release-e2e/workflow-transition.ps1')
        . (Join-Path $RepoRoot 'scripts/release-e2e/admission.ps1')
        . (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.package-content.ps1')
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/test-release-readiness.ps1'), [ref]$tokens, [ref]$errors)
        if ($errors) { throw 'Readiness owner must parse' }
        foreach ($name in @('Add-ReadinessIssue', 'Get-JsonFile', 'Get-GitValue', 'Get-FileSha256', 'Test-PathInsideRoot', 'Get-ManagedTextOrBinarySha256', 'Test-ReleaseCheckpointPreflight')) {
            $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $false)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        function New-EarlyAdmissionFixture {
            param([string]$Root)
            $main = Join-Path $Root 'Основной проект'; $worktree = Join-Path $Root 'Ветка Release'
            New-Item -ItemType Directory -Force (Join-Path $main '.agent-1c') | Out-Null
            $utf8 = [Text.UTF8Encoding]::new($false)
            [IO.File]::WriteAllText((Join-Path $main '.gitignore'), ".agent-1c/runs/`n.dev.env`n", $utf8)
            [IO.File]::WriteAllText((Join-Path $main '.agent-1c/project.json'), '{"exportPath":"src/cf","aiRules":{"tools":["codex"]}}', $utf8)
            & git -C $main init -q -b master
            & git -C $main config user.name 'Early Release admission'
            & git -C $main config user.email 'admission@example.invalid'
            & git -C $main add --all
            & git -C $main commit -qm baseline
            & git -C $main worktree add --quiet -b itldev/admission $worktree master
            if ($LASTEXITCODE -ne 0) { throw 'Owned Unicode worktree must exist' }
            [IO.File]::WriteAllText((Join-Path $main '.agent-1c/release-e2e.json'), (@{worktreePath=$worktree;devBranchName='admission'} | ConvertTo-Json), $utf8)
            $run = Join-Path $worktree '.agent-1c/runs/release-e2e/admission'
            New-Item -ItemType Directory -Force $run | Out-Null
            $dt = Join-Path $run 'baseline.dt'; $state = Join-Path $run 'baseline-state.json'; $envCopy = Join-Path $run 'baseline-env.txt'
            [IO.File]::WriteAllText($dt, 'unit fixture DT bytes', $utf8)
            [IO.File]::WriteAllText($state, '{"lastVerificationStatus":"unverified"}', $utf8)
            [IO.File]::WriteAllText($envCopy, 'PASSWORD=transient-sentinel-never-report', $utf8)
            $identity = [ordered]@{
                projectRoot=$main;worktreePath=$worktree;branch='itldev/admission'
                workflowCommit=(Invoke-RepositoryGit $RepoRoot @('rev-parse','HEAD')).stdout.Trim()
                workflowTree=(Invoke-RepositoryGit $RepoRoot @('rev-parse','HEAD^{tree}')).stdout.Trim()
                runnerSha256=Get-E2EAdmissionCanonicalTextSha256 (Join-Path $RepoRoot 'scripts/invoke-release-e2e.ps1')
                helperSha256=Get-E2EAdmissionCanonicalTextSha256 (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1')
                projectConfigSha256=Get-E2EAdmissionFileSha256 (Join-Path $worktree '.agent-1c/project.json')
                aiRulesCommit='';clientSelection=Get-SourceE2EClientIdentity $main 'codex'
            }
            $checkpoint = [ordered]@{schemaVersion=3;identity=$identity;expectedHead=(Invoke-RepositoryGit $worktree @('rev-parse','HEAD')).stdout.Trim();stages=[ordered]@{};
                snapshots=@{baseline=@{path=$dt;sha256=Get-E2EAdmissionFileSha256 $dt}};
                stateFiles=@{baseline=@{stateCopyPath=$state;stateSha256=Get-E2EAdmissionFileSha256 $state;envCopyPath=$envCopy;envSha256=Get-E2EAdmissionFileSha256 $envCopy}}}
            return @{main=$main;worktree=$worktree;run=$run;checkpoint=$checkpoint;checkpointPath=(Join-Path $run 'checkpoint.json');state=$state;envCopy=$envCopy}
        }
        function Invoke-EarlyAdmissionFixture {
            param($Fixture)
            [IO.File]::WriteAllText($Fixture.checkpointPath, ($Fixture.checkpoint | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
            $script:issues = New-Object 'Collections.Generic.List[object]'
            $RepositoryRoot=$RepoRoot; $ResumeMode='Auto'; $AgentTarget='codex'
            $before = Get-E2EAdmissionFileSha256 $Fixture.checkpointPath
            $candidateCommit=(Invoke-RepositoryGit $RepoRoot @('rev-parse','HEAD')).stdout.Trim()
            $candidateTree=(Invoke-RepositoryGit $RepoRoot @('rev-parse','HEAD^{tree}')).stdout.Trim()
            $result = Test-ReleaseCheckpointPreflight -StandProjectRoot $Fixture.main -StandWorktree $Fixture.worktree -DevBranchName 'admission' -CandidateCommit $candidateCommit -CandidateTree $candidateTree -AiRulesCommit ''
            # The candidate is current source even when the saved identity is old.
            (Get-E2EAdmissionFileSha256 $Fixture.checkpointPath) | Should -BeExactly $before
            return @{record=$result;issues=$script:issues.ToArray()}
        }
    }

    It 'rejects an unsupported cross-source HEAD before any runner action and leaves checkpoint bytes intact' {
        $fixture=New-EarlyAdmissionFixture (Join-Path $TestDrive 'Ранний отказ с пробелом')
        $fixture.checkpoint.identity.runnerSha256='0'*64
        [IO.File]::WriteAllText((Join-Path $fixture.worktree 'foreign.txt'),'foreign',[Text.UTF8Encoding]::new($false))
        & git -C $fixture.worktree add -- foreign.txt
        & git -C $fixture.worktree commit -qm 'chore: update ITL workflow in development branch'
        $observed=Invoke-EarlyAdmissionFixture $fixture
        $observed.record.transition.allowed | Should -BeFalse
        @($observed.issues.code) | Should -Contain 'RELEASE_CHECKPOINT_TRANSITION_UNPROVEN'
        $observed.record.transition.reason | Should -Match 'no supported completed'
        ($observed.record | ConvertTo-Json -Depth 16) | Should -Not -Match 'transient-sentinel|PASSWORD='
    }

    It 'uses the current helper identity to catch a second stand change after a successful early read' {
        $fixture=New-EarlyAdmissionFixture (Join-Path $TestDrive 'Повторная проверка границы')
        $first=Invoke-EarlyAdmissionFixture $fixture
        $first.record.transition.allowed | Should -BeTrue
        $first.record.exactIdentity | Should -BeTrue
        [IO.File]::WriteAllText((Join-Path $fixture.worktree 'foreign.txt'),'later foreign',[Text.UTF8Encoding]::new($false))
        & git -C $fixture.worktree add -- foreign.txt
        & git -C $fixture.worktree commit -qm later
        $second=Invoke-EarlyAdmissionFixture $fixture
        $second.record.transition.allowed | Should -BeFalse
        @($second.issues.code) | Should -Contain 'RELEASE_CHECKPOINT_HEAD_MISMATCH'
    }

    It 'reports rerun when HEAD is valid but source continuation proof is absent' {
        $fixture=New-EarlyAdmissionFixture (Join-Path $TestDrive 'Нет proof без нового запрета')
        $fixture.checkpoint.identity.workflowCommit='0'*40
        $fixture.checkpoint.stages['ondemand-mcp']=@{status='failed';fingerprint='old'}
        $observed=Invoke-EarlyAdmissionFixture $fixture
        $observed.record.transition.allowed | Should -BeTrue
        $observed.record.transition.sourceContinuationProven | Should -BeFalse
        $observed.record.stageDecisions.Count | Should -Be 1
        $observed.record.stageDecisions[0].action | Should -BeExactly 'rerun'
        @($observed.issues) | Should -BeNullOrEmpty
    }

    It 'checks exact saved <Kind> bytes before reuse without editing or printing them' -ForEach @(@{Kind='state'},@{Kind='envCopy'}) {
        $fixture=New-EarlyAdmissionFixture (Join-Path $TestDrive ('Дрейф '+$Kind))
        [IO.File]::AppendAllText($fixture[$Kind], ' changed')
        $badHash=Get-E2EAdmissionFileSha256 $fixture[$Kind]
        $observed=Invoke-EarlyAdmissionFixture $fixture
        @($observed.issues.code) | Should -Contain 'RELEASE_CHECKPOINT_SUPPORT_INVALID'
        ($observed.issues.message -join ' ') | Should -Match 'recorded SHA256'
        (Get-E2EAdmissionFileSha256 $fixture[$Kind]) | Should -BeExactly $badHash
        ($observed | ConvertTo-Json -Depth 16) | Should -Not -Match 'transient-sentinel|PASSWORD='
    }
}
