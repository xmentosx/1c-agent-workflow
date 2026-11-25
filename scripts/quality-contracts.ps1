Set-StrictMode -Version Latest

function Get-DevelopScenarioCatalog {
    param([object]$Catalog,[string]$Journey)
    if(-not $Catalog.developJourneys.PSObject.Properties['scenarios']) {return @()}
    $items=@($Catalog.developJourneys.scenarios.$Journey)
    $expected=if($Journey -eq 'upgrade') {@('update','configuration-rejection','verification-export')} else {@('install','branch','verification','stale-export','refresh','close')}
    if((@($items.id) -join ',') -cne ($expected -join ',')) {throw 'DEVELOP_SCENARIO_IMPLEMENTATION_MISSING'}
    $seen=@()
    foreach($item in $items) {
        if(@($item.PSObject.Properties.Name | Where-Object {$_ -notin @('id','dependsOn','operations')}).Count) {throw 'DEVELOP_SCENARIO_FIELD_UNKNOWN'}
        if($item.id -notmatch '^[a-z][a-z0-9-]+$' -or $item.id -in $seen -or
            @($item.dependsOn | Where-Object {$_ -notin $seen}).Count -or
            @($item.dependsOn | Sort-Object -Unique).Count -ne @($item.dependsOn).Count) {throw 'DEVELOP_SCENARIO_CATALOG_INVALID'}
        $seen+=([string]$item.id)
    }
    return $items
}

