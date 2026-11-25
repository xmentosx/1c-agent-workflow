BeforeAll {
    $RepoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $RepoRoot 'scripts/source-e2e-fixture.ps1')
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/invoke-develop-e2e.ps1'),[ref]$tokens,[ref]$errors)
    foreach($name in @('ConvertTo-DevelopProcessArgument','Invoke-DevelopProcess')){
        $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
        . ([scriptblock]::Create($function.Extent.Text))
    }
    function Start-DiskWindowFixture {
        param([string]$Script,[string]$Ready,[switch]$DiskFailure)
        $args=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$Script,'-ReadyFile',$Ready)
        if($DiskFailure){$args+='-DiskFailure'}
        return Start-DeliveryProcess -ArgumentList (($args|ForEach-Object {ConvertTo-GitProcessArgument $_}) -join ' ') -WorkingDirectory (Split-Path -Parent $Script) -StandardOutputPath ($Ready+'.stdout') -StandardErrorPath ($Ready+'.stderr')
    }
    function Wait-DiskWindowFixture {
        param([string]$Ready,[object]$Job)
        $deadline=[DateTime]::UtcNow.AddSeconds(20)
        while(-not (Test-Path -LiteralPath $Ready)){
            if($Job.process.HasExited -or [DateTime]::UtcNow -gt $deadline){throw 'Hidden Win32 test window did not start'}
            Start-Sleep -Milliseconds 100
        }
    }
}

Describe 'Owned native disk error monitoring' {
    It 'ignores an unrelated window and stops the actual failing child on the first heartbeat with retained Unicode evidence' {
        $root=Join-Path $TestDrive 'дочерний процесс с пробелами';[void][IO.Directory]::CreateDirectory($root)
        $script:outputRoot=Join-Path $root 'output';[void][IO.Directory]::CreateDirectory($script:outputRoot)
        $script:steps=[Collections.Generic.List[object]]::new()
        $entry=Join-Path $root 'скрытое окно.ps1'
        $child=@'
param([string]$ReadyFile,[switch]$DiskFailure)
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class StorageWindowFixture {
    [StructLayout(LayoutKind.Sequential)] public struct Message {public IntPtr window;public uint id;public IntPtr w;public IntPtr l;public uint time;public int x;public int y;public uint extra;}
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr CreateWindowEx(uint extended,string kind,string text,uint style,int x,int y,int width,int height,IntPtr parent,IntPtr menu,IntPtr instance,IntPtr value);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool PeekMessage(out Message message,IntPtr window,uint min,uint max,uint remove);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr DispatchMessage(ref Message message);
    public static void Pump(){Message m;while(PeekMessage(out m,IntPtr.Zero,0,0,1)){DispatchMessage(ref m);}}
}
"@
$text=if($DiskFailure){"На устройстве нет свободного места 'C:\временная папка\v8_тест.tmp'. 112(0x00000070): Недостаточно места на диске."}else{'normal owned operation'}
# No WS_VISIBLE and no ShowWindow: this is a hidden real Win32 boundary fixture.
$window=[StorageWindowFixture]::CreateWindowEx(0,'STATIC',$text,[uint32]2147483648,0,0,100,100,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero)
if($window -eq [IntPtr]::Zero){throw 'CreateWindowEx failed'}
[IO.File]::WriteAllText($ReadyFile,[string]$PID,[Text.UTF8Encoding]::new($false))
$deadline=[DateTime]::UtcNow.AddSeconds(120)
while([DateTime]::UtcNow -lt $deadline){[StorageWindowFixture]::Pump();Start-Sleep -Milliseconds 25}
'@
        [IO.File]::WriteAllText($entry,$child,[Text.UTF8Encoding]::new($true))
        $foreign=$null;$normal=$null
        try {
            $foreignReady=Join-Path $root 'foreign.ready'
            $foreign=Start-DiskWindowFixture -Script $entry -Ready $foreignReady -DiskFailure
            Wait-DiskWindowFixture -Ready $foreignReady -Job $foreign
            $normalReady=Join-Path $root 'normal.ready'
            $normal=Start-DiskWindowFixture -Script $entry -Ready $normalReady
            Wait-DiskWindowFixture -Ready $normalReady -Job $normal
            {Assert-SourceE2ENativeDisk -Process $normal.process -LogPaths @($normalReady+'.stdout',$normalReady+'.stderr') -EvidencePath (Join-Path $root 'must-not-exist.json') -VolumePaths @($root) -InspectWindows}|Should -Not -Throw
            Test-Path -LiteralPath (Join-Path $root 'must-not-exist.json')|Should -BeFalse
            Close-DeliveryProcessJob -JobHandle $normal.jobHandle -Process $normal.process -PriorErrorMessage 'test cleanup'
            $normal.process.Dispose();$normal=$null
            $ownedReady=Join-Path $root 'owned.ready';$watch=[Diagnostics.Stopwatch]::StartNew()
            {Invoke-DevelopProcess -Name disk112 -WorkingRoot $root -ScriptPath $entry -Arguments @('-ReadyFile',$ownedReady,'-DiskFailure') -TimeoutSeconds 90}|Should -Throw '*SOURCE_E2E_DISK_FULL*ResumePlan*'
            $watch.Elapsed.TotalSeconds|Should -BeLessThan 65
            $evidence=Read-QualificationFixtureJson -Path (Join-Path $script:outputRoot 'disk112.disk-full.json')
            $evidence.code|Should -Be 112
            ($evidence.evidence.text -join "`n")|Should -Match 'временная папка\\v8_тест.tmp'
            $ownedId=[int](Read-Utf8Text -Path $ownedReady)
            @(Get-Process -Id $ownedId -ErrorAction SilentlyContinue).Count|Should -Be 0
            $foreign.process.HasExited|Should -BeFalse
        } finally {
            foreach($job in @($normal,$foreign)){if($job){try {Close-DeliveryProcessJob -JobHandle $job.jobHandle -Process $job.process -PriorErrorMessage 'test cleanup'}finally{$job.process.Dispose()}}}
        }
    }
}
