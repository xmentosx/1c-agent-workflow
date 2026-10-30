Set-StrictMode -Version Latest

function Add-DevelopReuseDiagnostic {
    param([AllowNull()][Collections.Generic.List[object]]$Diagnostics,[string]$Code,[string]$Commit='',
        [string[]]$Inputs=@())
    if($null -eq $Diagnostics -or $Diagnostics.Count -ge 8) { return }
    $names=@($Inputs | Sort-Object -Unique)
    $Diagnostics.Add([pscustomobject]@{code=$Code; qualifiedCommit=$Commit;
        inputs=@($names | Select-Object -First 12); omittedInputCount=[math]::Max(0,$names.Count-12)})
}

# Explanations are advisory only: the acceptance owner still validates every
# hash, lineage, static proof and newer failure. Never emit environment values.
function Get-DevelopInputDifferenceNames {
    param([object]$Recorded,[object]$Current)
    $old=@{}; $new=@{}
    foreach($entry in @($Recorded.inventory.inputs)) {$old[[string]$entry.path]=[string]$entry.sha256}
    foreach($entry in @($Current.inventory.inputs)) {$new[[string]$entry.path]=[string]$entry.sha256}
    foreach($path in @(@($old.Keys)+@($new.Keys) | Sort-Object -Unique)) {
        if($old[$path] -cne $new[$path]) { 'source:'+ $path }
    }
    $before=$Recorded.inventory.external | ConvertTo-Json -Depth 24 | ConvertFrom-Json
    $after=$Current.inventory.external | ConvertTo-Json -Depth 24 | ConvertFrom-Json
    foreach($name in @(@($before.PSObject.Properties.Name)+@($after.PSObject.Properties.Name) | Sort-Object -Unique)) {
        $a=$before.PSObject.Properties[$name]; $b=$after.PSObject.Properties[$name]
        if(-not $a -or -not $b -or (Get-DevelopE2ECanonicalJsonSha256 $a.Value) -cne (Get-DevelopE2ECanonicalJsonSha256 $b.Value)) { 'external:'+ $name }
    }
    if((Get-DevelopE2ECanonicalJsonSha256 $Recorded.inventory.contract) -cne (Get-DevelopE2ECanonicalJsonSha256 $Current.inventory.contract)) {'contract'}
}

