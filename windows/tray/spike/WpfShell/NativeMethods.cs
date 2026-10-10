using System.Runtime.InteropServices;

namespace BenchBar.Tray.Wpf;

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
}
