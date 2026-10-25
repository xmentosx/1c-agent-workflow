
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $helperPath = $context.HelperPath
    $repoRoot = $context.RepoRoot

    function New-WorkflowRollbackFixture {
        param([string]$Root, [switch]$PendingInterruption, [switch]$MetadataCachedPackage, [switch]$PackageCache)
        New-Item -ItemType Directory -Force -Path (Join-Path $Root '.agent-1c/mcp'), (Join-Path $Root 'src/cf') | Out-Null
        [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/project.json'), '{"aiRules":{"tools":["codex"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $Root '.gitignore'), ".dev.env`n.agent-1c/mcp/`n.agent-1c/snapshots/`n.agent-1c/tmp/`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $Root 'AGENT-INSTALL.md'), 'old package', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Модуль.bsl'), 'business baseline', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $Root '.dev.env'), "CAVEMAN=On`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/mcp/client-managed.json'), '{"owners":{"old":"keep"}}', [Text.UTF8Encoding]::new($false))
        $cacheRoot='.agents/skills/itl-remote-runner'
        if ($PackageCache) {
            New-Item -ItemType Directory -Force -Path (Join-Path $Root ($cacheRoot+'/scripts/__pycache__')) | Out-Null
            [IO.File]::AppendAllText((Join-Path $Root '.gitignore'), "__pycache__/`n*.pyc`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $Root ($cacheRoot+'/scripts/module.py')), '# before source',[Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllBytes((Join-Path $Root ($cacheRoot+'/scripts/__pycache__/tracked.pyc')),[byte[]]@(0,255,13,10))
            [IO.File]::WriteAllBytes((Join-Path $Root ($cacheRoot+'/scripts/__pycache__/untracked.pyc')),[byte[]]@(0,128,10,13))
        }
        & git -C $Root init -q -b master
        & git -C $Root config user.name 'Workflow Rollback Test'
        & git -C $Root config user.email 'rollback@example.invalid'
        if ($MetadataCachedPackage) {
            # Supported local Git settings make this timestamp-preserving,
            # same-size copy deterministic without changing ordinary fixtures.
            & git -C $Root config --local core.trustctime false
            & git -C $Root config --local core.checkStat minimal
            $packageTime = [DateTime]::new(2020, 1, 2, 3, 4, 5, [DateTimeKind]::Utc)
            [IO.File]::SetLastWriteTimeUtc((Join-Path $Root 'AGENT-INSTALL.md'), $packageTime)
        }
        & git -C $Root add --all
        if ($PackageCache) { & git -C $Root add -f -- ($cacheRoot+'/scripts/__pycache__/tracked.pyc') }
        & git -C $Root commit -qm baseline
        $LASTEXITCODE | Should -Be 0
        $beforeHead = (& git -C $Root rev-parse HEAD).Trim()
        $saved = & {
            . $helperPath -ProjectRoot $Root -Action help *> $null
            $source = [pscustomobject]@{ root=$repoRoot; commit=('b' * 40); ref='master'; repo='fixture'; source='path' }
            $snapshotPaths=@('AGENT-INSTALL.md', '.dev.env', '.agent-1c/mcp/client-managed.json')
            if ($PackageCache) { $snapshotPaths += $cacheRoot }
            $snapshot = New-WorkflowUpdateRollbackSnapshot -RelativePaths $snapshotPaths `
                -SnapshotParent (Join-Path $Root '.agent-1c/snapshots/workflow-update')
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase prepared
            [IO.File]::WriteAllText((Join-Path $Root 'AGENT-INSTALL.md'), 'new package', [Text.UTF8Encoding]::new($false))
            if ($PackageCache) {
                $candidate=Join-Path $Root '.agent-1c/tmp/new package source'
                New-Item -ItemType Directory -Force -Path (Join-Path $candidate ($cacheRoot+'/scripts/__pycache__')) | Out-Null
                [IO.File]::WriteAllText((Join-Path $candidate ($cacheRoot+'/scripts/module.py')), '# after source',[Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllBytes((Join-Path $candidate ($cacheRoot+'/scripts/__pycache__/new.pyc')),[byte[]]@(0,200))
                Copy-WorkflowManagedDirectory -SourceRoot $candidate -RelativePath $cacheRoot
                & git -C $Root add -A -- $cacheRoot
                $LASTEXITCODE | Should -Be 0
            }
            if ($MetadataCachedPackage) {
                [IO.File]::SetLastWriteTimeUtc((Join-Path $Root 'AGENT-INSTALL.md'), $packageTime)
            }
            if ($PendingInterruption) {
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase copy-complete
                Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-running
            }
            [IO.File]::WriteAllText((Join-Path $Root '.dev.env'), "CAVEMAN=auto`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/mcp/client-managed.json'), '{"owners":{"new":"keep"}}', [Text.UTF8Encoding]::new($false))
            if ($PendingInterruption) {
                return [pscustomobject]@{ id=(Split-Path -Leaf $snapshot.root).Substring('itl-workflow-update-rollback-'.Length); retained=$snapshot.root }
            }
            if ($MetadataCachedPackage) {
                # Fully read the setup's new bytes once; the rollback owner
                # must later detect the restored old bytes on its own.
                & git -C $Root add --renormalize -- AGENT-INSTALL.md
            } else {
                & git -C $Root add -- AGENT-INSTALL.md
            }
            & git -C $Root commit -qm update
            $LASTEXITCODE | Should -Be 0
            Save-WorkflowUpdateSnapshotReceipt -Snapshot $snapshot -Source $source -Phase post-copy-complete
            $retained = Retain-WorkflowUpdateRollbackSnapshot -Snapshot $snapshot
            [pscustomobject]@{ id=(Split-Path -Leaf $retained).Substring('itl-workflow-update-completed-'.Length); retained=$retained }
        }
        return [pscustomobject]@{ root=$Root; id=$saved.id; retained=$saved.retained; beforeHead=$beforeHead; updateHead=(& git -C $Root rev-parse HEAD).Trim() }
    }

    function Set-RollbackSourceFixture {
        Mock Resolve-WorkflowPackageSource { [pscustomobject]@{ root=$repoRoot; commit=('b' * 40); ref='master'; repo='fixture'; source='path' } }
        Mock Assert-WorkflowUpdateRecordedSource {}
    }

    function Write-ReconciliationDecisionFixture {
        param([object]$Status, [string]$Path)
        $report = Get-Content -LiteralPath $Status.reportPath -Raw | ConvertFrom-Json
        $decision = @{ schemaVersion=1; reportPath=$Status.reportPath; reportSha256=$Status.reportSha256; paths=@($report.paths | ForEach-Object {
            @{relativePath=$_.relativePath; observedState=$_.observedState; decision='resume-confirmed-helper-output'; reason='Fixture interrupted dotenv and client owner outputs exactly match their expected candidate bytes.'}
        }) }
        [IO.File]::WriteAllText($Path, ($decision | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    }


        function New-FinalizationFixture {
            param([string]$Root, [switch]$BusinessConflict, [switch]$PackageCache)
            $utf8=[Text.UTF8Encoding]::new($false)
            New-Item -ItemType Directory -Force -Path (Join-Path $Root '.agent-1c'),(Join-Path $Root 'src/cf') | Out-Null
            [IO.File]::WriteAllText((Join-Path $Root '.gitignore'),".agent-1c/tmp/`n.agent-1c/snapshots/`n",$utf8)
            [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/project.json'),'{"aiRules":{"tools":["codex"]}}',$utf8)
            [IO.File]::WriteAllText((Join-Path $Root '.agent-1c/dependency-lock.json'),'{"schemaVersion":1,"dependencies":{}}',$utf8)
            [IO.File]::WriteAllText((Join-Path $Root 'AGENT-INSTALL.md'),"same package`n",$utf8)
            [IO.File]::WriteAllText((Join-Path $Root 'README.md'),"known readme`r`n",$utf8)
            [IO.File]::WriteAllText((Join-Path $Root 'DEVELOPER-GUIDE.ru.md'),"known guide`r`n",$utf8)
            [IO.File]::WriteAllText((Join-Path $Root 'VANESSA-TESTS-GUIDE.md'),'custom user document',$utf8)
            [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Модуль.bsl'),'base',$utf8)
            [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Другой модуль.bsl'),'baseline',$utf8)
            $known=@{ 'README.md'=@((Get-FileHash (Join-Path $Root 'README.md')).Hash); 'DEVELOPER-GUIDE.ru.md'=@((Get-FileHash (Join-Path $Root 'DEVELOPER-GUIDE.ru.md')).Hash); 'VANESSA-TESTS-GUIDE.md'=@('0'*64) }
            if ($PackageCache) {
                $package = Join-Path $Root '.agents/skills/itl-remote-runner/scripts'
                New-Item -ItemType Directory -Force -Path (Join-Path $package '__pycache__') | Out-Null
                [IO.File]::WriteAllText((Join-Path $package 'module.py'), "# original source`r`n", $utf8)
                [IO.File]::WriteAllBytes((Join-Path $package '__pycache__/module.cpython-313.pyc'), [byte[]]@(0,255,13,10,44))
            }
            & git -C $Root init -q -b itldev/finalize;$LASTEXITCODE|Should -Be 0
            & git -C $Root config user.name 'Finalization fixture';$LASTEXITCODE|Should -Be 0
            & git -C $Root config user.email 'finalize@example.invalid';$LASTEXITCODE|Should -Be 0
            & git -C $Root config core.autocrlf true;$LASTEXITCODE|Should -Be 0
            & git -C $Root add --all;$LASTEXITCODE|Should -Be 0
            & git -C $Root commit -qm baseline;$LASTEXITCODE|Should -Be 0
            if($BusinessConflict){
                & git -C $Root checkout -qb other;$LASTEXITCODE|Should -Be 0
                [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Модуль.bsl'),'other',$utf8)
                & git -C $Root commit -qam other;$LASTEXITCODE|Should -Be 0
                & git -C $Root checkout -q itldev/finalize;$LASTEXITCODE|Should -Be 0
                [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Модуль.bsl'),'current',$utf8)
                & git -C $Root commit -qam current;$LASTEXITCODE|Should -Be 0
                & git -C $Root merge --no-edit other *> $null;$LASTEXITCODE|Should -Be 1
            }
            [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Другой модуль.bsl'),'staged business',$utf8)
            & git -C $Root add -- 'src/cf/Другой модуль.bsl';$LASTEXITCODE|Should -Be 0
            [IO.File]::WriteAllText((Join-Path $Root 'src/cf/Другой модуль.bsl'),'unstaged business',$utf8)
            [pscustomobject]@{root=$Root;known=$known}
        }
