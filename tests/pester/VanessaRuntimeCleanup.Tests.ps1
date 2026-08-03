$ErrorActionPreference = "Stop"

Describe "Branch-safe Vanessa runtime cleanup" {
    BeforeAll {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
        $HelperPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\agent-1c.ps1"
        $VanessaPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1"
        $LifecyclePath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.lifecycle.ps1"
    }

    It "releases only current-branch TestManager, TestClient, and Vanessa backend and is idempotent" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-runtime-release-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $currentBase = Join-Path $tempRoot "current-base"
                $foreignBase = "D:\foreign-worktree\base"
                $state = [pscustomobject]@{
                    devBranchInfoBasePath = $currentBase
                    worktreePath = $tempRoot
                    safeDevBranchName = "current"
                    vanessaTestPort = 48151
                }
                $script:StoppedIds = @()
                $script:Processes = @(
                    [pscustomobject]@{ processId = 1001; name = "1cv8c.exe"; commandLine = "1cv8c.exe /TESTMANAGER /F `"$currentBase`""; workingSetMb = 10 },
                    [pscustomobject]@{ processId = 1002; name = "1cv8c.exe"; commandLine = "1cv8c.exe /TESTCLIENT -TPort 48151 /F `"$currentBase`""; workingSetMb = 10 },
                    [pscustomobject]@{ processId = 2001; name = "1cv8c.exe"; commandLine = "1cv8c.exe /TESTCLIENT -TPort 48152 /F `"$foreignBase`""; workingSetMb = 10 }
                )
                $script:Runtimes = @(
                    [pscustomobject]@{ family = "vanessa-ui"; instanceId = ("a" * 32); infoBasePath = $currentBase; pid = 3001 },
                    [pscustomobject]@{ family = "vanessa-ui"; instanceId = ("b" * 32); infoBasePath = $foreignBase; pid = 3002 }
                )
                function Get-OneCProcessInfo {
                    @($script:Processes | Where-Object { $script:StoppedIds -notcontains [int]$_.processId })
                }
                function Stop-Process {
                    param([int]$Id, [switch]$Force, [object]$ErrorAction)
                    $script:StoppedIds += $Id
                }
                function Start-Sleep {}
                function Get-ItlOnDemandRuntimeInstances {
                    param([switch]$Strict)
                    @($script:Runtimes)
                }
                function Stop-ItlOnDemandBackendInstance {
                    param([string]$Family, [string]$InstanceId, [switch]$StrictOwnership)
                    $script:Runtimes = @($script:Runtimes | Where-Object { [string]$_.instanceId -ne $InstanceId })
                    [pscustomobject]@{ status = "stopped" }
                }
                function Get-VanessaMcpRuntimeInfo {
                    [pscustomobject]@{ processAlive = $false; pid = 0 }
                }

                $first = Invoke-DevBranchVanessaRuntimeRelease -State $state -Reason "test" 6>$null
                $second = Invoke-DevBranchVanessaRuntimeRelease -State $state -Reason "repeat" 6>$null
                [pscustomobject]@{
                    first = $first
                    second = $second
                    stoppedIds = @($script:StoppedIds)
                    remainingRuntimeIds = @($script:Runtimes | ForEach-Object { [string]$_.instanceId })
                }
            }

            $result.first.status | Should -Be "released"
            $result.first.stoppedTestManager | Should -Be 1
            $result.first.stoppedTestClient | Should -Be 1
            $result.first.stoppedVanessaUiBackend | Should -Be 1
            $result.second.status | Should -Be "released"
            $result.second.stoppedTestManager | Should -Be 0
            $result.second.stoppedTestClient | Should -Be 0
            $result.second.stoppedVanessaUiBackend | Should -Be 0
            $result.stoppedIds | Should -Contain 1001
            $result.stoppedIds | Should -Contain 1002
            $result.stoppedIds | Should -Not -Contain 2001
            $result.remainingRuntimeIds | Should -Be @(("b" * 32))
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "never stops a foreign worktree with the same safe branch name" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-cross-project-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $currentBase = Join-Path $tempRoot "True-worktrees\branch1\.agent-1c\infobases\dev-branches\branch1"
                $foreignBase = Join-Path $tempRoot "Perf-worktrees\branch1\.agent-1c\infobases\dev-branches\branch1"
                $currentBaseVariant = $currentBase.ToUpperInvariant().Replace('\', '/')
                $branch10Base = "${foreignBase}0"
                $state = [pscustomobject]@{
                    stateProjectRoot = Join-Path $tempRoot "True"
                    worktreePath = Join-Path $tempRoot "True-worktrees\branch1"
                    safeDevBranchName = "branch1"
                    devBranchInfoBasePath = $currentBase
                    vanessaTestPort = 48054
                }
                $script:StoppedIds = @()
                $script:Processes = @(
                    [pscustomobject]@{ processId = 1001; name = "1cv8c.exe"; commandLine = "1cv8c.exe /TESTMANAGER /F `"$currentBaseVariant`""; workingSetMb = 10 },
                    [pscustomobject]@{ processId = 1002; name = "1cv8c.exe"; commandLine = "1cv8c.exe /TESTCLIENT -TPort 48054 /F`"$currentBase`""; workingSetMb = 10 },
                    [pscustomobject]@{ processId = 1003; name = "1cv8c.exe"; commandLine = "1cv8c.exe /TESTCLIENT -TPort 48067 /F `"$currentBase`""; workingSetMb = 10 },
                    [pscustomobject]@{ processId = 2001; name = "1cv8c.exe"; commandLine = "1cv8c.exe /TESTMANAGER /F `"$foreignBase`" /CStartFeaturePlayer;VAParams=$foreignBase\params.json"; workingSetMb = 10 },
                    [pscustomobject]@{ processId = 2002; name = "1cv8c.exe"; commandLine = "1cv8c.exe /TESTCLIENT -TPort 48067 /F `"$foreignBase`""; workingSetMb = 10 },
                    [pscustomobject]@{ processId = 2010; name = "1cv8c.exe"; commandLine = "1cv8c.exe /TESTMANAGER /F `"$branch10Base`" /Cbranch1"; workingSetMb = 10 }
                )
                function Get-OneCProcessInfo {
                    @($script:Processes | Where-Object { $script:StoppedIds -notcontains [int]$_.processId })
                }
                function Stop-Process {
                    param([int]$Id, [switch]$Force, [object]$ErrorAction)
                    $script:StoppedIds += $Id
                }
                function Start-Sleep {}

                $ownedBefore = @(Get-OwnVanessaTestProcesses -State $state | ForEach-Object { [int]$_.processId })
                $branchNameOnly = [pscustomobject]@{ processId = 3001; commandLine = "1cv8c.exe /TESTMANAGER /Cbranch1" }
                $branchNameOwn = Test-OneCProcessBelongsToState -ProcessInfo $branchNameOnly -State $state
                $incompleteOwn = @(Get-OwnVanessaTestProcesses -State ([pscustomobject]@{ safeDevBranchName = "branch1" }))
                $incompleteCleanup = Stop-OwnVanessaTestProcesses -State ([pscustomobject]@{ safeDevBranchName = "branch1" })
                $stoppedAfterIncomplete = @($script:StoppedIds)
                $foreignState = [pscustomobject]@{
                    stateProjectRoot = Join-Path $tempRoot "Perf"
                    worktreePath = Join-Path $tempRoot "Perf-worktrees\branch1"
                    safeDevBranchName = "branch1"
                    devBranchInfoBasePath = $foreignBase
                }
                $sameNameStateIdentity = Test-VanessaStateIdentityMatch -First $state -Second $foreignState
                $sameBaseStateIdentity = Test-VanessaStateIdentityMatch -First $state -Second ([pscustomobject]@{ devBranchInfoBasePath = $currentBaseVariant })
                $sameTupleStateIdentity = Test-VanessaStateIdentityMatch -First $state -Second ([pscustomobject]@{
                    stateProjectRoot = $state.stateProjectRoot.ToUpperInvariant().Replace('\', '/')
                    worktreePath = $state.worktreePath.ToUpperInvariant().Replace('\', '/')
                    safeDevBranchName = "different-display-name"
                    devBranchInfoBasePath = $currentBaseVariant
                })
                $cleanup = Stop-OwnVanessaTestProcesses -State $state -BranchWide
                [pscustomobject]@{
                    ownedBefore = $ownedBefore
                    branchNameOwn = $branchNameOwn
                    incompleteCount = $incompleteOwn.Count
                    incompleteCleanup = $incompleteCleanup
                    stoppedAfterIncomplete = $stoppedAfterIncomplete
                    sameNameStateIdentity = $sameNameStateIdentity
                    sameBaseStateIdentity = $sameBaseStateIdentity
                    sameTupleStateIdentity = $sameTupleStateIdentity
                    stoppedIds = @($script:StoppedIds)
                    cleanup = $cleanup
                }
            }

            $result.ownedBefore | Should -Be @(1001, 1002)
            $result.branchNameOwn | Should -BeFalse
            $result.incompleteCount | Should -Be 0
            $result.incompleteCleanup.errors -join "`n" | Should -Match "ownership-unverified"
            $result.stoppedAfterIncomplete | Should -BeNullOrEmpty
            $result.sameNameStateIdentity | Should -BeFalse
            $result.sameBaseStateIdentity | Should -BeFalse
            $result.sameTupleStateIdentity | Should -BeTrue
            $result.stoppedIds | Should -Contain 1001
            $result.stoppedIds | Should -Contain 1002
            $result.stoppedIds | Should -Not -Contain 1003
            $result.stoppedIds | Should -Not -Contain 2001
            $result.stoppedIds | Should -Not -Contain 2002
            $result.stoppedIds | Should -Not -Contain 2010
            $result.cleanup.stoppedTestManager | Should -Be 1
            $result.cleanup.stoppedTestClient | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "fails closed and reports remaining runtime when backend ownership cannot be verified" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-runtime-foreign-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $base = Join-Path $tempRoot "base"
                $state = [pscustomobject]@{ devBranchInfoBasePath = $base; worktreePath = $tempRoot; safeDevBranchName = "current" }
                $script:ForeignBackendAlive = $true
                $runtime = [pscustomobject]@{ family = "vanessa-ui"; instanceId = ("c" * 32); infoBasePath = $base; pid = 4001 }
                function Get-OneCProcessInfo { @() }
                function Get-ItlOnDemandRuntimeInstances { param([switch]$Strict); @($runtime) }
                function Stop-ItlOnDemandBackendInstance {
                    throw "ITL_ONDEMAND_OWNERSHIP_MISMATCH: refusing foreign PID"
                }
                function Get-VanessaMcpRuntimeInfo { [pscustomobject]@{ processAlive = $false; pid = 0 } }
                $script:ReleaseMessage = ""
                $output = @(& {
                    try {
                        Invoke-DevBranchVanessaRuntimeRelease -State $state -Reason "partial" *>&1
                    } catch {
                        $script:ReleaseMessage = $_.Exception.Message
                    }
                })
                [pscustomobject]@{
                    message = $script:ReleaseMessage
                    output = ($output -join [Environment]::NewLine)
                    foreignBackendAlive = $script:ForeignBackendAlive
                }
            }

            $result.message | Should -Match "^ITL_VANESSA_RUNTIME_RELEASE_FAILED "
            $result.message | Should -Match "remaining=1"
            $result.message | Should -Match "ITL_ONDEMAND_OWNERSHIP_MISMATCH"
            $result.output | Should -Match "Vanessa runtime cleanup remaining owned runtime: 1"
            $result.foreignBackendAlive | Should -BeTrue
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "wires the single release primitive into the explicit stop and infobase lifecycle path" {
        $vanessaText = Get-Content -LiteralPath $VanessaPath -Raw -Encoding UTF8
        $lifecycleText = Get-Content -LiteralPath $LifecyclePath -Raw -Encoding UTF8

        $vanessaText | Should -Match 'function Invoke-DevBranchVanessaRuntimeRelease'
        $vanessaText | Should -Match 'function Stop-DevBranchTestClients[\s\S]*Invoke-DevBranchVanessaRuntimeRelease'
        $lifecycleText | Should -Match 'function Stop-DevBranchRuntimeBeforeInfobaseMutation[\s\S]*Invoke-DevBranchVanessaRuntimeRelease'
        $lifecycleText | Should -Match 'function Save-ReleaseE2EInfobaseSnapshot[\s\S]*Stop-DevBranchRuntimeBeforeInfobaseMutation'
        $lifecycleText | Should -Match 'function Close-DevBranch[\s\S]*Stop-DevBranchRuntimeBeforeInfobaseMutation'
    }

    It "delegates infobase release to the Vanessa primitive and drains ROCTUP separately" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-vanessa-runtime-lifecycle-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $base = Join-Path $tempRoot "base"
                $state = [pscustomobject]@{ devBranchInfoBasePath = $base }
                $script:VanessaCalls = 0
                $script:VanessaReason = ""
                $script:DrainedFamily = ""
                $script:DrainedBase = ""
                function Set-RunStage {}
                function Invoke-DevBranchVanessaRuntimeRelease {
                    param([object]$State, [string]$Reason)
                    $script:VanessaCalls++
                    $script:VanessaReason = $Reason
                    [pscustomobject]@{ status = "released" }
                }
                function Stop-ItlOnDemandBackends {
                    param([string]$Family, [string]$InfoBasePath, [switch]$Strict)
                    $script:DrainedFamily = $Family
                    $script:DrainedBase = $InfoBasePath
                }
                function Get-RoctupMcpRuntimeInfo { [pscustomobject]@{ processAlive = $false } }
                function Get-OwnVanessaTestProcesses { @() }
                function Get-ItlOnDemandRuntimeInstances { param([switch]$Strict); @() }

                Stop-DevBranchRuntimeBeforeInfobaseMutation -State $state -Reason "fixture mutation" 6>$null
                [pscustomobject]@{
                    vanessaCalls = $script:VanessaCalls
                    reason = $script:VanessaReason
                    family = $script:DrainedFamily
                    infoBasePath = $script:DrainedBase
                }
            }

            $result.vanessaCalls | Should -Be 1
            $result.reason | Should -Be "fixture mutation"
            $result.family | Should -Be "roctup"
            $result.infoBasePath | Should -Be (Join-Path $tempRoot "base")
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "parses only exact TPort and mcpPort arguments and never disables RequireTestPort" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-port-identity-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $base = Join-Path $tempRoot "База с пробелом 48051"
                $state = [pscustomobject]@{ devBranchInfoBasePath = $base }
                $line = "1cv8c.exe /TESTCLIENT -TPort 48052 /F `"$base`" /Out `"$tempRoot\logs\48051.log`" /CStartFeaturePlayer;VAParams=$tempRoot\runs\48051\VAParams.json"
                $mcpLine = "1cv8c.exe /TESTMANAGER /F `"$base`" /CrunMcp;mcpPort=48123;VAParams=$tempRoot\runs\48052\VAParams.json"
                [pscustomobject]@{
                    exactTestPort = Test-CommandLineContainsPort -CommandLine $line -Port 48052
                    falseNumericTestPort = Test-CommandLineContainsPort -CommandLine $line -Port 48051
                    exactMcpPort = Test-CommandLineContainsMcpPort -CommandLine $mcpLine -Port 48123
                    falseNumericMcpPort = Test-CommandLineContainsMcpPort -CommandLine $mcpLine -Port 48052
                    testParserRejectsMcp = Test-CommandLineContainsPort -CommandLine $mcpLine -Port 48123
                    mcpParserRejectsTest = Test-CommandLineContainsMcpPort -CommandLine $line -Port 48052
                    duplicateTestPort = Test-CommandLineContainsPort -CommandLine "$line -TPort 48052" -Port 48052
                    duplicateMcpPort = Test-CommandLineContainsMcpPort -CommandLine "$mcpLine;mcpPort=48123" -Port 48123
                    missingRequiredPort = Test-OneCProcessBelongsToState -ProcessInfo ([pscustomobject]@{ commandLine = $line }) -State $state -TestPort 0 -RequireTestPort
                }
            }

            $result.exactTestPort | Should -BeTrue
            $result.falseNumericTestPort | Should -BeFalse
            $result.exactMcpPort | Should -BeTrue
            $result.falseNumericMcpPort | Should -BeFalse
            $result.testParserRejectsMcp | Should -BeFalse
            $result.mcpParserRejectsTest | Should -BeFalse
            $result.duplicateTestPort | Should -BeFalse
            $result.duplicateMcpPort | Should -BeFalse
            $result.missingRequiredPort | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "owns real unquoted multi-profile TestClient command lines by infobase port and current-run Out path" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-va-run-scope-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $base = Join-Path $tempRoot "Кириллица worktree\База с пробелами"
                $foreignBase = Join-Path $tempRoot "Другой worktree\База с пробелами"
                $currentParams = Join-Path $tempRoot "runs\current run\VAParams.json"
                $otherParams = Join-Path $tempRoot "runs\other run\VAParams.json"
                $currentRun = Split-Path -Parent $currentParams
                $otherRun = Split-Path -Parent $otherParams
                $state = [pscustomobject]@{ devBranchInfoBasePath = $base; vanessaTestPort = 48054; vanessaTestPorts = @(48054, 48055) }
                $script:StoppedIds = @()
                $script:StickyIds = @()
                $script:Processes = @(
                    [pscustomobject]@{ processId = 1101; commandLine = "1cv8c.exe /TESTMANAGER /F `"$base`" `"/CStartFeaturePlayer;VAParams=$currentParams`"" },
                    [pscustomobject]@{ processId = 1102; commandLine = "1cv8c.exe /TESTCLIENT /F $base -TPort 48054 /N U3 /Out $currentRun\U3_20260803183906.txt" },
                    [pscustomobject]@{ processId = 1103; commandLine = "1cv8c.exe /TESTMANAGER /F `"$base`" `"/CStartFeaturePlayer;VAParams=$otherParams`"" },
                    [pscustomobject]@{ processId = 1104; commandLine = "1cv8c.exe /TESTCLIENT /F $base -TPort 48054 /N reused /Out $otherRun\foreign-current-port.txt" },
                    [pscustomobject]@{ processId = 1105; commandLine = "1cv8c.exe /TESTCLIENT /F $base -TPort 48055 /N M5 /Out $currentRun\НРС-M5_20260803185957.txt" },
                    [pscustomobject]@{ processId = 1106; commandLine = "1cv8c.exe /TESTCLIENT /F $foreignBase -TPort 48054 /N foreign /Out $currentRun\foreign-worktree.txt" },
                    [pscustomobject]@{ processId = 1107; commandLine = "1cv8c.exe /TESTCLIENT /F $base -TPort 48054 /N U3-again /Out $currentRun\U3_20260803183907.txt" }
                )
                function Get-OneCProcessInfo { param([switch]$RequireSuccess); @($script:Processes | Where-Object { $script:StoppedIds -notcontains $_.processId }) }
                function Stop-Process { param([int]$Id); if ($script:StickyIds -notcontains $Id) { $script:StoppedIds += $Id } }
                function Start-Sleep {}

                $diagnostics = Write-OneCVanessaProcessDiagnostics -State $state -TestPorts @(48054, 48055) -RunParamsPath $currentParams 6>&1
                Stop-OwnHungVanessaTestClients -State $state -TestPorts @(48054, 48055) -RunParamsPath $currentParams
                $afterHung = @($script:StoppedIds)
                $script:StoppedIds = @()
                $ordinary = Stop-OwnVanessaTestProcesses -State $state -TestPorts @(48054, 48055) -RunParamsPath $currentParams
                $afterOrdinary = @($script:StoppedIds)
                $script:StoppedIds = @()
                $script:StickyIds = @(1105)
                $incomplete = Stop-OwnVanessaTestProcesses -State $state -TestPorts @(48054, 48055) -RunParamsPath $currentParams
                $afterIncomplete = @($script:StoppedIds)
                $script:StoppedIds = @()
                $script:StickyIds = @()
                $branch = Stop-OwnVanessaTestProcesses -State $state -BranchWide
                [pscustomobject]@{
                    ordinary = $ordinary
                    incomplete = $incomplete
                    diagnostics = ($diagnostics | Out-String)
                    afterHung = $afterHung
                    afterOrdinary = $afterOrdinary
                    afterIncomplete = $afterIncomplete
                    afterBranch = @($script:StoppedIds)
                    branch = $branch
                }
            }

            $result.ordinary.errors | Should -BeNullOrEmpty
            $result.diagnostics | Should -Match '(?s)\[current-run\].*PID=1101'
            $result.diagnostics | Should -Match '(?s)\[current-run\].*PID=1102'
            $result.diagnostics | Should -Match '(?s)\[current-run\].*PID=1105'
            $result.diagnostics | Should -Match '(?s)\[current-run\].*PID=1107'
            $result.diagnostics | Should -Not -Match '\[current-run\].*PID=1103'
            $result.diagnostics | Should -Not -Match '\[current-run\].*PID=1104'
            $result.diagnostics | Should -Not -Match '\[current-run\].*PID=1106'
            $result.afterHung | Should -Contain 1101
            $result.afterHung | Should -Contain 1102
            $result.afterHung | Should -Contain 1105
            $result.afterHung | Should -Contain 1107
            $result.afterHung | Should -Not -Contain 1103
            $result.afterHung | Should -Not -Contain 1104
            $result.afterHung | Should -Not -Contain 1106
            $result.afterOrdinary | Should -Contain 1101
            $result.afterOrdinary | Should -Contain 1102
            $result.afterOrdinary | Should -Contain 1105
            $result.afterOrdinary | Should -Contain 1107
            $result.afterOrdinary | Should -Not -Contain 1103
            $result.afterOrdinary | Should -Not -Contain 1104
            $result.afterOrdinary | Should -Not -Contain 1106
            @($result.incomplete.remaining | ForEach-Object { [int]$_.processId }) | Should -Contain 1105
            $result.afterIncomplete | Should -Contain 1101
            $result.afterIncomplete | Should -Contain 1102
            $result.afterIncomplete | Should -Contain 1107
            $result.afterIncomplete | Should -Not -Contain 1104
            $result.afterIncomplete | Should -Not -Contain 1105
            $result.afterIncomplete | Should -Not -Contain 1106
            $result.afterBranch | Should -Contain 1103
            $result.afterBranch | Should -Contain 1104
            $result.afterBranch | Should -Not -Contain 1106
            $result.branch.errors | Should -BeNullOrEmpty

            $helperText = Get-Content -LiteralPath (Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.vanessa.ps1") -Raw -Encoding UTF8
            $runStart = $helperText.IndexOf("function Run-DevBranchTests")
            $runEnd = $helperText.IndexOf("function ConvertTo-IntOrDefault", $runStart)
            $runText = $helperText.Substring($runStart, ($runEnd - $runStart))
            @([regex]::Matches($runText, '(?:Stop-OwnHungVanessaTestClients|Write-OneCVanessaProcessDiagnostics|Stop-OwnVanessaTestProcessesAndAssert).*?-TestPorts \$testPorts')).Count | Should -Be 6
            $runText | Should -Not -Match '(?:Stop-OwnHungVanessaTestClients|Write-OneCVanessaProcessDiagnostics|Stop-OwnVanessaTestProcessesAndAssert).*?-TestPort \$testPort(?:\s|$)'
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "publishes and clears exact Vanessa run evidence in lifecycle and helper status" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-va-run-evidence-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $Action = "check-dev-branch"
                $RunStatusPath = Join-Path $tempRoot "run-status.json"
                $script:RunStartedAt = Get-Date
                $operationId = [guid]::NewGuid().ToString("N")
                $operationPath = Join-Path $tempRoot ".agent-1c\locks\lifecycle-operation.json"
                $paramsPath = Join-Path $tempRoot "build\test-results\vanessa\current\VAParams.json"
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $paramsPath) | Out-Null
                Set-Content -LiteralPath $paramsPath -Encoding UTF8 -Value '{}'
                $record = [ordered]@{
                    schemaVersion = 1
                    status = "running"
                    operationId = $operationId
                    action = $Action
                    projectRoot = $tempRoot
                    worktreePath = $tempRoot
                    lockScopes = @($tempRoot)
                    pid = $PID
                    continuationPid = 0
                    phase = "vanessa.prepare"
                    activeVanessaRun = $null
                }
                $script:LifecycleOperationRecord = $record
                $script:LifecycleOperationStatePath = $operationPath
                $script:LifecycleOperationId = $operationId
                $script:LifecycleOperationOwnerPid = $PID
                $script:LifecycleOperationIsContinuation = $false
                Write-Agent1cLifecycleOperationRecord -Path $operationPath -Record $record
                Publish-Agent1cVanessaRunEvidence `
                    -State ([pscustomobject]@{ devBranchInfoBasePath = (Join-Path $tempRoot ".agent-1c\infobases\branch1") }) `
                    -TestPorts @(48054, 48055) `
                    -RunParamsPath $paramsPath
                $publishedLifecycle = Read-Agent1cLifecycleOperationRecord -Path $operationPath
                $publishedStatus = Get-Content -LiteralPath $RunStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
                Clear-Agent1cVanessaRunEvidence
                [pscustomobject]@{
                    publishedLifecycle = $publishedLifecycle
                    publishedStatus = $publishedStatus
                    clearedLifecycle = Read-Agent1cLifecycleOperationRecord -Path $operationPath
                    clearedStatus = Get-Content -LiteralPath $RunStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
                }
            }

            $result.publishedLifecycle.activeVanessaRun.operationId | Should -Be $result.publishedLifecycle.operationId
            [int]$result.publishedLifecycle.activeVanessaRun.ownerPid | Should -BeGreaterThan 0
            [int]$result.publishedLifecycle.activeVanessaRun.processId | Should -BeGreaterThan 0
            $result.publishedLifecycle.activeVanessaRun.testPorts | Should -Be @(48054, 48055)
            $result.publishedStatus.activeVanessaRun.operationId | Should -Be $result.publishedLifecycle.operationId
            $result.publishedStatus.activeVanessaRun.runParamsPath | Should -Be (Join-Path $tempRoot "build\test-results\vanessa\current\VAParams.json")
            $result.clearedLifecycle.activeVanessaRun | Should -BeNullOrEmpty
            $result.clearedStatus.activeVanessaRun | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "fails closed when destructive process inspection is unavailable" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-va-inspection-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                function Get-CimInstance { throw "fixture CIM unavailable" }
                function Stop-Process { $script:UnexpectedStop = $true }
                $script:UnexpectedStop = $false
                $message = ""
                try {
                    Stop-OwnVanessaTestProcesses -State ([pscustomobject]@{ devBranchInfoBasePath = (Join-Path $tempRoot "base"); vanessaTestPort = 48054 }) -BranchWide | Out-Null
                } catch {
                    $message = $_.Exception.Message
                }
                [pscustomobject]@{ message = $message; unexpectedStop = $script:UnexpectedStop }
            }

            $result.message | Should -Match '^ITL_ONEC_PROCESS_INSPECTION_UNAVAILABLE:'
            $result.unexpectedStop | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "rejects legacy MCP PID reuse before destructive stop or lease release" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-va-legacy-pid-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $base = Join-Path $tempRoot "Кириллица base with spaces"
                $started = [datetime]"2026-08-03T08:00:00Z"
                $state = [pscustomobject]@{
                    devBranchInfoBasePath = $base
                    vanessaMcpPid = 44001
                    vanessaMcpPort = 48123
                    vanessaMcpProcessStartTime = $started.ToString("o")
                    vanessaMcpExecutablePath = "C:\Program Files\1cv8\1cv8c.exe"
                    vanessaMcpCommandLineIdentity = "runMcp;mcpPort=48123"
                    vanessaMcpInfoBasePath = $base
                }
                $reused = [pscustomobject]@{
                    processId = 44001
                    processStartTime = $started.AddMinutes(10).ToString("o")
                    executablePath = "C:\Program Files\1cv8\1cv8c.exe"
                    commandLine = "1cv8c.exe /TESTMANAGER /F `"$base`" /CrunMcp;mcpPort=48123"
                }
                function Get-VanessaMcpRuntimeInfo { [pscustomobject]@{ processAlive = $true; pid = 44001; port = 48123; portOpen = $true } }
                function Get-OneCProcessInfo { param([switch]$RequireSuccess); @($reused) }
                function Stop-Process { $script:UnexpectedStop = $true }
                function Set-ItlManagedPortAllocationStatus { $script:UnexpectedLeaseRelease = $true }
                function Update-DevBranchState { $script:UnexpectedStateUpdate = $true }
                $script:UnexpectedStop = $false
                $script:UnexpectedLeaseRelease = $false
                $script:UnexpectedStateUpdate = $false
                $message = ""
                try { Stop-VanessaMcpForState -State $state -Quiet | Out-Null } catch { $message = $_.Exception.Message }
                [pscustomobject]@{
                    message = $message
                    unexpectedStop = $script:UnexpectedStop
                    unexpectedLeaseRelease = $script:UnexpectedLeaseRelease
                    unexpectedStateUpdate = $script:UnexpectedStateUpdate
                }
            }

            $result.message | Should -Match '^ITL_LEGACY_MCP_OWNERSHIP_MISMATCH:'
            $result.unexpectedStop | Should -BeFalse
            $result.unexpectedLeaseRelease | Should -BeFalse
            $result.unexpectedStateUpdate | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "requires every legacy MCP ownership component and exact mcpPort" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-va-legacy-identity-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $base = Join-Path $tempRoot "База с пробелами"
                $started = [datetime]"2026-08-03T08:00:00Z"
                $state = [pscustomobject]@{
                    devBranchInfoBasePath = $base
                    vanessaMcpPid = 44001
                    vanessaMcpPort = 48123
                    vanessaMcpProcessStartTime = $started.ToString("o")
                    vanessaMcpExecutablePath = "C:\Program Files\1cv8\1cv8c.exe"
                    vanessaMcpCommandLineIdentity = "runMcp;mcpPort=48123"
                    vanessaMcpInfoBasePath = $base
                }
                $owned = [pscustomobject]@{
                    processId = 44001
                    processStartTime = $started.AddMilliseconds(500).ToString("o")
                    executablePath = "C:\Program Files\1cv8\1cv8c.exe"
                    commandLine = "1cv8c.exe /TESTMANAGER /F `"$base`" /CrunMcp;mcpPort=48123 /Out `"$tempRoot\48124.log`""
                }
                $wrongPort = $owned.PSObject.Copy()
                $wrongPort.commandLine = "1cv8c.exe /TESTMANAGER /F `"$base`" /CrunMcp;mcpPort=48124 /Out `"$tempRoot\48123.log`""
                $wrongExecutable = $owned.PSObject.Copy()
                $wrongExecutable.executablePath = "C:\Other\1cv8c.exe"
                [pscustomobject]@{
                    owned = Test-VanessaMcpProcessBelongsToState -ProcessInfo $owned -State $state
                    wrongPort = Test-VanessaMcpProcessBelongsToState -ProcessInfo $wrongPort -State $state
                    wrongExecutable = Test-VanessaMcpProcessBelongsToState -ProcessInfo $wrongExecutable -State $state
                }
            }

            $result.owned | Should -BeTrue
            $result.wrongPort | Should -BeFalse
            $result.wrongExecutable | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "releases legacy MCP state only after an owned stop and successful postcondition inspection" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-va-legacy-stop-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $base = Join-Path $tempRoot "База with spaces"
                $started = [datetime]"2026-08-03T08:00:00Z"
                $state = [pscustomobject]@{
                    devBranchName = "branch"
                    devBranchInfoBasePath = $base
                    vanessaMcpPid = 44001
                    vanessaMcpPort = 48123
                    vanessaMcpProcessStartTime = $started.ToString("o")
                    vanessaMcpExecutablePath = "C:\Program Files\1cv8\1cv8c.exe"
                    vanessaMcpCommandLineIdentity = "runMcp;mcpPort=48123"
                    vanessaMcpInfoBasePath = $base
                }
                $owned = [pscustomobject]@{
                    processId = 44001
                    processStartTime = $started.ToString("o")
                    executablePath = "C:\Program Files\1cv8\1cv8c.exe"
                    commandLine = "1cv8c.exe /TESTMANAGER /F `"$base`" /CrunMcp;mcpPort=48123"
                }
                $script:InspectionCount = 0
                function Get-VanessaMcpRuntimeInfo { [pscustomobject]@{ processAlive = $true; pid = 44001; port = 48123; portOpen = $true } }
                function Get-OneCProcessInfo {
                    param([switch]$RequireSuccess)
                    $script:InspectionCount++
                    if ($script:InspectionCount -eq 1) { @($owned) } else { @() }
                }
                function Stop-Process { param([int]$Id, [switch]$Force, [object]$ErrorAction); $script:StoppedId = $Id }
                function Start-Sleep { param([int]$Milliseconds) }
                function Get-Process { param([int]$Id, [object]$ErrorAction); return $null }
                function Test-TcpPortOpen { param([int]$Port); return $false }
                function Get-ItlBranchManagedPortKey { param([string]$Family, [object]$State); return "fixture-key" }
                function Set-ItlManagedPortAllocationStatus { param([string]$Family, [string]$Key, [string]$Status); $script:LeaseStatus = $Status }
                function Update-DevBranchState { param([object]$State, [hashtable]$Updates); $script:StateUpdates = $Updates }
                function Read-DevBranchState { param([string]$Name); return $state }
                $script:StoppedId = 0
                $script:LeaseStatus = ""
                $script:StateUpdates = $null

                $stopped = Stop-VanessaMcpForState -State $state -Quiet -SkipClientConfig
                [pscustomobject]@{
                    stopped = $stopped
                    stoppedId = $script:StoppedId
                    inspectionCount = $script:InspectionCount
                    leaseStatus = $script:LeaseStatus
                    stateUpdates = $script:StateUpdates
                }
            }

            $result.stopped | Should -BeTrue
            $result.stoppedId | Should -Be 44001
            $result.inspectionCount | Should -Be 2
            $result.leaseStatus | Should -Be "stopped"
            $result.stateUpdates.vanessaMcpPid | Should -Be ""
            $result.stateUpdates.vanessaMcpProcessStartTime | Should -Be ""
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "preserves the legacy MCP lease when post-stop inspection becomes unavailable" {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-va-legacy-postcondition-" + [guid]::NewGuid().ToString("N"))
        try {
            New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot ".agent-1c") | Out-Null
            Set-Content -LiteralPath (Join-Path $tempRoot ".agent-1c\project.json") -Encoding UTF8 -Value '{"aiRules":{"tools":["codex"]}}'
            $result = & {
                . $HelperPath -ProjectRoot $tempRoot -Action help *> $null
                $base = Join-Path $tempRoot "base"
                $started = [datetime]"2026-08-03T08:00:00Z"
                $state = [pscustomobject]@{
                    devBranchInfoBasePath = $base; vanessaMcpPid = 44001; vanessaMcpPort = 48123
                    vanessaMcpProcessStartTime = $started.ToString("o"); vanessaMcpExecutablePath = "C:\1cv8c.exe"
                    vanessaMcpCommandLineIdentity = "runMcp;mcpPort=48123"; vanessaMcpInfoBasePath = $base
                }
                $owned = [pscustomobject]@{
                    processId = 44001; processStartTime = $started.ToString("o"); executablePath = "C:\1cv8c.exe"
                    commandLine = "1cv8c.exe /TESTMANAGER /F `"$base`" /CrunMcp;mcpPort=48123"
                }
                $script:InspectionCount = 0
                function Get-VanessaMcpRuntimeInfo { [pscustomobject]@{ processAlive = $true; pid = 44001; port = 48123; portOpen = $true } }
                function Get-OneCProcessInfo {
                    param([switch]$RequireSuccess)
                    $script:InspectionCount++
                    if ($script:InspectionCount -eq 1) { return @($owned) }
                    throw "ITL_ONEC_PROCESS_INSPECTION_UNAVAILABLE: fixture postcondition"
                }
                function Stop-Process { param([int]$Id, [switch]$Force, [object]$ErrorAction); $script:Stopped = $true }
                function Start-Sleep { param([int]$Milliseconds) }
                function Get-Process { param([int]$Id, [object]$ErrorAction); return $null }
                function Test-TcpPortOpen { param([int]$Port); return $false }
                function Set-ItlManagedPortAllocationStatus { $script:UnexpectedLeaseRelease = $true }
                function Update-DevBranchState { $script:UnexpectedStateUpdate = $true }
                $script:Stopped = $false
                $script:UnexpectedLeaseRelease = $false
                $script:UnexpectedStateUpdate = $false
                $message = ""
                try { Stop-VanessaMcpForState -State $state -Quiet -SkipClientConfig | Out-Null } catch { $message = $_.Exception.Message }
                [pscustomobject]@{
                    message = $message; stopped = $script:Stopped
                    unexpectedLeaseRelease = $script:UnexpectedLeaseRelease; unexpectedStateUpdate = $script:UnexpectedStateUpdate
                }
            }

            $result.message | Should -Match '^ITL_ONEC_PROCESS_INSPECTION_UNAVAILABLE:'
            $result.stopped | Should -BeTrue
            $result.unexpectedLeaseRelease | Should -BeFalse
            $result.unexpectedStateUpdate | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "keeps ordinary lifecycle runs serialized and legacy stop ownership mandatory" {
        $corePath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.core.ps1"
        $roctupPath = Join-Path $RepoRoot ".agents\skills\1c-workflow\scripts\lib\agent-1c.roctup-mcp.ps1"
        $coreText = Get-Content -LiteralPath $corePath -Raw -Encoding UTF8
        $vanessaText = Get-Content -LiteralPath $VanessaPath -Raw -Encoding UTF8
        $roctupText = Get-Content -LiteralPath $roctupPath -Raw -Encoding UTF8
        $lockFunction = [regex]::Match($coreText, 'function Test-Agent1cActionRequiresLifecycleLock[\s\S]*?^}', [Text.RegularExpressions.RegexOptions]::Multiline).Value
        $stopFunction = [regex]::Match($vanessaText, 'function Stop-VanessaMcpForState[\s\S]*?^}', [Text.RegularExpressions.RegexOptions]::Multiline).Value
        $startFunction = [regex]::Match($vanessaText, 'function Start-VanessaMcp[\s\S]*?^}', [Text.RegularExpressions.RegexOptions]::Multiline).Value

        $lockFunction | Should -Not -Match '"run-dev-branch-tests"'
        $lockFunction | Should -Not -Match '"check-dev-branch"'
        $lockFunction | Should -Not -Match '"verify-dev-branch"'
        $stopFunction | Should -Not -Match 'RequireOwnership'
        $stopFunction | Should -Match 'Test-VanessaMcpProcessBelongsToState'
        foreach ($field in @('vanessaMcpProcessStartTime', 'vanessaMcpExecutablePath', 'vanessaMcpCommandLineIdentity', 'vanessaMcpInfoBasePath')) {
            $startFunction | Should -Match $field
        }
        $roctupText | Should -Match 'Test-CommandLineContainsMcpPort'
    }
}
