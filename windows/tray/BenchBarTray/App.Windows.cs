using System.Diagnostics;
using System.Windows;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>The BenchBar window, the first run wizard, Settings and About: created when asked for, closed when done.</summary>
public partial class App
{
    private ResumeGate? _gate;

    private ResumeGate ResumeGate => _gate ??= new ResumeGate(() =>
    {
        try { _resumeFlag.Disable(); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { _log.Write("resume-flag", ex); }
    });

    private static readonly TimeSpan UpdateCheckEvery = TimeSpan.FromHours(6);

    // --- the BenchBar window ---

    private void OpenMain()
    {
        if (_quitting || _controller is null) return;
        if (_main is null)
        {
            var main = new MainWindow(BuildMainActions(), Theme);
            main.Closing += OnMainClosing;
            main.Closed += (_, _) =>
            {
                _main = null;
                Viewer(false);
                ReleaseMemory();
            };
            _main = main;
            Viewer(true);
            main.SetSnapshot(_controller.Snapshot, TrayController.UpText(_controller.Snapshot, _controller.Benches.Select(b => b.State).ToList()));
            if (_wizard is not null) main.ShowWizard(new WizardView(_wizard, BuildWizardActions()));
            main.Show();
            if (_config.CheckForUpdates) CheckBannerAsync().Forget();
            else if (_updateOffer is not null) main.SetUpdate(_updateOffer, DismissUpdate);
        }
        else
        {
            if (_main.WindowState == WindowState.Minimized) _main.WindowState = WindowState.Normal;
        }
        _main.Activate();
    }

    /// <summary>A window of ours is open: leave efficiency mode and poll at the window rate. The last one closing undoes both.</summary>
    private void Viewer(bool open)
    {
        Awake(open);
        _viewers = Math.Max(0, _viewers + (open ? 1 : -1));
        if (open && _viewers == 1) _controller?.FlyoutOpened();
        else if (!open && _viewers == 0) _controller?.FlyoutClosed();
    }

    private static void ReleaseMemory()
    {
        System.Runtime.GCSettings.LargeObjectHeapCompactionMode = System.Runtime.GCLargeObjectHeapCompactionMode.CompactOnce;
        GC.Collect(2, GCCollectionMode.Aggressive, blocking: true, compacting: true);
    }

    private void OnMainClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (_main?.Wizard is { IsBusy: true })
        {
            var answer = MessageBox.Show(_main, "A setup step is still running. Stop it and close the window?", "BenchBar",
                MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
            if (answer != MessageBoxResult.Yes)
            {
                e.Cancel = true;
                return;
            }
        }
        if (PageServicesInstance.HasRunInFlight)
        {
            // the run keeps going in the background (the CLI is not stopped) and its result comes as a notification
            var answer = MessageBox.Show(_main, "A change is still running (a site drop, an app update or an add). If you close the window it keeps running and BenchBar tells you the result in a notification. Close the window anyway?",
                "BenchBar", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
            if (answer != MessageBoxResult.Yes)
            {
                e.Cancel = true;
                return;
            }
        }
        // closing the window ends the wizard; a pending restart keeps its one shot flag so the wizard comes back after it
        _wizard?.Dispose();
        _wizard = null;
    }

    private PageServices? _pageServices;

    /// <summary>The CLI client and sheets every page of the main window and the log windows share.</summary>
    private PageServices PageServicesInstance => _pageServices ??= NewPageServices();

    private PageServices NewPageServices()
    {
        var services = PageServices.ForApp(_cli, () => Theme, () => _main, CopyText, OpenUrl, () => _controller?.Poller.Kick());
        services.Distro = () => DistroName.Resolve(_config.Distro) ?? _controller?.Snapshot.Distro;
        services.Notify = text => _icon?.TrayIcon.ShowNotification("BenchBar", text, H.NotifyIcon.Core.NotificationIcon.Info);
        services.ReportBug = (entry, problem) => ReportBugAsync(entry, problem).Forget();
        return services;
    }

    private MainActions BuildMainActions() => new()
    {
        Overview = new OverviewActions
        {
            StartStop = bench => _controller!.StartStopAsync(bench, checkPorts: false),
            Restart = bench => _controller!.RestartAsync(bench, checkPorts: false),
            OpenSite = bench => _controller!.OpenSite(bench),
            ShowLogs = ShowLogs,
            ShowHealth = _ => _main?.ShowHealth(),
            OpenEditor = OpenEditor,
            EditorName = () => EditorKind.DisplayName(_config.Editor),
            CopyText = CopyText,
            OpenUrl = OpenUrl,
        },
        Services = PageServicesInstance,
        StartDistro = () => _controller!.StartDistro(),
        ShowSettings = ShowSettings,
        ShowAbout = ShowAbout,
        NewBench = () => OpenWizard(resume: false),
        ExistingBench = () => OpenWizard(resume: false, existing: true),
        CopyText = CopyText,
        OpenUrl = OpenUrl,
        RefreshNow = () => _controller?.Poller.Kick(),
        ReportBug = (entry, problem) => ReportBugAsync(entry, problem).Forget(),
        BetaBannerVisible = () => !_config.BetaBannerDismissed,
        DismissBetaBanner = () =>
        {
            _config.BetaBannerDismissed = true;
            SaveConfig();
        },
    };

    // --- the update banner ---

    /// <summary>Asks GitHub when the window opens, at most once in a few hours; a failure shows nothing (the menu item reports errors).</summary>
    private async Task CheckBannerAsync()
    {
        if (Environment.TickCount64 - _updateCheckedAt < UpdateCheckEvery.TotalMilliseconds && _updateCheckedAt != 0)
        {
            _main?.SetUpdate(_updateOffer, DismissUpdate);
            return;
        }
        _updateCheckedAt = Math.Max(1, Environment.TickCount64);
        try
        {
            var latest = await UpdateCheck.FetchLatestAsync(CancellationToken.None);
            var current = UpdateCheck.CurrentVersion();
            _updateOffer = latest is { } release && UpdateCheck.IsNewer(release.Tag, current) && release.Tag != _updateDismissed
                ? new UpdateOffer(release.Tag.TrimStart('v'), release.Url)
                : null;
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            _updateCheckedAt = 0; // try again the next time the window opens
            return;
        }
        _main?.SetUpdate(_updateOffer, DismissUpdate);
    }

    private void DismissUpdate()
    {
        _updateDismissed = "v" + _updateOffer?.Version;
        _updateOffer = null;
    }

    // --- the first run wizard ---

    private void OpenWizard(bool resume, bool existing = false)
    {
        ResumeGate.Opening(resume);
        if (_quitting || _controller is null || _setup is null) return;
        OpenMain();
        if (_main is null) return;
        if (_wizard is not null)
        {
            // the wizard is already open: bring it forward, and switch to the flow that was asked for unless something runs
            if (_main.Mode != MainMode.Wizard) _main.ShowWizard(new WizardView(_wizard, BuildWizardActions()));
            if (!resume) _wizard.SwitchFlowAsync(existing ? WizardFlow.ExistingBench : WizardFlow.NewBench).Forget();
            _main.Activate();
            return;
        }
        var model = new WizardModel(_setup, new WizardHost(this), DistroName.Resolve(_config.Distro));
        model.AskLinuxPassword = request => Task.FromResult(LinuxPasswordDialog.Ask(request, Theme, _main));
        model.ConfirmRestartDistro = question => Task.FromResult(
            MessageBox.Show(_main, question, "BenchBar", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) == MessageBoxResult.Yes);
        model.CloseRequested += reason => CloseWizard(model, reason);
        _wizard = model;
        _main.ShowWizard(new WizardView(model, BuildWizardActions()));
        if (resume) model.ResumeAtCheck().Forget();
        else if (existing) model.ChooseExistingBench().Forget();
    }

    private void CloseWizard(WizardModel model, WizardClose reason)
    {
        if (!ReferenceEquals(model, _wizard)) return;
        if (reason == WizardClose.Cancelled && model.Page == WizardPage.Welcome)
        {
            _config.WizardDismissed = true; // no more opening by itself at launch; + > New Bench is still there
            SaveConfig();
        }
        else if (reason == WizardClose.Finished)
        {
            _config.WizardDismissed = false;
            SaveConfig();
            _controller?.Poller.BoostFor(BenchPoller.ActionBoost);
        }
        _wizard = null;
        _main?.CloseWizard();
        model.Dispose();
    }

    private WizardActions BuildWizardActions() => new()
    {
        ConfirmRestart = () => MessageBox.Show(_main, "Restart Windows now? Save your work in other programs first.\n\nBenchBar opens again after you sign in and carries on with the setup.",
            "BenchBar", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) == MessageBoxResult.Yes,
        OpenLog = OpenInstallLog,
        ReportBug = (entry, problem) => ReportBugAsync(entry, problem).Forget(),
    };

    private void OpenInstallLog(string linuxPath)
    {
        var distro = DistroName.Resolve(_config.Distro) ?? _controller?.Snapshot.Distro;
        if (distro is null) return;
        try
        {
            var info = new ProcessStartInfo("notepad.exe") { UseShellExecute = false };
            info.ArgumentList.Add(TextFormats.WslToWindows(distro, linuxPath));
            Process.Start(info)?.Dispose();
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            _log.Write("open-log", ex);
        }
    }

    private bool RestartWindows()
    {
        try
        {
            var info = new ProcessStartInfo("shutdown.exe") { UseShellExecute = false, CreateNoWindow = true };
            // 15 seconds: `shutdown /a` still aborts it
            foreach (var a in new[] { "/r", "/t", "15", "/c", "BenchBar: restarting to finish turning on WSL" }) info.ArgumentList.Add(a);
            using var process = Process.Start(info);
            // shutdown.exe returns at once; a non zero exit means Windows refused (another user, a policy, a pending restart)
            if (process is null) return false;
            if (!process.WaitForExit(5000)) return true;
            return process.ExitCode == 0;
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            _log.Write("restart", ex);
            return false;
        }
    }

    private void SetResumeAfterLogon(bool on)
    {
        try
        {
            if (on) _resumeFlag.Enable();
            else _resumeFlag.Disable();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            _log.Write("resume-flag", ex);
        }
    }

    private sealed class WizardHost(App app) : IWizardHost
    {
        public void SetResumeAfterLogon(bool on) => app.SetResumeAfterLogon(on);

        public bool RestartWindows() => app.RestartWindows();

        // the UAC prompt belongs to the elevated shim; let it take the foreground instead of blinking in the taskbar
        public void AllowForeground() => NativeMethods.AllowSetForegroundWindow(NativeMethods.AsfwAny);

        public string WindowsUserName => Environment.UserName;

        public string? ConfiguredDistro => app._config.Distro;

        public bool Notifications
        {
            get => app._config.Notifications;
            set => app.SetNotifications(value);
        }

        public bool OpenAtLogon
        {
            get => app._startup.IsEnabled();
            set => app.SetLogon(value);
        }

        public void OpenUrl(string url) => App.OpenUrl(url);

        public void CopyText(string text) => app.CopyText(text);
    }

    private void SetNotifications(bool on)
    {
        _config.Notifications = on;
        SaveConfig();
        if (_controller is not null) _controller.Notifications = on;
    }

    private void SetLogon(bool on)
    {
        try { if (on) _startup.Enable(); else _startup.Disable(); }
        catch (Exception ex) { _log.Write("logon", ex); }
    }

    // --- Settings and About ---

    private void ShowSettings()
    {
        if (_quitting || _setup is null) return;
        if (_settingsWindow is { } open)
        {
            open.Activate();
            return;
        }
        var model = new SettingsModel(_config, new SettingsHost(this), _setup, SaveConfig);
        var window = new SettingsWindow(model, () => RunnerSet.Load(), CopyText, Theme);
        _settingsWindow = window;
        window.Closed += (_, _) =>
        {
            _settingsWindow = null;
            Viewer(false);
        };
        Viewer(true);
        window.Show();
    }

    private sealed class SettingsHost(App app) : ISettingsHost
    {
        public bool OpenAtLogon
        {
            get => app._startup.IsEnabled();
            set => app.SetLogon(value);
        }

        public void ApplyAppearance(AppearanceMode mode)
        {
            app._controller?.SetAppearance(mode);
            app.ApplyThemeMode();
        }

        public void ApplyRunner(string id) => app._controller?.SetRunner(id);

        public void ApplyNotifications(bool on)
        {
            if (app._controller is not null) app._controller.Notifications = on;
        }

        public string? ShimPath => (app._source as ShimBenchSource)?.ShimPath;
    }

    private void ShowAbout()
    {
        if (_quitting || _setup is null) return;
        if (_aboutWindow is { } open)
        {
            open.Activate();
            return;
        }
        var window = new AboutWindow(new AboutActions
        {
            AppVersion = UpdateCheck.CurrentVersion(),
            ShimVersion = () => _setup.ShimVersionAsync(CancellationToken.None),
            CliVersion = ReadCliVersionAsync,
            CheckForUpdates = CheckUpdatesTextAsync,
            ReportBug = () => ReportBugAsync("About").Forget(),
            OpenUrl = OpenUrl,
            CopyText = CopyText,
        }, Theme);
        _aboutWindow = window;
        window.Closed += (_, _) =>
        {
            _aboutWindow = null;
            Viewer(false);
        };
        Viewer(true);
        window.Show();
    }

    /// <summary>
    /// The Linux CLI's version from the read only setup check, which never boots a stopped distro. The answer says why when there is none:
    /// "not installed yet" when WSL, the distro or the CLI is missing, and the stopped distro otherwise.
    /// </summary>
    private async Task<AboutCli> ReadCliVersionAsync()
    {
        if (_setup is null || _controller is null) return AboutCli.Unknown;
        if (_controller.Snapshot.DistroStopped) return AboutCli.Stopped;
        try
        {
            var report = await _setup.CheckAsync(DistroName.Resolve(_config.Distro), CancellationToken.None);
            return AboutCli.From(report);
        }
        catch (Exception ex) when (ex is SourceProblemException or System.Text.Json.JsonException)
        {
            return AboutCli.Unknown;
        }
    }

    private static async Task<string> CheckUpdatesTextAsync()
    {
        try
        {
            var latest = await UpdateCheck.FetchLatestAsync(CancellationToken.None);
            var current = UpdateCheck.CurrentVersion();
            return latest is { } release && UpdateCheck.IsNewer(release.Tag, current)
                ? $"BenchBar {release.Tag.TrimStart('v')} is out."
                : "You have the latest version.";
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            return "Could not check for updates: " + ex.Message;
        }
    }
}
