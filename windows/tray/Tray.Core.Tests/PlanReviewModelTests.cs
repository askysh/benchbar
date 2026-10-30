using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

public class PlanReviewModelTests
{
    private static readonly string[] Base = ["site", "add", "qa1.localhost", "--bench-dir", "/b"];

    private static (PlanReviewModel Model, ScriptedStreamRunner Runner, ScriptedReply Plan, ScriptedReply Apply) Make(
        Func<PlanReviewRequest, PlanReviewRequest>? tune = null, string plan = "site-add-plan.json", string apply = "site-add-apply.jsonl")
    {
        var (client, runner) = CliFixture.Scripted();
        var planReply = runner.On(a => a.Contains("--dry-run")).Print(CliFixture.Lines(plan));
        var applyReply = runner.On(a => a.Contains("--apply")).Print(CliFixture.Lines(apply));
        var request = PlanReviewRequest.Tokened("Add qa1.localhost", Base) with { ConfirmLabel = "Add Site" };
        if (tune is not null) request = tune(request);
        return (new PlanReviewModel(request, client), runner, planReply, applyReply);
    }

    [Fact]
    public async Task ThePlanLoadsAndOffersConfirm()
    {
        var (model, runner, _, _) = Make();
        Assert.Equal(PlanPhase.Loading, model.Phase);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(PlanPhase.Review, model.Phase);
        Assert.True(model.CanConfirm);
        Assert.Equal(2, model.Plan!.Steps.Count);
        Assert.Equal(["database", "site_folder"], model.Plan.Touches);
        Assert.Equal([.. Base, "--dry-run", "--json"], runner.Runs[0].Args);
    }

    [Fact]
    public async Task APlanThatFailsToReadOffersARefresh()
    {
        var (client, runner) = CliFixture.Scripted();
        var reply = runner.On("site").Fail(1, "Cannot reach the distro.");
        var model = new PlanReviewModel(PlanReviewRequest.Tokened("Add", Base), client);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(PlanPhase.PlanFailed, model.Phase);
        Assert.Equal("Cannot reach the distro.", model.Message);
        Assert.False(model.CanConfirm);
        reply.Print(CliFixture.Lines("site-add-plan.json")).Fail(0);
        await model.RefreshPlanAsync(TestContext.Current.CancellationToken);
        Assert.Equal(PlanPhase.Review, model.Phase);
    }

    [Fact]
    public async Task APlanWithErrorsOrNothingToDoCannotBeConfirmed()
    {
        var (blocked, _, _, _) = Make(plan: "site-add-plan-blocked.json");
        await blocked.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(PlanPhase.Review, blocked.Phase);
        Assert.False(blocked.CanConfirm);
        Assert.Equal("MariaDB is not running.", blocked.Message);

        var (empty, _, _, _) = Make(plan: "plan-no-changes.json");
        await empty.LoadAsync(TestContext.Current.CancellationToken);
        Assert.False(empty.CanConfirm);
    }

    [Fact]
    public async Task ConfirmRunsTheApplyWithTheTokenAndShowsTheResult()
    {
        var (model, runner, _, _) = Make();
        await model.LoadAsync(TestContext.Current.CancellationToken);
        var phases = new List<PlanPhase>();
        model.Changed += () => phases.Add(model.Phase);
        await model.ConfirmAsync();

        Assert.Equal([.. Base, "--apply", model.Plan!.Token!, "--yes", "--jsonl"], runner.Runs[1].Args);
        Assert.Contains(PlanPhase.Running, phases);
        Assert.Equal(PlanPhase.Finished, model.Phase);
        Assert.True(model.Outcome.Applied);
        var result = model.Result!;
        Assert.True(result.Ok);
        Assert.Equal("Done", result.Headline);
        Assert.Equal(["site", "app"], result.Changed.Select(c => c.Kind));
        Assert.Single(result.Warnings);
        Assert.Equal("benchbar site default qa1.localhost", result.NextActions.Single().Command);
        Assert.Equal([InstallStepStatus.Done, InstallStepStatus.Done], model.Steps.Select(s => s.Status));
        Assert.True(model.IsDismissible);
    }

