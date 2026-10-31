using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;

namespace BenchBar.Tray.Tests;

/// <summary>The review fixes in the views: a panel never outlives its bench, runs are counted, a hostile site name stays out of a terminal.</summary>
public class BenchPageSafetyViewTests
{
    private const string P = PageKit.BenchPath;
    private const string Other = "/home/akash/other-bench";

    private static (SitesView View, PageKit Kit) Sites()
    {
        var kit = new PageKit();
        var view = new SitesView(kit.Services);
        view.Bind(new BenchContext(PageKit.Bench(), null));
        return (view, kit);
    }

    private static (AppsView View, PageKit Kit) Apps()
    {
        var kit = new PageKit();
        kit.Runner.On("app", "list").Print(PageKit.Fixture("apps-list.json"));
        var view = new AppsView(kit.Services);
        view.Bind(new BenchContext(PageKit.Bench(), null));
        PageKit.Wait(view.Pending);
        return (view, kit);
    }

    private static void ScriptDrop(PageKit kit)
    {
        kit.Runner.On(a => a.Length > 1 && a[0] == "site" && a[1] == "drop" && a.Contains("--dry-run")).Print(PageKit.Fixture("sites-drop-plan.json"));
    }

    // --- a panel never outlives its bench ---

    [Fact]
    public void ADropPanelIsClosedWhenAnotherBenchIsShownAndNothingDropsThere() => Sta.Run(() =>
    {
        var (view, kit) = Sites();
        ScriptDrop(kit);
        PageKit.ClickMenu(view, "More actions for two.localhost", "Drop Site...");
        PageKit.Wait(view.Pending);
        Assert.NotNull(view.DropPlan);

        view.Bind(new BenchContext(PageKit.Bench(path: Other, sites: [("two.localhost", false), ("linuxdev.localhost", true)]), null));
        Assert.Null(view.OpenPanel);
        Assert.Null(view.DropPlan);
        Assert.False(view.IsBusy);
        Assert.Empty(kit.Typed);
        Assert.DoesNotContain(kit.Runner.Runs, r => r.Args.Contains("--confirm-site") && !r.Args.Contains("--dry-run"));
    });

    [Fact]
    public void TheDropPlanAndTheDropCallUseTheBenchThePanelWasOpenedFor() => Sta.Run(() =>
    {
        var (view, kit) = Sites();
        ScriptDrop(kit);
        kit.Runner.On(a => a.Length > 1 && a[0] == "site" && a[1] == "drop" && !a.Contains("--dry-run")).Print(PageKit.Fixture("sites-drop-result.json"));
        PageKit.ClickMenu(view, "More actions for two.localhost", "Drop Site...");
        PageKit.Wait(view.Pending);
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Drop two.localhost"));
        PageKit.Wait(view.Pending);
        Assert.All(kit.Runner.Runs, r => Assert.Equal(P, r.Args[^1]));
    });

    [Fact]
    public void ADropThatRunsWhileAnotherBenchIsShownDoesNotPaintOnIt() => Sta.Run(() =>
    {
        var (view, kit) = Sites();
        ScriptDrop(kit);
        var held = kit.Runner.On(a => a.Length > 1 && a[0] == "site" && a[1] == "drop" && !a.Contains("--dry-run")).Hold();
        PageKit.ClickMenu(view, "More actions for two.localhost", "Drop Site...");
        PageKit.Wait(view.Pending);
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Drop two.localhost"));
        Assert.True(kit.Services.HasRunInFlight);

        view.Bind(new BenchContext(PageKit.Bench(path: Other), null)); // the person moved on
        Assert.Null(view.OpenPanel);
        held.Release(PageKit.Fixture("sites-drop-result.json"));
        PageKit.Wait(view.Pending);
        PageKit.Drain();
        Assert.Null(view.OpenPanel); // the result is not drawn on the other bench
        Assert.False(kit.Services.HasRunInFlight);
        Assert.Equal(1, kit.Refreshes);
    });

    [Fact]
    public void TheAddSiteFormIsClosedWhenAnotherBenchIsShown() => Sta.Run(() =>
    {
        var (view, _) = Sites();
        PageKit.Click(PageKit.ButtonNamed(view, "Add Site..."));
        Assert.NotNull(view.AddForm);
        view.Bind(new BenchContext(PageKit.Bench(path: Other), null));
        Assert.Null(view.AddForm);
        Assert.Null(view.OpenPanel);
    });

