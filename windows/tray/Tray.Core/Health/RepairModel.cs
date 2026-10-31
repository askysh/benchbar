using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

public enum RepairPhase { Planning, Review, Running, Finished, Failed }

/// <summary>One step of a repair: from the plan's <c>actions[]</c>, then the <c>step</c> lines of the run.</summary>
public sealed record RepairStep(string Id, string Label, bool Sudo, InstallStepStatus Status = InstallStepStatus.Unknown, string Message = "");

/// <summary>The <c>plan</c> line of <c>repair --json</c>: <c>actions[]</c> and the run's log.</summary>
public sealed record RepairPlan(IReadOnlyList<RepairStep> Steps, string? Log)
{
    public static RepairPlan FromJson(JsonObject o)
    {
        if (o["actions"] is not JsonArray array) throw new FormatException("repair: the plan has no actions");
        var steps = new List<RepairStep>();
        foreach (var a in array.OfType<JsonObject>())
        {
            var id = JsonRead.Str(a, "id");
            if (string.IsNullOrEmpty(id)) continue;
            steps.Add(new RepairStep(id, JsonRead.Str(a, "label") ?? id, JsonRead.Bool(a, "sudo")));
        }
        return new RepairPlan(steps, JsonRead.Str(o, "log"));
    }
}

/// <summary>
/// One repair from the tray (macos RepairRun): the plan from <c>repair --dry-run --json</c>, the person's yes, then
/// <c>repair --yes --json</c> with a live step list. When a step needs sudo the Linux password is asked once, up front, and goes in
/// the environment of that one run (<see cref="CliSudo"/>). It never repairs on its own. While it runs it cannot be dismissed.
/// </summary>
public sealed class RepairModel : IDisposable
{
    private readonly ICliClient _cli;
    private readonly object _gate = new();
    private readonly SynchronizationContext? _context = SynchronizationContext.Current;
    private List<RepairStep> _steps = [];
    private CancellationTokenSource? _run;
    private bool _disposed;

    public RepairModel(ICliClient cli, string benchPath, string benchName)
    {
        _cli = cli;
        BenchPath = benchPath;
        BenchName = benchName;
    }

    public string BenchPath { get; }

    public string BenchName { get; }

    /// <summary>Asks for the Linux password; null cancels. The sheet sets it to the page services' dialog.</summary>
    public Func<LinuxPasswordRequest, Task<Secret?>> AskLinuxPassword { get; set; } = _ => Task.FromResult<Secret?>(null);

    public event Action? Changed;

    public RepairPhase Phase { get; private set; } = RepairPhase.Planning;

    public IReadOnlyList<RepairStep> Steps
    {
        get
        {
            lock (_gate) return [.. _steps];
        }
    }

    public string? Log { get; private set; }

    /// <summary>Why there is no plan, or why the run stopped without a result, or the line to show after a wrong password.</summary>
    public string? Message { get; private set; }

    public bool PasswordWasWrong { get; private set; }

    /// <summary>The exit code of a finished run (0: every check passes afterwards).</summary>
    public int? ExitCode { get; private set; }

    /// <summary>True once a run ended and the checks may have changed: the page asks doctor again.</summary>
    public bool Ran { get; private set; }

    public bool Succeeded => Phase == RepairPhase.Finished && ExitCode == 0;

    /// <summary>A running repair cannot be dismissed: the sheet ignores Escape and the close button until it ends.</summary>
    public bool IsDismissible => Phase != RepairPhase.Running;

    public int SudoSteps => Steps.Count(s => s.Sudo);

    public bool HasSudoSteps => SudoSteps > 0;

    public bool CanRepair => Phase == RepairPhase.Review && Steps.Count > 0;

    // --- plan ---

