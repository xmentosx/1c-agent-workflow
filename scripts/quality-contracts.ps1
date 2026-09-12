Set-StrictMode -Version Latest

function Get-QualityContractCatalog {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $path = Join-Path $RepositoryRoot "tests\quality-contracts.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Quality contract catalog is missing: $path" }
    $catalog = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$catalog.schemaVersion -ne 1) { throw "Quality contract catalog schemaVersion must be 1." }
    return $catalog
}

function Get-PublicLifecycleActions {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $helperPath = Join-Path $RepositoryRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw "Unable to parse lifecycle helper action inventory: $($errors[0].Message)" }
    $parameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "Action" } | Select-Object -First 1
    if (-not $parameter) { throw "Lifecycle helper has no Action parameter." }
    $validateSet = $parameter.Attributes | Where-Object { $_.TypeName.FullName -eq "ValidateSet" } | Select-Object -First 1
    if (-not $validateSet) { throw "Lifecycle helper Action parameter has no ValidateSet." }
    return @($validateSet.PositionalArguments | ForEach-Object { [string]$_.SafeGetValue() } | Sort-Object -Unique)
}

function Get-Agent1cSemanticModel {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$SourceName = "agent-1c.ps1"
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, $SourceName, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) {
        return [pscustomobject]@{ valid = $false; reason = "parse-error"; detail = [string]$errors[0].Message }
    }
    if ($null -eq $ast.ParamBlock) { return [pscustomobject]@{ valid = $false; reason = "missing-param-block"; detail = "" } }

    $parameters = @{}
    $functions = @{}
    $actions = @{}
    $spans = New-Object System.Collections.Generic.List[object]
    foreach ($parameter in @($ast.ParamBlock.Parameters)) {
        $name = [string]$parameter.Name.VariablePath.UserPath
        if (-not $name -or $parameters.ContainsKey($name)) { return [pscustomobject]@{ valid = $false; reason = "dynamic-or-duplicate-parameter"; detail = $name } }
        $parameters[$name] = [string]$parameter.Extent.Text
        $spans.Add([pscustomobject]@{ start = [int]$parameter.Extent.StartOffset; length = [int]($parameter.Extent.EndOffset - $parameter.Extent.StartOffset); marker = "__ITL_PARAMETER_$name`__" }) | Out-Null
    }
    foreach ($definition in @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })) {
        $name = [string]$definition.Name
        if (-not $name -or $functions.ContainsKey($name)) { return [pscustomobject]@{ valid = $false; reason = "dynamic-or-duplicate-function"; detail = $name } }
        $functions[$name] = [string]$definition.Extent.Text
        $spans.Add([pscustomobject]@{ start = [int]$definition.Extent.StartOffset; length = [int]($definition.Extent.EndOffset - $definition.Extent.StartOffset); marker = "__ITL_FUNCTION_$name`__" }) | Out-Null
    }

    $dispatches = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.SwitchStatementAst] -and $node.Condition.Extent.Text.Trim() -ceq '$Action'
    }, $true))
    if ($dispatches.Count -ne 1) { return [pscustomobject]@{ valid = $false; reason = "dynamic-or-missing-dispatch"; detail = [string]$dispatches.Count } }
    foreach ($clause in @($dispatches[0].Clauses)) {
        $label = $clause.Item1
        if ($label -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            return [pscustomobject]@{ valid = $false; reason = "dynamic-dispatch-label"; detail = [string]$label.Extent.Text }
        }
        $name = [string]$label.Value
        if (-not $name -or $actions.ContainsKey($name)) { return [pscustomobject]@{ valid = $false; reason = "dynamic-or-duplicate-action"; detail = $name } }
        $body = $clause.Item2
        $actions[$name] = [string]$body.Extent.Text
        # Keep the literal label in the shared fingerprint. Renaming an arm is
        # therefore never mistaken for a leaf body edit.
        $spans.Add([pscustomobject]@{ start = [int]$body.Extent.StartOffset; length = [int]($body.Extent.EndOffset - $body.Extent.StartOffset); marker = "__ITL_ACTION_BODY_$name`__" }) | Out-Null
    }

    $shared = New-Object System.Text.StringBuilder($Text)
    foreach ($span in @($spans | Sort-Object start -Descending)) {
        [void]$shared.Remove([int]$span.start, [int]$span.length)
        [void]$shared.Insert([int]$span.start, [string]$span.marker)
    }
    return [pscustomobject]@{
        valid = $true
        reason = ""
        detail = ""
        parameters = $parameters
        functions = $functions
        actions = $actions
        shared = $shared.ToString()
    }
}

