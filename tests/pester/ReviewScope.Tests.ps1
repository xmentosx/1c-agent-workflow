Describe 'Review scope from the branch transfer scope base' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $HelperPath = $context.HelperPath
        $script:ReviewBranch = 'itldev/task-задача'

        function Write-ReviewFile {
            param([string]$Root, [string]$Path, [string]$Text)
            $full = Join-Path $Root $Path
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $full))
            [IO.File]::WriteAllText($full, $Text, [Text.UTF8Encoding]::new($false))
        }
        function Invoke-ReviewGit {
            # Plain function: Git switches such as -A stay in $args.
            param([string]$Root)
            $gitArguments = @($args | ForEach-Object { [string]$_ })
            $ErrorActionPreference = 'Continue'
            $output = & git -C $Root -c core.quotepath=false @gitArguments 2>&1
            if ($LASTEXITCODE -ne 0) { throw "git $($gitArguments -join ' ') failed: $output" }
            return $output
        }
        function Save-ReviewCommit {
            param([string]$Root, [string]$Message)
            Invoke-ReviewGit $Root add -A | Out-Null
            Invoke-ReviewGit $Root commit --quiet -m $Message | Out-Null
            return ([string](Invoke-ReviewGit $Root rev-parse HEAD)).Trim()
        }
        function New-ReviewRepository {
            param([string]$Name)
            $root = Join-Path $TestDrive "Ревью $Name с пробелом"
            [void][IO.Directory]::CreateDirectory($root)
            Write-ReviewFile $root '.gitignore' ".agent-1c/dev-branches/`n.agent-1c/runs/`n.agent-1c/locks/`nbuild/result/`n"
            Write-ReviewFile $root 'src/cf/Configuration.xml' '<Configuration/>'
            Write-ReviewFile $root 'src/cf/ConfigDumpInfo.xml' 'dump 1'
            Write-ReviewFile $root 'src/cf/CommonModules/Общий модуль.xml' 'descriptor'
            Write-ReviewFile $root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' 'base'
            Write-ReviewFile $root 'src/cf/CommonModules/Чужой модуль/Ext/Module.bsl' 'base'
            Write-ReviewFile $root 'docs/readme.md' 'base'
            & git -C $root init --quiet
            & git -C $root config user.email test@example.com
            & git -C $root config user.name Fixture
            & git -C $root config core.autocrlf false
            $initial = Save-ReviewCommit $root 'initial'
            & git -C $root branch -M master
            Invoke-ReviewGit $root checkout --quiet -b $script:ReviewBranch | Out-Null
            return [pscustomobject]@{ root = $root; initial = $initial }
        }
        function New-ReviewState {
            param([object]$Fixture)
            return [ordered]@{ devBranch = $script:ReviewBranch; createdWithWorktree = $true; worktreePath = $Fixture.root; initializationStatus = 'ready' }
        }
        function Save-ReviewState {
            param([object]$Fixture, [Collections.IDictionary]$State)
            $path = Join-Path $Fixture.root ".agent-1c/dev-branches/$(ConvertTo-SafeName ($script:ReviewBranch.Substring(7))).json"
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
            [IO.File]::WriteAllText($path, ($State | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
            return $path
        }
        function Set-ReviewRefreshProof {
            param([object]$Fixture, [Collections.IDictionary]$State, [string]$MasterCommit, [string]$At = '2026-11-03T10:00:00Z')
            $State.lastRefreshMasterCommit = $MasterCommit
            $State.lastRefreshAt = $At
            $State.resultTransferBaseline = New-DevBranchResultTransferBaseline -State ([pscustomobject]$State) -Operation refresh-dev-branch -BaseCommit $MasterCommit -CompletedAt $At
            Save-ReviewState $Fixture $State | Out-Null
        }
        function Get-ReviewKind {
            param([object]$Scope, [string]$Kind)
            return @($Scope.entries | Where-Object kind -eq $Kind | ForEach-Object path)
        }
        function Invoke-ReviewCommand {
            param([string]$Root, [string]$Command)
            # Execute the emitted PowerShell command exactly as an agent would.
            Push-Location -LiteralPath $Root
            try {
                $output = Invoke-Expression ($Command + ' 2>&1')
                $LASTEXITCODE | Should -Be 0 -Because $Command
                return (@($output) -join "`n")
            } finally { Pop-Location }
        }
    }

    It 'covers the whole branch work before lifecycle operations with legacy provenance (1, 6)' {
        $fixture = New-ReviewRepository 'вся доработка'
        & {
            . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' 'committed work'
            Save-ReviewCommit $fixture.root 'work' | Out-Null
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Новый модуль.xml' 'untracked new object'
            Save-ReviewState $fixture (New-ReviewState $fixture) | Out-Null
            $scope = Get-ReviewScope -ReviewPurpose review
            $scope.mode | Should -Be 'branch'
            $scope.baseCommit | Should -Be $fixture.initial
            $scope.baseProvenance | Should -Be 'legacy:merge-base-master-no-lifecycle-proof'
            Get-ReviewKind $scope 'subject' | Should -Be @('src/cf/CommonModules/Новый модуль.xml', 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl')
            @($scope.entries | Where-Object path -eq 'src/cf/CommonModules/Новый модуль.xml').untracked | Should -BeTrue
        }
    }

    It 'shows only work after a reset without refresh and none of the master changes (2)' {
        $fixture = New-ReviewRepository 'после reset'
        & {
            . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' 'old task'
            Save-ReviewCommit $fixture.root 'old task' | Out-Null
            Invoke-ReviewGit $fixture.root checkout --quiet master | Out-Null
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Чужой модуль/Ext/Module.bsl' 'master change'
            $master = Save-ReviewCommit $fixture.root 'master'
            Invoke-ReviewGit $fixture.root checkout --quiet $script:ReviewBranch | Out-Null
            $resetHead = Set-DevBranchTreeToMasterCommit -MasterCommit $master
            $state = New-ReviewState $fixture
            $state.resetStatus = 'complete'; $state.resetMasterCommit = $master; $state.resetNewHead = $resetHead; $state.resetCompletedAt = '2026-11-03T09:00:00Z'
            $state.resultTransferBaseline = New-DevBranchResultTransferBaseline -State ([pscustomobject]$state) -Operation reset-dev-branch -BaseCommit $master -CompletedHead $resetHead -CompletedAt $state.resetCompletedAt
            Save-ReviewState $fixture $state | Out-Null
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' 'new task'
            $scope = Get-ReviewScope -ReviewPurpose review
            $scope.baseCommit | Should -Be $master
            $scope.baseProvenance | Should -Be 'lifecycle:reset-dev-branch'
            Get-ReviewKind $scope 'subject' | Should -Be @('src/cf/CommonModules/Общий модуль/Ext/Module.bsl')
        }
    }

    It 'after transfer, repository edit and refresh keeps only the fixes as subject and past tests and specs as lists (3)' {
        $fixture = New-ReviewRepository 'возврат к ветке'
        & {
            . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' 'transferred work'
            Write-ReviewFile $fixture.root 'tests/features/Прошлая доработка.feature' 'past test'
            Write-ReviewFile $fixture.root 'openspec/changes/past-change/proposal.md' 'past spec'
            Save-ReviewCommit $fixture.root 'past work' | Out-Null
            # Master is built from the repository dump: the transferred code
            # with a repository edit arrives, tests and specs do not.
            Invoke-ReviewGit $fixture.root checkout --quiet master | Out-Null
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' 'transferred work'
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Чужой модуль/Ext/Module.bsl' 'repository edit'
            $master = Save-ReviewCommit $fixture.root 'repository dump'
            Invoke-ReviewGit $fixture.root checkout --quiet $script:ReviewBranch | Out-Null
            Invoke-ReviewGit $fixture.root merge --quiet --no-edit master | Out-Null
            $state = New-ReviewState $fixture
            Set-ReviewRefreshProof $fixture $state $master
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' 'analyst fix'
            $scope = Get-ReviewScope -ReviewPurpose review
            $scope.baseCommit | Should -Be $master
            Get-ReviewKind $scope 'subject' | Should -Be @('src/cf/CommonModules/Общий модуль/Ext/Module.bsl')
            @($scope.objects.groups[0].items.name) | Should -Be @('ОбщийМодуль.Общий модуль')
            Get-ReviewKind $scope 'tests' | Should -Be @('tests/features/Прошлая доработка.feature')
            Get-ReviewKind $scope 'requirements' | Should -Be @('openspec/changes/past-change/proposal.md')
            @($scope.entries | Where-Object kind -eq 'tests').command | Should -Match ([regex]::Escape("diff --no-renames $master -- 'tests/features/Прошлая доработка.feature'"))
        }
    }

    It 'keeps a refreshed shared file in scope without master changes and shows a conflict lost to the branch version (4)' {
        $fixture = New-ReviewRepository 'refresh без переноса'
        & {
            . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
            $lines = "a`nb`nc`nd`ne`nf`n"
            Invoke-ReviewGit $fixture.root checkout --quiet master | Out-Null
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' $lines
            Save-ReviewCommit $fixture.root 'shared lines' | Out-Null
            Invoke-ReviewGit $fixture.root checkout --quiet $script:ReviewBranch | Out-Null
            Invoke-ReviewGit $fixture.root merge --quiet --ff-only master | Out-Null
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' ("branch line`n" + $lines)
            Save-ReviewCommit $fixture.root 'branch' | Out-Null
            Invoke-ReviewGit $fixture.root checkout --quiet master | Out-Null
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' ($lines + "master line`n")
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Чужой модуль/Ext/Module.bsl' 'repository fix'
            $master = Save-ReviewCommit $fixture.root 'master'
            Invoke-ReviewGit $fixture.root checkout --quiet $script:ReviewBranch | Out-Null
            Invoke-ReviewGit $fixture.root merge --quiet --no-edit master | Out-Null
            $state = New-ReviewState $fixture
            Set-ReviewRefreshProof $fixture $state $master
            $scope = Get-ReviewScope -ReviewPurpose review
            Get-ReviewKind $scope 'subject' | Should -Be @('src/cf/CommonModules/Общий модуль/Ext/Module.bsl')
            $diff = Invoke-ReviewCommand $fixture.root (@($scope.entries | Where-Object kind -eq 'subject')[0].command)
            $diff | Should -Match '\+branch line'
            $diff | Should -Not -Match 'master line'

            # A conflict resolved with the branch version loses the repository fix.
            Invoke-ReviewGit $fixture.root checkout --quiet master | Out-Null
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Чужой модуль/Ext/Module.bsl' 'second repository fix'
            $second = Save-ReviewCommit $fixture.root 'master 2'
            Invoke-ReviewGit $fixture.root checkout --quiet $script:ReviewBranch | Out-Null
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Чужой модуль/Ext/Module.bsl' 'branch version'
            Save-ReviewCommit $fixture.root 'branch edit' | Out-Null
            & git -C $fixture.root merge --quiet --no-edit master *> $null
            Invoke-ReviewGit $fixture.root checkout --ours -- 'src/cf/CommonModules/Чужой модуль/Ext/Module.bsl' | Out-Null
            Save-ReviewCommit $fixture.root 'resolved with branch version' | Out-Null
            Set-ReviewRefreshProof $fixture $state $second '2026-11-03T11:00:00Z'
            $scope = Get-ReviewScope -ReviewPurpose review
            Get-ReviewKind $scope 'subject' | Should -Contain 'src/cf/CommonModules/Чужой модуль/Ext/Module.bsl'
            $lost = Invoke-ReviewCommand $fixture.root (@($scope.entries | Where-Object path -eq 'src/cf/CommonModules/Чужой модуль/Ext/Module.bsl')[0].command)
            $lost | Should -Match '-second repository fix'
        }
    }

    It 'moves the scope base after a manual master merge and refuses a fork until refresh (5)' {
        $fixture = New-ReviewRepository 'ручной merge'
        & {
            . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
            function Get-MasterBranch { 'master' }
            $state = New-ReviewState $fixture
            Set-ReviewRefreshProof $fixture $state $fixture.initial
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' 'own'
            Save-ReviewCommit $fixture.root 'own' | Out-Null
            Invoke-ReviewGit $fixture.root checkout --quiet master | Out-Null
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Чужой модуль/Ext/Module.bsl' 'master change'
            $master = Save-ReviewCommit $fixture.root 'master'
            Invoke-ReviewGit $fixture.root checkout --quiet $script:ReviewBranch | Out-Null
            Invoke-ReviewGit $fixture.root merge --quiet --no-edit master | Out-Null
            $stateObject = Read-DevBranchState
            $scope = Get-ReviewScope -ReviewPurpose review
            $scope.baseCommit | Should -Be $master
            $scope.baseProvenance | Should -Be 'merge-base-after-manual-merge'
            $scope.recordedCommit | Should -Be $fixture.initial
            Get-ReviewKind $scope 'subject' | Should -Be @('src/cf/CommonModules/Общий модуль/Ext/Module.bsl')
            $lock = Get-ConfigRepositoryTransferPlan -ExportPath src/cf -State $stateObject -ForRepositoryLock
            @($lock.items.name) | Should -Be @('ОбщийМодуль.Общий модуль')
            $lock.baseProvenance | Should -Be 'merge-base-after-manual-merge'
            $report = [Collections.Generic.List[string]]::new()
            Add-ConfigRepositoryTransferPlanRunUserReportLines -Lines $report -Plan (Get-ConfigRepositoryTransferPlan -ExportPath src/cf -State $stateObject -ForReport)
            ($report -join "`n") | Should -Match 'merge-base-after-manual-merge'
        }

        $fork = New-ReviewRepository 'fork ручной merge'
        & {
            . $HelperPath -ProjectRoot $fork.root -Action help *> $null
            function Get-MasterBranch { 'master' }
            Invoke-ReviewGit $fork.root checkout --quiet -b itldev/source | Out-Null
            Write-ReviewFile $fork.root 'src/cf/CommonModules/Чужой модуль/Ext/Module.bsl' 'source branch work'
            $source = Save-ReviewCommit $fork.root 'source'
            Invoke-ReviewGit $fork.root checkout --quiet -B $script:ReviewBranch $source | Out-Null
            $state = New-ReviewState $fork
            $state.forkId = 'fork-1'; $state.forkedFromCommit = $source
            $state.resultTransferBaseline = New-DevBranchResultTransferBaseline -State ([pscustomobject]$state) -Operation fork-dev-branch -BaseCommit $source
            Save-ReviewState $fork $state | Out-Null
            Write-ReviewFile $fork.root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' 'fork work'
            Save-ReviewCommit $fork.root 'fork work' | Out-Null
            (Get-ReviewScope -ReviewPurpose review).baseProvenance | Should -Be 'lifecycle:fork-dev-branch'
            Invoke-ReviewGit $fork.root checkout --quiet master | Out-Null
            Write-ReviewFile $fork.root 'docs/readme.md' 'master change'
            $master = Save-ReviewCommit $fork.root 'master'
            Invoke-ReviewGit $fork.root checkout --quiet $script:ReviewBranch | Out-Null
            Invoke-ReviewGit $fork.root merge --quiet --no-edit master | Out-Null
            $stateObject = Read-DevBranchState
            { Get-ReviewScope -ReviewPurpose review } | Should -Throw '*DEV_BRANCH_MANUAL_MERGE_REFRESH_REQUIRED*/itl-refresh*development chat*'
            { Get-ConfigRepositoryTransferPlan -ExportPath src/cf -State $stateObject -ForRepositoryLock } | Should -Throw '*DEV_BRANCH_MANUAL_MERGE_REFRESH_REQUIRED*/itl-refresh*'
            $reportPlan = Get-ConfigRepositoryTransferPlan -ExportPath src/cf -State $stateObject -ForReport
            $reportPlan.unavailableCode | Should -Be 'DEV_BRANCH_MANUAL_MERGE_REFRESH_REQUIRED'
            @($reportPlan.items).Count | Should -Be 0
            $report = [Collections.Generic.List[string]]::new()
            Add-ConfigRepositoryTransferPlanRunUserReportLines -Lines $report -Plan $reportPlan
            ($report -join "`n") | Should -Match 'WARN: .*DEV_BRANCH_MANUAL_MERGE_REFRESH_REQUIRED'
            ($report -join "`n") | Should -Match '/itl-refresh'

            # Continuation: /itl-refresh records the merged master as the base.
            Set-ReviewRefreshProof $fork $state $master
            $after = Get-ConfigRepositoryTransferPlan -ExportPath src/cf -State (Read-DevBranchState) -ForRepositoryLock
            $after.baseCommit | Should -Be $master
            (Get-ReviewScope -ReviewPurpose review).mode | Should -Be 'branch'
        }

        $rewritten = New-ReviewRepository 'переписанный master'
        & {
            . $HelperPath -ProjectRoot $rewritten.root -Action help *> $null
            function Get-MasterBranch { 'master' }
            Invoke-ReviewGit $rewritten.root checkout --quiet master | Out-Null
            Write-ReviewFile $rewritten.root 'docs/readme.md' 'master v1'
            $master = Save-ReviewCommit $rewritten.root 'master v1'
            Invoke-ReviewGit $rewritten.root checkout --quiet $script:ReviewBranch | Out-Null
            Invoke-ReviewGit $rewritten.root merge --quiet --no-edit master | Out-Null
            $state = New-ReviewState $rewritten
            Set-ReviewRefreshProof $rewritten $state $master
            # Rewrite master (not a fast-forward) to a sibling of the recorded base.
            Invoke-ReviewGit $rewritten.root checkout --quiet -B master $rewritten.initial | Out-Null
            Write-ReviewFile $rewritten.root 'docs/readme.md' 'master rewritten'
            $rewrittenMaster = Save-ReviewCommit $rewritten.root 'rewritten'
            Invoke-ReviewGit $rewritten.root checkout --quiet $script:ReviewBranch | Out-Null
            Invoke-ReviewGit $rewritten.root merge --quiet --no-edit -X theirs master | Out-Null
            { Get-ReviewScope -ReviewPurpose review } | Should -Throw '*DEV_BRANCH_TRANSFER_SCOPE_BASE_DIVERGED*/itl-refresh*'
            Set-ReviewRefreshProof $rewritten $state $rewrittenMaster '2026-11-03T12:00:00Z'
            (Get-ReviewScope -ReviewPurpose review).baseCommit | Should -Be $rewrittenMaster
        }
    }

    It 'keeps verification and production on the recorded proof after a manual merge (8)' {
        $fixture = New-ReviewRepository 'изоляция'
        & {
            . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
            function Get-MasterBranch { 'master' }
            $state = New-ReviewState $fixture
            Set-ReviewRefreshProof $fixture $state $fixture.initial
            Invoke-ReviewGit $fixture.root checkout --quiet master | Out-Null
            Write-ReviewFile $fixture.root 'docs/readme.md' 'master'
            $master = Save-ReviewCommit $fixture.root 'master'
            Invoke-ReviewGit $fixture.root checkout --quiet $script:ReviewBranch | Out-Null
            Invoke-ReviewGit $fixture.root merge --quiet --no-edit master | Out-Null
            $stateObject = Read-DevBranchState
            Get-DevBranchResultTransferBaseCommit -State $stateObject | Should -Be $fixture.initial
            (Get-DevBranchTransferScopeBaseline -State $stateObject).commit | Should -Be $master
        }
        $text = Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $HelperPath) 'lib/agent-1c.lifecycle.ps1')
        $production = [regex]::Match($text, '(?s)function New-ProductionPlatformLegacyContext\s*\{.*?(?=\r?\nfunction )').Value
        $production | Should -Match 'Get-DevBranchResultTransferBaseline -State'
        $production | Should -Not -Match 'TransferScopeBaseline'
        $verification = Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent $HelperPath) 'lib/agent-1c.verification-change.ps1')
        $verification | Should -Match 'Get-DevBranchResultTransferBaseCommit -State'
        $releaseLock = [regex]::Match($text, '(?s)function Invoke-ReleaseE2EConfigRepositoryLockRoundtrip\s*\{.*?(?=\r?\nfunction )').Value
        $releaseLock | Should -Match 'Get-ConfigRepositoryTransferPlan -ExportPath \(Get-ExportPath\) -State \$state\r?\n'
        $plan = [regex]::Match($text, '(?s)function Get-ConfigRepositoryTransferPlan\s*\{.*?(?=\r?\nfunction )').Value
        $plan | Should -Match 'Get-DevBranchTransferScopeBaseline -State'
    }

    It 'classifies kinds by owner in first-match order (11) and reads a whitespace and Cyrillic path in every kind (7)' {
        $fixture = New-ReviewRepository 'виды файлов'
        & {
            . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
            Write-ReviewFile $fixture.root 'tests/verification-suites.shared.json' (@{ schemaVersion = 2; obligations = @(@{ id = 'o'; inputPaths = @('docs/Требование вход.md', 'scripts/Проверка вход/*.ps1') }) } | ConvertTo-Json -Depth 5)
            Save-ReviewCommit $fixture.root 'catalog on master' | Out-Null
            Invoke-ReviewGit $fixture.root branch -f master HEAD | Out-Null
            $base = ([string](Invoke-ReviewGit $fixture.root rev-parse HEAD)).Trim()
            $paths = [ordered]@{
                'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' = 'subject'
                'src/cf/Configuration.xml' = 'subject'
                'src/cf/ConfigDumpInfo.xml' = 'always-excluded'
                'src/cfe/Расширение один/CommonModules/Модуль А/Ext/Module.bsl' = 'subject'
                'src/cfe/Расширение два/Catalogs/Справочник Б.xml' = 'subject'
                'src/cfe/tests/CommonModules/Тест модуль/Ext/Module.bsl' = 'tests'
                'tests/yaxunit/Тест с пробелом.bsl' = 'tests'
                'tests/features/Сценарий с пробелом.feature' = 'tests'
                'scripts/Проверка вход/check one.ps1' = 'tests'
                'docs/Требование вход.md' = 'requirements'
                'docs/Постановка с пробелом.md' = 'requirements'
                'handoffs/Передача.md' = 'requirements'
                'docs/itl-workflow/Управляемый.md' = 'excluded'
                'tests/features/Libraries/ITL/Шаг.feature' = 'excluded'
                '.agent-1c/project.json' = 'excluded'
                '.agent-1c/diagnostic-artifacts/квитанция 1.json' = 'excluded'
                '.agent-1c/validation/Проверка 1.json' = 'unclassified'
                'tests/performance/Замер/сценарий.json' = 'unclassified'
                'build/Скрипт агента.ps1' = 'unclassified'
            }
            foreach ($path in $paths.Keys) { Write-ReviewFile $fixture.root $path "branch $path" }
            Write-ReviewFile $fixture.root 'build/result/Игнор.cf' 'ignored'
            Save-ReviewCommit $fixture.root 'kinds' | Out-Null
            Save-ReviewState $fixture (New-ReviewState $fixture) | Out-Null
            $scope = Get-ReviewScope -ReviewPurpose review
            $scope.baseCommit | Should -Be $base
            foreach ($path in $paths.Keys) {
                @($scope.entries | Where-Object path -ceq $path).kind | Should -Be $paths[$path] -Because $path
            }
            @($scope.entries | Where-Object path -like 'build/result/*').Count | Should -Be 0
            $roots = @($scope.objects.groups.root)
            $roots | Should -Be @('src/cf', 'src/cfe/Расширение два', 'src/cfe/Расширение один')
            @($scope.objects.groups[0].items.name) | Should -Be @('ОбщийМодуль.Общий модуль')
            @($scope.objects.groups[1].items.name) | Should -Be @('Справочник.Справочник Б')
            $transfer = Get-ConfigRepositoryTransferPlan -ExportPath 'src/cfe/Расширение один' -BaseCommit $base
            @($scope.objects.groups[2].items.name) | Should -Be @($transfer.items.name)
            foreach ($entry in @($scope.entries | Where-Object kind -in @('subject', 'tests', 'requirements'))) {
                Invoke-ReviewCommand $fixture.root $entry.command | Should -Match ([regex]::Escape("+branch $($entry.path)"))
            }
            $lines = [Collections.Generic.List[string]]::new()
            Add-ReviewScopeGroupedLines -Lines $lines -Entries @(1..21 | ForEach-Object { [pscustomobject]@{ path = "tests/performance/Замер/$_.json"; command = '' } })
            @($lines) | Should -Be @('- tests/performance/ (21)')
        }
    }

    It 'only reads: worktree, index, branch state, refs and objects stay unchanged (10)' {
        $fixture = New-ReviewRepository 'только чтение'
        & {
            . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' 'staged'
            Invoke-ReviewGit $fixture.root add -A | Out-Null
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Чужой модуль/Ext/Module.bsl' 'unstaged'
            Write-ReviewFile $fixture.root 'docs/Новый.md' 'untracked'
            $statePath = Save-ReviewState $fixture (New-ReviewState $fixture)
            $snapshot = {
                [pscustomobject]@{
                    status = (Invoke-ReviewGit $fixture.root status --porcelain=v1 --untracked-files=all) -join "`n"
                    index = (Get-FileHash -LiteralPath (Join-Path $fixture.root '.git/index')).Hash
                    state = [IO.File]::ReadAllText($statePath)
                    refs = (Invoke-ReviewGit $fixture.root for-each-ref) -join "`n"
                    objects = (Invoke-ReviewGit $fixture.root count-objects -v) -join "`n"
                }
            }
            $before = & $snapshot
            $scope = Get-ReviewScope -ReviewPurpose review
            $after = & $snapshot
            ($after | ConvertTo-Json) | Should -Be ($before | ConvertTo-Json)
            Get-ReviewKind $scope 'requirements' | Should -Be @('docs/Новый.md')
            @(Get-ReviewKind $scope 'subject').Count | Should -Be 2
            Test-Agent1cActionRequiresLifecycleLock -RequestedAction 'get-review-scope' | Should -BeFalse
        }
    }

    It 'runs while another action holds the lifecycle lock and two parallel calls both return the scope (12)' {
        $fixture = New-ReviewRepository 'параллельно'
        & {
            . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' 'own'
            Save-ReviewCommit $fixture.root 'own' | Out-Null
            Save-ReviewState $fixture (New-ReviewState $fixture) | Out-Null
            Enter-Agent1cLifecycleOperation -RequestedAction 'check-dev-branch'
            try {
                $runs = @(foreach ($index in 1, 2) {
                    $statusPath = Join-Path $TestDrive "review-status-$index-$([guid]::NewGuid().ToString('N')).json"
                    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $HelperPath + '"'), '-ProjectRoot', ('"' + $fixture.root + '"'),
                        '-Action', 'get-review-scope', '-ReviewPurpose', 'review', '-RunStatusPath', ('"' + $statusPath + '"'))
                    [pscustomobject]@{ statusPath = $statusPath; process = Start-Process -FilePath powershell -ArgumentList $arguments -PassThru -WindowStyle Hidden }
                })
                foreach ($run in $runs) {
                    $run.process.WaitForExit(180000) | Should -BeTrue
                    $run.process.ExitCode | Should -Be 0
                    $status = [IO.File]::ReadAllText($run.statusPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
                    $status.status | Should -Be 'succeeded'
                    $status.stageDetail | Should -Match "mode=branch; base=$($fixture.initial);.*subject=1; objects=1"
                    $status.userReport | Should -Match ([regex]::Escape("diff --no-renames $($fixture.initial) -- 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl'"))
                }
            } finally {
                Complete-Agent1cLifecycleOperation -Status 'succeeded' -ExitCode 0
                Exit-Agent1cLifecycleOperation
            }
        }
    }

    It 'refuses <Case> for a separate review, passes after the continuation, and falls back to the local delta for self-review (9, 13)' -TestCases @(
        @{ Case = 'pending refresh'; Code = 'REVIEW_SCOPE_REFRESH_PENDING' },
        @{ Case = 'unfinished reset'; Code = 'DEV_BRANCH_RESET_IN_PROGRESS' },
        @{ Case = 'merge conflict'; Code = 'REVIEW_SCOPE_MERGE_CONFLICT' },
        @{ Case = 'corrupted proof'; Code = 'DEV_BRANCH_TRANSFER_BASELINE_INVALID' },
        @{ Case = 'fork after manual merge'; Code = 'DEV_BRANCH_MANUAL_MERGE_REFRESH_REQUIRED' }
    ) {
        param($Case, $Code)
        $fixture = New-ReviewRepository "отказ $Case"
        & {
            . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
            function Get-MasterBranch { 'master' }
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' 'own'
            Save-ReviewCommit $fixture.root 'own' | Out-Null
            Invoke-ReviewGit $fixture.root checkout --quiet master | Out-Null
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' 'master conflict'
            $master = Save-ReviewCommit $fixture.root 'master'
            Invoke-ReviewGit $fixture.root checkout --quiet $script:ReviewBranch | Out-Null
            $state = New-ReviewState $fixture
            switch ($Case) {
                'pending refresh' {
                    # The base owner alone would answer with the generic code.
                    $state.initializationStatus = 'updating'
                    $state.pendingMergeOperation = 'refresh-dev-branch'; $state.pendingMergeTargetCommit = $master; $state.pendingMergeStage = 'merged'
                    $state.resultTransferBaseline = New-DevBranchResultTransferBaseline -State ([pscustomobject]$state) -Operation refresh-dev-branch -BaseCommit $fixture.initial -CompletedHead $fixture.initial -CompletedAt '2026-11-03T08:00:00Z'
                    $state.lastRefreshMasterCommit = $fixture.initial; $state.lastRefreshAt = '2026-11-03T08:00:00Z'
                }
                'unfinished reset' { $state.resetStatus = 'resetting'; $state.resetOldHead = $fixture.initial }
                'merge conflict' { & git -C $fixture.root merge --quiet --no-edit master *> $null }
                'corrupted proof' { $state.resultTransferBaseline = @{ schemaVersion = 9 } }
                'fork after manual merge' {
                    $state.forkId = 'fork-1'; $state.forkedFromCommit = ([string](Invoke-ReviewGit $fixture.root rev-parse HEAD)).Trim()
                    $state.resultTransferBaseline = New-DevBranchResultTransferBaseline -State ([pscustomobject]$state) -Operation fork-dev-branch -BaseCommit $state.forkedFromCommit
                    Invoke-ReviewGit $fixture.root merge --quiet --no-edit -X ours master | Out-Null
                }
            }
            Save-ReviewState $fixture $state | Out-Null
            $statusBefore = (Invoke-ReviewGit $fixture.root status --porcelain=v1) -join "`n"
            $headBefore = ([string](Invoke-ReviewGit $fixture.root rev-parse HEAD)).Trim()
            $failure = $null
            try { Get-ReviewScope -ReviewPurpose review | Out-Null } catch { $failure = $_.Exception.Message }
            $failure | Should -BeLike "$($Code):*"
            $failure | Should -Match 'development chat'
            $failure | Should -Match 'does not run lifecycle commands'

            $self = Get-ReviewScope -ReviewPurpose self
            $self.mode | Should -Be 'local-delta'
            $self.baseCommit | Should -Be $headBefore
            $self.refusal.code | Should -Be $Code
            $self.refusal.continuation | Should -Match '/itl-'
            ([string](Invoke-ReviewGit $fixture.root rev-parse HEAD)).Trim() | Should -Be $headBefore
            ((Invoke-ReviewGit $fixture.root status --porcelain=v1) -join "`n") | Should -Be $statusBefore

            # Perform the named continuation, then the original review passes.
            if ($Case -eq 'merge conflict') {
                Invoke-ReviewGit $fixture.root checkout --ours -- 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' | Out-Null
                Save-ReviewCommit $fixture.root 'refresh conflict resolved' | Out-Null
            } elseif ($Case -eq 'pending refresh') {
                Invoke-ReviewGit $fixture.root merge --quiet --no-edit -X ours master | Out-Null
            } elseif ($Case -eq 'unfinished reset') {
                $resetHead = Set-DevBranchTreeToMasterCommit -MasterCommit $master
                $state.resetStatus = 'complete'; $state.resetMasterCommit = $master; $state.resetNewHead = $resetHead; $state.resetCompletedAt = '2026-11-03T09:30:00Z'
                $state.resultTransferBaseline = New-DevBranchResultTransferBaseline -State ([pscustomobject]$state) -Operation reset-dev-branch -BaseCommit $master -CompletedHead $resetHead -CompletedAt $state.resetCompletedAt
                Save-ReviewState $fixture $state | Out-Null
            }
            if ($Case -ne 'unfinished reset') {
                if ($Case -ne 'fork after manual merge' -and $Case -ne 'pending refresh' -and $Case -ne 'merge conflict') {
                    Invoke-ReviewGit $fixture.root merge --quiet --no-edit -X ours master | Out-Null
                }
                foreach ($name in @('pendingMergeOperation', 'pendingMergeTargetCommit', 'pendingMergeStage')) { $state.Remove($name) }
                $state.initializationStatus = 'ready'
                Set-ReviewRefreshProof $fixture $state $master '2026-11-03T10:30:00Z'
            }
            $passed = Get-ReviewScope -ReviewPurpose review
            $passed.mode | Should -Be 'branch'
            $passed.baseCommit | Should -Be $master
        }
    }

    It 'requires an explicit purpose and outside a development branch refuses review but returns the local delta for self (13, 14)' {
        $fixture = New-ReviewRepository 'вне ветки'
        & {
            . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
            { Get-ReviewScope } | Should -Throw '*REVIEW_SCOPE_PURPOSE_REQUIRED*-ReviewPurpose review*-ReviewPurpose self*'
            Invoke-ReviewGit $fixture.root checkout --quiet master | Out-Null
            Write-ReviewFile $fixture.root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' 'local edit'
            { Get-ReviewScope -ReviewPurpose review } | Should -Throw '*REVIEW_SCOPE_DEVELOPMENT_BRANCH_REQUIRED*itldev/*review-criteria.md -> Scope*'
            $self = Get-ReviewScope -ReviewPurpose self
            $self.mode | Should -Be 'local-delta'
            $self.refusal.code | Should -Be 'REVIEW_SCOPE_DEVELOPMENT_BRANCH_REQUIRED'
            Get-ReviewKind $self 'subject' | Should -Be @('src/cf/CommonModules/Общий модуль/Ext/Module.bsl')
        }
        $agent = Get-Content -Raw -Encoding UTF8 $HelperPath
        $agent | Should -Match '\[ValidateSet\("", "review", "self"\)\]\s*\[string\]\$ReviewPurpose'
        $agent | Should -Match '"get-review-scope" \{ Invoke-ReviewScopeAction -ReviewPurpose \$ReviewPurpose -ReviewRange \$ReviewRange -ReviewSince \$ReviewSince \}'
        $agent | Should -Match '\[ValidateSet\("", "branch", "uncommitted", "since"\)\]\s*\[string\]\$ReviewRange'
        (Get-Content -Raw (Join-Path (Split-Path -Parent $HelperPath) 'run-itl-command.ps1')) | Should -Match '"get-review-scope"'
        $overlay = (Get-Content -Raw -Encoding UTF8 (Join-Path $context.RepoRoot 'templates/ai-rules-overlay/AGENTS.md')) -replace '\s+', ' '
        $overlay | Should -Match ([regex]::Escape('For a code review, including `/ponytail-review`, take the scope from the helper action `get-review-scope`'))
        $overlay | Should -Match ([regex]::Escape('verification-result.md#review-scope'))
        (Get-Content -Raw -Encoding UTF8 (Join-Path (Split-Path -Parent (Split-Path -Parent $HelperPath)) 'references/verification-result.md')) | Should -Match '(?m)^## Review scope?$'
    }

    Context 'size, range choice and itl-check freshness' {
        BeforeAll {
            function New-ReviewLargeText {
                param([string]$Tag)
                # ~320 KB of Cyrillic BSL: above the 300 KB separate-review threshold.
                $line = "Процедура Обработка$Tag() Экспорт // длинный комментарий для объёма текста изменений"
                return ((1..2400 | ForEach-Object { "$line $_" }) -join "`n")
            }
            function New-ReviewRefreshedLargeBranch {
                param([string]$Name)
                $fixture = New-ReviewRepository $Name
                Write-ReviewFile $fixture.root 'src/cf/CommonModules/Ранний модуль/Ext/Module.bsl' 'early branch work'
                $early = Save-ReviewCommit $fixture.root 'feat: ранняя правка'
                Write-ReviewFile $fixture.root 'src/cf/CommonModules/Большой модуль/Ext/Module.bsl' (New-ReviewLargeText 'А')
                $checkpoint = Save-ReviewCommit $fixture.root 'chore: checkpoint before branch refresh'
                Invoke-ReviewGit $fixture.root checkout --quiet master | Out-Null
                Write-ReviewFile $fixture.root 'src/cf/CommonModules/Чужой модуль/Ext/Module.bsl' 'master change'
                $master = Save-ReviewCommit $fixture.root 'master'
                Invoke-ReviewGit $fixture.root checkout --quiet $script:ReviewBranch | Out-Null
                Invoke-ReviewGit $fixture.root merge --quiet --no-edit master | Out-Null
                $merge = ([string](Invoke-ReviewGit $fixture.root rev-parse HEAD)).Trim()
                $state = New-ReviewState $fixture
                Write-ReviewFile $fixture.root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' 'fix after refresh'
                $fix = Save-ReviewCommit $fixture.root 'fix: исправление после обновления'
                Write-ReviewFile $fixture.root 'docs/Заметка.md' 'note'
                $service = Save-ReviewCommit $fixture.root 'chore: persist branch configuration synchronization cursor'
                Write-ReviewFile $fixture.root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' 'fix after refresh, uncommitted'
                return [pscustomobject]@{ root = $fixture.root; initial = $fixture.initial; early = $early; checkpoint = $checkpoint; master = $master; merge = $merge; fix = $fix; service = $service; state = $state }
            }
            function Complete-ReviewRefreshFixture {
                # Needs the dot-sourced helper: the refresh proof owner records the base.
                param([object]$Fixture)
                Set-ReviewRefreshProof $Fixture $Fixture.state $Fixture.master
            }
        }

        It 'classifies a large separate review, offers the ranges and keeps self-review unchanged' {
            $fixture = New-ReviewRefreshedLargeBranch 'большой объём'
            & {
                . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
                Complete-ReviewRefreshFixture $fixture
                $choice = Get-ReviewScope -ReviewPurpose review
                $choice.mode | Should -Be 'range-required'
                $choice.size.sizeClass | Should -Be 'large'
                $choice.size.bytes | Should -BeGreaterThan 307200
                $choice.size.modules | Should -Be 3
                $choice.choice.uncommitted.size.modules | Should -Be 1
                $choice.choice.uncommitted.size.sizeClass | Should -Be 'normal'
                $picker = $choice.choice.picker
                # The work before the refresh stays selectable commit by commit.
                @($picker.items | ForEach-Object commit) | Should -Be @($fixture.fix, $fixture.merge, $fixture.checkpoint, $fixture.early)
                $picker.items[0].serviceBefore | Should -Be 1
                $picker.items[0].objects | Should -Be @('ОбщийМодуль.Общий модуль')
                $picker.items[0].size.modules | Should -Be 1
                $picker.items[0].crossed | Should -BeFalse
                $picker.items[1].anchor | Should -Be 'merge'
                $picker.items[1].label | Should -Be 'обновление из master'
                $picker.items[1].size.sizeClass | Should -Be 'normal'
                $picker.items[1].crossed | Should -BeFalse
                $picker.items[2].crossed | Should -BeTrue
                $picker.items[2].label | Should -Be 'автосохранение работы перед обновлением из master'
                $picker.items[2].size.modules | Should -Be 2
                $picker.items[2].size.sizeClass | Should -Be 'large'
                $picker.items[3].size.modules | Should -Be 3
                $picker.complete | Should -BeTrue
                $picker.allowed | Should -Contain $fixture.checkpoint
                $picker.allowed | Should -Not -Contain $fixture.master

                $uncommitted = Get-ReviewScope -ReviewPurpose review -ReviewRange uncommitted
                $uncommitted.mode | Should -Be 'uncommitted'
                $uncommitted.baseCommit | Should -Be $fixture.service
                Get-ReviewKind $uncommitted 'subject' | Should -Be @('src/cf/CommonModules/Общий модуль/Ext/Module.bsl')

                $branch = Get-ReviewScope -ReviewPurpose review -ReviewRange branch
                $branch.mode | Should -Be 'branch'
                $branch.size.sizeClass | Should -Be 'large'
                $branch.baseCommit | Should -Be $fixture.master
                Get-ReviewKind $branch 'subject' | Should -Contain 'src/cf/CommonModules/Большой модуль/Ext/Module.bsl'

                $self = Get-ReviewScope -ReviewPurpose self
                $self.mode | Should -Be 'branch'
                $self.choice | Should -BeNullOrEmpty
                { Get-ReviewScope -ReviewPurpose self -ReviewRange branch } | Should -Throw '*REVIEW_SCOPE_RANGE_REVIEW_ONLY*'
                { Get-ReviewScope -ReviewPurpose review -ReviewRange since } | Should -Throw '*REVIEW_SCOPE_SINCE_REQUIRED*'
            }
        }

        It 'starts a range at any branch commit without master changes and refuses a commit outside the branch' {
            $fixture = New-ReviewRefreshedLargeBranch 'с коммита'
            & {
                . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
                Complete-ReviewRefreshFixture $fixture
                $afterRefresh = Get-ReviewScope -ReviewPurpose review -ReviewRange since -ReviewSince $fixture.merge.Substring(0, 12)
                $afterRefresh.mode | Should -Be 'since'
                $afterRefresh.baseCommit | Should -Be $fixture.merge
                Get-ReviewKind $afterRefresh 'subject' | Should -Be @('src/cf/CommonModules/Общий модуль/Ext/Module.bsl')
                $fromFix = Get-ReviewScope -ReviewPurpose review -ReviewRange since -ReviewSince $fixture.fix
                $fromFix.baseCommit | Should -Be $fixture.merge
                $fromFix.size.sizeClass | Should -Be 'normal'
                Get-ReviewKind $fromFix 'subject' | Should -Not -Contain 'src/cf/CommonModules/Чужой модуль/Ext/Module.bsl'
                $fromFix.pathFiltered | Should -BeFalse

                # Before the refresh merge: the branch's own paths since the
                # commit, read from the branch base; master and earlier-only
                # branch paths stay out.
                $fromCheckpoint = Get-ReviewScope -ReviewPurpose review -ReviewRange since -ReviewSince $fixture.checkpoint.Substring(0, 12)
                $fromCheckpoint.mode | Should -Be 'since'
                $fromCheckpoint.baseCommit | Should -Be $fixture.master
                $fromCheckpoint.pathFiltered | Should -BeTrue
                $fromCheckpoint.size.modules | Should -Be 2
                @(Get-ReviewKind $fromCheckpoint 'subject' | Sort-Object) | Should -Be @(
                    'src/cf/CommonModules/Большой модуль/Ext/Module.bsl',
                    'src/cf/CommonModules/Общий модуль/Ext/Module.bsl')
                Get-ReviewKind $fromCheckpoint 'requirements' | Should -Be @('docs/Заметка.md')
                @($fromCheckpoint.objects.groups.items | ForEach-Object name) | Should -Not -Contain 'ОбщийМодуль.Ранний модуль'
                @($fromCheckpoint.entries | Where-Object path -eq 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl').command |
                    Should -Match ([regex]::Escape("diff --no-renames $($fixture.master) --"))
                $fromEarly = Get-ReviewScope -ReviewPurpose review -ReviewRange since -ReviewSince $fixture.early
                Get-ReviewKind $fromEarly 'subject' | Should -Contain 'src/cf/CommonModules/Ранний модуль/Ext/Module.bsl'
                Get-ReviewKind $fromEarly 'subject' | Should -Not -Contain 'src/cf/CommonModules/Чужой модуль/Ext/Module.bsl'

                foreach ($outside in @($fixture.master, $fixture.initial)) {
                    $failure = $null
                    try { Get-ReviewScope -ReviewPurpose review -ReviewRange since -ReviewSince $outside | Out-Null } catch { $failure = $_.Exception.Message }
                    $failure | Should -BeLike 'REVIEW_SCOPE_SINCE_NOT_ALLOWED:*'
                    $failure | Should -Match '-ReviewRange branch'
                }
            }
        }

        It 'reports the range question through the compact action and stops before the file lists' {
            $fixture = New-ReviewRefreshedLargeBranch 'вопрос'
            & { . $HelperPath -ProjectRoot $fixture.root -Action help *> $null; Complete-ReviewRefreshFixture $fixture }
            $statusPath = Join-Path $TestDrive "review-range-$([guid]::NewGuid().ToString('N')).json"
            $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $HelperPath + '"'), '-ProjectRoot', ('"' + $fixture.root + '"'),
                '-Action', 'get-review-scope', '-ReviewPurpose', 'review', '-RunStatusPath', ('"' + $statusPath + '"'))
            $process = Start-Process -FilePath powershell -ArgumentList $arguments -PassThru -WindowStyle Hidden
            $process.WaitForExit(180000) | Should -BeTrue
            $status = [IO.File]::ReadAllText($statusPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $process.ExitCode | Should -Be 0 -Because ([string]$status.errorMessage)
            $status.stage | Should -Be 'review-scope.range-required'
            $status.userReport | Should -Match 'Нужен выбор объёма ревью'
            $status.userReport | Should -Match 'Только незакоммиченные изменения'
            $status.userReport | Should -Match ([regex]::Escape("-ReviewRange since -ReviewSince $($fixture.merge.Substring(0, 12))"))
            $status.userReport | Should -Match 'обновление из master'
            $status.userReport | Should -Match 'служебные коммиты ITL без изменений 1С: 1'
            # One numbered option per commit, shown whole rather than as a few buttons.
            $status.userReport | Should -Match 'одним нумерованным списком'
            $status.userReport | Should -Match 'Не сводите варианты к кнопкам'
            $status.userReport | Should -Match ([regex]::Escape("### 4. С коммита $($fixture.checkpoint.Substring(0, 12))"))
            $status.userReport | Should -Match ([regex]::Escape("### 5. С коммита $($fixture.early.Substring(0, 12))"))
            $status.userReport | Should -Match 'до обновления из master: в ревью файлы, которые ветка меняла'
            $status.userReport | Should -Match '### 6\. Вся работа ветки'
            $status.userReport | Should -Match 'Вся работа ветки \(большой объём\)'
            $status.userReport | Should -Match 'Проверка /itl-check'
            $status.userReport | Should -Not -Match '## Предмет ревью: файлы'
        }

        It 'reports itl-check freshness without changing objects, index or state on a dirty tree' {
            $fixture = New-ReviewRepository 'свежесть проверки'
            & {
                . $HelperPath -ProjectRoot $fixture.root -Action help *> $null
                Write-ReviewFile $fixture.root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' 'checked'
                $checked = Save-ReviewCommit $fixture.root 'work'
                $state = New-ReviewState $fixture
                $statePath = Save-ReviewState $fixture $state
                (Get-ReviewScope -ReviewPurpose review).verification.status | Should -Be 'not-run'

                $state.lastVerificationStatus = 'passed'; $state.lastVerifiedCommit = $checked; $state.lastVerifiedAt = '2026-11-06T18:00:00+03:00'
                $state.lastVerifiedFingerprint = Get-VerificationFingerprint
                Save-ReviewState $fixture $state | Out-Null
                $current = Get-ReviewScope -ReviewPurpose review
                $current.verification.status | Should -Be 'current'
                $current.verification.gate1Evidence | Should -BeTrue
                $current.verification.verifiedCommit | Should -Be $checked

                Write-ReviewFile $fixture.root 'src/cf/CommonModules/Общий модуль/Ext/Module.bsl' 'changed after the check'
                $snapshot = {
                    [pscustomobject]@{
                        status = (Invoke-ReviewGit $fixture.root status --porcelain=v1 --untracked-files=all) -join "`n"
                        index = (Get-FileHash -LiteralPath (Join-Path $fixture.root '.git/index')).Hash
                        state = [IO.File]::ReadAllText($statePath)
                        refs = (Invoke-ReviewGit $fixture.root for-each-ref) -join "`n"
                        objects = (Invoke-ReviewGit $fixture.root count-objects -v) -join "`n"
                    }
                }
                $before = & $snapshot
                $stale = Get-ReviewScope -ReviewPurpose self
                $after = & $snapshot
                ($after | ConvertTo-Json) | Should -Be ($before | ConvertTo-Json)
                $stale.verification.status | Should -Be 'stale'
                $stale.verification.gate1Evidence | Should -BeFalse

                $state.lastVerificationStatus = 'failed'
                Save-ReviewState $fixture $state | Out-Null
                (Get-ReviewScope -ReviewPurpose review).verification.status | Should -Be 'failed'
            }
        }

        It 'labels every automatic commit subject the helper creates' {
            $libRoot = Join-Path (Split-Path -Parent $HelperPath) 'lib'
            $subjects = @(Get-ChildItem -LiteralPath $libRoot -Filter '*.ps1' | ForEach-Object {
                [regex]::Matches([IO.File]::ReadAllText($_.FullName), '"(?<subject>(?:chore: checkpoint before|sync: copy combined)[^"]*)"') | ForEach-Object { $_.Groups['subject'].Value }
            } | Sort-Object -Unique)
            $subjects.Count | Should -BeGreaterThan 4
            & {
                . $HelperPath -ProjectRoot $TestDrive -Action help *> $null
                foreach ($subject in $subjects) {
                    $sample = [regex]::Replace($subject, '\$\([^)]*\)\)?|\$[A-Za-z_][A-Za-z0-9_]*', 'itldev/пример')
                    (Get-ReviewScopeCommitLabel -Subject $sample) | Should -Not -Be $sample -Because "the picker explains '$subject'"
                }
            }
        }
    }
}
