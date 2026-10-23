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
        'scripts/develop-configuration-rejection.ps1' { return @{ whole=$true } }
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
    if($tokens.Count -ge 4096) {
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

function Get-DevelopJourneySourceProjection {
    param([string]$Path,[AllowEmptyString()][string]$Text,[ValidateSet('fresh','upgrade')][string]$Journey='fresh')
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

function Test-DevelopJourneyUnaffectedPath {
    param([string]$RepositoryRoot,[string]$Path,[string]$BaseRef,[ValidateSet('fresh','upgrade')][string]$Journey='fresh')
    $scope=Get-DevelopJourneyExcludedScope -Path $Path -Journey $Journey
    if(-not $scope) { return $false }
    if($scope.ContainsKey('whole')) { return $true }
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
            Get-DevelopE2ECanonicalJsonSha256 $value
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
