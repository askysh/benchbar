namespace BenchBar.Tray.Core;

public enum PortSetupPhase { Planning, Review, Running, Finished, Failed }

/// <summary>A bench the sheet sets up.</summary>
public sealed record PortBench(string Path, string Name);

/// <summary>
/// The state behind the Port Settings and Setup sheet (macos PortSetupRun): <c>ports plan --json -- PATH</c>, the mode
/// (<c>ports mode</c>), Refresh Preview, and Apply (<c>ports apply TOKEN --yes -- PATH</c>). One approval covers the whole allocation, which the
/// CLI checks again under its lock. With <see cref="StartAfterSetup"/> (Resolve and Start) the bench is started once the apply worked, after
/// the ports are checked once more. Raises <see cref="Changed"/> on the context captured at construction.
/// </summary>
public sealed class PortSetupModel : IDisposable
{
    private readonly ICliClient _cli;
    private readonly SynchronizationContext? _context = SynchronizationContext.Current;
    private readonly List<string> _output = [];
    private CancellationTokenSource? _cts = new();
    private bool _disposed;

    public PortSetupModel(ICliClient cli, IReadOnlyList<PortBench> benches, bool startAfterSetup = false, bool opensSettings = false)
    {
        _cli = cli;
        Benches = benches;
        StartAfterSetup = startAfterSetup && benches.Count == 1;
        OpensSettings = opensSettings && !StartAfterSetup;
    }

    public IReadOnlyList<PortBench> Benches { get; }

    public bool StartAfterSetup { get; }

    /// <summary>Opened from Port Settings and Setup: ports and mode first, setup only when there is something to set up.</summary>
    public bool OpensSettings { get; }

    public event Action? Changed;

    public PortSetupPhase Phase { get; private set; } = PortSetupPhase.Planning;

    public PortPlanDocument? Plan { get; private set; }

    /// <summary>Why the sheet failed, shown with the title "Setup did not finish".</summary>
    public string? Error { get; private set; }

    /// <summary>The error of the last mode change.</summary>
    public string? ModeError { get; private set; }

    public string Output => string.Join(Environment.NewLine, _output);

    public bool IsBusy => Phase is PortSetupPhase.Planning or PortSetupPhase.Running;

    /// <summary>A running apply cannot be dismissed.</summary>
    public bool IsDismissible => Phase != PortSetupPhase.Running;

    public string Title
    {
        get
        {
            if (StartAfterSetup) return "Resolve Port Conflict";
            if (OpensSettings) return "Port Settings";
            return Benches.Count == 1 ? $"Set Up {Benches[0].Name}" : "Set Up Selected Benches";
        }
    }

    /// <summary>The plan has nothing to set up: Port Settings shows the ports and the mode only, and no setup action.</summary>
    public bool NothingToSetUp => OpensSettings && Plan is { } plan && !plan.Entries.Any(e => e.NeedsSetup);

    public bool CanApply => Phase == PortSetupPhase.Review && Plan is { CanApply: true } && !NothingToSetUp;

    /// <summary>"Resolve and Start", "Set Up Bench" or "Set Up Selected Benches".</summary>
    public string ApplyLabel => StartAfterSetup ? "Resolve and Start" : OpensSettings || Benches.Count == 1 ? "Set Up Bench" : "Set Up Selected Benches";

    public string SuccessText => StartAfterSetup
        ? "Setup completed and the start command succeeded."
        : "Management is set up. Start the benches when you are ready.";

