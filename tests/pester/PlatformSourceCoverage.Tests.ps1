Describe 'Operation-local MCP source coverage' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        $LibraryPath = Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/agent-1c.platform-evidence.ps1'
        . $LibraryPath

        function Write-CoverageJson([string]$Path, [object]$Value) {
            [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 15), [Text.UTF8Encoding]::new($false))
        }
        function New-CoverageFixture {
            $project = Join-Path $TestDrive ('Проект MCP проверка ' + [guid]::NewGuid().ToString('N'))
            $source = Join-Path $project 'src/cf'
            $proofs = Join-Path $project '.agent-1c/proofs'
            $bsl = 'CommonModules/Сложение/Ext/Module.bsl'
            $xml = 'Documents/Проверка.xml'
            foreach ($directory in @((Split-Path (Join-Path $source $bsl) -Parent), (Split-Path (Join-Path $source $xml) -Parent), $proofs)) { [void][IO.Directory]::CreateDirectory($directory) }
            $bslText = "Процедура Проверить() Экспорт`r`nКонецПроцедуры`r`n"
            [IO.File]::WriteAllText((Join-Path $source $bsl), $bslText, [Text.UTF8Encoding]::new($true))
            $xmlText = '<Metadata name="Проверка" />' + "`r`n"
            [IO.File]::WriteAllText((Join-Path $source $xml), $xmlText, [Text.UTF8Encoding]::new($true))
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $codeHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($bslText)))).Replace('-', '').ToLowerInvariant().Substring(0, 16) } finally { $sha.Dispose() }
            $codeDescriptor = @{ chars = $bslText.Length; lines = 3; sha256 = $codeHash }
            $bslRequest = @{ jsonrpc = '2.0'; id = 11; method = 'tools/call'; params = @{ name = 'syntaxcheck'; arguments = @{ code = $bslText; file_name = 'Module.bsl' } } }
            $bslResponse = @{ jsonrpc = '2.0'; id = 11; result = @{ isError = $false; content = @(@{ type = 'text'; text = 'events: actual structured report is authoritative' }); structuredContent = @{
                diagnostics = @(); diagnostic_asides = @(); summary = @{ total = 0; returned = 0; truncated = $false }
                filters = @{ line_filter_applied = $false; severity_filter_applied = $false; suppression_applied = $false; plugins_applied = $false }
                provenance = @{ tool = 'syntaxcheck'; analyzer_version = '0.2.81'; file_metrics_scope = 'whole_file'; source_encoding = 'utf-8'; index = 'absent' }
                request_rewrite = @{ applied = $false; requested = @{ code = $codeDescriptor; file_name = 'Module.bsl' }; used = @{ code = $codeDescriptor.Clone(); file_name = 'Module.bsl' }; changed_by = @() }
            } } }
            # Native saved calls may contain {name,arguments}; verify_xml also returns a JSON text payload.
            $xmlRequest = @{ name = 'verify_xml'; arguments = @{ xml_content = $xmlText; object_type = 'Document' } }
            $xmlResponse = @{ jsonrpc = '2.0'; id = 12; result = @{ isError = $false; content = @(@{ type = 'text'; text = (@{ status = 'valid'; errors = @() } | ConvertTo-Json -Depth 5) }) } }
            $fixture = @{ ProjectRoot = $project; SourceRoot = $source; ProofRoot = $proofs; EvidencePath = (Join-Path $proofs 'coverage.json'); Fingerprint = ('a' * 64); Files = @($bsl, $xml); BslRequest = $bslRequest; BslResponse = $bslResponse; XmlRequest = $xmlRequest; XmlResponse = $xmlResponse }
            foreach ($row in @(@{ name = 'bsl-request.json'; value = $bslRequest }, @{ name = 'bsl-result.json'; value = $bslResponse }, @{ name = 'xml-request.json'; value = $xmlRequest }, @{ name = 'xml-result.json'; value = $xmlResponse })) { Write-CoverageJson (Join-Path $proofs $row.name) $row.value }
            $fixture.Receipt = @{ schemaVersion = 1; kind = 'itl-mcp-source-validation'; taskPath = 'quick-fix'; projectRoot = $project; sourceRoot = $source; sourceFingerprint = $fixture.Fingerprint; infoBaseKind = 'file'; infoBasePath = (Join-Path $project '.agent-1c/infobases/Ветка тест'); entries = @(
                @{ relativePath = $bsl; inputSha256 = (Get-ItlPlatformEvidenceHash (Join-Path $source $bsl)); checker = @{ server = '1c-syntax-checker-mcp'; capability = 'syntaxcheck'; versionOrId = '0.2.81' }; request = @{ path = 'bsl-request.json'; sha256 = (Get-ItlPlatformEvidenceHash (Join-Path $proofs 'bsl-request.json')) }; result = @{ path = 'bsl-result.json'; sha256 = (Get-ItlPlatformEvidenceHash (Join-Path $proofs 'bsl-result.json')) } },
                @{ relativePath = $xml; inputSha256 = (Get-ItlPlatformEvidenceHash (Join-Path $source $xml)); checker = @{ server = '1c-code-metadata-mcp'; capability = 'verify_xml'; versionOrId = 'recorded-tools-schema-id' }; request = @{ path = 'xml-request.json'; sha256 = (Get-ItlPlatformEvidenceHash (Join-Path $proofs 'xml-request.json')) }; result = @{ path = 'xml-result.json'; sha256 = (Get-ItlPlatformEvidenceHash (Join-Path $proofs 'xml-result.json')) } }
            ) }
            Write-CoverageJson $fixture.EvidencePath $fixture.Receipt
            return $fixture
        }
        function Save-CoverageFixture([hashtable]$Fixture, [string]$Artifact = '') {
            if ($Artifact) {
                $map = @{ BslRequest = @{ entry = 0; ref = 'request'; file = 'bsl-request.json' }; BslResponse = @{ entry = 0; ref = 'result'; file = 'bsl-result.json' }; XmlRequest = @{ entry = 1; ref = 'request'; file = 'xml-request.json' }; XmlResponse = @{ entry = 1; ref = 'result'; file = 'xml-result.json' } }
                $row = $map[$Artifact]; $path = Join-Path $Fixture.ProofRoot $row.file
                Write-CoverageJson $path $Fixture[$Artifact]
                $Fixture.Receipt.entries[$row.entry][$row.ref].sha256 = Get-ItlPlatformEvidenceHash $path
            }
            Write-CoverageJson $Fixture.EvidencePath $Fixture.Receipt
        }
        function Read-CoverageFixture([hashtable]$Fixture, [string[]]$Files = @()) {
            if (-not $Files.Count) { $Files = $Fixture.Files }
            Test-ItlPlatformSourceCoverage -EvidencePath $Fixture.EvidencePath -SourceRoot $Fixture.SourceRoot -SourceFingerprint $Fixture.Fingerprint -Files $Files -ProjectRoot $Fixture.ProjectRoot
        }
    }

    It 'covers current BSL and explicitly valid XML through exact UTF8 Unicode and whitespace paths without writes' {
        $f = New-CoverageFixture
        $before = @(Get-ChildItem -LiteralPath $f.ProjectRoot -File -Recurse | Sort-Object FullName | ForEach-Object { $_.FullName + ':' + (Get-ItlPlatformEvidenceHash $_.FullName) })
        $r = Read-CoverageFixture $f @('src/cf/CommonModules/Сложение/Ext/Module.bsl', 'Documents/Проверка.xml')
        $r.covered | Should -BeTrue
        $r.coveredFiles.Count | Should -Be 2
        $r.reason | Should -Be 'MCP_ZERO_ERRORS_COVERS_CHANGED_FILES'
        $after = @(Get-ChildItem -LiteralPath $f.ProjectRoot -File -Recurse | Sort-Object FullName | ForEach-Object { $_.FullName + ':' + (Get-ItlPlatformEvidenceHash $_.FullName) })
        ($after -join "`n") | Should -Be ($before -join "`n")
    }
    It 'keeps real warnings distinct from syntax errors and normalizes only version whitespace' {
        $f = New-CoverageFixture
        $f.BslResponse.result.structuredContent.diagnostics = @(@{ severity = 'Hint'; code = 'CodeOutOfRegion'; file = 'Module.bsl' })
        $f.BslResponse.result.structuredContent.diagnostic_asides = @(@{ diagnostic = 0; field = 'tags'; value = 1 })
        $f.BslResponse.result.structuredContent.summary.total = 1; $f.BslResponse.result.structuredContent.summary.returned = 1
        $f.Receipt.entries[0].checker.versionOrId = ' 0.2.81 '
        Save-CoverageFixture $f BslResponse
        (Read-CoverageFixture $f).covered | Should -BeTrue
    }
    It 'rejects actual Critical ParseError despite a declared passed entry' {
        $f = New-CoverageFixture
        $f.Receipt.entries[0].status = 'passed'
        $f.BslResponse.result.structuredContent.diagnostics = @(@{ severity = 'Critical'; code = 'ParseError'; file = 'Module.bsl' })
        $f.BslResponse.result.structuredContent.summary.total = 1; $f.BslResponse.result.structuredContent.summary.returned = 1
        Save-CoverageFixture $f BslResponse
        (Read-CoverageFixture $f).covered | Should -BeFalse
    }
    It 'rejects an explicit invalid XML response' {
        $f = New-CoverageFixture
        $f.XmlResponse.result.content[0].text = (@{ status = 'invalid'; errors = @('XSD failure') } | ConvertTo-Json)
        Save-CoverageFixture $f XmlResponse
        (Read-CoverageFixture $f).covered | Should -BeFalse
    }
    It 'does not treat arbitrary passed payloads as checker evidence' {
        $f = New-CoverageFixture
        $f.BslResponse.result.structuredContent = @{ passed = $true }
        Save-CoverageFixture $f BslResponse
        (Read-CoverageFixture $f).covered | Should -BeFalse
    }
    It 'rejects a failed checker payload with otherwise empty diagnostics' {
        $f = New-CoverageFixture; $f.BslResponse.result.structuredContent.status = 'failed'
        Save-CoverageFixture $f BslResponse
        (Read-CoverageFixture $f).covered | Should -BeFalse
    }
    It 'requires all changed files rather than one successful entry' {
        $f = New-CoverageFixture; $f.Receipt.entries = @($f.Receipt.entries[0]); Save-CoverageFixture $f
        $r = Read-CoverageFixture $f
        $r.covered | Should -BeFalse; $r.reason | Should -Be 'COVERAGE_INCOMPLETE'
    }
    It 'rejects changed current input bytes' {
        $f = New-CoverageFixture
        [IO.File]::AppendAllText((Join-Path $f.SourceRoot $f.Files[0]), '// Изменено', [Text.UTF8Encoding]::new($false))
        $r = Read-CoverageFixture $f
        $r.covered | Should -BeFalse; $r.reason | Should -Be 'SOURCE_INPUT_CHANGED'
    }
    It 'rejects a request for a different module even with updated request hash' {
        $f = New-CoverageFixture; $f.BslRequest.params.arguments.file_name = $f.Files[1]; Save-CoverageFixture $f BslRequest
        $r = Read-CoverageFixture $f
        $r.covered | Should -BeFalse; $r.reason | Should -Be 'REQUEST_INPUT_MISMATCH'
    }
    It 'rejects stale XML request content independently of declared input hash' {
        $f = New-CoverageFixture; $f.XmlRequest.arguments.xml_content = '<Metadata name="Другой" />'; Save-CoverageFixture $f XmlRequest
        $r = Read-CoverageFixture $f
        $r.covered | Should -BeFalse; $r.reason | Should -Be 'REQUEST_INPUT_MISMATCH'
    }
    It 'rejects raw artifact tampering without exposing its content' {
        $f = New-CoverageFixture
        [IO.File]::WriteAllText((Join-Path $f.ProofRoot 'bsl-result.json'), '{"secret":"must-not-be-returned"}', [Text.UTF8Encoding]::new($false))
        $r = Read-CoverageFixture $f
        $r.covered | Should -BeFalse; $r.reason | Should -Be 'ARTIFACT_UNUSABLE'
        ($r | ConvertTo-Json -Depth 4) | Should -Not -Match 'must-not-be-returned'
    }
    It 'rejects stale source fingerprint and foreign project binding' {
        $f = New-CoverageFixture; $f.Receipt.sourceFingerprint = 'other-source'; Save-CoverageFixture $f
        (Read-CoverageFixture $f).reason | Should -Be 'EVIDENCE_TARGET_MISMATCH'
        $f.Receipt.sourceFingerprint = $f.Fingerprint; $f.Receipt.projectRoot = (Split-Path $f.ProjectRoot -Parent); Save-CoverageFixture $f
        (Read-CoverageFixture $f).covered | Should -BeFalse
    }
    It 'rejects traversal and foreign artifact paths' {
        $f = New-CoverageFixture; $f.Receipt.entries[0].request.path = '../bsl-request.json'; Save-CoverageFixture $f
        (Read-CoverageFixture $f).covered | Should -BeFalse
        $f.Receipt.entries[0].request.path = Join-Path (Split-Path $f.ProjectRoot -Parent) 'foreign.json'; Save-CoverageFixture $f
        (Read-CoverageFixture $f).covered | Should -BeFalse
    }
    It 'rejects traversal source paths without consulting a foreign file' {
        $f = New-CoverageFixture; $f.Receipt.entries[0].relativePath = '../Module.bsl'; Save-CoverageFixture $f
        (Read-CoverageFixture $f).reason | Should -Be 'SOURCE_PATH_INVALID'
    }
    It 'rejects incomplete filtered or truncated reports' {
        $f = New-CoverageFixture; $f.BslResponse.result.structuredContent.summary.truncated = $true; Save-CoverageFixture $f BslResponse
        (Read-CoverageFixture $f).covered | Should -BeFalse
        $f.BslResponse.result.structuredContent.summary.truncated = $false; $f.BslResponse.result.structuredContent.filters.line_filter_applied = $true; Save-CoverageFixture $f BslResponse
        (Read-CoverageFixture $f).covered | Should -BeFalse
    }
    It 'binds actual analyzer identity and matching RPC result id' {
        $f = New-CoverageFixture; $f.Receipt.entries[0].checker.versionOrId = 'other-version'; Save-CoverageFixture $f
        (Read-CoverageFixture $f).covered | Should -BeFalse
        $f.Receipt.entries[0].checker.versionOrId = '0.2.81'; $f.BslResponse.id = 99; Save-CoverageFixture $f BslResponse
        (Read-CoverageFixture $f).covered | Should -BeFalse
    }
    It 'requires explicit quick-fix triage rather than generic full-cycle evidence' {
        $f = New-CoverageFixture; $f.Receipt.taskPath = 'full-cycle'; Save-CoverageFixture $f
        (Read-CoverageFixture $f).reason | Should -Be 'EVIDENCE_TASK_PATH_UNSUPPORTED'
    }
    It 'rejects a matching path-only remote result without actual input byte binding' {
        $f = New-CoverageFixture
        $f.BslRequest.params.name = 'syntaxcheck_file'
        $f.BslRequest.params.arguments = @{ file_path = $f.Files[0]; lines = '' }
        $f.Receipt.entries[0].checker.capability = 'syntaxcheck_file'
        $f.BslResponse.result.structuredContent.provenance.tool = 'syntaxcheck_file'
        $f.BslResponse.result.structuredContent.request_rewrite = @{ applied = $false; requested = @{ file_path = $f.Files[0] }; used = @{ file_path = $f.Files[0] }; changed_by = @() }
        Save-CoverageFixture $f BslRequest; Save-CoverageFixture $f BslResponse
        $r = Read-CoverageFixture $f
        $r.covered | Should -BeFalse; $r.reason | Should -Be 'CHECKER_RESULT_UNUSABLE'
        $f.BslRequest.params.arguments.file_path = $f.Files[1]; Save-CoverageFixture $f BslRequest
        (Read-CoverageFixture $f).reason | Should -Be 'REQUEST_INPUT_MISMATCH'
    }
    It 'rejects a code fragment even when its saved request hash is updated' {
        $f = New-CoverageFixture
        $f.BslRequest.params.arguments.code = 'Процедура Проверить() Экспорт'
        Save-CoverageFixture $f BslRequest
        $r = Read-CoverageFixture $f
        $r.covered | Should -BeFalse; $r.reason | Should -Be 'REQUEST_INPUT_MISMATCH'
    }
    It 'rejects a rewritten result and nonempty rewrite attribution' {
        $f = New-CoverageFixture; $f.BslResponse.result.structuredContent.request_rewrite.applied = $true
        Save-CoverageFixture $f BslResponse
        (Read-CoverageFixture $f).covered | Should -BeFalse
        $f.BslResponse.result.structuredContent.request_rewrite.applied = $false
        $f.BslResponse.result.structuredContent.request_rewrite.changed_by = @('plugin')
        Save-CoverageFixture $f BslResponse
        (Read-CoverageFixture $f).covered | Should -BeFalse
    }
    It 'binds both actual code descriptors and complete diagnostic counts without inventing a full digest' {
        foreach ($side in @('requested', 'used')) {
            foreach ($field in @('sha256', 'chars', 'lines', 'file_name', 'invisible_file_name')) {
                $f = New-CoverageFixture; $descriptor = $f.BslResponse.result.structuredContent.request_rewrite[$side]
                if ($field -eq 'sha256') { $descriptor.code.sha256 = '0' * 64 }
                elseif ($field -eq 'file_name') { $descriptor.file_name = 'Другой.bsl' }
                elseif ($field -eq 'invisible_file_name') { $descriptor.file_name = [string][char]0xFEFF + 'Module.bsl' }
                else { $descriptor.code[$field]++ }
                Save-CoverageFixture $f BslResponse
                $r = Read-CoverageFixture $f
                $r.covered | Should -BeFalse; $r.reason | Should -Be 'CHECKER_RESULT_UNUSABLE'
            }
        }
        $f = New-CoverageFixture; $f.BslResponse.result.structuredContent.summary.total = 1
        Save-CoverageFixture $f BslResponse
        (Read-CoverageFixture $f).covered | Should -BeFalse
        $f.BslResponse.result.structuredContent.summary.total = 0
        $f.BslResponse.result.structuredContent.filters.plugins_applied = $true
        Save-CoverageFixture $f BslResponse
        (Read-CoverageFixture $f).covered | Should -BeFalse
        $f = New-CoverageFixture
        $f.BslResponse.result.structuredContent.diagnostics = @(@{ severity = 'Hint'; code = 'CodeOutOfRegion'; file = ([string][char]0xFEFF + 'Module.bsl') })
        $f.BslResponse.result.structuredContent.summary.total = 1; $f.BslResponse.result.structuredContent.summary.returned = 1
        Save-CoverageFixture $f BslResponse
        (Read-CoverageFixture $f).covered | Should -BeFalse
    }
    It 'removes only the actual UTF8 BOM and preserves another leading source character' {
        $f = New-CoverageFixture
        $path = Join-Path $f.SourceRoot $f.Files[0]
        $body = [string][char]0xFEFF + $f.BslRequest.params.arguments.code
        [IO.File]::WriteAllText($path, $body, [Text.UTF8Encoding]::new($true))
        $f.Receipt.entries[0].inputSha256 = Get-ItlPlatformEvidenceHash $path
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($body)))).Replace('-', '').ToLowerInvariant().Substring(0, 16) } finally { $sha.Dispose() }
        foreach ($side in @('requested','used')) { $f.BslResponse.result.structuredContent.request_rewrite[$side].code.chars++; $f.BslResponse.result.structuredContent.request_rewrite[$side].code.sha256 = $hash }
        # Even a current result descriptor cannot excuse a different saved request.
        Save-CoverageFixture $f BslResponse
        (Read-CoverageFixture $f).reason | Should -Be 'REQUEST_INPUT_MISMATCH'
        $f.BslRequest.params.arguments.code = $body; Save-CoverageFixture $f BslRequest
        (Read-CoverageFixture $f).covered | Should -BeTrue
        $xmlPath = Join-Path $f.SourceRoot $f.Files[1]
        $xmlBody = [string][char]0xFEFF + $f.XmlRequest.arguments.xml_content
        [IO.File]::WriteAllText($xmlPath, $xmlBody, [Text.UTF8Encoding]::new($true))
        $f.Receipt.entries[1].inputSha256 = Get-ItlPlatformEvidenceHash $xmlPath; Save-CoverageFixture $f
        (Read-CoverageFixture $f).reason | Should -Be 'REQUEST_INPUT_MISMATCH'
        $f.XmlRequest.arguments.xml_content = $xmlBody; Save-CoverageFixture $f XmlRequest
        (Read-CoverageFixture $f).covered | Should -BeTrue
    }
    It 'rejects invalid UTF8 source bytes even after the declared raw source hash is updated' {
        $f = New-CoverageFixture
        $path = Join-Path $f.SourceRoot $f.Files[0]
        [IO.File]::WriteAllBytes($path, [byte[]](0xEF,0xBB,0xBF,0xC3,0x28))
        $f.Receipt.entries[0].inputSha256 = Get-ItlPlatformEvidenceHash $path; Save-CoverageFixture $f
        (Read-CoverageFixture $f).covered | Should -BeFalse
    }
    It 'honors optional exact static infobase binding without contacting it' {
        $f = New-CoverageFixture
        $args = @{ EvidencePath = $f.EvidencePath; SourceRoot = $f.SourceRoot; SourceFingerprint = $f.Fingerprint; Files = $f.Files; ProjectRoot = $f.ProjectRoot; InfoBaseKind = 'file'; InfoBasePath = $f.Receipt.infoBasePath }
        (Test-ItlPlatformSourceCoverage @args).covered | Should -BeTrue
        $args.InfoBasePath = 'D:\Другая ИБ'; (Test-ItlPlatformSourceCoverage @args).covered | Should -BeFalse
    }
}
