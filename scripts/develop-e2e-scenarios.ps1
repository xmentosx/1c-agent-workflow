# Source qualification only. The catalog owns coverage; this module owns no
# queue, lock or installed state. Unknown inputs retain the full native route.
function Expand-DevelopScenarioSelection {
    param([object]$Catalog,[string]$Journey,[string[]]$Scenario=@())
    $items=@(Get-DevelopScenarioCatalog $Catalog $Journey)
    if(-not $items.Count) {return @()}
    $wanted=@($Scenario)
    if(@($wanted | Where-Object {$_ -notin @($items.id)}).Count) {throw 'DEVELOP_SCENARIO_UNKNOWN'}
    for($i=$items.Count-1;$i -ge 0;$i--) {
        if($items[$i].id -in $wanted) {$wanted+=@($items[$i].dependsOn)}
    }
    return @($items | Where-Object {$_.id -in $wanted} | ForEach-Object {[string]$_.id})
}

function Assert-DevelopScenarioCompletion {
    param([object]$Catalog,[string]$Journey,[object]$Result,[object[]]$Steps)
    if($Journey -eq 'fresh') {
        $observed=@($Result.operationTimings | Where-Object status -eq 'passed' | ForEach-Object name)
        foreach($item in @(Get-DevelopScenarioCatalog $Catalog $Journey | Where-Object {$_.id -in @($Result.coverage)})) {
            if(@($item.operations | Where-Object {$_ -notin $observed}).Count) {throw "DEVELOP_SCENARIO_OPERATIONS_MISSING: $Journey.$($item.id)"}
        }
    } else {
        if(-not @($Steps | Where-Object {$_.name -eq 'upgrade-update-workflow' -and $_.status -eq 'passed'}).Count) {throw 'DEVELOP_SCENARIO_OPERATIONS_MISSING: upgrade.update'}
        if('verification-export' -in @($Result.coverage)) {
            $positive=if($Result.Contains('positiveJourney')) {$Result.positiveJourney.summary.steps} else {$Steps}
            foreach($name in @('upgrade-check','upgrade-export')) {
                if(-not @($positive | Where-Object {$_.name -eq $name -and $_.status -eq 'passed'}).Count) {throw "DEVELOP_SCENARIO_OPERATIONS_MISSING: $name"}
            }
        }
    }
}

function Get-DevelopChangedFunctions {
    param([string]$Before,[string]$After)
    if($Before.StartsWith([string][char]0xfeff) -ne $After.StartsWith([string][char]0xfeff)) {return $null}
    $maps=@();$remainders=@();$contexts=@()
    foreach($text in @($Before,$After)) {
        $text=$text.Replace("`r`n","`n")
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($text.TrimStart([char]0xfeff),[ref]$tokens,[ref]$errors)
        if(@($errors).Count) {throw 'DEVELOP_SCENARIO_SOURCE_PARSE_ERROR'}
        $map=@{};$context=@{};$builder=[Text.StringBuilder]::new($text.TrimStart([char]0xfeff))
        $nodes=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst]})
        foreach($node in $nodes) {
            $map[$node.Name]=ConvertTo-DevelopSourceTokens $node.Extent.Text
            $locals=@('null','true','false','_','psitem','psboundparameters','psscriptroot','args','input','pscmdlet','pscommandpath')
            if($node.Body.ParamBlock) {$locals+=@($node.Body.ParamBlock.Parameters | ForEach-Object {$_.Name.VariablePath.UserPath.ToLowerInvariant()})}
            foreach($assignment in @($node.Body.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst]},$true))) {
                $locals+=@($assignment.Left.FindAll({param($n)$n -is [Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.IsUnqualified},$true) | ForEach-Object {$_.VariablePath.UserPath.ToLowerInvariant()})
            }
            $locals+=@($node.Body.FindAll({param($n)$n -is [Management.Automation.Language.ForEachStatementAst]},$true) | ForEach-Object {$_.Variable.VariablePath.UserPath.ToLowerInvariant()})
            $context[$node.Name]=@($node.Body.FindAll({param($n)$n -is [Management.Automation.Language.VariableExpressionAst]},$true) | ForEach-Object {$_.VariablePath.UserPath.ToLowerInvariant()} | Where-Object {$_ -notin $locals} | Sort-Object -Unique)
        }
        foreach($node in @($nodes | Sort-Object {$_.Extent.StartOffset} -Descending)) {
            [void]$builder.Remove($node.Extent.StartOffset,$node.Extent.EndOffset-$node.Extent.StartOffset)
        }
        $maps+=,$map;$contexts+=,$context;$remainders+=ConvertTo-DevelopSourceTokens $builder.ToString()
    }
    if($remainders[0] -cne $remainders[1]) {return $null}
    foreach($name in @($maps[0].Keys | Where-Object {$maps[1].ContainsKey($_)})) {
        if(@($contexts[1][$name] | Where-Object {$_ -notin @($contexts[0][$name])}).Count) {return $null}
    }
    return ,@(@($maps[0].Keys)+@($maps[1].Keys) | Sort-Object -Unique | Where-Object {$maps[0][$_] -cne $maps[1][$_]})
}

