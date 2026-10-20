# On-demand input for this same signed lifecycle operation, never a PID from
# settings or another owner. The foreground caller is waiting for this child.
function Invoke-ItlProductProjectCallerInput {
    param([Parameter(Mandatory=$true)][scriptblock]$Body)
    if (-not $script:LifecycleOperationIsContinuation -or $Action -ne 'update-workflow' -or
        $LifecyclePhase -ne 'post-copy' -or $null -eq $script:LifecycleOperationRecord -or
        [string]::IsNullOrWhiteSpace($script:LifecycleOperationId) -or $script:LifecycleOperationOwnerPid -le 0) {
        throw 'CATALOG_CALLER_INPUT_UNAVAILABLE: requires the active update post-copy continuation; use catalog select in the foreground.'
    }
    Assert-Agent1cLifecycleContinuationOwner
    $current=Read-Agent1cLifecycleOperationRecord -Path $script:LifecycleOperationStatePath
    if ($null -eq $current -or [string]$current['operationId'] -cne $script:LifecycleOperationId -or
        [string]$current['action'] -cne 'update-workflow' -or [string]$current['status'] -cne 'running' -or
        [int]$current['pid'] -ne $script:LifecycleOperationOwnerPid -or
        (Resolve-Agent1cFullPath -Path ([string]$current['projectRoot'])) -cne $script:ProjectRoot -or
        (Get-Process -Id $script:LifecycleOperationOwnerPid -ErrorAction Stop).SessionId -ne
            (Get-Process -Id $PID -ErrorAction Stop).SessionId) {
        throw 'CATALOG_CALLER_INPUT_UNAVAILABLE: the original lifecycle owner no longer matches; use catalog select in the foreground.'
    }
    if (-not ('ItlCatalogCallerConsole' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;
public sealed class ItlCatalogCallerConsole : IDisposable {
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AttachConsole(uint processId);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr GetStdHandle(int id);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetStdHandle(int id, IntPtr handle);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateFileW(string name,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool ReadConsoleW(IntPtr input,[Out] char[] buffer,uint chars,out uint read,IntPtr reserved);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetConsoleMode(IntPtr handle,out uint mode);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetConsoleMode(IntPtr handle,uint mode);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
    IntPtr input=IntPtr.Zero;
    uint originalMode;
    bool attached,modeSaved;
    static void Check(bool ok) { if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    public ItlCatalogCallerConsole(int ownerPid) {
        IntPtr stdout=GetStdHandle(-11),stderr=GetStdHandle(-12);
        try {
            FreeConsole();
            Check(AttachConsole((uint)ownerPid)); attached=true;
            // Preserve capture pipes even when attachment replaces std handles.
            Check(SetStdHandle(-11,stdout)); Check(SetStdHandle(-12,stderr));
            input=CreateFileW("CONIN$",0xC0000000,3,IntPtr.Zero,3,0,IntPtr.Zero);
            if (input==new IntPtr(-1)) { input=IntPtr.Zero; throw new Win32Exception(Marshal.GetLastWin32Error()); }
            Check(GetConsoleMode(input,out originalMode)); modeSaved=true;
            Check(SetConsoleMode(input,(originalMode | 7u) & ~0x200u));
        } catch { Dispose(); throw; }
        finally { SetStdHandle(-11,stdout); SetStdHandle(-12,stderr); }
    }
    public string ReadLine(string prompt) {
        // Legacy capture forwards complete lines only.
        Console.Out.WriteLine(prompt); Console.Out.Flush();
        var answer=new StringBuilder();
        while (true) {
            var buffer=new char[4096]; uint count;
            Check(ReadConsoleW(input,buffer,4096,out count,IntPtr.Zero));
            if (count==0) throw new InvalidOperationException("Catalog input ended without an answer.");
            // ReadConsoleW is counted UTF-16, not a null-terminated string.
            answer.Append(buffer,0,(int)count);
            if (buffer[count-1]=='\n' || buffer[count-1]=='\r')
                return answer.ToString().TrimEnd('\r','\n');
        }
    }
    public void Dispose() {
        if (input!=IntPtr.Zero) {
            if (modeSaved) SetConsoleMode(input,originalMode);
            CloseHandle(input); input=IntPtr.Zero;
        }
        if (attached) { FreeConsole(); attached=false; }
    }
}
'@
    }
    $catalogConsole=[ItlCatalogCallerConsole]::new($script:LifecycleOperationOwnerPid)
    try {
        # Override only this catalog flow, including its nested required/version
        # and conflict questions. Other actions retain the normal Read-Host.
        function Read-Host {
            [CmdletBinding()]
            param([Parameter(Position=0)][string]$Prompt)
            return $catalogConsole.ReadLine($Prompt)
        }
        & $Body
    } finally { $catalogConsole.Dispose() }
}