    [Fact]
    public async Task AFailedApplyShowsTheErrorAndWhatWasMissing()
    {
        var (model, _, _, apply) = Make(apply: "refusal.jsonl");
        apply.Fail(1);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        await model.ConfirmAsync();
        Assert.Equal(PlanPhase.Finished, model.Phase);
        Assert.False(model.Outcome.Applied);
        Assert.Equal("It did not finish", model.Result!.Headline);
        Assert.Equal("Missing inputs for the non interactive mode.", model.Result.Error);
        Assert.Equal(["ADMIN_PASSWORD", "--yes"], model.Result.Missing);
    }

    [Fact]
    public async Task ASudoPlanAsksForThePasswordAndPassesItOnlyInTheEnvironment()
    {
        var (model, runner, _, _) = Make(r => r with { UsesSudoEnv = true }, plan: "service-plan.jsonl");
        LinuxPasswordRequest? asked = null;
        model.AskLinuxPassword = request =>
        {
            asked = request;
            return Task.FromResult<Secret?>(Secret.From("s3cret-pw"));
        };
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.True(model.AsksPassword);
        await model.ConfirmAsync();

        Assert.Equal(1, asked!.SudoSteps);
        Assert.False(asked.WasWrong);
        var run = runner.Runs[1];
        Assert.Equal("env", run.Env["BENCHBAR_SUDO"]);
        Assert.Equal("s3cret-pw", run.Env["BENCHBAR_SUDO_PASSWORD"]);
        Assert.DoesNotContain(run.Args, a => a.Contains("s3cret"));
        Assert.DoesNotContain("BENCHBAR_SUDO_PASSWORD", runner.Runs[0].Env.Keys);
    }

    [Fact]
    public async Task CancellingThePasswordPromptKeepsThePlanAndRunsNothing()
    {
        var (model, runner, _, _) = Make(r => r with { UsesSudoEnv = true }, plan: "service-plan.jsonl");
        await model.LoadAsync(TestContext.Current.CancellationToken);
        await model.ConfirmAsync(); // the default prompt answers null
        Assert.Equal(PlanPhase.Review, model.Phase);
        Assert.Single(runner.Runs);
    }

    [Fact]
    public async Task AWrongPasswordGoesBackToReviewAndTheNextPromptSaysSo()
    {
        var (model, _, _, apply) = Make(r => r with { UsesSudoEnv = true }, plan: "service-plan.jsonl", apply: "sudo-wrong.jsonl");
        apply.Fail(1);
        var asks = new List<bool>();
        model.AskLinuxPassword = request =>
        {
            asks.Add(request.WasWrong);
            return Task.FromResult<Secret?>(Secret.From("nope-nope"));
        };
        await model.LoadAsync(TestContext.Current.CancellationToken);
        await model.ConfirmAsync();
        Assert.Equal(PlanPhase.Review, model.Phase);
        Assert.True(model.PasswordWasWrong);
        Assert.Contains("did not accept", model.Message);
        await model.ConfirmAsync();
        Assert.Equal([false, true], asks);
    }

    [Fact]
    public async Task AStaleTokenOffersARefreshThatReadsANewPlan()
    {
        var (model, runner, plan, apply) = Make(apply: "site-add-stale.jsonl");
        apply.Fail(1);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        await model.ConfirmAsync();
        Assert.Equal(PlanPhase.Stale, model.Phase);
        Assert.Contains("changed since", model.Message);
        Assert.False(model.Outcome.Applied);

        await model.RefreshPlanAsync(TestContext.Current.CancellationToken);
        Assert.Equal(PlanPhase.Review, model.Phase);
        Assert.Equal(3, runner.Runs.Count);
        Assert.Contains("--dry-run", runner.Runs[2].Args);
    }

    [Fact]
    public async Task StopCancelsARunWhenTheRequestAllowsIt()
    {
        var (model, _, _, apply) = Make(r => r with { CanStop = true });
        apply.Hold();
        await model.LoadAsync(TestContext.Current.CancellationToken);
        var run = model.ConfirmAsync();
        await apply.Started.Task;
        Assert.Equal(PlanPhase.Running, model.Phase);
        Assert.False(model.IsDismissible);
        Assert.True(model.CanStop);
        model.Stop();
        await run;
        Assert.Equal(PlanPhase.Finished, model.Phase);
        Assert.True(model.Result!.Cancelled);
        Assert.Equal("Stopped", model.Result.Headline);
        Assert.False(model.Outcome.Applied);
        Assert.True(model.IsDismissible);
    }

