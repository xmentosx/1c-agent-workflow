[CmdletBinding(DefaultParameterSetName = 'Record')]
param(
    # JSON Lines output: one record per foreground change or clipboard update.
    [Parameter(Mandatory = $true, ParameterSetName = 'Record')][string]$OutputPath,
    [Parameter(ParameterSetName = 'Record')][ValidateRange(1, 14400)][int]$DurationSeconds = 1800,
    # Creating this file stops the recording early.
    [Parameter(ParameterSetName = 'Record')][string]$StopFilePath = "",
    # Groups the 1C foreground records of an existing recording by appearance and launch mode.
    [Parameter(Mandatory = $true, ParameterSetName = 'Summarize')][string]$SummarizePath,
    # Prints the process facts that a foreground record would carry for this process.
    [Parameter(Mandatory = $true, ParameterSetName = 'Describe')][int]$DescribeProcessId
)

# Source-maintenance probe for the TestClient focus contract. It runs without
# elevation: EVENT_SYSTEM_FOREGROUND arrives through an out-of-context WinEvent
# hook, so brief foreground flashes are not lost between polls, and clipboard
# updates through AddClipboardFormatListener. Clipboard contents are never read.
# Process facts (start time, image, command line) are read in the hook callback,
# so a short-lived 1C process is still described; passwords are masked before
# anything is written.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not ('ItlForegroundRecorderV2' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public sealed class ItlForegroundEventV2 {
    public DateTime TimeUtc; public string Kind; public long Window; public int ProcessId; public string ClassName; public string Title;
    public DateTime ProcessStartUtc; public string ImagePath; public string CommandLine; public long InputIdleMs; public long ForegroundLockTimeoutMs;
}

public static class ItlForegroundRecorderV2 {
    delegate void WinEventProc(IntPtr hook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
    delegate IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASSEX { public uint cbSize; public uint style; public WndProc lpfnWndProc; public int cbClsExtra; public int cbWndExtra; public IntPtr hInstance; public IntPtr hIcon; public IntPtr hCursor; public IntPtr hbrBackground; public string lpszMenuName; public string lpszClassName; public IntPtr hIconSm; }
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [StructLayout(LayoutKind.Sequential)]
    struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int x; public int y; }

    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc proc, uint pid, uint thread, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out int pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern ushort RegisterClassEx(ref WNDCLASSEX cls);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowEx(uint exStyle, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool AddClipboardFormatListener(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG msg, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG msg);
    [DllImport("user32.dll")] static extern bool PostThreadMessage(uint thread, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern bool GetProcessTimes(IntPtr handle, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr handle, int flags, StringBuilder name, ref int size);
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action, uint param, out uint value, uint winIni);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr handle, int infoClass, IntPtr buffer, int length, out int returned);

    const uint EVENT_SYSTEM_FOREGROUND = 3, WINEVENT_OUTOFCONTEXT = 0, WM_CLIPBOARDUPDATE = 0x031D, WM_QUIT = 0x0012;
    const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    const int ProcessCommandLineInformation = 60;
    const uint SPI_GETFOREGROUNDLOCKTIMEOUT = 0x2000;
    static readonly IntPtr HWND_MESSAGE = new IntPtr(-3);
    public static readonly ConcurrentQueue<ItlForegroundEventV2> Events = new ConcurrentQueue<ItlForegroundEventV2>();
    static WinEventProc hookProc; static WndProc windowProc; static Thread loop; static uint loopThread; static string startError;

    // Limited-information access suffices for processes of the same user; an
    // inaccessible process leaves the facts empty instead of failing the hook.
    public static ItlForegroundEventV2 ReadProcess(int pid) {
        var facts = new ItlForegroundEventV2 { ImagePath = "", CommandLine = "" };
        if (pid <= 0) return facts;
        IntPtr handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (handle == IntPtr.Zero) return facts;
        try {
            long creation, exit, kernel, user;
            if (GetProcessTimes(handle, out creation, out exit, out kernel, out user)) facts.ProcessStartUtc = DateTime.FromFileTimeUtc(creation);
            var image = new StringBuilder(1024); int size = image.Capacity;
            if (QueryFullProcessImageName(handle, 0, image, ref size)) facts.ImagePath = image.ToString(0, size);
            int needed;
            NtQueryInformationProcess(handle, ProcessCommandLineInformation, IntPtr.Zero, 0, out needed);
            if (needed > 0) {
                IntPtr buffer = Marshal.AllocHGlobal(needed);
                try {
                    if (NtQueryInformationProcess(handle, ProcessCommandLineInformation, buffer, needed, out needed) == 0) {
                        // UNICODE_STRING: USHORT Length (bytes), USHORT MaximumLength, PWSTR Buffer at pointer alignment.
                        int length = Marshal.ReadInt16(buffer) & 0xFFFF;
                        IntPtr text = Marshal.ReadIntPtr(buffer, IntPtr.Size);
                        if (text != IntPtr.Zero && length > 0) facts.CommandLine = Marshal.PtrToStringUni(text, length / 2);
                    }
                } finally { Marshal.FreeHGlobal(buffer); }
            }
        } finally { CloseHandle(handle); }
        return facts;
    }

