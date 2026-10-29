using System.Text;
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
    private readonly List<(TraySnapshot Snapshot, string UpText)> _changes = [];
    private readonly List<Toast> _toastsShown = [];
    private string _tooltip = "";

    public IReadOnlyList<IntPtr> Icons { get { lock (_gate) return [.. _icons]; } }
    public string Tooltip { get { lock (_gate) return _tooltip; } }
    public IReadOnlyList<(TraySnapshot Snapshot, string UpText)> Changes { get { lock (_gate) return [.. _changes]; } }
    public IReadOnlyList<Toast> Toasts { get { lock (_gate) return [.. _toastsShown]; } }

    public void SetIcon(IntPtr hicon) { lock (_gate) _icons.Add(hicon); }
    public void SetTooltip(string text) { lock (_gate) _tooltip = text; }
    /// <summary>Stands in for the UI thread: posted work and the test's own UI calls never overlap, as on a dispatcher.</summary>
    public object UiThread { get; } = new();

    public void Post(Action action) { lock (UiThread) action(); }

    public void Ui(Action action) { lock (UiThread) action(); }

    public T Ui<T>(Func<T> action) { lock (UiThread) return action(); }

    /// <summary>Disposes on the "UI thread" too: the app disposes the controller on its dispatcher.</summary>
    public IDisposable Owning(IDisposable owned) => new UiOwned(this, owned);

    private sealed class UiOwned(FakeHost host, IDisposable owned) : IDisposable
    {
        public void Dispose() => host.Ui(owned.Dispose);
    }
    public void BenchesChanged(TraySnapshot snapshot, string upText) { lock (_gate) _changes.Add((snapshot, upText)); }
    public void ShowToast(Toast toast) { lock (_gate) _toastsShown.Add(toast); }
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
    public Dictionary<string, BenchStatus> Overrides { get; } = [];
    public Exception? ListFails { get; set; }
    public Exception? StatusFails { get; set; }
    public int Statuses => Volatile.Read(ref _statuses);
    public int DistroStarts { get; private set; }
    private int _statuses;

    public async Task<IReadOnlyList<BenchEntry>> ListAsync(CancellationToken ct)
    {
        Enter();
        try
        {
            Interlocked.Increment(ref _lists);
            if (ListFails is not null) throw ListFails;
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
            Interlocked.Increment(ref _statuses);
            if (StatusFails is not null) throw StatusFails;
            if (Overrides.TryGetValue(bench.Name, out var status)) return Task.FromResult(status);
            return Task.FromResult(new BenchStatus(bench.Name, bench.Path, States[bench.Name], null, bench.WebUrl, null));
        }
        finally { Leave(); }
    }

    public ActionResult Result { get; set; } = ActionResult.Success;

    public Task<ActionResult> RunAsync(string[] args, CancellationToken ct)
    {
        lock (Actions) Actions.Add(string.Join(' ', args));
        return Task.FromResult(Result);
    }

    public Task<DoctorReport> DoctorAsync(string benchPath, CancellationToken ct) => Task.FromResult(new DoctorReport(benchPath, null, [], 0, 0, 0));

    public Task<LogTail> LogsAsync(string benchPath, CancellationToken ct, int lines = 300) => Task.FromResult(new LogTail(null, []));

    public Task<string> ReportAsync(string? benchPath, CancellationToken ct) => Task.FromResult("/tmp/report.zip");

    public bool StartDistro()
    {
        DistroStarts++;
        return true;
    }

    private void Enter()
    {
        var now = Interlocked.Increment(ref _active);
        lock (this) MaxConcurrent = Math.Max(MaxConcurrent, now);
    }

    private void Leave() => Interlocked.Decrement(ref _active);

}

/// <summary>A distro probe whose answer a test sets and whose calls it counts.</summary>
internal sealed class FakeProbe : IDistroProbe
{
    private int _calls;

    public bool Running { get; set; } = true;
    public Exception? Throws { get; set; }
    public int Calls => Volatile.Read(ref _calls);

    public Task<bool> IsRunningAsync(string distro, CancellationToken ct)
    {
        Interlocked.Increment(ref _calls);
        if (Throws is not null) throw Throws;
        return Task.FromResult(Running);
    }
}

/// <summary>A process runner that starts nothing: it answers from a script and records what it was asked.</summary>
internal sealed class FakeProcessRunner : IProcessRunner
{
    public List<(string File, string[] Args)> Calls { get; } = [];
    public List<(string File, string[] Args)> Detached { get; } = [];
    public Func<string, string[], ProcessResult> Answer { get; set; } = (_, _) => new ProcessResult(0, "", "");
    public Exception? Throws { get; set; }
    public Encoding? LastEncoding { get; private set; }
    public TimeSpan? LastTimeout { get; private set; }

    public Task<ProcessResult> RunAsync(string fileName, IReadOnlyList<string> args, CancellationToken ct, TimeSpan? timeout = null, Encoding? outputEncoding = null)
    {
        Calls.Add((fileName, [.. args]));
        LastEncoding = outputEncoding;
        LastTimeout = timeout;
        if (Throws is not null) throw Throws;
        return Task.FromResult(Answer(fileName, [.. args]));
    }

    public void StartDetached(string fileName, IReadOnlyList<string> args)
    {
        if (Throws is not null) throw Throws;
        Detached.Add((fileName, [.. args]));
    }
}
