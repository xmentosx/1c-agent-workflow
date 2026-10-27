BeforeAll { . (Join-Path $PSScriptRoot 'SourceDeliveryIncremental.TestSupport.ps1') }
Describe 'Develop additive artifact protection' {
    AfterEach { Exit-DeliveryPlanFixtureEnvironment -Snapshot $script:deliveryPlanFixtureEnvironment }
    BeforeEach { $script:deliveryPlanFixtureEnvironment=Enter-DeliveryPlanFixtureEnvironment }
    It 'reuses authenticated fresh proof for additive protection and preserves destructive and caller guards' {
        Mock Get-DevelopE2EStandStateSha256 {'c'*64}
        $f=New-ScenarioPlanFixture;$script:Root=$f.root
        Mock Get-Command {[pscustomobject]@{Source=$f.artifact}} -ParameterFilter {$Name -contains 'go.exe'}
        $relative='.agents/skills/1c-workflow/scripts/lib/agent-1c.artifact-retention.ps1'
        foreach($path in @($relative,'install-agent-1c-workflow.ps1','.agents/skills/1c-workflow/scripts/agent-1c.ps1')) {
            $target=Join-Path $f.root $path;[void][IO.Directory]::CreateDirectory((Split-Path $target));Copy-Item (Join-Path $RepoRoot $path) $target
            $f.catalog.contracts[0].paths+=@($path)
        }
        $file=Join-Path $f.root $relative;$current=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($file))
        $first=$current.IndexOf('    [void]$paths.Add((Join-Path $ProjectRoot ''.agent-1c/verification-selection/changes''))');$last=$current.IndexOf('    return $paths',$first)
        $first|Should -BeGreaterThan -1;$last|Should -BeGreaterThan $first
        $before=$current.Remove($first,$last-$first)
        [IO.File]::WriteAllText($file,$before,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $f.root 'tests/quality-contracts.json'),($f.catalog|ConvertTo-Json -Depth 24))
        & git -C $f.root add --all;& git -C $f.root commit --quiet -m 'original protection before current task receipts'
        $f.base=(& git -C $f.root rev-parse HEAD).Trim();Save-IncrementalJourneyProofs $f
        $old=Get-DevelopE2EInputIdentity $f.root fresh $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
        [IO.File]::WriteAllText($file,$current,[Text.UTF8Encoding]::new($false))
        & git -C $f.root add --all;& git -C $f.root commit --quiet -m 'protect active plan requirements and history'
        $tree=(& git -C $f.root rev-parse 'HEAD^{tree}').Trim();$now=Get-DevelopE2EInputIdentity $f.root fresh $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding
        $records=@(Get-DevelopScenarioReusePlan $f.root $tree fresh $now $f.catalog -AllowPendingStatic)
        @($records|Where-Object execution -eq reuse|ForEach-Object id)|Should -Be @('stale-export','close') -Because ($records|Select-Object id,execution,reuseDiagnostics|ConvertTo-Json -Depth 5 -Compress)
        @($records|Where-Object execution -eq setup|ForEach-Object id)|Should -Be @('verification')
        @($records|Where-Object execution -eq execute|ForEach-Object id)|Should -Be @('install','branch','refresh')
        foreach($scenario in @('verification','stale-export','close')) {Test-DevelopScenarioEquivalentInput $f.root $old $now $f.base @($scenario) $f.catalog|Should -BeTrue}
        foreach($scenario in @('install','branch','refresh','future')) {Test-DevelopScenarioEquivalentInput $f.root $old $now $f.base @($scenario) $f.catalog|Should -BeFalse}
        $agent=Join-Path $f.root '.agents/skills/1c-workflow/scripts/agent-1c.ps1';$agentBytes=[IO.File]::ReadAllBytes($agent)
        $runner=Join-Path $f.root 'scripts/invoke-develop-e2e.ps1';$runnerBytes=[IO.File]::ReadAllBytes($runner)
        foreach($case in @('destructive-block','path-policy','old-protection','deletion-policy','unknown-function','top-level','ambient-use','mandatory-cleanup','runner','historical-sha')) {
            $changed=switch($case) {
                'destructive-block' {$current.Replace('$change=Read-Utf8Text -Path $changePath',"Remove-Item -LiteralPath `$changePath; `$change=Read-Utf8Text -Path `$changePath")}
                'path-policy' {$current.Replace("throw 'change evidence escaped the project'","Write-Warning 'escaped'")}
                'old-protection' {$current.Replace("'lastResultPath', 'lastResultManifestPath'","'changedPath', 'lastResultManifestPath'")}
                'deletion-policy' {$current.Replace('Where-Object delete','Where-Object { $true }')}
                'unknown-function' {$current+"`nfunction Unknown-Protection { 'new' }`n"}
                'top-level' {$current+"`nWrite-Output 'new side effect'`n"}
                'ambient-use' {$current.Replace('    return $paths',"    Write-Output `$changePath`n    return `$paths")}
                default {$current}
            }
            [IO.File]::WriteAllText($file,$changed,[Text.UTF8Encoding]::new($false))
            if($case -eq 'mandatory-cleanup'){[IO.File]::WriteAllText($agent,[Text.Encoding]::UTF8.GetString($agentBytes).Replace('catch { Write-Warning "ITL artifact cleanup skipped: $($_.Exception.Message)" }','catch { throw }'),[Text.UTF8Encoding]::new($false))}
            if($case -eq 'mandatory-cleanup'){Get-DevelopArtifactProtectionProjection '' $f.root -ProbeOnly|Should -BeNullOrEmpty}
            if($case -eq 'runner'){[IO.File]::AppendAllText($runner,"`nWrite-Verbose 'new explicit cleanup route'`n")}
            $after=Get-DevelopE2EInputIdentity $f.root fresh $f.catalog $f.stand $f.rules kilocode -ArtifactBinding $f.binding;$prior=$old|ConvertTo-Json -Depth 32|ConvertFrom-Json
            if($case -eq 'historical-sha'){($prior.inventory.inputs|Where-Object path -eq $relative).sha256='e'*64;$prior.fingerprint=Get-DevelopE2ECanonicalJsonSha256 $prior.inventory}
            Test-DevelopScenarioEquivalentInput $f.root $prior $after $f.base @('verification') $f.catalog|Should -BeFalse -Because $case
            [IO.File]::WriteAllBytes($agent,$agentBytes);[IO.File]::WriteAllBytes($runner,$runnerBytes)
        }
    }
    It 'retains exact source when protection removes a previous guarantee or the journey is not eligible' {
        $source=[IO.File]::ReadAllText((Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.artifact-retention.ps1'));$unsafe=$source.Replace('[void]$paths.Add($full)','[void]$paths.Remove($full)')
        (Get-DevelopArtifactProtectionProjection $source $RepoRoot)|Should -Not -BeExactly (Get-DevelopArtifactProtectionProjection $unsafe $RepoRoot)
        Get-DevelopScenarioSourceProjection -Path '.agents/skills/1c-workflow/scripts/lib/agent-1c.artifact-retention.ps1' -Text $source -Journey upgrade -Scenario @('update') -Catalog (Get-QualityContractCatalog $RepoRoot) -RepositoryRoot $RepoRoot|Should -BeNullOrEmpty
    }
}