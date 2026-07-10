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

    It 'keeps the detailed skill as a compact router and marks root docs human-facing' {
        $skillText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot '.agents\skills\1c-workflow\SKILL.md')
        ([regex]::Matches($skillText, '\S+')).Count | Should -BeLessOrEqual 750
        $skillText | Should -Match 'detailed ITL workflow router'
        $skillText | Should -Match ([regex]::Escape('references/workflow.md'))
        $skillText | Should -Match ([regex]::Escape('references/init-setup.md'))
        $skillText | Should -Match ([regex]::Escape('references/mcp.md'))
        $skillText | Should -Match ([regex]::Escape('references/branch-lifecycle.md'))
        $skillText | Should -Match ([regex]::Escape('references/verification-result.md'))
        $skillText | Should -Match 'human-facing'

        $humanDocPaths = @('DEVELOPER-GUIDE.ru.md', 'DEV-BRANCH-DEVELOPMENT.ru.md')
        foreach ($relativePath in $humanDocPaths) {
            $docText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot $relativePath)
            $docText | Should -Match 'human-facing'
            if ($relativePath -eq 'DEVELOPER-GUIDE.ru.md') {
                $docText | Should -Match ([regex]::Escape('.agents/skills/1c-workflow/references/workflow.md'))
            } else {
                $docText | Should -Match ([regex]::Escape('.agents/skills/1c-workflow/references/dev-branch-development.md'))
            }
        }
    }

    It "entrypoint token budgets stay within limits" {
        $budgets = @(
            @{ path = ".agents\skills\1c-workflow\SKILL.md"; maxWords = 750; maxApproxTokens = 1500 },
            @{ path = ".agents\skills\1c-workflow-fast\SKILL.md"; maxWords = 750; maxApproxTokens = 1500 },
            @{ path = "templates\USER-RULES.append.md"; maxWords = 750; maxApproxTokens = 1500 },
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

    It "human docs are summaries, not canonical procedures" {
        $readmeText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "README.md")
        $developerGuideText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "DEVELOPER-GUIDE.ru.md")

        $readmeText | Should -Match ([regex]::Escape(".agents/skills/1c-workflow/references/"))
        $developerGuideText | Should -Match ([regex]::Escape(".agents/skills/1c-workflow/references/"))

        $readmeText | Should -Not -Match ([regex]::Escape("1. Run installer"))
        $readmeText | Should -Not -Match ([regex]::Escape("Mantis token"))
        $developerGuideText | Should -Not -Match ([regex]::Escape("script wizard"))
        $developerGuideText | Should -Not -Match ([regex]::Escape("Refresh-DevBranch"))
    }

    It 'keeps Pester CI output under ignored build test-results path' {
        $ciText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot '.github\workflows\ci.yml')
        $testScriptText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot 'scripts\test.ps1')
        $ciText | Should -Match ([regex]::Escape('build\test-results\pester\testResults.xml'))
        $ciText | Should -Match ([regex]::Escape('.\scripts\test.ps1'))
        $ciText | Should -Match '-CI'
        $ciText | Should -Match '-OutputFile'
        $testScriptText | Should -Match 'New-PesterConfiguration'
        $testScriptText | Should -Match 'TestResult\.OutputPath'

        $gitignoreText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot '.gitignore')
        $templateIgnoreText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot 'templates\gitignore.append')
        $gitignoreText | Should -Match '(?m)^testResults\.xml$'
        $templateIgnoreText | Should -Match '(?m)^testResults\.xml$'
        $templateIgnoreText | Should -Match 'build/test-results/'
    }

    It "has context-specific Kilo command templates for the public surface" {
        $templateRoot = Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates"
        $expected = @{
            common = @("itl.md.template", "itl-status.md.template")
            master = @("itl-new-config-branch.md.template", "itl-new-extension-branch.md.template", "itl-update-workflow.md.template")
            dev = @("itl-check.md.template", "itl-refresh.md.template", "itl-result.md.template")
        }

        foreach ($setName in $expected.Keys) {
            $setPath = Join-Path $templateRoot $setName
            (Test-Path -LiteralPath $setPath -PathType Container) | Should -Be $true
            $actual = @(Get-ChildItem -LiteralPath $setPath -File -Filter "itl*.md.template" | Sort-Object Name | Select-Object -ExpandProperty Name)
            $actual | Should -Be @($expected[$setName] | Sort-Object)
        }

        @(Get-ChildItem -LiteralPath $templateRoot -Recurse -File -Filter "itl*.md" -ErrorAction SilentlyContinue).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $templateRoot -Recurse -File -Filter "opsx*.md" -ErrorAction SilentlyContinue).Count | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $RepoRoot ".kilo\commands") -PathType Container) | Should -Be $true
        @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".kilo\commands") -File -Filter "itl*.md" -ErrorAction SilentlyContinue).Count | Should -Be 0
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
            $text | Should -Match "Kilo OpenSpec commands are unavailable"
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

        $menuText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\workflow.md")
        $menuText | Should -Match ([regex]::Escape("/itl-check"))
        $menuText | Should -Match "itldev/\*"

        foreach ($relativePath in @(
            "README.md",
            "DEVELOPER-GUIDE.ru.md",
            "DEV-BRANCH-DEVELOPMENT.ru.md",
            ".agents\skills\1c-workflow\references\workflow.md",
            ".agents\skills\1c-workflow\references\dev-branch-development.md",
            ".agents\skills\1c-workflow-fast\SKILL.md",
            "templates\USER-RULES.append.md"
        )) {
            $text = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot $relativePath)
            $text | Should -Match ([regex]::Escape("/itl-check"))
        }
    }

    It "requires Vanessa tests and fresh /itl-check before agent development completion" {
        $userRulesText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\USER-RULES.append.md")

        foreach ($marker in @(
            "Development completion gate",
            "src/cf",
            "src/cfe",
            "modules, forms, commands, metadata",
            "tests/features",
            "VANESSA-TESTS-GUIDE.md",
            "/itl-check",
            "fresh passed",
            "/opsx-apply",
            "quick-fix",
            "develop code by this plan",
            "execute development tasks",
            "make this change",
            "ready/done/implemented",
            "final reply",
            "Vanessa report path",
            "Hybrid cadence",
            "focused regression scenario",
            "focused Vanessa scenario",
            "pending verification",
            "test-report.md"
        )) {
            $userRulesText | Should -Match ([regex]::Escape($marker))
        }

        $userRulesText | Should -Match "Do not answer.*tests are missing"
        $userRulesText | Should -Match "Do not answer.*/itl-check.*did not run"
        $userRulesText | Should -Match "Do not answer.*verification is not fresh passed"
        $userRulesText | Should -Match "Large OpenSpec.*tasks\.md.*checkable slices"
        $userRulesText | Should -Not -Match "opsx\*\.md"
    }

    It "documents the same development completion gate in dev-branch process docs" {
        foreach ($relativePath in @(
            "DEV-BRANCH-DEVELOPMENT.ru.md",
            ".agents\skills\1c-workflow\references\dev-branch-development.md"
        )) {
            $text = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot $relativePath)

            foreach ($marker in @(
                "src/cf",
                "src/cfe",
                "tests/features",
                "VANESSA-TESTS-GUIDE.md",
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
            $text | Should -Match "OpenSpec.*hybrid cadence"
            $text | Should -Match "2-4 Vanessa"
        }
    }

    It "documents OpenSpec slash commands at the matching branch development steps" {
        foreach ($relativePath in @(
            "DEV-BRANCH-DEVELOPMENT.ru.md",
            ".agents\skills\1c-workflow\references\dev-branch-development.md"
        )) {
            $text = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot $relativePath)
            foreach ($command in @("/opsx-propose", "/opsx-apply", "/opsx-archive", "/opsx-explore")) {
                $text | Should -Match ([regex]::Escape($command))
            }

            $text | Should -Match "/opsx-propose.*proposal"
            $text | Should -Match "/opsx-explore.*optional"
            $text | Should -Match "(?s)### 0\..*?/opsx-explore"
            $text | Should -Match "(?s)### 1\..*?/opsx-propose"
            $text | Should -Match "(?s)### 4\..*?/opsx-apply"
            $text | Should -Match "(?s)### 9\..*?/opsx-archive"
        }
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
    }

    It "ignores monitored run status and log artifacts" {
        $requiredPath = ".agent-1c/runs/"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape($requiredPath))
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\gitignore.append")) | Should -Match ([regex]::Escape($requiredPath))
        $HelperText | Should -Match ([regex]::Escape($requiredPath))
        $LauncherText | Should -Match ([regex]::Escape(".agent-1c\runs"))
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