function Resolve-DevelopScenarioSelection {
    param([string]$RepositoryRoot,[string]$BaseRef,[string[]]$Paths,[object]$Catalog,[string]$Journey)
    $items=@(Get-DevelopScenarioCatalog $Catalog $Journey)
    $selected=@();$reasons=@()
    foreach($path in $Paths) {
        if($path -like 'tests/pester/*.Tests.ps1' -or (Test-DevelopJourneyUnaffectedPath $RepositoryRoot $path $BaseRef $Journey)) {continue}
        $selection=Resolve-QualityContractsForPaths -Catalog $Catalog -Paths @($path)
        if($path -notin @($Catalog.developJourneys.fullPaths) -and
            -not @($selection.contracts.id | Where-Object {$_ -in @($Catalog.developJourneys.routes.$Journey.contracts)}).Count) {continue}
        $rules=@($Catalog.developJourneys.scenarioInputs | Where-Object {$_.path -ceq $path})
        $affected=@();$matched=$false
        if($rules.Count -eq 1 -and $BaseRef -and $rules[0].PSObject.Properties['functions']) {
            try {
                $old=Get-DevelopHistoricalSourceText $RepositoryRoot $BaseRef $path
                $new=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $RepositoryRoot $path)))
                $changed=Get-DevelopChangedFunctions $old $new
                if($null -ne $changed -and @($changed | Where-Object {$_ -notin @($rules[0].functions.PSObject.Properties.Name)}).Count -eq 0) {
                    $matched=$true
                    foreach($name in $changed) {$affected+=@($rules[0].functions.$name | Where-Object {$_ -like "$Journey.*"} | ForEach-Object {$_.Substring($Journey.Length+1)})}
                }
            } catch {$matched=$false}
        }
        if(-not $matched) {$affected=@($items.id)}
        $selected+=@($affected)
        if($affected.Count) {$reasons+=,[pscustomobject]@{path=$path;scenarios=@($affected | Sort-Object -Unique);basis=$(if($matched){'changed-owned-functions'}else{'unclassified-native-input'})}}
    }
    return [pscustomobject]@{selected=@(Expand-DevelopScenarioSelection $Catalog $Journey $selected);reasons=$reasons}
}

function Get-DevelopScenarioCoverage {
    param([object]$Report,[object]$Catalog,[string]$Journey)
    if($Report.PSObject.Properties['coverage']) {return @($Report.coverage | ForEach-Object {[string]$_})}
    # Schema 1 is the original complete journey. A partial execution is always
    # schema 2 with explicit coverage; it can never acquire legacy full status.
    if([int]$Report.schemaVersion -eq 1) {
        if($Journey -eq 'upgrade') {return @('update','configuration-rejection','verification-export')}
        return @('install','branch','verification','stale-export','refresh','close')
    }
    return @()
}

function Get-DevelopScenarioSourceProjection {
    param([string]$Path,[string]$Text,[string]$Journey,[string[]]$Scenario,[object]$Catalog,[bool]$NoProductContext=$false)
    $Text=$Text.Replace("`r`n","`n")
    $bom=[string]$Text.StartsWith([string][char]0xfeff)
    $controller=@()
    switch -Exact ($Path) {
        'scripts/check.ps1' {$controller=@('Ensure-DevelopE2ERoute','Get-WorkflowGateScriptPaths')}
        'scripts/develop-e2e-scenarios.ps1' {$controller=@('Get-DevelopChangedFunctions','Resolve-DevelopScenarioSelection','Get-DevelopScenarioCoverage','Get-DevelopScenarioSourceProjection','ConvertTo-DevelopEffectiveClientIdentity','Test-DevelopScenarioEquivalentInput','Get-DevelopScenarioReusePlan','Test-DevelopScenarioEvidence','Invoke-DevelopScenarioJourney','Invoke-DevelopScenarioJourneyCore','Save-DevelopScenarioExecution')}
        'scripts/quality-contracts.ps1' {$controller=@('Get-QualityContractReuseInputPaths','Get-DevelopE2EJourneyContractProjection','Get-QualityReleaseStageCatalog','Resolve-QualityReleaseCapabilities','ConvertTo-QualityBudgetSeconds','Get-ReleaseE2EBudgetProjection','Get-DevelopE2EJourneyHardBudgetSeconds','Resolve-PesterWorkerCount','Get-PublicLifecycleActions','Get-Agent1cSemanticModel','Resolve-Agent1cSemanticImpact','Get-Agent1cEntrypointProbeInventory','Test-QualityContractCatalog','Test-QualityPathPattern','Select-QualityPaths','Resolve-QualityContractsForPaths')}
    }
    if($controller.Count) {
        $tokens=$null;$errors=$null;$source=$Text.TrimStart([char]0xfeff)
        $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
        if(@($errors).Count) {throw 'DEVELOP_SCENARIO_SOURCE_PARSE_ERROR'}
        $builder=[Text.StringBuilder]::new($source)
        foreach($node in @($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -in $controller} | Sort-Object {$_.Extent.StartOffset} -Descending)) {
            [void]$builder.Remove($node.Extent.StartOffset,$node.Extent.EndOffset-$node.Extent.StartOffset)
        }
        return $bom+"`n"+(ConvertTo-DevelopSourceTokens $builder.ToString())
    }
    if($Path -ceq 'scripts/invoke-develop-e2e.ps1') {
        # Bind control flow and failure/cleanup handling too. Named operations
        # alone cannot authenticate an old runner after changing its envelope.
        # The existing closed journey projection is the sole proven exception.
        if(Get-DevelopJourneyExcludedScope $Path $Journey) {return Get-DevelopJourneySourceProjection $Path $Text $Journey}
        return $bom+"`n"+(ConvertTo-DevelopSourceTokens $Text.TrimStart([char]0xfeff))
    }
    $rule=@($Catalog.developJourneys.scenarioInputs | Where-Object {$_.path -ceq $Path})
    if($rule.Count -eq 1 -and $rule[0].PSObject.Properties['functions']) {
        if($rule[0].PSObject.Properties['requiresNoProductContext'] -and $rule[0].requiresNoProductContext -and -not $NoProductContext) {return $null}
        $excluded=@(foreach($property in $rule[0].functions.PSObject.Properties) {
            if(-not @($property.Value | Where-Object {$_ -in @($Scenario | ForEach-Object {"$Journey.$_"})}).Count) {$property.Name}
        })
        $tokens=$null;$errors=$null;$source=$Text.TrimStart([char]0xfeff)
        $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
        if(@($errors).Count) {throw 'DEVELOP_SCENARIO_SOURCE_PARSE_ERROR'}
        $builder=[Text.StringBuilder]::new($source)
        foreach($node in @($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -in $excluded} | Sort-Object {$_.Extent.StartOffset} -Descending)) {
            [void]$builder.Remove($node.Extent.StartOffset,$node.Extent.EndOffset-$node.Extent.StartOffset)
        }
        return $bom+"`n"+(ConvertTo-DevelopSourceTokens $builder.ToString())
    }
    if(Get-DevelopJourneyExcludedScope $Path $Journey) {return Get-DevelopJourneySourceProjection $Path $Text $Journey}
    return $null
}

