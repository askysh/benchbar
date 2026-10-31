using System.Windows;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// What every page of the main window gets: the CLI client and the shared sheets. Every member has a harmless default, so a
/// page builds alone in a test. A page keeps the instance it was given and never builds its own client or dialogs.
/// </summary>
internal sealed class PageServices
{
    /// <summary>Calls <c>benchbar.exe</c> and reads its JSON (<see cref="ICliClient.RunJsonAsync{T}"/>, <see cref="ICliClient.RunStreamAsync"/>).</summary>
    public ICliClient Cli { get; set; } = new CliClient(new ScriptedStreamRunner(), () => "benchbar.exe");

    public Func<ResolvedTheme> Theme { get; set; } = () => new ResolvedTheme(true, true);

    /// <summary>The window sheets and dialogs belong to (the main window).</summary>
    public Func<Window?> Owner { get; set; } = () => null;

    /// <summary>
    /// Shows the plan review sheet for <paramref name="request"/> and returns when it closes. It reads the plan, asks for the Linux
    /// password when the plan needs it, runs the apply and shows the result. After an apply that ran, the app polls again.
    /// </summary>
    public Func<PlanReviewRequest, Task<PlanOutcome>> ReviewPlan { get; set; } = _ => Task.FromResult(PlanOutcome.None);

    /// <summary>Shows the typed confirmation dialog; the typed text when it matched and was confirmed, else null.</summary>
    public Func<TypedConfirmRequest, string?> ConfirmTyped { get; set; } = _ => null;

    /// <summary>Asks for the Linux password (for a command that runs sudo without a plan sheet: build its environment with <see cref="CliSudo.Apply"/>).</summary>
    public Func<LinuxPasswordRequest, Task<Secret?>> AskLinuxPassword { get; set; } = _ => Task.FromResult<Secret?>(null);

    public Action<string> CopyText { get; set; } = _ => { };

    public Action<string> OpenUrl { get; set; } = _ => { };

    /// <summary>Polls the benches now (after a change, so the sidebar and Overview catch up).</summary>
    public Action RefreshNow { get; set; } = () => { };

    /// <summary>Report a Bug with a failure as its context: the entry point and the problem text.</summary>
    public Action<string, string?> ReportBug { get; set; } = (_, _) => { };

    /// <summary>Says something outside the window (a Windows notification): the result of a run whose window was closed meanwhile.</summary>
    public Action<string> Notify { get; set; } = _ => { };

    private int _runs;

    /// <summary>A run that changes things is going on in a page (a drop, an update, an add). The window asks before it closes.</summary>
    public bool HasRunInFlight => Volatile.Read(ref _runs) > 0;

    public void RunStarted() => Interlocked.Increment(ref _runs);

    public void RunEnded()
    {
        if (Interlocked.Decrement(ref _runs) < 0) Interlocked.Exchange(ref _runs, 0);
    }

    /// <summary>The WSL distro the tray watches, null when it is not known (Console, Database and tail -f need it).</summary>
    public Func<string?> Distro { get; set; } = () => null;

    /// <summary>Opens a command in Windows Terminal inside the distro (<see cref="TerminalLauncher"/>); the reason it could not, else null.</summary>
    public Func<TerminalLaunch, string?> OpenTerminal { get; set; } = _ => null;

    /// <summary>The services of the running app: dialogs over <paramref name="owner"/>, the real client.</summary>
    public static PageServices ForApp(ICliClient cli, Func<ResolvedTheme> theme, Func<Window?> owner, Action<string> copy, Action<string> openUrl, Action refresh)
    {
        PageServices? services = null;
        Task<Secret?> Ask(LinuxPasswordRequest request) => Task.FromResult(LinuxPasswordDialog.Ask(request, theme(), owner()));
        services = new PageServices
        {
            Cli = cli,
            Theme = theme,
            Owner = owner,
            CopyText = copy,
            OpenUrl = openUrl,
            RefreshNow = refresh,
            OpenTerminal = TerminalLauncher.Open,
            AskLinuxPassword = Ask,
            ConfirmTyped = request => TypedConfirmDialog.Ask(request, theme(), owner()),
            ReviewPlan = request => PlanReviewSheet.ReviewAsync(request, services!),
        };
        return services;
    }
}
