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

function Get-DevelopScenarioWorkloadHash {
    param([object]$Contract,[ValidateSet('scenarioInputs','inputs')][string]$RoutingField='scenarioInputs')
    # Routing describes which source nodes affect a scenario, not its native
    # assertions. Current policy must still project and authenticate both source
    # snapshots. Keep every workload/unknown field and never rewrite old proof.
    $workload=$Contract | ConvertTo-Json -Depth 24 | ConvertFrom-Json
    $workload.PSObject.Properties.Remove($RoutingField)
    # Source selection is checked against both authenticated inventories below;
    # it does not change the native workload certified by an ancestor.
    $workload.PSObject.Properties.Remove('contracts')
    $workload.PSObject.Properties.Remove('fullPaths')
    return Get-DevelopE2ECanonicalJsonSha256 $workload
}

function Test-DevelopScenarioBrokerIndependent {
    param([string]$Journey,[string[]]$Scenario=@())
    return ($Journey -ceq 'fresh' -and $Scenario.Count -gt 0 -and
        -not @($Scenario | Where-Object {$_ -cnotin @('verification','stale-export','close')}).Count)
}

function ConvertTo-DevelopScenarioArtifactIdentity {
    param([object]$Artifacts,[string]$Journey,[string[]]$Scenario=@())
    $copy=$Artifacts | ConvertTo-Json -Depth 16 | ConvertFrom-Json
    # These operations neither install the broker nor start its RPC process.
    # Installation/configuration/refresh, whole journeys and unknown scenarios
    # retain the exact broker hash. Vanessa and client CFE always remain exact.
    if((Test-DevelopScenarioBrokerIndependent $Journey $Scenario) -and
        $copy -and $copy.PSObject.Properties['ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE'] -and
        [string]$copy.ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE -cmatch '^[a-f0-9]{64}$') {
        $copy.ITL_ONDEMAND_MCP_SOURCE_BUILD_EXE='opaque-broker-not-executed'
    }
    return $copy
}

