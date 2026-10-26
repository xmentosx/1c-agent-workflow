# Source qualification only. No installed state, queue or native operation owner.
. (Join-Path $PSScriptRoot 'git-path-list.ps1')

function Get-AiRulesAuditedGuidanceInstaller {
    # This installer treats content/rules bodies as transformed UTF-8 data.
    # A changed consumer closes the exception even after a new baseline passes.
    return 'a264dc9ae5d483888659ec87115f25adff7578bf'
}

function Get-AiRulesNativeGuidanceConsumers {
    $path=Join-Path (Split-Path -Parent $PSScriptRoot) '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1'
    $key=$path+':'+(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $cached=Get-Variable aiRulesGuidanceConsumerSnapshot -Scope Script -ErrorAction SilentlyContinue
    if($cached -and $cached.Value.key -ceq $key) {return $cached.Value.value}
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if($errors.Count) {return $null}
    $expected=@{
        'Get-AiRules1cOpenSpecStatus'='2f4436716c9f2ffd8b26d5b3c3f0d1b037ab1d75b95827aa450d92a368839479'
        'Get-AiRulesUiTestingPolicySupportState'='338a33925918d8407f49e84d00ea68a5249b1118c0cc36250e50b63a436d05d1'
    }
    foreach($name in $expected.Keys) {
        $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true)
        if(-not $fn) {return $null}
        $sha=[Security.Cryptography.SHA256]::Create()
        try {$actual=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fn.Extent.Text.Replace("`r`n","`n"))))).Replace('-','').ToLowerInvariant()} finally {$sha.Dispose()}
        if($actual -cne $expected[$name]) {return $null}
        if($name -ceq 'Get-AiRulesUiTestingPolicySupportState') {
            $pattern=@($fn.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$pattern'},$true))
            if($pattern.Count -ne 1) {return $null}
            $literal=$pattern[0].Right.Find({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst]},$true)
            if(-not $literal) {return $null}
            $uiPattern=$literal.Value
        }
    }
    $value=[pscustomobject]@{readers=$expected;uiPattern=$uiPattern;paths=@('content/rules/dev-standards-env.md','content/rules/sdd-integrations.md','content/rules/verification-delivery.md','content/rules/verification-policy.md')}
    $script:aiRulesGuidanceConsumerSnapshot=@{key=$key;value=$value}
    return $value
}

