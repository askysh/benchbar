namespace BenchBar.Tray.Core;

/// <summary>How fast Follow may ask for new lines now.</summary>
public enum FollowPace
{
    /// <summary>The viewer's own rate, backed off while nothing new arrives.</summary>
    Normal,

    /// <summary>No faster than <see cref="LogViewModel.SlowEvery"/> (battery saver).</summary>
    Slow,

    /// <summary>No poll and no timer at all (locked, asleep, the window minimized or hidden). It catches up with one poll when it ends.</summary>
    Paused,
}

/// <summary>What the PC is doing, as far as Follow cares: the same lock and sleep the bench poller stops for, and battery saver.</summary>
public interface IFollowGate
{
    FollowPace Pace { get; }

    /// <summary>Raised (on any thread) when <see cref="Pace"/> may have changed.</summary>
    event Action? Changed;
}

/// <summary>The gate the app feeds from <see cref="TrayController"/> (away) and the power state (battery saver).</summary>
public sealed class FollowGate : IFollowGate
{
    private readonly object _lock = new();
    private bool _away;
    private bool _saver;

    public event Action? Changed;

    public FollowPace Pace
    {
        get
        {
            lock (_lock) return _away ? FollowPace.Paused : _saver ? FollowPace.Slow : FollowPace.Normal;
        }
    }

    /// <summary>The PC is locked or asleep.</summary>
    public void SetAway(bool away) => Set(ref _away, away);

    /// <summary>Windows battery saver is on.</summary>
    public void SetBatterySaver(bool on) => Set(ref _saver, on);

    private void Set(ref bool field, bool value)
    {
        lock (_lock)
        {
            if (field == value) return;
            field = value;
        }
        Changed?.Invoke();
    }
}
