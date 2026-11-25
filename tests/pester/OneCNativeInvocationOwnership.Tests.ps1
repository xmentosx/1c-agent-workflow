Describe 'Recovery identifies a native invocation by its captured arguments and time' {
    BeforeAll {
        Set-StrictMode -Version Latest
        . (Join-Path $PSScriptRoot 'TestSupport.ps1')
        $context = Initialize-WorkflowPesterContext
        . $context.HelperPath -ProjectRoot $context.RepoRoot -Action help *> $null
    }
    BeforeEach {
        $root = Join-Path $TestDrive 'Исходный запуск 1С'
        $basePath = Join-Path $root 'Целевая база'
        $outputPath = Join-Path $root 'Журнал запуска.log'
        $scope = [pscustomobject]@{schemaVersion=1;role='native-invocation';kind='file';path=$basePath;mode='DESIGNER';logPath=$outputPath;notBeforeUtc='2026-09-10T00:00:00Z'}
        $candidate = [pscustomobject]@{Name='1cv8.exe';ProcessId=4455;ParentProcessId=1;processStartTime='2026-09-10T00:00:01Z'
            CommandLine=('"C:\Program Files\1cv8\bin\1cv8.exe" DESIGNER /F "' + $basePath + '" /Out "' + $outputPath + '"')}
    }
    It 'recognizes an orphan with the exact captured target and output after the parent exited' {
        Test-OneCNativeProcessInRunScopes -ProcessInfo $candidate -Scopes @($scope) | Should -BeTrue
        $candidate.CommandLine = $candidate.CommandLine.Replace('/Out "','/Out"')
        Test-OneCNativeProcessInRunScopes -ProcessInfo $candidate -Scopes @($scope) | Should -BeTrue
    }
    It 'preserves a different <difference> despite a reused process id' -TestCases @(
        @{difference='database'},@{difference='output'},@{difference='mode'},@{difference='start-time'},@{difference='executable'}
    ) {
        param($difference)
        switch ($difference) {
            database { $candidate.CommandLine=$candidate.CommandLine.Replace($basePath,($basePath+' чужая')) }
            output { $candidate.CommandLine=$candidate.CommandLine.Replace($outputPath,($outputPath+'.other')) }
            mode { $candidate.CommandLine=$candidate.CommandLine.Replace(' DESIGNER ',' ENTERPRISE ') }
            start-time { $candidate.processStartTime='2026-09-09T23:59:59Z' }
            executable { $candidate.Name='other.exe' }
        }
        Test-OneCNativeProcessInRunScopes -ProcessInfo $candidate -Scopes @($scope) | Should -BeFalse
    }
    It 'does not turn missing creation-time evidence into an empty owned-process inventory' {
        $candidate.processStartTime=''
        { Test-OneCNativeProcessInRunScopes -ProcessInfo $candidate -Scopes @($scope) } | Should -Throw '*START_TIME_UNAVAILABLE*'
    }
    It 'uses the CIM creation date with an invariant UTC comparison' {
        $candidate.PSObject.Properties.Remove('processStartTime')
        $candidate | Add-Member NoteProperty CreationDate ([datetime]::Parse('2026-09-10T00:00:01Z',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind))
        Test-OneCNativeProcessInRunScopes -ProcessInfo $candidate -Scopes @($scope) | Should -BeTrue
    }
}
