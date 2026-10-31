using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>The bench page, the sidebar tools, the plan review sheet, the typed confirmation and the next action row.</summary>
public class ScaffoldViewTests
{

    private static BenchStatus Bench() => new("frappe-bench", "/home/a/frappe-bench", BenchState.Running, null, "http://one.localhost:8000", "one.localhost")
    {
        Sites = [new SiteInfo("one.localhost", true), new SiteInfo("two.localhost", false)],
    };

    private static (PlanReviewModel Model, ScriptedStreamRunner Runner) PlanModel(Func<PlanReviewRequest, PlanReviewRequest>? tune = null, string plan = "site-add-plan.json")
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var runner = new ScriptedStreamRunner();
        runner.On(a => a.Contains("--dry-run")).Print(Fixture(plan));
        runner.On(a => a.Contains("--apply")).Print(Fixture("site-add-apply.jsonl"));
        var request = PlanReviewRequest.Tokened("Add qa1.localhost", ["site", "add", "qa1.localhost"]) with { ConfirmLabel = "Add Site" };
        if (tune is not null) request = tune(request);
        return (new PlanReviewModel(request, new CliClient(runner, () => "benchbar.exe")), runner);
    }

    // --- bench page ---

    [Fact]
    public void TheBenchPageHasFourTabsAndBuildsThemWhenShown() => Sta.Run(() =>
    {
        var page = new BenchPage(new PageServices(), new OverviewView(new OverviewActions()));
        Assert.Equal(["Overview", "Sites", "Apps", "Health"], page.TabLabels);
        Assert.Null(page.Sites);
        page.Bind(Bench(), null, navigate: true);
        Assert.Equal(BenchTab.Overview, page.Tab);
        page.Select(BenchTab.Apps);
        Assert.NotNull(page.Apps);
        Assert.Null(page.Health);
        Assert.Equal("frappe-bench", page.Apps!.Context!.Bench.Name);
        AssertEveryControlIsNamed(page);
    });

    [Fact]
    public void ASiteOpensTheSitesTabAndAPollKeepsTheTab() => Sta.Run(() =>
    {
        var page = new BenchPage(new PageServices(), new OverviewView(new OverviewActions()));
        page.Bind(Bench(), "two.localhost", navigate: true);
        Assert.Equal(BenchTab.Sites, page.Tab);
        Assert.Equal("two.localhost", page.Sites!.SelectedSite);

        page.Select(BenchTab.Health);
        page.Bind(Bench() with { State = BenchState.Stopped }, "two.localhost", navigate: false); // a poll
        Assert.Equal(BenchTab.Health, page.Tab);
        Assert.Equal(BenchState.Stopped, page.Health!.Context!.Bench.State);

        page.Bind(Bench(), null, navigate: true); // the bench row
        Assert.Equal(BenchTab.Overview, page.Tab);
    });

    [Fact]
    public void TheSidebarSiteRowOpensTheSitesTabWithThatSite() => Sta.Run(() =>
    {
        var window = new MainWindow(new MainActions(), Theme);
        window.SetSnapshot(new TraySnapshot([Bench()]), "1 of 1 up");
        Assert.Equal("overview", window.ContentKind);
        var site = window.Items.Single(i => i.Kind == SidebarKind.Site && i.Title == "two.localhost");
        window.Select(site);
        Assert.Equal(BenchTab.Sites, window.Page.Tab);
        Assert.Equal("two.localhost", window.Page.Sites!.SelectedSite);
        Assert.Equal("bench|sites", window.ContentKind);
        window.SetSnapshot(new TraySnapshot([Bench()]), "1 of 1 up"); // a poll keeps it
        Assert.Equal(BenchTab.Sites, window.Page.Tab);
        window.Select(window.Items.First(i => i.Kind == SidebarKind.Bench));
        Assert.Equal(BenchTab.Overview, window.Page.Tab);
        Assert.Equal("overview", window.ContentKind);
    });

    [Fact]
    public void TheOverviewHealthButtonOpensTheHealthTab() => Sta.Run(() =>
    {
        var window = new MainWindow(new MainActions(), Theme);
        window.ShowHealth(); // nothing selected yet: no effect
        window.SetSnapshot(new TraySnapshot([Bench()]), "1 of 1 up");
        window.ShowHealth();
        Assert.Equal(BenchTab.Health, window.Page.Tab);
        Assert.Equal("bench|health", window.ContentKind);
    });

    [Fact]
    public void FindBenchesAndTeamProfilesOpenTheirPanesBelowTheBenches() => Sta.Run(() =>
    {
        var window = new MainWindow(new MainActions(), Theme);
        window.SetSnapshot(new TraySnapshot([Bench()]), "1 of 1 up");
        window.ShowTool(SidebarTool.FindBenches);
        Assert.Equal("tool|FindBenches", window.ContentKind);
        Assert.Equal(SidebarTool.FindBenches, window.Tool);
        window.SetSnapshot(new TraySnapshot([Bench()]), "1 of 1 up"); // a poll keeps the pane
        Assert.Equal("tool|FindBenches", window.ContentKind);
        window.ShowTool(SidebarTool.TeamProfiles);
        Assert.Equal("tool|TeamProfiles", window.ContentKind);
        window.Select(window.Items.First());
        Assert.Equal(SidebarTool.None, window.Tool);
        Assert.Equal("overview", window.ContentKind);
        // with no bench the panes still open
        var empty = new MainWindow(new MainActions(), Theme);
        empty.SetSnapshot(new TraySnapshot([]), "none up");
        empty.ShowTool(SidebarTool.FindBenches);
        Assert.Equal("tool|FindBenches", empty.ContentKind);
        AssertEveryControlIsNamed(window);
    });

    // --- plan sheet ---

    [Fact]
    public void ThePlanSheetShowsStepsThenTheResultAndBlocksCloseWhileRunning() => Sta.Run(() =>
    {
        var (model, _) = PlanModel();
        var sheet = new PlanReviewSheet(model, Theme, null, _ => { }, load: false);
        Assert.Equal(["Cancel"], sheet.ButtonLabels);
        model.LoadAsync(CancellationToken.None).GetAwaiter().GetResult();
        Assert.Equal(["Add Site", "Cancel"], sheet.ButtonLabels);
        Assert.Contains("1. Create qa1.localhost", sheet.Lines);
        Assert.Contains("Changes: database, site_folder", sheet.Lines);
        AssertEveryControlIsNamed(sheet);

        model.ConfirmAsync().GetAwaiter().GetResult();
        Assert.Equal(["Close"], sheet.ButtonLabels);
        Assert.Contains("Done", sheet.Lines);
        Assert.Contains("site: qa1.localhost, created", sheet.Lines);
        Assert.Contains("benchbar site default qa1.localhost", sheet.Lines);
        Assert.Contains("Warning: Redis cache was slow to answer.", sheet.Lines);
        AssertEveryControlIsNamed(sheet);
    });

    [Fact]
    public void ARunningPlanSheetRefusesToClose() => Sta.Run(() =>
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var runner = new ScriptedStreamRunner();
        runner.On(a => a.Contains("--dry-run")).Print(Fixture("site-add-plan.json"));
        var held = runner.On(a => a.Contains("--apply")).Print(Fixture("site-add-apply.jsonl")).Hold();
        var model = new PlanReviewModel(PlanReviewRequest.Tokened("Add", ["site", "add", "x"]), new CliClient(runner, () => "benchbar.exe"));
        var sheet = new PlanReviewSheet(model, Theme, null, _ => { }, load: false);
        var closed = false;
        sheet.Closed += (_, _) => closed = true;
        model.LoadAsync(CancellationToken.None).GetAwaiter().GetResult();
        var run = model.ConfirmAsync();
        held.Started.Task.Wait();
        Assert.Equal(PlanPhase.Running, model.Phase);
        Assert.Empty(sheet.ButtonLabels); // no Stop: this run is not safe to kill
        sheet.Close();
        Assert.False(closed);
        held.Release();
        run.GetAwaiter().GetResult();
        sheet.Close();
        Assert.True(closed);
    });

    [Fact]
    public void AStaleTokenShowsRefreshPlanAndAFailedPlanToo() => Sta.Run(() =>
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var runner = new ScriptedStreamRunner();
        runner.On(a => a.Contains("--dry-run")).Print(Fixture("site-add-plan.json"));
        runner.On(a => a.Contains("--apply")).Print(Fixture("site-add-stale.jsonl")).Fail(1);
        var model = new PlanReviewModel(PlanReviewRequest.Tokened("Add", ["site", "add", "x"]), new CliClient(runner, () => "benchbar.exe"));
        var sheet = new PlanReviewSheet(model, Theme, null, _ => { }, load: false);
        model.LoadAsync(CancellationToken.None).GetAwaiter().GetResult();
        model.ConfirmAsync().GetAwaiter().GetResult();
        Assert.Equal(["Refresh Plan", "Close"], sheet.ButtonLabels);
        Assert.Contains("The plan is out of date", sheet.Lines);

        var failing = new PlanReviewModel(PlanReviewRequest.Tokened("Add", ["site", "add", "x"]), new CliClient(new ScriptedStreamRunner(), () => "benchbar.exe"));
        var failedSheet = new PlanReviewSheet(failing, Theme, null, _ => { }, load: false);
        failing.LoadAsync(CancellationToken.None).GetAwaiter().GetResult();
        Assert.Equal(["Refresh Plan", "Close"], failedSheet.ButtonLabels);
        AssertEveryControlIsNamed(failedSheet);
    });

    [Fact]
    public void ANextActionOfTheResultHasACopyButton() => Sta.Run(() =>
    {
        var (model, _) = PlanModel();
        var copied = new List<string>();
        var sheet = new PlanReviewSheet(model, Theme, null, copied.Add, load: false);
        model.LoadAsync(CancellationToken.None).GetAwaiter().GetResult();
        model.ConfirmAsync().GetAwaiter().GetResult();
        var copy = Walk(sheet).OfType<Button>().Single(b => b.Content as string == "Copy");
        copy.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Assert.Equal(["benchbar site default qa1.localhost"], copied);
    });

    // --- typed confirmation, next action row ---

    [Fact]
    public void TheTypedConfirmationStaysOffUntilTheNameIsExact() => Sta.Run(() =>
    {
        var dialog = new TypedConfirmDialog(new TypedConfirmRequest("Drop qa1.localhost", "This deletes its database and files.", "qa1.localhost"), Theme, null);
        Assert.False(dialog.Confirm.IsEnabled);
        Assert.False(dialog.Confirm.IsDefault);
        dialog.Box.Text = "qa1";
        Assert.False(dialog.Confirm.IsEnabled);
        dialog.Box.Text = "qa1.localhost";
        Assert.True(dialog.Confirm.IsEnabled);
        Assert.Equal("qa1.localhost", dialog.Typed);
        dialog.Box.Text = "QA1.localhost";
        Assert.False(dialog.Confirm.IsEnabled);
        AssertEveryControlIsNamed(dialog);
    });

    [Fact]
    public void TheNextActionRowIsALineAndAtMostOneButton() => Sta.Run(() =>
    {
        var clicks = 0;
        var guidance = BenchGuidance.Make(BenchState.Stopped, "manual");
        var row = NextActionRow.For(guidance, _ => () => clicks++)!;
        Assert.Equal("You stopped it.", row.Text);
        Assert.Equal("Start", row.ButtonLabel);
        row.Button!.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Assert.Equal(1, clicks);
        Assert.Null(NextActionRow.For(guidance, _ => () => { }, shown: GuidanceAction.Start)!.ButtonLabel);
        Assert.Null(NextActionRow.For(null, _ => () => { }));
        AssertEveryControlIsNamed(row);
    });
}
