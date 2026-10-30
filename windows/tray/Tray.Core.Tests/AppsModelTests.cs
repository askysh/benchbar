using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using Xunit;
using static Tray.Core.Tests.CliFixture;

namespace Tray.Core.Tests;

/// <summary>The Apps tab: the list, the focus words, the update plan, the exact CLI arguments.</summary>
public class AppsModelTests
{
    private const string Bench = "/home/akash/frappe-bench";
    private static readonly TimeSpan Short = TimeSpan.FromSeconds(5);


    private static BenchAppList List(string fixture = "apps-list.json") => AppJson.ParseList(Doc(fixture));

    // --- the list ---

    [Fact]
    public void TheListIsReadWithBranchesSitesAndFocusFields()
    {
        var list = List();
        Assert.Equal(["frappe", "erpnext", "acme_crm"], list.Apps.Select(a => a.Name));
        Assert.True(list.SitesKnown);
        Assert.Null(list.SitesError);
        var erpnext = list.Apps[1];
        Assert.Equal("15.115.0", erpnext.Version);
        Assert.Equal("version-15", erpnext.Branch);
        Assert.Equal(["one.localhost"], erpnext.Sites);
        Assert.False(erpnext.Dirty);
        Assert.Equal("branch version-15  ·  https://github.com/frappe/erpnext", erpnext.SourceLine);
        Assert.False(list.OnlyFrappe);
    }

    [Fact]
    public void AFocusAppSaysWhyAndADependencySaysHowFarBehindItIs()
    {
        var list = List();
        var focus = list.Apps[2];
        Assert.True(focus.IsFocus);
        Assert.Equal(FocusPin.Focus, focus.Pin);
        Assert.Equal("focus app: pinned, local changes", focus.FocusSummary);
        Assert.Null(focus.DependencySummary);
        Assert.Null(focus.Behind);

        var frappe = list.Apps[0];
        Assert.False(frappe.IsFocus);
        Assert.Equal("needed by acme_crm, 30 commits / 12 days behind upstream/version-15", frappe.DependencySummary);
        Assert.True(frappe.IsStaleDependency);
        Assert.False(list.Apps[1].IsStaleDependency);
    }

    [Fact]
    public void ADependencyThatIsNotBehindOnlyNamesWhoNeedsIt()
    {
        var app = List().Apps[0] with { Behind = 0 };
        Assert.Equal("needed by acme_crm", app.DependencySummary);
        Assert.False(app.IsStaleDependency);
        Assert.Equal("needed by x, 1 commit behind its remote", (app with { NeededBy = ["x"], Behind = 1, BehindDays = 0, Upstream = null }).DependencySummary);
    }

    [Fact]
    public void ADirtyAppOrOneOnADetachedHeadCannotBeUpdatedAndSaysWhy()
    {
        var list = List();
        Assert.Null(list.Apps[1].UpdateBlocker);
        Assert.Contains("acme_crm has local changes", list.Apps[2].UpdateBlocker);
        Assert.Contains("Commit or stash", list.Apps[2].UpdateBlocker);
        var old = List("apps-list-old-cli.json").Apps[0];
        Assert.Contains("detached HEAD", old.UpdateBlocker);
    }

    [Fact]
    public void AnOlderCliLeavesTheFocusFieldsOutAndKeepsTheSiteError()
    {
        var list = List("apps-list-old-cli.json");
        var app = list.Apps.Single();
        Assert.Null(app.Focus);
        Assert.Equal(FocusPin.Auto, app.Pin);
        Assert.False(app.InAppsTxt);
        Assert.Equal("MariaDB is down", list.SitesError);
        Assert.Null(app.FocusSummary);
    }

    [Fact]
    public void OnlyFrappeAndUnknownSitesAreRecognised()
    {
        var list = List("apps-list-only-frappe.json");
        Assert.True(list.OnlyFrappe);
        Assert.False(list.SitesKnown);
    }

