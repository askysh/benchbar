using System.Runtime.InteropServices;

namespace BenchBar.Tray.Harness;

internal static partial class Native
{
    public const uint ProcessSetQuota = 0x0100;
    public const uint ProcessQueryLimitedInformation = 0x1000;
    public const uint TokenAdjustPrivileges = 0x0020;
    public const uint TokenQuery = 0x0008;
    public const uint SePrivilegeEnabled = 2;
    public const int ErrorNotAllAssigned = 1300;
    public const uint SrcCopy = 0x00CC0020;
    public const uint CaptureBlt = 0x40000000;

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct TokenPrivileges
    {
        public uint Count;
        public long Luid;
        public uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct BitmapInfoHeader
    {
        public uint Size;
        public int Width;
        public int Height;
        public ushort Planes;
        public ushort BitCount;
        public uint Compression;
        public uint SizeImage;
        public int XPelsPerMeter;
        public int YPelsPerMeter;
        public uint ClrUsed;
        public uint ClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MemoryStatusEx
    {
        public uint Length;
        public uint MemoryLoad;
        public ulong TotalPhys;
        public ulong AvailPhys;
        public ulong TotalPageFile;
        public ulong AvailPageFile;
        public ulong TotalVirtual;
        public ulong AvailVirtual;
        public ulong AvailExtendedVirtual;
    }

    [LibraryImport("kernel32.dll", SetLastError = true)]
    public static partial IntPtr OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint pid);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool CloseHandle(IntPtr handle);

    [LibraryImport("kernel32.dll", EntryPoint = "K32EmptyWorkingSet")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool EmptyWorkingSet(IntPtr process);

    [LibraryImport("kernel32.dll")]
    public static partial IntPtr GetCurrentProcess();

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GlobalMemoryStatusEx(ref MemoryStatusEx status);

    [LibraryImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

    [LibraryImport("advapi32.dll", EntryPoint = "LookupPrivilegeValueW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool LookupPrivilegeValue(string? system, string name, out long luid);

    [LibraryImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool AdjustTokenPrivileges(IntPtr token, [MarshalAs(UnmanagedType.Bool)] bool disableAll, ref TokenPrivileges state, uint length, IntPtr previous, IntPtr returned);

    [LibraryImport("ntdll.dll")]
    public static partial int NtSetSystemInformation(int infoClass, ref int info, int length);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetProcessDpiAwarenessContext(IntPtr context);

    [LibraryImport("user32.dll")]
    public static partial uint GetDpiForSystem();

    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }

    /// <summary>The window's visible bounds without the invisible resize border (DWMWA_EXTENDED_FRAME_BOUNDS = 9).</summary>
    [LibraryImport("dwmapi.dll")]
    public static partial int DwmGetWindowAttribute(IntPtr window, int attribute, out Rect rect, int size);

    [LibraryImport("user32.dll")]
    public static partial IntPtr GetDC(IntPtr window);

    [LibraryImport("user32.dll")]
    public static partial int ReleaseDC(IntPtr window, IntPtr dc);

    [LibraryImport("gdi32.dll")]
    public static partial IntPtr CreateCompatibleDC(IntPtr dc);

    [LibraryImport("gdi32.dll")]
    public static partial IntPtr CreateCompatibleBitmap(IntPtr dc, int width, int height);

    [LibraryImport("gdi32.dll")]
    public static partial IntPtr SelectObject(IntPtr dc, IntPtr obj);

    [LibraryImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool DeleteObject(IntPtr obj);

    [LibraryImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool DeleteDC(IntPtr dc);

    [LibraryImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool BitBlt(IntPtr dest, int x, int y, int w, int h, IntPtr src, int sx, int sy, uint rop);

    [LibraryImport("gdi32.dll")]
    public static partial int GetDIBits(IntPtr dc, IntPtr bitmap, uint start, uint lines, Span<byte> bits, ref BitmapInfoHeader info, uint usage);
}
