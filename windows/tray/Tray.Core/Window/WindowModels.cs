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
        "cursor" => "Cursor",
        "insiders" => "VS Code Insiders",
        _ => "VS Code",
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

public static class LaunchPlanner
{
    /// <summary>
    /// The wizard opens by itself only for a PC that has no bench and is not set up: no bench in the first poll, the distro
    /// is not merely stopped (a stopped distro exists, so this is not a new user), the person did not dismiss the wizard, and the
    /// shim's read only check says the PC is not ready.
    /// </summary>
    public static LaunchAction AtLaunch(TraySnapshot snapshot, SetupReport? report, bool dismissed, bool resumeFlag)
    {
        if (resumeFlag) return LaunchAction.OpenWizard;
        if (dismissed || snapshot.Benches.Count > 0 || snapshot.DistroStopped) return LaunchAction.Nothing;
        if (report is null) return LaunchAction.Nothing;
        return report.Ready ? LaunchAction.Nothing : LaunchAction.OpenWizard;
    }

    /// <summary>Whether the setup check is worth running for this first snapshot (no bench, a distro that is not just stopped).</summary>
    public static bool NeedsSetupCheck(TraySnapshot snapshot, bool dismissed) =>
        !dismissed && snapshot.Benches.Count == 0 && !snapshot.DistroStopped;
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
                items.Add(new SidebarItem(SidebarKind.Site, bench.Path + "|" + site.Name, site.Name, site.IsDefault ? "default site" : "", bench.State, bench.Path, SiteUrl(bench, site), site.IsDefault));
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
        return new OverviewButtons(up ? "Stop" : "Start", known && !busy, known && !busy && up, !string.IsNullOrWhiteSpace(bench.WebUrl));
    }
}
