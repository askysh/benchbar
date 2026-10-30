using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using Xunit;
using static Tray.Core.Tests.CliFixture;

namespace Tray.Core.Tests;

/// <summary>Port parsers, the exact arguments, the refusal on a conflict, and the setup model (plan, mode, apply, resolve and start).</summary>
public class PortsTests
{
    private const string B1 = "/home/akash/b1";


    private static PortSetupModel Model(ICliClient client, bool start = false, bool settings = false) =>
        new(client, [new PortBench(B1, "b1")], start, settings);

    // --- parsers ---

    [Fact]
    public void TheCheckReadsConflictsModeAndWhetherTheBenchRuns()
    {
        var clean = PortsJson.ParseCheck(Doc("ports-check-clean.json"));
        Assert.Empty(clean.Conflicts);
        Assert.Equal(PortMode.Automatic, clean.Mode);
        Assert.False(clean.AlreadyRunning);
        var conflict = PortsJson.ParseCheck(Doc("ports-check-conflict.json"));
        Assert.Equal(2, conflict.Conflicts.Count);
        Assert.Equal(PortMode.Fixed, conflict.Mode);
        Assert.Null(PortsJson.ParseCheck(new JsonObject { ["conflicts"] = new JsonArray() }).AlreadyRunning);
        Assert.Throws<FormatException>(() => PortsJson.ParseCheck(new JsonObject()));
    }

    [Fact]
    public void ThePlanReadsEntriesPortsAndWhatNeedsSetup()
    {
        var plan = PortsJson.ParsePlan(Doc("ports-plan.json"));
        Assert.Equal("cccc3333", plan.Token);
        Assert.True(plan.CanApply);
        var e = plan.Entries.Single();
        Assert.Equal(("/home/akash/b1", "b1", "b1.localhost", PortMode.Automatic), (e.Path, e.Name, e.Site, e.Mode));
        Assert.Equal(new BenchPorts(8000, 9000, 11000, 13000), e.Current);
        Assert.Equal(new BenchPorts(8001, 9001, 11001, 13001), e.Proposed);
        Assert.Equal("http://b1.localhost:8000", e.CurrentUrl);
        Assert.Equal("http://b1.localhost:8001", e.ProposedUrl);
        Assert.True(e.ChangesPorts);
        Assert.True(e.NeedsSetup);
        Assert.Null(e.Blocked);
        Assert.Contains("Rewrite the systemd unit", e.SetupPlan);

        var calm = PortsJson.ParsePlan(Doc("ports-plan-calm.json")).Entries.Single();
        Assert.Equal(PortMode.Fixed, calm.Mode);
        Assert.False(calm.ChangesPorts);
        Assert.False(calm.NeedsSetup);
        var blocked = PortsJson.ParsePlan(Doc("ports-plan-blocked.json"));
        Assert.False(blocked.CanApply);
        Assert.Equal("It is running; stop it first.", blocked.Entries[0].Blocked);
        Assert.Throws<FormatException>(() => PortsJson.ParsePlan(new JsonObject()));
    }

    [Fact]
    public void ThePortCallsUseTheDocumentedArguments()
    {
        Assert.Equal(["ports", "check", "--json", "--bench-dir", B1], PortArgs.Check(B1));
        Assert.Equal(["ports", "mode", "fixed", "--bench-dir", B1], PortArgs.Mode(PortMode.Fixed, B1));
        Assert.Equal(["ports", "mode", "automatic", "--bench-dir", B1], PortArgs.Mode(PortMode.Automatic, B1));
        Assert.Equal(["ports", "plan", "--json", "--", B1, "/home/akash/b2"], PortArgs.Plan([B1, "/home/akash/b2"]));
        Assert.Equal(["ports", "apply", "cccc3333", "--yes", "--", B1], PortArgs.Apply("cccc3333", [B1]));
        Assert.Equal(["up", "--bench-dir", B1], PortArgs.Start(B1));
        Assert.Equal(("Fixed", "Automatic"), (PortModes.Title(PortMode.Fixed), PortModes.Title(PortMode.Automatic)));
    }

