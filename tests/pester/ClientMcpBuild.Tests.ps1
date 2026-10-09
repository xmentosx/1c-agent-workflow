BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context = Initialize-WorkflowPesterContext
    $repo = $context.RepoRoot
    . (Join-Path $repo 'scripts/client-mcp-build.ps1')
    . (Join-Path $repo 'scripts/git-path-list.ps1')
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
    function New-RetainedClientFixture {
        $root = Join-Path $TestDrive ('retained client ' + [char]0x044f + ' ' + [guid]::NewGuid().ToString('N'))
        $manifestDirectory = Join-Path $root 'third-party/client-mcp/v0.6.5-itl-r1'
        [void][IO.Directory]::CreateDirectory($manifestDirectory)
        [IO.File]::Copy((Join-Path $assetRoot 'manifest.json'), (Join-Path $manifestDirectory 'manifest.json'))
        [void](Invoke-RepositoryGit $root @('init', '--quiet'))
        [void](Invoke-RepositoryGit $root @('config', 'user.name', 'Client fixture'))
        [void](Invoke-RepositoryGit $root @('config', 'user.email', 'fixture@example.invalid'))
        [void](Invoke-RepositoryGit $root @('add', '.'))
        [void](Invoke-RepositoryGit $root @('commit', '--quiet', '-m', 'source producer'))
        $commit = (Invoke-RepositoryGit $root @('rev-parse', 'HEAD')).stdout.Trim()
        $stage = Join-Path $root 'stage'
        $source = Join-Path $stage 'src'
        [void][IO.Directory]::CreateDirectory($source)
        [IO.File]::WriteAllText((Join-Path $source 'Module.bsl'), 'Procedure ExactSource() EndProcedure', [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText((Join-Path $source 'ConfigDumpInfo.xml'), '<versions retained="exact"/>', [Text.Encoding]::UTF8)
        $identity = Get-ClientMcpBuildSourceIdentity $source
        [IO.File]::WriteAllText((Join-Path $stage 'SOURCE-IDENTITY.json'), ($identity | ConvertTo-Json -Depth 5), [Text.Encoding]::UTF8)
        $output = Join-Path $root 'output'
        [void][IO.Directory]::CreateDirectory($output)
        $cfe = Join-Path $output $manifest.artifact.fileName
        $zip = Join-Path $output $manifest.correspondingSource.fileName
        [IO.File]::WriteAllBytes($cfe, [byte[]]@(1,2,3))
        New-ClientMcpSourceArchive $stage $zip
        $proof = [ordered]@{component='clientMcp';status='built';sourceCommit=$commit;restored=$true;released=$true;
            manifestSha256=(Get-FileHash (Join-Path $manifestDirectory 'manifest.json')).Hash.ToLowerInvariant();upstream=$manifest.upstream;buildInputs=[ordered]@{'scripts/build-client-mcp-patched.ps1'=('a'*64)};
            platformVersion=$manifest.build.platformVersion;platformSha256=$manifest.build.platformSha256;
            compatibilityVersion=$manifest.compatibilityVersion;downstreamRevision=$manifest.downstreamRevision;
            artifactSha256=(Get-FileHash $cfe).Hash.ToLowerInvariant();sourceArchiveSha256=(Get-FileHash $zip).Hash.ToLowerInvariant();sourceIdentity=$identity;
            gate6=[ordered]@{sourceFingerprint=$identity.fingerprint;steps=@('modules','applicability','configuration'|ForEach-Object{[ordered]@{step=$_;exitCode=0;dumpResult=0}})}}
        $proofPath = Join-Path $output 'candidate.provenance.json'
        [IO.File]::WriteAllText($proofPath, ($proof | ConvertTo-Json -Depth 9), [Text.Encoding]::UTF8)
        return [pscustomobject]@{root=$root;output=$output;stage=$stage;proof=$proof;proofPath=$proofPath;cfe=$cfe;zip=$zip}
    }
}

Describe 'Retained client native qualification' {
    It 'publishes a historical pair only with exact current helper proof and rejects later helper drift' {
        & {
            $tokens=$null; $errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts/source-delivery-component.ps1'),[ref]$tokens,[ref]$errors)
            $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DeliveryExactClientMcpCandidates'},$true)
            Invoke-Expression $definition.Extent.Text
            $fixture=New-RetainedClientFixture
            $script:Root=$fixture.root
            foreach($relative in @(Get-ClientMcpBuildInputPaths $repo)) {
                $destination=Join-Path $fixture.root $relative
                [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
                [IO.File]::Copy((Join-Path $repo $relative),$destination,$true)
            }
            $inputs=[ordered]@{}
            foreach($relative in @(Get-ClientMcpBuildInputPaths $fixture.root)) { $inputs[$relative]=(Get-FileHash (Join-Path $fixture.root $relative)).Hash.ToLowerInvariant() }
            $proof=$fixture.proof
            [IO.File]::WriteAllText($fixture.proofPath,($proof|ConvertTo-Json -Depth 9),[Text.Encoding]::UTF8)
            $lock=[pscustomobject]@{version=$manifest.compatibilityVersion;downstreamRevision=$manifest.downstreamRevision;upstreamCommit=$manifest.upstream.commit;
                assetName=$manifest.artifact.fileName;releaseTag=$manifest.artifact.releaseTag;sha256=$proof.artifactSha256;manifestSha256=$proof.manifestSha256;
                correspondingSource=[pscustomobject]@{assetName=$manifest.correspondingSource.fileName;sha256=$proof.sourceArchiveSha256}}
            $loaded=[pscustomobject]@{fingerprint=('sha256:'+('b'*64));files=@([pscustomobject]@{path='ConfigDumpInfo.xml';sha256=('c'*64)})}
            $qualification=[ordered]@{schemaVersion=1;kind='client-mcp-retained-native-qualification';component='clientMcp';status='qualified';sourceCommit=$proof.sourceCommit;
                restored=$true;released=$true;buildProvenanceSha256=(Get-FileHash $fixture.proofPath).Hash.ToLowerInvariant();artifactSha256=$proof.artifactSha256;
                sourceArchiveSha256=$proof.sourceArchiveSha256;manifestSha256=$proof.manifestSha256;platformVersion=$proof.platformVersion;platformSha256=$proof.platformSha256;
                sourceIdentity=$proof.sourceIdentity;loadedSourceIdentity=$loaded;buildInputs=$inputs;
                gate6=[ordered]@{sourceFingerprint=$loaded.fingerprint;steps=@('modules','applicability','configuration'|ForEach-Object{[ordered]@{step=$_;exitCode=0;dumpResult=0}})}}
            $saved=[Environment]::GetEnvironmentVariable('VANESSA_MCP_CLIENT_CFE_PATH','Process')
            try {
                [Environment]::SetEnvironmentVariable('VANESSA_MCP_CLIENT_CFE_PATH',$fixture.cfe,'Process')
                { Get-DeliveryExactClientMcpCandidates $fixture.root $lock } | Should -Throw '*helper inventory differs*'
                [IO.File]::WriteAllText((Join-Path $fixture.output 'candidate.native-qualification.json'),($qualification|ConvertTo-Json -Depth 9),[Text.Encoding]::UTF8)
                @(Get-DeliveryExactClientMcpCandidates $fixture.root $lock).Count | Should -Be 2
                $runtime=Join-Path $fixture.root '.agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1'
                [IO.File]::AppendAllText($runtime,'# changed native owner',[Text.Encoding]::UTF8)
                { Get-DeliveryExactClientMcpCandidates $fixture.root $lock } | Should -Throw '*build input differs*'
            } finally { [Environment]::SetEnvironmentVariable('VANESSA_MCP_CLIENT_CFE_PATH',$saved,'Process') }
        }
    }
    It 'preserves historical provenance and every corresponding-source byte' {
        $fixture = New-RetainedClientFixture
        $before = (Get-FileHash $fixture.proofPath).Hash
        $evidence = Get-ClientMcpRetainedBuildEvidence $fixture.root $fixture.output $manifest
        $evidence.artifactSha256 | Should -Be $fixture.proof.artifactSha256
        (Get-FileHash $fixture.proofPath).Hash | Should -Be $before
        [IO.File]::AppendAllText($fixture.cfe, 'changed')
        { Get-ClientMcpRetainedBuildEvidence $fixture.root $fixture.output $manifest } | Should -Throw '*ASSET_MISMATCH*'
    }
    It 'rejects a producer commit outside candidate ancestry' {
        $fixture = New-RetainedClientFixture
        $fixture.proof.sourceCommit = 'f' * 40
        [IO.File]::WriteAllText($fixture.proofPath, ($fixture.proof | ConvertTo-Json -Depth 9), [Text.Encoding]::UTF8)
        { Get-ClientMcpRetainedBuildEvidence $fixture.root $fixture.output $manifest } | Should -Throw '*NOT_ANCESTOR*'
    }
    It 'rejects changed module or dump-index bytes even when an archive hash is updated' -TestCases @(@{File='Module.bsl'},@{File='ConfigDumpInfo.xml'}) {
        param($File)
        $fixture = New-RetainedClientFixture
        [IO.File]::AppendAllText((Join-Path $fixture.stage ('src/' + $File)), 'changed')
        Remove-Item -LiteralPath $fixture.zip
        New-ClientMcpSourceArchive $fixture.stage $fixture.zip
        $fixture.proof.sourceArchiveSha256 = (Get-FileHash $fixture.zip).Hash.ToLowerInvariant()
        [IO.File]::WriteAllText($fixture.proofPath, ($fixture.proof | ConvertTo-Json -Depth 9), [Text.Encoding]::UTF8)
        { Get-ClientMcpRetainedBuildEvidence $fixture.root $fixture.output $manifest } | Should -Throw '*SOURCE_BYTES_MISMATCH*'
    }
    It 'requires a separate successful native ladder for the actually loaded retained artifact' {
        $fixture = New-RetainedClientFixture
        $proof = $fixture.proof
        $loaded = [pscustomobject]@{fingerprint=('sha256:' + ('b'*64));files=@([pscustomobject]@{path='ConfigDumpInfo.xml';sha256=('c'*64)})}
        $qualification = [ordered]@{schemaVersion=1;kind='client-mcp-retained-native-qualification';component='clientMcp';status='qualified';sourceCommit=$proof.sourceCommit;
            restored=$true;released=$true;buildProvenanceSha256=(Get-FileHash $fixture.proofPath).Hash.ToLowerInvariant();artifactSha256=$proof.artifactSha256;
            sourceArchiveSha256=$proof.sourceArchiveSha256;manifestSha256=$proof.manifestSha256;platformVersion=$proof.platformVersion;platformSha256=$proof.platformSha256;
            sourceIdentity=$proof.sourceIdentity;loadedSourceIdentity=$loaded;gate6=[ordered]@{sourceFingerprint=$loaded.fingerprint;steps=@('modules','applicability','configuration'|ForEach-Object{[ordered]@{step=$_;exitCode=0;dumpResult=0}})}}
        { Assert-ClientMcpNativeQualification ([pscustomobject]$qualification) ([pscustomobject]$proof) $fixture.proofPath } | Should -Not -Throw
        foreach ($field in @('restored','released')) {
            $qualification[$field]=$false
            { Assert-ClientMcpNativeQualification ([pscustomobject]$qualification) ([pscustomobject]$proof) $fixture.proofPath } | Should -Throw '*incompatible or incomplete*'
            $qualification[$field]=$true
        }
        $qualification.gate6.steps[1].exitCode=1
        { Assert-ClientMcpNativeQualification ([pscustomobject]$qualification) ([pscustomobject]$proof) $fixture.proofPath } | Should -Throw '*incompatible or incomplete*'
        $qualification.gate6.steps[1].exitCode=0
        $qualification.artifactSha256='d'*64
        { Assert-ClientMcpNativeQualification ([pscustomobject]$qualification) ([pscustomobject]$proof) $fixture.proofPath } | Should -Throw '*incompatible or incomplete*'
        $qualification.artifactSha256=$proof.artifactSha256
        [IO.File]::AppendAllText($fixture.proofPath, ' ')
        { Assert-ClientMcpNativeQualification ([pscustomobject]$qualification) ([pscustomobject]$proof) $fixture.proofPath } | Should -Throw '*incompatible or incomplete*'
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
