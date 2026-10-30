param([string]$ModulePath, [string]$ProjectRoot, [string]$Phase, [string]$Culture)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Text.UTF8Encoding]::new($false)
[Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($Culture)
$script:ProjectRoot=$ProjectRoot
$DevBranchName='branch'
function Resolve-ProjectPath {param([string]$Path) Join-Path $script:ProjectRoot $Path}
function Resolve-Agent1cFullPath {param([string]$Path) [IO.Path]::GetFullPath($Path)}
function Read-Utf8Text {param([string]$Path) [IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)}
function Write-Utf8TextAtomic {param([string]$Path,[string]$Value) [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path));[IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false))}
. $ModulePath
function Get-VerificationModel {'cumulative'}
function Get-VerificationOneOffObligations {@([pscustomobject]@{id='host-proof';expectedResult='Результат 42';inputPaths=@('src/cf/а_б/**','src/cf/а-б/**','src/cf/а.б/**');admissibleProof=@('runtime-observation')})}
function Get-VerificationSelectionEffectiveTree {'1111111111111111111111111111111111111111'}
function Read-DevBranchState {[pscustomobject]@{name='branch'}}
function Assert-DevelopmentBranchWorktreeContext {param($State,$Operation)}
function Get-VerificationLoadedBaseIdentity {param($State) 'same-loaded-target'}
function Get-GitPathList {param($Arguments) @(([string]$Arguments[-1]+'/А.bsl'),([string]$Arguments[-1]+'/а.bsl'))}
function Get-GitObjectIdForTreePath {param($Treeish,$RepoPath) if($Phase -eq 'changed'){'changed-object'}else{'same-object'}}
switch($Phase){
 'begin' {Start-VerificationOneOffProof -ObligationId host-proof | Out-Null}
 'complete' {
    $draft=Read-Utf8Text (Get-VerificationOneOffProofPath host-proof)|ConvertFrom-Json
    Write-Utf8TextAtomic (Resolve-ProjectPath 'evidence/actual.txt') '42'
    $e=@{obligationId='host-proof';runToken=$draft.runToken;expectedResult='Результат 42';status='passed';proofType='runtime-observation';actualResult='42';providerId='fixture';runnerVersion='1';steps=@(@{action='Observe';actual='42'});artifactPaths=@('evidence/actual.txt')}
    Write-Utf8TextAtomic (Resolve-ProjectPath 'evidence/result.json') ($e|ConvertTo-Json -Depth 8)
    Complete-VerificationOneOffProof -EvidencePath 'evidence/result.json' | Out-Null
 }
 'legacy' {
    $path=Get-VerificationOneOffProofPath host-proof
    $proof=Read-Utf8Text $path|ConvertFrom-Json
    $proof.obligationHash='legacy-host-dependent-hash'
    Write-Utf8TextAtomic $path ($proof|ConvertTo-Json -Depth 8)
    $assessment=Get-VerificationOneOffProofAssessment -Obligation @(Get-VerificationOneOffObligations)[0] -State (Read-DevBranchState)
    if($assessment.passed){throw 'Legacy receipt was accepted'}
    Start-VerificationOneOffProof -ObligationId host-proof | Out-Null
    if(@(Get-ChildItem (Join-Path (Split-Path -Parent $path) history) -Filter '*.json').Count -ne 1){throw 'Legacy receipt not preserved'}
 }
 default {
    $a=Get-VerificationOneOffProofAssessment -Obligation @(Get-VerificationOneOffObligations)[0] -State (Read-DevBranchState)
    if($a.passed -ne ($Phase -eq 'assess')){throw ($a|ConvertTo-Json -Compress)}
 }
}
[pscustomobject]@{phase=$Phase;host=$PSVersionTable.PSVersion.ToString();culture=$Culture;status='passed'}|ConvertTo-Json -Compress
