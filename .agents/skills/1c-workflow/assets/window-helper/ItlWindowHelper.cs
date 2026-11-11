// ITL window helper for hidden 1C TestClient groups.
// Built locally by csc.exe from .NET Framework 4.x; the language is limited to C# 5.
// One process serves one group directory. Every file in the group is data: the
// helper may be killed at any time and the next request starts it again.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace Itl.WindowHelper
{
    // The same contract is published in protocol.json and checked in the PowerShell
    // client and the Vanessa patch.
    internal static class Protocol
    {
        public const int Version = 1;
        public static readonly string[] Operations = { "lease", "lease-end", "capture-show", "capture-end", "adopt", "status", "show", "hide" };
        public static readonly string[] RequestFields = { "protocol", "op", "id", "scope", "deadlineUtc" };
        public const string Declined = "ITL_UI_CONTROL_DECLINED";
        public const string ActivationFailed = "ITL_WINDOW_ACTIVATION_FAILED";
    }

    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length < 2)
            {
                Console.Error.WriteLine("usage: itl-window-helper run|ensure|stop <group-directory> [--hung] [--show-hidden]");
                return 2;
            }
            string verb = args[0];
            string dir = Path.GetFullPath(args[1]);
            bool hung = Array.IndexOf(args, "--hung") >= 0;
            bool showHidden = Array.IndexOf(args, "--show-hidden") >= 0;
            try
            {
                switch (verb)
                {
                    case "run": return Daemon.Run(dir);
                    case "ensure": return Lifecycle.Ensure(dir, hung);
                    case "stop": return Lifecycle.Stop(dir, showHidden);
                    default:
                        Console.Error.WriteLine("unknown verb: " + verb);
                        return 2;
                }
            }
            catch (Exception e)
            {
                Console.Error.WriteLine(e.GetType().Name + ": " + e.Message);
                return 1;
            }
        }
    }

    internal static class Json
    {
        private static readonly JavaScriptSerializer Serializer = new JavaScriptSerializer();

        public static Dictionary<string, object> ReadFile(string path)
        {
            string text;
            using (var reader = new StreamReader(path, new UTF8Encoding(false), true))
            {
                text = reader.ReadToEnd();
            }
            text = text.TrimStart('﻿');
            var value = Serializer.DeserializeObject(text) as Dictionary<string, object>;
            if (value == null) throw new InvalidDataException("JSON object expected: " + path);
            return value;
        }

        public static string Write(object value)
        {
            return Serializer.Serialize(value);
        }

        public static void WriteFileAtomic(string path, object value)
        {
            string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            File.WriteAllText(temp, Write(value), new UTF8Encoding(false));
            if (File.Exists(path)) File.Delete(path);
            File.Move(temp, path);
        }

        public static string Str(Dictionary<string, object> d, string key)
        {
            object v;
            return d.TryGetValue(key, out v) && v != null ? Convert.ToString(v, CultureInfo.InvariantCulture) : "";
        }

        public static long Num(Dictionary<string, object> d, string key, long fallback)
        {
            object v;
            if (!d.TryGetValue(key, out v) || v == null) return fallback;
            long result;
            return long.TryParse(Convert.ToString(v, CultureInfo.InvariantCulture), NumberStyles.Integer, CultureInfo.InvariantCulture, out result) ? result : fallback;
        }

        public static bool Bool(Dictionary<string, object> d, string key)
        {
            object v;
            if (!d.TryGetValue(key, out v) || v == null) return false;
            if (v is bool) return (bool)v;
            string s = Convert.ToString(v, CultureInfo.InvariantCulture);
            return s == "1" || string.Equals(s, "true", StringComparison.OrdinalIgnoreCase);
        }
    }

    internal sealed class GroupPaths
    {
        public readonly string Root;
        public GroupPaths(string root) { Root = root; }
        public string Config { get { return Path.Combine(Root, "group.json"); } }
        public string Lock { get { return Path.Combine(Root, "helper.lock"); } }
        public string Identity { get { return Path.Combine(Root, "helper.json"); } }
        public string Adopted { get { return Path.Combine(Root, "adopted.json"); } }
        public string Requests { get { return Path.Combine(Root, "requests"); } }
        public string Responses { get { return Path.Combine(Root, "responses"); } }
        public string Journal { get { return Path.Combine(Root, "journal"); } }
        public string HiddenLog { get { return Path.Combine(Journal, "hidden.jsonl"); } }
        public string LeaseLog { get { return Path.Combine(Journal, "leases.jsonl"); } }
    }

    internal sealed class GroupConfig
    {
        public int ProtocolVersion;
        public string Mode = "hidden";
        public int CountdownSeconds = 10;
        public int PauseLimitSeconds = 600;
        public List<uint> Roots = new List<uint>();

        public static GroupConfig Load(GroupPaths paths)
        {
            var d = Json.ReadFile(paths.Config);
            var c = new GroupConfig();
            c.ProtocolVersion = (int)Json.Num(d, "protocol", 0);
            string mode = Json.Str(d, "mode");
            if (mode.Length > 0) c.Mode = mode;
            c.CountdownSeconds = (int)Math.Max(0, Math.Min(600, Json.Num(d, "countdownSeconds", 10)));
            c.PauseLimitSeconds = (int)Math.Max(1, Math.Min(86400, Json.Num(d, "pauseLimitSeconds", 600)));
            object roots;
            if (d.TryGetValue("roots", out roots) && roots is object[])
            {
                foreach (object r in (object[])roots)
                {
                    uint pid;
                    if (uint.TryParse(Convert.ToString(r, CultureInfo.InvariantCulture), out pid) && pid != 0) c.Roots.Add(pid);
                }
            }
            return c;
        }
    }

    // ---------------------------------------------------------------- Win32
    internal static class Native
    {
        public const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
        public const uint EVENT_OBJECT_SHOW = 0x8002;
        public const uint WINEVENT_OUTOFCONTEXT = 0x0000;
        public const uint WINEVENT_SKIPOWNPROCESS = 0x0002;
        public const int SW_HIDE = 0;
        public const int SW_SHOWNA = 8;
        public const uint SWP_NOSIZE = 0x0001, SWP_NOMOVE = 0x0002, SWP_NOACTIVATE = 0x0010, SWP_SHOWWINDOW = 0x0040;
        public static readonly IntPtr HWND_BOTTOM = new IntPtr(1);

        public delegate void WinEventDelegate(IntPtr hook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
        public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

        [DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr module, WinEventDelegate proc, uint pid, uint thread, uint flags);
        [DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr hook);
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc proc, IntPtr lParam);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hwnd, int index);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int size);
        [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
        [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
        [DllImport("user32.dll")] public static extern IntPtr GetLastActivePopup(IntPtr hwnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder text, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
        [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hwnd, int cmd);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint attach, uint to, bool doAttach);
        [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
        [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
        [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
        [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
        [DllImport("user32.dll")] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
        [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr desktop);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetUserObjectInformation(IntPtr obj, int index, StringBuilder info, int length, out int needed);
        [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
        [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
        [DllImport("user32.dll")] public static extern IntPtr SetProcessDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder name, ref int size);
        [DllImport("kernel32.dll")] public static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")] public static extern bool SetProcessWorkingSetSize(IntPtr process, IntPtr min, IntPtr max);
        [DllImport("ntdll.dll")] public static extern int NtQueryInformationProcess(IntPtr process, int infoClass, IntPtr buffer, int length, out int returned);
        [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool Process32FirstW(IntPtr snapshot, ref PROCESSENTRY32 entry);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool Process32NextW(IntPtr snapshot, ref PROCESSENTRY32 entry);

        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
        [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr extra; }
        [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public MOUSEINPUT mi; }
        [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct PROCESSENTRY32
        {
            public uint dwSize, cntUsage, th32ProcessID; public IntPtr th32DefaultHeapID; public uint th32ModuleID, cntThreads, th32ParentProcessID;
            public int pcPriClassBase; public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
        }

        public static uint PidOf(IntPtr hwnd)
        {
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            return pid;
        }

        public static string ClassOf(IntPtr hwnd)
        {
            var sb = new StringBuilder(256);
            GetClassName(hwnd, sb, sb.Capacity);
            return sb.ToString();
        }

        public static string TitleOf(IntPtr hwnd)
        {
            var sb = new StringBuilder(512);
            GetWindowText(hwnd, sb, sb.Capacity);
            return sb.ToString();
        }

        public static Rectangle RectOf(IntPtr hwnd)
        {
            RECT r;
            if (!GetWindowRect(hwnd, out r)) return Rectangle.Empty;
            return Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
        }

        public static List<IntPtr> TopLevelWindows(uint pid)
        {
            var list = new List<IntPtr>();
            EnumWindows(delegate(IntPtr h, IntPtr l) { if (PidOf(h) == pid) list.Add(h); return true; }, IntPtr.Zero);
            return list;
        }

        // Startup and lease pages are not needed while the helper waits for events.
        public static void TrimWorkingSet()
        {
            SetProcessWorkingSetSize(GetCurrentProcess(), new IntPtr(-1), new IntPtr(-1));
        }

        public static uint IdleMilliseconds()
        {
            var info = new LASTINPUTINFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            if (!GetLastInputInfo(ref info)) return uint.MaxValue;
            return unchecked((uint)Environment.TickCount - info.dwTime);
        }

        // The interactive desktop is "Default"; a locked or disconnected session has none.
        public static bool InteractiveDesktop()
        {
            IntPtr desk = OpenInputDesktop(0, false, 0x0001);
            if (desk == IntPtr.Zero) return false;
            try
            {
                var sb = new StringBuilder(256);
                int needed;
                if (!GetUserObjectInformation(desk, 2, sb, sb.Capacity * 2, out needed)) return false;
                return string.Equals(sb.ToString(), "Default", StringComparison.OrdinalIgnoreCase);
            }
            finally { CloseDesktop(desk); }
        }

        public static void Nudge()
        {
            var input = new INPUT();
            input.type = 0;
            input.mi.dwFlags = 0x0001;
            SendInput(1, new[] { input }, Marshal.SizeOf(typeof(INPUT)));
        }

        private static bool IsForeground(IntPtr hwnd, uint pid)
        {
            IntPtr fg = GetForegroundWindow();
            return fg == hwnd || (pid != 0 && fg != IntPtr.Zero && PidOf(fg) == pid);
        }

        private static bool WaitForeground(IntPtr hwnd, uint pid)
        {
            for (int i = 0; i < 3; i++)
            {
                if (IsForeground(hwnd, pid)) return true;
                Thread.Sleep(10);
            }
            return IsForeground(hwnd, pid);
        }

        // Activation chain shared by lease start and focus return: plain, then a
        // zero mouse move, then input attachment; up to three attempts.
        public static string Bring(IntPtr hwnd)
        {
            return Bring(hwnd, 0);
        }

        // With a process id, a foreground window of that process counts as success:
        // 1C may move the activation to another of its own top-level windows.
        public static string Bring(IntPtr hwnd, uint pid)
        {
            if (hwnd == IntPtr.Zero || !IsWindow(hwnd)) return "fail";
            for (int attempt = 0; attempt < 3; attempt++)
            {
                SetForegroundWindow(hwnd);
                if (WaitForeground(hwnd, pid)) return "plain";
                Nudge();
                SetForegroundWindow(hwnd);
                if (WaitForeground(hwnd, pid)) return "nudge";
                IntPtr fg = GetForegroundWindow();
                uint ignored;
                uint fgThread = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, out ignored);
                uint me = GetCurrentThreadId();
                bool attached = fgThread != 0 && fgThread != me && AttachThreadInput(me, fgThread, true);
                BringWindowToTop(hwnd);
                SetForegroundWindow(hwnd);
                if (attached) AttachThreadInput(me, fgThread, false);
                if (WaitForeground(hwnd, pid)) return "attach";
            }
            return "fail";
        }

        public static void SetDpiAwareness()
        {
            try
            {
                if (SetProcessDpiAwarenessContext(new IntPtr(-4)) != IntPtr.Zero) return;
            }
            catch (EntryPointNotFoundException) { }
            try { SetProcessDPIAware(); } catch (EntryPointNotFoundException) { }
        }

        public static Rectangle MonitorWorkArea(IntPtr hwnd, out Rectangle bounds)
        {
            IntPtr monitor = MonitorFromWindow(hwnd, 2);
            var info = new MONITORINFO();
            info.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
            if (monitor != IntPtr.Zero && GetMonitorInfo(monitor, ref info))
            {
                bounds = Rectangle.FromLTRB(info.rcMonitor.Left, info.rcMonitor.Top, info.rcMonitor.Right, info.rcMonitor.Bottom);
                return Rectangle.FromLTRB(info.rcWork.Left, info.rcWork.Top, info.rcWork.Right, info.rcWork.Bottom);
            }
            bounds = Screen.PrimaryScreen.Bounds;
            return Screen.PrimaryScreen.WorkingArea;
        }

        public static bool Capture(IntPtr hwnd, string path)
        {
            Rectangle r = RectOf(hwnd);
            if (r.Width <= 0 || r.Height <= 0) return false;
            using (var bmp = new Bitmap(r.Width, r.Height, PixelFormat.Format32bppArgb))
            {
                bool ok;
                using (var g = Graphics.FromImage(bmp))
                {
                    IntPtr hdc = g.GetHdc();
                    try { ok = PrintWindow(hwnd, hdc, 2); }
                    finally { g.ReleaseHdc(hdc); }
                }
                if (!ok) return false;
                bmp.Save(path, ImageFormat.Png);
                return true;
            }
        }
    }

    internal sealed class ProcessFacts
    {
        public uint Pid;
        public long CreationTime;
        public string ImagePath = "";
        public string CommandLine = "";
        public bool Alive;

        public bool IsOneC
        {
            get
            {
                string name = Path.GetFileName(ImagePath);
                return name.StartsWith("1cv8", StringComparison.OrdinalIgnoreCase);
            }
        }

        public bool IsTestClient { get { return IsOneC && CommandLine.IndexOf("/TESTCLIENT", StringComparison.OrdinalIgnoreCase) >= 0; } }
        public bool IsTestManager { get { return IsOneC && CommandLine.IndexOf("/TESTMANAGER", StringComparison.OrdinalIgnoreCase) >= 0; } }
        public bool IsWindowHelper { get { return Path.GetFileName(ImagePath).StartsWith("itl-window-helper", StringComparison.OrdinalIgnoreCase); } }

        public int TestPort
        {
            get
            {
                var m = System.Text.RegularExpressions.Regex.Match(CommandLine, @"(?i)(?:^|\s)-TPort\s+""?(\d+)");
                int port;
                return m.Success && int.TryParse(m.Groups[1].Value, out port) ? port : 0;
            }
        }

        public static ProcessFacts Read(uint pid)
        {
            var facts = new ProcessFacts();
            facts.Pid = pid;
            IntPtr h = Native.OpenProcess(0x1000 | 0x0010, false, pid);
            if (h == IntPtr.Zero) h = Native.OpenProcess(0x1000, false, pid);
            if (h == IntPtr.Zero) return facts;
            try
            {
                long creation, exit, kernel, user;
                if (Native.GetProcessTimes(h, out creation, out exit, out kernel, out user))
                {
                    facts.CreationTime = creation;
                    facts.Alive = exit == 0;
                }
                var sb = new StringBuilder(1024);
                int size = sb.Capacity;
                if (Native.QueryFullProcessImageName(h, 0, sb, ref size)) facts.ImagePath = sb.ToString();
                facts.CommandLine = ReadCommandLine(h);
            }
            finally { Native.CloseHandle(h); }
            return facts;
        }

        // ProcessCommandLineInformation (60) returns a UNICODE_STRING followed by its buffer.
        private static string ReadCommandLine(IntPtr process)
        {
            int length = 4096;
            for (int attempt = 0; attempt < 3; attempt++)
            {
                IntPtr buffer = Marshal.AllocHGlobal(length);
                try
                {
                    int returned;
                    int status = Native.NtQueryInformationProcess(process, 60, buffer, length, out returned);
                    if (status == unchecked((int)0xC0000004) && returned > length) { length = returned; continue; }
                    if (status != 0) return "";
                    int bytes = (ushort)Marshal.ReadInt16(buffer);
                    IntPtr text = Marshal.ReadIntPtr(buffer, IntPtr.Size);
                    return bytes == 0 || text == IntPtr.Zero ? "" : Marshal.PtrToStringUni(text, bytes / 2);
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
            return "";
        }
    }

    // ---------------------------------------------------------------- lifecycle verbs
    internal static class Lifecycle
    {
        public static bool LockHeld(GroupPaths paths)
        {
            try
            {
                using (new FileStream(paths.Lock, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None)) { }
                return false;
            }
            catch (IOException) { return true; }
            catch (UnauthorizedAccessException) { return true; }
        }

        public static int Ensure(string dir, bool hung)
        {
            var paths = new GroupPaths(dir);
            if (!File.Exists(paths.Config)) { Console.Error.WriteLine("no-group: " + paths.Config); return 4; }
            if (LockHeld(paths))
            {
                if (!hung) return WaitReady(paths, null, 3000) ? 0 : 3;
                if (!KillRecorded(paths)) { Console.Error.WriteLine("hung-helper-not-replaced"); return 3; }
            }
            DateTime requested = DateTime.UtcNow;
            string exe = Process.GetCurrentProcess().MainModule.FileName;
            var start = new ProcessStartInfo(exe, "run \"" + dir + "\"");
            // Shell execution inherits no handles: a caller reading this process's
            // output is never held open by the long-lived helper.
            start.UseShellExecute = true;
            start.WindowStyle = ProcessWindowStyle.Hidden;
            start.WorkingDirectory = Path.GetDirectoryName(exe);
            using (Process.Start(start)) { }
            return WaitReady(paths, requested, 3000) ? 0 : 3;
        }

        private static bool WaitReady(GroupPaths paths, DateTime? startedAfter, int timeoutMs)
        {
            var watch = Stopwatch.StartNew();
            while (watch.ElapsedMilliseconds < timeoutMs)
            {
                try
                {
                    if (File.Exists(paths.Identity) && LockHeld(paths))
                    {
                        var id = Json.ReadFile(paths.Identity);
                        if (Json.Bool(id, "ready") && Json.Num(id, "protocol", 0) == Protocol.Version)
                        {
                            if (startedAfter == null) return true;
                            // The new helper records its start after this process requested it;
                            // an older identity file must not report readiness.
                            DateTime started;
                            if (DateTime.TryParse(Json.Str(id, "startedUtc"), CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out started) &&
                                started >= startedAfter.Value) return true;
                        }
                    }
                }
                catch (IOException) { }
                catch (InvalidDataException) { }
                catch (ArgumentException) { }
                Thread.Sleep(50);
            }
            return false;
        }

        // Ends the helper recorded in helper.json after checking its image name and start time.
        public static bool KillRecorded(GroupPaths paths)
        {
            Dictionary<string, object> id;
            try { id = Json.ReadFile(paths.Identity); }
            catch (Exception) { return !LockHeld(paths); }
            uint pid = (uint)Json.Num(id, "pid", 0);
            long creation = Json.Num(id, "creationTime", 0);
            if (pid != 0)
            {
                var facts = ProcessFacts.Read(pid);
                if (facts.Alive && facts.CreationTime == creation && facts.IsWindowHelper)
                {
                    try
                    {
                        using (var p = Process.GetProcessById((int)pid))
                        {
                            p.Kill();
                            p.WaitForExit(3000);
                        }
                    }
                    catch (ArgumentException) { }
                    catch (InvalidOperationException) { }
                    catch (System.ComponentModel.Win32Exception) { }
                }
            }
            var watch = Stopwatch.StartNew();
            while (watch.ElapsedMilliseconds < 3000)
            {
                if (!LockHeld(paths)) return true;
                Thread.Sleep(50);
            }
            return false;
        }

        public static int Stop(string dir, bool showHidden)
        {
            var paths = new GroupPaths(dir);
            bool stopped = !LockHeld(paths) || KillRecorded(paths);
            if (showHidden && File.Exists(paths.Config))
            {
                var config = GroupConfig.Load(paths);
                var members = new Membership(config.Roots, Membership.LoadAdopted(paths));
                members.Refresh();
                foreach (uint pid in members.Clients)
                {
                    IntPtr main = WindowOps.MainWindow(pid);
                    if (main != IntPtr.Zero) Native.ShowWindowAsync(main, Native.SW_SHOWNA);
                }
            }
            return stopped ? 0 : 3;
        }
    }

    // ---------------------------------------------------------------- group membership
    internal sealed class Membership
    {
        private readonly List<uint> roots;
        private readonly List<uint> adopted;
        private readonly Dictionary<uint, ProcessFacts> facts = new Dictionary<uint, ProcessFacts>();
        public readonly HashSet<uint> Members = new HashSet<uint>();
        public readonly HashSet<uint> Clients = new HashSet<uint>();
        public bool SawRoot;

        public Membership(List<uint> roots, List<uint> adopted)
        {
            this.roots = new List<uint>(roots);
            this.adopted = new List<uint>(adopted);
        }

        public static List<uint> LoadAdopted(GroupPaths paths)
        {
            var list = new List<uint>();
            try
            {
                if (!File.Exists(paths.Adopted)) return list;
                var d = Json.ReadFile(paths.Adopted);
                object pids;
                if (d.TryGetValue("pids", out pids) && pids is object[])
                {
                    foreach (object p in (object[])pids)
                    {
                        uint pid;
                        if (uint.TryParse(Convert.ToString(p, CultureInfo.InvariantCulture), out pid) && pid != 0) list.Add(pid);
                    }
                }
            }
            catch (Exception) { }
            return list;
        }

        public List<uint> AdoptedPids { get { return new List<uint>(adopted); } }

        public bool Adopt(uint pid)
        {
            if (pid == 0 || adopted.Contains(pid) || roots.Contains(pid)) return false;
            adopted.Add(pid);
            return true;
        }

        public ProcessFacts Facts(uint pid)
        {
            ProcessFacts f;
            return facts.TryGetValue(pid, out f) ? f : null;
        }

        public bool HasAnchors { get { return roots.Count + adopted.Count > 0; } }

        // Roots and adopted processes plus their live descendants; a child must start after its parent.
        public void Refresh()
        {
            var parents = new Dictionary<uint, uint>();
            IntPtr snap = Native.CreateToolhelp32Snapshot(0x2, 0);
            if (snap != new IntPtr(-1))
            {
                try
                {
                    var entry = new Native.PROCESSENTRY32();
                    entry.dwSize = (uint)Marshal.SizeOf(typeof(Native.PROCESSENTRY32));
                    if (Native.Process32FirstW(snap, ref entry))
                    {
                        do { parents[entry.th32ProcessID] = entry.th32ParentProcessID; }
                        while (Native.Process32NextW(snap, ref entry));
                    }
                }
                finally { Native.CloseHandle(snap); }
            }
            var next = new HashSet<uint>();
            var anchors = new List<uint>(roots);
            anchors.AddRange(adopted);
            foreach (uint a in anchors)
            {
                if (!parents.ContainsKey(a)) continue;
                ProcessFacts f = Known(a);
                if (f == null || !f.Alive) continue;
                next.Add(a);
                if (roots.Contains(a) || adopted.Contains(a)) SawRoot = true;
            }
            bool grew = true;
            while (grew)
            {
                grew = false;
                foreach (var kv in parents)
                {
                    if (next.Contains(kv.Key) || !next.Contains(kv.Value) || kv.Key == kv.Value) continue;
                    ProcessFacts child = Known(kv.Key), parent = Known(kv.Value);
                    if (child == null || parent == null || !child.Alive || child.CreationTime < parent.CreationTime) continue;
                    next.Add(kv.Key);
                    grew = true;
                }
            }
            Members.Clear();
            Clients.Clear();
            foreach (uint pid in next)
            {
                Members.Add(pid);
                ProcessFacts f = Known(pid);
                if (f != null && f.IsTestClient) Clients.Add(pid);
            }
            var stale = new List<uint>();
            foreach (uint pid in facts.Keys) if (!parents.ContainsKey(pid)) stale.Add(pid);
            foreach (uint pid in stale) facts.Remove(pid);
        }

        // Between full snapshots only known processes are checked: a process snapshot
        // costs about 15 ms with 500 processes, a liveness check a few microseconds.
        public void PruneExited()
        {
            var exited = new List<uint>();
            foreach (uint pid in Members)
            {
                ProcessFacts f = ProcessFacts.Read(pid);
                ProcessFacts known;
                if (!f.Alive || !facts.TryGetValue(pid, out known) || known.CreationTime != f.CreationTime) exited.Add(pid);
            }
            foreach (uint pid in exited)
            {
                Members.Remove(pid);
                Clients.Remove(pid);
                facts.Remove(pid);
            }
        }

        private ProcessFacts Known(uint pid)
        {
            ProcessFacts f;
            if (facts.TryGetValue(pid, out f))
            {
                if (f.Alive) return f;
            }
            f = ProcessFacts.Read(pid);
            facts[pid] = f;
            return f;
        }
    }

    // ---------------------------------------------------------------- window operations
    internal static class WindowOps
    {
        public const string SplashTitle = "Загрузка конфигурационной информации";

        public static IntPtr MainWindow(uint pid)
        {
            IntPtr best = IntPtr.Zero;
            long bestArea = 0;
            foreach (IntPtr h in Native.TopLevelWindows(pid))
            {
                if (Native.GetWindow(h, 4) != IntPtr.Zero) continue;
                string cls = Native.ClassOf(h);
                if (!cls.StartsWith("V8TopLevelFrame", StringComparison.Ordinal) || cls.EndsWith("sec", StringComparison.Ordinal)) continue;
                if (Native.TitleOf(h).StartsWith(SplashTitle, StringComparison.Ordinal)) continue;
                Rectangle r = Native.RectOf(h);
                long area = (long)r.Width * r.Height;
                if (area > bestArea) { best = h; bestArea = area; }
            }
            return best;
        }

        // Top-level windows the user could see: frames, dialogs and form windows.
        // Frame shadows and borders (class V8Window, 10 px wide) are not.
        public static bool IsSignificant(IntPtr hwnd)
        {
            string cls = Native.ClassOf(hwnd);
            if (cls.StartsWith("V8TopLevelFrame", StringComparison.Ordinal)) return true;
            if (cls == "V8Window") return false;
            Rectangle r = Native.RectOf(hwnd);
            return r.Width > 40 && r.Height > 40 && r.Width * (long)r.Height > 4000;
        }
    }

    // One thread owns the cross-group lease mutex: Win32 mutex ownership is per thread.
    internal sealed class LeaseMutex : IDisposable
    {
        private readonly BlockingCollection<Action> queue = new BlockingCollection<Action>();
        private readonly Thread thread;
        private readonly Mutex mutex;
        private volatile bool held;

        public LeaseMutex(string name)
        {
            bool created;
            mutex = new Mutex(false, name, out created);
            thread = new Thread(Loop);
            thread.IsBackground = true;
            thread.Name = "lease-mutex";
            thread.Start();
        }

        public bool Held { get { return held; } }

        private void Loop()
        {
            foreach (Action action in queue.GetConsumingEnumerable())
            {
                try { action(); } catch (Exception) { }
            }
        }

        public void Acquire(DateTime deadlineUtc, Func<bool> cancelled, Action<bool> done)
        {
            queue.Add(delegate
            {
                bool got = held;
                while (!got)
                {
                    TimeSpan left = deadlineUtc - DateTime.UtcNow;
                    if (left <= TimeSpan.Zero || cancelled()) break;
                    try { got = mutex.WaitOne((int)Math.Min(250, Math.Max(1, left.TotalMilliseconds))); }
                    catch (AbandonedMutexException) { got = true; }
                }
                if (got && cancelled())
                {
                    mutex.ReleaseMutex();
                    got = false;
                }
                held = got;
                done(got);
            });
        }

        public void Release()
        {
            queue.Add(delegate
            {
                if (!held) return;
                held = false;
                mutex.ReleaseMutex();
            });
        }

        public void Dispose()
        {
            Release();
            queue.CompleteAdding();
        }
    }

    // ---------------------------------------------------------------- forms
    internal sealed class NoFocusButton : Button
    {
        public NoFocusButton() { SetStyle(ControlStyles.Selectable, false); TabStop = false; }
        protected override bool ShowFocusCues { get { return false; } }
    }

    // Never activates itself: Enter and space typed into the user's application
    // cannot press a button here, and the restored foreground stays where it is.
    internal class OverlayForm : Form
    {
        protected readonly float UiScale;

        public OverlayForm(float scale)
        {
            UiScale = scale;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            TopMost = true;
            AutoScaleMode = AutoScaleMode.None;
            KeyPreview = false;
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000 | 0x00000008 | 0x00000080; // NOACTIVATE | TOPMOST | TOOLWINDOW
                return cp;
            }
        }

        protected int S(int value) { return (int)Math.Round(value * UiScale); }

        protected Button AddButton(Control parent, string text, int x, int y, int w, int h, EventHandler click)
        {
            var b = new NoFocusButton();
            b.Text = text;
            b.UseMnemonic = false;
            b.Font = new Font("Segoe UI", S(15), FontStyle.Regular, GraphicsUnit.Pixel);
            b.SetBounds(x, y, w, h);
            // WinForms-drawn buttons take a mouse click without activating the window.
            b.FlatStyle = FlatStyle.Flat;
            b.BackColor = Color.FromArgb(58, 64, 76);
            b.ForeColor = Color.White;
            b.FlatAppearance.BorderColor = Color.FromArgb(120, 130, 150);
            b.Click += click;
            parent.Controls.Add(b);
            return b;
        }

        protected Label AddLabel(string text, int size, FontStyle style, Rectangle bounds, Color color, ContentAlignment align)
        {
            var l = new Label();
            l.Text = text;
            l.ForeColor = color;
            l.BackColor = Color.Transparent;
            l.TextAlign = align;
            l.Font = new Font("Segoe UI", S(size), style, GraphicsUnit.Pixel);
            l.Bounds = bounds;
            Controls.Add(l);
            return l;
        }
    }

    internal sealed class ConsentForm : OverlayForm
    {
        private readonly Label countdown;
        public event EventHandler Now, Pause, Cancel;

        public ConsentForm(Rectangle monitor, float scale, int seconds) : base(scale)
        {
            Bounds = monitor;
            BackColor = Color.FromArgb(24, 26, 32);
            Opacity = 0.94;
            int w = monitor.Width, cy = monitor.Height / 2;
            AddLabel("Агент хочет получить доступ к интерфейсу", 34, FontStyle.Bold, new Rectangle(0, cy - S(150), w, S(60)), Color.White, ContentAlignment.MiddleCenter);
            AddLabel("Агенту нужны клавиатура и мышь на время ввода в окно 1С. После ввода управление вернётся вам.", 18, FontStyle.Regular,
                new Rectangle(S(40), cy - S(80), w - S(80), S(40)), Color.Gainsboro, ContentAlignment.MiddleCenter);
            countdown = AddLabel("", 22, FontStyle.Regular, new Rectangle(0, cy - S(30), w, S(44)), Color.FromArgb(255, 210, 120), ContentAlignment.MiddleCenter);
            int bw = S(170), bh = S(46), gap = S(24), left = (w - 3 * bw - 2 * gap) / 2, top = cy + S(40);
            AddButton(this, "Сейчас", left, top, bw, bh, delegate { Raise(Now); });
            AddButton(this, "Пауза", left + bw + gap, top, bw, bh, delegate { Raise(Pause); });
            AddButton(this, "Отмена", left + 2 * (bw + gap), top, bw, bh, delegate { Raise(Cancel); });
            SetSeconds(seconds);
        }

        private void Raise(EventHandler handler) { if (handler != null) handler(this, EventArgs.Empty); }

        public void SetSeconds(int seconds)
        {
            countdown.Text = "Управление перейдёт агенту через " + seconds + " с";
        }
    }

    internal sealed class PanelForm : OverlayForm
    {
        public PanelForm(Rectangle workArea, Rectangle avoid, float scale, string text, string[] buttons, EventHandler[] handlers) : base(scale)
        {
            BackColor = Color.FromArgb(36, 40, 48);
            int bw = S(110), bh = S(34), pad = S(12);
            int width = Math.Max(S(360), pad + buttons.Length * (bw + pad));
            int height = S(56) + bh + pad;
            Size = new Size(width, height);
            AddLabel(text, 15, FontStyle.Regular, new Rectangle(pad, pad, width - 2 * pad, S(40)), Color.White, ContentAlignment.MiddleLeft);
            for (int i = 0; i < buttons.Length; i++)
            {
                AddButton(this, buttons[i], pad + i * (bw + pad), S(56), bw, bh, handlers[i]);
            }
            Location = Corner(workArea, avoid, Size, pad);
        }

        // The first monitor corner whose panel does not overlap the client window.
        private static Point Corner(Rectangle work, Rectangle avoid, Size size, int margin)
        {
            var candidates = new[]
            {
                new Point(work.Right - size.Width - margin, work.Bottom - size.Height - margin),
                new Point(work.Right - size.Width - margin, work.Top + margin),
                new Point(work.Left + margin, work.Bottom - size.Height - margin),
                new Point(work.Left + margin, work.Top + margin)
            };
            foreach (Point p in candidates)
            {
                if (avoid.IsEmpty || !new Rectangle(p, size).IntersectsWith(avoid)) return p;
            }
            return candidates[0];
        }
    }

    // ---------------------------------------------------------------- daemon
    internal sealed class LeaseRequest
    {
        public string Id = "";
        public string Scope = "";
        public uint Pid;
        public DateTime DeadlineUtc;
        public DateTime ReceivedUtc = DateTime.UtcNow;
    }

    internal enum LeaseState { Idle, Queued, Consent, Paused, IdleWait, Leased }

    internal static class Daemon
    {
        public static int Run(string dir)
        {
            var paths = new GroupPaths(dir);
            FileStream lockStream;
            try { lockStream = new FileStream(paths.Lock, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
            catch (IOException) { return 5; }
            using (lockStream)
            {
                GroupConfig config = GroupConfig.Load(paths);
                if (config.ProtocolVersion != Protocol.Version) return 6;
                Native.SetDpiAwareness();
                Directory.CreateDirectory(paths.Requests);
                Directory.CreateDirectory(paths.Responses);
                Directory.CreateDirectory(paths.Journal);
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                using (var context = new HelperContext(paths, config))
                {
                    Application.Run(context);
                }
            }
            return 0;
        }
    }

    internal sealed class HelperContext : ApplicationContext
    {
        private const int ReconcileMs = 2000;
        private const int LeaseIdleEndMs = 2000;
        private const int HoldLimitMs = 60000;
        private const int UserIdleMs = 300;
        private const int IdlePanelAfterMs = 5000;
        private const int CaptureLimitMs = 15000;
        private const int CompletionMs = 2500;

        private readonly GroupPaths paths;
        private readonly GroupConfig config;
        private readonly Control invoker;
        private readonly Membership members;
        private readonly LeaseMutex mutex = new LeaseMutex("Local\\ITL-UiLease");
        private readonly Native.WinEventDelegate eventProc;
        private readonly IntPtr foregroundHook;
        // Show events are hooked per client process: foreign windows never wake the helper.
        private readonly Dictionary<uint, IntPtr> clientHooks = new Dictionary<uint, IntPtr>();
        private readonly System.Windows.Forms.Timer reconcileTimer = new System.Windows.Forms.Timer();
        private readonly System.Windows.Forms.Timer stateTimer = new System.Windows.Forms.Timer();
        private readonly FileSystemWatcher watcher;
        private readonly uint ownPid = (uint)Process.GetCurrentProcess().Id;
        private readonly DateTime startedUtc = DateTime.UtcNow;
        private readonly Dictionary<uint, ProcessFacts> foreignFacts = new Dictionary<uint, ProcessFacts>();
        private readonly Dictionary<IntPtr, uint> hiddenByUs = new Dictionary<IntPtr, uint>();
        private readonly HashSet<string> seenRequests = new HashSet<string>();
        private readonly Queue<LeaseRequest> waiting = new Queue<LeaseRequest>();
        private readonly Dictionary<string, string> scopeDecisions = new Dictionary<string, string>();
        private readonly Dictionary<uint, DateTime> captures = new Dictionary<uint, DateTime>();
        // Clients the agent showed on request: kept visible, including their new windows,
        // until a hide request; the state lives only as long as this helper.
        private readonly HashSet<uint> revealed = new HashSet<uint>();
        // Per consent scope: leases, lease ms, consent wait ms, queue wait ms.
        private readonly Dictionary<string, long[]> scopeStats = new Dictionary<string, long[]>();
        private DateTime lastMembershipRefresh = DateTime.MinValue;
        private DateTime lastAnchorChange = DateTime.UtcNow;
        private IntPtr userWindow;

        private LeaseState state = LeaseState.Idle;
        private LeaseRequest current;
        private string currentScope;
        private uint leasedPid;
        private IntPtr leasedWindow;
        private string activation = "";
        private DateTime stateSince, mutexSince, leaseSince, lastLeaseRequest, pauseSince;
        private long queueWaitMs, consentWaitMs, idleWaitMs;
        private int leaseRequests;
        private bool idlePanelShown;
        private bool cancelled;
        private Native.POINT savedCursor;
        private bool cursorSaved;
        private ConsentForm consentForm;
        private PanelForm panel, leasePanel, completion;
        private DateTime completionSince;
        private int consentRemaining;
        private DateTime consentTick;

        public HelperContext(GroupPaths paths, GroupConfig config)
        {
            this.paths = paths;
            this.config = config;
            invoker = new Control();
            invoker.CreateControl();
            IntPtr ignoredHandle = invoker.Handle;
            members = new Membership(config.Roots, Membership.LoadAdopted(paths));
            eventProc = OnWinEvent;
            RefreshMembership();
            userWindow = Native.GetForegroundWindow();
            if (!UserEligible(userWindow)) userWindow = IntPtr.Zero;

            foregroundHook = Native.SetWinEventHook(Native.EVENT_SYSTEM_FOREGROUND, Native.EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, eventProc, 0, 0, Native.WINEVENT_OUTOFCONTEXT | Native.WINEVENT_SKIPOWNPROCESS);

            watcher = new FileSystemWatcher(paths.Requests, "*.json");
            watcher.NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite;
            watcher.Created += OnRequestFile;
            watcher.Renamed += OnRequestFile;
            watcher.Changed += OnRequestFile;
            watcher.EnableRaisingEvents = true;

            reconcileTimer.Interval = ReconcileMs;
            reconcileTimer.Tick += delegate { Reconcile(); };
            reconcileTimer.Start();
            stateTimer.Interval = 100;
            stateTimer.Tick += delegate { OnStateTick(); };

            // Windows left visible by a helper killed during a lease disappear on restart.
            HideClientWindows(null, "restart");
            ScanRequests();
            Process self = Process.GetCurrentProcess();
            ProcessFacts selfFacts = ProcessFacts.Read(ownPid);
            Json.WriteFileAtomic(paths.Identity, new Dictionary<string, object>
            {
                { "pid", ownPid }, { "creationTime", selfFacts.CreationTime }, { "exe", self.MainModule.FileName },
                { "startedUtc", startedUtc.ToString("o") }, { "protocol", Protocol.Version }, { "ready", true }
            });
            Native.TrimWorkingSet();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                foreach (IntPtr hook in clientHooks.Values) Native.UnhookWinEvent(hook);
                if (foregroundHook != IntPtr.Zero) Native.UnhookWinEvent(foregroundHook);
                watcher.Dispose();
                reconcileTimer.Dispose();
                stateTimer.Dispose();
                mutex.Dispose();
                invoker.Dispose();
            }
            base.Dispose(disposing);
        }

        // ------------------------------------------------ events
        private void OnRequestFile(object sender, FileSystemEventArgs e)
        {
            try { invoker.BeginInvoke(new MethodInvoker(ScanRequests)); } catch (InvalidOperationException) { }
        }

        private void OnWinEvent(IntPtr hook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
        {
            if (idObject != 0 || hwnd == IntPtr.Zero) return;
            if (eventType == Native.EVENT_SYSTEM_FOREGROUND) { OnForeground(hwnd); return; }
            if (eventType != Native.EVENT_OBJECT_SHOW || Native.GetAncestor(hwnd, 2) != hwnd) return;
            uint pid = Native.PidOf(hwnd);
            if (!members.Clients.Contains(pid) || Exposed(pid)) return;
            HideOutside(hwnd, pid, "shown");
        }

        private void OnForeground(IntPtr hwnd)
        {
            uint pid = Native.PidOf(hwnd);
            if (pid == ownPid) return;
            // A TestClient started since the last reconcile is joined at once.
            if (!members.Clients.Contains(pid) && Foreign(pid).IsTestClient &&
                (DateTime.UtcNow - lastMembershipRefresh).TotalMilliseconds >= 250) RefreshMembership();
            if (members.Clients.Contains(pid))
            {
                if (state == LeaseState.Leased && pid == leasedPid) return;
                // The user may click into a client the agent showed on request.
                if (revealed.Contains(pid)) return;
                string title = Native.TitleOf(hwnd);
                if (!Exposed(pid)) HideOutside(hwnd, pid, "foreground");
                string result = ReturnFocus();
                Journal(paths.HiddenLog, new Dictionary<string, object>
                {
                    { "t", Now() }, { "event", "foreground-returned" }, { "pid", pid }, { "title", title },
                    { "result", result }, { "userTitle", userWindow == IntPtr.Zero ? "" : Native.TitleOf(userWindow) }
                });
                return;
            }
            if (UserEligible(hwnd)) userWindow = hwnd;
        }

        private bool Exposed(uint pid)
        {
            return (state == LeaseState.Leased && pid == leasedPid) || captures.ContainsKey(pid) || revealed.Contains(pid);
        }

        private bool UserEligible(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return false;
            uint pid = Native.PidOf(hwnd);
            if (pid == 0 || pid == ownPid) return false;
            ProcessFacts f = Foreign(pid);
            return !(f.IsWindowHelper || f.IsTestClient || f.IsTestManager);
        }

        private ProcessFacts Foreign(uint pid)
        {
            ProcessFacts f;
            if (foreignFacts.TryGetValue(pid, out f)) return f;
            f = ProcessFacts.Read(pid);
            if (foreignFacts.Count > 512) foreignFacts.Clear();
            foreignFacts[pid] = f;
            return f;
        }

        private string ReturnFocus()
        {
            IntPtr target = userWindow;
            if (target == IntPtr.Zero || !Native.IsWindow(target) || !Native.IsWindowVisible(target))
            {
                // The remembered window is gone (for example a closed dialog): the topmost
                // eligible application window in Z order takes its place.
                target = FallbackUserWindow();
                if (target == IntPtr.Zero) return "no-user-window";
                userWindow = target;
            }
            return Native.Bring(target, Native.PidOf(target));
        }

        private IntPtr FallbackUserWindow()
        {
            IntPtr found = IntPtr.Zero;
            Native.EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                if (!Native.IsWindowVisible(h) || Native.IsIconic(h) || Native.GetWindow(h, 4) != IntPtr.Zero) return true;
                if ((Native.GetWindowLong(h, -20) & 0x80) != 0 || Native.TitleOf(h).Length == 0) return true;
                int cloaked;
                if (Native.DwmGetWindowAttribute(h, 14, out cloaked, 4) == 0 && cloaked != 0) return true;
                if (!UserEligible(h)) return true;
                found = h;
                return false;
            }, IntPtr.Zero);
            return found;
        }

        // ------------------------------------------------ hiding
        private void HideOutside(IntPtr hwnd, uint pid, string reason)
        {
            HideOutside(hwnd, pid, reason, true);
        }

        // A new window is journaled once with its image; re-hiding after a lease or a
        // capture is not a new appearance.
        private void HideOutside(IntPtr hwnd, uint pid, string reason, bool journal)
        {
            if (!Native.IsWindowVisible(hwnd)) return;
            journal = journal && !hiddenByUs.ContainsKey(hwnd);
            string title = Native.TitleOf(hwnd), cls = Native.ClassOf(hwnd);
            string image = "";
            if (journal && !title.StartsWith(WindowOps.SplashTitle, StringComparison.Ordinal) && WindowOps.IsSignificant(hwnd))
            {
                string path = Path.Combine(paths.Journal, "w-" + DateTime.UtcNow.ToString("HHmmssfff", CultureInfo.InvariantCulture) + "-" + hwnd.ToInt64().ToString("X", CultureInfo.InvariantCulture) + ".png");
                IntPtr target = hwnd;
                Task<bool> capture = Task.Factory.StartNew(delegate { try { return Native.Capture(target, path); } catch (Exception) { return false; } });
                // A busy 1C thread blocks PrintWindow; hiding never waits longer than 100 ms.
                // Thread.Sleep does not pump messages, so no event re-enters this handler.
                for (int waited = 0; waited < 100 && !capture.IsCompleted; waited += 5) Thread.Sleep(5);
                if (capture.IsCompleted && capture.Result) image = path;
            }
            Native.ShowWindowAsync(hwnd, Native.SW_HIDE);
            hiddenByUs[hwnd] = pid;
            if (journal && WindowOps.IsSignificant(hwnd))
            {
                Journal(paths.HiddenLog, new Dictionary<string, object>
                {
                    { "t", Now() }, { "event", "hidden" }, { "reason", reason }, { "pid", pid }, { "hwnd", hwnd.ToInt64() },
                    { "class", cls }, { "title", title }, { "image", image }
                });
                TrimJournal();
            }
        }

        private void HideClientWindows(uint? onlyPid, string reason)
        {
            foreach (uint pid in new List<uint>(members.Clients))
            {
                if (onlyPid.HasValue && pid != onlyPid.Value) continue;
                if (Exposed(pid)) continue;
                bool journal = reason != "lease-end" && reason != "capture-end" && reason != "hide-request";
                foreach (IntPtr h in Native.TopLevelWindows(pid))
                {
                    if (Native.IsWindowVisible(h)) HideOutside(h, pid, reason, journal);
                }
            }
        }

        private List<IntPtr> ShowClient(uint pid, bool bottom)
        {
            return ShowClient(pid, bottom ? Native.HWND_BOTTOM : IntPtr.Zero);
        }

        // insertAfter: HWND_BOTTOM under every window, another window to sit directly below
        // it, or zero for a plain show; none of them activates the client.
        private List<IntPtr> ShowClient(uint pid, IntPtr insertAfter)
        {
            var shown = new List<IntPtr>();
            IntPtr main = WindowOps.MainWindow(pid);
            if (main != IntPtr.Zero) shown.Add(main);
            foreach (var kv in hiddenByUs)
            {
                if (kv.Value == pid && kv.Key != main && Native.IsWindow(kv.Key) && WindowOps.IsSignificant(kv.Key) &&
                    !Native.TitleOf(kv.Key).StartsWith(WindowOps.SplashTitle, StringComparison.Ordinal)) shown.Add(kv.Key);
            }
            foreach (IntPtr h in shown)
            {
                if (insertAfter != IntPtr.Zero) Native.SetWindowPos(h, insertAfter, 0, 0, 0, 0, Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);
                else Native.ShowWindow(h, Native.SW_SHOWNA);
            }
            var stale = new List<IntPtr>();
            foreach (var kv in hiddenByUs) if (!Native.IsWindow(kv.Key)) stale.Add(kv.Key);
            foreach (IntPtr h in stale) hiddenByUs.Remove(h);
            return shown;
        }

        // ------------------------------------------------ reconcile
        private void RefreshMembership()
        {
            members.Refresh();
            lastMembershipRefresh = DateTime.UtcNow;
            SyncClientHooks();
        }

        private void SyncClientHooks()
        {
            foreach (uint pid in members.Clients)
            {
                if (clientHooks.ContainsKey(pid)) continue;
                IntPtr hook = Native.SetWinEventHook(Native.EVENT_OBJECT_SHOW, Native.EVENT_OBJECT_SHOW, IntPtr.Zero, eventProc, pid, 0, Native.WINEVENT_OUTOFCONTEXT);
                if (hook != IntPtr.Zero) clientHooks[pid] = hook;
            }
            var gone = new List<uint>();
            foreach (uint pid in clientHooks.Keys) if (!members.Clients.Contains(pid)) gone.Add(pid);
            foreach (uint pid in gone)
            {
                Native.UnhookWinEvent(clientHooks[pid]);
                clientHooks.Remove(pid);
            }
        }

        private void Reconcile()
        {
            ScanRequests();
            // Children appear early: full snapshots every 2 s for the first minute after a
            // start or an adopt, then every 60 s; status requests and a foreground TestClient
            // refresh at once.
            double sinceAnchor = (DateTime.UtcNow - lastAnchorChange).TotalSeconds;
            double sinceRefresh = (DateTime.UtcNow - lastMembershipRefresh).TotalSeconds;
            if (sinceAnchor < 60 || sinceRefresh >= 60) RefreshMembership();
            else { members.PruneExited(); SyncClientHooks(); }
            var expired = new List<uint>();
            foreach (var kv in captures) if ((DateTime.UtcNow - kv.Value).TotalMilliseconds > CaptureLimitMs) expired.Add(kv.Key);
            foreach (uint pid in expired) { captures.Remove(pid); }
            revealed.RemoveWhere(delegate(uint gone) { return !members.Clients.Contains(gone); });
            HideClientWindows(null, "reconcile");
            IntPtr fg = Native.GetForegroundWindow();
            if (fg != IntPtr.Zero && members.Clients.Contains(Native.PidOf(fg)) && !Exposed(Native.PidOf(fg))) ReturnFocus();
            bool quiet = state == LeaseState.Idle && waiting.Count == 0;
            if (quiet && members.SawRoot && members.Members.Count == 0) ExitThread();
            else if (quiet && !members.SawRoot && !members.HasAnchors && (DateTime.UtcNow - startedUtc).TotalSeconds > 60) ExitThread();
            else if (quiet && !members.SawRoot && members.HasAnchors && (DateTime.UtcNow - startedUtc).TotalSeconds > 60) ExitThread();
        }

        // ------------------------------------------------ requests
        private void ScanRequests()
        {
            string[] files;
            try { files = Directory.GetFiles(paths.Requests, "*.json"); }
            catch (IOException) { return; }
            Array.Sort(files, StringComparer.Ordinal);
            foreach (string file in files)
            {
                string name = Path.GetFileName(file);
                if (seenRequests.Contains(name)) continue;
                Dictionary<string, object> request;
                try { request = Json.ReadFile(file); }
                catch (IOException) { continue; }
                catch (Exception)
                {
                    seenRequests.Add(name);
                    TryDelete(file);
                    continue;
                }
                seenRequests.Add(name);
                TryDelete(file);
                Handle(request, Path.GetFileNameWithoutExtension(name));
            }
            if (seenRequests.Count > 4096) seenRequests.Clear();
        }

        private static void TryDelete(string file)
        {
            try { File.Delete(file); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }

        private void Respond(string id, string op, string status, Dictionary<string, object> fields)
        {
            var body = fields ?? new Dictionary<string, object>();
            body["protocol"] = Protocol.Version;
            body["id"] = id;
            body["op"] = op;
            body["status"] = status;
            try { Json.WriteFileAtomic(Path.Combine(paths.Responses, id + ".json"), body); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        private void Ack(string id)
        {
            try { File.WriteAllText(Path.Combine(paths.Responses, id + ".ack"), "accepted", new UTF8Encoding(false)); }
            catch (IOException) { }
        }

        private void Handle(Dictionary<string, object> request, string fileId)
        {
            string id = Json.Str(request, "id");
            if (id.Length == 0) id = fileId;
            string op = Json.Str(request, "op");
            if (Json.Num(request, "protocol", 0) != Protocol.Version)
            {
                Respond(id, op, "protocol-mismatch", new Dictionary<string, object> { { "expected", Protocol.Version } });
                return;
            }
            if (Array.IndexOf(Protocol.Operations, op) < 0)
            {
                Respond(id, op, "error", new Dictionary<string, object> { { "code", "unknown-op" } });
                return;
            }
            uint pid = (uint)Math.Max(0, Json.Num(request, "pid", 0));
            switch (op)
            {
                case "status": RespondStatus(id, (int)Json.Num(request, "port", 0)); break;
                case "adopt":
                    if (members.Adopt(pid))
                    {
                        lastAnchorChange = DateTime.UtcNow;
                        try { Json.WriteFileAtomic(paths.Adopted, new Dictionary<string, object> { { "pids", members.AdoptedPids.ToArray() } }); }
                        catch (IOException) { }
                    }
                    RefreshMembership();
                    HideClientWindows(null, "adopt");
                    Respond(id, op, "ok", new Dictionary<string, object> { { "members", members.Members.Count } });
                    break;
                case "capture-show": CaptureShow(id, pid); break;
                case "show": RevealShow(id, pid); break;
                case "hide": RevealHide(id, pid); break;
                case "capture-end": CaptureEnd(id, pid); break;
                case "lease-end": LeaseEnd(id, Json.Str(request, "scope"), Json.Bool(request, "endScope")); break;
                case "lease":
                    Ack(id);
                    var lease = new LeaseRequest();
                    lease.Id = id;
                    lease.Scope = Json.Str(request, "scope");
                    lease.Pid = pid;
                    DateTime deadline;
                    lease.DeadlineUtc = DateTime.TryParse(Json.Str(request, "deadlineUtc"), CultureInfo.InvariantCulture,
                        DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out deadline) ? deadline : DateTime.UtcNow.AddSeconds(60);
                    OnLease(lease);
                    break;
            }
        }

        private uint ResolveClient(uint requested)
        {
            if (requested != 0 && members.Clients.Contains(requested)) return requested;
            if (requested != 0)
            {
                RefreshMembership();
                if (members.Clients.Contains(requested)) return requested;
            }
            if (members.Clients.Count == 1) foreach (uint pid in members.Clients) return pid;
            return 0;
        }

        private void RespondStatus(string id, int port)
        {
            RefreshMembership();
            var clients = new List<object>();
            foreach (uint pid in members.Clients)
            {
                ProcessFacts f = members.Facts(pid);
                int clientPort = f == null ? 0 : f.TestPort;
                if (port > 0 && clientPort != port) continue;
                IntPtr main = WindowOps.MainWindow(pid);
                IntPtr popup = main == IntPtr.Zero ? IntPtr.Zero : Native.GetLastActivePopup(main);
                clients.Add(new Dictionary<string, object>
                {
                    { "pid", pid }, { "port", clientPort }, { "hwnd", main.ToInt64() }, { "activeHwnd", popup.ToInt64() },
                    { "title", main == IntPtr.Zero ? "" : Native.TitleOf(main) }
                });
            }
            Respond(id, "status", "ok", new Dictionary<string, object>
            {
                { "mode", config.Mode }, { "helperPid", ownPid }, { "members", members.Members.Count },
                { "clients", clients.ToArray() }, { "state", state.ToString().ToLowerInvariant() },
                { "revealed", new List<uint>(revealed).ToArray() }
            });
        }

        private void CaptureShow(string id, uint requested)
        {
            uint pid = ResolveClient(requested);
            if (pid == 0) { Respond(id, "capture-show", "error", new Dictionary<string, object> { { "code", "no-client" } }); return; }
            captures[pid] = DateTime.UtcNow;
            List<IntPtr> shown = (state == LeaseState.Leased && pid == leasedPid) ? new List<IntPtr> { leasedWindow } : ShowClient(pid, true);
            IntPtr main = WindowOps.MainWindow(pid);
            Respond(id, "capture-show", "ok", new Dictionary<string, object> { { "pid", pid }, { "hwnd", main.ToInt64() }, { "shown", shown.Count } });
        }

        // A show on request names a client of this group; any other process is refused
        // without touching its windows. With no PID the only client is meant.
        private uint ResolveMember(uint requested)
        {
            if (requested == 0) return ResolveClient(0);
            return ResolveClient(requested) == requested ? requested : 0;
        }

        private void RevealShow(string id, uint requested)
        {
            uint pid = ResolveMember(requested);
            if (pid == 0) { Respond(id, "show", "error", new Dictionary<string, object> { { "code", requested == 0 ? "no-client" : "not-member" } }); return; }
            revealed.Add(pid);
            // Directly below the user's active window: visible, while the foreground stays.
            IntPtr fg = Native.GetForegroundWindow();
            IntPtr after = fg != IntPtr.Zero && Native.PidOf(fg) != pid ? fg : Native.HWND_BOTTOM;
            List<IntPtr> shown = ShowClient(pid, after);
            Respond(id, "show", "ok", new Dictionary<string, object> { { "pid", pid }, { "hwnd", WindowOps.MainWindow(pid).ToInt64() }, { "shown", shown.Count } });
        }

        private void RevealHide(string id, uint requested)
        {
            uint pid = ResolveMember(requested);
            if (pid == 0) { Respond(id, "hide", "error", new Dictionary<string, object> { { "code", requested == 0 ? "no-client" : "not-member" } }); return; }
            revealed.Remove(pid);
            HideClientWindows(pid, "hide-request");
            Respond(id, "hide", "ok", new Dictionary<string, object> { { "pid", pid } });
        }

        private void CaptureEnd(string id, uint requested)
        {
            uint pid = ResolveClient(requested);
            if (pid != 0 && captures.Remove(pid)) HideClientWindows(pid, "capture-end");
            Respond(id, "capture-end", "ok", null);
        }

        // ------------------------------------------------ lease machine
        private void OnLease(LeaseRequest r)
        {
            if (r.Scope != currentScope)
            {
                if (currentScope != null) scopeDecisions.Remove(currentScope);
                if (state == LeaseState.Leased) EndLease("scope-changed");
                currentScope = r.Scope;
            }
            string decision;
            if (scopeDecisions.TryGetValue(r.Scope, out decision) && decision == "declined")
            {
                Decline(r, "scope-declined", false);
                return;
            }
            if (state == LeaseState.Leased)
            {
                if (r.Pid != 0 && r.Pid != leasedPid) EndLease("client-changed");
                else
                {
                    lastLeaseRequest = DateTime.UtcNow;
                    leaseRequests++;
                    string how = Native.PidOf(Native.GetForegroundWindow()) == leasedPid ? "kept" : Native.Bring(ActiveWindow(leasedPid), leasedPid);
                    if (how == "fail") { FailActivation(r); return; }
                    RespondLeaseOk(r, how);
                    return;
                }
            }
            if (state != LeaseState.Idle || current != null)
            {
                waiting.Enqueue(r);
                return;
            }
            Start(r);
        }

        private void Start(LeaseRequest r)
        {
            current = r;
            cancelled = false;
            queueWaitMs = consentWaitMs = idleWaitMs = 0;
            leaseRequests = 1;
            uint pid = ResolveClient(r.Pid);
            if (pid == 0) { Decline(r, "no-client", false); return; }
            r.Pid = pid;
            Enqueue(false);
        }

        private void Enqueue(bool consentGiven)
        {
            SetState(LeaseState.Queued);
            LeaseRequest r = current;
            mutex.Acquire(r.DeadlineUtc, delegate { return cancelled || current != r; }, delegate(bool got)
            {
                try { invoker.BeginInvoke(new MethodInvoker(delegate { OnMutex(r, got, consentGiven); })); }
                catch (InvalidOperationException) { }
            });
        }

        private void OnMutex(LeaseRequest r, bool got, bool consentGiven)
        {
            if (current != r) { if (got) mutex.Release(); return; }
            queueWaitMs += (long)(DateTime.UtcNow - stateSince).TotalMilliseconds;
            if (!got) { Decline(r, "deadline", false); return; }
            mutexSince = DateTime.UtcNow;
            if (consentGiven) scopeDecisions[r.Scope] = "granted";
            string decision;
            bool granted = config.CountdownSeconds == 0 || (scopeDecisions.TryGetValue(r.Scope, out decision) && decision == "granted");
            if (granted) EnterIdleWait();
            else EnterConsent();
        }

        private void SetState(LeaseState next)
        {
            state = next;
            stateSince = DateTime.UtcNow;
            stateTimer.Enabled = next != LeaseState.Idle || completion != null;
        }

        private IntPtr UserAnchor()
        {
            IntPtr anchor = userWindow != IntPtr.Zero && Native.IsWindow(userWindow) ? userWindow : Native.GetForegroundWindow();
            return anchor;
        }

        private float ScaleFor(IntPtr hwnd)
        {
            try
            {
                uint dpi = Native.GetDpiForWindow(hwnd);
                if (dpi > 0) return dpi / 96f;
            }
            catch (EntryPointNotFoundException) { }
            using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) return g.DpiX / 96f;
        }

        private void EnterConsent()
        {
            SetState(LeaseState.Consent);
            Rectangle bounds;
            IntPtr anchor = UserAnchor();
            Native.MonitorWorkArea(anchor, out bounds);
            consentRemaining = config.CountdownSeconds;
            consentForm = new ConsentForm(bounds, ScaleFor(anchor), consentRemaining);
            consentForm.Now += delegate { Grant(); };
            consentForm.Pause += delegate { EnterPause(); };
            consentForm.Cancel += delegate { DeclineScope("user-cancel"); };
            consentForm.Show();
            // The countdown starts only when the overlay is really visible on an interactive desktop.
            if (!Native.IsWindowVisible(consentForm.Handle) || !Native.InteractiveDesktop())
            {
                CloseForms();
                Decline(current, "consent-not-visible", false);
                return;
            }
            consentTick = DateTime.UtcNow;
        }

        private void Grant()
        {
            if (current == null) return;
            consentWaitMs += (long)(DateTime.UtcNow - stateSince).TotalMilliseconds;
            scopeDecisions[current.Scope] = "granted";
            CloseForms();
            EnterIdleWait();
        }

        private void EnterPause()
        {
            if (current == null) return;
            consentWaitMs += (long)(DateTime.UtcNow - stateSince).TotalMilliseconds;
            CloseForms();
            mutex.Release();
            SetState(LeaseState.Paused);
            pauseSince = DateTime.UtcNow;
            ShowPanel("Агент ждёт: можно продолжить, когда будете готовы", new[] { "Сейчас", "Отмена" },
                new EventHandler[] { delegate { ResumeFromPause(); }, delegate { DeclineScope("user-cancel"); } });
        }

        private void ResumeFromPause()
        {
            if (current == null || state != LeaseState.Paused) return;
            consentWaitMs += (long)(DateTime.UtcNow - stateSince).TotalMilliseconds;
            CloseForms();
            Enqueue(true);
        }

        private void EnterIdleWait()
        {
            SetState(LeaseState.IdleWait);
            idlePanelShown = false;
        }

        private void ShowPanel(string text, string[] buttons, EventHandler[] handlers)
        {
            CloseForms();
            Rectangle bounds;
            IntPtr anchor = UserAnchor();
            Rectangle work = Native.MonitorWorkArea(anchor, out bounds);
            Rectangle avoid = current != null ? Native.RectOf(WindowOps.MainWindow(current.Pid)) : Rectangle.Empty;
            panel = new PanelForm(work, avoid, ScaleFor(anchor), text, buttons, handlers);
            panel.Show();
        }

        private void CloseForms()
        {
            if (consentForm != null) { consentForm.Close(); consentForm.Dispose(); consentForm = null; }
            if (panel != null) { panel.Close(); panel.Dispose(); panel = null; }
        }

        private void CloseCompletion()
        {
            if (completion != null) { completion.Close(); completion.Dispose(); completion = null; }
        }

        private void OnStateTick()
        {
            DateTime now = DateTime.UtcNow;
            if (completion != null && (now - completionSince).TotalMilliseconds >= CompletionMs) CloseCompletion();
            if (current == null) { stateTimer.Enabled = state != LeaseState.Idle || completion != null; return; }
            bool pastDeadline = now >= current.DeadlineUtc;
            switch (state)
            {
                case LeaseState.Consent:
                    if (pastDeadline) { DeclineScope("deadline"); return; }
                    if ((now - consentTick).TotalMilliseconds >= 1000)
                    {
                        consentTick = now;
                        consentRemaining--;
                        if (consentRemaining <= 0) { Grant(); return; }
                        if (consentForm != null) consentForm.SetSeconds(consentRemaining);
                    }
                    break;
                case LeaseState.Paused:
                    if (pastDeadline) { DeclineScope("deadline"); return; }
                    if ((now - pauseSince).TotalSeconds >= config.PauseLimitSeconds) { DeclineScope("pause-limit"); return; }
                    break;
                case LeaseState.IdleWait:
                    if (pastDeadline) { DeclineScope("deadline"); return; }
                    if ((now - stateSince).TotalSeconds >= config.PauseLimitSeconds) { DeclineScope("pause-limit"); return; }
                    if (Native.IdleMilliseconds() >= UserIdleMs) { BeginLease("idle"); return; }
                    if (!idlePanelShown && (now - stateSince).TotalMilliseconds >= IdlePanelAfterMs)
                    {
                        idlePanelShown = true;
                        ShowPanel("Жду паузы в вашем вводе", new[] { "Сейчас", "Отмена" },
                            new EventHandler[] { delegate { BeginLease("now"); }, delegate { DeclineScope("user-cancel"); } });
                    }
                    if ((now - mutexSince).TotalMilliseconds >= HoldLimitMs)
                    {
                        idleWaitMs += (long)(now - stateSince).TotalMilliseconds;
                        CloseForms();
                        mutex.Release();
                        Enqueue(true);
                    }
                    break;
                case LeaseState.Leased:
                    if ((now - lastLeaseRequest).TotalMilliseconds >= LeaseIdleEndMs) { EndLease("idle-end"); return; }
                    if ((now - mutexSince).TotalMilliseconds >= HoldLimitMs) { EndLease("hold-limit"); return; }
                    break;
            }
        }

        private IntPtr ActiveWindow(uint pid)
        {
            IntPtr main = WindowOps.MainWindow(pid);
            if (main == IntPtr.Zero) return IntPtr.Zero;
            IntPtr popup = Native.GetLastActivePopup(main);
            return popup != IntPtr.Zero && Native.IsWindowVisible(popup) ? popup : main;
        }

        private void BeginLease(string trigger)
        {
            LeaseRequest r = current;
            if (r == null) return;
            idleWaitMs += (long)(DateTime.UtcNow - stateSince).TotalMilliseconds;
            CloseForms();
            CloseCompletion();
            IntPtr fg = Native.GetForegroundWindow();
            if (UserEligible(fg)) userWindow = fg;
            cursorSaved = Native.GetCursorPos(out savedCursor);
            leasedPid = r.Pid;
            SetState(LeaseState.Leased);
            leaseSince = DateTime.UtcNow;
            lastLeaseRequest = DateTime.UtcNow;
            ShowClient(r.Pid, false);
            leasedWindow = ActiveWindow(r.Pid);
            activation = Native.Bring(leasedWindow, r.Pid);
            if (activation == "fail" || Native.PidOf(Native.GetForegroundWindow()) != r.Pid)
            {
                FailActivation(r);
                return;
            }
            Rectangle bounds;
            Rectangle work = Native.MonitorWorkArea(leasedWindow, out bounds);
            leasePanel = new PanelForm(work, Native.RectOf(leasedWindow), ScaleFor(leasedWindow), "Агент управляет вводом", new[] { "Отмена" },
                new EventHandler[] { delegate { CancelLease(); } });
            leasePanel.Show();
            RespondLeaseOk(r, activation);
        }

        private void RespondLeaseOk(LeaseRequest r, string how)
        {
            IntPtr active = ActiveWindow(leasedPid);
            Respond(r.Id, "lease", "ok", new Dictionary<string, object>
            {
                { "pid", leasedPid }, { "hwnd", active.ToInt64() }, { "activation", how },
                { "consentWaitMs", consentWaitMs }, { "queueWaitMs", queueWaitMs }
            });
        }

        private void FailActivation(LeaseRequest r)
        {
            IntPtr fg = Native.GetForegroundWindow();
            string title = fg == IntPtr.Zero ? "" : Native.TitleOf(fg);
            Respond(r.Id, "lease", "error", new Dictionary<string, object>
            {
                { "code", Protocol.ActivationFailed }, { "foregroundTitle", title }, { "foregroundPid", Native.PidOf(fg) }
            });
            activation = "fail";
            EndLease("activation-failed", false);
        }

        private void CancelLease()
        {
            if (current == null) return;
            scopeDecisions[current.Scope] = "declined";
            EndLease("user-cancel");
        }

        private void EndLease(string outcome)
        {
            EndLease(outcome, true);
        }

        private void EndLease(string outcome, bool notify)
        {
            if (state != LeaseState.Leased) return;
            string returned = ReturnFocus();
            uint pid = leasedPid;
            leasedPid = 0;
            SetState(LeaseState.Idle);
            HideClientWindows(pid, "lease-end");
            if (cursorSaved) Native.SetCursorPos(savedCursor.X, savedCursor.Y);
            if (leasePanel != null) { leasePanel.Close(); leasePanel.Dispose(); leasePanel = null; }
            mutex.Release();
            long duration = (long)(DateTime.UtcNow - leaseSince).TotalMilliseconds;
            if (current != null) AddScopeStats(current.Scope, outcome == "activation-failed" ? 0 : 1, outcome == "activation-failed" ? 0 : duration);
            Journal(paths.LeaseLog, new Dictionary<string, object>
            {
                { "t", Now() }, { "scope", current == null ? "" : current.Scope }, { "pid", pid }, { "durationMs", duration },
                { "consentWaitMs", consentWaitMs }, { "queueWaitMs", queueWaitMs }, { "idleWaitMs", idleWaitMs },
                { "requests", leaseRequests }, { "activation", activation }, { "focusReturn", returned }, { "outcome", outcome }
            });
            if (notify)
            {
                Rectangle bounds;
                IntPtr anchor = UserAnchor();
                Rectangle work = Native.MonitorWorkArea(anchor, out bounds);
                completion = new PanelForm(work, Rectangle.Empty, ScaleFor(anchor), "Операция завершена, можно пользоваться", new[] { "OK" },
                    new EventHandler[] { delegate { CloseCompletion(); } });
                completion.Click += delegate { CloseCompletion(); };
                completion.Show();
                completionSince = DateTime.UtcNow;
                stateTimer.Enabled = true;
            }
            current = null;
            Next();
            if (current == null) Native.TrimWorkingSet();
        }

        private void LeaseEnd(string id, string scope, bool endScope)
        {
            if (state == LeaseState.Leased && current != null && current.Scope == scope) EndLease("lease-end");
            else if (endScope && current != null && current.Scope == scope && state != LeaseState.Idle) Decline(current, "scope-ended", false);
            long[] stats;
            if (!scopeStats.TryGetValue(scope, out stats)) stats = new long[4];
            if (endScope)
            {
                scopeDecisions.Remove(scope);
                scopeStats.Remove(scope);
                if (currentScope == scope) currentScope = null;
            }
            Respond(id, "lease-end", "ok", new Dictionary<string, object>
            {
                { "leases", stats[0] }, { "leaseMs", stats[1] }, { "consentWaitMs", stats[2] }, { "queueWaitMs", stats[3] }
            });
        }

        private void AddScopeStats(string scope, long leases, long leaseMs)
        {
            long[] stats;
            if (!scopeStats.TryGetValue(scope, out stats)) { stats = new long[4]; scopeStats[scope] = stats; }
            stats[0] += leases;
            stats[1] += leaseMs;
            stats[2] += consentWaitMs;
            stats[3] += queueWaitMs;
            if (scopeStats.Count > 256) scopeStats.Clear();
        }

        private void DeclineScope(string reason)
        {
            if (current == null) return;
            scopeDecisions[current.Scope] = "declined";
            Decline(current, reason, true);
        }

        private void Decline(LeaseRequest r, string reason, bool journal)
        {
            Respond(r.Id, "lease", "declined", new Dictionary<string, object> { { "code", Protocol.Declined }, { "reason", reason } });
            if (r != current) return;
            AddScopeStats(r.Scope, 0, 0);
            cancelled = true;
            CloseForms();
            if (mutex.Held || state == LeaseState.Consent || state == LeaseState.IdleWait) mutex.Release();
            if (journal || reason != "scope-declined")
            {
                Journal(paths.LeaseLog, new Dictionary<string, object>
                {
                    { "t", Now() }, { "scope", r.Scope }, { "pid", r.Pid }, { "durationMs", 0 }, { "consentWaitMs", consentWaitMs },
                    { "queueWaitMs", queueWaitMs }, { "idleWaitMs", idleWaitMs }, { "requests", 1 }, { "activation", "" }, { "outcome", "declined:" + reason }
                });
            }
            current = null;
            SetState(LeaseState.Idle);
            Next();
        }

        private void Next()
        {
            while (current == null && waiting.Count > 0)
            {
                LeaseRequest r = waiting.Dequeue();
                if (DateTime.UtcNow >= r.DeadlineUtc) { Respond(r.Id, "lease", "declined", new Dictionary<string, object> { { "code", Protocol.Declined }, { "reason", "deadline" } }); continue; }
                OnLease(r);
            }
        }

        // ------------------------------------------------ journal
        private static string Now() { return DateTime.UtcNow.ToString("o"); }

        private void Journal(string path, Dictionary<string, object> entry)
        {
            try { File.AppendAllText(path, Json.Write(entry) + "\n", new UTF8Encoding(false)); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        // Bounded diagnostics: at most 200 hidden-window lines and 30 images.
        private void TrimJournal()
        {
            try
            {
                string[] lines = File.ReadAllLines(paths.HiddenLog, Encoding.UTF8);
                if (lines.Length > 200)
                {
                    var keep = new string[100];
                    Array.Copy(lines, lines.Length - 100, keep, 0, 100);
                    File.WriteAllLines(paths.HiddenLog, keep, new UTF8Encoding(false));
                }
                var images = new List<FileInfo>(new DirectoryInfo(paths.Journal).GetFiles("w-*.png"));
                if (images.Count > 30)
                {
                    images.Sort(delegate(FileInfo a, FileInfo b) { return a.LastWriteTimeUtc.CompareTo(b.LastWriteTimeUtc); });
                    for (int i = 0; i < images.Count - 30; i++) images[i].Delete();
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
