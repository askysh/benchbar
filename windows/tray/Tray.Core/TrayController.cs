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

    /// <summary>The benches or their summary changed; update the flyout.</summary>
    void BenchesChanged(IReadOnlyList<BenchStatus> benches, string upText);
}

/// <summary>
/// The glue both shells use: poller to aggregate state to <see cref="RunnerPlan"/>
/// to <see cref="FrameSequencer"/> to the tray icon. Public members are for the UI thread.
/// </summary>
public sealed class TrayController : IDisposable
{
    private readonly IBenchSource _source;
    private readonly ITrayHost _host;
    private readonly BenchPoller _poller;
    private readonly RunnerIcons _icons;
    private readonly FrameSequencer _sequencer;
    private readonly bool _listenToSystemEvents;
    private readonly CancellationTokenSource _cts = new();
    private readonly object _powerGate = new();

    private SpeedSmoother _smoother = new();
    private IReadOnlyList<BenchStatus> _benches = [];
    private bool _slept;
    private bool _locked;
    private bool _started;
    private bool _disposed;

    /// <param name="listenToSystemEvents">
    /// Hooks <see cref="SystemEvents"/> (sleep, lock, taskbar theme and DPI, reduce motion). First use
    /// of SystemEvents starts a hidden message window and a thread; both shells pay that alike.
    /// Tests turn it off.
    /// </param>
    public TrayController(IBenchSource source, IFrameClock clock, ITrayHost host, TimeProvider time, bool listenToSystemEvents = true)
    {
        _source = source;
        _host = host;
        _listenToSystemEvents = listenToSystemEvents;
        _icons = new RunnerIcons(TrayMetrics.IconSide(TrayMetrics.TaskbarDpi()), TaskbarTheme.IsLight());
        _sequencer = new FrameSequencer(clock, (pose, frame) => _host.SetIcon(_icons.Get(pose, frame)), _icons.FrameCount);
        _poller = new BenchPoller(source, time);
        _poller.Updated += OnPolled;
    }

    public FrameSequencer Sequencer => _sequencer;

    public RunnerIcons Icons => _icons;

    public BenchPoller Poller => _poller;

    /// <summary>The benches of the last poll.</summary>
    public IReadOnlyList<BenchStatus> Benches => _benches;

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

    // --- actions ---

    /// <summary>Stops a running or starting bench, starts any other, then polls at once.</summary>
    public async Task StartStopAsync(BenchStatus bench)
    {
        var verb = bench.State is BenchState.Running or BenchState.Starting ? "down" : "up";
        try
        {
            await _source.RunAsync([verb, "--bench-dir", bench.Path], _cts.Token).ConfigureAwait(false);
        }
        finally
        {
            _poller.Kick();
        }
    }

    public void OpenSite(BenchStatus bench)
    {
        if (string.IsNullOrWhiteSpace(bench.WebUrl)) return;
        Process.Start(new ProcessStartInfo(bench.WebUrl) { UseShellExecute = true })?.Dispose();
    }

    /// <summary>Opens a console window running <c>benchbar doctor</c>.</summary>
    public async Task RunDoctorAsync()
    {
        if (_source is CliBenchSource cli)
        {
            Process.Start(cli.DoctorStartInfo())?.Dispose();
            return;
        }
        await _source.RunAsync(["doctor"], _cts.Token).ConfigureAwait(false);
    }

    // --- poll results ---

    private void OnPolled(IReadOnlyList<BenchStatus> benches)
    {
        var cpu = _poller.CpuPercent;
        _host.Post(() => Apply(benches, cpu));
    }

    private void Apply(IReadOnlyList<BenchStatus> benches, double? cpu)
    {
        if (_disposed) return;
        _benches = benches;
        var states = benches.Select(b => b.State).ToList();
        var aggregate = BenchAggregate.State(states);
        var upText = BenchAggregate.UpText(states);

        _sequencer.Play(RunnerPlan.ForState(aggregate, TrayMetrics.ReduceMotion()));
        if (aggregate == BenchState.Running)
            _sequencer.SetSpeed(_smoother.Add(SpeedMapping.Speed(cpu ?? 0)));
        else
        {
            _smoother.Reset();
            _sequencer.SetSpeed(SpeedMapping.Min);
        }

        _host.SetTooltip(Tooltip(benches.Count, upText));
        _host.BenchesChanged(benches, upText);
    }

    /// <summary>"BenchBar: 2 benches, none up".</summary>
    public static string Tooltip(int benchCount, string upText) =>
        $"BenchBar: {benchCount} {(benchCount == 1 ? "bench" : "benches")}, {upText}";

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

    /// <summary>Re-reads the taskbar theme, its DPI and reduce motion; redraws only what changed.</summary>
    public void RefreshAppearance()
    {
        if (_disposed) return;
        var side = TrayMetrics.IconSide(TrayMetrics.TaskbarDpi());
        var light = TaskbarTheme.IsLight();
        var changed = side != _icons.Side || light != _icons.LightTaskbar;
        _icons.SetSlot(side, light);
        if (_benches.Count > 0) Apply(_benches, _poller.CpuPercent);
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
