using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>
/// Tray parity, part 2 (issue 187): the 0.9.0 notices and the <c>ready</c> object of <c>status --json</c>, and <c>pull</c> with a reviewed
/// plan. The fixtures are the CLI's documents (the status ones derive from tests/record-tray-fixtures.sh's recorded status).
/// </summary>
public class Parity187bTests
{
    private const string Bench = "/home/akash/frappe-bench";

    private static BenchStatus Status(string fixture) => BenchJson.ParseStatus(string.Join('\n', CliFixture.Lines(fixture)));

    // --- row 1: notices ---

    [Fact]
    public void TheNoticesOfAStatusAreRead()
    {
        var bench = Status("status-notices.json");
        Assert.Equal(["listen-local", "unknown-flags", "pull-neutralise"], bench.Notices.Select(n => n.Id));
        var first = bench.Notices[0];
        Assert.Equal("The bench now listens on this computer only", first.Title);
        Assert.Contains("127.0.0.1", first.Text);
        Assert.Equal("benchbar listen all", first.SwitchBack);
        Assert.Equal("0.9.0", first.Since);
        Assert.Equal("https://benchbar.akashmishra.com/whats-new/#the-bench-listens-on-this-computer-only", first.SafeDoc);
        Assert.Equal("benchbar pull --keep-secrets", bench.Notices[2].SwitchBack);
    }

    [Fact]
    public void AnOlderCliWithoutTheMembersGivesNoNoticesAndNoReadiness()
    {
        var bench = Status("status-pending-add.json"); // recorded from a 0.8 CLI: no notices, no ready
        Assert.Empty(bench.Notices);
        Assert.Null(bench.Ready);
        Assert.Null(ReadinessText.Headline(bench));
        Assert.Empty(ReadinessText.Detail(bench));
    }

    [Fact]
    public void AMemberOfTheWrongShapeIsAbsentAndDoesNotFailTheStatus()
    {
        var doc = CliFixture.Doc("status-ready.json");
        doc["ready"] = "yes";
        doc["notices"] = new JsonObject { ["id"] = "x" };
        var json = doc.ToJsonString();
        var bench = BenchJson.ParseStatus(json);
        Assert.Null(bench.Ready);
        Assert.Empty(bench.Notices);
        Assert.Equal(BenchState.Running, bench.State);
    }

    [Fact]
    public void ANoticeWithoutAnIdIsSkippedAndAMissingTitleFallsBackToTheId()
    {
        var notices = StatusExtras.ParseNotices(JsonNode.Parse("""[{"title":"no id"},{"id":"a"},{"id":"b","title":"B","text":"t","doc":"javascript:alert(1)"},{"id":"c","doc":"http://plain.example/"}]"""));
        Assert.Equal(["a", "b", "c"], notices.Select(n => n.Id));
        Assert.Equal("a", notices[0].Title);
        Assert.Null(notices[1].SafeDoc); // a link the system would run is never opened
        Assert.Null(notices[2].SafeDoc); // plain http is not opened either
    }

    [Fact]
    public void DismissRunsTheNoticesCommandWithTheId()
    {
        Assert.Equal(["notices", "--dismiss", "listen-local"], NoticeCommands.Dismiss("listen-local"));
    }

    // --- row 2: readiness ---

    [Fact]
    public void ReadyIsReadWithEveryPart()
    {
        var ready = Status("status-ready.json").Ready!;
        Assert.True(ready.Ready);
        Assert.True(ready.Deep);
        Assert.True(ready.Web);
        Assert.False(ready.Stale);
        Assert.Empty(ready.WaitingOn);
        Assert.Null(ready.Fix);
        Assert.Equal("Ready", ReadinessText.Headline(Status("status-ready.json")));
        Assert.Empty(ReadinessText.Detail(Status("status-ready.json")));
    }

    [Fact]
    public void StaleCodeSaysNeedsRestartWithTheFileAndTheFix()
    {
        var bench = Status("status-ready-stale.json");
        Assert.Equal("Needs restart (code changed)", ReadinessText.Headline(bench));
        Assert.Equal("apps/erpnext/erpnext/hooks.py", bench.Ready!.StaleFile);
        Assert.Equal("benchbar restart --bench-dir " + Bench, bench.Ready.Fix);
        Assert.Equal(["Waiting on a restart (Python code changed).", "apps/erpnext/erpnext/hooks.py changed after the bench started."], ReadinessText.Detail(bench));
    }

