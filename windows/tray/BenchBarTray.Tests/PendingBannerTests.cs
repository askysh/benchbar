using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;

namespace BenchBar.Tray.Tests;

/// <summary>The banner for an update or add that stopped part way, and the Add App form with several apps (issue 175, PAR-6 and P14).</summary>
public class PendingBannerTests
{
    private const string Bench = "/home/akash/frappe-bench";

    private static BenchStatus Status(string fixture) =>
        BenchJson.ParseStatus(string.Join('\n', PageKit.Fixture(fixture)));

    private sealed class Rig
    {
        public Rig()
        {
            Kit = new PageKit();
            Banner = new PendingBanner(Kit.Services);
            Kit.Services.ReviewPlan = request =>
            {
                Requests.Add(request);
                return Task.FromResult(new PlanOutcome(Applied, false, null));
            };
            Kit.Services.ConfirmYesNo = (title, message, label) =>
            {
                Questions.Add((title, message, label));
                return Answer;
            };
            Kit.Services.RefreshNow = () => Refreshes++;
        }

        public PageKit Kit { get; }
        public PendingBanner Banner { get; }
        public List<PlanReviewRequest> Requests { get; } = [];
        public List<(string Title, string Message, string Label)> Questions { get; } = [];
        public bool Answer { get; set; } = true;
        public bool Applied { get; set; }
        public int Refreshes { get; private set; }
    }

    [Fact]
    public void NothingPendingShowsNothing() => Sta.Run(() =>
    {
        var rig = new Rig();
        rig.Banner.Bind(PageKit.Bench());
        Assert.Equal(System.Windows.Visibility.Collapsed, rig.Banner.Visibility);
    });

    [Fact]
    public void AnUpdateThatStoppedShowsWhyTheFixLineAndTheTwoWaysOut() => Sta.Run(() =>
    {
        var rig = new Rig();
        rig.Banner.Bind(Status("status-pending-update.json"));
        Assert.Equal(System.Windows.Visibility.Visible, rig.Banner.Visibility);
        var texts = PageKit.Texts(rig.Banner);
        Assert.Contains("Unfinished app update", texts);
        Assert.Contains("app update of acme_crm did not finish: stopped at migrate (bench --site macdev migrate failed with exit code 1 after 1s); 2 step(s) left (migrate, build)", texts);
        Assert.Contains("Left to do: Migrate macdev (macdev), Build (acme_crm)", texts);
        Assert.Contains(PageKit.Walk(rig.Banner).OfType<TextBox>(), t => t.Text == "benchbar app update acme_crm --bench-dir " + Bench);
        Assert.NotNull(PageKit.FindButton(rig.Banner, "Finish Update of acme_crm"));
        Assert.NotNull(PageKit.FindButton(rig.Banner, "Discard the unfinished app update of acme_crm"));
        PageKit.AssertEveryControlIsNamed(rig.Banner);
    });

    [Fact]
    public void AnAddThatStoppedOffersFinishAdd() => Sta.Run(() =>
    {
        var rig = new Rig();
        rig.Banner.Bind(Status("status-pending-add.json"));
        Assert.Contains("Unfinished app add", PageKit.Texts(rig.Banner));
        Assert.Contains(PageKit.Walk(rig.Banner).OfType<TextBox>(), t => t.Text == "benchbar app add acme_i1 --bench-dir " + Bench);
        Assert.NotNull(PageKit.FindButton(rig.Banner, "Finish Add of acme_i1"));
    });

    [Fact]
    public void APollThatChangedNothingKeepsTheSameButtons() => Sta.Run(() =>
    {
        var rig = new Rig();
        rig.Banner.Bind(Status("status-pending-update.json"));
        var before = PageKit.FindButton(rig.Banner, "Finish Update of acme_crm");
        rig.Banner.Bind(Status("status-pending-update.json"));
        Assert.Same(before, PageKit.FindButton(rig.Banner, "Finish Update of acme_crm"));
        rig.Banner.Bind(PageKit.Bench(path: Bench)); // the record is gone: the banner goes
        Assert.Equal(System.Windows.Visibility.Collapsed, rig.Banner.Visibility);
    });