    // Windows lets a background process take the foreground once the user has
    // been idle longer than the foreground lock timeout; both are readable unelevated.
    public static long ForegroundLockTimeoutMs() { uint value; return SystemParametersInfo(SPI_GETFOREGROUNDLOCKTIMEOUT, 0, out value, 0) ? (long)value : -1L; }

    public static long InputIdleMs() {
        var info = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO)) };
        return GetLastInputInfo(ref info) ? (long)unchecked((uint)Environment.TickCount - info.dwTime) : -1;
    }

    static ItlForegroundEventV2 Describe(string kind, IntPtr hwnd) {
        int pid = 0; var cls = new StringBuilder(256); var title = new StringBuilder(512);
        if (hwnd != IntPtr.Zero) { GetWindowThreadProcessId(hwnd, out pid); GetClassName(hwnd, cls, cls.Capacity); GetWindowText(hwnd, title, title.Capacity); }
        var record = kind == "foreground" || kind == "initial" ? ReadProcess(pid) : new ItlForegroundEventV2 { ImagePath = "", CommandLine = "" };
        record.TimeUtc = DateTime.UtcNow; record.Kind = kind; record.Window = hwnd.ToInt64(); record.ProcessId = pid;
        record.ClassName = cls.ToString(); record.Title = title.ToString();
        record.InputIdleMs = InputIdleMs(); record.ForegroundLockTimeoutMs = ForegroundLockTimeoutMs();
        return record;
    }

    public static void Start() {
        var ready = new ManualResetEventSlim(false);
        loop = new Thread(() => {
            IntPtr hook = IntPtr.Zero, window = IntPtr.Zero;
            try {
                loopThread = GetCurrentThreadId();
                hookProc = (h, e, hwnd, o, c, t, tm) => Events.Enqueue(Describe("foreground", hwnd));
                hook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, hookProc, 0, 0, WINEVENT_OUTOFCONTEXT);
                if (hook == IntPtr.Zero) throw new InvalidOperationException("SetWinEventHook failed: " + Marshal.GetLastWin32Error());
                windowProc = (hwnd, msg, w, l) => {
                    // Only the update notification is recorded; contents are never opened.
                    if (msg == WM_CLIPBOARDUPDATE) Events.Enqueue(Describe("clipboard", GetForegroundWindow()));
                    return DefWindowProc(hwnd, msg, w, l);
                };
                var cls = new WNDCLASSEX { cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX)), lpfnWndProc = windowProc, hInstance = GetModuleHandle(null), lpszClassName = "ItlForegroundRecorder" + Guid.NewGuid().ToString("N") };
                if (RegisterClassEx(ref cls) == 0) throw new InvalidOperationException("RegisterClassEx failed: " + Marshal.GetLastWin32Error());
                window = CreateWindowEx(0, cls.lpszClassName, "", 0, 0, 0, 0, 0, HWND_MESSAGE, IntPtr.Zero, cls.hInstance, IntPtr.Zero);
                if (window == IntPtr.Zero || !AddClipboardFormatListener(window)) throw new InvalidOperationException("Clipboard listener failed: " + Marshal.GetLastWin32Error());
                Events.Enqueue(Describe("initial", GetForegroundWindow()));
                ready.Set();
                MSG message;
                while (GetMessage(out message, IntPtr.Zero, 0, 0) > 0) { TranslateMessage(ref message); DispatchMessage(ref message); }
            } catch (Exception error) {
                startError = error.Message; ready.Set();
            } finally {
                if (window != IntPtr.Zero) { RemoveClipboardFormatListener(window); DestroyWindow(window); }
                if (hook != IntPtr.Zero) UnhookWinEvent(hook);
            }
        });
        loop.IsBackground = true; loop.SetApartmentState(ApartmentState.STA); loop.Start();
        ready.Wait();
        if (startError != null) throw new InvalidOperationException(startError);
    }

    public static void Stop() {
        if (loop == null) return;
        PostThreadMessage(loopThread, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
        loop.Join(5000);
        loop = null;
    }
}
'@
}