    public async Task LoadPlanAsync(CancellationToken ct = default)
    {
        Phase = PortSetupPhase.Planning;
        Plan = null;
        Raise();
        var paths = Benches.Select(b => b.Path).ToList();
        var result = await _cli.RunJsonAsync(PortArgs.Plan(paths), null, CliTimeouts.Plan, PortsJson.ParsePlan, Link(ct)).ConfigureAwait(true);
        if (_disposed) return;
        if (result.Value is not { } plan)
        {
            Error = result.Error ?? "The ports could not be planned.";
            Phase = PortSetupPhase.Failed;
        }
        else if (plan.CanApply && plan.Entries.Any(e => string.IsNullOrWhiteSpace(e.SetupPlan)))
        {
            Plan = plan;
            Error = "The CLI did not provide a service-change preview. Upgrade benchbar and refresh the preview before applying.";
            Phase = PortSetupPhase.Failed;
        }
        else
        {
            Plan = plan;
            Error = null;
            Phase = PortSetupPhase.Review;
        }
        Raise();
    }

    /// <summary>Saves the mode of one bench at once (it moves no port), then reads the plan again.</summary>
    public async Task SetModeAsync(PortMode mode, string path)
    {
        if (Phase != PortSetupPhase.Review || Benches.All(b => b.Path != path)) return;
        Phase = PortSetupPhase.Running;
        ModeError = null;
        Raise();
        var result = await _cli.RunStreamAsync(PortArgs.Mode(mode, path), null, CliTimeouts.Read, _ => { }, Link(default)).ConfigureAwait(true);
        if (_disposed) return;
        if (!result.Ok) ModeError = result.Problem ?? $"The mode could not be saved (exit {result.Exit}).";
        await LoadPlanAsync().ConfigureAwait(true);
    }

    public async Task ApplyAsync()
    {
        if (!CanApply || Plan is not { } plan) return;
        Phase = PortSetupPhase.Running;
        _output.Clear();
        Raise();
        var paths = Benches.Select(b => b.Path).ToList();
        var token = Link(default);
        var apply = await _cli.RunStreamAsync(PortArgs.Apply(plan.Token, paths), null, CliTimeouts.Apply, OnLine, token).ConfigureAwait(true);
        if (_disposed) return;
        if (!apply.Ok)
        {
            // a batch may have finished earlier entries: the page polls again to show what exists
            Error = PortSetupHints.Failures(apply.TextLines) ?? apply.Problem ?? $"ports apply failed (exit {apply.Exit}).";
            Phase = PortSetupPhase.Failed;
            Raise();
            return;
        }
        if (StartAfterSetup && Benches.Count == 1)
        {
            var path = Benches[0].Path;
            var guard = await PortGuard.CheckAsync(_cli, path, PortGuardAction.Start, token).ConfigureAwait(true);
            if (!guard.Allowed)
            {
                Error = guard.Conflict
                    ? "Setup completed, but a port is now occupied. The bench was not started. " + string.Join(" ", guard.Check?.Conflicts ?? [])
                    : "Setup completed, but the bench was not started. " + guard.Refusal;
                Phase = PortSetupPhase.Failed;
                Raise();
                return;
            }
            var start = await _cli.RunStreamAsync(PortArgs.Start(path), null, CliTimeouts.Apply, OnLine, token).ConfigureAwait(true);
            if (_disposed) return;
            if (!start.Ok)
            {
                Error = "Setup completed, but the bench did not start. " + (start.Problem ?? $"up failed (exit {start.Exit}).");
                Phase = PortSetupPhase.Failed;
                Raise();
                return;
            }
        }
        Phase = PortSetupPhase.Finished;
        Raise();
    }

    private void OnLine(CliEvent e)
    {
        if (e is CliEvent.Text t)
        {
            lock (_output) _output.Add(t.Line);
            Raise();
        }
    }

    private CancellationToken Link(CancellationToken ct) =>
        ct.CanBeCanceled && _cts is { } cts ? CancellationTokenSource.CreateLinkedTokenSource(ct, cts.Token).Token : _cts?.Token ?? ct;

    private void Raise()
    {
        if (_context is null || SynchronizationContext.Current == _context) Changed?.Invoke();
        else _context.Post(_ => { if (!_disposed) Changed?.Invoke(); }, null);
    }

    public void Dispose()
    {
        _disposed = true;
        try { _cts?.Cancel(); } catch (ObjectDisposedException) { }
        _cts = null;
    }
}
