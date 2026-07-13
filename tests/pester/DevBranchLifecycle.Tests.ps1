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

        function Copy-AutoUpdateToolFixture {
            param([string]$TargetRoot)
            $target = Join-Path $TargetRoot ".agents\skills\1c-workflow\tools\auto-update"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\tools\auto-update") -Destination $target -Recurse

            $fakePlatform = Join-Path $TargetRoot "source-base\test-platform\1cv8.cmd"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fakePlatform) | Out-Null
            Set-Content -LiteralPath $fakePlatform -Encoding ASCII -Value "@exit /b 0"
            return $fakePlatform
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

    It "keeps Enterprise normalization as the final resumable branch initialization step" {
        $initStart = $HelperText.IndexOf('function Initialize-DevBranchRuntime')
        $initBlock = $HelperText.Substring($initStart, $HelperText.IndexOf('function Get-ResumableDevBranchState', $initStart) - $initStart)
        $baselineIndex = $initBlock.IndexOf('Initialize-DevBranchEventLogBaseline')
        $pendingIndex = $initBlock.IndexOf('-Status "enterprise-normalization-pending"')
        $normalizeIndex = $initBlock.LastIndexOf('Ensure-DevBranchEnterpriseNormalized -State $state -Reason "branch-copy"')
        $readyIndex = $initBlock.IndexOf('-Status "ready"', $pendingIndex)
        $dataMcpIndex = $initBlock.IndexOf('Invoke-DevBranchDataMcpAfterPublication', $readyIndex)
        $baselineIndex | Should -BeGreaterThan -1
        $pendingIndex | Should -BeGreaterThan $baselineIndex
        $normalizeIndex | Should -BeGreaterThan $pendingIndex
        $readyIndex | Should -BeGreaterThan $normalizeIndex
        $dataMcpIndex | Should -BeGreaterThan $readyIndex
        $initBlock | Should -Match 'Resuming final Enterprise normalization for existing development branch copy'
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

    It "keeps root Configuration.xml in the exact partial load list" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null

            $script:CapturedDesignerArgs = @()
            function Get-ConfigLoadChangeSet {
                return [pscustomobject]@{
                    files = @("Configuration.xml")
                    baseCommit = "base"
                    currentCommit = "head"
                    absoluteExportPath = "C:\project\src\cf"
                }
            }
            function New-ConfigLoadListFile { return "C:\logs\changed-files.txt" }
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
        $result.args | Should -Contain "/UpdateDBCfg"
        $result.listFile | Should -Be "C:\logs\changed-files.txt"
    }

    It "keeps partial files load for non-root configuration changes" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null

            $script:CapturedDesignerArgs = @()
            function Get-ConfigLoadChangeSet {
                return [pscustomobject]@{
                    files = @("CommonModules\WorkflowE2E.xml")
                    baseCommit = "base"
                    currentCommit = "head"
                    absoluteExportPath = "C:\project\src\cf"
                }
            }
            function New-ConfigLoadListFile { return "C:\logs\changed-files.txt" }
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
        $result | Should -Contain "/UpdateDBCfg"
    }

    It "falls back once to full load only after a partial Designer failure" {
        $result = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:DesignerCalls = @()
            function Get-ConfigLoadChangeSet {
                [pscustomobject]@{ files = @("Configuration.xml", "CommonModules\Модуль.xml"); baseCommit = "base"; currentCommit = "head"; absoluteExportPath = "C:\project\src\cf" }
            }
            function New-ConfigLoadListFile { return "C:\logs\changed-files.txt" }
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
        $result.calls[1] | Should -Not -Contain "-listFile"
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
            function Get-ConfigLoadChangeSet {
                [pscustomobject]@{ files = @("Configuration.xml"); baseCommit = "base"; currentCommit = "head"; absoluteExportPath = "C:\project\src\cf" }
            }
            function New-ConfigLoadListFile { return "C:\logs\changed-files.txt" }
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
        $result.message | Should -Match "intermediate state"
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
        $full.load.loadModeUsed | Should -Be "full"
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
            function Get-ConfigLoadChangeSet { [pscustomobject]@{ files = @("Configuration.xml"); baseCommit = "base"; currentCommit = "head"; absoluteExportPath = "C:\src" } }
            function New-ConfigLoadListFile { throw "list must not be created" }
            function Invoke-Designer { param([string]$InfoBasePath, [string]$InfoBaseKind, [string[]]$DesignerArgs); $script:Calls++; $script:LastLogPath = "C:\logs\full.log" }
            $load = Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind file -State ([pscustomobject]@{}) -ExportPath "src/cf" -Mode Full 6>$null
            [pscustomobject]@{ calls = $script:Calls; listFile = $load.listFile; mode = $load.loadModeUsed }
        }
        $full.calls | Should -Be 1
        $full.listFile | Should -Be ""
        $full.mode | Should -Be "full"
    }

    It "does not invoke Designer or full fallback for no-op or list preparation errors" {
        $noOpCalls = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:DesignerCallCount = 0
            function Get-ConfigLoadChangeSet { [pscustomobject]@{ files = @(); baseCommit = "base"; currentCommit = "head"; absoluteExportPath = "C:\src" } }
            function Invoke-Designer { $script:DesignerCallCount++ }
            $load = Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind file -State ([pscustomobject]@{}) -ExportPath "src/cf" 6>$null
            [pscustomobject]@{ calls = $script:DesignerCallCount; loaded = $load.loaded }
        }
        $noOpCalls.calls | Should -Be 0
        $noOpCalls.loaded | Should -BeFalse

        $prep = & {
            . $HelperPath -ProjectRoot $RepoRoot -Action help *> $null
            $script:DesignerCallCount = 0
            function Get-ConfigLoadChangeSet { [pscustomobject]@{ files = @("Configuration.xml"); baseCommit = "base"; currentCommit = "head"; absoluteExportPath = "C:\src" } }
            function New-ConfigLoadListFile { throw "list preparation failed" }
            function Invoke-Designer { $script:DesignerCallCount++ }
            $message = ""
            try { Load-ConfigFromFiles -InfoBasePath "C:\base" -InfoBaseKind file -State ([pscustomobject]@{}) -ExportPath "src/cf" 6>$null | Out-Null } catch { $message = $_.Exception.Message }
            [pscustomobject]@{ calls = $script:DesignerCallCount; message = $message }
        }
        $prep.calls | Should -Be 0
        $prep.message | Should -Match "list preparation failed"
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
            $phaseRestartIndex = $body.IndexOf('Restart-Agent1cAfterDevBranchMerge -Operation')
            $loadIndex = $body.IndexOf('Load-ConfigFromFiles')

            $mergeIndex | Should -BeGreaterOrEqual 0
            $body | Should -Not -Match "Restart-Agent1cIfWorkflowHelperChangedSince"
            $phaseRestartIndex | Should -BeGreaterThan $mergeIndex
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
                Test-Path -LiteralPath $first.cachePath -PathType Leaf | Should -BeTrue

                $hit = Read-DevBranchEventLogBaselineWithCache -State $state
                $hit.cacheStatus | Should -Be "hit"
                $hit.signatureCount | Should -Be 1

                Add-Content -LiteralPath $segment1 -Encoding UTF8 -Value '{20260703101000,E,"_$PerformError$_","Catalog.Items","Item 2","Changed error"}'
                (Get-Item -LiteralPath $segment1).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddSeconds(2)
                $changed = Read-DevBranchEventLogBaselineWithCache -State $state
                $changed.cacheStatus | Should -Be "updated"
                $changed.errorCount | Should -Be 2
                $changed.signatureCount | Should -Be 2

                $segment2 = Join-Path $logDir "20260704.lgp"
                Set-Content -LiteralPath $segment2 -Encoding UTF8 -Value '{20260704100000,E,"_$PerformError$_","Catalog.Items","Item 3","Rotated error"}'
                $added = Read-DevBranchEventLogBaselineWithCache -State $state
                $added.cacheStatus | Should -Be "updated"
                $added.errorCount | Should -Be 3

                Remove-Item -LiteralPath $segment1 -Force
                $rotated = Read-DevBranchEventLogBaselineWithCache -State $state
                $rotated.cacheStatus | Should -Be "updated"
                $rotated.errorCount | Should -Be 1
                $rotated.signatureCount | Should -Be 1

                Set-Content -LiteralPath $rotated.cachePath -Encoding UTF8 -Value "{broken"
                $rebuilt = Read-DevBranchEventLogBaselineWithCache -State $state 6>$null
                $rebuilt.cacheStatus | Should -Be "rebuilt"
                $rebuilt.errorCount | Should -Be 1
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

    It "starts Vanessa verify TestManager without passing TPort on the TestManager command line" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-va-testmanager-args-" + [guid]::NewGuid().ToString("N"))

        try {
            New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
            $fakePlatform = Join-Path $tempRoot "1cv8.exe"
            Set-Content -LiteralPath $fakePlatform -Encoding ASCII -Value "fake"
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
                        [scriptblock]$OnTimeout = $null
                    )
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

                $script:LastNativeProcessArguments
            }

            $captured | Should -Contain "/TESTMANAGER"
            ($captured -join " ") | Should -Not -Match ([regex]::Escape("-TPort"))
        } finally {
            if (Test-Path -LiteralPath $tempRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
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

    It "leaves master clean after mocked initialization commits managed files" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-init-clean-" + [guid]::NewGuid().ToString("N"))
        $envNames = @(
            "INFOBASE_KIND",
            "SOURCE_USES_REPOSITORY",
            "SOURCE_INFOBASE_PATH",
            "IB_USER",
            "IB_PASSWORD",
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
            Copy-Item -LiteralPath (Join-Path $RepoRoot "templates") -Destination (Join-Path $tempRoot "templates") -Recurse
            $templateTarget = Join-Path $tempRoot ".agents\skills\1c-workflow\kilo-command-templates"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $templateTarget) | Out-Null
            Copy-Item -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates") -Destination $templateTarget -Recurse

            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null

                function Prepare-ConfiguredInitProjectSettings {
                    Ensure-WorkflowProjectFiles
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
                        VIBECODING1C_MCP_SETUP_DURING_INIT = "false"
                    }
                    Import-DotEnv -Path (Join-Path $script:ProjectRoot ".dev.env") -Overwrite
                    $script:InitVibecoding1cMcpSetupRequested = $false
                }

                function Check-Tools {
                    param([switch]$StopOnMissing)
                }

                function Install-RoctupMcp {
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

                function Install-AiRules1c {
                    Write-Utf8Text -Path (Join-Path $script:ProjectRoot ".ai-rules.json") -Value "{`"schemaVersion`":1,`"tools`":[`"kilocode`"],`"files`":{}}`n"
                    Write-Utf8Text -Path (Join-Path $script:ProjectRoot "AGENTS.md") -Value "Read USER-RULES.md for project-specific instructions.`n"
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
    }

    It "documents and templates the development branch worktree root" {
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\project.json")) | Should -Match "devBranchWorktreeRoot"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "DEV_BRANCH_WORKTREE_ROOT"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "README.md")) | Should -Match "worktree"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "DEVELOPER-GUIDE.ru.md")) | Should -Match "-UseCurrentWorktree"
    }

    It "declares manual unsafe action protection confirmation for development branches" {
        $HelperText | Should -Match "function Confirm-DevBranchUnsafeActionProtection"
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
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot "templates\dev.env.example")) | Should -Match "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=manual-confirm"
        (Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\references\branch-lifecycle.md")) | Should -Match "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP"
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

                Stop-OwnVanessaTestProcessesAndAssert -State $state 6>$null
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

    It "routes interactive branch creation through the monitored launcher" {
        $configBranchTemplate = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\master\itl-new-config-branch.md.template")
        $extensionBranchTemplate = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow\kilo-command-templates\master\itl-new-extension-branch.md.template")
        $fastSkill = Get-Content -Encoding UTF8 -Raw (Join-Path $RepoRoot ".agents\skills\1c-workflow-fast\SKILL.md")

        foreach ($text in @($configBranchTemplate, $extensionBranchTemplate, $fastSkill)) {
            $text | Should -Match "run-agent-1c-window\.ps1"
            $text | Should -Match "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip"
        }

        $configBranchTemplate | Should -Match ([regex]::Escape("run-agent-1c-window.ps1 -- -Action new-dev-branch"))
        $extensionBranchTemplate | Should -Match ([regex]::Escape("run-agent-1c-window.ps1 -- -Action new-extension-dev-branch"))
        $fastSkill | Should -Match ([regex]::Escape("run-agent-1c-window.ps1 -- -Action new-dev-branch"))
        $fastSkill | Should -Match ([regex]::Escape("run-agent-1c-window.ps1 -- -Action new-extension-dev-branch"))
    }

    It "keeps interactive Designer confirmation launch visible" {
        $match = [regex]::Match($HelperText, "(?s)function\s+Invoke-VisibleNativeProcessAndWait\s*\{(?<body>.*?)(?=`r?`nfunction\s+)")
        $match.Success | Should -Be $true
        $match.Groups["body"].Value | Should -Match "Start-Process"
        $match.Groups["body"].Value | Should -Not -Match "WindowStyle"
    }

    It "stops direct non-interactive manual unsafe action confirmation before creating a worktree" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-manual-confirm-test-" + [guid]::NewGuid().ToString("N"))
        $worktreeRoot = "$tempRoot-worktrees"
        $worktreePath = Join-Path $worktreeRoot "needs-confirmation"
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
            if (Test-Path -LiteralPath $worktreeRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $worktreeRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "creates a sibling worktree branch without starting branch MCP even when legacy auto-start is true" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-worktree-test-" + [guid]::NewGuid().ToString("N"))
        $worktreeRoot = "$tempRoot-worktrees"
        $worktreePath = Join-Path $worktreeRoot "fixture-branch"
        $sourceBase = Join-Path $tempRoot "source-base"
        $projectName = Split-Path -Leaf $tempRoot
        $oldAppData = $env:APPDATA

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
                "VANESSA_MCP_AUTO_START=true"
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
            $expectedLauncherName = "$projectName - Fixture Branch"
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
            $codexText = Get-Content -Encoding UTF8 -Raw (Join-Path $worktreePath ".codex\config.toml")
            $codexText | Should -Not -Match "itl-.*-roctup"
            $codexText | Should -Not -Match "VanessaAutomation-"
            $kiloText = Get-Content -Encoding UTF8 -Raw (Join-Path $worktreePath ".kilo\kilo.json")
            $kiloText | Should -Not -Match "itl-.*-roctup"
            $kiloText | Should -Not -Match "VanessaAutomation-"
            $branchKiloCommands = @(Get-ChildItem -LiteralPath (Join-Path $worktreePath ".kilo\commands") -File -Filter "itl*.md" | Select-Object -ExpandProperty Name | Sort-Object)
            $branchKiloCommands | Should -Be @("itl.md", "itl-check.md", "itl-refresh.md", "itl-result.md", "itl-status.md")
            $branchKiloCommands | Should -Not -Contain "itl-new-config-branch.md"
            $branchKiloCommands | Should -Not -Contain "itl-new-extension-branch.md"
            $branchKiloCommands | Should -Not -Contain "itl-update-workflow.md"
            $launcherText = Get-Content -Encoding UTF8 -Raw (Join-Path $env:APPDATA "1C\1CEStart\ibases.v8i")
            $launcherText | Should -Match ("(?m)^\[{0}\]\r?$" -f [regex]::Escape($expectedLauncherName))
            $launcherText | Should -Match ("(?m)^Folder={0}\r?$" -f [regex]::Escape($expectedLauncherFolder))
            $launcherText | Should -Not -Match "(?m)^Folder=/ITL/fixture-branch\r?$"

            $statusOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action status 2>&1
            $LASTEXITCODE | Should -Be 0
            $statusText = $statusOutput -join [Environment]::NewLine
            $statusText | Should -Match "Active development worktrees: 1"
            $statusText | Should -Match "ROCTUP MCP: stopped"
            $statusText | Should -Match "Vanessa UI MCP: stopped"

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

    It "resumes worktree branch initialization after launcher registration failure" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-worktree-resume-test-" + [guid]::NewGuid().ToString("N"))
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
                "VANESSA_MCP_AUTO_START=false"
            ) -join [Environment]::NewLine
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Value $devEnv -Encoding UTF8

            & git -C $tempRoot init | Out-Null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore README.md .agents
            & git -C $tempRoot commit -m init | Out-Null
            & git -C $tempRoot branch -M master

            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".kilo") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".kilo\kilo.json") -Value "{}" -Encoding ASCII

            $env:APPDATA = Join-Path $tempRoot "appdata"
            $firstResult = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @("-ProjectRoot", $tempRoot, "-Action", "new-dev-branch", "-DevBranchName", "Partial Branch")
            $firstResult.exitCode | Should -Not -Be 0
            $firstResult.combinedText | Should -Match "Unsupported DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP value"

            $statePath = Join-Path $worktreePath ".agent-1c\dev-branches\partial-branch.json"
            (Test-Path -LiteralPath $statePath -PathType Leaf) | Should -Be $true
            $state = Get-Content -Encoding UTF8 -Raw $statePath | ConvertFrom-Json
            $state.initializationStatus | Should -Be "launcher-registered"
            $state.initializationError | Should -Match "Unsupported DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP value"
            $expectedLauncherName = "$projectName - Partial Branch"
            $state.launcherInfoBaseName | Should -Be $expectedLauncherName

            $launcherPath = Join-Path $env:APPDATA "1C\1CEStart\ibases.v8i"
            $launcherText = Get-Content -Encoding UTF8 -Raw $launcherPath
            ([regex]::Matches($launcherText, ("(?m)^\[{0}\]\r?$" -f [regex]::Escape($expectedLauncherName)))).Count | Should -Be 1

            $statusOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action status 2>&1
            $LASTEXITCODE | Should -Be 0
            $statusText = $statusOutput -join [Environment]::NewLine
            $statusText | Should -Match "Initialization status: launcher-registered"
            $statusText | Should -Match "Recovery: rerun new-dev-branch"

            $listOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $tempRoot -Action list-dev-branches 2>&1
            $LASTEXITCODE | Should -Be 0
            $listText = $listOutput -join [Environment]::NewLine
            $listText | Should -Match "Initialization status: launcher-registered"
            $listText | Should -Match ([regex]::Escape([System.IO.Path]::GetFullPath($worktreePath)))

            foreach ($envPath in @((Join-Path $tempRoot ".dev.env"), (Join-Path $worktreePath ".dev.env"))) {
                $fixedEnv = (Get-Content -Encoding UTF8 -Raw $envPath).Replace("DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=invalid", "DEV_BRANCH_UNSAFE_ACTION_PROTECTION_SETUP=skip")
                Set-Content -LiteralPath $envPath -Value $fixedEnv -Encoding UTF8
            }

            $resumeResult = Invoke-TestPowerShellFile -FilePath $HelperPath -Arguments @("-ProjectRoot", $tempRoot, "-Action", "new-dev-branch", "-DevBranchName", "Partial Branch")
            $resumeResult.exitCode | Should -Be 0
            $resumeResult.combinedText | Should -Match "Resuming development branch initialization: itldev/partial-branch"

            $resumedState = Get-Content -Encoding UTF8 -Raw $statePath | ConvertFrom-Json
            $resumedState.initializationStatus | Should -Be "ready"
            $resumedState.initializationError | Should -Be ""
            $resumedState.unsafeActionProtectionSetupMode | Should -Be "skip"
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
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-worktree-mcp-test-" + [guid]::NewGuid().ToString("N"))
        $worktreeRoot = "$tempRoot-worktrees"
        $worktreePath = Join-Path $worktreeRoot "mcp-branch"
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
                "VANESSA_MCP_AUTO_START=false"
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
            & git -C $tempRoot add .gitignore README.md .agents
            & git -C $tempRoot commit -m init | Out-Null
            & git -C $tempRoot branch -M master

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
            $projectState.projectSlug | Should -Be "mcp-branch"
            $projectState.branchSlug | Should -Be "mcp-branch"
            (@($projectState.servers | Where-Object { $_.id -eq "code" }).Count) | Should -Be 1
            ($projectState.servers | Where-Object { $_.id -eq "code" } | Select-Object -First 1).url | Should -Be "http://host-a:18100/mcp"

            $codexText = Get-Content -Encoding UTF8 -Raw (Join-Path $worktreePath ".codex\config.toml")
            $codexText | Should -Match ([regex]::Escape("# >>> vibecoding1c-mcp project"))
            $codexText | Should -Match ([regex]::Escape('[mcp_servers."1c-code-metadata-mcp"]'))
            $codexText | Should -Match "http://host-a:18100/mcp"

            $kilo = Get-Content -Encoding UTF8 -Raw (Join-Path $worktreePath ".kilo\kilo.json") | ConvertFrom-Json
            $kilo.mcp.'1c-code-metadata-mcp'.managedBy | Should -Be "vibecoding1c-mcp"
            $kilo.mcp.'1c-code-metadata-mcp'.url | Should -Be "http://host-a:18100/mcp"
            $kilo.mcp.'1c-graph-metadata-mcp'.url | Should -Be "http://host-a:18101/mcp"
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
            if (Test-Path -LiteralPath $worktreeRoot -ErrorAction SilentlyContinue) {
                Remove-Item -LiteralPath $worktreeRoot -Recurse -Force -ErrorAction SilentlyContinue
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
            Set-Content -LiteralPath (Join-Path $worktreePath ".agent-1c\project.json") -Encoding UTF8 -Value (@{ schemaVersion = 1; baseConfigurationVersion = "PM5" } | ConvertTo-Json)

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
            $kilo.mcp.'BookStack-product-docs-mcp'.managedBy | Should -Be "vibecoding1c-mcp"
            $kilo.mcp.'BookStack-product-docs-mcp'.url | Should -Be "http://host-a:18005/mcp"
            (Get-Content -Encoding UTF8 -Raw $codexHomeConfig) | Should -Match ([regex]::Escape('[mcp_servers."BookStack-product-docs-mcp"]'))
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
                "VANESSA_MCP_AUTO_START=false"
            ) -join [Environment]::NewLine
            Set-Content -LiteralPath (Join-Path $tempRoot ".dev.env") -Value $devEnv -Encoding UTF8

            & git -C $tempRoot init | Out-Null
            & git -C $tempRoot config user.email "test@example.com"
            & git -C $tempRoot config user.name "Test User"
            & git -C $tempRoot add .gitignore README.md .agents
            & git -C $tempRoot commit -m init | Out-Null
            & git -C $tempRoot branch -M master

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
            New-Item -ItemType Directory -Force -Path $mainRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $mainRoot ".gitignore") -Encoding ASCII -Value ".kilo/"
            & git -C $mainRoot init | Out-Null
            & git -C $mainRoot config user.email "test@example.com"
            & git -C $mainRoot config user.name "Test User"
            & git -C $mainRoot add .gitignore
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
            $result | Should -Be @("/itl-update-workflow")

            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $HelperPath -ProjectRoot $worktreeRoot -Action help 2>&1
            ($output -join [Environment]::NewLine) | Should -Match "ITL commands valid in this context"
            ($output -join [Environment]::NewLine) | Should -Match "Inherited by Kilo from primary checkout; invalid in this context"
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
