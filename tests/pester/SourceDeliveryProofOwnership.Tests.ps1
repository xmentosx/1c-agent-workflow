BeforeAll {
    . (Join-Path $PSScriptRoot 'SourceDelivery.TestSupport.ps1')
    . (Join-Path $RepoRoot 'scripts/quality-contracts.ps1')
    . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')

    $script:ProofOwnershipAsts = @{}
    function Get-ProofOwnershipAst([string]$Relative) {
        if (-not $script:ProofOwnershipAsts.ContainsKey($Relative)) {
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $Relative), [ref]$tokens, [ref]$errors)
            @($errors) | Should -BeNullOrEmpty -Because "$Relative must parse"
            $script:ProofOwnershipAsts[$Relative] = $ast
        }
        return $script:ProofOwnershipAsts[$Relative]
    }

    # Static `. (Join-Path $PSScriptRoot 'x')` loads, relative to the loading file.
    $script:ProofOwnershipLoads = @{}
    function Get-ProofOwnershipStaticLoads([string]$Relative) {
        if ($script:ProofOwnershipLoads.ContainsKey($Relative)) { return $script:ProofOwnershipLoads[$Relative] }
        $directory = (Split-Path -Parent $Relative).Replace('\', '/')
        $ast = Get-ProofOwnershipAst $Relative
        $script:ProofOwnershipLoads[$Relative] = @(foreach ($command in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.InvocationOperator -eq 'Dot' }, $true)) {
            $text = $command.CommandElements[0].Extent.Text
            if ($text -match '^\(Join-Path \$PSScriptRoot [''"]([^''"$]+)[''"]\)$') {
                ($directory + '/' + $Matches[1]).Replace('\', '/')
            } elseif ($text -match '^\(Join-Path \(Split-Path -Parent \$PSScriptRoot\) [''"]([^''"$]+)[''"]\)$') {
                $parent = (Split-Path -Parent $directory).Replace('\', '/')
                $(if ($parent) { $parent + '/' + $Matches[1] } else { $Matches[1] }).Replace('\', '/')
            }
        })
        return $script:ProofOwnershipLoads[$Relative]
    }

    function Get-ProofOwnershipClosure([string[]]$Roots) {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        $pending = New-Object System.Collections.Generic.Queue[string]
        foreach ($root in $Roots) { $pending.Enqueue($root) }
        while ($pending.Count) {
            $relative = $pending.Dequeue()
            if (-not $seen.Add($relative)) { continue }
            if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $relative) -PathType Leaf)) { throw "Statically loaded file is missing: $relative" }
            foreach ($loaded in @(Get-ProofOwnershipStaticLoads $relative)) { $pending.Enqueue($loaded) }
        }
        return @($seen | Sort-Object)
    }

    function Get-ProofOwnershipStrings([Management.Automation.Language.Ast]$Ast) {
        @($Ast.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object Value)
    }

    # Each consumer's statically declared delivery source reads and executions.
    # Unresolvable names fail instead of silently narrowing the proof inputs.
    $script:DeliverySourceConsumers = $null
    function Get-DeliverySourceConsumers {
        if ($script:DeliverySourceConsumers) { return $script:DeliverySourceConsumers }
        $sourceFiles = @($DeliverySourcePaths | ForEach-Object { 'scripts/' + (Split-Path -Leaf $_) })
        $definingFile = @{}
        foreach ($source in $sourceFiles) {
            foreach ($definition in (Get-ProofOwnershipAst $source).FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
                $definingFile[$definition.Name] = $source
            }
        }
        # The entrypoint starts the supervisor as a child; both load their modules statically.
        $entrypoint = Get-ProofOwnershipClosure @('scripts/source-delivery.ps1', 'scripts/source-delivery-supervisor.ps1')
        $support = 'tests/pester/SourceDelivery.TestSupport.ps1'
        $unitFiles = @{}
        # Reaching the delivery support requires a static load other than the
        # shared TestSupport.ps1; other suites are skipped before AST traversal.
        $loadsSupport = 'Join-Path \$PSScriptRoot [''"](?!TestSupport\.ps1[''"])[^''"]+\.ps1'
        $script:DeliverySourceConsumers = @(foreach ($testFile in @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'tests/pester') -Filter '*.Tests.ps1' | Sort-Object Name)) {
            if ([IO.File]::ReadAllText($testFile.FullName) -notmatch $loadsSupport) { continue }
            $test = 'tests/pester/' + $testFile.Name
            $units = @(Get-ProofOwnershipClosure @($test) | Where-Object { $_ -like 'tests/pester/*' })
            if ($support -notin $units) { continue }
            $files = New-Object System.Collections.Generic.List[string]
            foreach ($unit in $units) {
                if ($unit -ne 'tests/pester/TestSupport.ps1') { $files.Add($unit) }
                if ($unitFiles.ContainsKey($unit)) { foreach ($file in $unitFiles[$unit]) { $files.Add($file) }; continue }
                $unitStart = $files.Count
                $ast = Get-ProofOwnershipAst $unit
                $commands = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
                $variables = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.VariablePath.UserPath })
                foreach ($call in @($commands | Where-Object { $_.GetCommandName() -eq 'Get-DeliveryFunctionDefinitions' })) {
                    $names = @($call.CommandElements | Select-Object -Skip 1 | ForEach-Object {
                        if ($_ -is [Management.Automation.Language.VariableExpressionAst]) {
                            $name = '$' + $_.VariablePath.UserPath
                            foreach ($assignment in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq $name }, $true)) {
                                Get-ProofOwnershipStrings $assignment.Right
                            }
                        } else { Get-ProofOwnershipStrings $_ }
                    })
                    $names.Count | Should -BeGreaterThan 0 -Because "$unit line $($call.Extent.StartLineNumber) must name its delivery definitions statically"
                    foreach ($name in $names) {
                        # An absent name asserts absence across every delivery module.
                        if ($definingFile.ContainsKey($name)) { $files.Add($definingFile[$name]) } else { foreach ($source in $sourceFiles) { $files.Add($source) } }
                    }
                }
                foreach ($call in @($commands | Where-Object { $_.GetCommandName() -in @('Get-TestFunctionClosure', 'Import-TestFunctionClosure') })) {
                    # A call closure indexes every owner file named by -Path; owners
                    # outside delivery are bound by their own contracts. The shared
                    # $DeliverySourcePaths form is covered by the unit-wide rule below.
                    foreach ($name in @(Get-ProofOwnershipStrings $call | ForEach-Object { 'scripts/' + (Split-Path -Leaf $_) } | Where-Object { $_ -in $sourceFiles })) { $files.Add($name) }
                }
                foreach ($call in @($commands | Where-Object { $_.GetCommandName() -eq 'Get-DeliverySourceText' })) {
                    if (@($call.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'All' }).Count) {
                        foreach ($source in $sourceFiles) { $files.Add($source) }
                        continue
                    }
                    $named = @(Get-ProofOwnershipStrings $call | Where-Object { ('scripts/' + $_) -in $sourceFiles })
                    $named.Count | Should -BeGreaterThan 0 -Because "$unit line $($call.Extent.StartLineNumber) must name the delivery module it reads"
                    foreach ($name in $named) { $files.Add('scripts/' + $name) }
                }
                if ('DeliverySourceText' -in $variables) {
                    # Text is read only from files declared at the assertion site.
                    @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                        $node.Left.Extent.Text -eq '$DeliverySourceText' -and $node.Right.Extent.Text -like 'Get-DeliverySourceText *' }, $true)).Count |
                        Should -BeGreaterThan 0 -Because "$unit must assign DeliverySourceText from named sources"
                }
                if ($unit -ne $support) {
                    if ('DeliverySourcePaths' -in $variables) { foreach ($source in $sourceFiles) { $files.Add($source) } }
                    if ('DeliveryScript' -in $variables -or @($commands | Where-Object { $_.GetCommandName() -eq 'Invoke-DeliveryTestPowerShell' }).Count) {
                        foreach ($source in $entrypoint) { $files.Add($source) }
                    }
                }
                $unitFiles[$unit] = @($files.GetRange($unitStart, $files.Count - $unitStart))
            }
            [pscustomobject]@{ test = $test; files = @($files | Sort-Object -Unique) }
        })
        return $script:DeliverySourceConsumers
    }
}

