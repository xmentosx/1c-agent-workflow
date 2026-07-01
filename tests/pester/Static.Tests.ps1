Describe "1C agent workflow static checks" {
    BeforeAll {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
        $HelperPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
        $LauncherPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\run-agent-1c-window.ps1"
        $HelperText = Get-Content -Encoding UTF8 -Raw $HelperPath
        $LauncherText = Get-Content -Encoding UTF8 -Raw $LauncherPath
    }

    It "parses the PowerShell helper" {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($HelperPath, [ref]$tokens, [ref]$errors) | Out-Null

        @($errors).Count | Should -Be 0
    }

    It "parses the monitored window launcher" {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($LauncherPath, [ref]$tokens, [ref]$errors) | Out-Null

        @($errors).Count | Should -Be 0
    }

    It "does not promote 1C Designer warnings to errors" {
        $flag = "-Warnings" + "AsErrors"
        $HelperText | Should -Not -Match ([regex]::Escape($flag))
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
            [regex]::Matches($text, "(?<![\w-])/(itl(?:-[a-z-]+)?)") | ForEach-Object { "/" + $_.Groups[1].Value }
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
        $allowedActions = @([regex]::Matches($match.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })

        $wrapperFiles = Get-ChildItem -LiteralPath (Join-Path $RepoRoot ".kilo\commands") -File -Filter "itl*.md"
        foreach ($file in $wrapperFiles) {
            $text = Get-Content -Encoding UTF8 -Raw $file.FullName
            $actionMatch = [regex]::Match($text, "-Action\s+([a-z0-9-]+)")
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

    It "does not advertise init-project in beginner command menus" {
        $menuPaths = @(
            ".kilo\commands\itl.md",
            "README.md",
            "DEVELOPER-GUIDE.ru.md"
        ) | ForEach-Object { Join-Path $RepoRoot $_ }

        foreach ($path in $menuPaths) {
            $text = Get-Content -Encoding UTF8 -Raw $path
            $text | Should -Not -Match "/itl-init-project"
        }

        $workflowText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\workflow.md")
        $shortSurfaceMatch = [regex]::Match($workflowText, "short command surface: (?<commands>.+?)\. These wrappers")
        $shortSurfaceMatch.Success | Should -Be $true
        $shortSurfaceMatch.Groups["commands"].Value | Should -Not -Match "/itl-init-project"
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
    }

    It "ignores monitored run status and log artifacts" {
        $requiredPath = ".agent-1c/runs/"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape($requiredPath))
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\gitignore.append")) | Should -Match ([regex]::Escape($requiredPath))
        $HelperText | Should -Match ([regex]::Escape($requiredPath))
        $LauncherText | Should -Match ([regex]::Escape(".agent-1c\runs"))
    }

    It "ignores local Kilo runtime state without blocking branch creation" {
        $requiredPath = ".kilo/kilo.json"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".gitignore")) | Should -Match ([regex]::Escape($requiredPath))
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\gitignore.append")) | Should -Match ([regex]::Escape($requiredPath))
        $HelperText | Should -Match ([regex]::Escape($requiredPath))
        $HelperText | Should -Match "Test-IgnorableLocalGitStatusLine"
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

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action validate -RunStatusPath $statusPath -RunLogPath $logPath *> $null
            $LASTEXITCODE | Should -Be 1

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

    It "wires result manifest creation into result and close actions" {
        $HelperText | Should -Match "function New-ResultManifest"
        $HelperText | Should -Match "\.manifest\.json"
        $HelperText | Should -Match "lastResultManifestPath"
        $HelperText | Should -Match "finalResultManifestPath"
        $HelperText | Should -Match "Get-FileHash -Algorithm SHA256"
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
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Value ".dev.env`nsource-base/`n" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot "README.md") -Value "fixture" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Value @"
INFOBASE_KIND=file
SOURCE_USES_REPOSITORY=false
SOURCE_INFOBASE_PATH=$sourceBase
IB_USER=
IB_PASSWORD=
WEB_PUBLISH_BY_DEFAULT=false
"@ -Encoding UTF8

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
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Value ".dev.env`nsource-base/`n" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot "README.md") -Value "fixture" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Value @"
INFOBASE_KIND=file
SOURCE_USES_REPOSITORY=false
SOURCE_INFOBASE_PATH=$sourceBase
IB_USER=
IB_PASSWORD=
WEB_PUBLISH_BY_DEFAULT=false
"@ -Encoding UTF8

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
            (Test-Path -LiteralPath "$tempRoot-worktrees" -PathType Container -ErrorAction SilentlyContinue) | Should -Be $false
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