    [Fact]
    public void NotReadySaysWhatItWaitsOnAndAnUnaskedPartIsNotAFailure()
    {
        var bench = Status("status-not-ready.json");
        Assert.Equal("Running, not ready", ReadinessText.Headline(bench));
        Assert.Null(bench.Ready!.Workers); // not asked without --deep: unknown, never "missing"
        Assert.Null(bench.Ready.Stale);
        Assert.Equal(["Waiting on the realtime server (socketio)."], ReadinessText.Detail(bench));
        Assert.Equal("benchbar logs --bench-dir " + Bench, bench.Ready.Fix);
    }

    [Fact]
    public void ReadinessIsOnlyShownForABenchThatRuns()
    {
        var running = Status("status-not-ready.json");
        var stopped = running with { State = BenchState.Stopped };
        Assert.Null(ReadinessText.Headline(stopped));
        Assert.Empty(ReadinessText.Detail(stopped));
        Assert.Equal("a part this build does not know", ReadinessText.Part("a part this build does not know"));
    }

    // --- row 3: pull ---

    private static PullInput Input(bool keep = false, bool folder = false) =>
        new(folder ? "/home/akash/backup" : "prod:erp.example.com", folder, "erpcopy.localhost", keep);

    [Fact]
    public void PullBuildsItsArgumentsAndKeepSecretsIsOnlyThereWhenChosen()
    {
        Assert.Equal(["pull", "prod:erp.example.com", "--as", "erpcopy.localhost", "--bench-dir", Bench], PullCommands.Base(Input(), Bench));
        Assert.Equal(["pull", "prod:erp.example.com", "--as", "erpcopy.localhost", "--keep-secrets", "--bench-dir", Bench], PullCommands.Base(Input(keep: true), Bench));
        Assert.Equal(["pull", "--from-dir", "/home/akash/backup", "--as", "erpcopy.localhost", "--bench-dir", Bench], PullCommands.Base(Input(folder: true), Bench));
        Assert.False(new PullInput("prod:a", false, "a.local", false).KeepSecrets); // the default of the form is off
    }

    [Theory]
    [InlineData("prod:erp.example.com", true)]
    [InlineData("my_host-1:site.name", true)]
    [InlineData("prod", false)]
    [InlineData(":erp", false)]
    [InlineData("prod:", false)]
    [InlineData("a:b:c", false)]
    [InlineData("prod:erp example", false)]
    [InlineData("prod:erp;rm", false)]
    [InlineData("-oProxy:x", false)] // a host that starts with a dash would be an option of ssh
    [InlineData("", false)]
    public void TheServerMustBeHostColonSite(string text, bool valid) => Assert.Equal(valid, PullCommands.IsValidSsh(text));

    [Fact]
    public void TheNameFollowsTheSiteAndAFormProblemIsSaidBeforeAnyPlan()
    {
        Assert.Equal("erp.example.com.local", PullCommands.DefaultName("prod:ERP.example.com"));
        Assert.Equal("", PullCommands.DefaultName("prod"));
        Assert.Null(PullCommands.Problem(Input(), ["one.localhost"]));
        Assert.Contains("already a site", PullCommands.Problem(Input(), ["erpcopy.localhost"]));
        Assert.Equal(SiteNames.Rule, PullCommands.Problem(Input() with { Name = "Bad Name" }, []));
        Assert.Contains("HOST:SITE", PullCommands.Problem(Input() with { Source = "prod" }, []));
        Assert.Contains("inside Ubuntu", PullCommands.Problem(Input(folder: true) with { Source = "C:\\Users\\me\\backup" }, []));
        Assert.Null(PullCommands.Problem(Input(folder: true), []));
    }

