Set-StrictMode -Version Latest

function ConvertTo-GitProcessArgument {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Invoke-RepositoryGit {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [AllowNull()][string]$StandardInput = $null,
        [switch]$AllowFailure
    )

    $allArguments = @("-C", ([System.IO.Path]::GetFullPath($RepositoryRoot)), "-c", "core.quotepath=false") + @($Arguments)
    $argumentLine = (@($allArguments | ForEach-Object { ConvertTo-GitProcessArgument -Value ([string]$_) }) -join " ")
    if ($null -ne $StandardInput) {
        $token = [guid]::NewGuid().ToString("N")
        $inputPath = Join-Path ([IO.Path]::GetTempPath()) ("itl-git-stdin-$token.txt")
        $stdoutPath = Join-Path ([IO.Path]::GetTempPath()) ("itl-git-stdout-$token.txt")
        $stderrPath = Join-Path ([IO.Path]::GetTempPath()) ("itl-git-stderr-$token.txt")
        try {
            [IO.File]::WriteAllText($inputPath, $StandardInput.TrimStart([char]0xFEFF), [Text.Encoding]::ASCII)
            $native = Start-Process -FilePath "git.exe" -ArgumentList $argumentLine -WindowStyle Hidden -RedirectStandardInput $inputPath -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -Wait -PassThru
            $null = $native.Handle
            $result = [pscustomobject]@{
                exitCode = [int]$native.ExitCode
                stdout = $(if (Test-Path $stdoutPath) { [IO.File]::ReadAllText($stdoutPath, [Text.Encoding]::UTF8) } else { "" })
                stderr = $(if (Test-Path $stderrPath) { [IO.File]::ReadAllText($stderrPath, [Text.Encoding]::UTF8) } else { "" })
            }
            if ($result.exitCode -ne 0 -and -not $AllowFailure) { throw "git $($Arguments -join ' ') failed with exit code $($result.exitCode): $($result.stderr.Trim())" }
            return $result
        } finally {
            Remove-Item -LiteralPath $inputPath, $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
        }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "git.exe"
    $startInfo.Arguments = $argumentLine
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $false
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    if ($startInfo.PSObject.Properties.Name -contains "StandardOutputEncoding") {
        $startInfo.StandardOutputEncoding = $utf8
        $startInfo.StandardErrorEncoding = $utf8
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Unable to start git." }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $result = [pscustomobject]@{ exitCode = [int]$process.ExitCode; stdout = $stdout; stderr = $stderr }
        if ($result.exitCode -ne 0 -and -not $AllowFailure) {
            throw "git $($Arguments -join ' ') failed with exit code $($result.exitCode): $($result.stderr.Trim())"
        }
        return $result
    } finally {
        $process.Dispose()
    }
}

function Get-RepositoryGitPathList {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    if ($Arguments.Count -eq 0) { return @() }
    if ($Arguments -notcontains "-z") { throw "Git path-list commands must include -z." }
    $result = Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments $Arguments
    if (-not $result.stdout) { return @() }
    return @($result.stdout.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries) | Where-Object { $_ })
}
