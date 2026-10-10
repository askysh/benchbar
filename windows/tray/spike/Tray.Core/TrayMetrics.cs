using Microsoft.Win32;

namespace BenchBar.Tray.Core;

/// <summary>Whether the taskbar is light or dark, which decides the template runner's tint.</summary>
public static class TaskbarTheme
{
    private const string PersonalizeKey = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    /// <summary>
    /// True when <c>SystemUsesLightTheme</c> is 1. Dark (0) or missing counts as
    /// dark, which is the Windows 11 default.
    /// </summary>
    public static bool IsLight()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(PersonalizeKey);
            return key?.GetValue("SystemUsesLightTheme") is int value && value == 1;
        }
        catch (Exception)
        {
            return false;
        }
    }
}

/// <summary>The tray slot's size and the settings that change how the icon animates.</summary>
public static class TrayMetrics
{
    /// <summary>The square icon side for a DPI: 16 at 96, 20 at 120, 24 at 144, 32 at 192.</summary>
    public static int IconSide(uint dpi)
    {
        var side = Native.GetSystemMetricsForDpi(Native.SM_CXSMICON, dpi == 0 ? 96 : dpi);
        return side > 0 ? side : 16;
    }

    /// <summary>The DPI of the monitor holding the taskbar (<c>Shell_TrayWnd</c>), else the system DPI.</summary>
    public static uint TaskbarDpi()
    {
        try
        {
            var taskbar = Native.FindWindow("Shell_TrayWnd", null);
            if (taskbar != IntPtr.Zero)
            {
                var monitor = Native.MonitorFromWindow(taskbar, Native.MONITOR_DEFAULTTOPRIMARY);
                if (monitor != IntPtr.Zero && Native.GetDpiForMonitor(monitor, Native.MDT_EFFECTIVE_DPI, out var dpiX, out _) == 0 && dpiX > 0)
                    return dpiX;
            }
        }
        catch (Exception) { /* fall through to the system DPI */ }
        var system = Native.GetDpiForSystem();
        return system == 0 ? 96 : system;
    }

    /// <summary>"Show animations in Windows" off means reduce motion.</summary>
    /// <summary>
    /// The system's "animation effects" switch, unless BENCHBAR_TRAY_REDUCE_MOTION says 0 or 1: the harness
    /// sets 0 for both shells, because a CI runner has animations off and would measure a still frame.
    /// </summary>
    public static bool ReduceMotion() => Environment.GetEnvironmentVariable("BENCHBAR_TRAY_REDUCE_MOTION") switch
    {
        "0" => false,
        "1" => true,
        _ => Native.SystemParametersInfo(Native.SPI_GETCLIENTAREAANIMATION, 0, out var enabled, 0) && enabled == 0,
    };
}
