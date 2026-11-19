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

    // --- the BenchBar window ---

    private void OpenMain()
    {
        if (_quitting || _controller is null) return;
        if (_main is null)
        {
            var main = new MainWindow(BuildMainActions(), Theme);
            main.Closing += OnMainClosing;
            main.StateChanged += (_, _) => SyncViewerActivity();
            WatchActivity(main);
            main.Closed += (_, _) =>
            {
                _main = null;
                Viewer(false);
                ReleaseMemory();
                MaybeShowRunningHint(); // once ever: where BenchBar went when its window closed
            };
            _main = main;
            Viewer(true);
            main.SetNotices(_notices.All, DismissNotice);
            main.SetSnapshot(_controller.Snapshot, TrayController.UpText(_controller.Snapshot, _controller.Benches.Select(b => b.State).ToList()));
            if (_wizard is not null) main.ShowWizard(new WizardView(_wizard, BuildWizardActions()));
            main.Show();
            CheckBannerAsync().Forget(); // the switch and the six hour cadence are checked inside; an offer already known is shown either way
        }
        else
        {
            if (_main.WindowState == WindowState.Minimized) _main.WindowState = WindowState.Normal;
        }
        // opened by the tray itself (a launch check, a resume, the installer): bring it to the front, or flash its taskbar button
        WindowFocus.Raise(_main);
    }

    /// <summary>A window of ours is open: leave efficiency mode and poll at the window rate. The last one closing undoes both.</summary>
    private void Viewer(bool open)
    {
        Awake(open);
        // the controller counts the windows: the flyout closing must not drop polling to the slow rate while the BenchBar window is open
        if (open)
        {
            _controller?.FlyoutOpened();
            Dispatcher.BeginInvoke(SyncViewerActivity, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        }
        else _controller?.FlyoutClosed();
    }

    /// <summary>
    /// Tells the controller whether one of our windows is in use: one is the active window and not minimized. When none has been for a while
    /// (minimized, or another program in front) polling backs off from 5 s to about 30 s; coming back polls at once.
    /// </summary>
    private void PostViewerSync() =>
        Dispatcher.BeginInvoke(SyncViewerActivity, System.Windows.Threading.DispatcherPriority.Background);

    /// <summary>
    /// Activated and Deactivated fire before Window.IsActive has caught up, so the sync runs after them, and a window's own
    /// events are watched too: a switch between two of our windows never raises the application's.
    /// </summary>
    private void WatchActivity(Window window)
    {
        window.Activated += (_, _) => PostViewerSync();
        window.Deactivated += (_, _) => PostViewerSync();
    }

    private void SyncViewerActivity()
    {
        var active = Windows.OfType<Window>().Any(w => w.IsActive && w.WindowState != WindowState.Minimized);
        _controller?.ViewersActive(active);
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
        // closing the window ends the wizard and counts as "not now" unless it was done; a pending restart keeps its one shot flag so the
        // wizard comes back after it (the resume start opens it whatever the dismissal says)
        if (_wizard is { } wizard) RecordWizardClose(wizard, reason: null);
        _wizard?.Dispose();
        _wizard = null;
    }

    private PageServices? _pageServices;

    /// <summary>The CLI client and sheets every page of the main window and the log windows share.</summary>
    private PageServices PageServicesInstance => _pageServices ??= NewPageServices();

    private PageServices NewPageServices()
    {
        var services = PageServices.ForApp(_cli, () => Theme, () => _main, CopyText, OpenUrl, () => _controller?.Poller.Kick());
        services.Pins = _config.Pins;
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
        NewBench = () => OpenWizard(resume: false, newBench: true), // asked for by name: no Welcome page to click through
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
        UpdateNow = UpdateNow,
    };

    // --- the first run wizard ---

    /// <param name="keepFlow">Set Up BenchBar from the tray menu: an open wizard is brought forward as it is, on the page it shows.</param>
    private void OpenWizard(bool resume, bool existing = false, bool newBench = false, bool keepFlow = false)
    {
        ResumeGate.Opening(resume);
        if (_quitting || _controller is null || _setup is null) return;
        OpenMain();
        if (_main is null) return;
        if (_wizard is not null)
        {
            // the wizard is already open: bring it forward, and switch to the flow that was asked for unless something runs
            if (_main.Mode != MainMode.Wizard) _main.ShowWizard(new WizardView(_wizard, BuildWizardActions()));
            if (!resume && !keepFlow) _wizard.SwitchFlowAsync(existing ? WizardFlow.ExistingBench : WizardFlow.NewBench).Forget();
            WindowFocus.Raise(_main);
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
        else if (newBench) model.ChooseNewBench().Forget();
    }

    private void CloseWizard(WizardModel model, WizardClose reason)
    {
        if (!ReferenceEquals(model, _wizard)) return;
        RecordWizardClose(model, reason);
        _wizard = null;
        _main?.CloseWizard();
        model.Dispose();
    }

    /// <summary>
    /// Any close of the wizard before Done (Cancel, the window's X, Alt+F4, Quit) is "not now": it no longer opens by itself at launch, and
    /// the tray menu, the flyout and the window still offer Set Up BenchBar. Done clears the dismissal and the pending setup.
    /// </summary>
    private void RecordWizardClose(WizardModel model, WizardClose? reason)
    {
        if (WizardDismissal.OnClose(reason, model.Page) == WizardCloseRecord.Finished)
        {
            _config.WizardDismissed = false;
            SaveConfig();
            SetSetupPending(false);
            _controller?.Poller.BoostFor(BenchPoller.ActionBoost);
            return;
        }
        if (_config.WizardDismissed) return;
        _config.WizardDismissed = true;
        SaveConfig();
    }

    private WizardActions BuildWizardActions() => new()
    {
        ConfirmRestart = () => ConfirmDialog.Ask("Restart Windows", "Windows restarts in 15 seconds. Save your work first.\n\nBenchBar opens again after you sign in and carries on with the setup.",
            "Restart Now", Theme, _main),
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
            info.ArgumentList.Add(TextFormats.WslToWindowsExisting(distro, linuxPath));
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

        // an install takes 20 to 30 minutes: the PC must not sleep in it (the execution state is per thread, and this is the UI thread)
        public void KeepAwake(bool on)
        {
            if (!app._keepAwake.Set(on) && on) app._log.Write("keep-awake", new InvalidOperationException("SetThreadExecutionState refused"));
        }

        public WizardFlow? ResumeFlow => app._config.ResumeFlow == "existing" ? WizardFlow.ExistingBench : WizardFlow.NewBench;

        public void SetResumeFlow(WizardFlow flow)
        {
            var text = flow == WizardFlow.ExistingBench ? "existing" : "new";
            if (app._config.ResumeFlow == text) return;
            app._config.ResumeFlow = text;
            app.SaveConfig();
        }
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
        WatchActivity(window);
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

        public void DistroSwitched() => app._controller?.Poller.Kick();
    }

    // --- Quick Switch ---

    private QuickSwitchWindow? _quickSwitch;
    private string? _lastSwitchTarget;
    private readonly Dictionary<string, string> _lastSwitchUser = [];

    /// <summary>
    /// The Quick Switch panel (one at a time). It reads the benches the last poll saw, and what it opens is the CLI's own <c>open --as</c>.
    /// The last user it opened is remembered for this run only, to mark the row "last opened".
    /// </summary>
    private void ShowQuickSwitch()
    {
        if (_quitting || _setup is null) return;
        if (_quickSwitch is { } open)
        {
            open.Activate();
            return;
        }
        var window = new QuickSwitchWindow(new QuickSwitchHost
        {
            Cli = _cli,
            Benches = () => _controller?.Snapshot.Benches ?? [],
            Pins = _config.Pins,
            LastTarget = () => _lastSwitchTarget,
            LastUser = key => _lastSwitchUser.GetValueOrDefault(key),
            Opened = (target, user) =>
            {
                _lastSwitchTarget = target.Key;
                _lastSwitchUser[target.Key] = user;
            },
        }, Theme);
        _quickSwitch = window;
        window.Closed += (_, _) =>
        {
            _quickSwitch = null;
            Viewer(false);
        };
        Viewer(true);
        window.Show();
        window.Activate();
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
            CheckForUpdates = RunUpdateCheckAsync,
            KnownOffer = () => _updateKnown,
            UpdateRunning = () => UpdateRunning,
            UpdateNow = UpdateNow,
            ReportBug = () => ReportBugAsync("About").Forget(),
            OpenUrl = OpenUrl,
            CopyText = CopyText,
        }, Theme);
        _aboutWindow = window;
        WatchActivity(window);
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
}