# One source projection is shared by journey selection and ancestor reuse.
# Exclude only nodes outside the requested journey's execution path. Everything
# else, including unknown functions and top-level code, remains an input.
# Never turn a node exclusion into an exemption for a shared runtime file.
function Get-DevelopJourneyExcludedScope {
    param([string]$Path,[ValidateSet('fresh','upgrade')][string]$Journey='fresh')
    if($Path -cin @('.agents/skills/1c-workflow/SKILL.md',
        '.agents/skills/1c-workflow/references/advanced-actions.md',
        '.agents/skills/1c-workflow/references/artifact-retention.md',
        '.agents/skills/1c-workflow/references/init-setup.md',
        '.agents/skills/1c-workflow/references/scoped-memory.md',
        '.agents/skills/1c-workflow/references/verification-change.md',
        '.agents/skills/1c-workflow/references/verification-result.md',
        '.agents/skills/1c-workflow/references/verification-suite-selection.md')) {
        # Installed presence is required, content is agent guidance. The fast
        # skill is deliberately NOT here: its marker and SHA are read at runtime.
        # Native callers print links to these references; static proof reads
        # their contents. Keep this audited set explicit; unknown files bind.
        return @{whole=$true;contentOnly=$true}
    }
    if($Path -ceq '.agents/skills/1c-workflow/references/mcp.md') {
        # A linked agent instruction, never read or executed by either native
        # runner. Its managed copy/content remains under current static proof.
        return @{whole=$true}
    }
    if($Path -ceq 'scripts/stand-env-identity.ps1') {
        # Discovery reads source artifacts for planning; it does not implement
        # either native journey. The rest of the shared stand contract binds.
        return @{functions=@('Find-SourceE2EArtifactBinding')}
    }
    if ($Journey -eq 'upgrade') {
        if ($Path -ceq 'scripts/invoke-develop-e2e.ps1') {
            return @{ functions=@('Set-FreshConfigurationComment','Get-BranchWorktree');
                conditions=@('$requestedJourneys -contains "fresh"') }
        }
        return $null
    }
    switch -Exact ($Path.Replace('\','/')) {
        # Source rules packaging/qualification is not executed by fresh install;
        # fresh consumes the independently pinned controlled-fork identity.
        'scripts/build-ai-rules-release.ps1' { return @{ whole=$true } }
        'scripts/test-ai-rules-compatibility.ps1' { return @{ whole=$true } }
        'scripts/test-ai-rules-overlay-lock.ps1' { return @{ whole=$true } }
        'scripts/promote-ai-rules-compatibility.ps1' { return @{ whole=$true } }
        # Shared planning is native fresh input; only negative-fixture helpers
        # belong exclusively to upgrade.
        'scripts/develop-configuration-rejection.ps1' { return @{ functions=@('Assert-DevelopConfigurationRejection','Initialize-DevelopConfigurationRejectionPlan','Invoke-DevelopConfigurationRejectionScenario') } }
        'scripts/update-installed-workflow.ps1' { return @{ whole=$true } }
        '.agents/skills/1c-workflow/references/workflow-update-recovery.md' { return @{ whole=$true } }
        '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1' {
            return @{ functions=@('Write-WorkflowUpdateFollowUp','Get-WorkflowUpdateRecoveryStatus',
                'Restore-CompletedWorkflowUpdate','Assert-WorkflowLegacyRecoveryMasterProof',
                'Complete-WorkflowUpdatePostCopyFromSnapshot','Get-WorkflowLegacyCopyEvidence',
                'Start-WorkflowLegacyCopyRecovery','Get-WorkflowUpdateCandidateRulesPaths','Update-WorkflowPackage') }
        }
        '.agents/skills/1c-workflow/scripts/agent-1c.ps1' {
            return @{ parameters=@('WorkflowUpdateRecovery','WorkflowUpdateLegacySourceRoot');
                conditions=@("`$WorkflowUpdateRecovery -eq 'legacy-copy'") }
        }
        '.agents/skills/1c-workflow/scripts/lib/agent-1c.product-project-runtime.ps1' {
            return @{ conditions=@("`$operation.status -eq 'completed' -and `$Mode -eq 'resume'") }
        }
    }
    return $null
}

function Get-DevelopSourceTokenNormalizer {
    # A stateless accelerator, keyed by its implementation so a candidate cannot
    # inherit another supervisor's loaded type. The original PS path remains
    # available on hosts where runtime compilation is unavailable.
    $definition=@'
using System;
using System.Collections.Generic;
using System.Text;
public static class __TYPE__ {
    struct Part { public string Kind; public string Text;
        public Part(string kind, string text) { Kind=kind; Text=text; } }
    public static string Normalize(object[] tokens) {
        if (tokens.Length==0) return "";
        var kindProperty=tokens[0].GetType().GetProperty("Kind");
        var textProperty=tokens[0].GetType().GetProperty("Text");
        var parts=new List<Part>();
        foreach (var token in tokens) {
            var kind=Convert.ToString(kindProperty.GetValue(token,null));
            if (kind=="Comment" || kind=="EndOfInput" || kind=="LineContinuation") continue;
            parts.Add(new Part(kind,Convert.ToString(textProperty.GetValue(token,null))));
        }
        var output=new StringBuilder(); var last=""; bool first=true;
        for (int i=0;i<parts.Count;i++) {
            var part=parts[i];
            if (part.Kind=="NewLine") {
                int next=i+1;
                while (next<parts.Count && parts[next].Kind=="NewLine") next++;
                if (last=="" || last=="NewLine" || last=="LCurly" || next==parts.Count || parts[next].Kind=="RCurly") continue;
                if (!first) output.Append('\n'); first=false;
                output.Append("NewLine:"); last="NewLine";
            } else {
                if (!first) output.Append('\n'); first=false;
                output.Append(part.Kind).Append(':').Append(part.Text); last=part.Kind;
            }
        }
        return output.ToString();
    }
}
'@
    $sha=[Security.Cryptography.SHA256]::Create()
    try {$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($definition)))).Replace('-','')}
    finally {$sha.Dispose()}
    $name='ItlDevelopTokens_'+$hash
    $cache=Get-Variable -Name developTokenNormalizers -Scope Script -ErrorAction SilentlyContinue
    if(-not $cache) {$script:developTokenNormalizers=@{}}
    if(-not $script:developTokenNormalizers.ContainsKey($name)) {
        $type=$name -as [type]
        if(-not $type) {
            try {$type=Add-Type -TypeDefinition ($definition.Replace('__TYPE__',$name)) -PassThru -ErrorAction Stop | Where-Object FullName -CEQ $name}
            catch {Write-Verbose 'Token accelerator unavailable; retaining the original PowerShell normalization.'; $type=$null}
        }
        $script:developTokenNormalizers[$name]=$type
    }
    return $script:developTokenNormalizers[$name]
}

