Describe "1C workflow bootstrap and update checks" {
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
        $ResumeFakeHelperText = @'
param(
    [string]$ProjectRoot,
    [string]$RunStatusPath,
    [string]$RunLogPath,
    [string]$Action,
    [string]$InitMode,
    [string]$ResumeRunStatusPath,
    [string]$RecoveryReason,
    [int]$LauncherPid
)
$utf8 = New-Object System.Text.UTF8Encoding $false
$now = Get-Date
$capture = [ordered]@{
    initMode = $InitMode
    resumeRunStatusPath = $ResumeRunStatusPath
    recoveryReason = $RecoveryReason
    launcherPid = $LauncherPid
}
[System.IO.File]::WriteAllText((Join-Path $ProjectRoot "resume-capture.json"), (($capture | ConvertTo-Json) + [Environment]::NewLine), $utf8)
$status = [ordered]@{
    schemaVersion = 1
    status = "succeeded"
    action = $Action
    projectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
    pid = $PID
    launcherPid = $LauncherPid
    startedAt = $now.AddSeconds(-1).ToString("o")
    updatedAt = $now.ToString("o")
    finishedAt = $now.ToString("o")
    exitCode = 0
    lastLogPath = ""
    runLogPath = $RunLogPath
    errorMessage = ""
    stage = "init.complete"
    stageDetail = "Initialization completed"
    lastProcessId = 0
    lastProcessTimedOut = $false
    gitIndexLockPreExisted = $false
    resumedFrom = $ResumeRunStatusPath
    recoveryReason = $RecoveryReason
}
[System.IO.File]::WriteAllText($RunStatusPath, (($status | ConvertTo-Json -Depth 6) + [Environment]::NewLine), $utf8)
exit 0
'@
    }
    It "keeps initialization on the monitored helper wizard path" {
        $text = (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "AGENT-INSTALL.md")) + [Environment]::NewLine + (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\SKILL.md"))
        $text | Should -Match "install-agent-1c-workflow\.ps1"
        $text | Should -Match "one-step bootstrap"
        $text | Should -Match ([regex]::Escape(".\.agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1"))
        $text | Should -Match "-Action\s+init-project"
        $text | Should -Match "-InitMode\s+wizard"
        $text | Should -Match ([regex]::Escape(".agent-1c/runs/<run>/status.json"))
        $text | Should -Match "do not collect the (initialization )?questionnaire in chat"
        $HelperText | Should -Match 'ValidateSet\("configured", "wizard", "json", "resume"\)'
        $HelperText | Should -Match "ResumeRunStatusPath"
        $LauncherText | Should -Match 'Get-AgentAction\) -ne "init-project"'
    }

    It "documents the one-step bootstrap as the normal install path" {
        $installText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "AGENT-INSTALL.md")
        $installText | Should -Match ([regex]::Escape("install-agent-1c-workflow.ps1 -ProjectRoot <project>"))
        $installText | Should -Match "Do not expand the normal bootstrap into manual copy commands"
        $installText | Should -Match "## Manual Recovery Copy Steps"

        $normalInstallText = $installText.Substring(0, $installText.IndexOf("## Manual Recovery Copy Steps"))
        $normalInstallText | Should -Not -Match "Copy the common skills into the target project"
        $normalInstallText | Should -Not -Match ([regex]::Escape('Create `.agent-1c/project.json`'))

        foreach ($relativePath in @(
            ".agents\skills\1c-workflow\SKILL.md",
            ".agents\skills\1c-workflow\references\workflow.md",
            ".agents\skills\1c-workflow\references\init-setup.md"
        )) {
            $text = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot $relativePath)
            $text | Should -Match "install-agent-1c-workflow\.ps1"
            $text | Should -Match "manual copy"
        }
    }

    It "keeps Apache install out of helper API and auto-installs Vanessa during init" {
        $HelperText | Should -Not -Match "InstallApacheIfMissing"
        $HelperText | Should -Not -Match "install-apache"
        $HelperText | Should -Match ([regex]::Escape('$InstallVanessaIfMissing'))
        $HelperText | Should -Match "Prepare-ConfiguredInitProjectSettings"
        $HelperText | Should -Match "New-ConfiguredInitAnswers"
        $HelperText | Should -Match "InstallVanessaIfMissing"
        $HelperText | Should -Match "installing it automatically"
        $HelperText | Should -Not -Match "rerun init-project with -InitMode configured -InstallVanessaIfMissing"
        $HelperText | Should -Match "configure-web-publication"
        $HelperText | Should -Match "publish-dev-branch"

        $installText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "AGENT-INSTALL.md")
        $installText | Should -Match "Diagnostic Tool Checks"
        $installText | Should -Match ([regex]::Escape('should not be expanded into `check-tools`, separate install actions, and a second init run'))
        $installText | Should -Match "Vanessa Automation"
        $installText | Should -Not -Match "init-project -InitMode configured -InstallVanessaIfMissing"
        $installText | Should -Not -Match "InstallApacheIfMissing"
        $installText | Should -Not -Match "install-apache"
        $installText | Should -Match "WEB_PUBLISH_BY_DEFAULT=false"
        $installText | Should -Match "empty .*INFOBASE_PUBLISH_URL.* is expected"
    }

    It "documents monitored init as a foreground command, not a background direct wizard" {
        $docPaths = @(
            "AGENT-INSTALL.md",
            ".agents\skills\1c-workflow\SKILL.md",
            ".agents\skills\1c-workflow\references\workflow.md",
            "AGENT-INSTALL.md"
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
            (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "AGENT-INSTALL.md"))
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
            "/itl-update-rules",
            "/itl-vibecoding1c-mcp",
            "/itl-update-base",
            "/itl-close"
        )

        $kiloTemplateText = (Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates") -Recurse -File -Filter "itl*.md.template" | ForEach-Object { Get-Content -Encoding UTF8 -Raw $_.FullName }) -join [Environment]::NewLine
        foreach ($command in $advancedCommands) {
            $kiloTemplateText | Should -Not -Match ([regex]::Escape($command))
        }

        $readmeText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "README.md")
        $readmeText | Should -Not -Match "Slash-"
        foreach ($command in $advancedCommands) {
            $readmeText | Should -Not -Match ([regex]::Escape($command))
        }

        $installText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "AGENT-INSTALL.md")
        $installMenuMatch = [regex]::Match($installText, '(?s)In the `master` worktree, show only:(?<commands>.*?)Advanced/helper actions')
        $installMenuMatch.Success | Should -Be $true
        foreach ($command in $advancedCommands) {
            $installMenuMatch.Groups["commands"].Value | Should -Not -Match ([regex]::Escape($command))
        }

        $workflowText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\workflow.md")
        $shortSurfaceMatch = [regex]::Match($workflowText, "(?s)master:\s*(?<commands>.*?)Render ITL commands")
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

        $advancedText | Should -Match "set-dev-branch-extension"
        $advancedText | Should -Match "dump-dev-branch-extension"
        $advancedText | Should -Match "install-vanessa-mcp"
        $advancedText | Should -Not -Match ([regex]::Escape("/itl-set-dev-branch-extension"))
        $advancedText | Should -Not -Match ([regex]::Escape("/itl-dump-dev-branch-extension"))
        $advancedText | Should -Not -Match ([regex]::Escape("/itl-vanessa-mcp"))
        $advancedText | Should -Match "beginner"
    }

    It "forbids manual init questionnaire fallback when terminal input is unavailable" {
        $docTexts = @(
            (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "AGENT-INSTALL.md")),
            (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\SKILL.md")),
            (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\workflow.md"))
        )

        foreach ($text in $docTexts) {
            $text | Should -Match "terminal input is unavailable"
            $text | Should -Match "do not collect the (initialization )?questionnaire in chat"
            $text | Should -Match "do not continue the lifecycle manually"
        }

        ($docTexts -join [Environment]::NewLine) | Should -Not -Match "recovering from helper failure"
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
        $userRulesTemplateText | Should -Match ([regex]::Escape("/installmcp"))
        $userRulesTemplateText | Should -Match "ITL MCP helper requests"
        $userRulesTemplateText | Should -Match "product-docs/SKILL.md"
        $userRulesTemplateText | Should -Match "BookStack-product-docs-mcp"
        $userRulesTemplateText | Should -Match "before broad repository traversal"
        $userRulesTemplateText | Should -Match "OpenSpec explore/propose/apply surface"
        $userRulesTemplateText | Should -Match "activate required project skills"
        $userRulesTemplateText | Should -Match "code, tests, current 1C metadata"
        $userRulesTemplateText | Should -Match "available MCP evidence"
        $userRulesTemplateText | Should -Match "surface conflicts"
        $userRulesTemplateText | Should -Not -Match ([regex]::Escape("/itl-vibecoding1c-mcp"))

        $productDocsSkillPath = Join-Path $RepoRoot ".agents\skills\product-docs\SKILL.md"
        (Test-Path -LiteralPath $productDocsSkillPath -PathType Leaf) | Should -Be $true
        $productDocsSkillText = Get-Content -Encoding UTF8 -Raw $productDocsSkillPath
        $productDocsSkillText | Should -Match "BookStack-product-docs-mcp"
        $productDocsSkillText | Should -Match "before answering, researching, planning, proposing, applying, or changing"
        $productDocsSkillText | Should -Match "OpenSpec explore/propose/apply"
        $productDocsSkillText | Should -Match "baseConfigurationVersion"
        $productDocsSkillText | Should -Match "PM4"
        $productDocsSkillText | Should -Match "search_docs"
        $productDocsSkillText | Should -Match "read_page"
        $productDocsSkillText | Should -Match "limit=3"
        $productDocsSkillText | Should -Match "next_cursor"
        $productDocsSkillText | Should -Match "max_chars=0"
        $productDocsSkillText | Should -Match "source of product context and intended behavior"
        $productDocsSkillText | Should -Match "technical or implementation architecture"
        $productDocsSkillText | Should -Match "internal design of a subsystem"
        $productDocsSkillText | Should -Match "before a broad repository traversal"
        $productDocsSkillText | Should -Match ([regex]::Escape('как устроена архитектура редактора планов'))
        $productDocsSkillText | Should -Match "Explicitly describe documentation/implementation differences"
        $productDocsSkillText | Should -Not -Match "source of product behavior truth"
        $productDocsSkillText | Should -Match "## Evidence Policy"
        $productDocsSkillText | Should -Match "## Verification Workflow"
        $productDocsSkillText | Should -Match "current code, tests, 1C metadata"
        $productDocsSkillText | Should -Match "BookStack is advisory"
        $productDocsSkillText | Should -Match "1c-code-metadata-mcp"
        $productDocsSkillText | Should -Match "1C-docs-mcp"
        $productDocsSkillText | Should -Match "Code/MCP evidence"

        $productDocsOpenAiText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\product-docs\agents\openai.yaml")
        $productDocsOpenAiText | Should -Match "technical architecture through BookStack"
        $productDocsOpenAiText | Should -Match "verify it against code/MCP evidence"
        $productDocsOpenAiText | Should -Match "answering, researching, planning, proposing, applying"

        $HelperText | Should -Match "function Update-AgentGuidanceBridge"
        $HelperText | Should -Match "function Update-UserRules"
        $HelperText | Should -Match "## 1C Agent Workflow Bridge"
        $HelperText | Should -Match "Update-AgentGuidanceBridge"
        $HelperText | Should -Match "Update-UserRules"
        $HelperText | Should -Match ([regex]::Escape("templates\USER-RULES.append.md"))
        $HelperText | Should -Match "AGENTS\.md already references USER-RULES\.md"

        $installText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "AGENT-INSTALL.md")
        $installText | Should -Match ([regex]::Escape("<project>/templates/"))
        $installText | Should -Match "templates/USER-RULES.append.md"
        $installText | Should -Match "fallback"
        $installText | Should -Match "upstream-managed"
        $installText | Should -Match "AGENTS\.md"
        $installText | Should -Match "USER-RULES.md"
    }

    It "installs BookStack routing only for PM5 and keeps fresh/update overlay behavior identical" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-product-docs-routing-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "templates") | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\USER-RULES.append.md") -Destination (Join-Path $tempRoot "templates\USER-RULES.append.md")

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Test-ProductDocsMcpAllowed { return $false }
                Update-UserRules
                $pm4 = Get-Content -LiteralPath (Join-Path $tempRoot "USER-RULES.md") -Raw -Encoding UTF8

                function Test-ProductDocsMcpAllowed { return $true }
                Update-UserRules
                $pm5 = Get-Content -LiteralPath (Join-Path $tempRoot "USER-RULES.md") -Raw -Encoding UTF8
                [pscustomobject]@{ pm4 = $pm4; pm5 = $pm5 }
            }

            $result.pm4 | Should -Match "For PM4 projects"
            $result.pm4 | Should -Match "technical or implementation architecture"
            $result.pm4 | Should -Not -Match "BookStack-product-docs-mcp"
            $result.pm5 | Should -Match "BookStack-product-docs-mcp"
            $result.pm5 | Should -Match "OpenSpec explore/propose/apply surface"
            $result.pm5 | Should -Match "product-docs/SKILL.md"
            ([regex]::Matches($result.pm5, 'ITL-WORKFLOW-USER-RULES:START')).Count | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "wires ai_rules_1c update through the helper and advanced docs" {
        $HelperText | Should -Match ([regex]::Escape('"update-ai-rules"'))
        $HelperText | Should -Match "function Update-AiRules1c"
        $HelperText | Should -Match ([regex]::Escape('Invoke-AiRules1cInstaller -Command "update"'))
        $HelperText | Should -Match ([regex]::Escape('powershell -NoProfile -ExecutionPolicy Bypass -File $installScript @installArgs'))
        $HelperText | Should -Match ([regex]::Escape('$effectiveCommand,'))
        $HelperText | Should -Match ([regex]::Escape('"-Force"'))
        $HelperText | Should -Match "Invoke-AiRules1cInstaller -Command `"update`""
        $HelperText | Should -Match "function Remove-AiRules1cManagedMcpConfig"
        $HelperText | Should -Match "function Invoke-AiRules1cManagedMcpConfigReconcile"
        $HelperText | Should -Match ([regex]::Escape('Invoke-AiRules1cManagedMcpConfigReconcile -Operation "ai_rules_1c $effectiveCommand"'))
        $HelperText | Should -Match "function Get-AiRules1cManagedMcpServerIds"
        $HelperText | Should -Match "1c-code-metadata-mcp"
        $HelperText | Should -Match "1C-docs-mcp"
        $HelperText | Should -Match "1c-data-mcp"

        (Test-Path -LiteralPath (Join-Path $RepoRoot ".kilo\commands\itl-update-rules.md") -PathType Leaf) | Should -Be $false
        $kiloTemplateText = (Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates") -Recurse -File -Filter "itl*.md.template" | ForEach-Object { Get-Content -Encoding UTF8 -Raw $_.FullName }) -join [Environment]::NewLine
        $kiloTemplateText | Should -Not -Match "update-ai-rules"

        $advancedText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\advanced-actions.md")
        $workflowText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\workflow.md")
        foreach ($text in @($advancedText, $workflowText)) {
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
            New-Item -ItemType Directory -Force -Path $projectRoot, $rulesRoot, (Join-Path $rulesRoot "adapters") | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $projectRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $projectRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            Set-Content -LiteralPath (Join-Path $projectRoot ".ai-rules.json") -Encoding UTF8 -Value '{"schemaVersion":1,"tools":["codex"],"files":{}}'
            Set-Content -LiteralPath (Join-Path $rulesRoot "adapters\codex.yaml") -Encoding ASCII -Value "tool: codex"
            Set-Content -LiteralPath (Join-Path $rulesRoot "adapters\kilocode.yaml") -Encoding ASCII -Value "tool: kilocode"
            Set-Content -LiteralPath (Join-Path $rulesRoot "install.ps1") -Encoding UTF8 -Value @'
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command,
    [string]$ProjectRoot,
    [string]$Source,
    [ValidateSet("delegated")]
    [string]$McpMode,
    [switch]$AssumeYes,
    [switch]$Force
)

$optional = [pscustomobject]@{}
$null = $optional.userModified
Set-Content -LiteralPath (Join-Path $ProjectRoot "installer-ran.txt") -Encoding ASCII -Value "$Command|$ProjectRoot|$Source|$McpMode|$($AssumeYes.IsPresent)"
'@

            & {
                . $HelperPath -ProjectRoot (Join-Path $projectRoot ".") -Action help *> $null
                function Sync-AiRules1cCheckout {
                    return [pscustomobject]@{
                        root = (Join-Path $rulesRoot ".")
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
            $result.Trim() | Should -Be ("update|{0}|{1}|delegated|True" -f (Get-Item -LiteralPath $projectRoot).FullName, (Get-Item -LiteralPath $rulesRoot).FullName)
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "does not assign to local home variables that collide with PowerShell HOME" {
        $HelperText | Should -Not -Match '(?im)^\s*\$home\s*='
    }

    It "wires ITL workflow package update through the helper and advanced docs" {
        $HelperText | Should -Match ([regex]::Escape('"update-workflow"'))
        $HelperText | Should -Match "function Update-WorkflowPackage"
        $HelperText | Should -Match "ITL_WORKFLOW_SOURCE_PATH"
        $HelperText | Should -Match "workflowPackage"
        $HelperText | Should -Match "Update-WorkflowPackageLockEntry"
        $HelperText | Should -Match "Apply-BootstrapWorkflowPackageProvenance"
        $HelperText.IndexOf("Apply-BootstrapWorkflowPackageProvenance | Out-Null") | Should -BeLessThan $HelperText.IndexOf('Set-RunStage -Stage "init.check-tools"')
        $HelperText | Should -Match "Invoke-AiRulesBaselineMigration"
        $HelperText | Should -Match "migration remains pending"
        $HelperText | Should -Match "install-agent-1c-workflow\.ps1"
        $HelperText | Should -Match "Update-AgentGuidanceBridge"
        $HelperText | Should -Match "Update-UserRules"
        $HelperText | Should -Match "Assert-WorkflowPackageUpdateContext"
        $HelperText | Should -Match "Assert-WorkflowTrackedGitClean"
        $HelperText | Should -Match ([regex]::Escape("Kilo Code: run /reload or open a new session"))
        $HelperText | Should -Match ([regex]::Escape('Invoke-AiRules1cManagedMcpConfigReconcile -Operation "refresh-dev-branch MCP reconcile"'))
        $HelperText | Should -Match "updatedAt"
        $HelperText | Should -Match "Remove-LegacyWorkflowManagedFiles"
        $HelperText | Should -Match "docs\\itl-workflow"

        $lockTemplate = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dependency-lock.json") | ConvertFrom-Json
        $lockTemplate.dependencies.workflowPackage.repo | Should -Be "https://github.com/xmentosx/1c-agent-workflow.git"
        $lockTemplate.dependencies.workflowPackage.ref | Should -Be "master"
        $lockTemplate.dependencies.workflowPackage.commit | Should -Be ""
        $lockTemplate.dependencies.workflowPackage.source | Should -Be "template default"
        $lockTemplate.dependencies.workflowPackage.updatedAt | Should -Be ""
        $lockTemplate.dependencies.workflowPackage.PSObject.Properties.Name | Should -Contain "updatedAt"

        $installContractText = Get-Content -LiteralPath (Join-Path $RepoRoot "AGENT-INSTALL.md") -Raw -Encoding UTF8
        $initSetupContractText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\init-setup.md") -Raw -Encoding UTF8
        foreach ($text in @($installContractText, $initSetupContractText)) {
            $text | Should -Match "source checkout origin/ref/full commit"
            $text | Should -Match "non-Git source"
            $text | Should -Match "empty commit"
        }

        $kiloTemplateText = (Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates") -Recurse -File -Filter "itl*.md.template" | ForEach-Object { Get-Content -Encoding UTF8 -Raw $_.FullName }) -join [Environment]::NewLine
        $kiloTemplateText | Should -Match "update-workflow"
        $advancedText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\advanced-actions.md")
        $advancedText | Should -Match "update-workflow"
        $advancedText | Should -Match "active client's generated command surface"
        $advancedText | Should -Match "Generated client surfaces stay local and ignored"

        $docPaths = @(
            "AGENT-INSTALL.md",
            "docs\itl-workflow\PROJECT-WORKFLOW.ru.md",
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

        $workflowText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\workflow.md")
        $workflowText | Should -Match "references/vanessa-tests\.md"

        $vanessaGuideText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\vanessa-tests.md")
        $vanessaGuideText | Should -Match "Agent reference"
        $vanessaGuideText | Should -Match "Context Economy"
        $vanessaGuideText | Should -Match "Do Not"
        $vanessaGuideText | Should -Match "2-3"
        $vanessaGuideText | Should -Match "smoke"
        $vanessaGuideText | Should -Match "tests/features"
        $featureMarker = -join ([char[]](0x0424, 0x0443, 0x043D, 0x043A, 0x0446, 0x0438, 0x043E, 0x043D, 0x0430, 0x043B, 0x003A))
        $contextMarker = -join ([char[]](0x041A, 0x043E, 0x043D, 0x0442, 0x0435, 0x043A, 0x0441, 0x0442, 0x003A))
        $scenarioMarker = -join ([char[]](0x0421, 0x0446, 0x0435, 0x043D, 0x0430, 0x0440, 0x0438, 0x0439, 0x003A))
        foreach ($marker in @("#language: ru", $featureMarker, $contextMarker, $scenarioMarker)) {
            $vanessaGuideText | Should -Match ([regex]::Escape($marker))
        }
        [math]::Ceiling(([System.Text.Encoding]::UTF8.GetByteCount($vanessaGuideText)) / 4) | Should -BeLessOrEqual 2400

        (Test-Path -LiteralPath (Join-Path $RepoRoot "VANESSA-TESTS-GUIDE.md")) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $RepoRoot "VANESSA-TESTS-GUIDE.ru.md")) | Should -BeFalse
    }

    It "documents immutable configured ai_rules updates instead of moving upstream main" {
        $installText = Get-Content -LiteralPath (Join-Path $RepoRoot "AGENT-INSTALL.md") -Raw -Encoding UTF8
        $initSetupText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\init-setup.md") -Raw -Encoding UTF8
        $advancedText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\advanced-actions.md") -Raw -Encoding UTF8

        foreach ($text in @($installText, $initSetupText, $advancedText)) {
            $text | Should -Match "configured"
            $text | Should -Match "immutable"
            $text | Should -Match "controlled fork"
        }
        $installText | Should -Match 'fresh mode.*does not advance'
        $initSetupText | Should -Match 'both `fresh` and `locked` checkout that immutable tag'
        $initSetupText | Should -Match 'legacy/custom repository without `aiRules\.ref`'
        $installText | Should -Not -Match 'git clone https://github\.com/comol/ai_rules_1c\.git'
        $installText | Should -Not -Match 'git -C \$rulesDir pull --ff-only'
        $initSetupText | Should -Not -Match 'In `fresh`, checkout remote HEAD'
        $advancedText | Should -Not -Match 'refreshes upstream `ai_rules_1c`'
    }

    It "applies exact bootstrap workflow provenance without replacing other lock entries" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-bootstrap-provenance-" + [guid]::NewGuid().ToString("N"))
        $lockPath = Join-Path $tempRoot ".agent-1c\dependency-lock.json"
        $commit = "0123456789abcdef0123456789abcdef01234567"
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lockPath) | Out-Null
            Set-Content -LiteralPath $lockPath -Encoding UTF8 -Value '{"schemaVersion":1,"mode":"fresh","dependencies":{"workflowPackage":{"repo":"old","ref":"old","commit":"","source":"template default","updatedAt":""},"keepMe":{"value":"preserved"}}}'

            $applied = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help `
                    -BootstrapWorkflowRepo "https://example.invalid/itl-workflow.git" `
                    -BootstrapWorkflowRef "master" `
                    -BootstrapWorkflowCommit $commit `
                    -BootstrapWorkflowSource "path" *> $null
                Apply-BootstrapWorkflowPackageProvenance
            }

            $applied | Should -BeTrue
            $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $lock.dependencies.workflowPackage.repo | Should -Be "https://example.invalid/itl-workflow.git"
            $lock.dependencies.workflowPackage.ref | Should -Be "master"
            $lock.dependencies.workflowPackage.commit | Should -Be $commit
            $lock.dependencies.workflowPackage.source | Should -Be "path"
            $lock.dependencies.workflowPackage.updatedAt | Should -Not -BeNullOrEmpty
            $lock.dependencies.keepMe.value | Should -Be "preserved"

            $beforeRepeat = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8
            $repeatApplied = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help `
                    -BootstrapWorkflowRepo "https://example.invalid/itl-workflow.git" `
                    -BootstrapWorkflowRef "master" `
                    -BootstrapWorkflowCommit $commit `
                    -BootstrapWorkflowSource "path" *> $null
                Apply-BootstrapWorkflowPackageProvenance
            }
            $repeatApplied | Should -BeTrue
            (Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8) | Should -Be $beforeRepeat
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "does not invent or overwrite bootstrap provenance when no bootstrap arguments are supplied" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-bootstrap-provenance-none-" + [guid]::NewGuid().ToString("N"))
        $lockPath = Join-Path $tempRoot ".agent-1c\dependency-lock.json"
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lockPath) | Out-Null
            Set-Content -LiteralPath $lockPath -Encoding UTF8 -Value '{"schemaVersion":1,"mode":"fresh","dependencies":{"workflowPackage":{"repo":"existing","ref":"v1","commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source":"git","updatedAt":"old"}}}'
            $before = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8

            $applied = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Apply-BootstrapWorkflowPackageProvenance
            }

            $applied | Should -BeFalse
            (Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8) | Should -Be $before
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects invalid bootstrap provenance before initialization tool checks" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-bootstrap-provenance-invalid-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $errorText = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help `
                    -BootstrapWorkflowCommit "short-sha" `
                    -BootstrapWorkflowSource "path" *> $null
                try {
                    Apply-BootstrapWorkflowPackageProvenance | Out-Null
                    return ""
                } catch {
                    return $_.Exception.Message
                }
            }
            $errorText | Should -Match "full 40-character Git SHA"
            (Test-Path -LiteralPath (Join-Path $tempRoot ".agent-1c\dependency-lock.json") -PathType Leaf) | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
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
.agent-1c/client-surface.json
.codex/config.toml
.kilo/kilo.json
.kilo/kilo.jsonc
"@
            Set-Content -LiteralPath (Join-Path $projectRoot "README.md") -Encoding UTF8 -Value "old readme"
            Set-Content -LiteralPath (Join-Path $projectRoot "AGENT-INSTALL.md") -Encoding UTF8 -Value "old install"
            Set-Content -LiteralPath (Join-Path $projectRoot "AGENTS.md") -Encoding UTF8 -Value "# Installed project agents`r`n`r`nRead USER-RULES.md for project-specific instructions."
            $installedAgentsText = Get-Content -LiteralPath (Join-Path $projectRoot "AGENTS.md") -Raw -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $projectRoot "DEVELOPER-GUIDE.ru.md") -Encoding UTF8 -Value "old developer guide"
            Set-Content -LiteralPath (Join-Path $projectRoot "DEV-BRANCH-DEVELOPMENT.ru.md") -Encoding UTF8 -Value "old branch guide"
            Copy-Item -LiteralPath (Join-Path $RepoRoot "tests\fixtures\legacy-vanessa-guide-stub.md") -Destination (Join-Path $projectRoot "VANESSA-TESTS-GUIDE.ru.md")
            Set-Content -LiteralPath (Join-Path $projectRoot ".agents\skills\1c-workflow\stale.txt") -Encoding UTF8 -Value "stale"
            New-Item -ItemType Directory -Force -Path (Join-Path $projectRoot ".agents\skills\1c-workflow\kilo-command-templates\master") | Out-Null
            Set-Content -LiteralPath (Join-Path $projectRoot ".agents\skills\1c-workflow\kilo-command-templates\master\itl-stale.md") -Encoding UTF8 -Value "stale command-shaped template"
            Set-Content -LiteralPath (Join-Path $projectRoot ".agents\skills\1c-workflow-fast\stale.txt") -Encoding UTF8 -Value "stale"
            Set-Content -LiteralPath (Join-Path $projectRoot ".kilo\commands\itl-old.md") -Encoding UTF8 -Value "stale command"
            Set-Content -LiteralPath (Join-Path $projectRoot ".kilo\commands\custom.md") -Encoding UTF8 -Value "custom command"
            Set-Content -LiteralPath (Join-Path $projectRoot "templates\stale.txt") -Encoding UTF8 -Value "stale template"
            Set-Content -LiteralPath (Join-Path $projectRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"custom":"keep-project","aiRules":{"tools":["kilocode"]}}'
            Set-Content -LiteralPath (Join-Path $projectRoot ".ai-rules.json") -Encoding UTF8 -Value '{"tools":["kilocode"],"files":{}}'
            Set-Content -LiteralPath (Join-Path $projectRoot ".agent-1c\tools.json") -Encoding UTF8 -Value '{"custom":"keep-tools"}'
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Destination (Join-Path $projectRoot ".agent-1c\dependency-lock.json")
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
            $legacySurfaceHash = (Get-FileHash -LiteralPath (Join-Path $projectRoot ".kilo\commands\itl-old.md") -Algorithm SHA256).Hash.ToLowerInvariant()
            Set-Content -LiteralPath (Join-Path $projectRoot ".agent-1c\client-surface.json") -Encoding UTF8 -Value (@{
                schemaVersion = 1
                clients = @{ kilocode = @{ files = @{ ".kilo/commands/itl-old.md" = $legacySurfaceHash } } }
            } | ConvertTo-Json -Depth 8)
            $commitCountBefore = ((& git -C $projectRoot rev-list --count HEAD).Trim())

            $env:ITL_WORKFLOW_SOURCE_PATH = $RepoRoot
            $env:ITL_WORKFLOW_REPO = ""
            $env:ITL_WORKFLOW_REF = ""
            & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $projectRoot -Action update-workflow -SkipAiRules > $stdoutPath 2> $stderrPath
            $diagnostic = ((Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue) + [Environment]::NewLine + (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue))
            $LASTEXITCODE | Should -Be 0 -Because $diagnostic

            $stdout = Get-Content -Encoding UTF8 -Raw $stdoutPath
            $stdout | Should -Match "ITL workflow package post-copy processing completed"
            $stdout | Should -Match "No commit was created automatically"
            $stdout | Should -Match "No active development branches were found"
            $stdout | Should -Match "Removed obsolete workflow-managed file: VANESSA-TESTS-GUIDE.ru.md"
            $operationState = Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot ".agent-1c\locks\lifecycle-operation.json") | ConvertFrom-Json
            $operationState.action | Should -Be "update-workflow"
            $operationState.status | Should -Be "succeeded"
            $operationState.phase | Should -Be "complete"
            [int]$operationState.continuationPid | Should -BeGreaterThan 0

            (Test-Path -LiteralPath (Join-Path $projectRoot ".agents\skills\1c-workflow\SKILL.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $projectRoot ".agents\skills\1c-workflow\assets\vanessa-reference-suites.json") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $projectRoot "tests\features\Libraries\ITL\Core\NavigationLinks.feature") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $projectRoot "tests\features\Libraries\ITL\PM5\README.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $projectRoot "tests\features\Libraries\ITL\PM4") -ErrorAction SilentlyContinue) | Should -Be $false
            (Test-Path -LiteralPath (Join-Path $projectRoot ".agents\skills\1c-workflow\kilo-plugin\itl-completion-gate.js") -ErrorAction SilentlyContinue) | Should -Be $false
            (Test-Path -LiteralPath (Join-Path $projectRoot ".agents\skills\1c-workflow\stale.txt") -PathType Leaf) | Should -Be $false
            @(Get-ChildItem -LiteralPath (Join-Path $projectRoot ".agents\skills\1c-workflow\kilo-command-templates") -Recurse -File -Filter "itl*.md" -ErrorAction SilentlyContinue).Count | Should -Be 0
            (Test-Path -LiteralPath (Join-Path $projectRoot ".agents\skills\1c-workflow-fast\SKILL.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $projectRoot ".agents\skills\product-docs\SKILL.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $projectRoot ".agents\skills\itl-roctup-1c-data\SKILL.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $projectRoot ".agents\skills\itl-vanessa-ui-mcp\SKILL.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $projectRoot "install-agent-1c-workflow.ps1") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $projectRoot ".kilo\commands\itl.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $projectRoot ".kilo\commands\itl-status.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $projectRoot ".kilo\commands\itl-new-config-branch.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $projectRoot ".kilo\commands\itl-new-extension-branch.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $projectRoot ".kilo\commands\itl-update-workflow.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $projectRoot ".kilo\commands\itl-check.md") -PathType Leaf) | Should -Be $false
            (Test-Path -LiteralPath (Join-Path $projectRoot ".kilo\commands\itl-old.md") -PathType Leaf) | Should -Be $false
            (Test-Path -LiteralPath (Join-Path $projectRoot ".kilo\commands\custom.md") -PathType Leaf) | Should -Be $true
            (Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot ".gitignore")) | Should -Match ([regex]::Escape(".kilo/commands/itl*.md"))
            @(& git -C $projectRoot ls-files -- ".kilo/commands/itl*.md").Count | Should -Be 0
            @(& git -C $projectRoot ls-files -- ".kilo/commands/custom.md") | Should -Be @(".kilo/commands/custom.md")
            (Test-Path -LiteralPath (Join-Path $projectRoot "templates\dependency-lock.json") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $projectRoot "templates\stale.txt") -PathType Leaf) | Should -Be $false
            (Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot ".agents\skills\1c-workflow\references\vanessa-tests.md")) | Should -Match "Vanessa Automation"
            $featureMarker = -join ([char[]](0x0424, 0x0443, 0x043D, 0x043A, 0x0446, 0x0438, 0x043E, 0x043D, 0x0430, 0x043B, 0x003A))
            (Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot ".agents\skills\1c-workflow\references\vanessa-tests.md")) | Should -Match ([regex]::Escape($featureMarker))
            (Test-Path -LiteralPath (Join-Path $projectRoot "VANESSA-TESTS-GUIDE.md")) | Should -BeFalse
            (Test-Path -LiteralPath (Join-Path $projectRoot "VANESSA-TESTS-GUIDE.ru.md")) | Should -BeFalse
            (Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot "README.md")) | Should -Match "old readme"
            (Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot "DEVELOPER-GUIDE.ru.md")) | Should -Match "old developer guide"
            (Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot "DEV-BRANCH-DEVELOPMENT.ru.md")) | Should -Match "old branch guide"
            foreach ($name in @("PROJECT-WORKFLOW.ru.md", "FEATURE-DEVELOPMENT.ru.md", "MODES-AND-SETTINGS.ru.md", "DEV-ENV-REFERENCE.ru.md")) {
                (Test-Path -LiteralPath (Join-Path $projectRoot "docs\itl-workflow\$name") -PathType Leaf) | Should -BeTrue
            }
            (Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot "AGENTS.md")) | Should -Be $installedAgentsText

            (Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot ".dev.env")) | Should -Match "SECRET=keep"
            (Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot ".agent-1c\project.json")) | Should -Match "keep-project"
            (Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot ".agent-1c\tools.json")) | Should -Match "keep-tools"
            (Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot ".agent-1c\mcp\state.json")) | Should -Match "keep"
            (Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot ".codex\config.toml")) | Should -Match "custom"
            (Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot ".kilo\kilo.json")) | Should -Match "keep"
            $updatedKiloConfig = Get-Content -Encoding UTF8 -Raw (Join-Path $projectRoot ".kilo\kilo.json") | ConvertFrom-Json
            $updatedKiloConfig.PSObject.Properties.Name | Should -Not -Contain "plugin"
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

    It "installs bootstrap package files into a temp project without runtime state when NoInit is used" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-package-smoke-" + [guid]::NewGuid().ToString("N"))
        $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-package-smoke-stdout-" + [guid]::NewGuid().ToString("N") + ".log")
        $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-package-smoke-stderr-" + [guid]::NewGuid().ToString("N") + ".log")

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

            & powershell -NoProfile -ExecutionPolicy Bypass -File $InstallerPath -ProjectRoot $tempRoot -NoInit > $stdoutPath 2> $stderrPath
            $LASTEXITCODE | Should -Be 0
            (Get-Content -Encoding UTF8 -Raw $stdoutPath) | Should -Match "Initialization skipped because -NoInit was specified"

            (Test-Path -LiteralPath (Join-Path $tempRoot ".agents\skills\1c-workflow\SKILL.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $tempRoot ".agents\skills\1c-workflow-fast\SKILL.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $tempRoot ".agents\skills\product-docs\SKILL.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $tempRoot ".agents\skills\itl-roctup-1c-data\SKILL.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $tempRoot ".agents\skills\itl-vanessa-ui-mcp\SKILL.md") -PathType Leaf) | Should -Be $true
            $copiedRoctupSkill = Get-Content -LiteralPath (Join-Path $tempRoot ".agents\skills\itl-roctup-1c-data\SKILL.md") -Raw -Encoding UTF8
            $copiedRoctupSkill | Should -Match '(?m)^name:\s*itl-roctup-1c-data\s*$'
            $copiedRoctupSkill | Should -Match '(?m)^description:\s*\S.+'
            (Test-Path -LiteralPath (Join-Path $tempRoot ".agents\skills\1c-workflow\kilo-command-templates\common\itl.md.template") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $tempRoot ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-result.md.template") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $tempRoot ".agents\skills\1c-workflow\tools\event-log-exporter\EventLogExporter.xml") -PathType Leaf) | Should -Be $true
            @(Get-ChildItem -LiteralPath (Join-Path $tempRoot ".agents\skills\1c-workflow\tools\auto-update") -File -Filter "*.epf").Count | Should -Be 2
            (Test-Path -LiteralPath (Join-Path $tempRoot "templates\project.json") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $tempRoot "templates\tools.json") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $tempRoot "templates\dev.env.example") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $tempRoot "templates\gitignore.append") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $tempRoot "templates\USER-RULES.append.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $tempRoot "templates\AGENTS.append.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $tempRoot "install-agent-1c-workflow.ps1") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $tempRoot "AGENT-INSTALL.md") -PathType Leaf) | Should -Be $true
            (Test-Path -LiteralPath (Join-Path $tempRoot "README.md") -PathType Leaf) | Should -Be $false
            foreach ($name in @("PROJECT-WORKFLOW.ru.md", "FEATURE-DEVELOPMENT.ru.md", "MODES-AND-SETTINGS.ru.md", "DEV-ENV-REFERENCE.ru.md")) {
                (Test-Path -LiteralPath (Join-Path $tempRoot "docs\itl-workflow\$name") -PathType Leaf) | Should -BeTrue
            }
            (Test-Path -LiteralPath (Join-Path $tempRoot "docs\package-architecture.md")) | Should -BeFalse
            (Test-Path -LiteralPath (Join-Path $tempRoot "AGENTS.md") -PathType Leaf) | Should -Be $false
            (Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot "templates\AGENTS.append.md")) | Should -Match "USER-RULES.md"
            (Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot "templates\USER-RULES.append.md")) | Should -Match "1C Project Lifecycle"

            (Test-Path -LiteralPath (Join-Path $tempRoot ".agent-1c") -ErrorAction SilentlyContinue) | Should -Be $false
            (Test-Path -LiteralPath (Join-Path $tempRoot ".dev.env") -ErrorAction SilentlyContinue) | Should -Be $false
            (Test-Path -LiteralPath (Join-Path $tempRoot ".codex") -ErrorAction SilentlyContinue) | Should -Be $false
            (Test-Path -LiteralPath (Join-Path $tempRoot ".kilo") -ErrorAction SilentlyContinue) | Should -Be $false
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            foreach ($path in @($stdoutPath, $stderrPath)) {
                if (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue) {
                    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    It "preserves an existing project README during bootstrap" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-package-readme-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "README.md") -Encoding UTF8 -Value "# Project-owned documentation"

            & powershell -NoProfile -ExecutionPolicy Bypass -File $InstallerPath -ProjectRoot $tempRoot -NoInit *> $null
            $LASTEXITCODE | Should -Be 0
            (Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot "README.md")) | Should -Match "Project-owned documentation"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "passes branch tag detached and non-Git workflow provenance through the monitored launcher" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-bootstrap-source-provenance-" + [guid]::NewGuid().ToString("N"))
        $sourceRoot = Join-Path $tempRoot "source"
        $originUrl = "https://example.invalid/itl-workflow.git"

        function Invoke-ProvenanceBootstrapFixture {
            param([string]$TargetRoot)

            New-Item -ItemType Directory -Force -Path $TargetRoot | Out-Null
            & powershell -NoProfile -ExecutionPolicy Bypass -File $InstallerPath `
                -ProjectRoot $TargetRoot `
                -SourceRoot $sourceRoot `
                -InitMode configured `
                -InitMaxWaitSeconds 10 *> $null
            $LASTEXITCODE | Should -Be 0 | Out-Null
            return (Get-Content -LiteralPath (Join-Path $TargetRoot "bootstrap-args.json") -Raw -Encoding UTF8 | ConvertFrom-Json)
        }

        function Get-ProvenanceArgumentValue {
            param(
                [object[]]$Arguments,
                [string]$Name
            )

            $flatArguments = if ($Arguments.Count -eq 1 -and $Arguments[0] -is [array]) { @($Arguments[0]) } else { @($Arguments) }
            $index = [array]::IndexOf($flatArguments, $Name)
            $index | Should -BeGreaterOrEqual 0 -Because ("launcher args were: " + ($flatArguments -join " | "))
            return [string]$flatArguments[$index + 1]
        }

        try {
            New-Item -ItemType Directory -Force -Path $sourceRoot | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot ".agents") -Destination $sourceRoot -Recurse -Force
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates") -Destination $sourceRoot -Recurse -Force
            New-Item -ItemType Directory -Force -Path (Join-Path $sourceRoot "docs") | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot "docs\itl-workflow") -Destination (Join-Path $sourceRoot "docs\itl-workflow") -Recurse -Force
            foreach ($name in @("install-agent-1c-workflow.ps1", "AGENT-INSTALL.md")) {
                Copy-Item -LiteralPath (Join-Path $RepoRoot $name) -Destination (Join-Path $sourceRoot $name) -Force
            }
            $fakeLauncherPath = Join-Path $sourceRoot ".agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1"
            Set-Content -LiteralPath $fakeLauncherPath -Encoding UTF8 -Value @'
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText(
    (Join-Path (Get-Location).Path "bootstrap-args.json"),
    ((@($args) | ConvertTo-Json -Depth 3) + [Environment]::NewLine),
    $utf8
)
exit 0
'@

            & git -C $sourceRoot init *> $null
            & git -C $sourceRoot config user.email "test@example.invalid"
            & git -C $sourceRoot config user.name "ITL Test"
            & git -C $sourceRoot add .
            & git -C $sourceRoot commit -m "fixture" *> $null
            & git -C $sourceRoot branch -M master
            & git -C $sourceRoot remote add origin $originUrl
            $commit = (& git -C $sourceRoot rev-parse HEAD).Trim()

            $branchArgs = @(Invoke-ProvenanceBootstrapFixture -TargetRoot (Join-Path $tempRoot "branch-target"))
            (Get-ProvenanceArgumentValue -Arguments $branchArgs -Name "-BootstrapWorkflowRepo") | Should -Be $originUrl
            (Get-ProvenanceArgumentValue -Arguments $branchArgs -Name "-BootstrapWorkflowRef") | Should -Be "master"
            (Get-ProvenanceArgumentValue -Arguments $branchArgs -Name "-BootstrapWorkflowCommit") | Should -Be $commit
            (Get-ProvenanceArgumentValue -Arguments $branchArgs -Name "-BootstrapWorkflowSource") | Should -Be "path"

            & git -C $sourceRoot tag "workflow-v1"
            & git -C $sourceRoot checkout --detach --quiet HEAD 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 0
            $tagArgs = @(Invoke-ProvenanceBootstrapFixture -TargetRoot (Join-Path $tempRoot "tag-target"))
            (Get-ProvenanceArgumentValue -Arguments $tagArgs -Name "-BootstrapWorkflowRef") | Should -Be "workflow-v1"
            (Get-ProvenanceArgumentValue -Arguments $tagArgs -Name "-BootstrapWorkflowCommit") | Should -Be $commit

            & git -C $sourceRoot tag -d "workflow-v1" *> $null
            $detachedArgs = @(Invoke-ProvenanceBootstrapFixture -TargetRoot (Join-Path $tempRoot "detached-target"))
            (Get-ProvenanceArgumentValue -Arguments $detachedArgs -Name "-BootstrapWorkflowRef") | Should -Be $commit
            (Get-ProvenanceArgumentValue -Arguments $detachedArgs -Name "-BootstrapWorkflowCommit") | Should -Be $commit

            $sourceGitPath = Join-Path $sourceRoot ".git"
            $sourceGitPath.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
            Remove-Item -LiteralPath $sourceGitPath -Recurse -Force
            $nonGitArgs = @(Invoke-ProvenanceBootstrapFixture -TargetRoot (Join-Path $tempRoot "nongit-target"))
            $nonGitFlatArgs = if ($nonGitArgs.Count -eq 1 -and $nonGitArgs[0] -is [array]) { @($nonGitArgs[0]) } else { @($nonGitArgs) }
            $nonGitFlatArgs | Should -Not -Contain "-BootstrapWorkflowRepo"
            $nonGitFlatArgs | Should -Not -Contain "-BootstrapWorkflowRef"
            $nonGitFlatArgs | Should -Not -Contain "-BootstrapWorkflowCommit"
            (Get-ProvenanceArgumentValue -Arguments $nonGitArgs -Name "-BootstrapWorkflowSource") | Should -Be "path"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
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
            ".agents\skills\1c-workflow\references\workflow.md"
        ) | ForEach-Object { Join-Path $RepoRoot $_ }

        foreach ($path in $docPaths) {
            $text = Get-Content -Encoding UTF8 -Raw $path
            $text | Should -Match "Test-Path"
            $text | Should -Match "CLIXML"
            $text | Should -Match "positive long timeout"
            $text | Should -Match "timeout: 0"
            $text | Should -Match "timeout_ms\s*>=\s*3900000"
            $text | Should -Match "repeat the same"
        }

        $combinedText = ($docPaths | ForEach-Object { Get-Content -Encoding UTF8 -Raw $_ }) -join [Environment]::NewLine
        $combinedText | Should -Match "launcher validates the helper path"
        $combinedText | Should -Match "MaxWaitSeconds 3600"
        $combinedText | Should -Match "InitMaxWaitSeconds 3600"
        $combinedText | Should -Match "launcher\.orphaned|orphaned"
        $combinedText | Should -Match "Do not delete.*lock|Never delete.*lock"
        $combinedText | Should -Match "edit.*status"
        $combinedText | Should -Not -Match "(?i)(use|set)\s+`?timeout:\s*0"

        $sourceAgentsText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "AGENTS.md")
        $sourceAgentsText | Should -Match "timeout_ms\s*>=\s*3900000"
        $sourceAgentsText | Should -Match "repeat the same bootstrap command"
    }

    It "splits workflow update into pre-copy reexec and post-copy new-code processing" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-workflow-reexec-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $script:copyCalls = 0
                $script:postCalls = 0
                $script:reexecArgs = @()
                function Assert-WorkflowPackageUpdateContext {}
                function Resolve-WorkflowPackageSource { [pscustomobject]@{ root = "C:\source"; repo = "repo"; ref = "ref"; commit = "commit"; source = "path" } }
                function Assert-WorkflowSourceOutsideProject {}
                function Copy-WorkflowManagedDirectory { $script:copyCalls++ }
                function Copy-WorkflowManagedFile { $script:copyCalls++ }
                function Update-WorkflowPackageLockEntry {}
                function Invoke-Agent1cFreshProcess { param([string[]]$AdditionalArguments); $script:reexecArgs = $AdditionalArguments; throw "reexec-stop" }

                $LifecyclePhase = "pre-copy"
                $preError = ""
                try { Update-WorkflowPackage *> $null } catch { $preError = $_.Exception.Message }
                $preCopyCalls = $script:copyCalls

                function Assert-MasterWorktreeContext {}
                function Ensure-GitIgnore { $script:postCalls++ }
                function Update-AgentGuidanceBridge { $script:postCalls++ }
                function Update-UserRules { $script:postCalls++ }
                function Update-RoctupMcp { $script:postCalls++ }
                function Update-VanessaMcpArtifacts { $script:postCalls++ }
                function Invoke-AiRulesBaselineMigration { [pscustomobject]@{ migrated = $true; suppressRegularUpdate = $true } }
                function Write-WorkflowUpdateFollowUp { $script:postCalls++ }
                function Read-DependencyLockManifest { @{ dependencies = @{ workflowPackage = @{ source = "path"; commit = "commit" } } } }
                $LifecyclePhase = "post-copy"
                Update-WorkflowPackage *> $null

                [pscustomobject]@{
                    preError = $preError
                    preCopyCalls = $preCopyCalls
                    finalCopyCalls = $script:copyCalls
                    reexecArgs = @($script:reexecArgs)
                    postCalls = $script:postCalls
                }
            }
            $result.preError | Should -Be "reexec-stop"
            $result.preCopyCalls | Should -BeGreaterThan 5
            $result.finalCopyCalls | Should -Be $result.preCopyCalls
            $result.reexecArgs | Should -Be @("-LifecyclePhase", "post-copy")
            $result.postCalls | Should -BeGreaterThan 4
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "documents long external shell timeout for ITL lifecycle commands" {
        $instructionPaths = @(
            ".agents\skills\1c-workflow-fast\SKILL.md",
            ".agents\skills\1c-workflow\SKILL.md",
            "templates\USER-RULES.append.md"
        ) | ForEach-Object { Join-Path $RepoRoot $_ }

        foreach ($path in $instructionPaths) {
            $text = Get-Content -Encoding UTF8 -Raw $path
            $text | Should -Match "timeout_ms\s*>=\s*1800000"
            $text | Should -Match 'Do not use\s+`?120000 ms'
            $text | Should -Match "1C Designer/Enterprise"
            $text | Should -Match "LoadConfigFromFiles.*UpdateDBCfg"
            $text | Should -Match "status.*help.*do not|status`/help.*do not"
        }

        $longTemplatePaths = @(
            ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-check.md.template",
            ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-refresh.md.template",
            ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-result.md.template",
            ".agents\skills\1c-workflow\kilo-command-templates\master\itl-new-config-branch.md.template",
            ".agents\skills\1c-workflow\kilo-command-templates\master\itl-new-extension-branch.md.template",
            ".agents\skills\1c-workflow\kilo-command-templates\master\itl-update-workflow.md.template"
        ) | ForEach-Object { Join-Path $RepoRoot $_ }

        foreach ($path in $longTemplatePaths) {
            $text = Get-Content -Encoding UTF8 -Raw $path
            $text | Should -Match "agent shell tool supports"
            $text | Should -Match "timeout_ms\s*>=\s*1800000"
            $text | Should -Match 'do not use\s+`?120000 ms'
            $text | Should -Match "1C Designer/Enterprise"
        }

        $shortTemplatePaths = @(
            ".agents\skills\1c-workflow\kilo-command-templates\common\itl.md.template",
            ".agents\skills\1c-workflow\kilo-command-templates\common\itl-status.md.template"
        ) | ForEach-Object { Join-Path $RepoRoot $_ }

        foreach ($path in $shortTemplatePaths) {
            $text = Get-Content -Encoding UTF8 -Raw $path
            $text | Should -Not -Match "timeout_ms\s*>=\s*1800000"
        }

        $HelperText | Should -Match "Long lifecycle actions may run 1C Designer/Enterprise"
        $HelperText | Should -Match "agent shell timeout_ms must be >= 1800000"
    }

    It "keeps helper path validation inside the monitored launcher" {
        $LauncherText | Should -Match "Helper script was not found"
        $LauncherText | Should -Match ([regex]::Escape('Test-Path -LiteralPath $helperFull'))
        $LauncherText | Should -Match '\$MaxWaitSeconds\s*=\s*3600'
        (Get-Content -Encoding UTF8 -Raw $InstallerPath) | Should -Match '\$InitMaxWaitSeconds\s*=\s*3600'
    }

    It "warns clearly when source repository sync is disabled" {
        $HelperText | Should -Match "WARNING: no repository update was performed; master dump uses current source infobase state"
    }

    It "warns when the interactive init wizard is run without monitoring" {
        $HelperText | Should -Match "direct init-project wizard is not monitored"
        $HelperText | Should -Match "scripts/run-agent-1c-window.ps1"
        $HelperText | Should -Match "Use the direct wizard only for manual debugging"
    }

    It "uses Russian init wizard prompts and fixed init defaults" {
        $russianPromptBase64 = @(
            "0JjQvdC40YbQuNCw0LvQuNC30LjRgNC+0LLQsNGC0YwgMUMg0L/RgNC+0LXQutGCINCyINGN0YLQvtC5INC/0LDQv9C60LU/",
            "0JLRi9Cx0LXRgNC40YLQtSDQvdC+0LzQtdGAINC/0LvQsNGC0YTQvtGA0LzRiyDQuNC70Lgg0LLQstC10LTQuNGC0LUg0L/QvtC70L3Ri9C5INC/0YPRgtGMINC6IDFjdjguZXhl",
            "0J/QvtC70L3Ri9C5INC/0YPRgtGMINC6IDFjdjguZXhl",
            "0KLQuNC/INC40YHRhdC+0LTQvdC+0Lkg0LjQvdGE0L7RgNC80LDRhtC40L7QvdC90L7QuSDQsdCw0LfRizogZmlsZSDQuNC70Lggc2VydmVyIFtmaWxlXQ==",
            "0JjRgdGF0L7QtNC90LDRjyDQuNC90YTQvtGA0LzQsNGG0LjQvtC90L3QsNGPINCx0LDQt9CwINC/0L7QtNC60LvRjtGH0LXQvdCwINC6INGF0YDQsNC90LjQu9C40YnRgyDQutC+0L3RhNC40LPRg9GA0LDRhtC40LggMUM/",
            "0JjQvNGPINGB0LXRgNCy0LXRgNCwIDFD",
            "0JjQvNGPINC40YHRhdC+0LTQvdC+0Lkg0LjQvdGE0L7RgNC80LDRhtC40L7QvdC90L7QuSDQsdCw0LfRiw==",
            "0JrQsNGC0LDQu9C+0LMg0LjRgdGF0L7QtNC90L7QuSDRhNCw0LnQu9C+0LLQvtC5INC40L3RhNC+0YDQvNCw0YbQuNC+0L3QvdC+0Lkg0LHQsNC30Ys=",
            "0J/QvtC70YzQt9C+0LLQsNGC0LXQu9GMINC40L3RhNC+0YDQvNCw0YbQuNC+0L3QvdC+0Lkg0LHQsNC30YsgKNC/0YPRgdGC0L4sINC10YHQu9C4INC90LUg0LjRgdC/0L7Qu9GM0LfRg9C10YLRgdGPKQ==",
            "0J/QsNGA0L7Qu9GMINC40L3RhNC+0YDQvNCw0YbQuNC+0L3QvdC+0Lkg0LHQsNC30YsgKNC/0YPRgdGC0L4g0LjQu9C4ICctJyDQtdGB0LvQuCDQvdC1INC40YHQv9C+0LvRjNC30YPQtdGC0YHRjyk=",
            "0J/Rg9GC0Ywg0Log0YXRgNCw0L3QuNC70LjRidGDINC60L7QvdGE0LjQs9GD0YDQsNGG0LjQuA==",
            "0J/QvtC70YzQt9C+0LLQsNGC0LXQu9GMINGF0YDQsNC90LjQu9C40YnQsCDQutC+0L3RhNC40LPRg9GA0LDRhtC40Lg=",
            "0J/QsNGA0L7Qu9GMINGF0YDQsNC90LjQu9C40YnQsCDQutC+0L3RhNC40LPRg9GA0LDRhtC40LggKNC/0YPRgdGC0L4g0LjQu9C4ICctJyDQtdGB0LvQuCDQvdC1INC40YHQv9C+0LvRjNC30YPQtdGC0YHRjyk=",
            "0JjRgdC/0L7Qu9GM0LfQvtCy0LDRgtGMINGB0LLQtdC20LjQtSDQstC10YDRgdC40Lgg0LfQsNCy0LjRgdC40LzQvtGB0YLQtdC5INC/0YDQuCDQuNC90LjRhtC40LDQu9C40LfQsNGG0LjQuD8g0J7RgtCy0LXRgtGM0YLQtSDQvdC10YIsINGH0YLQvtCx0Ysg0LjRgdC/0L7Qu9GM0LfQvtCy0LDRgtGMIHBpbnMg0LjQtyAuYWdlbnQtMWMvZGVwZW5kZW5jeS1sb2NrLmpzb24u",
            "0JLRi9Cx0LXRgNC40YLQtSDQtdC00LjQvdGB0YLQstC10L3QvdGL0Lkg0LDQs9C10L3RgtGB0LrQuNC5INC60LvQuNC10L3RgiDQtNC70Y8g0L/RgNC+0LXQutGC0LA6",
            "0JrQu9C40LXQvdGCINCw0LPQtdC90YLQsA==",
            "0JLRi9Cx0LXRgNC40YLQtSDQvtC00LjQvSDQuNC3Og==",
            "0J/RgNC+0LTQvtC70LbQuNGC0Ywg0YEg0Y3RgtC40LzQuCDQt9C90LDRh9C10L3QuNGP0LzQuD8g0J7RgtCy0LXRgtGM0YLQtSDQvdC10YIsINGH0YLQvtCx0Ysg0LfQsNC/0L7Qu9C90LjRgtGMINC/0LDRgNCw0LzQtdGC0YDRiyDQt9Cw0L3QvtCy0L4u",
            "0JfQsNC/0L7Qu9C90LjRgtC1INC/0LDRgNCw0LzQtdGC0YDRiyDQt9Cw0L3QvtCy0L4u",
            "0J/QvtC70L3Ri9C5INC/0YPRgtGMINC6IHdlYmluc3QuZXhl",
            "0JrQsNGC0LDQu9C+0LMg0L/Rg9Cx0LvQuNC60LDRhtC40Lk=",
            "0JHQsNC30L7QstGL0LkgVVJMINC/0YPQsdC70LjQutCw0YbQuNC5",
            "0KLQuNC/IHdlYmluc3Q=",
            "0J3QtdC+0LHRj9C30LDRgtC10LvRjNC90YvQuSDQv9GD0YLRjCDQuiDQutC+0L3RhNC40LPRg9GA0LDRhtC40LggQXBhY2hlL2h0dHBkLCDQv9GD0YHRgtC+INC10YHQu9C4INC90LUg0L3Rg9C20LXQvQ=="
        )

        foreach ($promptBase64 in $russianPromptBase64) {
            [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($promptBase64)) | Should -Not -BeNullOrEmpty
            $HelperText | Should -Match ([regex]::Escape($promptBase64))
        }

        $oldPromptSnippets = @(
            'Read-InitYesNo -Prompt "Initialize the 1C project in this folder?"',
            'Read-Host "Choose platform number or enter full path to 1cv8.exe"',
            'Read-InitRequired "Full path to 1cv8.exe"',
            'Read-Host "Source infobase kind: file or server [file]"',
            'Read-InitYesNo -Prompt "Is the source infobase connected to 1C configuration repository?"',
            'Read-InitYesNo -Prompt "Configure vibecoding1c MCP now? Answer no to do it later through a normal agent request or helper action."',
            'Read-InitYesNo -Prompt "Continue with these values?"',
            'Read-WebPublicationValue -Prompt "Full path to webinst.exe"',
            'Read-WebPublicationValue -Prompt "Publication root directory"',
            'Read-WebPublicationValue -Prompt "Publication URL base"'
        )
        foreach ($snippet in $oldPromptSnippets) {
            $HelperText | Should -Not -Match ([regex]::Escape($snippet))
        }

        $HelperText | Should -Match ([regex]::Escape("IFvQlC/QvV0="))
        $HelperText | Should -Match ([regex]::Escape("IFvQtC/QnV0="))
        $HelperText | Should -Match 'vibecoding1cMcpSetupDuringInit\s*=\s*\$true'
        $HelperText | Should -Not -Match 'answers\.webPublishByDefault\s*=\s*Read-InitYesNo'
        $HelperText | Should -Match 'webPublishByDefault\s*=\s*\$false'
        $HelperText | Should -Match 'Get-EnvValue\s+-Name\s+"VIBECODING1C_MCP_SETUP_DURING_INIT"\s+-Default\s+\$true\)\s+-Default\s+\$true'
    }

    It "restarts init wizard answers when the summary is rejected" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null

            $script:InitWizardRootConfirmations = 0
            $script:InitWizardAnswerReads = 0
            $script:InitWizardSummaryPaths = @()
            $script:InitWizardAnswerConfirmations = 0

            function Test-InteractiveInputAvailable {
                return $true
            }

            function Confirm-InitWizardProjectRoot {
                $script:InitWizardRootConfirmations++
            }

            function Read-InitWizardAnswersOnce {
                $script:InitWizardAnswerReads++
                return [pscustomobject]@{
                    platformPath = "platform-$script:InitWizardAnswerReads"
                    baseConfigurationVersion = "PM5"
                    infoBaseKind = "file"
                    sourceUsesRepository = $false
                    sourceInfoBasePath = "C:\bases\source-$script:InitWizardAnswerReads"
                    ibUser = ""
                    ibPassword = ""
                    repositoryPath = ""
                    repositoryUser = ""
                    repositoryPassword = ""
                    webPublishByDefault = $false
                    webPublishAuto = $false
                    dependencyMode = "fresh"
                    agentTarget = "codex"
                    vibecoding1cMcpSetupDuringInit = $true
                }
            }

            function Write-InitWizardAnswersSummary {
                param([object]$Answers)

                $script:InitWizardSummaryPaths += $Answers.platformPath
            }

            function Confirm-InitWizardAnswers {
                $script:InitWizardAnswerConfirmations++
                return ($script:InitWizardAnswerConfirmations -ge 2)
            }

            $answers = Read-InitAnswersFromWizard 6>$null
            [pscustomobject]@{
                rootConfirmations = $script:InitWizardRootConfirmations
                answerReads = $script:InitWizardAnswerReads
                summaryPaths = ($script:InitWizardSummaryPaths -join "|")
                answerConfirmations = $script:InitWizardAnswerConfirmations
                platformPath = $answers.platformPath
                sourceInfoBasePath = $answers.sourceInfoBasePath
            }
        }

        $result.rootConfirmations | Should -Be 1
        $result.answerReads | Should -Be 2
        $result.summaryPaths | Should -Be "platform-1|platform-2"
        $result.answerConfirmations | Should -Be 2
        $result.platformPath | Should -Be "platform-2"
        $result.sourceInfoBasePath | Should -Be "C:\bases\source-2"
    }

    It "always enables vibecoding1c setup and disables web publication during init" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null

            $baseAnswers = [pscustomobject]@{
                platformPath = "C:\Program Files\1cv8\8.3.99.1\bin\1cv8.exe"
                infoBaseKind = "file"
                sourceUsesRepository = $false
                sourceInfoBasePath = "C:\bases\source"
                dependencyMode = "fresh"
            }
            $defaulted = Normalize-InitAnswers -Answers $baseAnswers

            $explicitAnswers = [pscustomobject]@{
                platformPath = "C:\Program Files\1cv8\8.3.99.1\bin\1cv8.exe"
                infoBaseKind = "file"
                sourceUsesRepository = $false
                sourceInfoBasePath = "C:\bases\source"
                dependencyMode = "fresh"
                VIBECODING1C_MCP_SETUP_DURING_INIT = "false"
                WEB_PUBLISH_BY_DEFAULT = "true"
                WEB_PUBLISH_AUTO = "true"
            }
            $explicit = Normalize-InitAnswers -Answers $explicitAnswers

            [pscustomobject]@{
                defaulted = [bool]$defaulted.vibecoding1cMcpSetupDuringInit
                explicit = [bool]$explicit.vibecoding1cMcpSetupDuringInit
                webPublishByDefault = [bool]$explicit.webPublishByDefault
                webPublishAuto = [bool]$explicit.webPublishAuto
            }
        }

        $result.defaulted | Should -BeTrue
        $result.explicit | Should -BeTrue
        $result.webPublishByDefault | Should -BeFalse
        $result.webPublishAuto | Should -BeFalse
    }

    It "requires and normalizes the source unsafe action protection init mode" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null

            $base = [pscustomobject]@{
                agentTarget = "codex"
                platformPath = "C:\Program Files\1cv8\8.3.99.1\bin\1cv8.exe"
                infoBaseKind = "file"
                sourceUsesRepository = $false
                sourceInfoBasePath = "C:\bases\source"
                dependencyMode = "fresh"
            }
            $missing = Normalize-InitAnswers -Answers $base
            $missingMessage = ""
            try { Assert-InitAnswers -Answers $missing } catch { $missingMessage = $_.Exception.Message }

            $manual = Normalize-InitAnswers -Answers ([pscustomobject]@{
                agentTarget = "codex"
                platformPath = $base.platformPath
                infoBaseKind = "file"
                sourceUsesRepository = $false
                sourceInfoBasePath = $base.sourceInfoBasePath
                dependencyMode = "fresh"
                sourceInfoBaseUnsafeActionProtectionMode = "MANUAL-CONFIRM"
            })
            $invalidMessage = ""
            try { ConvertTo-SourceInfoBaseUnsafeActionProtectionMode "automatic" | Out-Null } catch { $invalidMessage = $_.Exception.Message }

            [pscustomobject]@{
                missingMessage = $missingMessage
                manual = $manual.sourceInfoBaseUnsafeActionProtectionMode
                invalidMessage = $invalidMessage
            }
        }

        $result.missingMessage | Should -Match "sourceInfoBaseUnsafeActionProtectionMode"
        $result.manual | Should -Be "manual-confirm"
        $result.invalidMessage | Should -Match "manual-confirm, defer, or confirmed"
        $HelperText | Should -Match 'sourceInfoBaseUnsafeActionProtectionMode\s*=\s*"manual-confirm"'
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\project.json")) | Should -Match '"sourceInfoBaseUnsafeActionProtectionMode"\s*:\s*"manual-confirm"'
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE=manual-confirm"
    }

    It "gives the configured source protection environment setting precedence over project json" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-source-protection-config-" + [guid]::NewGuid().ToString("N"))
        $oldMode = [Environment]::GetEnvironmentVariable("SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE", "Process")
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates\project.json") -Destination (Join-Path $tempRoot ".agent-1c\project.json")
            [Environment]::SetEnvironmentVariable("SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE", "defer", "Process")
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $fromEnvironment = (New-ConfiguredInitAnswers).sourceInfoBaseUnsafeActionProtectionMode
                [Environment]::SetEnvironmentVariable("SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE", $null, "Process")
                $fromProject = (New-ConfiguredInitAnswers).sourceInfoBaseUnsafeActionProtectionMode
                [pscustomobject]@{ fromEnvironment = $fromEnvironment; fromProject = $fromProject }
            }
            $result.fromEnvironment | Should -Be "defer"
            $result.fromProject | Should -Be "manual-confirm"
        } finally {
            [Environment]::SetEnvironmentVariable("SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE", $oldMode, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "normalizes and persists base configuration version init answers" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-base-configuration-version-" + [guid]::NewGuid().ToString("N"))
        $envNames = @(
            "PLATFORM_PATH",
            "INFOBASE_KIND",
            "SOURCE_USES_REPOSITORY",
            "SOURCE_INFOBASE_PATH",
            "SOURCE_SERVER_NAME",
            "SOURCE_INFOBASE_NAME",
            "IB_USER",
            "IB_PASSWORD",
            "REPOSITORY_PATH",
            "REPOSITORY_USER",
            "REPOSITORY_PASSWORD",
            "WEB_PUBLISH_BY_DEFAULT",
            "WEB_PUBLISH_AUTO",
            "DEPENDENCY_MODE",
            "VIBECODING1C_MCP_SETUP_DURING_INIT"
        )
        $savedEnv = @{}
        foreach ($name in $envNames) {
            $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        }

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null

                $baseAnswers = [pscustomobject]@{
                    platformPath = "C:\Program Files\1cv8\8.3.99.1\bin\1cv8.exe"
                    infoBaseKind = "file"
                    sourceUsesRepository = $false
                    sourceInfoBasePath = "C:\bases\source"
                    dependencyMode = "fresh"
                    agentTarget = "codex"
                }
                $defaulted = Normalize-InitAnswers -Answers $baseAnswers

                $pm4Answers = [pscustomobject]@{
                    platformPath = "C:\Program Files\1cv8\8.3.99.1\bin\1cv8.exe"
                    baseConfigurationVersion = "pm4"
                    infoBaseKind = "file"
                    sourceUsesRepository = $false
                    sourceInfoBasePath = "C:\bases\source"
                    dependencyMode = "fresh"
                    agentTarget = "codex"
                }
                $pm4 = Normalize-InitAnswers -Answers $pm4Answers

                $pm5Answers = [pscustomobject]@{
                    platformPath = "C:\Program Files\1cv8\8.3.99.1\bin\1cv8.exe"
                    BASE_CONFIGURATION_VERSION = "PM5"
                    infoBaseKind = "file"
                    sourceUsesRepository = $false
                    sourceInfoBasePath = "C:\bases\source"
                    dependencyMode = "fresh"
                }
                $pm5 = Normalize-InitAnswers -Answers $pm5Answers

                $invalidMessage = ""
                try {
                    Normalize-InitAnswers -Answers ([pscustomobject]@{
                        platformPath = "C:\Program Files\1cv8\8.3.99.1\bin\1cv8.exe"
                        baseConfigurationVersion = "PM6"
                        infoBaseKind = "file"
                        sourceUsesRepository = $false
                        sourceInfoBasePath = "C:\bases\source"
                        dependencyMode = "fresh"
                        agentTarget = "codex"
                    }) | Out-Null
                } catch {
                    $invalidMessage = $_.Exception.Message
                }

                Save-InitAnswers -Answers $pm4
                Read-ProjectConfig

                [pscustomobject]@{
                    defaulted = $defaulted.baseConfigurationVersion
                    pm4 = $pm4.baseConfigurationVersion
                    pm5 = $pm5.baseConfigurationVersion
                    invalidMessage = $invalidMessage
                    persisted = [string](Get-ConfigValue -Path "baseConfigurationVersion" -Default "")
                    dotenvText = Read-Utf8Text -Path (Join-Path $script:ProjectRoot ".dev.env")
                }
            }

            $result.defaulted | Should -Be "PM5"
            $result.pm4 | Should -Be "PM4"
            $result.pm5 | Should -Be "PM5"
            $result.invalidMessage | Should -Match "Use PM4 or PM5"
            $result.persisted | Should -Be "PM4"
            $result.dotenvText | Should -Not -Match "BASE_CONFIGURATION_VERSION"
        } finally {
            foreach ($name in $envNames) {
                [Environment]::SetEnvironmentVariable($name, $savedEnv[$name], "Process")
            }
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
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
            $status.stage | Should -Not -BeNullOrEmpty
            [int]$status.lastProcessId | Should -Be 0
            [bool]$status.lastProcessTimedOut | Should -Be $false
            [int]$status.launcherPid | Should -Be 0
            [bool]$status.gitIndexLockPreExisted | Should -Be $false
            [string]$status.resumedFrom | Should -Be ""
            [string]$status.recoveryReason | Should -Be ""
            $bytes = [System.IO.File]::ReadAllBytes($statusPath)
            ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) | Should -Be $false
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "rejects init success before the completion stage" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-status-incomplete-success-" + [guid]::NewGuid().ToString("N"))
        $statusPath = Join-Path $tempRoot "status.json"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            {
                & {
                    . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                    $Action = "init-project"
                    $RunStatusPath = $statusPath
                    $script:RunStage = "init.commit-dump"
                    Write-RunStatus -Status "succeeded" -ExitCode 0
                }
            } | Should -Throw "*requires stage init.complete and exitCode 0*"
            (Test-Path -LiteralPath $statusPath -PathType Leaf) | Should -Be $false
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "preserves Cyrillic projectRoot in helper status JSON" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-status-РљРћР Рџ-" + [guid]::NewGuid().ToString("N"))
        $statusPath = Join-Path $tempRoot "status.json"
        $logPath = Join-Path $tempRoot "console.log"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action help -RunStatusPath $statusPath -RunLogPath $logPath *> $null
            $LASTEXITCODE | Should -Be 0

            $status = Get-Content -Encoding UTF8 -Raw $statusPath | ConvertFrom-Json
            $status.status | Should -Be "succeeded"
            $status.projectRoot | Should -Be ([System.IO.Path]::GetFullPath($tempRoot))
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

    It "writes failed launcher status when helper exits without terminal status" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-launcher-РљРћР Рџ-" + [guid]::NewGuid().ToString("N"))
        $fakeHelperPath = Join-Path $tempRoot "fake-helper.ps1"
        $stdoutPath = Join-Path $tempRoot "stdout.log"
        $stderrPath = Join-Path $tempRoot "stderr.log"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath $fakeHelperPath -Encoding UTF8 -Value @'
