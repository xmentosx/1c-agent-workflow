[CmdletBinding()]
param(
    [string]$RepositoryRoot, [string]$IndexPath, [string]$SerializationPath,
    [ValidatePattern('^[a-f0-9]{40}$')][string]$BaselineCommit = 'fa0e3c91694112c1da3ecda7209a8a81ea828264'
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $RepositoryRoot 'scripts/git-path-list.ps1')
# This incident probe intentionally evaluates the historical hash owner, not
# the repaired current reader. Freeze its Git identity so later changes cannot
# silently change the meaning of the original escaping comparison.
$source = Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @('show', ($BaselineCommit + ':scripts/source-delivery-process.ps1'))
if ($source.exitCode -ne 0) { throw 'Cannot read the named baseline hash owner.' }
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source.stdout, [ref]$tokens, [ref]$errors)
$owner = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-DeliveryRunHotIndexContentSha256'
}, $true))
if (@($errors).Count -or $owner.Count -ne 1) { throw 'Historical hash owner is not unambiguous.' }
. ([scriptblock]::Create($owner[0].Extent.Text))
$raw = [IO.File]::ReadAllText($IndexPath, [Text.Encoding]::UTF8)
$reader = @{ InputObject = $raw }
$hasDateKind = (Get-Command Microsoft.PowerShell.Utility\ConvertFrom-Json).Parameters.ContainsKey('DateKind')
if ($hasDateKind) { $reader.DateKind = 'String' }
$index = Microsoft.PowerShell.Utility\ConvertFrom-Json @reader
$hasEscapeHandling = (Get-Command Microsoft.PowerShell.Utility\ConvertTo-Json).Parameters.ContainsKey('EscapeHandling')
$script:UseHtmlEscaping = $false
$script:LastOwnerJson = ''
function ConvertTo-Json {
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [int]$Depth, [switch]$Compress)
    process {
        $arguments = @{ InputObject = $InputObject; Depth = $Depth; Compress = $Compress }
        if ($script:UseHtmlEscaping) { $arguments.EscapeHandling = 'EscapeHtml' }
        $script:LastOwnerJson = Microsoft.PowerShell.Utility\ConvertTo-Json @arguments
        return $script:LastOwnerJson
    }
}
$defaultHash = Get-DeliveryRunHotIndexContentSha256 -Index $index
if ($SerializationPath) { [IO.File]::WriteAllText($SerializationPath, $script:LastOwnerJson, [Text.UTF8Encoding]::new($false)) }
$htmlHash = ''
if ($hasEscapeHandling) {
    $script:UseHtmlEscaping = $true
    $htmlHash = Get-DeliveryRunHotIndexContentSha256 -Index $index
    if ($SerializationPath) { [IO.File]::WriteAllText(($SerializationPath + '.escape-html.json'), $script:LastOwnerJson, [Text.UTF8Encoding]::new($false)) }
}
Remove-Item -LiteralPath Function:\ConvertTo-Json
[pscustomobject][ordered]@{
    runtime = $PSVersionTable.PSVersion.ToString()
    sourceCommit = $BaselineCommit
    dateKindString = $hasDateKind
    updatedAtType = $index.updatedAt.GetType().FullName
    storedSha256 = [string]$index.contentSha256
    defaultSerializerSha256 = $defaultHash
    defaultMatches = $defaultHash -ceq [string]$index.contentSha256
    escapeHtmlSha256 = $htmlHash
    escapeHtmlMatches = $htmlHash -ceq [string]$index.contentSha256
} | Microsoft.PowerShell.Utility\ConvertTo-Json -Compress