function Get-QualityPesterSemanticInputBindings {
    param([object]$Catalog)
    $map=@{}; $known=@()
    $property=$Catalog.PSObject.Properties['semanticTargeting']
    if(-not $property){return [pscustomobject]@{complete=$true;paths=@();byTest=$map}}
    $semantic=$property.Value
    if(@('path','fallbackContract'|Where-Object {-not $semantic.PSObject.Properties[$_]}).Count){return [pscustomobject]@{complete=$false;paths=@();byTest=$map}}
    $unknown=@($semantic.PSObject.Properties.Name|Where-Object {$_ -notin @('path','fallbackContract','commonTests','owners','actionOwners','parameterOwners','functionOwners','libraries','selectiveNodes')})
    if($unknown.Count){return [pscustomobject]@{complete=$false;paths=@();byTest=$map}}
    $entry=([string]$semantic.path).Replace('\','/')
    $fallback=@($Catalog.contracts|Where-Object id -eq $semantic.fallbackContract)
    if(-not $entry -or [IO.Path]::IsPathRooted($entry) -or $entry -match '(^|/)\.\.(/|$)' -or $fallback.Count -ne 1){return [pscustomobject]@{complete=$false;paths=@();byTest=$map}}
    $known+=,$entry
    # Historical catalogs may declare only path/fallbackContract. They have no
    # selective consumers: retain the complete fallback, including rename data.
    $entryTests=@($fallback[0].tests)
    if($semantic.PSObject.Properties['commonTests']){$entryTests+=@($semantic.commonTests)}
    if($semantic.PSObject.Properties['owners']){foreach($owner in $semantic.owners.PSObject.Properties){$entryTests+=@($owner.Value.tests)}}
    $libraries=$semantic.PSObject.Properties['libraries']
    if($libraries){foreach($library in $libraries.Value.PSObject.Properties){
        $path=([string]$library.Name).Replace('\','/');$known+=,$path
        if([IO.Path]::IsPathRooted($path) -or $path -match '(^|/)\.\.(/|$)' -or -not $library.Value.PSObject.Properties['functions'] -or @($library.Value.PSObject.Properties.Name|Where-Object {$_ -ne 'functions'}).Count){return [pscustomobject]@{complete=$false;paths=@();byTest=$map}}
        $selection=Resolve-QualityContractsForPaths -Catalog $Catalog -Paths @($path)
        if(@($selection.unknownPaths).Count){return [pscustomobject]@{complete=$false;paths=@();byTest=$map}}
        $tests=@($selection.tests)
        foreach($function in $library.Value.functions.PSObject.Properties){$tests+=@($function.Value.tests)}
        foreach($test in $tests){$map[[string]$test]=@(@($map[[string]$test])+@($entry,$path)|Where-Object {$_}|Sort-Object -Unique)}
    }}
    foreach($test in $entryTests){$map[[string]$test]=@(@($map[[string]$test])+@($entry)|Where-Object {$_}|Sort-Object -Unique)}
    # The same complete semantic inputs bind Targeted, Full and preview. A
    # selection-wide fallback must not contaminate unrelated owners' proofs.
    return [pscustomobject]@{complete=$true;paths=@($known|Sort-Object -Unique);byTest=$map}
}

function Get-QualityContractReuseInputPaths {
    param([Parameter(Mandatory = $true)][object]$Contract)
    $property = $Contract.PSObject.Properties['reuseInputPaths']
    if (-not $property) { return @() }
    $paths = @($property.Value | ForEach-Object { ([string]$_).Replace('\', '/') })
    if ($paths.Count -eq 0 -or @($paths | Sort-Object -Unique).Count -ne $paths.Count -or
        @($paths | Where-Object { -not $_ -or [IO.Path]::IsPathRooted($_) -or $_ -match '(^|/)\.\.(/|$)' }).Count -gt 0) {
        throw "Quality contract '$($Contract.id)' reuseInputPaths must contain unique non-empty repository-relative patterns."
    }
    return $paths
}

function Get-QualityContractStaticInputExclusions {
    param([Parameter(Mandatory = $true)][object]$Contract)
    # Scripts whose static load this contract's tests never reach (the loader
    # returns before it, as the custom-gate supervisor does before the native
    # planner). A path any owner of the test declares remains an input.
    $property = $Contract.PSObject.Properties['staticInputExclusions']
    if (-not $property) { return @() }
    $paths = @($property.Value | ForEach-Object { ([string]$_).Replace('\', '/') })
    if ($paths.Count -eq 0 -or @($paths | Sort-Object -Unique).Count -ne $paths.Count -or
        @($paths | Where-Object { -not $_ -or $_ -notlike '*.ps1' -or $_ -match '[*?\[]' -or [IO.Path]::IsPathRooted($_) -or $_ -match '(^|/)\.\.(/|$)' }).Count -gt 0) {
        throw "Quality contract '$($Contract.id)' staticInputExclusions must contain unique exact repository-relative .ps1 paths."
    }
    return $paths
}

function Get-DevelopE2EJourneyContractProjection {
    param([Parameter(Mandatory = $true)][object]$Catalog, [Parameter(Mandatory = $true)][ValidateSet('upgrade','fresh')][string]$Journey)
    $route = $Catalog.developJourneys.routes.$Journey
    $ids = @($route.contracts | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $owners = @($Catalog.contracts | Where-Object { [string]$_.id -in $ids } | Sort-Object id)
    if ($owners.Count -ne $ids.Count) { throw 'DEVELOP_INPUT_OWNER_MISSING: journey contract has an unknown owner.' }
    # Journey execution consumes owner paths, not isolated Pester layout or its
    # budgets. Unknown owner fields disable reuse until classified explicitly.
    $runtimeOwners = @(foreach ($owner in $owners) {
        foreach ($property in $owner.PSObject.Properties) {
            # staticInputExclusions narrows isolated Pester identity only.
            if ($property.Name -notin @('id','owner','gate','budgetSeconds','primaryTest','paths','tests','reuseInputPaths','staticInputExclusions')) {
                throw "DEVELOP_INPUT_OWNER_FIELD_UNKNOWN: $($owner.id).$($property.Name)"
            }
        }
        $projected = [ordered]@{ id=[string]$owner.id; paths=@($owner.paths) }
        $reuseInputs = @(Get-QualityContractReuseInputPaths -Contract $owner)
        if ($reuseInputs.Count -gt 0) { $projected['reuseInputPaths'] = $reuseInputs }
        [pscustomobject]$projected
    })
    $projection=[ordered]@{
        schemaVersion = 2; journey = $Journey
        hardSeconds = Get-DevelopE2EJourneyHardBudgetSeconds -Catalog $Catalog -Journey $Journey
        names = @($Catalog.developJourneys.names)
        fullPaths = @($Catalog.developJourneys.fullPaths)
        contracts = $runtimeOwners
    }
    if($Catalog.developJourneys.PSObject.Properties['scenarios']) {
        $projection['scenarios']=@($Catalog.developJourneys.scenarios.$Journey)
        $projection['scenarioInputs']=@($Catalog.developJourneys.scenarioInputs)
    }
    return $projection
}

function Get-QualityContractCatalog {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    $path = Join-Path $RepositoryRoot "tests\quality-contracts.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Quality contract catalog is missing: $path" }
    $catalog = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$catalog.schemaVersion -ne 1) { throw "Quality contract catalog schemaVersion must be 1." }
    return $catalog
}

function Get-QualityReleaseStageCatalog {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $path = Join-Path $RepositoryRoot "scripts\release-e2e\stages.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Release stage catalog is missing: $path" }
    $catalog = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$catalog.schemaVersion -ne 1 -or @($catalog.stages).Count -eq 0) { throw "Release stage catalog must use schemaVersion 1 and contain stages." }
    $ids = @($catalog.stages | ForEach-Object { [string]$_.id })
    if (@($ids | Sort-Object -Unique).Count -ne $ids.Count) { throw "Release stage catalog ids must be unique." }
    foreach ($stage in @($catalog.stages)) {
        if (-not [string]$stage.id -or [int]$stage.version -le 0 -or [int]$stage.budgetSeconds -le 0 -or @($stage.paths).Count -eq 0) {
            throw "Release stage definitions require id, version, budgetSeconds, and paths."
        }
        foreach ($dependency in @($stage.dependsOn)) { if ([string]$dependency -notin $ids) { throw "Release stage '$($stage.id)' has unknown dependency '$dependency'." } }
    }
    return $catalog
}

function Resolve-QualityReleaseCapabilities {
    param([Parameter(Mandatory = $true)][object]$Catalog, [switch]$RequireRelease, [string[]]$ReleaseCapability = @())
    $selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $definitions = @{}
    $visiting = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($definition in @($Catalog.stages)) { $definitions[[string]$definition.id] = $definition }
    function Add-RequiredReleaseCapability {
        param([Parameter(Mandatory = $true)][string]$Name)
        if (-not $definitions.ContainsKey($Name)) { throw "DELIVERY_RELEASE_CAPABILITY_UNKNOWN: $Name" }
        if ($selected.Contains($Name)) { return }
        if (-not $visiting.Add($Name)) { throw "QUALITY_RELEASE_DEPENDENCY_CYCLE: $Name; correct the source stage catalog before repeating the same delivery operation." }
        foreach ($dependency in @($definitions[$Name].dependsOn)) { Add-RequiredReleaseCapability -Name ([string]$dependency) }
        [void]$visiting.Remove($Name)
        [void]$selected.Add($Name)
    }
    if ($RequireRelease) {
        foreach ($definition in @($Catalog.stages)) { Add-RequiredReleaseCapability -Name ([string]$definition.id) }
    } else {
        foreach ($capability in @($ReleaseCapability | Where-Object { [string]$_ } | Sort-Object -Unique)) { Add-RequiredReleaseCapability -Name ([string]$capability) }
    }
    return @($Catalog.stages | Where-Object { $selected.Contains([string]$_.id) } | ForEach-Object { [string]$_.id })
}

function ConvertTo-QualityBudgetSeconds {
    param([AllowNull()][object]$Value, [string]$Name)
    if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -le 0 -or $Value -gt [int]::MaxValue) {
        throw "QUALITY_RELEASE_BUDGET_INVALID: $Name must be a positive 32-bit integer; correct the source catalog and repeat the same delivery operation."
    }
    return [int]$Value
}

function Get-ReleaseE2EBudgetProjection {
    param(
        [Parameter(Mandatory = $true)][object]$StageCatalog,
        [Parameter(Mandatory = $true)][object]$QualityCatalog,
        [switch]$RequireRelease,
        [string[]]$ReleaseCapability = @()
    )
    $selected = @(Resolve-QualityReleaseCapabilities -Catalog $StageCatalog -RequireRelease:$RequireRelease -ReleaseCapability $ReleaseCapability)
    $stageBudgets = [ordered]@{}
    [int64]$fullStageSeconds = 0
    [int64]$selectedStageSeconds = 0
    foreach ($stage in @($StageCatalog.stages)) {
        $seconds = ConvertTo-QualityBudgetSeconds -Value $stage.budgetSeconds -Name "stages.$($stage.id).budgetSeconds"
        $fullStageSeconds += $seconds
        if ([string]$stage.id -in $selected) {
            $stageBudgets[[string]$stage.id] = $seconds
            $selectedStageSeconds += $seconds
        }
    }
    $compatibilitySeconds = ConvertTo-QualityBudgetSeconds -Value $QualityCatalog.budgets.releaseHardSeconds -Name 'budgets.releaseHardSeconds'
    $overheadProperty = $StageCatalog.PSObject.Properties['enclosingOverheadSeconds']
    if (-not $overheadProperty) {
        # Older candidate catalogs keep their original enclosing mode deadline.
        return [pscustomobject]@{
            capabilities=$selected; stageBudgets=$stageBudgets; summedStageSeconds=$selectedStageSeconds
            fullStageSeconds=$fullStageSeconds; enclosingOverheadSeconds=0; usesLegacyModeBudget=$true
            e2eHardSeconds=$(if ($selected.Count) { $compatibilitySeconds } else { 0 }); gateHardSeconds=$compatibilitySeconds
        }
    }
    $overhead = ConvertTo-QualityBudgetSeconds -Value $overheadProperty.Value -Name 'enclosingOverheadSeconds'
    $fullStatic = ConvertTo-QualityBudgetSeconds -Value $QualityCatalog.budgets.fullHardSeconds -Name 'budgets.fullHardSeconds'
    [int64]$gateHard = $fullStatic + $fullStageSeconds + $overhead
    # Reserve the existing source wrapper's 300 seconds without integer overflow.
    if ($gateHard -gt ([int64][int]::MaxValue - 300)) { throw 'QUALITY_RELEASE_BUDGET_INVALID: projected Release budget exceeds the bounded process allowance.' }
    if ($compatibilitySeconds -ne $gateHard) {
        throw "QUALITY_RELEASE_BUDGET_PROJECTION_MISMATCH: budgets.releaseHardSeconds must equal fullHardSeconds + all Release stage budgets + enclosingOverheadSeconds ($gateHard); regenerate that compatibility field in the source catalog before retrying."
    }
    return [pscustomobject]@{
        capabilities=$selected; stageBudgets=$stageBudgets; summedStageSeconds=$selectedStageSeconds
        fullStageSeconds=$fullStageSeconds; enclosingOverheadSeconds=$overhead; usesLegacyModeBudget=$false
        e2eHardSeconds=$(if ($selected.Count) { [int]($selectedStageSeconds + $overhead) } else { 0 })
        gateHardSeconds=[int]$gateHard
    }
}

function Get-DevelopE2EJourneyHardBudgetSeconds {
    param(
        [Parameter(Mandatory = $true)][object]$Catalog,
        [Parameter(Mandatory = $true)][ValidateSet("upgrade", "fresh")][string]$Journey
    )

    $route = $Catalog.developJourneys.routes.$Journey
    if ($route -is [Collections.IDictionary]) {
        $hasBudget = $route.Contains("hardSeconds")
        $value = if ($hasBudget) { $route["hardSeconds"] } else { $null }
    } else {
        $property = $route.PSObject.Properties["hardSeconds"]
        $hasBudget = $null -ne $property
        $value = if ($hasBudget) { $property.Value } else { $null }
    }
    # Older candidate catalogs retain their original journey deadlines.
    if (-not $hasBudget) { return $(if ($Journey -eq "upgrade") { 1200 } else { 2100 }) }
    if (($value -isnot [int] -and $value -isnot [long]) -or $value -le 0 -or $value -gt [int]::MaxValue) {
        throw "QUALITY_DEVELOP_JOURNEY_BUDGET_INVALID: developJourneys.routes.$Journey.hardSeconds must be a positive 32-bit integer."
    }
    return [int]$value
}

function Resolve-PesterWorkerCount {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Targeted", "Smoke", "Full", "Develop", "Release")][string]$Mode,
        [Parameter(Mandatory = $true)][ValidateRange(1, 8)][int]$RequestedWorkerCount,
        [Parameter(Mandatory = $true)][bool]$Explicit,
        [Parameter(Mandatory = $true)][object]$Catalog,
        [int]$ProcessorCount = [Environment]::ProcessorCount
    )

    if ($Explicit -or $Mode -eq 'Smoke') { return $RequestedWorkerCount }
    $property = if ($Mode -eq 'Targeted') { 'targetedImplicitDefault' } else { 'qualificationImplicitDefault' }
    $hasDefault = if ($Catalog.pesterWorkers -is [Collections.IDictionary]) { $Catalog.pesterWorkers.Contains($property) } else { $null -ne $Catalog.pesterWorkers.PSObject.Properties[$property] }
    if (-not $hasDefault) { return $RequestedWorkerCount }
    $implicitDefault = [int]$Catalog.pesterWorkers.$property
    if ($implicitDefault -lt 1 -or $implicitDefault -gt 8) { throw "Quality contract pesterWorkers.$property must be between 1 and 8." }
    $availableProcessors = [Math]::Max(1, $ProcessorCount)
    return [Math]::Max(1, [Math]::Min($implicitDefault, $availableProcessors))
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

# Every registry that must enumerate the public actions is compared with the
# ValidateSet at once, so one failure names every place a new action is missing.
function Get-QualityActionRegistryMismatches {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Actions,
        [Parameter(Mandatory = $true)][System.Collections.Specialized.OrderedDictionary]$Registries
    )
    $expected = @($Actions | Sort-Object -Unique)
    $messages = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $Registries.GetEnumerator()) {
        $ignored = @()
        $listed = @($entry.Value.names | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        if ($entry.Value.Contains('ignore')) { $ignored = @($entry.Value.ignore) }
        $missing = @($expected | Where-Object { $_ -notin $listed -and $_ -notin $ignored })
        $stale = @($listed | Where-Object { $_ -notin $expected })
        if ($missing.Count -gt 0) { $messages.Add("$($entry.Key) is missing: $($missing -join ', ')") }
        if ($stale.Count -gt 0) { $messages.Add("$($entry.Key) lists unknown actions: $($stale -join ', ')") }
    }
    return @($messages.ToArray())
}

function Get-QualityAdvancedActionCatalog {
    param([Parameter(Mandatory = $true)][string]$Text)
    $match = [regex]::Match($Text, '(?s)Common internal actions:\s*```text(?<actions>.*?)```')
    if (-not $match.Success) { throw "ACTION_REGISTRY_MISMATCH: advanced-actions.md has no 'Common internal actions' text block." }
    return @($match.Groups['actions'].Value -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# The on-demand MCP facade version is repeated in the compatibility manifest, the
# dependency lock (version, release tag and URL) and the Go source constant.
function Get-QualityOnDemandVersionMismatches {
    param(
        [Parameter(Mandatory = $true)][object]$Compatibility,
        [Parameter(Mandatory = $true)][object]$LockEntry,
        [Parameter(Mandatory = $true)][string]$MainSource
    )
    $messages = New-Object System.Collections.Generic.List[string]
    $version = [string]$LockEntry.version
    $tag = 'itl-ondemand-mcp-v' + $version
    if ([string]$Compatibility.facadeVersion -cne $version) { $messages.Add("compatibility.json facadeVersion '$([string]$Compatibility.facadeVersion)' differs from dependency-lock itlOndemandMcp.version '$version'") }
    if ([string]$LockEntry.releaseTag -cne $tag) { $messages.Add("dependency-lock itlOndemandMcp.releaseTag '$([string]$LockEntry.releaseTag)' must be '$tag'") }
    $urlSuffix = "/releases/download/$tag/$([string]$LockEntry.assetName)"
    if (-not ([string]$LockEntry.url).EndsWith($urlSuffix, [StringComparison]::Ordinal)) { $messages.Add("dependency-lock itlOndemandMcp.url must end with '$urlSuffix'") }
    $source = [regex]::Match($MainSource, '(?m)^const version = "(?<version>[^"]+)"')
    if (-not $source.Success) { $messages.Add("tools/itl-ondemand-mcp/main.go has no 'const version' declaration") }
    elseif ($source.Groups['version'].Value -cne $version) { $messages.Add("tools/itl-ondemand-mcp/main.go version '$($source.Groups['version'].Value)' differs from dependency-lock itlOndemandMcp.version '$version'") }
    return @($messages.ToArray())
}

function Assert-QualityOnDemandVersionConsistency {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
    $compatibilityPath = Join-Path $RepositoryRoot '.agents\skills\1c-workflow\assets\ondemand-mcp\compatibility.json'
    $lockPath = Join-Path $RepositoryRoot 'templates\dependency-lock.json'
    $mainPath = Join-Path $RepositoryRoot 'tools\itl-ondemand-mcp\main.go'
    if (-not (Test-Path -LiteralPath $compatibilityPath -PathType Leaf) -or -not (Test-Path -LiteralPath $lockPath -PathType Leaf) -or -not (Test-Path -LiteralPath $mainPath -PathType Leaf)) { return }
    $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $lock.dependencies.PSObject.Properties['itlOndemandMcp']) { return }
    $messages = @(Get-QualityOnDemandVersionMismatches -Compatibility (Get-Content -LiteralPath $compatibilityPath -Raw -Encoding UTF8 | ConvertFrom-Json) -LockEntry $lock.dependencies.itlOndemandMcp -MainSource ([IO.File]::ReadAllText($mainPath)))
    if ($messages.Count -gt 0) { throw "ONDEMAND_VERSION_MISMATCH: $($messages -join '; ')." }
}

function Get-QualityPesterExternalInputNames {
    @('ITL_AI_RULES_SOURCE_PATH', 'ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE')
}

function Get-Agent1cSemanticModel {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [string]$SourceName = "agent-1c.ps1",
        [switch]$Library
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, $SourceName, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) {
        return [pscustomobject]@{ valid = $false; reason = "parse-error"; detail = [string]$errors[0].Message }
    }
    if ($null -eq $ast.ParamBlock -and -not $Library) { return [pscustomobject]@{ valid = $false; reason = "missing-param-block"; detail = "" } }
    if ($Library -and $null -ne $ast.ParamBlock) { return [pscustomobject]@{ valid = $false; reason = "library-param-block"; detail = "" } }

    $parameters = @{}
    $functions = @{}
    $actions = @{}
    $spans = New-Object System.Collections.Generic.List[object]
    foreach ($parameter in @(if ($null -ne $ast.ParamBlock) { $ast.ParamBlock.Parameters })) {
        $name = [string]$parameter.Name.VariablePath.UserPath
        if (-not $name -or $parameters.ContainsKey($name)) { return [pscustomobject]@{ valid = $false; reason = "dynamic-or-duplicate-parameter"; detail = $name } }
        $parameters[$name] = [string]$parameter.Extent.Text
        $spans.Add([pscustomobject]@{ start = [int]$parameter.Extent.StartOffset; length = [int]($parameter.Extent.EndOffset - $parameter.Extent.StartOffset); marker = "__ITL_PARAMETER_$name`__" }) | Out-Null
    }
    foreach ($definition in @(if ($null -ne $ast.EndBlock) { $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] } })) {
        $name = [string]$definition.Name
        if (-not $name -or $functions.ContainsKey($name)) { return [pscustomobject]@{ valid = $false; reason = "dynamic-or-duplicate-function"; detail = $name } }
        $functions[$name] = [string]$definition.Extent.Text
        $spans.Add([pscustomobject]@{ start = [int]$definition.Extent.StartOffset; length = [int]($definition.Extent.EndOffset - $definition.Extent.StartOffset); marker = "__ITL_FUNCTION_$name`__" }) | Out-Null
    }

    if (-not $Library) {
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
        ast = $ast
    }
}

function Resolve-Agent1cSemanticImpact {
    param(
        [Parameter(Mandatory = $true)][object]$Catalog,
        [AllowNull()][AllowEmptyString()][object]$CurrentText,
        [AllowNull()][AllowEmptyString()][object]$BaselineText,
        [string]$LibraryPath = ''
    )

    $semantic = $Catalog.semanticTargeting
    $library = if ($LibraryPath) { $semantic.libraries.PSObject.Properties[$LibraryPath].Value } else { $null }
    $fallback = {
        param([string]$Reason)
        if ($LibraryPath) {
            $selection = Resolve-QualityContractsForPaths -Catalog $Catalog -Paths @($LibraryPath)
            return [pscustomobject]@{
                fallback = $true; reason = $Reason
                impacts = @([pscustomobject]@{ kind = 'fallback'; name = $Reason; owner = $LibraryPath })
                tests = @($selection.tests)
            }
        }
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
    $before = Get-Agent1cSemanticModel -Text ([string]$BaselineText) -SourceName "baseline/$LibraryPath" -Library:([bool]$LibraryPath)
    $after = Get-Agent1cSemanticModel -Text ([string]$CurrentText) -SourceName "current/$LibraryPath" -Library:([bool]$LibraryPath)
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
    if ($LibraryPath) {
        foreach ($name in @($before.functions.Keys | Sort-Object)) {
            if ([string]$before.functions[$name] -ceq [string]$after.functions[$name]) { continue }
            $node = $library.functions.PSObject.Properties[$name]
            if (-not $node) { return & $fallback "unproven-function-$name" }
            # A new callee or invocation mechanism widens the declared owner.
            # Keep the existing complete path selection until it is reviewed.
            $beforeCalls = Get-QualityFunctionInvocationInventory -Model $before -Name $name
            $afterCalls = Get-QualityFunctionInvocationInventory -Model $after -Name $name
            if ($null -eq $beforeCalls -or $null -eq $afterCalls -or $beforeCalls -cne $afterCalls -or
                $afterCalls -cne [string]$node.Value.callsSha256) {
                return & $fallback "function-dependencies-changed-$name"
            }
            foreach ($test in @($node.Value.tests)) { $tests.Add([string]$test) | Out-Null }
            $impacts.Add([pscustomobject]@{ kind = 'function'; name = $name; owner = $LibraryPath }) | Out-Null
        }
        if ($impacts.Count -eq 0) { return & $fallback 'no-semantic-impact' }
        return [pscustomobject]@{ fallback = $false; reason = ''; impacts = @($impacts.ToArray()); tests = @($tests | Sort-Object -Unique) }
    }
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

function Get-QualityFunctionInvocationInventory {
    param([object]$Model, [string]$Name)
    $definition = @($Model.ast.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $Name
    })[0]
    if (@($definition.Body.FindAll({param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -or $node -is [Management.Automation.Language.TypeDefinitionAst]
    }, $true)).Count -gt 0) { return $null }
    $calls = New-Object Collections.Generic.List[string]
    foreach ($call in @($definition.FindAll({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -or $node -is [Management.Automation.Language.InvokeMemberExpressionAst]
    }, $true))) {
        if ($call -is [Management.Automation.Language.CommandAst]) {
            $command = $call.GetCommandName()
            if (-not $command -or $call.InvocationOperator -ne [Management.Automation.Language.TokenKind]::Unknown) { return $null }
            $calls.Add("command:$command") | Out-Null
        } else {
            if ($call.Member -isnot [Management.Automation.Language.StringConstantExpressionAst]) { return $null }
            # Bind the target as well as the member: File.Delete and an owned
            # list's Delete must never share an invocation identity.
            $calls.Add("member:$($call.Expression.Extent.Text):$($call.Member.Extent.Text):$($call.Static)") | Out-Null
        }
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((@($calls | Sort-Object -Unique) -join "`n"))))).Replace('-','').ToLowerInvariant()
    } finally { $sha.Dispose() }
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