function ConvertTo-DevelopSourceTokens {
    param([AllowEmptyString()][string]$Text)
    $Text=$Text.TrimStart([char]0xFEFF)
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if (@($errors).Count) { throw 'DEVELOP_SOURCE_PROJECTION_PARSE_ERROR' }
    # A real plan normalizes thousands of small function bodies. Applying the
    # same stateless accelerator only to large files leaves that cost dominant.
    if($tokens.Count) {
        $normalizer=Get-DevelopSourceTokenNormalizer
        if($normalizer) {
            try {return $normalizer::Normalize($tokens)}
            catch {Write-Verbose 'Token accelerator rejected this host input; retaining the original PowerShell normalization.'}
        }
    }
    $meaningful=@($tokens | Where-Object { $_.Kind -notin @('Comment','EndOfInput','LineContinuation') })
    $parts=[Collections.Generic.List[string]]::new(); $lastKind=''
    for($i=0;$i -lt $meaningful.Count;$i++) {
        $token=$meaningful[$i]
        if($token.Kind -eq 'NewLine') {
            $next=$i+1
            while($next -lt $meaningful.Count -and $meaningful[$next].Kind -eq 'NewLine') { $next++ }
            # Blank lines around removed nodes are immaterial. A statement
            # separator is not: return<newline>x differs from return x.
            if($lastKind -and $lastKind -notin @('NewLine','LCurly') -and
                $next -lt $meaningful.Count -and $meaningful[$next].Kind -ne 'RCurly') {
                $parts.Add('NewLine:'); $lastKind='NewLine'
            }
            continue
        }
        $parts.Add(([string]$token.Kind)+':'+[string]$token.Text); $lastKind=[string]$token.Kind
    }
    return $parts -join "`n"
}

function Get-DevelopHistoricalSourceText {
    param([string]$RepositoryRoot,[string]$Commit,[string]$Path)
    $spec="${Commit}:$Path"
    # Explicitly end revisions: without -- Git also probes commit:path as a
    # filesystem path, which can exceed MAX_PATH in nested registration fixtures.
    $text=(Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @('show',$spec,'--')).stdout
    # The shared Git UTF-8 StreamReader consumes a BOM. Recover it from the
    # authoritative blob byte count before comparing original source hashes.
    $size=[long](Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @('cat-file','-s',$spec)).stdout.Trim()
    $decoded=[Text.Encoding]::UTF8.GetByteCount($text)
    if($size -eq $decoded+3) { return ([string][char]0xFEFF)+$text }
    if($size -ne $decoded) { throw 'DEVELOP_SOURCE_TRANSPORT_MISMATCH' }
    return $text
}

