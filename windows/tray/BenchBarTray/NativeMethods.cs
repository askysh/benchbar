using System.Runtime.InteropServices;

namespace BenchBar.Tray;

internal static partial class NativeMethods
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct Rect { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    internal struct MonitorInfo { public int Size; public Rect Monitor; public Rect Work; public uint Flags; }

    internal const int GwlExStyle = -20;
    internal const int WsExToolWindow = 0x80;
    internal const int WsExNoActivate = 0x08000000;
    internal const uint SwpNoSize = 0x1, SwpNoZOrder = 0x4, SwpNoActivate = 0x10;
    internal const uint MonitorDefaultToPrimary = 1;
    internal const int MdtEffectiveDpi = 0;

    [LibraryImport("user32.dll", EntryPoint = "FindWindowW", StringMarshalling = StringMarshalling.Utf16)]
    internal static partial IntPtr FindWindow(string cls, string? title);

    [LibraryImport("user32.dll")]
    internal static partial IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);

    [LibraryImport("user32.dll", EntryPoint = "GetMonitorInfoW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);

    [LibraryImport("shcore.dll")]
    internal static partial int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetWindowRect(IntPtr hwnd, out Rect rect);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);

    [LibraryImport("user32.dll", EntryPoint = "GetWindowLongW")]
    internal static partial int GetWindowLong(IntPtr hwnd, int index);

    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongW")]
    internal static partial int SetWindowLong(IntPtr hwnd, int index, int value);

    [StructLayout(LayoutKind.Sequential)]
    internal unsafe struct StockIconInfo
    {
        public uint Size;
        public IntPtr Icon;
        public int SysImageIndex;
        public int IconIndex;
        public fixed char Path[260];
    }

    internal const int AsfwAny = -1;

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool AllowSetForegroundWindow(int processId);

    [StructLayout(LayoutKind.Sequential)]
    internal struct ScreenPoint { public int X, Y; }

    internal const uint MonitorDefaultToNearest = 2;

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetCursorPos(out ScreenPoint point);

    [LibraryImport("user32.dll")]
    internal static partial IntPtr MonitorFromPoint(ScreenPoint point, uint flags);

    /// <summary>ES_CONTINUOUS and ES_SYSTEM_REQUIRED: the state belongs to the calling thread and lasts until it is cleared or the thread ends.</summary>
    internal const uint EsContinuous = 0x80000000, EsSystemRequired = 0x00000001;

    [LibraryImport("kernel32.dll")]
    internal static partial uint SetThreadExecutionState(uint flags);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool SetForegroundWindow(IntPtr hwnd);

    [LibraryImport("user32.dll")]
    internal static partial IntPtr GetForegroundWindow();

    [StructLayout(LayoutKind.Sequential)]
    internal struct FlashInfo { public uint Size; public IntPtr Hwnd; public uint Flags; public uint Count; public uint Timeout; }

    /// <summary>FLASHW_ALL (caption and taskbar button) with FLASHW_TIMERNOFG (until the window comes to the front).</summary>
    internal const uint FlashAllUntilForeground = 0x3 | 0xC;

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool FlashWindowEx(ref FlashInfo info);

    internal const int SiidShield = 77;
    internal const uint ShgsiIcon = 0x100, ShgsiSmallIcon = 0x1;

    [LibraryImport("shell32.dll")]
    internal static partial int SHGetStockIconInfo(int id, uint flags, ref StockIconInfo info);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool DestroyIcon(IntPtr icon);
}
