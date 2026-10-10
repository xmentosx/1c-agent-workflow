BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $RepoRoot = $context.RepoRoot
    $HelperPath = $context.HelperPath
}

Describe 'Pinned OpenSpec CLI runtime' {
    It 'preserves an explicit already-synchronized archive request when rebuilding helper invocation' {
        $root = Join-Path $TestDrive 'Архив проекта с пробелом'
        New-Item -ItemType Directory -Path $root | Out-Null
        $result = & {
            . $HelperPath -ProjectRoot $root -Action help -OpenSpecChangeId native-sync-canary -OpenSpecArchiveSkipSpecs *> $null
            $selected = @(Get-Agent1cReexecArguments)
            $OpenSpecArchiveSkipSpecs = [System.Management.Automation.SwitchParameter]::new($false)
            $ordinary = @(Get-Agent1cReexecArguments)
            [pscustomobject]@{ selected=$selected; ordinary=$ordinary }
        }
        @($result.selected | Where-Object { $_ -ceq '-OpenSpecArchiveSkipSpecs' }).Count | Should -Be 1
        $result.selected[[Array]::IndexOf($result.selected, '-OpenSpecChangeId') + 1] | Should -Be 'native-sync-canary'
        $result.selected[[Array]::IndexOf($result.selected, '-ProjectRoot') + 1] | Should -Be $root
        $result.ordinary | Should -Not -Contain '-OpenSpecArchiveSkipSpecs'
    }

    It 'keeps the pinned package-lock bytes through a Windows Git checkout' {
        $relative = '.agents/skills/1c-workflow/resources/openspec-cli/package-lock.json'
        $source = Join-Path $RepoRoot $relative
        $expected = [string]((Get-Content (Join-Path $RepoRoot 'templates/dependency-lock.json') -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies.openSpecCli.packageLockSha256)
        (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $expected

        $root = Join-Path $TestDrive 'Исходный проект с пробелом'
        $before = Join-Path $TestDrive 'До атрибута'
        $after = Join-Path $TestDrive 'После атрибута'
        New-Item -ItemType Directory -Force -Path (Join-Path $root (Split-Path -Parent $relative)) | Out-Null
        & git init -q $root
        $LASTEXITCODE | Should -Be 0
        Copy-Item -LiteralPath $source -Destination (Join-Path $root $relative)
        & git -C $root add -- $relative
        & git -C $root -c user.name=ITL -c user.email=itl@example.invalid commit -qm baseline
        $LASTEXITCODE | Should -Be 0
        & git -c core.autocrlf=true clone -q -- $root $before
        $LASTEXITCODE | Should -Be 0
        (Get-FileHash -LiteralPath (Join-Path $before $relative) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Not -Be $expected

        & {
            . $HelperPath -ProjectRoot $root -Action help *> $null
            Ensure-ItlPinnedOpenSpecGitAttributes | Should -BeTrue
            Ensure-ItlPinnedOpenSpecGitAttributes | Should -BeFalse
        }
        & git -C $root add -- .gitattributes
        & git -C $root -c user.name=ITL -c user.email=itl@example.invalid commit -qm preserve-lock-bytes
        $LASTEXITCODE | Should -Be 0
        & git -c core.autocrlf=true clone -q -- $root $after
        $LASTEXITCODE | Should -Be 0
        (Get-FileHash -LiteralPath (Join-Path $after $relative) -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $expected
        @(& git -C $after check-attr text -- $relative) | Should -Match 'text: unset'
    }

    It 'preserves an existing 1C transport attribute block while adding the CLI pin' {
        $root = Join-Path $TestDrive 'Проект с 1C attributes'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $path = Join-Path $root '.gitattributes'
        $prefix = '*.md text eol=lf' + "`r`n"
        $result = & {
            . $HelperPath -ProjectRoot $root -Action help *> $null
            [IO.File]::WriteAllText($path, ($prefix + ((Get-OneCSourceGitAttributesManagedLines) -join "`r`n") + "`r`n"), [Text.UTF8Encoding]::new($false))
            Ensure-ItlPinnedOpenSpecGitAttributes | Should -BeTrue
            $text = Read-Utf8Text -Path $path
            [pscustomobject]@{ text = $text; contract = Test-OneCSourceGitAttributesContractText -Text $text }
        }
        $result.contract | Should -BeTrue
        $result.text.StartsWith($prefix, [StringComparison]::Ordinal) | Should -BeTrue
        $result.text | Should -Match '(?m)^\.agents/skills/1c-workflow/resources/openspec-cli/package-lock\.json -text\r?$'
    }

    It 'keeps the CLI pin when a fresh project later adds the 1C transport block' {
        $root = Join-Path $TestDrive 'Новый проект с пробелом'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $result = & {
            . $HelperPath -ProjectRoot $root -Action help *> $null
            Ensure-ItlPinnedOpenSpecGitAttributes | Should -BeTrue
            Ensure-OneCSourceGitAttributes | Should -BeTrue
            Ensure-ItlPinnedOpenSpecGitAttributes | Should -BeFalse
            $text = Read-Utf8Text -Path (Join-Path $root '.gitattributes')
            [pscustomobject]@{ text = $text; contract = Test-OneCSourceGitAttributesContractText -Text $text }
        }
        $result.contract | Should -BeTrue
        $result.text | Should -Match '(?m)^\.agents/skills/1c-workflow/resources/openspec-cli/package-lock\.json -text\r?$'
    }

    It 'provisions an exact local Node and CLI pair without using the global OpenSpec command' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('itl OpenSpec проект ' + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $root '.agent-1c') | Out-Null
            Set-Content -LiteralPath (Join-Path $root '.agent-1c\project.json') -Encoding UTF8 -Value '{"dependencyMode":"locked"}'
            Copy-Item -LiteralPath (Join-Path $RepoRoot 'templates\dependency-lock.json') -Destination (Join-Path $root '.agent-1c\dependency-lock.json')
            $result = & {
                . $HelperPath -ProjectRoot $root -Action help *> $null
                $before = Get-ItlOpenSpecCliStatus
                $installed = Provision-ItlOpenSpecCli
                $after = Get-ItlOpenSpecCliStatus
                [pscustomobject]@{ before = $before; installed = $installed; after = $after }
            }
            $result.before.available | Should -BeFalse
            $result.before.reason | Should -Match 'OPEN_SPEC_CLI_NOT_PROVISIONED'
            $result.installed.available | Should -BeTrue
            $result.after.available | Should -BeTrue
            $result.after.version | Should -Be '1.13.1'
            $result.after.path | Should -Match 'openspec-cli[\\/]1\.13\.1'
            (& $result.after.nodePath $result.after.path --version).Trim() | Should -Be '1.13.1'
            $peerRoot = Join-Path $root 'peer-project'
            New-Item -ItemType Directory -Force -Path (Join-Path $peerRoot '.agent-1c') | Out-Null
            Set-Content -LiteralPath (Join-Path $peerRoot '.agent-1c\project.json') -Encoding UTF8 -Value '{"dependencyMode":"locked"}'
            Copy-Item -LiteralPath (Join-Path $RepoRoot 'templates\dependency-lock.json') -Destination (Join-Path $peerRoot '.agent-1c\dependency-lock.json')
            $peerCli = & { . $HelperPath -ProjectRoot $peerRoot -Action help *> $null; Provision-ItlOpenSpecCli }
            $peerCli.available | Should -BeTrue
            $peerCli.path | Should -Not -Be $result.after.path
            # The second project models a pre-existing local OpenSpec workspace.
            # Its specs must stay bound to that checkout across a fresh helper
            # invocation, even while another project has its own pinned CLI.
            foreach ($relative in @('openspec/specs/legacy', 'openspec/changes/legacy-change')) {
                New-Item -ItemType Directory -Force -Path (Join-Path $peerRoot $relative) | Out-Null
            }
            Set-Content -LiteralPath (Join-Path $peerRoot 'openspec/config.yaml') -Encoding UTF8 -Value 'schema: spec-driven'
            Set-Content -LiteralPath (Join-Path $peerRoot 'openspec/specs/legacy/spec.md') -Encoding UTF8 -Value '### Requirement: Existing local rule'
            Set-Content -LiteralPath (Join-Path $peerRoot 'openspec/changes/legacy-change/.openspec.yaml') -Encoding UTF8 -Value 'schema: spec-driven'
            $legacySpecHash = (Get-FileHash -LiteralPath (Join-Path $peerRoot 'openspec/specs/legacy/spec.md') -Algorithm SHA256).Hash
            $legacyContext = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @(
                '-ProjectRoot', $peerRoot, '-Action', 'openspec-context', '-OpenSpecChangeId', 'legacy-change'
            )
            $legacyContext.exitCode | Should -Be 0 -Because $legacyContext.combinedText
            $legacyBinding = $legacyContext.combinedText | ConvertFrom-Json
            $legacyBinding.rootPath | Should -Be $peerRoot
            $legacyBinding.change.changeRoot | Should -Be (Join-Path $peerRoot 'openspec/changes/legacy-change')
            Push-Location $peerRoot
            try {
                $legacyStatusText = @(& $peerCli.nodePath $peerCli.path status --change legacy-change --json 2>&1) -join "`n"
                $LASTEXITCODE | Should -Be 0 -Because $legacyStatusText
                ($legacyStatusText | ConvertFrom-Json).changeName | Should -Be 'legacy-change'
                $legacyInstructionsText = @(& $peerCli.nodePath $peerCli.path instructions proposal --change legacy-change --json 2>&1) -join "`n"
                $LASTEXITCODE | Should -Be 0 -Because $legacyInstructionsText
                $legacyInstructionsText | ConvertFrom-Json | Should -Not -BeNullOrEmpty
            } finally { Pop-Location }
            (Get-FileHash -LiteralPath (Join-Path $peerRoot 'openspec/specs/legacy/spec.md') -Algorithm SHA256).Hash | Should -Be $legacySpecHash
            $peerReceiptBefore = (Get-FileHash -LiteralPath (Join-Path $peerRoot '.agent-1c\tools\openspec-cli\1.13.1\itl-runtime.json') -Algorithm SHA256).Hash
            foreach ($subcommand in @('context', 'list', 'status', 'instructions', 'store', 'new', 'archive')) {
                $helpText = @(& $result.after.nodePath $result.after.path $subcommand --help 2>&1) -join "`n"
                $LASTEXITCODE | Should -Be 0 -Because $helpText
                $helpText | Should -Match 'Usage:'
            }
            Push-Location $RepoRoot
            try {
                $contextText = @(& $result.after.nodePath $result.after.path context --json) -join "`n"
                $LASTEXITCODE | Should -Be 0 -Because $contextText
                $context = $contextText | ConvertFrom-Json
                $context.root.path | Should -Be $RepoRoot

                $listText = @(& $result.after.nodePath $result.after.path list --json) -join "`n"
                $LASTEXITCODE | Should -Be 0 -Because $listText
                $list = $listText | ConvertFrom-Json
                $list | Should -Not -BeNullOrEmpty

                $statusText = @(& $result.after.nodePath $result.after.path status --change upgrade-ai-rules-upstream-20a083e5 --json) -join "`n"
                $LASTEXITCODE | Should -Be 0 -Because $statusText
                $status = $statusText | ConvertFrom-Json
                $status.changeName | Should -Be 'upgrade-ai-rules-upstream-20a083e5'
                @($status.artifacts).Count | Should -BeGreaterThan 0

                $instructionsText = @(& $result.after.nodePath $result.after.path instructions apply --change upgrade-ai-rules-upstream-20a083e5 --json) -join "`n"
                $LASTEXITCODE | Should -Be 0 -Because $instructionsText
                $instructions = $instructionsText | ConvertFrom-Json
                $instructions | Should -Not -BeNullOrEmpty
            } finally { Pop-Location }
            $savedEnvironment = @{}
            foreach ($name in @('APPDATA', 'LOCALAPPDATA', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'OPENSPEC_TELEMETRY', 'OPENSPEC_NO_UPDATE_CHECK')) {
                $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            }
            try {
                $isolatedHome = Join-Path $root 'openspec-user-state'
                foreach ($name in @('APPDATA', 'LOCALAPPDATA', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME')) {
                    [Environment]::SetEnvironmentVariable($name, (Join-Path $isolatedHome $name), 'Process')
                }
                $env:OPENSPEC_TELEMETRY = '0'
                $env:OPENSPEC_NO_UPDATE_CHECK = '1'
                $storeRoot = Join-Path $root 'shared-store'
                $localRoot = Join-Path $root 'local-project'
                $pointerRoot = Join-Path $root 'pointer-project'
                $globalRoot = Join-Path $root 'global-project'
                $brokenRoot = Join-Path $root 'broken-project'
                foreach ($directory in @($localRoot, $pointerRoot, $globalRoot, $brokenRoot)) {
                    New-Item -ItemType Directory -Force -Path $directory | Out-Null
                }
                $setupText = @(& $result.after.nodePath $result.after.path store setup itl-fixture --path $storeRoot --no-init-git --json 2>&1) -join "`n"
                $LASTEXITCODE | Should -Be 0 -Because $setupText
                $setupText | Should -Match 'itl-fixture'

                New-Item -ItemType Directory -Force -Path (Join-Path $localRoot 'openspec/specs'), (Join-Path $localRoot 'openspec/changes') | Out-Null
                Set-Content -LiteralPath (Join-Path $localRoot 'openspec/config.yaml') -Encoding UTF8 -Value "schema: spec-driven`nstore: itl-fixture"
                New-Item -ItemType Directory -Force -Path (Join-Path $pointerRoot 'openspec') | Out-Null
                Set-Content -LiteralPath (Join-Path $pointerRoot 'openspec/config.yaml') -Encoding UTF8 -Value 'store: itl-fixture'
                New-Item -ItemType Directory -Force -Path (Join-Path $brokenRoot 'openspec') | Out-Null
                Set-Content -LiteralPath (Join-Path $brokenRoot 'openspec/config.yaml') -Encoding UTF8 -Value 'store: missing-itl-fixture'

                foreach ($scenario in @(
                    @{ directory = $localRoot; expectedSource = 'nearest'; expectedPath = $localRoot; args = @() },
                    @{ directory = $localRoot; expectedSource = 'store'; expectedPath = $storeRoot; args = @('--store', 'itl-fixture') },
                    @{ directory = $pointerRoot; expectedSource = 'declared'; expectedPath = $storeRoot; args = @() }
                )) {
                    Push-Location $scenario.directory
                    try {
                        $contextText = @(& $result.after.nodePath $result.after.path context @($scenario.args) --json 2>$null) -join "`n"
                        $LASTEXITCODE | Should -Be 0 -Because $contextText
                        $resolved = $contextText | ConvertFrom-Json
                        $resolved.root.source | Should -Be $scenario.expectedSource
                        $resolved.root.path | Should -Be $scenario.expectedPath
                    } finally { Pop-Location }
                }
                Push-Location $brokenRoot
                try {
                    $brokenText = @(& $result.after.nodePath $result.after.path context --json 2>&1) -join "`n"
                    $LASTEXITCODE | Should -Not -Be 0 -Because $brokenText
                    $brokenText | Should -Match 'missing-itl-fixture'
                } finally { Pop-Location }

                $defaultText = @(& $result.after.nodePath $result.after.path config set defaultStore itl-fixture 2>&1) -join "`n"
                $LASTEXITCODE | Should -Be 0 -Because $defaultText
                Push-Location $globalRoot
                try {
                    $globalText = @(& $result.after.nodePath $result.after.path context --json 2>$null) -join "`n"
                    $LASTEXITCODE | Should -Be 0 -Because $globalText
                    $globalContext = $globalText | ConvertFrom-Json
                    $globalContext.root.source | Should -Be 'global_default'
                    $globalContext.root.path | Should -Be $storeRoot
                } finally { Pop-Location }

                foreach ($project in @($localRoot, $pointerRoot, $globalRoot, $brokenRoot)) {
                    New-Item -ItemType Directory -Force -Path (Join-Path $project '.agent-1c') | Out-Null
                    Set-Content -LiteralPath (Join-Path $project '.agent-1c/project.json') -Encoding UTF8 -Value '{"openSpec":{"storeId":""}}'
                }
                $localSelection = & { . $HelperPath -ProjectRoot $localRoot -Action help *> $null; Resolve-ItlOpenSpecStore -Cli $result.after }
                $localSelection.source | Should -Be 'nearest'
                $localSelection.rootPath | Should -Be $localRoot
                { & { . $HelperPath -ProjectRoot $pointerRoot -Action help *> $null; Resolve-ItlOpenSpecStore -Cli $result.after } } |
                    Should -Throw '*OPEN_SPEC_EXTERNAL_STORE_DEFERRED*'
                Set-Content -LiteralPath (Join-Path $localRoot '.agent-1c/project.json') -Encoding UTF8 -Value '{"openSpec":{"storeId":"itl-fixture"}}'
                { & { . $HelperPath -ProjectRoot $localRoot -Action help *> $null; Resolve-ItlOpenSpecStore -Cli $result.after } } |
                    Should -Throw '*OPEN_SPEC_EXTERNAL_STORE_DEFERRED*'
                Set-Content -LiteralPath (Join-Path $localRoot '.agent-1c/project.json') -Encoding UTF8 -Value '{"openSpec":{"storeId":""}}'
                { & { . $HelperPath -ProjectRoot $globalRoot -Action help *> $null; Resolve-ItlOpenSpecStore -Cli $result.after } } |
                    Should -Throw '*OPEN_SPEC_EXTERNAL_STORE_DEFERRED*'
                { & { . $HelperPath -ProjectRoot $brokenRoot -Action help *> $null; Resolve-ItlOpenSpecStore -Cli $result.after } } |
                    Should -Throw '*OPEN_SPEC_CLI_COMMAND_FAILED*missing-itl-fixture*'
                Test-Path -LiteralPath (Join-Path $pointerRoot 'openspec/changes') | Should -BeFalse

                Set-Content -LiteralPath (Join-Path $root '.agent-1c/project.json') -Encoding UTF8 -Value '{"dependencyMode":"locked","openSpec":{"storeId":"itl-fixture"}}'
                $blockedWrite = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @(
                    '-ProjectRoot', $root, '-Action', 'openspec-new-change', '-OpenSpecChangeId', 'must-not-be-created'
                )
                $blockedWrite.exitCode | Should -Not -Be 0
                $blockedWrite.combinedText | Should -Match 'OPEN_SPEC_EXTERNAL_STORE_DEFERRED'
                $blockedArchive = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @(
                    '-ProjectRoot', $root, '-Action', 'openspec-archive-change', '-OpenSpecChangeId', 'existing-change'
                )
                $blockedArchive.exitCode | Should -Not -Be 0
                $blockedArchive.combinedText | Should -Match 'OPEN_SPEC_EXTERNAL_STORE_DEFERRED'
                Test-Path -LiteralPath (Join-Path $storeRoot 'openspec/changes/must-not-be-created') | Should -BeFalse
                Test-Path -LiteralPath (Join-Path $root 'openspec') | Should -BeFalse

                New-Item -ItemType Directory -Force -Path (Join-Path $root 'openspec/specs'), (Join-Path $root 'openspec/changes') | Out-Null
                Set-Content -LiteralPath (Join-Path $root 'openspec/config.yaml') -Encoding UTF8 -Value 'schema: spec-driven'
                Set-Content -LiteralPath (Join-Path $root '.agent-1c/project.json') -Encoding UTF8 -Value '{"dependencyMode":"locked","openSpec":{"storeId":""}}'
                $reportedContext = @(& $HelperPath -ProjectRoot $root -Action openspec-context 2>&1) -join "`n"
                $reportedContextJson = $reportedContext | ConvertFrom-Json
                $reportedContextJson.rootPath | Should -Be $root
                $reportedContextJson.source | Should -Be 'nearest'
                $reportedContextJson.cliVersion | Should -Be '1.13.1'
                $routed = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @(
                    '-ProjectRoot', $root, '-Action', 'openspec-new-change', '-OpenSpecChangeId', 'fixture-archive'
                )
                $routed.exitCode | Should -Be 0 -Because $routed.combinedText
                ($routed.combinedText | ConvertFrom-Json).status | Should -Be 'created'
                $changeRoot = Join-Path $root 'openspec/changes/fixture-archive'
                Test-Path -LiteralPath (Join-Path $changeRoot '.openspec.yaml') -PathType Leaf | Should -BeTrue
                $boundText = @(& $HelperPath -ProjectRoot $root -Action openspec-context -OpenSpecChangeId fixture-archive 2>&1) -join "`n"
                $bound = $boundText | ConvertFrom-Json
                $bound.change.changeId | Should -Be 'fixture-archive'
                $bound.change.changeRoot | Should -Be $changeRoot
                $bound.change.storeRoot | Should -Be $root
                $bound.change.checkoutPath | Should -Be $root
                $bound.change.metadataSha256 | Should -Match '^[0-9a-f]{64}$'
                { & { . $HelperPath -ProjectRoot $root -Action help *> $null; $selection = Resolve-ItlOpenSpecStore -Cli $result.after; Resolve-ItlOpenSpecChangeContext -Store $selection -ChangeId '../other' -Cli $result.after } } | Should -Throw '*OPEN_SPEC_CHANGE_ID_INVALID*'
                $storeActionLocks = & { . $HelperPath -ProjectRoot $root -Action help *> $null; @(
                    (Test-Agent1cActionRequiresLifecycleLock -RequestedAction 'openspec-context'),
                    (Test-Agent1cActionRequiresLifecycleLock -RequestedAction 'openspec-new-change'),
                    (Test-Agent1cActionRequiresLifecycleLock -RequestedAction 'openspec-archive-change')
                ) }
                $storeActionLocks | Should -Be @($false, $true, $true)
                Set-Content -LiteralPath (Join-Path $changeRoot 'proposal.md') -Encoding UTF8 -Value "## Why`nVerify pinned CLI archive behavior.`n`n## What Changes`n- Add a fixture capability.`n`n## Capabilities`n### New Capabilities`n- fixture-capability: Fixture behavior.`n`n## Impact`n- Isolated fixture only."
                Set-Content -LiteralPath (Join-Path $changeRoot 'design.md') -Encoding UTF8 -Value "## Context`nIsolated CLI test.`n`n## Goals / Non-Goals`n- Goal: archive a valid delta.`n`n## Decisions`n- Use a disposable local workspace."
                Set-Content -LiteralPath (Join-Path $changeRoot 'tasks.md') -Encoding UTF8 -Value "## 1. Fixture`n- [x] 1.1 Prepare the isolated archive fixture."
                $deltaRoot = Join-Path $changeRoot 'specs/fixture-capability'
                New-Item -ItemType Directory -Force -Path $deltaRoot | Out-Null
                Set-Content -LiteralPath (Join-Path $deltaRoot 'spec.md') -Encoding UTF8 -Value "## ADDED Requirements`n`n### Requirement: Fixture archive`nThe fixture SHALL archive a valid requirement.`n`n#### Scenario: Archive succeeds`n- **WHEN** the archive command runs`n- **THEN** the current spec contains the requirement"
                $archived = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @(
                    '-ProjectRoot', $root, '-Action', 'openspec-archive-change', '-OpenSpecChangeId', 'fixture-archive'
                )
                $archived.exitCode | Should -Be 0 -Because $archived.combinedText
                ($archived.combinedText | ConvertFrom-Json).status | Should -Be 'archived'
                Test-Path -LiteralPath (Join-Path $root 'openspec/specs/fixture-capability/spec.md') -PathType Leaf | Should -BeTrue
                Test-Path -LiteralPath $changeRoot | Should -BeFalse
            } finally {
                foreach ($name in $savedEnvironment.Keys) {
                    [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
                }
            }
            $beforeRepeat = (Get-FileHash -LiteralPath (Join-Path $root '.agent-1c\tools\openspec-cli\1.13.1\itl-runtime.json') -Algorithm SHA256).Hash
            $repeat = & { . $HelperPath -ProjectRoot $root -Action help *> $null; Provision-ItlOpenSpecCli }
            $repeat.available | Should -BeTrue
            (Get-FileHash -LiteralPath (Join-Path $root '.agent-1c\tools\openspec-cli\1.13.1\itl-runtime.json') -Algorithm SHA256).Hash | Should -Be $beforeRepeat
            $legacyPowerShell = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @(
                '-ProjectRoot', $root, '-Action', 'provision-openspec-cli'
            )
            $legacyPowerShell.exitCode | Should -Be 0 -Because $legacyPowerShell.combinedText
            [IO.File]::AppendAllText($result.after.path, "`n// test runtime drift`n", [Text.UTF8Encoding]::new($false))
            $drift = & { . $HelperPath -ProjectRoot $root -Action help *> $null; Get-ItlOpenSpecCliStatus }
            $drift.available | Should -BeFalse
            $drift.reason | Should -Match 'OPEN_SPEC_CLI_RUNTIME_DRIFT'
            $peerAfterDrift = & { . $HelperPath -ProjectRoot $peerRoot -Action help *> $null; Get-ItlOpenSpecCliStatus }
            $peerAfterDrift.available | Should -BeTrue
            (Get-FileHash -LiteralPath (Join-Path $peerRoot '.agent-1c\tools\openspec-cli\1.13.1\itl-runtime.json') -Algorithm SHA256).Hash | Should -Be $peerReceiptBefore
            $peerLockPath = Join-Path $peerRoot '.agent-1c/dependency-lock.json'
            $peerLockBytes = [IO.File]::ReadAllBytes($peerLockPath)
            $legacyLock = ([Text.Encoding]::UTF8.GetString($peerLockBytes) | ConvertFrom-Json)
            $legacyLock.dependencies.PSObject.Properties.Remove('openSpecCli')
            [IO.File]::WriteAllText($peerLockPath, (($legacyLock | ConvertTo-Json -Depth 20) + "`n"), [Text.UTF8Encoding]::new($false))
            $oldPin = & { . $HelperPath -ProjectRoot $peerRoot -Action help *> $null; Get-ItlOpenSpecCliStatus }
            $oldPin.available | Should -BeFalse
            [IO.File]::WriteAllBytes($peerLockPath, $peerLockBytes)
            $restoredPin = & { . $HelperPath -ProjectRoot $peerRoot -Action help *> $null; Get-ItlOpenSpecCliStatus }
            $restoredPin.available | Should -BeTrue
            $restoredPin.path | Should -Be $peerCli.path
            (Get-FileHash -LiteralPath (Join-Path $peerRoot '.agent-1c\tools\openspec-cli\1.13.1\itl-runtime.json') -Algorithm SHA256).Hash | Should -Be $peerReceiptBefore
            {
                & { . $HelperPath -ProjectRoot $root -Action help *> $null; Provision-ItlOpenSpecCli }
            } | Should -Throw '*OPEN_SPEC_CLI_RUNTIME_CONFLICT*'
        } finally {
            $full = [IO.Path]::GetFullPath($root)
            $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if (-not $full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to remove a test path outside Temp: $full" }
            if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
        }
    }
}
