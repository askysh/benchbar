namespace BenchBar.Tray.Core;

/// <summary>The editors Open in Editor can start. All three take <c>--remote wsl+DISTRO PATH</c>.</summary>
public static class EditorKind
{
    public const string DefaultId = "code";

    public static IReadOnlyList<string> Ids { get; } = ["code", "cursor", "insiders"];

    public static string Normalize(string? id) =>
        id?.Trim().ToLowerInvariant() is { } v && Ids.Contains(v) ? v : DefaultId;

    public static string DisplayName(string id) => Normalize(id) switch
    {
        "cursor" => UiText.Get("CommonEditorCursor"),
        "insiders" => UiText.Get("CommonEditorInsiders"),
        _ => UiText.Get("FlyoutVsCode"),
    };

    /// <summary>The launcher script that sits in the editor's <c>bin</c> folder.</summary>
    public static string CommandFile(string id) => Normalize(id) switch
    {
        "cursor" => "cursor.cmd",
        "insiders" => "code-insiders.cmd",
        _ => "code.cmd",
    };

    /// <summary>The per user install folder of the editor's <c>bin</c>, under <c>%LOCALAPPDATA%</c>.</summary>
    public static string UserBinFolder(string id, string localAppData) => Normalize(id) switch
    {
        "cursor" => Path.Combine(localAppData, "Programs", "cursor", "resources", "app", "bin"),
        "insiders" => Path.Combine(localAppData, "Programs", "Microsoft VS Code Insiders", "bin"),
        _ => Path.Combine(localAppData, "Programs", "Microsoft VS Code", "bin"),
    };
}

/// <summary>What the tray does at launch about the first run wizard.</summary>
public enum LaunchAction { Nothing, OpenWizard }

/// <summary>The tray's own start arguments, besides <c>--resume-setup</c> (<c>StartupShortcut.ResumeArgument</c>) and <c>--logon-log</c>.</summary>
public static class LaunchArguments
{
    /// <summary>The installer started the tray right after a first install: the wizard may open once even after an old dismissal.</summary>
    public const string Installed = "--installed";

    /// <summary>The installer or an update started the tray again after it replaced the files: never a reason to open the wizard.</summary>
    public const string Restarted = "--restarted";

    public static bool Has(IEnumerable<string> args, string name) => args.Contains(name, StringComparer.OrdinalIgnoreCase);
}

/// <summary>
/// How this start of the tray came about. <see cref="FirstRun"/>: config.json had no <c>tray</c> object yet (no tray ran and saved before).
/// <see cref="Dismissed"/>: the person closed the wizard before (<c>tray.wizard_dismissed</c>). <see cref="ResumeFlag"/>: started with
/// <c>--resume-setup</c> after the restart a WSL install needed. <see cref="Restarted"/>: <c>--restarted</c>, or a newer version than the
/// config recorded (an update). <see cref="FromInstaller"/>: <c>--installed</c>, the installer's start after a first install.
/// </summary>
public sealed record LaunchStart(bool FirstRun, bool Dismissed, bool ResumeFlag = false, bool Restarted = false, bool FromInstaller = false)
{
    public static LaunchStart From(IReadOnlyList<string> args, bool firstRun, bool dismissed, bool updated) => new(
        firstRun,
        dismissed,
        ResumeFlag: false, // the resume start opens the wizard on its own path (it consumes the flag); see App.OnStartup
        Restarted: updated || LaunchArguments.Has(args, LaunchArguments.Restarted),
        FromInstaller: LaunchArguments.Has(args, LaunchArguments.Installed));
}

public static class LaunchPlanner
{
    /// <summary>
    /// Whether the wizard opens by itself at this start. Only when that helps: the resume start after the restart for WSL (always), or,
    /// while setup is unfinished, the installer's start after a first install (even after an old dismissal, since uninstall keeps
    /// config.json) and the first start of a tray that never ran here, unless the person closed the wizard already. An ordinary logon
    /// start and a start after an update never open it; the flyout, the window and the tray menu offer Set Up BenchBar instead.
    /// </summary>
    public static LaunchAction Decide(LaunchStart start, bool setupUnfinished)
    {
        if (start.ResumeFlag) return LaunchAction.OpenWizard;
        if (!setupUnfinished) return LaunchAction.Nothing;
        if (start.FromInstaller) return LaunchAction.OpenWizard;
        if (start.Restarted || start.Dismissed) return LaunchAction.Nothing;
        return start.FirstRun ? LaunchAction.OpenWizard : LaunchAction.Nothing;
    }

