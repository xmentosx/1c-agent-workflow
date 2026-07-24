<#
.SYNOPSIS
Returns bounded static context for exact managed-form element names.

.DESCRIPTION
Reads one explicit Form.xml below ProjectRoot without starting 1C. The compact
JSON result contains only selected structural properties; it never returns the
XML document, titles, handlers, or other source contents.

Use Vanessa UI MCP get_form_element_data separately when runtime value,
visibility, or availability is required. This script is intentionally not an
itl-vanessa-ui backend tool: that public facade remains resolve_tool/call_tool
over its verified upstream catalog.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\.agents\skills\1c-workflow\scripts\get-form-element-context.ps1 `
  -ProjectRoot . `
  -SourcePath .\src\cf\DataProcessors\Example\Forms\Form\Ext\Form.xml `
  -ElementName FieldOne,PagesOne

The result has one record per requested name, in request order. A missing or
ambiguous source name is reported with status "missing" or "duplicate".
extendedEditMultipleValues is true/false when explicitly declared and null
when the property is absent or unsupported by the selected element.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string[]]$ElementName
)

$ErrorActionPreference = "Stop"
$script:MaxElementNames = 32
$script:MaxElementNameLength = 256
$script:MaxDataPathLength = 1024
$script:MaxAncestorDepth = 16
$script:MaxXmlCharacters = 32MB
$script:MaxOutputCharacters = 64KB

function Throw-FormElementContextError {
    param([string]$Code, [string]$Message)
    throw "$Code`: $Message"
}

function Get-CanonicalFormElementContextPath {
    param([string]$Path, [string]$BasePath)
    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $BasePath $Path }
    return [System.IO.Path]::GetFullPath($candidate)
}

function Get-DirectChildElementText {
    param([System.Xml.XmlElement]$Element, [string]$LocalName)
    foreach ($child in @($Element.ChildNodes)) {
        if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element -and
            [string]::Equals($child.LocalName, $LocalName, [System.StringComparison]::Ordinal)) {
            $value = [string]$child.InnerText
            return $value.Trim()
        }
    }
    return $null
}

function Test-ManagedFormElement {
    param([System.Xml.XmlElement]$Element)
    return $Element.ParentNode -and
        $Element.ParentNode.NodeType -eq [System.Xml.XmlNodeType]::Element -and
        [string]::Equals($Element.ParentNode.LocalName, "ChildItems", [System.StringComparison]::Ordinal)
}

function Get-FormElementAncestorKind {
    param([string]$ElementType)
    if ([string]::Equals($ElementType, "Pages", [System.StringComparison]::Ordinal)) { return "Pages" }
    if ([string]::Equals($ElementType, "Page", [System.StringComparison]::Ordinal)) { return "Page" }
    if ($ElementType.EndsWith("Group", [System.StringComparison]::Ordinal)) { return "Group" }
    return $null
}

function Get-FormElementAncestors {
    param([System.Xml.XmlElement]$Element)
    $nearestFirst = [System.Collections.Generic.List[object]]::new()
    $current = $Element.ParentNode
    while ($current) {
        if ($current.NodeType -eq [System.Xml.XmlNodeType]::Element -and (Test-ManagedFormElement -Element $current)) {
            $kind = Get-FormElementAncestorKind -ElementType ([string]$current.LocalName)
            if ($kind) {
                $ancestorName = [string]$current.GetAttribute("name")
                if ($ancestorName.Length -gt $script:MaxElementNameLength) {
                    Throw-FormElementContextError -Code "ITL_FORM_CONTEXT_SOURCE_VALUE_TOO_LONG" -Message "An ancestor name exceeds the output limit."
                }
                $nearestFirst.Add([ordered]@{
                    kind = $kind
                    name = $ancestorName
                })
            }
        }
        $current = $current.ParentNode
    }

    $all = @($nearestFirst)
    [array]::Reverse($all)
    $truncated = $all.Count -gt $script:MaxAncestorDepth
    if ($truncated) {
        $all = @($all | Select-Object -Last $script:MaxAncestorDepth)
    }
    return [ordered]@{
        items = @($all)
        truncated = $truncated
    }
}

if (-not $ElementName -or $ElementName.Count -lt 1 -or $ElementName.Count -gt $script:MaxElementNames) {
    Throw-FormElementContextError -Code "ITL_FORM_CONTEXT_NAME_COUNT_INVALID" -Message "Provide between 1 and $($script:MaxElementNames) exact element names."
}

$seenNames = [System.Collections.Generic.List[string]]::new()
foreach ($name in @($ElementName)) {
    if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt $script:MaxElementNameLength) {
        Throw-FormElementContextError -Code "ITL_FORM_CONTEXT_NAME_INVALID" -Message "Each element name must contain 1 to $($script:MaxElementNameLength) characters."
    }
    if (@($seenNames | Where-Object { [string]::Equals($_, $name, [System.StringComparison]::Ordinal) }).Count -gt 0) {
        Throw-FormElementContextError -Code "ITL_FORM_CONTEXT_NAME_DUPLICATE" -Message "Requested element names must be unique."
    }
    $seenNames.Add($name)
}

