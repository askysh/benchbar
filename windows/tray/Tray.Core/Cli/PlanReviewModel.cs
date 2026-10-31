namespace BenchBar.Tray.Core;

public enum PlanPhase { Loading, Review, PlanFailed, Running, Finished, Stale }

/// <summary>One step in the sheet while the apply runs: the plan's step, then its progress.</summary>
public sealed record PlanRunStep(string Id, string Name, InstallStepStatus Status, string? Message, bool Sudo);

/// <summary>The result view: what changed, warnings, what to do next. Built from the apply's done line.</summary>
public sealed record PlanResultModel(bool Ok, bool Cancelled, string Headline, string? Error, IReadOnlyList<CliChange> Changed,
    IReadOnlyList<string> Warnings, IReadOnlyList<CliNextAction> NextActions, IReadOnlyList<string> Missing, string? Log)
{
    public static PlanResultModel From(CliStreamResult result)
    {
        var done = result.Done;
        if (result.Cancelled)
            return new PlanResultModel(false, true, "Stopped", "The run was stopped. Run the plan again to finish it.", done?.Changed ?? [], done?.Warnings ?? [], [], [], done?.Log);
        if (result.Ok)
            return new PlanResultModel(true, false, done is { Changed.Count: 0 } ? "Nothing needed changing" : "Done", null, done?.Changed ?? [], done?.Warnings ?? [], done?.NextActions ?? [], [], done?.Log);
        var problem = result.Problem ?? $"The command failed (exit {result.Exit}).";
        return new PlanResultModel(false, false, "It did not finish", problem, done?.Changed ?? [], done?.Warnings ?? [], done?.NextActions ?? [], done?.Missing ?? [], done?.Log);
    }
}

/// <summary>
/// The state behind the plan review sheet: read a plan, show it, run the apply on confirm, show the result. The sheet only draws
/// this. States: Loading, then Review (or PlanFailed); Running once confirmed; Finished with a result; Stale when the CLI refused the
/// token (<see cref="RefreshPlanAsync"/> reads a new plan). Raises <see cref="Changed"/> on the UI thread captured at construction.
/// </summary>
public sealed class PlanReviewModel : IDisposable
{
    private readonly ICliClient _cli;
    private readonly object _gate = new();
    private readonly SynchronizationContext? _context = SynchronizationContext.Current;
    private List<PlanRunStep> _steps = [];
    private CancellationTokenSource? _run;
    private bool _disposed;

    public PlanReviewModel(PlanReviewRequest request, ICliClient cli)
    {
        Request = request;
        _cli = cli;
    }

    public PlanReviewRequest Request { get; }

    /// <summary>Asks for the Linux password; null answers cancel. The sheet sets it to <c>LinuxPasswordDialog</c>.</summary>
    public Func<LinuxPasswordRequest, Task<Secret?>> AskLinuxPassword { get; set; } = _ => Task.FromResult<Secret?>(null);

    public event Action? Changed;

    public PlanPhase Phase { get; private set; } = PlanPhase.Loading;

    public PlanDocument? Plan { get; private set; }

    /// <summary>Why there is no plan, or the line to show above a plan that must be asked again (a wrong password).</summary>
    public string? Message { get; private set; }

    public bool PasswordWasWrong { get; private set; }

    public string ProgressLabel { get; private set; } = "";

    private long? _runStarted;

    /// <summary>How long the apply has been running (zero before it starts). A long run shows this instead of a timeout.</summary>
    public TimeSpan Elapsed => _runStarted is { } t ? System.Diagnostics.Stopwatch.GetElapsedTime(t) : TimeSpan.Zero;

    public PlanResultModel? Result { get; private set; }

    public PlanOutcome Outcome { get; private set; } = PlanOutcome.None;

    public IReadOnlyList<PlanRunStep> Steps
    {
        get
        {
            lock (_gate) return [.. _steps];
        }
    }

    /// <summary>A running apply cannot be dismissed: the sheet ignores Escape and the close button until it ends.</summary>
    public bool IsDismissible => Phase != PlanPhase.Running;

    public bool CanStop => Phase == PlanPhase.Running && Request.CanStop;

    /// <summary>The plan can be applied: it has no errors, it changes something, and it has a token to apply it with.</summary>
    public bool CanConfirm => Phase == PlanPhase.Review && Plan is { CanApply: true, HasChanges: true } && (!Request.RequiresToken || Plan.Token is { Length: > 0 });

    public bool AsksPassword => Request.UsesSudoEnv && Plan is { SudoSteps: > 0 };

    // --- plan ---

