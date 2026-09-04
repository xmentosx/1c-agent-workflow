Describe "1C workflow development branch lifecycle checks" {
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

        function New-ShortWorkflowProjectRoot {
            $parent = Join-Path ([Environment]::GetFolderPath("UserProfile")) "W"
            return (Join-Path $parent ("t" + [guid]::NewGuid().ToString("N").Substring(0, 6)))
        }

        function New-LifecycleMergeConflictFixture {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-merge-resume-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf") | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot config core.autocrlf false
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "base-cursor"
            Set-Content -LiteralPath (Join-Path $tempRoot "conflict.txt") -Encoding UTF8 -Value "base"
            Set-Content -LiteralPath (Join-Path $tempRoot "unrelated.txt") -Encoding UTF8 -Value "base-unrelated"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Related.bsl") -Encoding UTF8 -Value "base-related"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M master

            & git -C $tempRoot checkout --quiet -b itldev/test
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "branch-cursor"
            Set-Content -LiteralPath (Join-Path $tempRoot "conflict.txt") -Encoding UTF8 -Value "branch"
            Set-Content -LiteralPath (Join-Path $tempRoot "branch.txt") -Encoding UTF8 -Value "branch-only"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "branch" *> $null
            $branchCommit = (& git -C $tempRoot rev-parse HEAD).Trim()

            & git -C $tempRoot checkout --quiet master
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "master-cursor"
            Set-Content -LiteralPath (Join-Path $tempRoot "conflict.txt") -Encoding UTF8 -Value "master"
            Set-Content -LiteralPath (Join-Path $tempRoot "master.txt") -Encoding UTF8 -Value "master-only"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "master" *> $null
            $targetCommit = (& git -C $tempRoot rev-parse HEAD).Trim()
            & git -C $tempRoot checkout --quiet itldev/test

            return [pscustomobject]@{
                root = $tempRoot
                branchCommit = $branchCommit
                targetCommit = $targetCommit
            }
        }

        function New-LifecyclePostMergeCursorFixture {
            param(
                [string]$Subject = "chore: persist branch configuration synchronization cursor",
                [ValidateSet("cursor", "foreign")][string]$ChangedPath = "cursor",
                [ValidateSet("none", "extra", "merge")][string]$AdditionalHead = "none",
                [switch]$SkipCursor
            )

            $fixture = New-LifecycleMergeConflictFixture
            & git -C $fixture.root merge --no-ff --no-commit $fixture.targetCommit *> $null
            Set-Content -LiteralPath (Join-Path $fixture.root "conflict.txt") -Encoding UTF8 -Value "resolved"
            Set-Content -LiteralPath (Join-Path $fixture.root "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "branch-cursor"
            & git -C $fixture.root add .
            & git -C $fixture.root commit --no-edit *> $null
            $mergeCommit = (& git -C $fixture.root rev-parse HEAD).Trim()

            $cursorCommit = $mergeCommit
            if (-not $SkipCursor) {
                if ($ChangedPath -eq "cursor") {
                    Set-Content -LiteralPath (Join-Path $fixture.root "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "post-merge-cursor"
                } else {
                    Set-Content -LiteralPath (Join-Path $fixture.root "unrelated.txt") -Encoding UTF8 -Value "post-merge-foreign"
                }
                & git -C $fixture.root add .
                & git -C $fixture.root commit -m $Subject *> $null
                $cursorCommit = (& git -C $fixture.root rev-parse HEAD).Trim()
            }

            if (-not $SkipCursor -and $AdditionalHead -eq "extra") {
                Set-Content -LiteralPath (Join-Path $fixture.root "branch.txt") -Encoding UTF8 -Value "extra"
                & git -C $fixture.root add .
                & git -C $fixture.root commit -m "extra commit" *> $null
            } elseif (-not $SkipCursor -and $AdditionalHead -eq "merge") {
                & git -C $fixture.root checkout --quiet -b cursor-side
                Set-Content -LiteralPath (Join-Path $fixture.root "side.txt") -Encoding UTF8 -Value "side"
                & git -C $fixture.root add .
                & git -C $fixture.root commit -m "side" *> $null
                & git -C $fixture.root checkout --quiet itldev/test
                & git -C $fixture.root merge --no-ff cursor-side -m "extra merge" *> $null
            }

            return [pscustomobject]@{
                root = $fixture.root
                branchCommit = $fixture.branchCommit
                targetCommit = $fixture.targetCommit
                mergeCommit = $mergeCommit
                cursorCommit = $cursorCommit
                head = (& git -C $fixture.root rev-parse HEAD).Trim()
            }
        }

        function New-LifecycleMergeSourceIntegrityFixture {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl source Целостность " + [guid]::NewGuid().ToString("N"))
            $configRoot = Join-Path $tempRoot "src\cf"
            $validatorRoot = Join-Path $tempRoot "tools с пробелом"
            New-Item -ItemType Directory -Force -Path $configRoot, $validatorRoot | Out-Null
            $configurationPath = Join-Path $configRoot "Configuration.xml"
            $baseConfiguration = @"
<Configuration>
  <ChildObjects>
    <Constant>Alpha</Constant>
    <Constant>Omega</Constant>
    <Catalog>Products</Catalog>
    <Document>Order</Document>
    <Report>Sales</Report>
    <CommonForm>Main</CommonForm>
  </ChildObjects>
</Configuration>
"@
            [System.IO.File]::WriteAllText($configurationPath, $baseConfiguration, [System.Text.UTF8Encoding]::new($false))
            Set-Content -LiteralPath (Join-Path $configRoot "ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor"
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot config core.autocrlf false
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M master

            & git -C $tempRoot checkout --quiet -b itldev/test
            $branchConfiguration = $baseConfiguration.Replace("    <CommonForm>Main</CommonForm>", "    <Constant>Shared</Constant>`r`n    <CommonForm>Main</CommonForm>")
            [System.IO.File]::WriteAllText($configurationPath, $branchConfiguration, [System.Text.UTF8Encoding]::new($false))
            Set-Content -LiteralPath (Join-Path $tempRoot "branch.txt") -Encoding UTF8 -Value "branch"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "branch" *> $null
            $branchCommit = (& git -C $tempRoot rev-parse HEAD).Trim()

            & git -C $tempRoot checkout --quiet master
            $masterConfiguration = $baseConfiguration.Replace("    <Constant>Omega</Constant>", "    <Constant>Shared</Constant>`r`n    <Constant>Omega</Constant>")
            [System.IO.File]::WriteAllText($configurationPath, $masterConfiguration, [System.Text.UTF8Encoding]::new($false))
            Set-Content -LiteralPath (Join-Path $tempRoot "master.txt") -Encoding UTF8 -Value "master"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "master" *> $null
            $targetCommit = (& git -C $tempRoot rev-parse HEAD).Trim()
            & git -C $tempRoot checkout --quiet itldev/test

            $validatorPath = Join-Path $validatorRoot "cf-validate.ps1"
            $validator = @'
param([string]$ConfigPath, [int]$MaxErrors, [string]$OutFile)
$source = [System.IO.File]::ReadAllText((Join-Path $ConfigPath "Configuration.xml"), [System.Text.Encoding]::UTF8)
$count = [regex]::Matches($source, "<Constant>Shared</Constant>").Count
$message = if ($count -gt 1) { "[ERROR] 5. Duplicate: Constant.Shared" } else { "=== Validation OK ===" }
[System.IO.File]::WriteAllText($OutFile, $message, [System.Text.UTF8Encoding]::new($true))
if ($count -gt 1) { exit 1 }
exit 0
'@
            [System.IO.File]::WriteAllText($validatorPath, $validator, [System.Text.UTF8Encoding]::new($false))
            Add-Content -LiteralPath (Join-Path $tempRoot ".git\info\exclude") -Encoding UTF8 -Value "tools с пробелом/"

            return [pscustomobject]@{
                root = $tempRoot
                branchCommit = $branchCommit
                targetCommit = $targetCommit
                configurationPath = $configurationPath
                validatorPath = $validatorPath
            }
        }

        function New-LifecycleMergeBslDuplicateFixture {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl BSL Дубликат " + [guid]::NewGuid().ToString("N"))
            $configRoot = Join-Path $tempRoot "src\cf"
            $moduleRoot = Join-Path $configRoot "CommonModules\ОбщийМодуль\Ext"
            $validatorRoot = Join-Path $tempRoot "tools с пробелом"
            New-Item -ItemType Directory -Force -Path $configRoot, $moduleRoot, $validatorRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $configRoot "Configuration.xml") -Encoding UTF8 -Value "<Configuration />"
            Set-Content -LiteralPath (Join-Path $configRoot "ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor"
            $modulePath = Join-Path $moduleRoot "Module.bsl"
            $baseModule = @"
Процедура Начало()
КонецПроцедуры

Процедура Середина()
КонецПроцедуры

Процедура Конец()
КонецПроцедуры
"@
            [System.IO.File]::WriteAllText($modulePath, $baseModule, [System.Text.UTF8Encoding]::new($false))
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot config core.autocrlf false
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M master

            $method = "Процедура ОбщийМетод()`r`nКонецПроцедуры`r`n`r`n"
            & git -C $tempRoot checkout --quiet -b itldev/test
            [System.IO.File]::WriteAllText($modulePath, $baseModule.Replace("Процедура Середина()", $method + "Процедура Середина()"), [System.Text.UTF8Encoding]::new($false))
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "branch method" *> $null
            $branchCommit = (& git -C $tempRoot rev-parse HEAD).Trim()

            & git -C $tempRoot checkout --quiet master
            [System.IO.File]::WriteAllText($modulePath, $baseModule.Replace("Процедура Конец()", $method + "Процедура Конец()"), [System.Text.UTF8Encoding]::new($false))
            $targetOnlyFormRoot = Join-Path $configRoot "CommonForms\ТолькоMaster\Ext"
            New-Item -ItemType Directory -Force -Path $targetOnlyFormRoot | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $targetOnlyFormRoot "Form.xml"), "<Form />", [System.Text.UTF8Encoding]::new($false))
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "master method" *> $null
            $targetCommit = (& git -C $tempRoot rev-parse HEAD).Trim()
            & git -C $tempRoot checkout --quiet itldev/test

            $validatorPath = Join-Path $validatorRoot "cf-validate.ps1"
            [System.IO.File]::WriteAllText($validatorPath, @'
param([string]$ConfigPath, [int]$MaxErrors, [string]$OutFile)
[System.IO.File]::WriteAllText($OutFile, "=== Validation OK ===", [System.Text.UTF8Encoding]::new($true))
exit 0
'@, [System.Text.UTF8Encoding]::new($false))
            Add-Content -LiteralPath (Join-Path $tempRoot ".git\info\exclude") -Encoding UTF8 -Value "tools с пробелом/"

            return [pscustomobject]@{
                root = $tempRoot
                branchCommit = $branchCommit
                targetCommit = $targetCommit
                modulePath = $modulePath
                moduleRepoPath = "src/cf/CommonModules/ОбщийМодуль/Ext/Module.bsl"
                validatorPath = $validatorPath
            }
        }

        function New-LifecycleMergeFormIntegrityFixture {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl Форма с пробелом " + [guid]::NewGuid().ToString("N"))
            $configRoot = Join-Path $tempRoot "src\cf"
            $formRoot = Join-Path $configRoot "CommonForms\ОбщаяФорма\Ext"
            $validatorRoot = Join-Path $tempRoot "tools с пробелом"
            New-Item -ItemType Directory -Force -Path $configRoot, $formRoot, $validatorRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $configRoot "Configuration.xml") -Encoding UTF8 -Value "<Configuration />"
            Set-Content -LiteralPath (Join-Path $configRoot "ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor"
            $formPath = Join-Path $formRoot "Form.xml"
            $baseForm = @"
<Form>
  <Items>
    <Item name="One" />
    <Item name="Two" />
    <Item name="Three" />
    <Item name="Four" />
    <Item name="Five" />
    <Item name="Six" />
    <Item name="Seven" />
    <Item name="Eight" />
    <Item name="Nine" />
    <Item name="Ten" />
  </Items>
</Form>
"@
            [System.IO.File]::WriteAllText($formPath, $baseForm, [System.Text.UTF8Encoding]::new($false))
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot config core.autocrlf false
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M master

            $sharedItem = '    <Item name="Shared" />'
            & git -C $tempRoot checkout --quiet -b itldev/test
            [System.IO.File]::WriteAllText($formPath, $baseForm.Replace('    <Item name="Two" />', "$sharedItem`r`n    <Item name=""Two"" />"), [System.Text.UTF8Encoding]::new($false))
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "branch form move" *> $null
            $branchCommit = (& git -C $tempRoot rev-parse HEAD).Trim()

            & git -C $tempRoot checkout --quiet master
            [System.IO.File]::WriteAllText($formPath, $baseForm.Replace('    <Item name="Nine" />', "$sharedItem`r`n    <Item name=""Nine"" />"), [System.Text.UTF8Encoding]::new($false))
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "master form move" *> $null
            $targetCommit = (& git -C $tempRoot rev-parse HEAD).Trim()
            & git -C $tempRoot checkout --quiet itldev/test

            $configurationValidatorPath = Join-Path $validatorRoot "cf-validate.ps1"
            [System.IO.File]::WriteAllText($configurationValidatorPath, @'
param([string]$ConfigPath, [int]$MaxErrors, [string]$OutFile)
[System.IO.File]::WriteAllText($OutFile, "=== Validation OK ===", [System.Text.UTF8Encoding]::new($true))
exit 0
'@, [System.Text.UTF8Encoding]::new($false))
            $formValidatorPath = Join-Path $validatorRoot "form-validate.ps1"
            [System.IO.File]::WriteAllText($formValidatorPath, @'
param([string]$FormPath, [int]$MaxErrors)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$source = [System.IO.File]::ReadAllText($FormPath, [System.Text.Encoding]::UTF8)
$count = [regex]::Matches($source, '<Item name="Shared"').Count
if ($count -gt 1) {
    Write-Output "[ERROR] Duplicate form item Shared"
    exit 1
}
Write-Output "=== Validation OK ==="
exit 0
'@, [System.Text.UTF8Encoding]::new($false))
            Add-Content -LiteralPath (Join-Path $tempRoot ".git\info\exclude") -Encoding UTF8 -Value "tools с пробелом/"

            return [pscustomobject]@{
                root = $tempRoot
                branchCommit = $branchCommit
                targetCommit = $targetCommit
                formPath = $formPath
                formRepoPath = "src/cf/CommonForms/ОбщаяФорма/Ext/Form.xml"
                configurationValidatorPath = $configurationValidatorPath
                formValidatorPath = $formValidatorPath
            }
        }

        function Copy-AutoUpdateToolFixture {
            param([string]$TargetRoot)
            $target = Join-Path $TargetRoot ".agents\skills\1c-workflow\tools\auto-update"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\tools\auto-update") -Destination $target -Recurse

            $fakePlatform = Join-Path $TargetRoot "source-base\test-platform\1cv8.cmd"
            $fakeThinPlatform = Join-Path $TargetRoot "source-base\test-platform\1cv8c.cmd"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fakePlatform) | Out-Null
            Set-Content -LiteralPath $fakePlatform -Encoding ASCII -Value "@exit /b 0"
            Set-Content -LiteralPath $fakeThinPlatform -Encoding ASCII -Value "@exit /b 0"
            return $fakePlatform
        }

        function New-ItlOnDemandMcpInstallFixture {
            param([string]$TargetRoot)

            $lock = Get-Content -LiteralPath (Join-Path $RepoRoot "templates\dependency-lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $entry = $lock.dependencies.itlOndemandMcp
            $installRoot = Join-Path $TargetRoot "ondemand"
            $assetPath = Join-Path (Join-Path $installRoot ([string]$entry.version)) ([string]$entry.assetName)
            $oldGoProxy = $env:GOPROXY
            $oldGoSumDb = $env:GOSUMDB
            $oldGoToolchain = $env:GOTOOLCHAIN
            try {
                $env:GOPROXY = "off"
                $env:GOSUMDB = "off"
                $env:GOTOOLCHAIN = "local"
                $build = @(& (Join-Path $RepoRoot "scripts\Build-ItlOnDemandMcp.ps1") -OutputPath $assetPath -SkipTests)
            } finally {
                $env:GOPROXY = $oldGoProxy
                $env:GOSUMDB = $oldGoSumDb
                $env:GOTOOLCHAIN = $oldGoToolchain
            }
            if ($build.Count -ne 1 -or [string]$build[0].sha256 -cne [string]$entry.sha256) {
                throw "ITL_ONDEMAND_TEST_FIXTURE_HASH_MISMATCH expected='$($entry.sha256)' actual='$($build[0].sha256)'"
            }
            return $installRoot
        }
    }
    It "normalizes existing paths and not-yet-created children through the nearest existing ancestor" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-path-normalization-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $expectedRoot = (Get-Item -LiteralPath $tempRoot).FullName
            $missingChild = Join-Path (Join-Path $tempRoot ".") "missing\child"
            $expectedChild = Join-Path $expectedRoot "missing\child"

            & {
                . $HelperPath -ProjectRoot (Join-Path $tempRoot ".") -Action help *> $null

                Resolve-Agent1cFullPath -Path (Join-Path $tempRoot ".") | Should -Be $expectedRoot
                Resolve-Agent1cFullPath -Path $missingChild | Should -Be $expectedChild
                Get-FullPathNormalized -Path ($expectedRoot + "\") | Should -Be $expectedRoot
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "normalizes Git -C roots before invoking git" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-git-root-normalization-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $expectedRoot = (Get-Item -LiteralPath $tempRoot).FullName

            & {
                . $HelperPath -ProjectRoot (Join-Path $tempRoot ".") -Action help *> $null
                $script:CapturedGitArgs = @()
                function git {
                    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments)
                    $script:CapturedGitArgs = @($Arguments | ForEach-Object { [string]$_ })
                    $global:LASTEXITCODE = 0
                    return @()
                }

                Invoke-GitCommand -Root (Join-Path $tempRoot ".") -Arguments @("status")

                $script:CapturedGitArgs[0] | Should -Be "-C"
                $script:CapturedGitArgs[1] | Should -Be $expectedRoot
                $script:CapturedGitArgs[2] | Should -Be "status"
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "accepts actual Windows 8.3 short paths when available" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl short path normalization " + [guid]::NewGuid().ToString("N"))
        $projectRoot = Join-Path $tempRoot "project folder"

        try {
            New-Item -ItemType Directory -Force -Path $projectRoot | Out-Null
            $shortProjectRoot = Get-TestShortPath -Path $projectRoot
            if (-not $shortProjectRoot) {
                if (Get-Command Set-ItResult -ErrorAction SilentlyContinue) {
                    Set-ItResult -Skipped -Because "Windows 8.3 short paths are not available for this test directory."
                }
                return
            }

            $statusPath = Join-Path $tempRoot "status.json"
            $logPath = Join-Path $tempRoot "console.log"
            $result = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @(
                "-ProjectRoot", $shortProjectRoot,
                "-Action", "help",
                "-RunStatusPath", $statusPath,
                "-RunLogPath", $logPath
            )

            $result.exitCode | Should -Be 0
            $status = Get-Content -Encoding UTF8 -Raw -LiteralPath $statusPath | ConvertFrom-Json
            $status.projectRoot | Should -Be (Get-Item -LiteralPath $projectRoot).FullName
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
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

    It "serializes launcher-list mutations with a dedicated cross-process file lock" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-launcher-lock-test-" + [guid]::NewGuid().ToString("N"))
        try {
            $listPath = Join-Path $tempRoot "1C\1CEStart\ibases.v8i"
            $firstLock = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                Enter-LauncherListLock -ListPath $listPath -TimeoutSeconds 1
            }
            try {
                {
                    & {
                        . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                        $secondLock = Enter-LauncherListLock -ListPath $listPath -TimeoutSeconds 1
                        $secondLock.Dispose()
                    }
                } | Should -Throw "LAUNCHER_LIST_LOCK_TIMEOUT*"
            } finally {
                $firstLock.Dispose()
            }

            $reacquired = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                Enter-LauncherListLock -ListPath $listPath -TimeoutSeconds 1
            }
            $reacquired | Should -Not -BeNullOrEmpty
            $reacquired.Dispose()

            $HelperText | Should -Match '(?s)function Register-DevBranchInLauncher\s*\{.*?Enter-LauncherListLock.*?Register-DevBranchInLauncherUnlocked.*?finally\s*\{\s*\$listLock\.Dispose\(\)'
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "copies both dev branch auto-update EPFs but launches only the main EPF after a real load" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-auto-update-epf-test-" + [guid]::NewGuid().ToString("N"))

        try {
            $sourceRoot = Join-Path $tempRoot ".agents\skills\1c-workflow\tools\auto-update"
            New-Item -ItemType Directory -Force -Path $sourceRoot | Out-Null

            & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $script:mainEpfName = Get-DevBranchAutoUpdateMainEpfName
                $script:deferredEpfName = Get-DevBranchAutoUpdateDeferredHandlersEpfName
            }

            Set-Content -LiteralPath (Join-Path $sourceRoot $script:mainEpfName) -Value "main" -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $sourceRoot $script:deferredEpfName) -Value "deferred" -Encoding UTF8

            $enterpriseCalls = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Get-SourceInfoBasePath { return "C:\bases\source" }

                $script:EnterpriseCalls = @()
                function Invoke-Enterprise {
                    param(
                        [string]$InfoBasePath,
                        [string]$InfoBaseKind,
                        [string[]]$EnterpriseArgs,
                        [int]$TimeoutSeconds
                    )
                    $script:LastLogPath = "C:\logs\enterprise-auto-update.log"
                    $script:EnterpriseCalls += [pscustomobject]@{
                        infoBasePath = $InfoBasePath
                        infoBaseKind = $InfoBaseKind
                        enterpriseArgs = @($EnterpriseArgs)
                        timeoutSeconds = $TimeoutSeconds
                    }
                }

                $state = [pscustomobject]@{
                    devBranchInfoBasePath = "C:\bases\branch"
                    infoBaseKind = "file"
                }
                $updates = @{}
                $loadResult = [pscustomobject]@{
                    loaded = $true
                    currentCommit = "abc"
                    listFile = "C:\logs\list.txt"
                    lastLogPath = "C:\logs\designer.log"
                }

                Invoke-DevBranchEnterpriseAutoUpdateIfLoaded -State $state -LoadResult $loadResult -Updates $updates

                [pscustomobject]@{
                    calls = @($script:EnterpriseCalls)
                    updates = $updates
                    mainEpf = Get-DevBranchAutoUpdateMainEpfName
                    deferredEpf = Get-DevBranchAutoUpdateDeferredHandlersEpfName
                    installRoot = Get-DevBranchAutoUpdateInstallRoot
                }
            }

            @($enterpriseCalls.calls).Count | Should -Be 1
            $enterpriseCalls.calls[0].infoBasePath | Should -Be "C:\bases\branch"
            $enterpriseCalls.calls[0].infoBaseKind | Should -Be "file"
            $enterpriseCalls.calls[0].enterpriseArgs | Should -Contain "/Execute"
            $enterpriseCalls.calls[0].enterpriseArgs[1] | Should -Be (Join-Path $enterpriseCalls.installRoot $enterpriseCalls.mainEpf)
            $enterpriseCalls.calls[0].enterpriseArgs[1] | Should -Not -Be (Join-Path $enterpriseCalls.installRoot $enterpriseCalls.deferredEpf)
            $enterpriseCalls.calls[0].timeoutSeconds | Should -Be 900
            $enterpriseCalls.updates["lastEnterpriseAutoUpdateLogPath"] | Should -Be "C:\logs\enterprise-auto-update.log"
            Test-Path -LiteralPath (Join-Path $enterpriseCalls.installRoot $enterpriseCalls.mainEpf) -PathType Leaf | Should -Be $true
            Test-Path -LiteralPath (Join-Path $enterpriseCalls.installRoot $enterpriseCalls.deferredEpf) -PathType Leaf | Should -Be $true
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "does not launch dev branch Enterprise auto-update after a no-op load" {
        $enterpriseCalls = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null

            $script:EnterpriseCallCount = 0
            function Invoke-DevBranchEnterpriseAutoUpdate {
                param([object]$State)
                $script:EnterpriseCallCount += 1
            }

            $updates = @{}
            $loadResult = [pscustomobject]@{
                loaded = $false
                currentCommit = "abc"
                listFile = ""
                lastLogPath = ""
            }
            Invoke-DevBranchEnterpriseAutoUpdateIfLoaded -State ([pscustomobject]@{}) -LoadResult $loadResult -Updates $updates
            [pscustomobject]@{
                callCount = $script:EnterpriseCallCount
                updateCount = $updates.Count
            }
        }

        $enterpriseCalls.callCount | Should -Be 0
        $enterpriseCalls.updateCount | Should -Be 0
    }

    It "propagates dev branch Enterprise auto-update failures" {
        $errorText = ""
        try {
            & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                function Get-SourceInfoBasePath { return "C:\bases\source" }

                function Invoke-DevBranchEnterpriseAutoUpdate {
                    param([object]$State)
                    throw "auto-update failed"
                }

                $updates = @{}
                $loadResult = [pscustomobject]@{
                    loaded = $true
                    currentCommit = "abc"
                    listFile = "C:\logs\list.txt"
                    lastLogPath = "C:\logs\designer.log"
                }
                $state = [pscustomobject]@{ devBranchInfoBasePath = "C:\bases\branch"; infoBaseKind = "file" }
                Invoke-DevBranchEnterpriseAutoUpdateIfLoaded -State $state -LoadResult $loadResult -Updates $updates
            }
        } catch {
            $errorText = $_.Exception.Message
        }

        $errorText | Should -Match "auto-update failed"
    }

    It "normalizes a legacy branch once and rejects the source infobase" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:Calls = 0
            function Get-SourceInfoBasePath { return "C:\bases\source" }
            function Invoke-DevBranchEnterpriseAutoUpdate {
                param([object]$State)
                $script:Calls++
                [pscustomobject]@{ epfPath = "C:\tools\auto.epf"; logPath = "C:\logs\enterprise.log"; updatedAt = "2026-07-13T12:00:00+03:00" }
            }
            $updates = @{}
            $state = [pscustomobject]@{ devBranchInfoBasePath = "C:\bases\branch"; infoBaseKind = "file" }
            Ensure-DevBranchEnterpriseNormalized -State $state -Reason legacy-preflight -Updates $updates 6>$null | Out-Null
            [pscustomobject]@{ calls = $script:Calls; updates = $updates }
        }
        $result.calls | Should -Be 1
        $result.updates.enterpriseNormalizationStatus | Should -Be "passed"
        $result.updates.enterpriseNormalizationReason | Should -Be "legacy-preflight"
        $result.updates.lastEnterpriseAutoUpdateLogPath | Should -Be "C:\logs\enterprise.log"

        $errorText = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-SourceInfoBasePath { return "C:\bases\source" }
            try {
                Ensure-DevBranchEnterpriseNormalized -State ([pscustomobject]@{ devBranchInfoBasePath = "C:\bases\source"; infoBaseKind = "file" }) -Reason branch-copy -Updates @{} | Out-Null
            } catch { $_.Exception.Message }
        }
        $errorText | Should -Match "target is the source infobase"
    }

    It "persists passed Enterprise normalization evidence before later refresh work can fail" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-normalization-evidence-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $statePath = Join-Path $tempRoot "branch.json"
            Set-Content -LiteralPath $statePath -Encoding UTF8 -Value "{}"
            $result = & {
                param($StatePath)
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $script:PersistedStatuses = [System.Collections.Generic.List[string]]::new()
                function Get-SourceInfoBasePath { return "C:\bases\source" }
                function Invoke-DevBranchEnterpriseAutoUpdate {
                    [pscustomobject]@{ epfPath = "C:\tools\auto.epf"; logPath = "C:\logs\current-enterprise.log"; updatedAt = "2026-08-31T18:00:48+03:00" }
                }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    if ($Updates.ContainsKey("enterpriseNormalizationStatus")) {
                        $script:PersistedStatuses.Add([string]$Updates.enterpriseNormalizationStatus) | Out-Null
                    }
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $State.PSObject.Properties[$key]) {
                            $State | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $State.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                $state = [pscustomobject]@{ statePath = $StatePath; devBranchInfoBasePath = "C:\bases\branch"; infoBaseKind = "file" }
                $updates = @{}
                Ensure-DevBranchEnterpriseNormalized -State $state -Reason config-load -Updates $updates 6>$null | Out-Null
                try { throw "simulated later runner failure" } catch {}
                [pscustomobject]@{
                    statuses = @($script:PersistedStatuses)
                    persistedStatus = $state.enterpriseNormalizationStatus
                    persistedAt = $state.enterpriseNormalizedAt
                    persistedLog = $state.lastEnterpriseAutoUpdateLogPath
                    pendingUpdatesStatus = $updates.enterpriseNormalizationStatus
                }
            } $statePath

            $result.statuses | Should -Be @("pending", "passed")
            $result.persistedStatus | Should -Be "passed"
            $result.persistedAt | Should -Be "2026-08-31T18:00:48+03:00"
            $result.persistedLog | Should -Be "C:\logs\current-enterprise.log"
            $result.pendingUpdatesStatus | Should -Be "passed"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "accepts branch reset as an Enterprise normalization reason" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-SourceInfoBasePath { return "C:\bases\source" }
            function Invoke-DevBranchEnterpriseAutoUpdate {
                param([object]$State)
                [pscustomobject]@{ epfPath = "C:\tools\auto.epf"; logPath = "C:\logs\enterprise.log"; updatedAt = "2026-08-25T12:00:00+03:00" }
            }
            $updates = @{}
            $state = [pscustomobject]@{ devBranchInfoBasePath = "C:\bases\branch"; infoBaseKind = "file" }
            Ensure-DevBranchEnterpriseNormalized -State $state -Reason branch-reset -Updates $updates 6>$null | Out-Null
            $updates
        }

        $result.enterpriseNormalizationStatus | Should -Be "passed"
        $result.enterpriseNormalizationReason | Should -Be "branch-reset"
    }

    It "blocks managed application startup when current sources are not loaded" {
        $message = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-ExportPath { "src/cf" }
            function Get-DevBranchKind { "configuration" }
            function Get-ConfigSourceFingerprint {
                [pscustomobject]@{ fingerprint = "fingerprint-b"; treeObjectId = ("b" * 40) }
            }
            function Ensure-DevBranchEnterpriseNormalized { throw "normalization must not run for mismatched sources" }
            $state = [pscustomobject]@{
                lastConfigDesignerFingerprint = "fingerprint-a"
                lastConfigDesignerTreeObjectId = ("a" * 40)
                configLoadStatus = "passed"
                enterpriseNormalizationStatus = "passed"
            }
            try { Assert-DevBranchApplicationReady -State $state -Operation "ROCTUP" | Out-Null; "" } catch { $_.Exception.Message }
        }

        $message | Should -Match '^ITL_INFOBASE_APPLICATION_NOT_READY:'
        $message | Should -Match 'configuration-fingerprint-mismatch'
        $message | Should -Match 'requiredAction=update-dev-branch-base'
    }

    It "classifies application readiness failures with the existing lifecycle recovery" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:RunErrorCategory = ""
            $script:RunRequiredAction = ""
            Set-RunFailureContextFromMessage `
                -Message "ITL_INFOBASE_APPLICATION_NOT_READY: reasons='configuration-fingerprint-mismatch'" `
                -RequestedAction "status"
            [pscustomobject]@{ category = $script:RunErrorCategory; requiredAction = $script:RunRequiredAction }
        }

        $result.category | Should -Be "infobase-readiness"
        $result.requiredAction | Should -Be "update-dev-branch-base"
    }

    It "routes failed check config loads to verification repair without suggesting refresh recovery" {
        $message = "ITL_CONFIG_LOAD_FAILED: partial and full fallback config loads both failed. Inspect and correct the reported configuration source error, then repeat /itl-check. Do not run refresh-dev-branch or sync-master as recovery."
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:RunErrorCategory = ""
            $script:RunRequiredAction = ""
            Set-RunFailureContextFromMessage -Message $message -RequestedAction "check-dev-branch"
            [pscustomobject]@{ category = $script:RunErrorCategory; requiredAction = $script:RunRequiredAction }
        }

        $result.category | Should -Be "config-load-failed"
        $result.requiredAction | Should -Be "/itl-verify-fix"
        $result.requiredAction | Should -Not -Match "refresh|sync-master"
        $HelperText | Should -Not -Match "safe recovery is to recreate its copy"
        $HelperText | Should -Match "Do not run refresh-dev-branch or sync-master as recovery"
    }

    It "does not use the Designer tree cursor as application readiness evidence" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-ExportPath { "src/cf" }
            function Get-DevBranchKind { "configuration" }
            function Get-ConfigSourceFingerprint {
                # A ConfigDumpInfo-only edit may change the raw Git tree while leaving
                # the effective configuration fingerprint unchanged.
                [pscustomobject]@{ fingerprint = "fingerprint-a"; treeObjectId = ("b" * 40) }
            }
            $state = [pscustomobject]@{
                lastConfigDesignerFingerprint = "fingerprint-a"
                lastConfigDesignerTreeObjectId = ("a" * 40)
                configLoadStatus = "passed"
                enterpriseNormalizationStatus = "passed"
            }
            Assert-DevBranchApplicationReady -State $state -Operation "ROCTUP"
        }

        $result.enterpriseNormalizationStatus | Should -Be "passed"
    }

    It "retries only pending Enterprise normalization when Designer proof matches" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:NormalizeCalls = 0
            function Get-ExportPath { "src/cf" }
            function Get-DevBranchKind { "configuration" }
            function Get-ConfigSourceFingerprint {
                [pscustomobject]@{ fingerprint = "fingerprint-a"; treeObjectId = ("a" * 40) }
            }
            function Ensure-DevBranchEnterpriseNormalized {
                param([object]$State)
                $script:NormalizeCalls++
                [pscustomobject]@{
                    lastConfigDesignerFingerprint = $State.lastConfigDesignerFingerprint
                    lastConfigDesignerTreeObjectId = $State.lastConfigDesignerTreeObjectId
                    configLoadStatus = "passed"
                    enterpriseNormalizationStatus = "passed"
                }
            }
            $state = [pscustomobject]@{
                lastConfigDesignerFingerprint = "fingerprint-a"
                lastConfigDesignerTreeObjectId = ("a" * 40)
                configLoadStatus = "passed"
                enterpriseNormalizationStatus = "pending"
            }
            $ready = Assert-DevBranchApplicationReady -State $state -Operation "TestClient"
            [pscustomobject]@{ calls = $script:NormalizeCalls; status = $ready.enterpriseNormalizationStatus }
        }

        $result.calls | Should -Be 1
        $result.status | Should -Be "passed"
    }

    It "keeps Enterprise normalization as the final resumable branch initialization step" {
        $initStart = $HelperText.IndexOf('function Initialize-DevBranchRuntime')
        $initBlock = $HelperText.Substring($initStart, $HelperText.IndexOf('function Get-DevWorkspacePlan', $initStart) - $initStart)
        $repositoryUnboundIndex = $initBlock.LastIndexOf('-Status "repository-unbound"')
        $protectionIndex = $initBlock.LastIndexOf('Resolve-DevBranchUnsafeActionProtectionState')
        $protectionStateIndex = $initBlock.LastIndexOf('-Status "unsafe-action-protection-resolved"')
        $launcherIndex = $initBlock.LastIndexOf('Register-DevBranchInLauncher')
        $baselineIndex = $initBlock.LastIndexOf('Initialize-DevBranchEventLogBaseline')
        $pendingIndex = $initBlock.LastIndexOf('-Status "enterprise-normalization-pending"')
        $normalizeIndex = $initBlock.LastIndexOf('Ensure-DevBranchEnterpriseNormalized -State $state -Reason "branch-copy"')
        $dataMcpIndex = $initBlock.LastIndexOf('Invoke-DevBranchDataMcpAfterPublication')
        $surfaceIndex = $initBlock.LastIndexOf('Sync-KiloItlCommandSurface')
        $readyIndex = $initBlock.LastIndexOf('-Status "ready"')
        $repositoryUnboundIndex | Should -BeGreaterThan -1
        $protectionIndex | Should -BeGreaterThan $repositoryUnboundIndex
        $protectionStateIndex | Should -BeGreaterThan $protectionIndex
        $launcherIndex | Should -BeGreaterThan $protectionStateIndex
        $baselineIndex | Should -BeGreaterThan -1
        $pendingIndex | Should -BeGreaterThan $baselineIndex
        $normalizeIndex | Should -BeGreaterThan $pendingIndex
        $dataMcpIndex | Should -BeGreaterThan $normalizeIndex
        $surfaceIndex | Should -BeGreaterThan $dataMcpIndex
        $readyIndex | Should -BeGreaterThan $surfaceIndex
        $initBlock | Should -Match 'Resuming final Enterprise normalization for existing development branch copy'
        $initBlock | Should -Match '\$branchCopyMayUseRepository = \$sourceUsesRepository -or \$configuredSourceUsesRepository'
        $initBlock | Should -Match 'if \(\$branchCopyMayUseRepository -and -not \$repositoryUnbound\)'
        $initBlock | Should -Match 'enterpriseNormalizationStatus'
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
            $baseTree = ((& git -C $tempRoot rev-parse "${baseCommit}:src/cf") -join "").Trim()

            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Value "<Configuration changed=`"true`" />" -Encoding UTF8
            $trackedEnumName = "СѓРїРѕ_РџРѕРІРµРґРµРЅРёРµРџСЂРёР—Р°РіСЂСѓР·РєРµРќРµСЂР°СЃСЃС‡РёС‚Р°РЅРЅРѕР№Р’РµСЂСЃРёРё.xml"
            $untrackedEnumName = "СѓРїРѕ_РџРѕРІРµРґРµРЅРёРµРџСЂРёР—Р°РїРёСЃРёРќРµСЂР°СЃСЃС‡РёС‚Р°РЅРЅРѕР№Р’РµСЂСЃРёРё.xml"
            $spacedModuleName = "РњРѕРґСѓР»СЊ СЃ РїСЂРѕР±РµР»РѕРј.xml"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Enums\$trackedEnumName") -Value "<Enum />" -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Enums\$untrackedEnumName") -Value "<Enum />" -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\CommonModules\$spacedModuleName") -Value "<CommonModule />" -Encoding UTF8
            & git -C $tempRoot add -- "src/cf/Enums/$trackedEnumName" "src/cf/CommonModules/$spacedModuleName"

            $changeSet = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Get-ConfigLoadChangeSet -State ([pscustomobject]@{ lastConfigDesignerTreeObjectId = $baseTree }) -ExportPath "src/cf"
            }

            $expectedFiles = @(
                "Configuration.xml",
                (Join-Path "CommonModules" $spacedModuleName),
                (Join-Path "Enums" $trackedEnumName),
                (Join-Path "Enums" $untrackedEnumName)
            )
            $normalizedFiles = @($changeSet.files | ForEach-Object { ([string]$_).Replace('/', '\') })
            foreach ($expectedFile in $expectedFiles) {
                $normalizedFiles | Should -Contain $expectedFile
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

    It "marks a missing Unicode root file in the exact partial-load inventory" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-missing-config-root-" + [guid]::NewGuid().ToString("N"))

        try {
            $catalogsPath = Join-Path $tempRoot "src\cf\Catalogs"
            New-Item -ItemType Directory -Force -Path $catalogsPath | Out-Null
            $missingRelativePath = "Catalogs\Каталог с пробелом.xml"
            $missingAbsolutePath = Join-Path (Join-Path $tempRoot "src\cf") $missingRelativePath
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Value "<Configuration />" -Encoding UTF8
            Set-Content -LiteralPath $missingAbsolutePath -Value "<Catalog />" -Encoding UTF8

            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add -- src/cf
            & git -C $tempRoot commit -m "base config" *> $null
            $baseCommit = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()
            $baseTree = ((& git -C $tempRoot rev-parse "${baseCommit}:src/cf") -join "").Trim()
            Remove-Item -LiteralPath $missingAbsolutePath -Force

            $changeSet = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Get-ConfigLoadChangeSet -State ([pscustomobject]@{ lastConfigDesignerTreeObjectId = $baseTree }) -ExportPath "src/cf"
            }

            @($changeSet.files | ForEach-Object { ([string]$_).Replace('/', '\') }) | Should -Contain $missingRelativePath
            @($changeSet.missingFiles | ForEach-Object { ([string]$_).Replace('/', '\') }) | Should -Be @($missingRelativePath)
            $changeSet.requiresFullLoad | Should -BeTrue
            $changeSet.fullLoadReason | Should -Be "designer-tree-deletion-detected"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "treats empty Git path list output as an empty array" {
        $tempParent = Join-Path ([System.IO.Path]::GetTempPath()) ("itl git paths parent " + [guid]::NewGuid().ToString("N"))
        $tempRoot = Join-Path $tempParent "РїСЂРѕРµРєС‚ СЃ РїСЂРѕР±РµР»РѕРј"

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

    It "validates and applies a local dev branch auto-update timeout" {
        $oldTimeout = $env:DEV_BRANCH_AUTO_UPDATE_TIMEOUT_SECONDS
        try {
            $env:DEV_BRANCH_AUTO_UPDATE_TIMEOUT_SECONDS = "60"
            $value = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                Get-DevBranchAutoUpdateTimeoutSeconds
            }
            $value | Should -Be 60

            $env:DEV_BRANCH_AUTO_UPDATE_TIMEOUT_SECONDS = "0"
            {
                & {
                    . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                    Get-DevBranchAutoUpdateTimeoutSeconds
                }
            } | Should -Throw "*must be a positive integer*"
        } finally {
            $env:DEV_BRANCH_AUTO_UPDATE_TIMEOUT_SECONDS = $oldTimeout
        }
    }

    It "blocks changed configuration source before runtime drain or Designer when root validation fails" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:ValidationCalls = 0
            $script:ValidationRelativePaths = @()
            $script:DrainCalls = 0
            $script:DesignerCalls = 0
            function Get-CurrentCommit { "head" }
            function Get-ConfigSourceFingerprint { [pscustomobject]@{ fingerprint = "changed"; fileCount = 1; absoluteExportPath = "C:\project\src\cf" } }
            function Get-ConfigLoadChangeSet { [pscustomobject]@{ files = @("Configuration.xml"); missingFiles = @(); baseCommit = "base"; currentCommit = "head"; absoluteExportPath = "C:\project\src\cf" } }
            function Assert-OneCConfigurationSourceIntegrity {
                param([string]$ExportPath, [string[]]$AdditionalRelativePaths)
                $script:ValidationCalls++
                $script:ValidationRelativePaths = @($AdditionalRelativePaths)
                throw "ONEC_SOURCE_INTEGRITY_FAILED fixture"
            }
            function Stop-DevBranchRuntimeBeforeInfobaseMutation { $script:DrainCalls++ }
            function Invoke-Designer { $script:DesignerCalls++ }
            $message = ""
            try {
                Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind file -State ([pscustomobject]@{}) -ExportPath "src/cf" 6>$null | Out-Null
            } catch {
                $message = $_.Exception.Message
            }
            [pscustomobject]@{
                message = $message
                validationCalls = $script:ValidationCalls
                validationRelativePaths = $script:ValidationRelativePaths
                drainCalls = $script:DrainCalls
                designerCalls = $script:DesignerCalls
            }
        }

        $result.message | Should -Be "ONEC_SOURCE_INTEGRITY_FAILED fixture"
        $result.validationCalls | Should -Be 1
        $result.validationRelativePaths | Should -Be @("Configuration.xml")
        $result.drainCalls | Should -Be 0
        $result.designerCalls | Should -Be 0
    }

    It "keeps root Configuration.xml in the exact partial load list" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null

            $script:CapturedDesignerArgs = @()
            function Get-ConfigSourceFingerprint { [pscustomobject]@{ fingerprint = "fingerprint-a"; fileCount = 1; absoluteExportPath = "C:\project\src\cf" } }
            function Get-ConfigLoadChangeSet {
                return [pscustomobject]@{
                    files = @("Configuration.xml")
                    baseCommit = "base"
                    currentCommit = "head"
                    absoluteExportPath = "C:\project\src\cf"
                }
            }
            function New-ConfigLoadListFile { return "C:\logs\changed-files.txt" }
            function Assert-OneCConfigurationSourceIntegrity {}
            function Stop-DevBranchRuntimeBeforeInfobaseMutation {}
            function Invoke-Designer {
                param(
                    [string]$InfoBasePath,
                    [string]$InfoBaseKind,
                    [string[]]$DesignerArgs
                )
                $script:CapturedDesignerArgs = @($DesignerArgs)
            }

            $loadResult = Load-ConfigFromFiles `
                -InfoBasePath "C:\base" `
                -InfoBaseKind "file" `
                -State ([pscustomobject]@{}) `
                -ExportPath "src/cf" 6>$null

            [pscustomobject]@{
                args = @($script:CapturedDesignerArgs)
                listFile = $loadResult.listFile
            }
        }

        $result.args | Should -Contain "/LoadConfigFromFiles"
        $result.args | Should -Contain "-listFile"
        $result.args | Should -Contain "C:\logs\changed-files.txt"
        $result.args | Should -Contain "-partial"
        $result.args | Should -Contain "-updateConfigDumpInfo"
        $result.args | Should -Contain "/UpdateDBCfg"
        $result.listFile | Should -Be "C:\logs\changed-files.txt"
    }

    It "keeps partial files load for non-root configuration changes" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null

            $script:CapturedDesignerArgs = @()
            function Get-ConfigSourceFingerprint { [pscustomobject]@{ fingerprint = "fingerprint-b"; fileCount = 1; absoluteExportPath = "C:\project\src\cf" } }
            function Get-ConfigLoadChangeSet {
                return [pscustomobject]@{
                    files = @("CommonModules\WorkflowE2E.xml")
                    baseCommit = "base"
                    currentCommit = "head"
                    absoluteExportPath = "C:\project\src\cf"
                }
            }
            function New-ConfigLoadListFile { return "C:\logs\changed-files.txt" }
            function Assert-OneCConfigurationSourceIntegrity {}
            function Stop-DevBranchRuntimeBeforeInfobaseMutation {}
            function Invoke-Designer {
                param(
                    [string]$InfoBasePath,
                    [string]$InfoBaseKind,
                    [string[]]$DesignerArgs
                )
                $script:CapturedDesignerArgs = @($DesignerArgs)
            }

            Load-ConfigFromFiles `
                -InfoBasePath "C:\base" `
                -InfoBaseKind "file" `
                -State ([pscustomobject]@{}) `
                -ExportPath "src/cf" 6>$null | Out-Null

            @($script:CapturedDesignerArgs)
        }

        $result | Should -Contain "-listFile"
        $result | Should -Contain "C:\logs\changed-files.txt"
        $result | Should -Contain "-partial"
        $result | Should -Contain "-updateConfigDumpInfo"
        $result | Should -Contain "/UpdateDBCfg"
    }

    It "skips partial Designer startup and uses a full load for missing inventory files" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null

            $script:DesignerCalls = @()
            $script:DrainCalls = 0
            $missingPath = "Catalogs\Каталог с пробелом.xml"
            function Get-ConfigSourceFingerprint { [pscustomobject]@{ fingerprint = "fingerprint-missing"; fileCount = 2; absoluteExportPath = "C:\project with spaces\src\cf" } }
            function Get-ConfigLoadChangeSet {
                [pscustomobject]@{
                    files = @("Configuration.xml", $missingPath)
                    missingFiles = @($missingPath)
                    baseCommit = "base"
                    currentCommit = "head"
                    absoluteExportPath = "C:\project with spaces\src\cf"
                }
            }
            function New-ConfigLoadListFile { throw "partial list must not be created" }
            function Assert-OneCConfigurationSourceIntegrity {}
            function Stop-DevBranchRuntimeBeforeInfobaseMutation { $script:DrainCalls++ }
            function Invoke-Designer {
                param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs)
                $script:DesignerCalls += , @($DesignerArgs)
                $script:LastLogPath = "C:\logs\full.log"
            }

            $load = Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind file -State ([pscustomobject]@{}) -ExportPath "src/cf" 3>$null 6>$null
            [pscustomobject]@{ calls = @($script:DesignerCalls); drains = $script:DrainCalls; load = $load }
        }

        $result.calls.Count | Should -Be 1
        $result.calls[0] | Should -Not -Contain "-listFile"
        $result.calls[0] | Should -Not -Contain "-partial"
        $result.calls[0] | Should -Contain "-updateConfigDumpInfo"
        $result.drains | Should -Be 1
        $result.load.listFile | Should -Be ""
        $result.load.loadModeUsed | Should -Be "full"
        $result.load.loadReason | Should -Be "partial-inventory-missing-files-full-load"
    }

    It "fails before list preparation, runtime drain, and Designer in explicit Partial mode" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null

            $script:DesignerCalls = 0
            $script:DrainCalls = 0
            $missingPath = "Catalogs\Каталог с пробелом.xml"
            function Get-ConfigSourceFingerprint { [pscustomobject]@{ fingerprint = "fingerprint-missing-partial"; fileCount = 2; absoluteExportPath = "C:\project with spaces\src\cf" } }
            function Get-ConfigLoadChangeSet {
                [pscustomobject]@{
                    files = @("Configuration.xml", $missingPath)
                    missingFiles = @($missingPath)
                    baseCommit = "base"
                    currentCommit = "head"
                    absoluteExportPath = "C:\project with spaces\src\cf"
                }
            }
            function New-ConfigLoadListFile { throw "partial list must not be created" }
            function Stop-DevBranchRuntimeBeforeInfobaseMutation { $script:DrainCalls++ }
            function Invoke-Designer { $script:DesignerCalls++ }

            $message = ""
            try {
                Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind file -State ([pscustomobject]@{}) -ExportPath "src/cf" -Mode Partial 6>$null | Out-Null
            } catch {
                $message = $_.Exception.Message
            }
            [pscustomobject]@{ designerCalls = $script:DesignerCalls; drainCalls = $script:DrainCalls; message = $message }
        }

        $result.designerCalls | Should -Be 0
        $result.drainCalls | Should -Be 0
        $result.message | Should -Match "^PARTIAL_CONFIG_LOAD_MISSING_FILES:"
        $result.message | Should -Match ([regex]::Escape("Catalogs\Каталог с пробелом.xml"))
    }

    It "drains workflow-owned runtime for the target infobase before starting Designer" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null

            $script:Sequence = @()
            $script:DrainPath = ""
            $script:DrainReason = ""
            function Get-ConfigSourceFingerprint { [pscustomobject]@{ fingerprint = "fingerprint-drain"; fileCount = 1; absoluteExportPath = "C:\project\src\cf" } }
            function Get-ConfigLoadChangeSet {
                [pscustomobject]@{
                    files = @("CommonModules\WorkflowE2E.xml")
                    baseCommit = "base"
                    currentCommit = "head"
                    absoluteExportPath = "C:\project\src\cf"
                }
            }
            function New-ConfigLoadListFile { "C:\logs\changed-files.txt" }
            function Assert-OneCConfigurationSourceIntegrity {}
            function Stop-DevBranchRuntimeBeforeInfobaseMutation {
                param([object]$State, [string]$Reason, [string]$InfoBasePath)
                $script:Sequence += "drain"
                $script:DrainPath = $InfoBasePath
                $script:DrainReason = $Reason
            }
            function Invoke-Designer {
                param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs)
                $script:Sequence += "designer"
            }

            Load-ConfigFromFiles `
                -InfoBasePath "C:\base" `
                -InfoBaseKind "file" `
                -State ([pscustomobject]@{}) `
                -ExportPath "src/cf" 6>$null | Out-Null

            [pscustomobject]@{
                sequence = @($script:Sequence)
                drainPath = $script:DrainPath
                drainReason = $script:DrainReason
            }
        }

        $result.sequence | Should -Be @("drain", "designer")
        $result.drainPath | Should -Be "C:\base"
        $result.drainReason | Should -Be "configuration source load"
    }

    It "fails closed before Designer when runtime drain cannot prove cleanup" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null

            $script:DesignerCallCount = 0
            function Get-ConfigSourceFingerprint { [pscustomobject]@{ fingerprint = "fingerprint-drain-failed"; fileCount = 1; absoluteExportPath = "C:\project\src\cf" } }
            function Get-ConfigLoadChangeSet {
                [pscustomobject]@{
                    files = @("CommonModules\WorkflowE2E.xml")
                    baseCommit = "base"
                    currentCommit = "head"
                    absoluteExportPath = "C:\project\src\cf"
                }
            }
            function New-ConfigLoadListFile { "C:\logs\changed-files.txt" }
            function Assert-OneCConfigurationSourceIntegrity {}
            function Stop-DevBranchRuntimeBeforeInfobaseMutation { throw "ITL_INFOBASE_RUNTIME_DRAIN_FAILED: ownership mismatch" }
            function Invoke-Designer { $script:DesignerCallCount++ }

            $message = ""
            try {
                Load-ConfigFromFiles `
                    -InfoBasePath "C:\base" `
                    -InfoBaseKind "file" `
                    -State ([pscustomobject]@{}) `
                    -ExportPath "src/cf" 6>$null | Out-Null
            } catch {
                $message = $_.Exception.Message
            }
            [pscustomobject]@{ calls = $script:DesignerCallCount; message = $message }
        }

        $result.calls | Should -Be 0
        $result.message | Should -Match "^ITL_INFOBASE_RUNTIME_DRAIN_FAILED"
    }

    It "falls back once to full load only after a partial Designer failure" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:DesignerCalls = @()
            function Get-ConfigSourceFingerprint { [pscustomobject]@{ fingerprint = "fingerprint-c"; fileCount = 2; absoluteExportPath = "C:\project\src\cf" } }
            function Get-ConfigLoadChangeSet {
                [pscustomobject]@{ files = @("Configuration.xml", "CommonModules\Модуль.xml"); baseCommit = "base"; currentCommit = "head"; absoluteExportPath = "C:\project\src\cf" }
            }
            function New-ConfigLoadListFile { return "C:\logs\changed-files.txt" }
            function Assert-OneCConfigurationSourceIntegrity {}
            function Stop-DevBranchRuntimeBeforeInfobaseMutation {}
            function Invoke-Designer {
                param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs)
                $script:DesignerCalls += , @($DesignerArgs)
                if ($script:DesignerCalls.Count -eq 1) {
                    $script:LastLogPath = "C:\logs\partial.log"
                    $script:LastNativeProcessStarted = $true
                    throw "partial failed"
                }
                $script:LastLogPath = "C:\logs\full.log"
            }

            $load = Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind "file" -State ([pscustomobject]@{}) -ExportPath "src/cf" 3>$null 6>$null
            [pscustomobject]@{ calls = @($script:DesignerCalls); load = $load }
        }

        $result.calls.Count | Should -Be 2
        $result.calls[0] | Should -Contain "-listFile"
        $result.calls[0] | Should -Contain "-partial"
        $result.calls[0] | Should -Contain "-updateConfigDumpInfo"
        $result.calls[1] | Should -Not -Contain "-listFile"
        $result.calls[1] | Should -Not -Contain "-partial"
        $result.calls[1] | Should -Contain "-updateConfigDumpInfo"
        $result.load.loadModeUsed | Should -Be "full-fallback"
        $result.load.configLoadStatus | Should -Be "fallback-succeeded"
        $result.load.partialLogPath | Should -Be "C:\logs\partial.log"
        $result.load.fullFallbackLogPath | Should -Be "C:\logs\full.log"
    }

    It "records both logs and leaves the loaded commit unchanged when fallback also fails" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:DesignerCallCount = 0
            $script:StateUpdates = @{}
            function Get-ConfigSourceFingerprint { [pscustomobject]@{ fingerprint = "fingerprint-d"; fileCount = 1; absoluteExportPath = "C:\project\src\cf" } }
            function Get-ConfigLoadChangeSet {
                [pscustomobject]@{ files = @("Configuration.xml"); baseCommit = "base"; currentCommit = "head"; absoluteExportPath = "C:\project\src\cf" }
            }
            function New-ConfigLoadListFile { return "C:\logs\changed-files.txt" }
            function Stop-DevBranchRuntimeBeforeInfobaseMutation {}
            function Invoke-Designer {
                param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs)
                $script:DesignerCallCount++
                $script:LastLogPath = if ($script:DesignerCallCount -eq 1) { "C:\logs\partial.log" } else { "C:\logs\full.log" }
                $script:LastNativeProcessStarted = $true
                throw "designer failure $script:DesignerCallCount"
            }
            function Update-DevBranchState {
                param([object]$State, [hashtable]$Updates)
                $script:StateUpdates = $Updates
            }
            function Assert-OneCConfigurationSourceIntegrity {}

            $message = ""
            try {
                Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind "file" -State ([pscustomobject]@{}) -ExportPath "src/cf" 3>$null 6>$null | Out-Null
            } catch { $message = $_.Exception.Message }
            [pscustomobject]@{ calls = $script:DesignerCallCount; updates = $script:StateUpdates; message = $message }
        }

        $result.calls | Should -Be 2
        $result.updates.configLoadStatus | Should -Be "fallback-failed"
        $result.updates.lastConfigPartialLogPath | Should -Be "C:\logs\partial.log"
        $result.updates.lastConfigFullFallbackLogPath | Should -Be "C:\logs\full.log"
        $result.updates.ContainsKey("lastConfigBaseUpdatedCommit") | Should -BeFalse
        $result.message | Should -Match "^ITL_CONFIG_LOAD_FAILED:"
        $result.message | Should -Match "repeat /itl-check"
        $result.message | Should -Match "Do not run refresh-dev-branch or sync-master as recovery"
        $result.message | Should -Not -Match "recreate its copy"
    }

    It "supports diagnostic Partial and emergency Full modes without crossing modes" {
        $partial = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:Calls = @()
            function Invoke-Designer {
                param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs)
                $script:Calls += , @($DesignerArgs)
                $script:LastNativeProcessStarted = $true
                throw "partial failed"
            }
            try { Invoke-ConfigLoadWithFallback -InfoBasePath "C:\base" -InfoBaseKind file -State ([pscustomobject]@{}) -AbsoluteExportPath "C:\src" -ListFilePath "C:\list.txt" -FileCount 1 -Mode Partial 6>$null | Out-Null } catch {}
            [pscustomobject]@{ calls = @($script:Calls) }
        }
        $partial.calls.Count | Should -Be 1
        $partial.calls[0] | Should -Contain "-listFile"
        $partial.calls[0] | Should -Contain "-partial"
        $partial.calls[0] | Should -Contain "-updateConfigDumpInfo"

        $full = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:Calls = @()
            function Invoke-Designer {
                param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs)
                $script:Calls += , @($DesignerArgs)
                $script:LastLogPath = "C:\logs\full.log"
            }
            $load = Invoke-ConfigLoadWithFallback -InfoBasePath "C:\base" -InfoBaseKind file -State ([pscustomobject]@{}) -AbsoluteExportPath "C:\src" -ListFilePath "C:\list.txt" -FileCount 1 -Mode Full 6>$null
            [pscustomobject]@{ calls = @($script:Calls); load = $load }
        }
        $full.calls.Count | Should -Be 1
        $full.calls[0] | Should -Not -Contain "-listFile"
        $full.calls[0] | Should -Not -Contain "-partial"
        $full.calls[0] | Should -Contain "-updateConfigDumpInfo"
        $full.load.loadModeUsed | Should -Be "full"
    }

    It "removes a stale ConfigDumpInfo cursor only for a restore-recovery full load" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-dump-info-reset-" + [guid]::NewGuid().ToString("N"))
        try {
            $exportPath = Join-Path $tempRoot "src\cf"
            New-Item -ItemType Directory -Force -Path $exportPath | Out-Null
            $dumpInfoPath = Join-Path $exportPath "ConfigDumpInfo.xml"
            Set-Content -LiteralPath $dumpInfoPath -Encoding UTF8 -Value "stale-cursor"

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $script:CursorExistedAtDesignerStart = $true
                function Invoke-Designer {
                    param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs)
                    $script:CursorExistedAtDesignerStart = Test-Path -LiteralPath $dumpInfoPath -PathType Leaf
                    Set-Content -LiteralPath $dumpInfoPath -Encoding UTF8 -Value "fresh-cursor"
                    $script:LastLogPath = "C:\logs\full.log"
                }
                $load = Invoke-ConfigLoadWithFallback -InfoBasePath "C:\base" -InfoBaseKind file -State ([pscustomobject]@{}) -AbsoluteExportPath $exportPath -ListFilePath "" -FileCount 1 -Mode Full -ResetConfigDumpInfo 6>$null
                [pscustomobject]@{
                    existedAtStart = $script:CursorExistedAtDesignerStart
                    cursor = (Get-Content -LiteralPath $dumpInfoPath -Raw).Trim()
                    load = $load
                }
            }

            $result.existedAtStart | Should -BeFalse
            $result.cursor | Should -Be "fresh-cursor"
            $result.load.loadModeUsed | Should -Be "full"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "restores ConfigDumpInfo when a cursor-free recovery load fails" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-dump-info-reset-fail-" + [guid]::NewGuid().ToString("N"))
        try {
            $exportPath = Join-Path $tempRoot "src\cf"
            New-Item -ItemType Directory -Force -Path $exportPath | Out-Null
            $dumpInfoPath = Join-Path $exportPath "ConfigDumpInfo.xml"
            Set-Content -LiteralPath $dumpInfoPath -Encoding UTF8 -Value "stale-cursor"

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $script:CursorExistedAtDesignerStart = $true
                function Invoke-Designer {
                    param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs)
                    $script:CursorExistedAtDesignerStart = Test-Path -LiteralPath $dumpInfoPath -PathType Leaf
                    throw "simulated full-load failure"
                }
                $message = ""
                try {
                    Invoke-ConfigLoadWithFallback -InfoBasePath "C:\base" -InfoBaseKind file -State ([pscustomobject]@{}) -AbsoluteExportPath $exportPath -ListFilePath "" -FileCount 1 -Mode Full -ResetConfigDumpInfo 6>$null | Out-Null
                } catch {
                    $message = $_.Exception.Message
                }
                [pscustomobject]@{
                    existedAtStart = $script:CursorExistedAtDesignerStart
                    cursor = (Get-Content -LiteralPath $dumpInfoPath -Raw).Trim()
                    message = $message
                }
            }

            $result.existedAtStart | Should -BeFalse
            $result.cursor | Should -Be "stale-cursor"
            $result.message | Should -Match "simulated full-load failure"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rolls ConfigDumpInfo back between a failed partial load and its full fallback" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-dump-info-fallback-" + [guid]::NewGuid().ToString("N"))
        try {
            $exportPath = Join-Path $tempRoot "src\cf"
            New-Item -ItemType Directory -Force -Path $exportPath | Out-Null
            $dumpInfoPath = Join-Path $exportPath "ConfigDumpInfo.xml"
            Set-Content -LiteralPath $dumpInfoPath -Encoding UTF8 -Value "original-cursor"

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $script:DesignerCallCount = 0
                $script:CursorSeenByFallback = ""
                function Invoke-Designer {
                    param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs)
                    $script:DesignerCallCount++
                    $script:LastNativeProcessStarted = $true
                    if ($script:DesignerCallCount -eq 1) {
                        Set-Content -LiteralPath $dumpInfoPath -Encoding UTF8 -Value "partial-cursor"
                        throw "partial failed"
                    }
                    $script:CursorSeenByFallback = (Get-Content -LiteralPath $dumpInfoPath -Raw).Trim()
                    Set-Content -LiteralPath $dumpInfoPath -Encoding UTF8 -Value "full-cursor"
                }

                $load = Invoke-ConfigLoadWithFallback `
                    -InfoBasePath "C:\base" `
                    -InfoBaseKind file `
                    -State ([pscustomobject]@{}) `
                    -AbsoluteExportPath $exportPath `
                    -ListFilePath "C:\list.txt" `
                    -FileCount 1 `
                    -Mode Auto 3>$null 6>$null
                [pscustomobject]@{
                    load = $load
                    fallbackInputCursor = $script:CursorSeenByFallback
                    finalCursor = (Get-Content -LiteralPath $dumpInfoPath -Raw).Trim()
                }
            }

            $result.load.loadModeUsed | Should -Be "full-fallback"
            $result.fallbackInputCursor | Should -Be "original-cursor"
            $result.finalCursor | Should -Be "full-cursor"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "restores ConfigDumpInfo when both partial and full fallback loads fail" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-dump-info-failed-" + [guid]::NewGuid().ToString("N"))
        try {
            $exportPath = Join-Path $tempRoot "src\cf"
            New-Item -ItemType Directory -Force -Path $exportPath | Out-Null
            $dumpInfoPath = Join-Path $exportPath "ConfigDumpInfo.xml"
            Set-Content -LiteralPath $dumpInfoPath -Encoding UTF8 -Value "original-cursor"

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $script:DesignerCallCount = 0
                function Invoke-Designer {
                    $script:DesignerCallCount++
                    $script:LastNativeProcessStarted = $true
                    Set-Content -LiteralPath $dumpInfoPath -Encoding UTF8 -Value "failed-cursor-$script:DesignerCallCount"
                    throw "load failed $script:DesignerCallCount"
                }

                $message = ""
                try {
                    Invoke-ConfigLoadWithFallback `
                        -InfoBasePath "C:\base" `
                        -InfoBaseKind file `
                        -State ([pscustomobject]@{}) `
                        -AbsoluteExportPath $exportPath `
                        -ListFilePath "C:\list.txt" `
                        -FileCount 1 `
                        -Mode Auto 3>$null 6>$null | Out-Null
                } catch {
                    $message = $_.Exception.Message
                }
                [pscustomobject]@{
                    calls = $script:DesignerCallCount
                    message = $message
                    finalCursor = (Get-Content -LiteralPath $dumpInfoPath -Raw).Trim()
                }
            }

            $result.calls | Should -Be 2
            $result.message | Should -Match "both failed"
            $result.finalCursor | Should -Be "original-cursor"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "does not fallback when Designer preparation fails before a process starts and Full does not require a list file" {
        $auto = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:Calls = 0
            function Invoke-Designer {
                $script:Calls++
                throw "platform path is missing"
            }
            $message = ""
            try {
                Invoke-ConfigLoadWithFallback -InfoBasePath "C:\base" -InfoBaseKind file -State ([pscustomobject]@{}) -AbsoluteExportPath "C:\src" -ListFilePath "C:\list.txt" -FileCount 1 -Mode Auto 6>$null | Out-Null
            } catch { $message = $_.Exception.Message }
            [pscustomobject]@{ calls = $script:Calls; message = $message }
        }
        $auto.calls | Should -Be 1
        $auto.message | Should -Match "platform path is missing"

        $full = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:Calls = 0
            function Get-ConfigSourceFingerprint { [pscustomobject]@{ fingerprint = "fingerprint-e"; fileCount = 1; absoluteExportPath = "C:\src" } }
            function Get-ConfigLoadChangeSet { [pscustomobject]@{ files = @("Configuration.xml"); baseCommit = "base"; currentCommit = "head"; absoluteExportPath = "C:\src" } }
            function Assert-OneCConfigurationSourceIntegrity {}
            function New-ConfigLoadListFile { throw "list must not be created" }
            function Stop-DevBranchRuntimeBeforeInfobaseMutation {}
            function Invoke-Designer { param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs); $script:Calls++; $script:LastLogPath = "C:\logs\full.log" }
            $load = Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind file -State ([pscustomobject]@{}) -ExportPath "src/cf" -Mode Full 6>$null
            [pscustomobject]@{ calls = $script:Calls; listFile = $load.listFile; mode = $load.loadModeUsed }
        }
        $full.calls | Should -Be 1
        $full.listFile | Should -Be ""
        $full.mode | Should -Be "full"
    }

    It "full-loads a legacy no-op proof and avoids Designer on list preparation errors" {
        $noOpCalls = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:DesignerCallCount = 0
            $script:DrainCallCount = 0
            function Get-ConfigSourceFingerprint { [pscustomobject]@{ fingerprint = "fingerprint-f"; fileCount = 1; absoluteExportPath = "C:\src" } }
            function Get-ConfigLoadChangeSet { [pscustomobject]@{ files = @(); baseCommit = ""; currentCommit = "head"; absoluteExportPath = "C:\src"; requiresFullLoad = $true; fullLoadReason = "designer-tree-proof-missing" } }
            function Assert-OneCConfigurationSourceIntegrity {}
            function Invoke-Designer { $script:DesignerCallCount++ }
            function Stop-DevBranchRuntimeBeforeInfobaseMutation { $script:DrainCallCount++ }
            $load = Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind file -State ([pscustomobject]@{}) -ExportPath "src/cf" 6>$null
            [pscustomobject]@{ calls = $script:DesignerCallCount; drains = $script:DrainCallCount; loaded = $load.loaded }
        }
        $noOpCalls.calls | Should -Be 1
        $noOpCalls.drains | Should -Be 1
        $noOpCalls.loaded | Should -BeTrue

        $prep = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:DesignerCallCount = 0
            $script:DrainCallCount = 0
            function Get-ConfigSourceFingerprint { [pscustomobject]@{ fingerprint = "fingerprint-g"; treeObjectId = ("b" * 40); fileCount = 1; absoluteExportPath = "C:\src" } }
            function Get-ConfigLoadChangeSet { [pscustomobject]@{ files = @("Configuration.xml"); baseCommit = ("a" * 40); currentCommit = "head"; absoluteExportPath = "C:\src"; requiresFullLoad = $false } }
            function Assert-OneCConfigurationSourceIntegrity {}
            function New-ConfigLoadListFile { throw "list preparation failed" }
            function Invoke-Designer { $script:DesignerCallCount++ }
            function Stop-DevBranchRuntimeBeforeInfobaseMutation { $script:DrainCallCount++ }
            $message = ""
            try { Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind file -State ([pscustomobject]@{ lastConfigDesignerTreeObjectId = ("a" * 40) }) -ExportPath "src/cf" 6>$null | Out-Null } catch { $message = $_.Exception.Message }
            [pscustomobject]@{ calls = $script:DesignerCallCount; drains = $script:DrainCallCount; message = $message }
        }
        $prep.calls | Should -Be 0
        $prep.drains | Should -Be 0
        $prep.message | Should -Match "list preparation failed"
    }

    It "rejects a staged dump that would remove the existing vendor support state" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-support-state-dump-" + [guid]::NewGuid().ToString("N"))
        try {
            $export = Join-Path $tempRoot "src\cf"
            $supportState = Join-Path $export "Ext\ParentConfigurations.bin"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $supportState) | Out-Null
            Set-Content -LiteralPath (Join-Path $export "Configuration.xml") -Encoding UTF8 -Value "<Configuration><Comment>original</Comment></Configuration>"
            Set-Content -LiteralPath (Join-Path $export "ConfigDumpInfo.xml") -Encoding UTF8 -Value "original-dump-info"
            [System.IO.File]::WriteAllBytes($supportState, [byte[]]@(0, 17, 34, 255))
            $beforeHash = (Get-FileHash -LiteralPath $supportState -Algorithm SHA256).Hash

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Get-ExportPath { "src/cf" }
                function Invoke-Designer {
                    param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs)
                    $stage = [string]$DesignerArgs[1]
                    New-Item -ItemType Directory -Force -Path $stage | Out-Null
                    Set-Content -LiteralPath (Join-Path $stage "Configuration.xml") -Encoding UTF8 -Value "<Configuration><Comment>staged</Comment></Configuration>"
                    Set-Content -LiteralPath (Join-Path $stage "ConfigDumpInfo.xml") -Encoding UTF8 -Value "staged-dump-info"
                }

                $message = ""
                try {
                    Dump-ConfigToFilesFromInfoBase -InfoBasePath "C:\base" -InfoBaseKind file 6>$null | Out-Null
                } catch {
                    $message = $_.Exception.Message
                }
                [pscustomobject]@{
                    message = $message
                    configuration = Get-Content -LiteralPath (Join-Path $export "Configuration.xml") -Raw -Encoding UTF8
                    supportHash = (Get-FileHash -LiteralPath $supportState -Algorithm SHA256).Hash
                }
            }

            $result.message | Should -Match "would lose Ext/ParentConfigurations\.bin"
            $result.configuration | Should -Match "original"
            $result.supportHash | Should -Be $beforeHash
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "uses content fingerprints to skip Designer and retry only Enterprise when needed" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-fingerprint-test-" + [guid]::NewGuid().ToString("N"))
        try {
            $export = Join-Path $tempRoot "src\cf"
            New-Item -ItemType Directory -Force -Path $export | Out-Null
            Set-Content -LiteralPath (Join-Path $export "Configuration.xml") -Encoding UTF8 -Value "<Configuration />"
            Set-Content -LiteralPath (Join-Path $export "ConfigDumpInfo.xml") -Encoding UTF8 -Value "one"
            & git -C $tempRoot init --quiet
            & git -C $tempRoot config user.email "itl-tests@example.invalid"
            & git -C $tempRoot config user.name "ITL Tests"
            & git -C $tempRoot add -- src/cf
            & git -C $tempRoot commit --quiet -m "baseline"

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Get-CurrentCommit { "head" }
                function Get-ConfigLoadChangeSet { throw "Git diff must not run for a fingerprint match" }
                function Invoke-Designer { throw "Designer must not run for a fingerprint match" }
                $fingerprint = (Get-ConfigSourceFingerprint -ExportPath "src/cf").fingerprint
                Set-Content -LiteralPath (Join-Path $export "ConfigDumpInfo.xml") -Encoding UTF8 -Value "two"
                $afterDumpInfo = (Get-ConfigSourceFingerprint -ExportPath "src/cf").fingerprint
                $passed = Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind file -State ([pscustomobject]@{
                    lastConfigDesignerFingerprint = $fingerprint
                    enterpriseNormalizationStatus = "passed"
                }) -ExportPath "src/cf" 6>$null
                $pending = Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind file -State ([pscustomobject]@{
                    lastConfigDesignerFingerprint = $fingerprint
                    enterpriseNormalizationStatus = "failed"
                }) -ExportPath "src/cf" 6>$null
                [pscustomobject]@{ original = $fingerprint; afterDumpInfo = $afterDumpInfo; passed = $passed; pending = $pending }
            }

            $result.afterDumpInfo | Should -Be $result.original
            $result.passed.designerInvoked | Should -BeFalse
            $result.passed.normalizationRequired | Should -BeFalse
            $result.pending.designerInvoked | Should -BeFalse
            $result.pending.normalizationRequired | Should -BeTrue
            $result.pending.loadReason | Should -Be "source-fingerprint-match-normalization-required"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "forces a full load after Release E2E restore even without a Git change list" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:LoadCalls = 0
            $script:LoadMode = ""
            $script:LoadFileCount = 0
            $script:ResetConfigDumpInfo = $false
            function Get-ConfigSourceFingerprint {
                [pscustomobject]@{ fingerprint = ("v2|git-tree-sha256|" + ("b" * 64)); fileCount = 7; absoluteExportPath = "C:\src" }
            }
            function Get-ConfigLoadChangeSet {
                [pscustomobject]@{ files = @(); baseCommit = "base"; currentCommit = "head"; absoluteExportPath = "C:\src" }
            }
            function Get-CurrentCommit { "head" }
            function Stop-DevBranchRuntimeBeforeInfobaseMutation {}
            function Invoke-ConfigLoadWithFallback {
                param([string]$Mode, [int]$FileCount, [switch]$ResetConfigDumpInfo)
                $script:LoadCalls++
                $script:LoadMode = $Mode
                $script:LoadFileCount = $FileCount
                $script:ResetConfigDumpInfo = [bool]$ResetConfigDumpInfo
                [pscustomobject]@{
                    lastLogPath = ""
                    loadModeUsed = $Mode.ToLowerInvariant()
                    partialLogPath = ""
                    fullFallbackLogPath = ""
                    configLoadStatus = "passed"
                    partialError = ""
                    fullFallbackError = ""
                }
            }
            function Assert-OneCConfigurationSourceIntegrity {}

            $load = Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind file -State ([pscustomobject]@{
                lastConfigDesignerFingerprint = ""
                loadReason = "release-e2e-restore-invalidated"
                enterpriseNormalizationStatus = "pending"
            }) -ExportPath "src/cf" 6>$null
            [pscustomobject]@{
                load = $load
                calls = $script:LoadCalls
                mode = $script:LoadMode
                fileCount = $script:LoadFileCount
                resetConfigDumpInfo = $script:ResetConfigDumpInfo
            }
        }

        $result.calls | Should -Be 1
        $result.mode | Should -Be "Full"
        $result.fileCount | Should -Be 1
        $result.resetConfigDumpInfo | Should -BeTrue
        $result.load.loaded | Should -BeTrue
        $result.load.designerInvoked | Should -BeTrue
        $result.load.loadReason | Should -Be "release-e2e-restore-full-load"
    }

    It "keeps the source fingerprint canonical without hashing every file" {
        $tempRoot = New-ShortWorkflowProjectRoot
        try {
            $export = Join-Path $tempRoot "src\cf"
            New-Item -ItemType Directory -Force -Path $export | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Encoding UTF8 -Value "src/cf/ignored.bin"
            Set-Content -LiteralPath (Join-Path $export "Configuration.xml") -Encoding UTF8 -Value "<Configuration />"
            Set-Content -LiteralPath (Join-Path $export "ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor-one"
            & git -C $tempRoot init --quiet
            & git -C $tempRoot config user.email "itl-tests@example.invalid"
            & git -C $tempRoot config user.name "ITL Tests"

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null

                $unborn = Get-ConfigSourceFingerprint -ExportPath "src/cf"
                & git -C $tempRoot add -- .gitignore src/cf
                $stagedUnborn = Get-ConfigSourceFingerprint -ExportPath "src/cf"
                & git -C $tempRoot commit --quiet -m "baseline"
                $clean = Get-ConfigSourceFingerprint -ExportPath "src/cf"
                $absolute = Get-ConfigSourceFingerprint -ExportPath $export

                Set-Content -LiteralPath (Join-Path $export "ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor-two"
                $cursorOnly = Get-ConfigSourceFingerprint -ExportPath "src/cf"

                Set-Content -LiteralPath (Join-Path $export "Configuration.xml") -Encoding UTF8 -Value "<Configuration><Comment>changed</Comment></Configuration>"
                [System.IO.File]::WriteAllBytes((Join-Path $export "данные.bin"), [byte[]]@(0, 1, 2, 255))
                $cachedBefore = @(Get-GitPathList -Arguments @("diff", "--cached", "--name-only", "-z", "--"))
                $dirty = Get-ConfigSourceFingerprint -ExportPath "src/cf"
                $cachedAfter = @(Get-GitPathList -Arguments @("diff", "--cached", "--name-only", "-z", "--"))

                & git -C $tempRoot add -- src/cf
                $staged = Get-ConfigSourceFingerprint -ExportPath "src/cf"
                & git -C $tempRoot commit --quiet -m "changed source"
                $committed = Get-ConfigSourceFingerprint -ExportPath "src/cf"

                Set-Content -LiteralPath (Join-Path $tempRoot "README.md") -Encoding UTF8 -Value "outside source scope"
                $outside = Get-ConfigSourceFingerprint -ExportPath "src/cf"

                [System.IO.File]::WriteAllBytes((Join-Path $export "ignored.bin"), [byte[]]@(9, 8, 7))
                $withIgnored = Get-ConfigSourceFingerprint -ExportPath "src/cf"
                Remove-Item -LiteralPath (Join-Path $export "ignored.bin") -Force
                $ignoredRemoved = Get-ConfigSourceFingerprint -ExportPath "src/cf"

                Move-Item -LiteralPath (Join-Path $export "Configuration.xml") -Destination (Join-Path $export "Переименованная.xml")
                $renamed = Get-ConfigSourceFingerprint -ExportPath "src/cf"
                Remove-Item -LiteralPath (Join-Path $export "данные.bin") -Force
                $deleted = Get-ConfigSourceFingerprint -ExportPath "src/cf"

                [pscustomobject]@{
                    unborn = $unborn
                    stagedUnborn = $stagedUnborn
                    clean = $clean
                    absolute = $absolute
                    cursorOnly = $cursorOnly
                    dirty = $dirty
                    staged = $staged
                    committed = $committed
                    outside = $outside
                    withIgnored = $withIgnored
                    ignoredRemoved = $ignoredRemoved
                    renamed = $renamed
                    deleted = $deleted
                    cachedBefore = $cachedBefore
                    cachedAfter = $cachedAfter
                }
            }

            $result.unborn.fingerprint | Should -Match '^v2\|git-tree-sha256\|[0-9a-f]{64}$'
            $result.stagedUnborn.fingerprint | Should -Be $result.unborn.fingerprint
            $result.clean.fingerprint | Should -Be $result.unborn.fingerprint
            $result.absolute.fingerprint | Should -Be $result.clean.fingerprint
            $result.clean.fileCount | Should -Be 1
            $result.cursorOnly.fingerprint | Should -Be $result.clean.fingerprint
            $result.dirty.fingerprint | Should -Not -Be $result.clean.fingerprint
            $result.dirty.fileCount | Should -Be 2
            $result.staged.fingerprint | Should -Be $result.dirty.fingerprint
            $result.committed.fingerprint | Should -Be $result.dirty.fingerprint
            $result.outside.fingerprint | Should -Be $result.dirty.fingerprint
            $result.withIgnored.fingerprint | Should -Not -Be $result.dirty.fingerprint
            $result.withIgnored.fileCount | Should -Be 3
            $result.ignoredRemoved.fingerprint | Should -Be $result.dirty.fingerprint
            $result.renamed.fingerprint | Should -Not -Be $result.dirty.fingerprint
            $result.deleted.fingerprint | Should -Not -Be $result.renamed.fingerprint
            @($result.cachedBefore).Count | Should -Be 0
            @($result.cachedAfter).Count | Should -Be 0
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "migrates a legacy source proof with one safe full load" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:ChangeSetCalls = 0
            $script:LoadCalls = 0
            function Get-ConfigSourceFingerprint {
                [pscustomobject]@{ fingerprint = ("v2|git-tree-sha256|" + ("b" * 64)); treeObjectId = ("b" * 40); fileCount = 7; absoluteExportPath = "C:\src" }
            }
            function Get-ConfigLoadChangeSet {
                $script:ChangeSetCalls++
                [pscustomobject]@{
                    files = @()
                    baseCommit = ""
                    currentCommit = "head"
                    absoluteExportPath = "C:\src"
                    requiresFullLoad = $true
                    fullLoadReason = "designer-tree-proof-missing"
                }
            }
            function Get-CurrentCommit { "head" }
            function New-ConfigLoadListFile { "C:\list.txt" }
            function Stop-DevBranchRuntimeBeforeInfobaseMutation {}
            function Invoke-ConfigLoadWithFallback {
                param([string]$Mode)
                $script:LoadCalls++
                [pscustomobject]@{
                    lastLogPath = ""
                    loadModeUsed = $Mode.ToLowerInvariant()
                    partialLogPath = ""
                    fullFallbackLogPath = ""
                    configLoadStatus = "passed"
                    partialError = ""
                    fullFallbackError = ""
                }
            }
            function Assert-OneCConfigurationSourceIntegrity {}

            $state = [pscustomobject]@{
                lastConfigDesignerFingerprint = ("a" * 64)
                enterpriseNormalizationStatus = "passed"
            }
            $load = Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind file -State $state -ExportPath "src/cf" 6>$null
            [pscustomobject]@{
                load = $load
                changeSetCalls = $script:ChangeSetCalls
                loadCalls = $script:LoadCalls
            }
        }

        $result.load.loaded | Should -BeTrue
        $result.load.designerInvoked | Should -BeTrue
        $result.load.loadModeUsed | Should -Be "full"
        $result.load.loadReason | Should -Be "designer-tree-proof-missing-full-load"
        $result.changeSetCalls | Should -Be 1
        $result.loadCalls | Should -Be 1
    }

    It "keeps the canonical verification fingerprint stable across staging and commit" {
        $tempRoot = New-ShortWorkflowProjectRoot
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf"), (Join-Path $tempRoot "tests\features") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Encoding UTF8 -Value "<Configuration />"
            & git -C $tempRoot init --quiet
            & git -C $tempRoot config user.email "itl-tests@example.invalid"
            & git -C $tempRoot config user.name "ITL Tests"
            & git -C $tempRoot add -- src/cf/Configuration.xml
            & git -C $tempRoot commit --quiet -m "baseline"

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null

                Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Encoding UTF8 -Value "<Configuration><Comment>checked</Comment></Configuration>"
                Set-Content -LiteralPath (Join-Path $tempRoot "tests\features\проверка.feature") -Encoding UTF8 -Value "Функционал: Проверка"
                [System.IO.File]::WriteAllBytes((Join-Path $tempRoot "src\cf\данные.bin"), [byte[]]@(0, 1, 2, 255))

                $cachedBefore = @(& git -C $tempRoot diff --cached --name-only)
                $dirty = Get-VerificationFingerprint
                $cachedAfter = @(& git -C $tempRoot diff --cached --name-only)

                & git -C $tempRoot add -- src/cf tests/features
                $staged = Get-VerificationFingerprint
                & git -C $tempRoot reset --quiet HEAD -- src/cf tests/features
                $unstaged = Get-VerificationFingerprint

                & git -C $tempRoot add -- src/cf tests/features
                & git -C $tempRoot commit --quiet -m "checked content"
                $clean = Get-VerificationFingerprint

                Set-Content -LiteralPath (Join-Path $tempRoot "README.md") -Encoding UTF8 -Value "outside verification scope"
                & git -C $tempRoot add -- README.md
                & git -C $tempRoot commit --quiet -m "outside scope"
                $outsideCommit = Get-VerificationFingerprint

                [System.IO.File]::WriteAllBytes((Join-Path $tempRoot "src\cf\данные.bin"), [byte[]]@(0, 1, 3, 255))
                $changed = Get-VerificationFingerprint
                [System.IO.File]::WriteAllBytes((Join-Path $tempRoot "src\cf\данные.bin"), [byte[]]@(0, 1, 2, 255))
                Move-Item -LiteralPath (Join-Path $tempRoot "src\cf\данные.bin") -Destination (Join-Path $tempRoot "src\cf\переименовано.bin")
                $renamed = Get-VerificationFingerprint
                Remove-Item -LiteralPath (Join-Path $tempRoot "src\cf\переименовано.bin") -Force
                $deleted = Get-VerificationFingerprint

                [pscustomobject]@{
                    cachedBefore = @($cachedBefore)
                    cachedAfter = @($cachedAfter)
                    dirty = $dirty
                    staged = $staged
                    unstaged = $unstaged
                    clean = $clean
                    outsideCommit = $outsideCommit
                    changed = $changed
                    renamed = $renamed
                    deleted = $deleted
                }
            }

            $result.dirty | Should -Match "^v3\|"
            @($result.cachedBefore) | Should -HaveCount 0
            @($result.cachedAfter) | Should -HaveCount 0
            $result.staged | Should -BeExactly $result.dirty
            $result.unstaged | Should -BeExactly $result.dirty
            $result.clean | Should -BeExactly $result.dirty
            $result.outsideCommit | Should -BeExactly $result.dirty
            $result.changed | Should -Not -BeExactly $result.dirty
            $result.renamed | Should -Not -BeExactly $result.dirty
            $result.deleted | Should -Not -BeExactly $result.dirty
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "does not let failed or legacy verification evidence become fresh" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $current = Get-VerificationFingerprint
            $failed = Get-VerificationState -State ([pscustomobject]@{
                lastVerificationStatus = "failed"
                lastVerifiedCommit = "old"
                lastVerifiedFingerprint = $current
            }) -CurrentCommit "head" -CurrentFingerprint $current
            $legacy = Get-VerificationState -State ([pscustomobject]@{
                lastVerificationStatus = "passed"
                lastVerifiedCommit = "head"
                lastVerifiedFingerprint = "v2|legacy"
            }) -CurrentCommit "head" -CurrentFingerprint $current
            [pscustomobject]@{ failed = $failed; legacy = $legacy }
        }

        $result.failed.isFreshPassed | Should -BeFalse
        $result.failed.effectiveStatus | Should -Be "failed"
        $result.legacy.isFreshPassed | Should -BeFalse
        $result.legacy.effectiveStatus | Should -Be "stale"
    }

    It "maps configuration source paths to full and partial repository transfer objects" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            [pscustomobject]@{
                full = ConvertTo-ConfigRepositoryTransferPath -RelativePath "CommonModules/Общий модуль.xml"
                partial = ConvertTo-ConfigRepositoryTransferPath -RelativePath "Catalogs/Договоры/Ext/ObjectModule.bsl"
                nestedFull = ConvertTo-ConfigRepositoryTransferPath -RelativePath "Catalogs/Договоры/Forms/Форма элемента.xml"
                nestedPartial = ConvertTo-ConfigRepositoryTransferPath -RelativePath "Subsystems/Управление/Subsystems/Настройки/Ext/Help.xml"
                rootPartial = ConvertTo-ConfigRepositoryTransferPath -RelativePath "Ext/ManagedApplicationModule.bsl"
                unknown = ConvertTo-ConfigRepositoryTransferPath -RelativePath "UnknownCollection/Объект.xml"
            }
        }

        $result.full.objectName | Should -Be "ОбщийМодуль.Общий модуль"
        $result.full.scope | Should -Be "full"
        $result.partial.objectName | Should -Be "Справочник.Договоры"
        $result.partial.scope | Should -Be "partial"
        $result.partial.part | Should -Be "модуль объекта"
        $result.nestedFull.objectName | Should -Be "Справочник.Договоры.Форма.Форма элемента"
        $result.nestedFull.scope | Should -Be "full"
        $result.nestedPartial.objectName | Should -Be "Подсистема.Управление.Настройки"
        $result.nestedPartial.part | Should -Be "справочная информация"
        $result.rootPartial.objectName | Should -Be "Конфигурация"
        $result.rootPartial.part | Should -Be "модуль управляемого приложения"
        $result.unknown | Should -BeNullOrEmpty
    }

    It "builds the repository transfer plan from committed dirty and untracked paths with Cyrillic and spaces" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-result-хранилище с пробелом-" + [guid]::NewGuid().ToString("N"))
        try {
            $catalogRoot = Join-Path $tempRoot "src\cf\Catalogs\Каталог с пробелом"
            $formRoot = Join-Path $catalogRoot "Forms\Форма элемента"
            New-Item -ItemType Directory -Force -Path (Join-Path $catalogRoot "Ext"), (Join-Path $formRoot "Ext") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Encoding UTF8 -Value "configuration-base"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor-base"
            Set-Content -LiteralPath "$catalogRoot.xml" -Encoding UTF8 -Value "catalog-base"
            Set-Content -LiteralPath (Join-Path $catalogRoot "Ext\ObjectModule.bsl") -Encoding UTF8 -Value "object-base"
            Set-Content -LiteralPath "$formRoot.xml" -Encoding UTF8 -Value "form-base"
            Set-Content -LiteralPath (Join-Path $formRoot "Ext\Form.xml") -Encoding UTF8 -Value "form-content-base"
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot config core.autocrlf false
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M master
            $masterCommit = (& git -C $tempRoot rev-parse HEAD).Trim()

            & git -C $tempRoot checkout --quiet -b itldev/test
            Set-Content -LiteralPath (Join-Path $catalogRoot "Ext\ObjectModule.bsl") -Encoding UTF8 -Value "object-committed"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "catalog module" *> $null
            Set-Content -LiteralPath (Join-Path $formRoot "Ext\Form.xml") -Encoding UTF8 -Value "form-content-dirty"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Encoding UTF8 -Value "configuration-dirty"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor-dirty"
            $moduleRoot = Join-Path $tempRoot "src\cf\CommonModules\Новый модуль"
            New-Item -ItemType Directory -Force -Path (Join-Path $moduleRoot "Ext") | Out-Null
            Set-Content -LiteralPath "$moduleRoot.xml" -Encoding UTF8 -Value "module-metadata"
            Set-Content -LiteralPath (Join-Path $moduleRoot "Ext\Module.bsl") -Encoding UTF8 -Value "module-source"
            $unknownPath = Join-Path $tempRoot "src\cf\UnknownCollection\Неизвестный объект.xml"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $unknownPath) | Out-Null
            Set-Content -LiteralPath $unknownPath -Encoding UTF8 -Value "unknown"

            $plan = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Get-MasterBranch { "master" }
                Get-ConfigRepositoryTransferPlan -ExportPath "src/cf"
            }

            $plan.baseCommit | Should -Be $masterCommit
            @($plan.items) | Should -HaveCount 3
            @($plan.unresolvedPaths) | Should -Be @("src/cf/UnknownCollection/Неизвестный объект.xml")
            $catalog = @($plan.items | Where-Object name -eq "Справочник.Каталог с пробелом")[0]
            $catalog.scope | Should -Be "partial"
            @($catalog.parts) | Should -Contain "модуль объекта"
            $form = @($plan.items | Where-Object name -eq "Справочник.Каталог с пробелом.Форма.Форма элемента")[0]
            $form.scope | Should -Be "partial"
            @($form.parts) | Should -Contain "форма"
            $module = @($plan.items | Where-Object name -eq "ОбщийМодуль.Новый модуль")[0]
            $module.scope | Should -Be "full"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "locks only the exact repository object list and blocks unresolved paths before Designer" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-lock-objects-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{ devBranch = "itldev/lock"; devBranchKind = "configuration"; initializationStatus = "ready" }
                $script:DesignerCalls = 0
                $script:DesignerArgs = @()
                $script:LockPlan = [pscustomobject]@{
                    baseCommit = "base-sha"
                    unresolvedPaths = @()
                    items = @(
                        [pscustomobject]@{ name = 'Справочник.Товары & "услуги"'; scope = "full" },
                        [pscustomobject]@{ name = "ОбщийМодуль.Обмен"; scope = "partial" }
                    )
                }
                function Read-DevBranchState { $state }
                function Assert-DevelopmentBranchWorktreeContext {}
                function Get-SourceUsesRepository { $true }
                function Get-ExportPath { "src/cf" }
                function Get-ConfigRepositoryTransferPlan { $script:LockPlan }
                function Get-SourceInfoBasePath { "srv\source" }
                function Get-InfoBaseKind { "server" }
                function New-RepositoryConnectionArgs { @("/ConfigurationRepositoryF", "repo", "-N", "user", "-P", "secret") }
                function Get-EnvValue { param([string]$Name) if ($Name -eq "REPOSITORY_USER") { "user" } elseif ($Name -eq "REPOSITORY_PASSWORD") { "secret" } else { "" } }
                function Invoke-Designer {
                    param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs)
                    $script:DesignerCalls++; $script:DesignerArgs = @($DesignerArgs)
                    $script:LastLogPath = Join-Path $tempRoot "designer.log"
                    [IO.File]::WriteAllText($script:LastLogPath, "command /P secret completed", [Text.UTF8Encoding]::new($false))
                }
                function Set-RunStage {}

                Lock-ConfigRepositoryObjects 6>$null
                $xmlPath = [regex]::Match($script:RunUserReport, '(?m)^- Файл объектов: (.+)$').Groups[1].Value.Trim()
                [xml]$xml = Get-Content -LiteralPath $xmlPath -Raw -Encoding UTF8
                $requested = @($xml.Objects.Object | ForEach-Object { [pscustomobject]@{ name = [string]$_.fullName; children = [string]$_.includeChildObjects } })
                $successCalls = $script:DesignerCalls
                $successArgs = @($script:DesignerArgs)

                $script:LockPlan = [pscustomobject]@{ baseCommit = "base-sha"; unresolvedPaths = @(); items = @() }
                Lock-ConfigRepositoryObjects 6>$null
                $afterNoOp = $script:DesignerCalls

                $script:LockPlan = [pscustomobject]@{ baseCommit = "base-sha"; unresolvedPaths = @("src/cf/Unknown/неизвестно.xml"); items = @() }
                $unresolved = ""
                try { Lock-ConfigRepositoryObjects 6>$null } catch { $unresolved = $_.Exception.Message }
                $redactedPath = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot ".agent-1c\runs") -Recurse -File -Filter "repository-lock.log" | Select-Object -First 1 -ExpandProperty FullName)
                [pscustomobject]@{ requested = $requested; successCalls = $successCalls; afterNoOp = $afterNoOp; args = $successArgs; unresolved = $unresolved; finalCalls = $script:DesignerCalls; redactedPath = [string]$redactedPath; redactedText = Read-Utf8Text -Path ([string]$redactedPath) }
            }

            $result.successCalls | Should -Be 1
            $result.afterNoOp | Should -Be 1
            $result.finalCalls | Should -Be 1
            @($result.requested).Count | Should -Be 2
            @($result.requested | Where-Object name -eq 'Справочник.Товары & "услуги"').children | Should -Be "true"
            @($result.requested | Where-Object name -eq "ОбщийМодуль.Обмен").children | Should -Be "false"
            @($result.args) | Should -Contain "/ConfigurationRepositoryLock"
            @($result.args) | Should -Contain "-Objects"
            (@($result.args) -join " ") | Should -Not -Match "ConfigurationRepositoryUpdateCfg|LoadCfg|LoadConfigFromFiles|-force|-revised"
            $result.unresolved | Should -Match "LOCK_CONFIG_REPOSITORY_UNRESOLVED_PATHS"
            $result.redactedPath | Should -Not -BeNullOrEmpty
            $result.redactedText | Should -Not -Match "secret"
            $result.redactedText | Should -Match "<redacted>"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "surfaces repository lock conflicts with the exact object owner and a redacted direct log" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-lock-conflict с пробелом-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{ devBranch = "itldev/lock"; devBranchKind = "configuration"; initializationStatus = "ready" }
                function Read-DevBranchState { $state }
                function Assert-DevelopmentBranchWorktreeContext {}
                function Get-SourceUsesRepository { $true }
                function Get-ExportPath { "src/cf" }
                function Get-ConfigRepositoryTransferPlan {
                    [pscustomobject]@{
                        baseCommit = "base-sha"
                        unresolvedPaths = @()
                        items = @([pscustomobject]@{ name = "Справочник.упо_Проекты.Форма.ФормаСписка"; scope = "full" })
                    }
                }
                function Get-SourceInfoBasePath { "srv\source" }
                function Get-InfoBaseKind { "server" }
                function New-RepositoryConnectionArgs { @("/ConfigurationRepositoryF", "repo", "-N", "user", "-P", "secret") }
                function Get-EnvValue { param([string]$Name) if ($Name -eq "REPOSITORY_PASSWORD") { "secret" } else { "" } }
                function Invoke-Designer {
                    param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs)
                    $script:LastLogPath = Join-Path $tempRoot "designer.log"
                    $lines = @(
                        "---- Начало операции с хранилищем конфигурации ----",
                        "Объект захвачен для редактирования другим пользователем: Справочник.упо_Проекты.Форма.ФормаСписка (Проценко2)",
                        "repository password: secret",
                        "---- Операция с хранилищем конфигурации завершена ----",
                        "Ошибка захвата объектов в хранилище"
                    )
                    [IO.File]::WriteAllLines($script:LastLogPath, $lines, [Text.UTF8Encoding]::new($false))
                    throw "1C Designer failed with exit code 1. Log: $script:LastLogPath"
                }
                function Set-RunStage { param([string]$Stage, [string]$Detail); $script:CapturedStage = $Stage; $script:CapturedStageDetail = $Detail }

                $errorMessage = ""
                try { Lock-ConfigRepositoryObjects 6>$null } catch { $errorMessage = $_.Exception.Message }
                [pscustomobject]@{
                    errorMessage = $errorMessage
                    stage = $script:CapturedStage
                    stageDetail = $script:CapturedStageDetail
                    errorCategory = $script:RunErrorCategory
                    requiredAction = $script:RunRequiredAction
                    lastLogPath = $script:LastLogPath
                    redactedText = Read-Utf8Text -Path $script:LastLogPath
                }
            }

            $result.errorMessage | Should -Match "LOCK_CONFIG_REPOSITORY_OBJECT_CONFLICT"
            $result.errorMessage | Should -Match ([regex]::Escape("Справочник.упо_Проекты.Форма.ФормаСписка"))
            $result.errorMessage | Should -Match "Проценко2"
            $result.errorMessage | Should -Match ([regex]::Escape("Редактированный лог: $($result.lastLogPath)"))
            $result.stage | Should -Be "repository-lock.conflict"
            $result.stageDetail | Should -BeLike "LOCK_CONFIG_REPOSITORY_OBJECT_CONFLICT*"
            $result.errorCategory | Should -Be "runner"
            $result.requiredAction | Should -Match ([regex]::Escape("/itl-lock-objects"))
            Split-Path -Leaf $result.lastLogPath | Should -Be "repository-lock.log"
            $result.redactedText | Should -Not -Match "secret"
            $result.redactedText | Should -Match "<redacted>"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "locks and releases the same exact object list in the Release E2E repository roundtrip" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-lock-roundtrip с пробелом-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $operations = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{ devBranch = "itldev/lock"; devBranchKind = "configuration"; initializationStatus = "ready" }
                $script:RepositoryOperations = [System.Collections.Generic.List[object]]::new()
                function Read-DevBranchState { $state }
                function Assert-DevelopmentBranchWorktreeContext {}
                function Get-SourceUsesRepository { $false }
                function Get-ExportPath { "src/cf" }
                function Get-ConfigRepositoryTransferPlan { [pscustomobject]@{ baseCommit = "base"; unresolvedPaths = @(); items = @([pscustomobject]@{ name = "ОбщийМодуль.Обмен"; scope = "full" }) } }
                function Get-SourceInfoBasePath { "srv\source" }
                function Get-InfoBaseKind { "server" }
                function Invoke-Designer { param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs); $script:RepositoryOperations.Add([pscustomobject]@{ args = @($DesignerArgs) }) | Out-Null }
                Invoke-ReleaseE2EConfigRepositoryLockRoundtrip 6>$null
                @($script:RepositoryOperations)
            }
            @($operations) | Should -HaveCount 3
            @($operations[0].args) | Should -Contain "/ConfigurationRepositoryCreate"
            @($operations[1].args) | Should -Contain "/ConfigurationRepositoryLock"
            @($operations[2].args) | Should -Contain "/ConfigurationRepositoryUnLock"
            $repositoryPath = @($operations[0].args)[@($operations[0].args).IndexOf("/ConfigurationRepositoryF") + 1]
            $repositoryPath | Should -Match ([regex]::Escape(" с пробелом-"))
            $repositoryPath | Should -Be @($operations[1].args)[@($operations[1].args).IndexOf("/ConfigurationRepositoryF") + 1]
            $repositoryPath | Should -Be @($operations[2].args)[@($operations[2].args).IndexOf("/ConfigurationRepositoryF") + 1]
            $firstObjects = @($operations[1].args)[@($operations[1].args).IndexOf("-Objects") + 1]
            $secondObjects = @($operations[2].args)[@($operations[2].args).IndexOf("-Objects") + 1]
            $firstObjects | Should -Be $secondObjects
            Test-Path -LiteralPath $firstObjects -PathType Leaf | Should -BeTrue
            (@($operations | ForEach-Object { @($_.args) }) -join " ") | Should -Not -Match "-force|-revised|ConfigurationRepositoryUpdateCfg"
            [Environment]::GetEnvironmentVariable("SOURCE_USES_REPOSITORY", "Process") | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "archives non-config delta resumably and creates a cleanup commit with the exact master tree" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-reset-archive с пробелом-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf"), (Join-Path $tempRoot "docs") | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.name "ITL Test"
            & git -C $tempRoot config user.email "itl@example.invalid"
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Encoding UTF8 -Value ".agent-1c/branch-archives/"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Encoding UTF8 -Value "master config"
            Set-Content -LiteralPath (Join-Path $tempRoot "docs\удалить меня.txt") -Encoding UTF8 -Value "master file"
            & git -C $tempRoot add --all
            & git -C $tempRoot commit -m "master" *> $null
            & git -C $tempRoot branch -M master
            $masterCommit = (& git -C $tempRoot rev-parse HEAD).Trim()
            & git -C $tempRoot checkout --quiet -b itldev/reset
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Encoding UTF8 -Value "branch config"
            Remove-Item -LiteralPath (Join-Path $tempRoot "docs\удалить меня.txt")
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "openspec\changes\новая спека") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "openspec\changes\новая спека\spec.md") -Encoding UTF8 -Value "branch spec"
            & git -C $tempRoot add --all
            & git -C $tempRoot commit -m "branch work" *> $null
            $oldHead = (& git -C $tempRoot rev-parse HEAD).Trim()

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $script:DumpCalls = 0
                $state = [pscustomobject]@{ devBranch = "itldev/reset"; safeDevBranchName = "reset"; devBranchInfoBasePath = "C:\base"; infoBaseKind = "file" }
                function Get-MainWorktreePath { $tempRoot }
                function Invoke-Designer {
                    param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs)
                    $script:DumpCalls++
                    [IO.File]::WriteAllBytes([string]$DesignerArgs[1], [byte[]](1,2,3,4))
                }
                function Set-RunStage {}
                $archivePath = Join-Path (Join-Path (Get-DevBranchArchiveRoot) "reset") "fixture"
                $first = New-DevBranchResetArchive -State $state -MasterCommit $masterCommit -OldHead $oldHead -ArchivePath $archivePath
                $second = New-DevBranchResetArchive -State $state -MasterCommit $masterCommit -OldHead $oldHead -ArchivePath $archivePath
                $manifest = Read-Utf8Text -Path $first.manifestPath | ConvertFrom-Json
                $newHead = Set-DevBranchTreeToMasterCommit -MasterCommit $masterCommit
                [pscustomobject]@{
                    first = $first; second = $second; manifest = $manifest; dumpCalls = $script:DumpCalls; newHead = $newHead
                    newTree = (Get-GitOutput @("rev-parse", "HEAD^{tree}")).Trim()
                    masterTree = (Get-GitOutput @("rev-parse", "$masterCommit^{tree}")).Trim()
                    parent = (Get-GitOutput @("rev-parse", "HEAD^")).Trim()
                    message = (Get-GitOutput @("log", "-1", "--pretty=%s")).Trim()
                }
            }

            $result.dumpCalls | Should -Be 1
            $result.first.archivePath | Should -Be $result.second.archivePath
            $result.manifest.schemaVersion | Should -Be 1
            $result.manifest.masterTree | Should -Be $result.masterTree
            @($result.manifest.files.path) | Should -Contain "openspec/changes/новая спека/spec.md"
            @($result.manifest.deletedPaths) | Should -Contain "docs/удалить меня.txt"
            @($result.manifest.excludedConfigurationPaths) | Should -Contain "src/cf/Configuration.xml"
            $result.newTree | Should -Be $result.masterTree
            $result.parent | Should -Be $oldHead
            $result.message | Should -Be "chore: reset branch for next change"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects extension reset before checkpoint or mutation" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:CheckpointCalled = $false
            function Read-DevBranchState { [pscustomobject]@{ devBranch = "itldev/ext"; devBranchKind = "extension"; initializationStatus = "ready" } }
            function Assert-DevelopmentBranchWorktreeContext {}
            function Save-DevBranchCheckpoint { $script:CheckpointCalled = $true }
            $message = ""
            try { Reset-DevBranch 6>$null } catch { $message = $_.Exception.Message }
            [pscustomobject]@{ message = $message; checkpointCalled = $script:CheckpointCalled }
        }
        $result.message | Should -Match "RESET_DEV_BRANCH_EXTENSION_UNSUPPORTED"
        $result.checkpointCalled | Should -BeFalse
    }

    It "restores the reset seed and unbinds repository-backed branch copies before initialization" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:DesignerCalls = 0
            $script:DesignerArgs = @()
            $seed = [pscustomobject]@{ configurationFingerprint = "master-fingerprint" }
            function Restore-ExistingDevBranchFromSeed { $seed }
            function Get-SourceUsesRepository { $true }
            function Set-RunStage {}
            function Invoke-Designer {
                param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs)
                $script:DesignerCalls++
                $script:DesignerArgs = @($DesignerArgs)
            }
            $restored = Restore-ExistingDevBranchRuntimeFromSeed `
                -State ([pscustomobject]@{ devBranchInfoBasePath = "srv\branch"; infoBaseKind = "server" }) `
                -ExpectedConfigurationFingerprint "master-fingerprint"
            $cleared = @{}
            Add-DevBranchResetTransientStateClearUpdates -State ([pscustomobject]@{
                lastVanessaTestPort = 48151
                lastVerificationSkippedComponents = @("vanessa")
                lastResultPath = "old.cf"
                eventLogDebtStatus = "failed"
                devBranch = "itldev/reset"
            }) -Updates $cleared
            [pscustomobject]@{
                designerCalls = $script:DesignerCalls
                designerArgs = @($script:DesignerArgs)
                repositoryUnbound = [bool]$restored.repositoryUnbound
                fingerprint = [string]$restored.seed.configurationFingerprint
                cleared = $cleared
            }
        }

        $result.designerCalls | Should -Be 1
        @($result.designerArgs) | Should -Be @("/ConfigurationRepositoryUnbindCfg", "-force")
        $result.repositoryUnbound | Should -BeTrue
        $result.fingerprint | Should -Be "master-fingerprint"
        $result.cleared.lastVanessaTestPort | Should -Be 0
        @($result.cleared.lastVerificationSkippedComponents).Count | Should -Be 0
        $result.cleared.lastResultPath | Should -Be ""
        $result.cleared.eventLogDebtStatus | Should -Be ""
        $result.cleared.ContainsKey("devBranch") | Should -BeFalse
    }

    It "inherits fork verification only for the exact fresh snapshot contract" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $snapshot = [pscustomobject]@{
                sourceVerification = [pscustomobject]@{ isFreshPassed = $true; fingerprint = "v3|exact" }
                sourceEnvironmentFingerprint = "environment"
            }
            $exact = Get-DevBranchForkVerificationDecision -Snapshot $snapshot -TargetFingerprint "v3|exact" -TargetEnvironmentFingerprint "environment" -BaseRestoreProven $true
            $changedTree = Get-DevBranchForkVerificationDecision -Snapshot $snapshot -TargetFingerprint "v3|changed" -TargetEnvironmentFingerprint "environment" -BaseRestoreProven $true
            $changedEnvironment = Get-DevBranchForkVerificationDecision -Snapshot $snapshot -TargetFingerprint "v3|exact" -TargetEnvironmentFingerprint "other" -BaseRestoreProven $true
            $unprovenBase = Get-DevBranchForkVerificationDecision -Snapshot $snapshot -TargetFingerprint "v3|exact" -TargetEnvironmentFingerprint "environment" -BaseRestoreProven $false
            [pscustomobject]@{ exact = $exact; changedTree = $changedTree; changedEnvironment = $changedEnvironment; unprovenBase = $unprovenBase }
        }

        $result.exact.inherited | Should -BeTrue
        $result.changedTree.inherited | Should -BeFalse
        $result.changedEnvironment.inherited | Should -BeFalse
        $result.unprovenBase.inherited | Should -BeFalse
        $result.changedTree.reason | Should -Match "fingerprintMatches=False"
    }

    It "keeps fork evidence while replacing branch and runtime identity" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $source = [pscustomobject]@{
                devBranchName = "source"
                safeDevBranchName = "source"
                devBranch = "itldev/source"
                worktreePath = "C:\source"
                devBranchInfoBasePath = "C:\source-base"
                lastVerificationStatus = "passed"
                lastVerifiedFingerprint = "v3|exact"
                lastVerifiedReportPath = "C:\evidence\report.md"
                launcherInfoBaseId = "old-launcher"
                roctupMcpPid = 111
                roctupMcpPort = 48100
                vanessaMcpPid = 222
                publicationUrl = "http://old"
                lastVanessaTestPid = 333
            }
            $snapshot = [pscustomobject]@{
                targetBranchName = "fork"
                targetSafeName = "fork"
                targetGitBranch = "itldev/fork"
                targetWorktreePath = "C:\fork"
                sourceCommit = "abc123"
                forkId = "fork-id"
                sourceGitBranch = "itldev/source"
                sourceBranchName = "source"
                artifactSha256 = "sha"
                artifactKind = "file-1cd"
            }
            New-ForkedDevBranchState -SourceState $source -Snapshot $snapshot -TargetInfoBasePath "C:\fork-base" -TargetHistoryRoot "C:\fork\.agent-1c\fork-history\fork-id" -MainProjectRoot "C:\main"
        }

        $result.devBranch | Should -Be "itldev/fork"
        $result.devBranchInfoBasePath | Should -Be "C:\fork-base"
        $result.lastVerificationStatus | Should -Be "passed"
        $result.lastVerifiedFingerprint | Should -Be "v3|exact"
        $result.lastVerifiedReportPath | Should -Be "C:\evidence\report.md"
        $result.launcherInfoBaseId | Should -Be ""
        $result.roctupMcpPid | Should -Be ""
        $result.roctupMcpPort | Should -Be 0
        $result.vanessaMcpPid | Should -Be ""
        $result.publicationStatus | Should -Be "disabled"
        $result.publicationUrl | Should -Be ""
        $result.Contains("lastVanessaTestPid") | Should -BeFalse

        {
            & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                Assert-DevBranchForkInfoBaseIsolated `
                    -SourceState ([pscustomobject]@{ devBranchInfoBasePath = "C:\same-base" }) `
                    -Snapshot ([pscustomobject]@{ infoBaseKind = "file"; sourceGitBranch = "itldev/source"; targetGitBranch = "itldev/fork" }) `
                    -TargetInfoBasePath "C:\same-base\."
            }
        } | Should -Throw "*DEV_BRANCH_FORK_INFOBASE_NOT_ISOLATED*"
    }

    It "copies file fork bases atomically and preserves the DoNotCopy marker" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-fork-base-" + [guid]::NewGuid().ToString("N"))
        try {
            $sourcePath = Join-Path $tempRoot "snapshot"
            $targetPath = Join-Path $tempRoot "target"
            New-Item -ItemType Directory -Force -Path $sourcePath | Out-Null
            $artifactPath = Join-Path $sourcePath "1Cv8.1CD"
            [System.IO.File]::WriteAllBytes($artifactPath, [byte[]](1, 2, 3, 4, 5))
            Set-Content -LiteralPath (Join-Path $sourcePath "DoNotCopy.txt") -Encoding UTF8 -Value "keep"
            $sha = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()

            $result = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                Restore-DevBranchForkInfoBase -Snapshot ([pscustomobject]@{
                    infoBaseKind = "file"
                    artifactPath = $artifactPath
                    artifactSha256 = $sha
                    forkId = "atomic"
                }) -TargetInfoBasePath $targetPath
            }

            $result | Should -BeTrue
            (Get-FileHash -LiteralPath (Join-Path $targetPath "1Cv8.1CD") -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $sha
            Test-Path -LiteralPath (Join-Path $targetPath "DoNotCopy.txt") -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath "$targetPath.fork-partial-atomic" | Should -BeFalse
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "archives source event logs and referenced verification evidence with hashes" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-fork-history-" + [guid]::NewGuid().ToString("N"))
        try {
            $eventLogRoot = Join-Path $tempRoot "1Cv8Log"
            $historyRoot = Join-Path $tempRoot "history"
            $evidencePath = Join-Path $tempRoot "verification-report.md"
            New-Item -ItemType Directory -Force -Path $eventLogRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $eventLogRoot "20260831000000.lgp") -Encoding UTF8 -Value "historical log"
            Set-Content -LiteralPath $evidencePath -Encoding UTF8 -Value "fresh passed evidence"

            $history = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                function Get-DevBranchEventLogDirectory { $eventLogRoot }
                New-DevBranchForkHistorySnapshot `
                    -SourceState ([pscustomobject]@{
                        devBranch = "itldev/source"
                        devBranchName = "source"
                        safeDevBranchName = "source"
                        lastVerifiedReportPath = $evidencePath
                        roctupMcpPid = 123
                        publicationUrl = "http://source"
                        lastVanessaStatusPath = "C:\temporary-run\status.json"
                    }) `
                    -HistoryRoot $historyRoot `
                    -SourceCommit "source-commit" `
                    -EventLogBaseline ([pscustomobject]@{
                        reader = "fixture"
                        logDirectory = $eventLogRoot
                        errorCount = 1
                        signatures = @("sig-1")
                        durationMs = 5
                        cacheStatus = "hit"
                        cachePath = "cache.json"
                        sourceKey = "source"
                        segmentCount = 1
                    })
            }

            Test-Path -LiteralPath (Join-Path $historyRoot "event-log\20260831000000.lgp") -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $historyRoot "evidence\lastVerifiedReportPath") -PathType Leaf | Should -BeTrue
            $history.evidencePaths.lastVerifiedReportPath | Should -Be "evidence/lastVerifiedReportPath"
            @($history.files | Where-Object path -eq "event-log/20260831000000.lgp").Count | Should -Be 1
            @($history.files | Where-Object path -eq "evidence/lastVerifiedReportPath").Count | Should -Be 1
            $archivedState = Get-Content -LiteralPath (Join-Path $historyRoot "source-state.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            @($archivedState.PSObject.Properties.Name) | Should -Not -Contain "roctupMcpPid"
            @($archivedState.PSObject.Properties.Name) | Should -Not -Contain "publicationUrl"
            @($archivedState.PSObject.Properties.Name) | Should -Not -Contain "lastVanessaStatusPath"
            $archivedState.lastVerifiedReportPath | Should -Be "evidence/lastVerifiedReportPath"
            $historyManifest = Get-Content -LiteralPath (Join-Path $historyRoot "history-manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $historyManifest.sourceCommit | Should -Be "source-commit"
            $historyManifest.rawEventLogCopied | Should -BeTrue

            $targetProjectRoot = Join-Path $tempRoot "target-project"
            New-Item -ItemType Directory -Force -Path $targetProjectRoot | Out-Null
            $installedHistory = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $script:ProjectRoot = $targetProjectRoot
                Install-DevBranchForkHistory `
                    -Snapshot ([pscustomobject]@{ historyPath = $historyRoot; historyFiles = @($history.files); forkId = "history" }) `
                    -TargetHistoryRoot (Join-Path $targetProjectRoot ".agent-1c\fork-history\history")
            }
            Test-Path -LiteralPath (Join-Path $installedHistory "event-log\20260831000000.lgp") -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath "$installedHistory.partial-history" | Should -BeFalse
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "installs the exact fork dependency lock idempotently and rejects drift" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-fork-lock-" + [guid]::NewGuid().ToString("N"))
        try {
            $snapshotRoot = Join-Path $tempRoot "snapshot"
            $targetRoot = Join-Path $tempRoot "target"
            New-Item -ItemType Directory -Force -Path $snapshotRoot, $targetRoot | Out-Null
            $snapshotLockPath = Join-Path $snapshotRoot "dependency-lock.json"
            Set-Content -LiteralPath $snapshotLockPath -Encoding UTF8 -Value '{"mode":"locked"}'
            $sha = (Get-FileHash -LiteralPath $snapshotLockPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $snapshotDotEnvPath = Join-Path $snapshotRoot ".dev.env"
            Set-Content -LiteralPath $snapshotDotEnvPath -Encoding UTF8 -Value 'SETTING=source'
            $dotEnvSha = (Get-FileHash -LiteralPath $snapshotDotEnvPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $snapshot = [pscustomobject]@{
                dependencyLockPath = $snapshotLockPath
                dependencyLockSha256 = $sha
                dotEnvPath = $snapshotDotEnvPath
                dotEnvSha256 = $dotEnvSha
                forkId = "lock"
            }

            $result = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $first = Install-DevBranchForkDependencyLock -Snapshot $snapshot -TargetProjectRoot $targetRoot
                $second = Install-DevBranchForkDependencyLock -Snapshot $snapshot -TargetProjectRoot $targetRoot
                $dotEnv = Install-DevBranchForkDotEnv -Snapshot $snapshot -TargetProjectRoot $targetRoot
                [pscustomobject]@{ first = $first; second = $second; dotEnv = $dotEnv }
            }
            $result.first | Should -Be $result.second
            (Get-FileHash -LiteralPath $result.first -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $sha
            (Get-FileHash -LiteralPath $result.dotEnv -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $dotEnvSha

            Set-Content -LiteralPath $result.first -Encoding UTF8 -Value '{"mode":"changed"}'
            {
                & {
                    . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                    Install-DevBranchForkDependencyLock -Snapshot $snapshot -TargetProjectRoot $targetRoot
                }
            } | Should -Throw "*DEV_BRANCH_FORK_TARGET_DEPENDENCY_LOCK_MISMATCH*"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "exports a freshly verified dirty working tree without invoking the clean Git guard" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:CapturedManifest = $null
            $state = [pscustomobject]@{
                devBranch = "itldev/branch1"
                devBranchName = "branch1"
                safeDevBranchName = "branch1"
                devBranchInfoBasePath = "C:\base"
                infoBaseKind = "file"
            }

            function Read-DevBranchState { $state }
            function Assert-DevelopmentBranchWorktreeContext {}
            function Assert-DevBranchExtensionInitialized {}
            function Assert-SingleManagedExtensionArtifact {}
            function Assert-CleanGit { throw "clean Git guard must not run for result export" }
            function Sync-DevBranchContextToDotEnv {}
            function Get-DevBranchKind { "configuration" }
            function Get-ExportPath { "src/cf" }
            function Get-ConfigRepositoryTransferPlan {
                [pscustomobject]@{
                    baseCommit = "master-base"
                    items = @(
                        [pscustomobject]@{ name = "ОбщийМодуль.Полный"; scope = "full"; parts = @() },
                        [pscustomobject]@{ name = "Справочник.Частичный"; scope = "partial"; parts = @("модуль объекта") }
                    )
                    unresolvedPaths = @("src/cf/UnknownCollection/Неизвестно.xml")
                }
            }
            function Get-CurrentCommit { "base-commit" }
            function Get-GitCommitOrEmpty { "master-commit" }
            function Get-VerificationState {
                [pscustomobject]@{
                    status = "passed"
                    effectiveStatus = "passed"
                    isFreshPassed = $true
                    verifiedCommit = "base-commit"
                    currentCommit = "base-commit"
                    verifiedFingerprint = "v3|fixture"
                    currentFingerprint = "v3|fixture"
                    verifiedAt = "2026-07-28T00:00:00Z"
                    reportPath = "report"
                    logPath = "log"
                    reason = "passed"
                }
            }
            function Confirm-UnverifiedProceed { $false }
            function New-ConfigDumpInfoLoadSnapshot { [pscustomobject]@{} }; function Restore-ConfigDumpInfoLoadSnapshot { $script:DumpInfoDirty = $false; $script:DumpInfoRestored = $true }; function Remove-ConfigDumpInfoLoadSnapshot {}
            function Invoke-DevBranchVanessaRuntimeRelease {}; function Assert-VanessaVerificationPreflight {}; function Use-ItlVerificationRepairAttempt {}; function Ensure-DevBranchEventLogBaseline { param([object]$State) $State }; function Ensure-DevBranchEventLogPendingCursor { [pscustomobject]@{ path = "cursor.json"; capturedAt = [datetime]"2026-07-28T00:00:00Z" } }; function Update-DevBranchBase { $script:DumpInfoDirty = $true }; function Invoke-ItlVerificationCycle { param([string]$Trigger, [string[]]$ExplicitComponents, [string]$EventLogCursorPath, [Nullable[datetime]]$EventLogBoundaryAt, [string]$EventLogCursorScope) $script:VerificationSawDirtyDumpInfo = $script:DumpInfoDirty }; function Complete-ItlVerificationRepairSession {}
            function Load-ConfigFromFiles {
                [pscustomobject]@{
                    currentCommit = "base-commit"
                    sourceFingerprint = "config-fingerprint"
                }
            }
            function New-LoadStateUpdates { @{} }; function Invoke-DevBranchEnterpriseAutoUpdateIfLoaded {}
            function Add-VerificationStaleIfNeeded {}; function Update-DevBranchState {}
            function Invoke-DevBranchMcpRestartAfterInfobaseLoad { param([object]$State) $State }; function Assert-DevBranchToolArtifactExportGuard {}
            function Export-DevBranchResultFile { "C:\Результаты работы\branch1.cf" }
            function Test-GitHasChanges { $true }
            function Get-VerificationWorkingTreeChangePaths { @("src/cf/Configuration.xml") }
            function Get-VerificationFingerprintScopePaths { @("src/cf", "src/cfe", "tests/features") }
            function New-ResultManifest {
                param(
                    [object]$State,
                    [string]$ResultPath,
                    [string]$ResultKind,
                    [string]$Operation,
                    [string]$MasterCommit,
                    [string]$DevBranchCommit,
                    [string]$SourceFingerprint,
                    [string]$VerificationFingerprint,
                    [object]$VerificationState,
                    [bool]$WorktreeClean,
                    [bool]$VerificationScopeCommitted,
                    [bool]$UnverifiedOverride,
                    [string]$VerificationDecision
                )
                $script:CapturedManifest = [pscustomobject]@{
                    resultPath = $ResultPath
                    devBranchCommit = $DevBranchCommit
                    sourceFingerprint = $SourceFingerprint
                    verificationFingerprint = $VerificationFingerprint
                    worktreeClean = $WorktreeClean
                    verificationScopeCommitted = $VerificationScopeCommitted
                }
                return "$ResultPath.manifest.json"
            }

            $script:DumpInfoDirty = $false; $script:DumpInfoRestored = $false; $script:VerificationSawDirtyDumpInfo = $true; Invoke-DevBranchCheck; $script:CheckDumpInfoRestored = $script:DumpInfoRestored; $script:DumpInfoRestored = $false; Export-DevBranchResult 6>$null
            $script:CapturedManifest | Add-Member -NotePropertyName runResultPath -NotePropertyValue $script:RunResultPath; $script:CapturedManifest | Add-Member -NotePropertyName runResultManifestPath -NotePropertyValue $script:RunResultManifestPath
            $script:CapturedManifest | Add-Member -NotePropertyName userReport -NotePropertyValue $script:RunUserReport; $script:CapturedManifest | Add-Member -NotePropertyName checkDumpInfoRestored -NotePropertyValue $script:CheckDumpInfoRestored
            $script:CapturedManifest | Add-Member -NotePropertyName verificationSawDirtyDumpInfo -NotePropertyValue $script:VerificationSawDirtyDumpInfo
            $script:CapturedManifest | Add-Member -NotePropertyName dumpInfoRestored -NotePropertyValue $script:DumpInfoRestored
            return $script:CapturedManifest
        }

        $result.resultPath | Should -Be "C:\Результаты работы\branch1.cf"
        $result.runResultPath | Should -Be "C:\Результаты работы\branch1.cf"
        $result.runResultManifestPath | Should -Be "C:\Результаты работы\branch1.cf.manifest.json"
        $result.userReport | Should -Match ([regex]::Escape("Файл: C:\Результаты работы\branch1.cf"))
        $result.userReport | Should -Match ([regex]::Escape("Манифест: C:\Результаты работы\branch1.cf.manifest.json"))
        $result.userReport | Should -Match ([regex]::Escape("## Перенос в хранилище конфигурации"))
        $result.userReport | Should -Match ([regex]::Escape("- ОбщийМодуль.Полный"))
        $result.userReport | Should -Match ([regex]::Escape("- Справочник.Частичный: модуль объекта"))
        $result.userReport | Should -Match ([regex]::Escape("- src/cf/UnknownCollection/Неизвестно.xml"))
        $result.devBranchCommit | Should -Be "base-commit"
        $result.sourceFingerprint | Should -Be "config-fingerprint"
        $result.verificationFingerprint | Should -Be "v3|fixture"; $result.checkDumpInfoRestored | Should -BeTrue; $result.verificationSawDirtyDumpInfo | Should -BeFalse; $result.dumpInfoRestored | Should -BeTrue
        $result.worktreeClean | Should -BeFalse
        $result.verificationScopeCommitted | Should -BeFalse
    }

    It "rejects stale result evidence before loading configuration files" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:LoadAttempted = $false
            $state = [pscustomobject]@{
                devBranch = "itldev/branch1"
                devBranchInfoBasePath = "C:\base"
                infoBaseKind = "file"
            }

            function Read-DevBranchState { $state }
            function Assert-DevelopmentBranchWorktreeContext {}
            function Assert-DevBranchExtensionInitialized {}
            function Assert-SingleManagedExtensionArtifact {}
            function Sync-DevBranchContextToDotEnv {}
            function Get-VerificationState {
                [pscustomobject]@{
                    status = "passed"
                    effectiveStatus = "stale"
                    isFreshPassed = $false
                    currentFingerprint = "v3|current"
                }
            }
            function Confirm-UnverifiedProceed { throw "stale evidence rejected early" }
            function Load-ConfigFromFiles { $script:LoadAttempted = $true; throw "load must not run" }

            $message = ""
            try {
                Export-DevBranchResult 6>$null
            } catch {
                $message = $_.Exception.Message
            }
            [pscustomobject]@{ message = $message; loadAttempted = $script:LoadAttempted }
        }

        $result.message | Should -Be "stale evidence rejected early"
        $result.loadAttempted | Should -BeFalse
    }

    It "applies fresh warn and block result policy without changing the close override contract" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $stale = [pscustomobject]@{ isFreshPassed = $false; effectiveStatus = "stale"; reason = "changed"; verifiedAt = ""; verifiedCommit = ""; currentCommit = "current"; reportPath = "" }
            $fresh = [pscustomobject]@{ isFreshPassed = $true; effectiveStatus = "passed" }

            function Get-VerificationPolicy { "warn" }
            $freshDecision = Confirm-UnverifiedProceed -State ([pscustomobject]@{}) -Operation "export-dev-branch-result" -VerificationState $fresh -ProceedOnWarn 6>$null
            $warnDecision = Confirm-UnverifiedProceed -State ([pscustomobject]@{}) -Operation "export-dev-branch-result" -VerificationState $stale -ProceedOnWarn 6>$null
            $closeFailure = ""
            try { Confirm-UnverifiedProceed -State ([pscustomobject]@{}) -Operation "close-dev-branch" -VerificationState $stale 6>$null | Out-Null } catch { $closeFailure = $_.Exception.Message }

            function Get-VerificationPolicy { "block" }
            $blockFailure = ""
            try { Confirm-UnverifiedProceed -State ([pscustomobject]@{}) -Operation "export-dev-branch-result" -VerificationState $stale -ProceedOnWarn 6>$null | Out-Null } catch { $blockFailure = $_.Exception.Message }
            [pscustomobject]@{ fresh = $freshDecision; warn = $warnDecision; closeFailure = $closeFailure; blockFailure = $blockFailure }
        }

        $result.fresh | Should -BeFalse
        $result.warn | Should -BeFalse
        $result.closeFailure | Should -Match "explicit unverified override"
        $result.blockFailure | Should -Match "verificationPolicy=block"
    }

    It "records dirty working-tree provenance and verification fingerprints in result manifests" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-result-manifest-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $artifactPath = Join-Path $tempRoot "result.cf"
            Set-Content -LiteralPath $artifactPath -Encoding UTF8 -Value "artifact"

            $manifestPath = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                function Get-VerificationState {
                    [pscustomobject]@{
                        status = "passed"
                        effectiveStatus = "passed"
                        isFreshPassed = $true
                        verifiedCommit = "base-commit"
                        currentCommit = "base-commit"
                        verifiedFingerprint = "v3|checked"
                        currentFingerprint = "v3|checked"
                        verifiedAt = "2026-07-28T00:00:00Z"
                        reportPath = "report"
                        logPath = "log"
                        reason = "passed"
                    }
                }
                function Get-DevBranchKind { "configuration" }
                $script:LastLogPath = "latest.log"
                New-ResultManifest `
                    -State ([pscustomobject]@{ devBranchName = "branch1"; safeDevBranchName = "branch1"; devBranch = "itldev/branch1" }) `
                    -ResultPath $artifactPath `
                    -ResultKind cf `
                    -Operation export-dev-branch-result `
                    -MasterCommit master-commit `
                    -DevBranchCommit base-commit `
                    -SourceFingerprint config-fingerprint `
                    -VerificationFingerprint "v3|checked" `
                    -WorktreeClean $false `
                    -VerificationScopeCommitted $false
            }
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

            $manifest.schemaVersion | Should -Be 3
            $manifest.commits.developmentBase | Should -Be "base-commit"
            $manifest.source.provenance | Should -Be "working-tree"
            $manifest.source.worktreeClean | Should -BeFalse
            $manifest.source.verificationScopeCommitted | Should -BeFalse
            $manifest.source.configFingerprint | Should -Be "config-fingerprint"
            $manifest.source.verificationFingerprint | Should -Be "v3|checked"
            $manifest.verification.verifiedFingerprint | Should -Be "v3|checked"
            $manifest.verification.currentFingerprint | Should -Be "v3|checked"
            $manifest.verification.policy | Should -Be "warn"
            $manifest.verification.decision | Should -Be "fresh-passed"
            $manifest.unverifiedOverride | Should -BeFalse
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "keeps configuration and extension designer fingerprints independent" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null

            $state = [ordered]@{
                lastConfigDesignerFingerprint = "config-old"
                lastConfigDesignerLoadedAt = "2026-07-01T10:00:00Z"
                lastExtensionDesignerFingerprint = "extension-old"
                lastExtensionDesignerLoadedAt = "2026-07-01T11:00:00Z"
            }
            $newLoadResult = {
                param([string]$Fingerprint, [string]$Commit)
                return [pscustomobject]@{
                    currentCommit = $Commit
                    listFile = "C:\logs\load.txt"
                    lastLogPath = "C:\logs\1c.log"
                    loaded = $true
                    configLoadStatus = "passed"
                    loadModeUsed = "partial"
                    partialLogPath = "C:\logs\1c.log"
                    fullFallbackLogPath = ""
                    partialError = ""
                    fullFallbackError = ""
                    sourceFingerprint = $Fingerprint
                    loadReason = "source-fingerprint-changed"
                    designerInvoked = $true
                    enterpriseInvoked = $false
                }
            }

            $configUpdates = New-LoadStateUpdates -LoadResult (& $newLoadResult "config-new" "config-head") -ContentKind configuration
            foreach ($key in $configUpdates.Keys) { $state[$key] = $configUpdates[$key] }
            $afterConfig = [pscustomobject]@{
                configFingerprint = $state.lastConfigDesignerFingerprint
                configLoadedAt = $state.lastConfigDesignerLoadedAt
                extensionFingerprint = $state.lastExtensionDesignerFingerprint
                extensionLoadedAt = $state.lastExtensionDesignerLoadedAt
                wroteExtensionFingerprint = $configUpdates.ContainsKey("lastExtensionDesignerFingerprint")
                wroteExtensionLoadedAt = $configUpdates.ContainsKey("lastExtensionDesignerLoadedAt")
            }

            $configLoadedAtAfterConfig = $state.lastConfigDesignerLoadedAt
            $extensionUpdates = New-LoadStateUpdates -LoadResult (& $newLoadResult "extension-new" "extension-head") -ContentKind extension
            foreach ($key in $extensionUpdates.Keys) { $state[$key] = $extensionUpdates[$key] }
            $afterExtension = [pscustomobject]@{
                configFingerprint = $state.lastConfigDesignerFingerprint
                configLoadedAt = $state.lastConfigDesignerLoadedAt
                extensionFingerprint = $state.lastExtensionDesignerFingerprint
                extensionLoadedAt = $state.lastExtensionDesignerLoadedAt
                configLoadedAtAfterConfig = $configLoadedAtAfterConfig
                wroteConfigFingerprint = $extensionUpdates.ContainsKey("lastConfigDesignerFingerprint")
                wroteConfigLoadedAt = $extensionUpdates.ContainsKey("lastConfigDesignerLoadedAt")
            }

            [pscustomobject]@{ afterConfig = $afterConfig; afterExtension = $afterExtension }
        }

        $result.afterConfig.configFingerprint | Should -Be "config-new"
        $result.afterConfig.configLoadedAt | Should -Not -Be "2026-07-01T10:00:00Z"
        $result.afterConfig.extensionFingerprint | Should -Be "extension-old"
        $result.afterConfig.extensionLoadedAt | Should -Be "2026-07-01T11:00:00Z"
        $result.afterConfig.wroteExtensionFingerprint | Should -BeFalse
        $result.afterConfig.wroteExtensionLoadedAt | Should -BeFalse

        $result.afterExtension.configFingerprint | Should -Be "config-new"
        $result.afterExtension.configLoadedAt | Should -Be $result.afterExtension.configLoadedAtAfterConfig
        $result.afterExtension.extensionFingerprint | Should -Be "extension-new"
        $result.afterExtension.extensionLoadedAt | Should -Not -Be "2026-07-01T11:00:00Z"
        $result.afterExtension.wroteConfigFingerprint | Should -BeFalse
        $result.afterExtension.wroteConfigLoadedAt | Should -BeFalse
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

    It "routes lifecycle Git path-list commands through the NUL-safe helper" {
        $HelperText | Should -Not -Match 'Get-GitOutput\s+@\(\s*"diff"\s*,\s*"--name-only"'
        $HelperText | Should -Not -Match 'Get-GitOutput\s+@\(\s*"(?:ls-files|ls-tree)"'
        $HelperText | Should -Match 'Get-GitPathList\s+-Arguments\s+@\(\s*"ls-tree"\s*,\s*"-r"\s*,\s*"--name-only"\s*,\s*"-z"'
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

    It "routes refresh and close through resumable merge validation before loading config files" {
        foreach ($functionName in @("Invoke-RefreshDevBranchCore", "Close-DevBranch")) {
            $match = [regex]::Match($HelperText, "(?s)function\s+$functionName\s*\{(?<body>.*?)(?=`r?`nfunction\s+)")
            $match.Success | Should -Be $true
            $body = $match.Groups["body"].Value
            $resumeIndex = $body.IndexOf("Resume-DevBranchLifecycleMergeIfPresent")
            $cleanIndex = $body.IndexOf("Assert-CleanGit")
            $mergeIndex = $body.IndexOf("Invoke-NewDevBranchLifecycleMerge")
            $postMergeIndex = $body.IndexOf("Assert-DevBranchLifecycleMergePostMerge")
            $loadIndex = $body.IndexOf('Load-ConfigFromFiles')

            $resumeIndex | Should -BeGreaterOrEqual 0
            $cleanIndex | Should -BeGreaterThan $resumeIndex
            $mergeIndex | Should -BeGreaterOrEqual 0
            $body | Should -Match 'if \(\$LifecyclePhase -ne "post-merge"\)'
            $body | Should -Not -Match "Restart-Agent1cIfWorkflowHelperChangedSince"
            $postMergeIndex | Should -BeGreaterThan $mergeIndex
            $loadIndex | Should -BeGreaterThan $postMergeIndex
        }
    }

    It "reconciles a verified failed-refresh recovery before another refresh or after check verification" {
        $refreshMatch = [regex]::Match($HelperText, "(?s)function\s+Invoke-RefreshDevBranchCore\s*\{(?<body>.*?)(?=`r?`nfunction\s+Refresh-DevBranch\s*\{)")
        $refreshMatch.Success | Should -BeTrue
        $refreshBody = $refreshMatch.Groups["body"].Value
        $refreshReconcileIndex = $refreshBody.IndexOf("Complete-PendingDevBranchRefreshAfterVerifiedRecovery")
        $refreshResumeIndex = $refreshBody.IndexOf("Resume-DevBranchLifecycleMergeIfPresent")
        $refreshReconcileIndex | Should -BeGreaterOrEqual 0
        $refreshResumeIndex | Should -BeGreaterThan $refreshReconcileIndex

        $checkMatch = [regex]::Match($HelperText, "(?s)function\s+Invoke-DevBranchCheck\s*\{(?<body>.*?)(?=`r?`nfunction\s+Check-DevBranch\s*\{)")
        $checkMatch.Success | Should -BeTrue
        $checkBody = $checkMatch.Groups["body"].Value
        $verificationIndex = $checkBody.IndexOf("Invoke-ItlVerificationCycle")
        $checkReconcileIndex = $checkBody.IndexOf("Complete-PendingDevBranchRefreshAfterVerifiedRecovery")
        $verificationIndex | Should -BeGreaterOrEqual 0
        $checkReconcileIndex | Should -BeGreaterThan $verificationIndex
    }

    It "clears a pending merge transaction only after the operation-specific post-merge work succeeds" {
        $refreshMatch = [regex]::Match($HelperText, "(?s)function\s+Invoke-RefreshDevBranchCore\s*\{(?<body>.*?)(?=`r?`nfunction\s+Refresh-DevBranch\s*\{)")
        $refreshMatch.Success | Should -BeTrue
        $refreshBody = $refreshMatch.Groups["body"].Value
        $refreshClearIndex = $refreshBody.IndexOf("Add-PendingDevBranchMergeClearUpdates")
        $refreshPostconditionIndex = $refreshBody.IndexOf("Complete-RefreshConfigDumpInfoPostcondition")
        $refreshUpdateIndex = $refreshBody.IndexOf("Update-DevBranchState", $refreshClearIndex)
        $refreshClearIndex | Should -BeGreaterThan $refreshPostconditionIndex
        $refreshUpdateIndex | Should -BeGreaterThan $refreshClearIndex

        $closeMatch = [regex]::Match($HelperText, "(?s)function\s+Close-DevBranch\s*\{(?<body>.*?)(?=`r?`nfunction\s+)")
        $closeMatch.Success | Should -BeTrue
        $closeBody = $closeMatch.Groups["body"].Value
        $closeClearIndex = $closeBody.IndexOf("Add-PendingDevBranchMergeClearUpdates")
        $closeExportIndex = $closeBody.IndexOf("Export-DevBranchResultFile")
        $closeFinalUpdateIndex = $closeBody.IndexOf("Update-DevBranchState", $closeClearIndex)
        $closeClearIndex | Should -BeGreaterThan $closeExportIndex
        $closeFinalUpdateIndex | Should -BeGreaterThan $closeClearIndex
    }

    It "writes the refresh user report only after MCP reconciliation" {
        $match = [regex]::Match($HelperText, "(?s)function\s+Invoke-RefreshDevBranchCore\s*\{(?<body>.*?)(?=`r?`nfunction\s+)")
        $match.Success | Should -Be $true
        $body = $match.Groups["body"].Value
        $reconcileIndex = $body.IndexOf('Invoke-AiRules1cManagedMcpConfigReconcile -Operation "$OperationName MCP reconcile"')
        $reportIndex = $body.IndexOf('Write-DevBranchRunUserReport -State $updatedState')
        $completeIndex = $body.IndexOf('Set-RunStage -Stage "$OperationName.complete"')

        $reconcileIndex | Should -BeGreaterOrEqual 0
        $reportIndex | Should -BeGreaterThan $reconcileIndex
        $completeIndex | Should -BeGreaterThan $reportIndex
        $body | Should -Match ([regex]::Escape("-Operation refreshed -LoadResult `$loadResult"))
    }

    It "synchronizes the pinned Vanessa runtime before refreshing a branch infobase" {
        $match = [regex]::Match($HelperText, "(?s)function\s+Invoke-RefreshDevBranchCore\s*\{(?<body>.*?)(?=`r?`nfunction\s+Refresh-DevBranch\s*\{)")
        $match.Success | Should -BeTrue
        $body = $match.Groups["body"].Value
        $installIndex = $body.IndexOf("Install-VanessaAutomation")
        $loadIndex = $body.IndexOf("Load-ConfigFromFiles")

        $installIndex | Should -BeGreaterOrEqual 0
        $loadIndex | Should -BeGreaterThan $installIndex
    }

    It "routes branch master synchronization through the main worktree helper first" {
        $match = [regex]::Match($HelperText, "(?s)function\s+Sync-Master\s*\{(?<body>.*?)(?=`r?`nfunction\s+)")
        $match.Success | Should -Be $true
        $body = $match.Groups["body"].Value
        $reexecIndex = $body.IndexOf("Restart-Agent1cFromMainWorktreeIfNeeded")
        $delegateIndex = $body.IndexOf("Invoke-InProjectContext")
        $reexecIndex | Should -BeGreaterOrEqual 0
        $delegateIndex | Should -BeGreaterThan $reexecIndex
    }

    It "routes the authoritative Sync-Master export through the specialized index rebuild" {
        $match = [regex]::Match($HelperText, "(?s)function\s+Sync-Master\s*\{(?<body>.*?)(?=`r?`nfunction\s+)")
        $match.Success | Should -BeTrue
        $body = $match.Groups["body"].Value

        ([regex]::Matches($body, "Commit-AuthoritativeExportPathIfChanged")).Count | Should -Be 1
        $body | Should -Match ([regex]::Escape('-ExportPath $dumpResult.exportPath'))
        $body | Should -Not -Match 'Commit-IfChanged[^\r\n]+\$dumpResult\.exportPath'
    }

    It "leaves Designer liveness before fingerprint, seed, and commit work" {
        $sync = [regex]::Match($HelperText, "(?s)function\s+Sync-Master\s*\{(?<body>.*?)(?=`r?`nfunction\s+)")
        $seed = [regex]::Match($HelperText, "(?s)function\s+New-BranchSeed\s*\{(?<body>.*?)(?=`r?`nfunction\s+)")
        $sync.Success | Should -BeTrue
        $seed.Success | Should -BeTrue

        $syncBody = $sync.Groups["body"].Value
        $seedBody = $seed.Groups["body"].Value
        $syncBody | Should -Match '(?s)sync-master\.dump-config.*?Dump-ConfigToFiles.*?sync-master\.fingerprint.*?Get-ConfigSourceFingerprint.*?sync-master\.seed.*?Ensure-BranchSeed'
        $syncBody | Should -Match '(?s)sync-master\.commit.*?Commit-AuthoritativeExportPathIfChanged'
        $seedBody | Should -Match '(?s)seed\.dump-config.*?Dump-ConfigToFilesFromInfoBase.*?seed\.fingerprint.*?Get-ConfigSourceFingerprint'
        $seedBody | Should -Match '(?s)seed\.hash-artifact.*?Get-FileHash.*?seed\.finalize.*?Write-BranchSeedManifest'
        $seedBody | Should -Match '(?s)seed\.complete.*?Read-BranchSeedManifest'
    }

    It "activates 1C byte preservation only with an authoritative dump commit" {
        $init = [regex]::Match($HelperText, "(?s)function\s+Initialize-Project\s*\{(?<body>.*?)(?=`r?`nfunction\s+Sync-Master\s*\{)")
        $update = [regex]::Match($HelperText, "(?s)function\s+Update-WorkflowPackage\s*\{(?<body>.*?)(?=`r?`nfunction\s+)")
        $commit = [regex]::Match($HelperText, "(?s)function\s+Commit-AuthoritativeExportPathIfChanged\s*\{(?<body>.*?)(?=`r?`nfunction\s+)")
        $resume = [regex]::Match($HelperText, "(?s)function\s+Resume-DevBranchLifecycleMergeIfPresent\s*\{(?<body>.*?)(?=`r?`nfunction\s+)")

        $init.Success | Should -BeTrue
        $update.Success | Should -BeTrue
        $commit.Success | Should -BeTrue
        $resume.Success | Should -BeTrue
        $init.Groups["body"].Value | Should -Match "Commit-AuthoritativeExportPathIfChanged"
        $update.Groups["body"].Value | Should -Not -Match "Ensure-OneCSourceGitAttributes"
        $commit.Groups["body"].Value | Should -Match "Ensure-OneCSourceGitAttributes"
        $commit.Groups["body"].Value | Should -Match "Rebuild-OneCSourceGitIndex"
        $resume.Groups["body"].Value | Should -Match "Test-GitWorktreePathDiffersOnlyByCarriageReturnsAtEol"
        $resume.Groups["body"].Value | Should -Match "Complete-OneCSourceByteContractMergeTransition"
    }

    It "rebuilds the authoritative export index for case-only renames in both directions" {
        $renameCases = @(
            [pscustomobject]@{ oldName = "удалить_Тест"; newName = "Удалить_Тест" },
            [pscustomobject]@{ oldName = "Удалить_Тест"; newName = "удалить_Тест" }
        )

        foreach ($renameCase in $renameCases) {
            $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-authoritative-case-" + [guid]::NewGuid().ToString("N"))
            try {
                New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
                & git -C $tempRoot init --quiet
                & git -C $tempRoot config user.email "itl-tests@example.invalid"
                & git -C $tempRoot config user.name "ITL Tests"
                & git -C $tempRoot config core.ignorecase true
                & git -C $tempRoot config core.fsmonitor true

                $oldFile = "src/cf/Плановые задания/$($renameCase.oldName).xml"
                $oldNestedFile = "src/cf/Плановые задания/$($renameCase.oldName)/Ext/Расписание.xml"
                $newFile = "src/cf/Плановые задания/$($renameCase.newName).xml"
                $newNestedFile = "src/cf/Плановые задания/$($renameCase.newName)/Ext/Расписание.xml"
                $oldFilePath = Join-Path $tempRoot ($oldFile.Replace("/", "\"))
                $oldNestedFilePath = Join-Path $tempRoot ($oldNestedFile.Replace("/", "\"))
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $oldNestedFilePath) | Out-Null
                [System.IO.File]::WriteAllText($oldFilePath, "old", [System.Text.UTF8Encoding]::new($false))
                [System.IO.File]::WriteAllText($oldNestedFilePath, "old nested", [System.Text.UTF8Encoding]::new($false))
                & git -C $tempRoot add --all --force -- src/cf
                & git -C $tempRoot commit --quiet -m "baseline"
                & git -C $tempRoot status --short | Out-Null

                $stagedExportPath = Join-Path $tempRoot (".tx-stage-" + [guid]::NewGuid().ToString("N") + "\cf")
                $newFilePath = Join-Path $stagedExportPath ($newFile.Substring("src/cf/".Length).Replace("/", "\"))
                $newNestedFilePath = Join-Path $stagedExportPath ($newNestedFile.Substring("src/cf/".Length).Replace("/", "\"))
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $newNestedFilePath) | Out-Null
                [System.IO.File]::WriteAllText($newFilePath, "new", [System.Text.UTF8Encoding]::new($false))
                [System.IO.File]::WriteAllText($newNestedFilePath, "new nested", [System.Text.UTF8Encoding]::new($false))
                Move-Item -LiteralPath (Join-Path $tempRoot "src\cf") -Destination (Join-Path $tempRoot (".tx-backup-" + [guid]::NewGuid().ToString("N")))
                Move-Item -LiteralPath $stagedExportPath -Destination (Join-Path $tempRoot "src\cf")

                $result = & {
                    . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                    $firstCommitted = Commit-AuthoritativeExportPathIfChanged -Message "sync: authoritative case rename" -ExportPath "src/cf"
                    $treePaths = @(Get-GitPathList -Arguments @("ls-tree", "-r", "--name-only", "-z", "HEAD", "--", "src/cf"))
                    $indexPaths = @(Get-GitPathList -Arguments @("ls-files", "-z", "--", "src/cf"))
                    $secondCommitted = Commit-AuthoritativeExportPathIfChanged -Message "sync: idempotent repeat" -ExportPath "src/cf"
                    [pscustomobject]@{
                        firstCommitted = $firstCommitted
                        secondCommitted = $secondCommitted
                        treePaths = $treePaths
                        indexPaths = $indexPaths
                        commitCount = [int](Get-GitOutput @("rev-list", "--count", "HEAD"))
                    }
                }

                $result.firstCommitted | Should -BeTrue
                $result.secondCommitted | Should -BeFalse
                $result.commitCount | Should -Be 2
                @($result.treePaths) | Should -HaveCount 2
                @($result.indexPaths) | Should -HaveCount 2
                @($result.treePaths | Where-Object { $_ -ceq $oldFile -or $_ -ceq $oldNestedFile }) | Should -HaveCount 0
                @($result.treePaths | Where-Object { $_ -ceq $newFile -or $_ -ceq $newNestedFile }) | Should -HaveCount 2
                $caseInsensitivePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($trackedPath in @($result.treePaths)) {
                    $caseInsensitivePaths.Add($trackedPath) | Should -BeTrue
                }
            } finally {
                if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                    & git -C $tempRoot fsmonitor--daemon stop *> $null
                    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    It "preserves platform bytes with autocrlf true and migrates a changed Cyrillic branch path" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ИТЛ source bytes с пробелом " + [guid]::NewGuid().ToString("N"))
        $checkoutRoot = Join-Path $tempRoot "checkout с пробелом"
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            & git -C $tempRoot init --quiet
            & git -C $tempRoot config user.email "itl-tests@example.invalid"
            & git -C $tempRoot config user.name "ITL Tests"
            & git -C $tempRoot config core.autocrlf true

            $cfDirectory = Join-Path $tempRoot "src\cf\Каталог с пробелом"
            $cfeDirectory = Join-Path $tempRoot "src\cfe\Расширение с пробелом\Ext"
            $auxiliaryDirectory = Join-Path $tempRoot "src\configs\Обмен с пробелом\cf"
            New-Item -ItemType Directory -Force -Path $cfDirectory, $cfeDirectory, $auxiliaryDirectory | Out-Null
            $branchPath = "src/cf/Каталог с пробелом/Модуль.bsl"
            $lfPath = "src/cf/Каталог с пробелом/Только LF.xml"
            $mixedPath = "src/cf/Каталог с пробелом/Смешанный.xml"
            $binaryPath = "src/cfe/Расширение с пробелом/Ext/Данные.bin"
            $auxiliaryPath = "src/configs/Обмен с пробелом/cf/Модуль.bsl"
            $utf8 = [System.Text.UTF8Encoding]::new($false)
            $baseBranchBytes = $utf8.GetBytes("Строка1`r`nСтрока2`r`n")
            $branchBytes = $utf8.GetBytes("Строка1`r`nИзменение ветки`r`n")
            $lfBytes = $utf8.GetBytes("<root>`n  <value>ЛФ</value>`n</root>`n")
            $mixedBytes = $utf8.GetBytes("<root>`r`n  <value>mixed</value>`n</root>`r`n")
            $binaryBytes = [byte[]](0, 13, 10, 255, 1, 10, 2, 13, 10, 0)
            $baseAuxiliaryBytes = $utf8.GetBytes("Строка1`r`nИсходный обмен`r`n")
            $branchAuxiliaryBytes = $utf8.GetBytes("Строка1`r`nИзменение обмена`r`n")
            $legacyAttributes = @(
                "*.md text eol=lf",
                "# BEGIN ITL MANAGED: preserve 1C source bytes",
                "src/cf/** -text",
                "src/cfe/** -text",
                "# END ITL MANAGED: preserve 1C source bytes"
            ) -join "`n"
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot ".gitattributes"), $utf8.GetBytes($legacyAttributes + "`n"))
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot ($branchPath.Replace("/", "\"))), $baseBranchBytes)
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot ($lfPath.Replace("/", "\"))), $lfBytes)
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot ($mixedPath.Replace("/", "\"))), $mixedBytes)
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot ($binaryPath.Replace("/", "\"))), $binaryBytes)
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot ($auxiliaryPath.Replace("/", "\"))), $baseAuxiliaryBytes)
            & git -C $tempRoot add --all
            & git -C $tempRoot commit --quiet -m "baseline before byte contract"
            & git -C $tempRoot branch "itldev/байты"

            $masterCommitted = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Commit-AuthoritativeExportPathIfChanged -Message "sync: install byte contract" -ExportPath "src/cf"
            }
            $masterCommitted | Should -BeTrue
            $masterCommit = (& git -C $tempRoot rev-parse HEAD).Trim()
            (& git -C $tempRoot check-attr text -- $branchPath) | Should -Match 'text: unset'
            (& git -C $tempRoot check-attr text -- $auxiliaryPath) | Should -Match 'text: unset'

            & git -C $tempRoot checkout --quiet "itldev/байты"
            & git -C $tempRoot reset --hard --quiet HEAD
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot ($branchPath.Replace("/", "\"))), $branchBytes)
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot ($auxiliaryPath.Replace("/", "\"))), $branchAuxiliaryBytes)
            & git -C $tempRoot add -- $branchPath $auxiliaryPath
            & git -C $tempRoot commit --quiet -m "branch source change"
            $branchCommit = (& git -C $tempRoot rev-parse HEAD).Trim()

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Assert-OneCConfigurationSourceIntegrity {}
                Merge-MasterPreservingBranchConfigDumpInfo -MasterBranch $masterCommit -BranchCommit $branchCommit
            }

            (& git -C $tempRoot status --porcelain) | Should -BeNullOrEmpty
            (& git -C $tempRoot rev-list --parents -n 1 HEAD).Trim().Split(' ').Count | Should -Be 3
            & git -C $tempRoot worktree add --detach --quiet $checkoutRoot HEAD
            $attributesText = [System.IO.File]::ReadAllText((Join-Path $checkoutRoot ".gitattributes"))
            $attributesText | Should -Match '^\*\.md text eol=lf'
            $attributesText | Should -Match 'src/configs/\*\* -text'
            $attributesText.TrimEnd() | Should -Match '# END ITL MANAGED: preserve 1C source bytes$'
            $expectedByPath = [ordered]@{
                $branchPath = $branchBytes
                $lfPath = $lfBytes
                $mixedPath = $mixedBytes
                $binaryPath = $binaryBytes
                $auxiliaryPath = $branchAuxiliaryBytes
            }
            foreach ($entry in $expectedByPath.GetEnumerator()) {
                $actual = [System.IO.File]::ReadAllBytes((Join-Path $checkoutRoot ($entry.Key.Replace("/", "\"))))
                [Convert]::ToBase64String($actual) | Should -Be ([Convert]::ToBase64String([byte[]]$entry.Value))
                (& git -C $checkoutRoot check-attr text -- $entry.Key) | Should -Match 'text: unset'
            }
        } finally {
            if (Test-Path -LiteralPath $checkoutRoot -ErrorAction SilentlyContinue) {
                & git -C $tempRoot worktree remove --force $checkoutRoot *> $null
            }
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                try { & git -C $tempRoot fsmonitor--daemon stop *> $null } catch {}
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "repairs mixed line endings only for changed 1C files with a homogeneous reference" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ИТЛ EOL с пробелом " + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf\Каталог с пробелом") | Out-Null
            & git -C $tempRoot init --quiet
            & git -C $tempRoot config user.email "itl-tests@example.invalid"
            & git -C $tempRoot config user.name "ITL Tests"
            & git -C $tempRoot config core.autocrlf true

            $crlfPath = "src/cf/Каталог с пробелом/CRLF модуль.bsl"
            $lfPath = "src/cf/Каталог с пробелом/LF описание.xml"
            $mixedPath = "src/cf/Каталог с пробелом/Смешанный эталон.xml"
            $binaryPath = "src/cf/Каталог с пробелом/Двоичный.xml"
            $newPath = "src/cf/Каталог с пробелом/Новый модуль.bsl"
            $utf8 = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot ".gitattributes"), $utf8.GetBytes("src/cf/** -text`n"))
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot ($crlfPath.Replace("/", "\"))), $utf8.GetBytes("Строка1`r`nСтрока2`r`n"))
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot ($lfPath.Replace("/", "\"))), $utf8.GetBytes("<root>`n  <value>base</value>`n</root>`n"))
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot ($mixedPath.Replace("/", "\"))), $utf8.GetBytes("<root>`r`n  <value>base</value>`n</root>`r`n"))
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot ($binaryPath.Replace("/", "\"))), [byte[]](0, 13, 10, 255, 10, 0))
            & git -C $tempRoot add --all
            & git -C $tempRoot commit --quiet -m "homogeneous and ambiguous references"
            & git -C $tempRoot branch -M master
            $masterCommit = (& git -C $tempRoot rev-parse HEAD).Trim()
            & git -C $tempRoot checkout --quiet -b "itldev/eol"

            $changedCrlfBytes = $utf8.GetBytes("Строка1`r`nИзменение ветки`nСтрока3`r`n")
            $expectedCrlfBytes = $utf8.GetBytes("Строка1`r`nИзменение ветки`r`nСтрока3`r`n")
            $changedLfBytes = $utf8.GetBytes("<root>`n  <value>edit</value>`r`n</root>`n")
            $expectedLfBytes = $utf8.GetBytes("<root>`n  <value>edit</value>`n</root>`n")
            $changedMixedBytes = $utf8.GetBytes("<root>`r`n  <value>edit</value>`n</root>`r`n")
            $changedBinaryBytes = [byte[]](0, 13, 10, 254, 10, 0)
            $newBytes = $utf8.GetBytes("Новая1`nНовая2`n")
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot ($crlfPath.Replace("/", "\"))), $changedCrlfBytes)
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot ($lfPath.Replace("/", "\"))), $changedLfBytes)
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot ($mixedPath.Replace("/", "\"))), $changedMixedBytes)
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot ($binaryPath.Replace("/", "\"))), $changedBinaryBytes)
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot ($newPath.Replace("/", "\"))), $newBytes)

            $repaired = @(& {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Repair-OneCSourceLineEndings -SourcePaths @("src/cf") -ReferenceCommit $masterCommit
            })

            $repaired | Should -HaveCount 2
            $repaired | Should -Contain $crlfPath
            $repaired | Should -Contain $lfPath
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $tempRoot ($crlfPath.Replace("/", "\"))))) | Should -Be ([Convert]::ToBase64String($expectedCrlfBytes))
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $tempRoot ($lfPath.Replace("/", "\"))))) | Should -Be ([Convert]::ToBase64String($expectedLfBytes))
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $tempRoot ($mixedPath.Replace("/", "\"))))) | Should -Be ([Convert]::ToBase64String($changedMixedBytes))
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $tempRoot ($binaryPath.Replace("/", "\"))))) | Should -Be ([Convert]::ToBase64String($changedBinaryBytes))
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $tempRoot ($newPath.Replace("/", "\"))))) | Should -Be ([Convert]::ToBase64String($newBytes))

            $secondPass = @(& {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Repair-OneCSourceLineEndings -SourcePaths @("src/cf") -ReferenceCommit $masterCommit
            })
            $secondPass | Should -HaveCount 0
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                try { & git -C $tempRoot fsmonitor--daemon stop *> $null } catch {}
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "runs the narrow line-ending repair before lifecycle commits loads and transfer planning" {
        $checkpointBody = [regex]::Match($HelperText, '(?s)function Save-DevBranchCheckpoint\s*\{.*?(?=\r?\nfunction )').Value
        $updateBody = [regex]::Match($HelperText, '(?s)function Update-DevBranchBase\s*\{.*?(?=\r?\nfunction )').Value
        $lockBody = [regex]::Match($HelperText, '(?s)function Lock-ConfigRepositoryObjects\s*\{.*?(?=\r?\nfunction )').Value
        $exportBody = [regex]::Match($HelperText, '(?s)function Export-DevBranchResult\s*\{.*?(?=\r?\nfunction )').Value
        $resumeBody = [regex]::Match($HelperText, '(?s)function Resume-DevBranchLifecycleMergeIfPresent\s*\{.*?(?=\r?\nfunction )').Value
        $repairBody = [regex]::Match($HelperText, '(?s)function Repair-OneCSourceLineEndings\s*\{.*?(?=\r?\nfunction )').Value

        $repairBody | Should -Not -Match 'ls-tree.*?"-r"'
        $checkpointBody.IndexOf('Repair-OneCSourceLineEndings') | Should -BeLessThan $checkpointBody.IndexOf('Test-GitHasChanges')
        $updateBody.IndexOf('Repair-OneCSourceLineEndings') | Should -BeLessThan $updateBody.IndexOf('Sync-DevBranchContextToDotEnv')
        $lockBody.IndexOf('Repair-OneCSourceLineEndings') | Should -BeLessThan $lockBody.IndexOf('Get-ConfigRepositoryTransferPlan')
        $exportBody.IndexOf('Repair-OneCSourceLineEndings') | Should -BeLessThan $exportBody.IndexOf('Get-VerificationState')
        $resumeBody | Should -Match '(?s)Repair-OneCSourceLineEndings.*?-StageChanges.*?Invoke-Git\s+@\("commit",\s*"--no-edit"\)'
    }

    It "adds the managed crash-dump ignore before checkpoint staging" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ИТЛ checkpoint с пробелом " + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Encoding UTF8 -Value "custom.local"
            Set-Content -LiteralPath (Join-Path $tempRoot "user.txt") -Encoding UTF8 -Value "before"
            & git -C $tempRoot init -b master *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore user.txt
            & git -C $tempRoot commit -m init *> $null

            Set-Content -LiteralPath (Join-Path $tempRoot "user.txt") -Encoding UTF8 -Value "after"
            [System.IO.File]::WriteAllBytes((Join-Path $tempRoot "1cv8c_test.mdmp"), [byte[]](1, 2, 3, 4))
            $checkpoint = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Repair-OneCSourceLineEndings { return @() }
                Save-DevBranchCheckpoint -Operation "refresh-dev-branch"
            }

            $checkpoint | Should -Match '^[a-f0-9]{40}$'
            ((& git -C $tempRoot show "HEAD:user.txt") -join "`n").Trim() | Should -Be "after"
            @(& git -C $tempRoot ls-tree -r --name-only HEAD -- "*.mdmp") | Should -BeNullOrEmpty
            & git -C $tempRoot check-ignore --quiet -- "1cv8c_test.mdmp"
            $LASTEXITCODE | Should -Be 0
            (Get-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Encoding UTF8) | Should -Contain "*.mdmp"
            @(& git -C $tempRoot status --short) | Should -BeNullOrEmpty
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "does not continue when a later attributes rule overrides the managed byte contract" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-attributes-override-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $attributesPath = Join-Path $tempRoot ".gitattributes"
            $text = @(
                "# BEGIN ITL MANAGED: preserve 1C source bytes",
                "src/cf/** -text",
                "src/cfe/** -text",
                "# END ITL MANAGED: preserve 1C source bytes",
                "src/cf/** text eol=lf"
            ) -join "`n"
            [System.IO.File]::WriteAllText($attributesPath, $text, [System.Text.UTF8Encoding]::new($false))

            {
                & {
                    . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                    Ensure-OneCSourceGitAttributes | Out-Null
                }
            } | Should -Throw "ITL_GIT_ATTRIBUTES_MANAGED_BLOCK_INVALID*"
            [System.IO.File]::ReadAllText($attributesPath) | Should -BeExactly $text
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects a real authoritative index collision before a commit" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-authoritative-collision-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            & git -C $tempRoot init --quiet
            & git -C $tempRoot config user.email "itl-tests@example.invalid"
            & git -C $tempRoot config user.name "ITL Tests"
            & git -C $tempRoot config core.ignorecase true

            $lowerPath = "src/cf/Плановые задания/объект.xml"
            $upperPath = "src/cf/Плановые задания/Объект.xml"
            $physicalPath = Join-Path $tempRoot ($lowerPath.Replace("/", "\"))
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $physicalPath) | Out-Null
            [System.IO.File]::WriteAllText($physicalPath, "lower", [System.Text.UTF8Encoding]::new($false))
            & git -C $tempRoot add --all --force -- src/cf
            & git -C $tempRoot commit --quiet -m "baseline"

            $intermediatePath = "$physicalPath.case-rename"
            $upperPhysicalPath = Join-Path $tempRoot ($upperPath.Replace("/", "\"))
            [System.IO.File]::Move($physicalPath, $intermediatePath)
            [System.IO.File]::Move($intermediatePath, $upperPhysicalPath)
            [System.IO.File]::WriteAllText($upperPhysicalPath, "upper", [System.Text.UTF8Encoding]::new($false))
            $upperBlob = ((& git -C $tempRoot hash-object -w -- $upperPhysicalPath) -join "").Trim()
            & git -C $tempRoot update-index --add --cacheinfo "100644,$upperBlob,$upperPath"

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $pathsBefore = @(Get-GitPathList -Arguments @("ls-files", "-z", "--", "src/cf"))
                $threw = $false
                $message = ""
                try {
                    Assert-GitAuthoritativeExportPathHasNoCaseCollisions -ExportPath "src/cf"
                } catch {
                    $threw = $true
                    $message = $_.Exception.Message
                }
                [pscustomobject]@{
                    pathsBefore = $pathsBefore
                    threw = $threw
                    message = $message
                    commitCount = [int](Get-GitOutput @("rev-list", "--count", "HEAD"))
                }
            }

            @($result.pathsBefore) | Should -HaveCount 2
            $result.threw | Should -BeTrue
            $result.message | Should -Match "GIT_CASE_COLLISION_IN_AUTHORITATIVE_DUMP"
            $result.message | Should -Match ([regex]::Escape($lowerPath))
            $result.message | Should -Match ([regex]::Escape($upperPath))
            $result.commitCount | Should -Be 1
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
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
                    -ConfigLoadMode Full `
                    -InstallVanessaIfMissing `
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
            $args | Should -Contain "-ConfigLoadMode"
            $args | Should -Contain "Full"
            $args | Should -Contain "-InstallVanessaIfMissing"
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

    It "reexecs a branch action through the main helper before master synchronization" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-main-helper-reexec-" + [guid]::NewGuid().ToString("N"))
        $mainRoot = Join-Path $tempRoot "main"
        $branchRoot = Join-Path $tempRoot "branch"
        try {
            $mainHelperPath = Join-Path $mainRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $mainHelperPath), $branchRoot | Out-Null
            Set-Content -LiteralPath $mainHelperPath -Encoding UTF8 -Value "# main helper"
            $result = & {
                . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                $script:Agent1cScriptPath = Join-Path $branchRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
                $script:CapturedScriptPath = ""
                $script:CapturedArguments = @()
                function Invoke-Agent1cFreshProcess {
                    param([string]$ScriptPath, [string[]]$AdditionalArguments)
                    $script:CapturedScriptPath = $ScriptPath
                    $script:CapturedArguments = @($AdditionalArguments)
                    throw "reexec-stop"
                }
                try {
                    Restart-Agent1cFromMainWorktreeIfNeeded -MainWorktreePath $mainRoot
                } catch {
                    if ($_.Exception.Message -ne "reexec-stop") { throw }
                }
                [pscustomobject]@{
                    scriptPath = $script:CapturedScriptPath
                    arguments = @($script:CapturedArguments)
                }
            }
            $result.scriptPath | Should -Be $mainHelperPath
            $result.arguments | Should -Be @("-LifecyclePhase", "main-helper")
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "hands the post-merge phase to the helper from the updated development branch" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-post-merge-handoff-" + [guid]::NewGuid().ToString("N"))
        $branchRoot = Join-Path $tempRoot "branch"
        try {
            $branchHelperPath = Join-Path $branchRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $branchHelperPath) | Out-Null
            Set-Content -LiteralPath $branchHelperPath -Encoding UTF8 -Value "# updated branch helper"
            $result = & {
                . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                $script:Agent1cScriptPath = Join-Path $tempRoot "main\.agents\skills\1c-workflow\scripts\agent-1c.ps1"
                $script:CapturedScriptPath = ""
                $script:CapturedArguments = @()
                function Invoke-Agent1cFreshProcess {
                    param([string]$ScriptPath, [string[]]$AdditionalArguments)
                    $script:CapturedScriptPath = $ScriptPath
                    $script:CapturedArguments = @($AdditionalArguments)
                    throw "handoff-stop"
                }
                try {
                    Restart-Agent1cAfterDevBranchMerge -Operation "refresh-dev-branch"
                } catch {
                    if ($_.Exception.Message -ne "handoff-stop") { throw }
                }
                [pscustomobject]@{
                    scriptPath = $script:CapturedScriptPath
                    arguments = @($script:CapturedArguments)
                }
            }
            $result.scriptPath | Should -Be $branchHelperPath
            $result.arguments | Should -Be @("-LifecyclePhase", "post-merge")
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "fails closed when the updated development branch helper is missing after merge" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-post-merge-missing-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $message = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Invoke-Agent1cFreshProcess { throw "unexpected reexec" }
                try {
                    Restart-Agent1cAfterDevBranchMerge -Operation "refresh-dev-branch-lite"
                } catch {
                    $_.Exception.Message
                }
            }
            $message | Should -Match "DEV_BRANCH_POST_MERGE_HELPER_MISSING"
            $message | Should -Match "refresh-dev-branch-lite"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "accepts the main-helper lifecycle phase emitted by a stale branch helper" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-main-helper-phase-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $args = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help -LifecyclePhase main-helper *> $null
                Get-Agent1cReexecArguments
            }

            $args | Should -Contain "-LifecyclePhase"
            $args | Should -Contain "main-helper"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "does not reexec again after the action is already running through the main helper" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-main-helper-no-loop-" + [guid]::NewGuid().ToString("N"))
        $mainRoot = Join-Path $tempRoot "main"
        try {
            $mainHelperPath = Join-Path $mainRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $mainHelperPath) | Out-Null
            Set-Content -LiteralPath $mainHelperPath -Encoding UTF8 -Value "# main helper"
            $calls = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help -LifecyclePhase main-helper *> $null
                $script:Agent1cScriptPath = $mainHelperPath
                $script:FreshProcessCalls = 0
                function Invoke-Agent1cFreshProcess { $script:FreshProcessCalls++ }
                Restart-Agent1cFromMainWorktreeIfNeeded -MainWorktreePath $mainRoot
                $script:FreshProcessCalls
            }

            $calls | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps every emitted lifecycle phase inside the entrypoint ValidateSet contract" {
        $tokens = $null
        $parseErrors = $null
        $entryAst = [System.Management.Automation.Language.Parser]::ParseFile($HelperPath, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $phaseParameter = @($entryAst.ParamBlock.Parameters | Where-Object {
            $_.Name.VariablePath.UserPath -eq "LifecyclePhase"
        })[0]
        $validateSet = @($phaseParameter.Attributes | Where-Object {
            $_.TypeName.Name -eq "ValidateSet"
        })[0]
        $allowedPhases = @($validateSet.PositionalArguments | ForEach-Object { [string]$_.SafeGetValue() })

        $emittedPhases = [System.Collections.Generic.List[string]]::new()
        $scriptsRoot = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts"
        $phasePattern = '["'']-LifecyclePhase["'']\s*,\s*["''](?<phase>[^"'']+)["'']'
        foreach ($file in @(Get-ChildItem -LiteralPath $scriptsRoot -Recurse -File -Filter "*.ps1")) {
            $fileTokens = $null
            $fileErrors = $null
            $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$fileTokens, [ref]$fileErrors)
            @($fileErrors).Count | Should -Be 0
            $commands = $fileAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq "Invoke-Agent1cFreshProcess"
            }, $true)
            foreach ($command in @($commands)) {
                foreach ($match in @([regex]::Matches($command.Extent.Text, $phasePattern))) {
                    $phase = [string]$match.Groups["phase"].Value
                    if (-not $emittedPhases.Contains($phase)) {
                        $emittedPhases.Add($phase) | Out-Null
                    }
                }
            }
        }

        @($emittedPhases | Sort-Object) | Should -Be @("main-helper", "post-copy", "post-merge")
        foreach ($phase in $emittedPhases) {
            $allowedPhases | Should -Contain $phase
        }
    }

    It "seeds fingerprints only after a real branch copy and invalidates both kinds after restore" {
        $lifecycleText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1") -Raw -Encoding UTF8
        $lifecycleText | Should -Match '(?s)if \(\$copyPerformed\)\s*\{.*?lastConfigDesignerFingerprint.*?loadReason"\] = "branch-copy-seed"'
        $lifecycleText | Should -Match '(?s)function Restore-ReleaseE2EInfobaseSnapshot.*?lastConfigDesignerFingerprint = "".*?lastExtensionDesignerFingerprint = "".*?loadReason = "release-e2e-restore-invalidated".*?vanessaMcpSafeModeProof = \$null'
        $lifecycleText | Should -Match '(?s)if \(\$currentStatus -eq "enterprise-normalization-pending"\).*?return.*?if \(\$copyPerformed\)'
    }

    It "preserves paired application proof only for an immutable Release snapshot restore" {
        $snapshotPath = Join-Path ([IO.Path]::GetTempPath()) ("itl-release-restore-" + [guid]::NewGuid().ToString("N") + ".dt")
        try {
            [IO.File]::WriteAllBytes($snapshotPath, [byte[]](1, 2, 3))
            $updates = & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help -ReleaseSnapshotPath $snapshotPath -PreserveReleaseSnapshotApplicationProof *> $null
                $script:CapturedRestoreUpdates = $null
                $state = [pscustomobject]@{
                    devBranchName = "release"
                    devBranchKind = "configuration"
                    devBranchInfoBasePath = "C:\base"
                    infoBaseKind = "file"
                    lastConfigDesignerFingerprint = "config-proof"
                    lastConfigDesignerTreeObjectId = ("a" * 40)
                    lastConfigDesignerLoadedAt = "2026-08-19T00:00:00Z"
                    lastExtensionDesignerFingerprint = "extension-proof"
                    lastExtensionDesignerTreeObjectId = ("b" * 40)
                    lastExtensionDesignerLoadedAt = "2026-08-19T00:01:00Z"
                    sourceFingerprint = "config-proof"
                    configLoadStatus = "passed"
                    loadReason = "source-fingerprint-changed"
                    enterpriseNormalizationStatus = "passed"
                    enterpriseNormalizedAt = "2026-08-19T00:02:00Z"
                    enterpriseNormalizationReason = "config-load"
                    enterpriseNormalizationError = ""
                }
                function Read-DevBranchState { $state }
                function Assert-DevelopmentBranchWorktreeContext {}
                function Assert-DevBranchKind {}
                function Require-Value {}
                function Assert-ExportPathInsideProject { $snapshotPath }
                function Restore-DevBranchInfobaseFromSnapshot {}
                function Update-DevBranchState { param([object]$State, [hashtable]$Updates); $script:CapturedRestoreUpdates = $Updates }
                function Sync-DevBranchContextToDotEnv {}

                Restore-ReleaseE2EInfobaseSnapshot *> $null
                $script:CapturedRestoreUpdates
            }

            $updates.lastConfigDesignerFingerprint | Should -Be "config-proof"
            $updates.lastConfigDesignerTreeObjectId | Should -Be ("a" * 40)
            $updates.lastExtensionDesignerFingerprint | Should -Be "extension-proof"
            $updates.configLoadStatus | Should -Be "passed"
            $updates.enterpriseNormalizationStatus | Should -Be "passed"
            $updates.vanessaMcpSafeModeProof | Should -BeNullOrEmpty
            $updates.designerInvoked | Should -BeFalse
            $updates.enterpriseInvoked | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $snapshotPath -Force -ErrorAction SilentlyContinue
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
        $HelperText | Should -Match "TestClientPort"
        $HelperText | Should -Not -Match ([regex]::Escape('$args += @("/TESTMANAGER", "-TPort"'))
        $HelperText | Should -Match "New-VanessaStartFeaturePlayerCommand"
        $HelperText | Should -Match "StartFeaturePlayer;VAParams="
        $HelperText | Should -Match "Get-OneCProcessInfo"
        $HelperText | Should -Match "Stop-OwnHungVanessaTestClients"
        $HelperText | Should -Match "Invoke-ForeignVanessaTestProcessPolicy"
        $HelperText | Should -Match "Write-ForeignVanessaTestProcessWarning"
        $HelperText | Should -Match "Test-VanessaTestPortUsedByForeignProcess"
        $HelperText | Should -Match "VANESSA_TEST_FOREIGN_WAIT_MODE"
        $HelperText | Should -Match "ConvertFrom-Utf8Base64"
        $HelperText | Should -Match '(?s)function Run-DevBranchTests.*?Assert-VanessaSourceBuildArchiveMatchesActivePin.*?\$vanessa = Get-VanessaAutomationState'

        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "VANESSA_TEST_PORT_RANGE=48051\.\.48150"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "VANESSA_TEST_FOREIGN_WAIT_MODE=warn"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "VANESSA_TEST_TIMEOUT_SECONDS=1800"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "VANESSA_EVENT_LOG_READER=auto"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "SOURCE_EVENT_LOG_BASELINE_ENABLED=true"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "SOURCE_SERVER_EVENT_LOG_LOOKBACK_DAYS=7"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Not -Match "(?m)^SOURCE_EVENT_LOG_LOOKBACK_DAYS="
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "SOURCE_EVENT_LOG_BOOTSTRAP_TAIL_BYTES=1048576"
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

    It "decodes fixed sequential fields and LGF dictionaries without treating numeric identifiers as levels" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-event-log-sequential-test-" + [guid]::NewGuid().ToString("N"))
        try {
            $logDir = Join-Path $tempRoot "ib\1Cv8Log"
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
            Set-Content -LiteralPath (Join-Path $logDir "1Cv8.lgf") -Encoding UTF8 -Value @(
                '1CV8LOG(ver 2.0)',
                'e4812c1b-b1d6-442c-bb53-080a84446ada',
                '{4,"_$Transaction$_.Begin",14}',
                '{4,"_$Transaction$_.Commit",15}',
                '{4,"_$PerformError$_",48}',
                '{5,5f3b5089-9a85-4a36-be4a-52aa6b96d0ae,"Справочник.упо_НастройкиМонитораПроекта",117}'
            )
            Set-Content -LiteralPath (Join-Path $logDir "20260817.lgp") -Encoding UTF8 -Value @(
                '{20260823120000,C,{2455583283b90,b79c},4,1,4,2,14,I,"",0,{"U"},"",0,0,0,8,0,{0}}',
                '{20260823120001,C,{2455583283b90,b79c},4,1,4,2,15,I,"",0,{"U"},"",0,0,0,8,0,{0}}',
                '{20260823120002,N,{0,0},4,1,4,2,48,E,"Ошибка фонового задания 12345678",117,{"U"},"Проект 42",0,0,0,8,0,{0}}'
            )

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    infoBaseKind = "file"
                    devBranchInfoBasePath = (Join-Path $tempRoot "ib")
                    stateProjectRoot = $tempRoot
                }

                $errors = @(Read-OneCEventLogDirect -State $state -Levels @("Error"))
                $errors.Count | Should -Be 1
                $errors[0].event | Should -BeExactly '_$PerformError$_'
                $errors[0].metadata | Should -BeExactly "Справочник.упо_НастройкиМонитораПроекта"
                $errors[0].dataPresentation | Should -BeExactly "Проект 42"
                $errors[0].comment | Should -BeExactly "Ошибка фонового задания 12345678"

                $information = @(Read-OneCEventLogDirect -State $state -Levels @("Info"))
                $information.Count | Should -Be 2
                @($information.event) | Should -Be @('_$Transaction$_.Begin', '_$Transaction$_.Commit')
                @($information.signature) | Should -Not -Contain "649f11d64972b14969c1908f6f6e732782124851b6d3ecbc0b66cc5dcf993b68"
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "reads only the active tail and new event-log segments from a run cursor" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-event-log-cursor-test-" + [guid]::NewGuid().ToString("N"))
        try {
            $logDir = Join-Path $tempRoot "ib\1Cv8Log"
            $runDir = Join-Path $tempRoot "run"
            New-Item -ItemType Directory -Force -Path $logDir, $runDir | Out-Null
            Set-Content -LiteralPath (Join-Path $logDir "1Cv8.lgf") -Encoding UTF8 -Value "{1}"
            $historical = Join-Path $logDir "20260702.lgp"
            $active = Join-Path $logDir "20260703.lgp"
            Set-Content -LiteralPath $historical -Encoding UTF8 -Value '{20260702100000,E,"_$PerformError$_","Catalog.Items","Old","Historical"}'
            Set-Content -LiteralPath $active -Encoding UTF8 -Value @(
                '{20260703100000,E,"_$PerformError$_","Catalog.Items","Old","Before cursor 1"}',
                '{20260703100100,E,"_$PerformError$_","Catalog.Items","Old","Before cursor 2"}'
            )

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    infoBaseKind = "file"
                    devBranchInfoBasePath = (Join-Path $tempRoot "ib")
                    stateProjectRoot = $tempRoot
                }
                $cursorPath = Join-Path $runDir "event-log-cursor.json"
                New-DevBranchEventLogCursor -State $state -Path $cursorPath | Out-Null
                Add-Content -LiteralPath (Join-Path $logDir "1Cv8.lgf") -Encoding UTF8 -Value "{2}"
                Add-Content -LiteralPath $active -Encoding UTF8 -Value '{20260703115959,E,"_$PerformError$_","Catalog.Items","New","After cursor with earlier clock"}'
                Add-Content -LiteralPath $active -Encoding UTF8 -Value '{20260703120500,E,"_$PerformError$_","Catalog.Items","New","After cursor"}'
                $newSegment = Join-Path $logDir "20260704.lgp"
                Set-Content -LiteralPath $newSegment -Encoding UTF8 -Value '{20260704120500,E,"_$PerformError$_","Catalog.Items","New","Rotated"}'

                $read = Read-DevBranchEventLogErrors -State $state `
                    -StartTime ([datetime]"2026-07-03T12:00:00") `
                    -EndTime ([datetime]"2026-07-04T12:30:00") `
                    -CursorPath $cursorPath
                $read.scanMode | Should -Be "cursor"
                $read.errorCount | Should -Be 3
                @($read.events.comment) | Should -Contain "After cursor with earlier clock"
                @($read.events.comment) | Should -Contain "After cursor"
                @($read.events.comment) | Should -Contain "Rotated"
                $read.scannedBytes | Should -BeLessThan ((Get-Item $historical).Length + (Get-Item $active).Length + (Get-Item $newSegment).Length)

                New-DevBranchEventLogCursor -State $state -Path $cursorPath | Out-Null
                Set-Content -LiteralPath $newSegment -Encoding UTF8 -Value "{}"
                $truncated = Get-DevBranchEventLogDeltaSelection -State $state -CursorPath $cursorPath -FallbackStartTime ([datetime]"2026-07-03T12:00:00") 6>$null
                $truncated.mode | Should -Be "fallback"

                Set-Content -LiteralPath $cursorPath -Encoding UTF8 -Value "{broken"
                $mystery = Join-Path $logDir "unknown-segment.lgp"
                Set-Content -LiteralPath $mystery -Encoding UTF8 -Value '{20260703121000,E,"_$PerformError$_","Catalog.Items","New","Unknown segment"}'
                (Get-Item $historical).LastWriteTimeUtc = [datetime]"2026-07-02T01:00:00Z"
                (Get-Item $active).LastWriteTimeUtc = [datetime]"2026-07-02T01:00:00Z"
                (Get-Item $newSegment).LastWriteTimeUtc = [datetime]"2026-07-02T01:00:00Z"
                (Get-Item $mystery).LastWriteTimeUtc = [datetime]"2026-07-02T01:00:00Z"
                $fallback = Get-DevBranchEventLogDeltaSelection -State $state -CursorPath $cursorPath -FallbackStartTime ([datetime]"2026-07-03T12:00:00") 6>$null
                $fallback.mode | Should -Be "fallback"
                $selectedNames = @($fallback.selections | ForEach-Object { Split-Path -Leaf $_.path })
                $selectedNames | Should -Not -Contain "20260702.lgp"
                $selectedNames | Should -Contain "20260703.lgp"
                $selectedNames | Should -Contain "20260704.lgp"
                $selectedNames | Should -Contain "unknown-segment.lgp"
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps the oldest branch event-log cursor pending until verification completes" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-event-log-pending-test-" + [guid]::NewGuid().ToString("N"))
        try {
            $logDir = Join-Path $tempRoot "ib\1Cv8Log"
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
            Set-Content -LiteralPath (Join-Path $logDir "1Cv8.lgf") -Encoding UTF8 -Value "{1}"
            $active = Join-Path $logDir "20260703.lgp"
            Set-Content -LiteralPath $active -Encoding UTF8 -Value '{20260703100000,I,"Start"}'

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchName = "Current Branch"
                    safeDevBranchName = "current-branch"
                    infoBaseKind = "file"
                    devBranchInfoBasePath = (Join-Path $tempRoot "ib")
                    stateProjectRoot = $tempRoot
                }

                $first = Ensure-DevBranchEventLogPendingCursor -State $state -Reason "separate-update"
                $firstText = Get-Content -LiteralPath $first.path -Raw -Encoding UTF8
                Add-Content -LiteralPath $active -Encoding UTF8 -Value '{20260703100500,E,"_$PerformError$_","Catalog.Items","New","Between update and check"}'
                $second = Ensure-DevBranchEventLogPendingCursor -State $state -Reason "check"
                (Get-Content -LiteralPath $second.path -Raw -Encoding UTF8) | Should -BeExactly $firstText
                $second.created | Should -BeFalse

                $updates = Complete-DevBranchEventLogObservation -State $state -Status "failed" -Fingerprint "v3|broken" -ReportPath "errors.json"
                $updates.eventLogDebtStatus | Should -Be "failed"
                $updates.eventLogDebtFingerprint | Should -Be "v3|broken"
                (Get-Content -LiteralPath $first.path -Raw -Encoding UTF8) | Should -Not -BeExactly $firstText
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "does not clear event-log debt on an unchanged command retry" {
        & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $state = [pscustomobject]@{
                eventLogDebtStatus = "failed"
                eventLogDebtFingerprint = "v3|same"
                eventLogDebtReportPath = "old-errors.json"
            }
            $passed = [pscustomobject]@{ status = "passed"; reason = "clean"; newErrorCount = 0 }

            $command = Resolve-DevBranchEventLogDebt -State $state -Verification $passed -Fingerprint "v3|same" -Trigger "command"
            $command.verification.status | Should -Be "failed"
            $command.updates.eventLogDebtStatus | Should -Be "failed"

            $repair = Resolve-DevBranchEventLogDebt -State $state -Verification $passed -Fingerprint "v3|same" -Trigger "repair"
            $repair.verification.status | Should -Be "passed"
            $repair.updates.eventLogDebtStatus | Should -Be ""

            $changed = Resolve-DevBranchEventLogDebt -State $state -Verification $passed -Fingerprint "v3|fixed" -Trigger "command"
            $changed.verification.status | Should -Be "passed"
            $changed.updates.eventLogDebtStatus | Should -Be ""
        }
    }

    It "migrates an existing branch from its baseline instead of accepting a cursor at upgrade time" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-event-log-migration-test-" + [guid]::NewGuid().ToString("N"))
        try {
            $logDir = Join-Path $tempRoot "ib\1Cv8Log"
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
            Set-Content -LiteralPath (Join-Path $logDir "1Cv8.lgf") -Encoding UTF8 -Value "{1}"
            Set-Content -LiteralPath (Join-Path $logDir "20260703.lgp") -Encoding UTF8 -Value '{20260703120500,E,"_$PerformError$_","Catalog.Items","New","Pre-upgrade error"}'

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchName = "Current Branch"
                    safeDevBranchName = "current-branch"
                    infoBaseKind = "file"
                    devBranchInfoBasePath = (Join-Path $tempRoot "ib")
                    stateProjectRoot = $tempRoot
                    eventLogBaselineCreatedAt = "2026-07-03T12:00:00Z"
                    lastVanessaEventLogCheckedUntil = "2026-07-03T12:10:00Z"
                }
                $pending = Ensure-DevBranchEventLogPendingCursor -State $state -Reason "upgrade"
                $cursor = Get-Content -LiteralPath $pending.path -Raw -Encoding UTF8 | ConvertFrom-Json
                $cursor.fallbackRequired | Should -BeTrue
                $cursor.boundaryKind | Should -Be "baseline-migration"
                ([datetime]$cursor.capturedAt).ToUniversalTime().ToString("o") | Should -Be "2026-07-03T12:00:00.0000000Z"

                $selection = Get-DevBranchEventLogDeltaSelection -State $state -CursorPath $pending.path -FallbackStartTime $pending.capturedAt 6>$null
                $selection.mode | Should -Be "fallback"
                @($selection.selections).Count | Should -Be 1
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "fails verification for an update error written before Vanessa starts" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-event-log-update-window-test-" + [guid]::NewGuid().ToString("N"))
        try {
            $logDir = Join-Path $tempRoot "ib\1Cv8Log"
            $runDir = Join-Path $tempRoot "run"
            New-Item -ItemType Directory -Force -Path $logDir, $runDir, (Join-Path $tempRoot ".agent-1c\event-log-baselines") | Out-Null
            Set-Content -LiteralPath (Join-Path $logDir "1Cv8.lgf") -Encoding UTF8 -Value "{1}"
            $active = Join-Path $logDir "20260703.lgp"
            Set-Content -LiteralPath $active -Encoding UTF8 -Value '{20260703115900,I,"Before update"}'
            $baselinePath = Join-Path $tempRoot ".agent-1c\event-log-baselines\current-branch.json"
            Set-Content -LiteralPath $baselinePath -Encoding UTF8 -Value '{"schemaVersion":2,"signatures":[]}'

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchName = "Current Branch"
                    safeDevBranchName = "current-branch"
                    infoBaseKind = "file"
                    devBranchInfoBasePath = (Join-Path $tempRoot "ib")
                    stateProjectRoot = $tempRoot
                    eventLogBaselinePath = $baselinePath
                }
                $pending = Ensure-DevBranchEventLogPendingCursor -State $state -Reason "update-dev-branch-base"
                Add-Content -LiteralPath $active -Encoding UTF8 -Value '{20260703120500,E,"_$PerformError$_","Catalog.Items","Update","Update failed before Vanessa"}'

                $verification = Test-DevBranchEventLogAfterVanessa `
                    -State $state `
                    -RunStartedAt ([datetime]"2026-07-03T12:10:00") `
                    -RunFinishedAt ([datetime]"2026-07-03T12:20:00") `
                    -RunDirectory $runDir `
                    -CursorPath $pending.path `
                    -BoundaryStartedAt ([datetime]"2026-07-03T12:00:00") `
                    -CursorScope "lifecycle-pending"

                $verification.status | Should -Be "failed"
                $verification.newErrorCount | Should -Be 1
                $verification.reason | Should -Match "Scope: lifecycle-pending"
                $report = Get-Content -LiteralPath $verification.reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $report.cursor.scope | Should -Be "lifecycle-pending"
                $report.cursor.sourceKey | Should -Be $pending.sourceKey
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "streams and caches event-log signatures per rotated segment" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-event-log-cache-test-" + [guid]::NewGuid().ToString("N"))

        try {
            $logDir = Join-Path $tempRoot "ib\1Cv8Log"
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
            Set-Content -LiteralPath (Join-Path $logDir "1Cv8.lgf") -Encoding UTF8 -Value "{1}"
            $segment1 = Join-Path $logDir "20260703.lgp"
            Set-Content -LiteralPath $segment1 -Encoding UTF8 -Value @(
                '{20260703100000,E,"_$PerformError$_","Catalog.Items",',
                '"Item 1","Legacy error"}',
                '{20260703100500,W,"_$PerformError$_","Catalog.Items","Item 1","Warning only"}'
            )

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchName = "Current Branch"
                    safeDevBranchName = "current-branch"
                    devBranch = "itldev/current-branch"
                    infoBaseKind = "file"
                    devBranchInfoBasePath = (Join-Path $tempRoot "ib")
                    stateProjectRoot = $tempRoot
                    mainWorktreePath = $tempRoot
                }

                $first = Read-DevBranchEventLogBaselineWithCache -State $state
                $first.cacheStatus | Should -Be "rebuilt"
                $first.errorCount | Should -Be 1
                $first.signatureCount | Should -Be 1
                $first.fullSegmentCount | Should -Be 1
                $first.appendSegmentCount | Should -Be 0
                $first.scannedBytes | Should -Be (Get-Item -LiteralPath $segment1).Length
                Test-Path -LiteralPath $first.cachePath -PathType Leaf | Should -BeTrue
                (Read-Utf8Text -Path $first.cachePath | ConvertFrom-Json).schemaVersion | Should -Be 2

                $hit = Read-DevBranchEventLogBaselineWithCache -State $state
                $hit.cacheStatus | Should -Be "hit"
                $hit.signatureCount | Should -Be 1
                $hit.scannedBytes | Should -Be 0

                $beforeAppendLength = (Get-Item -LiteralPath $segment1).Length
                Add-Content -LiteralPath $segment1 -Encoding UTF8 -Value '{20260703101000,E,"_$PerformError$_","Catalog.Items","Item 2","Changed error"}'
                (Get-Item -LiteralPath $segment1).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddSeconds(2)
                $changed = Read-DevBranchEventLogBaselineWithCache -State $state
                $changed.cacheStatus | Should -Be "updated"
                $changed.errorCount | Should -Be 2
                $changed.signatureCount | Should -Be 2
                $changed.appendSegmentCount | Should -Be 1
                $changed.fullSegmentCount | Should -Be 0
                $changed.scannedBytes | Should -Be ((Get-Item -LiteralPath $segment1).Length - $beforeAppendLength)
                $changed.scannedBytes | Should -BeLessThan (Get-Item -LiteralPath $segment1).Length

                Set-Content -LiteralPath $segment1 -Encoding UTF8 -Value '{20260703101500,E,"_$PerformError$_","Catalog.Items","Item 2","After truncation"}'
                $truncated = Read-DevBranchEventLogBaselineWithCache -State $state
                $truncated.cacheStatus | Should -Be "updated"
                $truncated.errorCount | Should -Be 1
                $truncated.fullSegmentCount | Should -Be 1
                $truncated.appendSegmentCount | Should -Be 0
                $truncated.scannedBytes | Should -Be (Get-Item -LiteralPath $segment1).Length

                $segment2 = Join-Path $logDir "20260704.lgp"
                Set-Content -LiteralPath $segment2 -Encoding UTF8 -Value '{20260704100000,E,"_$PerformError$_","Catalog.Items","Item 3","Rotated error"}'
                $added = Read-DevBranchEventLogBaselineWithCache -State $state
                $added.cacheStatus | Should -Be "updated"
                $added.errorCount | Should -Be 2

                Remove-Item -LiteralPath $segment1 -Force
                $rotated = Read-DevBranchEventLogBaselineWithCache -State $state
                $rotated.cacheStatus | Should -Be "updated"
                $rotated.errorCount | Should -Be 1
                $rotated.signatureCount | Should -Be 1

                Set-Content -LiteralPath $rotated.cachePath -Encoding UTF8 -Value "{broken"
                $rebuilt = Read-DevBranchEventLogBaselineWithCache -State $state 6>$null
                $rebuilt.cacheStatus | Should -Be "rebuilt"
                $rebuilt.errorCount | Should -Be 1

                $legacyCache = Read-Utf8Text -Path $rebuilt.cachePath | ConvertFrom-Json
                $legacyCache.schemaVersion = 1
                Write-Utf8Text -Path $rebuilt.cachePath -Value (($legacyCache | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
                $schemaRebuilt = Read-DevBranchEventLogBaselineWithCache -State $state 6>$null
                $schemaRebuilt.cacheStatus | Should -Be "rebuilt"
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "bounds the source baseline window and skips a damaged segment in best-effort mode" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-event-log-source-window-test-" + [guid]::NewGuid().ToString("N"))
        try {
            $logDir = Join-Path $tempRoot "ib\1Cv8Log"
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
            Set-Content -LiteralPath (Join-Path $logDir "1Cv8.lgf") -Encoding UTF8 -Value "{1}"
            $oldSegment = Join-Path $logDir "20260701.lgp"
            $recentSegment = Join-Path $logDir "20260708.lgp"
            $damagedSegment = Join-Path $logDir "20260709.lgp"
            $unknownOldSegment = Join-Path $logDir "legacy-segment.lgp"
            Set-Content -LiteralPath $oldSegment -Encoding UTF8 -Value '{20260701100000,E,"_$PerformError$_","Catalog.Items","Old","Outside segment window"}'
            Set-Content -LiteralPath $recentSegment -Encoding UTF8 -Value @(
                '{20260708100000,E,"_$PerformError$_","Catalog.Items","Old","Outside exact window"}',
                '{20260708130000,E,"_$PerformError$_","Catalog.Items","New","Inside exact window"}'
            )
            Set-Content -LiteralPath $damagedSegment -Encoding UTF8 -Value '{20260709100000,E,"_$PerformError$_","Catalog.Items","Broken","Incomplete"'
            Set-Content -LiteralPath $unknownOldSegment -Encoding UTF8 -Value '{20260708140000,E,"_$PerformError$_","Catalog.Items","Unknown","Old file"}'
            (Get-Item -LiteralPath $unknownOldSegment).LastWriteTime = [datetime]"2026-07-01T00:00:00"

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    infoBaseKind = "file"
                    devBranchInfoBasePath = (Join-Path $tempRoot "ib")
                    stateProjectRoot = $tempRoot
                    mainWorktreePath = $tempRoot
                }
                $result = Read-DevBranchEventLogBaselineWithCache `
                    -State $state `
                    -StartTime ([datetime]"2026-07-08T12:00:00") `
                    -BestEffort 6>$null

                $result.errorCount | Should -Be 1
                $result.signatureCount | Should -Be 1
                $result.segmentCount | Should -Be 1
                $result.failedSegmentCount | Should -Be 1
                @($result.failures.segment) | Should -Contain $damagedSegment
                $result.scannedBytes | Should -Be (Get-Item -LiteralPath $recentSegment).Length
                $cache = Read-Utf8Text -Path $result.cachePath | ConvertFrom-Json
                @($cache.segments.name) | Should -Be @("20260708.lgp")
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "uses only a bounded tail of the latest source segment and then reads append delta" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-event-log-source-latest-test-" + [guid]::NewGuid().ToString("N"))
        try {
            $logDir = Join-Path $tempRoot "ib\1Cv8Log"
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
            Set-Content -LiteralPath (Join-Path $logDir "1Cv8.lgf") -Encoding UTF8 -Value "{1}"
            Set-Content -LiteralPath (Join-Path $logDir "20260701.lgp") -Encoding UTF8 -Value "{broken previous segment"
            $latestSegment = Join-Path $logDir "20260708.lgp"
            $records = @(
                1..30 | ForEach-Object { '{2026070810' + $_.ToString('0000') + ',I,"_$Session$_","","","Routine"}' }
                '{20260708120000,E,"_$PerformError$_","Catalog.Items","Item 1","Latest error"}'
            )
            Set-Content -LiteralPath $latestSegment -Encoding UTF8 -Value $records

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    infoBaseKind = "file"
                    devBranchInfoBasePath = (Join-Path $tempRoot "ib")
                    stateProjectRoot = $tempRoot
                    mainWorktreePath = $tempRoot
                }
                $tailBytes = [int64]300
                $first = Read-SourceLatestEventLogBaselineWithCache -State $state -BootstrapTailBytes $tailBytes
                $first.segmentCount | Should -Be 1
                $first.cacheStatus | Should -Be "rebuilt"
                $first.scanMode | Should -Be "tail"
                $first.coverage | Should -Be "tail"
                $first.scannedBytes | Should -BeGreaterThan 0
                $first.scannedBytes | Should -BeLessOrEqual $tailBytes
                $first.errorCount | Should -Be 1
                $first.signatureCount | Should -Be 1
                $cache = Read-Utf8Text -Path $first.cachePath | ConvertFrom-Json
                $cache.schemaVersion | Should -Be 3
                $cache.scope | Should -Be "latest-segment"
                @($cache.segments).Count | Should -Be 1
                $cache.segments[0].name | Should -Be "20260708.lgp"

                $cache.schemaVersion = 2
                $cache.PSObject.Properties.Remove("scope")
                $cache.segments[0].PSObject.Properties.Remove("coverage")
                $cache.segments[0].PSObject.Properties.Remove("coverageStartOffset")
                Write-Utf8Text -Path $first.cachePath -Value (($cache | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
                $migrated = Read-SourceLatestEventLogBaselineWithCache -State $state -BootstrapTailBytes $tailBytes
                $migrated.cacheStatus | Should -Be "migrated"
                $migrated.scanMode | Should -Be "unchanged"
                $migrated.scannedBytes | Should -Be 0
                (Read-Utf8Text -Path $first.cachePath | ConvertFrom-Json).schemaVersion | Should -Be 3

                $hit = Read-SourceLatestEventLogBaselineWithCache -State $state -BootstrapTailBytes $tailBytes
                $hit.cacheStatus | Should -Be "hit"
                $hit.scanMode | Should -Be "unchanged"
                $hit.scannedBytes | Should -Be 0
                $hit.signatureCount | Should -Be 1

                $beforeAppendLength = (Get-Item -LiteralPath $latestSegment).Length
                Add-Content -LiteralPath $latestSegment -Encoding UTF8 -Value '{20260708120500,E,"_$PerformError$_","Catalog.Items","Item 2","Appended error"}'
                (Get-Item -LiteralPath $latestSegment).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddSeconds(2)
                $updated = Read-SourceLatestEventLogBaselineWithCache -State $state -BootstrapTailBytes $tailBytes
                $updated.cacheStatus | Should -Be "updated"
                $updated.scanMode | Should -Be "append"
                $updated.scannedBytes | Should -Be ((Get-Item -LiteralPath $latestSegment).Length - $beforeAppendLength)
                $updated.errorCount | Should -Be 2
                $updated.signatureCount | Should -Be 2
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "never falls back to a full source segment scan on cold start cache damage or rotation" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-event-log-source-tail-fallback-test-" + [guid]::NewGuid().ToString("N"))
        try {
            $logDir = Join-Path $tempRoot "ib\1Cv8Log"
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
            Set-Content -LiteralPath (Join-Path $logDir "1Cv8.lgf") -Encoding UTF8 -Value "{1}"
            $firstSegment = Join-Path $logDir "20260708.lgp"
            Set-Content -LiteralPath $firstSegment -Encoding UTF8 -Value @(
                1..40 | ForEach-Object { '{2026070810' + $_.ToString('0000') + ',I,"_$Session$_","","","Routine"}' }
                '{20260708120000,E,"_$PerformError$_","Catalog.Items","Item 1","First tail error"}'
            )

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    infoBaseKind = "file"
                    devBranchInfoBasePath = (Join-Path $tempRoot "ib")
                    stateProjectRoot = $tempRoot
                    mainWorktreePath = $tempRoot
                }
                $tailBytes = [int64]256
                $cold = Read-SourceLatestEventLogBaselineWithCache -State $state -BootstrapTailBytes $tailBytes
                $cold.scannedBytes | Should -BeLessOrEqual $tailBytes
                $cold.signatures.Count | Should -Be 1
                $firstSignature = [string]$cold.signatures[0]

                Set-Content -LiteralPath $cold.cachePath -Encoding UTF8 -Value "{broken"
                $damaged = Read-SourceLatestEventLogBaselineWithCache -State $state -BootstrapTailBytes $tailBytes 6>$null
                $damaged.cacheStatus | Should -Be "rebuilt"
                $damaged.scannedBytes | Should -BeLessOrEqual $tailBytes

                $cachedBeforeReplacement = Get-Item -LiteralPath $firstSegment
                $preservedLastWrite = $cachedBeforeReplacement.LastWriteTimeUtc
                $replacementBytes = [System.IO.File]::ReadAllBytes($firstSegment)
                for ($byteIndex = 0; $byteIndex -lt $replacementBytes.Length; $byteIndex++) {
                    if ($replacementBytes[$byteIndex] -eq 0x46) {
                        $replacementBytes[$byteIndex] = 0x58
                        break
                    }
                }
                [System.IO.File]::WriteAllBytes($firstSegment, $replacementBytes)
                (Get-Item -LiteralPath $firstSegment).LastWriteTimeUtc = $preservedLastWrite
                $replaced = Read-SourceLatestEventLogBaselineWithCache -State $state -BootstrapTailBytes $tailBytes
                $replaced.cacheStatus | Should -Be "rebuilt"
                $replaced.scanMode | Should -Be "tail"
                $replaced.scannedBytes | Should -BeLessOrEqual $tailBytes

                Set-Content -LiteralPath $firstSegment -Encoding UTF8 -Value "{broken previous segment"
                $nextSegment = Join-Path $logDir "20260715.lgp"
                Set-Content -LiteralPath $nextSegment -Encoding UTF8 -Value @(
                    1..40 | ForEach-Object { '{2026071510' + $_.ToString('0000') + ',I,"_$Session$_","","","Routine"}' }
                    '{20260715120000,E,"_$PerformError$_","Catalog.Items","Item 2","Rotated tail error"}'
                )
                $rotated = Read-SourceLatestEventLogBaselineWithCache -State $state -BootstrapTailBytes $tailBytes
                $rotated.scanMode | Should -Be "tail"
                $rotated.scannedBytes | Should -BeLessOrEqual $tailBytes
                $rotated.signatureCount | Should -Be 1
                @($rotated.signatures) | Should -Not -Contain $firstSignature

                Remove-Item -LiteralPath $rotated.cachePath -Force
                $empty = Read-SourceLatestEventLogBaselineWithCache -State $state -BootstrapTailBytes 0
                $empty.scanMode | Should -Be "empty-bootstrap"
                $empty.coverage | Should -Be "empty"
                $empty.scannedBytes | Should -Be 0
                $empty.signatureCount | Should -Be 0
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "disables source event-log reading through the dedicated switch" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-event-log-source-disabled-test-" + [guid]::NewGuid().ToString("N"))
        $oldEnabled = [Environment]::GetEnvironmentVariable("SOURCE_EVENT_LOG_BASELINE_ENABLED", "Process")
        $oldLookback = [Environment]::GetEnvironmentVariable("SOURCE_EVENT_LOG_LOOKBACK_DAYS", "Process")
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            [Environment]::SetEnvironmentVariable("SOURCE_EVENT_LOG_BASELINE_ENABLED", "false", "Process")
            [Environment]::SetEnvironmentVariable("SOURCE_EVENT_LOG_LOOKBACK_DAYS", $null, "Process")
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Get-InfoBaseKind { return "file" }
                function Get-SourceInfoBasePath { return (Join-Path $tempRoot "missing-source") }
                function Read-SourceLatestEventLogBaselineWithCache { throw "reader must not be called" }
                $baseline = Get-SourceEventLogSeedBaseline
                $baseline.reader | Should -Be "disabled"
                $baseline.lookbackDays | Should -BeNullOrEmpty
                $baseline.signatureCount | Should -Be 0
                $baseline.cache.status | Should -Be "disabled"
            }
        } finally {
            [Environment]::SetEnvironmentVariable("SOURCE_EVENT_LOG_BASELINE_ENABLED", $oldEnabled, "Process")
            [Environment]::SetEnvironmentVariable("SOURCE_EVENT_LOG_LOOKBACK_DAYS", $oldLookback, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps legacy zero lookback as a deprecated disable fallback" {
        $oldEnabled = [Environment]::GetEnvironmentVariable("SOURCE_EVENT_LOG_BASELINE_ENABLED", "Process")
        $oldLookback = [Environment]::GetEnvironmentVariable("SOURCE_EVENT_LOG_LOOKBACK_DAYS", "Process")
        try {
            [Environment]::SetEnvironmentVariable("SOURCE_EVENT_LOG_BASELINE_ENABLED", $null, "Process")
            [Environment]::SetEnvironmentVariable("SOURCE_EVENT_LOG_LOOKBACK_DAYS", "0", "Process")
            & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                Get-SourceEventLogBaselineEnabled 6>$null | Should -BeFalse
            }
        } finally {
            [Environment]::SetEnvironmentVariable("SOURCE_EVENT_LOG_BASELINE_ENABLED", $oldEnabled, "Process")
            [Environment]::SetEnvironmentVariable("SOURCE_EVENT_LOG_LOOKBACK_DAYS", $oldLookback, "Process")
        }
    }

    It "routes a file source baseline through the latest-segment reader" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-event-log-source-route-test-" + [guid]::NewGuid().ToString("N"))
        $oldEnabled = [Environment]::GetEnvironmentVariable("SOURCE_EVENT_LOG_BASELINE_ENABLED", "Process")
        $oldLookback = [Environment]::GetEnvironmentVariable("SOURCE_EVENT_LOG_LOOKBACK_DAYS", "Process")
        $oldTailBytes = [Environment]::GetEnvironmentVariable("SOURCE_EVENT_LOG_BOOTSTRAP_TAIL_BYTES", "Process")
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            [Environment]::SetEnvironmentVariable("SOURCE_EVENT_LOG_BASELINE_ENABLED", "true", "Process")
            [Environment]::SetEnvironmentVariable("SOURCE_EVENT_LOG_LOOKBACK_DAYS", $null, "Process")
            [Environment]::SetEnvironmentVariable("SOURCE_EVENT_LOG_BOOTSTRAP_TAIL_BYTES", "2048", "Process")
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Get-InfoBaseKind { return "file" }
                function Get-SourceInfoBasePath { return (Join-Path $tempRoot "source") }
                function Get-MainWorktreePath { return $tempRoot }
                function Read-DevBranchEventLogBaselineWithCache { throw "legacy source reader must not be called" }
                function Read-SourceLatestEventLogBaselineWithCache {
                    param([object]$State,[int64]$BootstrapTailBytes,[switch]$BestEffort)
                    return [pscustomobject]@{
                        reader = "direct-stream"
                        logDirectory = "latest-log"
                        signatures = @("latest-signature")
                        errorCount = 1
                        durationMs = 2
                        cacheStatus = "hit"
                        cachePath = [string]$BootstrapTailBytes
                        sourceKey = "source"
                        segmentCount = 1
                        scanMode = "unchanged"
                        scannedBytes = 0
                        coverage = "tail"
                        failedSegmentCount = 0
                    }
                }
                $baseline = Get-SourceEventLogSeedBaseline
                @($baseline.signatures) | Should -Be @("latest-signature")
                $baseline.scope | Should -Be "latest-segment"
                $baseline.lookbackDays | Should -BeNullOrEmpty
                $baseline.windowStart | Should -BeNullOrEmpty
                $baseline.cache.path | Should -Be "2048"
                $baseline.cache.scanMode | Should -Be "unchanged"
                $baseline.cache.scannedBytes | Should -Be 0
                $baseline.cache.coverage | Should -Be "tail"
            }
        } finally {
            [Environment]::SetEnvironmentVariable("SOURCE_EVENT_LOG_BASELINE_ENABLED", $oldEnabled, "Process")
            [Environment]::SetEnvironmentVariable("SOURCE_EVENT_LOG_LOOKBACK_DAYS", $oldLookback, "Process")
            [Environment]::SetEnvironmentVariable("SOURCE_EVENT_LOG_BOOTSTRAP_TAIL_BYTES", $oldTailBytes, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "accepts server source event-log lookback longer than seven days" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-event-log-source-long-window-test-" + [guid]::NewGuid().ToString("N"))
        $oldLookback = [Environment]::GetEnvironmentVariable("SOURCE_SERVER_EVENT_LOG_LOOKBACK_DAYS", "Process")
        $oldLegacyLookback = [Environment]::GetEnvironmentVariable("SOURCE_EVENT_LOG_LOOKBACK_DAYS", "Process")
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            [Environment]::SetEnvironmentVariable("SOURCE_SERVER_EVENT_LOG_LOOKBACK_DAYS", "365", "Process")
            [Environment]::SetEnvironmentVariable("SOURCE_EVENT_LOG_LOOKBACK_DAYS", $null, "Process")
            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                Get-SourceServerEventLogLookbackDays | Should -Be 365
                [Environment]::SetEnvironmentVariable("SOURCE_SERVER_EVENT_LOG_LOOKBACK_DAYS", $null, "Process")
                [Environment]::SetEnvironmentVariable("SOURCE_EVENT_LOG_LOOKBACK_DAYS", "90", "Process")
                Get-SourceServerEventLogLookbackDays 6>$null | Should -Be 90
            }
        } finally {
            [Environment]::SetEnvironmentVariable("SOURCE_SERVER_EVENT_LOG_LOOKBACK_DAYS", $oldLookback, "Process")
            [Environment]::SetEnvironmentVariable("SOURCE_EVENT_LOG_LOOKBACK_DAYS", $oldLegacyLookback, "Process")
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "falls back to a full segment scan when an apparent append changed the cached prefix" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-event-log-cache-prefix-test-" + [guid]::NewGuid().ToString("N"))
        try {
            $logDir = Join-Path $tempRoot "ib\1Cv8Log"
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
            Set-Content -LiteralPath (Join-Path $logDir "1Cv8.lgf") -Encoding UTF8 -Value "{1}"
            $segment = Join-Path $logDir "20260703.lgp"
            Set-Content -LiteralPath $segment -Encoding UTF8 -Value '{20260703100000,E,"_$PerformError$_","Catalog.Items","Old","Original"}'

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    infoBaseKind = "file"
                    devBranchInfoBasePath = (Join-Path $tempRoot "ib")
                    stateProjectRoot = $tempRoot
                    mainWorktreePath = $tempRoot
                }
                Read-DevBranchEventLogBaselineWithCache -State $state | Out-Null
                Set-Content -LiteralPath $segment -Encoding UTF8 -Value @(
                    '{20260703100000,E,"_$PerformError$_","Catalog.Items","Old","Replaced prefix"}',
                    '{20260703100500,E,"_$PerformError$_","Catalog.Items","New","Appended"}'
                )
                $result = Read-DevBranchEventLogBaselineWithCache -State $state
                $result.cacheStatus | Should -Be "updated"
                $result.fullSegmentCount | Should -Be 1
                $result.appendSegmentCount | Should -Be 0
                $result.scannedBytes | Should -Be (Get-Item -LiteralPath $segment).Length
                $result.errorCount | Should -Be 2
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps the last safe cached boundary when an appended record is incomplete" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-event-log-cache-boundary-test-" + [guid]::NewGuid().ToString("N"))
        try {
            $logDir = Join-Path $tempRoot "ib\1Cv8Log"
            New-Item -ItemType Directory -Force -Path $logDir | Out-Null
            Set-Content -LiteralPath (Join-Path $logDir "1Cv8.lgf") -Encoding UTF8 -Value "{1}"
            $segment = Join-Path $logDir "20260703.lgp"
            Set-Content -LiteralPath $segment -Encoding UTF8 -Value '{20260703100000,E,"_$PerformError$_","Catalog.Items","Old","Complete"}'

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    infoBaseKind = "file"
                    devBranchInfoBasePath = (Join-Path $tempRoot "ib")
                    stateProjectRoot = $tempRoot
                    mainWorktreePath = $tempRoot
                }
                $first = Read-DevBranchEventLogBaselineWithCache -State $state
                $safeLength = [int64](Read-Utf8Text -Path $first.cachePath | ConvertFrom-Json).segments[0].length

                [System.IO.File]::AppendAllText($segment, "`n{20260703100500,E,`"_`$PerformError`$_`",`"Catalog.Items`",`"New`",`"Incomplete`"", [System.Text.Encoding]::UTF8)
                { Read-DevBranchEventLogBaselineWithCache -State $state } | Should -Throw "*Incomplete bracket record*"
                [int64](Read-Utf8Text -Path $first.cachePath | ConvertFrom-Json).segments[0].length | Should -Be $safeLength

                [System.IO.File]::AppendAllText($segment, "}", [System.Text.Encoding]::UTF8)
                $completed = Read-DevBranchEventLogBaselineWithCache -State $state
                $completed.errorCount | Should -Be 2
                $completed.appendSegmentCount | Should -Be 1
                $completed.fullSegmentCount | Should -Be 0
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
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
                $additionalParamsKey = Decode-TestUtf8 "0JTQvtC/0J/QsNGA0LDQvNC10YLRgNGL"
                $statusKey = Decode-TestUtf8 "0J/Rg9GC0YzQmtCk0LDQudC70YPQlNC70Y/QktGL0LPRgNGD0LfQutC40KHRgtCw0YLRg9GB0LDQktGL0L/QvtC70L3QtdC90LjRj9Ch0YbQtdC90LDRgNC40LXQsg=="
                $windowTimeoutKey = Decode-TestUtf8 "0JrQvtC70LjRh9C10YHRgtCy0L7QodC10LrRg9C90LTQn9C+0LjRgdC60LDQntC60L3QsA=="
                $stopOnErrorKey = Decode-TestUtf8 "0J7RgdGC0LDQvdC+0LLQutCw0J/RgNC40JLQvtC30L3QuNC60L3QvtCy0LXQvdC40LjQntGI0LjQsdC60Lg="
                $portRangeKey = Decode-TestUtf8 "0JTQuNCw0L/QsNC30L7QvdCf0L7RgNGC0L7QslRlc3RjbGllbnQ="
                $serviceMessageDirectoryKey = Decode-TestUtf8 "0JrQsNGC0LDQu9C+0LPQpNCw0LnQu9C+0LLQktGL0LLQvtC00LDQodC70YPQttC10LHQvdGL0YXQodC+0L7QsdGJ0LXQvdC40Lk="
                $modalWindowErrorKey = Decode-TestUtf8 "0JzQvtC00LDQu9GM0L3QvtC10J7QutC90L7Qn9GA0LjQl9Cw0L/Rg9GB0LrQtdCa0LvQuNC10L3RgtCw0KLQtdGB0YLQuNGA0L7QstCw0L3QuNGP0K3RgtC+0J7RiNC40LHQutCw"
                $singleTestClientKey = Decode-TestUtf8 "0KDQsNC30YDQtdGI0LXQvdC+0JfQsNC/0YPRgdC60LDRgtGM0KLQvtC70YzQutC+0J7QtNC40L3QmtC70LjQtdC90YLQotC10YHRgtC40YDQvtCy0LDQvdC40Y8="

                $params.Version | Should -Be "1.2.043.28"
                $params.junitpath | Should -Be $runDirectory
                $params.logtotext | Should -BeTrue
                $params.logstepstotext | Should -BeTrue
                $params.logerrorstotext | Should -BeTrue
                $params.getactiveformdataonerror | Should -BeTrue
                $params.fulllog | Should -BeTrue
                $params.textlogname | Should -Be (Join-Path $runDirectory "vanessa.log")
                $params.texterrorslogname | Should -Be (Join-Path $runDirectory "errors")
                $params.maskpwdinlog | Should -BeTrue
                $params.outputloginconsole | Should -BeFalse
                $params.stoponerror | Should -BeFalse
                $params.NumberOfAttemptsToExecuteTheScript | Should -Be 1
                $params.updatetreewhenscenariostarts | Should -BeFalse
                $params.PSObject.Properties.Name | Should -Not -Contain "distinguishbrokenorfailedbythenkeyword"
                $params.PSObject.Properties[$portRangeKey].Value | Should -Be "48051-48051"
                $params.PSObject.Properties[$statusKey].Value | Should -Be $statusPath
                $params.PSObject.Properties[$scenarioKey].Value.PSObject.Properties[$windowTimeoutKey].Value | Should -Be 60
                $params.PSObject.Properties[$scenarioKey].Value.PSObject.Properties[$stopOnErrorKey].Value | Should -BeFalse

                $clientSettings = $params.PSObject.Properties[$clientKey].Value
                $clientSettings.PSObject.Properties[$serviceMessageDirectoryKey].Value | Should -Be $runDirectory
                $clientSettings.PSObject.Properties[$modalWindowErrorKey].Value | Should -BeTrue
                $params.PSObject.Properties[$singleTestClientKey].Value | Should -BeTrue
                $clientRecord = @($clientSettings.PSObject.Properties[$clientsKey].Value)[0]
                [int]$clientRecord.PSObject.Properties[$portKey].Value | Should -Be 48051
                $clientRecord.PSObject.Properties[$pathKey].Value | Should -Match ([regex]::Escape($ibPath))
                $clientRecord.PSObject.Properties[$additionalParamsKey].Value | Should -Match ([regex]::Escape("/DisableStartupMessages"))
                $clientRecord.PSObject.Properties[$additionalParamsKey].Value | Should -Not -Match ([regex]::Escape("/DisableStartupDialogs"))

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

    It "counts four independent JUnit scenarios and still fails on one failed verdict" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-junit-flat-test-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "junit.xml") -Encoding UTF8 -Value @'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites tests="4" failures="1" errors="0">
  <testsuite name="flat" tests="4" failures="1" errors="0">
    <testcase name="one"/><testcase name="two"><failure message="expected"/></testcase><testcase name="three"/><testcase name="four"/>
  </testsuite>
</testsuites>
'@
            & {
                . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
                $summary = Get-VanessaJunitSummary -RunDirectory $tempRoot
                $status = Get-VanessaVerificationStatus -RunDirectory $tempRoot -StatusPath (Join-Path $tempRoot "missing.json")
                $summary.tests | Should -Be 4
                $summary.failures | Should -Be 1
                $status.status | Should -Be "failed"
            }
        } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "starts Vanessa verify TestManager without passing TPort on the TestManager command line" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-testmanager-args-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $fakePlatform = Join-Path $tempRoot "1cv8.exe"
            $fakeThinClient = Join-Path $tempRoot "1cv8c.exe"
            Set-Content -LiteralPath $fakePlatform -Encoding ASCII -Value "fake"
            Set-Content -LiteralPath $fakeThinClient -Encoding ASCII -Value "fake"
            $ibPath = Join-Path $tempRoot "ib"
            New-Item -ItemType Directory -Force -Path $ibPath | Out-Null

            $captured = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null

                function Get-PlatformPath {
                    return $fakePlatform
                }
                function Assert-InfoBaseAvailable {
                }
                function Invoke-NativeProcessAndWaitResult {
                    param(
                        [string]$FilePath,
                        [string[]]$Arguments,
                        [int]$TimeoutSeconds = 0,
                        [scriptblock]$OnTimeout = $null,
                        [scriptblock]$CompletionProbe = $null,
                        [int]$CompletionGraceSeconds = 10,
                        [int]$PostExitProbeSeconds = 0,
                        [int]$MaxWorkingSetMb = 0
                    )
                    $script:LastNativeProcessFilePath = $FilePath
                    $script:LastNativeProcessArguments = @($Arguments)
                    return [pscustomobject]@{
                        timedOut = $false
                        exitCode = 0
                        processId = 4242
                    }
                }

                Invoke-Enterprise `
                    -InfoBasePath $ibPath `
                    -InfoBaseKind "file" `
                    -EnterpriseArgs @("/CStartFeaturePlayer;VAParams=C:\temp\VAParams.json") `
                    -TestClientPort 48051 `
                    -TimeoutSeconds 60 | Out-Null

                [pscustomobject]@{
                    filePath = $script:LastNativeProcessFilePath
                    arguments = @($script:LastNativeProcessArguments)
                }
            }

            $captured.filePath | Should -Be $fakeThinClient
            $captured.arguments | Should -Contain "/TESTMANAGER"
            ($captured.arguments -join " ") | Should -Not -Match ([regex]::Escape("-TPort"))
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "uses the thin client by default for Enterprise roles and keeps thick client explicit" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-enterprise-client-type-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $thickPath = Join-Path $tempRoot "1cv8.exe"
            $thinPath = Join-Path $tempRoot "1cv8c.exe"
            Set-Content -LiteralPath $thickPath -Encoding ASCII -Value "fake"
            Set-Content -LiteralPath $thinPath -Encoding ASCII -Value "fake"

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $script:Starts = @()
                $script:Invokes = @()
                function Get-PlatformPath { return $thickPath }
                function Assert-InfoBaseAvailable {}
                function Start-NativeProcessBackground {
                    param([string]$FilePath, [string[]]$Arguments)
                    $script:Starts += [pscustomobject]@{ filePath = $FilePath; arguments = @($Arguments) }
                    return [pscustomobject]@{ Id = 8100 + $script:Starts.Count }
                }
                function Invoke-NativeProcessAndWaitResult {
                    param(
                        [string]$FilePath,
                        [string[]]$Arguments,
                        [int]$TimeoutSeconds = 0,
                        [scriptblock]$OnTimeout = $null,
                        [scriptblock]$CompletionProbe = $null,
                        [int]$CompletionGraceSeconds = 10,
                        [int]$PostExitProbeSeconds = 0,
                        [int]$MaxWorkingSetMb = 0
                    )
                    $script:Invokes += [pscustomobject]@{ filePath = $FilePath; arguments = @($Arguments) }
                    return [pscustomobject]@{ timedOut = $false; exitCode = 0; processId = 8200 + $script:Invokes.Count }
                }

                $thinTestClient = Start-EnterpriseBackground -InfoBasePath $tempRoot -InfoBaseKind file -UseTestClient -TestClientPort 48151
                $thickManager = Start-EnterpriseBackground -InfoBasePath $tempRoot -InfoBaseKind file -ClientType Thick -UseTestManager -TestClientPort 48152
                Invoke-Enterprise -InfoBasePath $tempRoot -InfoBaseKind file -EnterpriseArgs @() -TestClientPort 48153 | Out-Null
                Invoke-Enterprise -InfoBasePath $tempRoot -InfoBaseKind file -EnterpriseArgs @() -ClientType Thick | Out-Null

                [pscustomobject]@{
                    starts = @($script:Starts)
                    invokes = @($script:Invokes)
                    thinResultPath = $thinTestClient.executablePath
                    thickResultPath = $thickManager.executablePath
                }
            }

            $result.starts[0].filePath | Should -Be $thinPath
            $result.starts[0].arguments | Should -Contain "/TESTCLIENT"
            $result.starts[0].arguments | Should -Not -Contain "/TESTMANAGER"
            $result.starts[0].arguments | Should -Not -Contain "/DisableStartupDialogs"
            $result.starts[1].filePath | Should -Be $thickPath
            $result.starts[1].arguments | Should -Contain "/TESTMANAGER"
            $result.starts[1].arguments | Should -Not -Contain "/TESTCLIENT"
            $result.starts[1].arguments | Should -Contain "/DisableStartupDialogs"
            $result.invokes[0].filePath | Should -Be $thinPath
            $result.invokes[0].arguments | Should -Contain "/TESTMANAGER"
            $result.invokes[0].arguments | Should -Contain "/DisableStartupDialogs"
            $result.invokes[1].filePath | Should -Be $thickPath
            $result.invokes[1].arguments | Should -Not -Contain "/TESTMANAGER"
            $result.invokes[1].arguments | Should -Contain "/DisableStartupDialogs"
            $result.thinResultPath | Should -Be $thinPath
            $result.thickResultPath | Should -Be $thickPath
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "reports distinct missing thin and thick Enterprise executables" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-enterprise-client-missing-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $thickPath = Join-Path $tempRoot "1cv8.exe"
            Set-Content -LiteralPath $thickPath -Encoding ASCII -Value "fake"
            $messages = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Get-PlatformPath { return $thickPath }
                $thinMessage = ""
                try { Resolve-EnterpriseClientExecutablePath | Out-Null } catch { $thinMessage = $_.Exception.Message }
                Remove-Item -LiteralPath $thickPath -Force
                $thickMessage = ""
                try { Resolve-EnterpriseClientExecutablePath -ClientType Thick | Out-Null } catch { $thickMessage = $_.Exception.Message }
                [pscustomobject]@{ thin = $thinMessage; thick = $thickMessage }
            }
            $messages.thin | Should -Match "^ITL_THIN_CLIENT_EXECUTABLE_MISSING:"
            $messages.thick | Should -Match "^ITL_THICK_CLIENT_EXECUTABLE_MISSING:"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "allocates Vanessa verify test ports per development branch state" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-test-port-test-" + [guid]::NewGuid().ToString("N"))
        $oldRange = [Environment]::GetEnvironmentVariable("VANESSA_TEST_PORT_RANGE", "Process")
        $oldRegistryHome = [Environment]::GetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", "Process")
        $oldRegistryScope = [Environment]::GetEnvironmentVariable("ITL_PORT_REGISTRY_SCOPE", "Process")
        $listener = $null

        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c\dev-branches") | Out-Null
            & git -C $tempRoot init *> $null
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", (Join-Path $tempRoot "port-registry"), "Process")
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_SCOPE", $null, "Process")

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
                    vanessaTestPortLeaseToken = "current-branch-token"
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
                    vanessaTestPortLeaseToken = "current-branch-token"
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
                        commandLine = "1cv8c.exe /TESTCLIENT -TPort $basePort /F `"D:\worktrees\other\.agent-1c\infobases\other`""
                        workingSetMb = 20
                    })
                }

                $state = [pscustomobject]@{
                    devBranchName = "Current Branch"
                    safeDevBranchName = "current-branch"
                    devBranch = "itldev/current-branch"
                    devBranchInfoBasePath = Join-Path $tempRoot "ib"
                    worktreePath = $tempRoot
                    vanessaTestPortLeaseToken = "current-branch-token"
                }
                Resolve-VanessaTestPort -State $state
            } | Should -Be ($basePort + 1)

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $state = [pscustomobject]@{
                    devBranchName = "Saved Branch"
                    safeDevBranchName = "saved-branch"
                    devBranch = "itldev/saved-branch"
                    vanessaTestPort = $basePort
                    vanessaTestPortLeaseToken = "saved-branch-token"
                }
                Resolve-VanessaTestPort -State $state
            } | Should -Be $basePort
        } finally {
            if ($null -ne $listener) {
                $listener.Stop()
            }
            [Environment]::SetEnvironmentVariable("VANESSA_TEST_PORT_RANGE", $oldRange, "Process")
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_HOME", $oldRegistryHome, "Process")
            [Environment]::SetEnvironmentVariable("ITL_PORT_REGISTRY_SCOPE", $oldRegistryScope, "Process")
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
                        commandLine = "1cv8c.exe /TESTCLIENT -TPort 48052 /F `"D:\worktrees\other\.agent-1c\infobases\other`" /CStartFeaturePlayer;VAParams=D:\worktrees\other\params.json"
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

    It "matches the branch TestManager and only the TestClient on the branch port" {
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
                    vanessaTestPort = 48051
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
                $manager = [pscustomobject]@{
                    processId = 1003
                    name = "1cv8c.exe"
                    commandLine = "1cv8c.exe ENTERPRISE /TESTMANAGER /F `"$ibPath`""
                    workingSetMb = 10
                }
                $wrongPort = [pscustomobject]@{
                    processId = 1004
                    name = "1cv8c.exe"
                    commandLine = "1cv8c.exe /TESTCLIENT -TPort 48052 /F `"$ibPath`""
                    workingSetMb = 10
                }
                function Get-OneCProcessInfo { @($own, $foreign, $manager, $wrongPort) }

                (Test-OneCVanessaTestProcess -ProcessInfo $own) | Should -Be $true
                (Test-OneCProcessBelongsToState -ProcessInfo $own -State $state -TestPort 48051 -RequireTestPort) | Should -Be $true
                (Test-OneCProcessBelongsToState -ProcessInfo $foreign -State $state -TestPort 48051 -RequireTestPort) | Should -Be $false
                $owned = @(Get-OwnVanessaTestProcesses -State $state)
                @($owned.processId) | Should -Be @(1001, 1003)
            }
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "leaves master clean after mocked initialization commits managed files" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-init-clean-" + [guid]::NewGuid().ToString("N"))
        $facadeFixtureRoot = "$tempRoot-facade-fixture"
        $envNames = @(
            "INFOBASE_KIND",
            "SOURCE_USES_REPOSITORY",
            "SOURCE_INFOBASE_PATH",
            "IB_USER",
            "IB_PASSWORD",
            "WEB_PUBLISH_BY_DEFAULT",
            "WEB_PUBLISH_AUTO",
            "DEPENDENCY_MODE",
            "SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE",
            "VIBECODING1C_MCP_SETUP_DURING_INIT",
            "ITL_ONDEMAND_MCP_INSTALL_ROOT"
        )
        $savedEnv = @{}
        foreach ($name in $envNames) {
            $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        }

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates") -Destination (Join-Path $tempRoot "templates") -Recurse
            $templateTarget = Join-Path $tempRoot ".agents\skills\1c-workflow\kilo-command-templates"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $templateTarget) | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates") -Destination $templateTarget -Recurse
            $env:ITL_ONDEMAND_MCP_INSTALL_ROOT = New-ItlOnDemandMcpInstallFixture -TargetRoot $facadeFixtureRoot

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null

                function Prepare-ConfiguredInitProjectSettings {
                    Ensure-WorkflowProjectFiles
                    Read-ProjectConfig
                    Set-ProjectAiRulesClient -Client "kilocode"
                    Read-ProjectConfig
                    Set-DotEnvValues -Values @{
                        INFOBASE_KIND = "file"
                        SOURCE_USES_REPOSITORY = "false"
                        SOURCE_INFOBASE_PATH = (Join-Path $script:ProjectRoot "source-base")
                        IB_USER = ""
                        IB_PASSWORD = ""
                        WEB_PUBLISH_BY_DEFAULT = "false"
                        WEB_PUBLISH_AUTO = "false"
                        DEPENDENCY_MODE = "fresh"
                        SOURCE_INFOBASE_UNSAFE_ACTION_PROTECTION_MODE = "defer"
                        VIBECODING1C_MCP_SETUP_DURING_INIT = "false"
                    }
                    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
                    $script:InitVibecoding1cMcpSetupRequested = $false
                    $script:PreparedInitProjectAnswers = New-ConfiguredInitAnswers
                }

                function Check-Tools {
                    param([switch]$StopOnMissing)
                }

                function Install-RoctupMcp {
                }

                function Ensure-VanessaAutomationForInit {
                    param([object]$Answers)
                }

                function Ensure-YAxUnitForInit {
                }

                function Update-BaseFromRepository {
                    return $false
                }

                function Dump-ConfigToFiles {
                    $exportPath = "src/cf"
                    $absoluteExportPath = Resolve-ProjectPath $exportPath
                    New-Item -ItemType Directory -Force -Path $absoluteExportPath | Out-Null
                    Write-Utf8Text -Path (Join-Path $absoluteExportPath "ConfigDumpInfo.xml") -Value "<dump />`n"
                    Write-Utf8Text -Path (Join-Path $absoluteExportPath "Configuration.xml") -Value "<configuration />`n"
                    $script:LastLogPath = Join-Path $script:ProjectRoot "empty-dump.log"
                    Write-Utf8Text -Path $script:LastLogPath -Value ""
                    return [pscustomobject]@{
                        exportPath = $exportPath
                        absoluteExportPath = $absoluteExportPath
                        incremental = $false
                        logPath = $script:LastLogPath
                    }
                }

                function Ensure-BranchSeed {
                    return [pscustomobject]@{ status = "ready"; syncId = "test-fixture" }
                }

                function Install-AiRules1c {
                    Write-Utf8Text -Path (Join-Path $script:ProjectRoot ".ai-rules.json") -Value "{`"schemaVersion`":1,`"tools`":[`"kilocode`"],`"files`":{}}`n"
                    Write-Utf8Text -Path (Join-Path $script:ProjectRoot "AGENTS.md") -Value "Read USER-RULES.md for project-specific instructions.`n"
                }

                function Assert-Agent1cInitialProjectRootPathBudget {
                    return [pscustomobject]@{ valid = $true }
                }

                Initialize-Project *> $null

                [pscustomobject]@{
                    status = @(Get-EffectiveGitStatusLines -StatusLines (& git -C $script:ProjectRoot status --porcelain))
                    trackedTemplates = @(& git -C $script:ProjectRoot ls-files -- templates)
                    trackedKiloItlCommands = @(& git -C $script:ProjectRoot ls-files -- ".kilo/commands/itl*.md")
                    localKiloItlCommands = @(Get-ChildItem -LiteralPath (Join-Path $script:ProjectRoot ".kilo\commands") -File -Filter "itl*.md" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
                    gitignoreText = Get-Content -Encoding UTF8 -Raw (Join-Path $script:ProjectRoot ".gitignore")
                    branch = ((& git -C $script:ProjectRoot branch --show-current) -join "").Trim()
                    commitCount = [int](((& git -C $script:ProjectRoot rev-list --count HEAD) -join "").Trim())
                    dumpLogPath = $script:LastLogPath
                }
            }

            @($result.status).Count | Should -Be 0
            $result.trackedTemplates | Should -Contain "templates/project.json"
            $result.trackedTemplates | Should -Contain "templates/tools.json"
            $result.trackedTemplates | Should -Contain "templates/dependency-lock.json"
            $result.trackedTemplates | Should -Contain "templates/gitignore.append"
            $result.trackedTemplates | Should -Contain "templates/USER-RULES.append.md"
            $result.trackedTemplates | Should -Contain "templates/AGENTS.append.md"
            $result.gitignoreText | Should -Match ([regex]::Escape(".kilo/commands/itl*.md"))
            @($result.trackedKiloItlCommands).Count | Should -Be 0
            @($result.localKiloItlCommands) | Should -Contain "itl.md"
            @($result.localKiloItlCommands) | Should -Contain "itl-status.md"
            @($result.localKiloItlCommands) | Should -Contain "itl-new-config-branch.md"
            $result.branch | Should -Be "master"
            $result.commitCount | Should -BeGreaterOrEqual 2
            (Get-Item -LiteralPath $result.dumpLogPath).Length | Should -Be 0
        } finally {
            foreach ($name in $envNames) {
                [Environment]::SetEnvironmentVariable($name, $savedEnv[$name], "Process")
            }
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $facadeFixtureRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $facadeFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "cleans only current-run Git index locks conservatively" {
        $currentRunRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-lock-current-" + [guid]::NewGuid().ToString("N"))
        $preExistingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-lock-preexisting-" + [guid]::NewGuid().ToString("N"))
        $runningGitRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-lock-git-running-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path $currentRunRoot, $preExistingRoot, $runningGitRoot | Out-Null

            $currentRun = & {
                . $HelperPath -ProjectRoot $currentRunRoot -Action help *> $null
                & git -C $currentRunRoot init *> $null
                $lockPath = Join-Path $currentRunRoot ".git\index.lock"
                Set-Content -LiteralPath $lockPath -Encoding ASCII -Value "current"
                function Test-GitProcessRunning {
                    return $false
                }
                [pscustomobject]@{
                    message = Invoke-GitIndexLockCleanupOnFailure
                    exists = Test-Path -LiteralPath $lockPath -PathType Leaf
                }
            }
            $currentRun.message | Should -Match "Removed Git index lock"
            $currentRun.exists | Should -Be $false

            & git -C $preExistingRoot init *> $null
            $preExistingLockPath = Join-Path $preExistingRoot ".git\index.lock"
            Set-Content -LiteralPath $preExistingLockPath -Encoding ASCII -Value "preexisting"
            $preExisting = & {
                . $HelperPath -ProjectRoot $preExistingRoot -Action help *> $null
                [pscustomobject]@{
                    message = Invoke-GitIndexLockCleanupOnFailure
                    exists = Test-Path -LiteralPath $preExistingLockPath -PathType Leaf
                }
            }
            $preExisting.message | Should -Match "present before this helper run"
            $preExisting.exists | Should -Be $true

            $runningGit = & {
                . $HelperPath -ProjectRoot $runningGitRoot -Action help *> $null
                & git -C $runningGitRoot init *> $null
                $lockPath = Join-Path $runningGitRoot ".git\index.lock"
                Set-Content -LiteralPath $lockPath -Encoding ASCII -Value "running"
                function Test-GitProcessRunning {
                    return $true
                }
                [pscustomobject]@{
                    message = Invoke-GitIndexLockCleanupOnFailure
                    exists = Test-Path -LiteralPath $lockPath -PathType Leaf
                }
            }
            $runningGit.message | Should -Match "git.exe is still running"
            $runningGit.exists | Should -Be $true

            {
                & {
                    . $HelperPath -ProjectRoot $runningGitRoot -Action help *> $null
                    Invoke-Git @("add", "--all")
                }
            } | Should -Throw "*Git index lock blocks this command*"
        } finally {
            foreach ($root in @($currentRunRoot, $preExistingRoot, $runningGitRoot)) {
                if (Test-Path -LiteralPath $root -ErrorAction SilentlyContinue) {
                    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    It "commits LF files without showing benign CRLF warnings under monitored logging" {
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
            $logText | Should -Not -Match "LF will be replaced by CRLF"
            $logText | Should -Match "Committed: test: commit lf file"
            $logText | Should -Not -Match "NativeCommandError"
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "does not print Git create mode lines for successful helper-created commits" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-git-quiet-commit-" + [guid]::NewGuid().ToString("N"))
        $probePath = Join-Path $tempRoot "probe.ps1"
        $launcherPath = Join-Path $tempRoot "launcher.ps1"
        $logPath = Join-Path $tempRoot "console.log"

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            for ($i = 1; $i -le 20; $i++) {
                Set-Content -LiteralPath (Join-Path $tempRoot ("file-{0:000}.txt" -f $i)) -Encoding UTF8 -Value "content $i"
            }

            Set-Content -LiteralPath $probePath -Encoding UTF8 -Value @'
param(
    [string]$HelperPath,
    [string]$ProjectRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. $HelperPath -ProjectRoot $ProjectRoot -Action help *> $null
Commit-IfChanged -Message "test: quiet commit output" -PathSpec @(".") -RequireChanges | Out-Null
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
            $logText = Get-Content -Encoding UTF8 -Raw $logPath
            $logText | Should -Match "Committed: test: quiet commit output"
            $logText | Should -Not -Match "create mode"
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

    It "wires web publication policy, actions, and branch state fields" {
        $projectTemplate = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\project.json")
        $devEnvTemplate = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")

        $projectTemplate | Should -Match '"publishByDefault"\s*:\s*false'
        $projectTemplate | Should -Match '"publishAuto"\s*:\s*false'
        $devEnvTemplate | Should -Match "WEB_PUBLISH_BY_DEFAULT=false"
        $devEnvTemplate | Should -Match "WEB_PUBLISH_AUTO=false"

        $HelperText | Should -Match "function Get-WebPublishAuto"
        $HelperText | Should -Match "function Configure-WebPublication"
        $HelperText | Should -Match "function Publish-DevBranch"
        $HelperText | Should -Match "detect-web-publication"
        $HelperText | Should -Match "configure-web-publication"
        $HelperText | Should -Match "publish-dev-branch"
        foreach ($field in @("publicationStatus", "publicationMode", "publicationError", "publicationUpdatedAt")) {
            $HelperText | Should -Match $field
        }
        $HelperText | Should -Match "Invoke-DevBranchPublicationCycle"
        $HelperText | Should -Match "Install-DevBranchDataMcpBestEffort"
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

        $openMessageFunction = [regex]::Match($HelperText, '(?s)function Write-DevBranchWorktreeOpenMessage \{.*?(?=\r?\nfunction )').Value
        $openMessageFunction | Should -Not -BeNullOrEmpty
        $openMessageFunction | Should -Not -Match '/reload'
        $openMessageFunction | Should -Match 'дополнительная перезагрузка клиента.*не требуется'
        $openMessageFunction | Should -Match 'RunRequiredAction'

        $handoff = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-ItlActiveClient { return "kilocode" }
            $script:RunRequiredAction = ""
            $script:RunWorktreePath = ""
            $output = Write-DevBranchWorktreeOpenMessage -MainProjectPath "C:\fixture\main" -WorktreePath "C:\fixture\branch1" 6>&1
            [pscustomobject]@{
                output = ($output -join [Environment]::NewLine)
                requiredAction = $script:RunRequiredAction
                worktreePath = $script:RunWorktreePath
            }
        }
        $handoff.output | Should -Not -Match '/reload'
        $handoff.requiredAction | Should -Match 'дополнительная перезагрузка клиента.*не требуется'
        $handoff.worktreePath | Should -Be "C:\fixture\branch1"

        $codexHandoff = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-ItlActiveClient { return "codex" }
            $script:RunRequiredAction = ""
            $script:RunWorktreePath = ""
            $output = Write-DevBranchWorktreeOpenMessage -MainProjectPath "C:\fixture\main" -WorktreePath "C:\fixture\branch-codex" 6>&1
            [pscustomobject]@{
                output = ($output -join [Environment]::NewLine)
                requiredAction = $script:RunRequiredAction
                worktreePath = $script:RunWorktreePath
            }
        }
        $codexHandoff.output | Should -Match 'как отдельный project'
        $codexHandoff.requiredAction | Should -Match 'После добавления project полностью перезапустите приложение Codex'
        $codexHandoff.requiredAction | Should -Match ([regex]::Escape('.codex/config.toml'))
        $codexHandoff.requiredAction | Should -Match 'подключило MCP-серверы'
        $codexHandoff.requiredAction | Should -Match 'новую задачу в режиме Local'
        $codexHandoff.requiredAction | Should -Match 'Режим Worktree не выбирайте'
        $codexHandoff.requiredAction | Should -Match 'Git worktree и среда 1С уже созданы ITL'
        $codexHandoff.worktreePath | Should -Be "C:\fixture\branch-codex"
    }

    It "requires the client-specific post-init reload handoff" {
        $initHandoffFunction = [regex]::Match($HelperText, '(?s)function Write-PostInitClientReloadHandoff \{.*?(?=\r?\nfunction )').Value
        $initHandoffFunction | Should -Not -BeNullOrEmpty
        $initHandoffFunction | Should -Match ([regex]::Escape('выполните /reload'))
        $initHandoffFunction | Should -Match 'открыто на master до инициализации'
        $initHandoffFunction | Should -Match 'прочитает собственный контекст при запуске'
        $HelperText | Should -Match 'Assert-InitGitClean\s+Write-PostInitClientReloadHandoff\s+Write-KiloBrowserAutomationSummary -ProjectRoot \$script:ProjectRoot\s+Write-InitRunUserReport.*?\s+Set-RunStage -Stage "init\.complete"'

        $handoff = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-ItlActiveClient { return "kilocode" }
            $script:RunRequiredAction = ""
            $output = Write-PostInitClientReloadHandoff 6>&1
            [pscustomobject]@{
                output = ($output -join [Environment]::NewLine)
                requiredAction = $script:RunRequiredAction
            }
        }
        $handoff.output | Should -Match ([regex]::Escape('выполните /reload'))
        $handoff.requiredAction | Should -Match 'до следующего действия в master'

        $codexHandoff = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-ItlActiveClient { return "codex" }
            $script:RunRequiredAction = ""
            $output = Write-PostInitClientReloadHandoff 6>&1
            [pscustomobject]@{
                output = ($output -join [Environment]::NewLine)
                requiredAction = $script:RunRequiredAction
            }
        }
        $codexHandoff.output | Should -Match 'полностью перезапустите приложение Codex'
        $codexHandoff.requiredAction | Should -Match ([regex]::Escape('.codex/config.toml'))
        $codexHandoff.requiredAction | Should -Match 'подключило MCP-серверы'
        $codexHandoff.requiredAction | Should -Match 'новую задачу в режиме Local'
    }

    It "requires Kilo reload only after a semantic on-demand MCP command change" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-ItlActiveClient { return "kilocode" }
            $script:RunRequiredAction = ""
            $script:ItlClientMcpSemanticChanges = [ordered]@{}
            $unchanged = Set-ItlOnDemandMcpSemanticReloadRequiredAction -Operation "refresh-dev-branch"
            $unchangedAction = $script:RunRequiredAction
            Register-ItlClientMcpSemanticChange -Client kilocode -Owner "ondemand-facade" -Path "C:\fixture\.kilo\kilo.json"
            $changed = Set-ItlOnDemandMcpSemanticReloadRequiredAction -Operation "refresh-dev-branch"
            [pscustomobject]@{
                unchanged = $unchanged
                unchangedAction = $unchangedAction
                changed = $changed
                changedAction = $script:RunRequiredAction
            }
        }
        $script:ItlClientMcpSemanticChanges = [ordered]@{}
        $result.unchanged | Should -BeFalse
        $result.unchangedAction | Should -BeNullOrEmpty
        $result.changed | Should -BeTrue
        $result.changedAction | Should -Match ([regex]::Escape('/reload'))
        $result.changedAction | Should -Match 'до следующего вызова ROCTUP или Vanessa UI'
    }

    It "requires a Codex application restart after a semantic on-demand MCP command change" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-ItlActiveClient { return "codex" }
            $script:RunRequiredAction = ""
            $script:ItlClientMcpSemanticChanges = [ordered]@{}
            Register-ItlClientMcpSemanticChange -Client codex -Owner "ondemand-facade" -Path "C:\fixture\.codex\config.toml"
            Set-ItlOnDemandMcpSemanticReloadRequiredAction -Operation "refresh-dev-branch" | Out-Null
            $script:RunRequiredAction
        }
        $script:ItlClientMcpSemanticChanges = [ordered]@{}
        $result | Should -Match 'полностью перезапустите приложение Codex'
        $result | Should -Match ([regex]::Escape('.codex/config.toml'))
        $result | Should -Match 'подключил MCP-серверы'
    }

    It "builds a complete safe branch user report with MCP Browser and advice" {
        $report = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-Vibecoding1cMcpStatusSummary {
                return [pscustomobject]@{ active = @("docs/remote"); skipped = @(); staleServers = @(); missingConfigId = @() }
            }
            function Format-Vibecoding1cMcpStatusList { param([object[]]$Items); if (@($Items).Count -eq 0) { return "<none>" }; return (@($Items) -join ", ") }
            function Get-KiloBrowserAutomationDisplay {
                return [pscustomobject]@{ statusLine = "Kilo Browser Automation: включена (источник: настройки проекта)."; adviceLine = "Рекомендация Browser fixture." }
            }
            $script:RunRequiredAction = "Откройте новый worktree; дополнительная перезагрузка клиента в нём не требуется."
            $state = [pscustomobject]@{
                devBranchKind = "extension"
                devBranch = "itldev/report-fixture"
                mainWorktreePath = "C:\fixture\main"
                worktreePath = "C:\fixture\branch"
                devBranchInfoBasePath = "C:\fixture\ib"
                launcherInfoBaseName = "fixture-branch"
                launcherFolder = "/ITL/fixture"
                publicationStatus = "disabled"
                extensionInitializationStatus = "pending"
                roctupMcpStatus = "stopped"
                vanessaMcpStatus = "stopped"
            }
            Write-DevBranchRunUserReport -State $state -AdvisoryRoot $state.worktreePath 6>$null
            $script:RunUserReport
        }

        $report | Should -Match "## Ветка разработки"
        $report | Should -Match "Тип: расширение"
        $report | Should -Match "Ветка: itldev/report-fixture"
        $report | Should -Match "База в launcher 1С: fixture-branch"
        $report | Should -Match "Публикация: отключена"
        $report | Should -Match "ROCTUP MCP: остановлен"
        $report | Should -Match "Kilo Browser Automation: включена"
        $report | Should -Match "Инициализация расширения: ожидает настройки"
        $report | Should -Match "Рекомендация Browser fixture"
        $report | Should -Match "дополнительная перезагрузка клиента.*не требуется"
        $report | Should -Not -Match "## Development branch|Extension initialization:|Instructions and advice"
        $report | Should -Not -Match "password|token|secret"
    }

    It "builds a Russian configuration branch report without extension setup" {
        $report = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-Vibecoding1cMcpStatusSummary {
                return [pscustomobject]@{ active = @(); skipped = @(); staleServers = @(); missingConfigId = @() }
            }
            function Format-Vibecoding1cMcpStatusList { param([object[]]$Items); if (@($Items).Count -eq 0) { return "<none>" }; return (@($Items) -join ", ") }
            function Get-KiloBrowserAutomationDisplay { return $null }
            $script:RunRequiredAction = "Откройте новое окно клиента в worktree."
            $state = [pscustomobject]@{
                devBranchKind = "configuration"
                devBranch = "itldev/config-report"
                mainWorktreePath = "C:\fixture\main"
                worktreePath = "C:\fixture\config-report"
                devBranchInfoBasePath = "C:\fixture\ib-config"
                launcherInfoBaseName = "fixture-config"
                launcherFolder = "/ITL/fixture"
                publicationUrl = "http://localhost/config-report"
                roctupMcpStatus = "running"
                vanessaMcpStatus = "disabled"
            }
            Write-DevBranchRunUserReport -State $state -AdvisoryRoot $state.worktreePath 6>$null
            $script:RunUserReport
        }

        $report | Should -Match "Тип: конфигурация"
        $report | Should -Match "URL публикации: http://localhost/config-report"
        $report | Should -Match "ROCTUP MCP: работает"
        $report | Should -Match "Vanessa UI MCP: отключён"
        $report | Should -Not -Match "Инициализация расширения"
        $report | Should -Match "Откройте новое окно клиента в worktree"
    }

    It "reports fork provenance history and inherited verification explicitly" {
        $report = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-Vibecoding1cMcpStatusSummary { [pscustomobject]@{ active = @(); skipped = @(); staleServers = @(); missingConfigId = @() } }
            function Format-Vibecoding1cMcpStatusList { param([object[]]$Items); "<none>" }
            function Get-KiloBrowserAutomationDisplay { return $null }
            $script:RunRequiredAction = "Откройте worktree копии в отдельном project."
            $state = [pscustomobject]@{
                devBranchKind = "configuration"
                devBranch = "itldev/fork-report"
                mainWorktreePath = "C:\fixture\main"
                worktreePath = "C:\fixture\fork-report"
                devBranchInfoBasePath = "C:\fixture\ib-fork"
                launcherInfoBaseName = "fixture-fork"
                launcherFolder = "/ITL/fixture"
                publicationStatus = "disabled"
                roctupMcpStatus = "stopped"
                vanessaMcpStatus = "stopped"
                forkedFromBranch = "itldev/source"
                forkedFromCommit = "abc123"
                forkHistoryPath = "C:\fixture\fork-report\.agent-1c\fork-history\id"
                forkVerificationInherited = $true
                forkVerificationReason = "fresh passed inherited from the exact fork snapshot"
            }
            Write-DevBranchRunUserReport -State $state -AdvisoryRoot $state.worktreePath -Operation forked 6>$null
            $script:RunUserReport
        }

        $report | Should -Match "## Копия ветки разработки"
        $report | Should -Match "Скопировано из ветки: itldev/source"
        $report | Should -Match "История логов и проверок:"
        $report | Should -Match "Verification evidence: fresh passed унаследована"
        $report | Should -Match "повторять ту же проверку до новых изменений не требуется"
        $report | Should -Match "Откройте worktree копии"
    }

    It "builds a complete safe Russian refresh report with an explicit successful result" {
        $report = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-ItlActiveClient { return "kilocode" }
            function Get-Vibecoding1cMcpStatusSummary {
                return [pscustomobject]@{ active = @("docs/remote"); skipped = @(); staleServers = @(); missingConfigId = @() }
            }
            function Format-Vibecoding1cMcpStatusList { param([object[]]$Items); if (@($Items).Count -eq 0) { return "<none>" }; return (@($Items) -join ", ") }
            function Get-KiloBrowserAutomationDisplay {
                return [pscustomobject]@{ statusLine = "Kilo Browser Automation: включена (источник: настройки проекта)."; adviceLine = "Browser Automation использует платный скрытый Playwright MCP." }
            }
            $state = [pscustomobject]@{
                devBranchKind = "configuration"
                devBranch = "itldev/refresh-report"
                mainWorktreePath = "C:\fixture\main"
                worktreePath = "C:\fixture\refresh-report"
                devBranchInfoBasePath = "C:\fixture\ib-refresh"
                lastRefreshRepairPaths = @("src/cf/CommonModules/Связанный/Ext/Module.bsl")
                roctupMcpStatus = "stopped"
                vanessaMcpStatus = "stopped"
                password = "PASSWORD_SHOULD_NOT_LEAK"
                token = "TOKEN_SHOULD_NOT_LEAK"
            }
            $loadResult = [pscustomobject]@{
                loaded = $true
                currentCommit = "0123456789abcdef"
                loadModeUsed = "partial"
                enterpriseInvoked = $true
                secretKey = "SECRET_SHOULD_NOT_LEAK"
            }
            Write-DevBranchRunUserReport -State $state -AdvisoryRoot $state.worktreePath -Operation refreshed -LoadResult $loadResult 6>$null
            $script:RunUserReport
        }

        $report | Should -Match "## Обновление ветки разработки"
        $report | Should -Match "Результат: успешно"
        $report | Should -Match "Тип: конфигурация"
        $report | Should -Match "Ветка: itldev/refresh-report"
        $report | Should -Match "Коммит ветки: 0123456789abcdef"
        $report | Should -Match ([regex]::Escape("Семантическое согласование: src/cf/CommonModules/Связанный/Ext/Module.bsl"))
        $report | Should -Match "Обновление конфигурации базы: выполнено"
        $report | Should -Match "Режим загрузки: частичная загрузка"
        $report | Should -Match "Enterprise-автообновление: выполнено"
        $report | Should -Match "ROCTUP MCP: остановлен"
        $report | Should -Match "Kilo Browser Automation: включена"
        $report | Should -Match "Browser Automation использует платный скрытый Playwright MCP"
        $report | Should -Match "Выполните /reload"
        $report | Should -Match "выполните /itl-check"
        $report | Should -Not -Match "Development branch|successful|Configuration update|Instructions and advice"
        $report | Should -Not -Match "PASSWORD_SHOULD_NOT_LEAK|TOKEN_SHOULD_NOT_LEAK|SECRET_SHOULD_NOT_LEAK"
    }

    It "reports an extension refresh without pretending that extension files were loaded" {
        $report = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-ItlActiveClient { return "kilocode" }
            function Get-Vibecoding1cMcpStatusSummary {
                return [pscustomobject]@{ active = @(); skipped = @(); staleServers = @(); missingConfigId = @() }
            }
            function Format-Vibecoding1cMcpStatusList { param([object[]]$Items); return "<none>" }
            function Get-KiloBrowserAutomationDisplay { return $null }
            $state = [pscustomobject]@{
                devBranchKind = "extension"
                devBranch = "itldev/extension-refresh"
                mainWorktreePath = "C:\fixture\main"
                worktreePath = "C:\fixture\extension-refresh"
                devBranchInfoBasePath = "C:\fixture\ib-extension"
                extensionInitializationStatus = "ready"
                roctupMcpStatus = "stopped"
                vanessaMcpStatus = "disabled"
            }
            $loadResult = [pscustomobject]@{
                loaded = $false
                currentCommit = "fedcba9876543210"
                loadModeUsed = ""
                enterpriseInvoked = $false
            }
            Write-DevBranchRunUserReport -State $state -AdvisoryRoot $state.worktreePath -Operation refreshed -LoadResult $loadResult 6>$null
            $script:RunUserReport
        }

        $report | Should -Match "Результат: успешно"
        $report | Should -Match "Тип: расширение"
        $report | Should -Match "Инициализация расширения: готово"
        $report | Should -Match "Обновление конфигурации базы: не требовалось"
        $report | Should -Match "Режим загрузки: не применялся"
        $report | Should -Match "Enterprise-автообновление: не требовалось"
        $report | Should -Match "Файлы расширения при обновлении ветки не загружались"
    }

    It "documents and templates the development branch worktree root" {
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\project.json")) | Should -Match "devBranchWorktreeRoot"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "DEV_BRANCH_WORKTREE_ROOT"
        $projectWorkflowText = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "docs\itl-workflow\PROJECT-WORKFLOW.ru.md")
        $projectWorkflowText | Should -Match "worktree"
        $projectWorkflowText | Should -Match ([regex]::Escape("/itl-status"))
    }

    It "declares manual unsafe action protection confirmation for development branches" {
        $HelperText | Should -Match "function Confirm-DevBranchUnsafeActionProtection"
        $HelperText | Should -Match "function Show-DevBranchUnsafeActionProtectionAttention"
        $HelperText | Should -Match "function Assert-DevBranchUnsafeActionProtectionPromptAvailable"
        $HelperText | Should -Match "function Get-DevBranchUnsafeActionProtectionSetup"
        $HelperText | Should -Match "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP"
        $HelperText | Should -Match "manual-confirm"
        $HelperText | Should -Match "unsafeActionProtectionSetupMode"
        $HelperText | Should -Match "unsafeActionProtectionConfirmed"
        $HelperText | Should -Match "unsafeActionProtectionConfirmedAt"
        $HelperText | Should -Match "unsafeActionProtectionUser"
        $HelperText | Should -Match "Test-InteractiveInputAvailable"
        $HelperText | Should -Match "Read-Host"
        $HelperText | Should -Match ([regex]::Escape('$null -eq $answerValue'))
        $HelperText | Should -Match '\[System\.StringComparison\]::OrdinalIgnoreCase'
        $HelperText | Should -Match "Invoke-DesignerInteractive"
        $HelperText | Should -Match "Invoke-VisibleNativeProcessAndWait"
        $HelperText | Should -Match "ItlConsoleWindowAttention"
        $HelperText | Should -Match "FlashWindowEx"
        $HelperText | Should -Match '\[Console\]::Title'
        $HelperText | Should -Match '\[Console\]::Beep\(880, 250\)'
        $confirmStart = $HelperText.IndexOf('function Confirm-DevBranchUnsafeActionProtection')
        $confirmEnd = $HelperText.IndexOf('function Configure-DevBranchUnsafeActionProtection', $confirmStart)
        $confirmBlock = $HelperText.Substring($confirmStart, $confirmEnd - $confirmStart)
        $confirmBlock.IndexOf('Show-DevBranchUnsafeActionProtectionAttention') | Should -BeLessThan $confirmBlock.IndexOf('$answerValue = Read-Host')
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=manual-confirm"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\branch-lifecycle.md")) | Should -Match "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP"
    }

    It "keeps source confirmation local, context-bound, and free of passwords" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-source-protection-state-" + [guid]::NewGuid().ToString("N"))
        $oldKind = [Environment]::GetEnvironmentVariable("INFOBASE_KIND", "Process")
        $oldSource = [Environment]::GetEnvironmentVariable("SOURCE_INFOBASE_PATH", "Process")
        $oldUser = [Environment]::GetEnvironmentVariable("IB_USER", "Process")
        try {
            $sourceBase = Join-Path $tempRoot "source"
            New-Item -ItemType Directory -Force -Path $sourceBase | Out-Null
            [Environment]::SetEnvironmentVariable("INFOBASE_KIND", "file", "Process")
            [Environment]::SetEnvironmentVariable("SOURCE_INFOBASE_PATH", $sourceBase, "Process")
            [Environment]::SetEnvironmentVariable("IB_USER", "Developer", "Process")

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $saved = Save-SourceInfoBaseUnsafeActionProtectionConfirmation -ConfirmationMode "manual-confirm"
                $valid = Get-ValidSourceInfoBaseUnsafeActionProtectionConfirmation
                [Environment]::SetEnvironmentVariable("SOURCE_INFOBASE_PATH", (Join-Path $tempRoot "another-source"), "Process")
                $changedSource = Get-ValidSourceInfoBaseUnsafeActionProtectionConfirmation
                [Environment]::SetEnvironmentVariable("SOURCE_INFOBASE_PATH", $sourceBase, "Process")
                [Environment]::SetEnvironmentVariable("IB_USER", "AnotherUser", "Process")
                $changedUser = Get-ValidSourceInfoBaseUnsafeActionProtectionConfirmation
                [pscustomobject]@{
                    saved = $saved
                    valid = $valid
                    changedSource = $changedSource
                    changedUser = $changedUser
                    stateText = Read-Utf8Text -Path (Get-SourceInfoBaseUnsafeActionProtectionStatePath)
                }
            }

            $result.valid.sourceKey | Should -Be $result.saved.sourceKey
            $result.changedSource | Should -BeNullOrEmpty
            $result.changedUser | Should -BeNullOrEmpty
            $result.stateText | Should -Not -Match "password"
            $result.stateText | Should -Match '"infoBaseUser"\s*:\s*"Developer"'
            (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\gitignore.append")) | Should -Match "source-infobase-unsafe-action-protection\.json"
        } finally {
            [Environment]::SetEnvironmentVariable("INFOBASE_KIND", $oldKind, "Process")
            [Environment]::SetEnvironmentVariable("SOURCE_INFOBASE_PATH", $oldSource, "Process")
            [Environment]::SetEnvironmentVariable("IB_USER", $oldUser, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "uses a valid master confirmation before branch fallback" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            function Get-ValidSourceInfoBaseUnsafeActionProtectionConfirmation {
                return [pscustomobject]@{
                    sourceKey = "abc123"
                    confirmationMode = "manual-confirm"
                    confirmedAt = "2026-07-17T12:00:00+03:00"
                    infoBaseUser = "Developer"
                    confirmed = $true
                }
            }
            function Confirm-DevBranchUnsafeActionProtection { throw "branch fallback must not run" }
            function Test-InteractiveInputAvailable { return $false }
            function Get-DevBranchUnsafeActionProtectionSetupRaw { throw "branch mode must not be read for a valid source confirmation" }
            Assert-DevBranchUnsafeActionProtectionPromptAvailable
            $state = Resolve-DevBranchUnsafeActionProtectionState `
                -State @{} `
                -InfoBaseKind "file" `
                -InfoBasePath "C:\bases\branch" `
                -BranchName "feature" `
                -MainProjectRoot $RepoRoot
            [pscustomobject]$state
        }

        $result.unsafeActionProtectionResolution | Should -Be "source-confirmed"
        $result.unsafeActionProtectionConfirmed | Should -BeTrue
        $result.unsafeActionProtectionSourceKey | Should -Be "abc123"
    }

    It "keeps source confirmation quiet and branch fallback attention-visible" {
        $sourceStart = $HelperText.IndexOf('function Confirm-SourceInfoBaseUnsafeActionProtection')
        $sourceEnd = $HelperText.IndexOf('function Initialize-SourceInfoBaseUnsafeActionProtection', $sourceStart)
        $sourceBlock = $HelperText.Substring($sourceStart, $sourceEnd - $sourceStart)
        $sourceBlock | Should -Not -Match "Show-DevBranchUnsafeActionProtectionAttention"
        $sourceBlock | Should -Not -Match '\[Console\]::Beep'
        $branchStart = $HelperText.IndexOf('function Confirm-DevBranchUnsafeActionProtection')
        $branchEnd = $HelperText.IndexOf('function Confirm-SourceInfoBaseUnsafeActionProtection', $branchStart)
        $branchBlock = $HelperText.Substring($branchStart, $branchEnd - $branchStart)
        $branchBlock | Should -Match "Show-DevBranchUnsafeActionProtectionAttention"
    }

    It "implements defer, confirmed, and manual-confirm source init modes" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:Mode = ""
            $script:Clears = 0
            $script:Saves = @()
            $script:ManualPrompts = 0
            function Get-SourceInfoBaseUnsafeActionProtectionMode { return $script:Mode }
            function Clear-SourceInfoBaseUnsafeActionProtectionConfirmation { $script:Clears++ }
            function Save-SourceInfoBaseUnsafeActionProtectionConfirmation {
                param([string]$ConfirmationMode)
                $script:Saves += $ConfirmationMode
                return [pscustomobject]@{ confirmationMode = $ConfirmationMode }
            }
            function Test-InteractiveInputAvailable { return $true }
            function Confirm-SourceInfoBaseUnsafeActionProtection {
                $script:ManualPrompts++
                return [pscustomobject]@{ confirmed = $true }
            }

            $script:Mode = "defer"
            Initialize-SourceInfoBaseUnsafeActionProtection 6>$null
            $script:Mode = "confirmed"
            Initialize-SourceInfoBaseUnsafeActionProtection 6>$null
            $script:Mode = "manual-confirm"
            Initialize-SourceInfoBaseUnsafeActionProtection 6>$null
            [pscustomobject]@{
                clears = $script:Clears
                saves = ($script:Saves -join "|")
                manualPrompts = $script:ManualPrompts
            }
        }

        $result.clears | Should -Be 1
        $result.saves | Should -Be "confirmed|manual-confirm"
        $result.manualPrompts | Should -Be 1
    }

    It "stops a lingering native process after result artifacts are complete" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-native-completion-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $markerPath = Join-Path $tempRoot "complete.txt"
            $elapsed = [System.Diagnostics.Stopwatch]::StartNew()
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $powershellPath = (Get-Command powershell.exe).Source
                Invoke-NativeProcessAndWaitResult `
                    -FilePath $powershellPath `
                    -Arguments @("-NoProfile", "-Command", "Set-Content -LiteralPath '$markerPath' -Value ready; Start-Sleep -Seconds 10") `
                    -TimeoutSeconds 30 `
                    -CompletionProbe { Test-Path -LiteralPath $markerPath -PathType Leaf } `
                    -CompletionGraceSeconds 0
            }
            $elapsed.Stop()
            $result.completedByProbe | Should -BeTrue
            $result.timedOut | Should -BeFalse
            $result.exitCode | Should -Be 0
            $elapsed.Elapsed.TotalSeconds | Should -BeLessThan 5
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "cleans Vanessa test processes before reading the event log" {
        $vanessaPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1"
        $text = Get-Content -LiteralPath $vanessaPath -Raw -Encoding UTF8
        $successStart = $text.IndexOf('$verification = Get-VanessaVerificationStatus')
        $successStart | Should -BeGreaterThan -1
        $successBlock = $text.Substring($successStart)
        $cleanupIndex = $successBlock.IndexOf('Stop-OwnVanessaTestProcessesAndAssert -State $state')
        $eventLogIndex = $successBlock.IndexOf('Test-DevBranchEventLogAfterVanessa')
        $cleanupIndex | Should -BeGreaterThan -1
        $eventLogIndex | Should -BeGreaterThan -1
        $cleanupIndex | Should -BeLessThan $eventLogIndex
    }

    It "stops only current-branch Vanessa test processes and exposes release cleanup action" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-process-cleanup-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $stopped = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $ibPath = Join-Path $tempRoot ".agent-1c\infobases\dev-branches\current-branch"
                $state = [pscustomobject]@{
                    safeDevBranchName = "current-branch"
                    devBranchInfoBasePath = $ibPath
                    worktreePath = $tempRoot
                    vanessaTestPort = 48051
                }
                $script:StoppedIds = @()
                $script:ProcessFixture = @(
                    [pscustomobject]@{ processId = 1001; name = "1cv8c.exe"; commandLine = "1cv8c.exe /TESTCLIENT -TPort 48051 /F `"$ibPath`""; workingSetMb = 10 },
                    [pscustomobject]@{ processId = 1002; name = "1cv8c.exe"; commandLine = "1cv8c.exe /TESTCLIENT -TPort 48052 /F `"D:\worktrees\foreign\base`""; workingSetMb = 10 }
                )
                function Get-OneCProcessInfo {
                    return @($script:ProcessFixture | Where-Object { $script:StoppedIds -notcontains $_.processId })
                }
                function Stop-Process {
                    param([int]$Id, [switch]$Force, [object]$ErrorAction)
                    $script:StoppedIds += $Id
                }
                function Start-Sleep {}

                $cleanup = Stop-OwnVanessaTestProcesses -State $state -BranchWide 6>$null
                if ($cleanup.errors.Count -gt 0 -or $cleanup.remaining.Count -gt 0) {
                    throw "branch-wide cleanup fixture failed"
                }
                @($script:StoppedIds)
            }

            $stopped | Should -Contain 1001
            $stopped | Should -Not -Contain 1002
            $HelperText | Should -Match '"stop-dev-branch-test-clients" \{ Stop-DevBranchTestClients \}'
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "provides monitored unsafe action protection recovery for an existing branch" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help -InfoBaseUser "itl_e2e" *> $null

            $script:SavedDotEnv = @{}
            $script:CapturedConfirmation = $null
            $script:CapturedUpdates = @{}
            function Read-DevBranchState {
                return [pscustomobject]@{
                    devBranch = "itldev/workflow-release-e2e"
                    devBranchName = "workflow-release-e2e"
                    infoBaseKind = "file"
                    devBranchInfoBasePath = "C:\bases\workflow-release-e2e"
                }
            }
            function Assert-DevelopmentBranchWorktreeContext {}
            function Set-DotEnvValues { param([hashtable]$Values) $script:SavedDotEnv = $Values }
            function Import-DotEnv {}
            function Sync-DevBranchContextToDotEnv {}
            function Confirm-DevBranchUnsafeActionProtection {
                param(
                    [string]$InfoBaseKind,
                    [string]$InfoBasePath,
                    [string]$DevBranchName,
                    [string]$SetupModeOverride
                )
                $script:CapturedConfirmation = [pscustomobject]@{
                    infoBaseKind = $InfoBaseKind
                    infoBasePath = $InfoBasePath
                    devBranchName = $DevBranchName
                    setupModeOverride = $SetupModeOverride
                }
                return [pscustomobject]@{
                    mode = "manual-confirm"
                    confirmed = $true
                    confirmedAt = "2026-07-11T20:00:00+03:00"
                    user = "itl_e2e"
                }
            }
            function Update-DevBranchState {
                param([object]$State, [hashtable]$Updates)
                $script:CapturedUpdates = $Updates
            }

            Configure-DevBranchUnsafeActionProtection 6>$null
            [pscustomobject]@{
                savedDotEnv = $script:SavedDotEnv
                confirmation = $script:CapturedConfirmation
                updates = $script:CapturedUpdates
            }
        }

        $result.savedDotEnv.IB_USER | Should -Be "itl_e2e"
        $result.confirmation.setupModeOverride | Should -Be "manual-confirm"
        $result.confirmation.infoBasePath | Should -Be "C:\bases\workflow-release-e2e"
        $result.updates.unsafeActionProtectionConfirmed | Should -BeTrue
        $result.updates.unsafeActionProtectionUser | Should -Be "itl_e2e"
        $HelperText | Should -Match '"configure-dev-branch-unsafe-action-protection" \{ Configure-DevBranchUnsafeActionProtection \}'
        (Get-Content -Raw -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\advanced-actions.md")) | Should -Match "configure-dev-branch-unsafe-action-protection"
    }

    It "routes interactive branch creation through the compact runner and monitored launcher" {
        $configBranchTemplate = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\master\itl-new-config-branch.md.template")
        $extensionBranchTemplate = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\master\itl-new-extension-branch.md.template")
        $forkBranchTemplate = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\dev\itl-fork-branch.md.template")
        $fastSkill = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow-fast\SKILL.md")

        foreach ($text in @($configBranchTemplate, $extensionBranchTemplate)) {
            $text | Should -Match "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip"
        }

        $configBranchTemplate | Should -Match ([regex]::Escape("run-itl-command.ps1 -Windowed -- -Action new-dev-branch"))
        $extensionBranchTemplate | Should -Match ([regex]::Escape("run-itl-command.ps1 -Windowed -- -Action new-extension-dev-branch"))
        $extensionBranchTemplate | Should -Match "ExtensionInitMode Empty"
        $extensionBranchTemplate | Should -Match "ExtensionSourcePath"
        $extensionBranchTemplate | Should -Match "Never ask the developer to open a terminal or copy a PowerShell command"
        $extensionBranchTemplate | Should -Match "-OfferOpenAgent"
        $forkBranchTemplate | Should -Match ([regex]::Escape("run-itl-command.ps1 -- -Action fork-dev-branch"))
        $forkBranchTemplate | Should -Not -Match ([regex]::Escape("run-itl-command.ps1 -Windowed"))
        $fastSkill | Should -Match ([regex]::Escape("run-itl-command.ps1 -Windowed -- -Action new-dev-branch"))
        $fastSkill | Should -Match ([regex]::Escape("run-itl-command.ps1 -Windowed -- -Action new-extension-dev-branch"))
        $fastSkill | Should -Not -Match ([regex]::Escape("run-agent-1c-window.ps1 -- -Action"))
    }

    It "keeps interactive Designer confirmation launch visible" {
        $match = [regex]::Match($HelperText, "(?s)function\s+Invoke-VisibleNativeProcessAndWait\s*\{(?<body>.*?)(?=`r?`nfunction\s+)")
        $match.Success | Should -Be $true
        $match.Groups["body"].Value | Should -Match "Start-Process"
        $match.Groups["body"].Value | Should -Not -Match "WindowStyle"
    }

    It "resolves flat project-qualified worktree paths for default and custom parents" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-worktree-path-test-" + [guid]::NewGuid().ToString("N"))
        $customRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-worktree-custom-root-" + [guid]::NewGuid().ToString("N"))
        $oldWorktreeRoot = [Environment]::GetEnvironmentVariable("DEV_BRANCH_WORKTREE_ROOT", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "README.md") -Value "fixture" -Encoding ASCII
            & git -C $tempRoot init | Out-Null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add README.md
            & git -C $tempRoot commit -m init | Out-Null
            & git -C $tempRoot branch -M master

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $projectName = Split-Path -Leaf $tempRoot

                [Environment]::SetEnvironmentVariable("DEV_BRANCH_WORKTREE_ROOT", $null, "Process")
                $defaultExpected = Join-Path (Split-Path -Parent $tempRoot) "$projectName-feature-one"
                Resolve-DevBranchWorktreePath -SafeDevBranchName "feature-one" | Should -Be ([System.IO.Path]::GetFullPath($defaultExpected))
                Get-LauncherInfoBaseName -SafeDevBranchName "feature-one" -ProjectRootForName $tempRoot | Should -Be "$projectName-feature-one"

                [Environment]::SetEnvironmentVariable("DEV_BRANCH_WORKTREE_ROOT", $customRoot, "Process")
                $customExpected = Join-Path $customRoot "$projectName-feature-two"
                Resolve-DevBranchWorktreePath -SafeDevBranchName "feature-two" | Should -Be ([System.IO.Path]::GetFullPath($customExpected))
            }
        } finally {
            [Environment]::SetEnvironmentVariable("DEV_BRANCH_WORKTREE_ROOT", $oldWorktreeRoot, "Process")
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $customRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $customRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "records a resumable conflict transaction and gives the agent the same-command recovery for every lifecycle merge" {
        foreach ($case in @(
            @{ operation = "refresh-dev-branch"; stage = "refresh.merge-conflicts" },
            @{ operation = "refresh-dev-branch-lite"; stage = "refresh.merge-conflicts" },
            @{ operation = "close-dev-branch"; stage = "close.merge-conflicts" }
        )) {
            $fixture = New-LifecycleMergeConflictFixture
            try {
                $result = & {
                    param($Fixture, $Case)
                    . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                    $DevBranchName = "test"
                    $script:MergeState = [pscustomobject]@{
                        safeDevBranchName = "test"
                        devBranchName = "test"
                        devBranch = "itldev/test"
                    }
                    $script:FailureCategory = ""
                    $script:RequiredAction = ""
                    $script:ConflictStage = ""
                    function Read-DevBranchState { return $script:MergeState }
                    function Update-DevBranchState {
                        param([object]$State, [hashtable]$Updates)
                        foreach ($key in $Updates.Keys) {
                            if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                                $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                            } else {
                                $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                            }
                        }
                    }
                    function Set-RunStage { param([string]$Stage); $script:ConflictStage = $Stage }
                    function Set-RunFailureContext { param([string]$Category, [string]$RequiredAction); $script:FailureCategory = $Category; $script:RequiredAction = $RequiredAction }
                    function Restart-Agent1cAfterDevBranchMerge { throw "unexpected restart" }

                    $message = ""
                    try {
                        Invoke-NewDevBranchLifecycleMerge `
                            -State $script:MergeState `
                            -Operation $Case.operation `
                            -TargetCommit $Fixture.targetCommit `
                            -ConflictStage $Case.stage
                    } catch {
                        $message = $_.Exception.Message
                    }
                    [pscustomobject]@{
                        message = $message
                        category = $script:FailureCategory
                        requiredAction = $script:RequiredAction
                        runStage = $script:ConflictStage
                        pendingOperation = $script:MergeState.pendingMergeOperation
                        pendingBranch = $script:MergeState.pendingMergeBranch
                        pendingBranchCommit = $script:MergeState.pendingMergeBranchCommit
                        pendingTarget = $script:MergeState.pendingMergeTargetCommit
                        pendingStage = $script:MergeState.pendingMergeStage
                        conflicts = @($script:MergeState.pendingMergeConflictPaths)
                        mergeHead = (Get-GitMergeHeadCommit)
                        head = (Get-CurrentCommit)
                        cursor = (Get-Content -LiteralPath (Join-Path $Fixture.root "src\cf\ConfigDumpInfo.xml") -Raw).Trim()
                    }
                } $fixture $case

                $result.message | Should -Match "^LIFECYCLE_MERGE_CONFLICT"
                $result.message | Should -Match "run git add"
                $result.message | Should -Match "Do not create the merge commit manually"
                $result.category | Should -Be "merge-conflict"
                $result.requiredAction | Should -Be "agent-progressive-semantic-repair-run-git-add-repeat-same-itl-command-no-manual-commit"
                $result.runStage | Should -Be $case.stage
                $result.pendingOperation | Should -Be $case.operation
                $result.pendingBranch | Should -Be "itldev/test"
                $result.pendingBranchCommit | Should -Be $fixture.branchCommit
                $result.pendingTarget | Should -Be $fixture.targetCommit
                $result.pendingStage | Should -Be "conflicts"
                $result.conflicts | Should -Be @("conflict.txt")
                $result.mergeHead | Should -Be $fixture.targetCommit
                $result.head | Should -Be $fixture.branchCommit
                $result.cursor | Should -Be "branch-cursor"
            } finally {
                Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "blocks a clean Git merge with duplicate root metadata and commits it after the agent fixes, stages, and retries" {
        $fixture = New-LifecycleMergeSourceIntegrityFixture
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:OneCConfigurationSourceValidatorPathOverride = $Fixture.validatorPath
                $script:MergeState = [pscustomobject]@{ safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test" }
                $script:FailureCategory = ""
                $script:RequiredAction = ""
                $script:FailureStage = ""
                $script:RestartCount = 0
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Set-RunStage { param([string]$Stage, [string]$Detail); $script:FailureStage = $Stage }
                function Set-RunFailureContext { param([string]$Category, [string]$RequiredAction); $script:FailureCategory = $Category; $script:RequiredAction = $RequiredAction }
                function Restart-Agent1cAfterDevBranchMerge { $script:RestartCount++; throw "RESTART_AFTER_MERGE" }

                $firstMessage = ""
                try {
                    Invoke-NewDevBranchLifecycleMerge -State $script:MergeState -Operation "refresh-dev-branch" -TargetCommit $Fixture.targetCommit -ConflictStage "refresh.merge-conflicts"
                } catch {
                    $firstMessage = $_.Exception.Message
                }
                $headBeforeFix = Get-CurrentCommit
                $mergeInProgressBeforeFix = Test-GitMergeInProgress
                $categoryBeforeFix = $script:FailureCategory
                $requiredActionBeforeFix = $script:RequiredAction
                $stageBeforeFix = $script:FailureStage
                $pendingStageBeforeFix = $script:MergeState.pendingMergeStage
                $conflictsBeforeFix = @($script:MergeState.pendingMergeConflictPaths)

                $source = [System.IO.File]::ReadAllText($Fixture.configurationPath, [System.Text.Encoding]::UTF8)
                $duplicate = "    <Constant>Shared</Constant>"
                $lastDuplicate = $source.LastIndexOf($duplicate, [System.StringComparison]::Ordinal)
                $source = $source.Remove($lastDuplicate, $duplicate.Length + 2)
                [System.IO.File]::WriteAllText($Fixture.configurationPath, $source, [System.Text.UTF8Encoding]::new($false))
                Invoke-Git @("add", "--", "src/cf/Configuration.xml")

                $retryMessage = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $retryMessage = $_.Exception.Message
                }
                $head = Get-CurrentCommit
                [pscustomobject]@{
                    firstMessage = $firstMessage
                    retryMessage = $retryMessage
                    category = $categoryBeforeFix
                    requiredAction = $requiredActionBeforeFix
                    failureStage = $stageBeforeFix
                    pendingStageBeforeFix = $pendingStageBeforeFix
                    conflictsBeforeFix = $conflictsBeforeFix
                    headBeforeFix = $headBeforeFix
                    mergeInProgressBeforeFix = $mergeInProgressBeforeFix
                    head = $head
                    parents = @(Get-GitCommitParents -Commit $head)
                    restartCount = $script:RestartCount
                    mergeInProgress = Test-GitMergeInProgress
                    pendingStage = $script:MergeState.pendingMergeStage
                    status = @(& git -C $Fixture.root status --porcelain)
                }
            } $fixture

            $result.firstMessage | Should -Match "^ONEC_SOURCE_INTEGRITY_FAILED"
            $result.firstMessage | Should -Match "Duplicate: Constant.Shared"
            $result.category | Should -Be "source-integrity"
            $result.requiredAction | Should -Be "agent-progressive-semantic-repair-run-git-add-repeat-same-itl-command-no-manual-commit"
            $result.failureStage | Should -Be "source-integrity.failed"
            $result.pendingStageBeforeFix | Should -Be "conflicts"
            $result.conflictsBeforeFix | Should -Be @("src/cf/Configuration.xml")
            $result.headBeforeFix | Should -Be $fixture.branchCommit
            $result.mergeInProgressBeforeFix | Should -BeTrue
            $result.retryMessage | Should -Be "RESTART_AFTER_MERGE"
            $result.parents | Should -Be @($fixture.branchCommit, $fixture.targetCommit)
            $result.restartCount | Should -Be 1
            $result.mergeInProgress | Should -BeFalse
            $result.pendingStage | Should -Be "merged"
            $result.status | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "blocks a clean merge-created duplicate BSL method and resumes after agent repair" {
        $fixture = New-LifecycleMergeBslDuplicateFixture
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:OneCConfigurationSourceValidatorPathOverride = $Fixture.validatorPath
                $script:MergeState = [pscustomobject]@{ safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test" }
                $script:FailureCategory = ""
                $script:RequiredAction = ""
                $script:FailureStage = ""
                $script:RestartCount = 0
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Set-RunStage { param([string]$Stage, [string]$Detail); $script:FailureStage = $Stage }
                function Set-RunFailureContext { param([string]$Category, [string]$RequiredAction); $script:FailureCategory = $Category; $script:RequiredAction = $RequiredAction }
                function Restart-Agent1cAfterDevBranchMerge { $script:RestartCount++; throw "RESTART_AFTER_MERGE" }

                $firstMessage = ""
                try {
                    Invoke-NewDevBranchLifecycleMerge -State $script:MergeState -Operation "refresh-dev-branch" -TargetCommit $Fixture.targetCommit -ConflictStage "refresh.merge-conflicts"
                } catch {
                    $firstMessage = $_.Exception.Message
                }
                $reportPath = $script:RunSourceIntegrityReportPath
                $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $conflictsBeforeFix = @($script:MergeState.pendingMergeConflictPaths)
                $source = [System.IO.File]::ReadAllText($Fixture.modulePath, [System.Text.Encoding]::UTF8)
                $pattern = '(?ms)Процедура ОбщийМетод\(\)\r?\nКонецПроцедуры\r?\n\r?\n'
                $source = [regex]::Replace($source, $pattern, "", 1)
                [System.IO.File]::WriteAllText($Fixture.modulePath, $source, [System.Text.UTF8Encoding]::new($false))
                Invoke-Git @("add", "--", $Fixture.moduleRepoPath)

                $retryMessage = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $retryMessage = $_.Exception.Message
                }
                $head = Get-CurrentCommit
                [pscustomobject]@{
                    firstMessage = $firstMessage
                    retryMessage = $retryMessage
                    category = $script:FailureCategory
                    requiredAction = $script:RequiredAction
                    failureStage = $script:FailureStage
                    reportPath = $reportPath
                    issue = @($report.issues)[0]
                    conflictPaths = $conflictsBeforeFix
                    parents = @(Get-GitCommitParents -Commit $head)
                    restartCount = $script:RestartCount
                    mergeInProgress = Test-GitMergeInProgress
                }
            } $fixture

            $result.firstMessage | Should -Match "^ONEC_SOURCE_INTEGRITY_FAILED"
            $result.firstMessage | Should -Match "ОбщийМетод"
            $result.category | Should -Be "source-integrity"
            $result.requiredAction | Should -Be "agent-progressive-semantic-repair-run-git-add-repeat-same-itl-command-no-manual-commit"
            $result.failureStage | Should -Be "source-integrity.failed"
            $result.reportPath | Should -Exist
            $result.issue.validator | Should -Be "bsl-merge-duplicates"
            $result.issue.code | Should -Be "merge-created-duplicate-declaration"
            $result.issue.path | Should -Be $fixture.moduleRepoPath
            $result.issue.baseCount | Should -Be 0
            $result.issue.branchCount | Should -Be 1
            $result.issue.targetCount | Should -Be 1
            $result.issue.mergedCount | Should -Be 2
            $result.conflictPaths | Should -Be $fixture.moduleRepoPath
            $result.retryMessage | Should -Be "RESTART_AFTER_MERGE"
            $result.parents | Should -Be @($fixture.branchCommit, $fixture.targetCommit)
            $result.restartCount | Should -Be 1
            $result.mergeInProgress | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "routes a clean merge-created form defect to the specialized form validator and resumes after repair" {
        $fixture = New-LifecycleMergeFormIntegrityFixture
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:OneCConfigurationSourceValidatorPathOverride = $Fixture.configurationValidatorPath
                $script:OneCSourceIntegrityValidatorPathOverrides = @{ form = $Fixture.formValidatorPath }
                $script:MergeState = [pscustomobject]@{ safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test" }
                $script:FailureCategory = ""
                $script:RequiredAction = ""
                $script:FailureStage = ""
                $script:RestartCount = 0
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Set-RunStage { param([string]$Stage, [string]$Detail); $script:FailureStage = $Stage }
                function Set-RunFailureContext { param([string]$Category, [string]$RequiredAction); $script:FailureCategory = $Category; $script:RequiredAction = $RequiredAction }
                function Restart-Agent1cAfterDevBranchMerge { $script:RestartCount++; throw "RESTART_AFTER_MERGE" }

                $firstMessage = ""
                try {
                    Invoke-NewDevBranchLifecycleMerge -State $script:MergeState -Operation "refresh-dev-branch" -TargetCommit $Fixture.targetCommit -ConflictStage "refresh.merge-conflicts"
                } catch {
                    $firstMessage = $_.Exception.Message
                }
                $reportPath = $script:RunSourceIntegrityReportPath
                $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $categoryBeforeFix = $script:FailureCategory
                $requiredActionBeforeFix = $script:RequiredAction
                $stageBeforeFix = $script:FailureStage
                $conflictsBeforeFix = @($script:MergeState.pendingMergeConflictPaths)
                $source = [System.IO.File]::ReadAllText($Fixture.formPath, [System.Text.Encoding]::UTF8)
                $duplicate = '    <Item name="Shared" />'
                $lastDuplicate = $source.LastIndexOf($duplicate, [System.StringComparison]::Ordinal)
                $source = $source.Remove($lastDuplicate, $duplicate.Length + 2)
                [System.IO.File]::WriteAllText($Fixture.formPath, $source, [System.Text.UTF8Encoding]::new($false))
                Invoke-Git @("add", "--", $Fixture.formRepoPath)

                $retryMessage = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $retryMessage = $_.Exception.Message
                }
                $head = Get-CurrentCommit
                [pscustomobject]@{
                    firstMessage = $firstMessage
                    retryMessage = $retryMessage
                    category = $categoryBeforeFix
                    requiredAction = $requiredActionBeforeFix
                    failureStage = $stageBeforeFix
                    reportPath = $reportPath
                    issue = @($report.issues)[0]
                    conflictPaths = $conflictsBeforeFix
                    parents = @(Get-GitCommitParents -Commit $head)
                    restartCount = $script:RestartCount
                    mergeInProgress = Test-GitMergeInProgress
                }
            } $fixture

            $result.firstMessage | Should -Match "^ONEC_SOURCE_INTEGRITY_FAILED"
            $result.firstMessage | Should -Match "Duplicate form item Shared"
            $result.category | Should -Be "source-integrity"
            $result.requiredAction | Should -Be "agent-progressive-semantic-repair-run-git-add-repeat-same-itl-command-no-manual-commit"
            $result.failureStage | Should -Be "source-integrity.failed"
            $result.reportPath | Should -Exist
            $result.issue.validator | Should -Be "form"
            $result.issue.code | Should -Be "specialized-validation-failed"
            $result.issue.path | Should -Be $fixture.formRepoPath
            $result.conflictPaths | Should -Be $fixture.formRepoPath
            $result.retryMessage | Should -Be "RESTART_AFTER_MERGE"
            $result.parents | Should -Be @($fixture.branchCommit, $fixture.targetCommit)
            $result.restartCount | Should -Be 1
            $result.mergeInProgress | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "leaves unresolved conflicts untouched and commits them after resolution, staging, and the same command retry" {
        $fixture = New-LifecycleMergeConflictFixture
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:MergeState = [pscustomobject]@{ safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test" }
                $script:RestartCount = 0
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Set-RunStage {}
                function Set-RunFailureContext {}
                function Assert-OneCConfigurationSourceIntegrity {}
                function Restart-Agent1cAfterDevBranchMerge { $script:RestartCount++; throw "RESTART_AFTER_MERGE" }

                try {
                    Invoke-NewDevBranchLifecycleMerge -State $script:MergeState -Operation "refresh-dev-branch" -TargetCommit $Fixture.targetCommit -ConflictStage "refresh.merge-conflicts"
                } catch {}
                $headBeforeRetry = Get-CurrentCommit
                $unresolvedMessage = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $unresolvedMessage = $_.Exception.Message
                }
                $headAfterUnresolvedRetry = Get-CurrentCommit

                Set-Content -LiteralPath (Join-Path $Fixture.root "conflict.txt") -Encoding UTF8 -Value "resolved"
                Invoke-Git @("add", "--", "conflict.txt")
                $resolvedMessage = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $resolvedMessage = $_.Exception.Message
                }
                $head = Get-CurrentCommit
                [pscustomobject]@{
                    unresolvedMessage = $unresolvedMessage
                    resolvedMessage = $resolvedMessage
                    headBeforeRetry = $headBeforeRetry
                    headAfterUnresolvedRetry = $headAfterUnresolvedRetry
                    head = $head
                    parents = @(Get-GitCommitParents -Commit $head)
                    restartCount = $script:RestartCount
                    mergeInProgress = Test-GitMergeInProgress
                    pendingStage = $script:MergeState.pendingMergeStage
                    pendingCommit = $script:MergeState.pendingMergeCommit
                    cursor = (Get-Content -LiteralPath (Join-Path $Fixture.root "src\cf\ConfigDumpInfo.xml") -Raw).Trim()
                    status = @(& git -C $Fixture.root status --porcelain)
                }
            } $fixture

            $result.unresolvedMessage | Should -Match "^LIFECYCLE_MERGE_CONFLICT"
            $result.headBeforeRetry | Should -Be $fixture.branchCommit
            $result.headAfterUnresolvedRetry | Should -Be $fixture.branchCommit
            $result.resolvedMessage | Should -Be "RESTART_AFTER_MERGE"
            $result.parents | Should -Be @($fixture.branchCommit, $fixture.targetCommit)
            $result.restartCount | Should -Be 1
            $result.mergeInProgress | Should -BeFalse
            $result.pendingStage | Should -Be "merged"
            $result.pendingCommit | Should -Be $result.head
            $result.cursor | Should -Be "branch-cursor"
            $result.status | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "blocks unstaged resolutions, unrelated untracked files, and unrelated staged files during resume" {
        foreach ($case in @(
            @{ kind = "unstaged"; expected = "^LIFECYCLE_MERGE_CONFLICT" },
            @{ kind = "untracked"; expected = "^LIFECYCLE_MERGE_UNTRACKED_FILES" },
            @{ kind = "staged"; expected = "^LIFECYCLE_MERGE_UNEXPECTED_STAGED_FILES" }
        )) {
            $fixture = New-LifecycleMergeConflictFixture
            try {
                $result = & {
                    param($Fixture, $Case)
                    . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                    $DevBranchName = "test"
                    $script:MergeState = [pscustomobject]@{ safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test" }
                    function Read-DevBranchState { return $script:MergeState }
                    function Update-DevBranchState {
                        param([object]$State, [hashtable]$Updates)
                        foreach ($key in $Updates.Keys) {
                            if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                                $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                            } else {
                                $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                            }
                        }
                    }
                    function Set-RunStage {}
                    function Set-RunFailureContext {}
                    function Assert-OneCConfigurationSourceIntegrity {}
                    function Restart-Agent1cAfterDevBranchMerge { throw "unexpected restart" }
                    try {
                        Invoke-NewDevBranchLifecycleMerge -State $script:MergeState -Operation "refresh-dev-branch" -TargetCommit $Fixture.targetCommit -ConflictStage "refresh.merge-conflicts"
                    } catch {}

                    Set-Content -LiteralPath (Join-Path $Fixture.root "conflict.txt") -Encoding UTF8 -Value "resolved"
                    Invoke-Git @("add", "--", "conflict.txt")
                    switch ($Case.kind) {
                        "unstaged" { Set-Content -LiteralPath (Join-Path $Fixture.root "conflict.txt") -Encoding UTF8 -Value "resolved-but-not-staged" }
                        "untracked" { Set-Content -LiteralPath (Join-Path $Fixture.root "foreign.txt") -Encoding UTF8 -Value "foreign" }
                        "staged" {
                            Set-Content -LiteralPath (Join-Path $Fixture.root "unrelated.txt") -Encoding UTF8 -Value "foreign-staged"
                            Invoke-Git @("add", "--", "unrelated.txt")
                        }
                    }
                    $message = ""
                    try {
                        Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                    } catch {
                        $message = $_.Exception.Message
                    }
                    [pscustomobject]@{
                        message = $message
                        head = Get-CurrentCommit
                        mergeInProgress = Test-GitMergeInProgress
                    }
                } $fixture $case

                $result.message | Should -Match $case.expected
                $result.head | Should -Be $fixture.branchCommit
                $result.mergeInProgress | Should -BeTrue
            } finally {
                Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "accepts and records a related 1C source repair outside the original conflict set" {
        $fixture = New-LifecycleMergeConflictFixture
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:MergeState = [pscustomobject]@{ safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test" }
                $script:RestartCount = 0
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Set-RunStage {}
                function Set-RunFailureContext {}
                function Assert-OneCConfigurationSourceIntegrity {}
                function Restart-Agent1cAfterDevBranchMerge { $script:RestartCount++; throw "RESTART_AFTER_MERGE" }
                try {
                    Invoke-NewDevBranchLifecycleMerge -State $script:MergeState -Operation "refresh-dev-branch" -TargetCommit $Fixture.targetCommit -ConflictStage "refresh.merge-conflicts"
                } catch {}

                Set-Content -LiteralPath (Join-Path $Fixture.root "conflict.txt") -Encoding UTF8 -Value "resolved"
                Set-Content -LiteralPath (Join-Path $Fixture.root "src\cf\Related.bsl") -Encoding UTF8 -Value "semantically adapted related method"
                Invoke-Git @("add", "--", "conflict.txt", "src/cf/Related.bsl")
                $resumeMessage = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $resumeMessage = $_.Exception.Message
                }
                $head = Get-CurrentCommit
                [pscustomobject]@{
                    resumeMessage = $resumeMessage
                    repairPaths = @($script:MergeState.pendingMergeRepairPaths)
                    allowedPaths = @($script:MergeState.pendingMergePaths)
                    changedPaths = @(Get-GitPathList -Arguments @("diff", "--name-only", "-z", $Fixture.branchCommit, $head))
                    parents = @(Get-GitCommitParents -Commit $head)
                    restartCount = $script:RestartCount
                    mergeInProgress = Test-GitMergeInProgress
                }
            } $fixture

            $result.resumeMessage | Should -Be "RESTART_AFTER_MERGE"
            $result.repairPaths | Should -Be @("src/cf/Related.bsl")
            $result.allowedPaths | Should -Contain "src/cf/Related.bsl"
            $result.changedPaths | Should -Contain "src/cf/Related.bsl"
            $result.parents | Should -Be @($fixture.branchCommit, $fixture.targetCommit)
            $result.restartCount | Should -Be 1
            $result.mergeInProgress | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "blocks a mismatched MERGE_HEAD without committing anything" {
        $fixture = New-LifecycleMergeConflictFixture
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:MergeState = [pscustomobject]@{ safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test" }
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Set-RunStage {}
                function Set-RunFailureContext {}
                function Assert-OneCConfigurationSourceIntegrity {}
                function Restart-Agent1cAfterDevBranchMerge { throw "unexpected restart" }
                try {
                    Invoke-NewDevBranchLifecycleMerge -State $script:MergeState -Operation "refresh-dev-branch" -TargetCommit $Fixture.targetCommit -ConflictStage "refresh.merge-conflicts"
                } catch {}
                $operationMessage = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "close-dev-branch" -ConflictStage "close.merge-conflicts" | Out-Null
                } catch {
                    $operationMessage = $_.Exception.Message
                }
                $mergeHeadPath = (Get-GitOutput @("rev-parse", "--git-path", "MERGE_HEAD")).Trim()
                if (-not [System.IO.Path]::IsPathRooted($mergeHeadPath)) {
                    $mergeHeadPath = Join-Path $Fixture.root $mergeHeadPath
                }
                Set-Content -LiteralPath $mergeHeadPath -Encoding ASCII -Value $Fixture.branchCommit
                $message = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $message = $_.Exception.Message
                }
                [pscustomobject]@{ operationMessage = $operationMessage; message = $message; head = Get-CurrentCommit }
            } $fixture

            $result.operationMessage | Should -Match "^LIFECYCLE_MERGE_OPERATION_MISMATCH"
            $result.message | Should -Match "^LIFECYCLE_MERGE_HEAD_MISMATCH"
            $result.head | Should -Be $fixture.branchCommit
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "recognizes a manually created exact merge commit as an interrupted workflow commit" {
        $fixture = New-LifecycleMergeConflictFixture
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:MergeState = [pscustomobject]@{ safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test" }
                $script:RestartCount = 0
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Set-RunStage {}
                function Set-RunFailureContext {}
                function Assert-OneCConfigurationSourceIntegrity {}
                function Restart-Agent1cAfterDevBranchMerge { $script:RestartCount++; throw "RESTART_AFTER_MERGE" }
                try {
                    Invoke-NewDevBranchLifecycleMerge -State $script:MergeState -Operation "refresh-dev-branch" -TargetCommit $Fixture.targetCommit -ConflictStage "refresh.merge-conflicts"
                } catch {}
                foreach ($name in @($script:MergeState.PSObject.Properties.Name | Where-Object { $_ -like "pendingMerge*" })) {
                    $script:MergeState.PSObject.Properties.Remove($name)
                }
                $legacyConflictMessage = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $legacyConflictMessage = $_.Exception.Message
                }
                Set-Content -LiteralPath (Join-Path $Fixture.root "conflict.txt") -Encoding UTF8 -Value "resolved"
                Invoke-Git @("add", "--", "conflict.txt")
                Invoke-Git @("commit", "--no-edit")
                $manualCommit = Get-CurrentCommit
                $message = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $message = $_.Exception.Message
                }
                [pscustomobject]@{
                    legacyConflictMessage = $legacyConflictMessage
                    message = $message
                    manualCommit = $manualCommit
                    pendingCommit = $script:MergeState.pendingMergeCommit
                    pendingStage = $script:MergeState.pendingMergeStage
                    parents = @(Get-GitCommitParents -Commit $manualCommit)
                    restartCount = $script:RestartCount
                }
            } $fixture

            $result.legacyConflictMessage | Should -Match "^LIFECYCLE_MERGE_CONFLICT"
            $result.message | Should -Be "RESTART_AFTER_MERGE"
            $result.pendingCommit | Should -Be $result.manualCommit
            $result.pendingStage | Should -Be "merged"
            $result.parents | Should -Be @($fixture.branchCommit, $fixture.targetCommit)
            $result.restartCount | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "migrates the existing helper-owned refresh cursor HEAD without replacing the recorded merge commit" {
        $fixture = New-LifecyclePostMergeCursorFixture
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:RestartCount = 0
                $script:MergeState = [pscustomobject]@{
                    safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test"
                    pendingMergeOperation = "refresh-dev-branch"; pendingMergeBranch = "itldev/test"
                    pendingMergeBranchCommit = $Fixture.branchCommit; pendingMergeTargetCommit = $Fixture.targetCommit
                    pendingMergeStage = "merged"; pendingMergePaths = @(); pendingMergeConflictPaths = @()
                    pendingMergeCommit = $Fixture.mergeCommit; pendingMergeResult = "merge-commit"
                }
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Restart-Agent1cAfterDevBranchMerge { $script:RestartCount++; throw "RESTART_AFTER_MERGE" }
                $resumeMessage = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $resumeMessage = $_.Exception.Message
                }
                $postMergeAccepted = $false
                try {
                    Assert-DevBranchLifecycleMergePostMerge -State $script:MergeState -Operation "refresh-dev-branch" | Out-Null
                    $postMergeAccepted = $true
                } catch {}
                [pscustomobject]@{
                    resumeMessage = $resumeMessage
                    mergeCommit = $script:MergeState.pendingMergeCommit
                    postMergeHead = $script:MergeState.pendingMergePostMergeHead
                    postMergeAccepted = $postMergeAccepted
                    restartCount = $script:RestartCount
                }
            } $fixture

            $result.resumeMessage | Should -Be "RESTART_AFTER_MERGE"
            $result.mergeCommit | Should -Be $fixture.mergeCommit
            $result.postMergeHead | Should -Be $fixture.cursorCommit
            $result.postMergeAccepted | Should -BeTrue
            $result.restartCount | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects unproven post-merge descendants instead of widening cursor recovery" {
        foreach ($case in @(
            @{ name = "foreign path"; subject = "chore: persist branch configuration synchronization cursor"; changedPath = "foreign"; additionalHead = "none" },
            @{ name = "wrong subject"; subject = "manual cursor"; changedPath = "cursor"; additionalHead = "none" },
            @{ name = "additional commit"; subject = "chore: persist branch configuration synchronization cursor"; changedPath = "cursor"; additionalHead = "extra" },
            @{ name = "merge commit"; subject = "chore: persist branch configuration synchronization cursor"; changedPath = "cursor"; additionalHead = "merge" }
        )) {
            $fixture = New-LifecyclePostMergeCursorFixture -Subject $case.subject -ChangedPath $case.changedPath -AdditionalHead $case.additionalHead
            try {
                $result = & {
                    param($Fixture)
                    . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                    $DevBranchName = "test"
                    $script:RestartCount = 0
                    $script:MergeState = [pscustomobject]@{
                        safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test"
                        pendingMergeOperation = "refresh-dev-branch"; pendingMergeBranch = "itldev/test"
                        pendingMergeBranchCommit = $Fixture.branchCommit; pendingMergeTargetCommit = $Fixture.targetCommit
                        pendingMergeStage = "merged"; pendingMergePaths = @(); pendingMergeConflictPaths = @()
                        pendingMergeCommit = $Fixture.mergeCommit; pendingMergeResult = "merge-commit"
                    }
                    function Read-DevBranchState { return $script:MergeState }
                    function Update-DevBranchState {
                        param([object]$State, [hashtable]$Updates)
                        foreach ($key in $Updates.Keys) {
                            if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                                $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                            } else {
                                $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                            }
                        }
                    }
                    function Restart-Agent1cAfterDevBranchMerge { $script:RestartCount++ }
                    $message = ""
                    try {
                        Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                    } catch {
                        $message = $_.Exception.Message
                    }
                    [pscustomobject]@{
                        message = $message
                        mergeCommit = $script:MergeState.pendingMergeCommit
                        postMergeHead = [string](Get-StateValue -State $script:MergeState -Name "pendingMergePostMergeHead" -Default "")
                        restartCount = $script:RestartCount
                    }
                } $fixture

                $result.message | Should -Match "^LIFECYCLE_MERGE_POST_HEAD_MISMATCH" -Because $case.name
                $result.mergeCommit | Should -Be $fixture.mergeCommit -Because $case.name
                $result.postMergeHead | Should -BeNullOrEmpty -Because $case.name
                $result.restartCount | Should -Be 0 -Because $case.name
            } finally {
                Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "completes a pending refresh on a corrective descendant only after fresh full verification" {
        $fixture = New-LifecyclePostMergeCursorFixture -AdditionalHead extra
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:MergeState = [pscustomobject]@{
                    safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test"
                    pendingMergeOperation = "refresh-dev-branch"; pendingMergeBranch = "itldev/test"
                    pendingMergeBranchCommit = $Fixture.branchCommit; pendingMergeTargetCommit = $Fixture.targetCommit
                    pendingMergeStage = "merged"; pendingMergePaths = @(); pendingMergeConflictPaths = @()
                    pendingMergeCommit = $Fixture.mergeCommit; pendingMergePostMergeHead = $Fixture.cursorCommit; pendingMergeResult = "merge-commit"
                    lastVerificationStatus = "passed"; lastVerificationEvidenceKind = "full"
                    lastVerifiedCommit = $Fixture.head; lastVerifiedAt = "2026-09-02T12:10:00+03:00"
                    configLoadStatus = "passed"; lastConfigBaseUpdateAt = "2026-09-02T12:00:00+03:00"
                    enterpriseNormalizationStatus = "passed"
                }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }

                $completed = Complete-PendingDevBranchRefreshAfterVerifiedRecovery -State $script:MergeState -RecoveryOperation "check-dev-branch"
                [pscustomobject]@{
                    completed = $completed
                    pendingOperation = $script:MergeState.pendingMergeOperation
                    refreshCommit = $script:MergeState.lastRefreshMasterCommit
                    refreshMode = $script:MergeState.lastRefreshMode
                    recoveryOperation = $script:MergeState.lastRefreshRecoveryOperation
                    recoveredHead = $script:MergeState.lastRefreshRecoveredHead
                    currentHead = Get-CurrentCommit
                }
            } $fixture

            $result.completed | Should -BeTrue
            $result.pendingOperation | Should -BeNullOrEmpty
            $result.refreshCommit | Should -Be $fixture.targetCommit
            $result.refreshMode | Should -Be "full"
            $result.recoveryOperation | Should -Be "check-dev-branch"
            $result.recoveredHead | Should -Be $fixture.head
            $result.currentHead | Should -Be $fixture.head
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps a pending refresh when full verification is stale" {
        $fixture = New-LifecyclePostMergeCursorFixture -AdditionalHead extra
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:MergeState = [pscustomobject]@{
                    safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test"
                    pendingMergeOperation = "refresh-dev-branch"; pendingMergeBranch = "itldev/test"
                    pendingMergeBranchCommit = $Fixture.branchCommit; pendingMergeTargetCommit = $Fixture.targetCommit
                    pendingMergeStage = "merged"; pendingMergePaths = @(); pendingMergeConflictPaths = @()
                    pendingMergeCommit = $Fixture.mergeCommit; pendingMergePostMergeHead = $Fixture.cursorCommit; pendingMergeResult = "merge-commit"
                    lastVerificationStatus = "passed"; lastVerificationEvidenceKind = "full"
                    lastVerifiedCommit = $Fixture.cursorCommit; lastVerifiedAt = "2026-09-02T12:10:00+03:00"
                    configLoadStatus = "passed"; lastConfigBaseUpdateAt = "2026-09-02T12:00:00+03:00"
                    enterpriseNormalizationStatus = "passed"
                }
                function Update-DevBranchState { throw "state must not change" }

                $completed = Complete-PendingDevBranchRefreshAfterVerifiedRecovery -State $script:MergeState -RecoveryOperation "check-dev-branch"
                [pscustomobject]@{
                    completed = $completed
                    pendingOperation = $script:MergeState.pendingMergeOperation
                }
            } $fixture

            $result.completed | Should -BeFalse
            $result.pendingOperation | Should -Be "refresh-dev-branch"
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "checkpoints the helper cursor before a later runner failure and resumes from that exact HEAD" {
        $fixture = New-LifecyclePostMergeCursorFixture -SkipCursor
        try {
            $result = & {
                param($Fixture)
                . $HelperPath -ProjectRoot $Fixture.root -Action help *> $null
                $DevBranchName = "test"
                $script:RestartCount = 0
                $script:MergeState = [pscustomobject]@{
                    safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test"
                    pendingMergeOperation = "refresh-dev-branch"; pendingMergeBranch = "itldev/test"
                    pendingMergeBranchCommit = $Fixture.branchCommit; pendingMergeTargetCommit = $Fixture.targetCommit
                    pendingMergeStage = "merged"; pendingMergePaths = @(); pendingMergeConflictPaths = @()
                    pendingMergeCommit = $Fixture.mergeCommit; pendingMergePostMergeHead = $Fixture.mergeCommit; pendingMergeResult = "merge-commit"
                }
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Restart-Agent1cAfterDevBranchMerge { $script:RestartCount++; throw "RESTART_AFTER_MERGE" }

                Set-Content -LiteralPath (Join-Path $Fixture.root "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "post-merge-cursor"
                Set-Content -LiteralPath (Join-Path $Fixture.root "foreign.txt") -Encoding UTF8 -Value "later runner failure"
                $loadResult = [pscustomobject]@{ currentCommit = "stale" }
                $failure = ""
                try {
                    Complete-RefreshConfigDumpInfoPostcondition `
                        -LoadResult $loadResult `
                        -ExportPath "src/cf" `
                        -State $script:MergeState `
                        -Operation "refresh-dev-branch"
                } catch {
                    $failure = $_.Exception.Message
                }
                Remove-Item -LiteralPath (Join-Path $Fixture.root "foreign.txt") -Force
                $resumeMessage = ""
                try {
                    Resume-DevBranchLifecycleMergeIfPresent -State $script:MergeState -Operation "refresh-dev-branch" -ConflictStage "refresh.merge-conflicts" | Out-Null
                } catch {
                    $resumeMessage = $_.Exception.Message
                }
                [pscustomobject]@{
                    failure = $failure
                    resumeMessage = $resumeMessage
                    mergeCommit = $script:MergeState.pendingMergeCommit
                    postMergeHead = $script:MergeState.pendingMergePostMergeHead
                    head = Get-CurrentCommit
                    restartCount = $script:RestartCount
                }
            } $fixture

            $result.failure | Should -Match "^Git worktree is not clean"
            $result.resumeMessage | Should -Be "RESTART_AFTER_MERGE"
            $result.mergeCommit | Should -Be $fixture.mergeCommit
            $result.postMergeHead | Should -Be $result.head
            $result.postMergeHead | Should -Not -Be $fixture.mergeCommit
            $result.restartCount | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $fixture.root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "records an already-contained target as a proven no-op without creating an empty merge commit" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-merge-noop-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            Set-Content -LiteralPath (Join-Path $tempRoot "base.txt") -Encoding UTF8 -Value "base"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M master
            $targetCommit = (& git -C $tempRoot rev-parse HEAD).Trim()
            & git -C $tempRoot checkout --quiet -b itldev/test
            Set-Content -LiteralPath (Join-Path $tempRoot "branch.txt") -Encoding UTF8 -Value "branch"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "branch" *> $null
            $branchCommit = (& git -C $tempRoot rev-parse HEAD).Trim()

            $result = & {
                param($TempRoot, $TargetCommit)
                . $HelperPath -ProjectRoot $TempRoot -Action help *> $null
                $DevBranchName = "test"
                $script:MergeState = [pscustomobject]@{ safeDevBranchName = "test"; devBranchName = "test"; devBranch = "itldev/test" }
                function Read-DevBranchState { return $script:MergeState }
                function Update-DevBranchState {
                    param([object]$State, [hashtable]$Updates)
                    foreach ($key in $Updates.Keys) {
                        if ($null -eq $script:MergeState.PSObject.Properties[$key]) {
                            $script:MergeState | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key]
                        } else {
                            $script:MergeState.PSObject.Properties[$key].Value = $Updates[$key]
                        }
                    }
                }
                function Restart-Agent1cAfterDevBranchMerge { throw "RESTART_AFTER_MERGE" }
                $message = ""
                try {
                    Invoke-NewDevBranchLifecycleMerge -State $script:MergeState -Operation "refresh-dev-branch-lite" -TargetCommit $TargetCommit -ConflictStage "refresh.merge-conflicts"
                } catch {
                    $message = $_.Exception.Message
                }
                [pscustomobject]@{
                    message = $message
                    head = Get-CurrentCommit
                    stage = $script:MergeState.pendingMergeStage
                    result = $script:MergeState.pendingMergeResult
                    mergeCommit = $script:MergeState.pendingMergeCommit
                    parents = @(Get-GitCommitParents -Commit (Get-CurrentCommit))
                }
            } $tempRoot $targetCommit

            $result.message | Should -Be "RESTART_AFTER_MERGE"
            $result.head | Should -Be $branchCommit
            $result.stage | Should -Be "merged"
            $result.result | Should -Be "already-up-to-date"
            $result.mergeCommit | Should -Be $branchCommit
            $result.parents | Should -Be @($targetCommit)
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps branch ConfigDumpInfo cursors with Unicode paths when master is merged" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-dump-info-merge-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf") | Out-Null
            $unicodeExtensionRoot = Join-Path $tempRoot "src\cfe\Тестовое расширение"
            New-Item -ItemType Directory -Force -Path $unicodeExtensionRoot | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot config core.quotePath true
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "base-cursor"
            Set-Content -LiteralPath (Join-Path $unicodeExtensionRoot "ConfigDumpInfo.xml") -Encoding UTF8 -Value "base-extension-cursor"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Encoding UTF8 -Value "<Configuration />"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M master

            & git -C $tempRoot checkout --quiet -b itldev/test
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "branch-cursor"
            Set-Content -LiteralPath (Join-Path $unicodeExtensionRoot "ConfigDumpInfo.xml") -Encoding UTF8 -Value "branch-extension-cursor"
            Set-Content -LiteralPath (Join-Path $tempRoot "branch.txt") -Encoding UTF8 -Value "branch"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "branch cursor" *> $null

            & git -C $tempRoot checkout --quiet master
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "master-cursor"
            Set-Content -LiteralPath (Join-Path $unicodeExtensionRoot "ConfigDumpInfo.xml") -Encoding UTF8 -Value "master-extension-cursor"
            Set-Content -LiteralPath (Join-Path $tempRoot "master.txt") -Encoding UTF8 -Value "master"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "master cursor" *> $null
            & git -C $tempRoot checkout --quiet itldev/test

            & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Assert-OneCConfigurationSourceIntegrity {}
                Merge-MasterPreservingBranchConfigDumpInfo -MasterBranch master
            }

            (Get-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Raw).Trim() | Should -Be "branch-cursor"
            (Get-Content -LiteralPath (Join-Path $unicodeExtensionRoot "ConfigDumpInfo.xml") -Raw).Trim() | Should -Be "branch-extension-cursor"
            Test-Path -LiteralPath (Join-Path $tempRoot "master.txt") -PathType Leaf | Should -BeTrue
            @((& git -C $tempRoot rev-list --parents -n 1 HEAD) -split "\s+").Count | Should -Be 3
            ((& git -C $tempRoot status --porcelain) -join "") | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "commits only a changed refresh cursor and leaves the worktree clean" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-refresh-cursor-commit-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf") | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "before"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\Configuration.xml") -Encoding UTF8 -Value "<Configuration />"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            & git -C $tempRoot branch -M itldev/test
            $beforeCommit = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "after"

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $loadResult = [pscustomobject]@{ currentCommit = $beforeCommit }
                Complete-RefreshConfigDumpInfoPostcondition -LoadResult $loadResult -ExportPath "src/cf"
                [pscustomobject]@{
                    currentCommit = $loadResult.currentCommit
                    head = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()
                    subject = ((& git -C $tempRoot log -1 --format=%s) -join "").Trim()
                    paths = @(& git -C $tempRoot show --format= --name-only HEAD | Where-Object { $_ })
                    status = @(& git -C $tempRoot status --porcelain)
                }
            }

            $result.head | Should -Not -Be $beforeCommit
            $result.currentCommit | Should -Be $result.head
            $result.subject | Should -Be "chore: persist branch configuration synchronization cursor"
            @($result.paths).Count | Should -Be 1
            $result.paths[0] | Should -Be "src/cf/ConfigDumpInfo.xml"
            @($result.status).Count | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "does not create an empty refresh cursor commit" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-refresh-cursor-clean-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf") | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            $beforeCommit = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $loadResult = [pscustomobject]@{ currentCommit = "stale" }
                Complete-RefreshConfigDumpInfoPostcondition -LoadResult $loadResult -ExportPath "src/cf"
                [pscustomobject]@{
                    currentCommit = $loadResult.currentCommit
                    head = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()
                    status = @(& git -C $tempRoot status --porcelain)
                }
            }

            $result.head | Should -Be $beforeCommit
            $result.currentCommit | Should -Be $beforeCommit
            @($result.status).Count | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "fails before committing when refresh changes another tracked file" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-refresh-cursor-unexpected-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf") | Out-Null
            & git -C $tempRoot init *> $null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "before"
            Set-Content -LiteralPath (Join-Path $tempRoot "tracked.txt") -Encoding UTF8 -Value "before"
            & git -C $tempRoot add .
            & git -C $tempRoot commit -m "base" *> $null
            $beforeCommit = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "after"
            Set-Content -LiteralPath (Join-Path $tempRoot "tracked.txt") -Encoding UTF8 -Value "after"

            $message = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                try {
                    Complete-RefreshConfigDumpInfoPostcondition -LoadResult ([pscustomobject]@{ currentCommit = $beforeCommit }) -ExportPath "src/cf"
                } catch {
                    $_.Exception.Message
                }
            }

            $message | Should -Match "^REFRESH_TRACKED_STATE_UNEXPECTED:"
            $message | Should -Match "tracked.txt"
            ((& git -C $tempRoot rev-parse HEAD) -join "").Trim() | Should -Be $beforeCommit
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps refresh failures correctly routed and persists only managed refresh state" {
        $refresh = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:RunErrorCategory = ""
            $script:RunRequiredAction = ""
            Set-RunFailureContextFromMessage -Message "REFRESH_TRACKED_STATE_UNEXPECTED: .kilo/kilo.json" -RequestedAction "refresh-dev-branch"
            [pscustomobject]@{ category = $script:RunErrorCategory; requiredAction = $script:RunRequiredAction }
        }
        $refresh.category | Should -Be "runner"
        $refresh.requiredAction | Should -BeNullOrEmpty

        $lifecycleText = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:RunErrorCategory = ""
            $script:RunRequiredAction = ""
            Set-RunFailureContextFromMessage -Message "Expected helper state was not found" -RequestedAction "refresh-dev-branch"
            [pscustomobject]@{ category = $script:RunErrorCategory; requiredAction = $script:RunRequiredAction }
        }
        $lifecycleText.category | Should -Be "runner"
        $lifecycleText.requiredAction | Should -BeNullOrEmpty

        $verification = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:RunErrorCategory = ""
            $script:RunRequiredAction = ""
            Set-RunFailureContextFromMessage -Message "Expected X, got Y" -RequestedAction "check-dev-branch"
            [pscustomobject]@{ category = $script:RunErrorCategory; requiredAction = $script:RunRequiredAction }
        }
        $verification.category | Should -Be "product-assertion"
        $verification.requiredAction | Should -Be "/itl-verify-fix"
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-refresh-kilo-managed-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf"), (Join-Path $tempRoot ".kilo") | Out-Null
            & git -C $tempRoot init *> $null; & git -C $tempRoot config user.email "test@example.com"; & git -C $tempRoot config user.name "Test User"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor"
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Encoding UTF8 -Value '{"mcp":{"itl-roctup-data":{"command":["branch-helper"]},"custom":{"url":"http://custom"}},"instructions":["USER-RULES.md"],"permission":{"bash":"ask"}}'
            & git -C $tempRoot add .; & git -C $tempRoot commit -m "base" *> $null

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $snapshot = New-RefreshTrackedKiloConfigSnapshot
                Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Encoding UTF8 -Value '{"mcp":{"custom":{"url":"http://custom"},"itl-roctup-data":{"command":["main-helper"]}},"instructions":["USER-RULES.md"],"permission":{"bash":"ask"}}'
                $loadResult = [pscustomobject]@{ currentCommit = "stale" }
                Complete-RefreshConfigDumpInfoPostcondition -LoadResult $loadResult -ExportPath "src/cf" -TrackedKiloSnapshot $snapshot
                [pscustomobject]@{
                    currentCommit = $loadResult.currentCommit
                    subject = ((& git -C $tempRoot log -1 --format=%s) -join "").Trim()
                    status = @(& git -C $tempRoot status --porcelain)
                    config = Get-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Raw -Encoding UTF8 | ConvertFrom-Json
                }
            }

            $result.subject | Should -Be "chore: persist branch refresh state"; $result.currentCommit | Should -Be (((& git -C $tempRoot rev-parse HEAD) -join "").Trim()); @($result.status).Count | Should -Be 0
            $result.config.mcp.'itl-roctup-data'.command[0] | Should -Be "main-helper"
            $result.config.mcp.custom.url | Should -Be "http://custom"; @($result.config.instructions) | Should -Be @("USER-RULES.md"); $result.config.permission.bash | Should -Be "ask"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-refresh-kilo-unmanaged-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot "src\cf"), (Join-Path $tempRoot ".kilo") | Out-Null
            & git -C $tempRoot init *> $null; & git -C $tempRoot config user.email "test@example.com"; & git -C $tempRoot config user.name "Test User"
            Set-Content -LiteralPath (Join-Path $tempRoot "src\cf\ConfigDumpInfo.xml") -Encoding UTF8 -Value "cursor"
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Encoding UTF8 -Value '{"mcp":{"custom":{"url":"http://before"}},"permission":{"bash":"ask"}}'
            & git -C $tempRoot add .; & git -C $tempRoot commit -m "base" *> $null

            $message = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $snapshot = New-RefreshTrackedKiloConfigSnapshot
                Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Encoding UTF8 -Value '{"mcp":{"custom":{"url":"http://after"}},"permission":{"bash":"ask"}}'
                try {
                    Complete-RefreshConfigDumpInfoPostcondition -LoadResult ([pscustomobject]@{ currentCommit = "stale" }) -ExportPath "src/cf" -TrackedKiloSnapshot $snapshot
                } catch {
                    $_.Exception.Message
                }
            }

            $message | Should -Match "^REFRESH_TRACKED_STATE_UNEXPECTED:"; $message | Should -Match ([regex]::Escape(".kilo/kilo.json")); $message | Should -Match "non-ITL content"
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        $match = [regex]::Match($HelperText, "(?s)function\s+Invoke-RefreshDevBranchCore\s*\{(?<body>.*?)(?=`r?`nfunction\s+Refresh-DevBranch\s*\{)")
        $match.Success | Should -BeTrue
        $body = $match.Groups["body"].Value
        $postconditionIndex = $body.LastIndexOf("Complete-RefreshConfigDumpInfoPostcondition")
        $postconditionIndex | Should -BeGreaterThan $body.LastIndexOf("Invoke-DevBranchDefaultMcpSetup"); $postconditionIndex | Should -BeGreaterThan $body.LastIndexOf("Invoke-DevBranchMcpRestartAfterInfobaseLoad")
        $postconditionIndex | Should -BeGreaterThan $body.LastIndexOf("Sync-KiloItlCommandSurface"); $postconditionIndex | Should -BeGreaterThan $body.LastIndexOf("Invoke-AiRules1cManagedMcpConfigReconcile")
    }

    It "does not run the refresh cursor postcondition after a failed configuration load" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $LifecyclePhase = "post-merge"
            $script:PostconditionCalls = 0
            $state = [pscustomobject]@{
                pendingRefreshMasterCommit = ("a" * 40)
                devBranchInfoBasePath = "D:\fixture\base"
                infoBaseKind = "file"
            }
            function Read-DevBranchState { return $state }
            function Assert-DevelopmentBranchWorktreeContext {}
            function Assert-DevBranchExtensionInitialized {}
            function Assert-CleanGit {}
            function Assert-DevBranchLifecycleMergePostMerge { [pscustomobject]@{ targetCommit = ("a" * 40) } }
            function Sync-DevBranchContextToDotEnv {}
            function Install-VanessaAutomation {}
            function Invoke-DevBranchDefaultMcpSetup { param([object]$State) return $State }
            function Load-ConfigFromFiles { throw "simulated load failure after ConfigDumpInfo rollback" }
            function Complete-RefreshConfigDumpInfoPostcondition { $script:PostconditionCalls++ }
            $message = ""
            try { Invoke-RefreshDevBranchCore -OperationName "refresh-dev-branch" } catch { $message = $_.Exception.Message }
            [pscustomobject]@{ message = $message; postconditionCalls = $script:PostconditionCalls }
        }
        $result.message | Should -Be "simulated load failure after ConfigDumpInfo rollback"
        $result.postconditionCalls | Should -Be 0
    }

    It "limits a new worktree path to 50 characters and reports the available branch name length" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null

            function Get-MainWorktreePath {
                return "C:\Users\e.ermakov\W\test3"
            }

            function Get-DevBranchWorktreeRoot {
                return "C:\Users\e.ermakov\W"
            }

            $acceptedName = "12345678901234567890123"
            $rejectedName = (("x" * 79) -join "")
            $acceptedPath = Resolve-DevBranchWorktreePath -SafeDevBranchName $acceptedName
            Assert-DevBranchWorktreePathBudget -WorktreePath $acceptedPath -SafeDevBranchName $acceptedName | Out-Null

            $message = ""
            $rejectedPath = ""
            try {
                $rejectedPath = Resolve-DevBranchWorktreePath -SafeDevBranchName $rejectedName
                Assert-DevBranchWorktreePathBudget -WorktreePath $rejectedPath -SafeDevBranchName $rejectedName | Out-Null
            } catch {
                $message = $_.Exception.Message
            }

            [pscustomobject]@{
                acceptedLength = $acceptedPath.Length
                rejectedLength = $rejectedPath.Length
                message = $message
                firstLine = @($message -split "\r?\n")[0]
            }
        }

        $result.acceptedLength | Should -Be 50
        $result.rejectedLength | Should -Be 106
        $result.firstLine | Should -Match "сейчас 79"
        $result.firstLine | Should -Match "допустимо не более 23"
        $result.firstLine | Should -Match "нужно убрать минимум 56"
        $result.message | Should -Match "MAX_PATH=260"
    }

    It "stops direct non-interactive manual unsafe action confirmation before creating a worktree" {
        $tempRoot = New-ShortWorkflowProjectRoot
        $legacyWorktreeRoot = "$tempRoot-worktrees"
        $worktreePath = "$tempRoot-needs-confirmation"
        $sourceBase = Join-Path $tempRoot "source-base"
        $oldAppData = $env:APPDATA
        $oldUnsafeSetup = [Environment]::GetEnvironmentVariable("DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP", "Process")
        $oldPrefixedUnsafeSetup = [Environment]::GetEnvironmentVariable("AGENT_1C_DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP", "Process")

        try {
            [Environment]::SetEnvironmentVariable("DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP", $null, "Process")
            [Environment]::SetEnvironmentVariable("AGENT_1C_DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP", $null, "Process")

            New-Item -ItemType Directory -Force -Path $sourceBase | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8.1CD") -Value "stub" -Encoding ASCII
            New-Item -ItemType Directory -Force -Path (Join-Path $sourceBase "1Cv8Log") | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8Log\1Cv8.lgf") -Value "" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Value ".dev.env`nsource-base/`nappdata/`n" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot "README.md") -Value "fixture" -Encoding ASCII
            $devEnv = @(
                "INFOBASE_KIND=file",
                "SOURCE_USES_REPOSITORY=false",
                "SOURCE_INFOBASE_PATH=$sourceBase",
                "IB_USER=",
                "IB_PASSWORD=",
                "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=manual-confirm",
                "WEB_PUBLISH_BY_DEFAULT=false",
                "ROCTUP_MCP_AUTO_START=false",
                "VANESSA_MCP_AUTO_START=false"
            ) -join [Environment]::NewLine
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Value $devEnv -Encoding UTF8

            & git -C $tempRoot init | Out-Null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore README.md
            & git -C $tempRoot commit -m init | Out-Null
            & git -C $tempRoot branch -M master

            $env:APPDATA = Join-Path $tempRoot "appdata"
            $result = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @("-ProjectRoot", $tempRoot, "-Action", "new-dev-branch", "-DevBranchName", "Needs Confirmation")
            $result.exitCode | Should -Not -Be 0
            $outputText = $result.combinedText
            $outputText | Should -Match "run-agent-1c-window\.ps1"
            $outputText | Should -Match "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip"

            ((& git -C $tempRoot branch --list "itldev/needs-confirmation") -join "") | Should -Be ""
            (Test-Path -LiteralPath $worktreePath -ErrorAction SilentlyContinue) | Should -Be $false
            (Test-Path -LiteralPath (Join-Path $tempRoot ".agent-1c\dev-branches\needs-confirmation.json") -PathType Leaf -ErrorAction SilentlyContinue) | Should -Be $false
        } finally {
            $env:APPDATA = $oldAppData
            [Environment]::SetEnvironmentVariable("DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP", $oldUnsafeSetup, "Process")
            [Environment]::SetEnvironmentVariable("AGENT_1C_DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP", $oldPrefixedUnsafeSetup, "Process")
            if (Test-Path -LiteralPath $worktreePath -PathType Container -ErrorAction SilentlyContinue) {
                & git -C $tempRoot worktree remove --force $worktreePath *> $null
            }
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $legacyWorktreeRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $legacyWorktreeRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "creates a sibling worktree branch without starting branch MCP even when legacy auto-start is true" {
        $tempRoot = New-ShortWorkflowProjectRoot
        $legacyWorktreeRoot = "$tempRoot-worktrees"
        $worktreePath = "$tempRoot-fixture-branch"
        $sourceBase = Join-Path $tempRoot "source-base"
        $facadeFixtureRoot = "$tempRoot-facade-fixture"
        $projectName = Split-Path -Leaf $tempRoot
        $oldAppData = $env:APPDATA
        $oldOnDemandInstallRoot = $env:ITL_ONDEMAND_MCP_INSTALL_ROOT

        try {
            New-Item -ItemType Directory -Force -Path $sourceBase | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8.1CD") -Value "stub" -Encoding ASCII
            New-Item -ItemType Directory -Force -Path (Join-Path $sourceBase "1Cv8Log") | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8Log\1Cv8.lgf") -Value "" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Value ".dev.env`nsource-base/`nappdata/`n.agent-1c/`n.kilo/commands/itl*.md`n" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot "README.md") -Value "fixture" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Value '{"tools":["kilocode"],"files":{}}' -Encoding UTF8
            $templateTarget = Join-Path $tempRoot ".agents\skills\1c-workflow\kilo-command-templates"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $templateTarget) | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates") -Destination $templateTarget -Recurse
            $fakePlatform = Copy-AutoUpdateToolFixture -TargetRoot $tempRoot
            $env:ITL_ONDEMAND_MCP_INSTALL_ROOT = New-ItlOnDemandMcpInstallFixture -TargetRoot $facadeFixtureRoot
            $devEnv = @(
                "PLATFORM_PATH=$fakePlatform",
                "INFOBASE_KIND=file",
                "SOURCE_USES_REPOSITORY=false",
                "SOURCE_INFOBASE_PATH=$sourceBase",
                "IB_USER=",
                "IB_PASSWORD=",
                "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip",
                "WEB_PUBLISH_BY_DEFAULT=false",
                "ROCTUP_MCP_AUTO_START=true",
                "VANESSA_MCP_AUTO_START=true",
                "AGENT_TOOLS=kilocode"
            ) -join [Environment]::NewLine
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Value $devEnv -Encoding UTF8

            & git -C $tempRoot init | Out-Null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore README.md .ai-rules.json .agents
            & git -C $tempRoot commit -m init | Out-Null
            & git -C $tempRoot branch -M master

            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Value '{"instructions":["USER-RULES.md","docs/custom.md"],"permission":{"bash":"ask"}}' -Encoding ASCII

            New-TestBranchSeedFixture -ProjectRoot $tempRoot -SourceInfoBasePath $sourceBase
            $env:APPDATA = Join-Path $tempRoot "appdata"
            & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action new-dev-branch -DevBranchName "Fixture Branch" *> $null
            $LASTEXITCODE | Should -Be 0

            ((& git -C $tempRoot branch --show-current).Trim()) | Should -Be "master"
            (Test-Path -LiteralPath $worktreePath -PathType Container) | Should -Be $true
            (Test-Path -LiteralPath $legacyWorktreeRoot -ErrorAction SilentlyContinue) | Should -Be $false
            (Test-Path -LiteralPath (Join-Path $worktreePath ".dev.env") -PathType Leaf) | Should -Be $true
            (Get-Content -Encoding UTF8 -Raw (Join-Path $worktreePath ".dev.env")) | Should -Match ([regex]::Escape("SOURCE_INFOBASE_PATH=$sourceBase"))
            $statePath = Join-Path $worktreePath ".agent-1c\dev-branches\fixture-branch.json"
            (Test-Path -LiteralPath $statePath -PathType Leaf) | Should -Be $true
            $state = Get-Content -Encoding UTF8 -Raw $statePath | ConvertFrom-Json
            ([bool]$state.createdWithWorktree) | Should -Be $true
            $state.worktreePath | Should -Be ([System.IO.Path]::GetFullPath($worktreePath))
            $state.mainWorktreePath | Should -Be ([System.IO.Path]::GetFullPath($tempRoot))
            $expectedLauncherFolder = "/ITL/" + (Split-Path -Leaf $tempRoot)
            $expectedLauncherName = "$projectName-fixture-branch"
            $state.launcherInfoBaseName | Should -Be $expectedLauncherName
            $state.launcherFolder | Should -Be $expectedLauncherFolder
            $state.unsafeActionProtectionSetupMode | Should -Be "skip"
            ([bool]$state.unsafeActionProtectionConfirmed) | Should -Be $false
            $state.initializationStatus | Should -Be "ready"
            $state.initializationError | Should -Be ""
            $state.initializationUpdatedAt | Should -Not -BeNullOrEmpty
            $state.publicationStatus | Should -Be "disabled"
            $state.publicationMode | Should -Be "none"
            $state.publicationUrl | Should -Be ""
            $state.roctupMcpStatus | Should -Be "stopped"
            [int]$state.roctupMcpPort | Should -Be 0
            $state.roctupMcpPid | Should -Be ""
            $state.roctupMcpUrl | Should -Be ""
            $state.roctupMcpHealthUrl | Should -Be ""
            $state.vanessaMcpStatus | Should -Be "stopped"
            [int]$state.vanessaMcpPort | Should -Be 0
            $state.vanessaMcpPid | Should -Be ""
            $state.vanessaMcpUrl | Should -Be ""
            (Test-Path -LiteralPath (Join-Path $worktreePath ".codex\config.toml") -PathType Leaf -ErrorAction SilentlyContinue) | Should -BeFalse
            $kiloText = Get-Content -Encoding UTF8 -Raw (Join-Path $worktreePath ".kilo\kilo.json")
            $kiloText | Should -Not -Match "itl-.*-roctup"
            $kiloText | Should -Not -Match "VanessaAutomation-"
            $kiloConfig = $kiloText | ConvertFrom-Json
            @($kiloConfig.instructions) | Should -Be @("USER-RULES.md", "docs/custom.md")
            $kiloConfig.permission.bash | Should -Be "ask"
            $kiloConfig.PSObject.Properties.Name | Should -Not -Contain "plugin"
            $branchKiloCommands = @(Get-ChildItem -LiteralPath (Join-Path $worktreePath ".kilo\commands") -File -Filter "itl*.md" | Select-Object -ExpandProperty Name | Sort-Object)
            $branchKiloCommands | Should -Be @(@("itl.md", "itl-check.md", "itl-fork-branch.md", "itl-litemode.md", "itl-lock-objects.md", "itl-refresh.md", "itl-refresh-lite.md", "itl-reset-branch.md", "itl-result.md", "itl-status.md", "itl-sync-master.md", "itl-update-workflow.md", "itl-verify-fix.md") | Sort-Object)
            $branchKiloCommands | Should -Not -Contain "itl-new-config-branch.md"
            $branchKiloCommands | Should -Not -Contain "itl-new-extension-branch.md"
            $launcherText = Get-Content -Encoding UTF8 -Raw (Join-Path $env:APPDATA "1C\1CEStart\ibases.v8i")
            $launcherText | Should -Match ("(?m)^\[{0}\]\r?$" -f [regex]::Escape($expectedLauncherName))
            $launcherText | Should -Match ("(?m)^Folder={0}\r?$" -f [regex]::Escape($expectedLauncherFolder))
            $launcherText | Should -Not -Match "(?m)^Folder=/ITL/fixture-branch\r?$"

            $statusOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action status 2>&1
            $LASTEXITCODE | Should -Be 0
            $statusText = $statusOutput -join [Environment]::NewLine
            $statusText | Should -Match "Active development worktrees: 1"
            $statusText | Should -Match "ITL on-demand MCP facade: ready"
            $statusText | Should -Match "ITL on-demand MCP backend instances: 0"

            $listOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action list-dev-branches 2>&1
            $LASTEXITCODE | Should -Be 0
            $listText = $listOutput -join [Environment]::NewLine
            $listText | Should -Match ([regex]::Escape([System.IO.Path]::GetFullPath($worktreePath)))
            $listText | Should -Match "ROCTUP MCP: stopped"
            $listText | Should -Match "Vanessa UI MCP: stopped"

            $switchOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action switch-dev-branch -DevBranchName "Fixture Branch" 2>&1
            $LASTEXITCODE | Should -Be 0
            ($switchOutput -join [Environment]::NewLine) | Should -Match ([regex]::Escape([System.IO.Path]::GetFullPath($worktreePath)))
            ((& git -C $tempRoot branch --show-current).Trim()) | Should -Be "master"

            $duplicateResult = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @("-ProjectRoot", $tempRoot, "-Action", "new-dev-branch", "-DevBranchName", "Fixture Branch")
            $duplicateResult.exitCode | Should -Not -Be 0
            $duplicateResult.combinedText | Should -Match "Development branch already exists: itldev/fixture-branch"
        } finally {
            $env:APPDATA = $oldAppData
            $env:ITL_ONDEMAND_MCP_INSTALL_ROOT = $oldOnDemandInstallRoot
            if (Test-Path -LiteralPath $worktreePath -PathType Container -ErrorAction SilentlyContinue) {
                & git -C $tempRoot worktree remove --force $worktreePath *> $null
            }
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $legacyWorktreeRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $legacyWorktreeRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $facadeFixtureRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $facadeFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "resumes worktree branch initialization after the early protection resolution fails" {
        $tempRoot = New-ShortWorkflowProjectRoot
        $worktreeRoot = "$tempRoot-worktrees"
        $worktreePath = Join-Path $worktreeRoot "partial-branch"
        $sourceBase = Join-Path $tempRoot "source-base"
        $projectName = Split-Path -Leaf $tempRoot
        $oldAppData = $env:APPDATA

        try {
            New-Item -ItemType Directory -Force -Path $sourceBase | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8.1CD") -Value "stub" -Encoding ASCII
            New-Item -ItemType Directory -Force -Path (Join-Path $sourceBase "1Cv8Log") | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8Log\1Cv8.lgf") -Value "" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Value ".dev.env`nsource-base/`nappdata/`n.agent-1c/`n" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot "README.md") -Value "fixture" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Value '{"tools":["kilocode"],"files":{}}' -Encoding UTF8
            $templateTarget = Join-Path $tempRoot ".agents\skills\1c-workflow\kilo-command-templates"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $templateTarget) | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates") -Destination $templateTarget -Recurse
            $fakePlatform = Copy-AutoUpdateToolFixture -TargetRoot $tempRoot
            $devEnv = @(
                "PLATFORM_PATH=$fakePlatform",
                "INFOBASE_KIND=file",
                "SOURCE_USES_REPOSITORY=false",
                "SOURCE_INFOBASE_PATH=$sourceBase",
                "IB_USER=",
                "IB_PASSWORD=",
                "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=invalid",
                "WEB_PUBLISH_BY_DEFAULT=false",
                "ROCTUP_MCP_AUTO_START=false",
                "VANESSA_MCP_AUTO_START=false",
                "AGENT_TOOLS=kilocode"
            ) -join [Environment]::NewLine
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Value $devEnv -Encoding UTF8

            & git -C $tempRoot init | Out-Null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore README.md .ai-rules.json .agents
            & git -C $tempRoot commit -m init | Out-Null
            & git -C $tempRoot branch -M master

            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Value "{}" -Encoding ASCII

            New-TestBranchSeedFixture -ProjectRoot $tempRoot -SourceInfoBasePath $sourceBase
            $env:APPDATA = Join-Path $tempRoot "appdata"
            $firstResult = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @("-ProjectRoot", $tempRoot, "-Action", "new-dev-branch", "-DevBranchName", "Partial Branch", "-DevBranchWorktreePath", $worktreePath)
            $firstResult.exitCode | Should -Not -Be 0
            $firstResult.combinedText | Should -Match "Unsupported DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP value"

            $statePath = Join-Path $worktreePath ".agent-1c\dev-branches\partial-branch.json"
            (Test-Path -LiteralPath $statePath -PathType Leaf) | Should -Be $true
            $state = Get-Content -Encoding UTF8 -Raw $statePath | ConvertFrom-Json
            $state.initializationStatus | Should -Be "repository-unbound"
            $state.initializationError | Should -Match "Unsupported DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP value"
            $launcherPath = Join-Path $env:APPDATA "1C\1CEStart\ibases.v8i"
            (Test-Path -LiteralPath $launcherPath -PathType Leaf -ErrorAction SilentlyContinue) | Should -BeFalse

            $statusOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action status 2>&1
            $LASTEXITCODE | Should -Be 0
            $statusText = $statusOutput -join [Environment]::NewLine
            $statusText | Should -Match "Initialization status: repository-unbound"
            $statusText | Should -Match "Recovery: rerun new-dev-branch"

            $listOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action list-dev-branches 2>&1
            $LASTEXITCODE | Should -Be 0
            $listText = $listOutput -join [Environment]::NewLine
            $listText | Should -Match "Initialization status: repository-unbound"
            $listText | Should -Match ([regex]::Escape([System.IO.Path]::GetFullPath($worktreePath)))

            foreach ($envPath in @((Join-Path $tempRoot ".dev.env"), (Join-Path $worktreePath ".dev.env"))) {
                $fixedEnv = (Get-Content -Encoding UTF8 -Raw $envPath).Replace("DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=invalid", "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip")
                Set-Content -LiteralPath $envPath -Value $fixedEnv -Encoding UTF8
            }

            $resumeResult = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @("-ProjectRoot", $tempRoot, "-Action", "new-dev-branch", "-DevBranchName", "Partial Branch")
            $resumeResult.exitCode | Should -Be 0 -Because $resumeResult.combinedText
            $resumeResult.combinedText | Should -Match "Resuming development branch initialization: itldev/partial-branch"
            (Test-Path -LiteralPath "$tempRoot-partial-branch" -ErrorAction SilentlyContinue) | Should -Be $false

            $resumedState = Get-Content -Encoding UTF8 -Raw $statePath | ConvertFrom-Json
            $resumedState.initializationStatus | Should -Be "ready"
            $resumedState.initializationError | Should -Be ""
            $resumedState.unsafeActionProtectionSetupMode | Should -Be "skip"
            $resumedState.unsafeActionProtectionResolution | Should -Be "skip"
            $expectedLauncherName = "$projectName-partial-branch"
            $launcherTextAfter = Get-Content -Encoding UTF8 -Raw $launcherPath
            ([regex]::Matches($launcherTextAfter, ("(?m)^\[{0}\]\r?$" -f [regex]::Escape($expectedLauncherName)))).Count | Should -Be 1
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

    It "inherits complete vibecoding1c MCP selection into a sibling worktree" {
        $tempRoot = New-ShortWorkflowProjectRoot
        $legacyWorktreeRoot = "$tempRoot-worktrees"
        $worktreePath = "$tempRoot-mcp-branch"
        $sourceBase = Join-Path $tempRoot "source-base"
        $registryRoot = Join-Path $tempRoot "registry"
        $oldAppData = $env:APPDATA
        $oldRegistryPath = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", "Process")
        $oldLocalHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $sourceBase, $registryRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8.1CD") -Value "stub" -Encoding ASCII
            New-Item -ItemType Directory -Force -Path (Join-Path $sourceBase "1Cv8Log") | Out-Null
            Set-Content -LiteralPath (Join-Path $sourceBase "1Cv8Log\1Cv8.lgf") -Value "" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Value ".dev.env`nsource-base/`nregistry/`n.agent-1c/`n" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot "README.md") -Value "fixture" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Value '{"tools":["kilocode"],"files":{}}' -Encoding UTF8
            $templateTarget = Join-Path $tempRoot ".agents\skills\1c-workflow\kilo-command-templates"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $templateTarget) | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates") -Destination $templateTarget -Recurse
            $fakePlatform = Copy-AutoUpdateToolFixture -TargetRoot $tempRoot
            $devEnv = @(
                "PLATFORM_PATH=$fakePlatform",
                "INFOBASE_KIND=file",
                "SOURCE_USES_REPOSITORY=false",
                "SOURCE_INFOBASE_PATH=$sourceBase",
                "IB_USER=",
                "IB_PASSWORD=",
                "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip",
                "WEB_PUBLISH_BY_DEFAULT=false",
                "ROCTUP_MCP_AUTO_START=false",
                "VANESSA_MCP_AUTO_START=false",
                "AGENT_TOOLS=kilocode"
            ) -join [Environment]::NewLine
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Value $devEnv -Encoding UTF8

            $registry = [ordered]@{
                schemaVersion = 2
                publishedAt = "2026-07-05T00:10:00Z"
                hosts = @(
                    [ordered]@{
                        hostId = "host-a"
                        baseUrl = "http://host-a"
                        publishedAt = "2026-07-05T00:00:00Z"
                        configurations = @([ordered]@{ configId = "trade"; title = "Trade"; configurationName = "Trade"; configurationVersion = "1.0" })
                        servers = @(
                            [ordered]@{ id = "code"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-code"; url = "http://host-a:18100/mcp"; health = "running"; configurationName = "Trade"; configurationVersion = "1.0"; embeddingModel = "intfloat/multilingual-e5-base"; indexedAt = "2026-07-05T00:00:00Z" },
                            [ordered]@{ id = "graph"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-graph"; url = "http://host-a:18101/mcp"; health = "running"; configurationName = "Trade"; configurationVersion = "1.0"; embeddingModel = "intfloat/multilingual-e5-base"; indexedAt = "2026-07-05T00:00:00Z" }
                        )
                    }
                )
                configurations = @()
                servers = @()
            }
            Set-Content -LiteralPath (Join-Path $registryRoot "registry.json") -Encoding UTF8 -Value (($registry | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c\mcp") | Out-Null
            $selection = [ordered]@{
                schemaVersion = 1
                family = "vibecoding1c"
                defaultProvider = "remote"
                remoteConfigId = "trade"
                remoteHostId = "host-a"
                localScopeDefault = "project"
                servers = @(
                    [ordered]@{ id = "code"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; hostId = "host-a"; localScope = "project" },
                    [ordered]@{ id = "graph"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; hostId = "host-a"; localScope = "project" }
                )
            }
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\mcp\vibecoding1c-selection.json") -Encoding UTF8 -Value (($selection | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            & git -C $tempRoot init | Out-Null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore README.md .ai-rules.json .agents
            & git -C $tempRoot commit -m init | Out-Null
            & git -C $tempRoot branch -M master

            New-TestBranchSeedFixture -ProjectRoot $tempRoot -SourceInfoBasePath $sourceBase
            $env:APPDATA = Join-Path $tempRoot "appdata"
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $registryRoot, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", (Join-Path $tempRoot "local-home"), "Process")
            & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action new-dev-branch -DevBranchName "MCP Branch" -McpScope project *> $null
            $LASTEXITCODE | Should -Be 0

            $worktreeSelectionPath = Join-Path $worktreePath ".agent-1c\mcp\vibecoding1c-selection.json"
            (Test-Path -LiteralPath $worktreeSelectionPath -PathType Leaf) | Should -Be $true
            (Get-Content -Encoding UTF8 -Raw $worktreeSelectionPath) | Should -Match '"configId"\s*:\s*"trade"'

            $projectStatePath = Join-Path $worktreePath ".agent-1c\mcp\state.json"
            (Test-Path -LiteralPath $projectStatePath -PathType Leaf) | Should -Be $true
            $projectState = Get-Content -Encoding UTF8 -Raw $projectStatePath | ConvertFrom-Json
            $projectState.projectSlug | Should -Be (Split-Path -Leaf $worktreePath).ToLowerInvariant()
            $projectState.branchSlug | Should -Be "mcp-branch"
            (@($projectState.servers | Where-Object { $_.id -eq "code" }).Count) | Should -Be 1
            ($projectState.servers | Where-Object { $_.id -eq "code" } | Select-Object -First 1).url | Should -Be "http://host-a:18100/mcp"

            (Test-Path -LiteralPath (Join-Path $worktreePath ".codex\config.toml") -PathType Leaf -ErrorAction SilentlyContinue) | Should -BeFalse

            $kilo = Get-Content -Encoding UTF8 -Raw (Join-Path $worktreePath ".kilo\kilo.json") | ConvertFrom-Json
            $kilo.mcp.'1c-code-metadata-mcp'.url | Should -Be "http://host-a:18100/mcp"
            $kilo.mcp.'1c-graph-metadata-mcp'.url | Should -Be "http://host-a:18101/mcp"
            $managed = Get-Content -Encoding UTF8 -Raw (Join-Path $worktreePath ".agent-1c\mcp\client-managed.json") | ConvertFrom-Json
            @($managed.owners.'kilocode/vibecoding1c') | Should -Contain "1c-code-metadata-mcp"
        } finally {
            $env:APPDATA = $oldAppData
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $oldRegistryPath, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldLocalHome, "Process")
            if (Test-Path -LiteralPath $worktreePath -PathType Container -ErrorAction SilentlyContinue) {
                & git -C $tempRoot worktree remove --force $worktreePath *> $null
            }
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $legacyWorktreeRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $legacyWorktreeRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "warns and repairs missing BookStack MCP client config in a PM5 development worktree" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-worktree-bookstack-mcp-test-" + [guid]::NewGuid().ToString("N"))
        $mainRoot = Join-Path $tempRoot "main"
        $worktreePath = Join-Path $tempRoot "branch1"
        $registryRoot = Join-Path $tempRoot "registry"
        $codexHomeConfig = Join-Path $tempRoot "codex-home\config.toml"
        $oldRegistryPath = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", "Process")
        $oldLocalHome = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", "Process")
        $oldBookStackEnabled = [Environment]::GetEnvironmentVariable("VIBECODING1C_MCP_BOOKSTACK_ENABLED", "Process")
        $oldBaseVersion = [Environment]::GetEnvironmentVariable("BASE_CONFIGURATION_VERSION", "Process")

        try {
            New-Item -ItemType Directory -Force -Path $mainRoot, $registryRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $mainRoot ".gitignore") -Value ".agent-1c/mcp/`n.codex/config.toml`n.kilo/kilo.json`n" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $mainRoot "README.md") -Value "fixture" -Encoding ASCII
            & git -C $mainRoot init | Out-Null
            & git -C $mainRoot config user.email "test@example.com"
            & git -C $mainRoot config user.name "Test User"
            & git -C $mainRoot add .gitignore README.md
            & git -C $mainRoot commit -m init | Out-Null
            & git -C $mainRoot branch -M master
            & git -C $mainRoot worktree add -b itldev/branch1 $worktreePath | Out-Null

            New-Item -ItemType Directory -Force -Path (Join-Path $mainRoot ".agent-1c\mcp"), (Join-Path $worktreePath ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $worktreePath ".agent-1c\project.json") -Encoding UTF8 -Value (@{ schemaVersion = 1; baseConfigurationVersion = "PM5"; aiRules = @{ tools = @("kilocode") } } | ConvertTo-Json -Depth 5)
            Set-Content -LiteralPath (Join-Path $worktreePath ".ai-rules.json") -Encoding UTF8 -Value '{"schemaVersion":1,"tools":["kilocode"],"files":{}}'

            $registryServers = @(
                [ordered]@{ id = "docs"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-docs"; url = "http://host-a:18000/mcp"; health = "running" },
                [ordered]@{ id = "templates"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-templates"; url = "http://host-a:18001/mcp"; health = "running" },
                [ordered]@{ id = "syntax"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-syntax"; url = "http://host-a:18002/mcp"; health = "running" },
                [ordered]@{ id = "codechecker"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-codechecker"; url = "http://host-a:18003/mcp"; health = "running" },
                [ordered]@{ id = "ssl"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "itl-1c-ssl"; url = "http://host-a:18004/mcp"; health = "running" },
                [ordered]@{ id = "bookstack"; scope = "global"; family = "vibecoding1c"; provider = "remote"; name = "bookstack-product-docs"; url = "http://host-a:18005/mcp"; health = "running"; embeddingModel = "intfloat/multilingual-e5-base" },
                [ordered]@{ id = "code"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-code"; url = "http://host-a:18100/mcp"; health = "running"; configurationName = "Trade"; configurationVersion = "1.0"; embeddingModel = "intfloat/multilingual-e5-base"; indexedAt = "2026-07-05T00:00:00Z" },
                [ordered]@{ id = "graph"; scope = "project"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; name = "itl-trade-graph"; url = "http://host-a:18101/mcp"; health = "running"; configurationName = "Trade"; configurationVersion = "1.0"; embeddingModel = "intfloat/multilingual-e5-base"; indexedAt = "2026-07-05T00:00:00Z" }
            )
            $registry = [ordered]@{
                schemaVersion = 2
                publishedAt = "2026-07-05T00:10:00Z"
                hosts = @(
                    [ordered]@{
                        hostId = "host-a"
                        baseUrl = "http://host-a"
                        publishedAt = "2026-07-05T00:00:00Z"
                        configurations = @([ordered]@{ configId = "trade"; title = "Trade"; configurationName = "Trade"; configurationVersion = "1.0" })
                        servers = $registryServers
                    }
                )
                configurations = @()
                servers = @()
            }
            Set-Content -LiteralPath (Join-Path $registryRoot "registry.json") -Encoding UTF8 -Value (($registry | ConvertTo-Json -Depth 20) + [Environment]::NewLine)

            $selection = [ordered]@{
                schemaVersion = 1
                family = "vibecoding1c"
                defaultProvider = "remote"
                remoteConfigId = ""
                remoteHostId = ""
                localScopeDefault = "project"
                servers = @(
                    "docs",
                    "templates",
                    "syntax",
                    "codechecker",
                    "ssl",
                    "bookstack"
                ) | ForEach-Object {
                    [ordered]@{ id = $_; family = "vibecoding1c"; provider = "remote"; configId = ""; hostId = "host-a"; localScope = "project" }
                }
            }
            $selection.servers += [ordered]@{ id = "code"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; hostId = "host-a"; localScope = "project" }
            $selection.servers += [ordered]@{ id = "graph"; family = "vibecoding1c"; provider = "remote"; configId = "trade"; hostId = "host-a"; localScope = "project" }
            Set-Content -LiteralPath (Join-Path $mainRoot ".agent-1c\mcp\vibecoding1c-selection.json") -Encoding UTF8 -Value (($selection | ConvertTo-Json -Depth 10) + [Environment]::NewLine)

            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $registryRoot, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", (Join-Path $tempRoot "local-home"), "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_BOOKSTACK_ENABLED", "true", "Process")
            [Environment]::SetEnvironmentVariable("BASE_CONFIGURATION_VERSION", $null, "Process")

            $statusOutput = & {
                . $HelperPath -ProjectRoot $worktreePath -Action help *> $null
                $script:TestCodexHomeConfigPath = $codexHomeConfig
                function Get-Vibecoding1cMcpCodexHomeConfigPath {
                    return $script:TestCodexHomeConfigPath
                }
                Show-Vibecoding1cMcpStatus
            } *>&1
            $statusText = $statusOutput -join [Environment]::NewLine
            $statusText | Should -Match "WARNING: PM5 product documentation MCP is selected in the main worktree"
            $statusText | Should -Match "BookStack-product-docs-mcp"
            $statusText | Should -Match "vibecoding1c-mcp-setup"

            & {
                . $HelperPath -ProjectRoot $worktreePath -Action help *> $null
                $script:TestCodexHomeConfigPath = $codexHomeConfig
                function Get-Vibecoding1cMcpCodexHomeConfigPath {
                    return $script:TestCodexHomeConfigPath
                }
                Setup-Vibecoding1cMcp *> $null
            }

            (Test-Path -LiteralPath (Join-Path $worktreePath ".agent-1c\mcp\vibecoding1c-selection.json") -PathType Leaf) | Should -BeTrue
            $kilo = Get-Content -Encoding UTF8 -Raw (Join-Path $worktreePath ".kilo\kilo.json") | ConvertFrom-Json
            $kilo.mcp.'BookStack-product-docs-mcp'.url | Should -Be "http://host-a:18005/mcp"
            $managed = Get-Content -Encoding UTF8 -Raw (Join-Path $worktreePath ".agent-1c\mcp\client-managed.json") | ConvertFrom-Json
            @($managed.owners.'kilocode/vibecoding1c') | Should -Contain "BookStack-product-docs-mcp"
            (Test-Path -LiteralPath $codexHomeConfig -PathType Leaf -ErrorAction SilentlyContinue) | Should -BeFalse
        } finally {
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_REGISTRY_PATH", $oldRegistryPath, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_LOCAL_HOME", $oldLocalHome, "Process")
            [Environment]::SetEnvironmentVariable("VIBECODING1C_MCP_BOOKSTACK_ENABLED", $oldBookStackEnabled, "Process")
            [Environment]::SetEnvironmentVariable("BASE_CONFIGURATION_VERSION", $oldBaseVersion, "Process")
            if (Test-Path -LiteralPath $worktreePath -PathType Container -ErrorAction SilentlyContinue) {
                & git -C $mainRoot worktree remove --force $worktreePath *> $null
            }
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
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
            Set-Content -LiteralPath (Join-Path $tempRoot ".gitignore") -Value ".dev.env`nsource-base/`n.agent-1c/`n" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot "README.md") -Value "fixture" -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $tempRoot ".ai-rules.json") -Value '{"tools":["kilocode"],"files":{}}' -Encoding UTF8
            $templateTarget = Join-Path $tempRoot ".agents\skills\1c-workflow\kilo-command-templates"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $templateTarget) | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates") -Destination $templateTarget -Recurse
            $fakePlatform = Copy-AutoUpdateToolFixture -TargetRoot $tempRoot
            $devEnv = @(
                "PLATFORM_PATH=$fakePlatform",
                "INFOBASE_KIND=file",
                "SOURCE_USES_REPOSITORY=false",
                "SOURCE_INFOBASE_PATH=$sourceBase",
                "IB_USER=",
                "IB_PASSWORD=",
                "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip",
                "WEB_PUBLISH_BY_DEFAULT=false",
                "ROCTUP_MCP_AUTO_START=false",
                "VANESSA_MCP_AUTO_START=false",
                "AGENT_TOOLS=kilocode"
            ) -join [Environment]::NewLine
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Value $devEnv -Encoding UTF8

            & git -C $tempRoot init | Out-Null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore README.md .ai-rules.json .agents
            & git -C $tempRoot commit -m init | Out-Null
            & git -C $tempRoot branch -M master

            New-TestBranchSeedFixture -ProjectRoot $tempRoot -SourceInfoBasePath $sourceBase
            $env:APPDATA = Join-Path $tempRoot "appdata"
            & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action new-dev-branch -DevBranchName "Legacy Branch" -UseCurrentWorktree *> $null
            $LASTEXITCODE | Should -Be 0

            ((& git -C $tempRoot branch --show-current).Trim()) | Should -Be "itldev/legacy-branch"
            $legacyWorktreeRoot = Join-Path (Split-Path -Parent $tempRoot) ((Split-Path -Leaf $tempRoot) + "-worktrees")
            (Test-Path -LiteralPath $legacyWorktreeRoot -PathType Container -ErrorAction SilentlyContinue) | Should -Be $false
            $statePath = Join-Path $tempRoot ".agent-1c\dev-branches\legacy-branch.json"
            $state = Get-Content -Encoding UTF8 -Raw $statePath | ConvertFrom-Json
            $state.publicationStatus | Should -Be "disabled"
            $state.publicationMode | Should -Be "none"
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

    It "separates local dev commands from Kilo primary-checkout inheritance" {
        $mainRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-kilo-primary-" + [guid]::NewGuid().ToString("N"))
        $worktreeRoot = $mainRoot + "-worktree"
        try {
            New-Item -ItemType Directory -Force -Path $mainRoot, (Join-Path $mainRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $mainRoot ".gitignore") -Encoding ASCII -Value ".kilo/"
            Set-Content -LiteralPath (Join-Path $mainRoot ".agent-1c\project.json") -Encoding ASCII -Value '{"aiRules":{"tools":["kilocode"]}}'
            & git -C $mainRoot init | Out-Null
            & git -C $mainRoot config user.email "test@example.com"
            & git -C $mainRoot config user.name "Test User"
            & git -C $mainRoot add .gitignore .agent-1c/project.json
            & git -C $mainRoot commit -m init | Out-Null
            & git -C $mainRoot branch -M master
            & git -C $mainRoot worktree add -b itldev/branch1 $worktreeRoot | Out-Null

            New-Item -ItemType Directory -Force -Path (Join-Path $mainRoot ".kilo\commands"), (Join-Path $worktreeRoot ".kilo\commands") | Out-Null
            Set-Content -LiteralPath (Join-Path $mainRoot ".kilo\commands\itl.md") -Encoding ASCII -Value "common"
            Set-Content -LiteralPath (Join-Path $mainRoot ".kilo\commands\itl-update-workflow.md") -Encoding ASCII -Value "master"
            Set-Content -LiteralPath (Join-Path $worktreeRoot ".kilo\commands\itl.md") -Encoding ASCII -Value "common"
            Set-Content -LiteralPath (Join-Path $worktreeRoot ".kilo\commands\itl-check.md") -Encoding ASCII -Value "dev"

            $result = & {
                . $HelperPath -ProjectRoot $worktreeRoot -Action help *> $null
                @(Get-KiloInheritedPrimaryItlCommands)
            }
            $result | Should -BeNullOrEmpty

            $helpResult = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @(
                "-ProjectRoot", $worktreeRoot,
                "-Action", "help"
            )
            $helpResult.exitCode | Should -Be 0
            $helpResult.combinedText | Should -Match "Команды ITL в этом контексте"
            $helpResult.combinedText | Should -Match "/itl-update-workflow"
        } finally {
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                & git -C $mainRoot worktree remove --force --force $worktreeRoot *> $null
                & git -C $mainRoot worktree prune *> $null
            } finally {
                $ErrorActionPreference = $previousPreference
            }
            Remove-Item -LiteralPath $mainRoot -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $worktreeRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "restores only clean ignored ai_rules managed files from the main worktree" {
        $mainRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ai-ignored-main-" + [guid]::NewGuid().ToString("N"))
        $branchRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-ai-ignored-branch-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $mainRoot ".kilo\skills\runtime") | Out-Null
            & git -C $mainRoot init | Out-Null
            & git -C $mainRoot config user.email "test@example.com"
            & git -C $mainRoot config user.name "Test User"
            Set-Content -LiteralPath (Join-Path $mainRoot ".gitignore") -Encoding UTF8 -Value ".kilo/skills/runtime/package.json"
            $runtimePath = Join-Path $mainRoot ".kilo\skills\runtime\package.json"
            [IO.File]::WriteAllText($runtimePath, "{}`n", (New-Object Text.UTF8Encoding $false))
            $runtimeHash = (Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifest = [ordered]@{ version = "itl-main-410951e7-r24"; tools = @("kilocode"); files = [ordered]@{
                ".kilo/skills/runtime/package.json" = [ordered]@{ source = "runtime"; installedHash = $runtimeHash }
            } }
            Set-Content -LiteralPath (Join-Path $mainRoot ".ai-rules.json") -Encoding UTF8 -Value ($manifest | ConvertTo-Json -Depth 8)
            Set-Content -LiteralPath (Join-Path $mainRoot "README.md") -Encoding UTF8 -Value "fixture"
            & git -C $mainRoot add .gitignore .ai-rules.json README.md
            & git -C $mainRoot commit -m init | Out-Null
            & git -C $mainRoot branch -M master
            & git -C $mainRoot worktree add -b itldev/test $branchRoot master | Out-Null

            $result = & {
                . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                Sync-AiRules1cManagedIgnoredFilesFromMain -State ([pscustomobject]@{ mainWorktreePath = $mainRoot })
            }
            $result | Should -Be 1
            $branchRuntimePath = Join-Path $branchRoot ".kilo\skills\runtime\package.json"
            [IO.File]::ReadAllBytes($branchRuntimePath) | Should -Be ([IO.File]::ReadAllBytes($runtimePath))

            Remove-Item -LiteralPath $branchRuntimePath -Force
            [IO.File]::WriteAllText($runtimePath, "{`"changed`":true}`n", (New-Object Text.UTF8Encoding $false))
            {
                & {
                    . $HelperPath -ProjectRoot $branchRoot -Action help *> $null
                    Sync-AiRules1cManagedIgnoredFilesFromMain -State ([pscustomobject]@{ mainWorktreePath = $mainRoot })
                }
            } | Should -Throw "*AI_RULES_MANAGED_IGNORED_SOURCE_DRIFT*"
            Test-Path -LiteralPath $branchRuntimePath | Should -BeFalse
        } finally {
            $previousPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try { & git -C $mainRoot worktree remove --force $branchRoot *> $null } finally { $ErrorActionPreference = $previousPreference }
            Remove-Item -LiteralPath $branchRoot, $mainRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects every master-only action from itldev before changing tracked state" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-master-action-guard-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot "sentinel.txt") -Encoding ASCII -Value "unchanged"
            & git -C $tempRoot init | Out-Null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add sentinel.txt
            & git -C $tempRoot commit -m init | Out-Null
            & git -C $tempRoot branch -M master
            & git -C $tempRoot checkout -b itldev/current | Out-Null
            $beforeCommit = ((& git -C $tempRoot rev-parse HEAD) -join "").Trim()

            foreach ($case in @(
                @{ action = "update-workflow"; extra = @() },
                @{ action = "new-dev-branch"; extra = @("-DevBranchName", "other") },
                @{ action = "new-extension-dev-branch"; extra = @("-DevBranchName", "other-extension") }
            )) {
                $result = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments (@("-ProjectRoot", $tempRoot, "-Action", $case.action) + $case.extra)
                $result.exitCode | Should -Not -Be 0
                $result.combinedText | Should -Match "master"
                ((& git -C $tempRoot rev-parse HEAD) -join "").Trim() | Should -Be $beforeCommit
                @(& git -C $tempRoot status --porcelain) | Should -BeNullOrEmpty
                (Get-Content -LiteralPath (Join-Path $tempRoot "sentinel.txt") -Raw -Encoding ASCII).Trim() | Should -Be "unchanged"
            }
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
