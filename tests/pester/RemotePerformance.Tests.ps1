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