# Tokens keep quoted runs together: /F"C:\a b", "File=""x"";Pwd=""y"";".
function Get-CommandLineTokens([string]$CommandLine) {
    return @([regex]::Matches([string]$CommandLine, '(?:[^\s"]+|"[^"]*")+') | ForEach-Object { $_.Value })
}

# 1C passwords: /P <value> or /P<value>, repository and unlock-code keys, and
# Pwd=/Password= inside connection strings. Over-masking a /P... switch is safe.
function ConvertTo-RedactedCommandLine([string]$CommandLine) {
    $result = New-Object System.Collections.Generic.List[string]
    $maskNext = $false
    foreach ($token in (Get-CommandLineTokens $CommandLine)) {
        if ($maskNext) { $result.Add('***'); $maskNext = $false; continue }
        if ($token -match '^(?i)/(P|ConfigurationRepositoryP|UC)$') { $result.Add($token); $maskNext = $true; continue }
        if ($token -match '^(?i)(/(?:ConfigurationRepositoryP|UC|P))(.+)$') { $result.Add($Matches[1] + '***'); continue }
        $result.Add(($token -replace '(?i)\b(Pwd|Password)\s*=\s*(""(?:[^"]|"""")*""|"[^"]*"|[^;"\s]*)', '$1=***'))
    }
    return ($result -join ' ')
}

function Test-OneCProcess([string]$ProcessName) { return [string]$ProcessName -match '^(?i)1cv8' }

# Launch mode of a 1C process; the thin client 1cv8c runs only ENTERPRISE.
function Get-OneCLaunchMode([string]$CommandLine, [string]$ProcessName) {
    if (-not (Test-OneCProcess $ProcessName)) { return '' }
    $tokens = @(Get-CommandLineTokens $CommandLine | Select-Object -Skip 1 | ForEach-Object { $_.ToUpperInvariant() })
    if ($tokens -contains 'DESIGNER') { return 'designer' }
    if ($tokens -contains 'CREATEINFOBASE') { return 'createinfobase' }
    if ($tokens -contains '/TESTCLIENT') { return 'testclient' }
    if ($tokens -contains '/TESTMANAGER') { return 'testmanager' }
    if ($tokens -contains 'ENTERPRISE' -or [string]$ProcessName -match '^(?i)1cv8c$') { return 'enterprise' }
    return 'launcher'
}

