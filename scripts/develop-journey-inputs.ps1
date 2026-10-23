Set-StrictMode -Version Latest

# One source projection is shared by journey selection and ancestor reuse.
# These nodes are unreachable from fresh's init/status/new/check/export/refresh
# actions. Everything else, including unknown functions and top-level code,
# remains an input. Do not turn this into a lifecycle-file exclusion.
function Get-DevelopFreshUpdateScope {
    param([string]$Path)
    switch -Exact ($Path.Replace('\','/')) {
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

function ConvertTo-DevelopSourceTokens {
    param([AllowEmptyString()][string]$Text)
    $Text=$Text.TrimStart([char]0xFEFF)
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if (@($errors).Count) { throw 'DEVELOP_SOURCE_PROJECTION_PARSE_ERROR' }
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
    $text=(Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @('show',$spec)).stdout
    # The shared Git UTF-8 StreamReader consumes a BOM. Recover it from the
    # authoritative blob byte count before comparing original source hashes.
    $size=[long](Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @('cat-file','-s',$spec)).stdout.Trim()
    $decoded=[Text.Encoding]::UTF8.GetByteCount($text)
    if($size -eq $decoded+3) { return ([string][char]0xFEFF)+$text }
    if($size -ne $decoded) { throw 'DEVELOP_SOURCE_TRANSPORT_MISMATCH' }
    return $text
}

function Get-DevelopFreshSourceProjection {
    param([string]$Path,[AllowEmptyString()][string]$Text)
    $scope=Get-DevelopFreshUpdateScope -Path $Path
    if (-not $scope) { return $null }
    if ($scope.ContainsKey('whole')) { return 'update-only-path' }
    $hasBom=$Text.StartsWith([string][char]0xFEFF,[StringComparison]::Ordinal)
    if($hasBom) { $Text=$Text.Substring(1) }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    if (@($errors).Count) { throw 'DEVELOP_SOURCE_PROJECTION_PARSE_ERROR' }
    $updateFunctions=(Get-DevelopFreshUpdateScope '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1').functions
    foreach($command in @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true))) {
        if($command.GetCommandName() -notin $updateFunctions) { continue }
        $parent=$command.Parent
        while($parent -and $parent -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $parent=$parent.Parent }
        if($parent -and $scope.ContainsKey('functions') -and $parent.Name -in $scope.functions) { continue }
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
    foreach($span in @($spans | Sort-Object start -Descending)) {
        if($span.end -gt $last) { throw 'DEVELOP_SOURCE_PROJECTION_OVERLAP' }
        [void]$builder.Remove($span.start,$span.end-$span.start)
        [void]$builder.Insert($span.start,$span.text)
        $last=$span.start
    }
    return ([string]$hasBom)+"`n"+(ConvertTo-DevelopSourceTokens $builder.ToString())
}

function Test-DevelopFreshUpdateOnlyPath {
    param([string]$RepositoryRoot,[string]$Path,[string]$BaseRef)
    $scope=Get-DevelopFreshUpdateScope -Path $Path
    if(-not $scope) { return $false }
    if($scope.ContainsKey('whole')) { return $true }
    if(-not $BaseRef) { return $false }
    try {
        $before=Get-DevelopHistoricalSourceText -RepositoryRoot $RepositoryRoot -Commit $BaseRef -Path $Path
        $after=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $RepositoryRoot $Path)))
        return (Get-DevelopFreshSourceProjection -Path $Path -Text $before) -ceq
            (Get-DevelopFreshSourceProjection -Path $Path -Text $after)
    } catch { return $false }
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
        if($changed.Count -and $Current.inventory.journey -cne 'fresh') { return $false }
        # Reject unrelated runtime drift before expensive historical AST reads.
        foreach($path in $changed) { if(-not (Get-DevelopFreshUpdateScope $path)) { return $false } }
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
            if($beforeHash -cne $old[$path] -or (Get-DevelopE2EInputFileSha256 -Path $afterPath -RelativePath $path) -cne $new[$path]) { return $false }
            if((Get-DevelopFreshSourceProjection -Path $path -Text $before) -cne (Get-DevelopFreshSourceProjection -Path $path -Text $after)) { return $false }
        }
        return $true
    } catch { return $false }
}