function ConvertTo-DevelopEffectiveClientIdentity {
    param([string]$Value)
    $client=$Value | ConvertFrom-Json
    if(@($client.PSObject.Properties.Name | Where-Object {$_ -notin @('requestedAgentTarget','freshAgentTarget','targets')}).Count) {throw 'DEVELOP_CLIENT_IDENTITY_UNKNOWN'}
    $resolved=@(foreach($target in @($client.targets)) {
        if(@($target.PSObject.Properties.Name | Where-Object {$_ -notin @('role','root','configuredClients')}).Count) {throw 'DEVELOP_CLIENT_TARGET_UNKNOWN'}
        $choice=[string]$client.requestedAgentTarget
        if([string]::IsNullOrWhiteSpace($choice)) {
            if(@($target.configuredClients).Count -ne 1) {throw 'SOURCE_E2E_AGENT_TARGET_REQUIRED'}
            $choice=[string]$target.configuredClients[0]
        }
        [ordered]@{role=$target.role;root=$target.root;configuredClients=@($target.configuredClients);effectiveAgentTarget=$choice}
    })
    return Get-DevelopE2ECanonicalJsonSha256 ([ordered]@{freshAgentTarget=$client.freshAgentTarget;targets=$resolved})
}

function Test-DevelopScenarioEquivalentInput {
    param([string]$RepositoryRoot,[object]$Recorded,[object]$Current,[string]$QualifiedCommit,[string[]]$Scenario,[object]$Catalog)
    try {
        foreach($value in @($Recorded,$Current)) {
            if([int]$value.schemaVersion -ne 2 -or -not $value.inventory.external.complete -or
                (Get-DevelopE2ECanonicalJsonSha256 $value.inventory) -cne $value.fingerprint) {return $false}
        }
        $old=$Recorded | ConvertTo-Json -Depth 32 | ConvertFrom-Json
        $new=$Current | ConvertTo-Json -Depth 32 | ConvertFrom-Json
        $contracts=@(foreach($value in @($old,$new)) {
            $contract=$value.inventory.contract | ConvertTo-Json -Depth 24 | ConvertFrom-Json
            $contract.PSObject.Properties.Remove('hardSeconds')
            foreach($owner in @($contract.contracts)) {$owner.paths=@($owner.paths | Where-Object {$_ -notlike 'tests/pester/*.Tests.ps1'})}
            Get-DevelopE2ECanonicalJsonSha256 $contract
        })
        if($contracts[0] -cne $contracts[1]) {return $false}
        # Authenticate the original nested positive fingerprint before changing
        # any client or source projection. Do not drop the positive environment.
        if($old.inventory.external.PSObject.Properties['positiveStandInputIdentity']) {
            if(-not $new.PSObject.Properties['positiveInputIdentity']) {return $false}
            if((Get-DevelopE2ECanonicalJsonSha256 $new.positiveInputIdentity.inventory) -cne $new.positiveInputIdentity.fingerprint -or
                $new.positiveInputIdentity.fingerprint -cne $new.inventory.external.positiveStandInputIdentity) {return $false}
            $positive=$new.positiveInputIdentity.inventory.external | ConvertTo-Json -Depth 24 | ConvertFrom-Json
            $oldClient=$old.inventory.external.client | ConvertFrom-Json
            $positiveClient=$positive.client | ConvertFrom-Json
            $positiveClient.requestedAgentTarget=$oldClient.requestedAgentTarget
            $positive.client=[string](ConvertTo-Json -InputObject $positiveClient -Depth 8 -Compress)
            $body=[ordered]@{schemaVersion=2;journey=$old.inventory.journey;contract=$old.inventory.contract;inputs=$old.inventory.inputs;external=$positive}
            if((Get-DevelopE2ECanonicalJsonSha256 $body) -cne $old.inventory.external.positiveStandInputIdentity) {return $false}
            $old.inventory.external.PSObject.Properties.Remove('positiveStandInputIdentity')
            $new.inventory.external.PSObject.Properties.Remove('positiveStandInputIdentity')
        }
        foreach($value in @($old,$new)) {
            $value.inventory.external.client=ConvertTo-DevelopEffectiveClientIdentity $value.inventory.external.client
            if($value.inventory.external.PSObject.Properties['freshProjectsRoot']) {
                if(-not [IO.Path]::IsPathRooted([string]$value.inventory.external.freshProjectsRoot)) {return $false}
                $value.inventory.external.freshProjectsRoot=[IO.Path]::GetFullPath([string]$value.inventory.external.freshProjectsRoot).TrimEnd('\','/').ToLowerInvariant()
            }
        }
        if((Get-DevelopE2ECanonicalJsonSha256 $old.inventory.external) -cne (Get-DevelopE2ECanonicalJsonSha256 $new.inventory.external)) {return $false}
        $before=@{};foreach($entry in $old.inventory.inputs) {$before[$entry.path]=$entry}
        foreach($entry in @($new.inventory.inputs | Sort-Object {if($_.path -eq 'scripts/invoke-develop-e2e.ps1'){0}else{1}})) {
            if(-not $before.ContainsKey($entry.path)) {return $false}
            $prior=$before[$entry.path]
            if($prior.sha256 -ceq $entry.sha256) {continue}
            $a=Get-DevelopHistoricalSourceText $RepositoryRoot $QualifiedCommit $entry.path
            $b=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $RepositoryRoot $entry.path)))
            if(@($Catalog.developJourneys.scenarioInputs | Where-Object path -eq $entry.path).Count -and $null -eq (Get-DevelopChangedFunctions $a $b)) {return $false}
            # Historical source is authenticated using the existing transport
            # hash before any scoped projection can authorize reuse.
            $bytes=if($entry.path -match '^(scripts/|\.agents/skills/|templates/).*\.ps1$') {
                [Text.Encoding]::UTF8.GetBytes($a.Replace("`r`n","`n"))
            } else {[Text.Encoding]::UTF8.GetBytes($a)}
            $sha=[Security.Cryptography.SHA256]::Create()
            try {$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
            if($hash -cne $prior.sha256 -and $entry.path -ceq '.agents/skills/1c-workflow/references/workflow-update-recovery.md') {
                $sha=[Security.Cryptography.SHA256]::Create()
                try {$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($a.Replace("`r`n","`n").Replace("`n","`r`n"))))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
            }
            if($hash -cne $prior.sha256 -or (Get-DevelopE2EInputFileSha256 (Join-Path $RepositoryRoot $entry.path) $entry.path) -cne $entry.sha256) {return $false}
            $noProduct=$new.inventory.external.PSObject.Properties['productContext'] -and $new.inventory.external.productContext.known -and $new.inventory.external.productContext.disabled
            $x=Get-DevelopScenarioSourceProjection $entry.path $a $new.inventory.journey $Scenario $Catalog ([bool]$noProduct)
            $y=Get-DevelopScenarioSourceProjection $entry.path $b $new.inventory.journey $Scenario $Catalog ([bool]$noProduct)
            if($null -eq $x -or $x -cne $y) {return $false}
            $prior.sha256=$entry.sha256
        }
        foreach($value in @($old,$new)) {$value.fingerprint=Get-DevelopE2ECanonicalJsonSha256 $value.inventory}
        return Test-DevelopE2EEquivalentInput $RepositoryRoot $old $new $QualifiedCommit
    } catch {Write-Verbose "Scenario reuse rejected: $($_.Exception.Message)";return $false}
}

