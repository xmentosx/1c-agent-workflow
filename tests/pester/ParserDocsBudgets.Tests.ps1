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
    It "parses the helper modules launcher and installer" {
        $parsePaths = @($HelperPath) + @($HelperModulePaths) + @($LauncherPath, $InstallerPath)
        $HelperModulePaths.Count | Should -BeGreaterThan 0
        foreach ($modulePath in $parsePaths) {
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors) | Out-Null
            @($errors).Count | Should -Be 0
        }
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
        ([regex]::Matches($skillText, '\S+')).Count | Should -BeLessOrEqual 775
        $skillText | Should -Match 'detailed ITL workflow router'
        $skillText | Should -Match ([regex]::Escape('references/workflow.md'))
        $skillText | Should -Match 'workflow\.md` only for help, an unclear request'
        $skillText | Should -Match 'Open only the matching topic'
        $skillText | Should -Match ([regex]::Escape('references/init-setup.md'))
        $skillText | Should -Match ([regex]::Escape('references/mcp.md'))
        $skillText | Should -Match ([regex]::Escape('references/branch-lifecycle.md'))
        $skillText | Should -Match ([regex]::Escape('references/verification-result.md'))
        $skillText | Should -Match ([regex]::Escape('references/vanessa-tests.md'))
        $skillText | Should -Match ([regex]::Escape('references/dev-branch-quick-fix.md'))
        $skillText | Should -Match ([regex]::Escape('references/dev-branch-direct.md'))
        $skillText | Should -Match ([regex]::Escape('references/dev-branch-openspec.md'))
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

    It "documentation budgets keep review thresholds below hard limits" {
        $budgets = @(
            @{ path = "AGENTS.md"; maxWords = 1150; reviewApproxTokens = 2000; maxApproxTokens = 2200; rationale = "source-maintainer router plus delivery, lock, component release, non-ASCII path, and byte-preserving 1C source safety contracts" },
            @{ path = ".agents\skills\1c-workflow\SKILL.md"; maxWords = 900; reviewApproxTokens = 1500; maxApproxTokens = 1800; rationale = "installed-project detailed router" },
            @{ path = ".agents\skills\1c-workflow-fast\SKILL.md"; maxWords = 800; reviewApproxTokens = 1350; maxApproxTokens = 1600; rationale = "routine helper router" },
            @{ path = "templates\USER-RULES.append.md"; maxWords = 775; reviewApproxTokens = 1200; maxApproxTokens = 1600; rationale = "always-on ITL safety overlay with explicit routine routing precedence" },
            @{ path = ".agents\skills\1c-workflow\references\workflow.md"; maxWords = 1000; reviewApproxTokens = 1600; maxApproxTokens = 1800; rationale = "on-demand command menu" },
            @{ path = ".agents\skills\1c-workflow\references\vanessa-tests.md"; maxWords = 1400; reviewApproxTokens = 2500; maxApproxTokens = 2800; rationale = "on-demand Vanessa authoring contract" },
            @{ path = ".agents\skills\1c-workflow\references\vanessa-recipes.md"; maxWords = 1100; reviewApproxTokens = 2100; maxApproxTokens = 2400; rationale = "selective worked Vanessa recipes and runtime discovery bounds" }
        )

        foreach ($budget in $budgets) {
            $budget.reviewApproxTokens | Should -BeLessThan $budget.maxApproxTokens
            $path = Join-Path $RepoRoot $budget.path
            $text = Get-Content -Encoding UTF8 -Raw $path
            $wordCount = ([regex]::Matches($text, '\S+')).Count
            $approxTokens = [math]::Ceiling(([System.Text.Encoding]::UTF8.GetByteCount($text)) / 4)

            if ($approxTokens -gt $budget.reviewApproxTokens) {
                Write-Warning ("Documentation budget review threshold exceeded for '{0}': {1} > {2} approximate tokens ({3}). This is a review signal, not permission to remove required meaning." -f $budget.path, $approxTokens, $budget.reviewApproxTokens, $budget.rationale)
            }

            $wordCount | Should -BeLessOrEqual $budget.maxWords
            $approxTokens | Should -BeLessOrEqual $budget.maxApproxTokens
        }
    }

    It "keeps root AGENTS source-only and enforces accumulated delivery defaults" {
        $agentsText = Get-Content -LiteralPath (Join-Path $RepoRoot "AGENTS.md") -Raw -Encoding UTF8
        $agentsText | Should -Match "source repository"
        $agentsText | Should -Match "not installed-project guidance"
        $agentsText | Should -Match ([regex]::Escape('Never add this root `AGENTS.md` to bootstrap or `update-workflow` managed-copy lists'))
        $qualityText = Get-Content -LiteralPath (Join-Path $RepoRoot "docs\local-quality-gate.md") -Raw -Encoding UTF8; foreach ($marker in @('timeout_ms >= 6000000', 'timeout_ms >= 7800000', 'Invoke-TestPowerShellFile', 'повторный Publish/Release блокируется')) { $qualityText | Should -Match ([regex]::Escape($marker)) }
        $agentsText | Should -Match "ITL owns project bootstrap and lifecycle"
        $agentsText | Should -Match ([regex]::Escape('controlled `ai_rules_1c` fork owns'))
        $agentsText | Should -Match ([regex]::Escape("scripts/source-delivery.ps1 -Action RegisterChange"))
        $agentsText | Should -Match ([regex]::Escape("scripts/source-delivery.ps1 -Action PublishDevelop"))
        $agentsText | Should -Match ([regex]::Escape("scripts/source-delivery.ps1 -Action PromoteRelease"))
        $agentsText | Should -Match ([regex]::Escape("scripts/source-delivery.ps1 -Action ReleaseMaster"))
        $agentsText | Should -Match ([regex]::Escape('follow the blocking policy in `docs/package-architecture.md`'))
        $architectureText = Get-Content -LiteralPath (Join-Path $RepoRoot "docs\package-architecture.md") -Raw -Encoding UTF8
        $architectureText | Should -Match ([regex]::Escape('A runtime check may block only when continuing can lose data, mutate the wrong target, violate an explicit safety boundary, or produce false success or verification evidence'))
        $architectureText | Should -Match ([regex]::Escape('Every other diagnostic discrepancy is `WARN`, not `FAIL`'))
        $architectureText | Should -Match ([regex]::Escape("ITL may duplicate one only after a reproduced cross-boundary failure"))
        $architectureText | Should -Match ([regex]::Escape("Capability checks use only the minimum prerequisites needed to perform the operation"))
        $architectureText | Should -Match ([regex]::Escape("integrity does not participate in capability detection unless exact identity is itself required for execution"))
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
        $agentsText | Should -Match 'Read-only source maintenance.*does not run `Targeted`, `Smoke`, `Full`, `Develop`, or `Release`'
        $agentsText | Should -Match 'Do not run a broad gate merely because a chat is ending'
        $agentsText | Should -Match '`Fast` is a deprecated alias for `Smoke`'
        $agentsText | Should -Match 'integrates the queue, qualifies and finalizes an installable candidate'
        $agentsText | Should -Match ([regex]::Escape('"Publish" never implies master'))
        $agentsText | Should -Match '`-RequireRelease`.*master must remain unchanged'
        $agentsText | Should -Match 'Passed `Develop` already contains exact-tree Full/static proof'
        $agentsText | Should -Match 'queue is empty and local `develop` equals `origin/develop`'
        $agentsText | Should -Match 'Do not ask which gate to run'
        $agentsText | Should -Match 'Do not activate them for source-repository maintenance'
        $agentsText | Should -Match 'separate installed project whose root the user identifies'
        $agentsText | Should -Match 'targeted `rg`.*one matching contract or reference'
        $agentsText | Should -Match 'Widen one layer only for a concrete gap'
        $agentsText | Should -Match 'Browse or use MCP only when external or current state is required'
        foreach ($field in @('developPublished=true', 'dependenciesInstallable=true', 'masterReleased=false', 'masterReleased=true')) {
            $qualityText | Should -Match ([regex]::Escape($field))
        }
        $agentsText | Should -Match 'budgets protect routing and readability'
        $agentsText | Should -Match 'Never delete, weaken, or telegraphically compress safety, verification, or behavioral contracts merely to pass a budget'
        $agentsText | Should -Match 'propose an explicit limit change with a short rationale'

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
        foreach ($client in @('Codex', 'Kilo Code', 'Claude Code', 'Cursor', 'OpenCode', 'Kimi Code', 'Qwen Code', 'Command Code', 'Cline', 'Pi')) {
            $workflowIndexText | Should -Match ([regex]::Escape($client))
        }
        $workflowIndexText | Should -Match 'capability registry'
        $workflowIndexText | Should -Match ('(?i)' + [regex]::Escape('never promise universal `/opsx*`'))

        $userRulesText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\USER-RULES.append.md")
        $userRulesText | Should -Match "Search hygiene"
        $userRulesText | Should -Match ([regex]::Escape(".agent-1c/runs/"))
        $userRulesText | Should -Match ([regex]::Escape("build/test-results/"))

        $installedSkillIds = @("1c-workflow", "1c-workflow-fast", "product-docs", "itl-roctup-1c-data", "itl-vanessa-ui-mcp")
        $skillReferences = [regex]::Matches($userRulesText, '\.agents/skills/([^/]+)/SKILL\.md') | ForEach-Object { $_.Groups[1].Value }
        foreach ($skillId in $skillReferences) {
            $installedSkillIds | Should -Contain $skillId
        }
        foreach ($marker in @(
            'shared across projects, not project memory',
            'verified, non-confidential facts safe and useful across unrelated projects',
            'project-specific facts and corrections in that project''s `memory.md`',
            'correction capture never requires shared `remember`',
            'Do not run shared `recall` by default',
            'verify results against the current project',
            '`templatesearch` is unaffected'
        )) {
            $userRulesText | Should -Match ([regex]::Escape($marker))
        }
    }

    It "routes explicit routines before the fast and detailed workflow routers" {
        $workflowSkill = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\SKILL.md") -Raw -Encoding UTF8
        $fastSkill = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow-fast\SKILL.md") -Raw -Encoding UTF8
        $agentsTemplate = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\AGENTS.append.md") -Raw -Encoding UTF8
        $userRulesTemplate = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\USER-RULES.append.md") -Raw -Encoding UTF8

        foreach ($text in @($workflowSkill, $fastSkill, $agentsTemplate, $userRulesTemplate)) {
            $text | Should -Match 'Explicit generated `itl-\*` skills run alone'
        }
        $workflowSkill | Should -Match 'description:.*Route non-routine work.*routine status.*1c-workflow-fast.*explicit generated itl-\* skill'
        $fastSkill | Should -Match 'description:.*Route routine natural-language requests.*Explicit generated itl-\* skills run alone'
        $fastSkill | Should -Match 'requiredAction=/itl-verify-fix.*explicit `itl-verify-fix` wrapper.*If that surface is unavailable.*full `1c-workflow`'
        $agentsTemplate | Should -Match 'routine natural-language lifecycle requests.*use only.*1c-workflow-fast/SKILL.md'
        $agentsTemplate | Should -Match '1c-workflow/SKILL.md` plus one matching reference only'
        $userRulesTemplate | Should -Match 'other routine requests use only `1c-workflow-fast`'
        $userRulesTemplate | Should -Match 'helper-directed recovery without an explicit wrapper'
    }

    It "requires Enterprise failure and stall diagnosis to use fresh event-log evidence before Out" {
        $rulesText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\USER-RULES.append.md")
        $lifecycleText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\branch-lifecycle.md")
        $authoringText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\vanessa-authoring.md")

        foreach ($text in @($rulesText, $lifecycleText)) {
            $text | Should -Match '(Enterprise failure|failed, timed-out, or .*Enterprise)'
            $text | Should -Match 'fresh branch `1Cv8Log` entries'
            $text | Should -Match 'process.*progress.*expected duration'
            $text | Should -Match '`/Out`.*secondary'
            $text | Should -Match '(stop waiting|do not wait only) for the hard timeout'
            $text | Should -Match 'never kill arbitrary 1C PIDs'
        }

        $authoringText | Should -Match 'status\.json.*JUnit.*error directory.*event-log.*vanessa\.log.*TestClient `/Out`'
        $authoringText | Should -Match '`/Out` as supplementary.*Enterprise may leave it empty'
    }

    It "keeps README as a compact source-repository entrypoint" {
        $readmeText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "README.md")
        ([regex]::Matches($readmeText, '\S+')).Count | Should -BeLessOrEqual 350
        $firstSection = [regex]::Match($readmeText, '(?m)^## (?<title>[^\r\n]+)\r?$')
        $firstSection.Success | Should -BeTrue
        $firstSection.Groups['title'].Value | Should -Be 'Быстрый старт'
        $readmeText | Should -Match 'обычной инициализации.*стабильного канала.*`master`'
        $readmeText | Should -Match ([regex]::Escape('https://raw.githubusercontent.com/xmentosx/1c-agent-workflow/master/AGENT-INSTALL.md'))
        $readmeText | Should -Match 'канала разработки.*`develop`.*отдельную команду'
        $readmeText | Should -Match ([regex]::Escape('https://raw.githubusercontent.com/xmentosx/1c-agent-workflow/develop/AGENT-INSTALL.md'))
        foreach ($client in @('Codex', 'Kilo Code', 'Claude Code', 'Cursor', 'OpenCode', 'Kimi Code', 'Qwen Code', 'Command Code', 'Cline', 'Pi')) {
            $readmeText | Should -Match ([regex]::Escape($client))
        }
        $readmeText | Should -Not -Match ([regex]::Escape('generic `other`'))
        $readmeText | Should -Not -Match "multi-client"
        $readmeText | Should -Not -Match "OpenSpec workspace и правила устанавливаются"
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
        $envTemplateText | Should -Match '(?m)^CAVEMAN_LEVEL=full\r?$'
        $envTemplateText | Should -Match '(?m)^ITL_ROUTINE_MODE=off\r?$'
        foreach ($marker in @(
            'VERIFICATION_DEPTH=standard', 'UI_TESTING=manual', 'ORCHESTRATION=standard',
            'CAVEMAN=on', 'CAVEMAN_LEVEL=full', 'DEPENDENCY_MODE=fresh', 'VERIFICATION_POLICY=warn',
            '/litemode', '/itl-litemode', '/rulesmodel', 'rtk', 'SUBAGENT_MODEL_CODING', 'ITL_ROUTINE_MODE=off',
            'AGENT_MODEL=', 'SUPPORT_GUARD=deny', 'agent-browser', 'Windows-MCP'
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

    It "keeps the Russian user guides ordered from workflow overview to reference detail" {
        $projectWorkflow = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "docs\itl-workflow\PROJECT-WORKFLOW.ru.md")
        $featureWorkflow = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "docs\itl-workflow\FEATURE-DEVELOPMENT.ru.md")
        $modes = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "docs\itl-workflow\MODES-AND-SETTINGS.ru.md")
        $envReference = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "docs\itl-workflow\DEV-ENV-REFERENCE.ru.md")

        $projectWorkflow.IndexOf("## За пять минут") | Should -BeLessThan $projectWorkflow.IndexOf("## Модель проекта")
        $projectWorkflow | Should -Match '(?s)```text.*master.*itldev/<имя-ветки>.*?/itl-check.*?/itl-result.*?```'
        $projectWorkflow | Should -Match "полные пути"
        $projectWorkflow | Should -Match "коммит только из разрешённых updater-путей"
        $featureWorkflow.IndexOf("## Процесс целиком") | Should -BeLessThan $featureWorkflow.IndexOf("## Перед началом")
        $featureWorkflow | Should -Match '(?s)```text.*quick-fix.*full-cycle.*OpenSpec.*?/itl-check.*?/itl-result.*?```'
        $modes.IndexOf("## Что использовать обычно") | Should -BeLessThan $modes.IndexOf("## Kilo Browser Automation")
        $envReference | Should -Match '(?s)```text.*нужно изменить поведение.*точному имени ключа.*?```'
    }

    It 'keeps the local gate output under ignored build test-results path' {
        $checkText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot 'scripts\check.ps1')
        $testScriptText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot 'scripts\test.ps1')
        Test-Path -LiteralPath (Join-Path $RepoRoot '.github\workflows\ci.yml') | Should -BeFalse
        $checkText | Should -Match ([regex]::Escape('build\test-results\local'))
        $checkText | Should -Match 'run-pester-shard\.ps1'
        $checkText | Should -Match 'pester-selection-plan\.json'
        $checkText | Should -Match 'pester\.xml'
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
            common = @("itl.md.template", "itl-litemode.md.template", "itl-status.md.template", "itl-sync-master.md.template", "itl-update-workflow.md.template")
            master = @("itl-new-config-branch.md.template", "itl-new-extension-branch.md.template", "itl-refresh-all.md.template", "itl-repository-mode.md.template", "itl-switch-client.md.template")
            dev = @("itl-check.md.template", "itl-fork-branch.md.template", "itl-lock-objects.md.template", "itl-refresh.md.template", "itl-refresh-lite.md.template", "itl-reset-branch.md.template", "itl-result.md.template", "itl-verify-fix.md.template")
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

    It "keeps ITL command descriptions Russian and agent actions English" {
        $templateRoot = Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates"
        $wrapperFiles = Get-ChildItem -LiteralPath $templateRoot -Recurse -File -Filter "itl*.md.template"
        foreach ($file in $wrapperFiles) {
            $text = Get-Content -Encoding UTF8 -Raw $file.FullName
            $description = [regex]::Match($text, '(?m)^description:\s*(.+)$')
            $description.Success | Should -Be $true
            $description.Groups[1].Value | Should -Match '[А-Яа-яЁё]'
        }

        $itl = Get-Content -Encoding UTF8 -Raw (Join-Path $templateRoot "common\itl.md.template")
        $result = Get-Content -Encoding UTF8 -Raw (Join-Path $templateRoot "dev\itl-result.md.template")
        $update = Get-Content -Encoding UTF8 -Raw (Join-Path $templateRoot "common\itl-update-workflow.md.template")
        $itl | Should -Match "Run the helper panel from the current project directory"
        $result | Should -Match "Use this command only from an active"
        $update | Should -Match 'from either the `master` worktree or an active `itldev/\*` worktree'
    }

    It "guards context-specific lifecycle actions in the helper" {
        $HelperText | Should -Match "function Assert-MasterWorktreeContext"
        $HelperText | Should -Match "function Assert-DevelopmentBranchWorktreeContext"
        $HelperText | Should -Match "(?s)function New-DevBranchCore.*Assert-MasterWorktreeContext"

        foreach ($functionName in @(
            "Update-DevBranchBase",
            "Fork-DevBranch",
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

    It "shows capability-matched OpenSpec modes only in the dev ITL lifecycle panel" {
        $masterStart = $HelperText.IndexOf('if ($surface -eq "master")')
        $devStart = $HelperText.IndexOf('} elseif ($surface -eq "dev")', $masterStart)
        $unknownStart = $HelperText.IndexOf('Write-Host "  Откройте worktree master для создания веток', $devStart)
        $masterStart | Should -BeGreaterThan -1
        $devStart | Should -BeGreaterThan $masterStart
        $unknownStart | Should -BeGreaterThan $devStart

        $masterBlock = $HelperText.Substring($masterStart, $devStart - $masterStart)
        $devBlock = $HelperText.Substring($devStart, $unknownStart - $devStart)
        $devBlock | Should -Match "OpenSpec"
        $devBlock | Should -Match 'Режим: \$\(\$openSpec\.mode\)'
        $devBlock | Should -Match 'openSpec\.mode -eq "native"'
        $devBlock | Should -Match 'openSpec\.mode -eq "natural"'
        $devBlock | Should -Match "Get-ItlOpenSpecNaturalRequests"
        $devBlock | Should -Match "Исследовать задачу"
        $devBlock | Should -Match "proposal"
        $devBlock | Should -Match "независимо выберите execution path quick-fix или full-cycle"
        $devBlock | Should -Match "По умолчанию используйте direct"
        $devBlock | Should -Match "Есть проверяемые изменения"
    }

    It "keeps the Russian lifecycle panel current for master dev and unknown contexts" {
        $lifecycleText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1")
        $panelText = $lifecycleText.Substring($lifecycleText.IndexOf("function Show-Help {"))
        foreach ($label in @(
            "Жизненный цикл ITL",
            "Корень проекта:",
            "Контекст:",
            "Ветка Git:",
            "Команды ITL в этом контексте:",
            "Рекомендуемый шаг:",
            "Следующий шаг:",
            "Дополнительные действия:"
        )) {
            $lifecycleText | Should -Match ([regex]::Escape($label))
        }
        foreach ($command in @(
            "/itl-new-config-branch <name>",
            "/itl-new-extension-branch <name>",
            "/itl-update-workflow",
            "/itl-switch-client <client>",
            "/itl-repository-mode <workflow|external|status>",
            "/itl-check",
            "/itl-verify-fix",
            "/itl-sync-master",
            "/itl-refresh",
            "/itl-refresh-lite",
            "/itl-fork-branch <name>",
            "/itl-refresh-all",
            "/itl-reset-branch",
            "/itl-lock-objects",
            "/itl-result"
        )) {
            $panelText | Should -Match ([regex]::Escape($command))
        }
        foreach ($obsolete in @(
            "ITL lifecycle",
            "Commands in this context:",
            "Recommended next step:",
            "Additional helper actions:"
        )) {
            $panelText | Should -Not -Match ([regex]::Escape($obsolete))
        }
    }

    It "keeps additional helper actions grouped without adding visible slash commands" {
        $HelperText | Should -Match "Дополнительные действия:"
        foreach ($group in @("ROCTUP", "vibecoding1c MCP", "Vanessa UI", "Ветки расширений", "Обслуживание и recovery")) {
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
        $wrapperText | Should -Match "entire final response"
        $wrapperText | Should -Match 'fenced `text` block'
        $wrapperText | Should -Match "nothing outside it"
        $wrapperText | Should -Match "every helper line break, blank line, and indentation"
        $wrapperText | Should -Match "Do not paraphrase"
        $wrapperText | Should -Match "On failure, report the actual error"
        $wrapperText | Should -Match "Дополнительные действия:"
        $wrapperText | Should -Match "Жизненный цикл:"
        $wrapperText | Should -Not -Match "Lifecycle-РґРµР№СЃС‚РІРёСЏ РЅРµ РІС‹РїРѕР»РЅСЏР»РёСЃСЊ"
    }

    It "keeps status and litemode responses markdown-safe" {
        $templateRoot = Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\common"
        $statusText = Get-Content -Encoding UTF8 -Raw (Join-Path $templateRoot "itl-status.md.template")
        $litemodeText = Get-Content -Encoding UTF8 -Raw (Join-Path $templateRoot "itl-litemode.md.template")

        $statusText | Should -Match "structured Russian Markdown report with no prose paragraphs"
        $statusText | Should -Match 'one `- Подпись: значение` field per line'
        $statusText | Should -Match "preserve concrete helper values"
        $statusText | Should -Match "Omit unavailable sections"
        $statusText | Should -Match "copy its Russian state/source line"
        $statusText | Should -Match "never omit, reword, or move"
        $litemodeText | Should -Match "complete helper stdout unchanged"
        $litemodeText | Should -Match 'exactly one fenced `text` code block'
        $litemodeText | Should -Match "mode-change confirmation"
        $litemodeText | Should -Match "nothing outside it"
    }

    It "requires complete user reports after init branch creation and refresh" {
        $installText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "AGENT-INSTALL.md")
        $workflowSkill = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\SKILL.md")
        $fastSkill = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow-fast\SKILL.md")
        $advancedActions = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\advanced-actions.md")
        $configBranch = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\master\itl-new-config-branch.md.template")
        $extensionBranch = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\master\itl-new-extension-branch.md.template")
        $refreshBranch = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-refresh.md.template")

        foreach ($text in @($installText, $workflowSkill, $fastSkill, $configBranch, $extensionBranch, $refreshBranch)) {
            $text | Should -Match "userReport"
            $text | Should -Match "final response must be exactly|make the final response exactly"
            $text | Should -Match "MCP/Browser"
            $text | Should -Match "advice"
            $text | Should -Match "Do not translate it"
            $text | Should -Match "convert it to a table"
            $text | Should -Match "rename or merge fields"
            $text | Should -Match "reorder or omit lines"
            $text | Should -Match "code fence"
            $text | Should -Match "console\.log"
        }
        foreach ($text in @($installText, $advancedActions)) {
            $text | Should -Match "userReportOmitted=true"
            $text | Should -Match 'full absolute `userReportPath`'
            $text | Should -Match "userReportSource=status-json"
        }
        foreach ($text in @($workflowSkill, $fastSkill)) {
            $text | Should -Match "userReportOmitted=true"
            $text | Should -Match ([regex]::Escape(".agents/skills/1c-workflow/references/advanced-actions.md"))
        }
        $refreshBranch | Should -Match "states the successful outcome"
        $refreshBranch | Should -Match "/itl-check"
        $refreshBranch | Should -Match "errorCategory=source-integrity"
        $refreshBranch | Should -Match "errorCategory=merge-conflict"
        $refreshBranch | Should -Match "progressive semantic repair"
        $refreshBranch | Should -Match "repairPaths"
        $refreshBranch | Should -Match "Ask the user only when authoritative evidence still leaves incompatible business outcomes"
        $refreshBranch | Should -Match "never create the merge commit manually"
        $refreshLite = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-refresh-lite.md.template")
        $refreshLite | Should -Match "errorCategory=source-integrity"
        $refreshLite | Should -Match "errorCategory=merge-conflict"
        $refreshLite | Should -Match "progressive semantic repair"
        $refreshLite | Should -Match "repairPaths"
        $refreshLite | Should -Match "Ask the user only when evidence leaves incompatible business outcomes"
        $refreshLite | Should -Match "repeat this same command"
    }

    It "reports exact repository object lock conflicts without a console-log hop" {
        $lockObjects = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-lock-objects.md.template")
        $lockObjects | Should -Match "LOCK_CONFIG_REPOSITORY_OBJECT_CONFLICT"
        $lockObjects | Should -Match "exact objects and repository users"
        $lockObjects | Should -Match "requiredAction"
        $lockObjects | Should -Match 'without reading `console\.log`'
    }

    It "keeps the native /itl contract compact and consistent" {
        $rulesTemplateText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\USER-RULES.append.md")
        $installText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "AGENT-INSTALL.md")

        $rulesTemplateText | Should -Match 'Native `/itl`'
        $rulesTemplateText | Should -Match 'one fenced `text` block'
        $rulesTemplateText | Should -Match "line breaks, blank lines, and indentation"
        $rulesTemplateText | Should -Match "write nothing outside"
        $installText | Should -Match 'exactly one fenced `text` block'
        $installText | Should -Match "preserving every line break, blank line, and indentation"
        $installText | Should -Match "actual error instead of fabricating a panel"
    }

    It "recommends separate execution and planning choices for a fresh clean dev branch" {
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
            $sourceProof = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Get-ConfigSourceFingerprint -ExportPath "src/cf"
            }

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
                lastConfigDesignerFingerprint = $sourceProof.fingerprint
                lastConfigDesignerTreeObjectId = $sourceProof.treeObjectId
                configLoadStatus = "passed"
                enterpriseNormalizationStatus = "passed"
            }
            Set-Content -LiteralPath (Join-Path $stateDir "branch3.json") -Encoding UTF8 -Value (($state | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

            $openSpecDir = Join-Path $tempRoot ".kilocode\workflows"
            New-Item -ItemType Directory -Force -Path $openSpecDir, (Join-Path $tempRoot "openspec/specs"), (Join-Path $tempRoot "openspec/changes"), (Join-Path $tempRoot ".kilo/rules-1c") | Out-Null
            foreach ($relativePath in @("openspec/README.md", "openspec/config.yaml", "openspec/project.md", "openspec/specs/README.md", "openspec/changes/README.md")) {
                Set-Content -LiteralPath (Join-Path $tempRoot $relativePath) -Encoding UTF8 -Value "fixture"
            }
            Set-Content -LiteralPath (Join-Path $tempRoot "USER-RULES.md") -Encoding UTF8 -Value "<!-- ITL-WORKFLOW-USER-RULES:START -->`nContext Sources; test-plan.md; fresh /itl-check`n<!-- ITL-WORKFLOW-USER-RULES:END -->"
            $integrationRulePath = Join-Path $tempRoot ".kilo/rules-1c/sdd-integrations.md"
            Set-Content -LiteralPath $integrationRulePath -Encoding UTF8 -Value "OpenSpec integration fixture"
            $openSpecFiles = [ordered]@{
                ".kilo/rules-1c/sdd-integrations.md" = [ordered]@{ source = "content/rules/sdd-integrations.md"; installedHash = (Get-FileHash -LiteralPath $integrationRulePath -Algorithm SHA256).Hash.ToLowerInvariant() }
            }
            foreach ($command in @("opsx-propose", "opsx-explore", "opsx-apply", "opsx-archive")) {
                $relativePath = ".kilocode/workflows/$command.md"
                $targetPath = Join-Path $tempRoot $relativePath
                Set-Content -LiteralPath $targetPath -Encoding UTF8 -Value $command
                $openSpecFiles[$relativePath] = [ordered]@{ source = "content/openspec-bundle/kilocode/$relativePath"; installedHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant() }
            }
            $aiRulesManifest = [ordered]@{
                tools = @("kilocode")
                files = $openSpecFiles
            }
            Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Encoding UTF8 -Value (($aiRulesManifest | ConvertTo-Json -Depth 8) + [Environment]::NewLine)

            $helpResult = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @("-ProjectRoot", $tempRoot, "-Action", "help")
            $helpResult.exitCode | Should -Be 0
            $text = $helpResult.combinedText

            foreach ($expectedBase64 in @('0JXRgdGC0Ywg0L/RgNC+0LLQtdGA0Y/QtdC80YvQtSDQuNC30LzQtdC90LXQvdC40Y86IEZhbHNl','0KDQtdC60L7QvNC10L3QtNGD0LXQvNGL0Lkg0YjQsNCzOiDQvdC10LfQsNCy0LjRgdC40LzQviDQstGL0LHQtdGA0LjRgtC1IGV4ZWN1dGlvbiBwYXRoIHF1aWNrLWZpeCDQuNC70LggZnVsbC1jeWNsZQ==','0J/QviDRg9C80L7Qu9GH0LDQvdC40Y4g0LjRgdC/0L7Qu9GM0LfRg9C50YLQtSBkaXJlY3Q=','0LLRi9Cx0LjRgNCw0LnRgtC1IC9vcHN4LWV4cGxvcmUg0LjQu9C4IC9vcHN4LXByb3Bvc2UsINGC0L7Qu9GM0LrQviDQtdGB0LvQuCDQv9C+0LvQtdC30L3QviDRhNC+0YDQvNCw0LvRjNC90L7QtSDQuNGB0YHQu9C10LTQvtCy0LDQvdC40LUg0LjQu9C4INGB0L7Qs9C70LDRgdC+0LLQsNC90LjQtQ==')) {
                $text | Should -Match ([regex]::Escape([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($expectedBase64))))
            }
            foreach ($command in @("/opsx-propose", "/opsx-explore", "/opsx-apply", "/opsx-archive")) {
                $text | Should -Match ([regex]::Escape($command))
            }
            $text | Should -Not -Match "Kilo OpenSpec commands are unavailable"
            $text | Should -Not -Match "Рекомендуемый шаг: /itl-check"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "renders exact natural OpenSpec requests without fictitious slash commands" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-help-natural-dev-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c/project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["qwen"]}}'
            $output = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Get-KiloItlCommandSurface { "dev" }
                function Get-CurrentBranch { "itldev/natural" }
                function Get-AiRules1cOpenSpecStatus {
                    [pscustomobject]@{ mode = "natural"; isAvailable = $true; reason = "intentional bundleSkipped"; cliAvailable = $false; cliPath = ""; invocations = [pscustomobject]@{} }
                }
                function Read-DevBranchState {
                    [pscustomobject]@{ devBranchName = "natural"; devBranchKind = "configuration"; devBranchInfoBasePath = "fixture"; lastResultPath = ""; finalResultPath = "" }
                }
                function Get-VerificationState { [pscustomobject]@{ effectiveStatus = "missing"; isFreshPassed = $false; reportPath = "" } }
                function Get-DevBranchKind { "configuration" }
                function Get-DevBranchExtensionInitializationStatus { "ready" }
                function Test-DevBranchHasCheckableChanges { $false }
                function Get-ItlActiveClient { "qwen" }
                Show-Help
            } 6>&1 | Out-String -Width 10000
            $normalizedOutput = ((@($output) -join [Environment]::NewLine) -replace '\s+', ' ').Trim()
            $normalizedOutput | Should -Match "Режим: natural"
            foreach ($request in @(
                "Исследуй задачу в режиме OpenSpec, не создавая proposal и не меняя код",
                "Подготовь OpenSpec proposal для <изменение>; создай proposal, design, tasks, test-plan и spec deltas; код не меняй",
                "Реализуй согласованный OpenSpec change <change-id> по tasks.md и test-plan.md",
                "Заархивируй принятый OpenSpec change <change-id> и синхронизируй specs"
            )) { $normalizedOutput | Should -Match ([regex]::Escape($request)) }
            $normalizedOutput | Should -Match "Внешний CLI: не найден; установка не выполняется"
            $normalizedOutput | Should -Not -Match "/opsx-propose"
            $normalizedOutput | Should -Not -Match "/opsx-apply"
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
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

            $text | Should -Match "Есть проверяемые изменения: True"
            $text | Should -Match "Рекомендуемый шаг: /itl-check"
            $text | Should -Match "OpenSpec недоступен"
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
        $HelperText | Should -Match "function Run-DevBranchTests"
        $HelperText | Should -Not -Match '"run-dev-branch-tests"'
        $HelperText | Should -Match '\[string\]\$VanessaFeaturePath'
        $HelperText | Should -Match '\[string\]\$VanessaFilterTags'

        $advancedText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\advanced-actions.md")
        $advancedText | Should -Match 'Automated performance profiling repeats canonical `check-dev-branch`'
        $advancedText | Should -Match 'fingerprint preflight skips Designer'
        $advancedText | Should -Match 'canonical ownership, cleanup, event-log, and evidence preflight still add overhead'

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
        $recoveryText | Should -Match "configured maximum"

        $menuText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\workflow.md")
        $menuText | Should -Match ([regex]::Escape("/itl-check"))
        $menuText | Should -Match ([regex]::Escape("/itl-verify-fix"))
        $menuText | Should -Match "itldev/\*"

        foreach ($relativePath in @(
            "docs\itl-workflow\PROJECT-WORKFLOW.ru.md",
            "docs\itl-workflow\FEATURE-DEVELOPMENT.ru.md",
            ".agents\skills\1c-workflow\references\workflow.md",
            ".agents\skills\1c-workflow\references\dev-branch-development.md",
            ".agents\skills\1c-workflow\references\dev-branch-quick-fix.md",
            ".agents\skills\1c-workflow\references\dev-branch-direct.md",
            ".agents\skills\1c-workflow\references\dev-branch-openspec.md",
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
            "executionPath=quick-fix|full-cycle",
            "planningMode=direct|OpenSpec",
            "all four pairs are valid",
            'Promotion triggers set only `executionPath=full-cycle`',
            "QUICKFIX_MAX_LINES",
            "/itl-check",
            "OpenSpec phases read rules",
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
        $developmentPaths = @(
            ".agents\skills\1c-workflow\references\dev-branch-development.md",
            ".agents\skills\1c-workflow\references\dev-branch-quick-fix.md",
            ".agents\skills\1c-workflow\references\dev-branch-direct.md",
            ".agents\skills\1c-workflow\references\dev-branch-openspec.md"
        )
        $developmentTexts = @{}
        foreach ($relativePath in $developmentPaths) {
            $developmentTexts[$relativePath] = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot $relativePath)
        }
        $text = ($developmentTexts.Values -join [Environment]::NewLine)

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
            "targeted/static",
            "pending verification",
            "unfiltered",
            "test-report.md"
        )) {
            $text | Should -Match ([regex]::Escape($marker))
        }

        $text | Should -Match "quick-fix.*переиспользуйте.*Vanessa-покрытие"
        $text | Should -Match "Второй сценарий.*только.*отдельной значимой границы"
        $text | Should -Match "OpenSpec.*hybrid cadence"
        $text | Should -Match "milestone.*результат решает.*продолж"
        $text | Should -Match 'последней verification-relevant правки.*unfiltered `/itl-check`'
        $text | Should -Not -Match 'Для каждого среза.*выполняет `/itl-check`'
        $text | Should -Not -Match 'после каждого значимого среза.*обязательно.*`/itl-check`'
        $text | Should -Match "1-2 Vanessa"
        $text | Should -Not -Match "четвертая проверка.*обоснован"
        $text | Should -Match "git branch --show-current.*не каталог"
        $text | Should -Match "exportPath.*extensionsPath"
        $text | Should -Match "master.*branch-safety blocker"
        $text | Should -Match "изменение существующей формы или wired metadata"
        $text | Should -Match "Promotion trigger.*сам по себе не требует OpenSpec"
        $text | Should -Not -Match "(?m)^- изменение поведения системы;$"
        $text | Should -Not -Match "2-4 Vanessa"

        foreach ($relativePath in @(
            ".agents\skills\1c-workflow\references\dev-branch-quick-fix.md",
            ".agents\skills\1c-workflow\references\dev-branch-direct.md",
            ".agents\skills\1c-workflow\references\dev-branch-openspec.md"
        )) {
            $routeText = $developmentTexts[$relativePath]
            foreach ($marker in @("git branch --show-current", "exportPath", "extensionsPath", "testsPath", "references/vanessa-tests.md", "fresh passed", "/itl-check", "master", "branch-safety blocker")) {
                $routeText | Should -Match ([regex]::Escape($marker))
            }
        }

        $routerText = $developmentTexts[".agents\skills\1c-workflow\references\dev-branch-development.md"]
        foreach ($marker in @("dev-branch-quick-fix.md", "dev-branch-direct.md", "dev-branch-openspec.md", "ровно один matching reference")) {
            $routerText | Should -Match ([regex]::Escape($marker))
        }

        $quickText = $developmentTexts[".agents\skills\1c-workflow\references\dev-branch-quick-fix.md"]
        $quickText | Should -Match "quick-fix.*переиспользуйте.*Vanessa-покрытие"
        $quickText | Should -Not -Match "/opsx-(?:explore|propose|apply|archive)"

        $directText = $developmentTexts[".agents\skills\1c-workflow\references\dev-branch-direct.md"]
        $directText | Should -Match "executionPath=full-cycle"
        $directText | Should -Match "planningMode=direct"
        $directText | Should -Not -Match "/opsx-(?:explore|propose|apply|archive)"

        $openSpecText = $developmentTexts[".agents\skills\1c-workflow\references\dev-branch-openspec.md"]
        $openSpecText | Should -Match "planningMode=OpenSpec"
        $openSpecText | Should -Match "executionPath=quick-fix\|full-cycle"
        $openSpecText | Should -Match "OpenSpec.*hybrid cadence"
        $openSpecText | Should -Match "1-2 Vanessa"
        $openSpecText | Should -Match "YAxUnit"
        $openSpecText | Should -Match "test-report.md"
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
        foreach ($marker in @('native', 'natural', 'Исследуй задачу в режиме OpenSpec', 'Подготовь OpenSpec proposal', 'не запускает `openspec update`')) {
            $text | Should -Match ([regex]::Escape($marker))
        }
        $text | Should -Match "Сам факт исправления наблюдаемого поведения.*не меняет planning mode"
        $text | Should -Match "Direct full-cycle"
        $text | Should -Match "высокий риск проверки сами по себе не принуждают к OpenSpec"
        $text | Should -Not -Match "Используется для новой функциональности, изменения поведения, нескольких модулей"
        $text | Should -Not -Match ([regex]::Escape('.agents/skills/1c-workflow/references/'))

        $vanessaGuide = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\vanessa-tests.md")
        foreach ($marker in @(
            "single-quoted Gherkin parameters and table cells", "stable business key", "selection restores/adds values",
            "runtime-visible, available elements", "targeted graph/code evidence", "Vanessa UI MCP for dynamic state",
            "scripts/get-form-element-context.ps1", "acceptance scenarios fully automated", "Interactive profiling is separate tooling",
            "Classify every executable BSL block", "Never combine both contexts in one block", "VAExtension cross-step transport",
            "freeze it during infrastructure diagnosis"
        )) { $vanessaGuide | Should -Match ([regex]::Escape($marker)) }
        $vanessaGuide | Should -Not -Match "PM5"

        $recipeGuide = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\vanessa-recipes.md")
        foreach ($marker in @(
            "assets/vanessa-authoring-examples", "Unit-Like Logic", "Integration Or Persistence", "UI Navigation And Command",
            "Stable Table Row", "Report Output", "user_actions_recording", "execute_form_actions", "get_window_list_os",
            "get_window_screenshot_os", "reloadAndRunFromLine", '/itl-check` remains the only executable verification gate'
        )) { $recipeGuide | Should -Match ([regex]::Escape($marker)) }
        $recipeGuide | Should -Not -Match "PM5"
    }

    It "documents native examples and natural OpenSpec requests at matching development steps" {
        foreach ($relativePath in @(
            "docs\itl-workflow\FEATURE-DEVELOPMENT.ru.md",
            ".agents\skills\1c-workflow\references\dev-branch-openspec.md"
        )) {
            $text = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot $relativePath)
            foreach ($command in @("/opsx-propose", "/opsx-apply", "/opsx-archive", "/opsx-explore")) {
                $text | Should -Match ([regex]::Escape($command))
            }
            foreach ($request in @("Исследуй задачу в режиме OpenSpec", "Подготовь OpenSpec proposal", "Реализуй согласованный OpenSpec change", "Заархивируй принятый OpenSpec change")) {
                $text | Should -Match ([regex]::Escape($request))
            }
            $text | Should -Match "не считайте.*универсальным|не универсаль"
        }
        $agentText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\dev-branch-openspec.md")
        $agentText | Should -Match "/opsx-propose.*proposal"
        $agentText | Should -Match "/opsx-explore.*optional"
        $agentText | Should -Match "(?s)### 0\..*?/opsx-explore"
        $agentText | Should -Match "(?s)### 1\..*?/opsx-propose"
        $agentText | Should -Match "(?s)### 4\..*?/opsx-apply"
        $agentText | Should -Match "(?s)### 9\..*?/opsx-archive"
    }

    It "ignores every workflow runtime surface without hiding tracked skills" {
        $requiredPath = ".agent-1c/dev-branches/"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape($requiredPath))
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\gitignore.append")) | Should -Match ([regex]::Escape($requiredPath))
        $HelperText | Should -Match ([regex]::Escape($requiredPath))

        $baselinePath = ".agent-1c/event-log-baselines/"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape($baselinePath))
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\gitignore.append")) | Should -Match ([regex]::Escape($baselinePath))
        $HelperText | Should -Match ([regex]::Escape($baselinePath))

        $cursorPath = ".agent-1c/event-log-cursors/"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape($cursorPath))
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\gitignore.append")) | Should -Match ([regex]::Escape($cursorPath))
        $HelperText | Should -Match ([regex]::Escape($cursorPath))

        $cachePath = ".agent-1c/event-log-signature-cache/"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape($cachePath))
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\gitignore.append")) | Should -Match ([regex]::Escape($cachePath))
        $HelperText | Should -Match ([regex]::Escape($cachePath))
        $requiredPath = ".agent-1c/runs/"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape($requiredPath))
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\gitignore.append")) | Should -Match ([regex]::Escape($requiredPath))
        $HelperText | Should -Match ([regex]::Escape($requiredPath))
        $LauncherText | Should -Match ([regex]::Escape('Join-Path $projectRootFull ".agent-1c"'))
        $LauncherText | Should -Match ([regex]::Escape('Join-Path $agentRoot "runs"'))
        $requiredPath = ".agent-1c/locks/"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape($requiredPath))
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\gitignore.append")) | Should -Match ([regex]::Escape($requiredPath))
        $HelperText | Should -Match ([regex]::Escape($requiredPath))
        $requiredPaths = @(
            ".tx/",
            ".agent-1c/branch-dumps/",
            ".agent-1c/config-dump/",
            ".agent-1c/extension-dump/",
            ".agent-1c/extension-init/",
            ".agent-1c/snapshots/",
            ".agent-1c/release-e2e-roundtrip/",
            ".agent-1c/release-e2e-extension/",
            ".agent-1c/tmp/"
        )
        foreach ($requiredPath in $requiredPaths) {
            (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape($requiredPath))
            (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\gitignore.append")) | Should -Match ([regex]::Escape($requiredPath))
            $HelperText | Should -Match ([regex]::Escape($requiredPath))
        }
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
        $generatedCodexSkillPaths = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            Get-ItlGeneratedCodexSkillIgnorePaths -SourceRoot $RepoRoot
        }
        $generatedCodexSkillPaths | Should -Contain ".agents/skills/itl-fork-branch/"
        foreach ($requiredPath in $generatedCodexSkillPaths) {
            (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape($requiredPath))
            (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\gitignore.append")) | Should -Match ([regex]::Escape($requiredPath))
        }
        @(& git -C $RepoRoot ls-files -- ".agents/skills/itl/SKILL.md").Count | Should -Be 0
        @(& git -C $RepoRoot ls-files -- ".agents/skills/itl-roctup-1c-data/SKILL.md").Count | Should -Be 1
        @(& git -C $RepoRoot ls-files -- ".agents/skills/itl-vanessa-ui-mcp/SKILL.md").Count | Should -Be 1
        $HelperText | Should -Match "Test-IgnorableLocalGitStatusLine"
    }
}
