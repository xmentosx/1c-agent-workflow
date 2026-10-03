BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $libRoot = Join-Path $repoRoot '.agents/skills/1c-workflow/scripts/lib'
    $functions = @{
        'agent-1c.lifecycle.ps1' = @('Test-MainConfigurationGate6Required', 'Get-PlatformGate6MetadataOwner', 'Get-ConfigRepositoryMetadataCollectionLabel', 'Get-GitPathList', 'Get-GitPathListAt')
        'agent-1c.core.ps1' = @('Get-EnvValue', 'ConvertTo-NativeCommandLineArgument', 'Join-NativeCommandLineArguments')
        'agent-1c.vanessa.ps1' = @('Invoke-ItlNativeProcessCapture')
        'agent-1c.runtime-values.ps1' = @('Get-StateValue')
    }
    foreach ($name in $functions.Keys) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $libRoot $name), [ref]$tokens, [ref]$errors)
        foreach ($functionName in $functions[$name]) {
            $definition = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object { $_.Name -ceq $functionName } | Select-Object -First 1
            if ($null -eq $definition) { throw "Missing real owner function: $functionName" }
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }
    . (Join-Path $libRoot 'agent-1c.platform-evidence.ps1')
    $gitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

    function Invoke-GateFixtureGit([string]$Root, [string[]]$Arguments) {
        $result = Invoke-ItlNativeProcessCapture -FilePath $gitPath -Arguments (@('-C', $Root, '-c', 'core.quotepath=false') + $Arguments) -WorkingDirectory $Root
        if ($result.exitCode -ne 0) { throw "Git fixture failed: $($result.stderr)" }
        return ([string]$result.stdout).Trim()
    }
    function Write-GateFixtureJson([string]$Path, [object]$Value) {
        [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
    }
    function Write-GateFixtureSource([string]$Path, [string]$Text) {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
        [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($true))
    }
    function Save-GateFixtureCoverage([hashtable]$Fixture) {
        $entries = @()
        $proofRoot = Join-Path $Fixture.ProjectRoot '.agent-1c/proofs'
        [void][IO.Directory]::CreateDirectory($proofRoot)
        foreach ($file in $Fixture.ChangeSet.files) {
            if ($file -notmatch '(?i)\.(bsl|xml)$' -or -not [IO.File]::Exists((Join-Path $Fixture.SourceRoot $file))) { continue }
            $index = $entries.Count
            if ($file -match '(?i)\.bsl$') {
                $capability = 'syntaxcheck_file'
                $arguments = @{ file_path = $file; lines = '' }
                $payload = @{ diagnostics = @(); summary = @{ total = 0; returned = 0; truncated = $false }
                    filters = @{ line_filter_applied = $false; severity_filter_applied = $false; suppression_applied = $false }
                    provenance = @{ tool = $capability; analyzer_version = '0.2.81'; file_metrics_scope = 'whole_file' }
                    request_rewrite = @{ applied = $false; requested = @{ file_path = $file }; used = @{ file_path = $file } } }
            } else {
                $capability = 'verify_xml'
                $text = [IO.File]::ReadAllText((Join-Path $Fixture.SourceRoot $file), [Text.UTF8Encoding]::new($false, $true))
                $arguments = @{ xml_content = $text; object_type = 'CommonModule' }
                $payload = @{ status = 'valid'; errors = @() }
            }
            # Only the checker is a fixture; all source bytes, Git trees, requests and receipt reads are real.
            $requestName = "request-$index.json"; $resultName = "result-$index.json"
            Write-GateFixtureJson (Join-Path $proofRoot $requestName) @{ name = $capability; arguments = $arguments }
            Write-GateFixtureJson (Join-Path $proofRoot $resultName) @{ isError = $false; structuredContent = $payload }
            $entries += @{ relativePath = $file; inputSha256 = (Get-ItlPlatformEvidenceHash (Join-Path $Fixture.SourceRoot $file))
                checker = @{ server = 'fixture-schema-qualified-checker'; capability = $capability; versionOrId = '0.2.81' }
                request = @{ path = $requestName; sha256 = (Get-ItlPlatformEvidenceHash (Join-Path $proofRoot $requestName)) }
                result = @{ path = $resultName; sha256 = (Get-ItlPlatformEvidenceHash (Join-Path $proofRoot $resultName)) } }
        }
        $Fixture.Receipt = @{ schemaVersion = 1; kind = 'itl-mcp-source-validation'; taskPath = 'quick-fix'
            projectRoot = $Fixture.ProjectRoot; sourceRoot = $Fixture.SourceRoot; sourceFingerprint = $Fixture.Fingerprint; entries = $entries }
        $Fixture.EvidencePath = Join-Path $proofRoot 'coverage.json'
        Write-GateFixtureJson $Fixture.EvidencePath $Fixture.Receipt
    }
    function New-GateFixture([ValidateSet('Small','Large','MultipleOwners','Deleted','BinaryOnly','UnknownBinary','GeneratedIndex')][string]$Mode = 'Small') {
        $project = Join-Path $TestDrive ('Git проект Gate 6 ' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($project)
        $source = Join-Path $project 'src/cf'
        $module = 'CommonModules/Логика/Ext/Module.bsl'; $metadata = 'CommonModules/Логика.xml'
        Write-GateFixtureSource (Join-Path $source $module) "Процедура Проверить() Экспорт`r`nКонецПроцедуры`r`n"
        Write-GateFixtureSource (Join-Path $source $metadata) "<Metadata name=`"Логика`" revision=`"1`" />`r`n"
        if ($Mode -eq 'GeneratedIndex') { Write-GateFixtureSource (Join-Path $source 'ConfigDumpInfo.xml') "<ConfigDumpInfo revision=`"1`" />`r`n" }
        if ($Mode -eq 'MultipleOwners') { Write-GateFixtureSource (Join-Path $source 'CommonModules/Другой/Ext/Module.bsl') "Процедура Другая() Экспорт`r`nКонецПроцедуры`r`n" }
        if ($Mode -in @('BinaryOnly','UnknownBinary')) { [IO.File]::WriteAllBytes((Join-Path $source 'Picture.bin'), [byte[]](0,1,2)) }
        [IO.File]::WriteAllText((Join-Path $project '.gitignore'), ".agent-1c/`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $project '.gitattributes'), "src/cf/** -text`n", [Text.UTF8Encoding]::new($false))
        [void](Invoke-GateFixtureGit $project @('init', '--quiet'))
        [void](Invoke-GateFixtureGit $project @('config', 'user.email', 'fixture@example.invalid'))
        [void](Invoke-GateFixtureGit $project @('config', 'user.name', 'Gate6 fixture'))
        [void](Invoke-GateFixtureGit $project @('add', '--all'))
        [void](Invoke-GateFixtureGit $project @('commit', '--quiet', '-m', 'before small configuration change'))
        $before = Invoke-GateFixtureGit $project @('rev-parse', 'HEAD:src/cf')
        switch ($Mode) {
            'Deleted' { [IO.File]::Delete((Join-Path $source $metadata)) }
            'Large' { Write-GateFixtureSource (Join-Path $source $module) ((@('Процедура Проверить() Экспорт') + @(1..41 | ForEach-Object { "// Изменение $_" }) + @('КонецПроцедуры')) -join "`r`n") }
            'MultipleOwners' {
                [IO.File]::AppendAllText((Join-Path $source $module), "// Первый объект`r`n", [Text.UTF8Encoding]::new($false))
                [IO.File]::AppendAllText((Join-Path $source 'CommonModules/Другой/Ext/Module.bsl'), "// Другой объект`r`n", [Text.UTF8Encoding]::new($false))
            }
            'BinaryOnly' { [IO.File]::WriteAllBytes((Join-Path $source 'Picture.bin'), [byte[]](0,3,4)) }
            default {
                [IO.File]::AppendAllText((Join-Path $source $module), "// Изменённый модуль`r`n", [Text.UTF8Encoding]::new($false))
                Write-GateFixtureSource (Join-Path $source $metadata) "<Metadata name=`"Логика`" revision=`"2`" />`r`n"
                if ($Mode -eq 'UnknownBinary') { [IO.File]::WriteAllBytes((Join-Path $source 'Picture.bin'), [byte[]](0,3,4)) }
                if ($Mode -eq 'GeneratedIndex') { Write-GateFixtureSource (Join-Path $source 'ConfigDumpInfo.xml') ((1..41 | ForEach-Object { "<Metadata index=`"$_`" />" }) -join "`r`n") }
            }
        }
        [void](Invoke-GateFixtureGit $project @('add', '--all'))
        [void](Invoke-GateFixtureGit $project @('commit', '--quiet', '-m', 'after configuration change'))
        $after = Invoke-GateFixtureGit $project @('rev-parse', 'HEAD:src/cf')
        $script:ProjectRoot = $project
        $files = @(Get-GitPathList -Arguments @('diff', '--name-only', '-z', '--no-renames', $before, $after))
        # Actual Get-ConfigLoadChangeSet excludes the generated dump index from load inputs.
        $files = @($files | Where-Object { [IO.Path]::GetFileName([string]$_) -ine 'ConfigDumpInfo.xml' })
        $fixture = @{ ProjectRoot = $project; SourceRoot = $source; Fingerprint = ('source:' + $after)
            ChangeSet = [pscustomobject]@{ files = $files; requiresFullLoad = $false; missingFiles = @($files | Where-Object { -not [IO.File]::Exists((Join-Path $source $_)) }); absoluteExportPath = $source; previousTreeObjectId = $before; currentTreeObjectId = $after } }
        Save-GateFixtureCoverage $fixture
        return $fixture
    }
    function Get-GateFixtureDecision([hashtable]$Fixture, [string]$EvidencePath = 'use-receipt') {
        $script:ProjectRoot = $Fixture.ProjectRoot
        if ($EvidencePath -eq 'use-receipt') { $EvidencePath = $Fixture.EvidencePath }
        return Test-MainConfigurationGate6Required -ChangeSet $Fixture.ChangeSet -ValidationEvidencePath $EvidencePath -SourceFingerprint $Fixture.Fingerprint
    }
}

Describe 'Conditional Gate6 for a real partial Git configuration change' {
    BeforeEach {
        $savedQuickFix = [Environment]::GetEnvironmentVariable('QUICKFIX_MAX_LINES', 'Process')
        $savedPrefixedQuickFix = [Environment]::GetEnvironmentVariable('AGENT_1C_QUICKFIX_MAX_LINES', 'Process')
        [Environment]::SetEnvironmentVariable('QUICKFIX_MAX_LINES', $null, 'Process')
        [Environment]::SetEnvironmentVariable('AGENT_1C_QUICKFIX_MAX_LINES', $null, 'Process')
    }
    AfterEach {
        [Environment]::SetEnvironmentVariable('QUICKFIX_MAX_LINES', $savedQuickFix, 'Process')
        [Environment]::SetEnvironmentVariable('AGENT_1C_QUICKFIX_MAX_LINES', $savedPrefixedQuickFix, 'Process')
    }
    It 'skips platform checks only for a small fully covered module and XML change in one owner' {
        $f = New-GateFixture
        $head = Invoke-GateFixtureGit $f.ProjectRoot @('rev-parse', 'HEAD')
        $sourceHashes = @($f.ChangeSet.files | ForEach-Object { Get-ItlPlatformEvidenceHash (Join-Path $f.SourceRoot $_) })
        (Get-GateFixtureDecision $f) | Should -BeFalse
        (Invoke-GateFixtureGit $f.ProjectRoot @('rev-parse', 'HEAD')) | Should -BeExactly $head
        (Invoke-GateFixtureGit $f.ProjectRoot @('status', '--porcelain')) | Should -BeExactly ''
        $after = @($f.ChangeSet.files | ForEach-Object { Get-ItlPlatformEvidenceHash (Join-Path $f.SourceRoot $_) })
        ($after -join ',') | Should -BeExactly ($sourceHashes -join ',')
    }
    It 'retains full checks when no operation-local evidence is supplied' {
        $f = New-GateFixture
        (Get-GateFixtureDecision $f '') | Should -BeTrue
    }
    It 'falls back after current source bytes make the checker receipt stale' {
        $f = New-GateFixture
        [IO.File]::AppendAllText((Join-Path $f.SourceRoot $f.ChangeSet.files[0]), "// После проверки`r`n", [Text.UTF8Encoding]::new($false))
        (Get-GateFixtureDecision $f) | Should -BeTrue
    }
    It 'falls back for incomplete changed-file coverage' {
        $f = New-GateFixture; $f.Receipt.entries = @($f.Receipt.entries[0])
        Write-GateFixtureJson $f.EvidencePath $f.Receipt
        (Get-GateFixtureDecision $f) | Should -BeTrue
    }
    It 'falls back for a checker failure rather than trusting a declared passed entry' {
        $f = New-GateFixture
        $entry = $f.Receipt.entries[0]
        $resultPath = Join-Path (Split-Path $f.EvidencePath -Parent) $entry.result.path
        Write-GateFixtureJson $resultPath @{ isError = $true; structuredContent = @{ passed = $true } }
        $entry.result.sha256 = Get-ItlPlatformEvidenceHash $resultPath
        Write-GateFixtureJson $f.EvidencePath $f.Receipt
        (Get-GateFixtureDecision $f) | Should -BeTrue
    }
    It 'does not exempt a full configuration load even with complete current evidence' {
        $f = New-GateFixture; $f.ChangeSet.requiresFullLoad = $true
        (Get-GateFixtureDecision $f) | Should -BeTrue
    }
    It 'requires full checks for a real deleted metadata file' {
        $f = New-GateFixture Deleted
        $f.ChangeSet.missingFiles | Should -Contain 'CommonModules/Логика.xml'
        (Get-GateFixtureDecision $f) | Should -BeTrue
    }
    It 'requires full checks for a large real diff despite complete MCP coverage' {
        $f = New-GateFixture Large
        (Test-ItlPlatformSourceCoverage -EvidencePath $f.EvidencePath -SourceRoot $f.SourceRoot -SourceFingerprint $f.Fingerprint -Files $f.ChangeSet.files -ProjectRoot $f.ProjectRoot).covered | Should -BeTrue
        (Get-GateFixtureDecision $f) | Should -BeTrue
    }
    It 'does not turn a small covered change into a full check because the generated dump index expanded' {
        $f = New-GateFixture GeneratedIndex
        $f.ChangeSet.files | Should -Not -Contain 'ConfigDumpInfo.xml'
        (Test-ItlPlatformSourceCoverage -EvidencePath $f.EvidencePath -SourceRoot $f.SourceRoot -SourceFingerprint $f.Fingerprint -Files $f.ChangeSet.files -ProjectRoot $f.ProjectRoot).covered | Should -BeTrue
        (Get-GateFixtureDecision $f) | Should -BeFalse
    }
    It 'requires full checks for two changed metadata owners despite complete MCP coverage' {
        $f = New-GateFixture MultipleOwners
        (Test-ItlPlatformSourceCoverage -EvidencePath $f.EvidencePath -SourceRoot $f.SourceRoot -SourceFingerprint $f.Fingerprint -Files $f.ChangeSet.files -ProjectRoot $f.ProjectRoot).covered | Should -BeTrue
        (Get-GateFixtureDecision $f) | Should -BeTrue
    }
    It 'honors the configured quick-fix bound and rejects unusable bound values' {
        $f = New-GateFixture
        [Environment]::SetEnvironmentVariable('QUICKFIX_MAX_LINES', '2', 'Process')
        (Get-GateFixtureDecision $f) | Should -BeTrue
        [Environment]::SetEnvironmentVariable('QUICKFIX_MAX_LINES', '3', 'Process')
        (Get-GateFixtureDecision $f) | Should -BeFalse
        [Environment]::SetEnvironmentVariable('QUICKFIX_MAX_LINES', 'not-a-number', 'Process')
        (Get-GateFixtureDecision $f) | Should -BeTrue
    }
    It 'keeps unknown and empty change sets on the platform route' {
        $f = New-GateFixture; $f.ChangeSet.files = @('<unknown-config-source>')
        (Get-GateFixtureDecision $f) | Should -BeTrue
        $f.ChangeSet.files = @()
        (Get-GateFixtureDecision $f) | Should -BeTrue
    }
    It 'falls back when a real Git tree cannot be resolved' {
        $f = New-GateFixture; $f.ChangeSet.currentTreeObjectId = 'missing-tree'
        (Get-GateFixtureDecision $f) | Should -BeTrue
    }
    It 'does not treat an unknown binary numstat as a small validated change' {
        $f = New-GateFixture UnknownBinary
        (Get-GateFixtureDecision $f) | Should -BeTrue
    }
    It 'preserves the existing binary-only route when no BSL or metadata changed' {
        $f = New-GateFixture BinaryOnly
        (Get-GateFixtureDecision $f) | Should -BeFalse
    }
}
