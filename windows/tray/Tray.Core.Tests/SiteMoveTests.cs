using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>
/// Move to Another Bench in the tray (issue 183): <c>site move NAME --to-bench PATH [--no-migrate]</c>, its plan and apply as the CLI prints them
/// (the fixtures are the ones the Mac app reads), the gating of the menu entry, and the plan sheet's rules for it: the typed name, Stop Bench
/// for a running source, and a plan that went stale.
/// </summary>
public class SiteMoveTests
{
    private const string Src = "/Users/you/dev/move-src";
    private const string Tgt = "/Users/you/dev/move-tgt";
    private const string Site = "acme.localhost";

    private static SiteMoveRequest Request(bool noMigrate = false) => new(Site, Tgt, noMigrate, Src);

    private static (PlanReviewModel Model, ScriptedStreamRunner Runner, ScriptedReply Plan, ScriptedReply Apply) Make(
        string plan = "site-move-plan.json", string apply = "site-move-apply.jsonl", Func<Task<bool>>? stop = null, bool noMigrate = false)
    {
        var (client, runner) = CliFixture.Scripted();
        var planReply = runner.On(a => a.Contains("--dry-run")).Print(CliFixture.Lines(plan));
        var applyReply = runner.On(a => a.Contains("--apply")).Print(CliFixture.Lines(apply));
        return (new PlanReviewModel(SiteMoveCommands.Review(Request(noMigrate), stop ?? (() => Task.FromResult(true))), client), runner, planReply, applyReply);
    }

    // --- the plan ---

    [Fact]
    public void ThePlanIsReadFromTheCliDocument()
    {
        var doc = PlanDocument.FromJson(CliFixture.Doc("site-move-plan.json"));
        Assert.True(doc.CanApply);
        Assert.Equal(["backup", "restore", "migrate", "check", "drop"], doc.Steps.Select(s => s.Id));
        Assert.Equal(new string('a', 64), doc.Token);
        var plan = SiteMoveJson.Read(doc);
        Assert.Equal(Src, plan.Bench);
        Assert.Equal(Tgt, plan.ToBench);
        Assert.Equal(Site, plan.Site);
        Assert.Equal(["frappe", "erpnext"], plan.Apps);
        Assert.Empty(plan.MissingApps);
        Assert.True(plan.Migrate);
        Assert.Equal(2, plan.Stays.Count);
        Assert.Equal(new SiteMoveAddress("kept (same name)", "http://acme.localhost:8000", "http://acme.localhost:8001", true), plan.Address);
        Assert.Empty(plan.NextActions);
    }

    [Fact]
    public void ADocumentWithoutTheExtraFieldsStillReads()
    {
        var plan = SiteMoveJson.Read(PlanDocument.FromJson(new System.Text.Json.Nodes.JsonObject { ["site"] = Site }));
        Assert.Equal(Site, plan.Site);
        Assert.Empty(plan.Apps);
        Assert.Null(plan.Address);
        Assert.True(plan.Migrate); // the CLI migrates unless told not to
    }

    [Fact]
    public void TheReviewListsTheAppsTheNewAddressWhatStaysAndWhatIsLeftAlone()
    {
        var lines = SiteMoveText.Facts(SiteMoveJson.Read(PlanDocument.FromJson(CliFixture.Doc("site-move-plan.json"))));
        Assert.Contains(lines, l => l.StartsWith("From: " + Src));
        Assert.Contains(lines, l => l.StartsWith("To: " + Tgt));
        Assert.Contains("Apps: frappe, erpnext", lines);
        Assert.Contains(lines, l => l.Contains("http://acme.localhost:8000") && l.Contains("http://acme.localhost:8001") && l.Contains("name stays"));
        Assert.Contains(lines, l => l.StartsWith("Migrate: bench migrate runs"));
        Assert.Contains(lines, l => l.StartsWith("Stays: the backups of acme.localhost"));
        Assert.Contains(lines, l => l.StartsWith("Left alone:"));
    }

    [Fact]
    public void SkippingMigrateIsSaidInTheReviewAndSentToThePlanAndTheApply()
    {
        var plan = SiteMoveJson.Read(PlanDocument.FromJson(CliFixture.Doc("site-move-plan.json")));
        Assert.Contains(SiteMoveText.Facts(plan with { Migrate = false }), l => l.StartsWith("Migrate: Not run"));
        var request = SiteMoveCommands.Review(Request(noMigrate: true), () => Task.FromResult(true));
        Assert.Contains("--no-migrate", request.PlanArgs);
        Assert.Contains("--no-migrate", request.ApplyArgs(PlanDocument.FromJson(CliFixture.Doc("site-move-plan.json"))));
    }

