namespace BenchBar.Tray.Core;

/// <summary>
/// The Mac's event driven polling, adapted: nothing watches files inside WSL
/// from Windows, so this is one re-armed one shot timer that backs off when
/// nothing is up. Source calls never overlap, a kick during a poll becomes one
/// more poll right after it, and a suspended poller holds no timer at all.
/// </summary>
public sealed class BenchPoller : IDisposable
{
    public static readonly TimeSpan FlyoutOpenDelay = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan StartingDelay = TimeSpan.FromSeconds(2);
    public static readonly TimeSpan RunningDelay = TimeSpan.FromSeconds(30);

    /// <summary>The back off for a poller with nothing up: 30, 60, 120, then 300 s for good.</summary>
    public static readonly IReadOnlyList<TimeSpan> IdleSteps =
        [TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(60), TimeSpan.FromSeconds(120), TimeSpan.FromSeconds(300)];

    /// <summary>
    /// The time to the next poll. Flyout open 5 s; any bench starting 2 s; any
    /// running 30 s; else (stopped, paused, crashed, unknown) the back off,
    /// where <paramref name="idleStep"/> counts the idle polls so far.
    /// </summary>
    public static TimeSpan NextDelay(IReadOnlyCollection<BenchState> states, bool flyoutOpen, int idleStep)
    {
        if (flyoutOpen) return FlyoutOpenDelay;
        if (states.Contains(BenchState.Starting)) return StartingDelay;
        if (states.Contains(BenchState.Running)) return RunningDelay;
        return IdleSteps[Math.Clamp(idleStep, 0, IdleSteps.Count - 1)];
    }

    private readonly IBenchSource _source;
    private readonly TimeProvider _time;
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
    private IReadOnlyList<BenchEntry> _entries = [];
    private IReadOnlyList<BenchStatus> _last = [];

    public BenchPoller(IBenchSource source, TimeProvider time)
    {
        _source = source;
        _time = time;
        _timer = time.CreateTimer(_ => Trigger(resetBackoff: false), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }

    /// <summary>Raised on a thread pool thread after every poll, with the benches in list order.</summary>
    public event Action<IReadOnlyList<BenchStatus>>? Updated;

    /// <summary>The load the source reported with the last poll, when it reports one.</summary>
    public double? CpuPercent { get; private set; }

    /// <summary>The benches of the last poll.</summary>
    public IReadOnlyList<BenchStatus> Last
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
            var statuses = await PollOnceAsync().ConfigureAwait(false);
            lock (_gate)
            {
                if (_disposed) return;
                _last = statuses;
                if (!_suspended && !_kickPending) Arm(advanceBackoff: true);
            }
            RaiseUpdated(statuses);
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
        var states = _last.Select(s => s.State).ToList();
        var delay = NextDelay(states, _flyoutOpen, _idleStep);
        var idle = !_flyoutOpen && !states.Contains(BenchState.Starting) && !states.Contains(BenchState.Running);
        if (!idle) _idleStep = 0;
        else if (advanceBackoff) _idleStep = Math.Min(_idleStep + 1, IdleSteps.Count - 1);
        _timer.Change(delay, Timeout.InfiniteTimeSpan);
    }

    private async Task<IReadOnlyList<BenchStatus>> PollOnceAsync()
    {
        var ct = _cts.Token;
        IReadOnlyList<BenchEntry> entries;
        try
        {
            entries = await _source.ListAsync(ct).ConfigureAwait(false);
            _entries = entries;
        }
        catch (Exception) when (!ct.IsCancellationRequested)
        {
            // the CLI did not answer: show what was known as unknown, never a stale "running"
            entries = _entries;
        }
        catch (OperationCanceledException)
        {
            return [];
        }

        var result = new List<BenchStatus>(entries.Count);
        foreach (var entry in entries)
        {
            try
            {
                result.Add(await _source.StatusAsync(entry, ct).ConfigureAwait(false));
            }
            catch (Exception) when (!ct.IsCancellationRequested)
            {
                result.Add(new BenchStatus(entry.Name, entry.Path, BenchState.Unknown, null, entry.WebUrl, null));
            }
            catch (OperationCanceledException)
            {
                return result;
            }
        }
        CpuPercent = (_source as ILoadSource)?.CpuPercent;
        return result;
    }

    private void RaiseUpdated(IReadOnlyList<BenchStatus> statuses)
    {
        try { Updated?.Invoke(statuses); }
        catch (Exception) { /* a handler must not stop the polling */ }
    }
}