function Get-DevelopScenarioReusePlan {
    param([string]$RepositoryRoot,[string]$Tree,[string]$Journey,[object]$InputIdentity,[object]$Catalog,
        [object]$StaticProof=$null,[switch]$AllowPendingStatic,[string]$ProjectRoot='')
    if($InputIdentity) {$ProjectRoot=[string]$InputIdentity.inventory.external.root}
    $descriptorPath=if($ProjectRoot) {Join-Path $ProjectRoot '.agent-1c/release-e2e.json'}else{''}
    $rejectionApplicable=$true
    $cacheRoot=Join-Path (Get-RepositoryCommonGitDirectory $RepositoryRoot) 'itl/develop-e2e-qualifications'
    # Enumerate once per invocation, without descending into immutable raw
    # evidence/references. Every consumer still rechecks manifest/report SHA.
    $inventory=@(if(Test-Path -LiteralPath $cacheRoot -PathType Container) {
        Get-ChildItem -LiteralPath $cacheRoot -Directory | Where-Object {$_.Name -notin @('.references','.native')} |
            ForEach-Object {Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Filter manifest.json} | Sort-Object LastWriteTimeUtc -Descending
    })
    if($descriptorPath -and (Test-Path -LiteralPath $descriptorPath -PathType Leaf)) {
        $descriptor=Get-Content -LiteralPath $descriptorPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $rejectionApplicable=[bool]$descriptor.PSObject.Properties['developConfigurationRejection']
    }
    $records=@(foreach($item in @(Get-DevelopScenarioCatalog $Catalog $Journey)) {
        $diagnostics=[Collections.Generic.List[object]]::new()
        $proof=$null
        if($InputIdentity) {
            $proof=Get-DevelopE2EAncestorQualification -RepositoryRoot $RepositoryRoot -Tree $Tree -Journey $Journey `
                -StandStateSha256 $InputIdentity.inventory.external.standStateSha256 -InputIdentity $InputIdentity `
                -StaticProof $StaticProof -AllowPendingStatic:$AllowPendingStatic -Diagnostics $diagnostics -RequiredScenario @($item.id) -Catalog $Catalog -QualificationInventory $inventory
        }
        $applicable=$true
        if($Journey -eq 'upgrade' -and $item.id -eq 'configuration-rejection' -and -not $rejectionApplicable) {$applicable=$false}
        [pscustomobject]@{id=[string]$item.id;execution=$(if($proof){'reuse'}elseif(-not $applicable){'not-applicable'}else{'execute'});applicable=$applicable;
            dependsOn=@($item.dependsOn);descriptorPath=$descriptorPath;proof=$proof;reuseDiagnostics=@($diagnostics.ToArray())}
    })
    $execute=@(Expand-DevelopScenarioSelection $Catalog $Journey @($records | Where-Object execution -eq 'execute' | ForEach-Object {$_.id}))
    foreach($record in $records) {
        if($record.id -in $execute) {
            if($record.execution -eq 'reuse') {$record.execution='setup'}
        }
    }
    return $records
}