    // --- argv ---

    [Fact]
    public void ThePlanAndTheApplyUseTheSameArgumentsAndThePlansOwnToken()
    {
        var request = SiteMoveCommands.Review(Request(), () => Task.FromResult(true));
        Assert.Equal(["site", "move", Site, "--to-bench", Tgt, "--bench-dir", Src, "--dry-run", "--json"], request.PlanArgs);
        var doc = PlanDocument.FromJson(CliFixture.Doc("site-move-plan.json"));
        Assert.Equal(["site", "move", Site, "--to-bench", Tgt, "--bench-dir", Src, "--apply", doc.Token!, "--yes", "--jsonl"], request.ApplyArgs(doc));
        Assert.Equal(["site", "move", Site, "--to-bench", Tgt, "--no-migrate", "--bench-dir", Src], Request(noMigrate: true).Base);
        Assert.False(request.CanStop); // a move is not safe to kill part way
        Assert.Equal("Move", request.ConfirmLabel);
    }

    [Fact]
    public void AMoveNeedsNoPersonModeBecauseTheCliHasNoAgentRefusalForIt()
    {
        var env = new SecretEnvironment();
        SiteMoveCommands.Review(Request(), () => Task.FromResult(true)).ConfigureEnv?.Invoke(env);
        Assert.DoesNotContain(SetupEnv.NonInteractive, env.Materialize().Keys);
    }

    // --- gating ---

    [Fact]
    public void TheEntryShowsOnlyWhenTheCliListsSiteMoveAndAnotherBenchIsRegistered()
    {
        var with = new CommandCatalogue([new CommandInfo("site move", "", "", true, [])], "0.9.0");
        var without = new CommandCatalogue([new CommandInfo("site drop", "", "", true, [])], "0.9.0");
        Assert.True(SiteMoveRules.Offered(with, 1));
        Assert.False(SiteMoveRules.Offered(with, 0));
        Assert.False(SiteMoveRules.Offered(without, 2));
        Assert.False(SiteMoveRules.Offered(null, 2));
    }

    [Fact]
    public void TheTargetsAreEveryOtherBenchAndTheDefaultSiteStaysPut()
    {
        BenchStatus Bench(string name, string path) => new(name, path, BenchState.Stopped, null, null, null);
        var all = new[] { Bench("src", Src), Bench("tgt", Tgt), Bench("third", "/x/third") };
        Assert.Equal(["tgt", "third"], SiteMoveRules.Targets(all, Src).Select(b => b.Name));
        var other = new SiteRowInfo(Site, false, null, true, false);
        var items = SiteMenu.For(other, false, move: true);
        Assert.True(items.Single(i => i.Action == SiteAction.Move).Enabled);
        Assert.Equal("Move to Another Bench...", items.Single(i => i.Action == SiteAction.Move).Label);
        Assert.False(SiteMenu.For(other with { IsDefault = true }, false, move: true).Single(i => i.Action == SiteAction.Move).Enabled);
        Assert.DoesNotContain(SiteMenu.For(other, false), i => i.Action == SiteAction.Move);
    }

    // --- the sheet's rules ---

    [Fact]
    public async Task MoveStaysOffUntilTheSiteNameIsTyped()
    {
        var (model, _, _, _) = Make();
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(Site, model.Request.ConfirmName);
        Assert.False(model.CanConfirm);
        model.Typed = "acme";
        Assert.False(model.CanConfirm);
        model.Typed = $" {Site} ";
        Assert.True(model.CanConfirm);
    }

    [Fact]
    public async Task APlanWithErrorsOrMissingAppsCannotBeMoved()
    {
        var (model, _, _, _) = Make("site-move-plan-errors.json");
        await model.LoadAsync(TestContext.Current.CancellationToken);
        model.Typed = Site;
        Assert.False(model.CanConfirm);
        Assert.Equal(2, model.Plan!.Errors.Count);
        Assert.Equal(["hrms"], SiteMoveJson.Read(model.Plan).MissingApps);
        Assert.Null(model.Blocker);
    }

