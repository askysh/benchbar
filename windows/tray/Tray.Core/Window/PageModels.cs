namespace BenchBar.Tray.Core;

/// <summary>The tabs of a bench page (macos BenchTab).</summary>
public enum BenchTab { Overview, Sites, Apps, Health }

public static class BenchTabs
{
    public static IReadOnlyList<BenchTab> All { get; } = [BenchTab.Overview, BenchTab.Sites, BenchTab.Apps, BenchTab.Health];

    public static string Label(BenchTab tab) => tab switch
    {
        BenchTab.Sites => "Sites",
        BenchTab.Apps => "Apps",
        BenchTab.Health => "Health",
        _ => "Overview",
    };
}

/// <summary>The rows below the benches in the sidebar. They open a pane that is not about one bench.</summary>
public enum SidebarTool { None, FindBenches, TeamProfiles }

public static class SidebarTools
{
    public static IReadOnlyList<SidebarTool> All { get; } = [SidebarTool.FindBenches, SidebarTool.TeamProfiles];

    public static string Title(SidebarTool tool) => tool switch
    {
        SidebarTool.FindBenches => "Find Benches",
        SidebarTool.TeamProfiles => "Team Profiles",
        _ => "",
    };
}

/// <summary>
/// Where a bench page should go after the sidebar selection changed: a site row opens the Sites tab with that site selected, a bench
/// row opens the Overview. A poll that only refreshes the same selection keeps the tab the person is on.
/// </summary>
public static class BenchNavigation
{
    public static BenchTab TabFor(SidebarItem item) => item.Kind == SidebarKind.Site ? BenchTab.Sites : BenchTab.Overview;
}