function Get-RecordValue($Record, [string]$Name) {
    $property = $Record.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-UtcTime($Value) {
    if ($null -eq $Value -or [string]$Value -eq '') { return $null }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    return [DateTime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

# new-process: the first foreground window of a process started during the
# recording; new-window: another, not yet seen window of such a process or of a
# process already seen in the foreground; reactivation: a window seen before, or
# the first window of a process that predates the recording. Each 'initial'
# record starts a new recording segment (the output file is appended to).
function Get-ForegroundAppearance([hashtable]$State, $Record) {
    $kind = [string](Get-RecordValue $Record 'kind')
    $timeUtc = ConvertTo-UtcTime (Get-RecordValue $Record 'timeUtc')
    if ($kind -eq 'initial') {
        $State.recordingStartUtc = $timeUtc; $State.processes = @{}; $State.windows = @{}
    } elseif ($kind -ne 'foreground') { return '' }
    $processId = [int](Get-RecordValue $Record 'processId')
    if ($processId -le 0) { return $(if ($kind -eq 'initial') { 'initial' } else { '' }) }
    $startUtc = ConvertTo-UtcTime (Get-RecordValue $Record 'processStartUtc')
    $processKey = [string]$processId + '@' + $(if ($startUtc) { $startUtc.Ticks } else { '' })
    $windowKey = $processKey + '#' + [string](Get-RecordValue $Record 'window')
    $seenProcess = $State.processes.ContainsKey($processKey)
    $seenWindow = $State.windows.ContainsKey($windowKey)
    $State.processes[$processKey] = $true
    $State.windows[$windowKey] = $true
    if ($kind -eq 'initial') { return 'initial' }
    $startedDuringRecording = $null -ne $startUtc -and $null -ne $State.recordingStartUtc -and $startUtc -ge $State.recordingStartUtc
    if (-not $seenProcess -and $startedDuringRecording) { return 'new-process' }
    if (-not $seenWindow -and ($seenProcess -or $startedDuringRecording)) { return 'new-window' }
    return 'reactivation'
}

function New-AppearanceState { return @{ recordingStartUtc = $null; processes = @{}; windows = @{} } }

if ($PSCmdlet.ParameterSetName -eq 'Describe') {
    $facts = [ItlForegroundRecorderV2]::ReadProcess($DescribeProcessId)
    $name = try { (Get-Process -Id $DescribeProcessId -ErrorAction Stop).ProcessName } catch { '' }
    return [pscustomobject][ordered]@{
        processId = $DescribeProcessId; process = $name
        processStartUtc = $(if ($facts.ProcessStartUtc -ne [DateTime]::MinValue) { $facts.ProcessStartUtc.ToString('o') } else { '' })
        imagePath = $facts.ImagePath; launch = Get-OneCLaunchMode $facts.CommandLine $name
        commandLine = ConvertTo-RedactedCommandLine $facts.CommandLine
    }
}

if ($PSCmdlet.ParameterSetName -eq 'Summarize') {
    $state = New-AppearanceState
    $rows = foreach ($line in [IO.File]::ReadAllLines([IO.Path]::GetFullPath($SummarizePath), [Text.UTF8Encoding]::new($false))) {
        if (-not $line.Trim()) { continue }
        $record = $line | ConvertFrom-Json
        $appearance = Get-ForegroundAppearance $state $record
        if ([string](Get-RecordValue $record 'kind') -ne 'foreground' -or -not (Test-OneCProcess (Get-RecordValue $record 'process'))) { continue }
        $launch = Get-RecordValue $record 'launch'
        if ($null -eq $launch) { $launch = Get-OneCLaunchMode (Get-RecordValue $record 'commandLine') (Get-RecordValue $record 'process') }
        [pscustomobject]@{ appearance = $appearance; launch = $launch; process = [string](Get-RecordValue $record 'process'); processId = [int](Get-RecordValue $record 'processId') }
    }
    return @($rows | Group-Object appearance, launch, process | Sort-Object Count -Descending | ForEach-Object {
        $first = $_.Group[0]
        [pscustomobject][ordered]@{
            appearance = $first.appearance; launch = $first.launch; process = $first.process
            count = $_.Count; processes = @($_.Group | Select-Object -ExpandProperty processId -Unique).Count
        }
    })
}

$OutputPath = [IO.Path]::GetFullPath($OutputPath)
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $OutputPath))
$writer = [IO.StreamWriter]::new($OutputPath, $true, [Text.UTF8Encoding]::new($false))
$processNames = @{}
$state = New-AppearanceState
$counts = @{ foreground = 0; clipboard = 0; 'new-process' = 0; 'new-window' = 0; reactivation = 0 }
[ItlForegroundRecorderV2]::Start()
try {
    $deadline = [DateTime]::UtcNow.AddSeconds($DurationSeconds)
    while ([DateTime]::UtcNow -lt $deadline -and -not ($StopFilePath -and (Test-Path -LiteralPath $StopFilePath))) {
        Start-Sleep -Milliseconds 200
        $event = $null
        while ([ItlForegroundRecorderV2]::Events.TryDequeue([ref]$event)) {
            if (-not $processNames.ContainsKey($event.ProcessId)) {
                $processNames[$event.ProcessId] = if ($event.ImagePath) { [IO.Path]::GetFileNameWithoutExtension($event.ImagePath) } else { try { (Get-Process -Id $event.ProcessId -ErrorAction Stop).ProcessName } catch { '' } }
            }
            $name = $processNames[$event.ProcessId]
            $record = [pscustomobject][ordered]@{
                timeUtc = $event.TimeUtc.ToString('o'); kind = $event.Kind; window = $event.Window
                processId = $event.ProcessId; process = $name
                processStartUtc = $(if ($event.ProcessStartUtc -ne [DateTime]::MinValue) { $event.ProcessStartUtc.ToString('o') } else { '' })
                className = $event.ClassName; title = $event.Title
                launch = Get-OneCLaunchMode $event.CommandLine $name
                commandLine = ConvertTo-RedactedCommandLine $event.CommandLine
                inputIdleMs = $event.InputIdleMs; foregroundLockTimeoutMs = $event.ForegroundLockTimeoutMs
                appearance = ''
            }
            $record.appearance = Get-ForegroundAppearance $state $record
            if ($counts.ContainsKey($event.Kind)) { $counts[$event.Kind]++ }
            if ($counts.ContainsKey($record.appearance)) { $counts[$record.appearance]++ }
            $writer.WriteLine(($record | ConvertTo-Json -Compress))
            $writer.Flush()
        }
    }
} finally {
    [ItlForegroundRecorderV2]::Stop()
    $writer.Dispose()
}
[pscustomobject]@{
    outputPath = $OutputPath; foregroundChanges = $counts.foreground; clipboardUpdates = $counts.clipboard
    newProcessWindows = $counts['new-process']; newWindows = $counts['new-window']; reactivations = $counts.reactivation
}