function Test-DevelopScenarioEvidence {
    param([object]$Report,[int]$Depth=0,[string[]]$RequiredScenario=@())
    if($Depth -gt 32) {return $false}
    $records=@($Report.result.scenarioEvidence)
    if((@($records.id | Sort-Object) -join ',') -cne (@($Report.coverage | Sort-Object) -join ',')) {return $false}
    if(@($RequiredScenario | Where-Object {$_ -notin @($Report.coverage)}).Count) {return $false}
    foreach($record in @($records | Where-Object {-not $RequiredScenario.Count -or $_.id -in $RequiredScenario})) {
        if($record.execution -eq 'executed') {
            if(-not (Test-Path -LiteralPath $record.path -PathType Leaf) -or
                (Get-FileHash -LiteralPath $record.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $record.sha256) {return $false}
            $raw=Get-Content -LiteralPath $record.path -Raw -Encoding UTF8 | ConvertFrom-Json
            if([int]$raw.schemaVersion -ne 3 -or $raw.status -cne 'passed' -or $raw.candidate.tree -cne $Report.repository.tree -or
                $Report.journey -notin @($raw.requestedJourneys) -or
                @($raw.requestedJourneys | Where-Object {$_ -notin @('upgrade','fresh')}).Count -or
                @($raw.requestedJourneys | Sort-Object -Unique).Count -ne @($raw.requestedJourneys).Count -or
                (@($raw.requestedJourneys | Sort-Object) -join ',') -cne (@($raw.journeys.name | Sort-Object) -join ',') -or
                @($raw.journeys | Where-Object status -ne 'passed').Count) {return $false}
            $journey=@($raw.journeys | Where-Object name -eq $Report.journey)
            if($journey.Count -ne 1 -or $journey[0].status -cne 'passed' -or $record.id -notin @($journey[0].coverage)) {return $false}
        } elseif($record.execution -eq 'not-applicable') {
            if($record.id -cne 'configuration-rejection' -or $Report.journey -cne 'upgrade' -or
                -not (Test-Path -LiteralPath $record.descriptorPath -PathType Leaf)) {return $false}
            $descriptor=Get-Content -LiteralPath $record.descriptorPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if($descriptor.PSObject.Properties['developConfigurationRejection']) {return $false}
        } elseif($record.execution -eq 'reused') {
            if(-not (Test-Path -LiteralPath $record.path -PathType Leaf) -or
                (Get-FileHash -LiteralPath $record.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $record.sha256 -or
                -not (Test-Path -LiteralPath $record.manifestPath -PathType Leaf) -or
                (Get-FileHash -LiteralPath $record.manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $record.manifestSha256) {return $false}
            $manifest=Get-Content -LiteralPath $record.manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if($manifest.identity.reportSha256 -cne $record.sha256 -or
                (Get-DevelopE2ECanonicalJsonSha256 $manifest.inputIdentity.inventory) -cne $manifest.inputIdentity.fingerprint) {return $false}
            $prior=Get-Content -LiteralPath $record.path -Raw -Encoding UTF8 | ConvertFrom-Json
            if($prior.status -cne 'passed' -or $prior.journey -cne $Report.journey) {return $false}
            if([int]$prior.schemaVersion -ne 1 -and $record.id -notin @($prior.coverage)) {return $false}
            if([int]$prior.schemaVersion -in @(2,3) -and -not (Test-DevelopScenarioEvidence $prior ($Depth+1) @($record.id))) {return $false}
        } else {return $false}
    }
    return $true
}

function Invoke-DevelopScenarioJourney {
    param([string]$Journey,[object]$Plan,[switch]$DeferForStatic,[switch]$ReuseOnly)
    # A composite may consume ancestor proof only after current complete static.
    if($DeferForStatic) {return $null}
    $script:developAncestorRoutes.Remove($Journey)
    if(Get-Variable -Name developScenarioExecution -Scope Script -ErrorAction SilentlyContinue) {$script:developScenarioExecution.Remove($Journey)}
    $currentHead=(Invoke-RepositoryGit -RepositoryRoot $repoRoot -Arguments @('rev-parse','HEAD')).stdout.Trim()
    if(-not $script:developCurrentStaticProof -or -not (Test-WorkflowCurrentStaticProof -Proof $script:developCurrentStaticProof -Commit $currentHead -Tree $tree)) {
        throw 'DEVELOP_SCENARIO_STATIC_REQUIRED: repeat the same qualification through its complete current-candidate static stage before consuming scenario proof.'
    }
    $journeyInput=Get-DevelopE2EInputIdentity -RepositoryRoot $repoRoot -Journey $Journey -Catalog $qualityCatalog -ProjectRoot $E2EProjectRoot -AiRulesSource $script:developRulesSource -AgentTarget $AgentTarget -ArtifactBinding $script:sourceE2EArtifactBinding -FreshProjectsRoot $FreshProjectsRoot
    $script:developJourneyInputs[$Journey]=$journeyInput
    $records=@(Get-DevelopScenarioReusePlan $repoRoot $tree $Journey $journeyInput $qualityCatalog -StaticProof $script:developCurrentStaticProof -ProjectRoot $E2EProjectRoot)
    $execute=@($records | Where-Object {$_.execution -in @('execute','setup')} | ForEach-Object {$_.id})
    if($ReuseOnly -and $execute.Count) {throw "DEVELOP_E2E_CONTINUATION_REQUIRED: unselected $Journey scenarios have no valid prior proof: $($execute -join ', '). Preserve the queue and qualify the missing baseline explicitly; the selected route will not widen itself."}
    $rawPath=Join-Path $outputRoot "develop-e2e-$Journey-scenarios-raw.json"
    $path=Join-Path $script:developQualificationRoot "develop-e2e-$Journey.json"
    $proofs=@($records | Where-Object {$null -ne $_.proof} | ForEach-Object {$_.proof})
    if(-not $execute.Count -and $proofs.Count -and $proofs[0].report.schemaVersion -in @(1,2) -and @($proofs.reportPath | Sort-Object -Unique).Count -eq 1) {
        $ancestor=$proofs[0]
        Copy-Item -LiteralPath $ancestor.reportPath -Destination $path -Force
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ancestor.sha256) {throw 'DEVELOP_E2E_CONTINUATION_CORRUPT'}
        $script:developAncestorRoutes[$Journey]=$ancestor
        Add-ReusedStage -Name "develop-e2e-$Journey" -Reason 'all scenario proofs match; complete current static passed' -Detail $path
        return $path
    }
    return Invoke-GateStage -Name "develop-e2e-$Journey" -Reason ('scenario execution/setup: '+($execute -join ', ')) -Detail $rawPath -Body {
        Invoke-DevelopScenarioJourneyCore -Journey $Journey -Plan $Plan -Records $records -JourneyInput $journeyInput -Execute $execute -RawPath $rawPath -Path $path -ReuseOnly:$ReuseOnly
    }
}

function Invoke-DevelopScenarioJourneyCore {
    param([string]$Journey,[object]$Plan,[object[]]$Records,[object]$JourneyInput,[string[]]$Execute,[string]$RawPath,[string]$Path,[switch]$ReuseOnly)
    $evidence=@()
    if($execute.Count) {
        if(-not (Get-Variable -Name developScenarioExecution -Scope Script -ErrorAction SilentlyContinue)) {$script:developScenarioExecution=@{}}
        $script:developScenarioExecution[$Journey]=@($execute)
            $script:developJourneyInputs[$Journey]=$journeyInput
            $arguments=@('-CandidateRoot',$repoRoot,'-ProjectRoot',$E2EProjectRoot,'-AiRulesSource',$script:developRulesSource,
                '-OutputPath',$rawPath,'-Journey',$Journey,'-Scenario',($execute -join ','),'-FreshProjectsRoot',$FreshProjectsRoot)
            if($AgentTarget) {$arguments+=@('-AgentTarget',$AgentTarget)}
            if($script:sourceE2EArtifactBindingPath) {$arguments+=@('-ArtifactBindingPath',$script:sourceE2EArtifactBindingPath)}
            Invoke-PowerShellChild -ScriptPath $script:developScript -Arguments $arguments -TimeoutSeconds (Get-DevelopE2EJourneyHardBudgetSeconds $qualityCatalog $Journey) -NoProgressSeconds 900 -LogName "develop-e2e-$Journey"
        $raw=Get-Content -LiteralPath $rawPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $result=@($raw.journeys | Where-Object name -eq $Journey)
        if([int]$raw.schemaVersion -ne 3 -or $raw.status -cne 'passed' -or $raw.candidate.tree -cne $tree -or
            @($raw.requestedJourneys).Count -ne 1 -or $raw.requestedJourneys[0] -cne $Journey -or $result.Count -ne 1 -or
            $result[0].status -cne 'passed' -or (@($result[0].coverage | Sort-Object) -join ',') -cne (@($execute | Sort-Object) -join ',')) {throw 'DEVELOP_SCENARIO_EXECUTION_UNPROVEN'}
        $rawHash=(Get-FileHash -LiteralPath $rawPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $nativeRoot=Join-Path (Get-RepositoryCommonGitDirectory $repoRoot) 'itl/develop-e2e-qualifications/.native'
        [void][IO.Directory]::CreateDirectory($nativeRoot)
        $immutableRaw=Join-Path $nativeRoot ($rawHash+'.json')
        if(-not (Test-Path -LiteralPath $immutableRaw -PathType Leaf)) {Copy-Item -LiteralPath $rawPath -Destination $immutableRaw}
        if((Get-FileHash -LiteralPath $immutableRaw -Algorithm SHA256).Hash.ToLowerInvariant() -cne $rawHash) {throw 'DEVELOP_SCENARIO_NATIVE_SHA_MISMATCH'}
        $rawPath=$immutableRaw
    }
    foreach($record in $records) {
        if($record.execution -eq 'not-applicable') {
            $evidence+=,[pscustomobject]@{id=$record.id;execution='not-applicable';descriptorPath=$record.descriptorPath}
        } elseif($record.execution -ne 'reuse') {
            $evidence+=,[pscustomobject]@{id=$record.id;execution='executed';path=$rawPath;sha256=(Get-FileHash -LiteralPath $rawPath -Algorithm SHA256).Hash.ToLowerInvariant()}
        } else {
            $reportSource=$record.proof.reportPath
            $reportSourceHash=$record.proof.sha256
            $manifest=Join-Path (Split-Path $reportSource -Parent) 'manifest.json'
            $prior=$record.proof.report
            # Point at the original scenario evidence, not an ever-growing
            # chain of complete compositions. Reauthenticate direct input
            # equivalence before removing any intermediate certificate.
            for($depth=0;$depth -lt 32 -and [int]$prior.schemaVersion -in @(2,3);$depth++) {
                $link=@($prior.result.scenarioEvidence | Where-Object id -eq $record.id)
                if($link.Count -ne 1 -or $link[0].execution -ne 'reused') {break}
                $link=$link[0]
                if((Get-FileHash -LiteralPath $link.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $link.sha256 -or
                    (Get-FileHash -LiteralPath $link.manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $link.manifestSha256) {throw 'DEVELOP_SCENARIO_REFERENCE_SHA_MISMATCH'}
                $leaf=Get-Content -LiteralPath $link.path -Raw -Encoding UTF8 | ConvertFrom-Json
                $leafManifest=Get-Content -LiteralPath $link.manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if(-not (Test-DevelopScenarioEquivalentInput $repoRoot $leafManifest.inputIdentity $journeyInput $leaf.repository.commit @($record.id) $qualityCatalog)) {break}
                $reportSource=$link.path;$reportSourceHash=$link.sha256;$manifest=$link.manifestPath;$prior=$leaf
            }
            $manifestHash=(Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant()
            $pairHash=Get-DevelopE2ECanonicalJsonSha256 ([ordered]@{report=$reportSourceHash;manifest=$manifestHash})
            $reference=Join-Path (Get-RepositoryCommonGitDirectory $repoRoot) ('itl/develop-e2e-qualifications/.references/'+$pairHash)
            [void][IO.Directory]::CreateDirectory($reference)
            $reportCopy=Join-Path $reference 'route-report.json';$manifestCopy=Join-Path $reference 'manifest.json'
            foreach($pair in @(@($reportSource,$reportCopy,$reportSourceHash),@($manifest,$manifestCopy,$manifestHash))) {
                if(-not (Test-Path -LiteralPath $pair[1] -PathType Leaf)) {Copy-Item -LiteralPath $pair[0] -Destination $pair[1]}
                if((Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pair[2]) {throw 'DEVELOP_SCENARIO_REFERENCE_SHA_MISMATCH'}
            }
            $evidence+=,[pscustomobject]@{id=$record.id;execution='reused';path=$reportCopy;sha256=$reportSourceHash;
                manifestPath=$manifestCopy;manifestSha256=$manifestHash}
        }
    }
    $after=Get-DevelopE2EInputIdentity -RepositoryRoot $repoRoot -Journey $Journey -Catalog $qualityCatalog -ProjectRoot $E2EProjectRoot -AiRulesSource $script:developRulesSource -AgentTarget $AgentTarget -ArtifactBinding $script:sourceE2EArtifactBinding -FreshProjectsRoot $FreshProjectsRoot
    $cacheInput=$null
    if($journeyInput -and $after -and $journeyInput.fingerprint -ceq $after.fingerprint) {$cacheInput=$after}
    if(($journeyInput -and $after -and $journeyInput.fingerprint -cne $after.fingerprint) -or
        (-not $cacheInput -and @($records | Where-Object execution -eq 'reuse').Count)) {
        throw 'DEVELOP_SCENARIO_INPUTS_CHANGED: preserve evidence and repeat qualification with stable complete inputs.'
    }
    # An actual complete native run remains valid without cache-only host facts.
    # Incomplete binding disables reuse; it cannot authorize composition.
    $scopedPlan=$Plan | ConvertTo-Json -Depth 24 | ConvertFrom-Json
    if(-not $scopedPlan.PSObject.Properties['scenarioCoverage']) {$scopedPlan|Add-Member -NotePropertyName scenarioCoverage -NotePropertyValue ([pscustomobject]@{})}
    $scopedPlan.scenarioCoverage | Add-Member -NotePropertyName $Journey -NotePropertyValue @($records.id) -Force
    if(-not $scopedPlan.PSObject.Properties['scenarioContracts']) {$scopedPlan|Add-Member -NotePropertyName scenarioContracts -NotePropertyValue ([pscustomobject]@{})}
    $scopedPlan.scenarioContracts | Add-Member -NotePropertyName $Journey -NotePropertyValue ([ordered]@{scenarios=$qualityCatalog.developJourneys.scenarios.$Journey;inputs=$qualityCatalog.developJourneys.scenarioInputs}) -Force
    $result=[pscustomobject]@{name=$Journey;status='passed';coverage=@($records.id);scenarioEvidence=$evidence}
    $identity=Get-DevelopE2EIdentitySha256 -ReleaseContext $script:releaseContext -ForkIdentity $script:aiRulesRelease -ProjectRoot $E2EProjectRoot -AgentTarget $AgentTarget
    $stand=Get-DevelopE2EStandStateSha256 -ProjectRoot $E2EProjectRoot
    $report=New-DevelopE2ERouteReport -RepositoryRoot $repoRoot -Plan $scopedPlan -Journey $Journey -IdentitySha256 $identity -StandStateSha256 $stand -JourneyResult $result
    [IO.File]::WriteAllText($path,($report | ConvertTo-Json -Depth 24),[Text.UTF8Encoding]::new($false))
    [void](Save-DevelopE2EQualification -RepositoryRoot $repoRoot -ReportPath $path -Tree $tree -Journey $Journey -IdentitySha256 $identity -StandStateSha256 $stand -InputIdentity $cacheInput)
    if($ReuseOnly) {
        $head=(Invoke-RepositoryGit -RepositoryRoot $repoRoot -Arguments @('rev-parse','HEAD')).stdout.Trim()
        $continuation=Get-DevelopE2EOwnerInputContinuation -RepositoryRoot $repoRoot -QualifiedCommit $head -CurrentCommit $head -CurrentTree $tree -StaticProof $script:developCurrentStaticProof
        if(-not $continuation) {throw 'DEVELOP_SCENARIO_STATIC_CONTINUATION_UNPROVEN'}
        $script:developAncestorRoutes[$Journey]=[pscustomobject]@{report=$report;reportPath=$path;inputIdentity=$after;continuation=$continuation}
    }
    return $path
}

function Save-DevelopScenarioExecution {
    param([string]$RepositoryRoot,[string]$RawPath,[string]$Journey,[object]$Before,[object]$After,[object]$Catalog)
    if(-not $Before -or -not $After -or $Before.fingerprint -cne $After.fingerprint) {return $null}
    foreach($value in @($Before,$After)) {
        if(-not $value.inventory.external.complete -or (Get-DevelopE2ECanonicalJsonSha256 $value.inventory) -cne $value.fingerprint) {return $null}
    }
    if(@(Get-RepositoryGitPathList -RepositoryRoot $RepositoryRoot -Arguments @('status','--porcelain=v1','--untracked-files=all','-z')).Count) {return $null}
    $raw=Get-Content -LiteralPath $RawPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $tree=(Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse','HEAD^{tree}')).stdout.Trim()
    $result=@($raw.journeys | Where-Object name -eq $Journey)
    if($raw.schemaVersion -ne 3 -or $raw.status -cne 'passed' -or $raw.candidate.tree -cne $tree -or
        $result.Count -ne 1 -or $result[0].status -cne 'passed' -or -not @($result[0].coverage).Count) {return $null}
    $coverage=@($result[0].coverage)
    if(@($coverage | Where-Object {$_ -notin @(Get-DevelopScenarioCatalog $Catalog $Journey | ForEach-Object {$_.id})}).Count) {return $null}
    $hash=(Get-FileHash -LiteralPath $RawPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $root=Join-Path (Get-RepositoryCommonGitDirectory $RepositoryRoot) 'itl/develop-e2e-qualifications/.native'
    [void][IO.Directory]::CreateDirectory($root)
    $immutable=Join-Path $root ($hash+'.json')
    if(-not (Test-Path -LiteralPath $immutable -PathType Leaf)) {Copy-Item -LiteralPath $RawPath -Destination $immutable}
    if((Get-FileHash -LiteralPath $immutable -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hash) {throw 'DEVELOP_SCENARIO_NATIVE_SHA_MISMATCH'}
    $contracts=[pscustomobject]@{};$contracts|Add-Member -NotePropertyName $Journey -NotePropertyValue ([ordered]@{scenarios=$Catalog.developJourneys.scenarios.$Journey;inputs=$Catalog.developJourneys.scenarioInputs})
    $selected=[pscustomobject]@{};$selected|Add-Member -NotePropertyName $Journey -NotePropertyValue $coverage
    $plan=[pscustomobject]@{kind='itl-develop-e2e-journey-plan';journeys=@($Journey);scenarioCoverage=$selected;scenarioContracts=$contracts}
    $evidence=@($coverage | ForEach-Object {[pscustomobject]@{id=$_;execution='executed';path=$immutable;sha256=$hash}})
    $outcome=[pscustomobject]@{name=$Journey;status='passed';coverage=$coverage;scenarioEvidence=$evidence}
    $report=New-DevelopE2ERouteReport -RepositoryRoot $RepositoryRoot -Plan $plan -Journey $Journey -IdentitySha256 $Before.fingerprint -StandStateSha256 $Before.inventory.external.standStateSha256 -JourneyResult $outcome
    $report.schemaVersion=3
    $path=$RawPath+'.'+$Journey+'.qualification.json'
    [IO.File]::WriteAllText($path,($report|ConvertTo-Json -Depth 24),[Text.UTF8Encoding]::new($false))
    return Save-DevelopE2EQualification -RepositoryRoot $RepositoryRoot -ReportPath $path -Tree $tree -Journey $Journey -IdentitySha256 $Before.fingerprint -StandStateSha256 $Before.inventory.external.standStateSha256 -InputIdentity $After -RequiredScenario $coverage
}