    [Fact]
    public void ADocumentWithoutAppsOrNamesIsRefused()
    {
        Assert.Throws<FormatException>(() => AppJson.ParseList(new JsonObject()));
        Assert.Throws<FormatException>(() => AppJson.ParseApp(new JsonObject { ["branch"] = "x" }));
    }

    [Fact]
    public void TheRemoteCheckIsReadLikeTheList()
    {
        var report = AppJson.ParseFocusReport(Doc("apps-focus.json"));
        Assert.Equal("2026-10-30T08:00:00Z", report.FetchedAt);
        Assert.Equal(1, report.Apps.Count(a => a.IsStaleDependency));
    }

    // --- sites an app can be installed on ---

    [Fact]
    public void AnAppCanBeInstalledOnTheSitesThatLackItButFrappeNeverAndNothingWhenSitesAreUnknown()
    {
        var list = List();
        string[] sites = ["one.localhost", "two.localhost"];
        Assert.Empty(AppSites.Missing(list.Apps[0], sites, true));
        Assert.Equal(["two.localhost"], AppSites.Missing(list.Apps[1], sites, true));
        Assert.Equal(sites, AppSites.Missing(list.Apps[2], sites, true));
        Assert.Empty(AppSites.Missing(list.Apps[1], sites, sitesKnown: false));
    }

    // --- focus words ---

    [Fact]
    public void EachPinHasItsWordsAndHelp()
    {
        Assert.Equal(["Auto", "Focus", "Ignore"], FocusPins.All.Select(FocusPins.Title));
        Assert.Equal(["app", "focus", "erpnext", "--auto"], FocusPins.Words(FocusPin.Auto, "erpnext"));
        Assert.Equal(["app", "focus", "erpnext"], FocusPins.Words(FocusPin.Focus, "erpnext"));
        Assert.Equal(["app", "unfocus", "erpnext"], FocusPins.Words(FocusPin.Ignore, "erpnext"));
        Assert.All(FocusPins.All, p => Assert.NotEmpty(FocusPins.Help(p)));
        Assert.Equal(FocusPin.Ignore, FocusPins.Parse("ignore"));
        Assert.Equal(FocusPin.Auto, FocusPins.Parse("what"));
        Assert.Equal(FocusPin.Auto, FocusPins.Parse(null));
    }

    // --- the update plan ---

    [Fact]
    public void AnUpdatePlanListsCommitsStepsAndSites()
    {
        var plan = AppJson.ParseUpdatePlan(Doc("apps-update-plan.json"));
        Assert.Equal("erpnext", plan.App);
        Assert.Equal("version-15", plan.Branch);
        Assert.Equal(12, plan.CommitsTotal);
        Assert.Equal(["fix: rounding in invoices", "feat: new report"], plan.Commits.Select(c => c.Subject));
        Assert.Equal(["Back up one.localhost", "Fast forward", "Migrate one.localhost"], plan.Steps.Select(s => s.Name));
        Assert.Equal("backup", plan.Steps[0].Kind);
        Assert.Equal(["one.localhost"], plan.Sites);
        Assert.False(plan.IsUpToDate);
        Assert.False(plan.HasPending);
    }

    [Fact]
    public void AnUpdatePlanWithNothingToTakeIsUpToDate()
    {
        Assert.True(AppJson.ParseUpdatePlan(Doc("apps-update-uptodate.json")).IsUpToDate);
        Assert.Throws<FormatException>(() => AppJson.ParseUpdatePlan(new JsonObject()));
    }

    // --- adding an app ---

    [Theory]
    [InlineData("https://github.com/acme/acme_crm", "acme_crm")]
    [InlineData("https://github.com/acme/acme_crm.git", "acme_crm")]
    [InlineData("git@github.com:acme/acme_crm.git", "acme_crm")]
    [InlineData("https://github.com/acme/acme_crm/", "acme_crm")]
    [InlineData("erpnext", "erpnext")]
    public void TheNameComesFromTheSource(string source, string name) => Assert.Equal(name, new AppAddInput(source).DisplayName);

