function New-OpenSpecRuntimeTestEvidence {
    param([string]$FixtureRoot, [string]$HelperPath, [string]$RepositoryRoot)
    return @{
        fixtureRoot = $FixtureRoot; helperPath = $HelperPath; repositoryRoot = $RepositoryRoot
        startedAt = [DateTime]::UtcNow.ToString('o')
        commands = [Collections.Generic.List[object]]::new()
        executableHashes = @{}
    }
}

function Invoke-OpenSpecRuntimeTestProcess {
    param(
        [hashtable]$Evidence, [string]$FilePath, [string[]]$Arguments,
        [string]$WorkingDirectory = (Get-Location).Path
    )
    $executable = (Get-Command -Name $FilePath -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    if (-not $Evidence.executableHashes.ContainsKey($executable)) {
        $Evidence.executableHashes[$executable] = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $identity = @{ pid = $null; processStartedAt = $null }
    $observe = {
        param($process, $startedAt, $deadline)
        $identity.pid = [int]$process.Id
        $identity.processStartedAt = $process.StartTime.ToUniversalTime().ToString('o')
    }.GetNewClosure()
    $record = [ordered]@{
        executable = $executable; executableSha256 = $Evidence.executableHashes[$executable]
        arguments = $Arguments; workingDirectory = $WorkingDirectory
        startedAt = [DateTime]::UtcNow.ToString('o'); finishedAt = $null
        pid = $null; processStartedAt = $null; exitCode = $null; exitHex = $null
        stdout = ''; stderr = ''; error = ''
    }
    try {
        $capture = & {
            . $Evidence.helperPath -ProjectRoot $Evidence.fixtureRoot -Action help *> $null
            Invoke-ItlNativeProcessCapture -FilePath $executable -Arguments $Arguments -WorkingDirectory $WorkingDirectory -OnWait $observe
        }
        $record.exitCode = [int]$capture.exitCode
        $record.exitHex = '0x' + [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$capture.exitCode), 0).ToString('X8')
        $record.stdout = [string]$capture.stdout; $record.stderr = [string]$capture.stderr
        $capture | Add-Member -NotePropertyName combinedText -NotePropertyValue ([string]$capture.stdout + [string]$capture.stderr)
        return $capture
    } catch {
        $record.error = $_.Exception.Message
        throw
    } finally {
        $record.pid = $identity.pid; $record.processStartedAt = $identity.processStartedAt
        $record.finishedAt = [DateTime]::UtcNow.ToString('o')
        $Evidence.commands.Add([pscustomobject]$record)
    }
}

function Invoke-OpenSpecRuntimeTestCli {
    param([hashtable]$Evidence, [object]$Cli, [string[]]$Arguments, [switch]$IncludeStderr)
    $capture = Invoke-OpenSpecRuntimeTestProcess -Evidence $Evidence -FilePath $Cli.nodePath -Arguments (@([string]$Cli.path) + $Arguments)
    Set-Variable -Name LASTEXITCODE -Value ([int]$capture.exitCode) -Scope 1
    if ($IncludeStderr) { return $capture.combinedText }
    return $capture.stdout
}

function Invoke-OpenSpecRuntimeTestHelper {
    param([hashtable]$Evidence, [string]$FilePath, [string[]]$Arguments)
    return Invoke-OpenSpecRuntimeTestProcess -Evidence $Evidence -FilePath 'powershell.exe' -Arguments (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FilePath) + $Arguments)
}

function Complete-OpenSpecRuntimeTestFixture {
    param([hashtable]$Evidence, [bool]$Succeeded, [AllowNull()][object]$Failure, [string]$ArtifactRoot = '')
    $full = [IO.Path]::GetFullPath($Evidence.fixtureRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean a test path outside Temp: $full"
    }
    if ($Succeeded) {
        if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
        return
    }
    # Keep the exact failed runtime and workspace. Copy small identity/input files
    # into the gate's durable evidence before any later Temp cleanup can remove it.
    if (-not $ArtifactRoot) { $ArtifactRoot = Join-Path $Evidence.repositoryRoot 'build/test-results/local/openspec-cli-failures' }
    $target = Join-Path $ArtifactRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $snapshots = @()
    foreach ($project in @('', 'peer-project')) {
        foreach ($relative in @(
            '.agent-1c/project.json', '.agent-1c/dependency-lock.json',
            '.agent-1c/tools/openspec-cli/1.13.1/itl-runtime.json',
            '.agent-1c/tools/openspec-cli/1.13.1/package.json',
            '.agent-1c/tools/openspec-cli/1.13.1/package-lock.json',
            'openspec/config.yaml', 'openspec/specs/legacy/spec.md',
            'openspec/changes/legacy-change/.openspec.yaml'
        )) {
            $path = Join-Path $full $(if ($project) { "$project/$relative" } else { $relative })
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $destination = Join-Path $target $(if ($project) { "$project/$relative" } else { $relative })
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            Copy-Item -LiteralPath $path -Destination $destination
            $snapshots += [ordered]@{ path=$destination.Substring($target.Length + 1).Replace('\','/'); sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() }
        }
    }
    $report = [ordered]@{
        schemaVersion=1; fixtureRoot=$full; fixtureRetained=$true
        startedAt=$Evidence.startedAt; finishedAt=[DateTime]::UtcNow.ToString('o')
        failure=[string]$Failure; commands=@($Evidence.commands.ToArray()); snapshots=$snapshots
    }
    $reportPath = Join-Path $target 'failure.json'
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    return $reportPath
}