    [Fact]
    public async Task ARunningSourceOffersStopBenchAndThenReadsTheNewPlan()
    {
        var stopped = 0;
        ScriptedReply? planReply = null;
        var (model, runner, plan, _) = Make("site-move-plan-running.json", stop: () =>
        {
            stopped++;
            planReply!.Lines.Clear();
            planReply.Print(CliFixture.Lines("site-move-plan.json"));
            return Task.FromResult(true);
        });
        planReply = plan;
        await model.LoadAsync(TestContext.Current.CancellationToken);
        model.Typed = Site;
        Assert.False(model.CanConfirm);
        Assert.Equal("Stop Bench", model.Blocker!.Label);
        Assert.True(SiteMoveRules.IsStop("benchbar down --bench-dir " + Src));
        Assert.False(SiteMoveRules.IsStop("benchbar up --bench-dir " + Src));

        await model.ResolveBlockerAsync(TestContext.Current.CancellationToken);
        Assert.Equal(1, stopped);
        Assert.Equal(2, runner.Runs.Count(r => r.Args.Contains("--dry-run"))); // it read the plan again
        Assert.Null(model.Blocker);
        Assert.False(model.CanConfirm); // the name is typed again for the plan that is shown now
        model.Typed = Site;
        Assert.True(model.CanConfirm);
    }

    [Fact]
    public async Task AStopThatFailsSaysSoAndKeepsTheBlockedPlan()
    {
        var (model, _, _, _) = Make("site-move-plan-running.json", stop: () => Task.FromResult(false));
        await model.LoadAsync(TestContext.Current.CancellationToken);
        await model.ResolveBlockerAsync(TestContext.Current.CancellationToken);
        Assert.Equal(PlanPhase.Review, model.Phase);
        Assert.Contains("did not stop", model.Message);
        Assert.NotNull(model.Blocker);
    }

    [Fact]
    public async Task TheStopRunsDownForThisBenchOnly()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("down").Print("{}");
        Assert.True(await SiteMoveCommands.StopBench(client, Src)); // the run carries no token to cancel
        Assert.Equal(["down", "--json", "--bench-dir", Src], runner.Runs.Single().Args);
    }

    // --- the apply ---

    [Fact]
    public async Task TheApplyRunsThePlansTokenAndShowsEachStepWithTheNewAddressAtTheEnd()
    {
        var (model, runner, _, _) = Make();
        await model.LoadAsync(TestContext.Current.CancellationToken);
        model.Typed = Site;
        await model.ConfirmAsync();
        Assert.Equal(["--apply", new string('a', 64), "--yes", "--jsonl"], runner.Runs[1].Args.Skip(runner.Runs[1].Args.Length - 4));
        Assert.Equal(PlanPhase.Finished, model.Phase);
        Assert.True(model.Outcome.Applied);
        var steps = model.Steps;
        Assert.Equal(5, steps.Count);
        Assert.Equal(InstallStepStatus.Done, steps.Single(s => s.Id == "backup").Status);
        Assert.Equal(InstallStepStatus.Done, steps.Single(s => s.Id == "drop").Status);
        var next = Assert.Single(model.Result!.NextActions);
        Assert.Equal("benchbar up --bench-dir " + Tgt, next.Command);
        Assert.Contains("8001", next.Why);
    }

    [Fact]
    public async Task ASubStepOfRestoreSharesItsIdButNeverChangesTheRestoreRow()
    {
        var parsed = CliJson.ParseLine(CliFixture.Lines("site-move-apply.jsonl").First(l => l.Contains("\"parent\"")));
        var sub = Assert.IsType<CliEvent.Step>(parsed).Value;
        Assert.Equal("restore", sub.Id);
        Assert.Equal("restore", sub.Parent);
        var (model, _, _, _) = Make();
        await model.LoadAsync(TestContext.Current.CancellationToken);
        model.Typed = Site;
        await model.ConfirmAsync();
        var restore = model.Steps.Single(s => s.Id == "restore");
        Assert.Equal("Create acme.localhost in /Users/you/dev/move-tgt and restore that backup into it (new-site, restore, encryption key)", restore.Name);
        Assert.Null(restore.Message); // the sub step's "new-site done" is not the restore's
        Assert.Equal(5, model.Steps.Count);
    }

    [Fact]
    public async Task APlanThatChangedSinceItWasShownIsStaleAndAsksToBeReviewedAgain()
    {
        var (model, _, plan, apply) = Make(apply: "site-move-apply-stale.jsonl");
        apply.Fail(1);
        Assert.True(PlanStale.Looks("The site move plan changed since it was shown (the sites, the default sites, the apps or a lease). Nothing was changed."));
        await model.LoadAsync(TestContext.Current.CancellationToken);
        model.Typed = Site;
        await model.ConfirmAsync();
        Assert.Equal(PlanPhase.Stale, model.Phase);
        Assert.Equal("Review Again", model.Request.RefreshLabel);
        Assert.False(model.Outcome.Applied);
        plan.Lines.Clear();
        plan.Print(CliFixture.Lines("site-move-plan.json"));
        await model.RefreshPlanAsync(TestContext.Current.CancellationToken);
        Assert.Equal(PlanPhase.Review, model.Phase);
        Assert.False(model.CanConfirm); // the name has to be typed again for the new plan
    }
}
