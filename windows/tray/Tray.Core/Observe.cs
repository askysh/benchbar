namespace BenchBar.Tray.Core;

/// <summary>
/// Fire and forget without losing the exception. <c>_ = SomethingAsync()</c> drops a failure until the garbage collector finalizes the task,
/// long after the page that started it is stuck; <see cref="Forget"/> hands it to <see cref="OnFault"/> (the app writes it to the error log) at once.
/// </summary>
public static class Observe
{
    /// <summary>Where a failure goes. The app sets it to its error log; nothing happens when unset (the failure is still observed).</summary>
    public static Action<Exception>? OnFault { get; set; }

    public static void Forget(this Task task)
    {
        if (task.IsCompleted)
        {
            if (task.IsFaulted) Report(task.Exception!);
            return;
        }
        task.ContinueWith(t => Report(t.Exception!), CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
    }

    private static void Report(AggregateException ex)
    {
        try { OnFault?.Invoke(ex.GetBaseException()); }
        catch (Exception) { /* a broken log is not a second failure */ }
    }
}

/// <summary>The beta words, in one place so the sidebar, About, the banner, the wizard and the tests say the same thing.</summary>
public static class BetaText
{
    public const string Pill = "Beta";
    public const string WindowTitle = "BenchBar (Beta)";
    public const string TooltipSuffix = " (Beta)";
    public const string AboutText = "BenchBar for Windows is in beta. It works, and you may find rough edges. Report a Bug sends us a redacted report in about a minute.";
    public const string Banner = "BenchBar for Windows is in beta. If something breaks or confuses you, tell us.";
    public const string WizardLine = "This is a beta. If a step fails, Report This Problem sends us what we need.";
    public const string ReportThisProblem = "Report This Problem";
    public const string ReportABug = "Report a Bug";
    public const string HowToFixUrl = "https://askysh.github.io/benchbar/windows/#first-run";
}