    [Fact]
    public void FinishUpdateOpensThePlanSheetWithoutATokenAndAppliesTheSameCommand() => Sta.Run(() =>
    {
        var rig = new Rig { Applied = true };
        rig.Banner.Bind(Status("status-pending-update.json"));
        PageKit.Click(PageKit.ButtonNamed(rig.Banner, "Finish Update of acme_crm"));
        PageKit.Wait(rig.Banner.Pending);
        var request = Assert.Single(rig.Requests);
        Assert.Equal(["app", "update", "acme_crm", "--dry-run", "--json", "--bench-dir", Bench], request.PlanArgs);
        Assert.False(request.RequiresToken);
        Assert.Equal("Finish Update", request.ConfirmLabel);
        Assert.Equal(["app", "update", "acme_crm", "--yes", "--jsonl", "--bench-dir", Bench],
            request.ApplyArgs(PlanDocument.FromJson(System.Text.Json.Nodes.JsonNode.Parse(string.Join('\n', PageKit.Fixture("apps-update-pending-plan.json")))!.AsObject())));
        Assert.Equal(1, rig.Refreshes); // a run that applied: the app polls again
    });

    [Fact]
    public void FinishAddPlansTheSameAddWithTheAppName() => Sta.Run(() =>
    {
        var rig = new Rig();
        rig.Banner.Bind(Status("status-pending-add.json"));
        PageKit.Click(PageKit.ButtonNamed(rig.Banner, "Finish Add of acme_i1"));
        PageKit.Wait(rig.Banner.Pending);
        var request = Assert.Single(rig.Requests);
        Assert.Equal(["app", "add", "acme_i1", "--bench-dir", Bench, "--dry-run", "--json"], request.PlanArgs);
        Assert.True(request.RequiresToken);
        var plan = PlanDocument.FromJson(System.Text.Json.Nodes.JsonNode.Parse(string.Join('\n', PageKit.Fixture("apps-add-pending-resume-plan.json")))!.AsObject());
        Assert.Equal(["app", "add", "acme_i1", "--bench-dir", Bench, "--apply", plan.Token!, "--yes", "--jsonl"], request.ApplyArgs(plan));
        Assert.Equal(0, rig.Refreshes); // the sheet was closed without a run
    });

    [Fact]
    public void DiscardAsksFirstAndRunsNothingWhenTheAnswerIsNo() => Sta.Run(() =>
    {
        var rig = new Rig { Answer = false };
        rig.Banner.Bind(Status("status-pending-update.json"));
        PageKit.Click(PageKit.ButtonNamed(rig.Banner, "Discard the unfinished app update of acme_crm"));
        PageKit.Wait(rig.Banner.Pending);
        var question = Assert.Single(rig.Questions);
        Assert.Equal("Discard the unfinished app update", question.Title);
        Assert.Contains("Its 2 steps will not run", question.Message);
        Assert.Equal("Discard", question.Label);
        Assert.Empty(rig.Kit.Runner.Runs);
        Assert.NotNull(PageKit.FindButton(rig.Banner, "Discard the unfinished app update of acme_crm"));
    });

    [Fact]
    public void ADiscardThatWasConfirmedRunsTheCliFlagThenSaysSo() => Sta.Run(() =>
    {
        var rig = new Rig();
        rig.Kit.Runner.On("app", "update").Print("  [WARN] dropping the unfinished app_update of acme_crm (started 2026-11-19T08:00:03Z, stopped at migrate); its 2 step(s) will not run, and nothing else runs now");
        rig.Banner.Bind(Status("status-pending-update.json"));
        PageKit.Click(PageKit.ButtonNamed(rig.Banner, "Discard the unfinished app update of acme_crm"));
        PageKit.Wait(rig.Banner.Pending);
        PageKit.Drain();
        Assert.Equal([["app", "update", "acme_crm", "--discard-pending", "--bench-dir", Bench]], rig.Kit.Runner.Runs.Select(r => r.Args));
        Assert.Equal("The unfinished app update of acme_crm was discarded.", rig.Banner.Message);
        Assert.Equal(1, rig.Refreshes);
        Assert.Empty(rig.Banner.Operations);
        Assert.Null(PageKit.FindButton(rig.Banner, "Finish Update of acme_crm"));
    });

    [Fact]
    public void AFailedDiscardKeepsTheRecordAndSaysWhy() => Sta.Run(() =>
    {
        var rig = new Rig();
        rig.Kit.Runner.On("app", "update").Fail(1, "no bench found");
        rig.Banner.Bind(Status("status-pending-update.json"));
        PageKit.Click(PageKit.ButtonNamed(rig.Banner, "Discard the unfinished app update of acme_crm"));
        PageKit.Wait(rig.Banner.Pending);
        PageKit.Drain();
        Assert.Single(rig.Banner.Operations);
        Assert.Contains("no bench found", rig.Banner.Message);
        Assert.Equal(0, rig.Refreshes);
        Assert.NotNull(PageKit.FindButton(rig.Banner, "Finish Update of acme_crm"));
    });

