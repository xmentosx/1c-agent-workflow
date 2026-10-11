BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSupport.ps1')
    $context=Initialize-WorkflowPesterContext
    $RepoRoot=$context.RepoRoot
}
Describe 'Repository Git native transport' {
It 'reads exact Unicode Git paths without entering the redirected stdin launcher' {
        . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
        $root=Join-Path $TestDrive 'Git путь с пробелом'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        & git -C $root init --quiet
        $LASTEXITCODE | Should -Be 0
        $name='Файл с пробелом.txt'
        [IO.File]::WriteAllText((Join-Path $root $name),'content',[Text.UTF8Encoding]::new($false))
        & git -C $root add -- $name
        $LASTEXITCODE | Should -Be 0
        Mock Start-Process { throw 'A Git command without stdin must use the direct process pipe' }
        @(Get-RepositoryGitPathList -RepositoryRoot $root -Arguments @('ls-files','-z')) | Should -Be @($name)
        $script:Root=$root
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/source-delivery-supervisor.ps1'),[ref]$tokens,[ref]$errors)
        $definition=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-DeliveryGit'},$true))
        $definition.Count | Should -Be 1
        . ([scriptblock]::Create($definition[0].Extent.Text))
        (Invoke-DeliveryGit -Arguments @('ls-files','-z')).stdout | Should -BeExactly ($name+[char]0)
        $failed=Invoke-DeliveryGit -Arguments @('rev-parse','--verify','refs/heads/Несуществующая ветка') -AllowFailure
        $failed.exitCode | Should -Not -Be 0
        $failed.stderr | Should -Not -BeNullOrEmpty
        Should -Invoke Start-Process -Times 0 -Exactly
    }

It 'preserves explicitly empty and nonempty Git stdin in a Unicode repository' {
        . (Join-Path $RepoRoot 'scripts/git-path-list.ps1')
        $root=Join-Path $TestDrive 'Git stdin путь с пробелом'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        & git -C $root init --quiet
        $LASTEXITCODE | Should -Be 0
        (Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('hash-object','--stdin') -StandardInput '').stdout.Trim() | Should -BeExactly 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391'
        (Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('hash-object','--stdin') -StandardInput 'test').stdout.Trim() | Should -BeExactly '30d74d258442c7c65512eafab474568dd706c430'
        $content='Данные: путь с пробелом'
        $file='Содержимое с пробелом.txt'
        [IO.File]::WriteAllText((Join-Path $root $file),$content,[Text.UTF8Encoding]::new($false))
        $expected=(& git -C $root hash-object -- $file).Trim()
        $LASTEXITCODE | Should -Be 0
        (Invoke-RepositoryGit -RepositoryRoot $root -Arguments @('hash-object','--stdin') -StandardInput $content).stdout.Trim() | Should -BeExactly $expected
    }

It 'drains large Unicode Git stderr and stdout without blocking either pipe' {
        . (Join-Path $PSScriptRoot 'SourceDelivery.TestSupport.ps1')
        foreach($definition in Get-DeliveryFunctionDefinitions @('Start-DeliveryProcess','Stop-DeliveryProcessJobAndWait','Close-DeliveryProcessJob','Stop-DeliveryProcessTree','Test-DeliveryProcessCreationIdentity','ConvertTo-DeliveryNativeArgument')) { Invoke-Expression $definition.Extent.Text }
        $root=Join-Path $TestDrive 'Git streams путь с пробелом'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        & git -C $root init --quiet
        $LASTEXITCODE | Should -Be 0
        $noise=@'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
if([Console]::In.ReadToEnd() -cne ''){throw 'Omitted Git stdin must reach EOF'}
[Console]::Error.Write(('Ошибка: путь с пробелом; '*8192))
[Console]::Error.Flush()
[Console]::Out.Write(('Вывод: путь с пробелом; '*8192))
[Console]::Out.Flush()
exit 19
'@
        [IO.File]::WriteAllText((Join-Path $root 'noise.ps1'),$noise,[Text.UTF8Encoding]::new($true))
        $probe=Join-Path $root 'probe.ps1'
        $probeBody=@'
param([string]$Root,[string]$Helper)
$ErrorActionPreference='Stop'
. $Helper
$result=Invoke-RepositoryGit -RepositoryRoot $Root -Arguments @('-c','alias.native-pressure=!powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./noise.ps1','native-pressure') -AllowFailure
if($result.exitCode -ne 19){throw "Git exit code was $($result.exitCode), expected 19"}
if($result.stdout -cne ('Вывод: путь с пробелом; '*8192)){throw 'Git stdout Unicode round trip failed'}
if($result.stderr -cne ('Ошибка: путь с пробелом; '*8192)){throw 'Git stderr Unicode round trip failed'}
[Console]::Out.Write('passed')
'@
        [IO.File]::WriteAllText($probe,$probeBody,[Text.UTF8Encoding]::new($true))
        $out=Join-Path $root 'out.log'; $err=Join-Path $root 'err.log'; $started=$null
        try {
            $arguments=(@('-NoProfile','-ExecutionPolicy','Bypass','-File',$probe,'-Root',$root,'-Helper',(Join-Path $RepoRoot 'scripts/git-path-list.ps1')) | ForEach-Object { ConvertTo-DeliveryNativeArgument ([string]$_) }) -join ' '
            $started=Start-DeliveryProcess -ArgumentList $arguments -WorkingDirectory $root -StandardOutputPath $out -StandardErrorPath $err
            $started.process.WaitForExit(10000) | Should -BeTrue -Because 'large stderr must not deadlock the stdout reader; the owned job bounds this reproducer'
            $started.process.ExitCode | Should -Be 0 -Because ([IO.File]::ReadAllText($err))
            [IO.File]::ReadAllText($out) | Should -BeExactly 'passed'
        } finally {
            if($started){
                try { [void](Stop-DeliveryProcessJobAndWait -JobHandle $started.jobHandle -Process $started.process -TimeoutMilliseconds 5000) }
                finally { Close-DeliveryProcessJob -JobHandle $started.jobHandle -Process $started.process; $started.process.Dispose() }
            }
        }
    }
}
