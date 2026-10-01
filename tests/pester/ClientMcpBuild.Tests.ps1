BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $repo = $context.RepoRoot
    . (Join-Path $repo 'scripts/client-mcp-build.ps1')
    $assetRoot = Join-Path $repo 'third-party/client-mcp/v0.6.5-itl-r1'
    $manifest = Get-Content -LiteralPath (Join-Path $assetRoot 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $original = Join-Path $repo 'tests/fixtures/client-mcp-language/Configuration.xml'
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts/release-e2e/ondemand-mcp.ps1'),[ref]$tokens,[ref]$errors)
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ReleaseClientMcpArtifactEvidence'},$true)
    Invoke-Expression $definition.Extent.Text
    function New-ClientMetadataFixture {
        $root = Join-Path $TestDrive ('client build ' + [char]0x044f + ' ' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($root)
        [IO.File]::Copy($original, (Join-Path $root 'Configuration.xml'))
        [IO.File]::WriteAllBytes((Join-Path $root 'opaque.bin'), [byte[]]@(239,187,191,13,10,0,255))
        return $root
    }
}
Describe 'Controlled client_mcp metadata build' {
    It 'changes only the language declaration and one name-bound adopted Language' {
        $root = New-ClientMetadataFixture
        $before = Get-ClientMcpBuildSourceIdentity $root
        $repair = Add-ClientMcpBorrowedLanguage -SourceRoot $root -LanguagePath (Join-Path $assetRoot 'Language.xml') -Specification $manifest.patch
        $after = Get-ClientMcpBuildSourceIdentity $root
        $after.files.Count | Should -Be ($before.files.Count + 1)
        @($repair.changedPaths) | Should -Be @($manifest.patch.expectedChangedPaths)
        ($after.files | Where-Object path -EQ 'opaque.bin').sha256 | Should -Be ($before.files | Where-Object path -EQ 'opaque.bin').sha256
        $xml = [IO.File]::ReadAllText((Join-Path $root 'Configuration.xml'), [Text.Encoding]::UTF8)
        $insert = "`r`n`t`t`t<Language>" + $manifest.patch.languageName + '</Language>'
        $xml.Replace($insert, '') | Should -Be ([IO.File]::ReadAllText($original, [Text.Encoding]::UTF8))
        [IO.File]::ReadAllBytes((Join-Path $root 'Configuration.xml'))[0..2] | Should -Be @(239,187,191)
        [xml]$language = [IO.File]::ReadAllText((Join-Path $root $repair.changedPaths[1]), [Text.Encoding]::UTF8)
        $language.MetaDataObject.Language.Properties.ObjectBelonging | Should -Be 'Adopted'
        @($language.SelectNodes("//*[local-name()='ExtendedConfigurationObject']")).Count | Should -Be 0
        $after.fingerprint | Should -Not -Be $before.fingerprint
    }
    It 'rejects a changed upstream baseline before any repair writes' {
        $root = New-ClientMetadataFixture
        [IO.File]::AppendAllText((Join-Path $root 'Configuration.xml'), 'changed', [Text.Encoding]::UTF8)
        $before = Get-ClientMcpBuildSourceIdentity $root
        { Add-ClientMcpBorrowedLanguage $root (Join-Path $assetRoot 'Language.xml') $manifest.patch } | Should -Throw '*BASELINE_METADATA_MISMATCH*'
        (Get-ClientMcpBuildSourceIdentity $root).fingerprint | Should -Be $before.fingerprint
    }
    It 'rejects target-base UUID binding without changing the original source' {
        $root = New-ClientMetadataFixture
        $languagePath = Join-Path $TestDrive 'bound-language.xml'
        $text = [IO.File]::ReadAllText((Join-Path $assetRoot 'Language.xml'), [Text.Encoding]::UTF8).Replace('</Properties>', '<ExtendedConfigurationObject>7f050357-4724-44ec-a376-70af0c426227</ExtendedConfigurationObject></Properties>')
        [IO.File]::WriteAllText($languagePath, $text, [Text.Encoding]::UTF8)
        $specification = $manifest.patch | ConvertTo-Json | ConvertFrom-Json
        $specification.languageSha256 = (Get-FileHash -LiteralPath $languagePath).Hash.ToLowerInvariant()
        $before = Get-ClientMcpBuildSourceIdentity $root
        { Add-ClientMcpBorrowedLanguage $root $languagePath $specification } | Should -Throw '*LANGUAGE_CONTRACT_INVALID*'
        (Get-ClientMcpBuildSourceIdentity $root).fingerprint | Should -Be $before.fingerprint
    }
    It 'keeps all licenses and repair sources pinned in the controlled manifest' {
        foreach ($name in @('LICENSE.upstream', 'LICENSE.GPL3', 'ITL-NOTICE.txt')) {
            (Get-FileHash -LiteralPath (Join-Path $assetRoot $name)).Hash.ToLowerInvariant() | Should -Be $manifest.notices.$name
        }
        (Get-FileHash -LiteralPath (Join-Path $assetRoot 'Language.xml')).Hash.ToLowerInvariant() | Should -Be $manifest.patch.languageSha256
        $manifest.compatibilityVersion | Should -Be 'v0.6.5'
        $manifest.upstream.sha256 | Should -Match '^[a-f0-9]{64}$'
    }
    It 'writes canonical UTF8 source ZIP paths and reconstructs every original byte' {
        $source = New-ClientMetadataFixture
        [void](Add-ClientMcpBorrowedLanguage $source (Join-Path $assetRoot 'Language.xml') $manifest.patch)
        $identity = Get-ClientMcpBuildSourceIdentity $source
        $stage = Join-Path $TestDrive ('source archive ' + [char]0x044f)
        [void][IO.Directory]::CreateDirectory($stage)
        Copy-Item -LiteralPath $source -Destination (Join-Path $stage 'src') -Recurse
        $zipPath = Join-Path $TestDrive ('source ' + [char]0x044f + '.zip')
        New-ClientMcpSourceArchive -SourceDirectory $stage -DestinationPath $zipPath
        $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            @($archive.Entries | Where-Object { $_.FullName.Contains('\') }).Count | Should -Be 0
            foreach ($file in $identity.files) {
                $archive.GetEntry('src/' + $file.path) | Should -Not -BeNullOrEmpty
            }
        } finally { $archive.Dispose() }
        $restored = Join-Path $TestDrive ('restored source ' + [char]0x044f)
        [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $restored)
        (Get-ClientMcpBuildSourceIdentity (Join-Path $restored 'src')).fingerprint | Should -Be $identity.fingerprint
        { New-ClientMcpSourceArchive -SourceDirectory $stage -DestinationPath $zipPath } | Should -Throw
    }
    It 'requires the exact CFE identity and existing installation owner proof for live release evidence' {
        $root=Join-Path $TestDrive ('release service '+[char]0x044f)
        $helper=Join-Path $root '.agents/skills/1c-workflow/scripts/agent-1c.ps1'
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $helper))
        $fake='param($ProjectRoot,$Action); function Read-DevBranchState { param($Name); Get-Content -LiteralPath (Join-Path $ProjectRoot "state.json") -Raw -Encoding UTF8 | ConvertFrom-Json }; function Test-VanessaMcpSafeModeProofMatchesState { param($State); return [bool]$State.fixtureOwnerMatches }'
        [IO.File]::WriteAllText($helper,$fake,[Text.Encoding]::UTF8)
        $state=[ordered]@{fixtureOwnerMatches=$true;vanessaMcpClientMcpSha256=('a'*64);vanessaMcpClientMcpVersion='v0.6.5';vanessaServiceInfoBasePath='service';vanessaMcpSafeModeProof=[ordered]@{clientRuntimeHash='runtime';clientMcp=[ordered]@{artifactSha256=('a'*64)}}}
        $lock=[pscustomobject]@{sha256=('a'*64);version='v0.6.5'}
        [IO.File]::WriteAllText((Join-Path $root state.json),($state|ConvertTo-Json -Depth 5),[Text.Encoding]::UTF8)
        (Get-ReleaseClientMcpArtifactEvidence $root branch $lock).sha256 | Should -Be ('a'*64)
        $state.vanessaMcpSafeModeProof.clientMcp.artifactSha256=('b'*64)
        [IO.File]::WriteAllText((Join-Path $root state.json),($state|ConvertTo-Json -Depth 5),[Text.Encoding]::UTF8)
        { Get-ReleaseClientMcpArtifactEvidence $root branch $lock } | Should -Throw '*exact workflow-pinned*'
        $state.vanessaMcpSafeModeProof.clientMcp.artifactSha256=('a'*64)
        $state.fixtureOwnerMatches=$false
        [IO.File]::WriteAllText((Join-Path $root state.json),($state|ConvertTo-Json -Depth 5),[Text.Encoding]::UTF8)
        { Get-ReleaseClientMcpArtifactEvidence $root branch $lock } | Should -Throw '*ownership proof is incomplete*'
    }
}