function Get-QualityPesterSharedInputPaths {
    # Every isolated Pester shard binds these runner/support files.
    @('tests/pester/TestSupport.ps1', 'scripts/run-pester-shard.ps1', 'scripts/invoke-pester-runtime.ps1')
}

function Join-QualityStaticPath {
    param([string]$Base, [string]$Child)
    if ($Child -match '^[A-Za-z]:|^[\\/]{2}|[*?$`]') { return $null }
    $segments = New-Object System.Collections.Generic.List[string]
    foreach ($part in @(($Base + '/' + $Child) -split '[\\/]+')) {
        if (-not $part -or $part -eq '.') { continue }
        if ($part -eq '..') {
            if ($segments.Count -eq 0) { return $null }
            $segments.RemoveAt($segments.Count - 1)
            continue
        }
        $segments.Add($part) | Out-Null
    }
    return ($segments -join '/')
}

function New-QualityStaticValue {
    param([string]$Kind, [string[]]$Values)
    # 'path' is repository-relative and anchored at the analysed file;
    # 'dynamic' is anchored there but not static (its value is the prefix).
    return [pscustomobject]@{ kind = $Kind; values = @($Values) }
}

function Join-QualityStaticValues {
    param($Base, $Child, [switch]$Concatenate)
    if ($null -eq $Base) { return $null }
    if ($Base.kind -eq 'dynamic') { return $Base }
    if ($Base.kind -eq 'text' -and $Concatenate -and $null -ne $Child -and $Child.kind -eq 'text') {
        return New-QualityStaticValue text @(foreach ($left in $Base.values) { foreach ($right in $Child.values) { $left + $right } })
    }
    if ($Base.kind -ne 'path') { return $null }
    if ($null -eq $Child -or $Child.kind -ne 'text') { return New-QualityStaticValue dynamic @($Base.values[0]) }
    $joined = @(foreach ($left in $Base.values) {
        foreach ($right in $Child.values) {
            if ($Concatenate) { Join-QualityStaticPath -Base '' -Child ($left + $right) } else { Join-QualityStaticPath -Base $left -Child $right }
        }
    })
    if (@($joined | Where-Object { $null -eq $_ }).Count -gt 0) { return New-QualityStaticValue dynamic @($Base.values[0]) }
    return New-QualityStaticValue path @($joined | Sort-Object -Unique)
}

