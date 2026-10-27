# Immutable producer receipts feed the existing artifact-retention owner.
# Directory age, task/chat inactivity and naming never establish disposability.
function Resolve-ItlDiagnosticArtifactPath {
    param([string]$ProjectRoot, [string]$RelativePath, [string]$Kind = '')
    if (-not $RelativePath -or [IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains(':')) { throw 'Diagnostic path must be project-relative.' }
    $full = [IO.Path]::GetFullPath((Join-Path $ProjectRoot $RelativePath))
    if (-not (Test-ItlArtifactPathInside -Root $ProjectRoot -Path $full) -or
        -not (Test-ItlArtifactPathWithoutReparse -Root $ProjectRoot -Path $full)) { throw "Diagnostic path is missing, linked, or outside the project: $full" }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'Diagnostic entries must be individual files.' }
    if ($Kind) {
        if (-not (Test-ItlArtifactPathInside -Root (Join-Path $ProjectRoot 'build') -Path $full)) { throw 'Disposable diagnostics must be below build.' }
        $leaf = Split-Path -Leaf $full
        switch ($Kind) {
            'native-temp' {
                if ($leaf -notmatch '^v8_[a-fA-F0-9]+_[a-fA-F0-9]+\.tmp$' -or (Split-Path -Leaf (Split-Path -Parent $full)) -notlike '*-temp') { throw 'Unrecognized native temporary file.' }
            }
            'derived-trace' {
                if ([IO.Path]::GetExtension($leaf) -notin @('.xml', '.etlx')) { throw 'Only derived XML/ETLX traces are disposable.' }
            }
            'superseded-attempt' {
                if ([IO.Path]::GetExtension($leaf) -notin @('.json', '.jsonl', '.bsl', '.xml', '.txt', '.log', '.md', '.csv', '.bytes') -or
                    $RelativePath -match '(^|[\\/])source-snapshots([\\/]|$)') { throw 'Only superseded check artifacts are disposable; retain source snapshots, databases, traces and executable helpers.' }
            }
            'agent-task-temp' {
                if (-not (Test-ItlArtifactPathInside -Root (Join-Path $ProjectRoot 'build/agent-artifacts') -Path $full)) { throw 'Agent task files must stay below build/agent-artifacts.' }
                if ([IO.Path]::GetExtension($leaf) -in @('.1cd', '.dt', '.etl', '.db', '.sqlite', '.sqlite3', '.mdf', '.ndf', '.ldf') -or
                    $leaf -match '\.(?:db|sqlite|sqlite3)-(?:wal|shm|journal)$' -or
                    $RelativePath -match '(^|[\\/])(?:source-snapshots|handoffs)([\\/]|$)') { throw "Retain databases, DT backups, original traces, source snapshots and handoffs: $RelativePath" }
            }
            default { throw 'Unknown diagnostic artifact kind.' }
        }
    }
    return $full
}

function Get-ItlAgentTaskArtifactContext {
    param([string]$ProjectRoot, [object]$Receipt, [string]$CompletionPath)
    $relative = [string]$Receipt.taskRoot
    if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative.Contains(':')) { throw 'A project-relative agent taskRoot is required.' }
    $artifactHome = [IO.Path]::GetFullPath((Join-Path $ProjectRoot 'build/agent-artifacts'))
    $root = [IO.Path]::GetFullPath((Join-Path $ProjectRoot $relative)).TrimEnd('\', '/')
    if (-not [string]::Equals((Split-Path -Parent $root), $artifactHome, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $root -PathType Container) -or
        -not (Test-ItlArtifactPathWithoutReparse -Root $ProjectRoot -Path $root)) { throw 'Agent taskRoot must be one unlinked task directory below build/agent-artifacts.' }
    $temporary = Join-Path $root 'tmp'
    if ((Test-Path -LiteralPath $temporary) -and (-not (Test-Path -LiteralPath $temporary -PathType Container) -or
        -not (Test-ItlArtifactPathWithoutReparse -Root $ProjectRoot -Path $temporary))) { throw 'Agent task tmp directory is linked or invalid.' }
    $completion = Resolve-ItlDiagnosticArtifactPath -ProjectRoot $ProjectRoot -RelativePath $CompletionPath
    if (-not (Test-ItlArtifactPathInside -Root $root -Path $completion) -or
        (Test-ItlArtifactPathInside -Root $temporary -Path $completion)) { throw 'Agent completion receipt must stay in its task directory outside tmp.' }
    return [pscustomobject]@{ root = $root; temporary = $temporary }
}

