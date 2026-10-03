# Read-only, operation-local MCP evidence. This does not launch a validator or own state.
function Get-ItlPlatformEvidenceValue {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return ,$property.Value
}

function Get-ItlPlatformEvidenceHash {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}

function Resolve-ItlPlatformEvidencePath {
    param([string]$Path, [string]$BaseRoot, [string]$ContainedRoot)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '[\x00-\x1F]' -or
        @($Path.Replace('\', '/').Split('/') | Where-Object { $_ -eq '..' }).Count) { throw 'Unsafe proof path' }
    $full = if ([IO.Path]::IsPathRooted($Path)) { [IO.Path]::GetFullPath($Path) } else { [IO.Path]::GetFullPath((Join-Path $BaseRoot $Path)) }
    $root = [IO.Path]::GetFullPath($ContainedRoot).TrimEnd('\', '/')
    if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Foreign proof path' }
    $cursor = $full
    while ($cursor.Length -ge $root.Length) {
        if (Test-Path -LiteralPath $cursor) {
            if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Indirect proof path' }
        }
        if ($cursor.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { break }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
        if (-not $cursor) { break }
    }
    return $full
}

function Read-ItlPlatformEvidenceJson {
    param([string]$Path, [string]$ExpectedHash = '')
    if (-not [IO.File]::Exists($Path) -or ([IO.FileInfo]$Path).Length -gt 16777216) { throw 'Unusable proof artifact' }
    $before = Get-ItlPlatformEvidenceHash -Path $Path
    if ($ExpectedHash -and ($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$' -or $before -cne $ExpectedHash.ToLowerInvariant())) { throw 'Changed proof artifact' }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $read = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    if ($read -cne $before -or (Get-ItlPlatformEvidenceHash -Path $Path) -cne $before) { throw 'Concurrent proof write' }
    $text = ([Text.UTF8Encoding]::new($false, $true)).GetString($bytes).TrimStart([char]0xFEFF)
    $value = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    if ($null -eq $value -or $value -is [Array] -or $value -is [string] -or $value -is [ValueType]) { throw 'Proof must be an object' }
    return $value
}

function Resolve-ItlPlatformSourceFile {
    param([string]$Path, [string]$SourceRoot, [string]$ProjectRoot)
    if (-not [IO.Path]::IsPathRooted($Path)) {
        $prefix = $SourceRoot.Substring($ProjectRoot.Length).TrimStart('\', '/').Replace('\', '/') + '/'
        if ($Path.Replace('\', '/').StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $Path = $Path.Substring($prefix.Length) }
    }
    return (Resolve-ItlPlatformEvidencePath -Path $Path -BaseRoot $SourceRoot -ContainedRoot $SourceRoot)
}

function Get-ItlPlatformRawResult {
    param([object]$Request, [object]$Response)
    if ($Response.PSObject.Properties['error']) { throw 'MCP error response' }
    if ($Request.PSObject.Properties['method']) {
        if ([string]$Request.method -cne 'tools/call' -or $null -eq $Request.id -or $null -eq $Response.id -or
            [string]$Request.id -cne [string]$Response.id) { throw 'Different MCP response' }
    }
    $result = if ($Response.PSObject.Properties['result']) { $Response.result } else { $Response }
    if ($null -eq $result) { throw 'Missing MCP result' }
    if ($result.PSObject.Properties['isError'] -and ($result.isError -isnot [bool] -or $result.isError)) { throw 'MCP tool failed' }
    return $result
}

function Test-ItlPlatformBslResult {
    param([object]$Result, [object]$Arguments, [object]$Checker, [string]$InputPath, [string]$SourceRoot, [string]$ProjectRoot)
    $data = Get-ItlPlatformEvidenceValue $Result 'structuredContent'
    if ($null -eq $data) { return $false }
    if ($data.PSObject.Properties['status'] -and [string]$data.status -notin @('ok', 'success', 'succeeded', 'passed')) { return $false }
    if ($data.PSObject.Properties['error'] -and $data.error) { return $false }
    $provenance = Get-ItlPlatformEvidenceValue $data 'provenance'
    if ([string](Get-ItlPlatformEvidenceValue $provenance 'tool') -cne 'syntaxcheck_file' -or
        ([string](Get-ItlPlatformEvidenceValue $provenance 'analyzer_version')).Trim() -cne ([string]$Checker.versionOrId).Trim() -or
        [string](Get-ItlPlatformEvidenceValue $provenance 'file_metrics_scope') -cne 'whole_file') { return $false }
    $summary = Get-ItlPlatformEvidenceValue $data 'summary'
    $diagnostics = Get-ItlPlatformEvidenceValue $data 'diagnostics'
    $total = Get-ItlPlatformEvidenceValue $summary 'total'
    $returned = Get-ItlPlatformEvidenceValue $summary 'returned'
    $truncated = Get-ItlPlatformEvidenceValue $summary 'truncated'
    if ($diagnostics -isnot [Array] -or ($total -isnot [int] -and $total -isnot [long]) -or
        ($returned -isnot [int] -and $returned -isnot [long]) -or $total -lt 0 -or $total -ne $returned -or
        $returned -ne $diagnostics.Count -or $truncated -isnot [bool] -or $truncated) { return $false }
    $filters = Get-ItlPlatformEvidenceValue $data 'filters'
    foreach ($name in @('line_filter_applied', 'severity_filter_applied', 'suppression_applied')) {
        $flag = Get-ItlPlatformEvidenceValue $filters $name
        if ($flag -isnot [bool] -or $flag) { return $false }
    }
    if (-not [string]::IsNullOrWhiteSpace([string](Get-ItlPlatformEvidenceValue $Arguments 'lines'))) { return $false }
    $rewrite = Get-ItlPlatformEvidenceValue $data 'request_rewrite'
    $applied = Get-ItlPlatformEvidenceValue $rewrite 'applied'
    if ($applied -isnot [bool] -or $applied) { return $false }
    foreach ($side in @('requested', 'used')) {
        $file = Get-ItlPlatformEvidenceValue (Get-ItlPlatformEvidenceValue $rewrite $side) 'file_path'
        if ([string]::IsNullOrWhiteSpace([string]$file) -or
            (Resolve-ItlPlatformSourceFile -Path $file -SourceRoot $SourceRoot -ProjectRoot $ProjectRoot) -ine $InputPath) { return $false }
    }
    foreach ($diagnostic in $diagnostics) {
        $severity = [string](Get-ItlPlatformEvidenceValue $diagnostic 'severity')
        if ($severity.ToLowerInvariant() -notin @('warning', 'major', 'minor', 'information', 'info', 'hint')) { return $false }
        $file = [string](Get-ItlPlatformEvidenceValue $diagnostic 'file')
        if ($file -and (Resolve-ItlPlatformSourceFile -Path $file -SourceRoot $SourceRoot -ProjectRoot $ProjectRoot) -ine $InputPath) { return $false }
    }
    return $true
}

function Test-ItlPlatformXmlResult {
    param([object]$Result, [object]$Checker)
    $data = Get-ItlPlatformEvidenceValue $Result 'structuredContent'
    if ($null -eq $data) {
        $content = Get-ItlPlatformEvidenceValue $Result 'content'
        if ($content -isnot [Array] -or $content.Count -ne 1 -or [string]$content[0].type -cne 'text') { return $false }
        try { $data = ConvertFrom-Json -InputObject ([string]$content[0].text) -ErrorAction Stop } catch { return $false }
    }
    $errors = Get-ItlPlatformEvidenceValue $data 'errors'
    if ([string](Get-ItlPlatformEvidenceValue $data 'status') -cne 'valid' -or $errors -isnot [Array] -or $errors.Count -ne 0) { return $false }
    # verify_xml does not promise a version field. Bind one only when actually returned.
    foreach ($name in @('checkerVersion', 'checkerId')) {
        $identity = Get-ItlPlatformEvidenceValue $data $name
        if ($identity -and [string]$identity -cne [string]$Checker.versionOrId) { return $false }
    }
    return $true
}

function Test-ItlPlatformSourceCoverage {
    param(
        [Parameter(Mandatory = $true)][string]$EvidencePath,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$SourceFingerprint,
        [Parameter(Mandatory = $true)][string[]]$Files,
        [string]$ProjectRoot = '',
        [string]$InfoBaseKind = '',
        [string]$InfoBasePath = ''
    )
    $required = @(); $covered = @(); $reason = 'EVIDENCE_UNUSABLE'
    try {
        if (-not $ProjectRoot) { $variable = Get-Variable -Name ProjectRoot -Scope Script -ErrorAction SilentlyContinue; if ($variable) { $ProjectRoot = [string]$variable.Value } }
        $ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
        $SourceRoot = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\', '/')
        if (-not [IO.Directory]::Exists($ProjectRoot) -or -not [IO.Directory]::Exists($SourceRoot) -or
            -not $SourceRoot.StartsWith($ProjectRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or -not $SourceFingerprint) { throw 'Invalid target' }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $reason = 'SOURCE_PATH_INVALID'
        foreach ($file in $Files) {
            $input = Resolve-ItlPlatformSourceFile -Path $file -SourceRoot $SourceRoot -ProjectRoot $ProjectRoot
            if ([IO.Path]::GetExtension($input).ToLowerInvariant() -notin @('.bsl', '.xml') -or -not [IO.File]::Exists($input)) { throw 'Unsupported input' }
            $relative = $input.Substring($SourceRoot.Length + 1).Replace('\', '/')
            if ($seen.Add($relative)) { $required += $relative }
        }
        if ($required.Count -eq 0) { throw 'Missing changed inputs' }
        $reason = 'EVIDENCE_UNUSABLE'
        $EvidencePath = Resolve-ItlPlatformEvidencePath -Path $EvidencePath -BaseRoot $ProjectRoot -ContainedRoot $ProjectRoot
        $receiptHash = Get-ItlPlatformEvidenceHash -Path $EvidencePath
        $receipt = Read-ItlPlatformEvidenceJson -Path $EvidencePath -ExpectedHash $receiptHash
        if ($receipt.schemaVersion -isnot [int] -or $receipt.schemaVersion -ne 1 -or [string]$receipt.kind -cne 'itl-mcp-source-validation') { throw 'Unknown proof schema' }
        $reason = 'EVIDENCE_TASK_PATH_UNSUPPORTED'
        if ([string]$receipt.taskPath -cne 'quick-fix') { throw 'Only selected quick-fix proof is eligible' }
        $reason = 'EVIDENCE_TARGET_MISMATCH'
        if ([IO.Path]::GetFullPath([string]$receipt.projectRoot).TrimEnd('\', '/') -ine $ProjectRoot -or
            [IO.Path]::GetFullPath([string]$receipt.sourceRoot).TrimEnd('\', '/') -ine $SourceRoot -or
            [string]$receipt.sourceFingerprint -cne $SourceFingerprint) { throw 'Different source target' }
        if ($InfoBaseKind -and [string](Get-ItlPlatformEvidenceValue $receipt 'infoBaseKind') -ine $InfoBaseKind) { throw 'Different infobase kind' }
        if ($InfoBasePath -and [string](Get-ItlPlatformEvidenceValue $receipt 'infoBasePath') -ine $InfoBasePath) { throw 'Different infobase target' }
        $entries = Get-ItlPlatformEvidenceValue $receipt 'entries'
        if ($entries -isnot [Array]) { throw 'Missing entry array' }
        $entryPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $observed = @(@{ path = $EvidencePath; hash = $receiptHash })
        foreach ($entry in $entries) {
            $reason = 'SOURCE_PATH_INVALID'
            if ([IO.Path]::IsPathRooted([string]$entry.relativePath)) { throw 'Entry must be source relative' }
            $input = Resolve-ItlPlatformEvidencePath -Path ([string]$entry.relativePath) -BaseRoot $SourceRoot -ContainedRoot $SourceRoot
            $relative = $input.Substring($SourceRoot.Length + 1).Replace('\', '/')
            if (-not $entryPaths.Add($relative) -or [IO.Path]::GetExtension($input).ToLowerInvariant() -notin @('.bsl', '.xml')) { throw 'Duplicate or unsupported entry' }
            $reason = 'SOURCE_INPUT_CHANGED'
            if ([string]$entry.inputSha256 -notmatch '^[a-fA-F0-9]{64}$' -or
                (Get-ItlPlatformEvidenceHash -Path $input) -cne ([string]$entry.inputSha256).ToLowerInvariant()) { throw 'Different source bytes' }
            $reason = 'CHECKER_IDENTITY_INVALID'
            $checker = $entry.checker
            $capability = if ([IO.Path]::GetExtension($input) -ieq '.bsl') { 'syntaxcheck_file' } else { 'verify_xml' }
            if ([string]::IsNullOrWhiteSpace([string]$checker.server) -or [string]::IsNullOrWhiteSpace([string]$checker.versionOrId) -or
                [string]$checker.capability -cne $capability) { throw 'Missing actual checker identity' }
            $reason = 'ARTIFACT_UNUSABLE'
            $artifactRoot = [IO.Path]::GetDirectoryName($EvidencePath)
            $requestPath = Resolve-ItlPlatformEvidencePath -Path ([string]$entry.request.path) -BaseRoot $artifactRoot -ContainedRoot $ProjectRoot
            $resultPath = Resolve-ItlPlatformEvidencePath -Path ([string]$entry.result.path) -BaseRoot $artifactRoot -ContainedRoot $ProjectRoot
            if ([string]$entry.request.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or [string]$entry.result.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Missing artifact hashes' }
            $request = Read-ItlPlatformEvidenceJson -Path $requestPath -ExpectedHash $entry.request.sha256
            $response = Read-ItlPlatformEvidenceJson -Path $resultPath -ExpectedHash $entry.result.sha256
            $observed += @{ path = $requestPath; hash = ([string]$entry.request.sha256).ToLowerInvariant() }
            $observed += @{ path = $resultPath; hash = ([string]$entry.result.sha256).ToLowerInvariant() }
            $call = if ($request.PSObject.Properties['method']) { $request.params } else { $request }
            $reason = 'REQUEST_INPUT_MISMATCH'
            if ([string]$call.name -cne $capability -or $null -eq $call.arguments) { throw 'Different requested capability' }
            if ($capability -eq 'syntaxcheck_file') {
                if ((Resolve-ItlPlatformSourceFile -Path ([string]$call.arguments.file_path) -SourceRoot $SourceRoot -ProjectRoot $ProjectRoot) -ine $input) { throw 'Different requested file' }
            } else {
                $text = ([Text.UTF8Encoding]::new($false, $true)).GetString([IO.File]::ReadAllBytes($input)).TrimStart([char]0xFEFF)
                if ([string]::IsNullOrWhiteSpace([string]$call.arguments.object_type) -or [string]$call.arguments.xml_content -cne $text) { throw 'Different requested XML bytes' }
            }
            $reason = 'CHECKER_RESULT_UNUSABLE'
            $result = Get-ItlPlatformRawResult -Request $request -Response $response
            $valid = if ($capability -eq 'syntaxcheck_file') {
                Test-ItlPlatformBslResult -Result $result -Arguments $call.arguments -Checker $checker -InputPath $input -SourceRoot $SourceRoot -ProjectRoot $ProjectRoot
            } else { Test-ItlPlatformXmlResult -Result $result -Checker $checker }
            if (-not $valid) { throw 'Actual checker result does not prove zero errors' }
            if ((Get-ItlPlatformEvidenceHash -Path $input) -cne ([string]$entry.inputSha256).ToLowerInvariant()) { $reason = 'SOURCE_INPUT_CHANGED'; throw 'Source changed during proof read' }
            $observed += @{ path = $input; hash = ([string]$entry.inputSha256).ToLowerInvariant() }
            if ($seen.Contains($relative)) { $covered += $relative }
        }
        $reason = 'COVERAGE_INCOMPLETE'
        if ($covered.Count -ne $required.Count) { throw 'Missing changed file coverage' }
        $reason = 'PROOF_CHANGED_DURING_READ'
        foreach ($record in $observed) { if ((Get-ItlPlatformEvidenceHash -Path $record.path) -cne $record.hash) { throw 'Observed bytes changed' } }
        return [pscustomobject]@{ covered = $true; reason = 'MCP_ZERO_ERRORS_COVERS_CHANGED_FILES'; coveredFiles = @($covered); requiredFiles = @($required) }
    } catch {
        return [pscustomobject]@{ covered = $false; reason = $reason; coveredFiles = @($covered); requiredFiles = @($required) }
    }
}
