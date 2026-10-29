using BenchBar.Tray.Core;

namespace Tray.Core.Tests;

internal static class Fixtures
{
    /// <summary>The spike's fixtures folder, found by walking up from the test binaries.</summary>
    public static string Root { get; } = Find();

    public static string Dir(string name) => Path.Combine(Root, name);

    private static string Find()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "fixtures");
            if (Directory.Exists(Path.Combine(candidate, "recorded"))) return candidate;
        }
        throw new DirectoryNotFoundException("fixtures folder not found above " + AppContext.BaseDirectory);
    }

    /// <summary>A scratch copy of a fixture folder that a test may change.</summary>
    public static string Copy(string name)
    {
        var target = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(target);
        foreach (var file in Directory.GetFiles(Dir(name)))
            File.Copy(file, Path.Combine(target, Path.GetFileName(file)));
        return target;
    }
}

/// <summary>A frame clock that holds one pending callback and fires it on demand.</summary>
internal sealed class FakeFrameClock : IFrameClock
{
    private Action? _tick;

    public TimeSpan? PendingDelay { get; private set; }

    public bool HasPending => _tick is not null;

    public int ScheduleCount { get; private set; }

    public void Schedule(TimeSpan delay, Action tick)
    {
        _tick = tick;
        PendingDelay = delay;
        ScheduleCount++;
    }

    public void Cancel()
    {
        _tick = null;
        PendingDelay = null;
    }

    /// <summary>Fires the pending callback, as the UI timer would.</summary>
    public void Fire()
    {
        var tick = _tick ?? throw new InvalidOperationException("no tick is pending");
        _tick = null;
        PendingDelay = null;
        tick();
    }
}

internal sealed class FakeHost : ITrayHost
{
    private readonly object _gate = new();
    private readonly List<IntPtr> _icons = [];
    private readonly List<(IReadOnlyList<BenchStatus> Benches, string UpText)> _changes = [];
    private string _tooltip = "";

    public IReadOnlyList<IntPtr> Icons { get { lock (_gate) return [.. _icons]; } }
    public string Tooltip { get { lock (_gate) return _tooltip; } }
    public IReadOnlyList<(IReadOnlyList<BenchStatus> Benches, string UpText)> Changes { get { lock (_gate) return [.. _changes]; } }

    public void SetIcon(IntPtr hicon) { lock (_gate) _icons.Add(hicon); }
    public void SetTooltip(string text) { lock (_gate) _tooltip = text; }
    public void Post(Action action) => action();
    public void BenchesChanged(IReadOnlyList<BenchStatus> benches, string upText) { lock (_gate) _changes.Add((benches, upText)); }
}

/// <summary>A source whose answers a test controls and whose calls it can count.</summary>
internal sealed class ScriptedSource : IBenchSource, ILoadSource
{
    private int _active;
    private int _lists;

    public List<BenchEntry> Entries { get; } = [new BenchEntry("a", "/a", true, "http://a.localhost:8000")];
    public Dictionary<string, BenchState> States { get; } = new() { ["a"] = BenchState.Stopped };
    public double? CpuPercent { get; set; }
    public int MaxConcurrent { get; private set; }
    public int Lists => Volatile.Read(ref _lists);
    public List<string> Actions { get; } = [];
    public TimeSpan Latency { get; set; } = TimeSpan.Zero;

    public async Task<IReadOnlyList<BenchEntry>> ListAsync(CancellationToken ct)
    {
        Enter();
        try
        {
            Interlocked.Increment(ref _lists);
            if (Latency > TimeSpan.Zero) await Task.Delay(Latency, ct);
            return [.. Entries];
        }
        finally { Leave(); }
    }

    public Task<BenchStatus> StatusAsync(BenchEntry bench, CancellationToken ct)
    {
        Enter();
        try
        {
            return Task.FromResult(new BenchStatus(bench.Name, bench.Path, States[bench.Name], null, bench.WebUrl, null));
        }
        finally { Leave(); }
    }

    public Task<int> RunAsync(string[] args, CancellationToken ct)
    {
        lock (Actions) Actions.Add(string.Join(' ', args));
        return Task.FromResult(0);
    }

    private void Enter()
    {
        var now = Interlocked.Increment(ref _active);
        lock (this) MaxConcurrent = Math.Max(MaxConcurrent, now);
    }

    private void Leave() => Interlocked.Decrement(ref _active);

}
