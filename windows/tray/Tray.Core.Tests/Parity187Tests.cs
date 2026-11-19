using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using BenchBar.Tray.TestSupport;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>
/// Tray parity, part 1 (issue 187): the command catalogue, services only, autostart, the lockfile sheet, the prerequisites of an
/// install, acknowledging a warning and the service plan. The fixtures are what the CLI printed (tests/record-tray-fixtures.sh).
/// </summary>
public class Parity187Tests
{
    private const string Bench = "/home/akash/frappe-bench";

    private static CommandCatalogue Catalogue(Func<JsonObject, bool>? drop = null)
    {
        var doc = CliFixture.Doc("commands.json");
        if (drop is not null && doc["commands"] is JsonArray array)
        {
            foreach (var item in array.OfType<JsonObject>().Where(drop).ToList()) array.Remove(item);
        }
        return CommandCatalogue.Parse(doc);
    }

    // --- P45 the catalogue ---

    [Fact]
    public void TheCatalogueNamesCommandsAndTheirFlags()
    {
        var catalogue = Catalogue();
        Assert.True(catalogue.Has("up"));
        Assert.True(catalogue.HasFlag("up", "--services-only"));
        Assert.True(catalogue.HasFlag("doctor", "--ack"));
        Assert.True(catalogue.HasFlag("doctor", "--unack"));
        Assert.True(catalogue.HasFlag("service", "--apply"));
        Assert.True(catalogue.Has("lock write") && catalogue.Has("lock apply") && catalogue.Has("autostart") && catalogue.Has("watch") && catalogue.Has("fg"));
        Assert.False(catalogue.Has("pull")); // not in the fixture: a command the CLI lacks is never offered
        Assert.False(catalogue.HasFlag("up", "--nothing"));
    }

    [Fact]
    public void ACliWithoutAFlagDoesNotOfferWhatNeedsIt()
    {
        var old = Catalogue(c => JsonRead.Str(c, "name") is "autostart" or "lock write");
        Assert.False(old.Has("autostart"));
        Assert.False(old.Has("lock write"));
        Assert.True(old.Has("lock apply"));
    }

    [Fact]
    public async Task TheCatalogueIsAskedOnceAndAFailureIsAskedAgain()
    {
        var (client, runner) = CliFixture.Scripted();
        var support = new CommandSupport(client);
        Assert.Null(await support.GetAsync()); // nothing scripted: no answer, nothing kept
        runner.On("commands").Print(CliFixture.Lines("commands.json"));
        var first = await support.GetAsync();
        var second = await support.GetAsync();
        Assert.NotNull(first);
        Assert.Same(first, second);
        Assert.Equal(2, runner.Runs.Count);
        Assert.All(runner.Runs, r => Assert.Equal(["commands", "--json"], r.Args));
    }

    // --- P02 services only ---

