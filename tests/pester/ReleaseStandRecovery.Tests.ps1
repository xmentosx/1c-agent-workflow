Describe 'Release stand recovery cutover' {
    BeforeAll {
        $script:SourceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:RecoveryScript = Join-Path $script:SourceRoot 'scripts\rebuild-release-e2e-stand.ps1'
        . (Join-Path $script:SourceRoot 'scripts/git-path-list.ps1')
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:SourceRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.client-adapters.ps1'),[ref]$tokens,[ref]$errors)
        if($errors){throw 'Client owner source must parse'}
        $owners=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-ItlActiveClient'},$false))
        if($owners.Count -ne 1){throw 'Expected exactly one authoritative client selector'}
        $script:ClientOwnerDefinition=$owners[0].Extent.Text
    }
    It 'keeps the damaged stand and checkpoint with <Selection> client selection' -ForEach @(
        @{Selection='omitted';Client='';Reject=$false},
        @{Selection='explicit attached kilocode';Client='kilocode';Reject=$false},
        @{Selection='explicit unattached codex';Client='codex';Reject=$true}
    ) {
        $root = Join-Path $TestDrive ('release recovery путь '+$Selection)
        $project = Join-Path $root 'project'
        $old = Join-Path $root 'old branch'
        $fixture = Join-Path $root 'fixture branch'
        $target = Join-Path $root 'new branch'
        New-Item -ItemType Directory -Force -Path $project | Out-Null
        & git -C $project init -b master | Out-Null
        & git -C $project config user.email tests@example.invalid
        & git -C $project config user.name Tests
        $marker = Join-Path $project 'tests\features\workflow-release-e2e.feature'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $marker) | Out-Null
        [IO.File]::WriteAllText($marker, "# fixture`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project '.gitignore'), ".agent-1c/runs/`n.agent-1c/dev-branches/`n.agent-1c/release-e2e.json`n", [Text.UTF8Encoding]::new($false))
        $projectConfig = Join-Path $project '.agent-1c/project.json'
        $manifest = Join-Path $project '.ai-rules.json'
        $clientConfig = Join-Path $project '.kilo/kilo.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $projectConfig),(Split-Path -Parent $clientConfig) | Out-Null
        [IO.File]::WriteAllText($projectConfig,'{"aiRules":{"tools":["kilocode"]}}',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($manifest,'{"tools":["kilocode"]}',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($clientConfig,'{"mcpServers":{"user-server":{"url":"http://localhost:12345/mcp"}}}',[Text.UTF8Encoding]::new($false))
        $helper = Join-Path $project '.agents\skills\1c-workflow\scripts\run-itl-command.ps1'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $helper) | Out-Null
        $captureAndProviders = @'
$forwarded=@($args|ForEach-Object{[string]$_})
$runRoot=Join-Path (Get-Location).Path '.agent-1c/runs'
New-Item -ItemType Directory -Force -Path $runRoot|Out-Null
[IO.File]::WriteAllText((Join-Path $runRoot 'recovery-helper-arguments.json'),(ConvertTo-Json -InputObject $forwarded),[Text.UTF8Encoding]::new($false))
function Get-AgentTargets {@((Get-Content -Raw -LiteralPath (Join-Path (Get-Location).Path '.agent-1c/project.json')|ConvertFrom-Json).aiRules.tools)}
function Get-AiRules1cProjectManifest {Get-Content -Raw -LiteralPath (Join-Path (Get-Location).Path '.ai-rules.json')|ConvertFrom-Json}
function Get-AiRules1cManifestToolNames {param($Manifest) @($Manifest.tools)}
function Get-InitAgentExecutionEnvironment {@{CODEX_THREAD_ID='fixture ambient codex'}}
function Resolve-InitAgentTargetFromExecutionContext {param($Environment,$ProcessChain) 'codex'}
function Get-InitAgentExecutionProcessChain {@()}
'@
        $fakeFork = @'
$clientIndex=[Array]::IndexOf($forwarded,'-AgentTarget')
if($clientIndex -ge 0){
    $AgentTarget=$forwarded[$clientIndex+1]
    Get-ItlActiveClient|Out-Null
}
$destination = $env:ITL_TEST_RECOVERY_TARGET_ROOT
& git -C (Get-Location).Path worktree add --quiet -b itldev/rebuilt $destination HEAD
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$state = Join-Path $destination '.agent-1c\dev-branches\rebuilt.json'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $state) | Out-Null
[IO.File]::WriteAllText($state, '{"unsafeActionProtectionConfirmed":true}', [Text.UTF8Encoding]::new($false))
'@
        $fakeHelper=$captureAndProviders+"`n"+$script:ClientOwnerDefinition+"`n"+$fakeFork
        [IO.File]::WriteAllText($helper, $fakeHelper, [Text.UTF8Encoding]::new($true))
        & git -C $project add -- .
        & git -C $project commit -m fixture | Out-Null
        & git -C $project worktree add --quiet -b itldev/old $old master
        & git -C $project worktree add --quiet -b itldev/fixture $fixture master
        $configPath = Join-Path $project '.agent-1c\release-e2e.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $configPath) | Out-Null
        $original = [ordered]@{ schemaVersion=1; devBranchName='old'; worktreePath=$old; developWorktreePath='preserved' }
        [IO.File]::WriteAllText($configPath, ($original | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $checkpoint = Join-Path $old '.agent-1c\runs\release-e2e\old\checkpoint.json'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $checkpoint) | Out-Null
        [IO.File]::WriteAllText($checkpoint, '{"damaged":true}', [Text.UTF8Encoding]::new($false))
        $previousTarget=[Environment]::GetEnvironmentVariable('ITL_TEST_RECOVERY_TARGET_ROOT','Process')
        $env:ITL_TEST_RECOVERY_TARGET_ROOT = $target
        $options=@{E2EProjectRoot=$project;FixtureWorktree=$fixture;NewDevBranchName='rebuilt'}
        if($Client){$options.AgentTarget=$Client}
        $configHash=(Get-FileHash -LiteralPath $configPath).Hash
        $protected=@(foreach($scope in @($project,$fixture)){foreach($relative in @('.agent-1c/project.json','.ai-rules.json','.kilo/kilo.json')){$path=Join-Path $scope $relative;[pscustomobject]@{path=$path;sha256=(Get-FileHash -LiteralPath $path).Hash}}})
        try {
            $dirtyPath=Join-Path $fixture 'Незакоммиченный файл с пробелом.txt'
            [IO.File]::WriteAllText($dirtyPath,'user work',[Text.UTF8Encoding]::new($false))
            { & $script:RecoveryScript @options }|Should -Throw '*Fixture worktree has changes*'
            (Get-FileHash -LiteralPath $configPath).Hash|Should -BeExactly $configHash
            Test-Path -LiteralPath $target|Should -BeFalse
            Remove-Item -LiteralPath $dirtyPath
            $fixtureCheckpoint = Join-Path $fixture '.agent-1c\runs\release-e2e\fixture\checkpoint.json'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fixtureCheckpoint) | Out-Null
            [IO.File]::WriteAllText($fixtureCheckpoint, '{"unsafe":true}', [Text.UTF8Encoding]::new($false))
            { & $script:RecoveryScript @options }|Should -Throw '*Fixture source has a Release checkpoint*'
            (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json).worktreePath | Should -Be $old
            Test-Path -LiteralPath $target | Should -BeFalse
            Remove-Item -LiteralPath $fixtureCheckpoint -Force
            if($Reject){
                { & $script:RecoveryScript @options }|Should -Throw "*ITL_CLIENT_NOT_ATTACHED: 'codex'*"
                (Get-FileHash -LiteralPath $configPath).Hash|Should -BeExactly $configHash
                (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8|ConvertFrom-Json).worktreePath|Should -BeExactly $old
                Test-Path -LiteralPath $target|Should -BeFalse
                @(Get-RepositoryGitPathList -RepositoryRoot $project -Arguments @('worktree','list','--porcelain','-z'))|Should -Not -Contain 'branch refs/heads/itldev/rebuilt'
                Test-Path (Join-Path $project '.agent-1c/runs/release-e2e-stand-recovery')|Should -BeFalse
            }else{
                $result = & $script:RecoveryScript @options
                $result.status | Should -Be 'recovered'
                $newConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $newConfig.devBranchName | Should -Be 'rebuilt'
                $newConfig.worktreePath | Should -Be $target
                $newConfig.developWorktreePath | Should -Be 'preserved'
                (Get-Content -LiteralPath $result.configBackup -Raw -Encoding UTF8 | ConvertFrom-Json).worktreePath | Should -Be $old
                (Get-FileHash -LiteralPath $result.configBackup).Hash|Should -BeExactly $configHash
                $result.configBackup | Should -Match '[\\/]\.agent-1c[\\/]runs[\\/]release-e2e-stand-recovery[\\/]'
            }
            @(Get-RepositoryGitPathList -RepositoryRoot $project -Arguments @('status','--porcelain','--untracked-files=all','-z')).Count|Should -Be 0
            $received=Get-Content -Raw -LiteralPath (Join-Path $fixture '.agent-1c/runs/recovery-helper-arguments.json') -Encoding UTF8|ConvertFrom-Json
            @($received|Where-Object{$_ -ceq '-AgentTarget'}).Count|Should -Be $(if($Client){1}else{0})
            if($Client){$received[[Array]::IndexOf($received,'-AgentTarget')+1]|Should -BeExactly $Client}
            @($received|Where-Object{$_ -ceq '-Action'}).Count|Should -Be 1
            $received[[Array]::IndexOf($received,'-Action')+1]|Should -BeExactly 'fork-dev-branch'
            @($received|Where-Object{$_ -ceq '-DevBranchName'}).Count|Should -Be 1
            $received[[Array]::IndexOf($received,'-DevBranchName')+1]|Should -BeExactly 'rebuilt'
            foreach($file in $protected){(Get-FileHash -LiteralPath $file.path).Hash|Should -BeExactly $file.sha256}
            Test-Path -LiteralPath $checkpoint -PathType Leaf | Should -BeTrue
            (Get-Content -LiteralPath $checkpoint -Raw -Encoding UTF8) | Should -Be '{"damaged":true}'
        } finally {
            [Environment]::SetEnvironmentVariable('ITL_TEST_RECOVERY_TARGET_ROOT',$previousTarget,'Process')
            foreach ($path in @($target, $fixture, $old)) {
                if (Test-Path -LiteralPath $path) { & git -C $project worktree remove --force $path 2>$null | Out-Null }
            }
        }
    }
}