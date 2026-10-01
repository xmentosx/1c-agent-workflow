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