    [Fact]
    public void TheUpdatePanelOfAnAppIsClosedWhenAnotherBenchIsShown() => Sta.Run(() =>
    {
        var (view, kit) = Apps();
        kit.Runner.On(a => a.Contains("--dry-run")).Print(PageKit.Fixture("apps-update-plan.json"));
        PageKit.Click(PageKit.ButtonNamed(view, "Update erpnext"));
        PageKit.Wait(view.Pending);
        Assert.NotNull(view.UpdatePlan);
        view.Bind(new BenchContext(PageKit.Bench(path: Other), null));
        Assert.Null(view.OpenPanel);
        Assert.Null(view.UpdatePlan);
        Assert.DoesNotContain(kit.Runner.Runs, r => r.Args.Contains("--yes"));
    });

    [Fact]
    public void TheUpdateCallsUseTheBenchThePanelWasOpenedFor() => Sta.Run(() =>
    {
        var (view, kit) = Apps();
        kit.Runner.On(a => a.Contains("--dry-run")).Print(PageKit.Fixture("apps-update-plan.json"));
        kit.Runner.On(a => a.Contains("--yes")).Print(PageKit.Fixture("apps-update.jsonl"));
        PageKit.Click(PageKit.ButtonNamed(view, "Update erpnext"));
        PageKit.Wait(view.Pending);
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Run the update of erpnext"));
        PageKit.Wait(view.Pending);
        Assert.All(kit.Runner.Runs.Where(r => r.Args[0] == "app" && r.Args[1] == "update"), r => Assert.Equal(P, r.Args[^1]));
    });

    [Fact]
    public void TheRepairSheetIsMadeForTheBenchThatIsShown() => Sta.Run(() =>
    {
        var (services, _) = PageKit.ScriptedServices();
        var view = new HealthView(services);
        view.Bind(new BenchContext(PageKit.Bench(path: Other), null));
        var sheet = view.CreateRepairSheet(load: false);
        Assert.Equal(Other, sheet.Model.BenchPath);
    });

    // --- a closing window can tell a run is going on ---

    [Fact]
    public void ARunningDropCountsAsInFlightAndItsResultGoesToANotificationWhenTheWindowIsGone() => Sta.Run(() =>
    {
        var (view, kit) = Sites();
        var said = new List<string>();
        kit.Services.Notify = said.Add;
        ScriptDrop(kit);
        var held = kit.Runner.On(a => a.Length > 1 && a[0] == "site" && a[1] == "drop" && !a.Contains("--dry-run")).Hold();
        Assert.False(kit.Services.HasRunInFlight);
        PageKit.ClickMenu(view, "More actions for two.localhost", "Drop Site...");
        PageKit.Wait(view.Pending);
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Drop two.localhost"));
        Assert.True(kit.Services.HasRunInFlight);
        held.Release(PageKit.Fixture("sites-drop-result.json"));
        PageKit.Wait(view.Pending);
        PageKit.Drain();
        Assert.False(kit.Services.HasRunInFlight);
        Assert.Contains(said, t => t.StartsWith("two.localhost was dropped.", StringComparison.Ordinal)); // the view is not loaded: no window shows it
    });

    // --- the Console and the Database take a plain site name only ---

    [Fact]
    public void AHostileSiteNameOpensNoTerminalFromTheOverview() => Sta.Run(() =>
    {
        var (services, _) = PageKit.ScriptedServices();
        var launches = new List<TerminalLaunch>();
        services.Distro = () => "Ubuntu-24.04";
        services.OpenTerminal = l => { launches.Add(l); return null; };
        var view = new OverviewView(new OverviewActions());
        view.Attach(services, (_, _) => { });
        view.Bind(PageKit.BenchWith(BenchState.Running), null);

        view.OpenShell("a;b", WslCommands.Console);
        Assert.Empty(launches);
        Assert.Contains("not a name the terminal can take", view.MessageText);

        view.OpenShell("one.localhost", WslCommands.Console);
        var launch = Assert.Single(launches);
        Assert.Equal(["bench", "--site", "one.localhost", "console"], launch.Command);
    });

    [Fact]
    public void AHostileSiteNameOpensNoTerminalFromTheSitesTab() => Sta.Run(() =>
    {
        var (view, kit) = Sites();
        view.OpenShell(SiteShellKind.Console, "a;b");
        Assert.Empty(kit.Terminals);
    });
}