function Get-AiRulesNativeBridge {
    param([string]$Root,[string]$FromCommit,[string]$FromTree,[string]$ToCommit,[string]$ToTree)
    try {
        foreach($id in @($FromCommit,$FromTree,$ToCommit,$ToTree)) {if($id -cnotmatch '^[a-f0-9]{40}$') {return $null}}
        if((Invoke-RepositoryGit $Root @('rev-parse','HEAD')).stdout.Trim() -cne $ToCommit -or
            @(Get-RepositoryGitPathList $Root @('status','--porcelain=v1','--untracked-files=all','-z')).Count) {return $null}
        if((Invoke-RepositoryGit $Root @('merge-base','--is-ancestor',$FromCommit,$ToCommit) -AllowFailure).exitCode -ne 0) {return $null}
        $maps=@(foreach($pair in @(@($FromCommit,$FromTree),@($ToCommit,$ToTree))) {
            if((Invoke-RepositoryGit $Root @('rev-parse',($pair[0]+'^{tree}'))).stdout.Trim() -cne $pair[1]) {return $null}
            $map=@{}
            foreach($row in @(Get-RepositoryGitPathList $Root @('ls-tree','-r','-z',$pair[0],'--'))) {
                if($row -cnotmatch '^([0-9]{6}) blob ([a-f0-9]{40})\t([\s\S]+)$') {return $null}
                if($map.ContainsKey($Matches[3])) {return $null}
                $map[$Matches[3]]=[pscustomobject]@{path=$Matches[3];mode=$Matches[1];blob=$Matches[2]}
            }
            ,$map
        })
        if($maps.Count -ne 2 -or $maps[0].Count -ne $maps[1].Count -or
            -not $maps[0].ContainsKey('install.ps1') -or
            $maps[0]['install.ps1'].blob -cne (Get-AiRulesAuditedGuidanceInstaller) -or
            $maps[1]['install.ps1'].blob -cne $maps[0]['install.ps1'].blob) {return $null}
        $consumers=Get-AiRulesNativeGuidanceConsumers
        if(-not $consumers) {return $null}
        $lines=[Collections.Generic.List[string]]::new();$guidance=[Collections.Generic.List[string]]::new()
        foreach($name in @($consumers.readers.Keys|Sort-Object)) {$lines.Add('workflow-reader='+$name+'='+$consumers.readers[$name])}
        [string[]]$orderedPaths=@($maps[0].Keys)
        [Array]::Sort($orderedPaths,[StringComparer]::Ordinal)
        foreach($path in $orderedPaths) {
            $a=$maps[0][$path];$b=$maps[1][$path]
            if(-not $b -or $b.path -cne $path -or $a.mode -cne $b.mode -or $a.mode -cnotin @('100644','100755')) {return $null}
            $value=$a.blob
            if($a.blob -cne $b.blob) {
                if($a.mode -ceq '100644' -and $path -cin $consumers.paths) {
                    $headers=@(foreach($commit in @($FromCommit,$ToCommit)) {
                        $text=(Invoke-RepositoryGit $Root @('show',($commit+':'+$path))).stdout
                        $header=[regex]::Match($text,'(?s)\A\uFEFF?---\r?\n(.*?)\r?\n---(?:\r?\n|$)')
                        if(-not $header.Success) {return $null}
                        [pscustomobject]@{frontmatter=$header.Groups[1].Value;signal=$(if($path -ceq 'content/rules/dev-standards-env.md'){[string][bool]($text -match $consumers.uiPattern)}else{'installed-presence'})}
                    })
                    if($headers.Count -ne 2 -or $headers[0].frontmatter -cne $headers[1].frontmatter -or $headers[0].signal -cne $headers[1].signal) {return $null}
                    $value='guidance-header='+$headers[0].frontmatter+'|native='+$headers[0].signal;$guidance.Add($path)
                } elseif($path -ceq 'tools/validate-rules.ps1') {
                    # The audited installer never invokes this source-only gate.
                    $value='current-fork-full-checker'
                } else {return $null}
            }
            $lines.Add($path+"`0"+$a.mode+"`0"+$value)
        }
        $sha=[Security.Cryptography.SHA256]::Create()
        try {$digest=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`0"))))).Replace('-','').ToLowerInvariant()} finally {$sha.Dispose()}
        return [pscustomobject]@{schemaVersion=1;sourceRoot=[IO.Path]::GetFullPath($Root);fromCommit=$FromCommit;fromTree=$FromTree;toCommit=$ToCommit;toTree=$ToTree;nativeSha256=$digest;guidancePaths=@($guidance.ToArray())}
    } catch {return $null}
}

function Get-DevelopForkNativeBridge {
    param([object]$Recorded,[object]$Current,[hashtable]$Cache=$null)
    try {
        $a=$Recorded.inventory.external;$b=$Current.inventory.external
        if(-not $Current.PSObject.Properties['rulesSourceRoot']) {return $null}
        $key=$a.rulesCommit+':'+$a.rulesTree+':'+$b.rulesCommit+':'+$b.rulesTree
        if($null -ne $Cache -and $Cache.ContainsKey($key)) {return $Cache[$key]}
        $bridge=Get-AiRulesNativeBridge $Current.rulesSourceRoot $a.rulesCommit $a.rulesTree $b.rulesCommit $b.rulesTree
        if($null -ne $Cache) {$Cache[$key]=$bridge}
        return $bridge
    } catch {return $null}
}

function Get-AiRulesTransitionClients {
    param([object]$Identity)
    $client=$Identity.inventory.external.client|ConvertFrom-Json
    return @($client.targets|ForEach-Object {@($_.configuredClients)}|Sort-Object -Unique)
}

function Get-AiRulesTransitionRequests {
    param([string]$WorkflowRoot,[string]$RulesRoot)
    $cache=Join-Path (Get-RepositoryCommonGitDirectory $WorkflowRoot) 'itl/develop-e2e-qualifications'
    if(-not (Test-Path -LiteralPath $cache -PathType Container)) {return @()}
    $to=(Invoke-RepositoryGit $RulesRoot @('rev-parse','HEAD')).stdout.Trim()
    $tree=(Invoke-RepositoryGit $RulesRoot @('rev-parse','HEAD^{tree}')).stdout.Trim()
    $requests=@{}
    foreach($top in @(Get-ChildItem -LiteralPath $cache -Directory|Where-Object Name -notin @('.references','.native'))) {
        foreach($file in @(Get-ChildItem -LiteralPath $top.FullName -Recurse -File -Filter manifest.json)) {
            try {
                $m=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8|ConvertFrom-Json
                $id=$m.inputIdentity;$ext=$id.inventory.external
                if($m.schemaVersion -ne 2 -or $m.kind -cne 'itl-develop-e2e-qualification-cache' -or
                    (Get-DevelopE2ECanonicalJsonSha256 $id.inventory) -cne $id.fingerprint -or $ext.rulesCommit -ceq $to) {continue}
                $report=Join-Path $file.DirectoryName 'route-report.json'
                if((Get-FileHash -LiteralPath $report -Algorithm SHA256).Hash.ToLowerInvariant() -cne $m.identity.reportSha256) {continue}
                $bridge=Get-AiRulesNativeBridge $RulesRoot $ext.rulesCommit $ext.rulesTree $to $tree
                if(-not $bridge) {continue}
                $clients=@(Get-AiRulesTransitionClients $id)
                if(-not $clients.Count) {continue}
                $key=$ext.rulesCommit
                if(-not $requests.ContainsKey($key)) {$requests[$key]=[pscustomobject]@{bridge=$bridge;clients=@()}}
                $requests[$key].clients=@(@($requests[$key].clients)+$clients|Sort-Object -Unique)
            } catch {continue}
        }
    }
    return @($requests.Values|Sort-Object {$_.bridge.fromCommit})
}

function Invoke-AiRulesTransitionCheck {
    param([string]$RulesRoot,[string]$OldRoot,[string]$ProjectRoot,[string]$CanonicalRoot,[string]$Client,[object]$Bridge)
    [void][IO.Directory]::CreateDirectory($ProjectRoot)
    $user=Join-Path $ProjectRoot 'LLM-RULES.md'
    [IO.File]::WriteAllText($user,'transition-user-owned',[Text.UTF8Encoding]::new($false))
    foreach($step in @(@($OldRoot,'init'),@($RulesRoot,'update'))) {
        $arguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $step[0] 'install.ps1'),$step[1],'-ProjectRoot',$ProjectRoot,'-Source',$step[0],'-McpMode','delegated','-NonInteractive','-AssumeYes')
        if($step[1] -eq 'init') {$arguments+=@('-Tools',$Client)}
        & powershell.exe @arguments | Out-Host
        if($LASTEXITCODE -ne 0) {throw "FORK_TRANSITION_INSTALL_FAILED: $Client $($step[1])"}
        if($step[1] -eq 'init') {
            $baseline=Get-Content (Join-Path $ProjectRoot '.ai-rules.json') -Raw -Encoding UTF8|ConvertFrom-Json
            $control=@($baseline.files.PSObject.Properties|Where-Object {$_.Value.source -like 'content/rules/*.md' -and $_.Value.source -cnotin @($Bridge.guidancePaths)}|Sort-Object Name|Select-Object -First 1)
            if($control.Count -ne 1) {throw 'FORK_TRANSITION_PRESERVATION_CONTROL_MISSING'}
            $controlPath=Join-Path $ProjectRoot $control[0].Name
            [IO.File]::AppendAllText($controlPath,"`nuser-transition-override`n",[Text.UTF8Encoding]::new($false))
            $controlHash=(Get-FileHash -LiteralPath $controlPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    if([IO.File]::ReadAllText($user) -cne 'transition-user-owned') {throw 'FORK_TRANSITION_USER_FILE_CHANGED'}
    $updated=Get-Content (Join-Path $ProjectRoot '.ai-rules.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $canonical=Get-Content (Join-Path $CanonicalRoot '.ai-rules.json') -Raw -Encoding UTF8|ConvertFrom-Json
    if((Get-FileHash -LiteralPath $controlPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $controlHash -or
        -not $updated.files.PSObject.Properties[$control[0].Name].Value.userModified) {throw 'FORK_TRANSITION_MANAGED_USER_FILE_CHANGED'}
    if((@($updated.files.PSObject.Properties.Name|Sort-Object) -join "`0") -cne (@($canonical.files.PSObject.Properties.Name|Sort-Object) -join "`0")) {throw 'FORK_TRANSITION_TARGET_INVENTORY_CHANGED'}
    foreach($source in @($Bridge.guidancePaths)) {
        $entries=@($updated.files.PSObject.Properties|Where-Object {$_.Value.source -ceq $source})
        if(-not $entries.Count) {throw "FORK_TRANSITION_PAYLOAD_MISSING: $source"}
        foreach($entry in $entries) {
            $target=$entry.Name;$expected=$canonical.files.PSObject.Properties[$target]
            $actual=(Get-FileHash -LiteralPath (Join-Path $ProjectRoot $target) -Algorithm SHA256).Hash.ToLowerInvariant()
            $fresh=(Get-FileHash -LiteralPath (Join-Path $CanonicalRoot $target) -Algorithm SHA256).Hash.ToLowerInvariant()
            if(-not $expected -or $entry.Value.source -cne $expected.Value.source -or $actual -cne $fresh -or
                $actual -cne $entry.Value.installedHash -or $fresh -cne $expected.Value.installedHash -or
                ($entry.Value.PSObject.Properties['userModified'] -and $entry.Value.userModified)) {throw "FORK_TRANSITION_PAYLOAD_CHANGED: $target"}
        }
    }
    return [pscustomobject]@{client=$Client;status='passed';checkedGuidanceCount=@($Bridge.guidancePaths).Count;preservedManagedUserFile=$true}
}

function Test-DevelopForkTransitionProof {
    param([object]$StaticProof,[object]$Recorded,[object]$Current,[string]$Commit,[string]$Tree)
    try {
        if(-not (Test-WorkflowCurrentStaticProof $StaticProof $Commit $Tree)) {return $false}
        $q=Get-Content -LiteralPath $StaticProof.path -Raw -Encoding UTF8|ConvertFrom-Json
        $ext=$Current.inventory.external
        if($q.fork.commit -cne $ext.rulesCommit -or $q.fork.tree -cne $ext.rulesTree -or -not $q.fork.PSObject.Properties['transitionProof']) {return $false}
        if(-not @($q.stages|Where-Object {$_.name -ceq 'fork-check' -and $_.status -ceq 'passed'}).Count -or
            $q.fork.qualificationSha256 -cnotmatch '^[a-f0-9]{64}$' -or
            (Get-FileHash -LiteralPath $q.fork.qualificationPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $q.fork.qualificationSha256) {return $false}
        $full=Get-Content -LiteralPath $q.fork.qualificationPath -Raw -Encoding UTF8|ConvertFrom-Json
        if($full.kind -cne 'itl-ai-rules-full-qualification' -or $full.status -cne 'passed' -or $full.reusable -ne $true -or
            $full.repository.worktreeClean -ne $true -or $full.repository.commit -cne $ext.rulesCommit -or $full.repository.tree -cne $ext.rulesTree) {return $false}
        $ref=$q.fork.transitionProof
        if($ref.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $ref.path -cne ('fork-transitions-'+$ref.sha256+'.json')) {return $false}
        $path=Join-Path (Split-Path -Parent $StaticProof.path) $ref.path
        if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ref.sha256) {return $false}
        $p=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
        $policy=Get-DevelopE2EInputFileSha256 (Join-Path $PSScriptRoot 'ai-rules-native-inputs.ps1') 'scripts/ai-rules-native-inputs.ps1'
        if($p.schemaVersion -ne 1 -or $p.kind -cne 'itl-fork-transition-proof' -or $p.status -cne 'passed' -or $p.policySha256 -cne $policy -or $p.commit -cne $ext.rulesCommit -or $p.tree -cne $ext.rulesTree) {return $false}
        $bridge=Get-DevelopForkNativeBridge $Recorded $Current
        if(-not $bridge) {return $false}
        $rows=@($p.transitions|Where-Object {$_.bridge.fromCommit -ceq $bridge.fromCommit -and $_.bridge.fromTree -ceq $bridge.fromTree -and $_.bridge.nativeSha256 -ceq $bridge.nativeSha256 -and $_.bridge.toCommit -ceq $bridge.toCommit -and $_.bridge.toTree -ceq $bridge.toTree})
        if($rows.Count -ne 1 -or (@($rows[0].bridge.guidancePaths) -join "`0") -cne (@($bridge.guidancePaths) -join "`0")) {return $false}
        $clients=@(Get-AiRulesTransitionClients $Current)
        return $clients.Count -gt 0 -and @($clients|Where-Object {$_ -notin @($rows[0].clients|Where-Object {$_.status -ceq 'passed' -and $_.checkedGuidanceCount -eq @($bridge.guidancePaths).Count -and $_.preservedManagedUserFile -eq $true}|ForEach-Object client)}).Count -eq 0
    } catch {return $false}
}
