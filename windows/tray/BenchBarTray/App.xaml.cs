using System.Diagnostics;
using System.Windows;
using BenchBar.Tray.Core;
using H.NotifyIcon;
using H.NotifyIcon.Core;
using H.NotifyIcon.EfficiencyMode;

namespace BenchBar.Tray;

/// <summary>
/// The tray app: no window at startup, a TaskbarIcon created in code, the shared <see cref="TrayController"/> behind
/// it, and a flyout, Logs and Doctor windows created on first use.
/// </summary>
public partial class App : Application, ITrayHost
{
    private const string MutexName = @"Local\BenchBarTray";
    private const string OpenEventName = @"Local\BenchBarTray.Open";
    private const string SetupEventName = @"Local\BenchBarTray.Setup";
    private const string HelpUrl = "https://benchbar.akashmishra.com/windows/";

    private readonly ErrorLog _log = new();
    private readonly StartupShortcut _startup = new();
    private readonly Dictionary<string, LogWindow> _logs = [];
    private readonly Dictionary<string, DoctorWindow> _doctors = [];
    private Mutex? _mutex;
    private EventWaitHandle? _openEvent;
    private RegisteredWaitHandle? _openWait;
    private TaskbarIcon? _icon;
    private TrayController? _controller;
    private TrayConfig _config = TrayConfig.Load();
    private HarnessLink? _link;
    private FlyoutWindow? _flyout;
    private TrayMenu? _menu;
    private IBenchSource? _source;
    private ISetupService? _setup;
    private ICliClient _cli = new CliClient();
    private IDistroProbe? _probe;
    private MainWindow? _main;
    private SettingsWindow? _settingsWindow;
    private AboutWindow? _aboutWindow;
    private WizardModel? _wizard;
    private readonly StartupShortcut _resumeFlag = new(fileName: StartupShortcut.ResumeFileName, arguments: StartupShortcut.ResumeArgument);
    private EventWaitHandle? _setupEvent;
    private RegisteredWaitHandle? _setupWait;
    private bool _launchChecked;
    private int _viewers;
    private long _updateCheckedAt;
    private UpdateOffer? _updateOffer;
    private string? _updateDismissed;
    private static readonly TimeSpan FlyoutKeepAlive = TimeSpan.FromSeconds(30);
    private readonly System.Windows.Threading.DispatcherTimer _releaseFlyout = new(System.Windows.Threading.DispatcherPriority.Background) { Interval = FlyoutKeepAlive };
    private long _flyoutHiddenAt;
    private int _awake;
    private bool _quitting;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // Software rendering: the flyout is plain 2D, and a Direct3D device (with the GPU driver behind it)
        // stayed in memory after the first open, 62.6 MB private instead of 17 MB at rest.
        if (Environment.GetEnvironmentVariable("BENCHBAR_TRAY_GPU") != "1")
            System.Windows.Media.RenderOptions.ProcessRenderMode = System.Windows.Interop.RenderMode.SoftwareOnly;
        Observe.OnFault = ex => _log.Write("task", ex);
        DispatcherUnhandledException += (_, args) =>
        {
            _log.Write("ui", args.Exception);
            args.Handled = true; // keep running
        };
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception ex) _log.Write("domain", ex);
        };
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            _log.Write("task", args.Exception);
            args.SetObserved();
        };

        var resume = e.Args.Contains(StartupShortcut.ResumeArgument, StringComparer.OrdinalIgnoreCase);
        if (!TakeSingleInstance(resume))
        {
            Shutdown();
            return;
        }

        // Created first: `hello` is queued until the pipe is up, so nothing sent below is lost.
        _link = HarnessLink.FromEnvironment("BenchBarTray");
        if (_link is not null) _link.Command += cmd => Dispatcher.BeginInvoke(() => OnHarnessCommand(cmd));

        _config = TrayConfig.Load();
        ApplyThemeMode();
        _source = BenchSourceFactory.FromEnvironment();
        _setup = BenchSourceFactory.SetupFromEnvironment();
        _cli = BenchSourceFactory.CliFromEnvironment();
        var options = new TrayOptions
        {
            Runners = RunnerSet.Load(),
            RunnerId = _config.RunnerId,
            Appearance = _config.Appearance,
            Notifications = _config.Notifications,
            DistroProbe = _probe = BenchSourceFactory.DistroProbeFromEnvironment(),
            Distro = () => DistroName.Resolve(_config.Distro),
            PortCheck = _cli,
        };
        // The controller and the first frame exist before NIM_ADD, so "icon-added" means a runner is visible.
        _controller = new TrayController(_source, new DispatcherFrameClock(), this, TimeProvider.System, options);
        _icon = new TaskbarIcon { ToolTipText = TrayController.TooltipName, NoLeftClickDelay = true };
        _icon.TrayLeftMouseUp += (_, _) => ToggleFlyout();
        // The menu is built on the first right click: built at startup it loaded WPF's render stack
        // (wpfgfx, d3d9, the GPU driver) and doubled private bytes at rest.
        _icon.TrayRightMouseDown += (_, _) => EnsureMenu();
        _icon.TrayKeyboardContextMenu += (_, _) => EnsureMenu();
        _icon.PreviewTrayContextMenuOpen += (_, _) => EnsureMenu();
        _icon.TrayBalloonTipClicked += (_, _) => ShowFlyout();

        // NIM_ADD succeeded when the core TrayIcon raises Created; IsCreated is the fallback.
        var added = false;
        void IconAdded()
        {
            if (added) return;
            added = true;
            _link?.Send($"icon-added qpc={HarnessLink.Qpc()}");
            LogonLog.IconAdded("BenchBarTray");
        }
        _icon.TrayIcon.Created += (_, _) => IconAdded();
        _icon.TrayIcon.UpdateIcon(_controller.Icons.Get(RunnerPose.Unknown, 0));
        _icon.ForceCreate(); // puts the process in efficiency mode; the windows leave it while open
        if (_icon.IsCreated) IconAdded();

        _icon.TrayMouseDoubleClick += (_, _) => OpenMain();
        _releaseFlyout.Tick += (_, _) => ReleaseFlyout();
        _controller.Start();
        if (resume)
        {
            // the one shot flag did its job: take it away before anything can fail
            try { _resumeFlag.Disable(); } catch (Exception ex) { _log.Write("resume-flag", ex); }
            Dispatcher.BeginInvoke(() => OpenWizard(resume: true));
        }
    }

    // --- single instance ---

    private bool TakeSingleInstance(bool resume)
    {
        _mutex = new Mutex(true, MutexName, out var first);
        if (!first)
        {
            // ask the running one to open its flyout (or the wizard, after a restart); quietly nothing if it cannot be reached
            try
            {
                using var existing = EventWaitHandle.OpenExisting(resume ? SetupEventName : OpenEventName);
                existing.Set();
            }
            catch (Exception ex) when (ex is WaitHandleCannotBeOpenedException or UnauthorizedAccessException or IOException) { }
            _mutex.Dispose();
            _mutex = null;
            return false;
        }
        _openEvent = new EventWaitHandle(false, EventResetMode.AutoReset, OpenEventName);
        _openWait = ThreadPool.RegisterWaitForSingleObject(_openEvent, (_, _) => Dispatcher.BeginInvoke(ShowFlyout), null, Timeout.Infinite, executeOnlyOnce: false);
        _setupEvent = new EventWaitHandle(false, EventResetMode.AutoReset, SetupEventName);
        _setupWait = ThreadPool.RegisterWaitForSingleObject(_setupEvent, (_, _) => Dispatcher.BeginInvoke(() => OpenWizard(resume: true)), null, Timeout.Infinite, executeOnlyOnce: false);
        return true;
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _openWait?.Unregister(null);
        _openEvent?.Dispose();
        _setupWait?.Unregister(null);
        _setupEvent?.Dispose();
        if (_mutex is not null)
        {
            try { _mutex.ReleaseMutex(); } catch (ApplicationException) { }
            _mutex.Dispose();
        }
        base.OnExit(e);
    }

    // --- ITrayHost ---

    public void SetIcon(IntPtr hicon) => _icon?.TrayIcon.UpdateIcon(hicon);

    public void SetTooltip(string text)
    {
        if (_icon is not null) _icon.ToolTipText = text;
    }

    public void Post(Action action) => Dispatcher.BeginInvoke(action);

    public void BenchesChanged(TraySnapshot snapshot, string upText)
    {
        _flyout?.View.SetSnapshot(snapshot, upText);
        _main?.SetSnapshot(snapshot, upText);
        if (!_launchChecked)
        {
            _launchChecked = true;
            LaunchCheckAsync(snapshot).Forget();
        }
    }

    /// <summary>
    /// A PC with no bench and no finished setup opens the wizard by itself. The read only <c>setup check</c> never boots a
    /// stopped distro, and a stopped distro is skipped entirely: it exists, so this is not a new user.
    /// </summary>
    private async Task LaunchCheckAsync(TraySnapshot snapshot)
    {
        if (_setup is null || !LaunchPlanner.NeedsSetupCheck(snapshot, _config.WizardDismissed)) return;
        SetupReport? report = null;
        try
        {
            report = await _setup.CheckAsync(DistroName.Resolve(_config.Distro), CancellationToken.None);
        }
        catch (Exception ex) when (ex is SourceProblemException or System.Text.Json.JsonException)
        {
            _log.Write("setup-check", ex); // no shim or an old one: the flyout already says so
        }
        if (LaunchPlanner.AtLaunch(snapshot, report, _config.WizardDismissed, resumeFlag: false) == LaunchAction.OpenWizard)
            OpenWizard(resume: false);
    }

    public void ShowToast(Toast toast)
    {
        try
        {
            _icon?.TrayIcon.ShowNotification(toast.Title, toast.Body, NotificationIcon.Warning);
        }
        catch (Exception ex)
        {
            _log.Write("toast", ex);
        }
    }

    public void ShowNotice(string text)
    {
        try
        {
            _icon?.TrayIcon.ShowNotification("BenchBar", text, NotificationIcon.Warning);
        }
        catch (Exception ex)
        {
            _log.Write("notice", ex);
        }
    }

    // --- efficiency mode ---

    /// <summary>The icon alone runs in efficiency mode; any open window of ours leaves it until the last one closes.</summary>
    private void Awake(bool open)
    {
        _awake = Math.Max(0, _awake + (open ? 1 : -1));
        if (open && _awake != 1) return;
        if (!open && _awake != 0) return;
        try { EfficiencyModeUtilities.SetEfficiencyMode(!open); }
        catch (Exception ex) { _log.Write("efficiency", ex); }
    }

    // --- flyout ---

    private void ShowFlyout()
    {
        if (_quitting || _controller is null) return;
        if (_flyout is null)
        {
            var view = new FlyoutView(BuildFlyoutActions());
            _flyout = new FlyoutWindow(_controller, view, _link);
            _flyout.Opened += () => Awake(true);
            _flyout.Hidden += () =>
            {
                _flyoutHiddenAt = Environment.TickCount64;
                Awake(false);
                _releaseFlyout.Stop();
                _releaseFlyout.Start();
            };
            view.SetSnapshot(_controller.Snapshot, TrayController.UpText(_controller.Snapshot, _controller.Benches.Select(b => b.State).ToList()));
        }
        _flyout.ShowAtTray();
    }

    /// <summary>
    /// A flyout hidden for <see cref="FlyoutKeepAlive"/> is closed and its memory handed back, so the tray
    /// returns to its at rest size; a click within that time reopens the warm window.
    /// </summary>
    private void ReleaseFlyout()
    {
        _releaseFlyout.Stop();
        if (_flyout is null || _flyout.IsVisible) return;
        _flyout.Close();
        _flyout = null;
        System.Runtime.GCSettings.LargeObjectHeapCompactionMode = System.Runtime.GCLargeObjectHeapCompactionMode.CompactOnce;
        GC.Collect(2, GCCollectionMode.Aggressive, blocking: true, compacting: true);
    }

    /// <summary>
    /// A click on the tray icon deactivates the open flyout first (it hides itself), so
    /// the click that follows within a moment means "close", not "open again".
    /// </summary>
    private void ToggleFlyout()
    {
        if (_flyout is { IsVisible: true }) { _flyout.HideFlyout(); return; }
        if (Environment.TickCount64 - _flyoutHiddenAt < 300) return;
        ShowFlyout();
    }

    private void OnHarnessCommand(string command)
    {
        switch (command)
        {
            case "open-flyout": ShowFlyout(); break;
            case "hide-flyout": _flyout?.HideFlyout(); break;
            case "quit": Quit(); break;
        }
    }

    private FlyoutActions BuildFlyoutActions() => new()
    {
        StartStop = bench => _controller!.StartStopAsync(bench),
        Restart = bench => _controller!.RestartAsync(bench),
        OpenSite = bench => _controller!.OpenSite(bench),
        ShowLogs = ShowLogs,
        ShowDoctor = ShowDoctor,
        CopyPath = bench => CopyText(bench.Path),
        OpenVsCode = OpenEditor,
        VsCodeAvailable = () => VsCode.FindEditor(_config.Editor) is not null,
        StartDistro = () => _controller!.StartDistro(),
        CopyText = CopyText,
        OpenUrl = OpenUrl,
        OpenMain = OpenMain,
        SetUpBench = () => OpenWizard(resume: false),
    };

    private VsCodeOutcome OpenEditor(BenchStatus bench)
    {
        var code = VsCode.FindEditor(_config.Editor);
        if (code is null) return VsCodeOutcome.NotFound;
        var distro = DistroName.Resolve(_config.Distro) ?? _controller?.Snapshot.Distro;
        if (distro is null) return VsCodeOutcome.NotFound;
        if (!VsCode.CanLaunch(distro, bench.Path)) return VsCodeOutcome.BadPath;
        try
        {
            Process.Start(VsCode.StartInfo(code, distro, bench.Path))?.Dispose();
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            _log.Write("vscode", ex);
            return VsCodeOutcome.NotFound;
        }
        return VsCodeOutcome.Launched;
    }

    // --- Logs and Doctor ---

    private ResolvedTheme Theme => ThemeResolver.Resolve(_config.Appearance);

    private void ShowLogs(BenchStatus bench)
    {
        if (_logs.TryGetValue(bench.Path, out var existing))
        {
            existing.Reopen();
            return;
        }
        var window = new LogWindow(PageServicesInstance, bench, Theme);
        _logs[bench.Path] = window;
        window.Closed += (_, _) =>
        {
            _logs.Remove(bench.Path);
            Awake(false);
        };
        Awake(true);
        window.Show();
    }

    private void ShowDoctor(BenchStatus bench)
    {
        if (_source is null) return;
        if (_doctors.TryGetValue(bench.Path, out var existing))
        {
            existing.Activate();
            existing.RunAsync().Forget();
            return;
        }
        var window = new DoctorWindow(_source, bench, Theme, CopyText);
        _doctors[bench.Path] = window;
        window.Closed += (_, _) =>
        {
            _doctors.Remove(bench.Path);
            Awake(false);
        };
        Awake(true);
        window.Show();
    }

    // --- context menu ---

    private void EnsureMenu()
    {
        if (_menu is not null || _icon is null || _quitting) return;
        _menu = new TrayMenu(BuildMenuModel());
        _icon.ContextMenu = _menu.Menu;
    }

    private TrayMenuModel BuildMenuModel() => new()
    {
        LogonEnabled = _startup.IsEnabled,
        SetLogon = on =>
        {
            try { if (on) _startup.Enable(); else _startup.Disable(); }
            catch (Exception ex) { _log.Write("logon", ex); }
        },
        Appearance = () => _config.Appearance,
        SetAppearance = mode =>
        {
            _config.Appearance = mode;
            SaveConfig();
            _controller?.SetAppearance(mode);
            ApplyThemeMode();
        },
        LoadRunners = () =>
        {
            var set = RunnerSet.Load();
            _controller?.ReloadRunners(set);
            return set;
        },
        RunnerId = () => _config.RunnerId,
        SelectRunner = id =>
        {
            _config.RunnerId = id;
            SaveConfig();
            _controller?.SetRunner(id);
        },
        OpenRunnersFolder = OpenRunnersFolder,
        Notifications = () => _config.Notifications,
        SetNotifications = on =>
        {
            _config.Notifications = on;
            SaveConfig();
            if (_controller is not null) _controller.Notifications = on;
        },
        Theme = () => Theme,
        OpenMain = OpenMain,
        OpenSettings = ShowSettings,
        CheckForUpdates = () => CheckForUpdatesAsync().Forget(),
        Help = () => OpenUrl(HelpUrl),
        ReportBug = () => ReportBugAsync("Tray menu").Forget(),
        Quit = Quit,
    };

    private void ApplyThemeMode() =>
        ThemeMode = _config.Appearance switch
        {
            AppearanceMode.Light => ThemeMode.Light,
            AppearanceMode.Dark => ThemeMode.Dark,
            _ => ThemeMode.System,
        };

    private void SaveConfig()
    {
        try { _config.Save(); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            _log.Write("config", ex);
        }
    }

    private void OpenRunnersFolder()
    {
        try
        {
            Directory.CreateDirectory(RunnerSet.DefaultFolder);
            var info = new ProcessStartInfo("explorer.exe") { UseShellExecute = false };
            info.ArgumentList.Add(RunnerSet.DefaultFolder);
            Process.Start(info)?.Dispose();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            _log.Write("runners-folder", ex);
        }
    }

    private async Task CheckForUpdatesAsync()
    {
        try
        {
            var latest = await UpdateCheck.FetchLatestAsync(CancellationToken.None);
            var current = UpdateCheck.CurrentVersion();
            if (latest is { } release && UpdateCheck.IsNewer(release.Tag, current))
            {
                var answer = MessageBox.Show($"BenchBar {release.Tag.TrimStart('v')} is out. You have {current.Split('+')[0]}.\n\nOpen the release page?",
                    "BenchBar", MessageBoxButton.YesNo, MessageBoxImage.Information);
                if (answer == MessageBoxResult.Yes) OpenUrl(release.Url);
            }
            else
            {
                MessageBox.Show("You have the latest version of BenchBar.", "BenchBar", MessageBoxButton.OK, MessageBoxImage.Information);
            }
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            MessageBox.Show("Could not check for updates: " + ex.Message, "BenchBar", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    // --- Report a Bug ---

    private ReportFlow? _reportFlow;

    private ReportFlow ReportFlowInstance => _reportFlow ??= new ReportFlow(
        new BugReporter(new SystemProcessRunner(), () => ShimLocator.Find(), TrayOnlyReport.ForThisPc()), BuildReportSeams());

    private ReportBusyWindow? _reportBusy;

    private ReportSeams BuildReportSeams() => new()
    {
        ShowBusy = () =>
        {
            var window = _reportBusy = new ReportBusyWindow(Theme, VisibleMain);
            Awake(true);
            window.Show();
            return new Busy(() =>
            {
                _reportBusy = null;
                window.Dispose();
                Awake(false);
            });
        },
        Refocus = () => _reportBusy?.Activate(),
        ShowReady = outcome =>
        {
            // not modal: a modal dialog blocks the other BenchBar windows, and the click that finds it open must be able to bring it forward
            var dialog = new ReportReadyDialog(outcome, Theme, VisibleMain, CopyText, RevealInExplorer, OpenUrl);
            Awake(true);
            dialog.Closed += (_, _) => Awake(false);
            dialog.Show();
            return new ReadyHandle(() => dialog.IsVisible, dialog.BringToFront);
        },
        ShowFailure = text => MessageBox.Show(text, "BenchBar", MessageBoxButton.OK, MessageBoxImage.Warning),
        Log = _log.Write,
    };

    /// <summary>The main window as an owner: only when it is on screen (a window that was never shown cannot own one).</summary>
    private Window? VisibleMain => _main is { IsVisible: true } main ? main : null;

    private sealed class Busy(Action done) : IDisposable
    {
        public void Dispose() => done();
    }

    private void RevealInExplorer(string file)
    {
        try { Process.Start(ReportFlow.RevealInfo(file))?.Dispose(); }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException) { _log.Write("reveal", ex); }
    }

    /// <summary>
    /// Report a Bug, from the tray menu, About, the beta banner, the wizard footer or a Report This Problem button. The context names
    /// the entry point, the window or wizard page, and the failure next to the button. A second click while one runs is ignored.
    /// </summary>
    internal async Task ReportBugAsync(string entry, string? problem = null)
    {
        if (_quitting) return;
        var snapshot = _controller?.Snapshot ?? TraySnapshot.Empty;
        string where;
        var inWizard = _main is { Mode: MainMode.Wizard } && _wizard is not null;
        if (inWizard) where = _wizard!.ReportWhere;
        else if (_main is not null) where = _main.ReportWhere;
        else where = "No BenchBar window open";
        problem ??= inWizard ? _wizard!.ReportProblem : null;
        var distro = DistroName.Resolve(_config.Distro) ?? snapshot.Distro;
        // the last poll's benches belong to the distro it polled: after a switch of distro (or while it is missing) they are not this one's
        var pollIsCurrent = !snapshot.DistroStopped && snapshot.Problem is null
            && string.Equals(snapshot.Distro ?? distro, distro, StringComparison.OrdinalIgnoreCase);
        var benchPath = _main?.SelectedBenchPath ?? (pollIsCurrent && snapshot.Benches.Count == 1 ? snapshot.Benches[0].Path : null);
        var includes = File.Exists(_log.Path) ? new[] { _log.Path } : [];
        var request = new ReportRequest(distro, benchPath,
            ReportContext.Compose(entry, where, problem), UpdateCheck.CurrentVersion().Split('+')[0], includes);
        await ReportFlowInstance.RunAsync(request);
    }

    // --- small helpers ---

    private void CopyText(string text)
    {
        try { Clipboard.SetText(text); }
        catch (System.Runtime.InteropServices.COMException ex) { _log.Write("clipboard", ex); }
    }

    private static void OpenUrl(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true })?.Dispose(); }
        catch (System.ComponentModel.Win32Exception) { }
    }

    private void Quit()
    {
        if (_quitting) return;
        _quitting = true;
        _controller?.Dispose();
        _flyout?.Close();
        foreach (var w in _logs.Values.ToList()) w.Close();
        foreach (var w in _doctors.Values.ToList()) w.Close();
        _wizard?.Dispose();
        _wizard = null;
        _main?.Close();
        _settingsWindow?.Close();
        _aboutWindow?.Close();
        _icon?.Dispose(); // NIM_DELETE
        _link?.Dispose(); // sends bye
        Shutdown();
    }
}