function Test-DevelopArtifactIdentityDifference {
    param([object]$Recorded,[object]$Current,[string]$Journey='', [string[]]$Scenario=@(),[ref]$ChangedInputs)
    if($ChangedInputs) {$ChangedInputs.Value=@()}
    $values=[Collections.Generic.List[object]]::new()
    foreach($identity in @($Recorded,$Current)) {
        $external=$identity.inventory.external;$artifacts=$null
        if($external -is [Collections.IDictionary]) {$artifacts=$external['artifacts']}
        elseif($external.PSObject.Properties['artifacts']) {$artifacts=$external.artifacts}
        $values.Add((ConvertTo-DevelopScenarioArtifactIdentity $artifacts $Journey $Scenario))
    }
    if($null -eq $values[0] -and $null -eq $values[1]) {return $false}
    if($null -eq $values[0] -or $null -eq $values[1]) {
        if($ChangedInputs) {$ChangedInputs.Value=@('external:artifacts')}
        return $true
    }
    $different=(Get-DevelopE2ECanonicalJsonSha256 $values[0]) -cne (Get-DevelopE2ECanonicalJsonSha256 $values[1])
    if($different -and $ChangedInputs) {
        $ChangedInputs.Value=@(foreach($name in @(@($values[0].PSObject.Properties.Name)+@($values[1].PSObject.Properties.Name)|Sort-Object -Unique)) {
            $a=$values[0].PSObject.Properties[$name];$b=$values[1].PSObject.Properties[$name]
            if(-not $a -or -not $b -or (Get-DevelopE2ECanonicalJsonSha256 $a.Value) -cne (Get-DevelopE2ECanonicalJsonSha256 $b.Value)) {'artifact:'+$name}
        })
    }
    return $different
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
    if($Before.StartsWith([string][char]0xfeff,[StringComparison]::Ordinal) -ne $After.StartsWith([string][char]0xfeff,[StringComparison]::Ordinal)) {return $null}
    $maps=@();$remainders=@();$definitions=@()
    foreach($text in @($Before,$After)) {
        $text=$text.Replace("`r`n","`n")
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($text.TrimStart([char]0xfeff),[ref]$tokens,[ref]$errors)
        if(@($errors).Count) {throw 'DEVELOP_SCENARIO_SOURCE_PARSE_ERROR'}
        $map=@{};$definition=@{};$builder=[Text.StringBuilder]::new($text.TrimStart([char]0xfeff))
        $nodes=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst]})
        foreach($node in $nodes) {
            $map[$node.Name]=ConvertTo-DevelopSourceTokens $node.Extent.Text
            $definition[$node.Name]=$node
        }
        foreach($node in @($nodes | Sort-Object {$_.Extent.StartOffset} -Descending)) {
            [void]$builder.Remove($node.Extent.StartOffset,$node.Extent.EndOffset-$node.Extent.StartOffset)
        }
        $maps+=,$map;$definitions+=,$definition;$remainders+=ConvertTo-DevelopSourceTokens $builder.ToString()
    }
    if($remainders[0] -cne $remainders[1]) {return $null}
    $changed=@(@($maps[0].Keys)+@($maps[1].Keys) | Sort-Object -Unique | Where-Object {$maps[0][$_] -cne $maps[1][$_]})
    # Identical executable tokens imply identical ambient references. Walking
    # every unchanged function repeatedly dominated real warm planning.
    $getContext={param($node)
        $locals=@('null','true','false','_','psitem','psboundparameters','psscriptroot','args','input','pscmdlet','pscommandpath')
        if($node.Body.ParamBlock) {$locals+=@($node.Body.ParamBlock.Parameters | ForEach-Object {$_.Name.VariablePath.UserPath.ToLowerInvariant()})}
        foreach($assignment in @($node.Body.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst]},$true))) {
            $locals+=@($assignment.Left.FindAll({param($n)$n -is [Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.IsUnqualified},$true) | ForEach-Object {$_.VariablePath.UserPath.ToLowerInvariant()})
        }
        $locals+=@($node.Body.FindAll({param($n)$n -is [Management.Automation.Language.ForEachStatementAst]},$true) | ForEach-Object {$_.Variable.VariablePath.UserPath.ToLowerInvariant()})
        @($node.Body.FindAll({param($n)$n -is [Management.Automation.Language.VariableExpressionAst]},$true) | ForEach-Object {$_.VariablePath.UserPath.ToLowerInvariant()} | Where-Object {$_ -notin $locals} | Sort-Object -Unique)
    }
    foreach($name in @($changed | Where-Object {$maps[0].ContainsKey($_) -and $maps[1].ContainsKey($_)})) {
        $beforeContext=@(& $getContext $definitions[0][$name])
        $afterContext=@(& $getContext $definitions[1][$name])
        if(@($afterContext | Where-Object {$_ -notin $beforeContext}).Count) {return $null}
    }
    return ,$changed
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
        $affected=@();$matched=$false;$changed=@();$unmapped=@();$fallback='no-scenario-owner'
        if($rules.Count -eq 1 -and $BaseRef -and $rules[0].PSObject.Properties['functions']) {
            try {
                $old=Get-DevelopHistoricalSourceText $RepositoryRoot $BaseRef $path
                $new=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $RepositoryRoot $path)))
                $changed=Get-DevelopChangedFunctions $old $new
                $unmapped=@($changed | Where-Object {$_ -notin @($rules[0].functions.PSObject.Properties.Name)})
                $fallback=if($null -eq $changed){'ambient-or-top-level-change'}elseif($unmapped.Count){'unmapped-function'}else{''}
                if($null -ne $changed -and $unmapped.Count -eq 0) {
                    $matched=$true
                    foreach($name in $changed) {$affected+=@($rules[0].functions.$name | Where-Object {$_ -like "$Journey.*"} | ForEach-Object {$_.Substring($Journey.Length+1)})}
                }
            } catch {$matched=$false;$fallback='source-analysis-unavailable'}
        }
        if(-not $matched) {$affected=@($items.id)}
        $selected+=@($affected)
        if($affected.Count) {$reasons+=,[pscustomobject]@{path=$path;scenarios=@($affected | Sort-Object -Unique);basis=$(if($matched){'changed-owned-functions'}else{'unclassified-native-input'});
            functions=@($changed | Select-Object -First 12);unmappedFunctions=@($unmapped | Select-Object -First 12);fallback=$fallback}}
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

