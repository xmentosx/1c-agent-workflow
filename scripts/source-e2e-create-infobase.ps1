[CmdletBinding()]
param([string]$ProjectRoot='', [string]$DevBranchName='')
# Source-only preparation. The installed baseline still owns RestoreIB.
$lib=Join-Path (Split-Path -Parent $PSScriptRoot) '.agents/skills/1c-workflow/scripts/lib'
. (Join-Path $lib 'agent-1c.core.ps1')
. (Join-Path $lib 'agent-1c.lifecycle.ps1')
. (Join-Path $lib 'agent-1c.ports.ps1')
. (Join-Path $lib 'agent-1c.sessions.ps1')
. (Join-Path $PSScriptRoot 'source-proof-json.ps1')
. (Join-Path $PSScriptRoot 'git-path-list.ps1')
. (Join-Path $PSScriptRoot 'lifecycle-qualification-fixture.ps1')

function New-SourceQualificationInfoBase {
    param([string]$BranchRoot, [string]$BranchName, [string]$PlatformPath)
    $branch=[IO.Path]::GetFullPath($BranchRoot).TrimEnd('\','/')
    $parent=Split-Path -Parent $branch
    $claim=Read-QualificationFixtureJson -Path (Join-Path $parent 'qualification-fixture.json')
    if([string]$claim.kind -cne 'itl-qualification-fixture-target' -or [string]$claim.status -cne 'materializing' -or
        [string]$claim.branchRoot -ine $branch -or [string]$claim.projectRoot -ine (Join-Path $parent 'project') -or
        $branch -ine (Join-Path $parent 'branch') -or [string]::IsNullOrWhiteSpace($BranchName) -or
        $BranchName -match '[/\\]' -or $BranchName -in @('.','..')) {throw 'FIXTURE_CREATE_OWNERSHIP_INVALID'}
    $common=Get-RepositoryCommonGitDirectory -RepositoryRoot $branch
    if($common -ine (Get-RepositoryCommonGitDirectory -RepositoryRoot ([string]$claim.projectRoot))){throw 'FIXTURE_CREATE_GIT_OWNERSHIP_INVALID'}
    $statePath=Resolve-QualificationFixtureChild -Root $branch -RelativePath ('.agent-1c/dev-branches/'+$BranchName+'.json')
    $state=Read-QualificationFixtureJson -Path $statePath
    $prefix=$branch+[IO.Path]::DirectorySeparatorChar
    $base=[IO.Path]::GetFullPath([string]$state.devBranchInfoBasePath)
    if([string]$state.infoBaseKind -cne 'file' -or [string]$state.devBranchName -cne $BranchName -or -not $base.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'FIXTURE_CREATE_TARGET_INVALID'}
    $base=Resolve-QualificationFixtureChild -Root $branch -RelativePath $base.Substring($prefix.Length)
    if(Test-Path -LiteralPath $base){throw 'FIXTURE_CREATE_TARGET_EXISTS: preserve this attempt; repeat qualification to create a new owned target'}
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $base))
    $logs=Resolve-QualificationFixtureChild -Root $parent -RelativePath 'preparation-logs'
    [void][IO.Directory]::CreateDirectory($logs)
    $log=Join-Path $logs ('create-infobase-'+[guid]::NewGuid().ToString('N')+'.log')
    $arguments=@('CREATEINFOBASE',(New-FileInfoBaseConnectionString -Path $base),'/DisableStartupDialogs','/Out',$log)
    $script:OneCNativeOperationJournal=New-OneCNativeOperationJournal -Resources @([pscustomobject]@{kind='file';path=$base})
    $result=Invoke-WithOneCSessionAdmissionContext -InfoBaseKind file -InfoBasePath $base -RequiredSessions 1 -Purpose 'qualification-infobase-create' -ScriptBlock {
        Invoke-NativeProcessAndWaitResult -FilePath $PlatformPath -Arguments $arguments -OneCCreateInfoBaseSyntax -TimeoutSeconds 300
    }
    if($result.timedOut -or $result.exitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $base '1Cv8.1CD') -PathType Leaf)){
        throw "FIXTURE_CREATE_FAILED: exit=$($result.exitCode) timedOut=$($result.timedOut); retain attempt/logs=$logs and repeat qualification after diagnosis"
    }
    return [pscustomobject]@{infoBasePath=$base;logPath=$log}
}

if($ProjectRoot){
    $ErrorActionPreference='Stop'
    $utf8=[Text.UTF8Encoding]::new($false);[Console]::InputEncoding=$utf8;[Console]::OutputEncoding=$utf8;$OutputEncoding=$utf8
    $script:ProjectRoot=[IO.Path]::GetFullPath($ProjectRoot)
    $script:ConfigPath=Join-Path $script:ProjectRoot '.agent-1c/project.json'
    Import-DotEnv -Path (Join-Path $script:ProjectRoot '.dev.env')
    Read-ProjectConfig
    $null=New-SourceQualificationInfoBase -BranchRoot $script:ProjectRoot -BranchName $DevBranchName -PlatformPath (Get-PlatformPath)
}