function Get-DevelopBrokerCleanupSourceProjection {
    param([string]$Text)
    # Develop never invokes the signed internal broker operation. Only that RPC
    # path supplies RetainedRuntimeState; ordinary lifecycle drain uses the
    # registered-instance path. Keep that path and the rest of this module exact.
    $Text=$Text.Replace("`r`n","`n")
    $bom=[string]$Text.StartsWith([string][char]0xfeff,[StringComparison]::Ordinal)
    $source=$Text.TrimStart([char]0xfeff);$tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
    if(@($errors).Count) {throw 'DEVELOP_BROKER_SCOPE_PARSE_ERROR'}
    $functions=@($ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst]})
    $stop=@($functions | Where-Object Name -eq 'Stop-ItlOnDemandBackendInstanceCore')
    if($stop.Count -ne 1) {throw 'DEVELOP_BROKER_SCOPE_UNKNOWN'}
    $parameter=@($stop[0].Body.ParamBlock.Parameters | Where-Object {$_.Name.VariablePath.UserPath -eq 'RetainedRuntimeState'})
    $assignments=@($stop[0].Body.FindAll({param($n)
        $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ieq '$retained'
    },$true))
    if($parameter.Count -ne 1 -or -not $parameter[0].DefaultValue -or
        $parameter[0].DefaultValue.Extent.Text -ine '$null' -or $assignments.Count -ne 1 -or
        (ConvertTo-DevelopSourceTokens $assignments[0].Extent.Text) -cne (ConvertTo-DevelopSourceTokens '$retained = $null -ne $RetainedRuntimeState')) {
        throw 'DEVELOP_BROKER_SCOPE_UNKNOWN'
    }
    $blocks=@($stop[0].Body.FindAll({param($n)
        $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses.Count -eq 1 -and
        -not $n.ElseClause -and $n.Clauses[0].Item1.Extent.Text.Trim() -ieq '$retained'
    },$true))
    if($blocks.Count -ne 1) {throw 'DEVELOP_BROKER_SCOPE_UNKNOWN'}
    $cleanup=@($functions | Where-Object Name -eq 'Test-ItlOnDemandRetainedCleanupComplete')
    $cleanupBlocks=@($stop[0].Body.FindAll({param($n)
        $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses.Count -eq 1 -and -not $n.ElseClause -and
        (ConvertTo-DevelopSourceTokens $n.Clauses[0].Item1.Extent.Text) -ceq
            (ConvertTo-DevelopSourceTokens '$retained -and (Test-ItlOnDemandRetainedCleanupComplete -RuntimeState $runtimeState)')
    },$true))
    if($cleanup.Count -gt 1 -or $cleanupBlocks.Count -ne $cleanup.Count) {throw 'DEVELOP_BROKER_SCOPE_UNKNOWN'}
    $peerScopes=@($blocks[0])+@($cleanup)
    $spans=@($peerScopes)+@($cleanupBlocks)+@($functions | Where-Object Name -eq 'Test-ItlOnDemandPeerSessionOwnership')
    foreach($command in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true))) {
        # A helper promoted to a shared path immediately closes this exception.
        if($command.GetCommandName() -eq 'Test-ItlOnDemandPeerSessionOwnership' -and -not @($peerScopes | Where-Object {
            $command.Extent.StartOffset -ge $_.Extent.StartOffset -and $command.Extent.EndOffset -le $_.Extent.EndOffset
        }).Count) {
            throw 'DEVELOP_BROKER_SCOPE_SHARED_CALLER'
        }
        if($command.GetCommandName() -eq 'Test-ItlOnDemandRetainedCleanupComplete') {
            $parent=$command.Parent
            while($parent -and $parent -isnot [Management.Automation.Language.FunctionDefinitionAst]) {$parent=$parent.Parent}
            $inRetainedStop=@($cleanupBlocks | Where-Object {
                $command.Extent.StartOffset -ge $_.Extent.StartOffset -and $command.Extent.EndOffset -le $_.Extent.EndOffset
            }).Count -eq 1
            if(-not $inRetainedStop -and (-not $parent -or $parent.Name -ne 'Get-ItlOnDemandRetainedLaunchState')) {
                throw 'DEVELOP_BROKER_SCOPE_SHARED_CALLER'
            }
        }
        if(@($command.CommandElements | Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'RetainedRuntimeState'}).Count) {
            $parent=$command.Parent
            while($parent -and $parent -isnot [Management.Automation.Language.FunctionDefinitionAst]) {$parent=$parent.Parent}
            if(-not $parent -or $parent.Name -notin @('Recover-ItlOnDemandBackendInstanceCore','Invoke-ItlOnDemandBackendBroker')) {throw 'DEVELOP_BROKER_SCOPE_SHARED_CALLER'}
        }
    }
    $builder=[Text.StringBuilder]::new($source)
    foreach($node in @($spans | Sort-Object {$_.Extent.StartOffset} -Descending)) {
        [void]$builder.Remove($node.Extent.StartOffset,$node.Extent.EndOffset-$node.Extent.StartOffset)
    }
    return $bom+"`n"+(ConvertTo-DevelopSourceTokens $builder.ToString())
}

