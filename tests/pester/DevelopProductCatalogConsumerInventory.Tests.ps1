BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1');$RepoRoot=(Initialize-WorkflowPesterContext).RepoRoot
    . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
}
Describe 'Product catalog validation consumers' {
    It 'keeps catalog validation behind the audited product entrypoints' {
        $names=@('Assert-ItlProductCatalog','Read-ItlProductCatalogSnapshot','Resolve-ItlProductContext','Resolve-ItlProductKnowledge')
        $callers=@()
        foreach($path in @(Get-RepositoryGitPathList $RepoRoot @('ls-files','-z','--','.agents/skills','scripts','install-agent-1c-workflow.ps1'))|Where-Object {$_ -like '*.ps1'}) {
            $text=[IO.File]::ReadAllText((Join-Path $RepoRoot $path));if($text -notmatch 'Assert-ItlProductCatalog|Read-ItlProductCatalogSnapshot|Resolve-ItlProductContext|Resolve-ItlProductKnowledge'){continue}
            $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($text.TrimStart([char]0xfeff),[ref]$t,[ref]$e)
            @($e)|Should -BeNullOrEmpty
            foreach($command in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true))) {
                if($command.GetCommandName() -cnotin $names){continue}
                $owner=$command.Parent;while($owner -and $owner -isnot [Management.Automation.Language.FunctionDefinitionAst]){$owner=$owner.Parent}
                $callers+=($path+':'+$(if($owner){$owner.Name}else{'<entrypoint>'})+':'+$command.GetCommandName())
            }
        }
        $expected=@(
            '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-catalog.ps1:Read-ItlProductCatalogSnapshot:Assert-ItlProductCatalog',
            '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-catalog.ps1:Resolve-ItlProductContext:Assert-ItlProductCatalog',
            '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-catalog.ps1:Resolve-ItlProductKnowledge:Assert-ItlProductCatalog',
            '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-project-context.ps1:Get-ItlProductProjectEffectiveSnapshot:Assert-ItlProductCatalog',
            '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-project-context.ps1:Read-ItlProductProjectSnapshot:Read-ItlProductCatalogSnapshot',
            '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-project-context.ps1:Resolve-ItlProductProjectRuntimeContext:Resolve-ItlProductContext',
            '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-project-context.ps1:Set-ItlProductProjectAppliedContext:Read-ItlProductCatalogSnapshot',
            '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-project-ui.ps1:Save-ItlProductProjectDraft:Assert-ItlProductCatalog',
            '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-project.ps1:Save-ItlCatalogRecord:Assert-ItlProductCatalog',
            '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-project.ps1:Save-ItlCatalogRecord:Read-ItlProductCatalogSnapshot',
            '.agents/skills/1c-workflow/scripts/lib/agent-1c.vibecoding1c-mcp.ps1:Read-Vibecoding1cProductContext:Read-ItlProductCatalogSnapshot',
            '.agents/skills/1c-workflow/scripts/lib/agent-1c.vibecoding1c-mcp.ps1:Read-Vibecoding1cProductContext:Resolve-ItlProductContext'
        )
        @($callers|Sort-Object -Unique)|Should -Be @($expected|Sort-Object -Unique)
    }
}