function Assert-ItlAgentTaskDisposablePath {
    param([string]$ProjectRoot, [object]$Context, [string]$RelativePath)
    if (-not $RelativePath -or [IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains(':')) { throw 'Agent disposable path must be project-relative.' }
    $path = [IO.Path]::GetFullPath((Join-Path $ProjectRoot $RelativePath))
    if (-not (Test-ItlArtifactPathInside -Root $Context.temporary -Path $path)) { throw "Agent disposable file must stay inside its own task tmp directory: $RelativePath" }
    return $path
}

function Get-ItlSupersededAttemptContext {
    param([string]$ProjectRoot, [object]$Receipt)
    $relative = [string]$Receipt.attemptRoot
    if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative.Contains(':')) { throw 'A project-relative attemptRoot is required.' }
    $root = [IO.Path]::GetFullPath((Join-Path $ProjectRoot $relative))
    if (-not (Test-ItlArtifactPathInside -Root (Join-Path $ProjectRoot 'build') -Path $root) -or
        -not (Test-ItlArtifactPathWithoutReparse -Root $ProjectRoot -Path $root) -or
        -not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Attempt root must be an existing unlinked directory below build.' }
    $successor = Resolve-ItlDiagnosticArtifactPath -ProjectRoot $ProjectRoot -RelativePath ([string]$Receipt.supersededBy)
    if (Test-ItlArtifactPathInside -Root $root -Path $successor) { throw 'Successor evidence must be outside the disposable attempt.' }
    if ((Get-Item -LiteralPath $successor).Length -gt 1048576) { throw 'Successor receipt exceeds 1 MiB.' }
    $proof = [IO.File]::ReadAllText($successor, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    if ($proof.status -notin @('passed', 'succeeded', 'completed')) { throw 'A successfully completed successor receipt is required.' }
    # Producers explicitly declare the transitive evidence/input dependencies.
    # Numbered directories and a newer timestamp never establish supersession.
    return [pscustomobject]@{ root = $root; successor = [string]$Receipt.supersededBy }
}

function Get-ItlDiagnosticFileRecord {
    param([string]$ProjectRoot, [string]$RelativePath, [string]$Kind = '')
    $full = Resolve-ItlDiagnosticArtifactPath -ProjectRoot $ProjectRoot -RelativePath $RelativePath -Kind $Kind
    $file = Get-Item -LiteralPath $full -Force
    return [pscustomobject]@{ path = $RelativePath; length = $file.Length; modifiedUtc = $file.LastWriteTimeUtc.ToString('o'); sha256 = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash }
}

function Register-ItlDiagnosticArtifacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Producer,
        [Parameter(Mandatory)][string]$TerminalReceipt,
        [Parameter(Mandatory)][ValidateSet('native-temp', 'derived-trace', 'superseded-attempt', 'agent-task-temp')][string]$Kind,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$DisposablePath, [string[]]$RetainedPath = @())
    if (-not $Producer.Trim() -or ($DisposablePath.Count -lt 1 -and $Kind -ne 'agent-task-temp') -or $DisposablePath.Count -gt 256) { throw 'Diagnostic producer and 1..256 disposable files are required; an agent task may retain evidence without disposable files.' }
    $ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
    $receiptPath = Resolve-ItlDiagnosticArtifactPath -ProjectRoot $ProjectRoot -RelativePath $TerminalReceipt
    $receipt = [IO.File]::ReadAllText($receiptPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($receipt.status -notin @('passed', 'succeeded', 'failed', 'cancelled', 'completed') -or $receipt.cleanupConfirmed -ne $true) { throw 'A terminal receipt with cleanupConfirmed=true is required.' }
    $attempt = if ($Kind -eq 'superseded-attempt') { Get-ItlSupersededAttemptContext -ProjectRoot $ProjectRoot -Receipt $receipt } else { $null }
    $task = if ($Kind -eq 'agent-task-temp') { Get-ItlAgentTaskArtifactContext -ProjectRoot $ProjectRoot -Receipt $receipt -CompletionPath $TerminalReceipt } else { $null }
    $retainedPaths = @($TerminalReceipt) + $RetainedPath
    if ($null -ne $attempt) { $retainedPaths += $attempt.successor }
    $root = Join-Path $ProjectRoot '.agent-1c/diagnostic-artifacts'
    $path = ''
    $completionHash = ''
    if ($null -ne $task) {
        # A repeated completion reuses its immutable batch even after deletion.
        # Identity includes the receipt bytes and exact canonical batch/dependencies.
        $disposableKeys = @($DisposablePath | ForEach-Object { (Assert-ItlAgentTaskDisposablePath -ProjectRoot $ProjectRoot -Context $task -RelativePath $_).ToUpperInvariant() } | Sort-Object -Unique)
        $retainedKeys = @($retainedPaths | ForEach-Object { (Resolve-ItlDiagnosticArtifactPath -ProjectRoot $ProjectRoot -RelativePath $_).ToUpperInvariant() } | Sort-Object -Unique)
        if (@($disposableKeys | Where-Object { $_ -in $retainedKeys }).Count) { throw 'A retained original cannot also be disposable.' }
        $completionHash = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash
        $identity = [ordered]@{ root = $ProjectRoot.ToUpperInvariant(); producer = $Producer; receipt = $receiptPath.ToUpperInvariant(); hash = $completionHash; files = $disposableKeys; retained = $retainedKeys }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $id = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($identity | ConvertTo-Json -Compress -Depth 4))))).Replace('-', '').ToLowerInvariant().Substring(0, 32) } finally { $sha.Dispose() }
        $path = Join-Path $root ($id + '.json')
        if (Test-Path -LiteralPath $path) {
            if (-not (Test-ItlArtifactPathWithoutReparse -Root $ProjectRoot -Path $path) -or (Get-Item -LiteralPath $path).Length -gt 262144) { throw 'Saved agent task manifest is linked or oversized.' }
            $saved = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $savedFiles = @($saved.files | ForEach-Object { ([IO.Path]::GetFullPath((Join-Path $ProjectRoot $_.path))).ToUpperInvariant() } | Sort-Object -Unique)
            $savedRetained = @($saved.retained | ForEach-Object { ([IO.Path]::GetFullPath((Join-Path $ProjectRoot $_.path))).ToUpperInvariant() } | Sort-Object -Unique)
            if ($saved.schemaVersion -ne 1 -or $saved.projectRoot -ine $ProjectRoot -or $saved.kind -ne $Kind -or $saved.status -ne 'completed' -or
                $saved.cleanupConfirmed -ne $true -or $saved.completionSha256 -ine $completionHash -or $saved.taskRoot -cne $receipt.taskRoot -or
                ($savedFiles -join "`n") -cne ($disposableKeys -join "`n") -or ($savedRetained -join "`n") -cne ($retainedKeys -join "`n")) { throw 'Saved agent task manifest does not match its immutable completion.' }
            return $path
        }
    }
    $retained = @($retainedPaths | Select-Object -Unique | ForEach-Object { Get-ItlDiagnosticFileRecord -ProjectRoot $ProjectRoot -RelativePath $_ })
    if ($Kind -eq 'derived-trace' -and @($retained | Where-Object { [IO.Path]::GetExtension($_.path) -eq '.etl' }).Count -eq 0) { throw 'Derived traces require a retained original ETL.' }
    $files = @($DisposablePath | Select-Object -Unique | ForEach-Object {
        $target = Resolve-ItlDiagnosticArtifactPath -ProjectRoot $ProjectRoot -RelativePath $_ -Kind $Kind
        if ($null -ne $task) { Assert-ItlAgentTaskDisposablePath -ProjectRoot $ProjectRoot -Context $task -RelativePath $_ | Out-Null }
        if ($null -ne $attempt -and -not (Test-ItlArtifactPathInside -Root $attempt.root -Path $target)) { throw 'Disposable file is outside its completed attempt.' }
        foreach ($source in $retained) {
            if ($target -ieq (Resolve-ItlDiagnosticArtifactPath -ProjectRoot $ProjectRoot -RelativePath $source.path)) { throw 'A retained original cannot also be disposable.' }
        }
        Get-ItlDiagnosticFileRecord -ProjectRoot $ProjectRoot -RelativePath $_ -Kind $Kind
    })
    if (-not (Test-ItlArtifactPathWithoutReparse -Root $ProjectRoot -Path (Split-Path -Parent $root))) { throw 'Unsafe diagnostic manifest parent.' }
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root | Out-Null }
    if (-not (Test-ItlArtifactPathWithoutReparse -Root $ProjectRoot -Path $root)) { throw 'Unsafe diagnostic manifest root.' }
    $manifest = [ordered]@{ schemaVersion = 1; projectRoot = $ProjectRoot; producer = $Producer; status = 'completed'; cleanupConfirmed = $true; completedUtc = [datetime]::UtcNow.ToString('o'); kind = $Kind; retained = $retained; files = $files }
    if ($null -ne $attempt) { $manifest.attemptRoot = [string]$receipt.attemptRoot; $manifest.supersededBy = $attempt.successor }
    if ($null -ne $task) { $manifest.taskRoot = [string]$receipt.taskRoot; $manifest.completionPath = $TerminalReceipt; $manifest.completionSha256 = $completionHash }
    if (-not $path) { $path = Join-Path $root (([guid]::NewGuid().ToString('N')) + '.json') }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($manifest | ConvertTo-Json -Depth 8))
    if ($null -ne $task -and $bytes.Length -gt 262144) { throw 'Agent task manifest exceeds 256 KiB; split the task evidence into bounded completion receipts.' }
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    return $path
}

function Complete-ItlDiagnosticArtifacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$CompletionPath)
    $path = Resolve-ItlDiagnosticArtifactPath -ProjectRoot $ProjectRoot -RelativePath $CompletionPath
    if ((Get-Item -LiteralPath $path).Length -gt 1048576) { throw 'Diagnostic completion receipt exceeds 1 MiB.' }
    $receipt = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($receipt.cleanupConfirmed -ne $true -or $receipt.status -notin @('completed', 'succeeded', 'passed', 'failed', 'cancelled')) { throw 'Terminal owned-process cleanup must finish before retention.' }
    $files = @($receipt.disposablePaths)
    if ($files.Count -gt 4096) { throw 'Diagnostic completion exceeds 4096 individual files.' }
    if ($receipt.kind -eq 'agent-task-temp') {
        $task = Get-ItlAgentTaskArtifactContext -ProjectRoot $ProjectRoot -Receipt $receipt -CompletionPath $CompletionPath
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $retained = @(@($CompletionPath) + @($receipt.retainedPaths) | ForEach-Object { Resolve-ItlDiagnosticArtifactPath -ProjectRoot $ProjectRoot -RelativePath $_ })
        foreach ($relative in $files) {
            $target = Assert-ItlAgentTaskDisposablePath -ProjectRoot $ProjectRoot -Context $task -RelativePath $relative
            if (-not $seen.Add($target) -or $target -in $retained) { throw 'Agent task files must be unique and cannot also be retained originals.' }
        }
        if ($files.Count -eq 0) {
            Register-ItlDiagnosticArtifacts -ProjectRoot $ProjectRoot -Producer $receipt.producer -TerminalReceipt $CompletionPath -Kind $receipt.kind -DisposablePath @() -RetainedPath @($receipt.retainedPaths)
            return
        }
    }
    for ($offset = 0; $offset -lt $files.Count; $offset += 256) {
        $batch = @($files[$offset..([Math]::Min($offset + 255, $files.Count - 1))])
        Register-ItlDiagnosticArtifacts -ProjectRoot $ProjectRoot -Producer $receipt.producer -TerminalReceipt $CompletionPath -Kind $receipt.kind -DisposablePath $batch -RetainedPath @($receipt.retainedPaths)
    }
}