function Merge-QualityStaticValues {
    param([object[]]$Items, [switch]$RequireSame)
    if (@($Items).Count -eq 0) { return $null }
    $dynamic = @($Items | Where-Object { $null -ne $_ -and $_.kind -eq 'dynamic' })
    if ($dynamic.Count -gt 0) { return $dynamic[0] }
    $anchored = @($Items | Where-Object { $null -ne $_ -and $_.kind -eq 'path' })
    if (@($Items | Where-Object { $null -eq $_ }).Count -gt 0 -or @($Items.kind | Sort-Object -Unique).Count -ne 1) {
        if ($anchored.Count -gt 0) { return New-QualityStaticValue dynamic @($anchored[0].values[0]) }
        return $null
    }
    if ($RequireSame) {
        $first = (@($Items[0].values | Sort-Object) -join [char]0)
        if (@($Items | Where-Object { (@($_.values | Sort-Object) -join [char]0) -cne $first }).Count -gt 0) {
            if ($anchored.Count -gt 0) { return New-QualityStaticValue dynamic @($anchored[0].values[0]) }
            return $null
        }
        return $Items[0]
    }
    return New-QualityStaticValue ([string]$Items[0].kind) @($Items | ForEach-Object { $_.values })
}

function Get-QualityStaticVariableName {
    param($Variable)
    return (([string]$Variable.VariablePath.UserPath) -replace '^(?i:script|global|local|private|using):', '').ToLowerInvariant()
}