    [Fact]
    public void TheBenchPageHostsTheBannerAboveTheTabs() => Sta.Run(() =>
    {
        var kit = new PageKit();
        var page = new BenchPage(kit.Services, new OverviewView(new OverviewActions()));
        page.Bind(Status("status-pending-update.json"), null, navigate: true);
        Assert.Equal(System.Windows.Visibility.Visible, page.Pending.Visibility);
        Assert.Contains("Unfinished app update", PageKit.Texts(page));
        page.Bind(PageKit.Bench(), null, navigate: false);
        Assert.Equal(System.Windows.Visibility.Collapsed, page.Pending.Visibility);
    });

    // --- Add App with several apps ---

    private static (AppsView View, PageKit Kit) MakeApps()
    {
        var kit = new PageKit();
        kit.Runner.On("app", "list").Print(PageKit.Fixture("apps-list.json"));
        var view = new AppsView(kit.Services);
        view.Bind(new BenchContext(PageKit.Bench(), null));
        PageKit.Wait(view.Pending);
        return (view, kit);
    }

    [Fact]
    public void AddAnotherAppAddsARowThatCanBeRemoved() => Sta.Run(() =>
    {
        var (view, _) = MakeApps();
        PageKit.Click(PageKit.ButtonNamed(view, "Add App..."));
        Assert.Single(view.AddFormRows);
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Add another app to this plan"));
        Assert.Equal(2, view.AddFormRows.Count);
        Assert.Equal(["one.localhost", "two.localhost"], view.AddFormRows[1].Sites.Select(s => (string)s.Content));
        PageKit.AssertEveryControlIsNamed(view);
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Remove app 2"));
        Assert.Single(view.AddFormRows);
    });

    [Fact]
    public void ThePlanIsAskedForOnceWithEveryAppAndItsOwnPinAndSites() => Sta.Run(() =>
    {
        var (view, kit) = MakeApps();
        var requests = new List<PlanReviewRequest>();
        kit.Services.ReviewPlan = r => { requests.Add(r); return Task.FromResult(PlanOutcome.None); };
        PageKit.Click(PageKit.ButtonNamed(view, "Add App..."));
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Add another app to this plan"));
        var rows = view.AddFormRows;
        rows[0].Source.Text = "acme_i1";
        rows[0].Commit.Text = "44973abd253d";
        rows[0].Sites[0].IsChecked = true;
        rows[1].Source.Text = "https://github.com/acme/acme_i2";
        rows[1].Branch.Text = "develop";
        rows[1].Sites[0].IsChecked = true;
        rows[1].Sites[1].IsChecked = true;
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Review Plan..."));
        PageKit.Wait(view.Pending);
        var request = Assert.Single(requests);
        Assert.Equal("Add acme_i1 and acme_i2", request.Title);
        Assert.Equal("Add Apps", request.ConfirmLabel);
        Assert.Equal(["app", "add", "acme_i1", "--commit", "44973abd253d", "--install-on", "one.localhost",
            "https://github.com/acme/acme_i2", "--branch", "develop", "--install-on", "one.localhost,two.localhost", "--bench-dir", PageKit.BenchPath, "--dry-run", "--json"], request.PlanArgs);
        Assert.NotNull(request.Describe);
    });

    [Fact]
    public void AProblemInTheSecondAppStopsTheFormBeforeAnyCommandRuns() => Sta.Run(() =>
    {
        var (view, kit) = MakeApps();
        PageKit.Click(PageKit.ButtonNamed(view, "Add App..."));
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Add another app to this plan"));
        view.AddFormRows[0].Source.Text = "acme_i1";
        view.AddFormRows[1].Source.Text = "acme_i2";
        view.AddFormRows[1].Commit.Text = "nothex";
        var runs = kit.Runner.Runs.Count;
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Review Plan..."));
        PageKit.Wait(view.Pending);
        Assert.Equal("App 2: A commit is 7 to 40 hex characters.", view.AddProblemText);
        Assert.Equal(runs, kit.Runner.Runs.Count);
    });
}
