Describe "1C workflow development branch lifecycle checks" {
    BeforeAll { . (Join-Path $PSScriptRoot 'DevBranchLifecycleSupport.ps1') }

    Describe 'Concurrent refresh documentation' -Tag 'RefreshDocumentationContinuation' {
        It 'retries <Operation> through load, normalization and MCP while preserving concurrent documents' -TestCases @(
            @{Operation='refresh-dev-branch'}, @{Operation='refresh-dev-branch-lite'}
        ) {
            param($Operation)
            $fixture = New-LifecycleMergeConflictFixture
            try {
                # CONTEXT already belongs to the branch before its lifecycle
                # merge, exactly as in the reported concurrent-writer case.
                [IO.File]::WriteAllText((Join-Path $fixture.root 'CONTEXT.md'), 'исходный контекст', [Text.UTF8Encoding]::new($false))
                & git -C $fixture.root add -- CONTEXT.md
                & git -C $fixture.root commit -qm 'project context'
                $fixture.branchCommit = (& git -C $fixture.root rev-parse HEAD).Trim()
                & git -C $fixture.root merge --no-ff --no-commit $fixture.targetCommit *> $null
                Set-Content -LiteralPath (Join-Path $fixture.root 'conflict.txt') -Encoding UTF8 -Value 'resolved'
                Set-Content -LiteralPath (Join-Path $fixture.root 'src/cf/ConfigDumpInfo.xml') -Encoding UTF8 -Value 'branch-cursor'
                & git -C $fixture.root add -- conflict.txt src/cf/ConfigDumpInfo.xml
                & git -C $fixture.root commit --no-edit *> $null
                $fixture | Add-Member -NotePropertyName mergeCommit -NotePropertyValue ((& git -C $fixture.root rev-parse HEAD).Trim())
                & {
                    . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
                    $utf8 = [Text.UTF8Encoding]::new($false)
                    $contextPath = Join-Path $fixture.root 'CONTEXT.md'
                    $adrPath = Join-Path $fixture.root 'docs/adr/0001 Перенос рабочего стола.md'
                    # The other writer starts after the checkpoint and merge.
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $adrPath) | Out-Null
                    [IO.File]::WriteAllText($contextPath, 'незавершённая проработка', $utf8)
                    [IO.File]::WriteAllText($adrPath, 'решение другого чата', $utf8)
                    $adrHash = (Get-FileHash -LiteralPath $adrPath).Hash
                    $DevBranchName = 'test'
                    $LifecyclePhase = 'post-merge'
                    $script:MergeState = [pscustomobject]@{
                        safeDevBranchName='test'; devBranchName='test'; devBranch='itldev/test'
                        devBranchInfoBasePath=(Join-Path $fixture.root 'База ветки'); infoBaseKind='file'
                        pendingMergeOperation=$Operation; pendingMergeBranch='itldev/test'
                        pendingMergeBranchCommit=$fixture.branchCommit; pendingMergeTargetCommit=$fixture.targetCommit
                        pendingMergeStage='merged'; pendingMergePaths=@(); pendingMergeConflictPaths=@()
                        pendingMergeCommit=$fixture.mergeCommit; pendingMergePostMergeHead=$fixture.mergeCommit
                        pendingMergeResult='merge-commit'; yaxunitApplicabilityBaseline=@{schemaVersion=1}
                        lastVerificationStatus='failed'; lastVerifiedCommit=$fixture.mergeCommit
                    }
                    $script:Calls = [Collections.Generic.List[string]]::new()
                    $script:LoadAttempts = 0
                    function Read-DevBranchState { $script:MergeState }
                    function Update-DevBranchState {
                        param($State, $Updates)
                        foreach ($key in $Updates.Keys) { $script:MergeState | Add-Member -Force -NotePropertyName $key -NotePropertyValue $Updates[$key] }
                    }
                    function Assert-DevelopmentBranchWorktreeContext {}
                    function Assert-DevBranchExtensionInitialized {}
                    function Sync-DevBranchContextToDotEnv {}
                    function Complete-PendingDevBranchRefreshAfterVerifiedRecovery { $false }
                    function Save-DevBranchCheckpoint { throw 'must not checkpoint another writer on resume' }
                    function Sync-Master { throw 'must not repeat master/seed' }
                    function Invoke-NewDevBranchLifecycleMerge { throw 'must not merge again' }
                    function Restart-Agent1cAfterDevBranchMerge {
                        $script:Calls.Add('handoff')
                        $LifecyclePhase = 'post-merge'
                        Invoke-RefreshDevBranchCore -OperationName $Operation -SynchronizeMaster:($Operation -eq 'refresh-dev-branch')
                        throw 'FIXTURE_REFRESH_HANDOFF_COMPLETED'
                    }
                    function Sync-AiRules1cManagedIgnoredFilesFromMain {}
                    function Sync-WorkflowManagedDependencyLockEntries {}
                    function Update-VerificationSuiteInventory { [pscustomobject]@{yaxunit=@{legacyBaseline=$false}; classificationComplete=$true; classificationIssues=@()} }
                    function Install-VanessaAutomation {}
                    function Get-RoctupMcpEnabled { $false }
                    function Install-VanessaMcpArtifacts {}
                    function Install-ItlOnDemandMcp {}
                    function Set-RunStage {}
                    function New-RefreshTrackedKiloConfigSnapshot { $null }
                    function Restore-RefreshTrackedKiloConfigSnapshot {}
                    function Invoke-DevBranchDefaultMcpSetup { param($State); $State }
                    function Load-ConfigFromFiles {
                        param($InfoBasePath)
                        $InfoBasePath | Should -Be (Join-Path $fixture.root 'База ветки')
                        $script:LoadAttempts++
                        if ($script:LoadAttempts -eq 1) { throw 'FIXTURE_LOAD_FAILED' }
                        $script:Calls.Add('load')
                        # The document writer may continue after admission.
                        [IO.File]::WriteAllText($contextPath, 'новая редакция другого чата', $utf8)
                        [IO.File]::WriteAllText((Join-Path $fixture.root 'src/cf/ConfigDumpInfo.xml'), 'loaded-cursor', $utf8)
                        [pscustomobject]@{currentCommit=(Get-CurrentCommit)}
                    }
                    function Invoke-DevBranchEnterpriseAutoUpdateIfLoaded { $script:Calls.Add('normalize') }
                    function Invoke-DevBranchMcpRestartAfterInfobaseLoad { param($State); $State }
                    function Sync-KiloItlCommandSurface {}
                    function Invoke-AiRules1cManagedMcpConfigReconcile { $script:Calls.Add('mcp') }
                    function Set-ItlOnDemandMcpSemanticReloadRequiredAction {}
                    function Set-VerificationClassificationRequiredAction {}
                    function New-LoadStateUpdates { @{} }
                    function New-DevBranchResultTransferBaseline { @{status='fixture'} }
                    function Get-VerificationClassificationInventoryPath { '' }
                    function Add-VerificationStaleIfNeeded {}
                    function Write-BaseUpdateResult {}
                    function Get-DevBranchKind { 'configuration' }
                    function Write-DevBranchRunUserReport { $script:Calls.Add('report') }
                    function Save-RefreshClassificationReportContext {}
                    { Invoke-RefreshDevBranchCore -OperationName $Operation -SynchronizeMaster:($Operation -eq 'refresh-dev-branch') } | Should -Throw 'FIXTURE_LOAD_FAILED'
                    $script:MergeState.pendingMergeStage | Should -Be 'merged'
                    $script:MergeState.pendingMergeTargetCommit | Should -Be $fixture.targetCommit
                    $LifecyclePhase = ''
                    { Invoke-RefreshDevBranchCore -OperationName $Operation -SynchronizeMaster:($Operation -eq 'refresh-dev-branch') } | Should -Throw 'FIXTURE_REFRESH_HANDOFF_COMPLETED'
                    @($script:Calls) | Should -Be @('handoff', 'load', 'normalize', 'mcp', 'report')
                    $script:LoadAttempts | Should -Be 2
                    $script:MergeState.pendingMergeOperation | Should -BeNullOrEmpty
                    $script:MergeState.lastRefreshMasterCommit | Should -Be $fixture.targetCommit
                    $script:MergeState.lastVerificationStatus | Should -Be 'failed'
                    $script:MergeState.lastVerifiedCommit | Should -Be $fixture.mergeCommit
                    [IO.File]::ReadAllText($contextPath) | Should -BeExactly 'новая редакция другого чата'
                    (Get-FileHash -LiteralPath $adrPath).Hash | Should -BeExactly $adrHash
                    @(Get-GitPathList -Arguments @('diff', '--cached', '--name-only', '-z', '--')).Count | Should -Be 0
                    @(Get-GitPathList -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', '-z', 'HEAD')) | Should -Be @('src/cf/ConfigDumpInfo.xml')
                    @(Get-GitPathList -Arguments @('ls-files', '-z', '--others', '--exclude-standard', '--')) | Should -Be @('docs/adr/0001 Перенос рабочего стола.md')
                }
            } finally {
                $resolved = [IO.Path]::GetFullPath($fixture.root)
                $resolved.StartsWith(([IO.Path]::GetTempPath().TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
                Remove-Item -LiteralPath $resolved -Recurse -Force
            }
        }

        It 'preserves <Path> staged=<Staged> while admitting independent documents and blocking other inputs' -TestCases @(
            @{Path='CONTEXT.md'; Staged=$true},
            @{Path='docs/adr/0001 Решение.md'; Staged=$true},
            @{Path='src/cf/Related.bsl'; Staged=$false},
            @{Path='src/cfe/Новый модуль.bsl'; Staged=$false},
            @{Path='src/configs/Новый модуль.bsl'; Staged=$false},
            @{Path='.agents/skills/foreign.md'; Staged=$false},
            @{Path='docs/adr/execute.ps1'; Staged=$false},
            @{Path='docs/other.md'; Staged=$false},
            @{Path='unknown.txt'; Staged=$false}
        ) {
            param($Path, $Staged)
            $fixture = New-LifecyclePostMergeCursorFixture -SkipCursor
            try {
                & {
                    . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
                    $absolute = Join-Path $fixture.root $Path
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $absolute) | Out-Null
                    [IO.File]::WriteAllText($absolute, 'чужая работа', [Text.UTF8Encoding]::new($false))
                    if ($Staged) { Invoke-Git @('add', '--', $Path) }
                    $before = Get-CurrentCommit
                    $indexBefore = @(Get-GitPathList -Arguments @('ls-files','--stage','-z','--',$Path)) -join "`0"
                    $independent = $Path -in @('CONTEXT.md','docs/adr/0001 Решение.md','docs/other.md')
                    if ($independent) {
                        { Assert-DevBranchLifecyclePostMergeGitState -Operation 'refresh-dev-branch' } | Should -Not -Throw
                    } else {
                        { Assert-DevBranchLifecyclePostMergeGitState -Operation 'refresh-dev-branch' } | Should -Throw '*LIFECYCLE_GIT_INPUTS_CHANGED*'
                        $script:RunRequiredAction | Should -Match '^prepare-lifecycle-git:'
                        $script:RunBlockerOwner.paths | Should -Contain $Path
                    }
                    [IO.File]::ReadAllText($absolute) | Should -BeExactly 'чужая работа'
                    [IO.File]::WriteAllText((Join-Path $fixture.root 'src/cf/ConfigDumpInfo.xml'), 'new cursor', [Text.UTF8Encoding]::new($false))
                    if ($independent) {
                        { Complete-RefreshConfigDumpInfoPostcondition -Operation 'refresh-dev-branch' -LoadResult ([pscustomobject]@{currentCommit=$before}) } | Should -Not -Throw
                    } else {
                        { Complete-RefreshConfigDumpInfoPostcondition -Operation 'refresh-dev-branch' -LoadResult ([pscustomobject]@{currentCommit=$before}) } | Should -Throw
                    }
                    if ($Path -eq 'src/cf/Related.bsl') {
                        (Get-CurrentCommit) | Should -Be $before
                    } else {
                        # Existing recovery checkpoints the owned cursor even
                        # when another untracked file blocks final completion.
                        @(Get-GitPathList -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', '-z', 'HEAD')) | Should -Be @('src/cf/ConfigDumpInfo.xml')
                    }
                    [IO.File]::ReadAllText($absolute) | Should -BeExactly 'чужая работа'
                    (@(Get-GitPathList -Arguments @('ls-files','--stage','-z','--',$Path)) -join "`0") | Should -BeExactly $indexBefore
                }
            } finally {
                $resolved = [IO.Path]::GetFullPath($fixture.root)
                $resolved.StartsWith(([IO.Path]::GetTempPath().TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
                Remove-Item -LiteralPath $resolved -Recurse -Force
            }
        }

        It 'retains the close guard and gives concrete decision guidance in both wrappers' {
            & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                function Assert-CleanGit { throw 'original strict guard' }
                { Assert-DevBranchLifecyclePostMergeGitState -Operation 'close-dev-branch' } | Should -Throw 'original strict guard'
            }
            foreach ($name in @('itl-refresh', 'itl-refresh-lite')) {
                $text = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents/skills/1c-workflow/kilo-command-templates/dev/$name.md.template") -Raw
                $text | Should -Match 'resolve-refresh-post-merge-worktree-then-repeat-same-itl-command'
                $text | Should -Match 'concrete options, consequences, and a recommendation'
                $text | Should -Match 'Complete safe owner-supported recovery and repeat this command in the same task'
            }
        }
    }

    It "records a resumable conflict transaction and gives the agent the same-command recovery for every lifecycle merge" {
        foreach ($case in @(
            @{ operation = "refresh-dev-branch"; stage = "refresh.merge-conflicts" },
            @{ operation = "refresh-dev-branch-lite"; stage = "refresh.merge-conflicts" },
            @{ operation = "close-dev-branch"; stage = "close.merge-conflicts" }
        )) {
            $fixture = New-LifecycleMergeConflictFixture
            try {
                $result = & {
                    param($Fixture, $Case)
                    . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                    $DevBranchName = "test"
                    $script:MergeState = [pscustomobject]@{
                        safeDevBranchName = "test"
                        devBranchName = "test"
                        devBranch = "itldev/test"
                    }
                    $script:FailureCategory = ""
                    $script:RequiredAction = ""
                    $script:ConflictStage = ""
                    function Read-DevBranchState { return $script:MergeState }
                    function Update-DevBranchState {
                        param([object]$State, [hashtable]$Updates)
                        foreach ($key in $Updates.Keys) {
                            if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                                $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                            } else {
                                $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                            }
                        }
                    }
                    function Set-RunStage { param([string]$Stage); $script:ConflictStage = $Stage }
                    function Set-RunFailureContext { param([string]$Category, [string]$RequiredAction); $script:FailureCategory = $Category; $script:RequiredAction = $RequiredAction }
                    function Restart-Agent1cAfterDevBranchMerge { throw "unexpected restart" }

                    $message = ""
                    try {
                        Invoke-NewDevBranchLifecycleMerge `
                            -State $script:MergeState `
                            -Operation $Case.operation `
                            -TargetCommit $Fixture.targetCommit `
                            -ConflictStage $Case.stage
                    } catch {
                        $message = $_.Exception.Message
                    }
                    [pscustomobject]@{
                        message = $message
                        category = $script:FailureCategory
                        requiredAction = $script:RequiredAction
                        runStage = $script:ConflictStage
                        pendingOperation = $script:MergeState.pendingMergeOperation
                        pendingBranch = $script:MergeState.pendingMergeBranch
                        pendingBranchCommit = $script:MergeState.pendingMergeBranchCommit
                        pendingTarget = $script:MergeState.pendingMergeTargetCommit
                        pendingStage = $script:MergeState.pendingMergeStage
                        conflicts = @($script:MergeState.pendingMergeConflictPaths)
                        mergeHead = (Get-GitMergeHeadCommit)
                        head = (Get-CurrentCommit)
                        cursor = (Get-Content -LiteralPath (Join-Path $Fixture.root "src\cf\ConfigDumpInfo.xml") -Raw).Trim()
                    }
                } $fixture $case

                $result.message | Should -Match "^LIFECYCLE_MERGE_CONFLICT"
                $result.message | Should -Match "run git add"
                $result.message | Should -Match "Do not create the merge commit manually"
                $result.category | Should -Be "merge-conflict"
                $result.requiredAction | Should -Be "agent-progressive-semantic-repair-run-git-add-repeat-same-itl-command-no-manual-commit"
                $result.runStage | Should -Be $case.stage
                $result.pendingOperation | Should -Be $case.operation
                $result.pendingBranch | Should -Be "itldev/test"
                $result.pendingBranchCommit | Should -Be $fixture.branchCommit
                $result.pendingTarget | Should -Be $fixture.targetCommit
                $result.pendingStage | Should -Be "conflicts"
                $result.conflicts | Should -Be @("conflict.txt")
                $result.mergeHead | Should -Be $fixture.targetCommit
                $result.head | Should -Be $fixture.branchCommit
                $result.cursor | Should -Be "branch-cursor"
            } finally {
                Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "limits merge UUID integrity to both changed sides plus Configuration.xml" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl UUID дельта " + [guid]::NewGuid().ToString("N"))
        $configRoot = Join-Path $tempRoot "src\cf"
        try {
            New-Item -ItemType Directory -Force -Path $configRoot | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $configRoot "Configuration.xml"), '<MetaDataObject><Configuration uuid="10ffa7c3-3d5d-4edd-9ebe-1acc0592d242" /></MetaDataObject>', [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::WriteAllText((Join-Path $configRoot "Unchanged.xml"), '<MetaDataObject><Catalog uuid="20ffa7c3-3d5d-4edd-9ebe-1acc0592d242" /></MetaDataObject>', [System.Text.UTF8Encoding]::new($false))
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot config core.autocrlf false
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M master

            & git -C $tempRoot checkout --quiet -b itldev/test
            [System.IO.File]::WriteAllText((Join-Path $configRoot "Branch.xml"), '<MetaDataObject><Catalog uuid="30ffa7c3-3d5d-4edd-9ebe-1acc0592d242" /></MetaDataObject>', [System.Text.UTF8Encoding]::new($false))
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "branch" *> $null

            & git -C $tempRoot checkout --quiet master
            [System.IO.File]::WriteAllText((Join-Path $configRoot "Master.xml"), '<MetaDataObject><Catalog uuid="40ffa7c3-3d5d-4edd-9ebe-1acc0592d242" /></MetaDataObject>', [System.Text.UTF8Encoding]::new($false))
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "master" *> $null
            & git -C $tempRoot checkout --quiet itldev/test
            & git -C $tempRoot merge --no-ff --no-commit master *> $null
            $LASTEXITCODE | Should -Be 0

            $paths = & {
                param($Root)
                . $HelperPath -ProjectRoot $Root -Action help *> $null
                $script:CapturedUuidPaths = @()
                function Get-OneCConfigurationSourceValidatorPath { return "configuration-validator" }
                function Get-OneCSourceIntegrityValidatorPath { return "uuid-validator" }
                function Invoke-OneCSourceIntegrityValidator {
                    param([string]$Validator, [string]$ScriptPath, [string[]]$Arguments, [switch]$SupportsOutFile)
                    if ($Validator -ceq "uuid") {
                        $listIndex = [Array]::IndexOf($Arguments, "-IncludePathList")
                        $script:CapturedUuidPaths = @(Get-Content -LiteralPath $Arguments[$listIndex + 1] -Encoding UTF8)
                    }
                    return [pscustomobject]@{ exitCode = 0; details = "ok" }
                }
                Assert-OneCConfigurationSourceIntegrity -ExportPath "src/cf"
                return @($script:CapturedUuidPaths)
            } $tempRoot

            $paths | Should -Be @("Branch.xml", "Configuration.xml", "Master.xml")
            $paths | Should -Not -Contain "Unchanged.xml"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "expands only a changed Template <Change> to its owner, descriptor, and DCS payload" -TestCases @(
        @{ Change = "descriptor" }
        @{ Change = "payload" }
    ) {
        param($Change)
        $fixture = New-LifecycleTemplateIntegrityFixture
        try {
            $result = & {
                param($Fixture, $Change)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $script:CapturedTemplateValidatorCalls = [Collections.Generic.List[object]]::new()
                $script:CapturedTemplateUuidPaths = @()
                function Get-OneCConfigurationSourceValidatorPath { return "configuration-validator" }
                function Get-OneCSourceIntegrityValidatorPath {
                    param([string]$Validator)
                    return "$Validator-validator"
                }
                function Invoke-OneCSourceIntegrityValidator {
                    param([string]$Validator, [string]$ScriptPath, [string[]]$Arguments, [switch]$SupportsOutFile)
                    $validatedPath = ""
                    foreach ($parameter in @("-ObjectPath", "-TemplatePath")) {
                        $index = [Array]::IndexOf($Arguments, $parameter)
                        if ($index -ge 0) { $validatedPath = [string]$Arguments[$index + 1]; break }
                    }
                    $script:CapturedTemplateValidatorCalls.Add([pscustomobject]@{ validator = $Validator; path = $validatedPath }) | Out-Null
                    if ($Validator -ceq "uuid") {
                        $listIndex = [Array]::IndexOf($Arguments, "-IncludePathList")
                        $script:CapturedTemplateUuidPaths = @(Get-Content -LiteralPath $Arguments[$listIndex + 1] -Encoding UTF8)
                    }
                    return [pscustomobject]@{ exitCode = 0; details = "ok" }
                }

                $changedRepoPath = if ($Change -eq "descriptor") { $Fixture.descriptorRepoPath } else { $Fixture.payloadRepoPath }
                Assert-OneCConfigurationSourceIntegrity -ExportPath "src/cf" -AdditionalRelativePaths @($changedRepoPath.Substring("src/cf/".Length))
                [pscustomobject]@{
                    calls = @($script:CapturedTemplateValidatorCalls)
                    uuidPaths = @($script:CapturedTemplateUuidPaths)
                    changedRepoPath = $changedRepoPath
                }
            } $fixture $Change

            $metadataPaths = @($result.calls | Where-Object validator -eq "metadata" | ForEach-Object path | Sort-Object)
            # The Template aggregate is checked above; the generic metadata validator cannot parse its descriptor.
            $expectedMetadataPaths = @($fixture.ownerPath)
            $expectedMetadataPaths = @($expectedMetadataPaths | Sort-Object)
            $metadataPaths | Should -Be $expectedMetadataPaths
            @($result.calls | Where-Object path -eq $fixture.descriptorPath) | Should -HaveCount 0
            @($result.calls | Where-Object { $_.validator -eq "skd" -and $_.path -ceq $fixture.payloadPath }) | Should -HaveCount 1
            @($result.calls | Where-Object path -eq $fixture.unrelatedPath) | Should -HaveCount 0
            $result.uuidPaths | Should -Contain "Configuration.xml"
            $result.uuidPaths | Should -Contain $result.changedRepoPath.Substring("src/cf/".Length)
            $result.uuidPaths | Should -HaveCount 2
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects an inconsistent Template aggregate: <Case>" -TestCases @(
        @{ Case = "missing owner registration"; ExpectedCode = "template-owner-registration-invalid" }
        @{ Case = "descriptor name differs from path"; ExpectedCode = "template-name-path-mismatch" }
        @{ Case = "TemplateType differs from payload"; ExpectedCode = "template-payload-type-mismatch" }
        @{ Case = "owner main schema reference is unresolved"; ExpectedCode = "template-owner-reference-unresolved" }
    ) {
        param($Case, $ExpectedCode)
        $fixture = New-LifecycleTemplateIntegrityFixture
        try {
            $codes = & {
                param($Fixture, $Case)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                if ($Case -eq "missing owner registration") {
                    $source = [IO.File]::ReadAllText($Fixture.ownerPath, [Text.Encoding]::UTF8)
                    [IO.File]::WriteAllText($Fixture.ownerPath, $source.Replace("<Template>ОсновнаяСхемаКомпоновкиДанных</Template>", "<Template>ДругойМакет</Template>"), [Text.UTF8Encoding]::new($false))
                } elseif ($Case -eq "descriptor name differs from path") {
                    $source = [IO.File]::ReadAllText($Fixture.descriptorPath, [Text.Encoding]::UTF8)
                    [IO.File]::WriteAllText($Fixture.descriptorPath, $source.Replace("<Name>ОсновнаяСхемаКомпоновкиДанных</Name>", "<Name>ДругаяСхема</Name>"), [Text.UTF8Encoding]::new($false))
                } elseif ($Case -eq "TemplateType differs from payload") {
                    $source = [IO.File]::ReadAllText($Fixture.descriptorPath, [Text.Encoding]::UTF8)
                    [IO.File]::WriteAllText($Fixture.descriptorPath, $source.Replace("<TemplateType>DataCompositionSchema</TemplateType>", "<TemplateType>SpreadsheetDocument</TemplateType>"), [Text.UTF8Encoding]::new($false))
                } else {
                    $source = [IO.File]::ReadAllText($Fixture.ownerPath, [Text.Encoding]::UTF8)
                    [IO.File]::WriteAllText($Fixture.ownerPath, $source.Replace(".Template.ОсновнаяСхемаКомпоновкиДанных", ".Template.НесуществующаяСхема"), [Text.UTF8Encoding]::new($false))
                }
                $scope = Resolve-OneCTemplateSourceIntegrityScope -CandidatePaths @($Fixture.descriptorRepoPath) -ProjectRoot $Fixture.root
                return @($scope.issues | ForEach-Object code)
            } $fixture $Case

            $codes | Should -Contain $ExpectedCode
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "syncs managed ignored validators from main before resumed merge source validation" {
        $source = $HelperText
        $resumeStart = $source.IndexOf("function Resume-DevBranchLifecycleMergeIfPresent", [System.StringComparison]::Ordinal)
        $resumeEnd = $source.IndexOf("function ", $resumeStart + 10, [System.StringComparison]::Ordinal)
        $resumeSource = $source.Substring($resumeStart, $resumeEnd - $resumeStart)
        $syncIndex = $resumeSource.IndexOf("Sync-AiRules1cManagedIgnoredFilesFromMain -State `$State", [System.StringComparison]::Ordinal)
        $validationIndex = $resumeSource.IndexOf("Assert-OneCConfigurationSourceIntegrity", [System.StringComparison]::Ordinal)

        $syncIndex | Should -BeGreaterThan -1
        $validationIndex | Should -BeGreaterThan $syncIndex
    }

    It "blocks a clean Git merge with duplicate root metadata and commits it after the agent fixes, stages, and retries" {
        $fixture = New-LifecycleMergeSourceIntegrityFixture
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:OneCConfigurationSourceValidatorPathOverride = $Fixture.validatorPath
                $script:MergeState = [pscustomobject]@{ safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test" }
                $script:FailureCategory = ""
                $script:RequiredAction = ""
                $script:FailureStage = ""
                $script:RestartCount = 0
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Set-RunStage { param([string]$Stage, [string]$Detail); $script:FailureStage = $Stage }
                function Set-RunFailureContext { param([string]$Category, [string]$RequiredAction); $script:FailureCategory = $Category; $script:RequiredAction = $RequiredAction }
                function Restart-Agent1cAfterDevBranchMerge { $script:RestartCount++; throw "RESTART_AFTER_MERGE" }

                $firstMessage = ""
                try {
                    Invoke-NewDevBranchLifecycleMerge -State $script:MergeState -Operation "refresh-dev-branch" -TargetCommit $Fixture.targetCommit -ConflictStage "refresh.merge-conflicts"
                } catch {
                    $firstMessage = $_.Exception.Message
                }
                $headBeforeFix = Get-CurrentCommit
                $mergeInProgressBeforeFix = Test-GitMergeInProgress
                $categoryBeforeFix = $script:FailureCategory
                $requiredActionBeforeFix = $script:RequiredAction
                $stageBeforeFix = $script:FailureStage
                $pendingStageBeforeFix = $script:MergeState.pendingMergeStage
                $conflictsBeforeFix = @($script:MergeState.pendingMergeConflictPaths)

                $source = [System.IO.File]::ReadAllText($Fixture.configurationPath, [System.Text.Encoding]::UTF8)
                $duplicate = "    <Constant>Shared</Constant>"
                $lastDuplicate = $source.LastIndexOf($duplicate, [System.StringComparison]::Ordinal)
                $source = $source.Remove($lastDuplicate, $duplicate.Length + 2)
                [System.IO.File]::WriteAllText($Fixture.configurationPath, $source, [System.Text.UTF8Encoding]::new($false))
                Invoke-Git @("add", "--", "src/cf/Configuration.xml")

                $retryMessage = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $retryMessage = $_.Exception.Message
                }
                $head = Get-CurrentCommit
                [pscustomobject]@{
                    firstMessage = $firstMessage
                    retryMessage = $retryMessage
                    category = $categoryBeforeFix
                    requiredAction = $requiredActionBeforeFix
                    failureStage = $stageBeforeFix
                    pendingStageBeforeFix = $pendingStageBeforeFix
                    conflictsBeforeFix = $conflictsBeforeFix
                    headBeforeFix = $headBeforeFix
                    mergeInProgressBeforeFix = $mergeInProgressBeforeFix
                    head = $head
                    parents = @(Get-GitCommitParents -Commit $head)
                    restartCount = $script:RestartCount
                    mergeInProgress = Test-GitMergeInProgress
                    pendingStage = $script:MergeState.pendingMergeStage
                    status = @(& git -C $Fixture.root status --porcelain)
                }
            } $fixture

            $result.firstMessage | Should -Match "^ONEC_SOURCE_INTEGRITY_FAILED"
            $result.firstMessage | Should -Match "Duplicate: Constant.Shared"
            $result.category | Should -Be "source-integrity"
            $result.requiredAction | Should -Be "agent-progressive-semantic-repair-run-git-add-repeat-same-itl-command-no-manual-commit"
            $result.failureStage | Should -Be "source-integrity.failed"
            $result.pendingStageBeforeFix | Should -Be "conflicts"
            $result.conflictsBeforeFix | Should -Be @("src/cf/Configuration.xml")
            $result.headBeforeFix | Should -Be $fixture.branchCommit
            $result.mergeInProgressBeforeFix | Should -BeTrue
            $result.retryMessage | Should -Be "RESTART_AFTER_MERGE"
            $result.parents | Should -Be @($fixture.branchCommit, $fixture.targetCommit)
            $result.restartCount | Should -Be 1
            $result.mergeInProgress | Should -BeFalse
            $result.pendingStage | Should -Be "merged"
            $result.status | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "blocks a clean merge-created duplicate BSL method and resumes after agent repair" {
        $fixture = New-LifecycleMergeBslDuplicateFixture
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:OneCConfigurationSourceValidatorPathOverride = $Fixture.validatorPath
                $script:MergeState = [pscustomobject]@{ safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test" }
                $script:FailureCategory = ""
                $script:RequiredAction = ""
                $script:FailureStage = ""
                $script:RestartCount = 0
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Set-RunStage { param([string]$Stage, [string]$Detail); $script:FailureStage = $Stage }
                function Set-RunFailureContext { param([string]$Category, [string]$RequiredAction); $script:FailureCategory = $Category; $script:RequiredAction = $RequiredAction }
                function Restart-Agent1cAfterDevBranchMerge { $script:RestartCount++; throw "RESTART_AFTER_MERGE" }

                $firstMessage = ""
                try {
                    Invoke-NewDevBranchLifecycleMerge -State $script:MergeState -Operation "refresh-dev-branch" -TargetCommit $Fixture.targetCommit -ConflictStage "refresh.merge-conflicts"
                } catch {
                    $firstMessage = $_.Exception.Message
                }
                $reportPath = $script:RunSourceIntegrityReportPath
                $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $conflictsBeforeFix = @($script:MergeState.pendingMergeConflictPaths)
                $source = [System.IO.File]::ReadAllText($Fixture.modulePath, [System.Text.Encoding]::UTF8)
                $pattern = '(?ms)Процедура ОбщийМетод\(\)\r?\nКонецПроцедуры\r?\n\r?\n'
                # The static fourth argument is RegexOptions, not a replacement
                # count. Repair one duplicate; retain the shared added method.
                $source = [regex]::new($pattern).Replace($source, "", 1)
                if ([regex]::Matches($source, $pattern).Count -ne 1) { throw "Duplicate repair must preserve exactly one shared method." }
                [System.IO.File]::WriteAllText($Fixture.modulePath, $source, [System.Text.UTF8Encoding]::new($false))
                Invoke-Git @("add", "--", $Fixture.moduleRepoPath)

                $retryMessage = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $retryMessage = $_.Exception.Message
                }
                $head = Get-CurrentCommit
                [pscustomobject]@{
                    firstMessage = $firstMessage
                    retryMessage = $retryMessage
                    category = $script:FailureCategory
                    requiredAction = $script:RequiredAction
                    failureStage = $script:FailureStage
                    reportPath = $reportPath
                    issue = @($report.issues)[0]
                    conflictPaths = $conflictsBeforeFix
                    parents = @(Get-GitCommitParents -Commit $head)
                    restartCount = $script:RestartCount
                    mergeInProgress = Test-GitMergeInProgress
                }
            } $fixture

            $result.firstMessage | Should -Match "^ONEC_SOURCE_INTEGRITY_FAILED"
            $result.firstMessage | Should -Match "ОбщийМетод"
            $result.category | Should -Be "source-integrity"
            $result.requiredAction | Should -Be "agent-progressive-semantic-repair-run-git-add-repeat-same-itl-command-no-manual-commit"
            $result.failureStage | Should -Be "source-integrity.failed"
            $result.reportPath | Should -Exist
            $result.issue.validator | Should -Be "bsl-merge-duplicates"
            $result.issue.code | Should -Be "merge-created-duplicate-declaration"
            $result.issue.path | Should -Be $fixture.moduleRepoPath
            $result.issue.baseCount | Should -Be 0
            $result.issue.branchCount | Should -Be 1
            $result.issue.targetCount | Should -Be 1
            $result.issue.mergedCount | Should -Be 2
            $result.conflictPaths | Should -Be $fixture.moduleRepoPath
            $result.retryMessage | Should -Be "RESTART_AFTER_MERGE"
            $result.parents | Should -Be @($fixture.branchCommit, $fixture.targetCommit)
            $result.restartCount | Should -Be 1
            $result.mergeInProgress | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "routes a clean merge-created form defect to the specialized form validator and resumes after repair" {
        $fixture = New-LifecycleMergeFormIntegrityFixture
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:OneCConfigurationSourceValidatorPathOverride = $Fixture.configurationValidatorPath
                $script:OneCSourceIntegrityValidatorPathOverrides = @{ form = $Fixture.formValidatorPath }
                $script:MergeState = [pscustomobject]@{ safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test" }
                $script:FailureCategory = ""
                $script:RequiredAction = ""
                $script:FailureStage = ""
                $script:RestartCount = 0
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Set-RunStage { param([string]$Stage, [string]$Detail); $script:FailureStage = $Stage }
                function Set-RunFailureContext { param([string]$Category, [string]$RequiredAction); $script:FailureCategory = $Category; $script:RequiredAction = $RequiredAction }
                function Restart-Agent1cAfterDevBranchMerge { $script:RestartCount++; throw "RESTART_AFTER_MERGE" }

                $firstMessage = ""
                try {
                    Invoke-NewDevBranchLifecycleMerge -State $script:MergeState -Operation "refresh-dev-branch" -TargetCommit $Fixture.targetCommit -ConflictStage "refresh.merge-conflicts"
                } catch {
                    $firstMessage = $_.Exception.Message
                }
                $reportPath = $script:RunSourceIntegrityReportPath
                $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $categoryBeforeFix = $script:FailureCategory
                $requiredActionBeforeFix = $script:RequiredAction
                $stageBeforeFix = $script:FailureStage
                $conflictsBeforeFix = @($script:MergeState.pendingMergeConflictPaths)
                $source = [System.IO.File]::ReadAllText($Fixture.formPath, [System.Text.Encoding]::UTF8)
                $duplicate = '    <Item name="Shared" />'
                $lastDuplicate = $source.LastIndexOf($duplicate, [System.StringComparison]::Ordinal)
                $source = $source.Remove($lastDuplicate, $duplicate.Length + 2)
                [System.IO.File]::WriteAllText($Fixture.formPath, $source, [System.Text.UTF8Encoding]::new($false))
                Invoke-Git @("add", "--", $Fixture.formRepoPath)

                $retryMessage = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $retryMessage = $_.Exception.Message
                }
                $head = Get-CurrentCommit
                [pscustomobject]@{
                    firstMessage = $firstMessage
                    retryMessage = $retryMessage
                    category = $categoryBeforeFix
                    requiredAction = $requiredActionBeforeFix
                    failureStage = $stageBeforeFix
                    reportPath = $reportPath
                    issue = @($report.issues)[0]
                    conflictPaths = $conflictsBeforeFix
                    parents = @(Get-GitCommitParents -Commit $head)
                    restartCount = $script:RestartCount
                    mergeInProgress = Test-GitMergeInProgress
                }
            } $fixture

            $result.firstMessage | Should -Match "^ONEC_SOURCE_INTEGRITY_FAILED"
            $result.firstMessage | Should -Match "Duplicate form item Shared"
            $result.category | Should -Be "source-integrity"
            $result.requiredAction | Should -Be "agent-progressive-semantic-repair-run-git-add-repeat-same-itl-command-no-manual-commit"
            $result.failureStage | Should -Be "source-integrity.failed"
            $result.reportPath | Should -Exist
            $result.issue.validator | Should -Be "form"
            $result.issue.code | Should -Be "specialized-validation-failed"
            $result.issue.path | Should -Be $fixture.formRepoPath
            $result.conflictPaths | Should -Be $fixture.formRepoPath
            $result.retryMessage | Should -Be "RESTART_AFTER_MERGE"
            $result.parents | Should -Be @($fixture.branchCommit, $fixture.targetCommit)
            $result.restartCount | Should -Be 1
            $result.mergeInProgress | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "completes reset then refresh-lite with an inherited form diagnostic (resume=<Resume>)" -TestCases @(
        @{ Resume = $false }, @{ Resume = $true }
    ) {
        param($Resume)
        $fixture = New-LifecycleResetFormIntegrityFixture
        try {
            $result = & {
                param($Fixture, $Resume)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:OneCConfigurationSourceValidatorPathOverride = $Fixture.configurationValidatorPath
                $script:OneCSourceIntegrityValidatorPathOverrides = @{ form = $Fixture.formValidatorPath }
                $script:MergeState = [pscustomobject]@{ safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test" }
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key] -Force
                    }
                }
                function Restart-Agent1cAfterDevBranchMerge { throw "RESTART_AFTER_MERGE" }

                # Exercise the actual reset tree replacement, retaining the old parent.
                $resetHead = Set-DevBranchTreeToMasterCommit -MasterCommit $Fixture.targetCommit
                $resetTree = Get-GitObjectIdForTreePath -Treeish $resetHead -RepoPath "src/cf"
                $targetTree = Get-GitObjectIdForTreePath -Treeish $Fixture.targetCommit -RepoPath "src/cf"
                $mergeBase = (Get-GitOutput @("merge-base", $resetHead, $Fixture.targetCommit)).Trim()
                if ($Resume) {
                    # Recreate the durable state left by the previous helper's false
                    # source-integrity failure. Conflict paths are not explicit repairs.
                    Invoke-Git @("merge", "--no-ff", "--no-commit", $Fixture.targetCommit)
                    Set-PendingDevBranchMergeTransaction -State $script:MergeState -Operation "refresh-dev-branch-lite" `
                        -Branch "itldev/test" -BranchCommit $resetHead -TargetCommit $Fixture.targetCommit `
                        -Stage "conflicts" -AllowedPaths @(Get-DevBranchMergeIndexPaths) -ConflictPaths @($Fixture.formRepoPath)
                }
                $message = ""
                try {
                    if ($Resume) {
                        Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch-lite" -ConflictStage "refresh.merge-conflicts" | Out-Null
                    } else {
                        Invoke-NewDevBranchLifecycleMerge -State $script:MergeState -Operation "refresh-dev-branch-lite" -TargetCommit $Fixture.targetCommit -ConflictStage "refresh.merge-conflicts"
                    }
                } catch { $message = $_.Exception.Message }
                [pscustomobject]@{
                    message = $message
                    resetHead = $resetHead
                    resetParents = @(Get-GitCommitParents -Commit $resetHead)
                    resetTree = $resetTree
                    targetTree = $targetTree
                    mergeBase = $mergeBase
                    parents = @(Get-GitCommitParents -Commit (Get-CurrentCommit))
                    stage = $script:MergeState.pendingMergeStage
                    mergeInProgress = Test-GitMergeInProgress
                    changes = @(Get-VerificationWorkingTreeChangePaths -PathSpec @("."))
                    source = [IO.File]::ReadAllText($Fixture.formPath, [Text.Encoding]::UTF8)
                }
            } $fixture $Resume
            $result.resetParents | Should -Be @($fixture.branchCommit)
            $result.resetTree | Should -Be $result.targetTree
            $result.mergeBase | Should -Not -Be $result.resetHead
            $result.mergeBase | Should -Not -Be $fixture.targetCommit
            $result.message | Should -Be "RESTART_AFTER_MERGE"
            $result.parents | Should -Be @($result.resetHead, $fixture.targetCommit)
            $result.stage | Should -Be "merged"
            $result.mergeInProgress | Should -BeFalse
            $result.changes | Should -HaveCount 0
            $result.source | Should -Match '<Command name="Пустышка" />'
        } finally {
            if ([IO.Path]::GetFullPath($fixture.root).StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "keeps reset form validation for <Change> despite equal parent blobs (invalid commands: <InvalidCommands>)" -TestCases @(
        foreach ($change in @('staged', 'unstaged', 'staged-reverted-worktree', 'repair', 'relative-repair')) {
            foreach ($invalid in @($false, $true)) { @{ Change = $change; InvalidCommands = $invalid } }
        }
    ) {
        param($Change, $InvalidCommands)
        $fixture = New-LifecycleResetFormIntegrityFixture -InvalidCommandIds:$InvalidCommands
        try {
            $result = & {
                param($Fixture, $Change)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $script:OneCConfigurationSourceValidatorPathOverride = $Fixture.configurationValidatorPath
                $script:OneCSourceIntegrityValidatorPathOverrides = @{ form = $Fixture.formValidatorPath }
                Set-DevBranchTreeToMasterCommit -MasterCommit $Fixture.targetCommit | Out-Null
                Invoke-Git @("merge", "--no-ff", "--no-commit", $Fixture.targetCommit)
                $source = [IO.File]::ReadAllText($Fixture.formPath, [Text.Encoding]::UTF8)
                $arguments = @{ ExportPath = "src/cf" }
                if ($Change -eq "repair") {
                    $arguments.AdditionalPaths = @($Fixture.formRepoPath)
                } elseif ($Change -eq "relative-repair") {
                    $arguments.AdditionalRelativePaths = @($Fixture.formRepoPath.Substring("src/cf/".Length))
                } else {
                    [IO.File]::WriteAllText($Fixture.formPath, $source.Replace('</Form>', '<!-- agent edit --></Form>'), [Text.UTF8Encoding]::new($false))
                    if ($Change -ne "unstaged") { Invoke-Git @("add", "--", $Fixture.formRepoPath) }
                    if ($Change -eq "staged-reverted-worktree") { [IO.File]::WriteAllText($Fixture.formPath, $source, [Text.UTF8Encoding]::new($false)) }
                }
                $allMergePaths = @(Get-OneCSourceIntegrityCandidatePaths -ExportPath "src/cf" -IncludeAllMergeChanges)
                $beforeValidation = [IO.File]::ReadAllText($Fixture.formPath, [Text.Encoding]::UTF8)
                $message = ""
                $advisoryWarnings = @()
                $WarningPreference = 'Stop'
                try {
                    Assert-OneCConfigurationSourceIntegrity @arguments 3>&1 | ForEach-Object {
                        if ($_ -is [System.Management.Automation.WarningRecord]) { $advisoryWarnings += $_ }
                    }
                } catch { $message = $_.Exception.Message }
                [pscustomobject]@{
                    message = $message; allMergePaths = $allMergePaths; mergeInProgress = Test-GitMergeInProgress
                    warnings = @($advisoryWarnings | ForEach-Object ToString)
                    reportPath = $script:RunSourceIntegrityReportPath
                    sourceUnchanged = $beforeValidation -ceq [IO.File]::ReadAllText($Fixture.formPath, [Text.Encoding]::UTF8)
                }
            } $fixture $Change
            if ($InvalidCommands) {
                $result.message | Should -Match '^ONEC_SOURCE_INTEGRITY_FAILED'
                $result.message | Should -Match 'Duplicate command id=1'
            } else {
                $result.message | Should -Be ''
                $result.reportPath | Should -Be ''
            }
            $result.warnings | Should -HaveCount 2
            $result.warnings[0] | Should -Match ([regex]::Escape($fixture.formRepoPath) + ':\[WARN\].*COMMAND_ACTION_UNASSIGNED')
            $result.warnings[0] | Should -Match 'УстановитьУровеньЗаглушка'
            $result.sourceUnchanged | Should -BeTrue
            $result.allMergePaths | Should -Contain $fixture.formRepoPath
            $result.mergeInProgress | Should -BeTrue
        } finally {
            if ([IO.Path]::GetFullPath($fixture.root).StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "leaves unresolved conflicts untouched and commits them after resolution, staging, and the same command retry" {
        $fixture = New-LifecycleMergeConflictFixture
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:MergeState = [pscustomobject]@{ safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test" }
                $script:RestartCount = 0
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Set-RunStage {}
                function Set-RunFailureContext {}
                function Assert-OneCConfigurationSourceIntegrity {}
                function Restart-Agent1cAfterDevBranchMerge { $script:RestartCount++; throw "RESTART_AFTER_MERGE" }

                try {
                    Invoke-NewDevBranchLifecycleMerge -State $script:MergeState -Operation "refresh-dev-branch" -TargetCommit $Fixture.targetCommit -ConflictStage "refresh.merge-conflicts"
                } catch {}
                $headBeforeRetry = Get-CurrentCommit
                $unresolvedMessage = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $unresolvedMessage = $_.Exception.Message
                }
                $headAfterUnresolvedRetry = Get-CurrentCommit

                Set-Content -LiteralPath (Join-Path $Fixture.root "conflict.txt") -Encoding UTF8 -Value "resolved"
                Invoke-Git @("add", "--", "conflict.txt")
                $resolvedMessage = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $resolvedMessage = $_.Exception.Message
                }
                $head = Get-CurrentCommit
                [pscustomobject]@{
                    unresolvedMessage = $unresolvedMessage
                    resolvedMessage = $resolvedMessage
                    headBeforeRetry = $headBeforeRetry
                    headAfterUnresolvedRetry = $headAfterUnresolvedRetry
                    head = $head
                    parents = @(Get-GitCommitParents -Commit $head)
                    restartCount = $script:RestartCount
                    mergeInProgress = Test-GitMergeInProgress
                    pendingStage = $script:MergeState.pendingMergeStage
                    pendingCommit = $script:MergeState.pendingMergeCommit
                    cursor = (Get-Content -LiteralPath (Join-Path $Fixture.root "src\cf\ConfigDumpInfo.xml") -Raw).Trim()
                    status = @(& git -C $Fixture.root status --porcelain)
                }
            } $fixture

            $result.unresolvedMessage | Should -Match "^LIFECYCLE_MERGE_CONFLICT"
            $result.headBeforeRetry | Should -Be $fixture.branchCommit
            $result.headAfterUnresolvedRetry | Should -Be $fixture.branchCommit
            $result.resolvedMessage | Should -Be "RESTART_AFTER_MERGE"
            $result.parents | Should -Be @($fixture.branchCommit, $fixture.targetCommit)
            $result.restartCount | Should -Be 1
            $result.mergeInProgress | Should -BeFalse
            $result.pendingStage | Should -Be "merged"
            $result.pendingCommit | Should -Be $result.head
            $result.cursor | Should -Be "branch-cursor"
            $result.status | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "recreates the same pinned merge when cleanup removed MERGE_HEAD after a recorded conflict" {
        $fixture = New-LifecycleMergeConflictFixture
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:MergeState = [pscustomobject]@{ safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test" }
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Set-RunStage {}
                function Set-RunFailureContext {}
                function Assert-OneCConfigurationSourceIntegrity {}
                function Restart-Agent1cAfterDevBranchMerge { throw "UNEXPECTED_RESTART" }

                try {
                    Invoke-NewDevBranchLifecycleMerge -State $script:MergeState -Operation "refresh-dev-branch" -TargetCommit $Fixture.targetCommit -ConflictStage "refresh.merge-conflicts"
                } catch {}
                Invoke-Git @("merge", "--abort")
                $message = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $message = $_.Exception.Message
                }
                [pscustomobject]@{
                    message = $message
                    mergeInProgress = Test-GitMergeInProgress
                    head = Get-CurrentCommit
                    target = Get-GitMergeHeadCommit
                    pendingStage = $script:MergeState.pendingMergeStage
                }
            } $fixture

            $result.message | Should -Match "^LIFECYCLE_MERGE_CONFLICT"
            $result.mergeInProgress | Should -BeTrue
            $result.head | Should -Be $fixture.branchCommit
            $result.target | Should -Be $fixture.targetCommit
            $result.pendingStage | Should -Be "conflicts"
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "blocks unstaged resolutions, unrelated untracked files, and unrelated staged files during resume" {
        foreach ($case in @(
            @{ kind = "unstaged"; expected = "^LIFECYCLE_MERGE_CONFLICT" },
            @{ kind = "untracked"; expected = "^LIFECYCLE_MERGE_UNTRACKED_FILES" },
            @{ kind = "staged"; expected = "^LIFECYCLE_MERGE_UNEXPECTED_STAGED_FILES" }
        )) {
            $fixture = New-LifecycleMergeConflictFixture
            try {
                $result = & {
                    param($Fixture, $Case)
                    . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                    $DevBranchName = "test"
                    $script:MergeState = [pscustomobject]@{ safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test" }
                    function Read-DevBranchState { return $script:MergeState }
                    function Update-DevBranchState {
                        param([object]$State, [hashtable]$Updates)
                        foreach ($key in $Updates.Keys) {
                            if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                                $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                            } else {
                                $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                            }
                        }
                    }
                    function Set-RunStage {}
                    function Set-RunFailureContext {}
                    function Assert-OneCConfigurationSourceIntegrity {}
                    function Restart-Agent1cAfterDevBranchMerge { throw "unexpected restart" }
                    try {
                        Invoke-NewDevBranchLifecycleMerge -State $script:MergeState -Operation "refresh-dev-branch" -TargetCommit $Fixture.targetCommit -ConflictStage "refresh.merge-conflicts"
                    } catch {}

                    Set-Content -LiteralPath (Join-Path $Fixture.root "conflict.txt") -Encoding UTF8 -Value "resolved"
                    Invoke-Git @("add", "--", "conflict.txt")
                    switch ($Case.kind) {
                        "unstaged" { Set-Content -LiteralPath (Join-Path $Fixture.root "conflict.txt") -Encoding UTF8 -Value "resolved-but-not-staged" }
                        "untracked" { Set-Content -LiteralPath (Join-Path $Fixture.root "foreign.txt") -Encoding UTF8 -Value "foreign" }
                        "staged" {
                            Set-Content -LiteralPath (Join-Path $Fixture.root "unrelated.txt") -Encoding UTF8 -Value "foreign-staged"
                            Invoke-Git @("add", "--", "unrelated.txt")
                        }
                    }
                    $message = ""
                    try {
                        Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                    } catch {
                        $message = $_.Exception.Message
                    }
                    [pscustomobject]@{
                        message = $message
                        head = Get-CurrentCommit
                        mergeInProgress = Test-GitMergeInProgress
                    }
                } $fixture $case

                $result.message | Should -Match $case.expected
                $result.head | Should -Be $fixture.branchCommit
                $result.mergeInProgress | Should -BeTrue
            } finally {
                Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "accepts and records a related 1C source repair outside the original conflict set" {
        $fixture = New-LifecycleMergeConflictFixture
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:MergeState = [pscustomobject]@{ safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test" }
                $script:RestartCount = 0
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Set-RunStage {}
                function Set-RunFailureContext {}
                function Assert-OneCConfigurationSourceIntegrity {}
                function Restart-Agent1cAfterDevBranchMerge { $script:RestartCount++; throw "RESTART_AFTER_MERGE" }
                try {
                    Invoke-NewDevBranchLifecycleMerge -State $script:MergeState -Operation "refresh-dev-branch" -TargetCommit $Fixture.targetCommit -ConflictStage "refresh.merge-conflicts"
                } catch {}

                Set-Content -LiteralPath (Join-Path $Fixture.root "conflict.txt") -Encoding UTF8 -Value "resolved"
                Set-Content -LiteralPath (Join-Path $Fixture.root "src\cf\Related.bsl") -Encoding UTF8 -Value "semantically adapted related method"
                Invoke-Git @("add", "--", "conflict.txt", "src/cf/Related.bsl")
                $resumeMessage = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $resumeMessage = $_.Exception.Message
                }
                $head = Get-CurrentCommit
                [pscustomobject]@{
                    resumeMessage = $resumeMessage
                    repairPaths = @($script:MergeState.pendingMergeRepairPaths)
                    allowedPaths = @($script:MergeState.pendingMergePaths)
                    changedPaths = @(Get-GitPathList -Arguments @("diff", "--name-only", "-z", $Fixture.branchCommit, $head))
                    parents = @(Get-GitCommitParents -Commit $head)
                    restartCount = $script:RestartCount
                    mergeInProgress = Test-GitMergeInProgress
                }
            } $fixture

            $result.resumeMessage | Should -Be "RESTART_AFTER_MERGE"
            $result.repairPaths | Should -Be @("src/cf/Related.bsl")
            $result.allowedPaths | Should -Contain "src/cf/Related.bsl"
            $result.changedPaths | Should -Contain "src/cf/Related.bsl"
            $result.parents | Should -Be @($fixture.branchCommit, $fixture.targetCommit)
            $result.restartCount | Should -Be 1
            $result.mergeInProgress | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "blocks a mismatched MERGE_HEAD without committing anything" {
        $fixture = New-LifecycleMergeConflictFixture
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:MergeState = [pscustomobject]@{ safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test" }
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Set-RunStage {}
                function Set-RunFailureContext {}
                function Assert-OneCConfigurationSourceIntegrity {}
                function Restart-Agent1cAfterDevBranchMerge { throw "unexpected restart" }
                try {
                    Invoke-NewDevBranchLifecycleMerge -State $script:MergeState -Operation "refresh-dev-branch" -TargetCommit $Fixture.targetCommit -ConflictStage "refresh.merge-conflicts"
                } catch {}
                $operationMessage = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "close-dev-branch" -ConflictStage "close.merge-conflicts" | Out-Null
                } catch {
                    $operationMessage = $_.Exception.Message
                }
                $mergeHeadPath = (Get-GitOutput @("rev-parse", "--git-path", "MERGE_HEAD")).Trim()
                if (-not [System.IO.Path]::IsPathRooted($mergeHeadPath)) {
                    $mergeHeadPath = Join-Path $Fixture.root $mergeHeadPath
                }
                Set-Content -LiteralPath $mergeHeadPath -Encoding ASCII -Value $Fixture.branchCommit
                $message = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $message = $_.Exception.Message
                }
                [pscustomobject]@{ operationMessage = $operationMessage; message = $message; head = Get-CurrentCommit }
            } $fixture

            $result.operationMessage | Should -Match "^LIFECYCLE_MERGE_OPERATION_MISMATCH"
            $result.message | Should -Match "^LIFECYCLE_MERGE_HEAD_MISMATCH"
            $result.head | Should -Be $fixture.branchCommit
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "recognizes a manually created exact merge commit as an interrupted workflow commit" {
        $fixture = New-LifecycleMergeConflictFixture
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:MergeState = [pscustomobject]@{ safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test" }
                $script:RestartCount = 0
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Set-RunStage {}
                function Set-RunFailureContext {}
                function Assert-OneCConfigurationSourceIntegrity {}
                function Restart-Agent1cAfterDevBranchMerge { $script:RestartCount++; throw "RESTART_AFTER_MERGE" }
                try {
                    Invoke-NewDevBranchLifecycleMerge -State $script:MergeState -Operation "refresh-dev-branch" -TargetCommit $Fixture.targetCommit -ConflictStage "refresh.merge-conflicts"
                } catch {}
                foreach ($name in @($script:MergeState.PSObject.Properties.Name | Where-Object { $_ -like "pendingMerge*" })) {
                    $script:MergeState.PSObject.Properties.Remove($name)
                }
                $legacyConflictMessage = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $legacyConflictMessage = $_.Exception.Message
                }
                Set-Content -LiteralPath (Join-Path $Fixture.root "conflict.txt") -Encoding UTF8 -Value "resolved"
                Invoke-Git @("add", "--", "conflict.txt")
                Invoke-Git @("commit", "--no-edit")
                $manualCommit = Get-CurrentCommit
                $message = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $message = $_.Exception.Message
                }
                [pscustomobject]@{
                    legacyConflictMessage = $legacyConflictMessage
                    message = $message
                    manualCommit = $manualCommit
                    pendingCommit = $script:MergeState.pendingMergeCommit
                    pendingStage = $script:MergeState.pendingMergeStage
                    parents = @(Get-GitCommitParents -Commit $manualCommit)
                    restartCount = $script:RestartCount
                }
            } $fixture

            $result.legacyConflictMessage | Should -Match "^LIFECYCLE_MERGE_CONFLICT"
            $result.message | Should -Be "RESTART_AFTER_MERGE"
            $result.pendingCommit | Should -Be $result.manualCommit
            $result.pendingStage | Should -Be "merged"
            $result.parents | Should -Be @($fixture.branchCommit, $fixture.targetCommit)
            $result.restartCount | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "migrates the existing helper-owned refresh cursor HEAD without replacing the recorded merge commit" {
        $fixture = New-LifecyclePostMergeCursorFixture
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:RestartCount = 0
                $script:MergeState = [pscustomobject]@{
                    safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test"
                    pendingMergeOperation = "refresh-dev-branch"; pendingMergeBranch = "itldev/test"
                    pendingMergeBranchCommit = $Fixture.branchCommit; pendingMergeTargetCommit = $Fixture.targetCommit
                    pendingMergeStage = "merged"; pendingMergePaths = @(); pendingMergeConflictPaths = @()
                    pendingMergeCommit = $Fixture.mergeCommit; pendingMergeResult = "merge-commit"
                }
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Restart-Agent1cAfterDevBranchMerge { $script:RestartCount++; throw "RESTART_AFTER_MERGE" }
                $resumeMessage = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $resumeMessage = $_.Exception.Message
                }
                $postMergeAccepted = $false
                try {
                    Assert-DevBranchLifecycleMergePostMerge -State $script:MergeState -Operation "refresh-dev-branch" | Out-Null
                    $postMergeAccepted = $true
                } catch {}
                [pscustomobject]@{
                    resumeMessage = $resumeMessage
                    mergeCommit = $script:MergeState.pendingMergeCommit
                    postMergeHead = $script:MergeState.pendingMergePostMergeHead
                    postMergeAccepted = $postMergeAccepted
                    restartCount = $script:RestartCount
                }
            } $fixture

            $result.resumeMessage | Should -Be "RESTART_AFTER_MERGE"
            $result.mergeCommit | Should -Be $fixture.mergeCommit
            $result.postMergeHead | Should -Be $fixture.cursorCommit
            $result.postMergeAccepted | Should -BeTrue
            $result.restartCount | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "accepts a helper-owned managed dependency lock commit as the refresh post-merge head" {
        $fixture = New-LifecyclePostMergeCursorFixture `
            -Subject "chore: persist branch refresh state" `
            -ChangedPath "dependency-lock"
        try {
            $accepted = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $transaction = [pscustomobject]@{
                    operation = "refresh-dev-branch"
                    mergeCommit = $Fixture.mergeCommit
                }
                Test-DevBranchLifecycleHelperOwnedPostMergeHead `
                    -Transaction $transaction `
                    -CandidateHead $Fixture.cursorCommit
            } $fixture

            $accepted | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "accepts an execution guard cutover only for its managed paths" {
        foreach ($changedPath in @('managed', 'foreign')) {
            $fixture = New-LifecyclePostMergeCursorFixture -Subject 'chore: activate execution guards v2' -ChangedPath $changedPath
            try {
                $accepted = & {
                    param($Fixture)
                    . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                    $transaction = [pscustomobject]@{
                        operation = 'refresh-dev-branch'
                        mergeCommit = $Fixture.mergeCommit
                    }
                    Test-DevBranchLifecycleHelperOwnedPostMergeHead -Transaction $transaction -CandidateHead $Fixture.cursorCommit
                } $fixture
                $accepted | Should -Be ($changedPath -eq 'managed')
            } finally {
                Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "rejects unproven post-merge descendants instead of widening cursor recovery" {
        foreach ($case in @(
            @{ name = "foreign path"; subject = "chore: persist branch configuration synchronization cursor"; changedPath = "foreign"; additionalHead = "none" },
            @{ name = "wrong subject"; subject = "manual cursor"; changedPath = "cursor"; additionalHead = "none" },
            @{ name = "additional commit"; subject = "chore: persist branch configuration synchronization cursor"; changedPath = "cursor"; additionalHead = "extra" },
            @{ name = "merge commit"; subject = "chore: persist branch configuration synchronization cursor"; changedPath = "cursor"; additionalHead = "merge" }
        )) {
            $fixture = New-LifecyclePostMergeCursorFixture -Subject $case.subject -ChangedPath $case.changedPath -AdditionalHead $case.additionalHead
            try {
                $result = & {
                    param($Fixture)
                    . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                    $DevBranchName = "test"
                    $script:RestartCount = 0
                    $script:MergeState = [pscustomobject]@{
                        safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test"
                        pendingMergeOperation = "refresh-dev-branch"; pendingMergeBranch = "itldev/test"
                        pendingMergeBranchCommit = $Fixture.branchCommit; pendingMergeTargetCommit = $Fixture.targetCommit
                        pendingMergeStage = "merged"; pendingMergePaths = @(); pendingMergeConflictPaths = @()
                        pendingMergeCommit = $Fixture.mergeCommit; pendingMergeResult = "merge-commit"
                    }
                    function Read-DevBranchState { return $script:MergeState }
                    function Update-DevBranchState {
                        param([object]$State, [hashtable]$Updates)
                        foreach ($key in $Updates.Keys) {
                            if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                                $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                            } else {
                                $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                            }
                        }
                    }
                    function Restart-Agent1cAfterDevBranchMerge { $script:RestartCount++ }
                    $message = ""
                    try {
                        Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                    } catch {
                        $message = $_.Exception.Message
                    }
                    [pscustomobject]@{
                        message = $message
                        mergeCommit = $script:MergeState.pendingMergeCommit
                        postMergeHead = [string](Get-StateValue -State $script:MergeState -Name "pendingMergePostMergeHead" -Default "")
                        restartCount = $script:RestartCount
                    }
                } $fixture

                $result.message | Should -Match "^LIFECYCLE_MERGE_POST_HEAD_MISMATCH" -Because $case.name
                $result.mergeCommit | Should -Be $fixture.mergeCommit -Because $case.name
                $result.postMergeHead | Should -BeNullOrEmpty -Because $case.name
                $result.restartCount | Should -Be 0 -Because $case.name
            } finally {
                Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'rejects an unrelated HEAD, branch, operation, merge, dirty tree or invalid checkpoint' {
        foreach ($case in @('unrelated-head', 'other-branch', 'other-operation', 'invalid-checkpoint', 'missing-checkpoint', 'new-merge', 'dirty-tree', 'tampered-merge')) {
            $fixture = New-LifecyclePostMergeCursorFixture -AdditionalHead $(if ($case -eq 'new-merge') { 'merge' } else { 'extra' })
            try {
                if ($case -eq 'unrelated-head') {
                    # This freshly created fixture owns the whole temporary repository.
                    & git -C $fixture.root reset --hard $fixture.branchCommit *> $null
                } elseif ($case -eq 'other-branch') {
                    & git -C $fixture.root checkout --quiet -b itldev/other
                } elseif ($case -eq 'dirty-tree') {
                    Set-Content -LiteralPath (Join-Path $fixture.root 'branch.txt') -Encoding UTF8 -Value 'uncommitted repair'
                }
                $result = & {
                    param($Fixture, $Case)
                    . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                    $DevBranchName = 'test'
                    $script:MergeState = [pscustomobject]@{
                        safeDevBranchName = 'test'; devBranchName = 'test'; devBranch = 'itldev/test'
                        pendingMergeOperation = 'refresh-dev-branch'; pendingMergeBranch = 'itldev/test'
                        pendingMergeBranchCommit = $Fixture.branchCommit; pendingMergeTargetCommit = $Fixture.targetCommit
                        pendingMergeStage = 'merged'; pendingMergePaths = @(); pendingMergeConflictPaths = @()
                        pendingMergeCommit = $Fixture.mergeCommit; pendingMergePostMergeHead = $Fixture.cursorCommit; pendingMergeResult = 'merge-commit'
                    }
                    if ($Case -eq 'invalid-checkpoint') { $script:MergeState.pendingMergePostMergeHead = $Fixture.branchCommit }
                    if ($Case -eq 'missing-checkpoint') { $script:MergeState.pendingMergePostMergeHead = '' }
                    if ($Case -eq 'tampered-merge') { $script:MergeState.pendingMergeCommit = $Fixture.branchCommit }
                    function Read-DevBranchState { return $script:MergeState }
                    function Update-DevBranchState { throw 'UNEXPECTED_STATE_CHANGE' }
                    function Restart-Agent1cAfterDevBranchMerge { throw 'UNEXPECTED_RESTART' }
                    $before = $script:MergeState | ConvertTo-Json -Depth 5 -Compress
                    $headBefore = Get-CurrentCommit
                    $operation = if ($Case -eq 'other-operation') { 'refresh-dev-branch-lite' } else { 'refresh-dev-branch' }
                    $message = ''
                    try {
                        Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation $operation -ConflictStage 'refresh.merge-conflicts' | Out-Null
                    } catch { $message = $_.Exception.Message }
                    [pscustomobject]@{
                        message = $message; requiredAction = $script:RunRequiredAction
                        stateUnchanged = ($before -ceq ($script:MergeState | ConvertTo-Json -Depth 5 -Compress))
                        headUnchanged = ($headBefore -ceq (Get-CurrentCommit))
                    }
                } $fixture $case
                $expectedCode = switch ($case) {
                    'unrelated-head' { 'LIFECYCLE_MERGE_POST_HEAD_MISMATCH' }
                    'other-branch' { 'LIFECYCLE_MERGE_BRANCH_MISMATCH' }
                    'other-operation' { 'LIFECYCLE_MERGE_OPERATION_MISMATCH' }
                    'invalid-checkpoint' { 'LIFECYCLE_MERGE_POST_HEAD_INVALID' }
                    'missing-checkpoint' { 'LIFECYCLE_MERGE_POST_HEAD_MISMATCH' }
                    'new-merge' { 'LIFECYCLE_MERGE_POST_HEAD_MISMATCH' }
                    'dirty-tree' { 'Git worktree is not clean' }
                    'tampered-merge' { 'LIFECYCLE_MERGE_RESULT_MISMATCH' }
                }
                $result.message | Should -Match "^$expectedCode" -Because $case
                if ($case -eq 'dirty-tree') {
                    $result.requiredAction | Should -Match '^prepare-lifecycle-git:'
                } else {
                    $result.requiredAction | Should -BeNullOrEmpty -Because $case
                }
                $result.stateUnchanged | Should -BeTrue -Because $case
                $result.headUnchanged | Should -BeTrue -Because $case
            } finally {
                Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'resumes the original refresh on a corrective descendant without changing failed verification (<Operation>, <Checkpoint>, <EvidenceKind>)' -Tag 'pending-refresh-evidence-kind' -TestCases @(
        @{ Checkpoint = 'merge'; Operation = 'refresh-dev-branch'; EvidenceKind = 'full' },
        @{ Checkpoint = 'cursor'; Operation = 'refresh-dev-branch'; EvidenceKind = 'full' },
        @{ Checkpoint = 'cursor'; Operation = 'refresh-dev-branch-lite'; EvidenceKind = 'full' },
        @{ Checkpoint = 'merge'; Operation = 'refresh-dev-branch'; EvidenceKind = 'complete/current-obligations' },
        @{ Checkpoint = 'cursor'; Operation = 'refresh-dev-branch'; EvidenceKind = 'complete/current-obligations' },
        @{ Checkpoint = 'cursor'; Operation = 'refresh-dev-branch-lite'; EvidenceKind = 'complete/current-obligations' },
        @{ Checkpoint = 'merge'; Operation = 'refresh-dev-branch'; EvidenceKind = 'complete/current-change' },
        @{ Checkpoint = 'cursor'; Operation = 'refresh-dev-branch'; EvidenceKind = 'complete/current-change' },
        @{ Checkpoint = 'cursor'; Operation = 'refresh-dev-branch-lite'; EvidenceKind = 'complete/current-change' }
    ) {
        param($Checkpoint, $Operation, $EvidenceKind)
        $fixture = if ($Checkpoint -eq 'merge') {
            New-LifecyclePostMergeCursorFixture -Subject 'fix: warn on unbound form commands in local validation' -ChangedPath foreign
        } else { New-LifecyclePostMergeCursorFixture -AdditionalHead extra }
        try {
            $result = & {
                param($Fixture, $Checkpoint, $Operation, $EvidenceKind)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                function Get-VerificationModel { 'cumulative' }
                $DevBranchName = "test"
                $script:MergeState = [pscustomobject]@{
                    safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test"
                    pendingMergeOperation = $Operation; pendingMergeBranch = "itldev/test"
                    pendingMergeBranchCommit = $Fixture.branchCommit; pendingMergeTargetCommit = $Fixture.targetCommit
                    pendingMergeStage = "merged"; pendingMergePaths = @(); pendingMergeConflictPaths = @()
                    pendingMergeCommit = $Fixture.mergeCommit; pendingMergePostMergeHead = $Fixture.cursorCommit; pendingMergeResult = "merge-commit"
                    lastVerificationStatus = "failed"; lastVerificationEvidenceKind = $EvidenceKind
                    resultTransferBaseline = @{ schemaVersion = 0; status = 'damaged-prior-proof' }
                    lastVerifiedCommit = $Fixture.head; lastVerifiedAt = "2026-09-02T12:10:00+03:00"
                    configLoadStatus = "passed"; lastConfigBaseUpdateAt = "2026-09-02T12:00:00+03:00"
                    enterpriseNormalizationStatus = "passed"
                    enterpriseNormalizationProofVersion = 1
                }
                if ($Checkpoint -eq 'merge') { $script:MergeState.pendingMergePostMergeHead = $Fixture.mergeCommit }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }

                function Read-DevBranchState { return $script:MergeState }
                function Restart-Agent1cAfterDevBranchMerge { throw 'RESTART_AFTER_MERGE' }
                $before = $script:MergeState | ConvertTo-Json -Depth 5 -Compress
                $resumeMessage = ''
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation $Operation -ConflictStage 'refresh.merge-conflicts' | Out-Null
                } catch { $resumeMessage = $_.Exception.Message }
                $postMerge = Assert-DevBranchLifecycleMergePostMerge -State $script:MergeState -Operation $Operation
                $RunStatusPath = Join-Path $Fixture.root '.agent-1c/corrective-resume.json'
                Write-RunStatus -Status failed -ExitCode 1 -ErrorMessage $resumeMessage
                $failureStatus = Get-Content -LiteralPath $RunStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $premature = Complete-PendingDevBranchRefreshAfterVerifiedRecovery -State $script:MergeState -RecoveryOperation 'check-dev-branch'
                $unchangedBeforeProof = ($before -ceq ($script:MergeState | ConvertTo-Json -Depth 5 -Compress))
                $failedVerification = $script:MergeState.lastVerificationStatus
                $script:MergeState.lastVerificationStatus = 'passed'
                $statusOnlyBefore = $script:MergeState | ConvertTo-Json -Depth 5 -Compress
                $statusOnlyCompleted = Complete-PendingDevBranchRefreshAfterVerifiedRecovery -State $script:MergeState -RecoveryOperation "check-dev-branch"
                $statusOnlyUnchanged = ($statusOnlyBefore -ceq ($script:MergeState | ConvertTo-Json -Depth 5 -Compress))
                # A current proof is supplied by the mocked successful check. Changing
                # a legacy status flag alone cannot complete the pending refresh.
                Update-DevBranchState -State $script:MergeState -Updates @{
                    lastVerifiedFingerprint = Get-VerificationFingerprint
                    lastVerifiedLoadedBaseIdentity = Get-VerificationLoadedBaseIdentity -State $script:MergeState
                }
                $freshBeforeCompletion = (Get-VerificationState -State $script:MergeState).isFreshPassed
                { Get-ConfigRepositoryTransferPlan -ExportPath src/cf -State $script:MergeState } | Should -Throw '*DEV_BRANCH_TRANSFER_BASELINE_INVALID*'
                $completed = Complete-PendingDevBranchRefreshAfterVerifiedRecovery -State $script:MergeState -RecoveryOperation "check-dev-branch"
                $continuedTransfer = Get-ConfigRepositoryTransferPlan -ExportPath src/cf -State $script:MergeState
                [pscustomobject]@{
                    failureStatus = $failureStatus
                    postMergeTarget = $postMerge.targetCommit
                    failedVerification = $failedVerification
                    premature = $premature
                    unchangedBeforeProof = $unchangedBeforeProof
                    statusOnlyCompleted = $statusOnlyCompleted
                    statusOnlyUnchanged = $statusOnlyUnchanged
                    freshBeforeCompletion = $freshBeforeCompletion
                    completed = $completed
                    pendingOperation = $script:MergeState.pendingMergeOperation
                    refreshCommit = Get-StateValue -State $script:MergeState -Name 'lastRefreshMasterCommit' -Default $null
                    refreshMode = Get-StateValue -State $script:MergeState -Name 'lastRefreshMode' -Default $null
                    recoveryOperation = Get-StateValue -State $script:MergeState -Name 'lastRefreshRecoveryOperation' -Default $null
                    recoveredHead = Get-StateValue -State $script:MergeState -Name 'lastRefreshRecoveredHead' -Default $null
                    transferBaseline = Get-StateValue -State $script:MergeState -Name 'resultTransferBaseline' -Default $null
                    continuedTransferBase = $continuedTransfer.baseCommit
                    currentHead = Get-CurrentCommit
                }
            } $fixture $Checkpoint $Operation $EvidenceKind

            $result.failureStatus.status | Should -Be 'failed'
            $result.failureStatus.exitCode | Should -Be 1
            $result.failureStatus.requiredAction | Should -BeNullOrEmpty
            $result.failureStatus.errorMessage | Should -Be 'RESTART_AFTER_MERGE'
            $result.postMergeTarget | Should -Be $fixture.targetCommit
            $result.failedVerification | Should -Be 'failed'
            $result.premature | Should -BeFalse
            $result.unchangedBeforeProof | Should -BeTrue
            $result.statusOnlyCompleted | Should -BeFalse
            $result.statusOnlyUnchanged | Should -BeTrue
            $result.freshBeforeCompletion | Should -BeTrue -Because 'the actual fingerprint/base assessor must accept the current proof before its kind reaches the pending-refresh consumer'
            $result.completed | Should -BeTrue
            $result.pendingOperation | Should -BeNullOrEmpty
            $result.refreshCommit | Should -Be $fixture.targetCommit
            $result.refreshMode | Should -Be $(if ($Operation -eq 'refresh-dev-branch') { 'full' } else { 'lite' })
            $result.recoveryOperation | Should -Be "check-dev-branch"
            $result.recoveredHead | Should -Be $fixture.head
            $result.transferBaseline.commit | Should -Be $fixture.targetCommit
            $result.transferBaseline.completedHead | Should -Be $fixture.head
            $result.transferBaseline.operation | Should -Be $Operation
            $result.transferBaseline.status | Should -Be 'complete'
            $result.continuedTransferBase | Should -Be $fixture.targetCommit -Because 'the original transfer continues after lifecycle-owned recovery replaces the damaged proof'
            $result.currentHead | Should -Be $fixture.head
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps a pending refresh when full verification is stale (<Operation>, <EvidenceKind>)' -Tag 'pending-refresh-evidence-kind' -TestCases @(
        @{ Operation = 'refresh-dev-branch'; EvidenceKind = 'full' },
        @{ Operation = 'refresh-dev-branch-lite'; EvidenceKind = 'full' },
        @{ Operation = 'refresh-dev-branch'; EvidenceKind = 'complete/current-obligations' },
        @{ Operation = 'refresh-dev-branch-lite'; EvidenceKind = 'complete/current-obligations' },
        @{ Operation = 'refresh-dev-branch'; EvidenceKind = 'complete/current-change' },
        @{ Operation = 'refresh-dev-branch-lite'; EvidenceKind = 'complete/current-change' }
    ) {
        param($Operation, $EvidenceKind)
        $fixture = New-LifecyclePostMergeCursorFixture -AdditionalHead extra
        try {
            $result = & {
                param($Fixture, $Operation, $EvidenceKind)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                function Get-VerificationModel { 'cumulative' }
                $DevBranchName = "test"
                $script:MergeState = [pscustomobject]@{
                    safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test"
                    pendingMergeOperation = $Operation; pendingMergeBranch = "itldev/test"
                    pendingMergeBranchCommit = $Fixture.branchCommit; pendingMergeTargetCommit = $Fixture.targetCommit
                    pendingMergeStage = "merged"; pendingMergePaths = @(); pendingMergeConflictPaths = @()
                    pendingMergeCommit = $Fixture.mergeCommit; pendingMergePostMergeHead = $Fixture.cursorCommit; pendingMergeResult = "merge-commit"
                    lastVerificationStatus = "passed"; lastVerificationEvidenceKind = $EvidenceKind
                    lastVerifiedCommit = $Fixture.cursorCommit; lastVerifiedAt = "2026-09-02T12:10:00+03:00"
                    configLoadStatus = "passed"; lastConfigBaseUpdateAt = "2026-09-02T12:00:00+03:00"
                    enterpriseNormalizationStatus = "passed"
                }
                function Update-DevBranchState { throw "state must not change" }

                $completed = Complete-PendingDevBranchRefreshAfterVerifiedRecovery -State $script:MergeState -RecoveryOperation "check-dev-branch"
                [pscustomobject]@{
                    completed = $completed
                    pendingOperation = $script:MergeState.pendingMergeOperation
                }
            } $fixture $Operation $EvidenceKind

            $result.completed | Should -BeFalse
            $result.pendingOperation | Should -Be $Operation
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps diagnostic partial and unknown evidence from completing a pending refresh despite actual freshness (<Operation>, <EvidenceKind>)' -Tag 'pending-refresh-evidence-kind' -TestCases @(
        @{ Operation = 'refresh-dev-branch'; EvidenceKind = 'diagnostic' },
        @{ Operation = 'refresh-dev-branch-lite'; EvidenceKind = 'diagnostic' },
        @{ Operation = 'refresh-dev-branch'; EvidenceKind = 'partial' },
        @{ Operation = 'refresh-dev-branch-lite'; EvidenceKind = 'partial' },
        @{ Operation = 'refresh-dev-branch'; EvidenceKind = 'partial/skipped' },
        @{ Operation = 'refresh-dev-branch-lite'; EvidenceKind = 'partial/skipped' },
        @{ Operation = 'refresh-dev-branch'; EvidenceKind = 'unknown' },
        @{ Operation = 'refresh-dev-branch-lite'; EvidenceKind = 'unknown' }
    ) {
        param($Operation, $EvidenceKind)
        $fixture = New-LifecyclePostMergeCursorFixture -AdditionalHead extra
        try {
            $result = & {
                param($Fixture, $Operation, $EvidenceKind)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                function Get-VerificationModel { 'cumulative' }
                $DevBranchName = 'test'
                $state = [pscustomobject]@{
                    safeDevBranchName = 'test'; devBranchName = 'test'; devBranch = 'itldev/test'
                    pendingMergeOperation = $Operation; pendingMergeBranch = 'itldev/test'
                    pendingMergeBranchCommit = $Fixture.branchCommit; pendingMergeTargetCommit = $Fixture.targetCommit
                    pendingMergeStage = 'merged'; pendingMergePaths = @(); pendingMergeConflictPaths = @()
                    pendingMergeCommit = $Fixture.mergeCommit; pendingMergePostMergeHead = $Fixture.cursorCommit; pendingMergeResult = 'merge-commit'
                    lastVerificationStatus = 'passed'; lastVerificationEvidenceKind = $EvidenceKind
                    lastVerifiedCommit = $Fixture.head; lastVerifiedAt = '2026-09-02T12:10:00+03:00'
                    configLoadStatus = 'passed'; lastConfigBaseUpdateAt = '2026-09-02T12:00:00+03:00'
                    enterpriseNormalizationStatus = 'passed'; enterpriseNormalizationProofVersion = 1
                }
                $state | Add-Member -NotePropertyMembers @{
                    lastVerifiedFingerprint = Get-VerificationFingerprint
                    lastVerifiedLoadedBaseIdentity = Get-VerificationLoadedBaseIdentity -State $state
                }
                function Update-DevBranchState { throw 'Rejected evidence must not change the original pending refresh' }
                $before = $state | ConvertTo-Json -Depth 5 -Compress
                $verification = Get-VerificationState -State $state
                $transaction = Get-PendingDevBranchMergeTransaction -State $state
                Assert-DevBranchLifecycleMergeIdentity -State $state -Transaction $transaction -Operation $Operation
                Assert-DevBranchLifecycleMergeRecordedResult -Transaction $transaction -Operation $Operation
                $completed = Complete-PendingDevBranchRefreshAfterVerifiedRecovery -State $state -RecoveryOperation 'check-dev-branch'
                [pscustomobject]@{
                    fresh = $verification.isFreshPassed; completed = $completed
                    stateUnchanged = ($before -ceq ($state | ConvertTo-Json -Depth 5 -Compress))
                    pendingOperation = $state.pendingMergeOperation; pendingTarget = $state.pendingMergeTargetCommit
                    pendingMergeCommit = $state.pendingMergeCommit; pendingPostMergeHead = $state.pendingMergePostMergeHead
                    currentHead = Get-CurrentCommit
                }
            } $fixture $Operation $EvidenceKind
            $result.fresh | Should -BeTrue -Because 'the evidence-kind consumer must reject this kind even when the real source/base freshness assessor passes'
            $result.completed | Should -BeFalse
            $result.stateUnchanged | Should -BeTrue
            $result.pendingOperation | Should -Be $Operation
            $result.pendingTarget | Should -Be $fixture.targetCommit
            $result.pendingMergeCommit | Should -Be $fixture.mergeCommit
            $result.pendingPostMergeHead | Should -Be $fixture.cursorCommit
            $result.currentHead | Should -Be $fixture.head
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "checkpoints the helper cursor before a later runner failure and resumes from that exact HEAD" {
        $fixture = New-LifecyclePostMergeCursorFixture -SkipCursor
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:RestartCount = 0
                $script:MergeState = [pscustomobject]@{
                    safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test"
                    pendingMergeOperation = "refresh-dev-branch"; pendingMergeBranch = "itldev/test"
                    pendingMergeBranchCommit = $Fixture.branchCommit; pendingMergeTargetCommit = $Fixture.targetCommit
                    pendingMergeStage = "merged"; pendingMergePaths = @(); pendingMergeConflictPaths = @()
                    pendingMergeCommit = $Fixture.mergeCommit; pendingMergePostMergeHead = $Fixture.mergeCommit; pendingMergeResult = "merge-commit"
                }
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Restart-Agent1cAfterDevBranchMerge { $script:RestartCount++; throw "RESTART_AFTER_MERGE" }

                Set-Content -LiteralPath (Join-Path $Fixture.root "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "post-merge-cursor"
                Set-Content -LiteralPath (Join-Path $Fixture.root "foreign.txt") -Encoding UTF8 -Value "later runner failure"
                $loadResult = [pscustomobject]@{ currentCommit = "stale" }
                $failure = ""
                try {
                    Complete-RefreshConfigDumpInfoPostcondition `
                        -LoadResult $loadResult `
                        -ExportPath "src/cf" `
                        -State $script:MergeState `
                        -Operation "refresh-dev-branch"
                } catch {
                    $failure = $_.Exception.Message
                }
                Remove-Item -LiteralPath (Join-Path $Fixture.root "foreign.txt") -Force
                $resumeMessage = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $resumeMessage = $_.Exception.Message
                }
                [pscustomobject]@{
                    failure = $failure
                    resumeMessage = $resumeMessage
                    mergeCommit = $script:MergeState.pendingMergeCommit
                    postMergeHead = $script:MergeState.pendingMergePostMergeHead
                    head = Get-CurrentCommit
                    restartCount = $script:RestartCount
                }
            } $fixture

            $result.failure | Should -Match "^Git worktree is not clean"
            $result.resumeMessage | Should -Be "RESTART_AFTER_MERGE"
            $result.mergeCommit | Should -Be $fixture.mergeCommit
            $result.postMergeHead | Should -Be $result.head
            $result.postMergeHead | Should -Not -Be $fixture.mergeCommit
            $result.restartCount | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "records an already-contained target as a proven no-op without creating an empty merge commit" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-merge-noop-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            Set-Content -LiteralPath (Join-Path $tempRoot "base.txt") -Encoding UTF8 -Value "base"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M master
            $targetCommit = (& git -C $tempRoot rev-parse HEAD).Trim()
            & git -C $tempRoot checkout --quiet -b itldev/test
            Set-Content -LiteralPath (Join-Path $tempRoot "branch.txt") -Encoding UTF8 -Value "branch"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "branch" *> $null
            $branchCommit = (& git -C $tempRoot rev-parse HEAD).Trim()

            $result = & {
                param($TempRoot, $TargetCommit)
                . $HelperPath -ProjectRoot $TempRoot -Action help *> $null
                $DevBranchName = "test"
                $script:MergeState = [pscustomobject]@{ safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test" }
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Restart-Agent1cAfterDevBranchMerge { throw "RESTART_AFTER_MERGE" }
                $message = ""
                try {
                    Invoke-NewDevBranchLifecycleMerge -State $script:MergeState -Operation "refresh-dev-branch-lite" -TargetCommit $TargetCommit -ConflictStage "refresh.merge-conflicts"
                } catch {
                    $message = $_.Exception.Message
                }
                [pscustomobject]@{
                    message = $message
                    head = Get-CurrentCommit
                    stage = $script:MergeState.pendingMergeStage
                    result = $script:MergeState.pendingMergeResult
                    mergeCommit = $script:MergeState.pendingMergeCommit
                    parents = @(Get-GitCommitParents -Commit (Get-CurrentCommit))
                }
            } $tempRoot $targetCommit

            $result.message | Should -Be "RESTART_AFTER_MERGE"
            $result.head | Should -Be $branchCommit
            $result.stage | Should -Be "merged"
            $result.result | Should -Be "already-up-to-date"
            $result.mergeCommit | Should -Be $branchCommit
            $result.parents | Should -Be @($targetCommit)
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps branch ConfigDumpInfo cursors with Unicode paths when master is merged" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-dump-info-merge-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf") | Out-Null
            $unicodeExtensionRoot = Join-Path $tempRoot "src\cfe\Тестовое расширение"
            New-Item -ItemType Directory -Force -Path $unicodeExtensionRoot | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot config core.quotePath true
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "base-cursor"
            Set-Content -LiteralPath (Join-Path $unicodeExtensionRoot "ConfigDumpInfo.xml") -Encoding UTF8 -Value "base-extension-cursor"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Encoding UTF8 -Value "<Configuration />"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M master

            & git -C $tempRoot checkout --quiet -b itldev/test
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "branch-cursor"
            Set-Content -LiteralPath (Join-Path $unicodeExtensionRoot "ConfigDumpInfo.xml") -Encoding UTF8 -Value "branch-extension-cursor"
            Set-Content -LiteralPath (Join-Path $tempRoot "branch.txt") -Encoding UTF8 -Value "branch"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "branch cursor" *> $null

            & git -C $tempRoot checkout --quiet master
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "master-cursor"
            Set-Content -LiteralPath (Join-Path $unicodeExtensionRoot "ConfigDumpInfo.xml") -Encoding UTF8 -Value "master-extension-cursor"
            Set-Content -LiteralPath (Join-Path $tempRoot "master.txt") -Encoding UTF8 -Value "master"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "master cursor" *> $null
            & git -C $tempRoot checkout --quiet itldev/test

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Assert-OneCConfigurationSourceIntegrity {}
                Merge-MasterPreservingBranchConfigDumpInfo -MasterBranch master
            }

            (Get-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Raw).Trim() | Should -Be "branch-cursor"
            (Get-Content -LiteralPath (Join-Path $unicodeExtensionRoot "ConfigDumpInfo.xml") -Raw).Trim() | Should -Be "branch-extension-cursor"
            Test-Path -LiteralPath (Join-Path $tempRoot "master.txt") -PathType Leaf | Should -BeTrue
            @((& git -C $tempRoot rev-list --parents -n 1 HEAD) -split "\s+").Count | Should -Be 3
            ((& git -C $tempRoot status --porcelain) -join "") | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "commits only a changed refresh cursor and leaves the worktree clean" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-refresh-cursor-commit-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf") | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "before"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Encoding UTF8 -Value "<Configuration />"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M itldev/test
            $beforeCommit = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "after"

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $loadResult = [pscustomobject]@{ currentCommit = $beforeCommit }
                Complete-RefreshConfigDumpInfoPostcondition -LoadResult $loadResult -ExportPath "src/cf"
                [pscustomobject]@{
                    currentCommit = $loadResult.currentCommit
                    head = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()
                    subject = ((& git -C $tempRoot log -1 --format=%s) -join "").Trim()
                    paths = @(& git -C $tempRoot show --format= --name-only HEAD | Where-Object { $_ })
                    status = @(& git -C $tempRoot status --porcelain)
                }
            }

            $result.head | Should -Not -Be $beforeCommit
            $result.currentCommit | Should -Be $result.head
            $result.subject | Should -Be "chore: persist branch configuration synchronization cursor"
            @($result.paths).Count | Should -Be 1
            $result.paths[0] | Should -Be "src/cf/ConfigDumpInfo.xml"
            @($result.status).Count | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "does not create an empty refresh cursor commit" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-refresh-cursor-clean-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf") | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            $beforeCommit = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $loadResult = [pscustomobject]@{ currentCommit = "stale" }
                Complete-RefreshConfigDumpInfoPostcondition -LoadResult $loadResult -ExportPath "src/cf"
                [pscustomobject]@{
                    currentCommit = $loadResult.currentCommit
                    head = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()
                    status = @(& git -C $tempRoot status --porcelain)
                }
            }

            $result.head | Should -Be $beforeCommit
            $result.currentCommit | Should -Be $beforeCommit
            @($result.status).Count | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps stale pending refresh recovery on main when the branch helper predates <Capability>" -TestCases @(
        @{ Capability='managed lock persistence'; HelperBody='# stale branch helper' },
        @{ Capability='independent documentation'; HelperBody='function Test-RefreshManagedDependencyLockChange { return $false }' }
    ) {
        param($Capability, $HelperBody)
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-post-merge-stale-helper-" + [guid]::NewGuid().ToString("N"))
        $branchRoot = Join-Path $tempRoot "branch"
        try {
            $branchHelperPath = Join-Path $branchRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $branchHelperPath) | Out-Null
            Set-Content -LiteralPath $branchHelperPath -Encoding UTF8 -Value $HelperBody
            $result = & {
                . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                $script:Agent1cScriptPath = Join-Path $tempRoot "main\.agents\skills\1c-workflow\scripts\agent-1c.ps1"
                $script:CapturedScriptPath = ""
                $script:CapturedArguments = @()
                function Invoke-Agent1cFreshProcess {
                    param([string]$ScriptPath, [string[]]$AdditionalArguments)
                    $script:CapturedScriptPath = $ScriptPath
                    $script:CapturedArguments = @($AdditionalArguments)
                    throw "handoff-stop"
                }
                try {
                    Restart-Agent1cAfterDevBranchMerge -Operation "refresh-dev-branch"
                } catch {
                    if ($_.Exception.Message -ne "handoff-stop") { throw }
                }
                [pscustomobject]@{
                    scriptPath = $script:CapturedScriptPath
                    arguments = @($script:CapturedArguments)
                }
            }
            $result.scriptPath | Should -Be (Join-Path $tempRoot "main\.agents\skills\1c-workflow\scripts\agent-1c.ps1")
            $result.arguments | Should -Be @("-LifecyclePhase", "post-merge")
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "semantically resolves the workflow dependency lock conflict and preserves a branch-only project entry" -Tag WorkflowDependencyRefresh {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-refresh-lock-merge-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            $lockPath = Join-Path $tempRoot ".agent-1c\dependency-lock.json"
            $baseLock = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $baseLock.dependencies.workflowPackage.commit = "base-workflow"
            $baseLock.dependencies | Add-Member -NotePropertyName projectSpecific -NotePropertyValue ([pscustomobject]@{ value = "base" })
            Set-Content -LiteralPath $lockPath -Encoding UTF8 -Value (($baseLock | ConvertTo-Json -Depth 100) + [Environment]::NewLine)
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            $baseCommit = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()

            & git -C $tempRoot switch -c target *> $null
            $targetLock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $targetLock.dependencies.workflowPackage.commit = "target-workflow"
            Set-Content -LiteralPath $lockPath -Encoding UTF8 -Value (($targetLock | ConvertTo-Json -Depth 100) + [Environment]::NewLine)
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "target" *> $null
            $targetCommit = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()

            & git -C $tempRoot switch -c itldev/test $baseCommit *> $null
            $branchLock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $branchLock.dependencies.workflowPackage.commit = "branch-stale-workflow"
            $branchLock.dependencies.projectSpecific.value = "branch-value"
            Set-Content -LiteralPath $lockPath -Encoding UTF8 -Value (($branchLock | ConvertTo-Json -Depth 100) + [Environment]::NewLine)
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "branch" *> $null
            $branchCommit = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()
            & git -C $tempRoot merge --no-ff --no-commit $targetCommit *> $null
            $LASTEXITCODE | Should -Not -Be 0

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $resolved = Resolve-RefreshDependencyLockMergeConflict
                $proven = Test-RefreshDependencyLockSemanticMergeResult -BranchCommit $branchCommit -TargetCommit $targetCommit
                . (Join-Path (Split-Path -Parent $HelperPath) "lib\agent-1c.merge-preservation.ps1")
                Assert-DevBranchMergePreservation `
                    -BranchCommit $branchCommit `
                    -TargetCommit $targetCommit `
                    -ExcludedPaths @(".agent-1c/dependency-lock.json")
                $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
                [pscustomobject]@{
                    resolved = $resolved
                    proven = $proven
                    unmerged = @(Get-DevBranchMergeUnmergedPaths)
                    workflowCommit = $lock.dependencies.workflowPackage.commit
                    projectValue = $lock.dependencies.projectSpecific.value
                }
            }

            $result.resolved | Should -BeTrue
            $result.proven | Should -BeTrue
            @($result.unmerged).Count | Should -Be 0
            $result.workflowCommit | Should -Be "target-workflow"
            $result.projectValue | Should -Be "branch-value"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "commits a workflow-managed dependency lock synchronization during refresh" -Tag WorkflowDependencyRefresh {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-refresh-lock-sync-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf"), (Join-Path $tempRoot ".agent-1c") | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor"
            $lockPath = Join-Path $tempRoot ".agent-1c\dependency-lock.json"
            $lock = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            # Published f5466e6 legacy client entry precedes the owned component.
            # Commit that real old pin, then exercise the actual synchronization owner.
            $lock.dependencies.vanessaMcp.clientMcp = [pscustomobject]@{
                version = "v0.6.5"
                assetName = "client_mcp.cfe"
                url = "https://github.com/1c-neurofish/onec-client-mcp-devkit/releases/download/v0.6.5/client_mcp.cfe"
                sha256 = "d1093475a15e50a33ad48a64b61d09d1108b5a39328c73e6be17a5c914825e7f"
                source = "template baseline"
                updatedAt = "2026-05-26T19:34:34Z"
            }
            Set-Content -LiteralPath $lockPath -Encoding UTF8 -Value (($lock | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            $beforeCommit = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()

            $result = & {
                $refreshDependencyModeBefore = [Environment]::GetEnvironmentVariable('DEPENDENCY_MODE', 'Process')
                try {
                    [Environment]::SetEnvironmentVariable('DEPENDENCY_MODE', 'fresh', 'Process')
                    . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                    $beforeHash = (Get-FileHash -LiteralPath $lockPath).Hash
                    { Sync-WorkflowManagedDependencyLockEntries } | Should -Throw '*DEPENDENCY_SELECTION_REQUIRED*'
                    (Get-FileHash -LiteralPath $lockPath).Hash | Should -BeExactly $beforeHash
                    $DependencySelectionFile = Join-Path $TestDrive 'Решение refresh с пробелом.json'
                    Write-Utf8Text -Path $DependencySelectionFile -Value (@{schemaVersion=1;worktrees=@(@{worktreePath=$tempRoot;decisions=@{vanessaMcp='workflow'}})}|ConvertTo-Json -Depth 10)
                    $sync = Sync-WorkflowManagedDependencyLockEntries
                    $loadResult = [pscustomobject]@{ currentCommit = $beforeCommit }
                    Complete-RefreshConfigDumpInfoPostcondition -LoadResult $loadResult -ExportPath "src/cf"
                    $actualLock = Read-Utf8Text -Path $lockPath | ConvertFrom-Json
                    $canonicalLock = New-DefaultDependencyLockManifest
                    [pscustomobject]@{
                        synchronized = $sync.changed
                        synchronizedEntries = @($sync.entries)
                        clientPin = ConvertTo-Json -InputObject (ConvertTo-DependencyLockComparableValue $actualLock.dependencies.vanessaMcp.clientMcp) -Depth 20 -Compress
                        canonicalClientPin = ConvertTo-Json -InputObject (ConvertTo-DependencyLockComparableValue $canonicalLock.dependencies.vanessaMcp.clientMcp) -Depth 20 -Compress
                        head = Get-CurrentCommit
                        loadCommit = $loadResult.currentCommit
                        subject = ((& git -C $tempRoot log -1 --format=%s) -join "").Trim()
                        paths = @(Get-GitPathList -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', '-z', 'HEAD'))
                        status = @(& git -C $tempRoot status --porcelain)
                    }
                } finally {
                    [Environment]::SetEnvironmentVariable('DEPENDENCY_MODE', $refreshDependencyModeBefore, 'Process')
                }
            }

            $result.synchronized | Should -BeTrue
            $result.synchronizedEntries | Should -Contain 'vanessaMcp'
            $result.clientPin | Should -BeExactly $result.canonicalClientPin
            $result.head | Should -Not -Be $beforeCommit
            $result.loadCommit | Should -Be $result.head
            $result.subject | Should -Be "chore: persist branch refresh state"
            @($result.paths).Count | Should -Be 1
            $result.paths[0] | Should -Be ".agent-1c/dependency-lock.json"
            @($result.status).Count | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects a noncanonical current workflow-managed dependency pin during refresh" {
        # Original observed failure: current owned pin was relabelled as a legacy
        # compatibility source without calling the synchronization owner.
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-refresh-lock-sync-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf"), (Join-Path $tempRoot ".agent-1c") | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor"
            $lockPath = Join-Path $tempRoot ".agent-1c\dependency-lock.json"
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Destination $lockPath
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            $beforeCommit = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()
            $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $lock.dependencies.vanessaMcp.clientMcp.source = "compatibility-manifest"
            Set-Content -LiteralPath $lockPath -Encoding UTF8 -Value (($lock | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
            $corruptHash = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash

            $message = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                try {
                    Complete-RefreshConfigDumpInfoPostcondition -LoadResult ([pscustomobject]@{ currentCommit = $beforeCommit }) -ExportPath "src/cf"
                } catch {
                    $_.Exception.Message
                }
            }

            $message | Should -Match "^REFRESH_TRACKED_STATE_UNEXPECTED:"
            $message | Should -Match "dependency-lock.json"
            ((& git -C $tempRoot rev-parse HEAD) -join "").Trim() | Should -Be $beforeCommit
            (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash | Should -BeExactly $corruptHash
            $trackedDirty = @(& {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                @(Get-GitPathList -Arguments @('diff', '--name-only', '-z', '--'))
            })
            @($trackedDirty).Count | Should -Be 1
            $trackedDirty[0] | Should -Be ".agent-1c/dependency-lock.json"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects a dependency lock change outside workflow-managed entries during refresh" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-refresh-lock-unmanaged-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf"), (Join-Path $tempRoot ".agent-1c") | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor"
            $lockPath = Join-Path $tempRoot ".agent-1c\dependency-lock.json"
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Destination $lockPath
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            $beforeCommit = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()
            $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $lock.dependencies.workflowPackage.commit = "unexpected"
            Set-Content -LiteralPath $lockPath -Encoding UTF8 -Value (($lock | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

            $message = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                try {
                    Complete-RefreshConfigDumpInfoPostcondition -LoadResult ([pscustomobject]@{ currentCommit = $beforeCommit }) -ExportPath "src/cf"
                } catch {
                    $_.Exception.Message
                }
            }

            $message | Should -Match "^REFRESH_TRACKED_STATE_UNEXPECTED:"
            $message | Should -Match "dependency-lock.json"
            ((& git -C $tempRoot rev-parse HEAD) -join "").Trim() | Should -Be $beforeCommit
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "fails before committing when refresh changes another tracked file" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-refresh-cursor-unexpected-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf") | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "before"
            Set-Content -LiteralPath (Join-Path $tempRoot "tracked.txt") -Encoding UTF8 -Value "before"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            $beforeCommit = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "after"
            Set-Content -LiteralPath (Join-Path $tempRoot "tracked.txt") -Encoding UTF8 -Value "after"

            $message = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                try {
                    Complete-RefreshConfigDumpInfoPostcondition -LoadResult ([pscustomobject]@{ currentCommit = $beforeCommit }) -ExportPath "src/cf"
                } catch {
                    $_.Exception.Message
                }
            }

            $message | Should -Match "^REFRESH_TRACKED_STATE_UNEXPECTED:"
            $message | Should -Match "tracked.txt"
            ((& git -C $tempRoot rev-parse HEAD) -join "").Trim() | Should -Be $beforeCommit
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps refresh failures correctly routed and persists only managed refresh state" {
        $refresh = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:RunErrorCategory = ""
            $script:RunRequiredAction = ""
            Set-RunFailureContextFromMessage -Message "REFRESH_TRACKED_STATE_UNEXPECTED: .kilo/kilo.json" -RequestedAction "refresh-dev-branch"
            [pscustomobject]@{ category = $script:RunErrorCategory; requiredAction = $script:RunRequiredAction }
        }
        $refresh.category | Should -Be "runner"
        $refresh.requiredAction | Should -BeNullOrEmpty

        $lifecycleText = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:RunErrorCategory = ""
            $script:RunRequiredAction = ""
            Set-RunFailureContextFromMessage -Message "Expected helper state was not found" -RequestedAction "refresh-dev-branch"
            [pscustomobject]@{ category = $script:RunErrorCategory; requiredAction = $script:RunRequiredAction }
        }
        $lifecycleText.category | Should -Be "runner"
        $lifecycleText.requiredAction | Should -BeNullOrEmpty

        $verification = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:RunErrorCategory = ""
            $script:RunRequiredAction = ""
            Set-RunFailureContextFromMessage -Message "Expected X, got Y" -RequestedAction "check-dev-branch"
            [pscustomobject]@{ category = $script:RunErrorCategory; requiredAction = $script:RunRequiredAction }
        }
        $verification.category | Should -Be "product-assertion"
        $verification.requiredAction | Should -Be "/itl-verify-fix"
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-refresh-kilo-managed-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf"), (Join-Path $tempRoot ".kilo") | Out-Null
            & git -C $tempRoot init *> $null; & git -C $tempRoot config user.email "test@example.com"; & git -C $tempRoot config user.name "Test User"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor"
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Encoding UTF8 -Value '{"mcp":{"itl-roctup-data":{"command":["branch-helper"]},"custom":{"url":"http://custom"}},"instructions":["USER-RULES.md"],"permission":{"bash":"ask"}}'
            & git -C $tempRoot add .; & git -C $tempRoot commit -m "base" *> $null

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $snapshot = New-RefreshTrackedKiloConfigSnapshot
                Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Encoding UTF8 -Value '{"mcp":{"custom":{"url":"http://custom"},"itl-roctup-data":{"command":["main-helper"]}},"instructions":["USER-RULES.md"],"permission":{"bash":"ask"}}'
                $loadResult = [pscustomobject]@{ currentCommit = "stale" }
                Complete-RefreshConfigDumpInfoPostcondition -LoadResult $loadResult -ExportPath "src/cf" -TrackedKiloSnapshot $snapshot
                [pscustomobject]@{
                    currentCommit = $loadResult.currentCommit
                    subject = ((& git -C $tempRoot log -1 --format=%s) -join "").Trim()
                    status = @(& git -C $tempRoot status --porcelain)
                    config = Get-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Raw -Encoding UTF8 | ConvertFrom-Json
                }
            }

            $result.subject | Should -Be "chore: persist branch refresh state"; $result.currentCommit | Should -Be (((& git -C $tempRoot rev-parse HEAD) -join "").Trim()); @($result.status).Count | Should -Be 0
            $result.config.mcp.'itl-roctup-data'.command[0] | Should -Be "main-helper"
            $result.config.mcp.custom.url | Should -Be "http://custom"; @($result.config.instructions) | Should -Be @("USER-RULES.md"); $result.config.permission.bash | Should -Be "ask"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-refresh-kilo-unmanaged-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf"), (Join-Path $tempRoot ".kilo") | Out-Null
            & git -C $tempRoot init *> $null; & git -C $tempRoot config user.email "test@example.com"; & git -C $tempRoot config user.name "Test User"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor"
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Encoding UTF8 -Value '{"mcp":{"custom":{"url":"http://before"}},"permission":{"bash":"ask"}}'
            & git -C $tempRoot add .; & git -C $tempRoot commit -m "base" *> $null

            $message = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $snapshot = New-RefreshTrackedKiloConfigSnapshot
                Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Encoding UTF8 -Value '{"mcp":{"custom":{"url":"http://after"}},"permission":{"bash":"ask"}}'
                try {
                    Complete-RefreshConfigDumpInfoPostcondition -LoadResult ([pscustomobject]@{ currentCommit = "stale" }) -ExportPath "src/cf" -TrackedKiloSnapshot $snapshot
                } catch {
                    $_.Exception.Message
                }
            }

            $message | Should -Match "^REFRESH_TRACKED_STATE_UNEXPECTED:"; $message | Should -Match ([regex]::Escape(".kilo/kilo.json")); $message | Should -Match "non-ITL content"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        $match = [regex]::Match($HelperText, "(?s)function\s+Invoke-RefreshDevBranchCore\s*\{(?<body>.*?)(?=`r?`nfunction\s+Refresh-DevBranch\s*\{)")
        $match.Success | Should -BeTrue
        $body = $match.Groups["body"].Value
        $postconditionIndex = $body.LastIndexOf("Complete-RefreshConfigDumpInfoPostcondition")
        $postconditionIndex | Should -BeGreaterThan $body.LastIndexOf("Invoke-DevBranchDefaultMcpSetup"); $postconditionIndex | Should -BeGreaterThan $body.LastIndexOf("Invoke-DevBranchMcpRestartAfterInfobaseLoad")
        $postconditionIndex | Should -BeGreaterThan $body.LastIndexOf("Sync-KiloItlCommandSurface"); $postconditionIndex | Should -BeGreaterThan $body.LastIndexOf("Invoke-AiRules1cManagedMcpConfigReconcile")
    }

    It "does not run the refresh cursor postcondition after a failed configuration load" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $LifecyclePhase = "post-merge"
            $script:PostconditionCalls = 0
            $state = [pscustomobject]@{
                pendingMergeOperation = 'refresh-dev-branch'
                pendingRefreshMasterCommit = ("a" * 40)
                devBranchInfoBasePath = "D:\fixture\base"
                infoBaseKind = "file"
            }
            function Read-DevBranchState { return $state }
            function Assert-DevelopmentBranchWorktreeContext {}
            function Assert-DevBranchExtensionInitialized {}
            function Assert-CleanGit {}
            function Assert-DevBranchLifecycleMergePostMerge { [pscustomobject]@{ targetCommit = ("a" * 40); branchCommit = ("b" * 40) } }
            function Assert-RefreshGitInputs {}
            function Update-DevBranchState {
                param([object]$State, [hashtable]$Updates)
                foreach ($key in $Updates.Keys) { $State | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key] -Force }
            }
            function Update-VerificationSuiteInventory {
                param([string]$Reason, [switch]$EvaluateApplicability)
                [pscustomobject]@{ yaxunit = [pscustomobject]@{ legacyBaseline = $true } }
            }
            function Sync-DevBranchContextToDotEnv {}
            function Sync-WorkflowManagedDependencyLockEntries {}
            function Install-VanessaAutomation {}
            function Get-RoctupMcpEnabled { return $false }
            function Install-VanessaMcpArtifacts {}
            function Install-ItlOnDemandMcp {}
            function Invoke-DevBranchDefaultMcpSetup { param([object]$State) return $State }
            function Load-ConfigFromFiles { throw "simulated load failure after ConfigDumpInfo rollback" }
            function Complete-RefreshConfigDumpInfoPostcondition { $script:PostconditionCalls++ }
            $message = ""
            try { Invoke-RefreshDevBranchCore -OperationName "refresh-dev-branch" } catch { $message = $_.Exception.Message }
            [pscustomobject]@{ message = $message; postconditionCalls = $script:PostconditionCalls; pendingOperation = $state.pendingMergeOperation }
        }
        $result.message | Should -Be "simulated load failure after ConfigDumpInfo rollback"
        $result.postconditionCalls | Should -Be 0
        $result.pendingOperation | Should -Be 'refresh-dev-branch'
    }

    It 'clears the original refresh only after its successful post-merge load and preserves failed verification' {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $LifecyclePhase = 'post-merge'
            $DevBranchName = 'test'
            $state = [pscustomobject]@{
                devBranch = 'itldev/test'; devBranchKind = 'configuration'
                devBranchInfoBasePath = 'D:\fixture\base'; infoBaseKind = 'file'
                yaxunitApplicabilityBaseline = @{ schemaVersion = 1 }
                pendingMergeOperation = 'refresh-dev-branch'; pendingMergeTargetCommit = ('a' * 40)
                pendingRefreshOperation = 'refresh-dev-branch'; pendingRefreshMasterCommit = ('a' * 40)
                lastVerificationStatus = 'failed'
            }
            function Read-DevBranchState { $state }
            function Update-DevBranchState {
                param($State, [hashtable]$Updates)
                foreach ($key in $Updates.Keys) { $State | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key] -Force }
            }
            function Assert-DevelopmentBranchWorktreeContext {}
            function Assert-DevBranchExtensionInitialized {}
            function Assert-DevBranchLifecycleMergePostMerge { [pscustomobject]@{ targetCommit = ('a' * 40); branchCommit = ('b' * 40); repairPaths = @() } }
            function Assert-RefreshGitInputs {}
            function Sync-DevBranchContextToDotEnv {}
            function Sync-AiRules1cManagedIgnoredFilesFromMain {}
            function Sync-WorkflowManagedDependencyLockEntries {}
            function Update-VerificationSuiteInventory { [pscustomobject]@{ yaxunit = @{ legacyBaseline = $false }; classificationComplete = $true; classificationIssues = @() } }
            function Install-VanessaAutomation {}
            function Get-RoctupMcpEnabled { $false }
            function Install-VanessaMcpArtifacts {}
            function Install-ItlOnDemandMcp {}
            function Set-RunStage {}
            function New-RefreshTrackedKiloConfigSnapshot { $null }
            function Restore-RefreshTrackedKiloConfigSnapshot {}
            function Invoke-DevBranchDefaultMcpSetup { param($State) $State }
            function Load-ConfigFromFiles { [pscustomobject]@{ currentCommit = ('c' * 40) } }
            function Invoke-DevBranchEnterpriseAutoUpdateIfLoaded {}
            function Invoke-DevBranchMcpRestartAfterInfobaseLoad { param($State) $State }
            function Sync-KiloItlCommandSurface {}
            function Invoke-AiRules1cManagedMcpConfigReconcile {}
            function Complete-RefreshConfigDumpInfoPostcondition {}
            function Set-ItlOnDemandMcpSemanticReloadRequiredAction {}
            function Set-VerificationClassificationRequiredAction {}
            function New-LoadStateUpdates { @{} }
            function Get-VerificationClassificationInventoryPath { 'fixture-inventory.json' }
            function Get-VerificationState { [pscustomobject]@{ status = 'failed'; currentFingerprint = 'fixture' } }
            function Write-BaseUpdateResult {}
            function Write-DevBranchRunUserReport {}
            Invoke-RefreshDevBranchCore -OperationName 'refresh-dev-branch'
            [pscustomobject]@{
                pendingOperation = $state.pendingMergeOperation
                pendingRefresh = $state.pendingRefreshOperation
                refreshTarget = $state.lastRefreshMasterCommit
                verification = $state.lastVerificationStatus
            }
        }
        $result.pendingOperation | Should -BeNullOrEmpty
        $result.pendingRefresh | Should -BeNullOrEmpty
        $result.refreshTarget | Should -Be ('a' * 40)
        $result.verification | Should -Be 'failed'
    }
}

Describe 'Refresh dependency selection ownership' -Tag WorkflowDependencyRefresh {
    BeforeAll { . (Join-Path $PSScriptRoot 'DevBranchLifecycleSupport.ps1') }

    It 'uses the branch exception against the merged workflow for <Case>' -ForEach @(
        @{Case='retained hotfix';Expected='1.5.0';Count=1},
        @{Case='incorporated hotfix';Expected='1.5.0';Count=0},
        @{Case='master has its own exception';Expected='1.5.0';Count=1},
        @{Case='legacy schema migration';Expected='1.2.0';Count=0}
    ) {
        $root=Join-Path $TestDrive ('Refresh версии с пробелом '+$Case)
        $result=& {
            . $HelperPath -ProjectRoot $root -Action help *> $null
            function Copy-RefreshFixtureManifest { param($Value); ConvertTo-Agent1cHashtable ($Value|ConvertTo-Json -Depth 100|ConvertFrom-Json) }
            $old=Copy-RefreshFixtureManifest (New-DefaultDependencyLockManifest)
            $old.dependencies.yaxunit.version='1.0.0'
            $old.dependencies.yaxunit.sha256='a'*64
            $base=Copy-RefreshFixtureManifest (New-WorkflowDependencyPlan -Template $old -Manifest $old).manifest
            $branch=Copy-RefreshFixtureManifest $base
            $branch.hotfixes=ConvertTo-Agent1cHashtable $branch.hotfixes
            $hot=ConvertTo-Agent1cHashtable $old.dependencies.yaxunit
            $hot.version='1.5.0';$hot.sha256='b'*64
            if($Case -eq 'legacy schema migration') {
                $base.schemaVersion=1;$base.mode='locked'
                $branch.schemaVersion=1;$branch.mode='fresh'
            } else {
                $branch.dependencies.yaxunit=$hot
                $branch.hotfixes['branch-yax']=@{reason='branch incident';dependencies=@{yaxunit=$hot}}
            }
            $script:refreshFixtureTemplate=Copy-RefreshFixtureManifest $old
            $script:refreshFixtureTemplate.dependencies.yaxunit.version='1.2.0'
            $script:refreshFixtureTemplate.dependencies.yaxunit.sha256='c'*64
            if($Case -eq 'incorporated hotfix') {$script:refreshFixtureTemplate.dependencies.yaxunit=ConvertTo-Agent1cHashtable $hot}
            function New-DefaultDependencyLockManifest { $script:refreshFixtureTemplate }
            $target=Copy-RefreshFixtureManifest $base
            $target.hotfixes=ConvertTo-Agent1cHashtable $target.hotfixes
            $target.schemaVersion=2;$target.mode='workflow'
            $target.dependencies.yaxunit=ConvertTo-Agent1cHashtable $script:refreshFixtureTemplate.dependencies.yaxunit
            $target.dependencies.workflowPackage.commit='target-workflow'
            if($Case -eq 'master has its own exception') {
                $masterPin=ConvertTo-Agent1cHashtable $hot
                $masterPin.version='2.0.0';$masterPin.sha256='d'*64
                $target.dependencies.yaxunit=$masterPin
                $target.hotfixes['master-yax']=@{reason='master-only incident';dependencies=@{yaxunit=$masterPin}}
            }
            $before=$branch|ConvertTo-Json -Depth 100
            $merged=Merge-RefreshDependencyLockManifests -Base $base -Branch $branch -Target $target -InstalledTemplate $old
            [pscustomobject]@{merged=$merged;before=$before;after=($branch|ConvertTo-Json -Depth 100)}
        }
        $result.merged.dependencies.yaxunit.version | Should -Be $Expected
        $result.merged.dependencies.workflowPackage.commit | Should -Be 'target-workflow'
        $result.merged.hotfixes.Count | Should -Be $Count
        $result.merged.hotfixes.Contains('master-yax') | Should -BeFalse
        $result.merged.schemaVersion | Should -Be 2
        $result.merged.mode | Should -Be workflow
        $result.after | Should -BeExactly $result.before
    }
}
