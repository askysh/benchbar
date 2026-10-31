using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;

namespace BenchBar.Tray.Tests;

public class AppsViewTests
{
    private const string P = PageKit.BenchPath;

    private static (AppsView View, PageKit Kit) Make(string list = "apps-list.json", BenchStatus? bench = null)
    {
        var kit = new PageKit();
        kit.Runner.On("app", "list").Print(PageKit.Fixture(list));
        var view = new AppsView(kit.Services);
        view.Bind(new BenchContext(bench ?? PageKit.Bench(), null));
        PageKit.Wait(view.Pending);
        return (view, kit);
    }

    private static BenchApp App(AppsView view, string name) => view.List!.Apps.Single(a => a.Name == name);

    // --- the list ---

    [Fact]
    public void ShowingTheTabReadsTheCachedListOnceAndAPollDoesNotReadItAgain() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        Assert.Equal([["app", "list", "--json", "--no-sites", "--bench-dir", P]], kit.Runner.Runs.Select(r => r.Args));
        Assert.Equal(["frappe", "erpnext", "acme_crm"], view.List!.Apps.Select(a => a.Name));
        view.Bind(new BenchContext(PageKit.Bench(), null));
        view.Bind(new BenchContext(PageKit.Bench(BenchState.Stopped), "one.localhost"));
        PageKit.Wait(view.Pending);
        Assert.Single(kit.Runner.Runs);

