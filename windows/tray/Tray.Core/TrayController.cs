using System.Diagnostics;
using Microsoft.Win32;

namespace BenchBar.Tray.Core;

/// <summary>What a shell provides to <see cref="TrayController"/>.</summary>
public interface ITrayHost
{
    /// <summary>Swaps the tray icon to a cached HICON (the core NIM_MODIFY, no image conversion).</summary>
    void SetIcon(IntPtr hicon);

    void SetTooltip(string text);

    /// <summary>Runs <paramref name="action"/> on the UI thread.</summary>
    void Post(Action action);

    /// <summary>The benches or their summary changed; update the flyout. Called on the UI thread.</summary>
    void BenchesChanged(TraySnapshot snapshot, string upText);

    /// <summary>Show one Windows notification. Called on the UI thread, only while notifications are on.</summary>
    void ShowToast(Toast toast);
}

/// <summary>What the controller starts with. Everything has a default that works without a config file.</summary>
public sealed class TrayOptions
{
    public RunnerSet Runners { get; init; } = RunnerSet.BuiltIn;

    public string RunnerId { get; init; } = TrayConfig.DefaultRunnerId;

    public AppearanceMode Appearance { get; init; } = AppearanceMode.System;

    public bool Notifications { get; init; } = true;

    /// <summary>Asked first on every poll; null means no distro gate (fixtures).</summary>
    public IDistroProbe? DistroProbe { get; init; }

    /// <summary>The distro to ask about, read on every poll. Default: the WSL default distro.</summary>
    public Func<string?>? Distro { get; init; }

    /// <summary>
    /// Hooks <see cref="SystemEvents"/> (sleep, lock, taskbar theme and DPI, reduce motion). First use
    /// of SystemEvents starts a hidden message window and a thread. Tests turn it off.
    /// </summary>
    public bool ListenToSystemEvents { get; init; } = true;
}

/// <summary>
/// The glue: poller to snapshot to <see cref="RunnerPlan"/> to <see cref="FrameSequencer"/> to the tray icon,
/// plus toasts and the actions. Public members are for the UI thread.
/// </summary>
public sealed class TrayController : IDisposable
{
    private readonly IBenchSource _source;
    private readonly ITrayHost _host;
    private readonly BenchPoller _poller;
    private readonly RunnerIcons _icons;
    private readonly FrameSequencer _sequencer;
    private readonly ToastPolicy _toasts;
    private readonly bool _listenToSystemEvents;
    private readonly CancellationTokenSource _cts = new();
    private readonly object _powerGate = new();

    private SpeedSmoother _smoother = new();
    private TraySnapshot _snapshot = TraySnapshot.Empty;
    private RunnerSet _runners;
    private string _runnerId;
    private AppearanceMode _appearance;
    private ResolvedTheme _theme;
    private bool _slept;
    private bool _locked;
    private bool _started;
    private bool _disposed;

    public TrayController(IBenchSource source, IFrameClock clock, ITrayHost host, TimeProvider time, TrayOptions? options = null)
    {
        options ??= new TrayOptions();
        _source = source;
        _host = host;
        _listenToSystemEvents = options.ListenToSystemEvents;
        _runners = options.Runners;
        _runnerId = options.RunnerId;
        _appearance = options.Appearance;
        _theme = ThemeResolver.Resolve(_appearance);
        _toasts = new ToastPolicy { Enabled = options.Notifications };
        _icons = new RunnerIcons(TrayMetrics.IconSide(TrayMetrics.TaskbarDpi()), _theme.TaskbarLight, _runners.Resolve(_runnerId));
        _sequencer = new FrameSequencer(clock, (pose, frame) => _host.SetIcon(_icons.Get(pose, frame)), _icons.FrameCount);
        _poller = new BenchPoller(source, time, options.DistroProbe, options.Distro ?? (() => DistroName.Resolve(null)));
        _poller.Updated += OnPolled;
    }

    public FrameSequencer Sequencer => _sequencer;

    public RunnerIcons Icons => _icons;

    public BenchPoller Poller => _poller;

    public IBenchSource Source => _source;

    /// <summary>What the last poll found.</summary>
    public TraySnapshot Snapshot => _snapshot;

    /// <summary>The benches of the last poll.</summary>
    public IReadOnlyList<BenchStatus> Benches => _snapshot.Benches;

