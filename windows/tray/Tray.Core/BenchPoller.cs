namespace BenchBar.Tray.Core;

/// <summary>
/// The Mac's event driven polling, adapted: nothing watches files inside WSL
/// from Windows, so this is one re-armed one shot timer that backs off when
/// nothing is up. Source calls never overlap, a kick during a poll becomes one
/// more poll right after it, and a suspended poller holds no timer at all.
/// When a distro probe is given it asks first on every poll; while the distro is
/// stopped it makes no CLI call (that would boot it) and backs off the probe on the idle steps.
/// </summary>
public sealed class BenchPoller : IDisposable
{
    public static readonly TimeSpan FlyoutOpenDelay = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan StartingDelay = TimeSpan.FromSeconds(2);
    public static readonly TimeSpan RunningDelay = TimeSpan.FromSeconds(30);

    /// <summary>How long polling stays fast after an up, down or restart.</summary>
    public static readonly TimeSpan ActionBoost = TimeSpan.FromSeconds(60);

    /// <summary>The back off for a poller with nothing up: 30, 60, 120, then 300 s for good.</summary>
    public static readonly IReadOnlyList<TimeSpan> IdleSteps =
        [TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(60), TimeSpan.FromSeconds(120), TimeSpan.FromSeconds(300)];

    /// <summary>
    /// The time to the next poll. Boosted (just after an action) 2 s; flyout open 5 s; any bench starting 2 s;
    /// any running 30 s; else (stopped, paused, crashed, unknown, distro stopped) the back off,
    /// where <paramref name="idleStep"/> counts the idle polls so far.
    /// </summary>
    public static TimeSpan NextDelay(IReadOnlyCollection<BenchState> states, bool flyoutOpen, int idleStep, bool boost = false)
    {
        if (boost) return StartingDelay;
        if (flyoutOpen) return FlyoutOpenDelay;
        if (states.Contains(BenchState.Starting)) return StartingDelay;
        if (states.Contains(BenchState.Running)) return RunningDelay;
        return IdleSteps[Math.Clamp(idleStep, 0, IdleSteps.Count - 1)];
    }

    public const string WslSilentMessage = "wsl.exe did not answer: WSL may be starting or stuck. Run wsl.exe --status.";
    public const string WslMissingMessage = "WSL is not installed: wsl.exe --install";

    private readonly IBenchSource _source;
    private readonly TimeProvider _time;
    private readonly IDistroProbe? _probe;
    private readonly Func<string?>? _distro;
    private readonly ITimer _timer;
    private readonly CancellationTokenSource _cts = new();
    private readonly object _gate = new();

    private bool _started;
    private bool _polling;
    private bool _kickPending;
    private bool _suspended;
    private bool _flyoutOpen;
    private bool _disposed;
    private int _idleStep;
    private DateTimeOffset _boostUntil;
    private bool _boostEndsWhenDistroUp;
    private IReadOnlyList<BenchEntry> _entries = [];
    private TraySnapshot _last = TraySnapshot.Empty;

