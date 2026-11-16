[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$RepositoryRoot)
$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $RepositoryRoot 'tests/pester/HostTooling.Tests.ps1'
$source = [IO.File]::ReadAllText($sourcePath, [Text.Encoding]::UTF8)
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if (@($errors).Count) { throw 'Cannot split invalid HostTooling source.' }
$definitions = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'It'
}, $true))
$groups = [ordered]@{
    HostNativeTransport = @(
        'round trips Python Unicode evidence through the host child-process helper',
        'round-trips a real retained SQLite/vector snapshot and rejects invalid archives before modifying data',
        'executes the shared real HTTP identity and Linux ownership regressions'
    )
    HostLinux = @('checks dedicated Linux watchdog and refresh ownership boundaries')
    HostCodeChecker = @(
        'restores the stable CodeChecker logic tool in the beta image',
        'applies the shared codechecker transport retry contract'
    )
    HostToolsProxy = @('preserves MCP tool contracts while compacting only descriptions')
    HostBookStack = @('bounds BookStack MCP responses and keeps explicit continuation')
    HostMantis = @(
        'keeps the Mantis MCP transport stateless',
        'qualifies Mantis delta, recovery and write journal through UTF-8 native transport'
    )
    HostSppr = @('qualifies SPPR corpus and HTTP tools with the selected isolated Python runtime')
}
$transfers = [Collections.Generic.List[object]]::new()
$selected = [Collections.Generic.List[object]]::new()
$sha = [Security.Cryptography.SHA256]::Create()
try {
    foreach ($group in $groups.GetEnumerator()) {
        $blocks = [Collections.Generic.List[string]]::new()
        foreach ($name in $group.Value) {
            $matches = @($definitions | Where-Object {
                $element = $_.CommandElements[1]
                ($element -is [Management.Automation.Language.StringConstantExpressionAst] -or
                    $element -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and
                    [string]$element.Value -ceq $name
            })
            if ($matches.Count -ne 1) { throw "Expected exactly one original case: $name" }
            $case = $matches[0]
            $inheritedTags = @()
            $block = '    ' + $case.Extent.Text
            if ($name -ceq 'executes the shared real HTTP identity and Linux ownership regressions') {
                # The original enclosing Describe contributes this tag.
                $inheritedTags = @('DirectEndpointRecovery')
                $block = "    Context 'Original endpoint recovery scope' -Tag DirectEndpointRecovery {`n    " + $block + "`n    }"
            }
            $blocks.Add($block)
            $selected.Add($case)
            $digest = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($case.Extent.Text.Replace("`r`n","`n")))).Replace('-','').ToLowerInvariant()
            $transfers.Add([pscustomobject][ordered]@{
                sourceFile='tests/pester/HostTooling.Tests.ps1';sourceLine=$case.Extent.StartLineNumber
                destinationFile=("tests/pester/$($group.Key).Tests.ps1");name=$name
                originalCommandSha256=$digest;inheritedTags=($inheritedTags -join ';')
                transfer='exact-command-with-original-inherited-tags-and-preconditions'
            })
        }
        $header = @'
BeforeAll {
    $env:ITL_UI_TOOLS_AUTO_INSTALL = 'skip'
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $McpHostPath = Join-Path $RepoRoot 'vibecoding1c-mcp-host/install-vibecoding1c-mcp-host.ps1'
}
'@
        $destination = Join-Path $RepositoryRoot "tests/pester/$($group.Key).Tests.ps1"
        if (Test-Path -LiteralPath $destination) { throw "Destination already exists: $destination" }
        $content = $header + "`n`nDescribe '$($group.Key) component regressions' {`n" + ($blocks -join "`n`n") + "`n}`n"
        [IO.File]::WriteAllText($destination, $content, [Text.UTF8Encoding]::new($true))
    }
    foreach ($case in @($selected | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        $start = $case.Extent.StartOffset
        $lineStart = $source.LastIndexOf("`n", $start - 1) + 1
        if ($source.Substring($lineStart, $start - $lineStart) -match '^\s*$') { $start = $lineStart }
        $source = $source.Remove($start, $case.Extent.EndOffset - $start)
    }
    [IO.File]::WriteAllText($sourcePath, $source, [Text.UTF8Encoding]::new($true))
    $outputRoot = Join-Path $RepositoryRoot 'build/redesign-source-delivery'
    [IO.Directory]::CreateDirectory($outputRoot) | Out-Null
    $transfers | Export-Csv -LiteralPath (Join-Path $outputRoot 'host-suite-transfers.csv') -NoTypeInformation -Encoding UTF8
    [pscustomobject]@{originalDefinitions=$definitions.Count;transferred=$transfers.Count;destinations=$groups.Count;remaining=$definitions.Count-$transfers.Count} | ConvertTo-Json -Compress
} finally { $sha.Dispose() }
