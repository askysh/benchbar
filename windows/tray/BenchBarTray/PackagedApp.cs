using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// The package's startup task (<c>BenchBarTrayLogon</c> in the manifest) through the WinRT projection, which the project already carries
/// (<c>net10.0-windows10.0.19041.0</c>: <c>Microsoft.Windows.SDK.NET.dll</c> is in the publish with or without this class). Only a packaged
/// process may call it: the caller checks <see cref="IPackageInfo.IsPackaged"/> first, and the type is never touched at start.
/// </summary>
internal sealed class WinRtStartupTask : IStartupTask
{
    public const string TaskId = "BenchBarTrayLogon";

    public async Task<Core.StartupTaskState> GetStateAsync()
    {
        var task = await Windows.ApplicationModel.StartupTask.GetAsync(TaskId);
        return Map(task.State);
    }

    public async Task<Core.StartupTaskState> RequestEnableAsync()
    {
        var task = await Windows.ApplicationModel.StartupTask.GetAsync(TaskId);
        return Map(await task.RequestEnableAsync());
    }

    public async Task DisableAsync()
    {
        var task = await Windows.ApplicationModel.StartupTask.GetAsync(TaskId);
        task.Disable();
    }

    internal static Core.StartupTaskState Map(Windows.ApplicationModel.StartupTaskState state) => state switch
    {
        Windows.ApplicationModel.StartupTaskState.Enabled => Core.StartupTaskState.Enabled,
        Windows.ApplicationModel.StartupTaskState.DisabledByUser => Core.StartupTaskState.DisabledByUser,
        Windows.ApplicationModel.StartupTaskState.DisabledByPolicy => Core.StartupTaskState.DisabledByPolicy,
        Windows.ApplicationModel.StartupTaskState.EnabledByPolicy => Core.StartupTaskState.EnabledByPolicy,
        _ => Core.StartupTaskState.Disabled,
    };
}

/// <summary>
/// The one shot flag that opens the setup wizard after Windows restarts. Unpackaged it is the <c>BenchBar Setup Resume.lnk</c> shortcut in the Startup
/// folder, as before. Packaged nothing may be written to the Startup folder, so the flag is a file <c>resume-setup</c> in the data folder: the tray reads it
/// when it starts (at logon when open at logon is on, or when the person opens BenchBar) and removes it.
/// </summary>
internal sealed class ResumeFlag(IPackageInfo package, StartupShortcut shortcut, string? markerPath = null)
{
    public const string MarkerName = "resume-setup";

    private readonly string _marker = markerPath ?? DataFolder.In(MarkerName);

    public string MarkerPath => _marker;

    /// <summary>The flag is set (packaged only: the shortcut's flag is passed as an argument).</summary>
    public bool IsSet => package.IsPackaged && File.Exists(_marker);

    public void Enable()
    {
        if (!package.IsPackaged)
        {
            shortcut.Enable();
            return;
        }
        Directory.CreateDirectory(Path.GetDirectoryName(_marker)!);
        File.WriteAllText(_marker, "resume");
    }

    public void Disable()
    {
        if (!package.IsPackaged)
        {
            shortcut.Disable();
            return;
        }
        if (File.Exists(_marker)) File.Delete(_marker);
    }
}
