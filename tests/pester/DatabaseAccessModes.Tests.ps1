Describe 'Database access mode producer inventory' {
    BeforeAll {
        $repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        $manifest = Get-Content -LiteralPath (Join-Path $repo 'tests/database-access-producers.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $canonicalModes = @('shared-read', 'functional-test', 'measurement-exclusive', 'mutation-exclusive')
    }

    It 'discovers every production PowerShell admission and transition through the AST' {
        $productionPaths = @(
            Get-ChildItem -LiteralPath (Join-Path $repo '.agents/skills/1c-workflow/scripts') -Filter '*.ps1' -Recurse -File
            Get-ChildItem -LiteralPath (Join-Path $repo '.agents/skills/itl-remote-runner/scripts') -Filter '*.ps1' -Recurse -File
            Get-ChildItem -LiteralPath (Join-Path $repo 'scripts') -Filter '*.ps1' -Recurse -File
        )
        $actual = [Collections.Generic.List[string]]::new()
        foreach ($path in $productionPaths) {
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($path.FullName, [ref]$tokens, [ref]$errors)
            @($errors) | Should -HaveCount 0
            foreach ($command in @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -in @('Start-ItlDatabaseAccessHost', 'Set-ItlDevBranchDatabaseAccessMode', 'Set-ItlDatabaseAccessMode')
            }, $true))) {
                $owner = $command.Parent
                while ($null -ne $owner -and $owner -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $owner = $owner.Parent }
                $functionName = if ($null -eq $owner) { '<script>' } else { $owner.Name }
                $path.FullName.StartsWith(($repo.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
                $relative = $path.FullName.Substring($repo.TrimEnd('\').Length).TrimStart('\', '/').Replace('\', '/')
                $siteKey = "$relative|$functionName|$($command.GetCommandName())"
                $actual.Add($siteKey)
                $expectedSite = @($manifest.powershellCommands | Where-Object { "$($_.file)|$($_.function)|$($_.command)" -ceq $siteKey })
                $expectedSite | Should -HaveCount 1

                if ($expectedSite[0].mode -eq 'parameter-canonical') {
                    $modeIndex = [Array]::IndexOf([object[]]$command.CommandElements, ($command.CommandElements | Where-Object {
                        $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -ceq 'AccessMode'
                    } | Select-Object -First 1))
                    $modeAst = $command.CommandElements[$modeIndex + 1]
                    $modeAst -is [Management.Automation.Language.VariableExpressionAst] | Should -BeTrue
                    $modeAst.VariablePath.UserPath | Should -Be 'AccessMode'
                    $parameter = @($owner.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'AccessMode' })
                    $parameter | Should -HaveCount 1
                    $validateSet = @($parameter[0].Attributes | Where-Object { $_.TypeName.FullName -ceq 'ValidateSet' })
                    $validateSet | Should -HaveCount 1
                    @($validateSet[0].PositionalArguments | ForEach-Object { $_.SafeGetValue() }) |
                        Should -Be @('functional-test', 'mutation-exclusive')
                } elseif ($command.GetCommandName() -eq 'Set-ItlDevBranchDatabaseAccessMode') {
                    $modeIndex = [Array]::IndexOf([object[]]$command.CommandElements, ($command.CommandElements | Where-Object {
                        $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -ceq 'AccessMode'
                    } | Select-Object -First 1))
                    $modeAst = $command.CommandElements[$modeIndex + 1]
                    $modeAst -is [Management.Automation.Language.StringConstantExpressionAst] | Should -BeTrue
                    $modeAst.Value | Should -BeIn $canonicalModes
                    $modeAst.Value | Should -Be $expectedSite[0].mode
                } elseif ($expectedSite[0].mode -in $canonicalModes) {
                    $scope = if ($null -eq $owner) { $ast } else { $owner }
                    $literalModes = [Collections.Generic.List[string]]::new()
                    foreach ($hashtable in @($scope.FindAll({ param($node) $node -is [Management.Automation.Language.HashtableAst] }, $true))) {
                        foreach ($pair in $hashtable.KeyValuePairs) {
                            try { $key = [string]$pair.Item1.SafeGetValue() } catch { continue }
                            if ($key -cne 'accessMode') { continue }
                            try { $literalModes.Add([string]$pair.Item2.SafeGetValue()) } catch { }
                        }
                    }
                    $literalModes | Should -Contain $expectedSite[0].mode
                }
            }
        }
        $expected = @($manifest.powershellCommands | ForEach-Object { "$($_.file)|$($_.function)|$($_.command)" })
        @($actual | Sort-Object) | Should -Be @($expected | Sort-Object)
        @($manifest.powershellCommands.mode | Where-Object { $_ -notin @($canonicalModes + 'operation-classified' + 'plan-canonical' + 'parameter-canonical') }) | Should -HaveCount 0
    }
}