function Get-DevelopJourneySourceProjection {
    param([string]$Path,[AllowEmptyString()][string]$Text,[ValidateSet('fresh','upgrade')][string]$Journey='fresh')
    if($Path -ceq '.agents/skills/1c-workflow/scripts/lib/agent-1c.ondemand-mcp.ps1') {
        return Get-DevelopBrokerCleanupSourceProjection $Text
    }
    $scope=Get-DevelopJourneyExcludedScope -Path $Path -Journey $Journey
    if (-not $scope) { return $null }
    if ($scope.ContainsKey('whole')) { return 'outside-requested-journey' }
    # Match the existing PowerShell transport hash contract, including CRLF
    # inside multiline token text. Keep BOM and every other source character.
    $Text=$Text.Replace("`r`n","`n")
    $hasBom=$Text.StartsWith([string][char]0xFEFF,[StringComparison]::Ordinal)
    if($hasBom) { $Text=$Text.Substring(1) }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if (@($errors).Count) { throw 'DEVELOP_SOURCE_PROJECTION_PARSE_ERROR' }
    $updateFunctions=@()
    if($Journey -eq 'fresh') {$updateFunctions+=@((Get-DevelopJourneyExcludedScope '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1').functions)}
    if($scope.ContainsKey('functions')) {$updateFunctions+=@($scope.functions)}
    foreach($command in @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true))) {
        if($command.GetCommandName() -notin $updateFunctions) { continue }
        $parent=$command.Parent
        while($parent -and $parent -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $parent=$parent.Parent }
        if($parent -and $scope.ContainsKey('functions') -and $parent.Name -in $scope.functions) { continue }
        if ($Journey -eq 'upgrade' -and $scope.ContainsKey('conditions')) {
            $parent=$command.Parent; $inFresh=$false
            while($parent) {
                if($parent -is [Management.Automation.Language.IfStatementAst] -and $parent.Clauses.Count -eq 1 -and -not $parent.ElseClause -and
                    (ConvertTo-DevelopSourceTokens $parent.Clauses[0].Item1.Extent.Text) -ceq (ConvertTo-DevelopSourceTokens $scope.conditions[0])) { $inFresh=$true; break }
                $parent=$parent.Parent
            }
            if($inFresh) { continue }
        }
        $inUpdateDispatch=$false
        if($Path -ceq '.agents/skills/1c-workflow/scripts/agent-1c.ps1') {
            foreach($dispatch in @($ast.FindAll({param($n) $n -is [Management.Automation.Language.SwitchStatementAst] -and $n.Condition.Extent.Text -ceq '$Action'},$true))) {
                foreach($clause in $dispatch.Clauses) {
                    if($clause.Item1 -is [Management.Automation.Language.StringConstantExpressionAst] -and $clause.Item1.Value -ceq 'update-workflow' -and
                        $command.Extent.StartOffset -ge $clause.Item2.Extent.StartOffset -and $command.Extent.EndOffset -le $clause.Item2.Extent.EndOffset) { $inUpdateDispatch=$true }
                }
            }
        }
        if(-not $inUpdateDispatch) { throw 'DEVELOP_UPDATE_SCOPE_HAS_SHARED_CALLER' }
    }
    $spans=[Collections.Generic.List[object]]::new()
    if ($scope.ContainsKey('parameters') -and $ast.ParamBlock) {
        foreach($parameter in @($ast.ParamBlock.Parameters | Where-Object {$_.Name.VariablePath.UserPath -in $scope.parameters})) {
            if($parameter.DefaultValue -and $parameter.DefaultValue.Extent.Text -cnotin @("''",'""')) {
                throw 'DEVELOP_UPDATE_PARAMETER_HAS_SHARED_DEFAULT'
            }
            foreach($attribute in @($parameter.Attributes)) {
                if($attribute -is [Management.Automation.Language.TypeConstraintAst] -and $attribute.TypeName.FullName -ceq 'string') { continue }
                if($attribute -is [Management.Automation.Language.AttributeAst] -and $attribute.TypeName.FullName -ceq 'ValidateSet' -and
                    $attribute.NamedArguments.Count -eq 0 -and @($attribute.PositionalArguments | Where-Object {$_ -isnot [Management.Automation.Language.StringConstantExpressionAst]}).Count -eq 0) { continue }
                throw 'DEVELOP_UPDATE_PARAMETER_HAS_SHARED_ATTRIBUTE'
            }
        }
        $remaining=@($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -notin $scope.parameters })
        $replacement=@($ast.ParamBlock.Attributes | ForEach-Object {$_.Extent.Text}) -join "`n"
        $replacement+="`nparam("+(@($remaining | ForEach-Object {$_.Extent.Text}) -join ',')+')'
        $spans.Add(@{start=$ast.ParamBlock.Extent.StartOffset;end=$ast.ParamBlock.Extent.EndOffset;text=$replacement})
    }
    foreach($node in @($ast.EndBlock.Statements)) {
        if($node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $scope.ContainsKey('functions') -and $node.Name -in $scope.functions) {
            $spans.Add(@{start=$node.Extent.StartOffset;end=$node.Extent.EndOffset;text=''})
        }
    }
    if($scope.ContainsKey('conditions')) {
        $conditions=@($scope.conditions | ForEach-Object {ConvertTo-DevelopSourceTokens $_})
        foreach($node in @($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst]},$true))) {
            # Else/elseif can introduce a shared path; never hide it.
            if($node.Clauses.Count -eq 1 -and -not $node.ElseClause -and
                (ConvertTo-DevelopSourceTokens $node.Clauses[0].Item1.Extent.Text) -cin $conditions) {
                $spans.Add(@{start=$node.Extent.StartOffset;end=$node.Extent.EndOffset;text=''})
            }
        }
    }
    $builder=[Text.StringBuilder]::new($Text)
    $last=$Text.Length
    # Windows PowerShell 5.1 does not reliably resolve a named sort property
    # on Hashtable items; compare numeric offsets explicitly.
    foreach($span in @($spans | Sort-Object { [int]$_.start } -Descending)) {
        if($span.end -gt $last) { throw 'DEVELOP_SOURCE_PROJECTION_OVERLAP' }
        [void]$builder.Remove($span.start,$span.end-$span.start)
        [void]$builder.Insert($span.start,$span.text)
        $last=$span.start
    }
    return ([string]$hasBom)+"`n"+(ConvertTo-DevelopSourceTokens $builder.ToString())
}

