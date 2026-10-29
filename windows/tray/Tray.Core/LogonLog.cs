using System.Diagnostics;
using System.Globalization;

namespace BenchBar.Tray.Core;

/// <summary>
/// Real logon to icon, measured on a real sign in: started with <c>--logon-log &lt;file&gt;</c>
/// (a shortcut in the Startup folder), a shell appends one line when its icon was added.
/// The sign in time comes from the System event log afterwards, so nothing here waits or polls.
/// </summary>
public static class LogonLog
{
    public static void IconAdded(string shell)
    {
        string? path = PathFromArgs(Environment.GetCommandLineArgs());
        if (path is null) return;
        try
        {
            using var process = Process.GetCurrentProcess();
            string line = string.Join(' ',
                $"shell={shell}",
                $"pid={Environment.ProcessId}",
                $"process_start_utc={process.StartTime.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture)}",
                $"icon_added_utc={DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture)}");
            File.AppendAllText(path, line + Environment.NewLine);
        }
        catch (Exception) { /* a measurement aid must never stop the app */ }
    }

    public static string? PathFromArgs(IReadOnlyList<string> args)
    {
        for (int i = 0; i < args.Count - 1; i++)
        {
            if (args[i] == "--logon-log") return args[i + 1];
        }
        return null;
    }
}