function Resolve-QualityStaticValue {
    param($Node, $Context, [int]$Depth = 0)
    # Only paths anchored at the analysed file ($PSScriptRoot, $PSCommandPath,
    # $MyInvocation.MyCommand.Path) are repository inputs. Other roots are
    # runtime values (target project, fixture, parameter) and stay unknown.
    if ($null -eq $Node -or $Depth -gt 24) { return $null }
    $next = $Depth + 1
    $language = 'System.Management.Automation.Language'
    switch ($Node.GetType().FullName) {
        "$language.StringConstantExpressionAst" { return New-QualityStaticValue text @([string]$Node.Value) }
        "$language.VariableExpressionAst" {
            $name = Get-QualityStaticVariableName $Node
            if ($name -eq 'psscriptroot') { return New-QualityStaticValue path @($Context.directory) }
            if ($name -eq 'pscommandpath') { return New-QualityStaticValue path @($Context.file) }
            # The enclosing foreach binds its own variable, even when another
            # loop elsewhere in the file reuses the name.
            for ($parent = $Node.Parent; $null -ne $parent; $parent = $parent.Parent) {
                if ($parent -is [Management.Automation.Language.ForEachStatementAst] -and (Get-QualityStaticVariableName $parent.Variable) -eq $name -and
                    -not [object]::ReferenceEquals($parent.Condition, $Node) -and $parent.Body.Extent.StartOffset -le $Node.Extent.StartOffset) {
                    return Resolve-QualityStaticValue -Node $parent.Condition -Context $Context -Depth $next
                }
            }
            if ($Context.variables.ContainsKey($name) -and $null -ne $Context.variables[$name]) {
                # One file-wide binding has one value; resolve it once per file.
                if (-not $Context.resolved.ContainsKey($name)) { $Context.resolved[$name] = Resolve-QualityStaticValue -Node $Context.variables[$name] -Context $Context -Depth $next }
                return $Context.resolved[$name]
            }
            return $null
        }
        "$language.MemberExpressionAst" {
            if (($Node.Extent.Text -replace '\s', '') -ieq '$MyInvocation.MyCommand.Path') { return New-QualityStaticValue path @($Context.file) }
            # (Resolve-Path <anchored>).Path names the same file.
            if (-not $Node.Static -and ([string]$Node.Member.Extent.Text) -in @('Path', 'ProviderPath')) {
                $owner = Resolve-QualityStaticValue -Node $Node.Expression -Context $Context -Depth $next
                if ($null -ne $owner -and $owner.kind -ne 'text') { return $owner }
            }
            return $null
        }
        "$language.ConvertExpressionAst" {
            if (([string]$Node.Type.TypeName.Name) -notin @('string', 'System.String')) { return $null }
            return Resolve-QualityStaticValue -Node $Node.Child -Context $Context -Depth $next
        }
        "$language.ForEachStatementAst" { return Resolve-QualityStaticValue -Node $Node.Condition -Context $Context -Depth $next }
        "$language.ParenExpressionAst" { return Resolve-QualityStaticValue -Node $Node.Pipeline -Context $Context -Depth $next }
        "$language.CommandExpressionAst" { return Resolve-QualityStaticValue -Node $Node.Expression -Context $Context -Depth $next }
        "$language.PipelineAst" {
            if (@($Node.PipelineElements).Count -ne 1) { return $null }
            return Resolve-QualityStaticValue -Node $Node.PipelineElements[0] -Context $Context -Depth $next
        }
        "$language.StatementBlockAst" {
            if (@($Node.Statements).Count -ne 1) { return $null }
            return Resolve-QualityStaticValue -Node $Node.Statements[0] -Context $Context -Depth $next
        }
        "$language.ArrayExpressionAst" {
            return Merge-QualityStaticValues @(foreach ($statement in @($Node.SubExpression.Statements)) { ,(Resolve-QualityStaticValue -Node $statement -Context $Context -Depth $next) })
        }
        "$language.ArrayLiteralAst" {
            return Merge-QualityStaticValues @(foreach ($element in @($Node.Elements)) { ,(Resolve-QualityStaticValue -Node $element -Context $Context -Depth $next) })
        }
        "$language.IfStatementAst" {
            if ($null -eq $Node.ElseClause) { return $null }
            $branches = @(foreach ($clause in @($Node.Clauses)) { ,(Resolve-QualityStaticValue -Node $clause.Item2 -Context $Context -Depth $next) })
            $branches += ,(Resolve-QualityStaticValue -Node $Node.ElseClause -Context $Context -Depth $next)
            return Merge-QualityStaticValues $branches -RequireSame
        }
        "$language.BinaryExpressionAst" {
            if ([string]$Node.Operator -ne 'Plus') { return $null }
            $left = Resolve-QualityStaticValue -Node $Node.Left -Context $Context -Depth $next
            return Join-QualityStaticValues -Base $left -Child (Resolve-QualityStaticValue -Node $Node.Right -Context $Context -Depth $next) -Concatenate
        }
        "$language.ExpandableStringExpressionAst" {
            $text = [string]$Node.Value
            if ($text.Contains('`')) { return $null }
            $value = $null
            $position = 0
            foreach ($nested in @($Node.NestedExpressions)) {
                $nestedText = [string]$nested.Extent.Text
                $index = $text.IndexOf($nestedText, $position, [StringComparison]::Ordinal)
                if ($index -lt 0) { return $null }
                $literal = New-QualityStaticValue text @($text.Substring($position, $index - $position))
                $part = Resolve-QualityStaticValue -Node $nested -Context $Context -Depth $next
                if ($null -eq $value) {
                    $value = if ($index -eq 0) { $part } elseif ($null -ne $part -and $part.kind -eq 'text') { Join-QualityStaticValues -Base $literal -Child $part -Concatenate } else { $null }
                    if ($null -eq $value) { return $null }
                } else {
                    $value = Join-QualityStaticValues -Base (Join-QualityStaticValues -Base $value -Child $literal -Concatenate) -Child $part -Concatenate
                    if ($null -eq $value) { return $null }
                }
                $position = $index + $nestedText.Length
            }
            if ($null -eq $value) { return New-QualityStaticValue text @($text) }
            return Join-QualityStaticValues -Base $value -Child (New-QualityStaticValue text @($text.Substring($position))) -Concatenate
        }
        "$language.InvokeMemberExpressionAst" {
            # [IO.Path]::GetFullPath(<anchored>) and [IO.Path]::Combine(<anchored>, '<literal>', ...)
            if ($Node.Static -and ([string]$Node.Member.Extent.Text) -ieq 'GetFullPath' -and @($Node.Arguments).Count -eq 1 -and
                ([string]$Node.Expression.Extent.Text -replace '\s', '') -match '^\[(System\.)?IO\.Path\]$') {
                return Resolve-QualityStaticValue -Node $Node.Arguments[0] -Context $Context -Depth $next
            }
            if (-not $Node.Static -or ([string]$Node.Member.Extent.Text) -ine 'Combine' -or
                ([string]$Node.Expression.Extent.Text -replace '\s', '') -notmatch '^\[(System\.)?IO\.Path\]$' -or @($Node.Arguments).Count -lt 2) { return $null }
            $value = Resolve-QualityStaticValue -Node $Node.Arguments[0] -Context $Context -Depth $next
            foreach ($argument in @($Node.Arguments | Select-Object -Skip 1)) {
                $value = Join-QualityStaticValues -Base $value -Child (Resolve-QualityStaticValue -Node $argument -Context $Context -Depth $next)
            }
            return $value
        }
        "$language.CommandAst" { }
        default { return $null }
    }

    $key = ([string]$Node.GetCommandName()).ToLowerInvariant()
    $valueParameters = @{ 'join-path' = @('path', 'childpath'); 'split-path' = @('path', 'literalpath'); 'resolve-path' = @('path', 'literalpath'); 'convert-path' = @('path', 'literalpath') }
    $switchParameters = @{ 'join-path' = @('resolve'); 'split-path' = @('parent'); 'resolve-path' = @(); 'convert-path' = @() }
    if (-not $valueParameters.ContainsKey($key)) { return $null }
    $named = @{}
    $positional = New-Object System.Collections.Generic.List[object]
    $unsupported = $false
    $elements = @($Node.CommandElements)
    for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -isnot [Management.Automation.Language.CommandParameterAst]) { $positional.Add($element) | Out-Null; continue }
        $parameter = ([string]$element.ParameterName).ToLowerInvariant()
        $valueName = @($valueParameters[$key] | Where-Object { $_.StartsWith($parameter, [StringComparison]::Ordinal) })
        $switchName = @($switchParameters[$key] | Where-Object { $_.StartsWith($parameter, [StringComparison]::Ordinal) })
        if ($valueName.Count -eq 1) {
            if ($null -ne $element.Argument) { $named[$valueName[0]] = $element.Argument; continue }
            if ($index + 1 -ge $elements.Count) { return $null }
            $index++
            $named[$valueName[0]] = $elements[$index]
        } elseif ($switchName.Count -ne 1) {
            $unsupported = $true
        }
    }
    if ($key -eq 'join-path') {
        $pathNode = if ($named.ContainsKey('path')) { $named['path'] } elseif ($positional.Count -gt 0) { $positional[0] } else { $null }
        $childIndex = if ($named.ContainsKey('path')) { 0 } else { 1 }
        $childNode = if ($named.ContainsKey('childpath')) { $named['childpath'] } elseif ($positional.Count -gt $childIndex) { $positional[$childIndex] } else { $null }
        $base = Resolve-QualityStaticValue -Node $pathNode -Context $Context -Depth $next
        $child = if ($unsupported -or $positional.Count -gt $childIndex + 1) { $null } else { Resolve-QualityStaticValue -Node $childNode -Context $Context -Depth $next }
        return Join-QualityStaticValues -Base $base -Child $child
    }
    $targetNode = if ($named.ContainsKey('path')) { $named['path'] } elseif ($named.ContainsKey('literalpath')) { $named['literalpath'] } elseif ($positional.Count -gt 0) { $positional[0] } else { $null }
    $target = Resolve-QualityStaticValue -Node $targetNode -Context $Context -Depth $next
    if ($null -eq $target -or $target.kind -eq 'text') { return $null }
    if ($unsupported -or $target.kind -eq 'dynamic') { return New-QualityStaticValue dynamic @($target.values[0]) }
    if ($key -ne 'split-path') { return $target }
    $parents = @(foreach ($path in $target.values) {
        if (-not $path) { $null } else { $separator = ([string]$path).LastIndexOf('/'); if ($separator -lt 0) { '' } else { ([string]$path).Substring(0, $separator) } }
    })
    if (@($parents | Where-Object { $null -eq $_ }).Count -gt 0) { return $null }
    return New-QualityStaticValue path @($parents | Sort-Object -Unique)
}