    /// <summary>Whether the flyout (app windows) and the runner (taskbar) are light now.</summary>
    public ResolvedTheme Theme => _theme;

    public RunnerSet Runners => _runners;

    public string RunnerId => _runnerId;

    public AppearanceMode Appearance => _appearance;

    public bool Notifications
    {
        get => _toasts.Enabled;
        set => _toasts.Enabled = value;
    }

    /// <summary>Shows the unknown pose, hooks the system events and starts polling.</summary>
    public void Start()
    {
        if (_started) return;
        _started = true;
        _host.SetTooltip("BenchBar: starting");
        _sequencer.Play(RunnerPlan.ForState(BenchState.Unknown, TrayMetrics.ReduceMotion()));
        if (_listenToSystemEvents)
        {
            SystemEvents.PowerModeChanged += OnPowerModeChanged;
            SystemEvents.SessionSwitch += OnSessionSwitch;
            SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
        }
        _poller.Start();
    }

    // --- the flyout ---

    public void FlyoutOpened()
    {
        _poller.SetFlyoutOpen(true);
        _poller.Kick();
    }

    public void FlyoutClosed() => _poller.SetFlyoutOpen(false);

    // --- settings ---

    /// <summary>Another runner by id (a broken or unknown id gives the Bench). Redraws the icon.</summary>
    public void SetRunner(string id)
    {
        _runnerId = id;
        ApplyRunner();
    }

    /// <summary>A freshly loaded set (the Runner menu re-read the folder); the selected id stays if it is still usable.</summary>
    public void ReloadRunners(RunnerSet runners)
    {
        _runners = runners;
        ApplyRunner();
    }

    private void ApplyRunner()
    {
        var art = _runners.Resolve(_runnerId);
        if (ReferenceEquals(art, _icons.Runner)) return;
        _icons.SetRunner(art);
        _sequencer.Rebuild();
    }

    public void SetAppearance(AppearanceMode mode)
    {
        _appearance = mode;
        RefreshAppearance();
    }

    // --- actions ---

    /// <summary>Stops a running or starting bench, starts any other (the result says why a refusal failed), then polls at once and keeps polling fast for a minute.</summary>
    public async Task<ActionResult> StartStopAsync(BenchStatus bench)
    {
        var verb = bench.State is BenchState.Running or BenchState.Starting ? "down" : "up";
        return await RunActionAsync(verb, bench).ConfigureAwait(false);
    }

    public Task<ActionResult> RestartAsync(BenchStatus bench) => RunActionAsync("restart", bench);

    private async Task<ActionResult> RunActionAsync(string verb, BenchStatus bench)
    {
        try
        {
            return await _source.RunAsync([verb, "--bench-dir", bench.Path], _cts.Token).ConfigureAwait(false);
        }
        catch (SourceProblemException ex)
        {
            return ActionResult.Failure(ex.Message);
        }
        finally
        {
            // stopping has no state of its own, so a short fast window is the only way to see it end
            _poller.BoostFor(BenchPoller.ActionBoost);
        }
    }

    /// <summary>Boots the distro (<c>keepalive run</c>, detached) and polls every 2 s until it is up, for at most a minute.</summary>
    public bool StartDistro()
    {
        var started = _source.StartDistro();
        if (started) _poller.BoostFor(BenchPoller.ActionBoost, untilDistroUp: true);
        else _poller.Kick();
        return started;
    }

    public void OpenSite(BenchStatus bench)
    {
        if (string.IsNullOrWhiteSpace(bench.WebUrl)) return;
        Process.Start(new ProcessStartInfo(bench.WebUrl) { UseShellExecute = true })?.Dispose();
    }

    // --- poll results ---

    private void OnPolled(TraySnapshot snapshot)
    {
        var cpu = _poller.CpuPercent;
        _host.Post(() => Apply(snapshot, cpu));
    }

    private void Apply(TraySnapshot snapshot, double? cpu)
    {
        if (_disposed) return;
        _snapshot = snapshot;
        var states = snapshot.Benches.Select(b => b.State).ToList();
        var aggregate = AggregateFor(snapshot, states);

        _sequencer.Play(RunnerPlan.ForState(aggregate, TrayMetrics.ReduceMotion()));
        if (aggregate == BenchState.Running)
            _sequencer.SetSpeed(_smoother.Add(SpeedMapping.Speed(cpu ?? 0)));
        else
        {
            _smoother.Reset();
            _sequencer.SetSpeed(SpeedMapping.Min);
        }

        _host.SetTooltip(Tooltip(snapshot, BenchAggregate.UpText(states)));
        _host.BenchesChanged(snapshot, UpText(snapshot, states));
        foreach (var toast in _toasts.Observe(snapshot)) _host.ShowToast(toast);
    }