function Get-ItlDiagnosticArtifactPlan {
    param([string]$ProjectRoot, [ValidateRange(0, 3650)][int]$MinimumAgeDays = 7, [object]$ProtectedPaths = @())
    $ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
    $root = Join-Path $ProjectRoot '.agent-1c/diagnostic-artifacts'
    if (-not (Test-Path -LiteralPath $root -PathType Container) -or -not (Test-ItlArtifactPathWithoutReparse -Root $ProjectRoot -Path $root)) { return @() }
    $ProtectedPaths = @($ProtectedPaths) + @(Get-ItlDiagnosticRetainedPaths -ProjectRoot $ProjectRoot)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Filter '*.json')) {
        try {
            if ($file.BaseName -notmatch '^[a-f0-9]{32}$' -or $file.Length -gt 262144 -or
                -not (Test-ItlArtifactPathWithoutReparse -Root $root -Path $file.FullName)) { continue }
            $manifest = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($manifest.schemaVersion -ne 1 -or $manifest.projectRoot -ine $ProjectRoot -or $manifest.status -ne 'completed' -or $manifest.cleanupConfirmed -ne $true -or
                $manifest.kind -notin @('native-temp', 'derived-trace', 'superseded-attempt', 'agent-task-temp') -or @($manifest.files).Count -gt 256 -or @($manifest.retained).Count -lt 1) { continue }
            $attempt = if ($manifest.kind -eq 'superseded-attempt') { Get-ItlSupersededAttemptContext -ProjectRoot $ProjectRoot -Receipt $manifest } else { $null }
            $task = if ($manifest.kind -eq 'agent-task-temp') { Get-ItlAgentTaskArtifactContext -ProjectRoot $ProjectRoot -Receipt $manifest -CompletionPath $manifest.completionPath } else { $null }
            $completed = ([datetime]$manifest.completedUtc).ToUniversalTime()
            $age = if ($null -ne $task) { 0 } else { $MinimumAgeDays }
            if ($completed -gt [datetime]::UtcNow.AddDays(-$age)) { continue }
            $manifestHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            foreach ($item in @($manifest.files)) {
                $absolute = [IO.Path]::GetFullPath((Join-Path $ProjectRoot ([string]$item.path)))
                if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) { continue }
                $path = Resolve-ItlDiagnosticArtifactPath -ProjectRoot $ProjectRoot -RelativePath $item.path -Kind $manifest.kind
                if ($null -ne $task) { Assert-ItlAgentTaskDisposablePath -ProjectRoot $ProjectRoot -Context $task -RelativePath $item.path | Out-Null }
                if ($null -ne $attempt -and -not (Test-ItlArtifactPathInside -Root $attempt.root -Path $path)) { continue }
                if (Test-ItlArtifactProtected -Path $path -ProtectedPaths $ProtectedPaths) { continue }
                $current = Get-Item -LiteralPath $path -Force
                if ($current.Length -ne $item.length -or $current.LastWriteTimeUtc.Ticks -ne ([datetime]$item.modifiedUtc).ToUniversalTime().Ticks -or $item.sha256 -notmatch '^[a-fA-F0-9]{64}$') { continue }
                if (-not $seen.Add($path)) { continue }
                [pscustomobject]@{ category = 'diagnostic'; group = $manifest.producer; root = $ProjectRoot; path = $path; companion = ''; expectedSha256 = $item.sha256; modifiedAt = $current.LastWriteTimeUtc; sizeBytes = $current.Length; delete = $true; reason = 'completed-disposable'; diagnosticManifest = $file.FullName; diagnosticManifestSha256 = $manifestHash; diagnosticRecord = $item; retained = @($manifest.retained) }
            }
        } catch { Write-Warning "ITL diagnostic manifest retained: $($file.FullName): $($_.Exception.Message)" }
    }
}