    /// <summary><see cref="Decide"/> with <see cref="SetupUnfinished"/> worked out from the first poll and the setup check.</summary>
    public static LaunchAction AtLaunch(TraySnapshot snapshot, SetupReport? report, LaunchStart start) =>
        Decide(start, SetupUnfinished(snapshot, report));

    /// <summary>
    /// A PC that has no bench and is not set up: no bench in the first poll, the distro is not merely stopped (a stopped distro exists, so
    /// this is not a new user), and the shim's read only check has a blocking step that is not done (advice rows do not count). A poll that
    /// failed on a PC where benchbar is installed in the distro is a returning user having a bad moment, not a new one. A distro that WSL
    /// does not list at all (<see cref="TraySnapshot.DistroMissing"/>) is not a stopped distro: it falls through to the check.
    /// </summary>
    public static bool SetupUnfinished(TraySnapshot snapshot, SetupReport? report)
    {
        if (snapshot.Benches.Count > 0 || StoppedButThere(snapshot)) return false;
        if (report is null || !report.HasBlockingFailure) return false;
        return !(snapshot.Problem is not null && report.Step(SetupIds.Cli) is { IsOk: true });
    }

    /// <summary>Whether the setup check is worth running for this first snapshot (no bench, a distro that is not just stopped).</summary>
    public static bool NeedsSetupCheck(TraySnapshot snapshot) =>
        snapshot.Benches.Count == 0 && !StoppedButThere(snapshot);

    /// <summary>A distro that exists and is not running: a returning user, not a new one. A missing distro is not that.</summary>
    private static bool StoppedButThere(TraySnapshot snapshot) => snapshot.DistroStopped && !snapshot.DistroMissing;
}

/// <summary>What closing the wizard means for <c>tray.wizard_dismissed</c>.</summary>
public enum WizardCloseRecord { Dismissed, Finished }

public static class WizardDismissal
{
    /// <summary>
    /// Done (or the Done page left by the window's X) is finished; any other close (Cancel on Welcome, the window's X or Alt+F4 on any page,
    /// Quit) is "not now", so the wizard does not open by itself again. <paramref name="reason"/> is null for a close that did not come from
    /// the wizard's own buttons.
    /// </summary>
    public static WizardCloseRecord OnClose(WizardClose? reason, WizardPage page) =>
        reason == WizardClose.Finished || page == WizardPage.Done ? WizardCloseRecord.Finished : WizardCloseRecord.Dismissed;
}

public enum SidebarKind { Bench, Site }

/// <summary>One row of the main window's sidebar: a bench (state dot) or one of its sites (child row).</summary>
public sealed record SidebarItem(SidebarKind Kind, string Key, string Title, string Detail, BenchState State, string BenchPath, string? Url, bool IsDefault);

/// <summary>The sidebar, built from a poll. A pure function of the snapshot, so it is tested without a window.</summary>
public static class SidebarModel
{
    public static IReadOnlyList<SidebarItem> Build(TraySnapshot snapshot)
    {
        var items = new List<SidebarItem>();
        foreach (var bench in snapshot.Benches)
        {
            items.Add(new SidebarItem(SidebarKind.Bench, bench.Path, bench.Name, BenchPresentation.StateWord(bench), bench.State, bench.Path, bench.WebUrl, false));
            foreach (var site in bench.Sites)
            {
                items.Add(new SidebarItem(SidebarKind.Site, bench.Path + "|" + site.Name, site.Name, site.IsDefault ? UiText.Get("CommonDefaultSite") : "", bench.State, bench.Path, SiteUrl(bench, site), site.IsDefault));
            }
        }
        return items;
    }

    /// <summary>The bench's own web URL for its default site; no URL is invented for the others (the port is the bench's).</summary>
    private static string? SiteUrl(BenchStatus bench, SiteInfo site) =>
        site.IsDefault || bench.Sites.Count == 1 ? bench.WebUrl : null;
}

/// <summary>Which buttons the Overview of one bench offers. The same rules as the flyout row.</summary>
public sealed record OverviewButtons(string StartStopLabel, bool CanStartStop, bool CanRestart, bool CanOpenSite)
{
    public static OverviewButtons For(BenchStatus bench, bool busy)
    {
        var up = bench.State is BenchState.Running or BenchState.Starting;
        var known = bench.State != BenchState.Unknown;
        return new OverviewButtons(up ? UiText.Get("CommonStop") : UiText.Get("CommonStart"), known && !busy, known && !busy && up, !string.IsNullOrWhiteSpace(bench.WebUrl));
    }
}