    public async Task LoadAsync(CancellationToken ct = default)
    {
        Phase = PlanPhase.Loading;
        Plan = null;
        Message = null;
        Result = null;
        Raise();
        var env = BuildEnv(null);
        var result = await _cli.RunJsonAsync(Request.PlanArgs, env, Request.PlanTimeout, PlanDocument.FromJson, ct).ConfigureAwait(true);
        if (_disposed) return;
        if (result.Value is { } plan)
        {
            Plan = plan;
            Phase = PlanPhase.Review;
            Message = plan.Errors.Count > 0 ? string.Join(' ', plan.Errors) : null;
        }
        else
        {
            Phase = PlanPhase.PlanFailed;
            Message = result.Error ?? "The plan could not be made.";
        }
        Raise();
    }

    /// <summary>Reads a new plan after a stale token or a failure. The same call as <see cref="LoadAsync"/>.</summary>
    public Task RefreshPlanAsync(CancellationToken ct = default) => LoadAsync(ct);

    // --- apply ---

    public async Task ConfirmAsync()
    {
        if (!CanConfirm || Plan is not { } plan) return;
        Secret? password = null;
        try
        {
            if (AsksPassword)
            {
                password = await AskLinuxPassword(new LinuxPasswordRequest(plan.SudoSteps, PasswordWasWrong)).ConfigureAwait(true);
                if (password is null || password.IsEmpty) return; // cancelled: the plan stays up
            }
            var env = BuildEnv(password);
            using var cts = new CancellationTokenSource();
            lock (_gate)
            {
                _run = cts;
                _steps = [.. plan.Steps.Where(s => s.WillRun).Select(s => new PlanRunStep(s.Id, s.Name, InstallStepStatus.Unknown, null, s.Sudo))];
            }
            PasswordWasWrong = false;
            Message = null;
            ProgressLabel = "";
            _runStarted = System.Diagnostics.Stopwatch.GetTimestamp();
            Phase = PlanPhase.Running;
            Raise();

            var apply = await _cli.RunStreamAsync(Request.ApplyArgs(plan), env, Request.ApplyTimeout, OnEvent, cts.Token).ConfigureAwait(true);
            lock (_gate) _run = null;
            if (_disposed) return;
            Finish(apply);
        }
        finally
        {
            password?.Dispose();
        }
    }

    private void Finish(CliStreamResult apply)
    {
        if (apply.Done?.WrongSudoPassword == true)
        {
            PasswordWasWrong = true;
            Message = "Linux did not accept that password. Nothing was changed.";
            Phase = PlanPhase.Review;
        }
        else if (!apply.Ok && !apply.Cancelled && PlanStale.Looks(apply.Problem))
        {
            Message = apply.Problem;
            Phase = PlanPhase.Stale;
        }
        else
        {
            Result = PlanResultModel.From(apply);
            Outcome = new PlanOutcome(apply.Ok, apply.Cancelled, apply.Done);
            Phase = PlanPhase.Finished;
        }
        Raise();
    }

    public void Stop()
    {
        if (!CanStop) return;
        CancellationTokenSource? run;
        lock (_gate) run = _run;
        try { run?.Cancel(); } catch (ObjectDisposedException) { }
    }

    private SecretEnvironment BuildEnv(Secret? password)
    {
        var env = new SecretEnvironment();
        Request.ConfigureEnv?.Invoke(env);
        if (password is not null) CliSudo.Apply(env, password);
        return env;
    }

    private void OnEvent(CliEvent e)
    {
        switch (e)
        {
            case CliEvent.Step { Value: var step }:
                lock (_gate)
                {
                    var i = _steps.FindIndex(s => string.Equals(s.Id, step.Id, StringComparison.OrdinalIgnoreCase));
                    if (i < 0) i = _steps.FindIndex(s => string.Equals(s.Name, step.Name, StringComparison.OrdinalIgnoreCase));
                    if (i >= 0) _steps[i] = _steps[i] with { Status = step.Status, Message = step.Message ?? _steps[i].Message };
                    else _steps.Add(new PlanRunStep(step.Id, step.Name, step.Status, step.Message, false));
                }
                break;
            case CliEvent.Progress p:
                ProgressLabel = p.Label;
                break;
            case CliEvent.Text t:
                ProgressLabel = t.Line;
                break;
            default:
                return;
        }
        Raise();
    }

    // --- helpers ---

    private void Raise() => Post(() => Changed?.Invoke());

    private void Post(Action action)
    {
        if (_context is null || SynchronizationContext.Current == _context) action();
        else _context.Post(_ => { if (!_disposed) action(); }, null);
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

/// <summary>The environment of a command that runs <c>sudo</c> inside WSL: <c>BENCHBAR_SUDO=env</c> and the password from a prompt.</summary>
public static class CliSudo
{
    /// <summary>Adds the sudo mode, the password and non interactive mode to <paramref name="env"/> (or a new one) and returns it.</summary>
    public static SecretEnvironment Apply(SecretEnvironment? env, Secret password)
    {
        env ??= new SecretEnvironment();
        return env.Set(SetupEnv.Sudo, "env").Set(SetupEnv.NonInteractive, "1").Set(SetupEnv.SudoPassword, password);
    }
}
