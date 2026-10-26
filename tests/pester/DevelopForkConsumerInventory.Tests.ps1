BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context=Initialize-WorkflowPesterContext;$RepoRoot=$context.RepoRoot
    . (Join-Path $RepoRoot 'scripts/develop-e2e-qualification.ps1')
}
Describe 'Closed native consumers of controlled-fork guidance' {
    It 'keeps every runtime rule reader under the audited input contract' {
        $profile=Get-AiRulesNativeGuidanceConsumers
        $profile|Should -Not -BeNullOrEmpty
        $seen=@()
        foreach($path in @(Get-RepositoryGitPathList $RepoRoot @('ls-files','-z','--','.agents/skills/1c-workflow/scripts'))) {
            $full=Join-Path $RepoRoot $path
            $text=[IO.File]::ReadAllText($full)
            if($text -notmatch 'content[\\/]rules(?:[\\/]|\b)') {continue}
            $path|Should -BeExactly '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1'
            $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($full,[ref]$tokens,[ref]$errors)
            @($errors)|Should -BeNullOrEmpty
            foreach($literal in @($ast.FindAll({param($n)($n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and $n.Value -match 'content[\\/]rules(?:[\\/]|\b)'},$true))) {
                $parent=$literal.Parent
                while($parent -and $parent -isnot [Management.Automation.Language.FunctionDefinitionAst]) {$parent=$parent.Parent}
                $parent|Should -Not -BeNullOrEmpty
                $parent.Name|Should -BeIn @($profile.readers.Keys)
                $literal.Value|Should -BeIn @('content/rules/dev-standards-env.md','content/rules/sdd-integrations.md')
                $seen+=@($parent.Name)
            }
        }
        @($seen|Sort-Object -Unique)|Should -Be @($profile.readers.Keys|Sort-Object)
    }
}
