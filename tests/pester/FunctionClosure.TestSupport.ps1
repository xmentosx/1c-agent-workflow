# Loads production functions for a fixture by their call closure instead of a
# hand-maintained name list. Starting from the named roots, every command whose
# name is a top-level function of the given owner files is followed. Functions
# that the test file itself defines are its substitutes: they are neither
# imported nor followed, so a missing substitute surfaces as CommandNotFound
# rather than as an accidental call of the real owner.

function Get-TestFunctionOwnerIndex {
    param([Parameter(Mandatory = $true)][string[]]$Path)
    $index = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($ownerPath in $Path) {
        $fullPath = [IO.Path]::GetFullPath($ownerPath)
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$tokens, [ref]$errors)
        if (@($errors).Count -gt 0) { throw "TEST_FUNCTION_CLOSURE_PARSE: '$fullPath' does not parse: $($errors[0].Message)" }
        $definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object {
            $parent = $_.Parent
            while ($parent -and $parent -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $parent = $parent.Parent }
            $null -eq $parent
        })
        foreach ($definition in $definitions) {
            if ($index.ContainsKey($definition.Name)) {
                if ([string]$index[$definition.Name].Extent.Text -cne [string]$definition.Extent.Text) {
                    throw "TEST_FUNCTION_CLOSURE_AMBIGUOUS: '$($definition.Name)' is defined differently in more than one owner file."
                }
                continue
            }
            $index[$definition.Name] = $definition
        }
    }
    return $index
}

function Get-TestFunctionSubstitutes {
    param([string]$StubSource)
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if (-not $StubSource) { return ,$names }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile([IO.Path]::GetFullPath($StubSource), [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw "TEST_FUNCTION_CLOSURE_PARSE: '$StubSource' does not parse: $($errors[0].Message)" }
    foreach ($definition in @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
        [void]$names.Add(($definition.Name -replace '^(?i:script|global|local):', ''))
    }
    return ,$names
}

function Get-TestFunctionClosure {
    param(
        [Parameter(Mandatory = $true)][string[]]$Path,
        [Parameter(Mandatory = $true)][string[]]$Root,
        # The test file whose own function definitions substitute owner functions.
        [string]$StubSource = '',
        # Owner functions that are deliberately absent from the fixture.
        [string[]]$Exclude = @()
    )
    $index = Get-TestFunctionOwnerIndex -Path $Path
    $substitutes = Get-TestFunctionSubstitutes -StubSource $StubSource
    $excluded = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Exclude) {
        if (-not $index.ContainsKey($name)) { throw "TEST_FUNCTION_CLOSURE_EXCLUDE_UNKNOWN: '$name' is not an owner function." }
        [void]$excluded.Add($name)
    }
    $selected = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $pending = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($name in $Root) {
        if (-not $index.ContainsKey($name)) { throw "TEST_FUNCTION_CLOSURE_ROOT_UNKNOWN: '$name' is not defined by the owner files." }
        if ($substitutes.Contains($name) -or $excluded.Contains($name)) { throw "TEST_FUNCTION_CLOSURE_ROOT_SUBSTITUTED: root '$name' is substituted or excluded by the fixture." }
        $pending.Enqueue($name)
    }
    while ($pending.Count -gt 0) {
        $name = $pending.Dequeue()
        if (-not $seen.Add($name)) { continue }
        $definition = $index[$name]
        $selected.Add($definition)
        foreach ($command in @($definition.Body.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))) {
            $callee = $command.GetCommandName()
            if (-not $callee -or -not $index.ContainsKey($callee) -or $seen.Contains($callee)) { continue }
            if ($substitutes.Contains($callee) -or $excluded.Contains($callee)) { continue }
            $pending.Enqueue($callee)
        }
    }
    return @($selected.ToArray())
}

function Import-TestFunctionClosure {
    param(
        [Parameter(Mandatory = $true)][string[]]$Path,
        [Parameter(Mandatory = $true)][string[]]$Root,
        [string]$StubSource = '',
        [string[]]$Exclude = @()
    )
    $definitions = @(Get-TestFunctionClosure -Path $Path -Root $Root -StubSource $StubSource -Exclude $Exclude)
    foreach ($definition in $definitions) {
        # Rebuild the declaration as script-scoped so the caller's test scope sees it.
        $body = $definition.Body.Extent.Text
        $keyword = if ($definition.IsFilter) { 'filter' } elseif ($definition.IsWorkflow) { 'workflow' } else { 'function' }
        $parameters = if ($definition.Parameters) { '(' + (@($definition.Parameters | ForEach-Object { $_.Extent.Text }) -join ', ') + ') ' } else { '' }
        . ([scriptblock]::Create("$keyword script:$($definition.Name) $parameters$body"))
    }
    return @($definitions | ForEach-Object { $_.Name })
}
