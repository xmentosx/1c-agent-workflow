Describe "1C workflow parser docs and budget checks" {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        $RepoRoot = $context.RepoRoot
        $HelperPath = $context.HelperPath
        $HelperModulePaths = $context.HelperModulePaths
        $LauncherPath = $context.LauncherPath
        $InstallerPath = $context.InstallerPath
        $McpHostPath = $context.McpHostPath
        $McpHostDumpPath = $context.McpHostDumpPath
        $HelperText = $context.HelperText
        $LauncherText = $context.LauncherText
        $McpHostText = $context.McpHostText
    }
    It "parses the PowerShell helper" {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($HelperPath, [ref]$tokens, [ref]$errors) | Out-Null

        @($errors).Count | Should -Be 0
    }

    It "parses helper modules" {
        $HelperModulePaths.Count | Should -BeGreaterThan 0
        foreach ($modulePath in $HelperModulePaths) {
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors) | Out-Null

            @($errors).Count | Should -Be 0
        }
    }

    It "parses the monitored window launcher" {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($LauncherPath, [ref]$tokens, [ref]$errors) | Out-Null

        @($errors).Count | Should -Be 0
    }

    It "parses the one-step workflow installer" {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($InstallerPath, [ref]$tokens, [ref]$errors) | Out-Null

        @($errors).Count | Should -Be 0
    }

    It "keeps Markdown files valid UTF-8 without mojibake markers" {
        $strictUtf8 = New-Object System.Text.UTF8Encoding $false, $true
        $mojibakePattern = "Р Сџ|Р С’|Р вЂ™|Р С™|Р Сљ|Р Сњ|Р С›|Р РЋ|Р Сћ|Р Р€|Р Р…Р ВµРЎвЂљ|РЎР‚|РЎРѓ|РЎвЂљ|Р В°|Р Вµ|Р С‘|Р С•"
        $markdownFiles = Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Filter "*.md" |
            Where-Object { $_.FullName -notmatch "\\.git\\" }

        foreach ($file in $markdownFiles) {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            { $strictUtf8.GetString($bytes) | Out-Null } | Should -Not -Throw
            $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
            $text | Should -Not -Match $mojibakePattern
        }
    }

    It 'keeps the detailed skill as a compact router and routes human documentation separately' {
        $skillText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot '.agents\skills\1c-workflow\SKILL.md')
        ([regex]::Matches($skillText, '\S+')).Count | Should -BeLessOrEqual 750
        $skillText | Should -Match 'detailed ITL workflow router'
        $skillText | Should -Match ([regex]::Escape('references/workflow.md'))
        $skillText | Should -Match ([regex]::Escape('references/init-setup.md'))
        $skillText | Should -Match ([regex]::Escape('references/mcp.md'))
        $skillText | Should -Match ([regex]::Escape('references/branch-lifecycle.md'))
        $skillText | Should -Match ([regex]::Escape('references/verification-result.md'))
        $skillText | Should -Match ([regex]::Escape('references/vanessa-tests.md'))
        $skillText | Should -Match 'human-facing'

        $humanDocPaths = @(
            'docs\itl-workflow\PROJECT-WORKFLOW.ru.md',
            'docs\itl-workflow\FEATURE-DEVELOPMENT.ru.md',
            'docs\itl-workflow\MODES-AND-SETTINGS.ru.md',
            'docs\itl-workflow\DEV-ENV-REFERENCE.ru.md'
        )
        foreach ($relativePath in $humanDocPaths) {
            (Test-Path -LiteralPath (Join-Path $RepoRoot $relativePath) -PathType Leaf) | Should -BeTrue
        }
        (Test-Path -LiteralPath (Join-Path $RepoRoot 'VANESSA-TESTS-GUIDE.ru.md')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $RepoRoot 'DEVELOPER-GUIDE.ru.md')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $RepoRoot 'DEV-BRANCH-DEVELOPMENT.ru.md')) | Should -BeFalse
    }

    It "keeps every installed ITL skill discoverable through valid frontmatter" {
        $skillRoot = Join-Path $RepoRoot ".agents\skills"
        $expectedSkillIds = @(
            "1c-workflow",
            "1c-workflow-fast",
            "itl-roctup-1c-data",
            "itl-vanessa-ui-mcp",
            "product-docs"
        ) | Sort-Object
        $actualSkillIds = @(Get-ChildItem -LiteralPath $skillRoot -Directory | Select-Object -ExpandProperty Name | Sort-Object)
        $actualSkillIds | Should -Be $expectedSkillIds

        foreach ($skillId in $expectedSkillIds) {
            $skillPath = Join-Path (Join-Path $skillRoot $skillId) "SKILL.md"
            $text = Get-Content -LiteralPath $skillPath -Raw -Encoding UTF8
            $frontmatterMatch = [regex]::Match($text, '\A---\r?\n(?<yaml>.*?)\r?\n---(?:\r?\n|\z)', [System.Text.RegularExpressions.RegexOptions]::Singleline)
            $frontmatterMatch.Success | Should -BeTrue

            $yaml = $frontmatterMatch.Groups['yaml'].Value
            $nameMatch = [regex]::Match($yaml, '(?m)^name:\s*["'']?(?<value>[^\r\n"'']+)["'']?\s*$')
            $nameMatch.Success | Should -BeTrue
            $name = $nameMatch.Groups['value'].Value.Trim()
            $name | Should -Be $skillId
            $name | Should -Match '^[a-z0-9]+(?:-[a-z0-9]+)*$'
            $name.Length | Should -BeLessOrEqual 64

            $descriptionMatch = [regex]::Match(
                $yaml,
                '(?ms)^description:\s*(?:(?:>|\|)[+-]?\s*\r?\n(?<folded>(?:[ \t]+[^\r\n]*(?:\r?\n|\z))+)|["'']?(?<inline>[^\r\n"'']+)["'']?\s*$)'
            )
            $descriptionMatch.Success | Should -BeTrue
            $description = if ($descriptionMatch.Groups['folded'].Success) {
                ($descriptionMatch.Groups['folded'].Value -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' '
            } else {
                $descriptionMatch.Groups['inline'].Value.Trim()
            }
            $description | Should -Not -BeNullOrEmpty
            $description.Length | Should -BeLessOrEqual 1024
        }
    }

    It "entrypoint token budgets stay within limits" {
        $budgets = @(
            @{ path = "AGENTS.md"; maxWords = 600; maxApproxTokens = 1000 },
            @{ path = ".agents\skills\1c-workflow\SKILL.md"; maxWords = 750; maxApproxTokens = 1500 },
            @{ path = ".agents\skills\1c-workflow-fast\SKILL.md"; maxWords = 750; maxApproxTokens = 1500 },
            @{ path = "templates\USER-RULES.append.md"; maxWords = 650; maxApproxTokens = 1160 },
            @{ path = ".agents\skills\1c-workflow\references\workflow.md"; maxWords = 900; maxApproxTokens = 1500 }
        )

        foreach ($budget in $budgets) {
            $path = Join-Path $RepoRoot $budget.path
            $text = Get-Content -Encoding UTF8 -Raw $path
            $wordCount = ([regex]::Matches($text, '\S+')).Count
            $approxTokens = [math]::Ceiling(([System.Text.Encoding]::UTF8.GetByteCount($text)) / 4)

            $wordCount | Should -BeLessOrEqual $budget.maxWords
            $approxTokens | Should -BeLessOrEqual $budget.maxApproxTokens
        }
    }

    It "keeps root AGENTS source-only and routes maintainers to canonical contracts" {
        $agentsText = Get-Content -LiteralPath (Join-Path $RepoRoot "AGENTS.md") -Raw -Encoding UTF8
        $agentsText | Should -Match "source repository"
        $agentsText | Should -Match "not installed-project guidance"
        $agentsText | Should -Match ([regex]::Escape('Never add this root `AGENTS.md` to bootstrap or `update-workflow` managed-copy lists'))
        $agentsText | Should -Match "ITL owns project bootstrap and lifecycle"
        $agentsText | Should -Match ([regex]::Escape('controlled `ai_rules_1c` fork owns'))
        $agentsText | Should -Match ([regex]::Escape("scripts/check.ps1 -Mode Fast"))
        $agentsText | Should -Match ([regex]::Escape("scripts/check.ps1 -Mode Full"))
        $agentsText | Should -Match ([regex]::Escape('fresh passed `/itl-check`'))
        foreach ($relativePath in @(
            ".agents/skills/1c-workflow/SKILL.md",
            "AGENT-INSTALL.md",
            "docs/ai-rules-fork-upgrades.md",
            "docs/local-quality-gate.md",
            "docs/release-checklist.md"
        )) {
            Test-Path -LiteralPath (Join-Path $RepoRoot $relativePath) -PathType Leaf | Should -BeTrue
        }
    }

    It "bounds source maintenance checks, skill activation, and exploration" {
        $agentsText = Get-Content -LiteralPath (Join-Path $RepoRoot "AGENTS.md") -Raw -Encoding UTF8

        $agentsText | Should -Match 'Read-only source maintenance.*does not run `Fast`, `Full`, or `Release`'
        $agentsText | Should -Match 'During edits run only tests that directly cover the change'
        $agentsText | Should -Match 'Mode Fast` once unless `Full` is next'
        $agentsText | Should -Match 'Final delivery does not justify a gate'
        $agentsText | Should -Match 'never run `Fast` immediately before `Full`'
        $agentsText | Should -Match 'Mode Full` once on the final tree only before a PR'
        $agentsText | Should -Match 'Do not activate them for source-repository maintenance'
        $agentsText | Should -Match 'separate installed project whose root the user identifies'
        $agentsText | Should -Match 'targeted `rg`.*one matching contract or reference'
        $agentsText | Should -Match 'Widen one layer only for a concrete gap'
        $agentsText | Should -Match 'Browse or use MCP only when external or current state is required'

        foreach ($skillId in @('1c-workflow', '1c-workflow-fast')) {
            $skillText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\$skillId\SKILL.md") -Raw -Encoding UTF8
            $skillText | Should -Match 'description:.*installed ITL 1C projects'
            $skillText | Should -Match 'Never use for development, review, tests, or docs of the 1c-agent-workflow source repository'
        }
    }

    It "agent guidance references stay resolvable" {
        $workflowIndexText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\workflow.md")
        foreach ($topic in @("init-setup.md", "mcp.md", "branch-lifecycle.md", "verification-result.md")) {
            $workflowIndexText | Should -Match ([regex]::Escape($topic))
        }
        $workflowIndexText | Should -Match "Open only the matching topic file"

        $userRulesText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\USER-RULES.append.md")
        $userRulesText | Should -Match "Search hygiene"
        $userRulesText | Should -Match ([regex]::Escape(".agent-1c/runs/"))
        $userRulesText | Should -Match ([regex]::Escape("build/test-results/"))

        $installedSkillIds = @("1c-workflow", "1c-workflow-fast", "product-docs", "itl-roctup-1c-data", "itl-vanessa-ui-mcp")
        $skillReferences = [regex]::Matches($userRulesText, '\.agents/skills/([^/]+)/SKILL\.md') | ForEach-Object { $_.Groups[1].Value }
        foreach ($skillId in $skillReferences) {
            $installedSkillIds | Should -Contain $skillId
        }
    }

    It "keeps README as a compact source-repository entrypoint" {
        $readmeText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "README.md")
        ([regex]::Matches($readmeText, '\S+')).Count | Should -BeLessOrEqual 350
        $firstSection = [regex]::Match($readmeText, '(?m)^## (?<title>[^\r\n]+)\r?$')
        $firstSection.Success | Should -BeTrue
        $firstSection.Groups['title'].Value | Should -Be 'Быстрый старт'
        $readmeText | Should -Match ([regex]::Escape('https://raw.githubusercontent.com/xmentosx/1c-agent-workflow/master/AGENT-INSTALL.md'))
        foreach ($client in @('Codex', 'Kilo Code', 'Claude Code', 'Cursor', 'OpenCode')) {
            $readmeText | Should -Match ([regex]::Escape($client))
        }
        foreach ($forbidden in @('VANESSA-TESTS-GUIDE', 'advanced-actions.md', '.agents/skills/1c-workflow/references/', '/itl-check')) {
            $readmeText | Should -Not -Match ([regex]::Escape($forbidden))
        }
        foreach ($relativePath in @(
            'docs/itl-workflow/PROJECT-WORKFLOW.ru.md',
            'docs/itl-workflow/FEATURE-DEVELOPMENT.ru.md',
            'docs/itl-workflow/MODES-AND-SETTINGS.ru.md',
            'docs/itl-workflow/DEV-ENV-REFERENCE.ru.md'
        )) {
            $readmeText | Should -Match ([regex]::Escape($relativePath))
            (Test-Path -LiteralPath (Join-Path $RepoRoot ($relativePath -replace '/', '\'))) | Should -BeTrue
        }
    }

    It "documents every active dev env key and the user-facing mode defaults" {
        $envTemplateText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot 'templates\dev.env.example')
        $envReferenceText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot 'docs\itl-workflow\DEV-ENV-REFERENCE.ru.md')
        $modesText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot 'docs\itl-workflow\MODES-AND-SETTINGS.ru.md')
        $keys = [regex]::Matches($envTemplateText, '(?m)^(?:#\s*)?(?<key>[A-Z][A-Z0-9_]*)=') | ForEach-Object { $_.Groups['key'].Value } | Select-Object -Unique
        foreach ($key in $keys) {
            $envReferenceText | Should -Match ([regex]::Escape("``$key``"))
        }
        $envTemplateText | Should -Match '(?m)^DEBUG_FAST_PATH=standard\r?$'
        $envTemplateText | Should -Match '(?m)^CAVEMAN=on\r?$'
        $envTemplateText | Should -Match '(?m)^ITL_ROUTINE_MODE=off\r?$'
        foreach ($marker in @(
            'VERIFICATION_DEPTH=full', 'UI_TESTING=manual', 'ORCHESTRATION=standard',
            'CAVEMAN=on', 'DEPENDENCY_MODE=fresh', 'VERIFICATION_POLICY=warn',
            '/litemode', '/itl-litemode', 'rtk', 'SUBAGENT_MODEL_CODING', 'ITL_ROUTINE_MODE=off'
        )) {
            $modesText | Should -Match ([regex]::Escape($marker))
        }
    }

    It "keeps user-documentation links local and resolvable" {
        $docPaths = @(
            'README.md',
            'docs\itl-workflow\PROJECT-WORKFLOW.ru.md',
            'docs\itl-workflow\FEATURE-DEVELOPMENT.ru.md',
            'docs\itl-workflow\MODES-AND-SETTINGS.ru.md',
            'docs\itl-workflow\DEV-ENV-REFERENCE.ru.md'
        )
        foreach ($relativePath in $docPaths) {
            $path = Join-Path $RepoRoot $relativePath
            $text = Get-Content -Encoding UTF8 -Raw $path
            $text | Should -Not -Match ([regex]::Escape('.agents/skills/'))
            foreach ($match in [regex]::Matches($text, '\[[^\]]+\]\((?<target>[^)#]+)(?:#[^)]*)?\)')) {
                $target = $match.Groups['target'].Value
                if ($target -match '^[a-z]+:' -or $target.StartsWith('#')) { continue }
                $resolved = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $path) ($target -replace '/', '\')))
                (Test-Path -LiteralPath $resolved -PathType Leaf) | Should -BeTrue -Because "$relativePath links to $target"
            }
        }
    }

    It 'keeps the local gate output under ignored build test-results path' {
        $checkText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot 'scripts\check.ps1')
        $testScriptText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot 'scripts\test.ps1')
        Test-Path -LiteralPath (Join-Path $RepoRoot '.github\workflows\ci.yml') | Should -BeFalse
        $checkText | Should -Match ([regex]::Escape('build\test-results\local'))
        $checkText | Should -Match 'New-PesterConfiguration'
        $checkText | Should -Match 'TestResult\.OutputPath'
        $testScriptText | Should -Match 'New-PesterConfiguration'
        $testScriptText | Should -Match 'TestResult\.OutputPath'

        $gitignoreText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot '.gitignore')
        $templateIgnoreText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot 'templates\gitignore.append')
        $gitignoreText | Should -Match '(?m)^testResults\.xml\r?$'
        $templateIgnoreText | Should -Match '(?m)^testResults\.xml\r?$'
        $templateIgnoreText | Should -Match 'build/test-results/'
    }

    It "has context-specific Kilo command templates for the public surface" {
        $templateRoot = Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates"
        $expected = @{
            common = @("itl.md.template", "itl-litemode.md.template", "itl-status.md.template")
            master = @("itl-new-config-branch.md.template", "itl-new-extension-branch.md.template", "itl-switch-client.md.template", "itl-update-workflow.md.template")
            dev = @("itl-check.md.template", "itl-refresh.md.template", "itl-result.md.template", "itl-verify-fix.md.template")
        }

        foreach ($setName in $expected.Keys) {
            $setPath = Join-Path $templateRoot $setName
            (Test-Path -LiteralPath $setPath -PathType Container) | Should -Be $true
            $actual = @(Get-ChildItem -LiteralPath $setPath -File -Filter "itl*.md.template" | Sort-Object Name | Select-Object -ExpandProperty Name)
            $actual | Should -Be @($expected[$setName] | Sort-Object)
        }

        @(Get-ChildItem -LiteralPath $templateRoot -Recurse -File -Filter "itl*.md" -ErrorAction SilentlyContinue).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $templateRoot -Recurse -File -Filter "opsx*.md" -ErrorAction SilentlyContinue).Count | Should -Be 0
        @(& git -C $RepoRoot ls-files -- ".kilo/commands/itl*.md").Count | Should -Be 0
    }

    It "uses only helper actions that are declared in the Action ValidateSet" {
        $match = [regex]::Match($HelperText, '(?s)\[ValidateSet\((.*?)\)\]\s*\[string\]\$Action')
        $match.Success | Should -Be $true
        $quote = [string]([char]34)
        $actionPattern = [regex]::Escape($quote) + "(.+?)" + [regex]::Escape($quote)
        $allowedActions = @([regex]::Matches($match.Groups[1].Value, $actionPattern) | ForEach-Object { $_.Groups[1].Value })

        $wrapperFiles = Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates") -Recurse -File -Filter "itl*.md.template"
        foreach ($file in $wrapperFiles) {
            $text = Get-Content -Encoding UTF8 -Raw $file.FullName
            $actionMatch = [regex]::Match($text, "-Action\s+(\S+)")
            if ($actionMatch.Success) {
                ($allowedActions -contains $actionMatch.Groups[1].Value) | Should -Be $true
            }
        }
    }

    It "guards context-specific lifecycle actions in the helper" {
        $HelperText | Should -Match "function Assert-MasterWorktreeContext"
        $HelperText | Should -Match "function Assert-DevelopmentBranchWorktreeContext"
        $HelperText | Should -Match "(?s)function New-DevBranchCore.*Assert-MasterWorktreeContext"

        foreach ($functionName in @(
            "Update-DevBranchBase",
            "Refresh-DevBranch",
            "Export-DevBranchResult",
            "Close-DevBranch",
            "Set-DevBranchExtension",
            "Dump-DevBranchExtension"
        )) {
            $guardPattern = '(?s)function ' + [regex]::Escape($functionName) + '.*Assert-DevelopmentBranchWorktreeContext'
            $HelperText | Should -Match $guardPattern
        }
    }

    It "shows existing OpenSpec commands only in the dev ITL lifecycle panel" {
        $masterStart = $HelperText.IndexOf('if ($surface -eq "master")')
        $devStart = $HelperText.IndexOf('} elseif ($surface -eq "dev")', $masterStart)
        $unknownStart = $HelperText.IndexOf('Write-Host "  Open the master worktree to create branches', $devStart)
        $masterStart | Should -BeGreaterThan -1
        $devStart | Should -BeGreaterThan $masterStart
        $unknownStart | Should -BeGreaterThan $devStart

        $masterBlock = $HelperText.Substring($masterStart, $devStart - $masterStart)
        $devBlock = $HelperText.Substring($devStart, $unknownStart - $devStart)
        foreach ($command in @("/opsx-propose", "/opsx-apply", "/opsx-archive", "/opsx-explore")) {
            $devBlock | Should -Match ([regex]::Escape($command))
            $masterBlock | Should -Not -Match ([regex]::Escape($command))
        }

        $devBlock | Should -Match "OpenSpec"
        $devBlock | Should -Match "Optional"
        $devBlock | Should -Match "proposal"
        $devBlock | Should -Match "choose development mode"
        $devBlock | Should -Match "Checkable changes"
    }

    It "keeps additional helper actions grouped without adding visible slash commands" {
        $HelperText | Should -Match "Additional helper actions:"
        foreach ($group in @("ROCTUP MCP", "vibecoding1c MCP", "Vanessa UI MCP", "Extension branches", "Maintenance/recovery")) {
            $HelperText | Should -Match ([regex]::Escape($group))
        }

        foreach ($hiddenCommand in @("/itl-vibecoding1c-mcp", "/itl-vanessa-mcp", "/itl-set-extension", "/itl-close")) {
            $HelperText | Should -Not -Match ([regex]::Escape($hiddenCommand))
        }
    }

    It "keeps the common /itl wrapper as a structured helper panel" {
        $wrapperPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\common\itl.md.template"
        $wrapperText = Get-Content -Encoding UTF8 -Raw $wrapperPath

        $wrapperText | Should -Match "-Action\s+help"
        $wrapperText | Should -Match "helper stdout verbatim"
        $wrapperText | Should -Match "Do not summarize"
        $wrapperText | Should -Match "Additional helper actions:"
        $wrapperText | Should -Match "Lifecycle:"
        $wrapperText | Should -Not -Match "Lifecycle-РґРµР№СЃС‚РІРёСЏ РЅРµ РІС‹РїРѕР»РЅСЏР»РёСЃСЊ"
    }

    It "tells Kilo rules to keep /itl as a verbatim process panel" {
        $rulesTemplateText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\USER-RULES.append.md")

        $rulesTemplateText | Should -Match 'For Kilo `/itl`'
        $rulesTemplateText | Should -Match "stdout verbatim"
        $rulesTemplateText | Should -Match "Additional helper actions:"
        $rulesTemplateText | Should -Match "merge OpenSpec"
        $rulesTemplateText | Should -Match "no lifecycle actions executed"
    }

    It "recommends choosing development mode for a fresh clean dev branch" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-help-clean-dev-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Value "<Configuration />" -Encoding UTF8
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add src/cf/Configuration.xml
            & git -C $tempRoot commit -m "base config" *> $null
            & git -C $tempRoot branch -M master
            $baseCommit = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()
            & git -C $tempRoot checkout -q -b itldev/branch3

            $stateDir = Join-Path $tempRoot ".agent-1c\dev-branches"
            New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["kilocode"]}}'
            $state = [ordered]@{
                devBranchName = "branch3"
                safeDevBranchName = "branch3"
                devBranchKind = "configuration"
                devBranch = "itldev/branch3"
                devBranchInfoBasePath = (Join-Path $tempRoot ".agent-1c\infobases\dev-branches\branch3")
                mainWorktreePath = $tempRoot
                worktreePath = $tempRoot
                createdFromCommit = $baseCommit
            }
            Set-Content -LiteralPath (Join-Path $stateDir "branch3.json") -Encoding UTF8 -Value (($state | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

            $openSpecDir = Join-Path $tempRoot ".kilocode\workflows"
            New-Item -ItemType Directory -Force -Path $openSpecDir | Out-Null
            $openSpecFiles = [ordered]@{}
            foreach ($command in @("opsx-propose", "opsx-explore", "opsx-apply", "opsx-archive")) {
                $relativePath = ".kilocode/workflows/$command.md"
                $targetPath = Join-Path $tempRoot $relativePath
                Set-Content -LiteralPath $targetPath -Encoding UTF8 -Value $command
                $openSpecFiles[$relativePath] = [ordered]@{ source = "content/openspec-bundle/kilocode/$relativePath" }
            }
            $aiRulesManifest = [ordered]@{
                tools = @("kilocode")
                files = $openSpecFiles
            }
            Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Encoding UTF8 -Value (($aiRulesManifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action help 2>&1
            $LASTEXITCODE | Should -Be 0
            $text = ($output | Out-String)

            $text | Should -Match "Checkable changes: False"
            $text | Should -Match "Recommended next step: choose development mode: quick-fix, /opsx-explore, or /opsx-propose"
            foreach ($command in @("/opsx-propose", "/opsx-explore", "/opsx-apply", "/opsx-archive")) {
                $text | Should -Match ([regex]::Escape($command))
            }
            $text | Should -Not -Match "Kilo OpenSpec commands are unavailable"
            $text | Should -Not -Match "Recommended next step: /itl-check"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "recommends /itl-check when a dev branch has checkable changes" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-help-changed-dev-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Value "<Configuration />" -Encoding UTF8
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add src/cf/Configuration.xml
            & git -C $tempRoot commit -m "base config" *> $null
            & git -C $tempRoot branch -M master
            $baseCommit = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()
            & git -C $tempRoot checkout -q -b itldev/branch3

            $stateDir = Join-Path $tempRoot ".agent-1c\dev-branches"
            New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["kilocode"]}}'
            $state = [ordered]@{
                devBranchName = "branch3"
                safeDevBranchName = "branch3"
                devBranchKind = "configuration"
                devBranch = "itldev/branch3"
                devBranchInfoBasePath = (Join-Path $tempRoot ".agent-1c\infobases\dev-branches\branch3")
                mainWorktreePath = $tempRoot
                worktreePath = $tempRoot
                createdFromCommit = $baseCommit
            }
            Set-Content -LiteralPath (Join-Path $stateDir "branch3.json") -Encoding UTF8 -Value (($state | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Value "<Configuration changed=`"true`" />" -Encoding UTF8

            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action help 2>&1
            $LASTEXITCODE | Should -Be 0
            $text = ($output | Out-String)

            $text | Should -Match "Checkable changes: True"
            $text | Should -Match "Recommended next step: /itl-check"
            $text | Should -Match "Active-client OpenSpec surface is unavailable"
            $text | Should -Not -Match "  /opsx-propose  Start the normal OpenSpec flow"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "wires the post-change check action through helper, docs, and Kilo wrapper" {
        $HelperText | Should -Match ([regex]::Escape('"check-dev-branch"'))
        $HelperText | Should -Match "function Check-DevBranch"
        $HelperText | Should -Match "function Invoke-DevBranchCheck"
        $HelperText | Should -Match "function Verify-DevBranch"

        $wrapperPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-check.md.template"
        (Test-Path -LiteralPath $wrapperPath -PathType Leaf) | Should -Be $true
        $wrapperText = Get-Content -Encoding UTF8 -Raw $wrapperPath
        $wrapperText | Should -Match "-Action\s+check-dev-branch"
        $wrapperText | Should -Match ([regex]::Escape('Do not run a separate base update first'))
        $wrapperText | Should -Not -Match "three failed runs"

        $recoveryPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-verify-fix.md.template"
        $recoveryText = Get-Content -Encoding UTF8 -Raw $recoveryPath
        $recoveryText | Should -Match "reuse it unchanged"
        $recoveryText | Should -Match "do not add or edit a test merely because this command was invoked"
        $recoveryText | Should -Match "-Action\s+check-dev-branch"
        $recoveryText | Should -Match "three failed runs"

        $menuText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\workflow.md")
        $menuText | Should -Match ([regex]::Escape("/itl-check"))
        $menuText | Should -Match ([regex]::Escape("/itl-verify-fix"))
        $menuText | Should -Match "itldev/\*"

        foreach ($relativePath in @(
            "docs\itl-workflow\PROJECT-WORKFLOW.ru.md",
            "docs\itl-workflow\FEATURE-DEVELOPMENT.ru.md",
            ".agents\skills\1c-workflow\references\workflow.md",
            ".agents\skills\1c-workflow\references\dev-branch-development.md",
            ".agents\skills\1c-workflow-fast\SKILL.md",
            "templates\USER-RULES.append.md"
        )) {
            $text = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot $relativePath)
            $text | Should -Match ([regex]::Escape("/itl-check"))
        }
    }

    It "requires mode-aware executable evidence without false fresh completion" {
        $userRulesText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\USER-RULES.append.md")

        foreach ($marker in @(
            "mechanically classify",
            "QUICKFIX_MAX_LINES",
            "/itl-check",
            "OpenSpec explore/propose/apply",
            "quick-fix",
            "Context Sources",
            "test-plan.md",
            "ITL_VANESSA_TESTING",
            "ITL_CHECK_EVENT_LOG",
            "auto|manual|off",
            "partial/skipped",
            "verificationPolicy=block",
            "implemented; executable verification skipped"
        )) {
            $userRulesText | Should -Match ([regex]::Escape($marker))
        }

        $userRulesText | Should -Match "skipped component.*never a normal fresh pass"
        $userRulesText | Should -Match '`off` runs only when the user explicitly requests that named component'
        $userRulesText | Should -Match 'never `verified`, `ready`, or `done`'
        $userRulesText | Should -Match "USER-RULES.md.*above.*LLM-RULES.md"
        $userRulesText | Should -Match "rtk rewrite.*lifecycle helper.*observed rewrite.*restart"
        $userRulesText | Should -Not -Match "opsx\*\.md"
    }

    It "documents the detailed development completion gate in the agent reference" {
        $text = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\dev-branch-development.md")

            foreach ($marker in @(
                "src/cf",
                "src/cfe",
                "tests/features",
                "references/vanessa-tests.md",
                "/itl-check",
                "fresh passed",
                "/opsx-apply",
                "quick-fix",
                "hybrid cadence",
                "focused Vanessa scenario",
                "pending verification",
                "test-report.md"
            )) {
                $text | Should -Match ([regex]::Escape($marker))
            }

            $text | Should -Match "quick-fix.*Vanessa regression test"
            $text | Should -Match "Второй сценарий.*только.*отдельной значимой границы"
            $text | Should -Match "OpenSpec.*hybrid cadence"
            $text | Should -Match "2-3 Vanessa"
            $text | Should -Match "четвертая проверка.*обоснован"
            $text | Should -Match "git branch --show-current.*не каталог"
            $text | Should -Match "exportPath.*extensionsPath"
            $text | Should -Match "master.*branch-safety blocker"
            $text | Should -Not -Match "2-4 Vanessa"
    }

    It "keeps the human feature guide outcome-focused and complete" {
        $text = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "docs\itl-workflow\FEATURE-DEVELOPMENT.ru.md")
        foreach ($marker in @(
            "/itl-check", "/itl-verify-fix", "fresh passed", "quick-fix",
            "/opsx-explore", "/opsx-propose", "/opsx-apply", "/opsx-archive",
            "focused Vanessa", "pending verification", "VERIFICATION_POLICY"
        )) {
            $text | Should -Match ([regex]::Escape($marker))
        }
        $text | Should -Not -Match ([regex]::Escape('.agents/skills/1c-workflow/references/'))
    }

    It "documents OpenSpec slash commands at the matching branch development steps" {
        foreach ($relativePath in @(
            "docs\itl-workflow\FEATURE-DEVELOPMENT.ru.md",
            ".agents\skills\1c-workflow\references\dev-branch-development.md"
        )) {
            $text = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot $relativePath)
            foreach ($command in @("/opsx-propose", "/opsx-apply", "/opsx-archive", "/opsx-explore")) {
                $text | Should -Match ([regex]::Escape($command))
            }
        }
        $agentText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\dev-branch-development.md")
        $agentText | Should -Match "/opsx-propose.*proposal"
        $agentText | Should -Match "/opsx-explore.*optional"
        $agentText | Should -Match "(?s)### 0\..*?/opsx-explore"
        $agentText | Should -Match "(?s)### 1\..*?/opsx-propose"
        $agentText | Should -Match "(?s)### 4\..*?/opsx-apply"
        $agentText | Should -Match "(?s)### 9\..*?/opsx-archive"
    }

    It "ignores local runtime branch state in all gitignore surfaces" {
        $requiredPath = ".agent-1c/dev-branches/"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape($requiredPath))
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\gitignore.append")) | Should -Match ([regex]::Escape($requiredPath))
        $HelperText | Should -Match ([regex]::Escape($requiredPath))

        $baselinePath = ".agent-1c/event-log-baselines/"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape($baselinePath))
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\gitignore.append")) | Should -Match ([regex]::Escape($baselinePath))
        $HelperText | Should -Match ([regex]::Escape($baselinePath))

        $cachePath = ".agent-1c/event-log-signature-cache/"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape($cachePath))
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\gitignore.append")) | Should -Match ([regex]::Escape($cachePath))
        $HelperText | Should -Match ([regex]::Escape($cachePath))
    }

    It "ignores monitored run status and log artifacts" {
        $requiredPath = ".agent-1c/runs/"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape($requiredPath))
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\gitignore.append")) | Should -Match ([regex]::Escape($requiredPath))
        $HelperText | Should -Match ([regex]::Escape($requiredPath))
        $LauncherText | Should -Match ([regex]::Escape(".agent-1c\runs"))
    }

    It "ignores lifecycle operation locks in every package surface" {
        $requiredPath = ".agent-1c/locks/"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape($requiredPath))
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\gitignore.append")) | Should -Match ([regex]::Escape($requiredPath))
        $HelperText | Should -Match ([regex]::Escape($requiredPath))
    }

    It "ignores local agent client and MCP runtime state without blocking branch creation" {
        $requiredPaths = @(
            ".agent-1c/mcp/",
            ".agent-1c/tools/data-mcp/",
            ".agent-1c/tools/roctup-mcp-toolkit/",
            "build/data-mcp-tools-loader/",
            ".codex/config.toml",
            ".kilo/kilo.json",
            ".kilo/kilo.jsonc"
        )
        foreach ($requiredPath in $requiredPaths) {
            (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape($requiredPath))
            (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\gitignore.append")) | Should -Match ([regex]::Escape($requiredPath))
            $HelperText | Should -Match ([regex]::Escape($requiredPath))
        }
        $HelperText | Should -Match "Test-IgnorableLocalGitStatusLine"
    }
}