function Test-DevelopGoBuildOnlyPath {
    param([string]$RepositoryRoot,[string]$Path,[string]$Commit='')
    # The native runner builds this main package with -SkipTests. Go excludes
    # *_test.go; README is not compiled. Explicit embed can consume either, so
    # refuse this exception if any compiled source contains an embed directive.
    if($Path -cne 'tools/itl-ondemand-mcp/README.md' -and $Path -cnotmatch '^tools/itl-ondemand-mcp/[^/]+_test\.go$') {return $false}
    try {
        # Pin the audited consumers too: a future runner/builder could read
        # tests or docs as data. Such a change closes this exception until its
        # native input contract is reviewed, even after a new baseline passes.
        # The reviewed legacy-snapshot continuation and its launcher do not
        # consume Go tests or README; any new reader closes this exception.
        $consumers=@{
            # Scoped stand rollout only adds/forwards an explicit roots-file
            # argument; the abandon recovery mode only adds a validated value.
            # Neither introduces a Go test or README reader.
            # Catalog selection adds three typed arguments and forwards them
            # to the same helper; reviewed content still reads no Go input.
            # Stand-scoped selection reads only its project/configuration XML.
            'scripts/update-installed-workflow.ps1'=@('bd4c23855e9255bb112277d33a36c1d2b263860d455dfeb3fd7919b36bd51664','f07f3182a49f119857a37ef84df5cccc9510517f620c242a466333d7114136af','d9acb246fc18235a3824bb2671ef25158a2822e8d71a26087a07922023e18254','0112c05de9d755f9351571e4f76376aae8e26689599588fefd075f7b584f3855')
            # Technical-catalog arguments and bootstrap parameter discovery add
            # no Go input reader.
            'scripts/invoke-develop-e2e.ps1'=@('f212c4b4f3fa9e9764212a3301985984db36a9c4fbc4d9451c4daa13a60d0bda','10c7ead27281f26f760c2ec0ad408b9e6152ed39c2492d4ad9102d36a99eebb9','00b1dfc5ea577a96c912453c42f9acb06ba7de5e32a95010d9501c3331c1c62e','b125e5b0cc18070f26f232193c0a26fe2331926a62edc4b048e196cc8dc7e3bc')
            # The rejection proof only stops requiring a pending refresh merge
            # on the production path; it reads no Go test or README.
            'scripts/develop-configuration-rejection.ps1'=@('26f565c76987e8bb531058116f254b53c21261efcd81623f7eba1891270f8075','5104d1d4df221895d135fcab07e76dfca42178cfb74a6a14031c0cd8570c0ff8','02a82e9c5152cef9fa4a3f48fcc355fd2d04851ba042dbae31140c615cb30036','05a432a05d0662a698bf7e1cb57fa7c09c41a6f5130be5443e889feb7b54b6f6','d408e54e85af22783ebf5ad9588442cfaa073aa5d2f7296aced8422ab4242955')
            # Catalog preparation/selection and bootstrap parameter discovery
            # read project settings, configuration XML and the declared script
            # parameters; none consumes Go tests or README data.
            # Restoring the exact technical publisher adds only binding/UUID
            # checks and the same catalog payload; it adds no Go input reader.
            'scripts/source-e2e-workflow-update.ps1'=@('8718186e811cd530c17dbb58dc08b88d3b07c8bf85b18194e98ba6a696e4c92e','82706efbc085410fd34da680a6a09f05db453a7b99ed1ea03731df1818f09ed4','27c8386bb9cd6158b3acd137950f57d22d203625cacc928a8085f8c592d08c7e','51804b1968b8b21fda559e06682812c3cd1c4436c5eeec0077df81909bb36293')
            'scripts/Build-ItlOnDemandMcp.ps1'='a300217bd37da53e3ce4a00dde1a371803b0a25baae0818e6ac5ceba50ee56c6'
        }
        foreach($consumer in $consumers.Keys) {
            $text=if($Commit){Get-DevelopHistoricalSourceText $RepositoryRoot $Commit $consumer}else{[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $RepositoryRoot $consumer)))}
            $sha=[Security.Cryptography.SHA256]::Create()
            try {$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text.Replace("`r`n","`n"))))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
            if($hash -cnotin @($consumers[$consumer])) {return $false}
        }
        $arguments=if($Commit){@('ls-tree','-r','--name-only','-z',$Commit,'--')}else{@('ls-files','-z','--')}
        $sources=@(Get-RepositoryGitPathList -RepositoryRoot $RepositoryRoot -Arguments $arguments | Where-Object {
            $_ -cmatch '^tools/itl-ondemand-mcp/[^/]+\.go$' -and $_ -cnotmatch '_test\.go$'})
        if(-not $sources.Count) {return $false}
        foreach($source in $sources) {
            $text=if($Commit){Get-DevelopHistoricalSourceText $RepositoryRoot $Commit $source}else{[IO.File]::ReadAllText((Join-Path $RepositoryRoot $source))}
            if($text -match 'go:embed') {return $false}
        }
        return $true
    } catch {return $false}
}