function Get-QualityStaticAstPredicate {
    param([Parameter(Mandatory = $true)][ValidateSet('loads', 'bindings')][string]$Kind)
    $cache = Get-Variable -Name qualityStaticAstPredicates -Scope Script -ErrorAction SilentlyContinue
    if (-not $cache -or $null -eq $cache.Value) { $script:qualityStaticAstPredicates = @{} }
    if ($script:qualityStaticAstPredicates.ContainsKey($Kind)) { return $script:qualityStaticAstPredicates[$Kind] }
    # Compiled type tests keep the pass over large helper files native-speed;
    # a script-block predicate or a PowerShell loop over every command costs
    # seconds across the repository.
    $expression = [Linq.Expressions.Expression]
    $parameter = $expression::Parameter([Management.Automation.Language.Ast], 'node')
    if ($Kind -eq 'loads') {
        # Dot/call operators, or a command named powershell*/pwsh* (a child
        # -File script). Never read Extent.Text here: for a Describe block it
        # is the whole file, which made this pass quadratic.
        $command = $expression::Convert($parameter, [Management.Automation.Language.CommandAst])
        $operator = $expression::NotEqual($expression::Property($command, 'InvocationOperator'), $expression::Constant([Management.Automation.Language.TokenKind]::Unknown))
        $elements = $expression::Property($command, 'CommandElements')
        $first = $expression::Property($elements, 'Item', [Linq.Expressions.Expression[]]@($expression::Constant(0)))
        $value = $expression::Property($expression::Property($first, 'Extent'), 'Text')
        $startsWith = [string].GetMethod('StartsWith', [Type[]]@([string], [StringComparison]))
        $named = $expression::AndAlso($expression::GreaterThan($expression::Property($elements, 'Count'), $expression::Constant(0)),
            $expression::AndAlso($expression::TypeIs($first, [Management.Automation.Language.StringConstantExpressionAst]),
                $expression::OrElse($expression::Call($value, $startsWith, $expression::Constant('powershell'), $expression::Constant([StringComparison]::OrdinalIgnoreCase)),
                    $expression::Call($value, $startsWith, $expression::Constant('pwsh'), $expression::Constant([StringComparison]::OrdinalIgnoreCase)))))
        # A literal or script-block call target can never be an anchored file.
        $literal = $expression::OrElse($expression::TypeIs($first, [Management.Automation.Language.StringConstantExpressionAst]),
            $expression::TypeIs($first, [Management.Automation.Language.ScriptBlockExpressionAst]))
        $body = $expression::AndAlso($expression::TypeIs($parameter, [Management.Automation.Language.CommandAst]),
            $expression::OrElse($expression::AndAlso($operator, $expression::Not($literal)), $named))
    } else {
        # Only bindings of the requested names (the shared set below, refilled
        # per file); visiting every assignment of large helpers costs seconds.
        $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $script:qualityStaticAstPredicates['bindingNames'] = $set
        $names = $expression::Constant($set)
        $contains = $set.GetType().GetMethod('Contains')
        $requested = {
            param($variable)
            $expression::Call($names, $contains, $expression::Property($expression::Property($variable, 'VariablePath'), 'UserPath'))
        }
        $variableType = [Management.Automation.Language.VariableExpressionAst]
        $left = $expression::Property($expression::Convert($parameter, [Management.Automation.Language.AssignmentStatementAst]), 'Left')
        $converted = $expression::Property($expression::Convert($left, [Management.Automation.Language.ConvertExpressionAst]), 'Child')
        $assigned = $expression::AndAlso($expression::TypeIs($parameter, [Management.Automation.Language.AssignmentStatementAst]), $expression::OrElse(
            $expression::AndAlso($expression::TypeIs($left, $variableType), (& $requested $expression::Convert($left, $variableType))),
            $expression::AndAlso($expression::TypeIs($left, [Management.Automation.Language.ConvertExpressionAst]),
                $expression::AndAlso($expression::TypeIs($converted, $variableType), (& $requested $expression::Convert($converted, $variableType))))))
        $loop = $expression::AndAlso($expression::TypeIs($parameter, [Management.Automation.Language.ForEachStatementAst]),
            (& $requested $expression::Property($expression::Convert($parameter, [Management.Automation.Language.ForEachStatementAst]), 'Variable')))
        $bound = $expression::AndAlso($expression::TypeIs($parameter, [Management.Automation.Language.ParameterAst]),
            (& $requested $expression::Property($expression::Convert($parameter, [Management.Automation.Language.ParameterAst]), 'Name')))
        $body = $expression::OrElse($assigned, $expression::OrElse($loop, $bound))
    }
    $script:qualityStaticAstPredicates[$Kind] = $expression::Lambda([Func[Management.Automation.Language.Ast, bool]], $body, [Linq.Expressions.ParameterExpression[]]@($parameter)).Compile()
    return $script:qualityStaticAstPredicates[$Kind]
}

