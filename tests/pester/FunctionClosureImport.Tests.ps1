BeforeAll {
    . (Join-Path $PSScriptRoot 'FunctionClosure.TestSupport.ps1')
    function New-ClosureFixtureFile {
        param([string]$Name, [string]$Text)
        $root = Join-Path $TestDrive 'Владелец с пробелом'
        [void][IO.Directory]::CreateDirectory($root)
        $path = Join-Path $root $Name
        [IO.File]::WriteAllText($path, $Text, [Text.UTF8Encoding]::new($true))
        return $path
    }
}

Describe 'Fixture function closure import' {
    It 'follows a newly added in-owner callee without a fixture edit' {
        # The original defect: a rollout owner started calling a new helper and a
        # hand-listed fixture failed with CommandNotFound.
        $owner = New-ClosureFixtureFile 'owner.ps1' @'
function Invoke-ClosureRoot { param([string]$Value) "root:" + (Format-ClosureValue $Value) }
function Format-ClosureValue { param([string]$Value) Write-ClosureMarker; $Value.ToUpperInvariant() }
function Write-ClosureMarker { $script:closureMarker = 'written' }
function Get-ClosureUnrelated { throw 'not imported' }
'@
        $stubs = New-ClosureFixtureFile 'stubs.Tests.ps1' 'function Get-OtherStub {}'
        $names = @(Import-TestFunctionClosure -Path @($owner) -Root @('Invoke-ClosureRoot') -StubSource $stubs)
        $names | Should -Be @('Invoke-ClosureRoot', 'Format-ClosureValue', 'Write-ClosureMarker')
        Invoke-ClosureRoot 'путь' | Should -BeExactly 'root:ПУТЬ'
        $script:closureMarker | Should -Be 'written'
        Get-Command Get-ClosureUnrelated -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'never imports or follows a function the test file substitutes' {
        $owner = New-ClosureFixtureFile 'substituted.ps1' @'
function Invoke-SubstitutedRoot { Invoke-RealWriter }
function Invoke-RealWriter { Remove-RealState; 'real' }
function Remove-RealState { throw 'the real writer must not run' }
'@
        $stubs = New-ClosureFixtureFile 'substitute.Tests.ps1' 'Describe x { BeforeEach { function Invoke-RealWriter { "stub" } } }'
        $names = @(Get-TestFunctionClosure -Path @($owner) -Root @('Invoke-SubstitutedRoot') -StubSource $stubs | ForEach-Object Name)
        $names | Should -Be @('Invoke-SubstitutedRoot')
        $null = Import-TestFunctionClosure -Path @($owner) -Root @('Invoke-SubstitutedRoot') -StubSource $stubs
        # Without the substitute in scope the call is missing, never the real owner.
        { Invoke-SubstitutedRoot } | Should -Throw -ExceptionType ([Management.Automation.CommandNotFoundException])
        function Invoke-RealWriter { 'stub' }
        Invoke-SubstitutedRoot | Should -Be 'stub'
    }

    It 'rejects unknown, substituted or ambiguous roots and unknown exclusions' {
        $owner = New-ClosureFixtureFile 'checks.ps1' 'function Get-CheckedRoot { Get-CheckedLeaf }; function Get-CheckedLeaf { 1 }'
        $duplicate = New-ClosureFixtureFile 'duplicate.ps1' 'function Get-CheckedLeaf { 2 }'
        $stubs = New-ClosureFixtureFile 'checks.Tests.ps1' 'function Get-CheckedRoot {}'
        { Get-TestFunctionClosure -Path @($owner) -Root @('Get-MissingRoot') } | Should -Throw '*TEST_FUNCTION_CLOSURE_ROOT_UNKNOWN*'
        { Get-TestFunctionClosure -Path @($owner) -Root @('Get-CheckedRoot') -StubSource $stubs } | Should -Throw '*TEST_FUNCTION_CLOSURE_ROOT_SUBSTITUTED*'
        { Get-TestFunctionClosure -Path @($owner) -Root @('Get-CheckedRoot') -Exclude @('Get-MissingLeaf') } | Should -Throw '*TEST_FUNCTION_CLOSURE_EXCLUDE_UNKNOWN*'
        { Get-TestFunctionClosure -Path @($owner, $duplicate) -Root @('Get-CheckedRoot') } | Should -Throw '*TEST_FUNCTION_CLOSURE_AMBIGUOUS*'
        @(Get-TestFunctionClosure -Path @($owner) -Root @('Get-CheckedRoot') -Exclude @('Get-CheckedLeaf') | ForEach-Object Name) | Should -Be @('Get-CheckedRoot')
    }
}