    /// <param name="probe">Asked first on every poll; null means no distro gate (fixtures).</param>
    /// <param name="distro">The distro name to ask about, read on every poll; null or empty skips the gate.</param>
    public BenchPoller(IBenchSource source, TimeProvider time, IDistroProbe? probe = null, Func<string?>? distro = null)
    {
        _source = source;
        _time = time;
        _probe = probe;
        _distro = distro;
        _timer = time.CreateTimer(_ => Trigger(resetBackoff: false), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }

    /// <summary>Raised on a thread pool thread after every poll.</summary>
    public event Action<TraySnapshot>? Updated;

    /// <summary>The load the source reported with the last poll, when it reports one.</summary>
    public double? CpuPercent { get; private set; }

    /// <summary>The snapshot of the last poll (empty before the first).</summary>
    public TraySnapshot Last
    {
        get { lock (_gate) return _last; }
    }

    /// <summary>Lists the benches and asks each one's status, now.</summary>
    public void Start()
    {
        lock (_gate) _started = true;
        Trigger(resetBackoff: true);
    }

    /// <summary>An action, the flyout opening, resume or unlock: reset the back off and poll now.</summary>
    public void Kick() => Trigger(resetBackoff: true);

    /// <summary>
    /// Poll every 2 s for <paramref name="duration"/> (an up, down or restart has no state of its own while it
    /// works), and now. With <paramref name="untilDistroUp"/> the window ends as soon as a poll finds the distro running.
    /// </summary>
    public void BoostFor(TimeSpan duration, bool untilDistroUp = false)
    {
        lock (_gate)
        {
            _boostUntil = _time.GetUtcNow() + duration;
            _boostEndsWhenDistroUp = untilDistroUp;
        }
        Trigger(resetBackoff: true);
    }

    public void SetFlyoutOpen(bool open)
    {
        lock (_gate)
        {
            if (_flyoutOpen == open) return;
            _flyoutOpen = open;
            // an armed timer follows the new interval; a poll in progress picks it up when it ends
            if (_started && !_polling && !_suspended && !_disposed) Arm(advanceBackoff: false);
        }
    }

    /// <summary>Sleep or lock: no timer at all until <see cref="Resume"/>.</summary>
    public void Suspend()
    {
        lock (_gate)
        {
            _suspended = true;
            _kickPending = false;
            _timer.Change(Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
        }
    }

    /// <summary>Wake or unlock: poll now with the back off reset.</summary>
    public void Resume()
    {
        lock (_gate) _suspended = false;
        Trigger(resetBackoff: true);
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
            _timer.Dispose();
        }
        _cts.Cancel();
        _cts.Dispose();
    }

    private void Trigger(bool resetBackoff)
    {
        lock (_gate)
        {
            if (_disposed || _suspended || !_started) return;
            if (resetBackoff) _idleStep = 0;
            if (_polling)
            {
                _kickPending = true; // coalesced into one more poll
                return;
            }
            _polling = true;
            _timer.Change(Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
        }
        _ = Task.Run(PollLoopAsync);
    }

    private async Task PollLoopAsync()
    {
        while (true)
        {
            var snapshot = await PollOnceAsync().ConfigureAwait(false);
            lock (_gate)
            {
                if (_disposed) return;
                _last = snapshot;
                if (!_suspended && !_kickPending) Arm(advanceBackoff: true);
            }
            RaiseUpdated(snapshot);
            lock (_gate)
            {
                if (_disposed) return;
                if (_kickPending && !_suspended)
                {
                    _kickPending = false;
                    _timer.Change(Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
                    continue;
                }
                _kickPending = false;
                _polling = false;
                return;
            }
        }
    }

    /// <summary>Re-arms the one shot timer for <see cref="NextDelay"/>. Call with the gate held.</summary>
    private void Arm(bool advanceBackoff)
    {
        var states = _last.Benches.Select(s => s.State).ToList();
        var boost = _time.GetUtcNow() < _boostUntil;
        var delay = NextDelay(states, _flyoutOpen, _idleStep, boost);
        var idle = !boost && !_flyoutOpen && !states.Contains(BenchState.Starting) && !states.Contains(BenchState.Running);
        if (!idle) _idleStep = 0;
        else if (advanceBackoff) _idleStep = Math.Min(_idleStep + 1, IdleSteps.Count - 1);
        _timer.Change(delay, Timeout.InfiniteTimeSpan);
    }

    private async Task<TraySnapshot> PollOnceAsync()
    {
        var ct = _cts.Token;

        string? distro = null;
        if (_probe is not null && _distro?.Invoke() is { } name && !string.IsNullOrWhiteSpace(name))
        {
            distro = name.Trim();
            bool running;
            try
            {
                running = await _probe.IsRunningAsync(distro, ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return TraySnapshot.Empty;
            }
            catch (Exception ex)
            {
                // The probe failed or timed out. Asking the CLI now could boot the distro, so it is not asked:
                // a problem line, the known benches as unknown, and the idle back off until a kick.
                return new TraySnapshot(
                    _entries.Select(UnknownStatus).ToList(), DistroStopped: false, Distro: distro,
                    Problem: ex is System.ComponentModel.Win32Exception ? WslMissingMessage : WslSilentMessage);
            }
            if (!running) return new TraySnapshot([], DistroStopped: true, Distro: distro);
            lock (_gate)
            {
                if (_boostEndsWhenDistroUp)
                {
                    _boostEndsWhenDistroUp = false;
                    _boostUntil = default;
                }
            }
        }

        IReadOnlyList<BenchEntry> entries;
        try
        {
            entries = await _source.ListAsync(ct).ConfigureAwait(false);
            _entries = entries;
        }
        catch (Exception ex) when (!ct.IsCancellationRequested)
        {
            // the CLI did not answer: show what was known as unknown, never a stale "running"
            return new TraySnapshot(
                _entries.Select(e => UnknownStatus(e)).ToList(), DistroStopped: false, Distro: distro, Problem: ProblemText(ex));
        }
        catch (OperationCanceledException)
        {
            return TraySnapshot.Empty;
        }

        var result = new List<BenchStatus>(entries.Count);
        foreach (var entry in entries)
        {
            try
            {
                result.Add(await _source.StatusAsync(entry, ct).ConfigureAwait(false));
            }
            catch (Exception ex) when (!ct.IsCancellationRequested)
            {
                // this bench's own line, shown under its row; the snapshot's Problem stays for the shim, list and probe
                result.Add(UnknownStatus(entry) with { Problem = ex is SourceProblemException ? ex.Message : "benchbar.exe status gave no usable answer." });
            }
            catch (OperationCanceledException)
            {
                return new TraySnapshot(result, false, distro);
            }
        }
        CpuPercent = (_source as ILoadSource)?.CpuPercent;
        return new TraySnapshot(result, false, distro);
    }

    private static BenchStatus UnknownStatus(BenchEntry entry) =>
        new(entry.Name, entry.Path, BenchState.Unknown, null, entry.WebUrl, null);

    private static string ProblemText(Exception ex) => ex is SourceProblemException
        ? ex.Message
        : "benchbar.exe gave no usable answer. Run benchbar.exe doctor.";

    private void RaiseUpdated(TraySnapshot snapshot)
    {
        try { Updated?.Invoke(snapshot); }
        catch (Exception) { /* a handler must not stop the polling */ }
    }
}
