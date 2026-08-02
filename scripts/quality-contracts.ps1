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

function Test-QualityContractCatalog {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][object]$Catalog
    )

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