function Test-DevelopJourneyUnaffectedPath {
    param([string]$RepositoryRoot,[string]$Path,[string]$BaseRef,[ValidateSet('fresh','upgrade')][string]$Journey='fresh')
    if($BaseRef -and (Test-DevelopGoBuildOnlyPath $RepositoryRoot $Path) -and
        (Test-DevelopGoBuildOnlyPath $RepositoryRoot $Path $BaseRef)) {return $true}
    if($BaseRef -and $Path -ceq '.agents/skills/1c-workflow/scripts/lib/agent-1c.ondemand-mcp.ps1') {
        try {
            $before=Get-DevelopHistoricalSourceText $RepositoryRoot $BaseRef $Path
            $after=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $RepositoryRoot $Path)))
            return (Get-DevelopBrokerCleanupSourceProjection $before) -ceq (Get-DevelopBrokerCleanupSourceProjection $after)
        } catch {return $false}
    }
    $scope=Get-DevelopJourneyExcludedScope -Path $Path -Journey $Journey
    if(-not $scope) { return $false }
    if($scope.ContainsKey('whole')) {
        if($scope.ContainsKey('contentOnly')) {
            if(-not $BaseRef -or -not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $Path) -PathType Leaf)) {return $false}
            try {[void](Get-DevelopHistoricalSourceText $RepositoryRoot $BaseRef $Path)} catch {return $false}
        }
        return $true
    }
    if(-not $BaseRef) { return $false }
    try {
        $before=Get-DevelopHistoricalSourceText -RepositoryRoot $RepositoryRoot -Commit $BaseRef -Path $Path
        $after=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $RepositoryRoot $Path)))
        return (Get-DevelopJourneySourceProjection -Path $Path -Text $before -Journey $Journey) -ceq
            (Get-DevelopJourneySourceProjection -Path $Path -Text $after -Journey $Journey)
    } catch {
        Write-Verbose "DEVELOP_JOURNEY_SOURCE_UNAVAILABLE ($Journey, $Path): $($_.Exception.Message)"
        return $false
    }
}