Describe 'Delivery test source proof ownership' {
    It 'declares every delivery source text read at its assertion site' {
        $support = Get-ProofOwnershipAst 'tests/pester/SourceDelivery.TestSupport.ps1'
        @($support.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$DeliverySourceText' }, $true)) |
            Should -BeNullOrEmpty -Because 'an aggregate of every delivery module hides which file an assertion reads'
        $consumers = @(Get-DeliverySourceConsumers)
        $byTest = @{}; foreach ($consumer in $consumers) { $byTest[$consumer.test] = $consumer.files }
        # Representative consumers of each recognized form.
        $byTest['tests/pester/SourceDeliveryComponentPublication.Tests.ps1'] | Should -Contain 'scripts/source-delivery-candidate.ps1'
        $byTest['tests/pester/SourceDeliveryPublish.Tests.ps1'] | Should -Contain 'scripts/source-delivery-supervisor.ps1'
        $byTest['tests/pester/SourceDeliveryProcess.Tests.ps1'] | Should -Contain 'scripts/source-delivery-component.ps1'
        $byTest['tests/pester/ToolingReadiness.Tests.ps1'] | Should -Contain 'scripts/source-delivery-process.ps1'
        $byTest['tests/pester/SourceDeliveryProcessLifetime.Tests.ps1'] | Should -Not -Contain 'scripts/source-delivery-queue.ps1'
        # Call-closure form: the named owner file and the closure support are inputs.
        $byTest['tests/pester/SourceDeliveryProcessLifetime.Tests.ps1'] | Should -Contain 'scripts/source-delivery-process.ps1'
        $byTest['tests/pester/SourceDeliveryProcessLifetime.Tests.ps1'] | Should -Contain 'tests/pester/FunctionClosure.TestSupport.ps1'
        $byTest['tests/pester/SourceDeliveryCandidateIntegrity.Tests.ps1'] | Should -Contain 'tests/pester/SourceDeliveryFrozen.TestSupport.ps1'
        $entrypoint = $byTest['tests/pester/SourceDeliveryQueue.Tests.ps1']
        foreach ($loaded in @('scripts/release-artifact-paths.ps1', 'scripts/develop-e2e-cleanup.ps1', '.agents/skills/1c-workflow/scripts/lib/agent-1c.immutable-download.ps1')) {
            $entrypoint | Should -Contain $loaded
        }
    }

    It 'invalidates each consumer proof when a delivery source it reads or executes changes' {
        # 4960495a reworded a candidate message asserted by ComponentPublication;
        # that suite's stale proof was reused through Develop and Release.
        $consumers = @(Get-DeliverySourceConsumers)
        $actualCatalog = Get-QualityContractCatalog -RepositoryRoot $RepoRoot
        $tracked = @(Get-RepositoryGitPathList -RepositoryRoot $RepoRoot -Arguments @('ls-files', '-z', '--cached'))
        $shardAst = Get-ProofOwnershipAst 'scripts/invoke-pester-shards.ps1'
        & {
            foreach ($name in @('Get-ShardRelativeTestPath', 'Get-ShardExternalProfiles', 'Get-ShardInputDigest', 'Get-TextSha256')) {
                $definition = $shardAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true)
                $definition | Should -Not -BeNullOrEmpty
                . ([scriptblock]::Create($definition.Extent.Text))
            }
            function Get-ShardTrackedFileIdentity {
                param($RelativePath, $AbsolutePath)
                [IO.File]::ReadAllText($AbsolutePath)
            }
            $RepositoryRoot = Join-Path $TestDrive 'Владелец proof с пробелом'
            $catalog = $actualCatalog.PSObject.Copy()
            $catalog.PSObject.Properties.Remove('pesterExternalRuntimeTests')
            $script:pesterRuntimeReceipt = [pscustomobject]@{ status = 'known'; identity = [pscustomobject]@{ powerShellVersion = [string]$PSVersionTable.PSVersion; pesterVersion = 'fixture'; identitySha256 = ('a' * 64) } }
            $sharedInputs = @()
            $pesterExternalInputsByTest = @{}
            $trackedPaths = $tracked
            $sources = @($consumers | ForEach-Object { $_.files } | Sort-Object -Unique)
            foreach ($relative in @($sources + @($consumers | ForEach-Object test))) {
                $absolute = Join-Path $RepositoryRoot $relative
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $absolute) | Out-Null
                [IO.File]::WriteAllText($absolute, "unchanged $relative", [Text.UTF8Encoding]::new($false))
            }
            $digest = @{}
            foreach ($consumer in $consumers) {
                $digest[$consumer.test] = Get-ShardInputDigest -Paths @((Join-Path $RepositoryRoot $consumer.test))
                $digest[$consumer.test] | Should -Not -BeNullOrEmpty -Because "$($consumer.test) needs a complete reusable owner set"
            }
            $unrelated = 'tests/pester/SourceDeliveryProcessLifetime.Tests.ps1'
            $stale = New-Object System.Collections.Generic.List[string]
            $unrelatedReused = $false
            foreach ($source in $sources) {
                [IO.File]::AppendAllText((Join-Path $RepositoryRoot $source), "`n# changed", [Text.UTF8Encoding]::new($false))
                foreach ($consumer in $consumers) {
                    $changed = Get-ShardInputDigest -Paths @((Join-Path $RepositoryRoot $consumer.test))
                    if ($source -in $consumer.files -and $changed -ceq $digest[$consumer.test]) { $stale.Add("$($consumer.test) <- $source") }
                    if ($consumer.test -eq $unrelated -and $source -eq 'scripts/source-delivery-queue.ps1') { $unrelatedReused = $changed -ceq $digest[$consumer.test] }
                    $digest[$consumer.test] = $changed
                }
            }
            @($stale) | Should -BeNullOrEmpty -Because 'a changed source that a consumer reads or executes must invalidate its proof'
            $unrelatedReused | Should -BeTrue -Because 'process lifetime proof does not load the queue module and stays reusable'
        }
    }
}
