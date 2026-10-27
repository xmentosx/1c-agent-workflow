BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1');$RepoRoot=(Initialize-WorkflowPesterContext).RepoRoot
    . (Join-Path $RepoRoot 'scripts/git-path-list.ps1');. (Join-Path $RepoRoot 'scripts/quality-contracts.ps1');. (Join-Path $RepoRoot 'scripts/develop-e2e-qualification.ps1')
}
Describe 'Optional artifact protection consumers' {
    It 'retains a closed reader inventory and the audited optional native caller' {
        $callers=@()
        foreach($path in @(Get-RepositoryGitPathList $RepoRoot @('ls-files','-z','--','.agents/skills/1c-workflow/scripts'))|Where-Object {$_ -like '*.ps1'}) {
            $text=[IO.File]::ReadAllText((Join-Path $RepoRoot $path));if($text -notmatch 'Get-ItlArtifactProtectedPaths'){continue}
            $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($text.TrimStart([char]0xfeff),[ref]$t,[ref]$e)
            foreach($command in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Get-ItlArtifactProtectedPaths'},$true))) {
                $owner=$command.Parent;while($owner -and $owner -isnot [Management.Automation.Language.FunctionDefinitionAst]){$owner=$owner.Parent}
                $callers+=($path+':'+$(if($owner){$owner.Name}else{'<entrypoint>'}))
            }
        }
        @($callers|Sort-Object -Unique)|Should -Be @('.agents/skills/1c-workflow/scripts/agent-1c.ps1:<entrypoint>','.agents/skills/1c-workflow/scripts/lib/agent-1c.artifact-retention.ps1:Get-ItlArtifactCleanupPlan','.agents/skills/1c-workflow/scripts/lib/agent-1c.diagnostic-retention.ps1:Remove-ItlDiagnosticArtifact')
        Get-DevelopArtifactProtectionProjection '' $RepoRoot -ProbeOnly|Should -BeTrue
    }
    It 'enrolls manifests only through explicit producers and keeps native callers closed' {
        $module='.agents/skills/1c-workflow/scripts/lib/agent-1c.diagnostic-retention.ps1'
        $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $module),[ref]$t,[ref]$e)
        $names=@($ast.EndBlock.Statements|ForEach-Object Name);$outside=@();$completion=@();$homes=@()
        foreach($path in @(Get-RepositoryGitPathList $RepoRoot @('ls-files','-z','--','.agents/skills'))|Where-Object {$_ -match '\.(ps1|py)$'}) {
            $text=[IO.File]::ReadAllText((Join-Path $RepoRoot $path))
            if($text.Contains('DiagnosticCompletionPath')) {$completion+=$path}
            if($text.Contains('diagnostic-artifacts')) {$homes+=$path}
            if($path -ceq $module -or $path -notlike '*.ps1' -or $text -notmatch 'ItlDiagnostic'){continue}
            $ast=[Management.Automation.Language.Parser]::ParseInput($text.TrimStart([char]0xfeff),[ref]$t,[ref]$e)
            foreach($command in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true))) {
                if($command.GetCommandName() -notin $names){continue}
                $owner=$command.Parent;while($owner -and $owner -isnot [Management.Automation.Language.FunctionDefinitionAst]){$owner=$owner.Parent}
                $outside+=($path+':'+$(if($owner){$owner.Name}else{'<entrypoint>'})+':'+$command.GetCommandName())
            }
        }
        @($outside|Sort-Object -Unique)|Should -Be @('.agents/skills/1c-workflow/scripts/agent-1c.ps1:<entrypoint>:Complete-ItlDiagnosticArtifacts','.agents/skills/1c-workflow/scripts/agent-1c.ps1:<entrypoint>:Invoke-ItlDiagnosticArtifactCleanup','.agents/skills/1c-workflow/scripts/lib/agent-1c.artifact-retention.ps1:Get-ItlArtifactCleanupPlan:Get-ItlDiagnosticArtifactPlan','.agents/skills/1c-workflow/scripts/lib/agent-1c.artifact-retention.ps1:Invoke-ItlArtifactCleanup:Remove-ItlDiagnosticArtifact')
        @($completion|Sort-Object -Unique)|Should -Be @('.agents/skills/1c-workflow/scripts/agent-1c.ps1','.agents/skills/itl-remote-runner/scripts/itl_remote/diagnostic_retention.py')
        @($homes|Sort-Object -Unique)|Should -Be @($module)
    }
}