function Test-DevelopE2EEquivalentInput {
    param([string]$RepositoryRoot,[object]$Recorded,[object]$Current,[string]$QualifiedCommit)
    try {
        foreach($input in @($Recorded,$Current)) {
            if([int]$input.schemaVersion -ne 2 -or -not $input.inventory.external.complete -or
                (Get-DevelopE2ECanonicalJsonSha256 $input.inventory) -cne [string]$input.fingerprint) { return $false }
        }
        if($Recorded.inventory.journey -cne $Current.inventory.journey) { return $false }
        $contracts=@(foreach($input in @($Recorded,$Current)) {
            $value=$input.inventory.contract | ConvertTo-Json -Depth 24 | ConvertFrom-Json
            # A deadline is still pinned by the immutable plan, not by workload.
            $value.PSObject.Properties.Remove('hardSeconds')
            # Adding an isolated static regression to an owner's path catalog
            # cannot change the native journey workload. Other paths/fields bind.
            foreach($owner in @($value.contracts)) {
                $owner.paths=@($owner.paths | Where-Object {$_ -notlike 'tests/pester/*.Tests.ps1'})
            }
            Get-DevelopScenarioWorkloadHash $value
        })
        if($contracts[0] -cne $contracts[1]) { return $false }
        $oldExternal=$Recorded.inventory.external | ConvertTo-Json -Depth 24 | ConvertFrom-Json
        $newExternal=$Current.inventory.external | ConvertTo-Json -Depth 24 | ConvertFrom-Json
        if($oldExternal.PSObject.Properties['positiveStandInputIdentity'] -or $newExternal.PSObject.Properties['positiveStandInputIdentity']) {
            # Old receipts stored a nested fingerprint, not its inventory. Derive
            # that exact old fingerprint using the unchanged positive environment
            # and old source inventory; never ignore this environment boundary.
            if(-not $Current.PSObject.Properties['positiveInputIdentity']) { return $false }
            $positive=$Current.positiveInputIdentity
            if((Get-DevelopE2ECanonicalJsonSha256 $positive.inventory) -cne $positive.fingerprint -or
                $positive.fingerprint -cne $newExternal.positiveStandInputIdentity) { return $false }
            $historical=[ordered]@{schemaVersion=2;journey=$Recorded.inventory.journey;
                contract=$Recorded.inventory.contract;inputs=$Recorded.inventory.inputs;external=$positive.inventory.external}
            if((Get-DevelopE2ECanonicalJsonSha256 $historical) -cne $oldExternal.positiveStandInputIdentity) { return $false }
            $oldExternal.PSObject.Properties.Remove('positiveStandInputIdentity')
            $newExternal.PSObject.Properties.Remove('positiveStandInputIdentity')
        }
        if((Get-DevelopE2ECanonicalJsonSha256 $oldExternal) -cne (Get-DevelopE2ECanonicalJsonSha256 $newExternal)) { return $false }
        $old=@{}; $new=@{}
        foreach($entry in @($Recorded.inventory.inputs)) { if($old.ContainsKey($entry.path)){return $false}; $old[$entry.path]=$entry.sha256 }
        foreach($entry in @($Current.inventory.inputs)) { if($new.ContainsKey($entry.path)){return $false}; $new[$entry.path]=$entry.sha256 }
        if((@($old.Keys | Sort-Object) -join "`n") -cne (@($new.Keys | Sort-Object) -join "`n")) { return $false }
        $changed=@($old.Keys | Where-Object {$old[$_] -cne $new[$_]})
        # Reject unrelated runtime drift before expensive historical AST reads.
        foreach($path in $changed) { if(-not (Get-DevelopJourneyExcludedScope -Path $path -Journey $Current.inventory.journey)) { return $false } }
        foreach($path in $changed) {
            $before=Get-DevelopHistoricalSourceText -RepositoryRoot $RepositoryRoot -Commit $QualifiedCommit -Path $path
            $afterPath=Join-Path $RepositoryRoot $path
            $after=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($afterPath))
            # Authenticate the historical source against the original input
            # hash, including BOM. Only PS transport normalizes LF/CRLF.
            $beforeBytes=if($path -match '^(scripts/|\.agents/skills/|templates/).*\.ps1$') {
                [Text.Encoding]::UTF8.GetBytes($before.Replace("`r`n","`n").Replace("`r","`n"))
            } else { [Text.Encoding]::UTF8.GetBytes($before) }
            $sha=[Security.Cryptography.SHA256]::Create()
            try { $beforeHash=([BitConverter]::ToString($sha.ComputeHash($beforeBytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
            if($beforeHash -cne $old[$path] -and $path -ceq '.agents/skills/1c-workflow/references/workflow-update-recovery.md') {
                # Git stores text as LF while the historical Windows checkout
                # may have been CRLF. Authenticate that exact alternative only
                # for this non-executable, update-only document. Never normalize
                # native artifacts, 1C transport or arbitrary runtime inputs.
                $checkoutBytes=[Text.Encoding]::UTF8.GetBytes($before.Replace("`r`n","`n").Replace("`n","`r`n"))
                $sha=[Security.Cryptography.SHA256]::Create()
                try { $beforeHash=([BitConverter]::ToString($sha.ComputeHash($checkoutBytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
            }
            if($beforeHash -cne $old[$path] -or (Get-DevelopE2EInputFileSha256 -Path $afterPath -RelativePath $path) -cne $new[$path]) { return $false }
            if((Get-DevelopJourneySourceProjection -Path $path -Text $before -Journey $Current.inventory.journey) -cne (Get-DevelopJourneySourceProjection -Path $path -Text $after -Journey $Current.inventory.journey)) { return $false }
        }
        return $true
    } catch { return $false }
}