function Resolve-Agent1cSemanticImpact {
    param(
        [Parameter(Mandatory = $true)][object]$Catalog,
        [AllowNull()][AllowEmptyString()][object]$CurrentText,
        [AllowNull()][AllowEmptyString()][object]$BaselineText
    )

    $semantic = $Catalog.semanticTargeting
    $fallback = {
        param([string]$Reason)
        $contract = @($Catalog.contracts | Where-Object { [string]$_.id -eq [string]$semantic.fallbackContract }) | Select-Object -First 1
        return [pscustomobject]@{
            fallback = $true
            reason = $Reason
            impacts = @([pscustomobject]@{ kind = "fallback"; name = $Reason; owner = [string]$semantic.fallbackContract })
            tests = @($contract.tests | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique)
        }
    }
    if ($null -eq $BaselineText) { return & $fallback "missing-baseline" }
    if ($null -eq $CurrentText) { return & $fallback "missing-current-entrypoint" }
    $before = Get-Agent1cSemanticModel -Text ([string]$BaselineText) -SourceName "baseline/agent-1c.ps1"
    $after = Get-Agent1cSemanticModel -Text ([string]$CurrentText) -SourceName "current/agent-1c.ps1"
    if (-not $before.valid) { return & $fallback ("baseline-" + [string]$before.reason) }
    if (-not $after.valid) { return & $fallback ("current-" + [string]$after.reason) }

    foreach ($kind in @("parameters", "functions", "actions")) {
        $beforeNames = @($before.$kind.Keys | Sort-Object)
        $afterNames = @($after.$kind.Keys | Sort-Object)
        if (($beforeNames -join "`n") -cne ($afterNames -join "`n")) { return & $fallback "$kind-inventory-changed" }
    }
    if ([string]$before.shared -cne [string]$after.shared) { return & $fallback "shared-or-top-level-change" }

    $impacts = New-Object System.Collections.Generic.List[object]
    $tests = New-Object System.Collections.Generic.List[string]
    foreach ($test in @($semantic.commonTests)) { $tests.Add(([string]$test).Replace('\', '/')) | Out-Null }
    foreach ($definition in @(
        [pscustomobject]@{ kind = "parameter"; plural = "parameters"; owners = $semantic.parameterOwners; selective = $semantic.selectiveNodes.parameters },
        [pscustomobject]@{ kind = "function"; plural = "functions"; owners = $semantic.functionOwners; selective = $semantic.selectiveNodes.functions },
        [pscustomobject]@{ kind = "action"; plural = "actions"; owners = $semantic.actionOwners; selective = $semantic.selectiveNodes.actions }
    )) {
        foreach ($name in @($before.($definition.plural).Keys | Sort-Object)) {
            if ([string]$before.($definition.plural)[$name] -ceq [string]$after.($definition.plural)[$name]) { continue }
            $ownerProperty = $definition.owners.PSObject.Properties[[string]$name]
            if (-not $ownerProperty) { return & $fallback ("unknown-$($definition.kind)-$name") }
            $selectiveProperty = $definition.selective.PSObject.Properties[[string]$name]
            if (-not $selectiveProperty) { return & $fallback ("unproven-$($definition.kind)-$name") }
            $ownerNames = @($selectiveProperty.Value.owners | ForEach-Object { [string]$_ } | Sort-Object -Unique)
            if ($ownerNames.Count -eq 0 -or [string]$ownerProperty.Value -notin $ownerNames) { return & $fallback ("invalid-selective-owner-$name") }
            foreach ($ownerName in $ownerNames) {
                $owner = $semantic.owners.PSObject.Properties[$ownerName]
                if (-not $owner) { return & $fallback ("unknown-owner-$ownerName") }
                foreach ($test in @($owner.Value.tests)) { $tests.Add(([string]$test).Replace('\', '/')) | Out-Null }
                $impacts.Add([pscustomobject]@{ kind = [string]$definition.kind; name = [string]$name; owner = $ownerName }) | Out-Null
            }
        }
    }
    if ($impacts.Count -eq 0) { return & $fallback "no-semantic-impact" }
    return [pscustomobject]@{
        fallback = $false
        reason = ""
        impacts = @($impacts | ForEach-Object { $_ })
        tests = @($tests | Sort-Object -Unique)
    }
}

function Get-Agent1cEntrypointProbeInventory {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string[]]$TestPaths
    )

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($relativePath in @($TestPaths | Sort-Object -Unique)) {
        $path = Join-Path $RepositoryRoot ([string]$relativePath).Replace('/', '\')
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        if (@($errors).Count -gt 0) { throw "Unable to parse entrypoint probe test '$relativePath': $($errors[0].Message)" }
        foreach ($command in @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-Agent1cEntrypointProbe'
        }, $true))) {
            $arguments = @{}
            for ($index = 1; $index -lt $command.CommandElements.Count; $index++) {
                $element = $command.CommandElements[$index]
                if ($element -isnot [Management.Automation.Language.CommandParameterAst]) { continue }
                if ($null -ne $element.Argument -or $index + 1 -ge $command.CommandElements.Count) {
                    throw "Entrypoint probe arguments must use separate literal values in '$relativePath'."
                }
                $arguments[[string]$element.ParameterName] = $command.CommandElements[++$index]
            }
            $probeId = $arguments['ProbeId']; $action = $arguments['Action']; $probeArguments = $arguments['Arguments']
            if ($probeId -isnot [Management.Automation.Language.StringConstantExpressionAst] -or
                $action -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
                throw "Entrypoint probes must declare literal ProbeId and Action in '$relativePath'."
            }
            $parameterNames = @()
            if ($null -ne $probeArguments) {
                if ($probeArguments -isnot [Management.Automation.Language.HashtableAst]) {
                    throw "Entrypoint probe Arguments must be a literal hashtable in '$relativePath'."
                }
                $parameterNames = @($probeArguments.KeyValuePairs | ForEach-Object {
                    if ($_.Item1 -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
                        throw "Entrypoint probe parameter names must be literal in '$relativePath'."
                    }
                    [string]$_.Item1.Value
                } | Sort-Object -Unique)
            }
            $records.Add([pscustomobject]@{
                id = [string]$probeId.Value
                action = [string]$action.Value
                parameters = $parameterNames
                test = ([string]$relativePath).Replace('\', '/')
            }) | Out-Null
        }
    }
    return @($records | ForEach-Object { $_ })
}

function Test-QualityContractCatalog {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][object]$Catalog,
        [switch]$SkipSemanticEntrypointValidation
    )

    $expectedContinuationScopes = @("deliveryPostGate", "develop", "gate", "release", "static") | Sort-Object
    $actualContinuationScopes = @($Catalog.continuationScopes.PSObject.Properties | ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
    if (($actualContinuationScopes -join "`n") -ne ($expectedContinuationScopes -join "`n")) {
        throw "Quality contract continuationScopes must define exactly: $($expectedContinuationScopes -join ', ')."
    }
    foreach ($scopeName in $expectedContinuationScopes) {
        $patterns = @($Catalog.continuationScopes.$scopeName | ForEach-Object { [string]$_ })
        if ($patterns.Count -eq 0 -or @($patterns | Where-Object { -not $_ -or [IO.Path]::IsPathRooted($_) -or $_ -match '(^|[\\/])\.\.([\\/]|$)' }).Count -gt 0) {
            throw "Quality contract continuation scope '$scopeName' must contain only non-empty repository-relative patterns."
        }
    }

    $expectedDevelopJourneys = @("upgrade", "fresh")
    $actualDevelopJourneys = @($Catalog.developJourneys.names | ForEach-Object { [string]$_ })
    if (@($actualDevelopJourneys | Sort-Object -Unique).Count -ne $expectedDevelopJourneys.Count -or ($actualDevelopJourneys -join "`n") -ne ($expectedDevelopJourneys -join "`n")) {
        throw "Quality contract developJourneys.names must define exactly: $($expectedDevelopJourneys -join ', ')."
    }
    $fullPaths = @($Catalog.developJourneys.fullPaths | ForEach-Object { ([string]$_).Replace('\', '/') })
    if ($fullPaths.Count -eq 0 -or @($fullPaths | Sort-Object -Unique).Count -ne $fullPaths.Count -or
        @($fullPaths | Where-Object { -not $_ -or [IO.Path]::IsPathRooted($_) -or $_ -match '[*?\[]' -or $_ -match '(^|/)\.\.(/|$)' }).Count -gt 0) {
        throw "Quality contract developJourneys.fullPaths must contain unique exact repository-relative paths."
    }
    $missingFullPaths = @($fullPaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $_.Replace('/', '\')) -PathType Leaf) })
    if ($missingFullPaths.Count -gt 0) { throw "Quality contract developJourneys.fullPaths references missing paths: $($missingFullPaths -join ', ')." }
    $routeNames = @($Catalog.developJourneys.routes.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if (($routeNames -join "`n") -ne ($expectedDevelopJourneys -join "`n")) {
        throw "Quality contract developJourneys.routes must define exactly: $($expectedDevelopJourneys -join ', ')."
    }

    $ids = @($Catalog.contracts | ForEach-Object { [string]$_.id })
    if ($ids.Count -eq 0 -or @($ids | Sort-Object -Unique).Count -ne $ids.Count) { throw "Quality contracts must have unique non-empty ids." }
    foreach ($contract in @($Catalog.contracts)) {
        if (-not [string]$contract.owner -or -not [string]$contract.primaryTest -or [int]$contract.budgetSeconds -le 0 -or @($contract.paths).Count -eq 0 -or @($contract.tests).Count -eq 0) {
            throw "Quality contract '$($contract.id)' must define owner, primaryTest, budgetSeconds, paths, and tests."
        }
        if ([string]$contract.primaryTest -notin @($contract.tests | ForEach-Object { [string]$_ })) { throw "Quality contract '$($contract.id)' primaryTest must be present in tests." }
        foreach ($test in @($contract.tests)) {
            $testPath = Join-Path $RepositoryRoot ([string]$test).Replace('/', '\')
            if (-not (Test-Path -LiteralPath $testPath -PathType Leaf)) { throw "Quality contract '$($contract.id)' references missing test '$test'." }
        }
    }
    $allowedPesterExternalInputs = @("ITL_AI_RULES_SOURCE_PATH", "ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE")
    $pesterExternalInputsProperty = $Catalog.PSObject.Properties["pesterExternalInputs"]
    $pesterExternalInputMappings = $(if ($pesterExternalInputsProperty) { @($pesterExternalInputsProperty.Value.PSObject.Properties) } else { @() })
    foreach ($property in $pesterExternalInputMappings) {
        $test = ([string]$property.Name).Replace('\', '/')
        $inputs = @($property.Value | ForEach-Object { [string]$_ })
        $testPath = Join-Path $RepositoryRoot $test.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $testPath -PathType Leaf) -or $test -notlike "tests/pester/*.Tests.ps1") {
            throw "Pester external input mapping references missing or invalid test '$test'."
        }
        if ($inputs.Count -eq 0 -or @($inputs | Sort-Object -Unique).Count -ne $inputs.Count -or @($inputs | Where-Object { $_ -notin $allowedPesterExternalInputs }).Count -gt 0) {
            throw "Pester external input mapping for '$test' must contain unique supported environment names."
        }
    }
    foreach ($journeyName in $expectedDevelopJourneys) {
        $contractIds = @($Catalog.developJourneys.routes.$journeyName.contracts | ForEach-Object { [string]$_ })
        if ($contractIds.Count -eq 0 -or @($contractIds | Sort-Object -Unique).Count -ne $contractIds.Count) {
            throw "Develop E2E journey '$journeyName' must declare unique non-empty contract ids."
        }
        $unknownContractIds = @($contractIds | Where-Object { $_ -notin $ids })
        if ($unknownContractIds.Count -gt 0) {
            throw "Develop E2E journey '$journeyName' references unknown quality contracts: $($unknownContractIds -join ', ')."
        }
    }
    foreach ($property in @($Catalog.retiredTests.PSObject.Properties)) {
        $replacement = Join-Path $RepositoryRoot ([string]$property.Value).Replace('/', '\')
        if (-not (Test-Path -LiteralPath $replacement -PathType Leaf)) {
            throw "Retired test '$($property.Name)' references missing replacement '$($property.Value)'."
        }
    }

    $inventory = @(Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot "tests\pester") -File -Filter "*.Tests.ps1" | ForEach-Object { "tests/pester/$($_.Name)" } | Sort-Object -Unique)
    $ownedTests = @($Catalog.contracts | ForEach-Object { @($_.tests) } | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique)
    $unownedTests = @($inventory | Where-Object { $_ -notin $ownedTests })
    if ($unownedTests.Count -gt 0) { throw "Every Pester file must have a quality contract owner. Unowned: $($unownedTests -join ', ')." }

    if (-not $SkipSemanticEntrypointValidation) {
    $actualActions = @(Get-PublicLifecycleActions -RepositoryRoot $RepositoryRoot)
    $coveredActions = @(
        @($Catalog.lifecycleActions.journey) + @($Catalog.lifecycleActions.boundary) |
            ForEach-Object { [string]$_ } |
            Sort-Object -Unique
    )
    if (($actualActions -join "`n") -ne ($coveredActions -join "`n")) {
        $missing = @($actualActions | Where-Object { $_ -notin $coveredActions })
        $stale = @($coveredActions | Where-Object { $_ -notin $actualActions })
        throw "Lifecycle action coverage mismatch. Missing: $($missing -join ', '); stale: $($stale -join ', ')."
    }

    $semantic = $Catalog.semanticTargeting
    if (-not $semantic -or ([string]$semantic.path).Replace('\', '/') -ne ".agents/skills/1c-workflow/scripts/agent-1c.ps1") {
        throw "Quality contracts must define semanticTargeting for the exact agent-1c.ps1 entrypoint."
    }
    $fallbackContract = @($Catalog.contracts | Where-Object { [string]$_.id -eq [string]$semantic.fallbackContract }) | Select-Object -First 1
    if (-not $fallbackContract -or ([string]$semantic.path).Replace('\', '/') -notin @($fallbackContract.paths | ForEach-Object { ([string]$_).Replace('\', '/') })) {
        throw "semanticTargeting fallbackContract must own the exact entrypoint path."
    }
    $allOwnedTests = @($Catalog.contracts | ForEach-Object { @($_.tests) } | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique)
    $ownerNames = @($semantic.owners.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($ownerNames.Count -eq 0 -or @($ownerNames | Sort-Object -Unique).Count -ne $ownerNames.Count) { throw "semanticTargeting owners must be unique and non-empty." }
    foreach ($owner in @($semantic.owners.PSObject.Properties)) {
        $ownerTests = @($owner.Value.tests | ForEach-Object { ([string]$_).Replace('\', '/') })
        if ($ownerTests.Count -eq 0 -or @($ownerTests | Sort-Object -Unique).Count -ne $ownerTests.Count -or @($ownerTests | Where-Object { $_ -notin $allOwnedTests }).Count -gt 0) {
            throw "semanticTargeting owner '$($owner.Name)' must reference unique catalog-owned tests."
        }
    }
    $commonTests = @($semantic.commonTests | ForEach-Object { ([string]$_).Replace('\', '/') })
    if ($commonTests.Count -eq 0 -or @($commonTests | Sort-Object -Unique).Count -ne $commonTests.Count -or @($commonTests | Where-Object { $_ -notin $allOwnedTests }).Count -gt 0) {
        throw "semanticTargeting commonTests must reference unique catalog-owned tests."
    }
    $entrypointText = Get-Content -LiteralPath (Join-Path $RepositoryRoot ([string]$semantic.path).Replace('/', '\')) -Raw -Encoding UTF8
    $entrypointModel = Get-Agent1cSemanticModel -Text $entrypointText
    if (-not $entrypointModel.valid) { throw "Unable to build the entrypoint semantic model: $($entrypointModel.reason)." }
    $actionOwners = @($semantic.actionOwners.PSObject.Properties | ForEach-Object { [string]$_.Name } | Sort-Object)
    $dispatchActions = @($entrypointModel.actions.Keys | Sort-Object)
    if (($actualActions -join "`n") -ne ($dispatchActions -join "`n") -or ($actualActions -join "`n") -ne ($actionOwners -join "`n")) {
        throw "Action ValidateSet, literal dispatch labels, and semanticTargeting.actionOwners must be exactly equal."
    }
    foreach ($mappingName in @("actionOwners", "parameterOwners", "functionOwners")) {
        foreach ($mapping in @($semantic.$mappingName.PSObject.Properties)) {
            if ([string]$mapping.Value -notin $ownerNames) { throw "semanticTargeting $mappingName '$($mapping.Name)' references unknown owner '$($mapping.Value)'." }
        }
    }
    foreach ($name in @($semantic.parameterOwners.PSObject.Properties | ForEach-Object { [string]$_.Name })) {
        if (-not $entrypointModel.parameters.ContainsKey($name)) { throw "semanticTargeting parameterOwners references missing parameter '$name'." }
    }
    foreach ($name in @($semantic.functionOwners.PSObject.Properties | ForEach-Object { [string]$_.Name })) {
        if (-not $entrypointModel.functions.ContainsKey($name)) { throw "semanticTargeting functionOwners references missing function '$name'." }
    }
    $selectiveNodesProperty = $semantic.PSObject.Properties['selectiveNodes']
    if (-not $selectiveNodesProperty) { throw 'semanticTargeting must separate selectiveNodes from informational owner mappings.' }
    foreach ($kind in @('actions', 'parameters', 'functions')) {
        if (-not $selectiveNodesProperty.Value.PSObject.Properties[$kind]) { throw "semanticTargeting.selectiveNodes must define $kind." }
    }
    $probeTestPaths = @($semantic.owners.PSObject.Properties | ForEach-Object { @($_.Value.tests) } | Sort-Object -Unique)
    $probes = @(Get-Agent1cEntrypointProbeInventory -RepositoryRoot $RepositoryRoot -TestPaths $probeTestPaths)
    $duplicateProbeIds = @($probes | Group-Object id | Where-Object Count -ne 1 | ForEach-Object { [string]$_.Name })
    if ($duplicateProbeIds.Count -gt 0) { throw "Entrypoint probe ids must be unique: $($duplicateProbeIds -join ', ')." }
    foreach ($definition in @(
        [pscustomobject]@{kind='action'; plural='actions'; mappings=$semantic.actionOwners; inventory=$entrypointModel.actions},
        [pscustomobject]@{kind='parameter'; plural='parameters'; mappings=$semantic.parameterOwners; inventory=$entrypointModel.parameters},
        [pscustomobject]@{kind='function'; plural='functions'; mappings=$semantic.functionOwners; inventory=$entrypointModel.functions}
    )) {
        foreach ($node in @($selectiveNodesProperty.Value.($definition.plural).PSObject.Properties)) {
            $name = [string]$node.Name
            if (-not $definition.inventory.ContainsKey($name)) { throw "Selective $($definition.kind) '$name' is missing from the entrypoint." }
            $owners = @($node.Value.owners | ForEach-Object { [string]$_ } | Sort-Object -Unique)
            $probeIds = @($node.Value.probes | ForEach-Object { [string]$_ } | Sort-Object -Unique)
            if ($owners.Count -eq 0 -or $probeIds.Count -eq 0 -or $owners.Count -ne @($node.Value.owners).Count -or $probeIds.Count -ne @($node.Value.probes).Count) {
                throw "Selective $($definition.kind) '$name' must declare unique non-empty owners and probes."
            }
            $classifiedOwner = $definition.mappings.PSObject.Properties[$name]
            if (-not $classifiedOwner -or [string]$classifiedOwner.Value -notin $owners -or @($owners | Where-Object { $_ -notin $ownerNames }).Count -gt 0) {
                throw "Selective $($definition.kind) '$name' is not covered by its classified owner."
            }
            $ownerTests = @($owners | ForEach-Object { $ownerName = $_; @($semantic.owners.PSObject.Properties[$ownerName].Value.tests) } | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique)
            foreach ($probeId in $probeIds) {
                $probe = @($probes | Where-Object { [string]$_.id -ceq $probeId })
                if ($probe.Count -ne 1 -or [string]$probe[0].test -notin $ownerTests) { throw "Selective $($definition.kind) '$name' references unowned or missing probe '$probeId'." }
                if ($definition.kind -eq 'action' -and [string]$probe[0].action -cne $name) { throw "Probe '$probeId' does not execute selective action '$name'." }
                if ($definition.kind -eq 'parameter' -and $name -notin @($probe[0].parameters)) { throw "Probe '$probeId' does not bind selective parameter '$name'." }
            }
        }
    }
    }
    return $true
}

function Test-QualityPathPattern {
    param([string]$Path, [string]$Pattern)

    $normalizedPath = $Path.Replace('\', '/')
    $normalizedPattern = $Pattern.Replace('\', '/')
    return $normalizedPath -like $normalizedPattern
}

function Resolve-QualityContractsForPaths {
    param(
        [Parameter(Mandatory = $true)][object]$Catalog,
        [Parameter(Mandatory = $true)][string[]]$Paths
    )

    $contracts = New-Object System.Collections.Generic.List[object]
    $unknown = New-Object System.Collections.Generic.List[string]
    $directTests = New-Object System.Collections.Generic.List[string]
    foreach ($rawPath in @($Paths)) {
        $path = ([string]$rawPath).Replace('\', '/')
        if (-not $path) { continue }
        if ($path -like "tests/pester/*.Tests.ps1") {
            $retired = $Catalog.retiredTests.PSObject.Properties[$path]
            if ($retired) {
                $directTests.Add(([string]$retired.Value).Replace('\', '/')) | Out-Null
            } else {
                $directTests.Add($path) | Out-Null
            }
            continue
        }
        $matches = @($Catalog.contracts | Where-Object {
            $contract = $_
            @($contract.paths | Where-Object { Test-QualityPathPattern -Path $path -Pattern ([string]$_) }).Count -gt 0
        })
        if ($matches.Count -eq 0) {
            $unknown.Add($path) | Out-Null
        } else {
            foreach ($match in $matches) {
                if (@($contracts | Where-Object { [string]$_.id -eq [string]$match.id }).Count -eq 0) { $contracts.Add($match) | Out-Null }
            }
        }
    }
    $tests = @(
        @($directTests) + @($contracts | ForEach-Object { @($_.tests) }) |
            ForEach-Object { ([string]$_).Replace('\', '/') } |
            Sort-Object -Unique
    )
    return [pscustomobject]@{
        contracts = @($contracts | ForEach-Object { $_ })
        tests = $tests
        unknownPaths = @($unknown | ForEach-Object { $_ } | Sort-Object -Unique)
    }
}
