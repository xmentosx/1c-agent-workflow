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

Describe 'Native database access pipe owner' {
    BeforeAll {
        $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . (Join-Path $repo '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')
        . (Join-Path $repo '.agents/skills/itl-remote-runner/scripts/DatabaseAccess.ps1')
    }
    BeforeEach {
        $root = Join-Path $TestDrive ('Общая база с пробелом ' + [guid]::NewGuid().ToString('N'))
        $request = [pscustomobject]@{
            schemaVersion = 1
            coordinator = Join-Path $root 'координатор базы'
            bases = @([pscustomobject]@{ kind = 'file'; path = (Join-Path $root 'целевая база') })
            owner = [pscustomobject]@{ operation = 'native-test'; project = $root; parentPid = $PID }
            timeout = 0
        }
        $owner = $null
    }
    AfterEach { Close-ItlDatabaseAccessHost -Owner $owner }

    It 'holds the whole native operation and admits a second owner only after cleanup' {
        $owner = Start-ItlDatabaseAccessHost -Request $request
        $owner.proof.ticket | Should -Match '^[a-f0-9]{32}$'
        ($owner.public | ConvertTo-Json -Depth 20) | Should -Not -Match 'token'
        { Start-ItlDatabaseAccessHost -Request $request } | Should -Throw '*WAIT_TIMEOUT*'
        (Complete-ItlDatabaseAccessHost -Owner $owner).status | Should -Be 'released'
        $owner = Start-ItlDatabaseAccessHost -Request $request
        (Complete-ItlDatabaseAccessHost -Owner $owner).status | Should -Be 'released'
    }

    It 'inherits a parent token without releasing the parent database reservation' {
        $owner = Start-ItlDatabaseAccessHost -Request $request
        $nestedRequest = $request | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $nestedRequest | Add-Member -NotePropertyName inherited -NotePropertyValue $owner.proof
        $nested = Start-ItlDatabaseAccessHost -Request $nestedRequest
        try {
            $nested.proof.ticket | Should -Be $owner.proof.ticket
            (Complete-ItlDatabaseAccessHost -Owner $nested).inherited | Should -BeTrue
            { Start-ItlDatabaseAccessHost -Request $request } | Should -Throw '*WAIT_TIMEOUT*'
        } finally { Close-ItlDatabaseAccessHost -Owner $nested }
        (Complete-ItlDatabaseAccessHost -Owner $owner).status | Should -Be 'released'
    }

    It 'retains attention when the native parent has no cleanup confirmation' {
        $owner = Start-ItlDatabaseAccessHost -Request $request
        Close-ItlDatabaseAccessHost -Owner $owner
        { Start-ItlDatabaseAccessHost -Request $request } | Should -Throw '*RECOVERY_REQUIRED*'
    }

    It 'preserves an explicit failed cleanup with a Unicode explanation' {
        $owner = Start-ItlDatabaseAccessHost -Request $request
        (Complete-ItlDatabaseAccessHost -Owner $owner -CleanupErrors @('Серверная работа не завершена')).status | Should -Be 'needs-attention'
        { Start-ItlDatabaseAccessHost -Request $request } | Should -Throw '*RECOVERY_REQUIRED*'
    }

    It 'cancels waiting without stopping or releasing the first owner' {
        $owner = Start-ItlDatabaseAccessHost -Request $request
        $request.timeout = 3
        $cancelPath = Join-Path $root 'отмена ожидания.json'
        [IO.File]::WriteAllText($cancelPath, '{}')
        { Start-ItlDatabaseAccessHost -Request $request -CancelPath $cancelPath -OnProgress { param($event) } } | Should -Throw '*CANCELLED*'
        $request.timeout = 0
        { Start-ItlDatabaseAccessHost -Request $request } | Should -Throw '*WAIT_TIMEOUT*'
        (Complete-ItlDatabaseAccessHost -Owner $owner).status | Should -Be 'released'
    }

    It 'reports a missing interpreter before creating any database ticket' {
        { Start-ItlDatabaseAccessHost -Request $request -Python (Join-Path $root 'missing-python.exe') } | Should -Throw
        (Test-Path -LiteralPath (Join-Path $request.coordinator 'tickets')) | Should -BeFalse
    }

    It 'retains database ownership after a real native parent process crash' {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $parentScript = Join-Path $root 'родитель операции.ps1'
        $requestPath = Join-Path $root 'заявка базы.json'
        $ownerInfo = Join-Path $root 'процесс координатора.json'
        [IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        $body = @'
param([string]$Repo, [string]$RequestPath, [string]$OwnerInfo)
$ErrorActionPreference = 'Stop'
. (Join-Path $Repo '.agents/skills/1c-workflow/scripts/lib/agent-1c.core.ps1')
. (Join-Path $Repo '.agents/skills/itl-remote-runner/scripts/DatabaseAccess.ps1')
$request = [IO.File]::ReadAllText($RequestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$owner = Start-ItlDatabaseAccessHost -Request $request
$identity = [pscustomobject]@{ pid = $owner.process.Id; started = $owner.process.StartTime.ToUniversalTime().Ticks; parentPid = $owner.public.owner.parentPid }
[IO.File]::WriteAllText($OwnerInfo, ($identity | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
while ($true) { Start-Sleep -Seconds 1 }
'@
        [IO.File]::WriteAllText($parentScript, $body, [Text.UTF8Encoding]::new($true))
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = 'powershell.exe'
        $start.Arguments = Join-NativeCommandLineArguments -Arguments @('-NoProfile', '-File', $parentScript, '-Repo', $repo, '-RequestPath', $requestPath, '-OwnerInfo', $ownerInfo)
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $parentProcess = New-Object Diagnostics.Process
        $parentProcess.StartInfo = $start
        $hostProcess = $null
        try {
            [void]$parentProcess.Start()
            $stderr = $parentProcess.StandardError.ReadToEndAsync()
            $stdout = $parentProcess.StandardOutput.ReadToEndAsync()
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath $ownerInfo) -and -not $parentProcess.HasExited -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 20
            }
            (Test-Path -LiteralPath $ownerInfo) | Should -BeTrue
            $identity = [IO.File]::ReadAllText($ownerInfo, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $identity.parentPid | Should -Be $parentProcess.Id
            $hostProcess = Get-Process -Id $identity.pid -ErrorAction Stop
            $hostProcess.StartTime.ToUniversalTime().Ticks | Should -Be ([long]$identity.started)
            # Open the exact OS handle before crashing the parent, preventing PID reuse.
            $hostProcess.Handle | Should -Not -Be ([IntPtr]::Zero)
            $parentProcess.Kill()
            $parentProcess.WaitForExit(5000) | Should -BeTrue
            $hostProcess.WaitForExit(5000) | Should -BeTrue
            { Start-ItlDatabaseAccessHost -Request $request } | Should -Throw '*RECOVERY_REQUIRED*'
        } finally {
            if (-not $parentProcess.HasExited) { $parentProcess.Kill(); [void]$parentProcess.WaitForExit(5000) }
            if ($null -ne $hostProcess) {
                if (-not $hostProcess.HasExited) { $hostProcess.Kill(); [void]$hostProcess.WaitForExit(5000) }
                $hostProcess.Dispose()
            }
            $parentProcess.Dispose()
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