param(
    [string]$ProjectRoot,
    [string]$RunStatusPath,
    [string]$RunLogPath,
    [string]$Action,
    [string]$InitMode
)
Write-Host "fake helper exits without status"
exit 7
'@

            $process = Start-Process -FilePath "powershell" -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", $LauncherPath,
                "-ProjectRoot", $tempRoot,
                "-HelperPath", $fakeHelperPath,
                "-PollIntervalMilliseconds", "50",
                "-StatusStartTimeoutSeconds", "1",
                "-MaxWaitSeconds", "10",
                "--",
                "-Action", "init-project",
                "-InitMode", "configured"
            ) -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -NoNewWindow -Wait -PassThru

            $process.ExitCode | Should -Be 7
            $runDir = Get-ChildItem -LiteralPath (Join-Path $tempRoot ".agent-1c\runs") -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $status = Get-Content -Encoding UTF8 -Raw (Join-Path $runDir.FullName "status.json") | ConvertFrom-Json
            $status.status | Should -Be "failed"
            $status.projectRoot | Should -Be ([System.IO.Path]::GetFullPath($tempRoot))
            [int]$status.exitCode | Should -Be 7
            $status.stage | Should -Be "launcher.helper-exited"
            $status.errorMessage | Should -Match "before writing a terminal status"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "times out launcher, writes failed status, and removes current-run Git index lock" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-launcher-timeout-" + [guid]::NewGuid().ToString("N"))
        $fakeHelperPath = Join-Path $tempRoot "fake-helper.ps1"
        $stdoutPath = Join-Path $tempRoot "stdout.log"
        $stderrPath = Join-Path $tempRoot "stderr.log"
        $lockPath = Join-Path $tempRoot ".git\index.lock"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath $fakeHelperPath -Encoding UTF8 -Value @'
