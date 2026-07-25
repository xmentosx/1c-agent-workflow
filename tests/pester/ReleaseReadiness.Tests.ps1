$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$RunnerPath = Join-Path $RepoRoot "scripts\test-release-readiness.ps1"

Describe "Deterministic Release readiness" {
    BeforeAll {
        $script:ReadinessRunnerPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "scripts\test-release-readiness.ps1"
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
            $patchSha = ("3" * 64)
            $upstreamCommit = ("4" * 40)
            $provenance = [ordered]@{
                compatibilityVersion = "1.2.3"
                downstreamRevision = "itl-r1"
                upstream = [ordered]@{ commit = $upstreamCommit }
                patch = [ordered]@{ sha256 = $patchSha }
                artifact = [ordered]@{ fileName = $assetName; entryPoint = "vanessa-automation-single.epf" }
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
                publicationStatus = "published"
                source = "workflow-pinned"
            }
            $lock = [ordered]@{
                schemaVersion = 1
                dependencies = [ordered]@{
                    workflowPackage = [ordered]@{ repo = "https://example.invalid/workflow.git"; ref = "master"; commit = "" }
                    aiRules1c = [ordered]@{ ref = "itl-test"; commit = ("5" * 40) }
                    vanessaAutomation = $vanessa
                }
            }
            Write-Utf8Json -Path (Join-Path $Root "templates\dependency-lock.json") -Value $lock
            $compatibility = [ordered]@{
                families = [ordered]@{
                    "vanessa-ui" = [ordered]@{
                        backendVersions = [ordered]@{ vanessaAutomation = $vanessa.compatibilityVersion }
                        backendRevisions = [ordered]@{ vanessaAutomation = $vanessa.downstreamRevision }
                        vanessaAutomationArtifact = [ordered]@{
                            archiveSha256 = $vanessa.sha256
                            epfSha256 = $vanessa.epfSha256
                            manifestSha256 = $vanessa.manifestSha256
                            patchSha256 = $vanessa.patchSha256
                            upstreamCommit = $vanessa.upstreamCommit
                        }
                    }
                }
            }
            Write-Utf8Json -Path (Join-Path $Root ".agents\skills\1c-workflow\assets\ondemand-mcp\compatibility.json") -Value $compatibility
            New-Item -ItemType Directory -Force -Path (Join-Path $Root ".agents\skills\1c-workflow\scripts") | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $Root ".agents\skills\1c-workflow\scripts\agent-1c.ps1"), "param()`n", [System.Text.UTF8Encoding]::new($false))
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
            return [pscustomobject]@{ root = $Root; assetPath = $assetPath; lock = $lock; compatibility = $compatibility }
        }

        function Invoke-ReadinessFixture {
            param([string]$Root, [string]$OutputPath, [string]$Mode = "Full", [string]$E2EProjectRoot = "")
            $quote = { param([string]$Value) '"' + $Value.Replace('"', '\"') + '"' }
            $arguments = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (& $quote $script:ReadinessRunnerPath), "-Mode", (& $quote $Mode), "-RepositoryRoot", (& $quote $Root), "-OutputPath", (& $quote $OutputPath), "-Offline")
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

    It "rejects stale Release stand locks and unconfirmed protection before checkpoint creation" {
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
                [System.IO.File]::WriteAllText((Join-Path $root ".gitignore"), ".agent-1c/dev-branches/`n.agent-1c/runs/`n", [System.Text.UTF8Encoding]::new($false))
                & git -C $root add -- .
                & git -C $root commit -m "stand" | Out-Null
            }
            Write-Utf8Json -Path (Join-Path $worktreeRoot ".agent-1c\dev-branches\release-test.json") -Value ([ordered]@{ unsafeActionProtectionConfirmed = $false })
            $outputPath = Join-Path $tempRoot "release-context.json"
            Invoke-ReadinessFixture -Root $fixture.root -OutputPath $outputPath -Mode "Release" -E2EProjectRoot $e2eRoot | Out-Null
            $context = Get-Content -LiteralPath $outputPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $context.status | Should -Be "failed"
            $codes = @($context.issues.code)
            $codes | Should -Contain "RELEASE_DEPENDENCY_LOCK_DRIFT"
            $codes | Should -Contain "RELEASE_STAND_WORKFLOW_COMMIT_DRIFT"
            $codes | Should -Contain "RELEASE_STAND_UNSAFE_ACTION_PROTECTION_UNCONFIRMED"
            $codes | Should -Not -Contain "RELEASE_STAND_MANAGED_PACKAGE_DRIFT"
            Test-Path -LiteralPath (Join-Path $worktreeRoot ".agent-1c\runs\release-e2e") | Should -BeFalse
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
}
