using System.Runtime.InteropServices;

namespace BenchBar.Tray.WinUI;

/// <summary>Where the taskbar sits: its monitor, that monitor's DPI and the work area.</summary>
internal readonly record struct TaskbarPlacement(Native.Rect Monitor, Native.Rect Work, uint Dpi)
{
    public enum Edge { Bottom, Top, Left, Right }

    public static TaskbarPlacement Find()
    {
        var taskbar = Native.FindWindow("Shell_TrayWnd", null);
        var monitor = Native.MonitorFromWindow(taskbar, Native.MONITOR_DEFAULTTOPRIMARY);
        var info = new Native.MonitorInfo { Size = Marshal.SizeOf<Native.MonitorInfo>() };
        if (monitor == IntPtr.Zero || !Native.GetMonitorInfo(monitor, ref info))
            return new TaskbarPlacement(new Native.Rect { Right = 1920, Bottom = 1080 }, new Native.Rect { Right = 1920, Bottom = 1040 }, 96);
        uint dpi = 96;
        if (Native.GetDpiForMonitor(monitor, 0, out var x, out _) == 0 && x > 0) dpi = x;
        return new TaskbarPlacement(info.Monitor, info.Work, dpi);
    }

    /// <summary>The edge the taskbar is on, read from where the work area is smaller than the monitor.</summary>
    public Edge TaskbarEdge =>
        Work.Top > Monitor.Top ? Edge.Top :
        Work.Left > Monitor.Left ? Edge.Left :
        Work.Right < Monitor.Right ? Edge.Right : Edge.Bottom;

    /// <summary>Top left of a window of the given physical size: against the tray corner, with a small gap.</summary>
    public (int X, int Y) Place(int width, int height)
    {
        var gap = (int)Math.Round(12 * Dpi / 96.0);
        return TaskbarEdge switch
        {
            Edge.Top => (Work.Right - width - gap, Work.Top + gap),
            Edge.Left => (Work.Left + gap, Work.Bottom - height - gap),
            _ => (Work.Right - width - gap, Work.Bottom - height - gap),
        };
    }
}