param(
    [string]$ProjectRoot,
    [string]$RunStatusPath,
    [string]$RunLogPath,
    [string]$Action
)
& git -C $ProjectRoot init *> $null
Set-Content -LiteralPath (Join-Path $ProjectRoot ".git\index.lock") -Encoding ASCII -Value "created-by-timeout-test"
Start-Sleep -Seconds 20
'@

            $process = Start-Process -FilePath "powershell" -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", $LauncherPath,
                "-ProjectRoot", $tempRoot,
                "-HelperPath", $fakeHelperPath,
                "-PollIntervalMilliseconds", "50",
                "-StatusStartTimeoutSeconds", "1",
                "-MaxWaitSeconds", "5",
                "--",
                "-Action", "init-project"
            ) -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -NoNewWindow -Wait -PassThru

            $process.ExitCode | Should -Be 124
            $runDir = Get-ChildItem -LiteralPath (Join-Path $tempRoot ".agent-1c\runs") -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $status = Get-Content -Encoding UTF8 -Raw (Join-Path $runDir.FullName "status.json") | ConvertFrom-Json
            $status.status | Should -Be "failed"
            [int]$status.exitCode | Should -Be 124
            $status.stage | Should -Be "launcher.timeout"
            $status.errorMessage | Should -Match "timed out after 5 seconds"
            if ($status.errorMessage -match "Removed Git index lock") {
                (Test-Path -LiteralPath $lockPath -PathType Leaf) | Should -Be $false
            } else {
                $status.errorMessage | Should -Match "git.exe is still running"
                (Test-Path -LiteralPath $lockPath -PathType Leaf) | Should -Be $true
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "marks an invalid init success orphaned and automatically resumes it" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-resume-КОРП-" + [guid]::NewGuid().ToString("N"))
        $fakeHelperPath = Join-Path $tempRoot "fake-resume-helper.ps1"
        $oldRunDir = Join-Path $tempRoot ".agent-1c\runs\20260101-000000-old"
        $oldStatusPath = Join-Path $oldRunDir "status.json"
        $lockPath = Join-Path $tempRoot ".git\index.lock"
        $stdoutPath = Join-Path $tempRoot "stdout.log"
        $stderrPath = Join-Path $tempRoot "stderr.log"

        try {
            New-Item -ItemType Directory -Force -Path $oldRunDir | Out-Null
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lockPath) | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value "{}"
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Encoding UTF8 -Value "VIBECODING1C_MCP_SETUP_DURING_INIT=false"
            Set-Content -LiteralPath $fakeHelperPath -Encoding UTF8 -Value $ResumeFakeHelperText
            Set-Content -LiteralPath $lockPath -Encoding ASCII -Value "interrupted-run"
            $now = Get-Date
            $oldStatus = [ordered]@{
                schemaVersion = 1
                status = "succeeded"
                action = "init-project"
                projectRoot = [System.IO.Path]::GetFullPath($tempRoot)
                pid = 999999
                launcherPid = 999998
                startedAt = $now.AddMinutes(-2).ToString("o")
                updatedAt = $now.AddMinutes(-1).ToString("o")
                finishedAt = $now.ToString("o")
                exitCode = $null
                stage = "init.commit-dump"
                stageDetail = "Committing baseline 1C configuration dump"
                lastProcessId = 0
                lastProcessTimedOut = $false
                gitIndexLockPreExisted = $false
            }
            [System.IO.File]::WriteAllText($oldStatusPath, (($oldStatus | ConvertTo-Json) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding $false))

            $process = Start-Process -FilePath "powershell" -ArgumentList @(
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $LauncherPath,
                "-ProjectRoot", $tempRoot, "-HelperPath", $fakeHelperPath,
                "-PollIntervalMilliseconds", "50", "-MaxWaitSeconds", "10", "--",
                "-Action", "init-project", "-InitMode", "wizard"
            ) -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -NoNewWindow -Wait -PassThru

            $process.ExitCode | Should -Be 0
            $oldFinal = Get-Content -Encoding UTF8 -Raw $oldStatusPath | ConvertFrom-Json
            $oldFinal.status | Should -Be "failed"
            $oldFinal.stage | Should -Be "launcher.orphaned"
            $oldFinal.resumeStage | Should -Be "init.commit-dump"
            [int]$oldFinal.exitCode | Should -Be 125
            (Test-Path -LiteralPath $lockPath -PathType Leaf) | Should -Be $false

            $capture = Get-Content -Encoding UTF8 -Raw (Join-Path $tempRoot "resume-capture.json") | ConvertFrom-Json
            $capture.initMode | Should -Be "resume"
            $capture.resumeRunStatusPath | Should -Be ([System.IO.Path]::GetFullPath($oldStatusPath))
            $capture.recoveryReason | Should -Match "marked orphaned"
            [int]$capture.launcherPid | Should -BeGreaterThan 0

            $newRun = Get-ChildItem -LiteralPath (Join-Path $tempRoot ".agent-1c\runs") -Directory | Where-Object { $_.FullName -ne $oldRunDir } | Select-Object -First 1
            $newStatus = Get-Content -Encoding UTF8 -Raw (Join-Path $newRun.FullName "status.json") | ConvertFrom-Json
            $newStatus.status | Should -Be "succeeded"
            $newStatus.stage | Should -Be "init.complete"
            [int]$newStatus.exitCode | Should -Be 0
            $newStatus.projectRoot | Should -Be ([System.IO.Path]::GetFullPath($tempRoot))
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "preserves an orphan lock when old status has no ownership field" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-resume-old-status-" + [guid]::NewGuid().ToString("N"))
        $fakeHelperPath = Join-Path $tempRoot "fake-resume-helper.ps1"
        $oldRunDir = Join-Path $tempRoot ".agent-1c\runs\20260101-000000-old"
        $oldStatusPath = Join-Path $oldRunDir "status.json"
        $lockPath = Join-Path $tempRoot ".git\index.lock"

        try {
            New-Item -ItemType Directory -Force -Path $oldRunDir | Out-Null
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $lockPath) | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value "{}"
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Encoding UTF8 -Value "VIBECODING1C_MCP_SETUP_DURING_INIT=false"
            Set-Content -LiteralPath $fakeHelperPath -Encoding UTF8 -Value $ResumeFakeHelperText
            Set-Content -LiteralPath $lockPath -Encoding ASCII -Value "unknown-owner"
            $now = Get-Date
            $oldStatus = [ordered]@{
                schemaVersion = 1
                status = "running"
                action = "init-project"
                projectRoot = [System.IO.Path]::GetFullPath($tempRoot)
                pid = 999999
                startedAt = $now.AddMinutes(-2).ToString("o")
                updatedAt = $now.AddMinutes(-1).ToString("o")
                finishedAt = $null
                exitCode = $null
                stage = "init.commit-dump"
                lastProcessId = 0
            }
            Set-Content -LiteralPath $oldStatusPath -Encoding UTF8 -Value ($oldStatus | ConvertTo-Json)

            & powershell -NoProfile -ExecutionPolicy Bypass -File $LauncherPath -ProjectRoot $tempRoot -HelperPath $fakeHelperPath -PollIntervalMilliseconds 50 -MaxWaitSeconds 10 -- -Action init-project -InitMode wizard *> $null
            $LASTEXITCODE | Should -Be 0
            (Test-Path -LiteralPath $lockPath -PathType Leaf) | Should -Be $true
            $oldFinal = Get-Content -Encoding UTF8 -Raw $oldStatusPath | ConvertFrom-Json
            $oldFinal.errorMessage | Should -Match "ownership is unknown"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "refuses automatic recovery while the recorded helper is still alive" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-resume-live-helper-" + [guid]::NewGuid().ToString("N"))
        $oldRunDir = Join-Path $tempRoot ".agent-1c\runs\20260101-000000-old"
        $oldStatusPath = Join-Path $oldRunDir "status.json"
        $stdoutPath = Join-Path $tempRoot "stdout.log"
        $stderrPath = Join-Path $tempRoot "stderr.log"
        $sleeper = $null

        try {
            New-Item -ItemType Directory -Force -Path $oldRunDir | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value "{}"
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Encoding UTF8 -Value "VIBECODING1C_MCP_SETUP_DURING_INIT=false"
            $sleeper = Start-Process -FilePath "powershell" -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 30") -PassThru -WindowStyle Hidden
            $now = Get-Date
            $oldStatus = [ordered]@{
                schemaVersion = 1
                status = "running"
                action = "init-project"
                projectRoot = [System.IO.Path]::GetFullPath($tempRoot)
                pid = $sleeper.Id
                startedAt = $now.AddSeconds(-5).ToString("o")
                updatedAt = $now.ToString("o")
                finishedAt = $null
                exitCode = $null
                stage = "init.dump-config"
                lastProcessId = 0
                gitIndexLockPreExisted = $false
            }
            Set-Content -LiteralPath $oldStatusPath -Encoding UTF8 -Value ($oldStatus | ConvertTo-Json)

            $process = Start-Process -FilePath "powershell" -ArgumentList @(
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $LauncherPath,
                "-ProjectRoot", $tempRoot, "-MaxWaitSeconds", "10", "--",
                "-Action", "init-project", "-InitMode", "wizard"
            ) -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -NoNewWindow -Wait -PassThru
            $process.ExitCode | Should -Not -Be 0
            (Get-Content -LiteralPath $stderrPath -Raw) | Should -Match "already running"
            @(Get-ChildItem -LiteralPath (Join-Path $tempRoot ".agent-1c\runs") -Directory).Count | Should -Be 1
            (Get-Content -Encoding UTF8 -Raw $oldStatusPath | ConvertFrom-Json).status | Should -Be "running"
        } finally {
            if ($null -ne $sleeper) {
                Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "repeats pre-dump work but skips a dump proven complete by commit stage" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-resume-stage-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "<dump />"

            $results = @{}
            foreach ($resumeStage in @("init.dump-config", "init.commit-dump")) {
                $statusPath = Join-Path $tempRoot ("$($resumeStage.Replace('.', '-')).json")
                $status = [ordered]@{
                    schemaVersion = 1
                    status = "failed"
                    action = "init-project"
                    projectRoot = [System.IO.Path]::GetFullPath($tempRoot)
                    stage = "launcher.orphaned"
                    resumeStage = $resumeStage
                }
                Set-Content -LiteralPath $statusPath -Encoding UTF8 -Value ($status | ConvertTo-Json)

                $results[$resumeStage] = & {
                    param($Helper, $Root, $ResumeStatus)
                    . $Helper -ProjectRoot $Root -Action help *> $null
                    $InitMode = "resume"
                    $ResumeRunStatusPath = $ResumeStatus
                    $RunStatusPath = ""
                    $calls = [System.Collections.Generic.List[string]]::new()

                    function Write-Section { param([string]$Text) }
                    function Set-RunStage { param([string]$Stage, [string]$Detail = "") }
                    function Prepare-ConfiguredInitProjectSettings { $calls.Add("prepare") | Out-Null }
                    function Apply-BootstrapWorkflowPackageProvenance { return $null }
                    function Check-Tools { param([switch]$StopOnMissing); $calls.Add("check-tools") | Out-Null }
                    function Install-RoctupMcp { $calls.Add("install-roctup") | Out-Null }
                    function Install-VanessaMcpArtifacts { $calls.Add("cache-vanessa") | Out-Null; return $null }
                    function Get-DevBranchInfoBaseRoot { return ".agent-1c/infobases/dev-branches" }
                    function Ensure-GitRepository { $calls.Add("ensure-git") | Out-Null }
                    function Ensure-GitIgnore { }
                    function Checkout-Master { }
                    function Get-SourceUsesRepository { return $true }
                    function Update-BaseFromRepository { $calls.Add("repository-update") | Out-Null }
                    function Dump-ConfigToFiles {
                        $calls.Add("dump") | Out-Null
                        return [pscustomobject]@{ exportPath = "src/cf"; absoluteExportPath = (Join-Path $Root "src\cf"); incremental = $true; logPath = "" }
                    }
                    function Commit-BaselineDumpIfNeeded { param([string]$Message, [string]$ExportPath); $calls.Add("commit-dump") | Out-Null; return $false }
                    function Assert-BaselineDumpCommitted { param([string]$ExportPath) }
                    function Test-InitAiRulesReady { return $true }
                    function Install-AiRules1c { $calls.Add("install-ai-rules") | Out-Null }
                    function Update-AgentGuidanceBridge { }
                    function Update-UserRules { }
                    function Sync-KiloItlCommandSurface { }
                    function Commit-IfChanged { param([string]$Message); return $false }
                    function Get-EnvValue { param([string]$Name, [object]$Default); return $false }
                    function ConvertTo-YesNoBool { param([object]$Value, [bool]$Default); return $false }
                    function Setup-Vibecoding1cMcp { $calls.Add("setup-vibecoding") | Out-Null }
                    function Assert-InitGitClean { $calls.Add("git-clean") | Out-Null }

                    Initialize-Project
                    return @($calls)
                } $HelperPath $tempRoot $statusPath
            }

            $results["init.dump-config"] | Should -Contain "check-tools"
            $results["init.dump-config"] | Should -Contain "repository-update"
            $results["init.dump-config"] | Should -Contain "dump"
            $results["init.commit-dump"] | Should -Not -Contain "check-tools"
            $results["init.commit-dump"] | Should -Not -Contain "repository-update"
            $results["init.commit-dump"] | Should -Not -Contain "dump"
            $results["init.commit-dump"] | Should -Contain "commit-dump"
            $results["init.commit-dump"] | Should -Not -Contain "install-ai-rules"
            $results["init.commit-dump"] | Should -Contain "git-clean"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "skips init baseline dump commit when the dump is already committed" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-baseline-dump-skip-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf") | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "<dump />"
            & git -C $tempRoot add src/cf/ConfigDumpInfo.xml
            & git -C $tempRoot commit -m "baseline dump" *> $null

            $commitBefore = ((& git -C $tempRoot rev-parse HEAD).Trim())
            $committed = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Commit-BaselineDumpIfNeeded -Message "sync: export 1C configuration from source infobase" -ExportPath "src/cf"
            }

            $committed | Should -Be $false
            ((& git -C $tempRoot rev-parse HEAD).Trim()) | Should -Be $commitBefore
            ((& git -C $tempRoot diff --cached --name-only) -join [Environment]::NewLine) | Should -Be ""
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "fails init baseline dump commit when no baseline dump is committed" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-baseline-dump-missing-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf") | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Other.xml") -Encoding UTF8 -Value "<other />"
            & git -C $tempRoot add src/cf/Other.xml
            & git -C $tempRoot commit -m "other dump file" *> $null

            {
                & {
                    . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                    Commit-BaselineDumpIfNeeded -Message "sync: export 1C configuration from source infobase" -ExportPath "src/cf"
                }
            } | Should -Throw "*Expected files from the 1C configuration dump*"

            ((& git -C $tempRoot rev-list --count HEAD).Trim()) | Should -Be "1"
            ((& git -C $tempRoot diff --cached --name-only) -join [Environment]::NewLine) | Should -Be ""
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "accepts empty 1C dump log when dump artifacts exist" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-empty-dump-log-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null

                function Get-ExportPath {
                    return "src/cf"
                }

                function Get-SourceUsesRepository {
                    return $false
                }

                function Get-SourceInfoBasePath {
                    return (Join-Path $script:ProjectRoot "source-base")
                }

                function Get-InfoBaseKind {
                    return "file"
                }

                function Invoke-Designer {
                    param(
                        [string]$InfoBasePath,
                        [string]$InfoBaseKind,
                        [string[]]$DesignerArgs
                    )

                    $dumpIndex = [Array]::IndexOf($DesignerArgs, "/DumpConfigToFiles")
                    if ($dumpIndex -lt 0 -or ($dumpIndex + 1) -ge $DesignerArgs.Count) {
                        throw "Dump path was not passed to Invoke-Designer."
                    }
                    $dumpPath = [string]$DesignerArgs[$dumpIndex + 1]
                    New-Item -ItemType Directory -Force -Path $dumpPath | Out-Null
                    Write-Utf8Text -Path (Join-Path $dumpPath "ConfigDumpInfo.xml") -Value "<dump />`n"
                    Write-Utf8Text -Path (Join-Path $dumpPath "Configuration.xml") -Value "<configuration />`n"
                    $script:LastLogPath = Join-Path $script:ProjectRoot "empty-1c.log"
                    Write-Utf8Text -Path $script:LastLogPath -Value ""
                    return $script:LastLogPath
                }

                Dump-ConfigToFiles
            }

            $result.exportPath | Should -Be "src/cf"
            (Get-Item -LiteralPath $result.logPath).Length | Should -Be 0
            (Test-Path -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -PathType Leaf) | Should -Be $true
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
