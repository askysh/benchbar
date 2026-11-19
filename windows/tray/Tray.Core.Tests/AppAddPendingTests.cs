using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using BenchBar.Tray.TestSupport;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>Several apps in one add and the pending operations of the status (issue 175, P14 and PAR-6 / P52). The fixtures are the CLI's own output.</summary>
public class AppAddPendingTests
{
    private const string Bench = "/home/akash/frappe-bench";

    private static JsonObject Cli(string name) => JsonNode.Parse(File.ReadAllText(Path.Combine(FixtureFiles.Dir("cli"), name)))!.AsObject();

    // --- several apps in one add ---

    [Fact]
    public void OneAppGivesTheSameArgumentsAsBefore()
    {
        var input = new AppAddInput("https://github.com/acme/acme_crm", "main", "9b1d2c4", ["one.localhost", "two.localhost"]);
        Assert.Equal(["app", "add", "https://github.com/acme/acme_crm", "--branch", "main", "--commit", "9b1d2c4", "--install-on", "one.localhost,two.localhost", "--bench-dir", Bench],
            AppCommands.Add(input, Bench));
        Assert.Equal(AppCommands.Add(input, Bench), AppCommands.AddMany([input], Bench));
    }

    [Fact]
    public void EachAppsOptionsFollowItsOwnName()
    {
        var args = AppCommands.AddMany(
        [
            new AppAddInput("acme_i1", "", "44973abd253d", ["macdev"]),
            new AppAddInput(" acme_i2 ", "develop", "", ["macdev", "site2"]),
            new AppAddInput("acme_i3"),
        ], Bench);
        Assert.Equal(["app", "add", "acme_i1", "--commit", "44973abd253d", "--install-on", "macdev",
            "acme_i2", "--branch", "develop", "--install-on", "macdev,site2", "acme_i3", "--bench-dir", Bench], args);
    }

    [Fact]
    public void TheFormNamesTheAppThatHasAProblem()
    {
        Assert.Null(AppAddBatch.Problem([new AppAddInput("acme_i1"), new AppAddInput("acme_i2", Commit: "44973ab")]));
        Assert.Equal("Enter an app name or a git URL.", AppAddBatch.Problem([]));
        Assert.Equal("Enter an app name or a git URL.", AppAddBatch.Problem([new AppAddInput("")]));
        Assert.Equal("App 2: A commit is 7 to 40 hex characters.", AppAddBatch.Problem([new AppAddInput("acme_i1"), new AppAddInput("acme_i2", Commit: "nothex")]));
        Assert.Equal("App 3: The app name or URL has no spaces.", AppAddBatch.Problem([new AppAddInput("a"), new AppAddInput("b"), new AppAddInput("c d")]));
        Assert.Equal("App 2: acme_i1 is listed twice.", AppAddBatch.Problem([new AppAddInput("acme_i1"), new AppAddInput("https://github.com/acme/acme_i1.git")]));
    }

    [Fact]
    public void TheTitleSaysWhatIsAdded()
    {
        Assert.Equal("Add acme_i1", AppAddBatch.Title([new AppAddInput("acme_i1")]));
        Assert.Equal("Add acme_i1 and acme_i2", AppAddBatch.Title([new AppAddInput("acme_i1"), new AppAddInput("acme_i2")]));
        Assert.Equal("Add 3 apps", AppAddBatch.Title([new AppAddInput("a"), new AppAddInput("b"), new AppAddInput("c")]));
    }

    [Fact]
    public void ThePlanOfSeveralAppsReadsAsOneLinePerApp()
    {
        var plan = PlanDocument.FromJson(Cli("apps-add-plan-many.json"));
        Assert.True(plan.CanApply);
        Assert.NotNull(plan.Token);
        Assert.Equal(["Clone acme_i1", "Clone acme_i2", "Build", "Install acme_i1 on macdev", "Install acme_i2 on macdev", "Install acme_i2 on site2", "Restart"],
            plan.Steps.Select(s => s.Name));
        var lines = AppAddBatch.PlanLines(plan);
        Assert.Equal(2, lines.Count);
        Assert.Equal("acme_i1: main at 44973ab (pinned), install on macdev", lines[0]);
        Assert.StartsWith("acme_i2: main at ", lines[1]);
        Assert.EndsWith(", install on macdev, site2", lines[1]);
        Assert.DoesNotContain("(pinned)", lines[1]);
    }

    [Fact]
    public void ThePlanOfOneAppHasItsFieldsAtTheTop()
    {
        var lines = AppAddBatch.PlanLines(PlanDocument.FromJson(Cli("apps-add-plan.json")));
        Assert.Equal(["acme_crm: main at 9b1d2c0, install on one.localhost"], lines);
    }

    [Fact]
    public void ThePlanOfAnAddThatStoppedListsOnlyWhatIsLeftAndSaysWhy()
    {
        var doc = Cli("apps-add-pending-resume-plan.json");
        var plan = PlanDocument.FromJson(doc);
        Assert.Equal(["Build", "Install on macdev", "Restart"], plan.Steps.Select(s => s.Name));
        Assert.StartsWith("an earlier app add of acme_i1 stopped at build", JsonRead.Str(doc, "reason"));
        Assert.Equal(["acme_i1: main, already in the bench, install on macdev"], AppAddBatch.PlanLines(plan));
    }