    [Fact]
    public void TheAddFormRefusesWhatTheCliWouldRefuse()
    {
        Assert.NotNull(new AppAddInput("").Problem);
        Assert.NotNull(new AppAddInput("  ").Problem);
        Assert.NotNull(new AppAddInput("two words").Problem);
        Assert.NotNull(new AppAddInput("erpnext", "my branch").Problem);
        Assert.NotNull(new AppAddInput("erpnext", Commit: "xyz").Problem);
        Assert.NotNull(new AppAddInput("erpnext", Commit: "abc12").Problem);
        Assert.Null(new AppAddInput("erpnext", Commit: "abc1234").Problem);
        Assert.Null(new AppAddInput(" erpnext ", "version-15", "9B1D2C0000000000000000000000000000000000").Problem);
        Assert.True(new AppAddInput("erpnext").CanReview);
    }

    // --- exact arguments ---

    [Fact]
    public void EveryActionRunsExactlyTheseArguments()
    {
        Assert.Equal(["app", "list", "--json", "--no-sites", "--bench-dir", Bench], AppCommands.List(Bench));
        Assert.Equal(["app", "list", "--json", "--bench-dir", Bench], AppCommands.ListLive(Bench));
        Assert.Equal(["app", "focus", "--fetch", "--json", "--bench-dir", Bench], AppCommands.CheckRemotes(Bench));
        Assert.Equal(["app", "install", "erpnext", "--site", "two.localhost", "--yes", "--plain", "--bench-dir", Bench], AppCommands.Install("erpnext", "two.localhost", Bench));
        Assert.Equal(["app", "update", "erpnext", "--dry-run", "--json", "--bench-dir", Bench], AppCommands.UpdatePlan("erpnext", Bench));
        Assert.Equal(["app", "update", "erpnext", "--yes", "--jsonl", "--bench-dir", Bench], AppCommands.Update("erpnext", Bench));
        Assert.Equal(["app", "focus", "erpnext", "--auto", "--json", "--bench-dir", Bench], AppCommands.SetFocus("erpnext", FocusPin.Auto, Bench));
        Assert.Equal(["app", "focus", "erpnext", "--json", "--bench-dir", Bench], AppCommands.SetFocus("erpnext", FocusPin.Focus, Bench));
        Assert.Equal(["app", "unfocus", "erpnext", "--json", "--bench-dir", Bench], AppCommands.SetFocus("erpnext", FocusPin.Ignore, Bench));
    }

    [Fact]
    public void AddAppPutsBranchCommitAndSitesInTheBaseArguments()
    {
        Assert.Equal(["app", "add", "erpnext", "--bench-dir", Bench], AppCommands.Add(new AppAddInput("erpnext"), Bench));
        var full = new AppAddInput(" https://github.com/acme/acme_crm ", " main ", " abc1234 ", ["one.localhost", "two.localhost"]);
        Assert.Equal(["app", "add", "https://github.com/acme/acme_crm", "--branch", "main", "--commit", "abc1234", "--install-on", "one.localhost,two.localhost", "--bench-dir", Bench],
            AppCommands.Add(full, Bench));
    }

    // --- through the client ---

    [Fact]
    public async Task TheListCallRunsItsArgumentsAndReadsTheDocument()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("app", "list").Print(CliFixture.Lines("apps-list.json"));
        var result = await client.RunJsonAsync(AppCommands.List(Bench), null, Short, AppJson.ParseList, TestContext.Current.CancellationToken);
        Assert.True(result.Ok);
        Assert.Equal(3, result.Value!.Apps.Count);
        Assert.Equal(AppCommands.List(Bench), runner.Runs.Single().Args);
    }

    [Fact]
    public async Task ADocumentTheParserRefusesBecomesAnErrorNotAnException()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("app", "list").Print("{\"schema_version\":1,\"other\":true}");
        var result = await client.RunJsonAsync(AppCommands.List(Bench), null, Short, AppJson.ParseList, TestContext.Current.CancellationToken);
        Assert.False(result.Ok);
        Assert.Contains("apps list", result.Error);
    }
}
