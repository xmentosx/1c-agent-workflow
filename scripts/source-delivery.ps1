[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("RegisterChange", "Status", "PublishDevelop", "ReleaseMaster")]
    [string]$Action,
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$Remote = "origin",
    [string]$QueueId = "",
    [string]$BaseRef = "",
    [string[]]$CoverageContract = @(),
    [string]$AiRulesSource = "",
    [string]$E2EProjectRoot = "",
    [string]$GateScript = "",
    [string]$ComponentFinalizerScript = "",
    [string]$Version = "",
    [ValidateSet("Auto", "Restart")]
    [string]$ReleaseResumeMode = "Auto",
    [switch]$RequireRelease
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
. (Join-Path $PSScriptRoot "git-path-list.ps1")
. (Join-Path $PSScriptRoot "release-qualification.ps1")

$script:Root = [System.IO.Path]::GetFullPath($RepositoryRoot)
$script:Remote = $Remote
$script:GateScript = if ($GateScript) { [System.IO.Path]::GetFullPath($GateScript) } else { Join-Path $script:Root "scripts\check.ps1" }
$script:ComponentFinalizerScript = if ($ComponentFinalizerScript) { [System.IO.Path]::GetFullPath($ComponentFinalizerScript) } else { "" }
$script:QueueRoot = "refs/itl/develop-queue"

function Invoke-DeliveryGit {
    param([string[]]$Arguments, [switch]$AllowFailure, [AllowNull()][string]$StandardInput = $null)
    return Invoke-RepositoryGit -RepositoryRoot $script:Root -Arguments $Arguments -AllowFailure:$AllowFailure -StandardInput $StandardInput
}

function Get-GitValue {
    param([string[]]$Arguments)
    return (Invoke-DeliveryGit -Arguments $Arguments).stdout.Trim()
}

function Assert-CleanDeliveryWorktree {
    $status = (Invoke-DeliveryGit -Arguments @("status", "--porcelain", "--untracked-files=all")).stdout
    if ($status) { throw "Source delivery requires a clean worktree. Commit or move unrelated changes first." }
}

