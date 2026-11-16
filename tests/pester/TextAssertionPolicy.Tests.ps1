BeforeAll {
    Set-StrictMode -Version Latest
    $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $script:BaselinePath = Join-Path $RepoRoot 'tests/text-assertion-baseline.json'

    # A wording pattern names four or more words outside code spans, regex
    # escapes and file names. Identifiers such as `-RequireRelease`,
    # `PublishDevelop` or `docs/x.md` are stable contracts and are not counted.
    function Get-TextAssertionWordCount {
        param([string]$Pattern)
        $plain = $Pattern -replace '`[^`]*`', ' ' -replace '\S*[/\\]\S*[/\\.]\S*', ' ' -replace '[\w.-]+\.(md|ps1|psm1|json|ya?ml|txt|xml|cs|go|py)\b', ' ' -replace '\\.', ' '
        return [regex]::Matches($plain, '[A-Za-zА-Яа-яЁё]{3,}').Count
    }

    function Get-TextAssertionLiterals {
        param([Management.Automation.Language.Ast]$Expression, [Management.Automation.Language.Ast]$Context)
        $node = $Expression
        while ($node -is [Management.Automation.Language.ParenExpressionAst]) {
            $node = $node.Pipeline
            if ($node -is [Management.Automation.Language.PipelineAst] -and $node.PipelineElements.Count -eq 1 -and
                $node.PipelineElements[0] -is [Management.Automation.Language.CommandExpressionAst]) { $node = $node.PipelineElements[0].Expression }
        }
        if ($node -is [Management.Automation.Language.StringConstantExpressionAst]) { return @($node.Value) }
        if ($node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$node.Member -ceq 'Escape' -and @($node.Arguments).Count -eq 1) {
            return @(Get-TextAssertionLiterals -Expression $node.Arguments[0] -Context $Context)
        }
        if ($node -is [Management.Automation.Language.VariableExpressionAst]) {
            # A loop that feeds literal markers into one assertion counts each marker.
            $name = $node.VariablePath.UserPath
            for ($parent = $Context.Parent; $parent; $parent = $parent.Parent) {
                if ($parent -is [Management.Automation.Language.ForEachStatementAst] -and $parent.Variable.VariablePath.UserPath -ieq $name) {
                    return @($parent.Condition.FindAll({ param($item) $item -is [Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
                }
            }
        }
        return @()
    }

    function Get-WordingAssertions {
        param([string]$Path)
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        foreach ($command in $ast.FindAll({ param($item) $item -is [Management.Automation.Language.CommandAst] -and $item.GetCommandName() -ceq 'Should' }, $true)) {
            $elements = @($command.CommandElements)
            $parameters = @($elements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] } | ForEach-Object { $_.ParameterName })
            # Prohibitions (Should -Not -Match) stay permitted by the policy.
            if ($parameters -notcontains 'Match' -or $parameters -contains 'Not') { continue }
            for ($index = 0; $index -lt $elements.Count; $index++) {
                $element = $elements[$index]
                if ($element -isnot [Management.Automation.Language.CommandParameterAst] -or $element.ParameterName -cne 'Match') { continue }
                $argument = if ($element.Argument) { $element.Argument } elseif ($index + 1 -lt $elements.Count) { $elements[$index + 1] } else { $null }
                if (-not $argument) { break }
                foreach ($literal in @(Get-TextAssertionLiterals -Expression $argument -Context $command)) {
                    if ((Get-TextAssertionWordCount -Pattern $literal) -ge 4) { $literal }
                }
                break
            }
        }
    }
}

Describe 'Source text assertions protect stable contracts' {
    It 'adds no wording assertion to any test file beyond its recorded count' {
        $baseline = (Get-Content -LiteralPath $script:BaselinePath -Raw -Encoding UTF8 | ConvertFrom-Json).files
        $drift = @(foreach ($file in Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tests/pester') -Filter '*.Tests.ps1' | Sort-Object Name) {
            $relative = 'tests/pester/' + $file.Name
            $count = @(Get-WordingAssertions -Path $file.FullName).Count
            $recorded = if ($baseline.PSObject.Properties[$relative]) { [int]$baseline.$relative } else { 0 }
            if ($count -ne $recorded) { "$relative recorded=$recorded actual=$count" }
        })
        foreach ($property in $baseline.PSObject.Properties) {
            if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $property.Name) -PathType Leaf)) { $drift += "$($property.Name) recorded=$($property.Value) file removed" }
        }
        @($drift) | Should -BeNullOrEmpty -Because ('assertions over prose wording break on rewording (openspec spec source-check-derivation). ' +
            'When actual exceeds recorded, assert a stable identifier (code, flag, action, path) or the behavior instead, or a prohibition with Should -Not -Match; never raise the recorded count. ' +
            'When actual is lower, lower the count in tests/text-assertion-baseline.json.')
    }

    It 'counts literal, escaped and loop-fed wording patterns but not identifiers or prohibitions' {
        $fixture = Join-Path $TestDrive 'Wording Проверка.Tests.ps1'
        [IO.File]::WriteAllText($fixture, @'
$text | Should -Match 'Publish only when the user asks'
$text | Should -Match ([regex]::Escape('Repair a failed frozen publication through it'))
foreach ($marker in @('Group related edits before checking them', '`PublishDevelop`')) { $text | Should -Match ([regex]::Escape($marker)) }
$text | Should -Match ([regex]::Escape('`docs/source-publication.md`'))
$text | Should -Match 'scripts/source-delivery.ps1 -Action PublishDevelop'
$text | Should -Match 'tests/pester/beta\.Tests\.ps1 reported failed'
$text | Should -Not -Match 'never keep any obsolete legacy wording'
$text | Should -Match 'Публикуй только по просьбе пользователя'
'@, [Text.UTF8Encoding]::new($true))
        @(Get-WordingAssertions -Path $fixture) | Should -Be @(
            'Publish only when the user asks',
            'Repair a failed frozen publication through it',
            'Group related edits before checking them',
            'Публикуй только по просьбе пользователя')
    }
}
