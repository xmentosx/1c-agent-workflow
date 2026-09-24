BeforeAll {
    $script:AdmissionFixturePythonOverride = $env:ITL_PYTHON_EXECUTABLE
    if (-not $env:ITL_PYTHON_EXECUTABLE) { $env:ITL_PYTHON_EXECUTABLE = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source }
}
AfterAll { $env:ITL_PYTHON_EXECUTABLE = $script:AdmissionFixturePythonOverride }
Describe 'Portable remote execution and performance' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }
    It 'executes local exchange SSH and both agent protocol regressions' {
        $result = Invoke-TestPowerShellFile -FilePath (Join-Path $repo 'tests/python/remote_work/run-tests.ps1')
        $result.exitCode | Should -Be 0 -Because $result.combinedText
    }
    It 'parses every portable PowerShell entrypoint' {
        $files = Get-ChildItem -LiteralPath (Join-Path $repo '.agents/skills/itl-remote-runner/scripts') -Filter '*.ps1'
        foreach ($file in $files) {
            $tokens=$null; $errors=$null
            [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors) | Out-Null
            @($errors).Count | Should -Be 0 -Because $file.Name
        }
    }
}



Describe 'Read-only target source capture boundary' {
    BeforeAll {
        $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . (Join-Path $repo '.agents/skills/1c-workflow/scripts/lib/agent-1c.runtime-values.ps1')
        . (Join-Path $repo '.agents/skills/itl-remote-runner/scripts/SourceCapture.ps1')
    }
    BeforeEach {
        $run = Join-Path $TestDrive ('Измерение базы ' + [guid]::NewGuid().ToString('N'))
        $snapshotId = [guid]::NewGuid().ToString('N')
        $root = Join-Path $run ('source-snapshots\' + $snapshotId)
        $platform = Join-Path $run 'Платформа 1С\1cv8.exe'
        New-Item -ItemType Directory -Force -Path $root, (Split-Path -Parent $platform) | Out-Null
        Set-Content -LiteralPath $platform -Value 'fixture executable; never launched'
        $context = [pscustomobject]@{jobId='job'; operations=@('measure'); accessLease=[pscustomobject]@{ticket='owned'};
            target=[pscustomobject]@{platform=$platform; sourceCapture=[pscustomobject]@{};
                infoBase=[pscustomobject]@{kind='server'; path='server\Измеряемая база'}}}
    }
    It 'reads only the executing database configuration without requiring update permission' {
        foreach ($op in @('dump-database','dump-extension','list-extensions')) {
            $spec=[pscustomobject]@{snapshotId=$snapshotId; operation=$op; extension=$(if ($op -eq 'dump-extension') {'Расширение_Замера'} else {''})}
            $step=Get-ItlSourceCaptureStep -Context $context -RunRoot $run -Spec $spec
            $step.base.path | Should -Be 'server\Измеряемая база'
            $step.arguments | Should -Contain '/S'
            $step.arguments | Should -Not -Contain '/LoadCfg'
            $step.arguments | Should -Not -Contain '/UpdateDBCfg'
            $step.arguments | Should -Not -Contain '/RollbackCfg'
            $step.arguments | Should -Contain $(if ($op -eq 'list-extensions') {'/DumpDBCfgList'} else {'/DumpDBCfg'})
        }
    }
    It 'loads and extracts only in the owned scratch database using Cyrillic and space paths' {
        $private=Join-Path $root 'private'
        New-Item -ItemType Directory -Force -Path $private | Out-Null
        $scratch=Join-Path $private 'scratch'
        [pscustomobject]@{snapshotId=$snapshotId;jobId='job';path=$scratch} | ConvertTo-Json | Set-Content (Join-Path $private 'scratch-owner.json') -Encoding UTF8
        Set-Content (Join-Path $root 'database.cf') 'captured bytes'
        foreach($op in @('load-snapshot','dump-sources')) {
            $step=Get-ItlSourceCaptureStep -Context $context -RunRoot $run -Spec ([pscustomobject]@{snapshotId=$snapshotId;operation=$op})
            $step.base.kind | Should -Be 'file'
            $step.base.path | Should -Be $scratch
            $step.arguments | Should -Not -Contain $context.target.infoBase.path
            $step.arguments | Should -Contain '/F'
        }
    }
    It 'does not reuse or overwrite a scratch database or captured artifact' {
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'private\scratch') | Out-Null
        { Get-ItlSourceCaptureStep -Context $context -RunRoot $run -Spec ([pscustomobject]@{snapshotId=$snapshotId;operation='create-scratch'}) } | Should -Throw '*SOURCE_CAPTURE_SCRATCH_ALREADY_EXISTS*'
        Set-Content (Join-Path $root 'database.cf') 'existing'
        { Get-ItlSourceCaptureStep -Context $context -RunRoot $run -Spec ([pscustomobject]@{snapshotId=$snapshotId;operation='dump-database'}) } | Should -Throw '*SOURCE_CAPTURE_ARTIFACT_ALREADY_EXISTS*'
    }
    It 'rejects scope expansion and unowned scratch loading' {
        foreach ($op in @('update','rollback','restore','/LoadCfg')) {
            { Get-ItlSourceCaptureStep -Context $context -RunRoot $run -Spec ([pscustomobject]@{snapshotId=$snapshotId;operation=$op}) } | Should -Throw '*SOURCE_CAPTURE_OPERATION_INVALID*'
        }
        Set-Content (Join-Path $root 'database.cf') 'captured bytes'
        { Get-ItlSourceCaptureStep -Context $context -RunRoot $run -Spec ([pscustomobject]@{snapshotId=$snapshotId;operation='load-snapshot'}) } | Should -Throw '*SOURCE_CAPTURE_SCRATCH_OWNER_MISSING*'
        { Get-ItlSourceCaptureStep -Context $context -RunRoot $run -Spec ([pscustomobject]@{snapshotId='..';operation='dump-database'}) } | Should -Throw '*SOURCE_CAPTURE_ID_INVALID*'
    }
    It 'requires inherited access and refuses an extension name used as an argument' {
        { Get-ItlSourceCaptureStep -Context $context -RunRoot $run -Spec ([pscustomobject]@{snapshotId=$snapshotId;operation='dump-extension';extension='/UpdateDBCfg'}) } | Should -Throw '*SOURCE_CAPTURE_EXTENSION_NAME_INVALID*'
        $context.accessLease=$null
        { Get-ItlSourceCaptureStep -Context $context -RunRoot $run -Spec ([pscustomobject]@{snapshotId=$snapshotId;operation='dump-database'}) } | Should -Throw '*SOURCE_CAPTURE_ACCESS_LEASE_REQUIRED*'
    }
    It 'cannot create its configured measurement target through the scratch route' {
        $context.target.infoBase=[pscustomobject]@{kind='file';path=(Join-Path $root 'private\scratch')}
        { Get-ItlSourceCaptureStep -Context $context -RunRoot $run -Spec ([pscustomobject]@{snapshotId=$snapshotId;operation='create-scratch'}) } | Should -Throw '*SOURCE_CAPTURE_SCRATCH_OVERLAPS_TARGET*'
    }
}

