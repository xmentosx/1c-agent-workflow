# Stateless metadata repair for the exact published client_mcp baseline.
function Get-ClientMcpBuildInputPaths {
    param([string]$RepositoryRoot)
    $paths = @('scripts/build-client-mcp-patched.ps1', 'scripts/client-mcp-build.ps1', 'scripts/vanessa-build-runtime.ps1', 'scripts/git-path-list.ps1',
        'third-party/client-mcp/v0.6.5-itl-r1/manifest.json', 'third-party/client-mcp/v0.6.5-itl-r1/Language.xml',
        '.agents/skills/1c-workflow/scripts/agent-1c.ps1',
        '.agents/skills/itl-remote-runner/scripts/ExecutionGuard.ps1', '.agents/skills/itl-remote-runner/scripts/PythonRuntime.ps1',
        '.agents/skills/itl-remote-runner/scripts/itl_remote/__init__.py', '.agents/skills/itl-remote-runner/scripts/itl_remote/execution_guard.py',
        '.agents/skills/itl-remote-runner/scripts/itl_remote/execution_guard_host.py', '.agents/skills/itl-remote-runner/scripts/itl_remote/common.py')
    # The entrypoint loads this complete library inventory. Unknown/transitive
    # helper changes must not reuse native compiler, guard or rollback proof.
    $root = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
    $libraryRoot = Join-Path $root '.agents/skills/1c-workflow/scripts/lib'
    $paths += @(Get-ChildItem -LiteralPath $libraryRoot -Filter '*.ps1' -File | ForEach-Object { $_.FullName.Substring($root.Length + 1).Replace('\', '/') })
    return @($paths | Sort-Object -Unique)
}

function Add-ClientMcpBorrowedLanguage {
    param([string]$SourceRoot, [string]$LanguagePath, [object]$Specification)
    $configurationPath = Join-Path $SourceRoot 'Configuration.xml'
    $before = (Get-FileHash -LiteralPath $configurationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($before -cne [string]$Specification.configurationSha256) { throw 'CLIENT_MCP_BUILD_BASELINE_METADATA_MISMATCH' }
    if ((Get-FileHash -LiteralPath $LanguagePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$Specification.languageSha256) {
        throw 'CLIENT_MCP_BUILD_LANGUAGE_SOURCE_MISMATCH'
    }
    [xml]$language = [IO.File]::ReadAllText($LanguagePath, [Text.Encoding]::UTF8)
    $node = $language.SelectSingleNode("/*[local-name()='MetaDataObject']/*[local-name()='Language']")
    $name = [string]$node.Properties.Name
    if ($null -eq $node -or $node.GetAttribute('uuid') -cne [string]$Specification.languageUuid -or
        [string]$node.Properties.ObjectBelonging -cne 'Adopted' -or [string]$node.Properties.LanguageCode -cne 'ru' -or
        $name -cne [string]$Specification.languageName -or $null -ne $node.SelectSingleNode(".//*[local-name()='ExtendedConfigurationObject']")) {
        throw 'CLIENT_MCP_BUILD_LANGUAGE_CONTRACT_INVALID'
    }
    $bytes = [IO.File]::ReadAllBytes($configurationPath)
    $bomLength = if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { 3 } else { 0 }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $text = $utf8.GetString($bytes, $bomLength, $bytes.Length - $bomLength)
    [xml]$configuration = $text
    if ([string]$configuration.MetaDataObject.Configuration.uuid -cne [string]$Specification.configurationUuid -or
        [regex]::Matches($text, '<ChildObjects>').Count -ne 1 -or $text.Contains('<Language>') -or
        @($configuration.SelectNodes("//*[local-name()='Language']")).Count -ne 0) { throw 'CLIENT_MCP_BUILD_BASELINE_CONTRACT_INVALID' }
    $destination = Join-Path $SourceRoot ('Languages/' + $name + '.xml')
    if (Test-Path -LiteralPath $destination) { throw 'CLIENT_MCP_BUILD_LANGUAGE_ALREADY_EXISTS' }
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $patched = $text.Replace('<ChildObjects>', ('<ChildObjects>' + $newline + "`t`t`t<Language>" + $name + '</Language>'))
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
    [IO.File]::Copy($LanguagePath, $destination, $false)
    [IO.File]::WriteAllText($configurationPath, $patched, [Text.UTF8Encoding]::new(($bomLength -eq 3)))
    return [pscustomobject]@{ changedPaths = @('Configuration.xml', ('Languages/' + $name + '.xml')); beforeSha256 = $before }
}

function Get-ClientMcpBuildSourceIdentity {
    param([string]$SourceRoot)
    $root = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object {
        [pscustomobject]@{ path = $_.FullName.Substring($root.Length + 1).Replace('\', '/'); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    } | Sort-Object path)
    $bytes = [Text.Encoding]::UTF8.GetBytes((@($files | ForEach-Object { $_.path + [char]0 + $_.sha256 }) -join "`n"))
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $sha = ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() } finally { $hash.Dispose() }
    return [pscustomobject]@{ fingerprint = ('sha256:' + $sha); files = $files }
}

function New-ClientMcpSourceArchive {
    param([string]$SourceDirectory, [string]$DestinationPath)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\')
    $paths = [string[]]@(Get-ChildItem -LiteralPath $root -Recurse -File |
        ForEach-Object { $_.FullName.Substring($root.Length + 1) })
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $stream = [IO.File]::Open($DestinationPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false, [Text.Encoding]::UTF8)
        try {
            foreach ($relative in $paths) {
                $entry = $archive.CreateEntry($relative.Replace('\', '/'), [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $entry.ExternalAttributes = 0
                $inputStream = [IO.File]::OpenRead((Join-Path $root $relative))
                try {
                    $outputStream = $entry.Open()
                    try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
                } finally { $inputStream.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
}

# A retained build is historical source correspondence, not current native proof.
# Validate the immutable pair before loading its CFE with today's runtime owner.
function Get-ClientMcpRetainedBuildEvidence {
    param([string]$RepositoryRoot, [string]$Directory, [object]$Manifest)
    $path = Join-Path $Directory 'candidate.provenance.json'
    $proof = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($proof.component -cne 'clientMcp' -or $proof.status -cne 'built' -or
        [string]$proof.sourceCommit -cnotmatch '^[a-f0-9]{40}$' -or -not $proof.restored -or -not $proof.released -or
        $proof.manifestSha256 -cne (Get-FileHash -LiteralPath (Join-Path $RepositoryRoot 'third-party/client-mcp/v0.6.5-itl-r1/manifest.json')).Hash.ToLowerInvariant() -or
        $proof.platformVersion -cne $Manifest.build.platformVersion -or $proof.platformSha256 -cne $Manifest.build.platformSha256 -or
        $proof.upstream.commit -cne $Manifest.upstream.commit -or $proof.compatibilityVersion -cne $Manifest.compatibilityVersion -or
        $proof.downstreamRevision -cne $Manifest.downstreamRevision -or
        $proof.gate6.sourceFingerprint -cne $proof.sourceIdentity.fingerprint -or
        (@($proof.gate6.steps | ForEach-Object step) -join ',') -cne 'modules,applicability,configuration' -or
        @($proof.gate6.steps | Where-Object { $_.exitCode -ne 0 -or $_.dumpResult -ne 0 }).Count -gt 0) {
        throw 'CLIENT_MCP_RETAINED_BUILD_PROVENANCE_INVALID'
    }
    $ancestor = Invoke-RepositoryGit -RepositoryRoot $RepositoryRoot -Arguments @('merge-base', '--is-ancestor', $proof.sourceCommit, 'HEAD') -AllowFailure
    if ($ancestor.exitCode -ne 0) { throw 'CLIENT_MCP_RETAINED_BUILD_NOT_ANCESTOR' }
    $historicalInputs = @($proof.buildInputs.PSObject.Properties)
    if ($historicalInputs.Count -eq 0 -or @($historicalInputs | Where-Object { [string]$_.Value -cnotmatch '^[a-f0-9]{64}$' }).Count -gt 0) { throw 'CLIENT_MCP_RETAINED_BUILD_INPUTS_INVALID' }
    foreach ($asset in @(@{name=$Manifest.artifact.fileName; sha=$proof.artifactSha256}, @{name=$Manifest.correspondingSource.fileName; sha=$proof.sourceArchiveSha256})) {
        if ([string]$asset.sha -cnotmatch '^[a-f0-9]{64}$' -or
            (Get-FileHash -LiteralPath (Join-Path $Directory $asset.name)).Hash.ToLowerInvariant() -cne $asset.sha) { throw 'CLIENT_MCP_RETAINED_BUILD_ASSET_MISMATCH' }
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead((Join-Path $Directory $Manifest.correspondingSource.fileName))
    try {
        $identityEntry = $archive.GetEntry('SOURCE-IDENTITY.json')
        if ($null -eq $identityEntry) { throw 'CLIENT_MCP_RETAINED_SOURCE_IDENTITY_MISSING' }
        $reader = [IO.StreamReader]::new($identityEntry.Open(), [Text.Encoding]::UTF8)
        try { $identity = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        if ($identity.fingerprint -cne $proof.sourceIdentity.fingerprint -or [string]$identity.fingerprint -cnotmatch '^sha256:[a-f0-9]{64}$') { throw 'CLIENT_MCP_RETAINED_SOURCE_IDENTITY_MISMATCH' }
        $files = @($archive.Entries | Where-Object { $_.FullName.StartsWith('src/', [StringComparison]::Ordinal) -and -not $_.FullName.EndsWith('/') })
        if ($files.Count -eq 0 -or $files.Count -ne @($files.FullName | Sort-Object -Unique).Count -or
            $files.Count -ne @($identity.files).Count -or $files.Count -ne @($proof.sourceIdentity.files).Count) { throw 'CLIENT_MCP_RETAINED_SOURCE_INVENTORY_MISMATCH' }
        foreach ($file in $files) {
            $relative = $file.FullName.Substring(4)
            $expected = @($identity.files | Where-Object path -CEQ $relative)
            $built = @($proof.sourceIdentity.files | Where-Object path -CEQ $relative)
            if ($relative.Contains('\') -or $relative.Split('/') -contains '..' -or $expected.Count -ne 1 -or $built.Count -ne 1 -or $built[0].sha256 -cne $expected[0].sha256) { throw 'CLIENT_MCP_RETAINED_SOURCE_INVENTORY_MISMATCH' }
            $stream = $file.Open(); $hash = [Security.Cryptography.SHA256]::Create()
            try { $sha = ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() } finally { $stream.Dispose(); $hash.Dispose() }
            if ($sha -cne $expected[0].sha256) { throw 'CLIENT_MCP_RETAINED_SOURCE_BYTES_MISMATCH' }
        }
    } finally { $archive.Dispose() }
    return $proof
}

function Assert-ClientMcpNativeQualification {
    param([object]$Qualification, [object]$BuildProof, [string]$BuildProofPath)
    if ([int]$Qualification.schemaVersion -ne 1 -or $Qualification.kind -cne 'client-mcp-retained-native-qualification' -or
        $Qualification.component -cne 'clientMcp' -or $Qualification.status -cne 'qualified' -or
        [string]$Qualification.sourceCommit -cnotmatch '^[a-f0-9]{40}$' -or -not $Qualification.restored -or -not $Qualification.released -or
        $Qualification.buildProvenanceSha256 -cne (Get-FileHash -LiteralPath $BuildProofPath).Hash.ToLowerInvariant() -or
        $Qualification.artifactSha256 -cne $BuildProof.artifactSha256 -or $Qualification.sourceArchiveSha256 -cne $BuildProof.sourceArchiveSha256 -or
        $Qualification.manifestSha256 -cne $BuildProof.manifestSha256 -or $Qualification.platformVersion -cne $BuildProof.platformVersion -or
        $Qualification.platformSha256 -cne $BuildProof.platformSha256 -or $Qualification.sourceIdentity.fingerprint -cne $BuildProof.sourceIdentity.fingerprint -or
        [string]$Qualification.loadedSourceIdentity.fingerprint -cnotmatch '^sha256:[a-f0-9]{64}$' -or
        @($Qualification.loadedSourceIdentity.files).Count -eq 0 -or $Qualification.gate6.sourceFingerprint -cne $Qualification.loadedSourceIdentity.fingerprint -or
        (@($Qualification.gate6.steps | ForEach-Object step) -join ',') -cne 'modules,applicability,configuration' -or
        @($Qualification.gate6.steps | Where-Object { $_.exitCode -ne 0 -or $_.dumpResult -ne 0 }).Count -gt 0) {
        throw 'clientMcp retained native qualification is incompatible or incomplete.'
    }
}