if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container -ErrorAction SilentlyContinue)) {
    Throw-FormElementContextError -Code "ITL_FORM_CONTEXT_PROJECT_ROOT_INVALID" -Message "ProjectRoot must be an existing directory."
}
$projectRootFull = [System.IO.Path]::GetFullPath((Get-Item -LiteralPath $ProjectRoot -ErrorAction Stop).FullName)
$projectPathRoot = [System.IO.Path]::GetPathRoot($projectRootFull)
if (-not [string]::Equals($projectRootFull, $projectPathRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    $projectRootFull = $projectRootFull.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
}
$sourceFull = Get-CanonicalFormElementContextPath -Path $SourcePath -BasePath $projectRootFull
$comparison = if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}
$rootPrefix = if ($projectRootFull.EndsWith([string][System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::Ordinal)) {
    $projectRootFull
} else {
    $projectRootFull + [System.IO.Path]::DirectorySeparatorChar
}
if (-not $sourceFull.StartsWith($rootPrefix, $comparison)) {
    Throw-FormElementContextError -Code "ITL_FORM_CONTEXT_SOURCE_OUTSIDE_PROJECT" -Message "SourcePath must stay below ProjectRoot."
}
if (-not (Test-Path -LiteralPath $sourceFull -PathType Leaf -ErrorAction SilentlyContinue) -or
    -not [string]::Equals([System.IO.Path]::GetFileName($sourceFull), "Form.xml", [System.StringComparison]::OrdinalIgnoreCase)) {
    Throw-FormElementContextError -Code "ITL_FORM_CONTEXT_SOURCE_INVALID" -Message "SourcePath must identify an existing Form.xml."
}

$settings = [System.Xml.XmlReaderSettings]::new()
$settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
$settings.XmlResolver = $null
$settings.MaxCharactersInDocument = $script:MaxXmlCharacters
$document = [System.Xml.XmlDocument]::new()
$document.XmlResolver = $null
$reader = $null
try {
    $reader = [System.Xml.XmlReader]::Create($sourceFull, $settings)
    $document.Load($reader)
} catch {
    Throw-FormElementContextError -Code "ITL_FORM_CONTEXT_XML_INVALID" -Message "Form.xml could not be parsed within the safe document limits."
} finally {
    if ($reader) { $reader.Dispose() }
}

$formElements = @(
    $document.SelectNodes("//*[local-name()='ChildItems']/*[@name]") |
        Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element }
)
$records = [System.Collections.Generic.List[object]]::new()
foreach ($requestedName in @($ElementName)) {
    $matches = @(
        $formElements |
            Where-Object { [string]::Equals($_.GetAttribute("name"), $requestedName, [System.StringComparison]::Ordinal) }
    )
    if ($matches.Count -ne 1) {
        $records.Add([ordered]@{
            name = $requestedName
            status = $(if ($matches.Count -eq 0) { "missing" } else { "duplicate" })
            matchCount = $matches.Count
            elementType = $null
            dataPath = $null
            extendedEditMultipleValues = $null
            ancestors = @()
            ancestorsTruncated = $false
        })
        continue
    }

    [System.Xml.XmlElement]$element = $matches[0]
    $dataPath = Get-DirectChildElementText -Element $element -LocalName "DataPath"
    if ($null -ne $dataPath -and $dataPath.Length -gt $script:MaxDataPathLength) {
        Throw-FormElementContextError -Code "ITL_FORM_CONTEXT_SOURCE_VALUE_TOO_LONG" -Message "A DataPath exceeds the output limit."
    }
    $multipleText = Get-DirectChildElementText -Element $element -LocalName "ExtendedEditMultipleValues"
    $multiple = $null
    if ([string]::Equals($multipleText, "true", [System.StringComparison]::OrdinalIgnoreCase)) {
        $multiple = $true
    } elseif ([string]::Equals($multipleText, "false", [System.StringComparison]::OrdinalIgnoreCase)) {
        $multiple = $false
    }
    $ancestorResult = Get-FormElementAncestors -Element $element
    $records.Add([ordered]@{
        name = $requestedName
        status = "found"
        matchCount = 1
        elementType = [string]$element.LocalName
        dataPath = $dataPath
        extendedEditMultipleValues = $multiple
        ancestors = @($ancestorResult.items)
        ancestorsTruncated = [bool]$ancestorResult.truncated
    })
}

$relativeSourcePath = $sourceFull.Substring($rootPrefix.Length).Replace('\', '/')
$outputJson = [ordered]@{
    schemaVersion = 1
    sourcePath = $relativeSourcePath
    records = @($records)
} | ConvertTo-Json -Depth 8 -Compress
if ($outputJson.Length -gt $script:MaxOutputCharacters) {
    Throw-FormElementContextError -Code "ITL_FORM_CONTEXT_OUTPUT_LIMIT" -Message "Selected context exceeds the compact output limit; request fewer element names."
}
$outputJson
