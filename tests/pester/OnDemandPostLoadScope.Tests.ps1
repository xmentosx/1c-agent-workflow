Describe 'On-demand cleanup scope after configuration load' {
    BeforeAll {
        $repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        $lib = Join-Path $repo '.agents/skills/1c-workflow/scripts/lib'
        foreach ($name in @('core','runtime-values','lifecycle','roctup-mcp','ondemand-mcp')) {
            . (Join-Path $lib ("agent-1c.$name.ps1"))
        }
    }
    BeforeEach {
        $script:ProjectRoot = Join-Path $TestDrive 'Проект с общей базой'
        $script:postLoadState = [pscustomobject]@{devBranchName='scope';infoBaseKind='file';devBranchInfoBasePath=(Join-Path $script:ProjectRoot 'Обновленная база')}
        $script:postLoadRuntimes = @()
        $script:stoppedPostLoad = @()
        Mock Read-DevBranchState { $script:postLoadState }
        Mock Get-ItlOnDemandRuntimeInstances { $script:postLoadRuntimes }
        Mock Write-ItlBranchMcpClientConfig { }
        Mock Stop-ItlOnDemandBackendInstance {
            param($Family,$InstanceId,[switch]$StrictOwnership)
            $StrictOwnership | Should -BeTrue
            $script:stoppedPostLoad += $InstanceId
            $script:postLoadRuntimes = @($script:postLoadRuntimes | Where-Object { $_.instanceId -ne $InstanceId })
            [pscustomobject]@{status='stopped'}
        }
    }

    It 'stops only the loaded <Kind> base and preserves auxiliary runtime in the same branch' -TestCases @(
        @{Kind='file'}, @{Kind='server'}
    ) {
        param($Kind)
        if ($Kind -eq 'server') {
            $script:postLoadState.infoBaseKind='server'
            $script:postLoadState.devBranchInfoBasePath='Srvr="ufa-host";Ref="PM5 main";'
        }
        $foreign = $(if ($Kind -eq 'server') { 'Srvr="ufa-host";Ref="PM5 auxiliary";' } else { Join-Path $script:ProjectRoot 'Вспомогательная база' })
        $script:postLoadRuntimes = @(
            [pscustomobject]@{family='roctup';instanceId='loaded-data';infoBasePath=$script:postLoadState.devBranchInfoBasePath},
            [pscustomobject]@{family='vanessa-ui';instanceId='loaded-ui';infoBasePath=$script:postLoadState.devBranchInfoBasePath},
            [pscustomobject]@{family='roctup';instanceId='auxiliary-data';infoBasePath=$foreign},
            [pscustomobject]@{family='vanessa-ui';instanceId='auxiliary-ui';infoBasePath=$foreign}
        )
        Invoke-DevBranchMcpRestartAfterInfobaseLoad -State $script:postLoadState -LoadResult ([pscustomobject]@{loaded=$true;infoBaseKind=$Kind;infoBasePath=$script:postLoadState.devBranchInfoBasePath}) | Out-Null
        $script:stoppedPostLoad.Count | Should -Be 2
        $script:stoppedPostLoad | Should -Contain 'loaded-data'
        $script:stoppedPostLoad | Should -Contain 'loaded-ui'
        @($script:postLoadRuntimes.instanceId) | Should -Contain 'auxiliary-data'
        @($script:postLoadRuntimes.instanceId) | Should -Contain 'auxiliary-ui'
        Should -Invoke Write-ItlBranchMcpClientConfig -Times 1
    }

    It 'does not turn a missing loaded target into stop-all' {
        $unknown = [pscustomobject]@{devBranchName='scope';infoBaseKind='file'}
        { Invoke-DevBranchMcpRestartAfterInfobaseLoad -State $unknown -LoadResult ([pscustomobject]@{loaded=$true}) } | Should -Throw '*LOAD_TARGET_REQUIRED*'
        Should -Invoke Stop-ItlOnDemandBackendInstance -Times 0
        Should -Invoke Write-ItlBranchMcpClientConfig -Times 0
    }

    It 'rejects changed target before stopping any runtime' {
        $loaded = [pscustomobject]@{devBranchName='scope';infoBaseKind='file';devBranchInfoBasePath=(Join-Path $script:ProjectRoot 'Прежняя база')}
        { Invoke-DevBranchMcpRestartAfterInfobaseLoad -State $script:postLoadState -LoadResult ([pscustomobject]@{loaded=$true;infoBaseKind=$loaded.infoBaseKind;infoBasePath=$loaded.devBranchInfoBasePath}) } | Should -Throw '*LOAD_TARGET_CHANGED*'
        Should -Invoke Stop-ItlOnDemandBackendInstance -Times 0
        Should -Invoke Write-ItlBranchMcpClientConfig -Times 0
    }

    It 'does not stop runtime when the load was skipped' {
        Invoke-DevBranchMcpRestartAfterInfobaseLoad -State $script:postLoadState -LoadResult ([pscustomobject]@{loaded=$false}) | Out-Null
        Should -Invoke Stop-ItlOnDemandBackendInstance -Times 0
        Should -Invoke Write-ItlBranchMcpClientConfig -Times 0
    }
}
