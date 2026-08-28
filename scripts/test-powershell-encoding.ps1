[CmdletBinding()]
param(
    [string]$RepositoryRoot = "",
    [string]$BaseRef = "",
    [string]$OutputPath = "",
    [switch]$ReportOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if (-not $RepositoryRoot) { $RepositoryRoot = Split-Path -Parent $PSScriptRoot }
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
if (-not $OutputPath) { $OutputPath = Join-Path $RepositoryRoot "build\test-results\local\powershell-encoding.json" }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
. (Join-Path $PSScriptRoot "git-path-list.ps1")

function ConvertTo-NativeArgument {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Get-GitValue {
    param([string[]]$Arguments)
    $result = Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments $Arguments -AllowFailure
    if ([int]$result.exitCode -ne 0) { return "" }
    return ([string]$result.stdout).Trim()
}

$startedAt = [DateTime]::UtcNow
$issues = New-Object System.Collections.Generic.List[object]
$targetRef = if ($BaseRef) { $BaseRef } else { "origin/master" }
$baseCommit = Get-GitValue -Arguments @("merge-base", "HEAD", $targetRef)
if (-not $baseCommit) { throw "PowerShell encoding preflight cannot resolve merge base for '$targetRef'." }
$changed = @(
    Get-RepositoryGitPathList -RepositoryRoot $RepositoryRoot -Arguments @(
        "diff", "--name-only", "--diff-filter=ACMRT", "-z", "$baseCommit...HEAD", "--", "*.ps1"
    )
)

if ($changed.Count -gt 0) {
    $probePath = Join-Path $PSScriptRoot "release-e2e\test-powershell51-decoding.ps1"
    $probeToken = [guid]::NewGuid().ToString("N")
    $probeInputPath = Join-Path ([IO.Path]::GetTempPath()) ("itl-ps51-decode-$probeToken.input.json")
    $probeOutputPath = Join-Path ([IO.Path]::GetTempPath()) ("itl-ps51-decode-$probeToken.output.json")
    $probeStdoutPath = $probeOutputPath + ".stdout.log"
    $probeStderrPath = $probeOutputPath + ".stderr.log"
    $paths = @($changed | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $RepositoryRoot ([string]$_).Replace('/', '\'))) })
    $decodedByPath = @{}
    try {
        [IO.File]::WriteAllText($probeInputPath, (ConvertTo-Json -InputObject @($paths)), [Text.UTF8Encoding]::new($false))
        $parts = @(
            "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", (ConvertTo-NativeArgument $probePath),
            "-InputPath", (ConvertTo-NativeArgument $probeInputPath),
            "-OutputPath", (ConvertTo-NativeArgument $probeOutputPath)
        )
        $process = Start-Process -FilePath "powershell.exe" -ArgumentList ($parts -join " ") -WindowStyle Hidden `
            -RedirectStandardOutput $probeStdoutPath -RedirectStandardError $probeStderrPath -Wait -PassThru
        $null = $process.Handle
        if ([int]$process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $probeOutputPath -PathType Leaf)) {
            $stderr = if (Test-Path -LiteralPath $probeStderrPath -PathType Leaf) { Get-Content -LiteralPath $probeStderrPath -Raw } else { "" }
            throw "Windows PowerShell 5.1 batch decode probe failed with exit code $($process.ExitCode): $($stderr.Trim())"
        }
        $probeResults = Get-Content -LiteralPath $probeOutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($result in $probeResults) {
            $decodedByPath[[IO.Path]::GetFullPath([string]$result.path)] = [string]$result.decodedBase64
        }
    } catch {
        $issues.Add([ordered]@{
            code = "RELEASE_POWERSHELL_ENCODING_INVALID"
            path = ""
            message = "Windows PowerShell 5.1 batch decode preflight failed: $($_.Exception.Message)"
        }) | Out-Null
    } finally {
        Remove-Item -LiteralPath $probeInputPath, $probeOutputPath, $probeStdoutPath, $probeStderrPath -Force -ErrorAction SilentlyContinue
    }

    if ($issues.Count -eq 0) {
        foreach ($relativePath in $changed) {
            $path = Join-Path $RepositoryRoot ([string]$relativePath).Replace('/', '\')
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            try {
                $bytes = [IO.File]::ReadAllBytes($path)
                $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
                $text = $strictUtf8.GetString($bytes)
                if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
                if ($text.IndexOf([char]0xFFFD) -ge 0) { throw "replacement character U+FFFD is present" }
                $tokens = $null
                $errors = $null
                [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
                if (@($errors).Count -gt 0) { throw "PowerShell AST errors: $(@($errors | ForEach-Object { $_.Message }) -join '; ')" }
                $actualBase64 = [string]$decodedByPath[[IO.Path]::GetFullPath($path)]
                $expectedBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
                if (-not $actualBase64 -or $actualBase64 -cne $expectedBase64) {
                    throw "Windows PowerShell 5.1 default decoding differs from strict UTF-8"
                }
            } catch {
                $issues.Add([ordered]@{
                    code = "RELEASE_POWERSHELL_ENCODING_INVALID"
                    path = [string]$relativePath
                    message = "Changed PowerShell file is not strict UTF-8/AST-clean and Windows PowerShell 5.1-safe: $relativePath; $($_.Exception.Message)"
                }) | Out-Null
            }
        }
    }
}

$report = [ordered]@{
    schemaVersion = 1
    kind = "itl-powershell-encoding-preflight"
    status = $(if ($issues.Count -eq 0) { "passed" } else { "failed" })
    baseRef = $targetRef
    baseCommit = $baseCommit
    changedPowerShellFiles = @($changed)
    contract = "windows-powershell-5.1-default-decode-plus-strict-utf8-and-ast"
    issues = @($issues.ToArray())
    startedAt = $startedAt.ToString("o")
    finishedAt = [DateTime]::UtcNow.ToString("o")
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
[IO.File]::WriteAllText($OutputPath, (($report | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
$report | ConvertTo-Json -Depth 8
if (-not $ReportOnly -and [string]$report.status -ne "passed") {
    throw "PowerShell encoding preflight failed: $(@($issues | ForEach-Object { $_.message }) -join '; ')"
}