    public async Task LoadPlanAsync(CancellationToken ct = default)
    {
        Phase = RepairPhase.Planning;
        Message = null;
        Raise();
        var result = await _cli.RunJsonAsync(HealthArgs.RepairPlan(BenchPath), null, CliTimeouts.Plan, RepairPlan.FromJson, ct).ConfigureAwait(true);
        if (_disposed) return;
        if (result.Value is { } plan)
        {
            lock (_gate) _steps = [.. plan.Steps];
            Log = plan.Log;
            Phase = RepairPhase.Review;
        }
        else
        {
            Message = result.Error ?? "The repair plan could not be made.";
            Phase = RepairPhase.Failed;
        }
        Raise();
    }

    // --- run ---

    public async Task RunAsync()
    {
        if (!CanRepair) return;
        Secret? password = null;
        try
        {
            if (HasSudoSteps)
            {
                password = await AskLinuxPassword(new LinuxPasswordRequest(SudoSteps, PasswordWasWrong)).ConfigureAwait(true);
                if (password is null || password.IsEmpty) return; // cancelled: the plan stays up
            }
            var env = password is null ? null : CliSudo.Apply(null, password);
            using var cts = new CancellationTokenSource();
            lock (_gate)
            {
                _run = cts;
                _steps = [.. _steps.Select(s => s with { Status = InstallStepStatus.Unknown, Message = "" })];
            }
            PasswordWasWrong = false;
            Message = null;
            Phase = RepairPhase.Running;
            Raise();

            var result = await _cli.RunStreamAsync(HealthArgs.Repair(BenchPath), env, CliTimeouts.Apply, OnEvent, cts.Token).ConfigureAwait(true);
            lock (_gate) _run = null;
            if (_disposed) return;
            Finish(result);
        }
        finally
        {
            password?.Dispose();
        }
    }

    private void Finish(CliStreamResult result)
    {
        Ran = true;
        if (result.Done is { Log: { Length: > 0 } log }) Log = log;
        if (result.Done?.WrongSudoPassword == true)
        {
            PasswordWasWrong = true;
            Message = "Linux did not accept that password. Nothing was changed.";
            lock (_gate) _steps = [.. _steps.Select(s => s with { Status = InstallStepStatus.Unknown, Message = "" })];
            Ran = false;
            Phase = RepairPhase.Review;
        }
        else if (result.Done is null && !result.Ok)
        {
            Message = result.Cancelled ? "The repair was stopped." : result.Problem ?? $"The repair failed (exit {result.Exit}).";
            Phase = RepairPhase.Failed;
        }
        else
        {
            ExitCode = result.Exit;
            Phase = RepairPhase.Finished;
        }
        Raise();
    }

    private void OnEvent(CliEvent e)
    {
        switch (e)
        {
            case CliEvent.Plan { Value: var plan }:
                try
                {
                    var fresh = RepairPlan.FromJson(plan);
                    lock (_gate)
                    {
                        // the real run's plan wins: the bench may have changed since the dry run
                        _steps = [.. fresh.Steps.Select(s => _steps.FirstOrDefault(old => old.Id == s.Id) is { } old ? old with { Label = s.Label, Sudo = s.Sudo } : s)];
                    }
                    if (fresh.Log is { Length: > 0 }) Log = fresh.Log;
                }
                catch (FormatException)
                {
                    return;
                }
                break;
            case CliEvent.Step { Value: var step }:
                lock (_gate)
                {
                    var i = _steps.FindIndex(s => s.Id == step.Id);
                    if (i < 0) return;
                    var message = step.Message is { Length: > 0 } m && step.Status != InstallStepStatus.Running ? m : _steps[i].Message;
                    _steps[i] = _steps[i] with { Status = step.Status, Message = message };
                }
                break;
            default:
                return;
        }
        Raise();
    }

    private void Raise()
    {
        if (_context is null || SynchronizationContext.Current == _context) Changed?.Invoke();
        else _context.Post(_ => { if (!_disposed) Changed?.Invoke(); }, null);
    }

    public void Dispose()
    {
        _disposed = true;
        lock (_gate)
        {
            try { _run?.Cancel(); } catch (ObjectDisposedException) { }
        }
    }
}
