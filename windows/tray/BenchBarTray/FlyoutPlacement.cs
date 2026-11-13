namespace BenchBar.Tray;

/// <summary>Where the flyout goes: the monitor of the click, and the corner of it nearest the notification area.</summary>
internal static class FlyoutPlacement
{
    public const double EdgeMargin = 12;

    /// <summary>
    /// The monitor the cursor is on: the click on the taskbar icon happened there, and with a taskbar on each monitor that is the one whose
    /// icon was clicked. Without a cursor position (the call failed) the monitor of the primary taskbar.
    /// </summary>
    public static IntPtr MonitorOfClick()
    {
        if (NativeMethods.GetCursorPos(out var point)) return NativeMethods.MonitorFromPoint(point, NativeMethods.MonitorDefaultToNearest);
        var taskbar = NativeMethods.FindWindow("Shell_TrayWnd", null);
        return NativeMethods.MonitorFromWindow(taskbar, NativeMethods.MonitorDefaultToPrimary);
    }

    /// <summary>
    /// The top left corner, in pixels of that monitor, for a window of the given physical size: against the taskbar's edge, found from the
    /// difference between the monitor and its work area (a taskbar on top moves the work area's top down, on the left its left edge right).
    /// </summary>
    public static (int X, int Y) Anchor(NativeMethods.Rect work, NativeMethods.Rect monitor, uint dpi, int widthPx, int heightPx)
    {
        var margin = (int)Math.Round(EdgeMargin * dpi / 96.0);
        if (work.Top > monitor.Top) return (work.Right - widthPx - margin, work.Top + margin);        // taskbar on top
        if (work.Left > monitor.Left) return (work.Left + margin, work.Bottom - heightPx - margin);   // taskbar on the left
        return (work.Right - widthPx - margin, work.Bottom - heightPx - margin);                      // bottom or right
    }
}