    // --- pending operations in the status ---

    [Fact]
    public void AStatusWithoutPendingOperationsHasNone()
    {
        var status = BenchJson.ParseStatus(File.ReadAllText(Path.Combine(FixtureFiles.Dir("rest"), "status-frappe-bench.json")));
        Assert.Empty(status.PendingOperations);
    }

    [Fact]
    public void AnUpdateThatStoppedIsReadWithItsStepsAndReason()
    {
        var status = BenchJson.ParseStatus(File.ReadAllText(Path.Combine(FixtureFiles.Dir("cli"), "status-pending-update.json")));
        var op = Assert.Single(status.PendingOperations);
        Assert.True(op.IsUpdate);
        Assert.Equal("acme_crm", op.App);
        Assert.Equal("main", op.Branch);
        Assert.Equal("migrate", op.FailedStep);
        Assert.Equal("bench --site macdev migrate failed with exit code 1 after 1s", op.Reason);
        Assert.Equal([("migrate", "macdev", "Migrate macdev"), ("build", "acme_crm", "Build")], op.Steps.Select(s => (s.Kind, s.Target, s.Name)));
        Assert.Equal(40, op.To!.Length);
        Assert.NotNull(op.From);
        Assert.Equal("app update of acme_crm did not finish: stopped at migrate (bench --site macdev migrate failed with exit code 1 after 1s); 2 step(s) left (migrate, build)", op.Message);
        Assert.Equal("benchbar app update acme_crm --bench-dir " + Bench, op.FixLine(Bench));
        Assert.Equal("benchbar app update acme_crm --discard-pending --bench-dir " + Bench, op.DiscardLine(Bench));
        Assert.Equal("Finish Update", op.ResumeLabel);
        Assert.True(op.CanResume);
    }

    [Fact]
    public void AnAddThatStoppedHasNoFromCommitAndAnEmptyTargetForTheRestart()
    {
        var status = BenchJson.ParseStatus(File.ReadAllText(Path.Combine(FixtureFiles.Dir("cli"), "status-pending-add.json")));
        var op = Assert.Single(status.PendingOperations);
        Assert.True(op.IsAdd);
        Assert.Null(op.From);
        Assert.Equal(["build", "install", "restart"], op.Steps.Select(s => s.Kind));
        Assert.Equal("", op.Steps[^1].Target);
        Assert.Equal("app add of acme_i1 did not finish: stopped at build (bench build --app acme_i1 failed with exit code 1 after 1s); 3 step(s) left (build, install, restart)", op.Message);
        Assert.Equal("benchbar app add acme_i1 --bench-dir " + Bench, op.FixLine(Bench));
        Assert.Equal("Finish Add", op.ResumeLabel);
    }

    [Fact]
    public void ARecordOfAnUnknownKindCanOnlyBeDiscarded()
    {
        var json = File.ReadAllText(Path.Combine(FixtureFiles.Dir("cli"), "status-pending-update.json")).Replace("\"op\":\"app_update\"", "\"op\":\"app_move\"");
        var op = Assert.Single(BenchJson.ParseStatus(json).PendingOperations);
        Assert.False(op.CanResume);
        Assert.Equal("app_move", op.Op);
    }

    [Fact]
    public void ARecordWithoutAnAppIsSkippedAndTheRestIsKept()
    {
        var json = File.ReadAllText(Path.Combine(FixtureFiles.Dir("cli"), "status-pending-update.json")).Replace("\"pending_operations\":[", "\"pending_operations\":[{\"op\":\"app_add\"},");
        var status = BenchJson.ParseStatus(json);
        Assert.Equal(["acme_crm"], status.PendingOperations.Select(o => o.App));
    }

    // --- the calls ---

    [Fact]
    public void TheDiscardCallIsTheCliFlagAndNothingElse()
    {
        Assert.Equal(["app", "update", "acme_crm", "--discard-pending", "--bench-dir", Bench], AppCommands.DiscardPending("acme_crm", Bench));
    }

    [Fact]
    public void ResumingAnAddIsTheSameCommandWithTheAppName()
    {
        Assert.Equal(["app", "add", "acme_i1", "--bench-dir", Bench], AppCommands.ResumeAdd("acme_i1", Bench));
    }

    [Fact]
    public void ThePlanOfAPendingUpdateHasNoTokenAndListsOnlyTheStepsLeft()
    {
        Assert.Equal(["app", "update", "acme_crm", "--dry-run", "--json", "--bench-dir", Bench], AppCommands.ResumeUpdatePlan("acme_crm", Bench));
        var doc = Cli("apps-update-pending-plan.json");
        var plan = AppJson.ParseUpdatePlan(doc);
        Assert.True(plan.HasPending);
        Assert.Equal(["Migrate macdev", "Build"], plan.Steps.Select(s => s.Name));
        var review = PlanDocument.FromJson(doc);
        Assert.Null(review.Token);
        Assert.True(review.CanApply);
        Assert.Equal(["Migrate macdev", "Build"], review.Steps.Select(s => s.Name));
    }
}