    [Fact]
    public async Task ServicesOnlyStreamsAndEndsOk()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("up").Print(CliFixture.Lines("up-services-only.jsonl"));
        var steps = new List<CliStep>();
        var result = await client.RunStreamAsync(OverviewArgs.ServicesOnly(Bench), null, TimeSpan.FromSeconds(5), e => { if (e is CliEvent.Step s) steps.Add(s.Value); }, TestContext.Current.CancellationToken);
        Assert.True(result.Ok);
        Assert.Equal(["up", "--services-only", "--json", "--bench-dir", Bench], runner.Runs.Single().Args);
        Assert.Contains("start_redis", steps.Select(s => s.Id));
        Assert.Equal(["down", "--json", "--bench-dir", Bench], OverviewArgs.StopServices(Bench));
    }

    // --- P04 autostart ---

    [Fact]
    public void AutostartIsReadFromTheLineTheCliPrints()
    {
        Assert.True(AutostartText.Parse(FixtureFiles.CliLines("autostart-on.txt")));
        Assert.False(AutostartText.Parse(FixtureFiles.CliLines("autostart-off.txt")));
        Assert.Null(AutostartText.Parse(["something else"])); // an unknown wording is not a guess
        Assert.Equal(["autostart", "off", "--bench-dir", Bench], OverviewArgs.Autostart(false, Bench));
        Assert.Equal(["autostart", "--bench-dir", Bench], OverviewArgs.AutostartRead(Bench));
    }

    // --- P05 watch and fg ---

    [Fact]
    public void WatchAndForegroundRunInATerminalWithTheBenchAsAnArgument()
    {
        var watch = new TerminalLaunch("Ubuntu-24.04", Bench, OverviewArgs.InTerminal("watch", "/home/a/b;c"));
        Assert.Equal(["-d", "Ubuntu-24.04", "--cd", Bench, "--exec", "/bin/sh", "-c", "PATH=\"$HOME/.local/bin:$PATH\"; exec benchbar \"$@\"", "benchbar", "watch", "--bench-dir", "/home/a/b;c"], watch.WslArguments);
        Assert.DoesNotContain("b;c", OverviewArgs.InTerminal("fg", "/home/a/b;c")[2]); // the path is an argument, never part of the script
    }

    // --- P23 lock write and apply ---

    [Fact]
    public async Task ALockWriteIsShownAsTheDryRunPrintsItAndRunsOnlyAfterTheYes()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On(a => a.Contains("--dry-run")).Print("", $"New file {Bench}/benchbar.toml", "    schema = 1");
        runner.On(a => a.Contains("--yes")).Print("  [OK] wrote " + Bench + "/benchbar.toml");
        using var model = new PlanReviewModel(LockArgs.Review("write", Bench), client);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(PlanPhase.Review, model.Phase);
        Assert.True(model.CanConfirm);
        Assert.Contains("    schema = 1", model.Plan!.Preview);
        Assert.Single(runner.Runs); // nothing was written yet
        Assert.Equal(["lock", "write", "--dry-run", "--bench-dir", Bench], runner.Runs[0].Args);

        await model.ConfirmAsync();
        Assert.Equal(PlanPhase.Finished, model.Phase);
        Assert.True(model.Outcome.Applied);
        Assert.Equal(["lock", "write", "--yes", "--bench-dir", Bench], runner.Runs[1].Args);
    }

    [Fact]
    public async Task ALockWriteThatIsRefusedShowsTheCliReasonAndOffersNothing()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("lock").Print(FixtureFiles.CliLines("lock-write-refused.txt")).Fail(1);
        using var model = new PlanReviewModel(LockArgs.Review("write", Bench), client);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(PlanPhase.PlanFailed, model.Phase);
        Assert.Equal("not written: apps/frappe is not a git checkout; apps/erpnext is not a git checkout", model.Message);
        Assert.False(model.CanConfirm);
        Assert.Single(runner.Runs);
    }

    [Fact]
    public async Task AnUnchangedLockfileHasNothingToConfirmAndApplyAsksTheSameWay()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("lock").Print($"  [OK] unchanged: {Bench}/benchbar.toml already says this");
        using var model = new PlanReviewModel(LockArgs.Review("apply", Bench), client);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(PlanPhase.Review, model.Phase);
        Assert.False(model.CanConfirm);
        Assert.Equal(["lock", "apply", "--dry-run", "--bench-dir", Bench], runner.Runs.Single().Args);
        Assert.Equal(["lock", "apply", "--yes", "--bench-dir", Bench], LockArgs.Review("apply", Bench).ApplyArgs(model.Plan!));
    }

    // --- P26 prerequisites ---

    [Fact]
    public void PrerequisitesShowWarningsAndAFailureStopsContinue()
    {
        var warn = PrerequisiteReport.Parse(CliFixture.Doc("prerequisites.json"));
        Assert.True(warn.CanContinue);
        Assert.Equal(["sudo", "linger", "mariadb_password"], warn.NeedsAttention.Select(c => c.Id));
        Assert.Equal("sudo loginctl enable-linger tester", warn.NeedsAttention[1].FixCommand);
        var fail = PrerequisiteReport.Parse(CliFixture.Doc("prerequisites-fail.json"));
        Assert.False(fail.CanContinue);
        Assert.Equal(CheckLevel.Fail, fail.NeedsAttention[0].Level);
        Assert.Equal(["doctor", "--prerequisites", "--json", "--bench-dir", Bench], PrerequisiteReport.Args(Bench));
        Assert.Throws<FormatException>(() => PrerequisiteReport.Parse(new JsonObject()));
    }

    private sealed class PrerequisiteSetup(FixtureSetupService inner, string file) : DelegatingSetup(inner)
    {
        public List<string> Benches { get; } = [];

        public override Task<PrerequisiteResult> PrerequisitesAsync(string benchDir, CancellationToken ct)
        {
            Benches.Add(benchDir);
            return Task.FromResult(new PrerequisiteResult(PrerequisiteReport.Parse(CliFixture.Doc(file)), null));
        }
    }

    [Fact]
    public async Task TheNewBenchPageReadsThePrerequisitesOfItsFolderAndNothingBlocksOnThem()
    {
        var fixture = new SetupFixture();
        fixture.Check("check.json", ready: true);
        var setup = new PrerequisiteSetup(fixture.Service, "prerequisites-fail.json");
        var model = new WizardModel(setup, new FakeWizardHost());
        await model.ChooseNewBench();
        await model.ContinueFromCheckAsync();
        await model.PrerequisitesTask;
        Assert.Single(setup.Benches);
        Assert.Contains(model.Prerequisites!.NeedsAttention, c => c is { Id: "sudo", Level: CheckLevel.Fail });
        Assert.Null(model.PrerequisitesError);
    }

    [Fact]
    public async Task APrerequisiteReadThatFailsSaysSoAndHidesNothing()
    {
        var fixture = new SetupFixture();
        fixture.Check("check.json", ready: true);
        var model = new WizardModel(new DelegatingSetup(fixture.Service) { }, new FakeWizardHost());
        await model.ChooseNewBench();
        await model.ContinueFromCheckAsync();
        await model.PrerequisitesTask;
        Assert.Null(model.Prerequisites); // the fixture folder has no recorded answer
        Assert.NotNull(model.PrerequisitesError);
    }

    // --- P27 acknowledge ---

    [Fact]
    public async Task AcknowledgingAWarningRunsAckThenAsksDoctorAgain()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("doctor", "--ack").Print(CliFixture.Lines("doctor-ack.json"));
        runner.On(a => a is ["doctor", "--json", ..]).Print(CliFixture.Lines("health-doctor.json"));
        runner.On("setup").Print(CliFixture.Lines("health-setup-check.json"));
        using var model = new HealthModel(client, Bench);
        var warning = new HealthCheck("mariadb_utf8", "Database", "MariaDB character set", CheckLevel.Warn, "not utf8mb4", null, null, false);
        Assert.True(warning.CanAck);
        await model.AckAsync(warning, true, TestContext.Current.CancellationToken);
        Assert.Equal(["doctor", "--ack", "mariadb_utf8", "--json", "--bench-dir", Bench], runner.Runs[0].Args);
        Assert.Contains(runner.Runs, r => r.Args.SequenceEqual(HealthArgs.Doctor(Bench)));
        Assert.Null(model.AckError);
        Assert.Equal(["doctor", "--unack", "mariadb_utf8", "--json", "--bench-dir", Bench], HealthArgs.Ack("mariadb_utf8", false, Bench));
    }

    [Fact]
    public async Task AFailureCannotBeAcknowledgedAndTheRefusalIsShown()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("doctor", "--ack").Fail(1, "env_python FAILs: a failing check cannot be acknowledged.");
        using var model = new HealthModel(client, Bench);
        var failing = new HealthCheck("env_python", "Env", "Python", CheckLevel.Fail, "broken", null, null, false);
        Assert.False(failing.CanAck);
        var acked = new HealthCheck("mariadb_utf8", "Database", "x", CheckLevel.Warn, "m", null, null, true);
        Assert.False(acked.CanAck);
        await model.AckAsync(failing, true, TestContext.Current.CancellationToken);
        Assert.Equal("env_python FAILs: a failing check cannot be acknowledged.", model.AckError);
    }

    // --- P39 service ---

    [Fact]
    public async Task TheServicePlanHasATokenAndTheApplyUsesIt()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On(a => a.Contains("--dry-run")).Print(CliFixture.Lines("service-plan.jsonl"));
        runner.On(a => a.Contains("--apply")).Print(CliFixture.Lines("service-plan.jsonl").Last());
        var request = PlanReviewRequest.Tokened("Install the service", OverviewArgs.ServiceBase(Bench, true)) with { UsesSudoEnv = true };
        using var model = new PlanReviewModel(request, client);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(["service", "--with-schedule", "--bench-dir", Bench, "--dry-run", "--json"], runner.Runs[0].Args);
        Assert.Equal("bbbb2222", model.Plan!.Token);
        Assert.Equal(["service", "--bench-dir", Bench], OverviewArgs.ServiceBase(Bench));
        Assert.Equal(["service", "--without-schedule", "--bench-dir", Bench], OverviewArgs.ServiceBase(Bench, false));
        Assert.Equal(["service", "--with-schedule", "--bench-dir", Bench, "--apply", "bbbb2222", "--yes", "--jsonl"], request.ApplyArgs(model.Plan));
    }
}
