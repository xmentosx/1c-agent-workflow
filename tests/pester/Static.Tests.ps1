Describe "1C agent workflow static checks" {
    BeforeAll {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
        $HelperPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
        $HelperModulePaths = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib") -File -Filter "agent-1c.*.ps1" | Sort-Object Name | ForEach-Object { $_.FullName })
        $LauncherPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1"
        $McpHostPath = Join-Path $RepoRoot "vibecoding1c-mcp-host\install-vibecoding1c-mcp-host.ps1"
        $McpHostDumpPath = Join-Path $RepoRoot "vibecoding1c-mcp-host\export-1c-config-dump.ps1"
        $helperParts = @()
        $helperParts += Get-Content -Encoding UTF8 -Raw $HelperPath
        foreach ($modulePath in $HelperModulePaths) {
            $helperParts += Get-Content -Encoding UTF8 -Raw $modulePath
        }
        $HelperText = $helperParts -join [Environment]::NewLine
        $LauncherText = Get-Content -Encoding UTF8 -Raw $LauncherPath
        $McpHostText = @(
            (Get-Content -Encoding UTF8 -Raw $McpHostPath),
            (Get-Content -Encoding UTF8 -Raw $McpHostDumpPath)
        ) -join [Environment]::NewLine
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

    It "parses the standalone MCP host installer" {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($McpHostPath, [ref]$tokens, [ref]$errors) | Out-Null

        @($errors).Count | Should -Be 0
    }

    It "parses the standalone MCP host config dump helper" {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($McpHostDumpPath, [ref]$tokens, [ref]$errors) | Out-Null

        @($errors).Count | Should -Be 0
    }

    It "does not promote 1C Designer warnings to errors" {
        $flag = "-Warnings" + "AsErrors"
        $HelperText | Should -Not -Match ([regex]::Escape($flag))
    }

    It "uses process APPDATA for the 1C launcher list path" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-launcher-appdata-test-" + [guid]::NewGuid().ToString("N"))
        $oldAppData = $env:APPDATA

        try {
            $env:APPDATA = Join-Path $tempRoot "appdata"
            $expectedPath = Join-Path $env:APPDATA "1C\1CEStart\ibases.v8i"

            $actualPath = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                Get-LauncherListPath
            }

            $actualPath | Should -Be $expectedPath
        } finally {
            $env:APPDATA = $oldAppData
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "collects config load paths from Git without losing Cyrillic names" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-config-load-paths-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf\Enums") | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf\CommonModules") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Value "<Configuration />" -Encoding UTF8

            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot config core.quotepath true
            & git -C $tempRoot add src/cf/Configuration.xml
            & git -C $tempRoot commit -m "base config" *> $null
            $baseCommit = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()

            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Value "<Configuration changed=`"true`" />" -Encoding UTF8
            $trackedEnumName = "упо_ПоведениеПриЗагрузкеНерассчитаннойВерсии.xml"
            $untrackedEnumName = "упо_ПоведениеПриЗаписиНерассчитаннойВерсии.xml"
            $spacedModuleName = "Модуль с пробелом.xml"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Enums\$trackedEnumName") -Value "<Enum />" -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Enums\$untrackedEnumName") -Value "<Enum />" -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\CommonModules\$spacedModuleName") -Value "<CommonModule />" -Encoding UTF8
            & git -C $tempRoot add -- "src/cf/Enums/$trackedEnumName" "src/cf/CommonModules/$spacedModuleName"

            $changeSet = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Get-ConfigLoadChangeSet -State ([pscustomobject]@{ createdFromCommit = $baseCommit }) -ExportPath "src/cf"
            }

            $expectedFiles = @(
                "Configuration.xml",
                (Join-Path "CommonModules" $spacedModuleName),
                (Join-Path "Enums" $trackedEnumName),
                (Join-Path "Enums" $untrackedEnumName)
            )
            foreach ($expectedFile in $expectedFiles) {
                $changeSet.files | Should -Contain $expectedFile
            }

            foreach ($file in $changeSet.files) {
                $file | Should -Not -Match '^"'
                $file | Should -Not -Match '\\3(20|21)'
                $file -replace "\\", "/" | Should -Not -Match "^src/cf/"
            }

            $oldQuotedEscapedPath = '"src/cf/Enums/\321\203.xml"'
            $converted = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                ConvertTo-ConfigLoadRelativePath -RepoPath $oldQuotedEscapedPath -ExportPath "src/cf"
            }
            $converted | Should -BeNullOrEmpty
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "treats empty Git path list output as an empty array" {
        $tempParent = Join-Path ([System.IO.Path]::GetTempPath()) ("itl git paths parent " + [guid]::NewGuid().ToString("N"))
        $tempRoot = Join-Path $tempParent "проект с пробелом"

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Value "<Configuration />" -Encoding UTF8
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add src/cf/Configuration.xml
            & git -C $tempRoot commit -m "base" *> $null

            $paths = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help -LifecyclePhase post-merge *> $null
                @(Get-GitPathList -Arguments @("ls-files", "-z", "--others", "--exclude-standard", "--", "src/cf"))
            }

            @($paths).Count | Should -Be 0
        } finally {
            if (Test-Path -LiteralPath $tempParent -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempParent -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "reports detailed diagnostics when Git path collection fails" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-git-path-failure-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $errorText = ""
            try {
                & {
                    . $HelperPath -ProjectRoot $tempRoot -Action help -LifecyclePhase post-merge *> $null
                    Get-GitPathList -Arguments @("not-a-git-command")
                }
            } catch {
                $errorText = $_.Exception.Message
            }

            $errorText | Should -Match "Git path collection failed"
            $errorText | Should -Match ([regex]::Escape([System.IO.Path]::GetFullPath($tempRoot)))
            $errorText | Should -Match "LifecyclePhase: post-merge"
            $errorText | Should -Match "ExitCode:"
            $errorText | Should -Match "not-a-git-command"
            $errorText | Should -Match "Stderr:"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "detects workflow helper script changes after a merge base commit" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-helper-change-test-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agents\skills\1c-workflow\scripts\lib") | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1") -Value "base" -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Value "<Configuration />" -Encoding UTF8

            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            $baseCommit = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()

            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Value "<Configuration changed=`"true`" />" -Encoding UTF8
            & git -C $tempRoot add src/cf/Configuration.xml
            & git -C $tempRoot commit -m "config only" *> $null
            $configCommit = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()
            $onlyConfigChanged = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Test-WorkflowHelperChangedSince -BeforeCommit $baseCommit
            }
            $onlyConfigChanged | Should -BeFalse

            Set-Content -LiteralPath (Join-Path $tempRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1") -Value "changed" -Encoding UTF8
            & git -C $tempRoot add .agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1
            & git -C $tempRoot commit -m "helper change" *> $null
            $helperChanged = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Test-WorkflowHelperChangedSince -BeforeCommit $configCommit
            }
            $helperChanged | Should -BeTrue
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "restarts after refresh and close merges before loading config files" {
        foreach ($functionName in @("Refresh-DevBranch", "Close-DevBranch")) {
            $match = [regex]::Match($HelperText, "(?s)function\s+$functionName\s*\{(?<body>.*?)(?=`r?`nfunction\s+)")
            $match.Success | Should -Be $true
            $body = $match.Groups["body"].Value
            $mergeIndex = $body.IndexOf('Invoke-Git @("merge", (Get-MasterBranch))')
            $guardIndex = $body.IndexOf('Restart-Agent1cIfWorkflowHelperChangedSince -BeforeCommit $beforeMergeCommit -AdditionalArguments @("-LifecyclePhase", "post-merge")')
            $phaseRestartIndex = $body.IndexOf('Restart-Agent1cAfterDevBranchMerge -Operation')
            $loadIndex = $body.IndexOf('Load-ConfigFromFiles')

            $mergeIndex | Should -BeGreaterOrEqual 0
            $guardIndex | Should -BeGreaterThan $mergeIndex
            $phaseRestartIndex | Should -BeGreaterThan $guardIndex
            $loadIndex | Should -BeGreaterThan $phaseRestartIndex
        }
    }

    It "preserves helper arguments needed for automatic reexec" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-reexec-args-test-" + [guid]::NewGuid().ToString("N"))
        $statusPath = Join-Path $tempRoot "status.json"
        $logPath = Join-Path $tempRoot "run.log"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $args = & {
                . $HelperPath `
                    -ProjectRoot $tempRoot `
                    -Action help `
                    -DevBranchName "branch3" `
                    -DevBranch "itldev/branch3" `
                    -RunStatusPath $statusPath `
                    -RunLogPath $logPath `
                    -AllowUnverifiedClose *> $null
                Get-Agent1cReexecArguments
            }

            $args | Should -Contain "-Action"
            $args | Should -Contain "help"
            $args | Should -Contain "-ProjectRoot"
            $args | Should -Contain ([System.IO.Path]::GetFullPath($tempRoot))
            $args | Should -Contain "-DevBranchName"
            $args | Should -Contain "branch3"
            $args | Should -Contain "-DevBranch"
            $args | Should -Contain "itldev/branch3"
            $args | Should -Contain "-RunStatusPath"
            $args | Should -Contain $statusPath
            $args | Should -Contain "-RunLogPath"
            $args | Should -Contain $logPath
            $args | Should -Contain "-AllowUnverifiedClose"
            $args | Should -Not -Contain "-AllowUnverifiedResult"
            $args | Should -Not -Contain "-LifecyclePhase"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "preserves the post-merge lifecycle phase for second phase reexec" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-reexec-phase-test-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $args = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help -LifecyclePhase post-merge *> $null
                Get-Agent1cReexecArguments
            }

            $args | Should -Contain "-Action"
            $args | Should -Contain "help"
            $args | Should -Contain "-LifecyclePhase"
            $args | Should -Contain "post-merge"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "keeps Markdown files valid UTF-8 without mojibake markers" {
        $strictUtf8 = New-Object System.Text.UTF8Encoding $false, $true
        $mojibakePattern = "Рџ|Рђ|Р’|Рљ|Рњ|Рќ|Рћ|РЎ|Рў|РЈ|РЅРµС‚|СЂ|СЃ|С‚|Р°|Рµ|Рё|Рѕ"
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

    It "has Kilo wrapper files for every documented /itl command" {
        $docPaths = @(
            "README.md",
            "DEVELOPER-GUIDE.ru.md",
            "DEV-BRANCH-DEVELOPMENT.ru.md",
            "AGENT-INSTALL.md",
            ".agents\skills\1c-workflow\references\workflow.md",
            ".kilo\commands\itl.md"
        ) | ForEach-Object { Join-Path $RepoRoot $_ }

        $documentedCommands = foreach ($path in $docPaths) {
            $text = Get-Content -Encoding UTF8 -Raw $path
            [regex]::Matches($text, "(?<![\w-])/(itl(?:-[a-z0-9-]+)?)") | ForEach-Object { "/" + $_.Groups[1].Value }
        }

        $documentedCommands = @($documentedCommands | Sort-Object -Unique)
        ($documentedCommands -contains "/itl") | Should -Be $true

        foreach ($command in ($documentedCommands | Where-Object { $_ -ne "/itl" })) {
            $fileName = $command.TrimStart("/") + ".md"
            $wrapperPath = Join-Path $RepoRoot (Join-Path ".kilo\commands" $fileName)
            (Test-Path -LiteralPath $wrapperPath -PathType Leaf) | Should -Be $true
        }
    }

    It "uses only helper actions that are declared in the Action ValidateSet" {
        $match = [regex]::Match($HelperText, '(?s)\[ValidateSet\((.*?)\)\]\s*\[string\]\$Action')
        $match.Success | Should -Be $true
        $quote = [string]([char]34)
        $actionPattern = [regex]::Escape($quote) + "(.+?)" + [regex]::Escape($quote)
        $allowedActions = @([regex]::Matches($match.Groups[1].Value, $actionPattern) | ForEach-Object { $_.Groups[1].Value })

        $wrapperFiles = Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".kilo\commands") -File -Filter "itl*.md"
        foreach ($file in $wrapperFiles) {
            $text = Get-Content -Encoding UTF8 -Raw $file.FullName
            $actionMatch = [regex]::Match($text, "-Action\s+(\S+)")
            if ($actionMatch.Success) {
                ($allowedActions -contains $actionMatch.Groups[1].Value) | Should -Be $true
            }
        }
    }

    It "keeps the Kilo init command on the helper wizard path" {
        $wrapperPath = Join-Path $RepoRoot ".kilo\commands\itl-init-project.md"
        (Test-Path -LiteralPath $wrapperPath -PathType Leaf) | Should -Be $true
        $text = Get-Content -Encoding UTF8 -Raw $wrapperPath
        $text | Should -Match ([regex]::Escape(".\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1"))
        $text | Should -Match "-Action\s+init-project"
        $text | Should -Match "-InitMode\s+wizard"
        $text | Should -Match ([regex]::Escape(".agent-1c/runs/<run>/status.json"))
        $text | Should -Match "Do not collect the initialization questionnaire"
        $text | Should -Match "direct bootstrap-only wrapper"
    }

    It "documents monitored init as a foreground command, not a background direct wizard" {
        $docPaths = @(
            "AGENT-INSTALL.md",
            ".agents\skills\1c-workflow\SKILL.md",
            ".agents\skills\1c-workflow\references\workflow.md",
            ".kilo\commands\itl-init-project.md"
        ) | ForEach-Object { Join-Path $RepoRoot $_ }

        foreach ($path in $docPaths) {
            $text = Get-Content -Encoding UTF8 -Raw $path
            $text | Should -Match ([regex]::Escape("run-agent-1c-window.ps1 -- -Action init-project -InitMode wizard"))
            $text | Should -Match "foreground"
            $text | Should -Match "background PowerShell"
            $text | Should -Match "KeepWindowOnFailure"
            $text | Should -Not -Match "(?m)^\s*powershell[^\r\n]*agent-1c\.ps1[^\r\n]*-Action\s+init-project\s+-InitMode\s+wizard"
        }

        $strictInitDocs = @(
            (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "AGENT-INSTALL.md")),
            (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".kilo\commands\itl-init-project.md"))
        ) -join [Environment]::NewLine
        $strictInitDocs | Should -Not -Match "Start-Process"
        $strictInitDocs | Should -Not -Match "-NoExit"
    }

    It "keeps advanced wrappers out of beginner command menus" {
        $advancedCommands = @(
            "/itl-init-project",
            "/itl-set-dev-branch-extension",
            "/itl-dump-dev-branch-extension",
            "/itl-vanessa-mcp",
            "/itl-update-rules"
        )

        $kiloMenuText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".kilo\commands\itl.md")
        foreach ($command in $advancedCommands) {
            $kiloMenuText | Should -Not -Match ([regex]::Escape($command))
        }

        $readmeText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "README.md")
        $readmeMenuMatch = [regex]::Match($readmeText, '(?s)```text\s*(?<commands>/itl\s+.*?/itl-switch[^\r\n]*.*?)```')
        $readmeMenuMatch.Success | Should -Be $true
        foreach ($command in $advancedCommands) {
            $readmeMenuMatch.Groups["commands"].Value | Should -Not -Match ([regex]::Escape($command))
        }

        $installText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "AGENT-INSTALL.md")
        $installMenuMatch = [regex]::Match($installText, '(?s)show only the short command surface:\s*```text(?<commands>.*?)```')
        $installMenuMatch.Success | Should -Be $true
        foreach ($command in $advancedCommands) {
            $installMenuMatch.Groups["commands"].Value | Should -Not -Match ([regex]::Escape($command))
        }

        $workflowText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\workflow.md")
        $shortSurfaceMatch = [regex]::Match($workflowText, "short command surface: (?<commands>.+?)\. These wrappers")
        $shortSurfaceMatch.Success | Should -Be $true
        foreach ($command in $advancedCommands) {
            $shortSurfaceMatch.Groups["commands"].Value | Should -Not -Match ([regex]::Escape($command))
        }
    }

    It "documents the helper action catalog in advanced actions" {
        $match = [regex]::Match($HelperText, '(?s)\[ValidateSet\((.*?)\)\]\s*\[string\]\$Action')
        $match.Success | Should -Be $true
        $quote = [string]([char]34)
        $actionPattern = [regex]::Escape($quote) + "(.+?)" + [regex]::Escape($quote)
        $allowedActions = @([regex]::Matches($match.Groups[1].Value, $actionPattern) | ForEach-Object { $_.Groups[1].Value })

        $advancedText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\advanced-actions.md")
        $advancedListMatch = [regex]::Match($advancedText, '(?s)Common internal actions:\s*```text(?<actions>.*?)```')
        $advancedListMatch.Success | Should -Be $true
        $advancedActions = @($advancedListMatch.Groups["actions"].Value -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        foreach ($action in ($allowedActions | Where-Object { $_ -ne "help" })) {
            ($advancedActions -contains $action) | Should -Be $true
        }

        foreach ($action in $advancedActions) {
            ($allowedActions -contains $action) | Should -Be $true
        }

        $advancedText | Should -Match ([regex]::Escape("/itl-set-dev-branch-extension"))
        $advancedText | Should -Match ([regex]::Escape("/itl-dump-dev-branch-extension"))
        $advancedText | Should -Match ([regex]::Escape("/itl-vanessa-mcp"))
        $advancedText | Should -Match "beginner"
    }

    It "forbids manual init questionnaire fallback when terminal input is unavailable" {
        $docTexts = @(
            (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "AGENT-INSTALL.md")),
            (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\SKILL.md")),
            (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\workflow.md")),
            (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".kilo\commands\itl-init-project.md"))
        )

        foreach ($text in $docTexts) {
            $text | Should -Match "terminal input is unavailable"
            $text | Should -Match "do not collect the (initialization )?questionnaire in chat"
            $text | Should -Match "do not continue the lifecycle manually"
        }

        ($docTexts -join [Environment]::NewLine) | Should -Not -Match "recovering from helper failure"
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

    It "wires vibecoding1c MCP actions, scopes, ports, registry, selection, and client config" {
        $actions = @("vibecoding1c-mcp-setup", "vibecoding1c-mcp-update", "vibecoding1c-mcp-status", "vibecoding1c-mcp-start", "vibecoding1c-mcp-stop", "vibecoding1c-mcp-select", "vibecoding1c-mcp-refresh-registry", "vibecoding1c-mcp-rotate-keys", "vibecoding1c-mcp-ensure-model", "vibecoding1c-mcp-write-client-config")
        foreach ($action in $actions) {
            $HelperText | Should -Match ([regex]::Escape("`"$action`""))
        }
        foreach ($oldAction in @("mcp-setup", "mcp-update", "mcp-status", "mcp-start", "mcp-stop", "mcp-select", "mcp-refresh-registry", "mcp-rotate-keys", "mcp-ensure-model", "mcp-write-client-config")) {
            $HelperText | Should -Not -Match "(?<!vibecoding1c-)(?<!vanessa-)$([regex]::Escape($oldAction))(?![A-Za-z0-9-])"
        }
        foreach ($parameter in @('$McpProvider', '$McpConfigId', '$McpHostId', '$McpLocalScope')) {
            $HelperText | Should -Match ([regex]::Escape($parameter))
        }

        $HelperText | Should -Match "itl-1c-docs"
        $HelperText | Should -Match "itl-1c-templates"
        $HelperText | Should -Match "itl-1c-syntax"
        $HelperText | Should -Match "itl-1c-codechecker"
        $HelperText | Should -Match "itl-{projectSlug}-code"
        $HelperText | Should -Match "itl-{projectSlug}-graph"
        $HelperText | Should -Not -Match "itl-{projectSlug}-{branchSlug}-vanessa"
        $HelperText | Should -Not -Match "localVanessa"
        foreach ($portMarker in @("18000", "18100", "18500", "19000")) {
            $HelperText | Should -Match $portMarker
        }
        foreach ($internalPort in @("8000", "8002", "8003", "8004", "8006", "8007", "8008")) {
            $HelperText | Should -Match $internalPort
        }
        $HelperText | Should -Match "host.docker.internal"
        $HelperText | Should -Match "Qwen3-Embedding-4B-GGUF"
        $HelperText | Should -Match "intfloat/multilingual-e5-small"
        $HelperText | Should -Match "lms server start --port"
        $HelperText | Should -Match "mcp_servers"
        $HelperText | Should -Match "managedBy"
        $HelperText | Should -Match "family = `"vibecoding1c`""
        $HelperText | Should -Match "managedBy = `"vibecoding1c-mcp`""
        $HelperText | Should -Match ([regex]::Escape("http://gitlabserv01.itland.local/root/MCP-vibecoding1c.git"))
        $HelperText | Should -Match ([regex]::Escape("http://gitlabserv01.itland.local/root/MCP-vibecoding1c-registry.git"))
        $HelperText | Should -Match "VIBECODING1C_MCP_DISTRIBUTION_REPO"
        $HelperText | Should -Match "VIBECODING1C_MCP_REGISTRY_REPO"
        $HelperText | Should -Match "vibecoding1c-selection.json"
        $HelperText | Should -Match "Get-Vibecoding1cMcpSelectionCompleteness"
        $HelperText | Should -Match "vibecoding1c MCP selection is missing or incomplete"
        $HelperText | Should -Match "Force was specified; running vibecoding1c MCP selection"
        $HelperText | Should -Match "remote-shared"
        $HelperText | Should -Match "Get-Vibecoding1cMcpStatusSummary"
        $HelperText | Should -Match "vibecoding1c MCP skipped servers"
        $HelperText | Should -Match "vibecoding1c MCP stale servers"
        $HelperText | Should -Match "vibecoding1c MCP missing-configId servers"
        $HelperText | Should -Not -Match ([regex]::Escape("D:\Git\MCP vibecoding1c"))
        $HelperText | Should -Not -Match "-p 8000:8000"
        $HelperText | Should -Not -Match "-p 8006:8006"
        $HelperText | Should -Not -Match "ITL_MCP"
        $HelperText | Should -Not -Match "ITL MCP"
        $HelperText | Should -Not -Match "/itl-mcp"
        $HelperText | Should -Not -Match "itl-mcp"
        $HelperText | Should -Not -Match "(?<![A-Za-z0-9])mcpSetupDuringInit"

        (Test-Path -LiteralPath (Join-Path $RepoRoot ".kilo\commands\itl-vibecoding1c-mcp.md") -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $RepoRoot ".kilo\commands\itl-mcp.md") -PathType Leaf) | Should -Be $false
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".kilo\commands\itl.md")) | Should -Match "/itl-vibecoding1c-mcp"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "README.md")) | Should -Match "/itl-vibecoding1c-mcp"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "AGENT-INSTALL.md")) | Should -Match "/itl-vibecoding1c-mcp"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "VIBECODING1C_MCP_DISTRIBUTION_PATH"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "VIBECODING1C_MCP_DISTRIBUTION_REPO"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "VIBECODING1C_MCP_REGISTRY_PATH"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "VIBECODING1C_MCP_REGISTRY_REPO"
        $projectTemplate = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\project.json")
        $projectTemplate | Should -Match "vibecoding1cMcp"
        $projectTemplate | Should -Match "providerDefault"
        $projectTemplate | Should -Not -Match '"mcp"\s*:'
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "PATH_METADATA"
    }

    It "wires standalone MCP host tooling and registry schema" {
        (Test-Path -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\install-vibecoding1c-mcp-host.ps1") -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\export-1c-config-dump.ps1") -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\host.config.example.json") -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $RepoRoot "vibecoding1c-mcp-host\README.md") -PathType Leaf) | Should -Be $true

        $hostConfig = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "vibecoding1c-mcp-host\host.config.example.json") | ConvertFrom-Json
        $hostConfig.registryRepo | Should -Be "http://gitlabserv01.itland.local/root/MCP-vibecoding1c-registry.git"
        $hostConfig.pythonPath | Should -Be "python"
        $hostConfig.embedding.PSObject.Properties["apiBase"] | Should -BeNullOrEmpty
        $hostConfig.embedding.PSObject.Properties["apiKey"] | Should -BeNullOrEmpty
        $hostConfig.embedding.model | Should -Be "intfloat/multilingual-e5-base"
        $hostConfig.codeMetadataSearchServer.resetDatabase | Should -Be $false
        $hostConfig.codeMetadataSearchServer.PSObject.Properties["reindexIntervalHours"] | Should -Not -BeNullOrEmpty
        $hostConfig.graphMetadataSearchServer.resetDatabase | Should -Be $false
        $hostConfig.graphMetadataSearchServer.PSObject.Properties["reindexIntervalHours"] | Should -Not -BeNullOrEmpty
        $hostConfig.graphMetadataSearchServer.autoUpdateOnStartup | Should -Be $true
        $hostConfig.configurations[0].configId | Should -Be "trade"
        $hostConfig.configurations[0].sourceRepo | Should -Match "trade-config-dump"
        $hostConfig.configurations[1].sourcePath | Should -Match "trade-local"
        $hostConfig.configurations[1].dump.repositoryPath | Should -Match "tcp://"
        $hostConfig.secrets.ONEC_AI_TOKEN | Should -Match "^<"
        $hostConfig.helpSearchServer.platformVersion | Should -Match "8\.3\."
        $hostConfig.helpSearchServer.platformBinPath | Should -Match "1cv8"
        $hostConfig.sslSearchServer.bspVersion | Should -Match "3\."
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape("vibecoding1c-mcp-host/host.config.json"))
        $McpHostText | Should -Match "norkins/metadata"
        $McpHostText | Should -Match "Invoke-PythonMetadataGenerator"
        $McpHostText | Should -Match "Ensure-PythonRuntime"
        $McpHostText | Should -Match "Resolve-PythonExecutable"
        $McpHostText | Should -Match "pythonPath"
        $McpHostText | Should -Match "Python 3 runtime check failed"
        $McpHostText | Should -Match "function Invoke-Git"
        $McpHostText | Should -Match '& git -C \$Root @Arguments 2>&1'
        $McpHostText | Should -Match 'Invoke-Git -Root \$parent -Arguments @\("clone", \$Repo, \$Path\)'
        $McpHostText | Should -Match "Write-MetadataDiagnosticsSummary"
        $McpHostText | Should -Match "Write-HostPhase"
        $McpHostText | Should -Match "Refreshing metadata for configId"
        $McpHostText | Should -Match "Running norkins/metadata report generation"
        $McpHostText | Should -Match "Report.txt ready for configId"
        $McpHostText | Should -Match "Container ready:"
        $McpHostText | Should -Match "Enabled global servers:"
        $McpHostText | Should -Match "Enabled project servers:"
        $McpHostText | Should -Match 'exitCode -eq 1'
        $McpHostText | Should -Match "with warnings"
        $McpHostText | Should -Match "did not create Report.txt"
        $McpHostText | Should -Match "norkins-metadata-"
        $McpHostText | Should -Match "mainConfigPath was not found"
        $McpHostText | Should -Match "Generator config:"
        $McpHostText | Should -Match "Python log:"
        $McpHostText | Should -Match "registry.json"
        $McpHostText | Should -Match "family"
        $McpHostText | Should -Match "sourceFingerprint"
        $McpHostText | Should -Match "dump-config"
        $McpHostText | Should -Match '"reindex"'
        $McpHostText | Should -Match "Invoke-HostReindex"
        $McpHostText | Should -Match "Update-HostStateServers"
        $McpHostText | Should -Match "ForceResetDatabase"
        $McpHostText | Should -Match "Test-HostServerSupportsDatabaseReset"
        $McpHostText | Should -Match "Reindexing database-backed MCP servers"
        $McpHostText | Should -Match "standalone-cpu-embedding-placeholder"
        $McpHostText | Should -Match "Invoke-HostConfigDumpHelper"
        $McpHostText | Should -Match 'Refresh-HostConfigurations -Config \$config -TargetConfigId \$ConfigId'
        $McpHostText | Should -Match "sourcePath"
        $McpHostText | Should -Match "Ensure-HostEmbeddingModel"
        $McpHostText | Should -Match "Test-HostEmbeddingModelPresent"
        $McpHostText | Should -Match "Get-HostEmbeddingModelsUri"
        $McpHostText | Should -Match "lms server start --port"
        $McpHostText | Should -Match "ONEC_AI_TOKEN"
        $McpHostText | Should -Match "PATH_1C_BIN"
        $McpHostText | Should -Match "PLATFORM_VERSION"
        $McpHostText | Should -Match "SSL_VERSION"
        $McpHostText | Should -Match "BSP_VERSION"
        $McpHostText | Should -Match "ConfigurationRepositoryUpdateCfg"
        $McpHostText | Should -Match "DumpConfigToFiles"
        $McpHostText | Should -Match "ConfigDumpInfo.xml"
        $McpHostDumpText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "vibecoding1c-mcp-host\export-1c-config-dump.ps1")
        $nativeEmptyStringFunction = [regex]::Match($McpHostDumpText, '(?s)function ConvertTo-NativeEmptyStringArgument \{.*?\n\}')
        $nativeEmptyStringFunction.Success | Should -Be $true
        $nativeEmptyStringFunction.Value | Should -Match 'return ""'
        $nativeEmptyStringFunction.Value | Should -Not -Match 'return ''""'''
        $McpHostText | Should -Match "Invoke-DockerCommand"
        $McpHostText | Should -Match '"image", "inspect"'
        $McpHostText | Should -Match '"pull", \$Image'
        $McpHostText | Should -Match 'Write-Host \(\[string\]\$line\)'
        $McpHostText | Should -Match "Invoke-ProcessWithTimeout"
        $McpHostText | Should -Match "Invoke-DockerCommandChecked"
        $McpHostText | Should -Match "Invoke-DockerCommandCapture"
        $McpHostText | Should -Match "Command timed out after"
        $McpHostText | Should -Match "read-only file system"
        $McpHostText | Should -Not -Match '(?m)^\s*LICENSE_KEY_[A-Z0-9_]+\s*=\s*[^#\s]+'
    }

    It "keeps config-specific MCP host servers project-scoped for legacy manifests and configs" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-scope-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                enabledServers = [ordered]@{
                    global = @("docs", "graph")
                    project = @("code")
                }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                $legacyGraph = [pscustomobject]@{ id = "graph" }
                $globalGraph = [pscustomobject]@{ id = "graph"; scope = "global" }

                Get-ServerScope -Server $legacyGraph | Should -Be "project"
                Get-ServerScope -Server $globalGraph | Should -Be "project"
                Get-EnabledServerIds -Config $hostConfig -Scope "global" | Should -Not -Contain "graph"
                Get-EnabledServerIds -Config $hostConfig -Scope "project" | Should -Contain "graph"
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "does not let blank distribution PATH settings shadow host-generated config paths" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-path-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            $stateRoot = Join-Path $tempRoot "state"
            New-Item -ItemType Directory -Force -Path (Join-Path $stateRoot "distribution") | Out-Null
            Set-Content -LiteralPath (Join-Path $stateRoot "distribution\config.env") -Encoding UTF8 -Value "PATH_METADATA=`nPATH_CODE=`n"

            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = $stateRoot
                enabledServers = [ordered]@{ global = @(); project = @("graph") }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                $configState = [pscustomobject]@{
                    configId = "pm5corp"
                    metadataRoot = (Join-Path $tempRoot "metadata")
                    sourceRoot = (Join-Path $tempRoot "source")
                    mainConfigPath = "src/cf"
                }
                $server = [pscustomobject]@{
                    id = "graph"
                    env = @([ordered]@{ name = "METADATA_HOST_PATH"; from = "PATH_METADATA"; required = $true })
                }

                $envValues = Resolve-ServerEnv -Config $hostConfig -Server $server -ConfigState $configState

                $envValues["METADATA_HOST_PATH"] | Should -Be $configState.metadataRoot
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "falls back graph chat OpenAI settings to host embedding settings" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-graph-openai-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            $stateRoot = Join-Path $tempRoot "state"
            New-Item -ItemType Directory -Force -Path (Join-Path $stateRoot "distribution") | Out-Null
            Set-Content -LiteralPath (Join-Path $stateRoot "distribution\config.env") -Encoding UTF8 -Value "CHAT_API_KEY=`nCHAT_API_BASE=`nCHAT_MODEL=`n"

            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = $stateRoot
                embedding = [ordered]@{
                    apiBase = "http://host.docker.internal:19000/v1"
                    apiKey = "lm-studio"
                    model = "fixture-embedding-model"
                }
                enabledServers = [ordered]@{ global = @(); project = @("graph") }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                $server = [pscustomobject]@{
                    id = "graph"
                    embedding = $true
                    env = @(
                        [ordered]@{ name = "OPENAI_API_KEY"; from = "CHAT_API_KEY"; required = $false },
                        [ordered]@{ name = "OPENAI_API_BASE"; from = "CHAT_API_BASE"; required = $false },
                        [ordered]@{ name = "OPENAI_MODEL"; from = "CHAT_MODEL"; required = $false }
                    )
                }

                $envValues = Resolve-ServerEnv -Config $hostConfig -Server $server

                $envValues["OPENAI_API_KEY"] | Should -Be "lm-studio"
                $envValues["OPENAI_API_BASE"] | Should -Be "http://host.docker.internal:19000/v1"
                $envValues["OPENAI_MODEL"] | Should -Be "fixture-embedding-model"
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "isolates standalone PATH_BASES volumes by config and server" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-bases-volume-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                enabledServers = [ordered]@{ global = @(); project = @("code") }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                $server = [pscustomobject]@{
                    id = "code"
                    scope = "project"
                    volumes = @([ordered]@{ from = "PATH_BASES"; to = "/app/chroma_db"; required = $false; subdir = "mcp_codemetadata" })
                }
                $tradeState = [pscustomobject]@{ configId = "trade"; sourceRoot = $tempRoot; mainConfigPath = "."; metadataRoot = $tempRoot }
                $pmState = [pscustomobject]@{ configId = "pm5corp"; sourceRoot = $tempRoot; mainConfigPath = "."; metadataRoot = $tempRoot }

                $tradeVolumes = @(Resolve-ServerVolumes -Config $hostConfig -Server $server -ConfigState $tradeState)
                $pmVolumes = @(Resolve-ServerVolumes -Config $hostConfig -Server $server -ConfigState $pmState)

                $tradeVolume = $tradeVolumes | Where-Object { $_.container -eq "/app/chroma_db" } | Select-Object -First 1
                $pmVolume = $pmVolumes | Where-Object { $_.container -eq "/app/chroma_db" } | Select-Object -First 1
                $tradeVolume.host | Should -Be (Join-Path (Join-Path (Join-Path $hostConfig.stateRoot "bases") "trade") "code\mcp_codemetadata")
                $pmVolume.host | Should -Be (Join-Path (Join-Path (Join-Path $hostConfig.stateRoot "bases") "pm5corp") "code\mcp_codemetadata")
                $tradeVolume.host | Should -Not -Be $pmVolume.host
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "supplies a placeholder graph OpenAI key in standalone CPU embedding mode" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-graph-cpu-key-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            $stateRoot = Join-Path $tempRoot "state"
            New-Item -ItemType Directory -Force -Path (Join-Path $stateRoot "distribution") | Out-Null
            Set-Content -LiteralPath (Join-Path $stateRoot "distribution\config.env") -Encoding UTF8 -Value "CHAT_API_KEY=`nCHAT_API_BASE=`nCHAT_MODEL=`n"

            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = $stateRoot
                embedding = [ordered]@{ model = "intfloat/multilingual-e5-base" }
                enabledServers = [ordered]@{ global = @(); project = @("graph") }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                $graphServer = [pscustomobject]@{
                    id = "graph"
                    embedding = $true
                    env = @(
                        [ordered]@{ name = "OPENAI_API_KEY"; from = "CHAT_API_KEY"; required = $false },
                        [ordered]@{ name = "OPENAI_API_BASE"; from = "CHAT_API_BASE"; required = $false },
                        [ordered]@{ name = "OPENAI_MODEL"; from = "CHAT_MODEL"; required = $false }
                    )
                }
                $codeServer = [pscustomobject]@{
                    id = "code"
                    embedding = $true
                    env = @(
                        [ordered]@{ name = "OPENAI_API_BASE"; embedding = "base"; required = $true },
                        [ordered]@{ name = "OPENAI_API_KEY"; embedding = "key"; required = $true },
                        [ordered]@{ name = "OPENAI_MODEL"; embedding = "model"; required = $true }
                    )
                }

                $graphEnv = Resolve-ServerEnv -Config $hostConfig -Server $graphServer
                $graphEnv["OPENAI_API_KEY"] | Should -Be "standalone-cpu-embedding-placeholder"
                $graphEnv.Contains("OPENAI_API_BASE") | Should -Be $false
                $graphEnv.Contains("OPENAI_MODEL") | Should -Be $false
                $graphEnv["EMBEDDING_MODEL"] | Should -Be "intfloat/multilingual-e5-base"

                $codeEnv = Resolve-ServerEnv -Config $hostConfig -Server $codeServer
                $codeEnv.Contains("OPENAI_API_KEY") | Should -Be $false
                $codeEnv.Contains("OPENAI_API_BASE") | Should -Be $false
                $codeEnv.Contains("OPENAI_MODEL") | Should -Be $false
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "uses standalone CPU embedding model without OpenAI env, lms, or LM Studio bootstrap" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-cpu-embedding-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                embedding = [ordered]@{
                    model = "intfloat/multilingual-e5-base"
                }
                enabledServers = [ordered]@{ global = @(); project = @("code") }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $script:HostCpuLmsWasCalled = $false
                function Get-HostLmsCommand {
                    $script:HostCpuLmsWasCalled = $true
                    return $null
                }

                $hostConfig = Read-JsonFile -Path $configPath
                $server = [pscustomobject]@{
                    id = "code"
                    scope = "project"
                    embedding = $true
                    env = @(
                        [ordered]@{ name = "OPENAI_API_BASE"; embedding = "base"; required = $true },
                        [ordered]@{ name = "OPENAI_API_KEY"; embedding = "key"; required = $true },
                        [ordered]@{ name = "OPENAI_MODEL"; embedding = "model"; required = $true }
                    )
                }
                $manifest = [pscustomobject]@{ servers = @($server) }

                Ensure-HostEmbeddingModel -Config $hostConfig -Manifest $manifest -GlobalServerIds @() -ProjectServerIds @("code")
                $script:HostCpuLmsWasCalled | Should -Be $false

                $envValues = Resolve-ServerEnv -Config $hostConfig -Server $server
                $envValues["EMBEDDING_MODEL"] | Should -Be "intfloat/multilingual-e5-base"
                $envValues.Contains("OPENAI_API_BASE") | Should -Be $false
                $envValues.Contains("OPENAI_API_KEY") | Should -Be $false
                $envValues.Contains("OPENAI_MODEL") | Should -Be $false
                $envValues["RESET_CACHE"] | Should -Be "false"

                $volumes = @(Resolve-ServerVolumes -Config $hostConfig -Server $server)
                @($volumes | Where-Object { $_.container -eq "/app/model_cache" }).Count | Should -Be 1
                (Test-Path -LiteralPath (Join-Path $hostConfig.stateRoot "model-cache") -PathType Container) | Should -Be $true
                Remove-Variable -Scope Script -Name HostCpuLmsWasCalled -ErrorAction SilentlyContinue
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "maps standalone CodeMetadata and Graph index settings to server env" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-index-env-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                embedding = [ordered]@{ model = "intfloat/multilingual-e5-base" }
                codeMetadataSearchServer = [ordered]@{
                    resetDatabase = $true
                    reindexIntervalHours = 6
                }
                graphMetadataSearchServer = [ordered]@{
                    resetDatabase = $false
                    reindexIntervalHours = 12
                    autoUpdateOnStartup = $false
                }
                enabledServers = [ordered]@{ global = @(); project = @("code", "graph") }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath

                $codeEnv = Resolve-ServerEnv -Config $hostConfig -Server ([pscustomobject]@{ id = "code"; scope = "project"; embedding = $false; env = @() })
                $codeEnv["RESET_DATABASE"] | Should -Be "true"
                $codeEnv["REINDEX_INTERVAL_HOURS"] | Should -Be "6"

                $graphEnv = Resolve-ServerEnv -Config $hostConfig -Server ([pscustomobject]@{ id = "graph"; scope = "project"; embedding = $false; env = @() })
                $graphEnv["RESET_DATABASE"] | Should -Be "false"
                $graphEnv["REINDEX_INTERVAL_HOURS"] | Should -Be "12"
                $graphEnv["AUTO_UPDATE_ON_STARTUP"] | Should -Be "false"

                $codeReindexEnv = Resolve-ServerEnv -Config $hostConfig -Server ([pscustomobject]@{ id = "code"; scope = "project"; embedding = $true; env = @() }) -ForceResetDatabase
                $codeReindexEnv["RESET_DATABASE"] | Should -Be "true"

                $docsSetupEnv = Resolve-ServerEnv -Config $hostConfig -Server ([pscustomobject]@{
                    id = "docs"
                    scope = "global"
                    embedding = $true
                    env = @([ordered]@{ name = "RESET_CACHE"; value = "true" })
                })
                $docsSetupEnv["RESET_CACHE"] | Should -Be "false"
                $docsSetupEnv["EMBEDDING_MODEL"] | Should -Be "intfloat/multilingual-e5-base"

                $docsReindexEnv = Resolve-ServerEnv -Config $hostConfig -Server ([pscustomobject]@{
                    id = "docs"
                    scope = "global"
                    embedding = $true
                    env = @([ordered]@{ name = "RESET_CACHE"; value = "true" })
                }) -ForceResetDatabase
                $docsReindexEnv["RESET_CACHE"] | Should -Be "false"
                $docsReindexEnv.Contains("RESET_DATABASE") | Should -Be $false
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "extracts configuration name and version from Configuration.xml and tolerates a missing file" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-config-xml-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        $mainRoot = Join-Path $tempRoot "src\cf"

        try {
            New-Item -ItemType Directory -Force -Path $mainRoot | Out-Null
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (@{ schemaVersion = 1; stateRoot = (Join-Path $tempRoot "state") } | ConvertTo-Json)
            Set-Content -LiteralPath (Join-Path $mainRoot "Configuration.xml") -Encoding UTF8 -Value @"
<MetaDataObject xmlns="http://v8.1c.ru/8.3/MDClasses">
  <Configuration uuid="fixture">
    <Properties>
      <Name>TradeManagement</Name>
      <Version>11.5.10.99</Version>
    </Properties>
  </Configuration>
</MetaDataObject>
"@

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $info = Read-ConfigurationXmlInfo -MainConfigRoot $mainRoot -FallbackName "Fallback"
                $info.configurationName | Should -Be "TradeManagement"
                $info.configurationVersion | Should -Be "11.5.10.99"

                $missing = Read-ConfigurationXmlInfo -MainConfigRoot (Join-Path $tempRoot "missing") -FallbackName "Fallback"
                $missing.configurationName | Should -Be "Fallback"
                $missing.configurationVersion | Should -Be ""
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "merges standalone registry v2 hosts without overwriting another host" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-registry-v2-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        $registryPath = Join-Path $tempRoot "state\registry\registry.json"

        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $registryPath) | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "host-a"
                baseUrl = "http://host-a"
                stateRoot = (Join-Path $tempRoot "state")
                embedding = [ordered]@{ model = "intfloat/multilingual-e5-base" }
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
            $existing = [ordered]@{
                schemaVersion = 2
                publishedAt = "2026-07-04T00:00:00Z"
                hosts = @([ordered]@{
                    hostId = "host-b"
                    baseUrl = "http://host-b"
                    publishedAt = "2026-07-04T00:00:00Z"
                    configurations = @([ordered]@{ configId = "trade"; title = "Trade B" })
                    servers = @([ordered]@{ id = "code"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-code"; url = "http://host-b:18100/mcp"; image = "image-b"; health = "running" })
                })
                configurations = @()
                servers = @()
            }
            Set-Content -LiteralPath $registryPath -Encoding UTF8 -Value (($existing | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $hostConfig = Read-JsonFile -Path $configPath
                $state = [ordered]@{
                    schemaVersion = 1
                    configurations = @([ordered]@{
                        configId = "trade"
                        title = "Trade A"
                        configurationName = "Trade A Name"
                        configurationVersion = "1.0"
                        reportHash = "abc"
                        indexedAt = "2026-07-05T00:00:00Z"
                    })
                    servers = @([ordered]@{
                        id = "code"
                        scope = "project"
                        family = "vibecoding1c"
                        provider = "remote"
                        configId = "trade"
                        name = "itl-trade-code"
                        url = "http://host-a:18100/mcp"
                        image = "image-a"
                        health = "running"
                        configurationName = "Trade A Name"
                        configurationVersion = "1.0"
                        embeddingMode = "cpu"
                        embeddingModel = "intfloat/multilingual-e5-base"
                        indexedAt = "2026-07-05T00:00:00Z"
                    })
                }
                Write-HostState -Config $hostConfig -State $state
                Write-MergedRegistryPayload -Config $hostConfig -RegistryPath $registryPath -PublishedAt "2026-07-05T00:00:00Z"
                $registry = Read-JsonFile -Path $registryPath

                @($registry.hosts).Count | Should -Be 2
                @($registry.hosts | Where-Object { $_.hostId -eq "host-b" }).Count | Should -Be 1
                @($registry.servers | Where-Object { $_.hostId -eq "host-a" -and $_.embeddingModel -eq "intfloat/multilingual-e5-base" }).Count | Should -Be 1
                ($registry.servers | Where-Object { $_.hostId -eq "host-a" -and $_.id -eq "code" } | Select-Object -First 1).clientNames.aiRules1c | Should -Be "1c-code-metadata-mcp"
                (Read-HostState -Config $hostConfig).servers[0].clientNames.aiRules1c | Should -Be "1c-code-metadata-mcp"
                @($registry.configurations | Where-Object { $_.hostId -eq "host-a" -and $_.configurationName -eq "Trade A Name" }).Count | Should -Be 1
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "refreshes standalone publish state statuses without starting containers or changing index metadata" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-publish-refresh-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"
        $registryPath = Join-Path $tempRoot "state\registry\registry.json"

        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $registryPath) | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "host-a"
                baseUrl = "http://host-a"
                stateRoot = (Join-Path $tempRoot "state")
                embedding = [ordered]@{ model = "intfloat/multilingual-e5-base" }
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
            Set-Content -LiteralPath $registryPath -Encoding UTF8 -Value (([ordered]@{ schemaVersion = 2; hosts = @(); configurations = @(); servers = @() } | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $script:PublishDockerCalls = New-Object System.Collections.Generic.List[string]
                function Invoke-DockerCommandCapture {
                    param([string[]]$Arguments, [int]$TimeoutSec = 300, [string]$Description = "docker command")
                    $script:PublishDockerCalls.Add("capture:$($Arguments -join ' ')")
                    $name = $Arguments[-1]
                    switch ($name) {
                        "itl-trade-code" { return @("exited") }
                        "itl-trade-graph" { return @("running") }
                        "itl-1c-docs" { throw "No such object: $name" }
                        "itl-1c-ssl" { return @("running") }
                        "itl-1c-syntax" { throw "Cannot connect to the Docker daemon" }
                        default { throw "Unexpected docker inspect for $name" }
                    }
                }
                function Invoke-DockerCommandChecked {
                    param([string[]]$Arguments, [int]$TimeoutSec = 300, [string]$Description = "docker command")
                    $script:PublishDockerCalls.Add("checked:$($Arguments -join ' ')")
                    throw "publish refresh must not run docker checked commands"
                }
                function Test-HostTcpPortOpen {
                    param([int]$Port, [int]$TimeoutMilliseconds = 500)
                    return ($Port -eq 18004)
                }

                $hostConfig = Read-JsonFile -Path $configPath
                $state = [ordered]@{
                    schemaVersion = 1
                    configurations = @()
                    servers = @(
                        [ordered]@{ id = "code"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-code"; containerName = "itl-trade-code"; hostPort = 18100; url = "http://host-a:18100/mcp"; image = "image-code"; sourceFingerprint = "fp-code"; reportHash = "hash-code"; indexedAt = "2026-07-05T00:00:00Z" },
                        [ordered]@{ id = "graph"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-graph"; containerName = "itl-trade-graph"; hostPort = 18101; url = "http://host-a:18101/mcp"; image = "image-graph"; sourceFingerprint = "fp-graph"; reportHash = "hash-graph"; indexedAt = "2026-07-05T01:00:00Z" },
                        [ordered]@{ id = "docs"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-docs"; containerName = "itl-1c-docs"; hostPort = 18000; url = "http://host-a:18000/mcp"; image = "image-docs" },
                        [ordered]@{ id = "ssl"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-ssl"; containerName = "itl-1c-ssl"; hostPort = 18004; url = "http://host-a:18004/mcp"; image = "image-ssl" },
                        [ordered]@{ id = "syntax"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-syntax"; containerName = "itl-1c-syntax"; hostPort = 18003; url = "http://host-a:18003/mcp"; image = "image-syntax" }
                    )
                }
                Write-HostState -Config $hostConfig -State $state
                Write-MergedRegistryPayload -Config $hostConfig -RegistryPath $registryPath -PublishedAt "2026-07-05T00:00:00Z"

                $updatedState = Read-HostState -Config $hostConfig
                $registry = Read-JsonFile -Path $registryPath
                $stateServers = @($updatedState.servers)
                $registryServers = @($registry.servers | Where-Object { $_.hostId -eq "host-a" })

                ($stateServers | Where-Object { $_.id -eq "code" } | Select-Object -First 1).status | Should -Be "stopped"
                ($stateServers | Where-Object { $_.id -eq "graph" } | Select-Object -First 1).status | Should -Be "unreachable"
                ($stateServers | Where-Object { $_.id -eq "docs" } | Select-Object -First 1).status | Should -Be "missing"
                ($stateServers | Where-Object { $_.id -eq "ssl" } | Select-Object -First 1).status | Should -Be "running"
                ($stateServers | Where-Object { $_.id -eq "syntax" } | Select-Object -First 1).status | Should -Be "unknown"

                ($registryServers | Where-Object { $_.id -eq "code" } | Select-Object -First 1).status | Should -Be "stopped"
                ($registryServers | Where-Object { $_.id -eq "graph" } | Select-Object -First 1).status | Should -Be "unreachable"
                ($registryServers | Where-Object { $_.id -eq "docs" } | Select-Object -First 1).status | Should -Be "missing"
                ($registryServers | Where-Object { $_.id -eq "ssl" } | Select-Object -First 1).status | Should -Be "running"
                ($registryServers | Where-Object { $_.id -eq "syntax" } | Select-Object -First 1).status | Should -Be "unknown"
                ($registryServers | Where-Object { $_.id -eq "code" } | Select-Object -First 1).clientNames.aiRules1c | Should -Be "1c-code-metadata-mcp"
                ($registryServers | Where-Object { $_.id -eq "graph" } | Select-Object -First 1).sourceFingerprint | Should -Be "fp-graph"
                ($registryServers | Where-Object { $_.id -eq "graph" } | Select-Object -First 1).reportHash | Should -Be "hash-graph"
                ($registryServers | Where-Object { $_.id -eq "graph" } | Select-Object -First 1).indexedAt | Should -Be "2026-07-05T01:00:00Z"
                @($script:PublishDockerCalls | Where-Object { $_ -match "checked:| start | run | compose up" }).Count | Should -Be 0
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "starts existing standalone Docker containers through timeout wrappers" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-docker-timeout-wrapper-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                embedding = [ordered]@{ model = "intfloat/multilingual-e5-base" }
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $script:HostDockerWrapperCalls = New-Object System.Collections.Generic.List[string]
                function Invoke-DockerCommandCapture {
                    param([string[]]$Arguments, [int]$TimeoutSec = 300, [string]$Description = "docker command")
                    $script:HostDockerWrapperCalls.Add("capture:${TimeoutSec}:${Description}:$($Arguments -join ' ')")
                    return @("itl-1c-ssl")
                }
                function Invoke-DockerCommandChecked {
                    param([string[]]$Arguments, [int]$TimeoutSec = 300, [string]$Description = "docker command")
                    $script:HostDockerWrapperCalls.Add("checked:${TimeoutSec}:${Description}:$($Arguments -join ' ')")
                }

                $hostConfig = Read-JsonFile -Path $configPath
                $server = [pscustomobject]@{ id = "ssl"; embedding = $false }
                $runtime = [pscustomobject]@{
                    containerName = "itl-1c-ssl"
                    hostPort = 18004
                    internalPort = 8008
                    image = "fixture"
                    url = "http://localhost:18004/mcp"
                }
                Start-DockerServer -Config $hostConfig -Server $server -Runtime $runtime

                $calls = @($script:HostDockerWrapperCalls)
                $calls[0] | Should -Match "^capture:60:docker ps for itl-1c-ssl:"
                $calls[1] | Should -Be "checked:120:docker start itl-1c-ssl:start itl-1c-ssl"
                Remove-Variable -Scope Script -Name HostDockerWrapperCalls -ErrorAction SilentlyContinue
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "checks standalone embedding readiness by configured model id" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-embedding-ready-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                enabledServers = [ordered]@{ global = @(); project = @() }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $smallResponse = [pscustomobject]@{
                    data = @([pscustomobject]@{ id = "intfloat/multilingual-e5-small" })
                }
                $baseResponse = [pscustomobject]@{
                    data = @([pscustomobject]@{ id = "intfloat/multilingual-e5-base" })
                }

                Test-HostEmbeddingModelPresent -Response $smallResponse -Model "intfloat/multilingual-e5-base" | Should -Be $false
                Test-HostEmbeddingModelPresent -Response $baseResponse -Model "intfloat/multilingual-e5-base" | Should -Be $true
                Get-HostEmbeddingModelsUri -ApiBase "http://host.docker.internal:19000/v1" | Should -Be "http://127.0.0.1:19000/v1/models"
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "requires and propagates standalone host embedding.model" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-embedding-model-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                embedding = [ordered]@{
                    apiBase = "http://host.docker.internal:19000/v1"
                    apiKey = "lm-studio"
                    model = "intfloat/multilingual-e5-base"
                }
                enabledServers = [ordered]@{ global = @(); project = @() }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $missingModelConfig = [pscustomobject]@{
                    embedding = [pscustomobject]@{
                        apiBase = "http://host.docker.internal:19000/v1"
                        apiKey = "lm-studio"
                    }
                }
                { Get-HostEmbeddingSettings -Config $missingModelConfig } | Should -Throw "*embedding.model is required*"

                $hostConfig = Read-JsonFile -Path $configPath
                $server = [pscustomobject]@{
                    id = "code"
                    env = @([ordered]@{ name = "OPENAI_MODEL"; embedding = "model"; required = $true })
                }

                $envValues = Resolve-ServerEnv -Config $hostConfig -Server $server

                $envValues["OPENAI_MODEL"] | Should -Be "intfloat/multilingual-e5-base"
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "fails clearly before container start when local standalone embedding needs lms and lms is missing" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-missing-lms-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                embedding = [ordered]@{
                    apiBase = "http://host.docker.internal:19000/v1"
                    apiKey = "lm-studio"
                    model = "intfloat/multilingual-e5-base"
                }
                enabledServers = [ordered]@{ global = @(); project = @() }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                function Test-HostEmbeddingEndpointReady {
                    param([string]$ApiBase, [string]$Model)
                    return $false
                }
                function Get-HostLmsCommand {
                    return $null
                }

                $hostConfig = Read-JsonFile -Path $configPath
                $manifest = [pscustomobject]@{
                    servers = @([pscustomobject]@{ id = "code"; scope = "project"; embedding = $true })
                }

                {
                    Ensure-HostEmbeddingModel -Config $hostConfig -Manifest $manifest -GlobalServerIds @() -ProjectServerIds @("code")
                } | Should -Throw "*needs LM Studio CLI 'lms'*"
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "loads missing standalone embedding model through lms before declaring readiness" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-lms-bootstrap-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                embedding = [ordered]@{
                    apiBase = "http://host.docker.internal:19000/v1"
                    apiKey = "lm-studio"
                    model = "intfloat/multilingual-e5-base"
                }
                enabledServers = [ordered]@{ global = @(); project = @() }
                configurations = @()
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $script:HostLmsBootstrapCalls = New-Object System.Collections.Generic.List[string]
                $script:HostLmsBootstrapProbeCount = 0
                function Test-HostEmbeddingEndpointReady {
                    param([string]$ApiBase, [string]$Model)
                    $script:HostLmsBootstrapProbeCount++
                    return ($script:HostLmsBootstrapProbeCount -gt 1)
                }
                function Get-HostLmsCommand {
                    return [pscustomobject]@{ Source = "lms" }
                }
                function Invoke-HostLmsCommand {
                    param([string[]]$Arguments)
                    $script:HostLmsBootstrapCalls.Add(($Arguments -join " "))
                    return [pscustomobject]@{ exitCode = 0; output = "" }
                }

                $hostConfig = Read-JsonFile -Path $configPath
                $manifest = [pscustomobject]@{
                    servers = @([pscustomobject]@{ id = "code"; scope = "project"; embedding = $true })
                }

                Ensure-HostEmbeddingModel -Config $hostConfig -Manifest $manifest -GlobalServerIds @() -ProjectServerIds @("code")

                $calls = @($script:HostLmsBootstrapCalls)
                $calls.Count | Should -Be 3
                $calls[0] | Should -Be "get intfloat/multilingual-e5-base"
                $calls[1] | Should -Be "load intfloat/multilingual-e5-base"
                $calls[2] | Should -Be "server start --port 19000"
                Remove-Variable -Scope Script -Name HostLmsBootstrapCalls -ErrorAction SilentlyContinue
                Remove-Variable -Scope Script -Name HostLmsBootstrapProbeCount -ErrorAction SilentlyContinue
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "bootstraps standalone embedding before starting embedding-dependent servers" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-bootstrap-order-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                embedding = [ordered]@{
                    apiBase = "http://host.docker.internal:19000/v1"
                    apiKey = "lm-studio"
                    model = "intfloat/multilingual-e5-base"
                }
                enabledServers = [ordered]@{ global = @(); project = @("code") }
                configurations = @([ordered]@{ configId = "trade" })
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $script:HostBootstrapTestEvents = New-Object System.Collections.Generic.List[string]
                function Add-HostBootstrapTestEvent {
                    param([string]$Name)
                    $script:HostBootstrapTestEvents.Add($Name)
                }
                function Ensure-HostPrerequisites {
                    param([object]$Config)
                    Add-HostBootstrapTestEvent -Name "prerequisites"
                }
                function Ensure-Distribution {
                    param([object]$Config)
                    Add-HostBootstrapTestEvent -Name "distribution"
                }
                function Read-DistributionManifest {
                    param([object]$Config)
                    Add-HostBootstrapTestEvent -Name "manifest"
                    return [pscustomobject]@{
                        servers = @([pscustomobject]@{
                            id = "code"
                            scope = "project"
                            embedding = $true
                            internalPort = 8000
                            image = "fixture-code-image:latest"
                        })
                    }
                }
                function Ensure-HostEmbeddingModel {
                    param(
                        [object]$Config,
                        [object]$Manifest,
                        [string[]]$GlobalServerIds,
                        [string[]]$ProjectServerIds
                    )
                    Add-HostBootstrapTestEvent -Name "embedding"
                }
                function Refresh-Configuration {
                    param([object]$Config, [object]$Configuration)
                    Add-HostBootstrapTestEvent -Name "refresh"
                    return [pscustomobject]@{
                        configId = "trade"
                        sourceRoot = (Join-Path $tempRoot "source")
                        mainConfigPath = "src/cf"
                        metadataRoot = (Join-Path $tempRoot "metadata")
                        configurationName = "Trade"
                        configurationVersion = "1.0"
                        sourceCommit = "fixture"
                        sourceFingerprint = "fixture"
                        reportHash = "fixture"
                        indexedAt = "2026-07-05T00:00:00Z"
                    }
                }
                function Start-DockerServer {
                    param([object]$Config, [object]$Server, [object]$Runtime, [object]$ConfigState = $null)
                    Add-HostBootstrapTestEvent -Name "start"
                }
                function Write-HostState {
                    param([object]$Config, [object]$State)
                    Add-HostBootstrapTestEvent -Name "state"
                }

                $hostConfig = Read-JsonFile -Path $configPath
                Start-HostServers -Config $hostConfig

                $events = @($script:HostBootstrapTestEvents)
                $events | Should -Contain "embedding"
                $events | Should -Contain "start"
                [array]::IndexOf($events, "embedding") | Should -BeLessThan ([array]::IndexOf($events, "start"))
                Remove-Variable -Scope Script -Name HostBootstrapTestEvents -ErrorAction SilentlyContinue
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "reindexes only embedding-dependent standalone servers with stable port indexes" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-host-reindex-test-" + [guid]::NewGuid().ToString("N"))
        $configPath = Join-Path $tempRoot "host.config.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $config = [ordered]@{
                schemaVersion = 1
                hostId = "test-host"
                baseUrl = "http://localhost"
                stateRoot = (Join-Path $tempRoot "state")
                embedding = [ordered]@{ model = "intfloat/multilingual-e5-base" }
                enabledServers = [ordered]@{
                    global = @("ssl", "docs")
                    project = @("codechecker", "code", "graph")
                }
                configurations = @([ordered]@{ configId = "trade" })
            }
            Set-Content -LiteralPath $configPath -Encoding UTF8 -Value (($config | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & {
                . $McpHostPath -Action status -ConfigPath $configPath *> $null
                $script:HostReindexTestEvents = New-Object System.Collections.Generic.List[string]
                function Add-HostReindexTestEvent {
                    param([string]$Name)
                    $script:HostReindexTestEvents.Add($Name)
                }
                function Ensure-HostPrerequisites {
                    param([object]$Config)
                    Add-HostReindexTestEvent -Name "prerequisites"
                }
                function Ensure-Distribution {
                    param([object]$Config)
                    Add-HostReindexTestEvent -Name "distribution"
                }
                function Read-DistributionManifest {
                    param([object]$Config)
                    Add-HostReindexTestEvent -Name "manifest"
                    return [pscustomobject]@{
                        servers = @(
                            [pscustomobject]@{ id = "ssl"; scope = "global"; embedding = $false; internalPort = 8008; image = "fixture-ssl:latest" },
                            [pscustomobject]@{ id = "docs"; scope = "global"; embedding = $true; internalPort = 8001; image = "fixture-docs:latest"; env = @([ordered]@{ name = "RESET_CACHE"; value = "true" }) },
                            [pscustomobject]@{ id = "codechecker"; scope = "project"; embedding = $false; internalPort = 8002; image = "fixture-codechecker:latest" },
                            [pscustomobject]@{ id = "code"; scope = "project"; embedding = $true; internalPort = 8000; image = "fixture-code:latest" },
                            [pscustomobject]@{ id = "graph"; scope = "project"; embedding = $true; internalPort = 8006; image = "fixture-graph:latest"; compose = $true }
                        )
                    }
                }
                function Ensure-HostEmbeddingModel {
                    param(
                        [object]$Config,
                        [object]$Manifest,
                        [string[]]$GlobalServerIds,
                        [string[]]$ProjectServerIds
                    )
                    Add-HostReindexTestEvent -Name "embedding"
                }
                function Refresh-Configuration {
                    param([object]$Config, [object]$Configuration)
                    Add-HostReindexTestEvent -Name "refresh:$([string](Get-ObjectValue -Object $Configuration -Name 'configId' -Default ''))"
                    return [pscustomobject]@{
                        configId = "trade"
                        sourceRoot = (Join-Path $tempRoot "source")
                        mainConfigPath = "src/cf"
                        metadataRoot = (Join-Path $tempRoot "metadata")
                        configurationName = "Trade"
                        configurationVersion = "1.0"
                        sourceCommit = "fixture"
                        sourceFingerprint = "fixture-fingerprint"
                        reportHash = "fixture-report"
                        indexedAt = "2026-07-05T00:00:00Z"
                    }
                }
                function Start-DockerServer {
                    param(
                        [object]$Config,
                        [object]$Server,
                        [object]$Runtime,
                        [object]$ConfigState = $null,
                        [switch]$Recreate,
                        [switch]$ForceResetDatabase
                    )
                    Add-HostReindexTestEvent -Name "docker:$($Runtime.id):$($Runtime.hostPort):recreate=$($Recreate.IsPresent):reset=$($ForceResetDatabase.IsPresent)"
                }
                function Start-ComposeServer {
                    param(
                        [object]$Config,
                        [object]$Server,
                        [object]$Runtime,
                        [object]$ConfigState,
                        [switch]$Recreate,
                        [switch]$ForceResetDatabase
                    )
                    Add-HostReindexTestEvent -Name "compose:$($Runtime.id):$($Runtime.hostPort):recreate=$($Recreate.IsPresent):reset=$($ForceResetDatabase.IsPresent)"
                }

                $hostConfig = Read-JsonFile -Path $configPath
                $initialState = [ordered]@{
                    schemaVersion = 1
                    updatedAt = "2026-07-05T00:00:00Z"
                    configurations = @()
                    servers = @([ordered]@{
                        id = "ssl"
                        scope = "global"
                        name = "itl-ssl"
                        containerName = "itl-ssl"
                        health = "running"
                    }, [ordered]@{
                        id = "docs"
                        scope = "global"
                        name = "itl-docs"
                        containerName = "itl-docs"
                        health = "running"
                    })
                }
                Write-HostState -Config $hostConfig -State $initialState

                Invoke-HostReindex -Config $hostConfig

                $events = @($script:HostReindexTestEvents)
                $events | Should -Contain "embedding"
                $events | Should -Contain "refresh:trade"
                $events | Should -Contain "docker:code:18101:recreate=True:reset=True"
                $events | Should -Contain "compose:graph:18102:recreate=True:reset=True"
                ($events -join "|") | Should -Not -Match "docker:ssl"
                ($events -join "|") | Should -Not -Match "docker:docs"
                ($events -join "|") | Should -Not -Match "docker:codechecker"

                $state = Read-HostState -Config $hostConfig
                @($state.configurations | Where-Object { $_.configId -eq "trade" }).Count | Should -Be 1
                @($state.servers | Where-Object { $_.id -eq "ssl" }).Count | Should -Be 1
                @($state.servers | Where-Object { $_.id -eq "docs" }).Count | Should -Be 1
                @($state.servers | Where-Object { $_.id -eq "code" }).Count | Should -Be 1
                @($state.servers | Where-Object { $_.id -eq "graph" }).Count | Should -Be 1
                Remove-Variable -Scope Script -Name HostReindexTestEvents -ErrorAction SilentlyContinue
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "normalizes unscoped local code and graph manifest entries to project scope" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-local-scope-test-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot | Out-Null

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                $legacyGraph = [pscustomobject]@{ id = "graph" }
                $branchGraph = [pscustomobject]@{ id = "graph"; scope = "branch" }

                Get-Vibecoding1cMcpServerScope -Server $legacyGraph | Should -Be "project"
                Get-Vibecoding1cMcpServerScope -Server $branchGraph | Should -Be "branch"
                Test-Vibecoding1cMcpServerNeedsRemoteConfig -Server $legacyGraph | Should -Be $true
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "falls back local graph chat OpenAI settings to embedding settings" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-local-graph-openai-test-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $localHome = Join-Path $tempRoot "local-home"
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot, $localHome | Out-Null
            $state = [ordered]@{
                schemaVersion = 1
                model = [ordered]@{
                    apiBase = "http://127.0.0.1:19000/v1"
                    apiKey = "lm-studio"
                    model = "fixture-embedding-model"
                    ready = $true
                }
                servers = @()
                updatedAt = "2026-07-05T00:00:00Z"
            }
            Set-Content -LiteralPath (Join-Path $localHome "state.json") -Encoding UTF8 -Value (($state | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $localHome, "Process")

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                $server = [pscustomobject]@{
                    id = "graph"
                    env = @(
                        [ordered]@{ name = "OPENAI_API_KEY"; from = "CHAT_API_KEY"; required = $false },
                        [ordered]@{ name = "OPENAI_API_BASE"; from = "CHAT_API_BASE"; required = $false },
                        [ordered]@{ name = "OPENAI_MODEL"; from = "CHAT_MODEL"; required = $false }
                    )
                }
                $runtime = [pscustomobject]@{ projectSlug = "fixture"; branchSlug = "master" }
                $configContext = [pscustomobject]@{ values = [ordered]@{} }

                $envResult = Resolve-Vibecoding1cMcpEnvironment -Server $server -Runtime $runtime -ConfigContext $configContext

                $envResult.values["OPENAI_API_KEY"] | Should -Be "lm-studio"
                $envResult.values["OPENAI_API_BASE"] | Should -Be "http://127.0.0.1:19000/v1"
                $envResult.values["OPENAI_MODEL"] | Should -Be "fixture-embedding-model"
            }
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "clones and fast-forwards the managed vibecoding1c MCP distribution checkout" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-distribution-test-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $workRepo = Join-Path $tempRoot "source"
        $remoteRepo = Join-Path $tempRoot "remote.git"
        $localHome = Join-Path $tempRoot "local-home"
        $oldRepo = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_REPO", "Process")
        $oldPath = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_PATH", "Process")
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot, $workRepo | Out-Null
            & git -C $workRepo init *> $null
            & git -C $workRepo config user.email "test@example.com"
            & git -C $workRepo config user.name "Test User"
            & git -C $workRepo branch -M main
            Set-Content -LiteralPath (Join-Path $workRepo "config.env") -Value "LICENSE_KEY_HELP=fixture-key`n" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $workRepo "vibecoding1c-mcp.manifest.json") -Value '{"servers":[]}' -Encoding ASCII
            & git -C $workRepo add config.env vibecoding1c-mcp.manifest.json
            & git -C $workRepo commit -m "initial distribution" *> $null
            & git init --bare $remoteRepo *> $null
            & git -C $workRepo remote add origin $remoteRepo
            & git -C $workRepo push --quiet -u origin main *> $null
            & git -C $remoteRepo symbolic-ref HEAD refs/heads/main

            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_REPO", $remoteRepo, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_PATH", $null, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $localHome, "Process")

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                Ensure-Vibecoding1cMcpDistribution | Out-Null
            }

            $managedPath = Join-Path $localHome "distribution"
            (Test-Path -LiteralPath (Join-Path $managedPath ".git") -PathType Container) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $managedPath "config.env") -PathType Leaf) | Should -Be $true

            Set-Content -LiteralPath (Join-Path $workRepo "version.txt") -Value "2" -Encoding ASCII
            & git -C $workRepo add version.txt
            & git -C $workRepo commit -m "update distribution" *> $null
            & git -C $workRepo push --quiet origin main *> $null

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                Ensure-Vibecoding1cMcpDistribution | Out-Null
            }

            (Get-Content -Encoding ASCII -Raw (Join-Path $managedPath "version.txt")).Trim() | Should -Be "2"
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_REPO", $oldRepo, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_PATH", $oldPath, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "does not clone when an explicit vibecoding1c MCP distribution path is configured" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-distribution-override-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $manualDistribution = Join-Path $tempRoot "manual-distribution"
        $localHome = Join-Path $tempRoot "local-home"
        $oldRepo = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_REPO", "Process")
        $oldPath = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_PATH", "Process")
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot, $manualDistribution | Out-Null
            Set-Content -LiteralPath (Join-Path $manualDistribution "config.env") -Value "LICENSE_KEY_HELP=manual-key`n" -Encoding ASCII
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_REPO", "bad://should-not-be-used", "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_PATH", $manualDistribution, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $localHome, "Process")

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                $resolved = Ensure-Vibecoding1cMcpDistribution
                $resolved | Should -Be ([System.IO.Path]::GetFullPath($manualDistribution))
            }

            (Test-Path -LiteralPath (Join-Path $localHome "distribution") -ErrorAction SilentlyContinue) | Should -Be $false
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_REPO", $oldRepo, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_PATH", $oldPath, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "fails clearly when the managed vibecoding1c MCP distribution path is not a Git checkout" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-distribution-invalid-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $localHome = Join-Path $tempRoot "local-home"
        $managedPath = Join-Path $localHome "distribution"
        $oldRepo = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_REPO", "Process")
        $oldPath = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_PATH", "Process")
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot, $managedPath | Out-Null
            Set-Content -LiteralPath (Join-Path $managedPath "config.env") -Value "LICENSE_KEY_HELP=stale`n" -Encoding ASCII
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_REPO", "bad://should-not-be-used", "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_PATH", $null, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $localHome, "Process")

            {
                & {
                    . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                    Ensure-Vibecoding1cMcpDistribution | Out-Null
                }
            } | Should -Throw "*not a Git checkout*"
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_REPO", $oldRepo, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_DISTRIBUTION_PATH", $oldPath, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "requires explicit remote config selection and resolves registry endpoints" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-registry-select-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $registryRoot = Join-Path $tempRoot "registry"
        $localHome = Join-Path $tempRoot "local-home"
        $oldRegistryPath = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", "Process")
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot, $registryRoot | Out-Null
            $registry = [ordered]@{
                schemaVersion = 1
                publishedAt = "2026-07-04T00:00:00Z"
                host = [ordered]@{ hostId = "host-a"; baseUrl = "http://vibecoding1c-mcp-host" }
                configurations = @(
                    [ordered]@{
                        configId = "trade"
                        title = "Trade"
                        sourceFingerprint = "remote-fingerprint"
                        reportHash = "abc"
                        indexedAt = "2026-07-04T00:00:00Z"
                    }
                )
                servers = @(
                    [ordered]@{
                        id = "code"
                        scope = "project"
                        family = "vibecoding1c"
                        provider = "remote"
                        configId = "trade"
                        name = "itl-trade-code"
                        url = "http://vibecoding1c-mcp-host:18100/mcp"
                        health = "running"
                        sourceFingerprint = "remote-fingerprint"
                        reportHash = "abc"
                        indexedAt = "2026-07-04T00:00:00Z"
                    }
                )
            }
            Set-Content -LiteralPath (Join-Path $registryRoot "registry.json") -Value (($registry | ConvertTo-Json -Depth 10) + [Environment]::NewLine) -Encoding UTF8
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $registryRoot, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $localHome, "Process")

            {
                & {
                    . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                    $server = (Read-Vibecoding1cMcpManifest).servers | Where-Object { $_.id -eq "code" } | Select-Object -First 1
                    New-Vibecoding1cMcpRemoteRuntime -Server $server -Selection (Read-Vibecoding1cMcpSelection) | Out-Null
                }
            } | Should -Throw "*requires explicit configuration selection*"

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help -McpServerId code -McpProvider remote -McpConfigId trade *> $null
                Set-Vibecoding1cMcpSelection *> $null
                $selection = Read-Vibecoding1cMcpSelection
                $server = (Read-Vibecoding1cMcpManifest).servers | Where-Object { $_.id -eq "code" } | Select-Object -First 1
                $runtime = New-Vibecoding1cMcpRemoteRuntime -Server $server -Selection $selection
                $runtime.url | Should -Be "http://vibecoding1c-mcp-host:18100/mcp"
                $runtime.configId | Should -Be "trade"
                (Get-Vibecoding1cMcpEndpointFreshness -Endpoint $runtime) | Should -Be "remote-shared"
            }
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $oldRegistryPath, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "keeps config-specific remote choices per server during selection" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-per-server-config-select-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $registryRoot = Join-Path $tempRoot "registry"
        $localHome = Join-Path $tempRoot "local-home"
        $oldRegistryPath = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", "Process")
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")
        $oldConfigId = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_CONFIG_ID", "Process")
        $oldHostId = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_HOST_ID", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot, $registryRoot | Out-Null
            $registry = [ordered]@{
                schemaVersion = 1
                publishedAt = "2026-07-05T00:00:00Z"
                host = [ordered]@{ hostId = "host-a"; baseUrl = "http://vibecoding1c-mcp-host" }
                configurations = @(
                    [ordered]@{ configId = "trade"; title = "Trade"; indexedAt = "2026-07-05T00:00:00Z" },
                    [ordered]@{ configId = "erp"; title = "ERP"; indexedAt = "2026-07-05T00:00:00Z" }
                )
                servers = @(
                    [ordered]@{ id = "code"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-code"; url = "http://vibecoding1c-mcp-host:18100/mcp"; health = "running"; indexedAt = "2026-07-05T00:00:00Z" },
                    [ordered]@{ id = "code"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "erp"; name = "itl-erp-code"; url = "http://vibecoding1c-mcp-host:18101/mcp"; health = "running"; indexedAt = "2026-07-05T00:00:00Z" },
                    [ordered]@{ id = "graph"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-graph"; url = "http://vibecoding1c-mcp-host:18106/mcp"; health = "running"; indexedAt = "2026-07-05T00:00:00Z" },
                    [ordered]@{ id = "graph"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "erp"; name = "itl-erp-graph"; url = "http://vibecoding1c-mcp-host:18107/mcp"; health = "running"; indexedAt = "2026-07-05T00:00:00Z" }
                )
            }
            Set-Content -LiteralPath (Join-Path $registryRoot "registry.json") -Encoding UTF8 -Value (($registry | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $registryRoot, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $localHome, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_CONFIG_ID", $null, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_HOST_ID", $null, "Process")

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                $script:vibecoding1cConfigChoices = @("trade", "erp")
                $script:vibecoding1cConfigChoiceIndex = 0

                function Test-InteractiveInputAvailable {
                    return $false
                }

                function Read-Vibecoding1cMcpRemoteConfigChoice {
                    param([object]$Selection)

                    $choice = $script:vibecoding1cConfigChoices[$script:vibecoding1cConfigChoiceIndex]
                    $script:vibecoding1cConfigChoiceIndex += 1
                    return $choice
                }

                Set-Vibecoding1cMcpSelection *> $null
                $selection = Read-Vibecoding1cMcpSelection
                $script:vibecoding1cConfigChoiceIndex | Should -Be 2
                $selection.remoteConfigId | Should -Be ""

                $codeSelection = $selection.servers | Where-Object { $_.id -eq "code" } | Select-Object -First 1
                $graphSelection = $selection.servers | Where-Object { $_.id -eq "graph" } | Select-Object -First 1
                $codeSelection.configId | Should -Be "trade"
                $graphSelection.configId | Should -Be "erp"

                $complete = Get-Vibecoding1cMcpSelectionCompleteness -Selection $selection -RefreshRegistry
                $complete.isComplete | Should -Be $true
            }
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $oldRegistryPath, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_CONFIG_ID", $oldConfigId, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_HOST_ID", $oldHostId, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "requires McpHostId for duplicate remote registry endpoints and resolves v2 host metadata" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-registry-v2-host-select-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $registryRoot = Join-Path $tempRoot "registry"
        $localHome = Join-Path $tempRoot "local-home"
        $oldRegistryPath = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", "Process")
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot, $registryRoot | Out-Null
            $registry = [ordered]@{
                schemaVersion = 2
                publishedAt = "2026-07-05T00:00:00Z"
                hosts = @(
                    [ordered]@{
                        hostId = "host-a"
                        baseUrl = "http://host-a"
                        publishedAt = "2026-07-05T00:00:00Z"
                        configurations = @([ordered]@{ configId = "trade"; title = "Trade"; configurationName = "Trade A"; configurationVersion = "1.0" })
                        servers = @([ordered]@{
                            id = "code"
                            scope = "project"
                            family = "vibecoding1c"
                            provider = "remote"
                            configId = "trade"
                            name = "itl-trade-code"
                            url = "http://host-a:18100/mcp"
                            health = "running"
                            configurationName = "Trade A"
                            configurationVersion = "1.0"
                            embeddingMode = "cpu"
                            embeddingModel = "intfloat/multilingual-e5-base"
                            indexedAt = "2026-07-05T00:00:00Z"
                        })
                    },
                    [ordered]@{
                        hostId = "host-b"
                        baseUrl = "http://host-b"
                        publishedAt = "2026-07-05T00:05:00Z"
                        configurations = @([ordered]@{ configId = "trade"; title = "Trade"; configurationName = "Trade B"; configurationVersion = "2.0" })
                        servers = @([ordered]@{
                            id = "code"
                            scope = "project"
                            family = "vibecoding1c"
                            provider = "remote"
                            configId = "trade"
                            name = "itl-trade-code"
                            url = "http://host-b:18100/mcp"
                            health = "running"
                            configurationName = "Trade B"
                            configurationVersion = "2.0"
                            embeddingMode = "cpu"
                            embeddingModel = "intfloat/multilingual-e5-base"
                            indexedAt = "2026-07-05T00:05:00Z"
                        })
                    }
                )
                configurations = @()
                servers = @()
            }
            Set-Content -LiteralPath (Join-Path $registryRoot "registry.json") -Value (($registry | ConvertTo-Json -Depth 20) + [Environment]::NewLine) -Encoding UTF8
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $registryRoot, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $localHome, "Process")

            {
                & {
                    . $HelperPath -ProjectRoot $projectRoot -Action help -McpServerId code -McpProvider remote -McpConfigId trade *> $null
                    Set-Vibecoding1cMcpSelection *> $null
                    $selection = Read-Vibecoding1cMcpSelection
                    $server = (Read-Vibecoding1cMcpManifest).servers | Where-Object { $_.id -eq "code" } | Select-Object -First 1
                    New-Vibecoding1cMcpRemoteRuntime -Server $server -Selection $selection | Out-Null
                }
            } | Should -Throw "*multiple matching hosts*"

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help -McpServerId code -McpProvider remote -McpConfigId trade -McpHostId host-b *> $null
                Set-Vibecoding1cMcpSelection *> $null
                $selection = Read-Vibecoding1cMcpSelection
                $selection.remoteConfigId | Should -Be ""
                $selection.remoteHostId | Should -Be ""
                $selectionEntry = $selection.servers | Where-Object { $_.id -eq "code" } | Select-Object -First 1
                $selectionEntry.configId | Should -Be "trade"
                $selectionEntry.hostId | Should -Be "host-b"
                $server = (Read-Vibecoding1cMcpManifest).servers | Where-Object { $_.id -eq "code" } | Select-Object -First 1
                $runtime = New-Vibecoding1cMcpRemoteRuntime -Server $server -Selection $selection
                $runtime.url | Should -Be "http://host-b:18100/mcp"
                $runtime.hostId | Should -Be "host-b"
                $runtime.configurationName | Should -Be "Trade B"
                $runtime.configurationVersion | Should -Be "2.0"
                $runtime.embeddingModel | Should -Be "intfloat/multilingual-e5-base"
            }
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $oldRegistryPath, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "marks missing and incomplete vibecoding1c MCP selections before setup" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-selection-complete-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot | Out-Null
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", (Join-Path $tempRoot "local-home"), "Process")

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                $missing = Get-Vibecoding1cMcpSelectionCompleteness -Selection (Read-Vibecoding1cMcpSelection)
                $missing.isComplete | Should -Be $false
                $missing.reasons | Should -Contain "selection file is missing"

                $serverIds = @("docs", "templates", "syntax", "codechecker", "ssl", "code", "graph")
                $selectionPath = Get-Vibecoding1cMcpSelectionPath
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $selectionPath) | Out-Null
                $incompleteSelection = [ordered]@{
                    schemaVersion = 1
                    family = "vibecoding1c"
                    defaultProvider = "remote"
                    remoteConfigId = ""
                    remoteHostId = ""
                    localScopeDefault = "project"
                    servers = @($serverIds | ForEach-Object {
                        [ordered]@{ id = $_; family = "vibecoding1c"; provider = "remote"; configId = ""; hostId = ""; localScope = "project" }
                    })
                }
                Set-Content -LiteralPath $selectionPath -Encoding UTF8 -Value (($incompleteSelection | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

                $incomplete = Get-Vibecoding1cMcpSelectionCompleteness -Selection (Read-Vibecoding1cMcpSelection)
                $incomplete.isComplete | Should -Be $false
                ($incomplete.reasons -join [Environment]::NewLine) | Should -Match "code/project remote provider has no configId"

                $completeSelection = [ordered]@{
                    schemaVersion = 1
                    family = "vibecoding1c"
                    defaultProvider = "remote"
                    remoteConfigId = "trade"
                    remoteHostId = "host-a"
                    localScopeDefault = "project"
                    servers = @($serverIds | ForEach-Object {
                        [ordered]@{
                            id = $_
                            family = "vibecoding1c"
                            provider = "remote"
                            configId = $(if ($_ -eq "code" -or $_ -eq "graph") { "trade" } else { "" })
                            hostId = "host-a"
                            localScope = "project"
                        }
                    })
                }
                Set-Content -LiteralPath $selectionPath -Encoding UTF8 -Value (($completeSelection | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

                $complete = Get-Vibecoding1cMcpSelectionCompleteness -Selection (Read-Vibecoding1cMcpSelection)
                $complete.isComplete | Should -Be $true
            }
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "requires a host selection for duplicate remote endpoints and formats host details for selection" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-selection-host-details-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $registryRoot = Join-Path $tempRoot "registry"
        $oldRegistryPath = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", "Process")
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot, $registryRoot | Out-Null
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $registryRoot, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", (Join-Path $tempRoot "local-home"), "Process")

            $registry = [ordered]@{
                schemaVersion = 2
                publishedAt = "2026-07-05T00:10:00Z"
                hosts = @(
                    [ordered]@{
                        hostId = "host-a"
                        baseUrl = "http://host-a"
                        publishedAt = "2026-07-05T00:00:00Z"
                        configurations = @([ordered]@{ configId = "trade"; title = "Trade"; configurationName = "Trade A"; configurationVersion = "1.0" })
                        servers = @([ordered]@{ id = "code"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-code"; url = "http://host-a:18100/mcp"; health = "running"; configurationName = "Trade A"; configurationVersion = "1.0"; embeddingModel = "intfloat/multilingual-e5-base"; indexedAt = "2026-07-05T00:00:00Z" })
                    },
                    [ordered]@{
                        hostId = "host-b"
                        baseUrl = "http://host-b"
                        publishedAt = "2026-07-05T00:05:00Z"
                        configurations = @([ordered]@{ configId = "trade"; title = "Trade"; configurationName = "Trade B"; configurationVersion = "2.0" })
                        servers = @([ordered]@{ id = "code"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-code"; url = "http://host-b:18100/mcp"; health = "running"; configurationName = "Trade B"; configurationVersion = "2.0"; embeddingModel = "intfloat/multilingual-e5-base"; indexedAt = "2026-07-05T00:05:00Z" })
                    }
                )
                configurations = @()
                servers = @()
            }
            Set-Content -LiteralPath (Join-Path $registryRoot "registry.json") -Encoding UTF8 -Value (($registry | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                $serverIds = @("docs", "templates", "syntax", "codechecker", "ssl", "code", "graph")
                $selectionPath = Get-Vibecoding1cMcpSelectionPath
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $selectionPath) | Out-Null
                $selection = [ordered]@{
                    schemaVersion = 1
                    family = "vibecoding1c"
                    defaultProvider = "remote"
                    remoteConfigId = "trade"
                    remoteHostId = ""
                    localScopeDefault = "project"
                    servers = @($serverIds | ForEach-Object {
                        [ordered]@{
                            id = $_
                            family = "vibecoding1c"
                            provider = "remote"
                            configId = $(if ($_ -eq "code" -or $_ -eq "graph") { "trade" } else { "" })
                            hostId = ""
                            localScope = "project"
                        }
                    })
                }
                Set-Content -LiteralPath $selectionPath -Encoding UTF8 -Value (($selection | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

                $duplicate = Get-Vibecoding1cMcpSelectionCompleteness -Selection (Read-Vibecoding1cMcpSelection) -RefreshRegistry
                $duplicate.isComplete | Should -Be $false
                ($duplicate.reasons -join [Environment]::NewLine) | Should -Match "code/project remote provider has multiple matching hosts and no hostId"

                $endpoint = (Get-Vibecoding1cMcpRegistryServers -Registry (Read-Vibecoding1cMcpRegistry) | Where-Object { [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "hostId" -Default "") -eq "host-b" } | Select-Object -First 1)
                $details = Format-Vibecoding1cMcpRemoteEndpointInfo -Endpoint $endpoint
                $details | Should -Match "hostId=host-b"
                $details | Should -Match ([regex]::Escape("url=http://host-b:18100/mcp"))
                $details | Should -Match "health=running"
                $details | Should -Match "configId=trade"
                $details | Should -Match "configuration=Trade B 2.0"
                $details | Should -Match "model=intfloat/multilingual-e5-base"
                $details | Should -Match "indexedAt=2026-07-05T00:05:00Z"

                foreach ($serverSelection in $selection["servers"]) {
                    if ($serverSelection["id"] -eq "code") {
                        $serverSelection["hostId"] = "host-b"
                    }
                }
                Set-Content -LiteralPath $selectionPath -Encoding UTF8 -Value (($selection | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
                $complete = Get-Vibecoding1cMcpSelectionCompleteness -Selection (Read-Vibecoding1cMcpSelection) -RefreshRegistry
                $complete.isComplete | Should -Be $true
            }
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $oldRegistryPath, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "shows vibecoding1c MCP active, skipped, stale, and missing-configId status groups" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-status-groups-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $localHome = Join-Path $tempRoot "local-home"
        $oldHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path `
                $projectRoot,
                (Join-Path $projectRoot ".agent-1c\mcp"),
                $localHome | Out-Null

            $selection = [ordered]@{
                schemaVersion = 1
                family = "vibecoding1c"
                defaultProvider = "remote"
                remoteConfigId = ""
                localScopeDefault = "project"
                servers = @(
                    [ordered]@{ id = "docs"; provider = "local"; localScope = "project"; configId = "" },
                    [ordered]@{ id = "templates"; provider = "remote"; localScope = "project"; configId = "" }
                )
                updatedAt = "2026-07-04T00:00:00Z"
            }
            Set-Content -LiteralPath (Join-Path $projectRoot ".agent-1c\mcp\vibecoding1c-selection.json") -Encoding UTF8 -Value (($selection | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            $state = [ordered]@{
                schemaVersion = 1
                model = [ordered]@{ modelId = "fixture-model"; ready = $true }
                staleIndexes = @("docs")
                servers = @(
                    [ordered]@{
                        id = "docs"
                        scope = "global"
                        name = "itl-1c-docs"
                        url = "http://127.0.0.1:18003/mcp"
                        status = "running"
                        family = "vibecoding1c"
                        provider = "local"
                        configId = ""
                        sourceFingerprint = "old-fingerprint"
                    },
                    [ordered]@{
                        id = "templates"
                        scope = "global"
                        name = "itl-1c-templates"
                        url = ""
                        status = "missing-settings"
                        family = "vibecoding1c"
                        provider = "remote"
                        configId = ""
                    }
                )
                updatedAt = "2026-07-04T00:00:00Z"
            }
            Set-Content -LiteralPath (Join-Path $localHome "state.json") -Encoding UTF8 -Value (($state | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $localHome, "Process")

            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $projectRoot -Action vibecoding1c-mcp-status 2>&1
            $LASTEXITCODE | Should -Be 0
            $statusText = ($output -join [Environment]::NewLine)

            $statusText | Should -Match "vibecoding1c MCP active servers: .*itl-1c-docs/local/stale"
            $statusText | Should -Match "vibecoding1c MCP skipped servers: .*templates/global/remote/missing-settings"
            $statusText | Should -Match "vibecoding1c MCP stale servers: .*itl-1c-docs/stale"
            $statusText | Should -Match "vibecoding1c MCP missing-configId servers: .*code/project"
            $statusText | Should -Match "vibecoding1c MCP stale indexes: docs"
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldHome, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "does not store concrete MCP license key values in tracked text files" {
        $tracked = @(& git -C $RepoRoot ls-files)
        $textExtensions = @(".ps1", ".md", ".json", ".jsonc", ".yml", ".yaml", ".example", ".gitignore", ".toml")
        foreach ($relativePath in $tracked) {
            if ($relativePath -match '[<>:"|?*\x00-\x1F]') {
                continue
            }
            $extension = [System.IO.Path]::GetExtension($relativePath)
            if ($textExtensions -notcontains $extension -and $relativePath -notlike "templates/*" -and $relativePath -notlike ".gitignore") {
                continue
            }
            $path = Join-Path $RepoRoot $relativePath
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                continue
            }
            $text = Get-Content -Encoding UTF8 -Raw $path
            $text | Should -Not -Match '(?m)^\s*LICENSE_KEY_[A-Z0-9_]+\s*=\s*[^#\s]+'
            $text | Should -Not -Match '(?m)^\s*ONEC_AI_TOKEN\s*=\s*(?!<)[^#\s]+'
            $text | Should -Not -Match '"ONEC_AI_TOKEN"\s*:\s*"(?!<)[^"]+"'
        }
    }

    It "wires branch-local Vanessa MCP actions and local artifacts" {
        $actions = @("install-vanessa-mcp", "start-vanessa-mcp", "stop-vanessa-mcp", "vanessa-mcp-status")
        foreach ($action in $actions) {
            $HelperText | Should -Match ([regex]::Escape("`"$action`""))
        }

        $HelperText | Should -Match "Resolve-VanessaMcpPort"
        $HelperText | Should -Match "VANESSA_MCP_PORT_RANGE"
        $HelperText | Should -Match "client_mcp.cfe"
        $HelperText | Should -Match "VAExtension"
        $HelperText | Should -Match "runMcp;mcpPort="
        $HelperText | Should -Match "Write-VanessaMcpKiloConfig"
        $HelperText | Should -Match 'managedBy = "vanessa-mcp"'
        $HelperText | Should -Match 'family = "vanessa"'
        $HelperText | Should -Match "reload or restart Kilo Code"
        $HelperText | Should -Match "StartFeaturePlayer"

        $mcpToolPath = ".agent-1c/tools/vanessa-mcp/"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape($mcpToolPath))
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\gitignore.append")) | Should -Match ([regex]::Escape($mcpToolPath))
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "VANESSA_MCP_URL"
        (Test-Path -LiteralPath (Join-Path $RepoRoot ".kilo\commands\itl-vanessa-mcp.md") -PathType Leaf) | Should -Be $true
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".kilo\commands\itl-vanessa-mcp.md")) | Should -Match "reload or restart Kilo Code"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".kilo\commands\itl.md")) | Should -Not -Match "/itl-vanessa-mcp"
    }

    It "keeps the ITL overlay in USER-RULES and AGENTS as a fallback bridge" {
        $templatePath = Join-Path $RepoRoot "templates\AGENTS.append.md"
        (Test-Path -LiteralPath $templatePath -PathType Leaf) | Should -Be $true

        $templateText = Get-Content -Encoding UTF8 -Raw $templatePath
        $templateText | Should -Match "## 1C Agent Workflow Bridge"
        $templateText | Should -Match "USER-RULES.md"
        $templateText | Should -Match "1c-workflow-fast"
        $templateText | Should -Match "1c-workflow/SKILL.md"

        $userRulesTemplatePath = Join-Path $RepoRoot "templates\USER-RULES.append.md"
        (Test-Path -LiteralPath $userRulesTemplatePath -PathType Leaf) | Should -Be $true
        $userRulesTemplateText = Get-Content -Encoding UTF8 -Raw $userRulesTemplatePath
        $userRulesTemplateText | Should -Match "## 1C Project Lifecycle"
        $userRulesTemplateText | Should -Match "update-ai-rules"
        $userRulesTemplateText | Should -Match "TESTMANAGER -> TESTCLIENT"
        $userRulesTemplateText | Should -Match ([regex]::Escape(".agent-1c/event-log-baselines/*.json"))
        $userRulesTemplateText | Should -Match "standards and role library"
        $userRulesTemplateText | Should -Match "content/skills"
        $userRulesTemplateText | Should -Match ([regex]::Escape("/installmcp"))
        $userRulesTemplateText | Should -Match ([regex]::Escape("/itl-vibecoding1c-mcp"))

        $HelperText | Should -Match "function Update-AgentGuidanceBridge"
        $HelperText | Should -Match "function Update-UserRules"
        $HelperText | Should -Match "## 1C Agent Workflow Bridge"
        $HelperText | Should -Match "Update-AgentGuidanceBridge"
        $HelperText | Should -Match "Update-UserRules"
        $HelperText | Should -Match ([regex]::Escape("templates\USER-RULES.append.md"))
        $HelperText | Should -Match "AGENTS\.md already references USER-RULES\.md"

        $installText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "AGENT-INSTALL.md")
        $installText | Should -Match "templates/USER-RULES.append.md"
        $installText | Should -Match "fallback"
        $installText | Should -Match "upstream-managed"
        $installText | Should -Match "AGENTS\.md"
        $installText | Should -Match "USER-RULES.md"
    }

    It "wires ai_rules_1c update through the helper and Kilo wrapper" {
        $HelperText | Should -Match ([regex]::Escape('"update-ai-rules"'))
        $HelperText | Should -Match "function Update-AiRules1c"
        $HelperText | Should -Match ([regex]::Escape('Invoke-AiRules1cInstaller -Command "update"'))
        $HelperText | Should -Match ([regex]::Escape('powershell -NoProfile -ExecutionPolicy Bypass -File $installScript @installArgs'))
        $HelperText | Should -Match ([regex]::Escape('$effectiveCommand,'))
        $HelperText | Should -Match ([regex]::Escape('"-Force"'))
        $HelperText | Should -Match "Update ai_rules_1c managed rules"
        $HelperText | Should -Match "function Remove-AiRules1cManagedMcpConfig"
        $HelperText | Should -Match "function Get-AiRules1cManagedMcpServerIds"
        $HelperText | Should -Match "1c-code-metadata-mcp"
        $HelperText | Should -Match "1C-docs-mcp"
        $HelperText | Should -Match "1c-data-mcp"

        $wrapperPath = Join-Path $RepoRoot ".kilo\commands\itl-update-rules.md"
        (Test-Path -LiteralPath $wrapperPath -PathType Leaf) | Should -Be $true
        $wrapperText = Get-Content -Encoding UTF8 -Raw $wrapperPath
        $wrapperText | Should -Match "-Action\s+update-ai-rules"
        $wrapperText | Should -Match "USER-RULES.md"
        $wrapperText | Should -Match "MCP"

        $advancedText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\advanced-actions.md")
        $workflowText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\workflow.md")
        $readmeText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "README.md")
        $developerGuideText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "DEVELOPER-GUIDE.ru.md")
        foreach ($text in @($advancedText, $workflowText, $readmeText, $developerGuideText)) {
            $text | Should -Match "update-ai-rules"
            $text | Should -Match "USER-RULES.md"
            $text | Should -Match "MCP"
        }
    }

    It "runs ai_rules_1c installer outside helper StrictMode" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-rules-strictmode-test-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $rulesRoot = Join-Path $tempRoot "ai_rules_1c"

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot, $rulesRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $projectRoot ".ai-rules.json") -Encoding UTF8 -Value '{"schemaVersion":1}'
            Set-Content -LiteralPath (Join-Path $rulesRoot "install.ps1") -Encoding UTF8 -Value @'
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command,
    [string]$ProjectRoot,
    [string]$Source,
    [switch]$AssumeYes,
    [switch]$Force
)

$optional = [pscustomobject]@{}
$null = $optional.userModified
Set-Content -LiteralPath (Join-Path $ProjectRoot "installer-ran.txt") -Encoding ASCII -Value "$Command|$Source|$($AssumeYes.IsPresent)"
'@

            & {
                . $HelperPath -ProjectRoot $projectRoot -Action help *> $null
                function Sync-AiRules1cCheckout {
                    return [pscustomobject]@{
                        root = $rulesRoot
                        repo = "fixture"
                        ref = "fixture"
                    }
                }
                function Get-GitOutputAt {
                    return "fixture-commit"
                }

                Invoke-AiRules1cInstaller -Command "update"
            }

            $result = Get-Content -Encoding ASCII -Raw (Join-Path $projectRoot "installer-ran.txt")
            $result.Trim() | Should -Be "update|$rulesRoot|True"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "does not assign to local home variables that collide with PowerShell HOME" {
        $HelperText | Should -Not -Match '(?im)^\s*\$home\s*='
    }

    It "wires ITL workflow package update through the helper, docs, and Kilo wrapper" {
        $HelperText | Should -Match ([regex]::Escape('"update-workflow"'))
        $HelperText | Should -Match "function Update-WorkflowPackage"
        $HelperText | Should -Match "ITL_WORKFLOW_SOURCE_PATH"
        $HelperText | Should -Match "workflowPackage"
        $HelperText | Should -Match "Update-WorkflowPackageLockEntry"
        $HelperText | Should -Match "Update-AgentGuidanceBridge"
        $HelperText | Should -Match "Update-UserRules"
        $HelperText | Should -Match "Assert-WorkflowPackageUpdateContext"
        $HelperText | Should -Match "Assert-WorkflowTrackedGitClean"
        $HelperText | Should -Match "updatedAt"

        $lockTemplate = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dependency-lock.json") | ConvertFrom-Json
        $lockTemplate.dependencies.workflowPackage.repo | Should -Be "https://github.com/xmentosx/1c-agent-workflow.git"
        $lockTemplate.dependencies.workflowPackage.ref | Should -Be "master"
        $lockTemplate.dependencies.workflowPackage.PSObject.Properties.Name | Should -Contain "updatedAt"

        $wrapperPath = Join-Path $RepoRoot ".kilo\commands\itl-update-workflow.md"
        (Test-Path -LiteralPath $wrapperPath -PathType Leaf) | Should -Be $true
        $wrapperText = Get-Content -Encoding UTF8 -Raw $wrapperPath
        $wrapperText | Should -Match "-Action\s+update-workflow"
        $wrapperText | Should -Match "ITL_WORKFLOW_SOURCE_PATH"
        $wrapperText | Should -Match "SkipAiRules"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".kilo\commands\itl.md")) | Should -Not -Match "/itl-update-workflow"

        $docPaths = @(
            "README.md",
            "AGENT-INSTALL.md",
            "DEVELOPER-GUIDE.ru.md",
            "DEV-BRANCH-DEVELOPMENT.ru.md",
            ".agents\skills\1c-workflow\SKILL.md",
            ".agents\skills\1c-workflow-fast\SKILL.md",
            ".agents\skills\1c-workflow\references\workflow.md",
            ".agents\skills\1c-workflow\references\advanced-actions.md",
            "templates\USER-RULES.append.md"
        )
        foreach ($relativePath in $docPaths) {
            $text = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot $relativePath)
            $text | Should -Match "update-workflow"
        }
    }

    It "removes default upstream ai_rules_1c MCP entries without deleting ITL or External MCP config" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-rules-mcp-cleanup-test-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".codex"), (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".codex\config.toml") -Value @"