# A fresh recipe creates a new root and copies only project.json and .dev.env
# before bootstrap. It cannot contain retained on-demand runtime records. Pin
# those audited consumers even after a later native baseline passes.
function Test-DevelopColdCutoverConsumers {
    param([string]$RepositoryRoot,[string]$Commit='')
    if(-not $RepositoryRoot) {return $false}
    $consumers=@{
        'install-agent-1c-workflow.ps1'=@('1917f4163747d6c1c55e6b9bf69184c3d9d7553a27cde549ce758ad440fbce17')
        'scripts/invoke-develop-e2e.ps1'=@('ab50bc1388d98b40b4a9dd602d969635889cdb5bb762e3a7dd27e2e5ff11a77d','10c7ead27281f26f760c2ec0ad408b9e6152ed39c2492d4ad9102d36a99eebb9','00b1dfc5ea577a96c912453c42f9acb06ba7de5e32a95010d9501c3331c1c62e')
    }
    try {
        foreach($path in $consumers.Keys) {
            $text=if($Commit){Get-DevelopHistoricalSourceText $RepositoryRoot $Commit $path}else{[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $RepositoryRoot $path)))}
            $sha=[Security.Cryptography.SHA256]::Create()
            try {$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text.Replace("`r`n","`n"))))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
            if($hash -cnotin $consumers[$path]) {return $false}
            if($path -ceq 'scripts/invoke-develop-e2e.ps1' -and $hash -ceq '00b1dfc5ea577a96c912453c42f9acb06ba7de5e32a95010d9501c3331c1c62e') {
                # The modern recipe plans current-change evidence, but still
                # registers no diagnostic batch and invokes no explicit cleanup.
                $helper='scripts/develop-configuration-rejection.ps1'
                $helperText=if($Commit){Get-DevelopHistoricalSourceText $RepositoryRoot $Commit $helper}else{[IO.File]::ReadAllText((Join-Path $RepositoryRoot $helper))}
                $helperText=Get-DevelopJourneySourceProjection $helper $helperText fresh
                $sha=[Security.Cryptography.SHA256]::Create()
                try {$helperHash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($helperText)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
                if($helperHash -cne 'a547992821bcd7c88f44eb68a7874bcfdc4727688d9d96f147867b22dd21346e') {return $false}
            }
        }
        return $true
    } catch {return $false}
}