Describe 'Remote Vanessa manager completion' {
    BeforeAll {
        $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . (Join-Path $repo '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')
        . (Join-Path $repo '.agents/skills/itl-remote-runner/scripts/VanessaFeatureResult.ps1')
    }
    BeforeEach {
        $iteration = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + ' Сценарий')
        New-Item -ItemType Directory -Path $iteration | Out-Null
        $feature = Join-Path $iteration 'Проверка.feature'
        [IO.File]::WriteAllText($feature, 'Feature: test', [Text.UTF8Encoding]::new($false))
        $launch = [pscustomobject]@{
            jobId = 'fixture-job'
            pid = 1234
            startedAt = [DateTime]::UtcNow.AddSeconds(-10).ToString('o')
            exitedAt = [DateTime]::UtcNow.ToString('o')
            exitCodeState = 'unavailable'
            exitCode = $null
            infoBase = [pscustomobject]@{ kind='file'; path=(Join-Path $iteration 'служебная база') }
        }
        $statusPath = Join-Path $iteration 'vanessa-status.txt'
        $junitPath = Join-Path $iteration 'junit.xml'
        [IO.File]::WriteAllText($statusPath, "0`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($junitPath, '<testsuite tests="1" failures="0" errors="0"><testcase name="Selected"/></testsuite>', [Text.UTF8Encoding]::new($false))
    }

    It 'accepts a missing exit code only with fresh successful Vanessa and JUnit evidence' {
        [IO.File]::WriteAllText($junitPath, '<testsuites><testsuite name="Feature" tests="1" failures="0" errors="0"><testcase name="Selected"/></testsuite></testsuites>', [Text.UTF8Encoding]::new($false))
        $result = Assert-VanessaFeatureResult -Launch $launch -Iteration $iteration -FeaturePath $feature
        $result.outcome | Should -Be 'passed'
        $result.exitCodeState | Should -Be 'unavailable'
        $result.junit.passedCases | Should -Be 1
        $saved = Read-Utf8Text -Path (Join-Path $iteration 'manager-result.json') | ConvertFrom-Json
        $saved.completionBasis | Should -Be 'owned-process-exit+fresh-vanessa-status+fresh-junit'
    }

    It 'rejects a nonzero exit despite successful Vanessa files' {
        $launch.exitCodeState = 'available'
        $launch.exitCode = 7
        { Assert-VanessaFeatureResult -Launch $launch -Iteration $iteration -FeaturePath $feature } | Should -Throw '*VANESSA_MANAGER_FAILED: 7*'
        (Read-Utf8Text -Path (Join-Path $iteration 'manager-result.json') | ConvertFrom-Json).exitCode | Should -Be 7
    }

    It 'rejects a missing and stale status' {
        Remove-Item -LiteralPath $statusPath
        { Assert-VanessaFeatureResult -Launch $launch -Iteration $iteration -FeaturePath $feature } | Should -Throw '*VANESSA_STATUS_MISSING*'
        [IO.File]::WriteAllText($statusPath, "0`n", [Text.UTF8Encoding]::new($false))
        (Get-Item -LiteralPath $statusPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-1)
        { Assert-VanessaFeatureResult -Launch $launch -Iteration $iteration -FeaturePath $feature } | Should -Throw '*VANESSA_STATUS_STALE*'
    }

    It 'rejects a missing and stale JUnit report' {
        Remove-Item -LiteralPath $junitPath
        { Assert-VanessaFeatureResult -Launch $launch -Iteration $iteration -FeaturePath $feature } | Should -Throw '*VANESSA_JUNIT_MISSING*'
        [IO.File]::WriteAllText($junitPath, '<testsuite tests="1" failures="0" errors="0"><testcase name="Selected"/></testsuite>', [Text.UTF8Encoding]::new($false))
        (Get-Item -LiteralPath $junitPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-1)
        { Assert-VanessaFeatureResult -Launch $launch -Iteration $iteration -FeaturePath $feature } | Should -Throw '*VANESSA_JUNIT_STALE*'
    }

    It 'rejects an empty or failed JUnit even when the status is zero' {
        foreach ($xml in @(
            '<testsuite tests="0" failures="0" errors="0"/>',
            '<testsuite tests="1" failures="1" errors="0"><testcase name="Selected"><failure/></testcase></testsuite>'
        )) {
            [IO.File]::WriteAllText($junitPath, $xml, [Text.UTF8Encoding]::new($false))
            { Assert-VanessaFeatureResult -Launch $launch -Iteration $iteration -FeaturePath $feature } | Should -Throw '*VANESSA_JUNIT_FAILED*'
        }
    }

    It 'requires confirmation that the owned manager exited' {
        $launch.exitedAt = $null
        { Assert-VanessaFeatureResult -Launch $launch -Iteration $iteration -FeaturePath $feature } | Should -Throw '*VANESSA_MANAGER_EXIT_UNCONFIRMED*'
    }

    It 'reports the effective TestClient range and configured profile port without claiming OS occupation' {
        $settings = [pscustomobject]@{
            ДиапазонПортовTestclient = '34189-34200'
            КлиентТестирования = [pscustomobject]@{
                ДанныеКлиентовТестирования = @([pscustomobject]@{ Имя='ufa_ui'; ПортЗапускаТестКлиента=34189 })
            }
        }
        $preflight = Get-VanessaFeaturePortPreflight -Settings $settings
        $preflight.range.kind | Should -Be 'range'
        $preflight.profiles[0].rangeRelation | Should -Be 'inside'
        $settings.ДиапазонПортовTestclient = '34189-34189'
        (Get-VanessaFeaturePortPreflight -Settings $settings).diagnosis | Should -Be 'single-port-range-configured'
    }
}