    /// <summary>A setup or CLI problem shows the unknown pose; a stopped distro the sleeping one; else the worst bench.</summary>
    private static BenchState AggregateFor(TraySnapshot snapshot, IEnumerable<BenchState> states) =>
        snapshot.Problem is not null ? BenchState.Unknown
        : snapshot.DistroStopped ? BenchState.Stopped
        : BenchAggregate.State(states);

    /// <summary>The short summary beside the title: "2 of 3 up", "none up", "distro stopped" or "needs attention".</summary>
    public static string UpText(TraySnapshot snapshot, IReadOnlyList<BenchState> states) =>
        snapshot.Problem is not null ? "needs attention"
        : snapshot.DistroStopped ? "distro stopped"
        : BenchAggregate.UpText(states);

    /// <summary>"BenchBar: 2 benches, none up".</summary>
    public static string Tooltip(int benchCount, string upText) =>
        $"BenchBar: {benchCount} {(benchCount == 1 ? "bench" : "benches")}, {upText}";

    /// <summary>The tooltip for a snapshot, at most 127 characters (the shell's limit).</summary>
    public static string Tooltip(TraySnapshot snapshot, string upText)
    {
        var text = snapshot.Problem is { } problem ? $"BenchBar: {problem}"
            : snapshot.DistroStopped ? $"BenchBar: {snapshot.Distro ?? "WSL distro"} is not running"
            : Tooltip(snapshot.Benches.Count, upText);
        return text.Length <= 127 ? text : text[..126] + "…";
    }

    // --- system events ---

    private void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Suspend) SetAway(slept: true, locked: null);
        else if (e.Mode == PowerModes.Resume) SetAway(slept: false, locked: null);
    }

    private void OnSessionSwitch(object? sender, SessionSwitchEventArgs e)
    {
        switch (e.Reason)
        {
            case SessionSwitchReason.SessionLock:
            case SessionSwitchReason.ConsoleDisconnect:
            case SessionSwitchReason.RemoteDisconnect:
                SetAway(slept: null, locked: true);
                break;
            case SessionSwitchReason.SessionUnlock:
            case SessionSwitchReason.ConsoleConnect:
            case SessionSwitchReason.RemoteConnect:
                SetAway(slept: null, locked: false);
                break;
        }
    }

    /// <summary>Asleep or locked: no poll timer, no frame timer. Back: poll now, animate again.</summary>
    private void SetAway(bool? slept, bool? locked)
    {
        bool away;
        lock (_powerGate)
        {
            if (slept is { } s) _slept = s;
            if (locked is { } l) _locked = l;
            away = _slept || _locked;
        }
        if (away)
        {
            _poller.Suspend();
            _host.Post(_sequencer.Pause);
        }
        else
        {
            _poller.Resume();
            _host.Post(_sequencer.Resume);
        }
    }

    private void OnUserPreferenceChanged(object? sender, UserPreferenceChangedEventArgs e) => _host.Post(RefreshAppearance);

    /// <summary>Re-reads the theme, the taskbar's DPI and reduce motion; redraws only what changed.</summary>
    public void RefreshAppearance()
    {
        if (_disposed) return;
        var side = TrayMetrics.IconSide(TrayMetrics.TaskbarDpi());
        _theme = ThemeResolver.Resolve(_appearance);
        var changed = side != _icons.Side || _theme.TaskbarLight != _icons.LightTaskbar;
        _icons.SetSlot(side, _theme.TaskbarLight);
        if (_snapshot.Benches.Count > 0 || _snapshot.DistroStopped || _snapshot.Problem is not null) Apply(_snapshot, _poller.CpuPercent);
        if (changed) _sequencer.Refresh();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (_listenToSystemEvents && _started)
        {
            SystemEvents.PowerModeChanged -= OnPowerModeChanged;
            SystemEvents.SessionSwitch -= OnSessionSwitch;
            SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
        }
        _cts.Cancel();
        _poller.Dispose();
        _sequencer.Pause();
        _icons.Dispose();
        _cts.Dispose();
    }
}
