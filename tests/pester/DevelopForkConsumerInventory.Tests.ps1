BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context=Initialize-WorkflowPesterContext;$RepoRoot=$context.RepoRoot
    . (Join-Path $RepoRoot 'scripts/develop-e2e-qualification.ps1')
    function Get-ProjectedForkReaderLiterals($Ast,$Profile) {
        foreach($literal in @($Ast.FindAll({param($n)($n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and $n.Value -match 'content[\\/]rules(?:[\\/]|\b)'},$true))) {
            $relative=$literal.Value.Replace('\','/')
            # Fixed other rule files remain byte-exact in the complete fork
            # inventory. Dynamic/directory reads can reach projected guidance.
            if($literal -is [Management.Automation.Language.StringConstantExpressionAst] -and
                $relative -match '^content/rules/[^/]+\.md$' -and $relative -notin @($Profile.paths)) {continue}
            $literal
        }
    }
}
Describe 'Closed native consumers of controlled-fork guidance' {
    It 'keeps projected aliases and dynamic readers audited while other fixed rules stay byte exact' {
        $sample=@'
function Read-Other {'content/rules/project-memory.md'}
function Read-Projected {'content/rules/Verification-Policy.md'}
function Read-Dynamic {"content/rules/$Name.md"}
function Read-Directory {'content/rules'}
'@
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($sample,[ref]$tokens,[ref]$errors)
        $items=@(Get-ProjectedForkReaderLiterals $ast (Get-AiRulesNativeGuidanceConsumers))
        $items.Count|Should -Be 3
        @($items.Value)|Should -Not -Contain 'content/rules/project-memory.md'
        @($items.Value)|Should -Contain 'content/rules/Verification-Policy.md'
        @($items.Value)|Should -Contain 'content/rules/$Name.md'
        @($items.Value)|Should -Contain 'content/rules'
    }
    It 'binds the imported fork policy only to its Pester consumers and static continuation scope' {
        $catalog=Get-QualityContractCatalog $RepoRoot
        @($catalog.continuationScopes.gate)|Should -Contain 'scripts/ai-rules-native-inputs.ps1'
        $imports=@('scripts/develop-e2e-qualification.ps1','scripts/develop-e2e-scenarios.ps1','tests/pester/SourceDeliveryPlan.TestSupport.ps1','tests/pester/SourceDeliveryIncremental.TestSupport.ps1')
        foreach($owner in $catalog.contracts) {
            $patterns=@($owner.paths)+@(Get-QualityContractReuseInputPaths $owner)
            if(@($patterns|Where-Object {$_ -in $imports}).Count) {
                @($patterns|Where-Object {'scripts/ai-rules-native-inputs.ps1' -like $_}).Count|Should -BeGreaterThan 0 -Because $owner.id
            }
        }
    }
    It 'compares live dictionary fork bindings with serialized proof without inventing a transition' {
        $live=[pscustomobject]@{inventory=@{external=[ordered]@{rulesCommit='a'*40;rulesTree='b'*40}}}
        $saved=$live|ConvertTo-Json -Depth 6|ConvertFrom-Json
        Test-DevelopForkIdentityChanged $saved $live|Should -BeFalse
        Test-DevelopForkIdentityChanged $live $saved|Should -BeFalse
        $legacy=[pscustomobject]@{inventory=@{external=@{complete=$true}}}
        Test-DevelopForkIdentityChanged $legacy ($legacy|ConvertTo-Json -Depth 6|ConvertFrom-Json)|Should -BeFalse
        Test-DevelopForkIdentityChanged $legacy $live|Should -BeTrue
        Test-DevelopForkIdentityChanged $saved $legacy|Should -BeTrue
        $live.inventory.external.rulesTree='c'*40
        Test-DevelopForkIdentityChanged $saved $live|Should -BeTrue
    }
    It 'keeps every runtime reader of projected guidance under the audited input contract' {
        $profile=Get-AiRulesNativeGuidanceConsumers
        $profile|Should -Not -BeNullOrEmpty
        $seen=@()
        foreach($path in @(Get-RepositoryGitPathList $RepoRoot @('ls-files','-z','--','.agents/skills/1c-workflow/scripts'))) {
            $full=Join-Path $RepoRoot $path
            $text=[IO.File]::ReadAllText($full)
            if($text -notmatch 'content[\\/]rules(?:[\\/]|\b)') {continue}
            $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($full,[ref]$tokens,[ref]$errors)
            @($errors)|Should -BeNullOrEmpty
            foreach($literal in @(Get-ProjectedForkReaderLiterals $ast $profile)) {
                $path|Should -BeExactly '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1'
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
