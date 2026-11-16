param([string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $RepositoryRoot 'scripts/git-path-list.ps1')
$base = 'fa0e3c91694112c1da3ecda7209a8a81ea828264'
$auditRoot = Join-Path $RepositoryRoot 'build/redesign-source-delivery/audit-fa0e3c91'
$files = @(Import-Csv (Join-Path $auditRoot 'test-files.csv'))
$routes = [Collections.Generic.List[object]]::new()
$variants = [Collections.Generic.List[object]]::new()
foreach ($file in $files) {
    $path = Join-Path $RepositoryRoot $file.file
    $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sourceSha256) {
        $blob = Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @('show', ($base + ':' + $file.file))
        if ($blob.exitCode -ne 0) { throw ('Missing baseline blob: ' + $file.file) }
        $text = $blob.stdout
    }
    $route = ''; $routeKind = ''; $runtime = ''; $skip = @()
    switch ($file.family) {
        'pester' {
            $route = 'scripts/invoke-pester-shards.ps1: Full root *.Tests.ps1 discovery; Targeted catalog/direct selection'
            $routeKind = 'automated'
            $runtime = 'Windows PowerShell 5.1 / Pester 5; case-specific children'
            $tokens=$null; $errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
            if (@($errors).Count) { throw ('Baseline parse error: ' + $file.file) }
            foreach ($it in @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'It'},$true))) {
                $elements=@($it.CommandElements)
                $name=@($elements | Select-Object -Skip 1 | Where-Object { $_ -is [Management.Automation.Language.StringConstantExpressionAst] -or $_ -is [Management.Automation.Language.ExpandableStringExpressionAst] } | Select-Object -First 1)[0].Value
                for($i=1;$i -lt $elements.Count;$i++) {
                    $parameter=$elements[$i]
                    if ($parameter -isnot [Management.Automation.Language.CommandParameterAst]) { continue }
                    if ($parameter.ParameterName -notin @('Skip','TestCases','ForEach')) { continue }
                    $value=$parameter.Argument
                    if ($null -eq $value -and $i+1 -lt $elements.Count -and $elements[$i+1] -isnot [Management.Automation.Language.CommandParameterAst]) { $value=$elements[$i+1] }
                    $expression=if($null -ne $value){$value.Extent.Text}else{'switch-present'}
                    if ($parameter.ParameterName -eq 'Skip') { $skip+=('{0}: {1}' -f $it.Extent.StartLineNumber,$expression) }
                    $count=$null; $state='expression-not-expanded'
                    if($parameter.ParameterName -ne 'Skip' -and $null -ne $value) {
                        try { $constant=$value.SafeGetValue(); $count=@($constant).Count; $state='safe-constant-definition-count' } catch {}
                    }
                    $variants.Add([pscustomobject][ordered]@{
                        sourceCommit=$base;file=$file.file;line=$it.Extent.StartLineNumber;name=$name
                        parameter=$parameter.ParameterName;expression=$expression;constantCount=$count;status=$state
                    })
                }
            }
        }
        'python' {
            $runtime = 'Python; component dependencies; original process/HTTP boundaries'
            $skip=@([regex]::Matches($text,'(?m)^\s*@(?:unittest\.)?skip(?:If|Unless)?\([^\r\n]+') | ForEach-Object Value)
            $routeKind='automated'
            if($file.file -like 'tests/python/chatgpt/*'){$route='ChatGptBridge.Tests.ps1: unittest discover -s tests/python/chatgpt'}
            elseif($file.file -like 'tests/python/remote_work/*'){$route='RemotePerformance.Tests.ps1 -> tests/python/remote_work/run-tests.ps1: unittest discover'}
            elseif($file.file -like '*linux-native-host/*'){$route='HostTooling.Tests.ps1: LinuxHost unittest discover'}
            elseif($file.file -match 'mantis-ticket-mcp/test_(protocol|zvec)\.py$'){$route='mantis-ticket-mcp/README.md local commands only; no automated gate route found';$routeKind='manual-only'}
            elseif($file.file -like '*mantis-ticket-mcp/test_extract.py'){$route='No named automated gate or documented local command found';$routeKind='unrouted'}
            else{$route='HostTooling.Tests.ps1: explicit test file invocation'}
        }
        'go' {
            $runtime='Go and named native/Python child fixtures'
            $route='Build-ItlOnDemandMcp.ps1 without SkipTests: go test ./...; release-ondemand-mcp workflow and Release ondemand-mcp capability'
            $routeKind='conditional-automated'
            $skip=@([regex]::Matches($text,'(?m)^//go:build[^\r\n]+|t\.Skip(?:f)?\([^\r\n]+') | ForEach-Object Value)
            foreach($match in [regex]::Matches($text,'t\.Run\([^\r\n]+')){
                $variants.Add([pscustomobject][ordered]@{sourceCommit=$base;file=$file.file;line=(1+[regex]::Matches($text.Substring(0,$match.Index),'\n').Count);name='nested Go subtest';parameter='t.Run';expression=$match.Value;constantCount=$null;status='expression-not-expanded'})
            }
        }
        'node' {
            $runtime='Node.js; loopback HTTP fixtures'
            $route='HostTooling.Tests.ps1: node tests/node/tools-list-proxy.test.js'
            $routeKind='automated'
        }
    }
    if ($file.family -eq 'pester') {
        foreach ($match in [regex]::Matches($text, '(?m)^.*Set-ItResult\s+-Skipped[^\r\n]*')) {
            $line = 1 + ([regex]::Matches($text.Substring(0, $match.Index), "`n")).Count
            $skip += ('{0}: conditional runtime skip: {1}' -f $line, $match.Value.Trim())
        }
    }
    $routes.Add([pscustomobject][ordered]@{
        sourceCommit=$base;family=$file.family;file=$file.file;definitionCount=$file.definitionCount
        route=$route;routeKind=$routeKind;runtime=$runtime;skipExpressions=($skip -join ' | ')
        decision='pending-semantic-review';history='not inferred from absence of failures'
    })
}
$routes | Export-Csv -LiteralPath (Join-Path $auditRoot 'routes-and-skips.csv') -NoTypeInformation -Encoding UTF8
$variants | Export-Csv -LiteralPath (Join-Path $auditRoot 'parameterized-definitions.csv') -NoTypeInformation -Encoding UTF8
[pscustomobject]@{files=$routes.Count;parameterExpressions=$variants.Count;literalParameterizedDefinitions=@($variants | Where-Object status -eq 'safe-constant-definition-count').Count;unexpanded=@($variants | Where-Object status -eq 'expression-not-expanded').Count;nonautomatic=@($routes | Where-Object routeKind -in @('manual-only','unrouted') | Select-Object file,routeKind)} | ConvertTo-Json -Depth 4