function Get-ItlDiagnosticRetainedPaths {
    param([string]$ProjectRoot)
    $root = Join-Path $ProjectRoot '.agent-1c/diagnostic-artifacts'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Filter '*.json')) {
        if ($file.BaseName -notmatch '^[a-f0-9]{32}$') { continue }
        if ($file.Length -gt 262144 -or -not (Test-ItlArtifactPathWithoutReparse -Root $ProjectRoot -Path $file.FullName)) { throw 'Diagnostic dependency manifest is oversized or linked; retain diagnostics.' }
        try { $manifest = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop }
        catch { throw 'Diagnostic dependency manifest is unreadable; retain diagnostics.' }
        if ($manifest.schemaVersion -ne 1 -or $manifest.projectRoot -ine $ProjectRoot) { continue }
        foreach ($source in @($manifest.retained)) {
            $relative = [string]$source.path
            if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative.Contains(':')) { throw 'Unsafe diagnostic dependency path; retain diagnostics.' }
            $full = [IO.Path]::GetFullPath((Join-Path $ProjectRoot $relative))
            if (-not (Test-ItlArtifactPathInside -Root $ProjectRoot -Path $full)) { throw 'Diagnostic dependency escaped the project; retain diagnostics.' }
            $full
        }
    }
}

function Remove-ItlDiagnosticArtifact {
    param([Parameter(Mandatory)][object]$Entry)
    if (-not (Test-ItlArtifactPathWithoutReparse -Root $Entry.root -Path $Entry.diagnosticManifest) -or
        (Get-FileHash -LiteralPath $Entry.diagnosticManifest -Algorithm SHA256).Hash -ine $Entry.diagnosticManifestSha256) { throw 'Diagnostic manifest changed.' }
    $manifest = [IO.File]::ReadAllText($Entry.diagnosticManifest, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $record = @($manifest.files | Where-Object { $_.path -ceq $Entry.diagnosticRecord.path -and $_.sha256 -ieq $Entry.expectedSha256 })
    if ($manifest.projectRoot -ine $Entry.root -or $record.Count -ne 1 -or $manifest.cleanupConfirmed -ne $true -or $manifest.status -ne 'completed') { throw 'Saved diagnostic preview is not bound to its manifest.' }
    $path = Resolve-ItlDiagnosticArtifactPath -ProjectRoot $Entry.root -RelativePath $record[0].path -Kind $manifest.kind
    if ($manifest.kind -eq 'superseded-attempt') {
        $attempt = Get-ItlSupersededAttemptContext -ProjectRoot $Entry.root -Receipt $manifest
        if (-not (Test-ItlArtifactPathInside -Root $attempt.root -Path $path)) { throw 'Disposable file is outside its completed attempt.' }
    }
    if ($manifest.kind -eq 'agent-task-temp') {
        $task = Get-ItlAgentTaskArtifactContext -ProjectRoot $Entry.root -Receipt $manifest -CompletionPath $manifest.completionPath
        Assert-ItlAgentTaskDisposablePath -ProjectRoot $Entry.root -Context $task -RelativePath $record[0].path | Out-Null
        if (Test-ItlArtifactProtected -Path $path -ProtectedPaths @(Get-ItlArtifactProtectedPaths -ProjectRoot $Entry.root)) { throw 'Agent task target is current workflow evidence or recovery data.' }
    }
    if ($path -ine $Entry.path) { throw 'Diagnostic target differs from its manifest.' }
    if (Test-ItlArtifactProtected -Path $path -ProtectedPaths @(Get-ItlDiagnosticRetainedPaths -ProjectRoot $Entry.root)) { throw 'Diagnostic target is a retained dependency.' }
    foreach ($source in @($manifest.retained)) {
        $original = Resolve-ItlDiagnosticArtifactPath -ProjectRoot $Entry.root -RelativePath $source.path
        if ($original -ieq $path) { throw 'Diagnostic target is also retained.' }
        if ((Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash -ine $source.sha256) { throw 'Retained diagnostic original changed or is missing.' }
    }
    if (-not ('ItlDiagnosticFileDeletion' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.ComponentModel;
using System.Text;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;
public static class ItlDiagnosticFileDeletion {
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateFileW(string p,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileTime(SafeFileHandle h,out long creation,out long access,out long write);
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint GetFinalPathNameByHandleW(SafeFileHandle h,StringBuilder path,uint size,uint flags);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetFileInformationByHandle(SafeFileHandle h,int infoClass,ref int info,uint size);
 public static void Delete(string path,long length,long modifiedTicks,string hash) {
  // Request DELETE access up front, deny all sharing, and do not follow a final
  // reparse point. Mark the SAME verified handle for deletion before closing it.
  using(var h=CreateFileW("\\\\?\\"+path,0x80010000,0,IntPtr.Zero,3,0x00200000,IntPtr.Zero)) {
   if(h.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error());
   var finalPath=new StringBuilder(32768);uint count=GetFinalPathNameByHandleW(h,finalPath,(uint)finalPath.Capacity,0);
   if(count==0 || count>=finalPath.Capacity)throw new Win32Exception(Marshal.GetLastWin32Error());
   if(!string.Equals(finalPath.ToString(),"\\\\?\\"+path,StringComparison.OrdinalIgnoreCase))throw new IOException("Diagnostic path changed after preview.");
   using(var stream=new FileStream(h,FileAccess.Read)) {
    long c,a,w;if(!GetFileTime(h,out c,out a,out w))throw new Win32Exception(Marshal.GetLastWin32Error());
    if(stream.Length!=length || DateTime.FromFileTimeUtc(w).Ticks!=modifiedTicks)throw new IOException("Diagnostic file changed after preview.");
    string actual;using(var sha=SHA256.Create())actual=BitConverter.ToString(sha.ComputeHash(stream)).Replace("-","");
    if(!string.Equals(actual,hash,StringComparison.OrdinalIgnoreCase))throw new IOException("Diagnostic file hash changed after preview.");
    int remove=1;if(!SetFileInformationByHandle(h,4,ref remove,4))throw new Win32Exception(Marshal.GetLastWin32Error());
   }
  }
 }
}
'@
    }
    [ItlDiagnosticFileDeletion]::Delete($path, [long]$record[0].length, ([datetime]$record[0].modifiedUtc).ToUniversalTime().Ticks, [string]$record[0].sha256)
}

function Invoke-ItlDiagnosticArtifactCleanup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot, [ValidateRange(0, 3650)][int]$MinimumAgeDays = 7, [switch]$DryRun, [object]$ProtectedPaths = @())
    $plan = @(Get-ItlDiagnosticArtifactPlan -ProjectRoot $ProjectRoot -MinimumAgeDays $MinimumAgeDays -ProtectedPaths $ProtectedPaths)
    $removed = [long]0; $failed = @()
    foreach ($entry in $plan) {
        if ($DryRun) { continue }
        try { Remove-ItlDiagnosticArtifact -Entry $entry; $removed += $entry.sizeBytes }
        catch { $failed += [pscustomobject]@{ path = $entry.path; error = $_.Exception.Message } }
    }
    return [pscustomobject]@{ entries = $plan; removedBytes = $removed; failed = $failed; dryRun = [bool]$DryRun }
}