function Get-DevelopColdCutoverProjection {
    param([string]$Path,[string]$Text,[string]$RepositoryRoot,[string]$Commit='')
    if(-not (Test-DevelopColdCutoverConsumers $RepositoryRoot $Commit)) {return $null}
    $source=$Text.Replace("`r`n","`n");$bom=[string]$source.StartsWith([string][char]0xfeff,[StringComparison]::Ordinal);$source=$source.TrimStart([char]0xfeff)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
    if(@($errors).Count) {return $null}
    $remove=@()
    if($Path -ceq '.agents/skills/1c-workflow/scripts/lib/agent-1c.runtime-values.ps1') {
        # Importing function declarations has no eager side effects. Everything
        # except this update-only leaf, including unknown nodes, remains bound.
        if(@($ast.EndBlock.Statements|Where-Object {$_ -isnot [Management.Automation.Language.FunctionDefinitionAst]}).Count -or $ast.ParamBlock -or $ast.BeginBlock -or $ast.ProcessBlock) {return $null}
        $remove=@($ast.EndBlock.Statements|Where-Object Name -eq 'Get-ItlOnDemandRuntimeRecordFiles')
    } else {
        $function=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $(if($Path -like '*lifecycle.ps1'){'Get-WorkflowUpdateRootRuntimeBusyReason'}else{'Assert-NoActiveCutoverRuntime'})})
        if($function.Count -ne 1) {return $null}
        $statements=@($function[0].Body.EndBlock.Statements)
        $prefix=@('$runtimeRoot = Join-Path (Get-CutoverFullPath $Root) ''.agent-1c\mcp\ondemand''','if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) { return }')
        if($Path -ceq '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1') {
            $prefix=@('$runtimeRoot = Join-Path $Root ''.agent-1c/mcp/ondemand''','if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) { return '''' }')
        }
        if($statements.Count -lt 2) {return $null}
        for($i=0;$i -lt 2;$i++) {if((ConvertTo-DevelopSourceTokens $statements[$i].Extent.Text) -cne (ConvertTo-DevelopSourceTokens $prefix[$i])) {return $null}}
        $remove=@($statements|Select-Object -Skip 2)
        $import=ConvertTo-DevelopSourceTokens '. (Join-Path $PSScriptRoot ''lib/agent-1c.runtime-values.ps1'')'
        foreach($node in $ast.EndBlock.Statements) {
            if((ConvertTo-DevelopSourceTokens $node.Extent.Text) -ceq $import) {
                $library='.agents/skills/1c-workflow/scripts/lib/agent-1c.runtime-values.ps1'
                $libraryText=if($Commit){Get-DevelopHistoricalSourceText $RepositoryRoot $Commit $library}else{[IO.File]::ReadAllText((Join-Path $RepositoryRoot $library))}
                $libraryAst=[Management.Automation.Language.Parser]::ParseInput($libraryText.TrimStart([char]0xfeff),[ref]$tokens,[ref]$errors)
                if(@($errors).Count -or $libraryAst.ParamBlock -or $libraryAst.BeginBlock -or $libraryAst.ProcessBlock -or @($libraryAst.EndBlock.Statements|Where-Object {$_ -isnot [Management.Automation.Language.FunctionDefinitionAst]}).Count) {return $null}
                $remove+=@($node)
            }
        }
    }
    $builder=[Text.StringBuilder]::new($source)
    foreach($node in @($remove|Sort-Object {$_.Extent.StartOffset} -Descending)) {[void]$builder.Remove($node.Extent.StartOffset,$node.Extent.EndOffset-$node.Extent.StartOffset)}
    if($Path -ceq '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1') {
        return Get-DevelopJourneySourceProjection $Path ($(if($bom -ceq 'True'){[string][char]0xfeff}else{''})+$builder.ToString()) fresh
    }
    return $bom+"`n"+(ConvertTo-DevelopSourceTokens $builder.ToString())
}

# This exact delta only adds protected paths. Automatic cleanup is optional
# and cannot grant native check/export/close success. Keep its caller, every
# deletion/candidate rule and all other protection code bound to the proof.
function Get-DevelopArtifactProtectionProjection {
    param([string]$Text,[string]$RepositoryRoot,[string]$Commit='',[switch]$ProbeOnly)
    if(-not (Test-DevelopColdCutoverConsumers $RepositoryRoot $Commit)) {return $null}
    $tokenHash={param([string]$Value)
        $sha=[Security.Cryptography.SHA256]::Create()
        try {return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((ConvertTo-DevelopSourceTokens $Value))))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    }
    $consumerPath='.agents/skills/1c-workflow/scripts/agent-1c.ps1'
    $consumer=if($Commit){Get-DevelopHistoricalSourceText $RepositoryRoot $Commit $consumerPath}else{[IO.File]::ReadAllText((Join-Path $RepositoryRoot $consumerPath))}
    $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($consumer.TrimStart([char]0xfeff),[ref]$t,[ref]$e)
    if(@($e).Count) {return $null}
    $commands=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Invoke-ItlArtifactCleanup' -and $n.Extent.Text -match '\-Automatic'},$true))
    if($commands.Count -ne 1) {return $null}
    $node=$commands[0].Parent;while($node -and $node -isnot [Management.Automation.Language.IfStatementAst]) {$node=$node.Parent}
    if(-not $node -or (& $tokenHash $node.Extent.Text) -cne '683a9dcfc05acd3d3f246a6e82652cb9ea062eaba46594ebe8990e86f395648d') {return $null}
    if($ProbeOnly) {return $true}
    $source=$Text.Replace("`r`n","`n");$bom=[string]$source.StartsWith([string][char]0xfeff,[StringComparison]::Ordinal);$source=$source.TrimStart([char]0xfeff)
    $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$t,[ref]$e)
    if(@($e).Count) {return $null}
    $functions=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq 'Get-ItlArtifactProtectedPaths'})
    if($functions.Count -ne 1) {return $null}
    $statements=@($functions[0].Body.EndBlock.Statements);$matchedBlocks=@()
    for($i=0;$i -lt $statements.Count-2;$i++) {
        $window=@($statements[$i..($i+2)])
        if((& $tokenHash (($window|ForEach-Object {$_.Extent.Text}) -join "`n")) -ceq 'a207fb31796e57a160b3fdb3959b3a1503cc1e259ba03751f1fc458715cae539') {$matchedBlocks+=,@($window)}
    }
    if($matchedBlocks.Count -gt 1) {return $null}
    $builder=[Text.StringBuilder]::new($source)
    if($matchedBlocks.Count -eq 1) {
        $remove=@($matchedBlocks[0]);$start=$remove[0].Extent.StartOffset;$end=$remove[-1].Extent.EndOffset
        # A new ambient use could make the assignment affect another path.
        if(@($functions[0].FindAll({param($n)$n -is [Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -ieq 'changePath'},$true)|Where-Object {$_.Extent.StartOffset -lt $start -or $_.Extent.EndOffset -gt $end}).Count) {return $null}
        foreach($node in @($remove|Sort-Object {$_.Extent.StartOffset} -Descending)) {[void]$builder.Remove($node.Extent.StartOffset,$node.Extent.EndOffset-$node.Extent.StartOffset)}
    }
    # Unknown/new variants stay exact; only the audited additive block is cut.
    return $bom+"`n"+(ConvertTo-DevelopSourceTokens $builder.ToString())
}

# Exact audited old/new diagnostic implementations return before all changed
# code on a fresh root without producer-enrolled manifests. Unknown versions
# retain native qualification; registration and existing manifests stay exact.
function Get-DevelopColdDiagnosticProjection {
    param([string]$Text,[string]$RepositoryRoot,[string]$Commit='',[switch]$ProbeOnly)
    if(-not (Test-DevelopColdCutoverConsumers $RepositoryRoot $Commit)) {return $null}
    if($ProbeOnly) {return $true}
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text.Replace("`r`n","`n"))))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    if($hash -cnotin @('998444b79b4fcca47bc95a672f058d81e00d7af327444cc0e9c833e0a47ae349','87b42915c8a9f7b68254625adc048994add6df6fe0a6a7d664703ed61603d415')) {return $null}
    return 'cold-root-without-diagnostic-manifests'
}

function Get-DevelopScenarioSourceProjection {
    param([string]$Path,[string]$Text,[string]$Journey,[string[]]$Scenario=@(),[object]$Catalog,[bool]$NoProductContext=$false,[string]$RepositoryRoot='',[string]$Commit='', [switch]$ProbeOnly,[object]$ForkBridge=$null)
    if($Journey -ceq 'fresh' -and $Scenario.Count -gt 0 -and -not @($Scenario|Where-Object {$_ -cnotin @('install','branch','verification','stale-export','refresh','close')}).Count -and
        $Path -cin @('.agents/skills/1c-workflow/scripts/execution-guard-cutover.ps1','.agents/skills/1c-workflow/scripts/lib/agent-1c.runtime-values.ps1','.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1')) {
        if($ProbeOnly) {return Test-DevelopColdCutoverConsumers $RepositoryRoot $Commit}
        return Get-DevelopColdCutoverProjection $Path $Text $RepositoryRoot $Commit
    }
    if($Path -ceq '.agents/skills/1c-workflow/scripts/lib/agent-1c.artifact-retention.ps1' -and $Journey -ceq 'fresh' -and $Scenario.Count -gt 0 -and
        -not @($Scenario|Where-Object {$_ -cnotin @('verification','stale-export','close')}).Count) {
        return Get-DevelopArtifactProtectionProjection $Text $RepositoryRoot $Commit -ProbeOnly:$ProbeOnly
    }
    if($Path -ceq '.agents/skills/1c-workflow/scripts/lib/agent-1c.diagnostic-retention.ps1' -and $Journey -ceq 'fresh' -and $Scenario.Count -gt 0 -and
        -not @($Scenario|Where-Object {$_ -cnotin @('verification','stale-export','close')}).Count) {
        return Get-DevelopColdDiagnosticProjection $Text $RepositoryRoot $Commit -ProbeOnly:$ProbeOnly
    }
    if($Path -ceq 'scripts/ai-rules-native-inputs.ps1') {return 'source-qualification-policy-only'}
    if($Path -ceq 'templates/dependency-lock.json' -and $ForkBridge) {
        if($ProbeOnly) {return $true}
        $lock=$Text.TrimStart([char]0xfeff)|ConvertFrom-Json
        $expected=if($Commit){$ForkBridge.fromCommit}else{$ForkBridge.toCommit}
        $rules=$lock.dependencies.aiRules1c
        if($rules.commit -cne $expected -or $rules.ref -cnotmatch '^itl-.+-r([0-9]+)$' -or
            [int]$rules.downstreamRevision -ne [int]$Matches[1] -or $rules.compatibilityStatus -cnotin @('pending','passed')) {return $null}
        $tag='refs/tags/'+[string]$rules.ref
        if((Invoke-RepositoryGit $ForkBridge.sourceRoot @('cat-file','-t',$tag)).stdout.Trim() -cne 'tag' -or
            (Invoke-RepositoryGit $ForkBridge.sourceRoot @('rev-parse',($tag+'^{commit}'))).stdout.Trim() -cne $expected) {return $null}
        foreach($name in @('ref','commit','downstreamRevision','compatibilityStatus','compatibilityCheckedAt')) {
            if($lock.dependencies.aiRules1c.PSObject.Properties[$name]) {$lock.dependencies.aiRules1c.$name='current-qualified-guidance-transition'}
        }
        if(Test-DevelopScenarioBrokerIndependent $Journey $Scenario) {
            foreach($name in @('version','releaseTag','url','sha256')) {$lock.dependencies.itlOndemandMcp.PSObject.Properties.Remove($name)}
        }
        return Get-DevelopE2ECanonicalJsonSha256 $lock
    }
    if($Path -ceq '.agents/skills/1c-workflow/scripts/lib/agent-1c.ondemand-mcp.ps1') {
        if($ProbeOnly) {return $true}
        return Get-DevelopBrokerCleanupSourceProjection $Text
    }
    if($RepositoryRoot -and (Test-DevelopGoBuildOnlyPath $RepositoryRoot $Path $Commit)) {return 'outside-native-go-build'}
    if(Test-DevelopScenarioBrokerIndependent $Journey $Scenario) {
        if($Path -cmatch '^tools/itl-ondemand-mcp/[^/]+\.go$') {return 'outside-broker-independent-scenario'}
        if($Path -ceq 'templates/dependency-lock.json') {
            if($ProbeOnly) {return $true}
            $lock=$Text.TrimStart([char]0xfeff) | ConvertFrom-Json
            # Keep transport/platform/unknown fields, all other dependencies,
            # and the JSON envelope. Only the opaque component release changes.
            foreach($name in @('version','releaseTag','url','sha256')) {$lock.dependencies.itlOndemandMcp.PSObject.Properties.Remove($name)}
            return Get-DevelopE2ECanonicalJsonSha256 $lock
        }
        if($Path -ceq '.agents/skills/1c-workflow/assets/ondemand-mcp/compatibility.json') {
            if($ProbeOnly) {return $true}
            $compatibility=$Text.TrimStart([char]0xfeff) | ConvertFrom-Json
            $compatibility.PSObject.Properties.Remove('facadeVersion')
            return Get-DevelopE2ECanonicalJsonSha256 $compatibility
        }
    }
    $Text=$Text.Replace("`r`n","`n")
    $bom=[string]$Text.StartsWith([string][char]0xfeff,[StringComparison]::Ordinal)
    if($Path -ceq 'tests/quality-contracts.json') {
        if($ProbeOnly) {return $true}
        # The raw catalog may also be in a legacy owner's source inventory.
        # Ignore only this same routing field; all other JSON fields still bind.
        $catalogSource=$Text.TrimStart([char]0xfeff) | ConvertFrom-Json
        foreach($field in @('contracts','pesterNonReusableTests','pesterExternalRuntimeProfiles','pesterExternalRuntimeTests','pesterWorkers','smokeTests','retiredTests','pesterExternalInputs','semanticTargeting','lifecycleActions','continuationScopes')) {
            $catalogSource.PSObject.Properties.Remove($field)
        }
        foreach($field in @('scenarioInputs','routes','fullPaths')) {$catalogSource.developJourneys.PSObject.Properties.Remove($field)}
        return $bom+"`n"+(Get-DevelopE2ECanonicalJsonSha256 $catalogSource)
    }
    $controller=@()
    switch -Exact ($Path) {
        # Copy GC retains/reports resources; it cannot grant journey status.
        # Fixture preparation, space admission and native assertions stay bound.
        'scripts/source-e2e-storage.ps1' {$controller=@('Get-SourceE2EFixtureReaderInventory','Remove-SourceE2EFixtureCopy')}
        'scripts/check.ps1' {$controller=@('Ensure-DevelopE2ERoute','Get-WorkflowGateScriptPaths')}
        'scripts/develop-e2e-scenarios.ps1' {$controller=@('Test-DevelopColdCutoverConsumers','Get-DevelopColdCutoverProjection','Get-DevelopArtifactProtectionProjection','Get-DevelopColdDiagnosticProjection','Test-DevelopScenarioBrokerIndependent','ConvertTo-DevelopScenarioArtifactIdentity','Test-DevelopArtifactIdentityDifference','Get-DevelopScenarioWorkloadHash','Get-DevelopChangedFunctions','Resolve-DevelopScenarioSelection','Get-DevelopScenarioCoverage','Get-DevelopScenarioSourceProjection','ConvertTo-DevelopEffectiveClientIdentity','Test-DevelopScenarioEquivalentInput','Get-DevelopScenarioReusePlan','Test-DevelopScenarioEvidence','Invoke-DevelopScenarioJourney','Invoke-DevelopScenarioJourneyCore','Save-DevelopScenarioExecution')}
        'scripts/quality-contracts.ps1' {$controller=@('Get-QualityContractReuseInputPaths','Get-QualityPesterSemanticInputBindings','Get-DevelopE2EJourneyContractProjection','Get-QualityReleaseStageCatalog','Resolve-QualityReleaseCapabilities','ConvertTo-QualityBudgetSeconds','Get-ReleaseE2EBudgetProjection','Get-DevelopE2EJourneyHardBudgetSeconds','Resolve-PesterWorkerCount','Get-PublicLifecycleActions','Get-Agent1cSemanticModel','Resolve-Agent1cSemanticImpact','Get-Agent1cEntrypointProbeInventory','Test-QualityContractCatalog','Test-QualityPathPattern','Select-QualityPaths','Resolve-QualityContractsForPaths')}
    }
    if($controller.Count) {
        if($ProbeOnly) {return $true}
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
        if($ProbeOnly) {return $true}
        # Bind control flow and failure/cleanup handling too. Named operations
        # alone cannot authenticate an old runner after changing its envelope.
        # The existing closed journey projection is the sole proven exception.
        if(Get-DevelopJourneyExcludedScope $Path $Journey) {return Get-DevelopJourneySourceProjection $Path $Text $Journey}
        return $bom+"`n"+(ConvertTo-DevelopSourceTokens $Text.TrimStart([char]0xfeff))
    }
    $rule=@($Catalog.developJourneys.scenarioInputs | Where-Object {$_.path -ceq $Path})
    if($rule.Count -eq 1 -and $rule[0].PSObject.Properties['functions']) {
        if($rule[0].PSObject.Properties['requiresNoProductContext'] -and $rule[0].requiresNoProductContext -and -not $NoProductContext) {return $null}
        if($ProbeOnly) {return $true}
        $excluded=@(foreach($property in $rule[0].functions.PSObject.Properties) {
            $outsideDisabled=$rule[0].PSObject.Properties['outsideWhenNoProductContext'] -and $rule[0].outsideWhenNoProductContext -and $NoProductContext
            if($outsideDisabled -or -not @($property.Value | Where-Object {$_ -in @($Scenario | ForEach-Object {"$Journey.$_"})}).Count) {$property.Name}
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
    if(Get-DevelopJourneyExcludedScope $Path $Journey) {
        if($ProbeOnly) {return $true}
        return Get-DevelopJourneySourceProjection $Path $Text $Journey
    }
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
    param([string]$RepositoryRoot,[object]$Recorded,[object]$Current,[string]$QualifiedCommit,[string[]]$Scenario,[object]$Catalog,[hashtable]$LookupContext=$null)
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
            Get-DevelopScenarioWorkloadHash $contract
        })
        if($contracts[0] -cne $contracts[1]) {return $false}
        $forkBridge=$null
        if(Test-DevelopForkIdentityChanged $old $new) {
            $cache=if($null -ne $LookupContext){$LookupContext.forkBridges}else{$null}
            $forkBridge=Get-DevelopForkNativeBridge $Recorded $Current -Cache $cache
            if(-not $forkBridge) {return $false}
        }
        # Authenticate the original nested positive fingerprint before changing
        # any client or source projection. Do not drop the positive environment.
        if($old.inventory.external.PSObject.Properties['positiveStandInputIdentity']) {
            if(-not $new.PSObject.Properties['positiveInputIdentity']) {return $false}
            if((Get-DevelopE2ECanonicalJsonSha256 $new.positiveInputIdentity.inventory) -cne $new.positiveInputIdentity.fingerprint -or
                $new.positiveInputIdentity.fingerprint -cne $new.inventory.external.positiveStandInputIdentity) {return $false}
            $positive=$new.positiveInputIdentity.inventory.external | ConvertTo-Json -Depth 24 | ConvertFrom-Json
            if($forkBridge) {
                if($positive.rulesCommit -cne $new.inventory.external.rulesCommit -or $positive.rulesTree -cne $new.inventory.external.rulesTree) {return $false}
                $positive.rulesCommit=$old.inventory.external.rulesCommit;$positive.rulesTree=$old.inventory.external.rulesTree
            }
            $positive.artifacts=$old.inventory.external.artifacts
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
            if($forkBridge) {
                $value.inventory.external.rulesCommit='native-contract:'+$forkBridge.nativeSha256
                $value.inventory.external.rulesTree='native-contract:'+$forkBridge.nativeSha256
            }
            $value.inventory.inputs=@($value.inventory.inputs|Where-Object path -cne 'scripts/ai-rules-native-inputs.ps1')
            if($value.inventory.external.PSObject.Properties['artifacts']) {
                $value.inventory.external.artifacts=ConvertTo-DevelopScenarioArtifactIdentity $value.inventory.external.artifacts $value.inventory.journey $Scenario
            }
            $value.inventory.external.client=ConvertTo-DevelopEffectiveClientIdentity $value.inventory.external.client
            if($value.inventory.external.PSObject.Properties['freshProjectsRoot']) {
                if(-not [IO.Path]::IsPathRooted([string]$value.inventory.external.freshProjectsRoot)) {return $false}
                $value.inventory.external.freshProjectsRoot=[IO.Path]::GetFullPath([string]$value.inventory.external.freshProjectsRoot).TrimEnd('\','/').ToLowerInvariant()
            }
        }
        if((Get-DevelopE2ECanonicalJsonSha256 $old.inventory.external) -cne (Get-DevelopE2ECanonicalJsonSha256 $new.inventory.external)) {return $false}
        # These paths belong to the current static proof, including additions
        # and deletions. Audited consumers and absence of embed must hold in
        # BOTH snapshots before their inventories can be projected out.
        if((Test-DevelopGoBuildOnlyPath $RepositoryRoot 'tools/itl-ondemand-mcp/README.md') -and
            (Test-DevelopGoBuildOnlyPath $RepositoryRoot 'tools/itl-ondemand-mcp/README.md' $QualifiedCommit)) {
            foreach($value in @($old,$new)) {
                $value.inventory.inputs=@($value.inventory.inputs | Where-Object {
                    $_.path -cne 'tools/itl-ondemand-mcp/README.md' -and $_.path -cnotmatch '^tools/itl-ondemand-mcp/[^/]+_test\.go$'})
            }
        }
        $brokerScoped=Test-DevelopScenarioBrokerIndependent $new.inventory.journey $Scenario
        if($brokerScoped) {
            foreach($value in @($old,$new)) {
                $value.inventory.inputs=@($value.inventory.inputs | Where-Object {$_.path -cnotmatch '^tools/itl-ondemand-mcp/[^/]+\.go$'})
            }
        }
        $before=@{};foreach($entry in $old.inventory.inputs) {$before[$entry.path]=$entry}
        $noProduct=$new.inventory.external.PSObject.Properties['productContext'] -and $new.inventory.external.productContext.known -and $new.inventory.external.productContext.disabled
        # A changed input without a scenario projection cannot qualify anyway.
        # Reject before historical Git/AST reads. This rejection grants no proof;
        # every eligible path still authenticates both sources below.
        foreach($entry in $new.inventory.inputs) {
            if($before.ContainsKey($entry.path) -and $before[$entry.path].sha256 -cne $entry.sha256 -and
                -not (Get-DevelopScenarioSourceProjection -Path $entry.path -Journey $new.inventory.journey -Scenario $Scenario -Catalog $Catalog -NoProductContext ([bool]$noProduct) -RepositoryRoot $RepositoryRoot -ProbeOnly -ForkBridge $forkBridge)) {return $false}
        }
        foreach($entry in @($new.inventory.inputs | Sort-Object {if($_.path -eq 'scripts/invoke-develop-e2e.ps1'){0}else{1}})) {
            if(-not $before.ContainsKey($entry.path)) {return $false}
            $prior=$before[$entry.path]
            if($prior.sha256 -ceq $entry.sha256) {continue}
            $a=Get-DevelopHistoricalSourceText $RepositoryRoot $QualifiedCommit $entry.path
            $b=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $RepositoryRoot $entry.path)))
            # Historical source is authenticated using the existing transport
            # hash before any scoped projection can authorize reuse.
            $bytes=if($entry.path -match '^(scripts/|\.agents/skills/|templates/).*\.ps1$') {
                [Text.Encoding]::UTF8.GetBytes($a.Replace("`r`n","`n"))
            } else {[Text.Encoding]::UTF8.GetBytes($a)}
            $sha=[Security.Cryptography.SHA256]::Create()
            try {$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
            $scope=Get-DevelopJourneyExcludedScope $entry.path $new.inventory.journey
            $contentOnly=$scope -and $scope.ContainsKey('contentOnly')
            if($hash -cne $prior.sha256 -and ($contentOnly -or $entry.path -cin @('.agents/skills/1c-workflow/references/mcp.md','.agents/skills/1c-workflow/references/workflow-update-recovery.md','tests/quality-contracts.json','templates/dependency-lock.json','.agents/skills/1c-workflow/assets/ondemand-mcp/compatibility.json'))) {
                # Git stores LF while an older Windows checkout can have CRLF.
                # Authenticate that exact alternative before semantic projection;
                # never normalize native artifacts or arbitrary source inputs.
                $sha=[Security.Cryptography.SHA256]::Create()
                try {$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($a.Replace("`r`n","`n").Replace("`n","`r`n"))))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
            }
            if($hash -cne $prior.sha256 -or (Get-DevelopE2EInputFileSha256 (Join-Path $RepositoryRoot $entry.path) $entry.path) -cne $entry.sha256) {return $false}
            if(@($Catalog.developJourneys.scenarioInputs | Where-Object path -eq $entry.path).Count) {
                # This invocation-only cache follows, never replaces, actual
                # historical/current SHA authentication. Cache null refusals too.
                $key=[string]$prior.sha256+':'+[string]$entry.sha256
                if($null -ne $LookupContext -and $LookupContext.changedFunctions.ContainsKey($key)) {$changed=$LookupContext.changedFunctions[$key]}
                else {
                    $changed=Get-DevelopChangedFunctions $a $b
                    if($null -ne $LookupContext) {$LookupContext.changedFunctions[$key]=$changed}
                }
                if($null -eq $changed) {return $false}
            }
            $x=Get-DevelopScenarioSourceProjection $entry.path $a $new.inventory.journey $Scenario $Catalog ([bool]$noProduct) -RepositoryRoot $RepositoryRoot -Commit $QualifiedCommit -ForkBridge $forkBridge
            $y=Get-DevelopScenarioSourceProjection $entry.path $b $new.inventory.journey $Scenario $Catalog ([bool]$noProduct) -RepositoryRoot $RepositoryRoot -ForkBridge $forkBridge
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
    $lookupContext=@{changedFunctions=@{};forkBridges=@{}}
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
                -StaticProof $StaticProof -AllowPendingStatic:$AllowPendingStatic -Diagnostics $diagnostics -RequiredScenario @($item.id) -Catalog $Catalog -QualificationInventory $inventory -LookupContext $lookupContext
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
