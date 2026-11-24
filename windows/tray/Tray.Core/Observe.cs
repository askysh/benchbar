namespace BenchBar.Tray.Core;

/// <summary>
/// Fire and forget without losing the exception. <c>_ = SomethingAsync()</c> drops a failure until the garbage collector finalizes the task,
/// long after the page that started it is stuck; <see cref="Forget"/> hands it to <see cref="OnFault"/> (the app writes it to the error log) at once.
/// </summary>
public static class Observe
{
    /// <summary>Where a failure goes. The app sets it to its error log; nothing happens when unset (the failure is still observed).</summary>
    public static Action<Exception>? OnFault { get; set; }

    /// <summary>A fault that leaves the process in an unknown state: the app lets it end the process (the run marker says so on the next start) instead of carrying on.</summary>
    public static bool IsFatal(Exception ex) =>
        ex is OutOfMemoryException or AccessViolationException or AppDomainUnloadedException or BadImageFormatException or InvalidProgramException
        || ex.InnerException is { } inner && IsFatal(inner);

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
    public static string Pill => UiText.Get("CommonBetaPill");
    public static string WindowTitle => UiText.Get("CommonBetaWindowTitle");
    public const string TooltipSuffix = " (Beta)";
    public static string AboutText => UiText.Get("CommonBetaAbout");
    public static string Banner => UiText.Get("CommonBetaBanner");
    public static string WizardLine => UiText.Get("CommonBetaWizardLine");
    public static string ReportThisProblem => UiText.Get("CommonReportThisProblem");
    public static string ReportABug => UiText.Get("MenuReportBug");
    public const string HowToFixUrl = "https://askysh.github.io/benchbar/windows/#first-run";
}
