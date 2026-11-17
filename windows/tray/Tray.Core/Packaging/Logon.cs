namespace BenchBar.Tray.Core;

/// <summary>The states of a package's startup task, as the WinRT <c>StartupTaskState</c> reports them.</summary>
public enum StartupTaskState { Disabled, DisabledByUser, Enabled, DisabledByPolicy, EnabledByPolicy }

/// <summary>The packaged side of "Open BenchBar at logon": the manifest's startup task. The WinRT calls live in the app, behind this.</summary>
public interface IStartupTask
{
    Task<StartupTaskState> GetStateAsync();

    /// <summary>Asks Windows to turn the task on; the answer is the state after (DisabledByUser stays off: only the person can turn it on again).</summary>
    Task<StartupTaskState> RequestEnableAsync();

    Task DisableAsync();
}

/// <summary>The unpackaged side: the Startup folder shortcut.</summary>
public interface IShortcutLogon
{
    bool IsEnabled();

    void Enable();

    void Disable();
}

/// <summary>What the switch shows: on or off, whether the person can change it here, and one line when they cannot (with a button to Startup settings).</summary>
public sealed record LogonView(bool IsOn, bool CanChange, string? Note = null, bool ShowSettingsButton = false)
{
    public const string SettingsUri = "ms-settings:startupapps";
    public const string SettingsButton = "Open Startup Settings";
    public const string TurnedOffInWindows = "Open at logon is turned off in Windows. Turn it on in Settings > Apps > Startup.";
    public const string TurnedOffByPolicy = "Open at logon is turned off by a policy on this PC. Settings > Apps > Startup shows its state.";
    public const string TurnedOnByPolicy = "Open at logon is turned on by a policy on this PC.";
    public const string Unreadable = "BenchBar could not read the startup setting. Check Settings > Apps > Startup.";

    /// <summary>Before the first answer: off, and not changeable until it is known (so a click cannot race the read).</summary>
    public static LogonView Loading { get; } = new(false, false);

    public static LogonView FromTask(StartupTaskState state) => state switch
    {
        StartupTaskState.Enabled => new LogonView(true, true),
        StartupTaskState.Disabled => new LogonView(false, true),
        StartupTaskState.DisabledByUser => new LogonView(false, false, TurnedOffInWindows, true),
        StartupTaskState.DisabledByPolicy => new LogonView(false, false, TurnedOffByPolicy, true),
        StartupTaskState.EnabledByPolicy => new LogonView(true, false, TurnedOnByPolicy),
        _ => new LogonView(false, false, Unreadable, true),
    };
}

/// <summary>The surface Settings, the tray menu and the wizard use.</summary>
public interface ILogonControl
{
    LogonView View { get; }

    event Action? Changed;

    Task RefreshAsync();

    Task SetAsync(bool on);
}

/// <summary>
/// Open at logon in both states. Not packaged: the Startup shortcut, as before. Packaged: the package's startup task only, and nothing in the
/// Startup folder is read, written or deleted (it holds the other install's shortcut, and a shortcut to a versioned WindowsApps folder breaks on update).
/// The WinRT task is touched only when Settings, the menu or the wizard asks, never at start.
/// </summary>
public sealed class LogonModel(IPackageInfo package, IShortcutLogon shortcut, IStartupTask? task, Action<Exception>? fault = null) : ILogonControl
{
    private readonly Lock _gate = new();
    private LogonView _view = package.IsPackaged ? LogonView.Loading : new LogonView(false, true);
    private bool _read;

    public event Action? Changed;

    public bool IsPackaged => package.IsPackaged;

    public LogonView View
    {
        get { lock (_gate) return _view; }
    }

    public async Task RefreshAsync()
    {
        if (!package.IsPackaged || task is null)
        {
            Publish(ReadShortcut());
            return;
        }
        try
        {
            Publish(LogonView.FromTask(await task.GetStateAsync().ConfigureAwait(true)));
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            fault?.Invoke(ex);
            Publish(LogonView.FromTask((StartupTaskState)(-1)));
        }
    }

    public async Task SetAsync(bool on)
    {
        if (!package.IsPackaged || task is null)
        {
            try
            {
                if (on) shortcut.Enable(); else shortcut.Disable();
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                fault?.Invoke(ex);
            }
            Publish(ReadShortcut());
            return;
        }
        try
        {
            if (on)
            {
                Publish(LogonView.FromTask(await task.RequestEnableAsync().ConfigureAwait(true)));
            }
            else
            {
                await task.DisableAsync().ConfigureAwait(true);
                Publish(LogonView.FromTask(await task.GetStateAsync().ConfigureAwait(true)));
            }
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            fault?.Invoke(ex);
            Publish(LogonView.FromTask((StartupTaskState)(-1)));
        }
    }

    private LogonView ReadShortcut()
    {
        try
        {
            return new LogonView(shortcut.IsEnabled(), true);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            fault?.Invoke(ex);
            return new LogonView(false, true);
        }
    }

    private void Publish(LogonView view)
    {
        bool changed;
        lock (_gate)
        {
            changed = !_read || _view != view;
            _view = view;
            _read = true;
        }
        if (changed) Changed?.Invoke();
    }
}