    [Fact]
    public async Task ARunThatIsNotSafeToKillOffersNoStopAndIgnoresIt()
    {
        var (model, _, _, apply) = Make();
        apply.Hold();
        await model.LoadAsync(TestContext.Current.CancellationToken);
        var run = model.ConfirmAsync();
        await apply.Started.Task;
        Assert.False(model.CanStop);
        model.Stop();
        Assert.Equal(PlanPhase.Running, model.Phase);
        Assert.False(model.IsDismissible);
        apply.Release();
        await run;
        Assert.Equal(PlanPhase.Finished, model.Phase);
    }
}

public class GuidanceAndConfirmTests
{
    [Fact]
    public void TheTypedNameMustMatchExactly()
    {
        Assert.True(TypedConfirm.Matches("qa1.localhost", "qa1.localhost"));
        Assert.True(TypedConfirm.Matches("qa1.localhost", "  qa1.localhost "));
        Assert.False(TypedConfirm.Matches("qa1.localhost", "QA1.localhost"));
        Assert.False(TypedConfirm.Matches("qa1.localhost", "qa1"));
        Assert.False(TypedConfirm.Matches("qa1.localhost", null));
        Assert.False(TypedConfirm.Matches("", ""));
    }

    [Theory]
    [InlineData(BenchState.Running, null, null)]
    [InlineData(BenchState.Unknown, null, null)]
    [InlineData(BenchState.Stopped, "manual", GuidanceAction.Start)]
    [InlineData(BenchState.Stopped, null, GuidanceAction.Start)]
    [InlineData(BenchState.Stopped, "broken", GuidanceAction.Repair)]
    [InlineData(BenchState.Stopped, "port_conflict", GuidanceAction.ReviewPortConflict)]
    [InlineData(BenchState.Crashed, null, GuidanceAction.ViewHealth)]
    [InlineData(BenchState.Paused, "broken", GuidanceAction.Repair)]
    [InlineData(BenchState.Paused, null, GuidanceAction.ViewHealth)]
    public void TheGuidanceFollowsTheStateAndTheStopReason(BenchState state, string? reason, GuidanceAction? action)
    {
        var g = BenchGuidance.Make(state, reason);
        Assert.Equal(action, g?.Action);
        Assert.Equal(action is null, g is null);
    }

    [Fact]
    public void ManagementAndPortConflictsComeFirstAndAPendingActionSaysNothing()
    {
        Assert.Equal(GuidanceAction.SetUpManagement, BenchGuidance.Make(BenchState.Stopped, "manual", needsService: true)!.Action);
        Assert.Equal(GuidanceAction.ReviewPortConflict, BenchGuidance.Make(BenchState.Running, null, portConflict: true)!.Action);
        Assert.Null(BenchGuidance.Make(BenchState.Stopped, "manual", needsService: true, pending: true));
    }

    [Fact]
    public void WithoutDropsTheActionAButtonAlreadyOffers()
    {
        var g = BenchGuidance.Make(BenchState.Stopped, "manual")!;
        Assert.Null(g.Without(GuidanceAction.Start).Action);
        Assert.Equal("You stopped it.", g.Without(GuidanceAction.Start).Reason);
        Assert.Equal(GuidanceAction.Start, g.Without(GuidanceAction.Repair).Action);
        Assert.Equal("Start", g.ActionTitle);
    }

    [Fact]
    public void ASiteRowOpensTheSitesTabAndABenchRowTheOverview()
    {
        var site = new SidebarItem(SidebarKind.Site, "k", "a.localhost", "", BenchState.Running, "/b", null, false);
        var bench = site with { Kind = SidebarKind.Bench };
        Assert.Equal(BenchTab.Sites, BenchNavigation.TabFor(site));
        Assert.Equal(BenchTab.Overview, BenchNavigation.TabFor(bench));
        Assert.Equal(["Overview", "Sites", "Apps", "Health"], BenchTabs.All.Select(BenchTabs.Label));
        Assert.Equal(["Find Benches", "Team Profiles"], SidebarTools.All.Select(SidebarTools.Title));
    }
}
