namespace BenchBar.Tray.Core;

/// <summary>What Settings changes outside the config file.</summary>
public interface ISettingsHost
{
    bool OpenAtLogon { get; set; }

    void ApplyAppearance(AppearanceMode mode);

    void ApplyRunner(string id);

    void ApplyNotifications(bool on);

    /// <summary>The path of benchbar.exe to show, or null: packaged, the alias in WindowsApps (see <see cref="ShimPathDisplay"/>).</summary>
    string? ShimPath { get; }

    /// <summary>Packaged (Microsoft Store) or not: a packaged tray has no GitHub update check and keeps open at logon in the package's startup task.</summary>
    IPackageInfo Package => PackageInfo.Unpackaged;

    /// <summary>The logon switch when it is more than a boolean (the packaged startup task); null: use <see cref="OpenAtLogon"/>.</summary>
    ILogonControl? Logon => null;

    /// <summary>Opens Windows' Settings > Apps > Startup (<c>ms-settings:startupapps</c>).</summary>
    void OpenStartupSettings() { }

    /// <summary>The distro BenchBar uses changed: poll now instead of waiting out the back off.</summary>
    void DistroSwitched() { }
}

/// <summary>
/// The Settings window as a value: General (open at logon, notifications, update check, distro, editor, CLI path) and Tray
/// (appearance, runner). Every setter writes the config through <c>save</c> and tells the host, so the window holds no rules.
/// </summary>
public sealed class SettingsModel(TrayConfig config, ISettingsHost host, ISetupService setup, Action save)
{
    public event Action? Changed;

    public IReadOnlyList<DistroInfo> Distros { get; private set; } = [];

    public bool LoadingDistros { get; private set; }

    /// <summary>The line under the distro picker: the result of switching, or a note when WSL lists nothing.</summary>
    public string? DistroMessage { get; private set; }

    public bool SwitchingDistro { get; private set; }

    public bool OpenAtLogon
    {
        get => LogonView.IsOn;
        set
        {
            if (host.Logon is { } control) control.SetAsync(value).Forget();
            else
            {
                host.OpenAtLogon = value;
                Changed?.Invoke();
            }
        }
    }

    /// <summary>The logon switch: on or off, whether it can be changed here and the line that says why not.</summary>
    public LogonView LogonView => host.Logon?.View ?? new LogonView(host.OpenAtLogon, true);

    /// <summary>Reads the packaged startup task's state (the first time it is needed) and tells the window when it arrives.</summary>
    public async Task LoadLogonAsync()
    {
        if (host.Logon is not { } control) return;
        control.Changed -= RaiseChanged;
        control.Changed += RaiseChanged;
        await control.RefreshAsync().ConfigureAwait(true);
        Changed?.Invoke();
    }

    /// <summary>Stops listening to the logon switch; the window calls it when it closes.</summary>
    public void Detach()
    {
        if (host.Logon is { } control) control.Changed -= RaiseChanged;
    }

    private void RaiseChanged() => Changed?.Invoke();

    public bool IsPackaged => host.Package.IsPackaged;

    /// <summary>Packaged: the Store updates the programs, so there is no "check for updates" switch.</summary>
    public bool ShowsUpdateCheck => UpdatePolicy.ChecksGitHub(host.Package);

    public void OpenStartupSettings() => host.OpenStartupSettings();

    public bool Notifications
    {
        get => config.Notifications;
        set
        {
            config.Notifications = value;
            save();
            host.ApplyNotifications(value);
            Changed?.Invoke();
        }
    }

    public bool CheckForUpdates
    {
        get => config.CheckForUpdates;
        set
        {
            config.CheckForUpdates = value;
            save();
            Changed?.Invoke();
        }
    }

    public string Editor
    {
        get => EditorKind.Normalize(config.Editor);
        set
        {
            config.Editor = EditorKind.Normalize(value);
            save();
            Changed?.Invoke();
        }
    }

    public AppearanceMode Appearance
    {
        get => config.Appearance;
        set
        {
            config.Appearance = value;
            save();
            host.ApplyAppearance(value);
            Changed?.Invoke();
        }
    }

    public string RunnerId
    {
        get => config.RunnerId;
        set
        {
            config.RunnerId = value;
            save();
            host.ApplyRunner(value);
            Changed?.Invoke();
        }
    }

    /// <summary>The distro BenchBar uses: the shim's <c>distro</c> key, else the pick the tray makes (a Docker or Rancher default is skipped).</summary>
    public string? CurrentDistro => DistroName.Resolve(config.Distro, () => DistroName.Pick(Distros.Select(d => (d.Name, d.IsDefault)).ToList()));

    public string? CliPath => config.CliPath;

    public string? ShimPath => host.ShimPath;

    /// <summary>The text of the CLI path row: the shim's cli_path, else the shim itself.</summary>
    public string CliPathText => config.CliPath is { Length: > 0 } p ? p : host.ShimPath ?? "benchbar.exe was not found";

    /// <summary><c>wsl.exe --list --verbose</c>; never boots a distro.</summary>
    public async Task LoadDistrosAsync(CancellationToken ct = default)
    {
        LoadingDistros = true;
        Changed?.Invoke();
        try
        {
            Distros = await setup.ListDistrosAsync(ct).ConfigureAwait(true);
            DistroMessage = Distros.Count == 0 ? "WSL lists no distro. Run the setup from the + menu." : null;
        }
        finally
        {
            LoadingDistros = false;
            Changed?.Invoke();
        }
    }

    /// <summary>Makes another distro the one BenchBar uses (the shim's <c>adopt-distro</c>, which writes the config key).</summary>
    public async Task UseDistroAsync(string name, CancellationToken ct = default)
    {
        if (SwitchingDistro || string.Equals(name, CurrentDistro, StringComparison.OrdinalIgnoreCase)) return;
        SwitchingDistro = true;
        DistroMessage = $"Switching to {name}...";
        Changed?.Invoke();
        try
        {
            var result = await setup.UseDistroAsync(name, ct).ConfigureAwait(true);
            DistroMessage = result.Ok ? null : result.Message;
            if (result.Ok) host.DistroSwitched();
        }
        catch (SourceProblemException ex)
        {
            DistroMessage = ex.Message;
        }
        finally
        {
            SwitchingDistro = false;
            Changed?.Invoke();
        }
    }
}
