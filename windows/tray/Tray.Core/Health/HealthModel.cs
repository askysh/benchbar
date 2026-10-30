namespace BenchBar.Tray.Core;

/// <summary>The exact arguments of the Health tab's calls, in one place so a test can pin them.</summary>
public static class HealthArgs
{
    public static string[] Doctor(string benchPath) => ["doctor", "--json", "--bench-dir", benchPath];

    /// <summary>The shim's own rows. No <c>--probe</c>: it must never start a stopped distro.</summary>
    public static string[] ShimCheck { get; } = ["setup", "check", "--json"];

    public static string[] RepairPlan(string benchPath) => ["repair", "--dry-run", "--json", "--bench-dir", benchPath];

    public static string[] Repair(string benchPath) => ["repair", "--yes", "--json", "--bench-dir", benchPath];

    public static string[] LockCheck(string benchPath) => ["lock", "check", "--json", "--bench-dir", benchPath];
}

/// <summary>
/// What the Health tab shows for one bench: the doctor checks of the bench and the shim's own rows (Windows build, WSL, systemd...).
/// Both are read only. <see cref="RunAsync"/> asks again; a newer run replaces one still going. Raises <see cref="Changed"/> on the
/// context captured at construction (the UI thread).
/// </summary>
public sealed class HealthModel : IDisposable
{
    private readonly ICliClient _cli;
    private readonly SynchronizationContext? _context = SynchronizationContext.Current;
    private CancellationTokenSource? _run;
    private bool _disposed;

    public HealthModel(ICliClient cli, string benchPath)
    {
        _cli = cli;
        BenchPath = benchPath;
    }

    public string BenchPath { get; }

    public event Action? Changed;

    public bool IsRunning { get; private set; }

    /// <summary>True once a run has ended, whatever it found.</summary>
    public bool HasRun { get; private set; }

    public HealthReport? Report { get; private set; }

    /// <summary>Why doctor gave no report (the CLI failed, printed no JSON, or was not found).</summary>
    public string? Error { get; private set; }

    public SetupReport? Shim { get; private set; }

    public string? ShimError { get; private set; }

    public bool Repairable => Report?.Repairable == true;

    public async Task RunAsync(CancellationToken ct = default)
    {
        _run?.Cancel();
        var source = CancellationTokenSource.CreateLinkedTokenSource(ct);
        _run = source;
        var token = source.Token;
        IsRunning = true;
        Error = null;
        ShimError = null;
        Raise();
        try
        {
            var doctor = _cli.RunJsonAsync(HealthArgs.Doctor(BenchPath), null, CliTimeouts.Read, HealthJson.ParseDoctor, token);
            var shim = _cli.RunJsonAsync(HealthArgs.ShimCheck, null, CliTimeouts.Read, HealthJson.ParseSetupCheck, token);
            var report = await doctor.ConfigureAwait(true);
            var rows = await shim.ConfigureAwait(true);
            if (_disposed || token.IsCancellationRequested) return;
            if (report.Value is { } value)
            {
                Report = value;
            }
            else
            {
                Report = null;
                Error = report.Error ?? "Doctor gave no report.";
            }
            if (rows.Value is { } setup)
            {
                Shim = setup;
            }
            else
            {
                Shim = null;
                ShimError = rows.Error ?? "The Windows checks gave no answer.";
            }
        }
        catch (OperationCanceledException)
        {
            return;
        }
        finally
        {
            if (!token.IsCancellationRequested && !_disposed)
            {
                IsRunning = false;
                HasRun = true;
                Raise();
            }
        }
    }

    private void Raise()
    {
        if (_context is null || SynchronizationContext.Current == _context) Changed?.Invoke();
        else _context.Post(_ => { if (!_disposed) Changed?.Invoke(); }, null);
    }

    public void Dispose()
    {
        _disposed = true;
        try { _run?.Cancel(); } catch (ObjectDisposedException) { }
    }
}