function Get-QualityScriptStaticReferences {
    param([Parameter(Mandatory = $true)][string]$RelativePath, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    # Static .ps1 loads (dot-source, call, powershell -File) resolved from the
    # file's own location. A load anchored there whose remainder is not static
    # is returned as unresolved, never skipped. A path passed through an
    # unknown command is a runtime value (fixture, copy, target project).
    $empty = [pscustomobject]@{ includes = @(); unresolved = @() }
    if ($Text -notmatch '(?i)PSScriptRoot|PSCommandPath|MyInvocation') { return $empty }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text.TrimStart([char]0xfeff), [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { return $empty }
    $file = $RelativePath.Replace('\', '/')
    $context = [pscustomobject]@{
        file = $file
        directory = $(if ($file.Contains('/')) { $file.Substring(0, $file.LastIndexOf('/')) } else { '' })
        variables = @{}
        resolved = @{}
    }
    $loads = @($ast.FindAll((Get-QualityStaticAstPredicate -Kind loads), $true))
    if ($loads.Count -eq 0) { return $empty }
    # Bind only names the load targets read, then the names their definitions
    # read, until no new name appears.
    $pattern = '(?i)\$\{?(?:script:|global:|local:|private:|using:)?([a-z_][a-z0-9_]*)'
    $pending = @(foreach ($load in $loads) { foreach ($match in [regex]::Matches([string]$load.CommandElements[0].Extent.Text, $pattern)) { $match.Groups[1].Value } })
    $requested = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $variables = $context.variables
    for ($round = 0; $round -lt 16; $round++) {
        $names = @($pending | Where-Object { $_ -notin @('PSScriptRoot', 'PSCommandPath', 'MyInvocation', 'true', 'false', 'null') -and $requested.Add($_) })
        if ($names.Count -eq 0) { break }
        $predicate = Get-QualityStaticAstPredicate -Kind bindings
        $bindingNames = $script:qualityStaticAstPredicates['bindingNames']
        $bindingNames.Clear()
        foreach ($name in $names) { foreach ($scope in @('', 'script:', 'global:', 'local:', 'private:')) { [void]$bindingNames.Add($scope + $name) } }
        $pending = @()
        foreach ($node in @($ast.FindAll($predicate, $true))) {
            $value = $null
            if ($node -is [Management.Automation.Language.AssignmentStatementAst]) {
                $left = $node.Left
                if ($left -is [Management.Automation.Language.ConvertExpressionAst]) { $left = $left.Child }
                $name = [string]$left.VariablePath.UserPath
                if ([string]$node.Operator -eq 'Equals') { $value = $node.Right }
            } elseif ($node -is [Management.Automation.Language.ForEachStatementAst]) {
                $name = [string]$node.Variable.VariablePath.UserPath
                $value = $node
            } else {
                $name = [string]$node.Name.VariablePath.UserPath
            }
            if ($name.IndexOf(':') -ge 0) { $name = $name -replace '^(?i:script|global|local|private|using):', '' }
            # A reassigned or parameter-bound name has no single static value.
            $variables[$name] = if ($variables.ContainsKey($name)) { $null } else { $value }
            if ($null -ne $value) { $pending += @(foreach ($match in [regex]::Matches([string]$value.Extent.Text, $pattern)) { $match.Groups[1].Value }) }
        }
    }
    $includes = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $unresolved = New-Object System.Collections.Generic.List[object]
    foreach ($node in $loads) {
        # A load is a dot-source, a call, or a child PowerShell -File script.
        $target = $null
        if ([string]$node.GetCommandName() -match '(?i)^(powershell|pwsh)(\.exe)?$') {
            $elements = @($node.CommandElements)
            for ($index = 1; $index -lt $elements.Count - 1; $index++) {
                if ($elements[$index] -is [Management.Automation.Language.CommandParameterAst] -and ([string]$elements[$index].ParameterName) -ieq 'File') { $target = $elements[$index + 1]; break }
            }
        } elseif ([string]$node.InvocationOperator -in @('Dot', 'Ampersand')) {
            $target = $node.CommandElements[0]
        }
        if ($null -eq $target) { continue }
        $value = Resolve-QualityStaticValue -Node $target -Context $context
        if ($null -eq $value) { continue }
        if ($value.kind -eq 'path') {
            foreach ($path in @($value.values | Where-Object { ([string]$_) -like '*.ps1' })) { [void]$includes.Add([string]$path) }
        } elseif ($value.kind -eq 'dynamic') {
            $unresolved.Add([pscustomobject]@{ source = $file; line = [int]$node.Extent.StartLineNumber; text = ([string]$node.Extent.Text -split "`r?`n")[0].Trim(); prefix = [string]$value.values[0] }) | Out-Null
        }
    }
    return [pscustomobject]@{ includes = @($includes | Sort-Object); unresolved = @($unresolved | ForEach-Object { $_ }) }
}

function New-QualityTrackedScriptIndex {
    param([AllowEmptyCollection()][string[]]$Paths)
    $byKey = @{}
    $directories = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($raw in @($Paths)) {
        $path = ([string]$raw).Replace('\', '/')
        if ($path -notlike '*.ps1') { continue }
        $byKey[$path.ToLowerInvariant()] = $path
        $directory = $path
        while ($directory.Contains('/')) { $directory = $directory.Substring(0, $directory.LastIndexOf('/')); [void]$directories.Add($directory) }
        [void]$directories.Add('')
    }
    return [pscustomobject]@{ scripts = $byKey; directories = $directories; analyses = @{}; closures = @{} }
}

function Get-QualityStaticScriptAnalysis {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot, [Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][object]$Index)
    if ($Index.analyses.ContainsKey($Source)) { return $Index.analyses[$Source] }
    $absolute = Join-Path $RepositoryRoot $Source.Replace('/', '\')
    # An analysis depends only on the path and bytes; reuse it across catalog
    # validations and digests within one process.
    $shared = Get-Variable -Name qualityStaticAnalysisCache -Scope Script -ErrorAction SilentlyContinue
    if (-not $shared -or $null -eq $shared.Value) { $script:qualityStaticAnalysisCache = @{} }
    if (-not [IO.File]::Exists($absolute)) {
        $Index.analyses[$Source] = [pscustomobject]@{ includes = @(); unresolved = @() }
    } else {
        $bytes = [IO.File]::ReadAllBytes($absolute)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $key = $Source + '|' + [BitConverter]::ToString($sha.ComputeHash($bytes)) } finally { $sha.Dispose() }
        if (-not $script:qualityStaticAnalysisCache.ContainsKey($key)) {
            $script:qualityStaticAnalysisCache[$key] = Get-QualityScriptStaticReferences -RelativePath $Source -Text ([Text.Encoding]::UTF8.GetString($bytes))
        }
        $Index.analyses[$Source] = $script:qualityStaticAnalysisCache[$key]
    }
    return $Index.analyses[$Source]
}

function Get-QualityStaticInputClosure {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [AllowEmptyCollection()][string[]]$Roots,
        [Parameter(Mandatory = $true)][object]$Index,
        [AllowEmptyCollection()][string[]]$Exclusions = @()
    )
    # The single owner of statically loaded shard inputs. Every consumer of
    # shard identity (Targeted, Full, Develop static, preview, plan) and the
    # catalog validation call this function; none keeps its own copy. Each
    # root's closure is computed once per index and then merged natively.
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $unresolved = New-Object System.Collections.Generic.List[object]
    $excluded = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($Exclusions)) { [void]$excluded.Add(([string]$path).Replace('\', '/')) }
    $exclusionKey = (@($excluded | Sort-Object) -join [char]0) + [char]1
    foreach ($root in @($Roots)) {
        $tracked = $Index.scripts[([string]$root).Replace('\', '/').ToLowerInvariant()]
        if (-not $tracked) { continue }
        $closureKey = $exclusionKey + $tracked
        if (-not $Index.closures.ContainsKey($closureKey)) {
            $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            $queue = New-Object System.Collections.Generic.Queue[string]
            $rootUnresolved = New-Object System.Collections.Generic.List[object]
            [void]$visited.Add($tracked); $queue.Enqueue($tracked)
            while ($queue.Count -gt 0) {
                $analysis = Get-QualityStaticScriptAnalysis -RepositoryRoot $RepositoryRoot -Source $queue.Dequeue() -Index $Index
                foreach ($include in @($analysis.includes)) {
                    # Untracked or external files (installed modules, runtime copies) are not repository inputs.
                    $next = $Index.scripts[([string]$include).ToLowerInvariant()]
                    # An excluded script is entered only as a root (a declared input).
                    if ($next -and -not $excluded.Contains($next) -and $visited.Add($next)) { $queue.Enqueue($next) }
                }
                foreach ($item in @($analysis.unresolved)) { if ($Index.directories.Contains([string]$item.prefix)) { $rootUnresolved.Add($item) | Out-Null } }
            }
            $Index.closures[$closureKey] = [pscustomobject]@{ paths = $visited; unresolved = @($rootUnresolved | ForEach-Object { $_ }) }
        }
        $paths.UnionWith($Index.closures[$closureKey].paths)
        foreach ($item in @($Index.closures[$closureKey].unresolved)) { $unresolved.Add($item) | Out-Null }
    }
    $distinct = @($unresolved | Sort-Object source, line, text -Unique)
    return [pscustomobject]@{
        complete = $distinct.Count -eq 0
        paths = @($paths | Sort-Object)
        unresolved = $distinct
    }
}

function Get-QualityContractStaticInputRoots {
    param([Parameter(Mandatory = $true)][object]$Catalog, [Parameter(Mandatory = $true)][object]$Index)
    # Contract scripts and reuse inputs are executed by their tests. Another
    # contract's test file matched by a broad pattern is data (for example a
    # policy reading every test), so only listed tests are roots.
    $scripts = @($Index.scripts.Values)
    $roots = @(Get-QualityPesterSharedInputPaths)
    foreach ($contract in @($Catalog.contracts)) {
        $declared = @(@($contract.paths) + @(Get-QualityContractReuseInputPaths -Contract $contract) | ForEach-Object { ([string]$_).Replace('\', '/') })
        $roots += @($contract.tests | ForEach-Object { ([string]$_).Replace('\', '/') })
        $roots += @(Select-QualityPaths -Paths $scripts -Pattern $declared | Where-Object { $_ -notlike 'tests/pester/*.Tests.ps1' })
    }
    $semantic = Get-QualityPesterSemanticInputBindings -Catalog $Catalog
    return @(@($roots) + @($semantic.paths) | Sort-Object -Unique)
}

function Assert-QualityStaticInputsResolvable {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][object]$Catalog,
        [AllowNull()][string[]]$TrackedPaths = $null
    )
    if ($null -eq $TrackedPaths) {
        if (-not (Get-Command Get-RepositoryGitPathList -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'git-path-list.ps1') }
        $TrackedPaths = @(Get-RepositoryGitPathList -RepositoryRoot $RepositoryRoot -Arguments @('ls-files', '-z', '--'))
    }
    $index = New-QualityTrackedScriptIndex -Paths $TrackedPaths
    $closure = Get-QualityStaticInputClosure -RepositoryRoot $RepositoryRoot -Roots (Get-QualityContractStaticInputRoots -Catalog $Catalog -Index $index) -Index $index
    if (-not $closure.complete) {
        $items = @($closure.unresolved | Sort-Object source, line | ForEach-Object { "$($_.source):$($_.line) '$($_.text)' under '$($_.prefix)'" })
        throw ("QUALITY_STATIC_INCLUDE_UNRESOLVED: a script load anchored in the repository is not static, so Pester shard identity cannot bind its target and such shards would not be reused. " +
            "Continue by building the path from `$PSScriptRoot with literal Join-Path children, or iterate a literal array with foreach, then repeat the same command. Unresolved: $($items -join '; ').")
    }
    return $closure
}

function Test-QualityContractCatalog {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][object]$Catalog,
        [switch]$SkipSemanticEntrypointValidation,
        [string[]]$SkipSemanticLibraryValidation = @(),
        [AllowNull()][string[]]$TrackedPaths = $null
    )

    Assert-QualityOnDemandVersionConsistency -RepositoryRoot $RepositoryRoot

    $releaseCatalogPath = Join-Path $RepositoryRoot 'scripts/release-e2e/stages.json'
    if (Test-Path -LiteralPath $releaseCatalogPath -PathType Leaf) {
        $releaseCatalog = Get-QualityReleaseStageCatalog -RepositoryRoot $RepositoryRoot
        if ($releaseCatalog.PSObject.Properties['enclosingOverheadSeconds']) {
            [void](Get-ReleaseE2EBudgetProjection -StageCatalog $releaseCatalog -QualityCatalog $Catalog -RequireRelease)
        }
    }
    $targetedImplicitDefault = [int]$Catalog.pesterWorkers.targetedImplicitDefault
    if ($targetedImplicitDefault -lt 1 -or $targetedImplicitDefault -gt 8) { throw "Quality contract pesterWorkers.targetedImplicitDefault must be between 1 and 8." }
    $qualificationDefault = $Catalog.pesterWorkers.PSObject.Properties['qualificationImplicitDefault']
    if ($qualificationDefault -and ([int]$qualificationDefault.Value -lt 1 -or [int]$qualificationDefault.Value -gt 8)) {
        throw 'Quality contract pesterWorkers.qualificationImplicitDefault must be between 1 and 8.'
    }

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
    if($Catalog.developJourneys.PSObject.Properties['scenarios']) {
        foreach($name in $expectedDevelopJourneys) {[void](Get-DevelopScenarioCatalog $Catalog $name)}
        $known=@(foreach($name in $expectedDevelopJourneys) {Get-DevelopScenarioCatalog $Catalog $name | ForEach-Object {"$name.$($_.id)"}})
        $rulePaths=@()
        foreach($rule in @($Catalog.developJourneys.scenarioInputs)) {
            if($rule.path -in $rulePaths -or [IO.Path]::IsPathRooted($rule.path) -or $rule.path -match '(^|/)\.\.(/|$)' -or
                ($rule.path -notin $SkipSemanticLibraryValidation -and -not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $rule.path) -PathType Leaf)) -or
                @($rule.PSObject.Properties.Name | Where-Object {$_ -notin @('path','functions','requiresNoProductContext','outsideWhenNoProductContext')}).Count) {throw 'DEVELOP_SCENARIO_INPUT_INVALID'}
            if($rule.PSObject.Properties['requiresNoProductContext'] -and $rule.requiresNoProductContext -isnot [bool]) {throw 'DEVELOP_SCENARIO_INPUT_INVALID'}
            if($rule.PSObject.Properties['outsideWhenNoProductContext'] -and
                ($rule.outsideWhenNoProductContext -isnot [bool] -or -not $rule.PSObject.Properties['requiresNoProductContext'] -or -not $rule.requiresNoProductContext)) {throw 'DEVELOP_SCENARIO_INPUT_INVALID'}
            $rulePaths+=([string]$rule.path)
            foreach($function in $rule.functions.PSObject.Properties) {
                if(-not $function.Name -or @($function.Value).Count -eq 0 -or
                    @($function.Value | Where-Object {$_ -notin $known}).Count -or
                    @($function.Value | Sort-Object -Unique).Count -ne @($function.Value).Count) {throw 'DEVELOP_SCENARIO_INPUT_INVALID'}
            }
        }
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
        [void](Get-QualityContractReuseInputPaths -Contract $contract)
        $exclusions = @(Get-QualityContractStaticInputExclusions -Contract $contract)
        $declaredExclusions = @(Select-QualityPaths -Paths $exclusions -Pattern @(@($contract.paths) + @(Get-QualityContractReuseInputPaths -Contract $contract)))
        $missingExclusions = @($exclusions | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $_.Replace('/', '\')) -PathType Leaf) })
        if ($declaredExclusions.Count -gt 0 -or $missingExclusions.Count -gt 0) {
            throw "Quality contract '$($contract.id)' staticInputExclusions must name existing scripts it does not declare: $(@($declaredExclusions + $missingExclusions) -join ', ')."
        }
        if (-not [string]$contract.owner -or -not [string]$contract.primaryTest -or [int]$contract.budgetSeconds -le 0 -or @($contract.paths).Count -eq 0 -or @($contract.tests).Count -eq 0) {
            throw "Quality contract '$($contract.id)' must define owner, primaryTest, budgetSeconds, paths, and tests."
        }
        if ([string]$contract.primaryTest -notin @($contract.tests | ForEach-Object { [string]$_ })) { throw "Quality contract '$($contract.id)' primaryTest must be present in tests." }
        foreach ($test in @($contract.tests)) {
            $testPath = Join-Path $RepositoryRoot ([string]$test).Replace('/', '\')
            if (-not (Test-Path -LiteralPath $testPath -PathType Leaf)) { throw "Quality contract '$($contract.id)' references missing test '$test'." }
        }
    }
    $allowedPesterExternalInputs = @(Get-QualityPesterExternalInputNames)
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
        [void](Get-DevelopE2EJourneyHardBudgetSeconds -Catalog $Catalog -Journey $journeyName)
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
    # Shard identity binds static script loads automatically; a load it cannot
    # resolve would silently disable reuse, so the catalog owner rejects it.
    [void](Assert-QualityStaticInputsResolvable -RepositoryRoot $RepositoryRoot -Catalog $Catalog -TrackedPaths $TrackedPaths)

    if (-not $SkipSemanticEntrypointValidation -and $Catalog.PSObject.Properties['semanticTargeting']) {
    $actualActions = @(Get-PublicLifecycleActions -RepositoryRoot $RepositoryRoot)
    $coveredActions = @(
        @($Catalog.lifecycleActions.journey) + @($Catalog.lifecycleActions.boundary) |
            ForEach-Object { [string]$_ } |
            Sort-Object -Unique
    )


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
    # One message names every registry that misses or still lists an action.
    $actionRegistries = [ordered]@{
        'tests/quality-contracts.json lifecycleActions (journey/boundary)' = @{ names = $coveredActions }
        'agent-1c.ps1 literal dispatch labels' = @{ names = $dispatchActions }
        'tests/quality-contracts.json semanticTargeting.actionOwners' = @{ names = $actionOwners }
    }
    $advancedActionsPath = Join-Path $RepositoryRoot '.agents\skills\1c-workflow\references\advanced-actions.md'
    if (Test-Path -LiteralPath $advancedActionsPath -PathType Leaf) {
        $actionRegistries['.agents/skills/1c-workflow/references/advanced-actions.md Common internal actions'] = @{
            names = @(Get-QualityAdvancedActionCatalog -Text ([IO.File]::ReadAllText($advancedActionsPath))); ignore = @('help')
        }
    }
    $registryMismatches = @(Get-QualityActionRegistryMismatches -Actions $actualActions -Registries $actionRegistries)
    if ($registryMismatches.Count -gt 0) {
        throw "ACTION_REGISTRY_MISMATCH: every public action of agent-1c.ps1 must be registered everywhere. $($registryMismatches -join '; ')."
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
    $semanticProperty = $Catalog.PSObject.Properties['semanticTargeting']
    $libraryProperty = if ($semanticProperty) { $semanticProperty.Value.PSObject.Properties['libraries'] } else { $null }
    if ($libraryProperty) {
        foreach ($library in @($libraryProperty.Value.PSObject.Properties)) {
            $path = [string]$library.Name
            if ($path -notmatch '^\.agents/skills/1c-workflow/scripts/lib/agent-1c\.[a-z0-9-]+\.ps1$' -or
                @($Catalog.contracts | Where-Object { $path -in @($_.paths) }).Count -eq 0) {
                throw "Semantic library '$path' must be an exact catalog-owned helper module."
            }
            $model = if ($path -notin $SkipSemanticLibraryValidation) {
                Get-Agent1cSemanticModel -Text ([IO.File]::ReadAllText((Join-Path $RepositoryRoot $path), [Text.Encoding]::UTF8)) -Library
            } else { $null }
            if ($null -ne $model -and -not $model.valid) { throw "Semantic library '$path' is not parseable." }
            foreach ($node in @($library.Value.functions.PSObject.Properties)) {
                # The existing entrypoint validation proves this declared set;
                # its missing-file fallback must still select complete tests.
                $libraryActions = @($Catalog.lifecycleActions.journey) + @($Catalog.lifecycleActions.boundary)
                if ($null -ne $model -and -not $model.functions.ContainsKey($node.Name)) { throw "Semantic library function '$($node.Name)' does not exist in '$path'." }
                $tests = @($node.Value.tests)
                $ids = @($node.Value.probes)
                if ($tests.Count -eq 0 -or @($tests | Sort-Object -Unique).Count -ne $tests.Count -or
                    @($tests | Where-Object { $_ -notin $ownedTests }).Count -gt 0 -or
                    $ids.Count -eq 0 -or @($ids | Sort-Object -Unique).Count -ne $ids.Count -or
                    [string]$node.Value.action -notin $libraryActions -or
                    [string]$node.Value.callsSha256 -cnotmatch '^[a-f0-9]{64}$') {
                    throw "Semantic library function '$($node.Name)' needs owned tests and unique public probes."
                }
                $libraryProbes = @(Get-Agent1cEntrypointProbeInventory -RepositoryRoot $RepositoryRoot -TestPaths $tests)
                foreach ($id in $ids) {
                    $probe = @($libraryProbes | Where-Object id -CEQ $id)
                    if ($probe.Count -ne 1 -or [string]$probe[0].action -cne [string]$node.Value.action) {
                        throw "Semantic library function '$($node.Name)' has no matching public probe '$id'."
                    }
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

function Select-QualityPaths {
    param([AllowEmptyCollection()][string[]]$Paths,[AllowEmptyCollection()][string[]]$Pattern)
    # Compile once per inventory, preserving PowerShell's wildcard/case rules.
    # Calling a script function for every file x pattern dominated warm Plan.
    $matchers=@(foreach($item in $Pattern) {
        [Management.Automation.WildcardPattern]::new($item.Replace('\','/'),[Management.Automation.WildcardOptions]::IgnoreCase)
    })
    foreach($raw in $Paths) {
        $path=$raw.Replace('\','/')
        foreach($matcher in $matchers) {
            if($matcher.IsMatch($path)) {$path; break}
        }
    }
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
        $matches = @(foreach($contract in $Catalog.contracts) {
            foreach($pattern in $contract.paths) {
                if($path -like ([string]$pattern).Replace('\','/')) {$contract; break}
            }
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