    [Fact]
    public void TheHintsReadTheFailuresOfTheOutput()
    {
        Assert.Equal("[FAIL] two" + Environment.NewLine + "[FAIL] three" + Environment.NewLine + "[FAIL] four",
            PortSetupHints.Failures(["Applying", "[FAIL] one", " [FAIL] two", "[FAIL] three", "[FAIL] four"]));
        Assert.Null(PortSetupHints.Failures(["Completed"]));
    }

    // --- the refusal on a conflict ---

    [Fact]
    public async Task AStartWithNoConflictIsAllowedAfterOneCheck()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("ports", "check").Print(CliFixture.Lines("ports-check-clean.json"));
        var guard = await PortGuard.CheckAsync(client, B1, PortGuardAction.Start, TestContext.Current.CancellationToken);
        Assert.True(guard.Allowed);
        Assert.False(guard.Conflict);
        Assert.Null(guard.Refusal);
        Assert.Equal(PortArgs.Check(B1), runner.Runs.Single().Args);
    }

    [Fact]
    public async Task AConflictRefusesStartAndRestartWithTheReasonAndKillsNothing()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("ports", "check").Print(CliFixture.Lines("ports-check-conflict.json"));
        foreach (var action in new[] { PortGuardAction.Start, PortGuardAction.Restart })
        {
            var guard = await PortGuard.CheckAsync(client, B1, action, TestContext.Current.CancellationToken);
            Assert.False(guard.Allowed);
            Assert.True(guard.Conflict);
            Assert.StartsWith(PortGuard.ConflictLead, guard.Refusal);
            Assert.Contains("8000 has a listener: pid 4242", guard.Refusal);
            Assert.Contains("9000 reserved by /home/akash/b2", guard.Refusal);
        }
        // only checks ran: no up, restart, kill or stop
        Assert.All(runner.Runs, r => Assert.Equal(PortArgs.Check(B1), r.Args));
    }

    [Fact]
    public async Task ABenchThatAlreadyRunsMayBeStartedButNotRestartedOverItsOwnPorts()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("ports", "check").Print(CliFixture.Lines("ports-check-running.json"));
        Assert.True((await PortGuard.CheckAsync(client, B1, PortGuardAction.Start, TestContext.Current.CancellationToken)).Allowed);
        Assert.False((await PortGuard.CheckAsync(client, B1, PortGuardAction.Restart, TestContext.Current.CancellationToken)).Allowed);
    }

    [Fact]
    public async Task APortCheckThatCannotRunRefusesWithTheReason()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("ports", "check").Fail(2, "benchbar: unknown command ports");
        var guard = await PortGuard.CheckAsync(client, B1, PortGuardAction.Start, TestContext.Current.CancellationToken);
        Assert.False(guard.Allowed);
        Assert.False(guard.Conflict);
        Assert.StartsWith("The ports could not be checked:", guard.Refusal);
        Assert.Contains("unknown command ports", guard.Refusal);
    }

    // --- the setup model ---

    [Fact]
    public async Task ThePlanLoadsForReviewAndNamesTheSheet()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("ports", "plan").Print(CliFixture.Lines("ports-plan.json"));
        var model = Model(client);
        Assert.Equal(PortSetupPhase.Planning, model.Phase);
        await model.LoadPlanAsync(TestContext.Current.CancellationToken);
        Assert.Equal(PortSetupPhase.Review, model.Phase);
        Assert.True(model.CanApply);
        Assert.False(model.NothingToSetUp);
        Assert.Equal("Set Up b1", model.Title);
        Assert.Equal("Set Up Bench", model.ApplyLabel);
        Assert.Equal(PortArgs.Plan([B1]), runner.Runs.Single().Args);
        Assert.Equal("Port Settings", Model(client, settings: true).Title);
        Assert.Equal("Resolve Port Conflict", Model(client, start: true).Title);
        Assert.Equal("Resolve and Start", Model(client, start: true).ApplyLabel);
    }

    [Fact]
    public async Task PortSettingsWithNothingToSetUpOffersNoApply()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("ports", "plan").Print(CliFixture.Lines("ports-plan-calm.json"));
        var model = Model(client, settings: true);
        await model.LoadPlanAsync(TestContext.Current.CancellationToken);
        Assert.True(model.NothingToSetUp);
        Assert.False(model.CanApply);
        // the same plan opened as a setup is not calm
        var setup = Model(client);
        await setup.LoadPlanAsync(TestContext.Current.CancellationToken);
        Assert.False(setup.NothingToSetUp);
        Assert.True(setup.CanApply);
    }

    [Fact]
    public async Task ABlockedPlanCannotBeAppliedAndAMissingPreviewFailsTheSheet()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("ports", "plan").Print(CliFixture.Lines("ports-plan-blocked.json"));
        var blocked = Model(client);
        await blocked.LoadPlanAsync(TestContext.Current.CancellationToken);
        Assert.Equal(PortSetupPhase.Review, blocked.Phase);
        Assert.False(blocked.CanApply);
        await blocked.ApplyAsync();
        Assert.DoesNotContain(runner.Runs, r => r.Args[1] == "apply");

        var (client2, runner2) = CliFixture.Scripted();
        runner2.On("ports", "plan").Print(CliFixture.Lines("ports-plan-nopreview.json"));
        var nopreview = Model(client2);
        await nopreview.LoadPlanAsync(TestContext.Current.CancellationToken);
        Assert.Equal(PortSetupPhase.Failed, nopreview.Phase);
        Assert.Contains("did not provide a service-change preview", nopreview.Error);

        var (client3, runner3) = CliFixture.Scripted();
        runner3.On("ports", "plan").Fail(1, "benchbar: not a bench");
        var broken = Model(client3);
        await broken.LoadPlanAsync(TestContext.Current.CancellationToken);
        Assert.Equal(PortSetupPhase.Failed, broken.Phase);
        Assert.Contains("not a bench", broken.Error);
    }

    [Fact]
    public async Task AModeChangeIsSavedAtOnceAndThePlanIsReadAgain()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("ports", "plan").Print(CliFixture.Lines("ports-plan.json"));
        runner.On("ports", "mode");
        var model = Model(client, settings: true);
        await model.LoadPlanAsync(TestContext.Current.CancellationToken);
        await model.SetModeAsync(PortMode.Fixed, B1);
        Assert.Equal(PortSetupPhase.Review, model.Phase);
        Assert.Null(model.ModeError);
        Assert.Equal(["ports plan", "ports mode", "ports plan"], runner.Runs.Select(r => r.Args[0] + " " + r.Args[1]));
        Assert.Equal(PortArgs.Mode(PortMode.Fixed, B1), runner.Runs[1].Args);
        await model.SetModeAsync(PortMode.Fixed, "/not/a/bench"); // not one of the sheet's benches
        Assert.Equal(3, runner.Runs.Count);
    }

    [Fact]
    public async Task AModeThatCannotBeSavedShowsTheErrorAndKeepsTheSheet()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("ports", "plan").Print(CliFixture.Lines("ports-plan.json"));
        runner.On("ports", "mode").Fail(1, "cannot write benchbar.toml");
        var model = Model(client);
        await model.LoadPlanAsync(TestContext.Current.CancellationToken);
        await model.SetModeAsync(PortMode.Fixed, B1);
        Assert.Equal(PortSetupPhase.Review, model.Phase);
        Assert.Contains("cannot write benchbar.toml", model.ModeError);
    }

    [Fact]
    public async Task ApplyRunsThePlansTokenOverTheSameBenchesAndKeepsTheOutput()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("ports", "plan").Print(CliFixture.Lines("ports-plan.json"));
        runner.On("ports", "apply").Print(File.ReadAllLines(Path.Combine(Fixtures.Dir("cli"), "ports-apply.txt")));
        var model = Model(client);
        await model.LoadPlanAsync(TestContext.Current.CancellationToken);
        await model.ApplyAsync();
        Assert.Equal(PortSetupPhase.Finished, model.Phase);
        Assert.Equal(PortArgs.Apply("cccc3333", [B1]), runner.Runs.Last().Args);
        Assert.Equal(["ports", "apply", "cccc3333", "--yes", "--", B1], runner.Runs.Last().Args);
        Assert.Contains("Completed /home/akash/b1", model.Output);
        Assert.Equal("Management is set up. Start the benches when you are ready.", model.SuccessText);
        Assert.DoesNotContain(runner.Runs, r => r.Args[0] == "up"); // setup never starts a bench on its own
    }

    [Fact]
    public async Task AFailedApplyShowsTheFailLinesAndANewPreviewIsNeeded()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("ports", "plan").Print(CliFixture.Lines("ports-plan.json"));
        runner.On("ports", "apply").Print("Applying /home/akash/b1", "[FAIL] the plan changed since it was shown").Fail(1);
        var model = Model(client);
        await model.LoadPlanAsync(TestContext.Current.CancellationToken);
        await model.ApplyAsync();
        Assert.Equal(PortSetupPhase.Failed, model.Phase);
        Assert.Equal("[FAIL] the plan changed since it was shown", model.Error);
        Assert.True(model.IsDismissible);
    }

    [Fact]
    public async Task ResolveAndStartChecksThePortsAgainThenStartsTheBench()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("ports", "plan").Print(CliFixture.Lines("ports-plan.json"));
        runner.On("ports", "apply").Print("Applying /home/akash/b1", "Completed /home/akash/b1");
        runner.On("ports", "check").Print(CliFixture.Lines("ports-check-clean.json"));
        runner.On("up");
        var model = Model(client, start: true);
        await model.LoadPlanAsync(TestContext.Current.CancellationToken);
        await model.ApplyAsync();
        Assert.Equal(PortSetupPhase.Finished, model.Phase);
        Assert.Equal(["ports plan", "ports apply", "ports check", "up --bench-dir"], runner.Runs.Select(r => string.Join(' ', r.Args.Take(2))));
        Assert.Equal(PortArgs.Start(B1), runner.Runs[^1].Args);
        Assert.Equal("Setup completed and the start command succeeded.", model.SuccessText);
    }

    [Fact]
    public async Task ResolveAndStartDoesNotStartIfAPortIsTakenAgain()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("ports", "plan").Print(CliFixture.Lines("ports-plan.json"));
        runner.On("ports", "apply").Print("Completed /home/akash/b1");
        runner.On("ports", "check").Print(CliFixture.Lines("ports-check-conflict.json"));
        var model = Model(client, start: true);
        await model.LoadPlanAsync(TestContext.Current.CancellationToken);
        await model.ApplyAsync();
        Assert.Equal(PortSetupPhase.Failed, model.Phase);
        Assert.Contains("a port is now occupied", model.Error);
        Assert.Contains("The bench was not started", model.Error);
        Assert.DoesNotContain(runner.Runs, r => r.Args[0] == "up");
    }

    [Fact]
    public async Task ARunningApplyCannotBeDismissed()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("ports", "plan").Print(CliFixture.Lines("ports-plan.json"));
        var held = runner.On("ports", "apply").Print("Applying /home/akash/b1").Hold();
        var model = Model(client);
        await model.LoadPlanAsync(TestContext.Current.CancellationToken);
        var run = model.ApplyAsync();
        await held.Started.Task;
        Assert.Equal(PortSetupPhase.Running, model.Phase);
        Assert.False(model.IsDismissible);
        Assert.True(model.IsBusy);
        held.Release("Completed /home/akash/b1");
        await run;
        Assert.True(model.IsDismissible);
    }
}
