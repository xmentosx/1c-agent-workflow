[CmdletBinding()]
param(
    # JSON Lines output: one record per foreground change or clipboard update.
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [ValidateRange(1, 14400)][int]$DurationSeconds = 1800,
    # Creating this file stops the recording early.
    [string]$StopFilePath = ""
)

# Source-maintenance probe for the TestClient focus contract. It runs without
# elevation: EVENT_SYSTEM_FOREGROUND arrives through an out-of-context WinEvent
# hook, so brief foreground flashes are not lost between polls, and clipboard
# updates through AddClipboardFormatListener. Clipboard contents are never read.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not ('ItlForegroundRecorder' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public sealed class ItlForegroundEvent {
    public DateTime TimeUtc; public string Kind; public long Window; public int ProcessId; public string ClassName; public string Title;
}

public static class ItlForegroundRecorder {
    delegate void WinEventProc(IntPtr hook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
    delegate IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASSEX { public uint cbSize; public uint style; public WndProc lpfnWndProc; public int cbClsExtra; public int cbWndExtra; public IntPtr hInstance; public IntPtr hIcon; public IntPtr hCursor; public IntPtr hbrBackground; public string lpszMenuName; public string lpszClassName; public IntPtr hIconSm; }
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

    const uint EVENT_SYSTEM_FOREGROUND = 3, WINEVENT_OUTOFCONTEXT = 0, WM_CLIPBOARDUPDATE = 0x031D, WM_QUIT = 0x0012;
    static readonly IntPtr HWND_MESSAGE = new IntPtr(-3);
    public static readonly ConcurrentQueue<ItlForegroundEvent> Events = new ConcurrentQueue<ItlForegroundEvent>();
    static WinEventProc hookProc; static WndProc windowProc; static Thread loop; static uint loopThread; static string startError;

    static ItlForegroundEvent Describe(string kind, IntPtr hwnd) {
        int pid = 0; var cls = new StringBuilder(256); var title = new StringBuilder(512);
        if (hwnd != IntPtr.Zero) { GetWindowThreadProcessId(hwnd, out pid); GetClassName(hwnd, cls, cls.Capacity); GetWindowText(hwnd, title, title.Capacity); }
        return new ItlForegroundEvent { TimeUtc = DateTime.UtcNow, Kind = kind, Window = hwnd.ToInt64(), ProcessId = pid, ClassName = cls.ToString(), Title = title.ToString() };
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

$OutputPath = [IO.Path]::GetFullPath($OutputPath)
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $OutputPath))
$writer = [IO.StreamWriter]::new($OutputPath, $true, [Text.UTF8Encoding]::new($false))
$processNames = @{}
$counts = @{ foreground = 0; clipboard = 0 }
[ItlForegroundRecorder]::Start()
try {
    $deadline = [DateTime]::UtcNow.AddSeconds($DurationSeconds)
    while ([DateTime]::UtcNow -lt $deadline -and -not ($StopFilePath -and (Test-Path -LiteralPath $StopFilePath))) {
        Start-Sleep -Milliseconds 200
        $event = $null
        while ([ItlForegroundRecorder]::Events.TryDequeue([ref]$event)) {
            if (-not $processNames.ContainsKey($event.ProcessId)) {
                $processNames[$event.ProcessId] = try { (Get-Process -Id $event.ProcessId -ErrorAction Stop).ProcessName } catch { '' }
            }
            if ($counts.ContainsKey($event.Kind)) { $counts[$event.Kind]++ }
            $record = [ordered]@{
                timeUtc = $event.TimeUtc.ToString('o'); kind = $event.Kind; window = $event.Window
                processId = $event.ProcessId; process = $processNames[$event.ProcessId]
                className = $event.ClassName; title = $event.Title
            }
            $writer.WriteLine(($record | ConvertTo-Json -Compress))
            $writer.Flush()
        }
    }
} finally {
    [ItlForegroundRecorder]::Stop()
    $writer.Dispose()
}
[pscustomobject]@{ outputPath = $OutputPath; foregroundChanges = $counts.foreground; clipboardUpdates = $counts.clipboard }
