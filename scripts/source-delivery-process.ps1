# Owned publication child processes and source-gate execution.

function ConvertTo-DeliveryUtcDateTime {
    param([Parameter(Mandatory = $true)][AllowNull()][object]$Value)

    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).UtcDateTime }
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime() }
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "Delivery timestamp must be a DateTime, DateTimeOffset, or round-trip string."
    }
    return [DateTimeOffset]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).UtcDateTime
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
using System.Collections;
using System.Collections.Generic;
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
    private const UInt32 CREATE_UNICODE_ENVIRONMENT = 0x00000400;
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

    private static IntPtr CreateEnvironmentWithout(string excludedName)
    {
        SortedDictionary<string, string> variables = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables())
        {
            string name = Convert.ToString(entry.Key);
            if (!String.Equals(name, excludedName, StringComparison.OrdinalIgnoreCase))
                variables[name] = Convert.ToString(entry.Value);
        }
        StringBuilder block = new StringBuilder();
        foreach (KeyValuePair<string, string> variable in variables)
            block.Append(variable.Key).Append('=').Append(variable.Value).Append('\0');
        block.Append('\0');
        return Marshal.StringToHGlobalUni(block.ToString());
    }

    public static StartedProcess Start(string executable, string arguments, string workingDirectory, string standardOutputPath, string standardErrorPath, bool resetPowerShellModulePath)
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
        IntPtr environment = IntPtr.Zero;
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
            UInt32 creationFlags = EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW | CREATE_SUSPENDED;
            if (resetPowerShellModulePath)
            {
                environment = CreateEnvironmentWithout("PSModulePath");
                creationFlags |= CREATE_UNICODE_ENVIRONMENT;
            }
            if (!CreateProcess(executable, commandLine, IntPtr.Zero, IntPtr.Zero, true, creationFlags, environment, workingDirectory, ref startupInfo, out processInformation))
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
            if (environment != IntPtr.Zero) Marshal.FreeHGlobal(environment);
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
    # Native CreateProcess would pass PowerShell Core's PSModulePath through
    # unchanged. Omit it so Windows PowerShell rebuilds its own module roots.
    $resetModulePathForWindowsPowerShell = [string]$PSVersionTable.PSEdition -eq "Core"
    $started = [ItlDeliveryProcessJob]::Start($powershellPath, $ArgumentList, $WorkingDirectory, $StandardOutputPath, $StandardErrorPath, $resetModulePathForWindowsPowerShell)
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
        $hardSeconds = switch ($Mode) { "Targeted" { 900 } "Smoke" { 120 } "Full" { 1300 } "Develop" { 5400 } "Release" { 7200 } default { 1200 } }
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
            if ([string]$summary.mode -ne $Mode -or [string]$summary.status -ne "passed" -or (ConvertTo-DeliveryUtcDateTime -Value $summary.finishedAt) -lt $gateStartedAt.AddSeconds(-2)) { throw "$Mode source gate did not produce a fresh passed summary. See $summaryPath" }
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

function Get-DeliveryOperationLockPath {
    return Join-Path (Get-DeliveryCommonGitDirectory) "itl\delivery-operation"
}

function Test-DeliveryProcessIdentity {
    param([int]$ProcessId, [AllowNull()][object]$StartedAt)
    if ($ProcessId -le 0 -or -not $StartedAt) { return $false }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return $false }
    try {
        $expected = ConvertTo-DeliveryUtcDateTime -Value $StartedAt
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
    $ownerAlive = Test-DeliveryProcessIdentity -ProcessId ([int]$operation.ownerPid) -StartedAt $operation.ownerProcessStartedAt
    $gateAlive = Test-DeliveryProcessIdentity -ProcessId ([int]$operation.gatePid) -StartedAt $operation.gateProcessStartedAt
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
            if (-not $summary.PSObject.Properties["startedAt"] -or (ConvertTo-DeliveryUtcDateTime -Value $summary.startedAt) -lt $StartedAt.AddSeconds(-2)) { $summary = $null }
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
        $startedAt = ConvertTo-DeliveryUtcDateTime -Value $summary.startedAt; $finishedAt = ConvertTo-DeliveryUtcDateTime -Value $summary.finishedAt
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
