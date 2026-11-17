BeforeAll {
    Set-StrictMode -Version Latest
    $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')

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
        param([string]$Path, [string]$Text)
        $tokens = $null; $errors = $null
        $ast = if ($PSBoundParameters.ContainsKey('Text')) { [Management.Automation.Language.Parser]::ParseInput($Text.TrimStart([char]0xFEFF), [ref]$tokens, [ref]$errors) } else { [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) }
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
    # Net change of wording assertions between the base commit and the working tree,
    # over test files that differ; unchanged files cannot change the total.
    function Get-WordingAssertionDelta {
        param([Parameter(Mandatory = $true)][string]$BaseCommit, [string]$Root = $RepoRoot)
        $changed = @(@(Get-RepositoryGitPathList -RepositoryRoot $Root -Arguments @('diff', '--name-only', '-z', $BaseCommit, '--', 'tests/pester')) +
            @(Get-RepositoryGitPathList -RepositoryRoot $Root -Arguments @('ls-files', '--others', '--exclude-standard', '-z', '--', 'tests/pester')) |
            Where-Object { $_ -like 'tests/pester/*.Tests.ps1' } | Sort-Object -Unique)
        $added = 0
        $files = @(foreach ($relative in $changed) {
            $path = Join-Path $Root $relative
            $now = if (Test-Path -LiteralPath $path -PathType Leaf) { @(Get-WordingAssertions -Path $path).Count } else { 0 }
            $show = Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @('show', "${BaseCommit}:$relative", '--') -AllowFailure
            $before = if ($show.exitCode -eq 0) { @(Get-WordingAssertions -Path $relative -Text ([string]$show.stdout)).Count } else { 0 }
            $added += ($now - $before)
            if ($now -gt $before) { "$relative base=$before now=$now" }
        })
        return [pscustomobject]@{ added = $added; files = @($files) }
    }}

Describe 'Source text assertions protect stable contracts' {
    It 'adds no wording assertion relative to the registration base' {
        # The rule is enforced as a delta: a change may not add assertions over prose
        # wording. A shared recorded count went stale whenever parallel queue entries
        # met in one candidate (three failures and three count-only commits on
        # 2026-11-16/17); the base is the merge base with published develop instead.
        $baseRef = if ($env:ITL_TEXT_ASSERTION_BASE) { $env:ITL_TEXT_ASSERTION_BASE } else { 'refs/remotes/origin/develop' }
        $base = (Invoke-RepositoryGit -RepositoryRoot $RepoRoot -Arguments @('merge-base', 'HEAD', $baseRef) -AllowFailure)
        if ($base.exitCode -ne 0 -or [string]$base.stdout.Trim() -notmatch '^[0-9a-f]{40}$') {
            Set-ItResult -Skipped -Because "no registration base '$baseRef' is reachable from HEAD"
            return
        }
        $result = Get-WordingAssertionDelta -BaseCommit $base.stdout.Trim()
        $result.added | Should -BeLessOrEqual 0 -Because ('assertions over prose wording break on rewording (openspec spec source-check-derivation). ' +
            "This change adds $($result.added) net: $(@($result.files) -join '; '). Assert a stable identifier (code, flag, action, path) or the behavior instead, or a prohibition with Should -Not -Match.")
    }

    It 'fails a change that adds a wording assertion and tolerates moving one between files' {
        $root = Join-Path $TestDrive 'Политика формулировок'
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'tests/pester'))
        & git -C $root init -q
        [IO.File]::WriteAllText((Join-Path $root 'tests/pester/A.Tests.ps1'), "`$text | Should -Match 'Publish only when the user asks'`n", [Text.UTF8Encoding]::new($true))
        $null = & git -C $root add --all 2>&1; $null = & git -C $root -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm base 2>&1
        $baseCommit = (& git -C $root rev-parse HEAD).Trim()
        # A split moves the assertion into a new file: the total is unchanged.
        [IO.File]::WriteAllText((Join-Path $root 'tests/pester/A.Tests.ps1'), "`$text | Should -Match 'PublishDevelop'`n", [Text.UTF8Encoding]::new($true))
        [IO.File]::WriteAllText((Join-Path $root 'tests/pester/B.Tests.ps1'), "`$text | Should -Match 'Publish only when the user asks'`n", [Text.UTF8Encoding]::new($true))
        (Get-WordingAssertionDelta -BaseCommit $baseCommit -Root $root).added | Should -Be 0
        # A new prose assertion is a net addition and names its file.
        [IO.File]::AppendAllText((Join-Path $root 'tests/pester/B.Tests.ps1'), "`$text | Should -Match 'Repair a failed frozen publication through it'`n")
        $added = Get-WordingAssertionDelta -BaseCommit $baseCommit -Root $root
        $added.added | Should -Be 1
        @($added.files) | Should -Contain 'tests/pester/B.Tests.ps1 base=0 now=2'
        # Replacing one lowers the total.
        [IO.File]::WriteAllText((Join-Path $root 'tests/pester/B.Tests.ps1'), "`$text | Should -Match 'DELIVERY_QUEUE_ADVANCED'`n", [Text.UTF8Encoding]::new($true))
        (Get-WordingAssertionDelta -BaseCommit $baseCommit -Root $root).added | Should -Be -1
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