    private static (PlanReviewModel Model, ScriptedStreamRunner Runner) MakePull(string plan = "pull-plan.jsonl", string apply = "pull-apply.jsonl", bool keep = false)
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On(a => a.Contains("--dry-run")).Print(CliFixture.Lines(plan));
        runner.On(a => a.Contains("--apply")).Print(CliFixture.Lines(apply));
        return (new PlanReviewModel(PullCommands.Review(Input(keep), Bench), client), runner);
    }

    [Fact]
    public async Task ThePlanIsReadWithDryRunAndAppliedByItsOwnToken()
    {
        var (model, runner) = MakePull();
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(PlanPhase.Review, model.Phase);
        Assert.True(model.CanConfirm);
        Assert.Equal("0ae11fd8a7dd70b49af83085424cbdf431c4237d2da52d31abdd9ea35b2eeceb", model.Plan!.Token);
        Assert.Equal("Download the backup", model.Plan.Steps[0].Name);
        Assert.Contains("Create the site erpcopy.localhost (bench new-site)", model.Plan.Steps.Select(s => s.Name));
        Assert.Contains("Neutralise the copy: integrations off, stored secrets cleared", model.Plan.Steps.Select(s => s.Name));
        Assert.Matches("^[0-9a-f]{64}$", model.Plan.Token!);
        Assert.Equal(["pull", "prod:erp.example.com", "--as", "erpcopy.localhost", "--bench-dir", Bench, "--dry-run", "--json"], runner.Runs[0].Args);

        await model.ConfirmAsync();
        Assert.Equal(PlanPhase.Finished, model.Phase);
        Assert.True(model.Outcome.Applied);
        Assert.Equal(["pull", "prod:erp.example.com", "--as", "erpcopy.localhost", "--bench-dir", Bench, "--apply", "0ae11fd8a7dd70b49af83085424cbdf431c4237d2da52d31abdd9ea35b2eeceb", "--yes", "--jsonl"], runner.Runs[1].Args);
        Assert.DoesNotContain("--keep-secrets", runner.Runs[1].Args);
        Assert.False(model.Request.CanStop); // a restore is not killed part way
    }

    [Fact]
    public async Task ThePlanSheetDescribesTheBackupTheAppsAndWhatTheCopyLoses()
    {
        var (model, _) = MakePull();
        await model.LoadAsync(TestContext.Current.CancellationToken);
        var lines = model.Request.Describe!(model.Plan!);
        Assert.Contains("Backup: 20260925_020000-erp_example_com-database.sql.gz, 8.1 KB, 55 days old", lines);
        Assert.Contains("Local site: erpcopy.localhost is created on this bench.", lines);
        Assert.Contains("The copy: " + PullCommands.NeutralisedText, lines);
        Assert.Contains("App that differs: frappe: 15.41.0 here, 15.40.0 on production (local newer)", lines);
        Assert.Contains("App that differs: erpnext: 15.30.0 here, 15.30.0 on production (branch differs)", lines);
        Assert.DoesNotContain(lines, l => l.Contains("hrms")); // a skipped app is not worth a line
        Assert.DoesNotContain(lines, l => l.StartsWith("Warning", StringComparison.Ordinal));
    }

    [Fact]
    public async Task KeepingSecretsIsAFlagInBothCallsAndTheSheetWarnsAboutIt()
    {
        var (model, runner) = MakePull("pull-plan-keep.jsonl", keep: true);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Contains("--keep-secrets", runner.Runs[0].Args);
        Assert.DoesNotContain(model.Plan!.Steps, s => s.Id.StartsWith("Neutralise", StringComparison.Ordinal)); // the CLI leaves the step out
        Assert.Equal("9c36a3b81ade9add42016679ef9a88612cd441084483b90ed8e066c2e0c33e0f", model.Plan!.Token);
        var lines = model.Request.Describe!(model.Plan);
        Assert.StartsWith("Warning: the copy keeps production's secrets", lines[0]);
        Assert.Contains("The copy: " + PullCommands.KeptText, lines);
        await model.ConfirmAsync();
        Assert.Contains("--keep-secrets", runner.Runs[1].Args);
    }

    [Fact]
    public async Task APlanWithoutAFieldReadsAsNotNeutralisedAndAPlanWithoutATokenCannotBeRun()
    {
        var (client, runner) = CliFixture.Scripted();
        var old = string.Join('\n', CliFixture.Lines("pull-plan.jsonl")).Replace("\"neutralise\":true,", "");
        old = System.Text.RegularExpressions.Regex.Replace(old, ",\"token\":\"[0-9a-f]{64}\"", "");
        runner.On("pull").Print(old.Split('\n'));
        var model = new PlanReviewModel(PullCommands.Review(Input(), Bench), client);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.False(model.CanConfirm); // no token: nothing is run that was not reviewed
        var lines = model.Request.Describe!(model.Plan!);
        Assert.StartsWith("Warning: the copy keeps production's secrets", lines[0]); // absent counts as not neutralised, never as neutralised
        Assert.Contains(lines, l => l.Contains("does not give a plan token"));
    }

    [Fact]
    public async Task APlanTheCliRefusedAsChangedAsksForAFreshPlan()
    {
        var (model, runner) = MakePull(apply: "pull-apply-stale.jsonl");
        await model.LoadAsync(TestContext.Current.CancellationToken);
        await model.ConfirmAsync();
        Assert.Equal(PlanPhase.Stale, model.Phase);
        Assert.Contains("The plan changed since it was shown", model.Message);
        runner.On(a => a.Contains("--dry-run")).Print(CliFixture.Lines("pull-plan.jsonl"));
        await model.RefreshPlanAsync(TestContext.Current.CancellationToken);
        Assert.Equal(PlanPhase.Review, model.Phase);
    }

    [Fact]
    public void AnExpiredTokenIsAlsoAStalePlan()
    {
        Assert.True(PlanStale.Looks("The plan token expired: a token is good for about an hour after its plan was made, and this one is older. Nothing was changed."));
        Assert.False(PlanStale.Looks("The plan token is fine."));
    }

    [Fact]
    public async Task ThePullStreamShowsStepsAndTheDownloadAsItGoes()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("pull").Print(CliFixture.Lines("pull-apply.jsonl"));
        var steps = new List<CliStep>();
        var labels = new List<string>();
        var result = await client.RunStreamAsync(["pull", "x", "--apply", "t", "--yes", "--jsonl"], null, TimeSpan.FromSeconds(5),
            e =>
            {
                if (e is CliEvent.Step s) steps.Add(s.Value);
                if (e is CliEvent.Progress p) labels.Add(p.Label);
            }, TestContext.Current.CancellationToken);
        Assert.True(result.Ok);
        Assert.Equal(["Downloaded 4.0 KB of 8.1 KB"], labels);
        Assert.Equal(["download", "download", "new_site", "restore", "encryption_key", "dev_safety", "neutralise", "skip_apps", "migrate", "clear_cache", "admin_password", "hosts", "cleanup", "verify"], steps.Select(s => s.Id));
        Assert.Equal("erpcopy.localhost", result.Done!.Raw["site"]!.GetValue<string>());
    }

    [Fact]
    public async Task ARootPasswordRefusalGetsTheAdviceOnTheResult()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On(a => a.Contains("--dry-run")).Print(CliFixture.Lines("pull-plan.jsonl"));
        runner.On(a => a.Contains("--apply")).Print("""{"schema_version":1,"event":"done","exit":2,"error":"MariaDB has a root password benchbar does not know.","warnings":[]}""").Fail(2);
        var model = new PlanReviewModel(PullCommands.Review(Input(), Bench), client);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        await model.ConfirmAsync();
        Assert.Equal(PlanPhase.Finished, model.Phase);
        Assert.False(model.Outcome.Applied);
        Assert.Contains("MARIADB_ROOT_PASSWORD", model.Result!.Error);
    }

    // --- row 5: the MCP entry ---

    [Fact]
    public void TheJsonEntryIsAStdioServerThatRunsBenchbarExeWithMcp()
    {
        var o = JsonNode.Parse(WizardModel.McpJson)!.AsObject();
        var server = o["mcpServers"]!["benchbar"]!.AsObject();
        Assert.Equal("benchbar.exe", server["command"]!.GetValue<string>());
        Assert.Equal(["mcp"], server["args"]!.AsArray().Select(a => a!.GetValue<string>()));
        Assert.Equal("claude mcp add benchbar -- benchbar.exe mcp", WizardModel.McpLine);
    }
}