function ConvertTo-QueueRefName {
    param([string]$Value)
    $name = $Value.Trim().Replace('\', '/').ToLowerInvariant()
    $name = [regex]::Replace($name, '[^a-z0-9._/-]+', '-')
    $name = [regex]::Replace($name, '/+', '/')
    $name = $name.Trim('/', '.', '-')
    if (-not $name) { throw "Queue id cannot be converted to a safe Git ref name." }
    return $name
}

function Get-DefaultQueueId {
    $branch = Get-GitValue -Arguments @("branch", "--show-current")
    if ($branch) { return $branch }
    return "detached-" + (Get-GitValue -Arguments @("rev-parse", "--short=12", "HEAD"))
}

function Invoke-QueueRefTransaction {
    param([string[]]$Commands)
    $payload = (($Commands -join "`n") + "`n")
    [void](Invoke-DeliveryGit -Arguments @("update-ref", "--stdin") -StandardInput $payload)
}

function Get-QueueEntries {
    $result = Invoke-DeliveryGit -Arguments @("for-each-ref", "--format=%(refname) %(objectname)", "$script:QueueRoot/")
    $records = @{}
    foreach ($line in @($result.stdout -split "`r?`n" | Where-Object { $_ })) {
        $parts = $line.Split(' ', 2)
        $ref = [string]$parts[0]
        $sha = [string]$parts[1]
        if ($ref -notmatch ('^' + [regex]::Escape($script:QueueRoot) + '/(.+)/(base|head)$')) { continue }
        $id = $Matches[1]
        $kind = $Matches[2]
        if (-not $records.ContainsKey($id)) { $records[$id] = [ordered]@{ id = $id; base = ""; head = "" } }
        $records[$id][$kind] = $sha
    }
    return @($records.Values | Where-Object { $_.base -and $_.head } | Sort-Object id | ForEach-Object { [pscustomobject]$_ })
}

function Stop-DeliveryProcessTree {
    param([AllowNull()][object]$Process)
    if (-not $Process) { return }
    try { if ($Process.HasExited) { return } } catch { return }

    $processId = [int]$Process.Id
    try {
        if ($env:OS -eq "Windows_NT") {
            # Use the .NET launcher instead of a PowerShell native-command
            # pipeline: Ctrl+C stops that pipeline, while finally still needs
            # to run taskkill for every descendant owned by the gate.
            $taskkillPath = Join-Path $env:SystemRoot "System32\taskkill.exe"
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $taskkillPath
            $startInfo.Arguments = "/PID $processId /T /F"
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $killer = [Diagnostics.Process]::Start($startInfo)
            try {
                $stdoutTask = $killer.StandardOutput.ReadToEndAsync()
                $stderrTask = $killer.StandardError.ReadToEndAsync()
                $killer.WaitForExit()
                [void]$stdoutTask.GetAwaiter().GetResult()
                [void]$stderrTask.GetAwaiter().GetResult()
            } finally { $killer.Dispose() }
        } else {
            $Process.Kill()
        }
    } catch {
        try { $Process.Kill() } catch {}
    }
    try { [void]$Process.WaitForExit(15000) } catch {}
}

function Start-DeliveryProcess {
    param(
        [Parameter(Mandatory = $true)][string]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$StandardOutputPath,
        [Parameter(Mandatory = $true)][string]$StandardErrorPath
    )
    if ($env:OS -ne "Windows_NT") {
        $process = Start-Process -FilePath "powershell.exe" -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -RedirectStandardOutput $StandardOutputPath -RedirectStandardError $StandardErrorPath -PassThru
        $null = $process.Handle
        return [pscustomobject]@{ process = $process; jobHandle = [IntPtr]::Zero }
    }
    if (-not ("ItlDeliveryProcessJob" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class ItlDeliveryProcessJob
{
    private const UInt32 JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    private const Int32 JobObjectExtendedLimitInformation = 9;
    private const UInt32 EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    private const UInt32 CREATE_NO_WINDOW = 0x08000000;
    private const UInt32 CREATE_SUSPENDED = 0x00000004;
    private const UInt32 STARTF_USESTDHANDLES = 0x00000100;
    private const UInt32 PROC_THREAD_ATTRIBUTE_HANDLE_LIST = 0x00020002;
    private const UInt32 PROC_THREAD_ATTRIBUTE_JOB_LIST = 0x0002000D;
    private const UInt32 GENERIC_READ = 0x80000000;
    private const UInt32 GENERIC_WRITE = 0x40000000;
    private const UInt32 FILE_SHARE_READ = 0x00000001;
    private const UInt32 FILE_SHARE_WRITE = 0x00000002;
    private const UInt32 CREATE_ALWAYS = 2;
    private const UInt32 OPEN_EXISTING = 3;
    private const UInt32 FILE_ATTRIBUTE_NORMAL = 0x00000080;
    private static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public Int64 PerProcessUserTimeLimit;
        public Int64 PerJobUserTimeLimit;
        public UInt32 LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public UInt32 ActiveProcessLimit;
        public UIntPtr Affinity;
        public UInt32 PriorityClass;
        public UInt32 SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public UInt64 ReadOperationCount;
        public UInt64 WriteOperationCount;
        public UInt64 OtherOperationCount;
        public UInt64 ReadTransferCount;
        public UInt64 WriteTransferCount;
        public UInt64 OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SECURITY_ATTRIBUTES
    {
        public Int32 nLength;
        public IntPtr lpSecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFOEX
    {
        public Int32 cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public UInt32 dwX;
        public UInt32 dwY;
        public UInt32 dwXSize;
        public UInt32 dwYSize;
        public UInt32 dwXCountChars;
        public UInt32 dwYCountChars;
        public UInt32 dwFillAttribute;
        public UInt32 dwFlags;
        public UInt16 wShowWindow;
        public UInt16 cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public UInt32 dwProcessId;
        public UInt32 dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct RTL_OSVERSIONINFOEX
    {
        public UInt32 dwOSVersionInfoSize;
        public UInt32 dwMajorVersion;
        public UInt32 dwMinorVersion;
        public UInt32 dwBuildNumber;
        public UInt32 dwPlatformId;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szCSDVersion;
        public UInt16 wServicePackMajor;
        public UInt16 wServicePackMinor;
        public UInt16 wSuiteMask;
        public Byte wProductType;
        public Byte wReserved;
    }

    public sealed class StartedProcess
    {
        public Process Process;
        public IntPtr JobHandle;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, Int32 informationClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION information, UInt32 informationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(IntPtr attributeList, Int32 attributeCount, UInt32 flags, ref IntPtr size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(IntPtr attributeList, UInt32 flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previousValue, IntPtr returnSize);

    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(string fileName, UInt32 desiredAccess, UInt32 shareMode, ref SECURITY_ATTRIBUTES securityAttributes, UInt32 creationDisposition, UInt32 flagsAndAttributes, IntPtr templateFile);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcess(string applicationName, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, UInt32 creationFlags, IntPtr environment, string currentDirectory, ref STARTUPINFOEX startupInfo, out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern UInt32 ResumeThread(IntPtr thread);

    [DllImport("ntdll.dll", CharSet = CharSet.Unicode)]
    private static extern Int32 RtlGetVersion(ref RTL_OSVERSIONINFOEX versionInformation);

    private static void AssertAtomicJobListSupport()
    {
        RTL_OSVERSIONINFOEX version = new RTL_OSVERSIONINFOEX();
        version.dwOSVersionInfoSize = (UInt32)Marshal.SizeOf(typeof(RTL_OSVERSIONINFOEX));
        Int32 status = RtlGetVersion(ref version);
        if (status != 0)
            throw new PlatformNotSupportedException("Unable to verify Windows 10 or Windows Server 2016+ support required for atomic publication child process ownership (RtlGetVersion status " + status + ").");
        if (version.dwMajorVersion < 10)
            throw new PlatformNotSupportedException("Atomic publication child process ownership requires Windows 10 or Windows Server 2016+; detected Windows " + version.dwMajorVersion + "." + version.dwMinorVersion + " build " + version.dwBuildNumber + ".");
    }

    private static IntPtr CreateInheritedFile(string path, UInt32 access, UInt32 disposition)
    {
        SECURITY_ATTRIBUTES attributes = new SECURITY_ATTRIBUTES();
        attributes.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
        attributes.bInheritHandle = true;
        IntPtr handle = CreateFile(path, access, FILE_SHARE_READ | FILE_SHARE_WRITE, ref attributes, disposition, FILE_ATTRIBUTE_NORMAL, IntPtr.Zero);
        if (handle == INVALID_HANDLE_VALUE) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateFile failed for " + path + ".");
        return handle;
    }

    public static StartedProcess Start(string executable, string arguments, string workingDirectory, string standardOutputPath, string standardErrorPath)
    {
        AssertAtomicJobListSupport();
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateJobObject failed.");
        IntPtr attributeList = IntPtr.Zero;
        IntPtr jobList = IntPtr.Zero;
        IntPtr handleList = IntPtr.Zero;
        IntPtr standardInput = IntPtr.Zero;
        IntPtr standardOutput = IntPtr.Zero;
        IntPtr standardError = IntPtr.Zero;
        PROCESS_INFORMATION processInformation = new PROCESS_INFORMATION();
        try
        {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION information = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            information.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            UInt32 length = (UInt32)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref information, length))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetInformationJobObject failed.");

            IntPtr attributeSize = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref attributeSize);
            attributeList = Marshal.AllocHGlobal(attributeSize);
            if (!InitializeProcThreadAttributeList(attributeList, 2, 0, ref attributeSize))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "InitializeProcThreadAttributeList failed.");

            jobList = Marshal.AllocHGlobal(IntPtr.Size);
            Marshal.WriteIntPtr(jobList, job);
            if (!UpdateProcThreadAttribute(attributeList, 0, new IntPtr(PROC_THREAD_ATTRIBUTE_JOB_LIST), jobList, new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "UpdateProcThreadAttribute for the delivery job failed.");

            standardInput = CreateInheritedFile("NUL", GENERIC_READ, OPEN_EXISTING);
            standardOutput = CreateInheritedFile(standardOutputPath, GENERIC_WRITE, CREATE_ALWAYS);
            standardError = CreateInheritedFile(standardErrorPath, GENERIC_WRITE, CREATE_ALWAYS);
            handleList = Marshal.AllocHGlobal(IntPtr.Size * 3);
            Marshal.WriteIntPtr(handleList, 0, standardInput);
            Marshal.WriteIntPtr(handleList, IntPtr.Size, standardOutput);
            Marshal.WriteIntPtr(handleList, IntPtr.Size * 2, standardError);
            if (!UpdateProcThreadAttribute(attributeList, 0, new IntPtr(PROC_THREAD_ATTRIBUTE_HANDLE_LIST), handleList, new IntPtr(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "UpdateProcThreadAttribute for delivery standard handles failed.");

            STARTUPINFOEX startupInfo = new STARTUPINFOEX();
            startupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
            startupInfo.dwFlags = STARTF_USESTDHANDLES;
            startupInfo.hStdInput = standardInput;
            startupInfo.hStdOutput = standardOutput;
            startupInfo.hStdError = standardError;
            startupInfo.lpAttributeList = attributeList;
            StringBuilder commandLine = new StringBuilder("\"" + executable + "\" " + arguments);
            if (!CreateProcess(executable, commandLine, IntPtr.Zero, IntPtr.Zero, true, EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW | CREATE_SUSPENDED, IntPtr.Zero, workingDirectory, ref startupInfo, out processInformation))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcess for the delivery child failed.");
            StartedProcess started = new StartedProcess();
            started.Process = Process.GetProcessById((Int32)processInformation.dwProcessId);
            IntPtr ownedProcessHandle = started.Process.Handle;
            started.JobHandle = job;
            if (ResumeThread(processInformation.hThread) == UInt32.MaxValue)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "ResumeThread for the delivery child failed.");
            job = IntPtr.Zero;
            return started;
        }
        finally
        {
            if (processInformation.hThread != IntPtr.Zero) CloseHandle(processInformation.hThread);
            if (processInformation.hProcess != IntPtr.Zero) CloseHandle(processInformation.hProcess);
            if (standardInput != IntPtr.Zero && standardInput != INVALID_HANDLE_VALUE) CloseHandle(standardInput);
            if (standardOutput != IntPtr.Zero && standardOutput != INVALID_HANDLE_VALUE) CloseHandle(standardOutput);
            if (standardError != IntPtr.Zero && standardError != INVALID_HANDLE_VALUE) CloseHandle(standardError);
            if (attributeList != IntPtr.Zero) { DeleteProcThreadAttributeList(attributeList); Marshal.FreeHGlobal(attributeList); }
            if (jobList != IntPtr.Zero) Marshal.FreeHGlobal(jobList);
            if (handleList != IntPtr.Zero) Marshal.FreeHGlobal(handleList);
            if (job != IntPtr.Zero) CloseHandle(job);
        }
    }

    public static void Close(IntPtr job)
    {
        if (job != IntPtr.Zero && !CloseHandle(job))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "CloseHandle for delivery process job failed.");
    }
}
'@
    }
    $powershellPath = (Get-Command "powershell.exe" -ErrorAction Stop).Source
    $started = [ItlDeliveryProcessJob]::Start($powershellPath, $ArgumentList, $WorkingDirectory, $StandardOutputPath, $StandardErrorPath)
    try {
        $process = $started.Process
        $null = $process.Handle
        return [pscustomobject]@{ process = $process; jobHandle = [IntPtr]$started.JobHandle }
    } catch {
        try { [ItlDeliveryProcessJob]::Close([IntPtr]$started.JobHandle) } catch {}
        throw
    }
}

function Close-DeliveryProcessJob {
    param([IntPtr]$JobHandle, [AllowNull()][object]$Process, [string]$PriorErrorMessage = "")
    if ($JobHandle -eq [IntPtr]::Zero -or $env:OS -ne "Windows_NT") { return }
    try { [ItlDeliveryProcessJob]::Close($JobHandle) } catch {
        $closeMessage = $_.Exception.Message
        Stop-DeliveryProcessTree -Process $Process
        if ($PriorErrorMessage) {
            throw "Publication child failed: $PriorErrorMessage Additionally, its process job could not be closed: $closeMessage The owned process tree was stopped best-effort."
        }
        throw "Publication child process job could not be closed: $closeMessage The owned process tree was stopped best-effort; publication cannot continue."
    }
}

function Invoke-SourceGate {
    param([string]$Mode, [string]$WorkingRoot, [string]$TargetBaseRef = "")
    $gate = if ($script:GateScript -eq (Join-Path $script:Root "scripts\check.ps1")) { Join-Path $WorkingRoot "scripts\check.ps1" } else { $script:GateScript }
    if (-not (Test-Path -LiteralPath $gate -PathType Leaf)) { throw "Source gate was not found: $gate" }
    $arguments = @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $gate, "-Mode", $Mode)
    if ($TargetBaseRef) { $arguments += @("-BaseRef", $TargetBaseRef) }
    $contracts = @($CoverageContract | Where-Object { $_ })
    if ($contracts.Count -gt 0) { $arguments += @("-CoverageContract", ($contracts -join ",")) }
    if ($AiRulesSource) { $arguments += @("-AiRulesSource", ([System.IO.Path]::GetFullPath($AiRulesSource))) }
    if ($E2EProjectRoot) { $arguments += @("-E2EProjectRoot", ([System.IO.Path]::GetFullPath($E2EProjectRoot))) }
    if ($Mode -eq "Release") { $arguments += @("-ReleaseResumeMode", $ReleaseResumeMode) }
    $quoted = @($arguments | ForEach-Object {
        $value = [string]$_
        if ($value -notmatch '[\s"]') { $value } else { '"' + $value.Replace('"', '\"') + '"' }
    })
    $logRoot = Join-Path $WorkingRoot "build\test-results\delivery"
    New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
    $stdout = Join-Path $logRoot ("gate-$($Mode.ToLowerInvariant()).stdout.log")
    $stderr = Join-Path $logRoot ("gate-$($Mode.ToLowerInvariant()).stderr.log")
    $gateStartedAt = [DateTime]::UtcNow
    $gateStatus = "failed"; $gateError = ""; $process = $null; $processJob = [IntPtr]::Zero
    try {
        $started = Start-DeliveryProcess -ArgumentList ($quoted -join " ") -WorkingDirectory $WorkingRoot -StandardOutputPath $stdout -StandardErrorPath $stderr
        $process = $started.process
        $processJob = [IntPtr]$started.jobHandle
        Update-DeliveryOperation -Values @{ mode = $Mode; workingRoot = $WorkingRoot; gatePid = [int]$process.Id; gateProcessStartedAt = $process.StartTime.ToUniversalTime().ToString("o"); gateStatus = "running" }
        $hardSeconds = switch ($Mode) { "Targeted" { 900 } "Smoke" { 120 } "Full" { 1200 } "Develop" { 5400 } "Release" { 7200 } default { 1200 } }
        $watch = [Diagnostics.Stopwatch]::StartNew(); $lastLength = -1L; $lastProgress = [DateTime]::UtcNow
        while (-not $process.WaitForExit(5000)) {
            $length = 0L
            foreach ($path in @($stdout, $stderr)) { if (Test-Path $path) { $length += (Get-Item $path).Length } }
            if ($length -ne $lastLength) { $lastLength = $length; $lastProgress = [DateTime]::UtcNow }
            if ($watch.Elapsed.TotalSeconds -ge $hardSeconds -or ([DateTime]::UtcNow - $lastProgress).TotalMinutes -ge 15) {
                Stop-DeliveryProcessTree -Process $process
                throw "$Mode source gate exceeded its hard/no-progress budget. See $stdout and $stderr"
            }
        }
        $process.WaitForExit(); $process.Refresh(); $watch.Stop()
        if ([int]$process.ExitCode -ne 0) { throw "$Mode source gate failed with exit code $($process.ExitCode). See $stdout and $stderr" }
        if ($gate -eq (Join-Path $WorkingRoot "scripts\check.ps1")) {
            $summaryPath = Join-Path $WorkingRoot "build\test-results\local\check-summary.json"
            if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) { throw "$Mode source gate returned without an authoritative check summary." }
            $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$summary.mode -ne $Mode -or [string]$summary.status -ne "passed" -or [DateTime]::Parse([string]$summary.finishedAt).ToUniversalTime() -lt $gateStartedAt.AddSeconds(-2)) { throw "$Mode source gate did not produce a fresh passed summary. See $summaryPath" }
        }
        $gateStatus = "passed"
    } catch { $gateError = $_.Exception.Message; throw } finally {
        $jobCloseError = $null
        try { Close-DeliveryProcessJob -JobHandle $processJob -Process $process -PriorErrorMessage $gateError } catch { $jobCloseError = $_ }
        Stop-DeliveryProcessTree -Process $process
        $finishedAt = [DateTime]::UtcNow
        $historyError = $null
        try {
            $runRecordPath = Write-DeliveryRunRecord -Mode $Mode -Status $gateStatus -ErrorMessage $gateError -WorkingRoot $WorkingRoot -StartedAt $gateStartedAt -FinishedAt $finishedAt -ExitCode $(if ($process -and $process.HasExited) { [int]$process.ExitCode } else { -1 })
            Update-DeliveryOperation -Values @{ gatePid = 0; gateProcessStartedAt = ""; gateStatus = $gateStatus; gateFinishedAt = $finishedAt.ToString("o"); runRecordPath = $runRecordPath }
        }
        catch { if ($gateStatus -eq "passed") { $historyError = $_ } else { Write-Warning "Unable to persist failed gate history: $($_.Exception.Message)" } }
        if ($jobCloseError) { throw $jobCloseError }
        if ($historyError) { throw $historyError }
    }
}

function Register-SourceChange {
    Assert-CleanDeliveryWorktree
    $head = Get-GitValue -Arguments @("rev-parse", "HEAD")
    $base = if ($BaseRef) { Get-GitValue -Arguments @("rev-parse", $BaseRef) } else { Get-GitValue -Arguments @("rev-parse", "$script:Remote/develop") }
    $id = ConvertTo-QueueRefName -Value $(if ($QueueId) { $QueueId } else { Get-DefaultQueueId })
    $baseQueueRef = "$script:QueueRoot/$id/base"
    $headQueueRef = "$script:QueueRoot/$id/head"
    $oldBase = (Invoke-DeliveryGit -Arguments @("rev-parse", "--verify", $baseQueueRef) -AllowFailure).stdout.Trim()
    $oldHead = (Invoke-DeliveryGit -Arguments @("rev-parse", "--verify", $headQueueRef) -AllowFailure).stdout.Trim()
    if ([bool]$oldBase -ne [bool]$oldHead) { throw "Queue $id has incomplete base/head refs. Repair the shared queue before registering another change." }

    if ($oldHead) {
        if ((Invoke-DeliveryGit -Arguments @("merge-base", "--is-ancestor", $oldBase, $oldHead) -AllowFailure).exitCode -ne 0) {
            throw "Queue $id is corrupt: its base $oldBase is not an ancestor of its head $oldHead. Repair the shared queue before registering another change."
        }
        if ((Invoke-DeliveryGit -Arguments @("merge-base", "--is-ancestor", $oldHead, $head) -AllowFailure).exitCode -ne 0) {
            throw "Existing queue head $oldHead is not an ancestor of HEAD $head. Continue the same QueueId from its registered head or use a different QueueId."
        }
    } elseif ((Invoke-DeliveryGit -Arguments @("merge-base", "--is-ancestor", $base, $head) -AllowFailure).exitCode -ne 0) {
        throw "Queue base $base is not an ancestor of HEAD $head. Rebase the task on current develop."
    }
    $targetBase = if ($oldHead) { $oldHead } else { $base }
    if ($targetBase -eq $head) { throw "There are no commits to register after $targetBase." }

    $changed = @(Get-RepositoryGitPathList -RepositoryRoot $script:Root -Arguments @("diff", "--name-only", "-z", "$targetBase...$head", "--"))
    $testChanged = @($changed | Where-Object { ([string]$_).Replace('\', '/') -like "tests/pester/*.Tests.ps1" }).Count -gt 0
    if (-not $testChanged -and @($CoverageContract | Where-Object { $_ }).Count -eq 0) {
        throw "Executable changes without a test change must declare an existing -CoverageContract. Registration was not created."
    }
    Invoke-SourceGate -Mode "Targeted" -WorkingRoot $script:Root -TargetBaseRef $targetBase

    $queueBase = if ($oldBase) { $oldBase } else { $base }
    $commands = @()
    $commands += ("update $baseQueueRef $queueBase" + $(if ($oldBase) { " $oldBase" } else { "" }))
    $commands += ("update $headQueueRef $head" + $(if ($oldHead) { " $oldHead" } else { "" }))
    Invoke-QueueRefTransaction -Commands $commands
    return [pscustomobject]@{ status = "registered"; id = $id; base = $queueBase; head = $head; paths = $changed }
}

function New-DeliveryWorktree {
    param([string]$StartPoint, [string]$Purpose)
    $id = [guid]::NewGuid().ToString("N")
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("itl-source-$Purpose-$id")
    $branch = "itl/$Purpose-$id"
    [void](Invoke-DeliveryGit -Arguments @("worktree", "add", "--quiet", "-b", $branch, $path, $StartPoint))
    return [pscustomobject]@{ path = $path; branch = $branch }
}

function Remove-DeliveryWorktree {
    param([object]$Worktree)
    if (-not $Worktree) { return }
    $resolved = [System.IO.Path]::GetFullPath([string]$Worktree.path)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike "itl-source-*") {
        throw "Refusing to remove unexpected delivery worktree path: $resolved"
    }
    [void](Invoke-DeliveryGit -Arguments @("worktree", "remove", "--force", $resolved) -AllowFailure)
    [void](Invoke-DeliveryGit -Arguments @("branch", "-D", [string]$Worktree.branch) -AllowFailure)
}

function Invoke-WorktreeGit {
    param([string]$Root, [string[]]$Arguments, [switch]$AllowFailure)
    return Invoke-RepositoryGit -RepositoryRoot $Root -Arguments $Arguments -AllowFailure:$AllowFailure
}

function Get-DeliveryCommonGitDirectory {
    $value = Get-GitValue -Arguments @("rev-parse", "--path-format=absolute", "--git-common-dir")
    if ([IO.Path]::IsPathRooted($value)) { return [IO.Path]::GetFullPath($value) }
    return [IO.Path]::GetFullPath((Join-Path $script:Root $value))
}

function Get-DeliveryOperationLockPath {
    return Join-Path (Get-DeliveryCommonGitDirectory) "itl\delivery-operation"
}

function Test-DeliveryProcessIdentity {
    param([int]$ProcessId, [string]$StartedAt)
    if ($ProcessId -le 0 -or -not $StartedAt) { return $false }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return $false }
    try {
        $expected = [DateTime]::Parse($StartedAt).ToUniversalTime()
        return [Math]::Abs(($process.StartTime.ToUniversalTime() - $expected).TotalSeconds) -lt 2
    } catch { return $false }
}

function Read-DeliveryOperation {
    $path = Join-Path (Get-DeliveryOperationLockPath) "operation.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Write-DeliveryOperation {
    param([Parameter(Mandatory = $true)][object]$Operation)
    $root = Get-DeliveryOperationLockPath
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Delivery operation lock disappeared while it was active: $root" }
    $target = Join-Path $root "operation.json"; $temp = Join-Path $root ("operation." + [guid]::NewGuid().ToString("N") + ".tmp")
    [IO.File]::WriteAllText($temp, (($Operation | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $target -Force
}

function Get-DeliveryOperationStatus {
    $operation = Read-DeliveryOperation
    if (-not $operation) { return $null }
    $ownerAlive = Test-DeliveryProcessIdentity -ProcessId ([int]$operation.ownerPid) -StartedAt ([string]$operation.ownerProcessStartedAt)
    $gateAlive = Test-DeliveryProcessIdentity -ProcessId ([int]$operation.gatePid) -StartedAt ([string]$operation.gateProcessStartedAt)
    return [pscustomobject]@{
        id = [string]$operation.id; action = [string]$operation.action; startedAt = [string]$operation.startedAt
        ownerPid = [int]$operation.ownerPid; ownerAlive = $ownerAlive; gatePid = [int]$operation.gatePid; gateAlive = $gateAlive
        mode = [string]$operation.mode; candidatePath = [string]$operation.workingRoot; status = $(if ($ownerAlive -or $gateAlive) { "running" } else { "stale" })
    }
}

function Write-DeliveryRunRecord {
    param([string]$Mode, [string]$Status, [string]$ErrorMessage, [string]$WorkingRoot, [datetime]$StartedAt, [datetime]$FinishedAt, [int]$ExitCode)
    $runRoot = Join-Path (Get-DeliveryCommonGitDirectory) "itl\runs"; New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $summaryPath = Join-Path $WorkingRoot "build\test-results\local\check-summary.json"; $summary = $null
    if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
        try {
            $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $summary.PSObject.Properties["startedAt"] -or [DateTime]::Parse([string]$summary.startedAt).ToUniversalTime() -lt $StartedAt.AddSeconds(-2)) { $summary = $null }
        } catch { $summary = $null }
    }
    $record = [ordered]@{ schemaVersion = 1; id = [guid]::NewGuid().ToString("N"); mode = $Mode; status = $Status; exitCode = $ExitCode; startedAt = $StartedAt.ToString("o"); finishedAt = $FinishedAt.ToString("o"); durationMs = [int64]($FinishedAt - $StartedAt).TotalMilliseconds; commit = (Invoke-WorktreeGit -Root $WorkingRoot -Arguments @("rev-parse", "HEAD")).stdout.Trim(); tree = (Invoke-WorktreeGit -Root $WorkingRoot -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim(); error = $ErrorMessage; tests = $(if ($summary) { $summary.tests } else { $null }); stages = $(if ($summary) { @($summary.stages | Sort-Object durationMs -Descending | Select-Object -First 10) } else { @() }) }
    $name = "{0}-{1}-{2}.json" -f $StartedAt.ToString("yyyyMMdd-HHmmss-fff"), $Mode.ToLowerInvariant(), $record.id; $target = Join-Path $runRoot $name; $temp = "$target.tmp"
    [IO.File]::WriteAllText($temp, (($record | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false)); Move-Item -LiteralPath $temp -Destination $target
    return $target
}

function Get-DeliveryRunHistory {
    param([int]$Limit = 20)
    $runRoot = Join-Path (Get-DeliveryCommonGitDirectory) "itl\runs"; if (-not (Test-Path -LiteralPath $runRoot)) { return [pscustomobject]@{ root = $runRoot; count = 0; totalDurationMs = 0; byMode = @(); lastRuns = @() } }
    $runs = @(Get-ChildItem -LiteralPath $runRoot -File -Filter "*.json" | Sort-Object Name -Descending | ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} })
    $byMode = @($runs | Group-Object mode | Sort-Object Name | ForEach-Object { [pscustomobject]@{ mode = $_.Name; count = $_.Count; durationMs = [int64](($_.Group | Measure-Object durationMs -Sum).Sum) } })
    return [pscustomobject]@{ root = $runRoot; count = $runs.Count; totalDurationMs = [int64](($runs | Measure-Object -Property durationMs -Sum).Sum); byMode = $byMode; lastRuns = @($runs | Select-Object -First $Limit) }
}

function Get-DeliveryQualificationCachePath {
    param([Parameter(Mandatory = $true)][string]$Tree)
    if ($Tree -notmatch '^[a-f0-9]{40}$') { throw "Invalid candidate tree for qualification cache: $Tree" }
    return Join-Path (Get-DeliveryCommonGitDirectory) ("itl\qualifications\" + $Tree)
}

function Save-DeliveryQualification {
    param([Parameter(Mandatory = $true)][string]$CandidateRoot, [Parameter(Mandatory = $true)][string]$Tree)
    $source = Join-Path $CandidateRoot "build\test-results\qualification"
    foreach ($name in @("full.json", "develop.json", "develop-e2e-summary.json")) {
        if (-not (Test-Path -LiteralPath (Join-Path $source $name) -PathType Leaf)) { throw "Develop gate did not create reusable qualification file '$name'." }
    }
    $target = Get-DeliveryQualificationCachePath -Tree $Tree
    $parent = Split-Path -Parent $target
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $staging = Join-Path $parent ("." + $Tree + "." + [guid]::NewGuid().ToString("N") + ".tmp")
    New-Item -ItemType Directory -Path $staging | Out-Null
    $routeReports = @("develop-e2e-upgrade.json", "develop-e2e-fresh.json")
    try {
        Copy-Item -LiteralPath (Join-Path $source "full.json"), (Join-Path $source "develop.json"), (Join-Path $source "develop-e2e-summary.json") -Destination $staging -Force
        if (Test-Path -LiteralPath (Join-Path $source "pester.xml") -PathType Leaf) { Copy-Item -LiteralPath (Join-Path $source "pester.xml") -Destination $staging -Force }
        foreach ($name in $routeReports) {
            if (Test-Path -LiteralPath (Join-Path $source $name) -PathType Leaf) { Copy-Item -LiteralPath (Join-Path $source $name) -Destination $staging -Force }
        }
        if (-not (Test-Path -LiteralPath $target)) { Move-Item -LiteralPath $staging -Destination $target }
        else {
            # Older exact-tree cache entries remain valid without route reports.
            # When a later Develop run produces route-aware schema 3 evidence,
            # refresh the complete proof set together instead of mixing new
            # route reports with an older develop.json for the same tree.
            $availableRoutes = @($routeReports | Where-Object { Test-Path -LiteralPath (Join-Path $staging $_) -PathType Leaf })
            if ($availableRoutes.Count -gt 0) {
                $backup = Join-Path $parent ("." + $Tree + "." + [guid]::NewGuid().ToString("N") + ".old")
                Move-Item -LiteralPath $target -Destination $backup
                try { Move-Item -LiteralPath $staging -Destination $target } catch { Move-Item -LiteralPath $backup -Destination $target; throw }
                Remove-Item -LiteralPath $backup -Recurse -Force
            }
        }
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
    return $target
}

function Restore-DeliveryQualification {
    param([Parameter(Mandatory = $true)][string]$CandidateRoot, [Parameter(Mandatory = $true)][string]$Tree)
    $source = Get-DeliveryQualificationCachePath -Tree $Tree
    foreach ($name in @("full.json", "develop.json", "develop-e2e-summary.json")) {
        if (-not (Test-Path -LiteralPath (Join-Path $source $name) -PathType Leaf)) { return $false }
    }
    $target = Join-Path $CandidateRoot "build\test-results\qualification"
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Get-ChildItem -LiteralPath $source -File | Copy-Item -Destination $target -Force
    return $true
}

function Archive-StaleDeliveryOperation {
    param([Parameter(Mandatory = $true)][object]$Operation)
    $workingRoot = [string]$Operation.workingRoot
    $summary = $null
    if ($workingRoot) {
        $summaryPath = Join-Path $workingRoot "build\test-results\local\check-summary.json"
        if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
            try { $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $summary = $null }
        }
    }
    if ($summary -and -not [string]$Operation.runRecordPath -and (Test-Path -LiteralPath $workingRoot -PathType Container)) {
        $startedAt = [DateTime]::Parse([string]$summary.startedAt).ToUniversalTime(); $finishedAt = [DateTime]::Parse([string]$summary.finishedAt).ToUniversalTime()
        $status = if ([string]$summary.status -eq "passed") { "passed" } else { "failed" }
        $error = if ($status -eq "passed") { "" } else { "Recovered after the delivery wrapper ended before recording the completed gate: $([string]$summary.error)" }
        $Operation.runRecordPath = Write-DeliveryRunRecord -Mode ([string]$summary.mode) -Status $status -ErrorMessage $error -WorkingRoot $workingRoot -StartedAt $startedAt -FinishedAt $finishedAt -ExitCode $(if ($status -eq "passed") { 0 } else { 1 })
        if ($status -eq "passed" -and [string]$summary.mode -eq "Develop") {
            $tree = (Invoke-WorktreeGit -Root $workingRoot -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim()
            [void](Save-DeliveryQualification -CandidateRoot $workingRoot -Tree $tree)
        }
    }
    $Operation | Add-Member -NotePropertyName recoveredAt -NotePropertyValue ([DateTime]::UtcNow.ToString("o")) -Force
    $archiveRoot = Join-Path (Get-DeliveryCommonGitDirectory) "itl\operations"; New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $archiveRoot ("$([string]$Operation.id).json")), (($Operation | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Remove-Item -LiteralPath (Get-DeliveryOperationLockPath) -Recurse -Force
}

function Enter-DeliveryOperation {
    param([Parameter(Mandatory = $true)][string]$Action)
    $lockPath = Get-DeliveryOperationLockPath
    if (Test-Path -LiteralPath $lockPath -PathType Container) {
        $status = Get-DeliveryOperationStatus
        if ($status -and ($status.ownerAlive -or $status.gateAlive)) {
            throw "Delivery operation '$($status.action)' is already active (owner PID $($status.ownerPid), gate PID $($status.gatePid), candidate '$($status.candidatePath)'). Wait for it and inspect Status before retrying."
        }
        $stale = Read-DeliveryOperation
        if ($stale) { Archive-StaleDeliveryOperation -Operation $stale }
        else {
            $lockAge = ([DateTime]::UtcNow - (Get-Item -LiteralPath $lockPath).LastWriteTimeUtc).TotalMinutes
            if ($lockAge -lt 2) { throw "Another delivery operation is acquiring the shared lock. Inspect source-delivery Status before retrying." }
            Remove-Item -LiteralPath $lockPath -Recurse -Force
        }
    }
    try { New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null } catch { throw "Another delivery operation acquired the shared lock. Inspect source-delivery Status before retrying." }
    $owner = Get-Process -Id $PID
    $operation = [pscustomobject]@{
        schemaVersion = 1; id = [guid]::NewGuid().ToString("N"); action = $Action; startedAt = [DateTime]::UtcNow.ToString("o")
        ownerPid = $PID; ownerProcessStartedAt = $owner.StartTime.ToUniversalTime().ToString("o")
        mode = ""; workingRoot = ""; gatePid = 0; gateProcessStartedAt = ""; gateStatus = "pending"; runRecordPath = ""
    }
    Write-DeliveryOperation -Operation $operation
    $script:ActiveOperation = $operation
    return $operation
}

function Update-DeliveryOperation {
    param([hashtable]$Values)
    if (-not $script:ActiveOperation) { return }
    foreach ($key in $Values.Keys) { $script:ActiveOperation | Add-Member -NotePropertyName $key -NotePropertyValue $Values[$key] -Force }
    Write-DeliveryOperation -Operation $script:ActiveOperation
}

function Exit-DeliveryOperation {
    if (-not $script:ActiveOperation) { return }
    $current = Read-DeliveryOperation
    if ($current -and [string]$current.id -eq [string]$script:ActiveOperation.id) { Remove-Item -LiteralPath (Get-DeliveryOperationLockPath) -Recurse -Force }
    $script:ActiveOperation = $null
}

function Add-QueuedRangesToCandidate {
    param([string]$CandidateRoot, [object[]]$Entries)
    foreach ($entry in @($Entries)) {
        $already = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("merge-base", "--is-ancestor", [string]$entry.head, "HEAD") -AllowFailure
        if ($already.exitCode -eq 0) { continue }
        $result = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("merge", "--no-edit", [string]$entry.head) -AllowFailure
        if ($result.exitCode -ne 0) {
            [void](Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("merge", "--abort") -AllowFailure)
            throw "Queued range '$($entry.id)' conflicts with the develop candidate at $($entry.head). Resolve it in its source task and register again."
        }
    }
}

function Clear-PublishedQueueEntries {
    param([string]$PublishedCommit)
    $commands = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @(Get-QueueEntries)) {
        $reachable = Invoke-DeliveryGit -Arguments @("merge-base", "--is-ancestor", [string]$entry.head, $PublishedCommit) -AllowFailure
        if ($reachable.exitCode -eq 0) {
            $commands.Add("delete $script:QueueRoot/$($entry.id)/base $($entry.base)") | Out-Null
            $commands.Add("delete $script:QueueRoot/$($entry.id)/head $($entry.head)") | Out-Null
        }
    }
    if ($commands.Count -gt 0) { Invoke-QueueRefTransaction -Commands @($commands) }
}

function Sync-LocalDevelopAfterPublish {
    $branch = Get-GitValue -Arguments @("branch", "--show-current")
    if ($branch -ne "develop") { return }
    Assert-CleanDeliveryWorktree
    [void](Invoke-DeliveryGit -Arguments @("fetch", $script:Remote, "develop"))
    $ff = Invoke-DeliveryGit -Arguments @("merge", "--ff-only", "$script:Remote/develop") -AllowFailure
    if ($ff.exitCode -ne 0) { throw "Remote develop was published, but local develop could not fast-forward. Inspect local-only commits before continuing." }
}

function ConvertTo-DeliveryNativeArgument {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Get-DeliveryGitHubRepository {
    param([string]$CandidateRoot)
    $remoteUrl = (Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("remote", "get-url", $script:Remote)).stdout.Trim()
    $match = [regex]::Match($remoteUrl, '^(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)(?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$')
    if (-not $match.Success) { throw "Component publication requires $($script:Remote) to be an exact github.com repository URL; actual='$remoteUrl'." }
    return [pscustomobject]@{ owner = $match.Groups["owner"].Value; repo = $match.Groups["repo"].Value; slug = ($match.Groups["owner"].Value + "/" + $match.Groups["repo"].Value) }
}

function Get-DeliveryRemoteAssetState {
    param([string]$Url, [string]$ExpectedSha256, [int]$Attempts = 1)
    $lastMissing = $false
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $downloadPath = Join-Path ([IO.Path]::GetTempPath()) ("itl-component-download-" + [guid]::NewGuid().ToString("N") + ".bin")
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $downloadPath -TimeoutSec 300
            $actual = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -cne $ExpectedSha256) {
                throw "Published Vanessa asset SHA256 mismatch. expected='$ExpectedSha256'; actual='$actual'; url='$Url'. Refusing to overwrite an immutable asset."
            }
            return [pscustomobject]@{ status = "matched"; sha256 = $actual }
        } catch {
            if ($_.Exception.Message -like "Published Vanessa asset SHA256 mismatch.*") { throw }
            $statusCode = 0
            try { if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode } } catch {}
            if ($statusCode -ne 404) {
                throw "Unable to verify the immutable Vanessa asset without mutation: $($_.Exception.Message)"
            }
            $lastMissing = $true
            if ($attempt -lt $Attempts) { Start-Sleep -Seconds ([Math]::Min(2 * $attempt, 10)) }
        } finally {
            Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($lastMissing) { return [pscustomobject]@{ status = "missing"; sha256 = "" } }
    throw "Unable to determine the immutable Vanessa asset state: $Url"
}

function Get-DeliveryExactVanessaCandidate {
    param([string]$CandidateRoot, [object]$Lock)
    $expected = ([string]$Lock.sha256).ToLowerInvariant()
    $override = [Environment]::GetEnvironmentVariable("ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE", "Process")
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $path = [IO.Path]::GetFullPath($override)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE does not exist: $path" }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne $expected) { throw "Vanessa source-build override SHA256 mismatch. expected='$expected'; actual='$actual'." }
        return $path
    }

    $folder = ([string]$Lock.compatibilityVersion) + "-" + ([string]$Lock.downstreamRevision)
    $relative = Join-Path ("build\third-party\vanessa-automation\" + $folder) ([string]$Lock.assetName)
    foreach ($root in @($CandidateRoot, $script:Root) | Select-Object -Unique) {
        $path = Join-Path $root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne $expected) { throw "Canonical Vanessa candidate SHA256 mismatch. expected='$expected'; actual='$actual'; path='$path'." }
        return $path
    }
    throw "The immutable Vanessa URL is absent and no exact local candidate is available. Set ITL_VANESSA_AUTOMATION_SOURCE_BUILD_ARCHIVE or place the locked asset at the canonical candidate path."
}

function Get-DeliveryRemoteAnnotatedTagCommit {
    param([string]$CandidateRoot, [string]$Tag)
    $result = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("ls-remote", "--tags", $script:Remote, "refs/tags/$Tag", "refs/tags/$Tag^{}") -AllowFailure
    if ($result.exitCode -ne 0) { throw "Unable to inspect remote component tag '$Tag'." }
    $direct = ""; $peeled = ""
    foreach ($line in @($result.stdout -split "`r?`n" | Where-Object { $_ })) {
        $parts = $line -split "\s+", 2
        if ($parts.Count -ne 2) { continue }
        if ($parts[1] -eq "refs/tags/$Tag") { $direct = $parts[0] }
        if ($parts[1] -eq "refs/tags/$Tag^{}") { $peeled = $parts[0] }
    }
    if (-not $direct) { return "" }
    if (-not $peeled) { throw "Remote component tag '$Tag' is lightweight; an immutable annotated tag is required." }
    return $peeled
}

function Invoke-DeliveryGitHubCli {
    param([string[]]$Arguments, [switch]$AllowFailure)
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) { throw "GitHub CLI is required to finalize an unpublished Vanessa component." }
    $output = @(& $gh.Source @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) { throw "gh $($Arguments -join ' ') failed: $($output -join '; ')" }
    return [pscustomobject]@{ exitCode = [int]$exitCode; output = $output; text = ($output -join "`n") }
}

function Save-DeliveryComponentPublicationEvidence {
    param([string]$CandidateCommit, [object]$Evidence)
    $root = Join-Path (Get-DeliveryCommonGitDirectory) "itl\component-publications\$CandidateCommit"
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    [IO.File]::WriteAllText((Join-Path $root "vanessa-automation.json"), (($Evidence | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

function Invoke-VanessaComponentPublicationFinalize {
    param([string]$CandidateRoot, [string]$CandidateCommit)
    $lockPath = Join-Path $CandidateRoot "templates\dependency-lock.json"
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { throw "Component finalization requires templates/dependency-lock.json in the exact candidate." }
    $lock = (Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies.vanessaAutomation
    foreach ($field in @("releaseTag", "url", "assetName", "sha256", "compatibilityVersion", "downstreamRevision")) {
        $property = if ($null -eq $lock) { $null } else { $lock.PSObject.Properties[$field] }
        if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { throw "Vanessa component lock is missing '$field'." }
    }
    $expectedSha = ([string]$lock.sha256).ToLowerInvariant()
    if ($expectedSha -notmatch '^[a-f0-9]{64}$') { throw "Vanessa component lock has an invalid SHA256: $expectedSha" }
    $repository = Get-DeliveryGitHubRepository -CandidateRoot $CandidateRoot
    $uri = [Uri]([string]$lock.url)
    $urlMatch = [regex]::Match($uri.AbsolutePath, '^/(?<owner>[^/]+)/(?<repo>[^/]+)/releases/download/(?<tag>[^/]+)/(?<asset>[^/]+)$')
    if ($uri.Scheme -ne "https" -or $uri.Host -ne "github.com" -or -not $urlMatch.Success) { throw "Vanessa immutable URL is not an exact GitHub release asset URL: $($lock.url)" }
    $urlOwner = [Uri]::UnescapeDataString($urlMatch.Groups["owner"].Value)
    $urlRepo = [Uri]::UnescapeDataString($urlMatch.Groups["repo"].Value)
    $urlTag = [Uri]::UnescapeDataString($urlMatch.Groups["tag"].Value)
    $urlAsset = [Uri]::UnescapeDataString($urlMatch.Groups["asset"].Value)
    if ($urlOwner -cne $repository.owner -or $urlRepo -cne $repository.repo -or $urlTag -cne [string]$lock.releaseTag -or $urlAsset -cne [string]$lock.assetName) {
        throw "Vanessa immutable URL owner/repo/tag/asset does not match origin, releaseTag, and assetName."
    }

    $remote = Get-DeliveryRemoteAssetState -Url ([string]$lock.url) -ExpectedSha256 $expectedSha
    $mutated = $false
    if ($remote.status -eq "missing") {
        if (-not $RequireRelease) { throw "The locked Vanessa asset is not published. Component upload requires PublishDevelop -RequireRelease so the exact candidate passes Release first." }
        $candidatePath = Get-DeliveryExactVanessaCandidate -CandidateRoot $CandidateRoot -Lock $lock
        $remoteTagCommit = Get-DeliveryRemoteAnnotatedTagCommit -CandidateRoot $CandidateRoot -Tag ([string]$lock.releaseTag)
        if ($remoteTagCommit) {
            if ($remoteTagCommit -cne $CandidateCommit) { throw "Remote component tag '$($lock.releaseTag)' points to '$remoteTagCommit', not exact candidate '$CandidateCommit'. Refusing to repoint it." }
        } else {
            $localTag = "refs/tags/$($lock.releaseTag)"
            $localTagType = (Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("cat-file", "-t", $localTag) -AllowFailure).stdout.Trim()
            if ($localTagType) {
                $localTagCommit = (Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("rev-parse", "$localTag^{}") -AllowFailure).stdout.Trim()
                if ($localTagType -cne "tag" -or $localTagCommit -cne $CandidateCommit) { throw "Local component tag '$($lock.releaseTag)' is not an annotated tag for exact candidate '$CandidateCommit'." }
            } else {
                [void](Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("tag", "-a", [string]$lock.releaseTag, $CandidateCommit, "-m", "Vanessa Automation $($lock.downstreamRevision)"))
            }
            $tagPush = Invoke-WorktreeGit -Root $CandidateRoot -Arguments @("push", $script:Remote, $localTag) -AllowFailure
            if ($tagPush.exitCode -ne 0) {
                $racedTagCommit = Get-DeliveryRemoteAnnotatedTagCommit -CandidateRoot $CandidateRoot -Tag ([string]$lock.releaseTag)
                if ($racedTagCommit -cne $CandidateCommit) { throw "Unable to publish the immutable component tag '$($lock.releaseTag)' safely." }
            }
            $mutated = $true
        }

        $releaseView = Invoke-DeliveryGitHubCli -Arguments @("release", "view", [string]$lock.releaseTag, "--repo", $repository.slug, "--json", "assets") -AllowFailure
        if ($releaseView.exitCode -ne 0) {
            if ($releaseView.text -notmatch '(?i)(release not found|HTTP 404|not found)') { throw "Unable to inspect GitHub Release '$($lock.releaseTag)': $($releaseView.text)" }
            [void](Invoke-DeliveryGitHubCli -Arguments @("release", "create", [string]$lock.releaseTag, "--repo", $repository.slug, "--verify-tag", "--title", [string]$lock.releaseTag, "--notes", "Immutable Vanessa Automation component $($lock.downstreamRevision)."))
            $mutated = $true
            $releaseView = Invoke-DeliveryGitHubCli -Arguments @("release", "view", [string]$lock.releaseTag, "--repo", $repository.slug, "--json", "assets")
        }
        $release = $releaseView.text | ConvertFrom-Json
        $assetExists = @($release.assets | Where-Object { [string]$_.name -ceq [string]$lock.assetName }).Count -gt 0
        if (-not $assetExists) {
            $uploadRoot = Join-Path ([IO.Path]::GetTempPath()) ("itl-component-upload-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Force -Path $uploadRoot | Out-Null
            try {
                $uploadPath = Join-Path $uploadRoot ([string]$lock.assetName)
                Copy-Item -LiteralPath $candidatePath -Destination $uploadPath
                [void](Invoke-DeliveryGitHubCli -Arguments @("release", "upload", [string]$lock.releaseTag, $uploadPath, "--repo", $repository.slug))
                $mutated = $true
            } finally { Remove-Item -LiteralPath $uploadRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $remote = Get-DeliveryRemoteAssetState -Url ([string]$lock.url) -ExpectedSha256 $expectedSha -Attempts 6
        if ($remote.status -ne "matched") { throw "The Vanessa component was finalized, but its immutable URL is still unavailable. The queue is preserved for a safe retry." }
    }

    $evidence = [ordered]@{
        schemaVersion = 1; status = "passed"; component = "vanessaAutomation"; candidateCommit = $CandidateCommit
        releaseTag = [string]$lock.releaseTag; url = [string]$lock.url; assetName = [string]$lock.assetName; sha256 = $expectedSha
        githubRepository = $repository.slug; githubMutated = $mutated; verifiedAt = [DateTime]::UtcNow.ToString("o")
    }
    Save-DeliveryComponentPublicationEvidence -CandidateCommit $CandidateCommit -Evidence $evidence
    return [pscustomobject]$evidence
}

function Invoke-ComponentPublicationFinalizer {
    param([string]$CandidateRoot, [string]$CandidateCommit)
    if (-not $script:ComponentFinalizerScript) { return Invoke-VanessaComponentPublicationFinalize -CandidateRoot $CandidateRoot -CandidateCommit $CandidateCommit }
    if (-not (Test-Path -LiteralPath $script:ComponentFinalizerScript -PathType Leaf)) { throw "Component finalizer seam was not found: $($script:ComponentFinalizerScript)" }
    $arguments = @(
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script:ComponentFinalizerScript,
        "-RepositoryRoot", $CandidateRoot, "-SourceRepositoryRoot", $script:Root, "-CandidateCommit", $CandidateCommit, "-Remote", $script:Remote
    )
    if ($RequireRelease) { $arguments += "-ReleaseQualified" }
    $quoted = @($arguments | ForEach-Object { ConvertTo-DeliveryNativeArgument -Value ([string]$_) })
    $logRoot = Join-Path $CandidateRoot "build\test-results\delivery"
    New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
    $stdout = Join-Path $logRoot "component-finalizer.stdout.log"; $stderr = Join-Path $logRoot "component-finalizer.stderr.log"
    $process = $null; $processJob = [IntPtr]::Zero; $finalizerError = ""
    try {
        $started = Start-DeliveryProcess -ArgumentList ($quoted -join " ") -WorkingDirectory $CandidateRoot -StandardOutputPath $stdout -StandardErrorPath $stderr
        $process = $started.process
        $processJob = [IntPtr]$started.jobHandle
        while (-not $process.WaitForExit(1000)) {}
        $process.WaitForExit(); $process.Refresh()
        if ([int]$process.ExitCode -ne 0) {
            $detail = if (Test-Path -LiteralPath $stderr -PathType Leaf) { (Get-Content -LiteralPath $stderr -Raw -Encoding UTF8).Trim() } else { "" }
            throw "Component publication finalizer failed with exit code $($process.ExitCode). $detail"
        }
    } catch {
        $finalizerError = $_.Exception.Message
        throw
    } finally {
        $jobCloseError = $null
        try { Close-DeliveryProcessJob -JobHandle $processJob -Process $process -PriorErrorMessage $finalizerError } catch { $jobCloseError = $_ }
        Stop-DeliveryProcessTree -Process $process
        if ($jobCloseError) { throw $jobCloseError }
    }
    return [pscustomobject]@{ status = "passed"; component = "test-seam"; candidateCommit = $CandidateCommit }
}

function Publish-AccumulatedDevelop {
    Assert-CleanDeliveryWorktree
    [void](Invoke-DeliveryGit -Arguments @("fetch", $script:Remote, "develop"))
    $remoteBefore = Get-GitValue -Arguments @("rev-parse", "$script:Remote/develop")
    $entries = @(Get-QueueEntries)
    if ($entries.Count -eq 0) { throw "There are no registered develop changes to publish." }

    $worktree = $null
    $deliverySucceeded = $false
    try {
        $worktree = New-DeliveryWorktree -StartPoint "$script:Remote/develop" -Purpose "publish-develop"
        Add-QueuedRangesToCandidate -CandidateRoot $worktree.path -Entries $entries
        $candidateTree = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim()
        $exactDevelopQualificationRestored = Restore-DeliveryQualification -CandidateRoot $worktree.path -Tree $candidateTree
        if (-not $exactDevelopQualificationRestored) {
            $baselineTree = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "$remoteBefore^{tree}")).stdout.Trim()
            [void](Restore-DeliveryQualification -CandidateRoot $worktree.path -Tree $baselineTree)
        }
        # Always enter Develop, even when exact proof was restored. Its static
        # and journey checkpoints make this a cheap resume while readiness
        # recomputes the mutable stand/runtime identity before optional Release.
        Invoke-SourceGate -Mode "Develop" -WorkingRoot $worktree.path -TargetBaseRef $remoteBefore
        [void](Save-DeliveryQualification -CandidateRoot $worktree.path -Tree $candidateTree)
        if ($RequireRelease) {
            Invoke-SourceGate -Mode "Release" -WorkingRoot $worktree.path
            [void](Save-DeliveryQualification -CandidateRoot $worktree.path -Tree $candidateTree)
        }

        $candidate = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD")).stdout.Trim()
        $componentPublication = Invoke-ComponentPublicationFinalizer -CandidateRoot $worktree.path -CandidateCommit $candidate
        $push = Invoke-WorktreeGit -Root $worktree.path -Arguments @("push", $script:Remote, "HEAD:refs/heads/develop") -AllowFailure
        if ($push.exitCode -ne 0) { throw "origin/develop changed or rejected the fast-forward push. The queue is preserved; rebuild the candidate from the new remote head." }
        $remoteAfter = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("ls-remote", $script:Remote, "refs/heads/develop")).stdout.Split([char]9)[0].Trim()
        if ($remoteAfter -ne $candidate) { throw "Published develop verification failed: expected $candidate, remote reports $remoteAfter." }
        Clear-PublishedQueueEntries -PublishedCommit $candidate
        Sync-LocalDevelopAfterPublish
        $deliverySucceeded = $true
        return [pscustomobject]@{ status = "published"; branch = "develop"; commit = $candidate; tree = $candidateTree; releaseQualified = [bool]$RequireRelease; componentPublication = $componentPublication }
    } finally {
        $customGate = $script:GateScript -ne (Join-Path $script:Root "scripts\check.ps1")
        if ($deliverySucceeded -or $customGate) { Remove-DeliveryWorktree -Worktree $worktree }
        elseif ($worktree) { Write-Warning "Develop candidate was preserved for diagnosis and retry: $($worktree.path) (branch $($worktree.branch)). The queue is unchanged." }
    }
}

function Publish-ReleaseVersion {
    param([string]$Commit)
    if (-not $Version) { return }
    if ($Version -notmatch '^itl-workflow-v\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') { throw "Version must look like itl-workflow-v1.2.3." }
    [void](Invoke-DeliveryGit -Arguments @("tag", "-a", $Version, $Commit, "-m", "ITL workflow $Version"))
    [void](Invoke-DeliveryGit -Arguments @("push", $script:Remote, "refs/tags/$Version"))
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) { throw "Tag $Version was published, but GitHub CLI is unavailable; create the GitHub Release explicitly." }
    & $gh.Source release create $Version --verify-tag --title $Version --generate-notes
    if ($LASTEXITCODE -ne 0) { throw "Tag $Version was published, but GitHub Release creation failed." }
}

function Assert-ReleaseVersionRequest {
    if (-not $Version) { return }
    if ($Version -notmatch '^itl-workflow-v\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') { throw "Version must look like itl-workflow-v1.2.3." }
    if ((Invoke-DeliveryGit -Arguments @("rev-parse", "--verify", "refs/tags/$Version") -AllowFailure).exitCode -eq 0) { throw "Local tag already exists: $Version" }
    if ((Invoke-DeliveryGit -Arguments @("ls-remote", "--exit-code", "--tags", $script:Remote, "refs/tags/$Version") -AllowFailure).exitCode -eq 0) { throw "Remote tag already exists: $Version" }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI is required before a versioned master release can start." }
}

function Release-DevelopToMaster {
    Assert-ReleaseVersionRequest
    Assert-CleanDeliveryWorktree
    if (@(Get-QueueEntries).Count -gt 0) { throw "ReleaseMaster requires an empty develop queue. Publish accumulated develop changes first." }
    [void](Invoke-DeliveryGit -Arguments @("fetch", $script:Remote, "develop", "master"))
    $localDevelop = Get-GitValue -Arguments @("rev-parse", "develop")
    $remoteDevelop = Get-GitValue -Arguments @("rev-parse", "$script:Remote/develop")
    $remoteMaster = Get-GitValue -Arguments @("rev-parse", "$script:Remote/master")
    if ($localDevelop -ne $remoteDevelop) { throw "Local develop must equal origin/develop before ReleaseMaster." }

    $worktree = $null
    $deliverySucceeded = $false
    try {
        $worktree = New-DeliveryWorktree -StartPoint "$script:Remote/develop" -Purpose "release-master"
        $masterAncestor = Invoke-WorktreeGit -Root $worktree.path -Arguments @("merge-base", "--is-ancestor", "$script:Remote/master", "HEAD") -AllowFailure
        if ($masterAncestor.exitCode -ne 0) {
            $merge = Invoke-WorktreeGit -Root $worktree.path -Arguments @("merge", "--no-ff", "--no-edit", "$script:Remote/master") -AllowFailure
            if ($merge.exitCode -ne 0) {
                [void](Invoke-WorktreeGit -Root $worktree.path -Arguments @("merge", "--abort") -AllowFailure)
                throw "origin/master conflicts with develop. Resolve the release reconciliation on develop and publish it first."
            }
        }
        $candidateTree = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD^{tree}")).stdout.Trim()
        [void](Restore-DeliveryQualification -CandidateRoot $worktree.path -Tree $candidateTree)
        Invoke-SourceGate -Mode "Develop" -WorkingRoot $worktree.path -TargetBaseRef $remoteDevelop
        [void](Save-DeliveryQualification -CandidateRoot $worktree.path -Tree $candidateTree)
        Invoke-SourceGate -Mode "Release" -WorkingRoot $worktree.path
        $candidate = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "HEAD")).stdout.Trim()
        foreach ($oldHead in @($remoteDevelop, $remoteMaster)) {
            if ((Invoke-WorktreeGit -Root $worktree.path -Arguments @("merge-base", "--is-ancestor", $oldHead, $candidate) -AllowFailure).exitCode -ne 0) {
                throw "Release candidate does not contain both fetched remote branch histories. Nothing was published."
            }
        }
        $push = Invoke-WorktreeGit -Root $worktree.path -Arguments @("push", "--atomic", $script:Remote, "HEAD:refs/heads/develop", "HEAD:refs/heads/master") -AllowFailure
        if ($push.exitCode -ne 0) { throw "Release candidate passed, but the atomic develop/master fast-forward push was rejected. Neither branch was published and no force push was attempted." }
        foreach ($branch in @("develop", "master")) {
            $remoteCommit = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("ls-remote", $script:Remote, "refs/heads/$branch")).stdout.Split([char]9)[0].Trim()
            if ($remoteCommit -ne $candidate) { throw "Remote $branch verification failed after release." }
            $remoteTree = (Invoke-WorktreeGit -Root $worktree.path -Arguments @("rev-parse", "$remoteCommit^{tree}")).stdout.Trim()
            if ($remoteTree -ne $candidateTree) { throw "Remote $branch tree verification failed after release." }
        }
        Publish-ReleaseVersion -Commit $candidate
        Sync-LocalDevelopAfterPublish
        $deliverySucceeded = $true
        return [pscustomobject]@{ status = "released"; commit = $candidate; tree = $candidateTree; version = $Version }
    } finally {
        $customGate = $script:GateScript -ne (Join-Path $script:Root "scripts\check.ps1")
        if ($deliverySucceeded -or $customGate) { Remove-DeliveryWorktree -Worktree $worktree }
        elseif ($worktree) { Write-Warning "Release candidate was preserved for diagnosis and retry: $($worktree.path) (branch $($worktree.branch)). No force push was attempted." }
    }
}

[void](Invoke-DeliveryGit -Arguments @("rev-parse", "--git-dir"))
if ($RequireRelease -and $Action -ne "PublishDevelop") {
    throw "-RequireRelease is valid only with -Action PublishDevelop."
}
$script:ActiveOperation = $null
try {
    if ($Action -in @("PublishDevelop", "ReleaseMaster")) { [void](Enter-DeliveryOperation -Action $Action) }
    $result = switch ($Action) {
        "RegisterChange" { Register-SourceChange }
        "Status" { [pscustomobject]@{ status = "ok"; queue = @(Get-QueueEntries); activeOperation = (Get-DeliveryOperationStatus); runHistory = (Get-DeliveryRunHistory) } }
        "PublishDevelop" { Publish-AccumulatedDevelop }
        "ReleaseMaster" { Release-DevelopToMaster }
    }
    $result | ConvertTo-Json -Depth 8
} finally {
    Exit-DeliveryOperation
}