[mcp_servers."1c-code-metadata-mcp"]
url = "http://localhost:8000/mcp"
enabled = true

[mcp_servers."1c-ssl-mcp"]
url = "http://localhost:8007/mcp"
enabled = true
managedBy = "external-mcp"

# >>> vibecoding1c-mcp project
[mcp_servers."1c-code-metadata-mcp"]
url = "http://127.0.0.1:18100/mcp"
enabled = true
managedBy = "vibecoding1c-mcp"
family = "vibecoding1c"

[mcp_servers."1c-data-mcp"]
url = "http://127.0.0.1/published/hs/mcp"
enabled = true
managedBy = "vibecoding1c-mcp"
family = "vibecoding1c"
# <<< vibecoding1c-mcp project

[mcp_servers."custom-tool"]
url = "http://localhost:9999/mcp"
enabled = true
"@ -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Value @"
{
  "mcp": {
    "1c-code-metadata-mcp": {
      "type": "remote",
      "url": "http://localhost:8000/mcp",
      "enabled": true
    },
    "1C-docs-mcp": {
      "type": "remote",
      "url": "http://localhost:8003/mcp",
      "enabled": true,
      "managedBy": "ai_rules_1c"
    },
    "1c-ssl-mcp": {
      "type": "remote",
      "url": "http://localhost:8007/mcp",
      "enabled": true,
      "managedBy": "external-mcp",
      "family": "external"
    },
    "itl-demo-code": {
      "type": "remote",
      "url": "http://127.0.0.1:18100/mcp",
      "enabled": true,
      "managedBy": "vibecoding1c-mcp",
      "family": "vibecoding1c"
    },
    "1c-graph-metadata-mcp": {
      "type": "remote",
      "url": "http://127.0.0.1:18101/mcp",
      "enabled": true,
      "managedBy": "vibecoding1c-mcp",
      "family": "vibecoding1c"
    },
    "1c-data-mcp": {
      "type": "remote",
      "url": "http://127.0.0.1/published/hs/mcp",
      "enabled": true,
      "managedBy": "vibecoding1c-mcp",
      "family": "vibecoding1c"
    },
    "custom-tool": {
      "type": "remote",
      "url": "http://localhost:9999/mcp",
      "enabled": true,
      "managedBy": "external-mcp",
      "family": "external"
    }
  }
}
"@ -Encoding UTF8

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Remove-AiRules1cManagedMcpConfig
            }

            $codexText = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot ".codex\config.toml")
            $codexText | Should -Not -Match "http://localhost:8000/mcp"
            $codexText | Should -Match ([regex]::Escape('[mcp_servers."1c-code-metadata-mcp"]'))
            $codexText | Should -Match ([regex]::Escape('[mcp_servers."1c-data-mcp"]'))
            $codexText | Should -Match "1c-ssl-mcp"
            $codexText | Should -Match "external-mcp"
            $codexText | Should -Match ([regex]::Escape("# >>> vibecoding1c-mcp project"))
            $codexText | Should -Match ([regex]::Escape("# <<< vibecoding1c-mcp project"))
            $codexText | Should -Match ([regex]::Escape('[mcp_servers."custom-tool"]'))

            $kilo = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot ".kilo\kilo.json") | ConvertFrom-Json
            $kilo.mcp.PSObject.Properties["1c-code-metadata-mcp"] | Should -BeNullOrEmpty
            $kilo.mcp.PSObject.Properties["1C-docs-mcp"] | Should -BeNullOrEmpty
            $kilo.mcp.'1c-ssl-mcp'.managedBy | Should -Be "external-mcp"
            $kilo.mcp.'itl-demo-code'.managedBy | Should -Be "vibecoding1c-mcp"
            $kilo.mcp.'1c-graph-metadata-mcp'.managedBy | Should -Be "vibecoding1c-mcp"
            $kilo.mcp.'1c-data-mcp'.managedBy | Should -Be "vibecoding1c-mcp"
            $kilo.mcp.'custom-tool'.managedBy | Should -Be "external-mcp"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "does not append the AGENTS bridge when upstream AGENTS already loads USER-RULES" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-rules-bridge-test-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "templates") | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\USER-RULES.append.md") -Destination (Join-Path $tempRoot "templates\USER-RULES.append.md")
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\AGENTS.append.md") -Destination (Join-Path $tempRoot "templates\AGENTS.append.md")
            Set-Content -LiteralPath (Join-Path $tempRoot "AGENTS.md") -Encoding UTF8 -Value "# Agent Instructions`n`nRead USER-RULES.md for project-specific instructions."

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Update-AgentGuidanceBridge *> $null
                Update-UserRules *> $null
            }

            $agentsText = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot "AGENTS.md")
            $agentsText | Should -Match "USER-RULES.md"
            $agentsText | Should -Not -Match "## 1C Agent Workflow Bridge"
            $userRulesText = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot "USER-RULES.md")
            $userRulesText | Should -Match "## 1C Project Lifecycle"
            $userRulesText | Should -Match "ITL-WORKFLOW-USER-RULES:START"
            $userRulesText | Should -Match "ITL-WORKFLOW-USER-RULES:END"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "updates workflow package files in a temp project while preserving local runtime state" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-update-workflow-test-" + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project"
        $stdoutPath = Join-Path $tempRoot "stdout.log"
        $stderrPath = Join-Path $tempRoot "stderr.log"
        $previousSourcePath = $env:ITL_WORKFLOW_SOURCE_PATH
        $previousRepo = $env:ITL_WORKFLOW_REPO
        $previousRef = $env:ITL_WORKFLOW_REF

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot | Out-Null
            New-Item -ItemType Directory -Force -Path `
                (Join-Path $projectRoot ".agents\skills\1c-workflow"),
                (Join-Path $projectRoot ".agents\skills\1c-workflow-fast"),
                (Join-Path $projectRoot ".kilo\commands"),
                (Join-Path $projectRoot "templates"),
                (Join-Path $projectRoot ".agent-1c\mcp"),
                (Join-Path $projectRoot ".agent-1c\dev-branches"),
                (Join-Path $projectRoot ".codex"),
                (Join-Path $projectRoot ".kilo") | Out-Null

            Set-Content -LiteralPath (Join-Path $projectRoot ".gitignore") -Encoding UTF8 -Value @"
.dev.env
.agent-1c/mcp/
.agent-1c/dev-branches/
.codex/config.toml
.kilo/kilo.json
.kilo/kilo.jsonc
"@
            Set-Content -LiteralPath (Join-Path $projectRoot "README.md") -Encoding UTF8 -Value "old readme"
            Set-Content -LiteralPath (Join-Path $projectRoot "AGENT-INSTALL.md") -Encoding UTF8 -Value "old install"
            Set-Content -LiteralPath (Join-Path $projectRoot "DEVELOPER-GUIDE.ru.md") -Encoding UTF8 -Value "old developer guide"
            Set-Content -LiteralPath (Join-Path $projectRoot "DEV-BRANCH-DEVELOPMENT.ru.md") -Encoding UTF8 -Value "old branch guide"
            Set-Content -LiteralPath (Join-Path $projectRoot ".agents\skills\1c-workflow\stale.txt") -Encoding UTF8 -Value "stale"
            Set-Content -LiteralPath (Join-Path $projectRoot ".agents\skills\1c-workflow-fast\stale.txt") -Encoding UTF8 -Value "stale"
            Set-Content -LiteralPath (Join-Path $projectRoot ".kilo\commands\itl-old.md") -Encoding UTF8 -Value "stale command"
            Set-Content -LiteralPath (Join-Path $projectRoot ".kilo\commands\custom.md") -Encoding UTF8 -Value "custom command"
            Set-Content -LiteralPath (Join-Path $projectRoot "templates\stale.txt") -Encoding UTF8 -Value "stale template"
            Set-Content -LiteralPath (Join-Path $projectRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"custom":"keep-project"}'
            Set-Content -LiteralPath (Join-Path $projectRoot ".agent-1c\tools.json") -Encoding UTF8 -Value '{"custom":"keep-tools"}'
            Set-Content -LiteralPath (Join-Path $projectRoot ".agent-1c\dependency-lock.json") -Encoding UTF8 -Value '{"schemaVersion":1,"mode":"fresh","dependencies":{}}'
            Set-Content -LiteralPath (Join-Path $projectRoot ".dev.env") -Encoding UTF8 -Value "SECRET=keep"
            Set-Content -LiteralPath (Join-Path $projectRoot ".agent-1c\mcp\state.json") -Encoding UTF8 -Value '{"state":"keep"}'
            Set-Content -LiteralPath (Join-Path $projectRoot ".codex\config.toml") -Encoding UTF8 -Value '[mcp_servers.custom]'
            Set-Content -LiteralPath (Join-Path $projectRoot ".kilo\kilo.json") -Encoding UTF8 -Value '{"custom":"keep"}'
            Set-Content -LiteralPath (Join-Path $projectRoot "USER-RULES.md") -Encoding UTF8 -Value @"
before

## 1C Project Lifecycle

old managed block

## Local Rules

local after
"@

            & git -C $projectRoot init *> $null
            & git -C $projectRoot config user.email "test@example.com"
            & git -C $projectRoot config user.name "Test User"
            & git -C $projectRoot add .
            & git -C $projectRoot commit -m init *> $null
            & git -C $projectRoot branch -M master
            Set-Content -LiteralPath (Join-Path $projectRoot "scratch.local") -Encoding UTF8 -Value "keep untracked"
            $commitCountBefore = ((& git -C $projectRoot rev-list --count HEAD).Trim())

            $env:ITL_WORKFLOW_SOURCE_PATH = $RepoRoot
            $env:ITL_WORKFLOW_REPO = ""
            $env:ITL_WORKFLOW_REF = ""
            & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $projectRoot -Action update-workflow -SkipAiRules > $stdoutPath 2> $stderrPath
            $LASTEXITCODE | Should -Be 0

            $stdout = Get-Content -Encoding UTF8 -Raw $stdoutPath
            $stdout | Should -Match "ITL workflow package updated"
            $stdout | Should -Match "No commit was created automatically"
            $stdout | Should -Match "No active development branches were found"

            (Test-Path -LiteralPath (Join-Path $projectRoot ".agents\skills\1c-workflow\SKILL.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $projectRoot ".agents\skills\1c-workflow\stale.txt") -PathType Leaf) | Should -Be $false
            (Test-Path -LiteralPath (Join-Path $projectRoot ".kilo\commands\itl-update-workflow.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $projectRoot ".kilo\commands\itl-old.md") -PathType Leaf) | Should -Be $false
            (Test-Path -LiteralPath (Join-Path $projectRoot ".kilo\commands\custom.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $projectRoot "templates\dependency-lock.json") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $projectRoot "templates\stale.txt") -PathType Leaf) | Should -Be $false

            (Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot ".dev.env")) | Should -Match "SECRET=keep"
            (Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot ".agent-1c\project.json")) | Should -Match "keep-project"
            (Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot ".agent-1c\tools.json")) | Should -Match "keep-tools"
            (Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot ".agent-1c\mcp\state.json")) | Should -Match "keep"
            (Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot ".codex\config.toml")) | Should -Match "custom"
            (Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot ".kilo\kilo.json")) | Should -Match "keep"
            (Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot "scratch.local")) | Should -Match "keep untracked"

            $lock = Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot ".agent-1c\dependency-lock.json") | ConvertFrom-Json
            $lock.dependencies.workflowPackage.source | Should -Be "path"
            $lock.dependencies.workflowPackage.commit | Should -Be ((& git -C $RepoRoot rev-parse HEAD).Trim())
            $lock.dependencies.workflowPackage.ref | Should -Be "master"
            $lock.dependencies.workflowPackage.updatedAt | Should -Not -BeNullOrEmpty

            $userRulesText = Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot "USER-RULES.md")
            $userRulesText | Should -Match "ITL-WORKFLOW-USER-RULES:START"
            $userRulesText | Should -Match "ITL-WORKFLOW-USER-RULES:END"
            $userRulesText | Should -Match "update-workflow"
            $userRulesText | Should -Not -Match "old managed block"
            $userRulesText | Should -Match "local after"

            ((& git -C $projectRoot rev-list --count HEAD).Trim()) | Should -Be $commitCountBefore
            ((& git -C $projectRoot branch --show-current).Trim()) | Should -Be "master"
            (& git -C $projectRoot status --short) | Should -Not -BeNullOrEmpty
        } finally {
            $env:ITL_WORKFLOW_SOURCE_PATH = $previousSourcePath
            $env:ITL_WORKFLOW_REPO = $previousRepo
            $env:ITL_WORKFLOW_REF = $previousRef
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It "smoke-copies bootstrap package files into a temp project" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-package-smoke-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agents\skills"), (Join-Path $tempRoot ".kilo"), (Join-Path $tempRoot "templates") | Out-Null

            Copy-Item -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow") -Destination (Join-Path $tempRoot ".agents\skills\1c-workflow") -Recurse
            Copy-Item -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow-fast") -Destination (Join-Path $tempRoot ".agents\skills\1c-workflow-fast") -Recurse
            Copy-Item -LiteralPath (Join-Path $RepoRoot ".kilo\commands") -Destination (Join-Path $tempRoot ".kilo\commands") -Recurse
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\project.json") -Destination (Join-Path $tempRoot "templates\project.json")
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\tools.json") -Destination (Join-Path $tempRoot "templates\tools.json")
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\dev.env.example") -Destination (Join-Path $tempRoot "templates\dev.env.example")
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\gitignore.append") -Destination (Join-Path $tempRoot "templates\gitignore.append")
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\USER-RULES.append.md") -Destination (Join-Path $tempRoot "USER-RULES.md")
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\AGENTS.append.md") -Destination (Join-Path $tempRoot "AGENTS.md")

            (Test-Path -LiteralPath (Join-Path $tempRoot ".agents\skills\1c-workflow\SKILL.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $tempRoot ".agents\skills\1c-workflow-fast\SKILL.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $tempRoot ".kilo\commands\itl-vanessa-mcp.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $tempRoot ".agents\skills\1c-workflow\tools\event-log-exporter\EventLogExporter.xml") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $tempRoot "AGENTS.md") -PathType Leaf) | Should -Be $true
            (Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot "AGENTS.md")) | Should -Match "USER-RULES.md"
            (Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot "USER-RULES.md")) | Should -Match "1C Project Lifecycle"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "allocates Vanessa MCP ports per development branch state" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-port-test-" + [guid]::NewGuid().ToString("N"))
        $oldRange = [Environment]::GetEnvironmentVariable("VANESSA_MCP_PORT_RANGE", "Process")
        $listener = $null

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c\dev-branches") | Out-Null
            & git -C $tempRoot init *> $null

            $basePort = 0
            for ($candidate = 41000; $candidate -lt 55000; $candidate += 10) {
                $probe1 = $null
                $probe2 = $null
                try {
                    $address = [System.Net.IPAddress]::Parse("127.0.0.1")
                    $probe1 = New-Object System.Net.Sockets.TcpListener($address, $candidate)
                    $probe2 = New-Object System.Net.Sockets.TcpListener($address, ($candidate + 1))
                    $probe1.Start()
                    $probe2.Start()
                    $basePort = $candidate
                    break
                } catch {
                } finally {
                    if ($null -ne $probe1) { $probe1.Stop() }
                    if ($null -ne $probe2) { $probe2.Stop() }
                }
            }
            $basePort | Should -BeGreaterThan 0

            [Environment]::SetEnvironmentVariable("VANESSA_MCP_PORT_RANGE", "$basePort..$($basePort + 1)", "Process")

            $otherState = @{
                devBranchName = "Other Branch"
                safeDevBranchName = "other-branch"
                devBranch = "itldev/other-branch"
                vanessaMcpPort = $basePort
            } | ConvertTo-Json
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\dev-branches\other-branch.json") -Value $otherState -Encoding UTF8

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchName = "Current Branch"
                    safeDevBranchName = "current-branch"
                    devBranch = "itldev/current-branch"
                }
                Resolve-VanessaMcpPort -State $state
            } | Should -Be ($basePort + 1)

            Remove-Item -LiteralPath (Join-Path $tempRoot ".agent-1c\dev-branches\other-branch.json") -Force
            $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse("127.0.0.1"), $basePort)
            $listener.Start()

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchName = "Current Branch"
                    safeDevBranchName = "current-branch"
                    devBranch = "itldev/current-branch"
                }
                Resolve-VanessaMcpPort -State $state
            } | Should -Be ($basePort + 1)

            $listener.Stop()
            $listener = $null

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchName = "Current Branch"
                    safeDevBranchName = "current-branch"
                    devBranch = "itldev/current-branch"
                    vanessaMcpPort = $basePort
                }
                Resolve-VanessaMcpPort -State $state
            } | Should -Be $basePort
        } finally {
            if ($null -ne $listener) {
                $listener.Stop()
            }
            [Environment]::SetEnvironmentVariable("VANESSA_MCP_PORT_RANGE", $oldRange, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "selects vibecoding1c MCP embedding models from mocked hardware" {
        $results = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            [pscustomobject]@{
                Gpu6 = (Select-Vibecoding1cMcpEmbeddingModel -GpuMemoryMb 6144 -RamGb 32).modelId
                Gpu4 = (Select-Vibecoding1cMcpEmbeddingModel -GpuMemoryMb 4096 -RamGb 32).modelId
                Gpu3 = (Select-Vibecoding1cMcpEmbeddingModel -GpuMemoryMb 3072 -RamGb 32).modelId
                CpuLarge = (Select-Vibecoding1cMcpEmbeddingModel -GpuMemoryMb 0 -RamGb 32).modelId
                CpuSmall = (Select-Vibecoding1cMcpEmbeddingModel -GpuMemoryMb 0 -RamGb 8).modelId
            }
        }

        $results.Gpu6 | Should -Be "Qwen3-Embedding-4B-GGUF:Q8_0"
        $results.Gpu4 | Should -Be "Qwen3-Embedding-4B-GGUF:Q6_K"
        $results.Gpu3 | Should -Be "Qwen3-Embedding-4B-GGUF:Q4_K_M"
        $results.CpuLarge | Should -Be "intfloat/multilingual-e5-base"
        $results.CpuSmall | Should -Be "intfloat/multilingual-e5-small"
    }

    It "patches Data MCP tools XML from vcvalidatequery to validatequery" {
        $patched = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $catalogName = Get-DataMcpToolsCatalogLocalName
            $xml = @"
<DataExchange>
  <$catalogName>
    <Description>vcvalidatequery</Description>
  </$catalogName>
</DataExchange>
"@
            Convert-DataMcpToolsXmlText -Text $xml
        }

        $patched | Should -Match "<Description>validatequery</Description>"
        $patched | Should -Not -Match "vcvalidatequery"
    }

    It "patches a publication default.vrd with the Data MCP HTTP service" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("data-mcp-vrd-test-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "default.vrd") -Encoding UTF8 -Value @"
<?xml version="1.0" encoding="UTF-8"?>
<point xmlns="http://v8.1c.ru/8.2/virtual-resource-system"
       base="/published"
       ib="File='C:\base';Usr='Admin';Pwd=''"
       enable="false">
  <httpServices publishByDefault="false"/>
</point>
"@

            & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                Enable-DataMcpHttpService -PublicationDir $tempRoot *> $null
            }

            $vrdText = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot "default.vrd")
            $vrdText | Should -Match 'name="APA_MCP"'
            $vrdText | Should -Match 'rootUrl="mcp"'
            $vrdText | Should -Match 'enable="true"'
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "merges managed Codex TOML and Kilo MCP JSON without deleting unrelated entries" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-config-test-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".codex"), (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".codex\config.toml") -Value @"
[mcp_servers.unrelated]
url = "http://localhost:9999/mcp"
"@ -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Value @"
{
  "mcp": {
    "unrelated": {
      "type": "remote",
      "url": "http://localhost:9999/mcp"
    },
    "external-tool": {
      "type": "remote",
      "url": "http://localhost:9998/mcp",
      "managedBy": "external-mcp",
      "family": "external"
    },
    "itl-old": {
      "type": "remote",
      "url": "http://localhost:1/mcp",
      "managedBy": "vibecoding1c-mcp",
      "family": "vibecoding1c"
    },
    "VanessaAutomation-demo": {
      "type": "remote",
      "url": "http://localhost:9874/mcp",
      "managedBy": "vanessa-mcp",
      "family": "vanessa",
      "scope": "branch"
    }
  }
}
"@ -Encoding UTF8

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help -McpServerId code -McpProvider remote -McpConfigId trade *> $null
                $endpoints = @(
                    [pscustomobject]@{ id = "docs"; name = "itl-1c-docs"; url = "http://127.0.0.1:18000/mcp"; scope = "global"; provider = "remote" },
                    [pscustomobject]@{ id = "code"; name = "itl-dead-code"; url = "http://127.0.0.1:18102/mcp"; scope = "project"; provider = "remote"; configId = "trade"; status = "stopped"; clientNames = [pscustomobject]@{ aiRules1c = "1c-code-metadata-mcp" } },
                    [pscustomobject]@{ id = "code"; name = "itl-trade-code"; url = "http://127.0.0.1:18100/mcp"; scope = "project"; provider = "remote"; configId = "trade"; clientNames = [pscustomobject]@{ aiRules1c = "1c-code-metadata-mcp" } },
                    [pscustomobject]@{ id = "code"; name = "itl-erp-code"; url = "http://127.0.0.1:18101/mcp"; scope = "project"; provider = "remote"; configId = "erp"; clientNames = [pscustomobject]@{ aiRules1c = "1c-code-metadata-mcp" } },
                    [pscustomobject]@{ id = "data"; name = "itl-current-data"; url = "http://localhost/current/hs/mcp"; scope = "branch"; provider = "local"; clientNames = [pscustomobject]@{ aiRules1c = "1c-data-mcp" } }
                )
                Write-Vibecoding1cMcpCodexConfig -Path (Join-Path $tempRoot ".codex\config.toml") -BlockId "project" -Endpoints $endpoints
                Write-Vibecoding1cMcpCodexConfig -Path (Join-Path $tempRoot ".codex\config.toml") -BlockId "project" -Endpoints $endpoints
                Write-Vibecoding1cMcpKiloConfig -Endpoints $endpoints
            }

            $codexText = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot ".codex\config.toml")
            $codexText | Should -Match "mcp_servers.unrelated"
            $codexText | Should -Match ([regex]::Escape('[mcp_servers."1C-docs-mcp"]'))
            $codexText | Should -Match ([regex]::Escape('[mcp_servers."1c-code-metadata-mcp"]'))
            $codexText | Should -Match ([regex]::Escape('[mcp_servers."1c-data-mcp"]'))
            $codexText | Should -Match "http://127.0.0.1:18100/mcp"
            $codexText | Should -Match "http://localhost/current/hs/mcp"
            $codexText | Should -Not -Match "http://127.0.0.1:18101/mcp"
            $codexText | Should -Not -Match "http://127.0.0.1:18102/mcp"
            @([regex]::Matches($codexText, [regex]::Escape("# >>> vibecoding1c-mcp project"))).Count | Should -Be 1

            $kilo = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot ".kilo\kilo.json") | ConvertFrom-Json
            $kilo.mcp.unrelated.url | Should -Be "http://localhost:9999/mcp"
            $kilo.mcp.'external-tool'.url | Should -Be "http://localhost:9998/mcp"
            $kilo.mcp.'external-tool'.family | Should -Be "external"
            $kilo.mcp.'VanessaAutomation-demo'.url | Should -Be "http://localhost:9874/mcp"
            $kilo.mcp.'VanessaAutomation-demo'.managedBy | Should -Be "vanessa-mcp"
            $kilo.mcp.'VanessaAutomation-demo'.family | Should -Be "vanessa"
            $kilo.mcp.PSObject.Properties["itl-old"] | Should -BeNullOrEmpty
            $kilo.mcp.'1c-code-metadata-mcp'.url | Should -Be "http://127.0.0.1:18100/mcp"
            $kilo.mcp.'1c-code-metadata-mcp'.managedBy | Should -Be "vibecoding1c-mcp"
            $kilo.mcp.'1c-code-metadata-mcp'.family | Should -Be "vibecoding1c"
            $kilo.mcp.'1c-code-metadata-mcp'.logicalId | Should -Be "code"
            $kilo.mcp.'1c-code-metadata-mcp'.registryName | Should -Be "itl-trade-code"
            $kilo.mcp.'1c-data-mcp'.url | Should -Be "http://localhost/current/hs/mcp"
            $kilo.mcp.'1c-data-mcp'.managedBy | Should -Be "vibecoding1c-mcp"
            $kilo.mcp.'1c-data-mcp'.logicalId | Should -Be "data"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "writes branch-local Vanessa MCP into Kilo config without deleting custom entries" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vanessa-mcp-kilo-config-test-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Value @"
{
  "mcp": {
    "custom-tool": {
      "type": "remote",
      "url": "http://localhost:9999/mcp",
      "managedBy": "external-mcp",
      "family": "external"
    },
    "VanessaAutomation-demo": {
      "type": "remote",
      "url": "http://localhost:9874/mcp",
      "managedBy": "vanessa-mcp",
      "family": "vanessa",
      "scope": "branch",
      "devBranchName": "demo",
      "safeDevBranchName": "demo"
    }
  }
}
"@ -Encoding UTF8

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchName = "feature/demo"
                    safeDevBranchName = "feature-demo"
                    vanessaMcpPort = 9888
                    vanessaMcpUrl = "http://localhost:9888/mcp"
                }
                Write-VanessaMcpKiloConfig -State $state *> $null
            }

            $kilo = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot ".kilo\kilo.json") | ConvertFrom-Json
            $kilo.mcp.'custom-tool'.url | Should -Be "http://localhost:9999/mcp"
            $kilo.mcp.'custom-tool'.managedBy | Should -Be "external-mcp"
            $kilo.mcp.'VanessaAutomation-demo'.url | Should -Be "http://localhost:9874/mcp"
            $kilo.mcp.'VanessaAutomation-feature-demo'.type | Should -Be "remote"
            $kilo.mcp.'VanessaAutomation-feature-demo'.url | Should -Be "http://localhost:9888/mcp"
            $kilo.mcp.'VanessaAutomation-feature-demo'.enabled | Should -Be $true
            $kilo.mcp.'VanessaAutomation-feature-demo'.timeout | Should -Be 15000
            $kilo.mcp.'VanessaAutomation-feature-demo'.managedBy | Should -Be "vanessa-mcp"
            $kilo.mcp.'VanessaAutomation-feature-demo'.family | Should -Be "vanessa"
            $kilo.mcp.'VanessaAutomation-feature-demo'.scope | Should -Be "branch"
            $kilo.mcp.'VanessaAutomation-feature-demo'.devBranchName | Should -Be "feature/demo"
            $kilo.mcp.'VanessaAutomation-feature-demo'.safeDevBranchName | Should -Be "feature-demo"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "connects Data MCP for a published branch with stubbed 1C calls" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("data-mcp-success-test-" + [guid]::NewGuid().ToString("N"))
        $publicationDir = Join-Path $tempRoot "publication"

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c"), $publicationDir | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\project.json") -Destination (Join-Path $tempRoot ".agent-1c\project.json")
            Set-Content -LiteralPath (Join-Path $publicationDir "default.vrd") -Encoding UTF8 -Value @"
<?xml version="1.0" encoding="UTF-8"?>
<point xmlns="http://v8.1c.ru/8.2/virtual-resource-system" base="/published" ib="File='C:\base';Usr='Admin';Pwd=''" enable="false"/>
"@

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null

                function Ensure-DataMcpPackage {
                    return [pscustomobject]@{
                        cfePath = "C:\fake\OneMCP.cfe"
                        toolsXmlPath = "C:\fake\tools.xml"
                    }
                }
                function Install-DataMcpExtension {
                    param([object]$State, [string]$CfePath)
                    $script:DataMcpCfePath = $CfePath
                    return "designer.log"
                }
                function Invoke-DataMcpToolsLoader {
                    param([object]$State, [string]$ToolsXmlPath)
                    $script:DataMcpToolsXmlPath = $ToolsXmlPath
                    return "tools-loader.json"
                }
                function Test-DataMcpEndpointReachable {
                    param([string]$Url)
                    return $true
                }
                function Write-Vibecoding1cMcpClientConfig {
                    $localEndpoints = @(Get-Vibecoding1cMcpCurrentEndpoints | Where-Object { [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "scope" -Default "") -ne "global" })
                    Write-Vibecoding1cMcpCodexConfig -Path (Join-Path $script:ProjectRoot ".codex\config.toml") -BlockId "project" -Endpoints $localEndpoints
                    Write-Vibecoding1cMcpKiloConfig -Endpoints $localEndpoints
                }

                $state = [pscustomobject]@{
                    devBranchInfoBasePath = "C:\base"
                    infoBaseKind = "file"
                    publicationUrl = "http://localhost/published"
                }
                $updates = Install-DevBranchDataMcpBestEffort -State $state -PublicationUrl "http://localhost/published" -PublicationDir $publicationDir
                $updates.dataMcpStatus | Should -Be "running"
                $updates.dataMcpEndpointUrl | Should -Be "http://localhost/published/hs/mcp"
                $script:DataMcpCfePath | Should -Be "C:\fake\OneMCP.cfe"
                $script:DataMcpToolsXmlPath | Should -Be "C:\fake\tools.xml"
            }

            $codexText = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot ".codex\config.toml")
            $codexText | Should -Match ([regex]::Escape('[mcp_servers."1c-data-mcp"]'))
            $codexText | Should -Match "http://localhost/published/hs/mcp"
            $vrdText = Get-Content -Encoding UTF8 -Raw (Join-Path $publicationDir "default.vrd")
            $vrdText | Should -Match 'name="APA_MCP"'
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "keeps published branch creation non-blocking when Data MCP package is missing" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("data-mcp-failure-test-" + [guid]::NewGuid().ToString("N"))
        $publicationDir = Join-Path $tempRoot "publication"

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c"), $publicationDir | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\project.json") -Destination (Join-Path $tempRoot ".agent-1c\project.json")
            Set-Content -LiteralPath (Join-Path $publicationDir "default.vrd") -Encoding UTF8 -Value @"
<?xml version="1.0" encoding="UTF-8"?>
<point xmlns="http://v8.1c.ru/8.2/virtual-resource-system" base="/published" ib="File='C:\base';Usr='Admin';Pwd=''" enable="false"/>
"@

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null

                function Ensure-DataMcpPackage {
                    throw "MCP_1C_Distr.zip was not found"
                }
                function Write-Vibecoding1cMcpClientConfig {
                    $localEndpoints = @(Get-Vibecoding1cMcpCurrentEndpoints | Where-Object { [string](Get-Vibecoding1cMcpObjectValue -Object $_ -Name "scope" -Default "") -ne "global" })
                    Write-Vibecoding1cMcpCodexConfig -Path (Join-Path $script:ProjectRoot ".codex\config.toml") -BlockId "project" -Endpoints $localEndpoints
                    Write-Vibecoding1cMcpKiloConfig -Endpoints $localEndpoints
                }

                $state = [pscustomobject]@{
                    devBranchInfoBasePath = "C:\base"
                    infoBaseKind = "file"
                    publicationUrl = "http://localhost/published"
                }
                $updates = Install-DevBranchDataMcpBestEffort -State $state -PublicationUrl "http://localhost/published" -PublicationDir $publicationDir 3>$null
                $updates.dataMcpStatus | Should -Be "failed"
                $updates.dataMcpError | Should -Match "MCP_1C_Distr.zip"
            }

            $codexPath = Join-Path $tempRoot ".codex\config.toml"
            if (Test-Path -LiteralPath $codexPath -PathType Leaf -ErrorAction SilentlyContinue) {
                (Get-Content -Encoding UTF8 -Raw $codexPath) | Should -Not -Match "1c-data-mcp"
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "wires Vanessa verify through TestManager and TestClient" {
        $HelperText | Should -Match "Resolve-VanessaTestPort"
        $HelperText | Should -Match "VANESSA_TEST_PORT_RANGE"
        $HelperText | Should -Match "VANESSA_TEST_TIMEOUT_SECONDS"
        $HelperText | Should -Match "Initialize-DevBranchEventLogBaseline"
        $HelperText | Should -Match "Read-OneCEventLogDirect"
        $HelperText | Should -Match "Test-DevBranchEventLogAfterVanessa"
        $HelperText | Should -Match ([regex]::Escape("/TESTMANAGER"))
        $HelperText | Should -Match ([regex]::Escape("-TPort"))
        $HelperText | Should -Match "New-VanessaStartFeaturePlayerCommand"
        $HelperText | Should -Match "StartFeaturePlayer;VAParams="
        $HelperText | Should -Match "Get-OneCProcessInfo"
        $HelperText | Should -Match "Stop-OwnHungVanessaTestClients"
        $HelperText | Should -Match "Invoke-ForeignVanessaTestProcessPolicy"
        $HelperText | Should -Match "Write-ForeignVanessaTestProcessWarning"
        $HelperText | Should -Match "Test-VanessaTestPortUsedByForeignProcess"
        $HelperText | Should -Match "VANESSA_TEST_FOREIGN_WAIT_MODE"
        $HelperText | Should -Match "ConvertFrom-Utf8Base64"

        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "VANESSA_TEST_PORT_RANGE=48051\.\.48150"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "VANESSA_TEST_FOREIGN_WAIT_MODE=warn"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "VANESSA_TEST_TIMEOUT_SECONDS=1800"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "VANESSA_EVENT_LOG_READER=auto"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\workflow.md")) | Should -Match "TESTMANAGER -> TESTCLIENT"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\workflow.md")) | Should -Match "VANESSA_TEST_FOREIGN_WAIT_MODE=warn"
    }

    It "reads direct 8.3.22 sequential event log and compares against branch baseline" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-event-log-test-" + [guid]::NewGuid().ToString("N"))

        try {
            $logDir = Join-Path $tempRoot "ib\1Cv8Log"
            $runDir = Join-Path $tempRoot "build\test-results\vanessa\run"
            New-Item -ItemType Directory -Force -Path $logDir, $runDir | Out-Null
            Set-Content -LiteralPath (Join-Path $logDir "1Cv8.lgf") -Encoding UTF8 -Value "{1}"
            $records = @(
                '{20260703100000,E,"_$PerformError$_","Catalog.Items","Item 1","Legacy error"}',
                '{20260703120500,E,"_$PerformError$_","Catalog.Items","Item 1","Legacy error"}',
                '{20260703121000,E,"_$PerformError$_","Catalog.Items","Item 1","New error 12345678"}',
                '{20260703121100,W,"_$PerformError$_","Catalog.Items","Item 1","Warning only"}'
            ) -join [Environment]::NewLine
            Set-Content -LiteralPath (Join-Path $logDir "20260703.lgp") -Encoding UTF8 -Value $records

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchName = "Current Branch"
                    safeDevBranchName = "current-branch"
                    devBranch = "itldev/current-branch"
                    infoBaseKind = "file"
                    devBranchInfoBasePath = (Join-Path $tempRoot "ib")
                    stateProjectRoot = $tempRoot
                }

                $baselineEvents = @(Read-OneCEventLogDirect -State $state -EndTime ([datetime]"2026-07-03T10:30:00"))
                $baselineEvents.Count | Should -Be 1
                $baselinePath = Get-DevBranchEventLogBaselinePath -State $state
                $baseline = [ordered]@{
                    schemaVersion = 1
                    signatures = @($baselineEvents[0].signature)
                }
                Write-Utf8Text -Path $baselinePath -Value (($baseline | ConvertTo-Json -Depth 5) + [Environment]::NewLine)
                $state | Add-Member -NotePropertyName eventLogBaselinePath -NotePropertyValue $baselinePath -Force

                $fresh = @(Read-OneCEventLogDirect -State $state -StartTime ([datetime]"2026-07-03T12:00:00") -EndTime ([datetime]"2026-07-03T12:30:00"))
                $fresh.Count | Should -Be 2

                $result = Test-DevBranchEventLogAfterVanessa `
                    -State $state `
                    -RunStartedAt ([datetime]"2026-07-03T12:00:00") `
                    -RunFinishedAt ([datetime]"2026-07-03T12:30:00") `
                    -RunDirectory $runDir

                $result.status | Should -Be "failed"
                $result.newErrorCount | Should -Be 1
                $result.legacyErrorCount | Should -Be 1
                (Test-Path -LiteralPath $result.reportPath -PathType Leaf) | Should -Be $true
                (Get-Content -Encoding UTF8 -Raw $result.reportPath) | Should -Match "New error"
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "keeps event log fallback exporter source in the repo without D Downloads dependency" {
        $sourceRoot = Join-Path $RepoRoot ".agents\skills\1c-workflow\tools\event-log-exporter\EventLogExporter.xml"
        $sourceDir = Split-Path -Parent $sourceRoot
        $modulePath = @(Get-ChildItem -LiteralPath $sourceDir -Recurse -File -Filter "Module.bsl" | Select-Object -First 1).FullName
        $exportMethod = -join ([char[]](1042, 1099, 1075, 1088, 1091, 1079, 1080, 1090, 1100, 1046, 1091, 1088, 1085, 1072, 1083, 1056, 1077, 1075, 1080, 1089, 1090, 1088, 1072, 1094, 1080, 1080))
        $errorLevel = -join ([char[]](1059, 1088, 1086, 1074, 1077, 1085, 1100, 1046, 1091, 1088, 1085, 1072, 1083, 1072, 1056, 1077, 1075, 1080, 1089, 1090, 1088, 1072, 1094, 1080, 1080, 46, 1054, 1096, 1080, 1073, 1082, 1072))

        (Test-Path -LiteralPath $sourceRoot -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath $modulePath -PathType Leaf) | Should -Be $true
        $moduleText = Get-Content -Encoding UTF8 -Raw $modulePath
        $moduleText | Should -Match ([regex]::Escape($exportMethod))
        $moduleText | Should -Match ([regex]::Escape($errorLevel))
        $moduleText | Should -Match "levels"
        $moduleText | Should -Match "status"
        $moduleText | Should -Match "failure"
        $moduleText | Should -Match "errorMessage"
        $moduleText | Should -Match "errorDetails"
        $moduleText | Should -Not -Match "D:\\Downloads"
        $HelperText | Should -Match "LoadExternalDataProcessorOrReportFromFiles"
        $HelperText | Should -Match "Event log fallback exporter failed"
        $HelperText | Should -Match "errorMessage"
        $HelperText | Should -Match "errorDetails"
        $HelperText | Should -Not -Match "COMConnector"
        $HelperText | Should -Not -Match "ibcmd"
    }

    It "keeps required package files visible for Git packaging" {
        $requiredFiles = @(
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1",
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.data-mcp.ps1",
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.vanessa.ps1",
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.vibecoding1c-mcp.ps1",
            ".agents/skills/1c-workflow/scripts/lib/agent-1c.lifecycle.ps1",
            ".kilo/commands/itl-update-rules.md",
            ".kilo/commands/itl-vanessa-mcp.md",
            "scripts/test.ps1",
            "templates/AGENTS.append.md",
            "templates/USER-RULES.append.md",
            "templates/dependency-lock.json",
            ".agents/skills/1c-workflow/tools/data-mcp-tools-loader/DataMcpToolsLoader.xml",
            ".agents/skills/1c-workflow/tools/event-log-exporter/EventLogExporter.xml"
        )

        foreach ($relativePath in $requiredFiles) {
            (Test-Path -LiteralPath (Join-Path $RepoRoot $relativePath) -PathType Leaf) | Should -Be $true
            @(& git -C $RepoRoot ls-files --cached --others --exclude-standard -- $relativePath).Count | Should -BeGreaterThan 0
        }

        $modulePath = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\tools\event-log-exporter") -Recurse -File -Filter "Module.bsl" | Select-Object -First 1).FullName
        $modulePath | Should -Not -BeNullOrEmpty
        $moduleRelativePath = $modulePath.Substring($RepoRoot.Length + 1).Replace("\", "/")
        @(& git -C $RepoRoot ls-files --cached --others --exclude-standard -- $moduleRelativePath).Count | Should -BeGreaterThan 0
    }

    It "times out native processes used by Vanessa watchdog" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-native-timeout-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $powershellPath = (Get-Command powershell.exe).Source
                $result = Invoke-NativeProcessAndWaitResult `
                    -FilePath $powershellPath `
                    -Arguments @("-NoProfile", "-Command", "Start-Sleep -Seconds 5") `
                    -TimeoutSeconds 1
                $result.timedOut | Should -Be $true
                $result.exitCode | Should -Be -1
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "creates Vanessa TestClient params and keeps VAParams path unquoted" {
        function Decode-TestUtf8([string]$Value) {
            return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Value))
        }

        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-params-test-" + [guid]::NewGuid().ToString("N"))
        $oldUser = [Environment]::GetEnvironmentVariable("IB_USER", "Process")
        $oldPassword = [Environment]::GetEnvironmentVariable("IB_PASSWORD", "Process")

        try {
            $featuresPath = Join-Path $tempRoot "tests\features"
            $runDirectory = Join-Path $tempRoot "build\test-results\vanessa\run"
            $ibPath = Join-Path $tempRoot "ib"
            New-Item -ItemType Directory -Force -Path $featuresPath, $runDirectory, $ibPath | Out-Null
            [Environment]::SetEnvironmentVariable("IB_USER", "Admin", "Process")
            [Environment]::SetEnvironmentVariable("IB_PASSWORD", "", "Process")

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchName = "Current Branch"
                    safeDevBranchName = "current-branch"
                    devBranch = "itldev/current-branch"
                    infoBaseKind = "file"
                    devBranchInfoBasePath = $ibPath
                }
                $statusPath = Join-Path $runDirectory "status.json"
                $paramsPath = New-VanessaParamsFile `
                    -FeaturePath $featuresPath `
                    -RunDirectory $runDirectory `
                    -StatusPath $statusPath `
                    -State $state `
                    -TestPort 48051 `
                    -VanessaVersion "1.2.043.28"
                $command = New-VanessaStartFeaturePlayerCommand -ParamsPath $paramsPath
                $params = Get-Content -Encoding UTF8 -Raw $paramsPath | ConvertFrom-Json

                $scenarioKey = Decode-TestUtf8 "0JLRi9C/0L7Qu9C90LXQvdC40LXQodGG0LXQvdCw0YDQuNC10LI="
                $clientKey = Decode-TestUtf8 "0JrQu9C40LXQvdGC0KLQtdGB0YLQuNGA0L7QstCw0L3QuNGP"
                $clientsKey = Decode-TestUtf8 "0JTQsNC90L3Ri9C10JrQu9C40LXQvdGC0L7QstCi0LXRgdGC0LjRgNC+0LLQsNC90LjRjw=="
                $portKey = Decode-TestUtf8 "0J/QvtGA0YLQl9Cw0L/Rg9GB0LrQsNCi0LXRgdGC0JrQu9C40LXQvdGC0LA="
                $pathKey = Decode-TestUtf8 "0J/Rg9GC0YzQmtCY0L3RhNC+0LHQsNC30LU="
                $statusKey = Decode-TestUtf8 "0J/Rg9GC0YzQmtCk0LDQudC70YPQlNC70Y/QktGL0LPRgNGD0LfQutC40KHRgtCw0YLRg9GB0LDQktGL0L/QvtC70L3QtdC90LjRj9Ch0YbQtdC90LDRgNC40LXQsg=="
                $windowTimeoutKey = Decode-TestUtf8 "0JrQvtC70LjRh9C10YHRgtCy0L7QodC10LrRg9C90LTQn9C+0LjRgdC60LDQntC60L3QsA=="

                $params.Version | Should -Be "1.2.043.28"
                $params.junitpath | Should -Be $runDirectory
                $params.PSObject.Properties[$statusKey].Value | Should -Be $statusPath
                $params.PSObject.Properties[$scenarioKey].Value.PSObject.Properties[$windowTimeoutKey].Value | Should -Be 60

                $clientSettings = $params.PSObject.Properties[$clientKey].Value
                $clientRecord = @($clientSettings.PSObject.Properties[$clientsKey].Value)[0]
                [int]$clientRecord.PSObject.Properties[$portKey].Value | Should -Be 48051
                $clientRecord.PSObject.Properties[$pathKey].Value | Should -Match ([regex]::Escape($ibPath))

                $command | Should -Be "StartFeaturePlayer;VAParams=$paramsPath"
                $command | Should -Not -Match 'VAParams="'
            }
        } finally {
            [Environment]::SetEnvironmentVariable("IB_USER", $oldUser, "Process")
            [Environment]::SetEnvironmentVariable("IB_PASSWORD", $oldPassword, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "allocates Vanessa verify test ports per development branch state" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-test-port-test-" + [guid]::NewGuid().ToString("N"))
        $oldRange = [Environment]::GetEnvironmentVariable("VANESSA_TEST_PORT_RANGE", "Process")
        $listener = $null

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c\dev-branches") | Out-Null
            & git -C $tempRoot init *> $null

            $basePort = 0
            for ($candidate = 42000; $candidate -lt 55000; $candidate += 10) {
                $probe1 = $null
                $probe2 = $null
                try {
                    $address = [System.Net.IPAddress]::Parse("127.0.0.1")
                    $probe1 = New-Object System.Net.Sockets.TcpListener($address, $candidate)
                    $probe2 = New-Object System.Net.Sockets.TcpListener($address, ($candidate + 1))
                    $probe1.Start()
                    $probe2.Start()
                    $basePort = $candidate
                    break
                } catch {
                } finally {
                    if ($null -ne $probe1) { $probe1.Stop() }
                    if ($null -ne $probe2) { $probe2.Stop() }
                }
            }
            $basePort | Should -BeGreaterThan 0

            [Environment]::SetEnvironmentVariable("VANESSA_TEST_PORT_RANGE", "$basePort..$($basePort + 1)", "Process")
            $otherState = @{
                devBranchName = "Other Branch"
                safeDevBranchName = "other-branch"
                devBranch = "itldev/other-branch"
                vanessaTestPort = $basePort
            } | ConvertTo-Json
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\dev-branches\other-branch.json") -Value $otherState -Encoding UTF8

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchName = "Current Branch"
                    safeDevBranchName = "current-branch"
                    devBranch = "itldev/current-branch"
                }
                Resolve-VanessaTestPort -State $state
            } | Should -Be ($basePort + 1)

            Remove-Item -LiteralPath (Join-Path $tempRoot ".agent-1c\dev-branches\other-branch.json") -Force
            $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse("127.0.0.1"), $basePort)
            $listener.Start()

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchName = "Current Branch"
                    safeDevBranchName = "current-branch"
                    devBranch = "itldev/current-branch"
                }
                Resolve-VanessaTestPort -State $state
            } | Should -Be ($basePort + 1)

            $listener.Stop()
            $listener = $null

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null

                function Get-OneCProcessInfo {
                    return @([pscustomobject]@{
                        processId = 2201
                        name = "1cv8c.exe"
                        commandLine = "1cv8c.exe /TESTMANAGER -TPort $basePort /F `"D:\worktrees\other\.agent-1c\infobases\other`""
                        workingSetMb = 20
                    })
                }

                $state = [pscustomobject]@{
                    devBranchName = "Current Branch"
                    safeDevBranchName = "current-branch"
                    devBranch = "itldev/current-branch"
                    devBranchInfoBasePath = Join-Path $tempRoot "ib"
                    worktreePath = $tempRoot
                }
                Resolve-VanessaTestPort -State $state
            } | Should -Be ($basePort + 1)

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchName = "Current Branch"
                    safeDevBranchName = "current-branch"
                    devBranch = "itldev/current-branch"
                    vanessaTestPort = $basePort
                }
                Resolve-VanessaTestPort -State $state
            } | Should -Be $basePort
        } finally {
            if ($null -ne $listener) {
                $listener.Stop()
            }
            [Environment]::SetEnvironmentVariable("VANESSA_TEST_PORT_RANGE", $oldRange, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "warns about foreign Vanessa test processes by default without waiting" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-foreign-warn-" + [guid]::NewGuid().ToString("N"))
        $oldWaitMode = [Environment]::GetEnvironmentVariable("VANESSA_TEST_FOREIGN_WAIT_MODE", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            [Environment]::SetEnvironmentVariable("VANESSA_TEST_FOREIGN_WAIT_MODE", $null, "Process")

            $output = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $script:waitCalled = $false

                function Wait-ForeignVanessaTestQuiet {
                    param([object]$State, [int]$TestPort)
                    $script:waitCalled = $true
                }

                function Get-ForeignVanessaTestProcesses {
                    param([object]$State, [int]$TestPort)
                    return @([pscustomobject]@{
                        processId = 2001
                        name = "1cv8c.exe"
                        commandLine = "1cv8c.exe /TESTMANAGER -TPort 48052 /F `"D:\worktrees\other\.agent-1c\infobases\other`" /CStartFeaturePlayer;VAParams=D:\worktrees\other\params.json"
                        workingSetMb = 20
                    })
                }

                $state = [pscustomobject]@{
                    devBranchName = "Current Branch"
                    safeDevBranchName = "current-branch"
                    devBranch = "itldev/current-branch"
                    devBranchInfoBasePath = Join-Path $tempRoot "ib"
                    worktreePath = $tempRoot
                }

                Invoke-ForeignVanessaTestProcessPolicy -State $state -TestPort 48051
                "WAIT_CALLED=$script:waitCalled"
            } *>&1

            $joined = $output -join [Environment]::NewLine
            $joined | Should -Match "Foreign Vanessa 1C test process"
            $joined | Should -Match "Continuing because verify uses branch-local ports"
            $joined | Should -Match "WAIT_CALLED=False"
        } finally {
            [Environment]::SetEnvironmentVariable("VANESSA_TEST_FOREIGN_WAIT_MODE", $oldWaitMode, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "uses foreign Vanessa wait policy only in conservative wait mode" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-foreign-wait-" + [guid]::NewGuid().ToString("N"))
        $oldWaitMode = [Environment]::GetEnvironmentVariable("VANESSA_TEST_FOREIGN_WAIT_MODE", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            [Environment]::SetEnvironmentVariable("VANESSA_TEST_FOREIGN_WAIT_MODE", "wait", "Process")

            $output = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $script:waitCalled = $false

                function Wait-ForeignVanessaTestQuiet {
                    param([object]$State, [int]$TestPort)
                    $script:waitCalled = $true
                    "WAIT_POLICY_USED=$TestPort"
                }

                function Write-ForeignVanessaTestProcessWarning {
                    param([object]$State, [int]$TestPort)
                    "WARN_POLICY_USED=$TestPort"
                }

                $state = [pscustomobject]@{
                    devBranchName = "Current Branch"
                    safeDevBranchName = "current-branch"
                    devBranch = "itldev/current-branch"
                    devBranchInfoBasePath = Join-Path $tempRoot "ib"
                    worktreePath = $tempRoot
                }

                Invoke-ForeignVanessaTestProcessPolicy -State $state -TestPort 48051
                "WAIT_CALLED=$script:waitCalled"
            } *>&1

            $joined = $output -join [Environment]::NewLine
            $joined | Should -Match "WAIT_POLICY_USED=48051"
            $joined | Should -Match "WAIT_CALLED=True"
            $joined | Should -Not -Match "WARN_POLICY_USED"
        } finally {
            [Environment]::SetEnvironmentVariable("VANESSA_TEST_FOREIGN_WAIT_MODE", $oldWaitMode, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "matches own Vanessa TESTCLIENT without matching another worktree" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-process-match-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $ibPath = Join-Path $tempRoot ".agent-1c\infobases\dev-branches\current-branch"
                $state = [pscustomobject]@{
                    devBranchName = "Current Branch"
                    safeDevBranchName = "current-branch"
                    devBranch = "itldev/current-branch"
                    devBranchInfoBasePath = $ibPath
                    worktreePath = $tempRoot
                }
                $own = [pscustomobject]@{
                    processId = 1001
                    name = "1cv8c.exe"
                    commandLine = "1cv8c.exe /TESTCLIENT -TPort 48051 /F `"$ibPath`""
                    workingSetMb = 10
                }
                $foreign = [pscustomobject]@{
                    processId = 1002
                    name = "1cv8c.exe"
                    commandLine = "1cv8c.exe /TESTCLIENT -TPort 48052 /F `"D:\worktrees\branch1\.agent-1c\infobases\dev-branches\branch1`""
                    workingSetMb = 10
                }

                (Test-OneCVanessaTestProcess -ProcessInfo $own) | Should -Be $true
                (Test-OneCProcessBelongsToState -ProcessInfo $own -State $state -TestPort 48051 -RequireTestPort) | Should -Be $true
                (Test-OneCProcessBelongsToState -ProcessInfo $foreign -State $state -TestPort 48051 -RequireTestPort) | Should -Be $false
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "refuses to start Vanessa MCP outside an itldev worktree" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibecoding1c-mcp-master-test-" + [guid]::NewGuid().ToString("N"))
        $stdoutPath = Join-Path $tempRoot "stdout.log"
        $stderrPath = Join-Path $tempRoot "stderr.log"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Value ".dev.env`n" -Encoding ASCII
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore
            & git -C $tempRoot commit -m init *> $null
            & git -C $tempRoot branch -M master

            $process = Start-Process -FilePath "powershell" -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", $HelperPath,
                "-ProjectRoot", $tempRoot,
                "-Action", "start-vanessa-mcp"
            ) -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -NoNewWindow -Wait -PassThru
            $process.ExitCode | Should -Be 1
            $output = @(
                if (Test-Path -LiteralPath $stdoutPath) { Get-Content -Encoding UTF8 -Raw $stdoutPath }
                if (Test-Path -LiteralPath $stderrPath) { Get-Content -Encoding UTF8 -Raw $stderrPath }
            ) -join [Environment]::NewLine
            $output | Should -Match "active itldev/\* development branch worktree"
            $output | Should -Match "Current branch: master"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "closes the monitored window on failure unless debug keep-open is explicit" {
        $LauncherText | Should -Match '\$KeepWindowOnFailure\s*=\s*\$false'
        $LauncherText | Should -Match '"-keepwindowonfailure"'
        $LauncherText | Should -Match 'if \(\$KeepWindowOnFailure\)'
        $LauncherText | Should -Match '"-PauseOnFailure"'

        $defaultArgsMatch = [regex]::Match($LauncherText, '(?s)\$monitoredArgs\s*=\s*@\((?<args>.*?)\)\s*\+\s*@\(\$AgentArgs\)')
        $defaultArgsMatch.Success | Should -Be $true
        $defaultArgsMatch.Groups["args"].Value | Should -Not -Match "PauseOnFailure"
    }

    It "suppresses PowerShell progress output in helper entrypoints" {
        $HelperText | Should -Match '\$ProgressPreference\s*=\s*"SilentlyContinue"'
        $LauncherText | Should -Match '\$ProgressPreference\s*=\s*"SilentlyContinue"'
    }

    It "documents init launcher timeout and preflight guardrails" {
        $docPaths = @(
            "AGENT-INSTALL.md",
            ".agents\skills\1c-workflow\SKILL.md",
            ".agents\skills\1c-workflow\references\workflow.md",
            ".kilo\commands\itl-init-project.md"
        ) | ForEach-Object { Join-Path $RepoRoot $_ }

        foreach ($path in $docPaths) {
            $text = Get-Content -Encoding UTF8 -Raw $path
            $text | Should -Match "Test-Path"
            $text | Should -Match "CLIXML"
            $text | Should -Match "positive long timeout"
            $text | Should -Match "timeout: 0"
        }

        $combinedText = ($docPaths | ForEach-Object { Get-Content -Encoding UTF8 -Raw $_ }) -join [Environment]::NewLine
        $combinedText | Should -Match "launcher validates the helper path"
        $combinedText | Should -Not -Match "(?i)(use|set)\s+`?timeout:\s*0"
    }

    It "keeps helper path validation inside the monitored launcher" {
        $LauncherText | Should -Match "Helper script was not found"
        $LauncherText | Should -Match ([regex]::Escape('Test-Path -LiteralPath $helperFull'))
    }

    It "warns clearly when source repository sync is disabled" {
        $HelperText | Should -Match "WARNING: no repository update was performed; master dump uses current source infobase state"
    }

    It "warns when the interactive init wizard is run without monitoring" {
        $HelperText | Should -Match "direct init-project wizard is not monitored"
        $HelperText | Should -Match "scripts/run-agent-1c-window.ps1"
        $HelperText | Should -Match "Use the direct wizard only for manual debugging"
    }

    It "writes run status on successful helper completion" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-status-success-" + [guid]::NewGuid().ToString("N"))
        $statusPath = Join-Path $tempRoot "status.json"
        $logPath = Join-Path $tempRoot "console.log"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action help -RunStatusPath $statusPath -RunLogPath $logPath *> $null
            $LASTEXITCODE | Should -Be 0

            (Test-Path -LiteralPath $statusPath -PathType Leaf) | Should -Be $true
            $status = Get-Content -Encoding UTF8 -Raw $statusPath | ConvertFrom-Json
            $status.status | Should -Be "succeeded"
            $status.action | Should -Be "help"
            $status.projectRoot | Should -Be ([System.IO.Path]::GetFullPath($tempRoot))
            [int]$status.exitCode | Should -Be 0
            $status.runLogPath | Should -Be ([System.IO.Path]::GetFullPath($logPath))
            $status.errorMessage | Should -Be ""
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "writes run status on failed helper completion" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-status-failure-" + [guid]::NewGuid().ToString("N"))
        $statusPath = Join-Path $tempRoot "status.json"
        $logPath = Join-Path $tempRoot "console.log"
        $stdoutPath = Join-Path $tempRoot "stdout.log"
        $stderrPath = Join-Path $tempRoot "stderr.log"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $process = Start-Process -FilePath "powershell" -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", $HelperPath,
                "-ProjectRoot", $tempRoot,
                "-Action", "validate",
                "-RunStatusPath", $statusPath,
                "-RunLogPath", $logPath
            ) -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -NoNewWindow -Wait -PassThru
            $process.ExitCode | Should -Be 1

            (Test-Path -LiteralPath $statusPath -PathType Leaf) | Should -Be $true
            $status = Get-Content -Encoding UTF8 -Raw $statusPath | ConvertFrom-Json
            $status.status | Should -Be "failed"
            $status.action | Should -Be "validate"
            $status.projectRoot | Should -Be ([System.IO.Path]::GetFullPath($tempRoot))
            [int]$status.exitCode | Should -Be 1
            $status.runLogPath | Should -Be ([System.IO.Path]::GetFullPath($logPath))
            $status.errorMessage | Should -Not -BeNullOrEmpty
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "commits LF files when Git emits CRLF warnings under monitored logging" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-git-crlf-warning-" + [guid]::NewGuid().ToString("N"))
        $probePath = Join-Path $tempRoot "probe.ps1"
        $launcherPath = Join-Path $tempRoot "launcher.ps1"
        $logPath = Join-Path $tempRoot "console.log"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot config core.autocrlf true
            & git -C $tempRoot config core.safecrlf warn
            Set-Content -LiteralPath (Join-Path $tempRoot "lf.txt") -NoNewline -Value "line1`nline2`n" -Encoding ASCII

            Set-Content -LiteralPath $probePath -Encoding UTF8 -Value @'
param(
    [string]$HelperPath,
    [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. $HelperPath -ProjectRoot $ProjectRoot -Action help *> $null
Commit-IfChanged -Message "test: commit lf file" -PathSpec @("lf.txt") -RequireChanges | Out-Null

if (-not (Test-GitCommitExists "HEAD")) {
    throw "HEAD commit was not created."
}

$staged = & git -C $ProjectRoot diff --cached --name-only
if ($LASTEXITCODE -ne 0) {
    throw "Cannot read staged Git changes."
}
if ($staged) {
    throw "Staged changes remain: $($staged -join ', ')"
}
'@

            Set-Content -LiteralPath $launcherPath -Encoding UTF8 -Value @"
`$ErrorActionPreference = "Stop"
& '$probePath' '$HelperPath' '$tempRoot' *>&1 | Tee-Object -FilePath '$logPath'
if (`$LASTEXITCODE -is [int]) { exit `$LASTEXITCODE }
if (`$?) { exit 0 } else { exit 1 }
"@

            & powershell -NoProfile -ExecutionPolicy Bypass -File $launcherPath *> $null
            $LASTEXITCODE | Should -Be 0

            ((& git -C $tempRoot rev-list --count HEAD).Trim()) | Should -Be "1"
            ((& git -C $tempRoot diff --cached --name-only) -join [Environment]::NewLine) | Should -Be ""
            $logText = Get-Content -Encoding UTF8 -Raw $logPath
            $logText | Should -Match "LF will be replaced by CRLF"
            $logText | Should -Not -Match "NativeCommandError"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "still fails when Git returns a non-zero exit code" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-git-real-failure-" + [guid]::NewGuid().ToString("N"))
        $probePath = Join-Path $tempRoot "probe.ps1"
        $launcherPath = Join-Path $tempRoot "launcher.ps1"
        $logPath = Join-Path $tempRoot "console.log"
        $stdoutPath = Join-Path $tempRoot "stdout.log"
        $stderrPath = Join-Path $tempRoot "stderr.log"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath $probePath -Encoding UTF8 -Value @'
param(
    [string]$HelperPath,
    [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. $HelperPath -ProjectRoot $ProjectRoot -Action help *> $null
Invoke-Git @("not-a-git-command")
Write-Host "SHOULD_NOT_REACH_AFTER_GIT_FAILURE"
'@

            Set-Content -LiteralPath $launcherPath -Encoding UTF8 -Value @"
`$ErrorActionPreference = "Stop"
& '$probePath' '$HelperPath' '$tempRoot' *>&1 | Tee-Object -FilePath '$logPath'
if (`$LASTEXITCODE -is [int]) { exit `$LASTEXITCODE }
if (`$?) { exit 0 } else { exit 1 }
"@

            $process = Start-Process -FilePath "powershell" -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", $launcherPath
            ) -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -NoNewWindow -Wait -PassThru
            $process.ExitCode | Should -Be 1

            $logText = Get-Content -Encoding UTF8 -Raw $logPath
            $logText | Should -Match "not-a-git-command"
            $logText | Should -Not -Match "SHOULD_NOT_REACH_AFTER_GIT_FAILURE"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "wires result manifest creation into result and close actions" {
        $HelperText | Should -Match "function New-ResultManifest"
        $HelperText | Should -Match "\.manifest\.json"
        $HelperText | Should -Match "lastResultManifestPath"
        $HelperText | Should -Match "finalResultManifestPath"
        $HelperText | Should -Match "Get-FileHash -Algorithm SHA256"
    }

    It "wires dependency lock mode and verification policy" {
        $projectTemplate = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\project.json")
        $devEnvTemplate = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")
        $lockTemplatePath = Join-Path $RepoRoot "templates\dependency-lock.json"
        $lockTemplate = Get-Content -Encoding UTF8 -Raw $lockTemplatePath | ConvertFrom-Json

        $projectTemplate | Should -Match '"dependencyMode"\s*:\s*"fresh"'
        $projectTemplate | Should -Match '"verificationPolicy"\s*:\s*"warn"'
        $devEnvTemplate | Should -Match "DEPENDENCY_MODE=fresh"
        $devEnvTemplate | Should -Match "VERIFICATION_POLICY=warn"
        $lockTemplate.mode | Should -Be "fresh"
        $lockTemplate.dependencies.aiRules1c.repo | Should -Match "ai_rules_1c"
        $lockTemplate.dependencies.vanessaAutomation.PSObject.Properties.Name | Should -Contain "sha256"
        $lockTemplate.dependencies.apache.PSObject.Properties.Name | Should -Contain "sha256"

        $HelperText | Should -Match "function Get-DependencyMode"
        $HelperText | Should -Match "function Update-DependencyLockEntry"
        $HelperText | Should -Match "function Get-VerificationPolicy"
        $HelperText | Should -Match "verificationPolicy=block"
        $HelperText | Should -Match "Dependency mode is locked"
    }

    It "declares worktree branch parameters, state fields, and Russian open guidance" {
        $HelperText | Should -Match '\[string\]\$DevBranchWorktreePath'
        $HelperText | Should -Match '\[switch\]\$UseCurrentWorktree'
        $HelperText | Should -Match '\[switch\]\$OfferOpenAgent'
        $HelperText | Should -Match "createdWithWorktree"
        $HelperText | Should -Match "worktreePath"
        $HelperText | Should -Match "mainWorktreePath"
        $createdMessage = -join ([char[]](0x0412, 0x0435, 0x0442, 0x043A, 0x0430, 0x0020, 0x0440, 0x0430, 0x0437, 0x0440, 0x0430, 0x0431, 0x043E, 0x0442, 0x043A, 0x0438, 0x0020, 0x0441, 0x043E, 0x0437, 0x0434, 0x0430, 0x043D, 0x0430))
        $worktreeMessage = -join ([char[]](0x0420, 0x0430, 0x0431, 0x043E, 0x0447, 0x0430, 0x044F, 0x0020, 0x043F, 0x0430, 0x043F, 0x043A, 0x0430, 0x0020, 0x043D, 0x043E, 0x0432, 0x043E, 0x0439, 0x0020, 0x0432, 0x0435, 0x0442, 0x043A, 0x0438))
        $HelperText | Should -Match ([regex]::Escape($createdMessage))
        $HelperText | Should -Match ([regex]::Escape($worktreeMessage))
    }

    It "documents and templates the development branch worktree root" {
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\project.json")) | Should -Match "devBranchWorktreeRoot"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "DEV_BRANCH_WORKTREE_ROOT"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "README.md")) | Should -Match "worktree"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "DEVELOPER-GUIDE.ru.md")) | Should -Match "-UseCurrentWorktree"
    }

    It "creates a sibling worktree branch by default without switching the main folder" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-worktree-test-" + [guid]::NewGuid().ToString("N"))
        $worktreeRoot = "$tempRoot-worktrees"
        $worktreePath = Join-Path $worktreeRoot "fixture-branch"
        $sourceBase = Join-Path $tempRoot "source-base"
        $oldAppData = $env:APPDATA

        try {
            New-Item -ItemType Directory -Force -Path $sourceBase | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8.1CD") -Value "stub" -Encoding ASCII
            New-Item -ItemType Directory -Force -Path (Join-Path $sourceBase "1Cv8Log") | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8Log\1Cv8.lgf") -Value "" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Value ".dev.env`nsource-base/`n" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot "README.md") -Value "fixture" -Encoding ASCII
            $devEnv = @(
                "INFOBASE_KIND=file",
                "SOURCE_USES_REPOSITORY=false",
                "SOURCE_INFOBASE_PATH=$sourceBase",
                "IB_USER=",
                "IB_PASSWORD=",
                "WEB_PUBLISH_BY_DEFAULT=false"
            ) -join [Environment]::NewLine
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Value $devEnv -Encoding UTF8

            & git -C $tempRoot init | Out-Null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore README.md
            & git -C $tempRoot commit -m init | Out-Null
            & git -C $tempRoot branch -M master

            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Value "{}" -Encoding ASCII

            $env:APPDATA = Join-Path $tempRoot "appdata"
            & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action new-dev-branch -DevBranchName "Fixture Branch" *> $null
            $LASTEXITCODE | Should -Be 0

            ((& git -C $tempRoot branch --show-current).Trim()) | Should -Be "master"
            (Test-Path -LiteralPath $worktreePath -PathType Container) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $worktreePath ".dev.env") -PathType Leaf) | Should -Be $true
            (Get-Content -Encoding UTF8 -Raw (Join-Path $worktreePath ".dev.env")) | Should -Match ([regex]::Escape("SOURCE_INFOBASE_PATH=$sourceBase"))
            $statePath = Join-Path $worktreePath ".agent-1c\dev-branches\fixture-branch.json"
            (Test-Path -LiteralPath $statePath -PathType Leaf) | Should -Be $true
            $state = Get-Content -Encoding UTF8 -Raw $statePath | ConvertFrom-Json
            ([bool]$state.createdWithWorktree) | Should -Be $true
            $state.worktreePath | Should -Be ([System.IO.Path]::GetFullPath($worktreePath))
            $state.mainWorktreePath | Should -Be ([System.IO.Path]::GetFullPath($tempRoot))
            $expectedLauncherFolder = "/ITL/" + (Split-Path -Leaf $tempRoot)
            $state.launcherInfoBaseName | Should -Be "Fixture Branch"
            $state.launcherFolder | Should -Be $expectedLauncherFolder
            $launcherText = Get-Content -Encoding UTF8 -Raw (Join-Path $env:APPDATA "1C\1CEStart\ibases.v8i")
            $launcherText | Should -Match "(?m)^\[Fixture Branch\]\r?$"
            $launcherText | Should -Match ("(?m)^Folder={0}\r?$" -f [regex]::Escape($expectedLauncherFolder))
            $launcherText | Should -Not -Match "(?m)^Folder=/ITL/fixture-branch\r?$"

            $statusOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action status 2>&1
            $LASTEXITCODE | Should -Be 0
            ($statusOutput -join [Environment]::NewLine) | Should -Match "Active development worktrees: 1"

            $listOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action list-dev-branches 2>&1
            $LASTEXITCODE | Should -Be 0
            ($listOutput -join [Environment]::NewLine) | Should -Match ([regex]::Escape([System.IO.Path]::GetFullPath($worktreePath)))

            $switchOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action switch-dev-branch -DevBranchName "Fixture Branch" 2>&1
            $LASTEXITCODE | Should -Be 0
            ($switchOutput -join [Environment]::NewLine) | Should -Match ([regex]::Escape([System.IO.Path]::GetFullPath($worktreePath)))
            ((& git -C $tempRoot branch --show-current).Trim()) | Should -Be "master"
        } finally {
            $env:APPDATA = $oldAppData
            if (Test-Path -LiteralPath $worktreePath -PathType Container -ErrorAction SilentlyContinue) {
                & git -C $tempRoot worktree remove --force $worktreePath *> $null
            }
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $worktreeRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $worktreeRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "keeps the legacy checkout mode when UseCurrentWorktree is explicit" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-legacy-branch-test-" + [guid]::NewGuid().ToString("N"))
        $sourceBase = Join-Path $tempRoot "source-base"
        $oldAppData = $env:APPDATA

        try {
            New-Item -ItemType Directory -Force -Path $sourceBase | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8.1CD") -Value "stub" -Encoding ASCII
            New-Item -ItemType Directory -Force -Path (Join-Path $sourceBase "1Cv8Log") | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8Log\1Cv8.lgf") -Value "" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Value ".dev.env`nsource-base/`n" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot "README.md") -Value "fixture" -Encoding ASCII
            $devEnv = @(
                "INFOBASE_KIND=file",
                "SOURCE_USES_REPOSITORY=false",
                "SOURCE_INFOBASE_PATH=$sourceBase",
                "IB_USER=",
                "IB_PASSWORD=",
                "WEB_PUBLISH_BY_DEFAULT=false"
            ) -join [Environment]::NewLine
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Value $devEnv -Encoding UTF8

            & git -C $tempRoot init | Out-Null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore README.md
            & git -C $tempRoot commit -m init | Out-Null
            & git -C $tempRoot branch -M master

            $env:APPDATA = Join-Path $tempRoot "appdata"
            & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action new-dev-branch -DevBranchName "Legacy Branch" -UseCurrentWorktree *> $null
            $LASTEXITCODE | Should -Be 0

            ((& git -C $tempRoot branch --show-current).Trim()) | Should -Be "itldev/legacy-branch"
            $legacyWorktreeRoot = Join-Path (Split-Path -Parent $tempRoot) ((Split-Path -Leaf $tempRoot) + "-worktrees")
            (Test-Path -LiteralPath $legacyWorktreeRoot -PathType Container -ErrorAction SilentlyContinue) | Should -Be $false
            $statePath = Join-Path $tempRoot ".agent-1c\dev-branches\legacy-branch.json"
            (Test-Path -LiteralPath $statePath -PathType Leaf) | Should -Be $true
            $state = Get-Content -Encoding UTF8 -Raw $statePath | ConvertFrom-Json
            ([bool]$state.createdWithWorktree) | Should -Be $false
            $state.worktreePath | Should -Be ([System.IO.Path]::GetFullPath($tempRoot))
            $state.mainWorktreePath | Should -Be ([System.IO.Path]::GetFullPath($tempRoot))
        } finally {
            $env:APPDATA = $oldAppData
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