        view.Bind(new BenchContext(PageKit.Bench(path: "/home/akash/other-bench"), null));
        PageKit.Wait(view.Pending);
        Assert.Equal(2, kit.Runner.Runs.Count);
        Assert.Equal("/home/akash/other-bench", kit.Runner.Runs[1].Args[^1]);
    });

    [Fact]
    public void ARowShowsVersionTagsFocusAndSites() => Sta.Run(() =>
    {
        var (view, _) = Make();
        var texts = PageKit.Texts(view);
        Assert.Contains("15.115.0", texts);
        Assert.Contains("local changes", texts);
        Assert.Contains("expected develop", texts);
        Assert.Contains("focus", texts);
        Assert.Contains("behind", texts);
        Assert.Contains("focus app: pinned, local changes", texts);
        Assert.Contains("needed by acme_crm, 30 commits / 12 days behind upstream/version-15", texts);
        Assert.Contains("on one.localhost", texts);
        Assert.Contains("on one.localhost, two.localhost", texts);
        Assert.Contains("on no site yet", texts);
        Assert.Contains("branch version-15  ·  https://github.com/frappe/erpnext", texts);
        PageKit.AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void UnknownSitesSayNothingAboutSites() => Sta.Run(() =>
    {
        var (view, _) = Make("apps-list-only-frappe.json");
        Assert.DoesNotContain(PageKit.Texts(view), t => t.StartsWith("on ", StringComparison.Ordinal));
    });

    [Fact]
    public void ASiteErrorOfTheListIsShownUnderTheTitle() => Sta.Run(() =>
    {
        var (view, _) = Make("apps-list-old-cli.json");
        Assert.Contains("Site lists are from the last successful read: MariaDB is down", PageKit.Texts(view));
        Assert.Contains("not in apps.txt", PageKit.Texts(view));
    });

    [Fact]
    public void OnlyFrappeIsOneLineAndOneAction() => Sta.Run(() =>
    {
        var (view, _) = Make("apps-list-only-frappe.json");
        Assert.Contains("Only Frappe so far. Add ERPNext or any app from the registry or a git repository.", PageKit.Texts(view));
        Assert.Single(PageKit.ButtonLabels(view), l => l == "Add App...");
    });

    [Fact]
    public void AListThatCannotBeReadShowsTheErrorAndRefreshTriesAgain() => Sta.Run(() =>
    {
        var kit = new PageKit();
        kit.Runner.On("app", "list").Fail(1, "bench folder is gone");
        var view = new AppsView(kit.Services);
        view.Bind(new BenchContext(PageKit.Bench(), null));
        PageKit.Wait(view.Pending);
        Assert.Equal("bench folder is gone", view.ListError);
        Assert.Contains("bench folder is gone", PageKit.Texts(view));
        Assert.Null(view.List);
        PageKit.Click(PageKit.ButtonNamed(view, "Refresh the site lists"));
        PageKit.Wait(view.Pending);
        Assert.Equal(["app", "list", "--json", "--bench-dir", P], kit.Runner.Runs.Last().Args);
    });

    // --- Refresh, Check Remotes ---

    [Fact]
    public void RefreshAsksBenchForTheSitesOfEveryApp() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        PageKit.Click(PageKit.ButtonNamed(view, "Refresh the site lists"));
        PageKit.Wait(view.Pending);
        Assert.Equal(["app", "list", "--json", "--bench-dir", P], kit.Runner.Runs.Last().Args);
        Assert.False(view.IsLoading);
    });

    [Fact]
    public void CheckRemotesFetchesThenReadsTheListAgain() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On("app", "focus").Print(PageKit.Fixture("apps-focus.json"));
        PageKit.Click(PageKit.ButtonNamed(view, "Check Remotes"));
        PageKit.Wait(view.Pending);
        Assert.Equal([["app", "focus", "--fetch", "--json", "--bench-dir", P], ["app", "list", "--json", "--no-sites", "--bench-dir", P]],
            kit.Runner.Runs.Skip(1).Select(r => r.Args));
        Assert.Equal("Checked the remotes. 1 app your focus apps need is behind.", view.Message);
        Assert.False(view.MessageIsError);
    });

    [Fact]
    public void AFailedRemoteCheckSaysSo() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On("app", "focus").Fail(1, "git fetch timed out");
        PageKit.Click(PageKit.ButtonNamed(view, "Check Remotes"));
        PageKit.Wait(view.Pending);
        Assert.Equal("git fetch timed out", view.Message);
        Assert.True(view.MessageIsError);
        Assert.Equal(2, kit.Runner.Runs.Count); // no second list read
    });

    // --- Install ---

    [Fact]
    public void InstallIsOfferedOnlyForSitesThatLackTheApp() => Sta.Run(() =>
    {
        var (view, _) = Make();
        Assert.DoesNotContain(PageKit.MenuOf(view, "More actions for frappe"), i => ((string)i.Header).StartsWith("Install", StringComparison.Ordinal));
        Assert.Equal(["Install on two.localhost"], PageKit.MenuOf(view, "More actions for erpnext").Select(i => (string)i.Header).Where(h => h.StartsWith("Install", StringComparison.Ordinal)));
        Assert.Equal(["Install on one.localhost", "Install on two.localhost"], PageKit.MenuOf(view, "More actions for acme_crm").Select(i => (string)i.Header).Where(h => h.StartsWith("Install", StringComparison.Ordinal)));
    });

    [Fact]
    public void InstallRunsAppInstallOnTheSiteAndReadsTheListAgain() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On("app", "install").Print("Installed erpnext on two.localhost");
        PageKit.ClickMenu(view, "More actions for erpnext", "Install on two.localhost");
        PageKit.Wait(view.Pending);
        Assert.Equal([["app", "install", "erpnext", "--site", "two.localhost", "--yes", "--plain", "--bench-dir", P], ["app", "list", "--json", "--no-sites", "--bench-dir", P]],
            kit.Runner.Runs.Skip(1).Select(r => r.Args));
        Assert.Equal("erpnext is installed on two.localhost.", view.Message);
        Assert.Equal(1, kit.Refreshes);
    });

    [Fact]
    public void AFailedInstallShowsTheCliError() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On("app", "install").Fail(1, "erpnext requires frappe");
        PageKit.ClickMenu(view, "More actions for erpnext", "Install on two.localhost");
        PageKit.Wait(view.Pending);
        Assert.Equal("erpnext requires frappe", view.Message);
        Assert.True(view.MessageIsError);
        Assert.Equal(0, kit.Refreshes);
    });

    // --- the focus pin ---

    [Fact]
    public void TheFocusPinIsAMenuWithTheCurrentOneChecked() => Sta.Run(() =>
    {
        var (view, _) = Make();
        var focus = PageKit.MenuOf(view, "More actions for acme_crm").Where(i => ((string)i.Header).StartsWith("Focus pin", StringComparison.Ordinal)).ToList();
        Assert.Equal(["Focus pin: Auto", "Focus pin: Focus", "Focus pin: Ignore"], focus.Select(i => (string)i.Header));
        Assert.Equal([false, true, false], focus.Select(i => i.IsChecked));
        Assert.All(focus, i => Assert.True(i.IsEnabled));
    });

    [Fact]
    public void AnOlderCliCannotSetAPin() => Sta.Run(() =>
    {
        var (view, _) = Make("apps-list-old-cli.json");
        var focus = PageKit.MenuOf(view, "More actions for erpnext").Where(i => ((string)i.Header).StartsWith("Focus pin", StringComparison.Ordinal)).ToList();
        Assert.Equal(3, focus.Count);
        Assert.All(focus, i => Assert.False(i.IsEnabled));
    });

    [Theory]
    [InlineData("Focus pin: Auto", new[] { "app", "focus", "erpnext", "--auto", "--json", "--bench-dir", P })]
    [InlineData("Focus pin: Focus", new[] { "app", "focus", "erpnext", "--json", "--bench-dir", P })]
    [InlineData("Focus pin: Ignore", new[] { "app", "unfocus", "erpnext", "--json", "--bench-dir", P })]
    public void EachPinRunsItsCommand(string item, string[] expected) => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On("app", "focus").Print(PageKit.Fixture("apps-pin.json"));
        kit.Runner.On("app", "unfocus").Print(PageKit.Fixture("apps-pin.json"));
        PageKit.ClickMenu(view, "More actions for erpnext", item);
        PageKit.Wait(view.Pending);
        Assert.Equal(expected, kit.Runner.Runs[1].Args);
        Assert.False(view.MessageIsError);
        Assert.Equal(["app", "list", "--json", "--no-sites", "--bench-dir", P], kit.Runner.Runs[2].Args);
    });

    // --- Update ---

    [Fact]
    public void ADirtyAppCannotBeUpdatedAndTheRowSaysWhy() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        Assert.False(PageKit.ButtonNamed(view, "Update acme_crm").IsEnabled);
        Assert.True(PageKit.ButtonNamed(view, "Update erpnext").IsEnabled);
        Assert.Contains(PageKit.Texts(view), t => t.StartsWith("Update is off: acme_crm has local changes", StringComparison.Ordinal));
        PageKit.Wait(view.UpdateAsync(App(view, "acme_crm")));
        Assert.Single(kit.Runner.Runs); // no plan was asked for
        Assert.True(view.MessageIsError);
    });

    [Fact]
    public void UpdateShowsTheChangelogThenRunsYesAndShowsTheSteps() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On(a => a.Contains("--dry-run")).Print(PageKit.Fixture("apps-update-plan.json"));
        kit.Runner.On(a => a.Contains("--yes")).Print(PageKit.Fixture("apps-update.jsonl"));
        PageKit.Click(PageKit.ButtonNamed(view, "Update erpnext"));
        PageKit.Wait(view.Pending);
        Assert.Equal(["app", "update", "erpnext", "--dry-run", "--json", "--bench-dir", P], kit.Runner.Runs[1].Args);
        var panel = view.OpenPanel!;
        Assert.Contains("12 new commits on version-15:", PageKit.Texts(panel));
        Assert.Contains("fix: rounding in invoices", PageKit.Texts(panel));
        Assert.Contains("and 10 more", PageKit.Texts(panel));
        Assert.Contains("1. Back up one.localhost", PageKit.Texts(panel));
        Assert.Contains("Each site is backed up before it is migrated: one.localhost.", PageKit.Texts(panel));
        Assert.Equal(2, kit.Runner.Runs.Count); // nothing changed yet

        PageKit.Click(PageKit.ButtonNamed(panel, "Run the update of erpnext"));
        PageKit.Wait(view.Pending);
        Assert.Equal(["app", "update", "erpnext", "--yes", "--jsonl", "--bench-dir", P], kit.Runner.Runs[2].Args);
        Assert.Equal(["app", "list", "--json", "--no-sites", "--bench-dir", P], kit.Runner.Runs[3].Args);
        Assert.Contains("erpnext was updated. Changed: erpnext.", PageKit.Texts(view.OpenPanel!));
        Assert.Equal(1, kit.Refreshes);
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Done"));
        Assert.Null(view.OpenPanel);
    });

    [Fact]
    public void CancellingTheChangelogChangesNothing() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On(a => a.Contains("--dry-run")).Print(PageKit.Fixture("apps-update-plan.json"));
        PageKit.Click(PageKit.ButtonNamed(view, "Update erpnext"));
        PageKit.Wait(view.Pending);
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Cancel"));
        Assert.Null(view.OpenPanel);
        Assert.Equal(2, kit.Runner.Runs.Count);
    });

    [Fact]
    public void AnAppThatIsUpToDateSaysSoAndOffersNoUpdate() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On(a => a.Contains("--dry-run")).Print(PageKit.Fixture("apps-update-uptodate.json"));
        PageKit.Click(PageKit.ButtonNamed(view, "Update erpnext"));
        PageKit.Wait(view.Pending);
        Assert.Contains("erpnext is up to date on version-15.", PageKit.Texts(view.OpenPanel!));
        Assert.Null(PageKit.FindButton(view.OpenPanel!, "Run the update of erpnext"));
        PageKit.AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void AFailedUpdateShowsTheCliProblem() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On(a => a.Contains("--dry-run")).Print(PageKit.Fixture("apps-update-plan.json"));
        kit.Runner.On(a => a.Contains("--yes")).Print(PageKit.Fixture("apps-update-fail.jsonl")).Fail(1);
        PageKit.Click(PageKit.ButtonNamed(view, "Update erpnext"));
        PageKit.Wait(view.Pending);
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Run the update of erpnext"));
        PageKit.Wait(view.Pending);
        Assert.Contains("erpnext has diverged from its remote.", PageKit.Texts(view.OpenPanel!));
        Assert.Equal(0, kit.Refreshes);
        Assert.False(view.IsBusy);
    });

    [Fact]
    public void AnUpdateThatIsRunningCannotBeDismissed() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On(a => a.Contains("--dry-run")).Print(PageKit.Fixture("apps-update-plan.json"));
        var held = kit.Runner.On(a => a.Contains("--yes")).Hold();
        PageKit.Click(PageKit.ButtonNamed(view, "Update erpnext"));
        PageKit.Wait(view.Pending);
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Run the update of erpnext"));
        Assert.True(view.IsBusy);
        Assert.Empty(PageKit.Walk(view.OpenPanel!).OfType<Button>());
        Assert.False(PageKit.ButtonNamed(view, "Update acme_crm").IsEnabled);
        Assert.False(PageKit.ButtonNamed(view, "Refresh the site lists").IsEnabled);
        held.Release(PageKit.Fixture("apps-update.jsonl"));
        PageKit.Wait(view.Pending);
        PageKit.Drain();
        Assert.False(view.IsBusy);
        Assert.NotNull(PageKit.FindButton(view.OpenPanel!, "Done"));
    });

    // --- Add App ---

    private static void FillAdd(AppsView view, string source, string branch = "", string commit = "", params string[] sites)
    {
        var form = view.AddForm!.Value;
        form.Source.Text = source;
        form.Branch.Text = branch;
        form.Commit.Text = commit;
        foreach (var box in form.Sites) box.IsChecked = sites.Contains((string)box.Content);
    }

    [Fact]
    public void TheAddFormListsTheSitesAndNamesEveryControl() => Sta.Run(() =>
    {
        var (view, _) = Make();
        PageKit.Click(PageKit.ButtonNamed(view, "Add App..."));
        var form = view.AddForm!.Value;
        Assert.Equal(["one.localhost", "two.localhost"], form.Sites.Select(s => (string)s.Content));
        Assert.Equal(["Review Plan...", "Cancel"], PageKit.Walk(view.OpenPanel!).OfType<Button>().Select(b => (string)b.Content));
        PageKit.AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void AddAppChecksTheFormBeforeAnyCommandRuns() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        PageKit.Click(PageKit.ButtonNamed(view, "Add App..."));
        FillAdd(view, "");
        PageKit.Click(PageKit.ButtonNamed(view, "Review Plan..."));
        Assert.Equal("Enter an app name or a git URL.", view.AddProblemText);
        FillAdd(view, "erpnext", commit: "nothex");
        PageKit.Click(PageKit.ButtonNamed(view, "Review Plan..."));
        Assert.Equal("A commit is 7 to 40 hex characters.", view.AddProblemText);
        Assert.Empty(kit.Plans);
        Assert.Single(kit.Runner.Runs);
    });

    [Fact]
    public void AddAppRunsThePlanThenItsTokenWithBranchCommitAndSites() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On(a => a.Contains("--dry-run")).Print(PageKit.Fixture("apps-add-plan.json"));
        kit.Runner.On(a => a.Contains("--apply")).Print(PageKit.Fixture("apps-add-apply.jsonl"));
        PageKit.Click(PageKit.ButtonNamed(view, "Add App..."));
        FillAdd(view, " https://github.com/acme/acme_crm ", "main", "9b1d2c0", "one.localhost");
        PageKit.Click(PageKit.ButtonNamed(view, "Review Plan..."));
        PageKit.Wait(view.Pending);

        var request = Assert.Single(kit.Plans);
        Assert.Equal("Add App", request.ConfirmLabel);
        Assert.Equal("Add acme_crm", request.Title);
        Assert.False(request.CanStop);
        var runs = kit.RunsOf("app", "add");
        Assert.Equal(["app", "add", "https://github.com/acme/acme_crm", "--branch", "main", "--commit", "9b1d2c0", "--install-on", "one.localhost", "--bench-dir", P, "--dry-run", "--json"], runs[0]);
        Assert.Equal(["app", "add", "https://github.com/acme/acme_crm", "--branch", "main", "--commit", "9b1d2c0", "--install-on", "one.localhost", "--bench-dir", P,
            "--apply", "3f9c0e2222222222222222222222222222222222222222222222222222222222", "--yes", "--jsonl"], runs[1]);
        Assert.Equal("acme_crm was added.", view.Message);
        Assert.Equal(1, kit.Refreshes);
        Assert.Null(view.OpenPanel);
        Assert.Equal(["app", "list", "--json", "--no-sites", "--bench-dir", P], kit.Runner.Runs.Last().Args);
    });

    [Fact]
    public void AddAppWithOnlyAnameAsksForNoSite() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On(a => a.Contains("--dry-run")).Print(PageKit.Fixture("apps-add-plan.json"));
        kit.Runner.On(a => a.Contains("--apply")).Print(PageKit.Fixture("apps-add-apply.jsonl"));
        PageKit.Click(PageKit.ButtonNamed(view, "Add App..."));
        FillAdd(view, "erpnext");
        PageKit.Click(PageKit.ButtonNamed(view, "Review Plan..."));
        PageKit.Wait(view.Pending);
        Assert.Equal(["app", "add", "erpnext", "--bench-dir", P, "--dry-run", "--json"], kit.RunsOf("app", "add")[0]);
    });

    [Fact]
    public void ACancelledPlanSheetKeepsTheFormOpen() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Services.ReviewPlan = _ => Task.FromResult(PlanOutcome.None);
        PageKit.Click(PageKit.ButtonNamed(view, "Add App..."));
        FillAdd(view, "erpnext");
        PageKit.Click(PageKit.ButtonNamed(view, "Review Plan..."));
        PageKit.Wait(view.Pending);
        Assert.NotNull(view.AddForm);
        Assert.False(view.IsBusy);
        Assert.Equal(0, kit.Refreshes);
    });
}
