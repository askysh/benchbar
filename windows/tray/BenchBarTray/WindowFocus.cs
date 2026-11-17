using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace BenchBar.Tray;

/// <summary>
/// Brings a window forward when the tray opened it by itself (a launch check, a resume after a restart, the installer starting the tray).
/// A program that does not have the foreground cannot take it: Activate then only flashes the taskbar button and the window stays behind
/// others, which on the first run wizard is the only way forward. So: restore, Activate, the topmost toggle, SetForegroundWindow, and
/// when Windows still refuses, flash the taskbar button until the person comes to it.
/// </summary>
internal static class WindowFocus
{
    /// <summary>True when the window ended in front; false when Windows refused and the taskbar button flashes instead.</summary>
    public static bool Raise(Window window)
    {
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        if (!window.IsVisible) window.Show();
        window.Activate();
        // Topmost for a moment puts the window above the others without leaving it there
        window.Topmost = true;
        window.Topmost = false;
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return window.IsActive;
        try
        {
            if (NativeMethods.GetForegroundWindow() != hwnd) NativeMethods.SetForegroundWindow(hwnd);
            if (NativeMethods.GetForegroundWindow() == hwnd) return true;
            Flash(hwnd);
            return false;
        }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException or COMException)
        {
            return window.IsActive;
        }
    }

    private static void Flash(IntPtr hwnd)
    {
        var info = new NativeMethods.FlashInfo
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.FlashInfo>(),
            Hwnd = hwnd,
            Flags = NativeMethods.FlashAllUntilForeground,
            Count = uint.MaxValue,
            Timeout = 0,
        };
        NativeMethods.FlashWindowEx(ref info);
    }
}
