[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$OutputRoot
)

# One-off, source-only evidence producer for this change. It never executes tests.
$ErrorActionPreference = 'Stop'
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
. (Join-Path $RepositoryRoot 'scripts/git-path-list.ps1')
$paths = @(Get-RepositoryGitPathList -RepositoryRoot $RepositoryRoot -Arguments @('ls-files', '-z', '--cached'))
$catalog = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'tests/quality-contracts.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$timings = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts/pester-timings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$cases = New-Object 'System.Collections.Generic.List[object]'
$files = New-Object 'System.Collections.Generic.List[object]'
$sha = [Security.Cryptography.SHA256]::Create()

function Get-TextDigest([string]$Text) {
    return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '').ToLowerInvariant()
}

foreach ($path in $paths) {
    $family = if ($path -like 'tests/pester/*.Tests.ps1') { 'pester' }
        elseif ($path -match '(^|/)test_[^/]+\.py$|(^|/)[^/]+_test\.py$') { 'python' }
        elseif ($path -like '*_test.go') { 'go' }
        elseif ($path -like '*.test.js' -or $path -like '*.test.ts') { 'node' }
        else { '' }
    if (-not $family) { continue }
    $absolute = Join-Path $RepositoryRoot $path
    $text = [IO.File]::ReadAllText($absolute, [Text.UTF8Encoding]::new($false, $true))
    $owners = @(@(foreach ($contract in $catalog.contracts) {
        if ($path -in @($contract.tests) -or @($contract.paths | Where-Object { $path -like $_ }).Count -gt 0) { [string]$contract.id }
    }) | Sort-Object -Unique)
    $declaredOwners = @($catalog.contracts | Where-Object { $path -in @($_.tests) } | ForEach-Object { [string]$_.id })
    $countBefore = $cases.Count
    $parseErrors = 0
    if ($family -eq 'pester') {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($absolute, [ref]$tokens, [ref]$errors)
        $parseErrors = @($errors).Count
        if ($parseErrors) { throw "Cannot inventory invalid source: $path" }
        $definitions = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'It' }, $true))
        foreach ($definition in $definitions) {
            $nameElement = @($definition.CommandElements | Select-Object -Skip 1 | Where-Object {
                $_ -is [Management.Automation.Language.StringConstantExpressionAst] -or $_ -is [Management.Automation.Language.ExpandableStringExpressionAst]
            }) | Select-Object -First 1
            $block = @($definition.CommandElements | Where-Object { $_ -is [Management.Automation.Language.ScriptBlockExpressionAst] }) | Select-Object -Last 1
            $body = if ($block) { $block.ScriptBlock.Extent.Text } else { $definition.Extent.Text }
            $commands = if ($block) { @($block.ScriptBlock.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) } else { @() }
            $commandNames = @($commands | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
            $knownSourceAssertions = [regex]::Matches($body, '\$(HelperText|LauncherText|McpHostText|[A-Za-z]*ScriptText)\s*\|\s*Should\b').Count
            $flags = New-Object 'System.Collections.Generic.List[string]'
            if ($declaredOwners.Count -gt 1) { $flags.Add('multiple-contract-owners') }
            if ($knownSourceAssertions) { $flags.Add('source-structure-assertions') }
            if ($body -match 'Ran\s+\d+\s+tests') { $flags.Add('literal-nested-case-count') }
            if ($body -match 'Start-Sleep|WaitForExit|Stopwatch|AddSeconds|AddMilliseconds') { $flags.Add('time-or-process-boundary') }
            if ($body -match '\bpython\b|\.py[\x22\x27]|\bnode\b|go test|Build-ItlOnDemandMcp') { $flags.Add('nested-runtime-or-build') }
            $cases.Add([pscustomobject][ordered]@{
                family = $family; file = $path; line = $definition.Extent.StartLineNumber
                name = [string]$nameElement.Value; owners = ($declaredOwners -join ';')
                assertions = @($commands | Where-Object { $_.GetCommandName() -eq 'Should' }).Count
                knownSourceAssertions = $knownSourceAssertions; reviewFlags = ($flags -join ';')
                commands = ($commandNames -join ';'); normalizedBodySha256 = Get-TextDigest (($body -replace '\s+', ' ').Trim())
                reviewDecision = 'pending-semantic-review'; retainedProof = ''
            })
        }
    } else {
        $pattern = if ($family -eq 'python') { '(?m)^\s*(?:async\s+)?def\s+(test_[A-Za-z0-9_]+)\s*\(' }
            elseif ($family -eq 'go') { '(?m)^func\s+(Test[A-Za-z0-9_]+)\s*\(' }
            else { '(?m)^(?:async\s+)?function\s+(run[A-Za-z0-9_]+|test[A-Za-z0-9_]+)\s*\(' }
        foreach ($match in [regex]::Matches($text, $pattern)) {
            $line = 1 + [regex]::Matches($text.Substring(0, $match.Index), '\n').Count
            $cases.Add([pscustomobject][ordered]@{
                family = $family; file = $path; line = $line; name = $match.Groups[1].Value
                owners = ($owners -join ';'); assertions = ''; knownSourceAssertions = ''
                reviewFlags = 'nested-route-and-skip-review'; commands = ''; normalizedBodySha256 = ''
                reviewDecision = 'pending-semantic-review'; retainedProof = ''
            })
        }
        if ($family -eq 'node') {
            $cases.Add([pscustomobject][ordered]@{
                family = $family; file = $path; line = 1; name = 'top-level-assertion-script'
                owners = ($owners -join ';'); assertions = [regex]::Matches($text, '\bassert\.').Count
                knownSourceAssertions = ''; reviewFlags = 'non-framework-script'; commands = ''
                normalizedBodySha256 = ''; reviewDecision = 'pending-semantic-review'; retainedProof = ''
            })
        }
    }
    $timing = $timings.files.PSObject.Properties[[IO.Path]::GetFileName($path)]
    $files.Add([pscustomobject][ordered]@{
        family = $family; file = $path; sourceSha256 = (Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash.ToLowerInvariant()
        definitionCount = $cases.Count - $countBefore; declaredOwners = ($declaredOwners -join ';')
        inputOwners = ($owners -join ';'); trackedTimingSeconds = $(if ($timing) { $timing.Value } else { '' })
        timingMeaning = 'scheduler-observation-not-current-execution'; parseErrors = $parseErrors
        reviewDecision = 'pending-semantic-review'
    })
}

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$files | Export-Csv -LiteralPath (Join-Path $OutputRoot 'test-files.csv') -NoTypeInformation -Encoding UTF8
$cases | Export-Csv -LiteralPath (Join-Path $OutputRoot 'test-cases.csv') -NoTypeInformation -Encoding UTF8
$head = (Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse', 'HEAD')).stdout.Trim()
$duplicates = @($cases | Where-Object { $_.normalizedBodySha256 } | Group-Object normalizedBodySha256 | Where-Object Count -gt 1)
$summary = [ordered]@{
    sourceCommit = $head; mode = 'static-read-only'; files = $files.Count; definitions = $cases.Count
    families = @($files | Group-Object family | ForEach-Object { [ordered]@{ family = $_.Name; files = $_.Count; definitions = ($_.Group | Measure-Object definitionCount -Sum).Sum } })
    multipleOwnerPesterFiles = @($files | Where-Object { $_.family -eq 'pester' -and $_.declaredOwners -match ';' }).Count
    literalNestedCountCases = @($cases | Where-Object { $_.reviewFlags -match 'literal-nested-case-count' }).Count
    normalizedDuplicateBodyGroups = $duplicates.Count
    semanticReviewComplete = $false
    limitations = @('Static definitions are not expanded executions.', 'Node top-level assertions and integration functions are inventoried separately.', 'Declared owners and flags do not prove semantic necessity or equivalent replacement.', 'Pester timing values are prior scheduler observations, not current or nested-runtime timings.')
}
$summary | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $OutputRoot 'test-inventory-summary.json') -Encoding UTF8
$summary | ConvertTo-Json -Depth 7
$sha.Dispose()
