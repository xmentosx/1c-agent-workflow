param([string]$RepoRoot,[string]$Root,[string]$Case,[switch]$Child,[string]$OperationId,[int]$OwnerPid)
$ErrorActionPreference='Stop'
$fixtureOperationId=$OperationId
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$OutputEncoding=[Console]::OutputEncoding
. (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/lib/itl-powershell-environment.ps1')
$env:PSModulePath=Get-ItlWindowsPowerShellModulePath
. (Join-Path $RepoRoot '.agents/skills/1c-workflow/scripts/agent-1c.ps1') -ProjectRoot $Root -Action help *> $null
. Import-ItlProductProjectSetup
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CatalogFixtureInput {
 [StructLayout(LayoutKind.Explicit,CharSet=CharSet.Unicode,Size=20)] public struct Key {
  [FieldOffset(0)] public ushort kind;
  [FieldOffset(4)] public int down;
  [FieldOffset(8)] public ushort repeat;
  [FieldOffset(14)] public char character;
 }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool WriteConsoleInputW(IntPtr h,Key[] keys,uint count,out uint written);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr CreateFileW(string name,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool GetConsoleMode(IntPtr h,out uint mode);
 [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
 [DllImport("kernel32.dll")] public static extern uint GetConsoleCP();
 public static void Answer(IntPtr h,string text) {
  char[] chars=(text+"\r").ToCharArray(); var keys=new Key[chars.Length];
  for(int i=0;i<chars.Length;i++) keys[i]=new Key {kind=1,down=1,repeat=1,character=chars[i]};
  uint count; if(!WriteConsoleInputW(h,keys,(uint)keys.Length,out count) || count!=keys.Length) throw new Exception("Fixture console injection failed.");
 }
}
'@
if($Child){
    $Action='update-workflow';$LifecyclePhase='post-copy'
    Enter-Agent1cLifecycleOperation -RequestedAction $Action -RequestedOperationId $fixtureOperationId -RequestedOwnerPid $OwnerPid -Continuation
    function Test-InteractiveInputAvailable {return ($Case -ne 'unattended')}
    function Read-InitOptional {
        param([string]$Prompt)
        $value=Read-Host $Prompt
        Write-Utf8TextAtomic (Join-Path $Root 'answer.json') (@{value=$value}|ConvertTo-Json)
        return $value
    }
    function Select-ItlProductProjectCandidate {
        param($ProjectId,$ProfileId,[bool]$AllowPrompt,$Limit)
        if(-not $AllowPrompt){throw 'CATALOG_PROJECT_REQUIRED: fixture unattended selection'}
        if(-not $ProjectId){$ProjectId=Read-InitRequired 'Published project ID (required)'}
        if($ProjectId -eq 'new'){throw 'CATALOG_PROJECT_CREATE_SEPARATE: fixture creation is separate'}
        if($ProjectId -ne 'five'){throw 'CATALOG_PROJECT_UNKNOWN: fixture requires five'}
        return @{binding=@{projectId='five'};context=@{catalogRevision=('a'*40);settingsHash=('b'*64)}}
    }
    function Invoke-ItlProductProjectAssociation {
        param($Candidate,$Decision,[bool]$AllowPrompt,[switch]$IncludeClientSurfaces)
        $name=Read-InitRequired 'Fixture nested project name'
        if($Case -eq 'throw'){throw 'Fixture association failed after input'}
        $version=Read-InitBaseConfigurationVersion
        Write-Utf8TextAtomic (Join-Path $Root 'nested.json') (@{name=$name;version=$version}|ConvertTo-Json)
    }
    $associationError=''
    try {Invoke-ItlProductProjectPostUpdateOffer} catch {$associationError=$_.Exception.Message}
    $result=@{error=$associationError;preferences=(Read-ItlProductProjectSetting selection);detached=([CatalogFixtureInput]::GetConsoleCP() -eq 0);readHostKind=(Get-Command Read-Host).CommandType.ToString()}
    Write-Utf8TextAtomic (Join-Path $Root 'child.json') ($result|ConvertTo-Json -Depth 20)
    Write-Output 'CAPTURE_PIPE_SURVIVED'
    Exit-Agent1cLifecycleOperation
    exit 0
}
$console=[IntPtr]::Zero
try {
    Enter-Agent1cLifecycleOperation -RequestedAction update-workflow
    # This dedicated hidden fixture console belongs only to this parent/child.
    # No prompt hook is installed in the parent; it only supplies test keystrokes.
    $console=[CatalogFixtureInput]::CreateFileW('CONIN$',[uint32]3221225472,3,[IntPtr]::Zero,3,0,[IntPtr]::Zero)
    if($console -eq [IntPtr]::new(-1)){throw 'Fixture needs its own console'}
    $before=[uint32]0;$null=[CatalogFixtureInput]::GetConsoleMode($console,[ref]$before)
    $script:answerIndex=0
    $script:fixtureAnswers=@(switch($Case){'later'{@('later')};'empty'{@('','five','Тест Проект PM5','PM5')};'new'{@('new')};'existing'{@('five','Тест Проект PM5','PM5')};'throw'{@('five','Тест Проект PM5')};default{@()}})
    $capture=Invoke-ItlNativeProcessCapture -FilePath powershell.exe -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-RepoRoot',$RepoRoot,'-Root',$Root,'-Case',$Case,'-Child','-OperationId',$script:LifecycleOperationId,'-OwnerPid',[string]$PID) -WorkingDirectory $Root -TimeoutSeconds 35 -OnStdoutLine {
        param($line)
        if($line -match '^Published project ID|^Fixture nested|^Base configuration version'){
            if($script:answerIndex -ge $script:fixtureAnswers.Count){throw 'Unexpected additional prompt'}
            [CatalogFixtureInput]::Answer($console,$script:fixtureAnswers[$script:answerIndex]);$script:answerIndex++
        }
    }
    $after=[uint32]0;$null=[CatalogFixtureInput]::GetConsoleMode($console,[ref]$after)
    Write-Utf8TextAtomic (Join-Path $Root 'parent.json') (@{capture=$capture;answered=$script:answerIndex;modeRestored=($before -eq $after)}|ConvertTo-Json -Depth 25)
    exit ([int]$capture.exitCode)
} catch {
    Write-Utf8TextAtomic (Join-Path $Root 'failure.txt') ($_|Out-String)
    exit 1
} finally {
    if($console -ne [IntPtr]::Zero -and $console -ne [IntPtr]::new(-1)){$null=[CatalogFixtureInput]::CloseHandle($console)}
    Exit-Agent1cLifecycleOperation
}
