using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using Xunit;
using static Tray.Core.Tests.CliFixture;

namespace Tray.Core.Tests;

/// <summary>The Health tab's parsers and models, the repair run, and the Overview facts (lockfile, uptime, scheduler, terminal).</summary>
public class HealthTests
{
    private const string Bench = "/home/akash/frappe-bench";


    private static Secret Password() => Secret.From("hunter2");

    // --- doctor parser ---

    [Fact]
    public void DoctorReadsLevelMessageFixActionAndAck()
    {
        var report = HealthJson.ParseDoctor(Doc("health-doctor.json"));
        Assert.Equal(5, report.Checks.Count);
        var assets = report.Checks[0];
        Assert.Equal(("assets", "bench", "Built assets", CheckLevel.Fail), (assets.Id, assets.Group, assets.Label, assets.Level));
        Assert.Equal("cd /home/akash/frappe-bench && bench build", assets.FixCommand);
        Assert.Equal("build", assets.Action);
        Assert.True(assets.Repairable);
        Assert.True(report.Checks[1].Acked);
        Assert.False(report.Checks[1].Repairable); // a warn without a repair action
        Assert.Null(report.Checks[2].FixCommand);
        Assert.Equal(CheckLevel.Unknown, report.Checks[4].Level);
        Assert.Equal(("v15-lts", "default"), (report.Profile, report.ProfileSource));
        Assert.True(report.ProfileIsDefault);
        Assert.Equal((2, 1, 1), (report.Ok, report.Warn, report.Fail));
        Assert.True(report.Repairable);
    }

    [Fact]
    public void DoctorReadsTheOldNamesAndTakesCountsFromTheChecksWithoutASummary()
    {
        var report = HealthJson.ParseDoctor(Doc("health-doctor-legacy.json"));
        Assert.Equal(CheckLevel.Fail, report.Checks[0].Level);
        Assert.Equal("bench build", report.Checks[0].FixCommand);
        Assert.Null(report.Checks[1].FixCommand); // an empty fix is none
        Assert.Equal((1, 0, 1), (report.Ok, report.Warn, report.Fail));
        Assert.False(report.ProfileIsDefault);
    }

    [Fact]
    public void DoctorRefusesADocumentWithoutChecks()
    {
        Assert.Throws<FormatException>(() => HealthJson.ParseDoctor(new JsonObject { ["bench"] = Bench }));
    }

    [Fact]
    public void TheReportOrdersFailuresFirstAndSaysItInWords()
    {
        var report = HealthJson.ParseDoctor(Doc("health-doctor.json"));
        Assert.Equal(["assets", "hosts", "odd"], report.NeedsAttention.Select(c => c.Id));
        Assert.Equal(["agent", "env_python"], report.Passing.Select(c => c.Id));
        Assert.Equal("1 failure, 1 warning", report.Attention);
        Assert.Equal("2 passing, 1 failure, 1 warning", report.SummaryText);
        var calm = report with { Fail = 0, Warn = 0 };
        Assert.Null(calm.Attention);
        Assert.Equal("2 passing", calm.SummaryText);
        Assert.Equal("3 failures, 2 warnings", (report with { Fail = 3, Warn = 2 }).Attention);
    }

    [Fact]
    public void ACheckCopiesAsTheCliPrintsIt()
    {
        var report = HealthJson.ParseDoctor(Doc("health-doctor.json"));
        Assert.Equal("[FAIL] Built assets: 2 of 2 dist files referenced by assets.json are missing (site loads unstyled)"
            + Environment.NewLine + "   fix: cd /home/akash/frappe-bench && bench build", HealthText.Row(report.Checks[0]));
        Assert.Equal("[OK] systemd unit: unit benchbar-frappe-bench loaded, running", HealthText.Row(report.Checks[2]));
        Assert.Equal("[?] Something new: a level this build does not know", HealthText.Row(report.Checks[4]));
    }

    [Fact]
    public void TheShimRowsComeFromSetupCheck()
    {
        var setup = HealthJson.ParseSetupCheck(Doc("health-setup-check.json"));
        Assert.Equal("Ubuntu-24.04", setup.Distro);
        Assert.Equal(["windows_build", "wsl_version", "systemd"], setup.Steps.Select(s => s.Id));
        Assert.True(setup.Steps[2].NotChecked);
        Assert.Equal("WARN", HealthText.ShimWord(setup.Steps[2].Status));
    }

    // --- the exact arguments ---

    [Fact]
    public void TheHealthCallsUseTheDocumentedArguments()
    {
        Assert.Equal(["doctor", "--json", "--bench-dir", Bench], HealthArgs.Doctor(Bench));
        Assert.Equal(["setup", "check", "--json"], HealthArgs.ShimCheck);
        Assert.DoesNotContain("--probe", HealthArgs.ShimCheck);
        Assert.Equal(["repair", "--dry-run", "--json", "--bench-dir", Bench], HealthArgs.RepairPlan(Bench));
        Assert.Equal(["repair", "--yes", "--json", "--bench-dir", Bench], HealthArgs.Repair(Bench));
        Assert.Equal(["lock", "check", "--json", "--bench-dir", Bench], HealthArgs.LockCheck(Bench));
        Assert.Equal(["service", "--yes", "--with-schedule", "--bench-dir", Bench], OverviewArgs.Scheduler(true, Bench));
        Assert.Equal(["service", "--yes", "--without-schedule", "--bench-dir", Bench], OverviewArgs.Scheduler(false, Bench));
    }

    // --- the model ---

    [Fact]
    public async Task RunDoctorAsksDoctorAndTheShimAndKeepsBothAnswers()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("doctor").Print(CliFixture.Lines("health-doctor.json")).Fail(1);
        runner.On("setup", "check").Print(CliFixture.Lines("health-setup-check.json"));
        var model = new HealthModel(client, Bench);
        Assert.False(model.HasRun);
        await model.RunAsync(TestContext.Current.CancellationToken);
        Assert.True(model.HasRun);
        Assert.False(model.IsRunning);
        Assert.Equal(1, model.Report!.Fail); // doctor exits 1 on a FAIL and still prints its report
        Assert.True(model.Repairable);
        Assert.Equal(3, model.Shim!.Steps.Count);
        Assert.Null(model.Error);
        Assert.Equal(new[] { HealthArgs.Doctor(Bench), HealthArgs.ShimCheck }.Select(a => string.Join(' ', a)).Order(),
            runner.Runs.Select(r => string.Join(' ', r.Args)).Order());
    }

    [Fact]
    public async Task ADoctorFailureAndAShimFailureAreEachShownOnTheirOwn()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("doctor").Fail(2, "benchbar: cannot read the bench");
        runner.On("setup", "check").Print(CliFixture.Lines("health-setup-check.json"));
        var model = new HealthModel(client, Bench);
        await model.RunAsync(TestContext.Current.CancellationToken);
        Assert.Null(model.Report);
        Assert.Contains("cannot read the bench", model.Error);
        Assert.NotNull(model.Shim);

        var (client2, runner2) = CliFixture.Scripted();
        runner2.On("doctor").Print(CliFixture.Lines("health-doctor.json"));
        var again = new HealthModel(client2, Bench);
        await again.RunAsync(TestContext.Current.CancellationToken);
        Assert.NotNull(again.Report);
        Assert.Null(again.Shim);
        Assert.False(string.IsNullOrEmpty(again.ShimError));
    }

    [Fact]
    public async Task ADisposedModelRaisesNothingMore()
    {
        var (client, runner) = CliFixture.Scripted();
        var gate = runner.On("doctor").Print(CliFixture.Lines("health-doctor.json")).Hold();
        runner.On("setup", "check").Print(CliFixture.Lines("health-setup-check.json"));
        var model = new HealthModel(client, Bench);
        var changes = 0;
        model.Changed += () => changes++;
        var run = model.RunAsync(TestContext.Current.CancellationToken);
        await gate.Started.Task;
        var before = changes;
        model.Dispose();
        await run;
        Assert.Equal(before, changes);
        Assert.Null(model.Report);
    }

    // --- repair ---

    [Fact]
    public async Task TheRepairPlanListsTheActionsAndMarksTheSudoOnes()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("repair").Print(CliFixture.Lines("health-repair-plan.json"));
        var model = new RepairModel(client, Bench, "frappe-bench");
        Assert.Equal(RepairPhase.Planning, model.Phase);
        await model.LoadPlanAsync(TestContext.Current.CancellationToken);
        Assert.Equal(RepairPhase.Review, model.Phase);
        Assert.Equal(["build", "unit"], model.Steps.Select(s => s.Id));
        Assert.Equal(["bench build", "write the systemd unit (sudo)"], model.Steps.Select(s => s.Label));
        Assert.True(model.HasSudoSteps);
        Assert.Equal(1, model.SudoSteps);
        Assert.True(model.CanRepair);
        Assert.EndsWith("20261030-101500-4242.log", model.Log);
        Assert.Equal(HealthArgs.RepairPlan(Bench), runner.Runs.Single().Args);
    }

    [Fact]
    public async Task AnEmptyPlanHasNothingToRepairAndAFailedPlanSaysWhy()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("repair").Print(CliFixture.Lines("health-repair-empty.json"));
        var model = new RepairModel(client, Bench, "b");
        await model.LoadPlanAsync(TestContext.Current.CancellationToken);
        Assert.Equal(RepairPhase.Review, model.Phase);
        Assert.False(model.CanRepair);

        var (client2, runner2) = CliFixture.Scripted();
        runner2.On("repair").Fail(1, "no such bench");
        var broken = new RepairModel(client2, Bench, "b");
        await broken.LoadPlanAsync(TestContext.Current.CancellationToken);
        Assert.Equal(RepairPhase.Failed, broken.Phase);
        Assert.Contains("no such bench", broken.Message);
        Assert.True(broken.IsDismissible);
    }

    [Fact]
    public async Task RepairWithoutSudoStepsRunsWithNoPasswordAndShowsEveryStep()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("repair", "--dry-run").Print(CliFixture.Lines("health-repair-plan-plain.json"));
        runner.On("repair", "--yes").Print(CliFixture.Lines("health-repair-run.jsonl"));
        var asked = 0;
        var model = new RepairModel(client, Bench, "b") { AskLinuxPassword = _ => { asked++; return Task.FromResult<Secret?>(null); } };
        await model.LoadPlanAsync(TestContext.Current.CancellationToken);
        Assert.False(model.HasSudoSteps);
        await model.RunAsync();
        Assert.Equal(0, asked);
        Assert.Equal(RepairPhase.Finished, model.Phase);
        Assert.True(model.Succeeded);
        Assert.True(model.Ran);
        // the run's own plan wins: it also has the sudo step, which was skipped without a password
        Assert.Equal([InstallStepStatus.Done, InstallStepStatus.Skipped], model.Steps.Select(s => s.Status));
        Assert.Contains("skipped without sudo", model.Steps[1].Message);
        var run = runner.Runs.Last();
        Assert.Equal(HealthArgs.Repair(Bench), run.Args);
        Assert.DoesNotContain("BENCHBAR_SUDO", run.Env.Keys);
    }

    [Fact]
    public async Task RepairAsksForThePasswordOnceAndSendsItOnlyThroughTheEnvironment()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("repair", "--dry-run").Print(CliFixture.Lines("health-repair-plan.json"));
        runner.On("repair", "--yes").Print(CliFixture.Lines("health-repair-run.jsonl"));
        var requests = new List<LinuxPasswordRequest>();
        var model = new RepairModel(client, Bench, "b") { AskLinuxPassword = r => { requests.Add(r); return Task.FromResult<Secret?>(Password()); } };
        await model.LoadPlanAsync(TestContext.Current.CancellationToken);
        await model.RunAsync();
        Assert.Equal([new LinuxPasswordRequest(1, false)], requests);
        var run = runner.Runs.Last();
        Assert.Equal("env", run.Env["BENCHBAR_SUDO"]);
        Assert.Equal("hunter2", run.Env["BENCHBAR_SUDO_PASSWORD"]);
        Assert.DoesNotContain(run.Args, a => a.Contains("hunter2"));
        Assert.Equal(RepairPhase.Finished, model.Phase);
    }

    [Fact]
    public async Task ACancelledPasswordQuestionRunsNothingAndAWrongPasswordAsksAgain()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("repair", "--dry-run").Print(CliFixture.Lines("health-repair-plan.json"));
        var model = new RepairModel(client, Bench, "b");
        await model.LoadPlanAsync(TestContext.Current.CancellationToken);
        await model.RunAsync(); // the default question answers "cancel"
        Assert.Equal(RepairPhase.Review, model.Phase);
        Assert.DoesNotContain(runner.Runs, r => r.Args.Contains("--yes"));

        var (client2, runner2) = CliFixture.Scripted();
        runner2.On("repair", "--dry-run").Print(CliFixture.Lines("health-repair-plan.json"));
        runner2.On("repair", "--yes").Print(CliFixture.Lines("sudo-wrong.jsonl")).Fail(1);
        var requests = new List<LinuxPasswordRequest>();
        var wrong = new RepairModel(client2, Bench, "b") { AskLinuxPassword = r => { requests.Add(r); return Task.FromResult<Secret?>(Password()); } };
        await wrong.LoadPlanAsync(TestContext.Current.CancellationToken);
        await wrong.RunAsync();
        Assert.Equal(RepairPhase.Review, wrong.Phase);
        Assert.True(wrong.PasswordWasWrong);
        Assert.Contains("did not accept", wrong.Message);
        Assert.False(wrong.Ran);
        await wrong.RunAsync();
        Assert.Equal([new LinuxPasswordRequest(1, false), new LinuxPasswordRequest(1, true)], requests);
    }

    [Fact]
    public async Task AFailedStepLeavesProblemsAndARunningRepairCannotBeDismissed()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("repair", "--dry-run").Print(CliFixture.Lines("health-repair-plan-plain.json"));
        var held = runner.On("repair", "--yes").Print(CliFixture.Lines("health-repair-run-plain.jsonl")).Hold();
        var model = new RepairModel(client, Bench, "b");
        await model.LoadPlanAsync(TestContext.Current.CancellationToken);
        var run = model.RunAsync();
        await held.Started.Task;
        Assert.Equal(RepairPhase.Running, model.Phase);
        Assert.False(model.IsDismissible);
        Assert.False(model.CanRepair); // no second run while one goes
        held.Release();
        await run;
        Assert.True(model.IsDismissible);
        Assert.Equal(RepairPhase.Finished, model.Phase);
        Assert.Equal(1, model.ExitCode);
        Assert.False(model.Succeeded);
        Assert.Equal(InstallStepStatus.Failed, model.Steps[0].Status);
        Assert.Contains("bench build exited 1", model.Steps[0].Message);
    }

    [Fact]
    public async Task ARepairThatPrintsNoDoneLineFails()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("repair", "--dry-run").Print(CliFixture.Lines("health-repair-plan-plain.json"));
        runner.On("repair", "--yes").Fail(3, "honcho is missing");
        var model = new RepairModel(client, Bench, "b");
        await model.LoadPlanAsync(TestContext.Current.CancellationToken);
        await model.RunAsync();
        Assert.Equal(RepairPhase.Failed, model.Phase);
        Assert.Contains("honcho is missing", model.Message);
        Assert.True(model.Ran);
    }

    // --- lockfile ---

    [Fact]
    public void TheLockCheckReadsDriftAndBadges()
    {
        var drift = LockJson.Parse(Doc("health-lock-drift.json"));
        Assert.False(drift.InSync);
        Assert.Equal("2 differences", drift.Badge);
        Assert.Equal("erpnext: commit behind (is a1b2c3d, lock b5f7846)", drift.Drift[0].Text);
        Assert.Equal("hrms: app missing", drift.Drift[1].Text);
        Assert.True(drift.Drift[1].IsFail);
        Assert.Contains("benchbar lock apply", drift.Footer);
        var sync = LockJson.Parse(Doc("health-lock-sync.json"));
        Assert.Equal("In sync", sync.Badge);
        Assert.Equal("1 difference", (drift with { Drift = [drift.Drift[0]] }).Badge);
        Assert.Throws<FormatException>(() => LockJson.Parse(new JsonObject()));
    }

    [Fact]
    public async Task ABenchWithoutALockfileIsNotAFailure()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("lock").Fail(1, "No lockfile for /home/akash/frappe-bench (looked for /home/akash/frappe-bench/benchbar.toml).");
        var none = LockOutcome.Parse(await client.RunJsonAsync(HealthArgs.LockCheck(Bench), null, CliTimeouts.Read, LockJson.Parse, TestContext.Current.CancellationToken));
        Assert.True(none.NoLockfile);
        Assert.Null(none.Check);

        var (client2, runner2) = CliFixture.Scripted();
        runner2.On("lock").Print(CliFixture.Lines("health-lock-drift.json")).Fail(1);
        var drift = LockOutcome.Parse(await client2.RunJsonAsync(HealthArgs.LockCheck(Bench), null, CliTimeouts.Read, LockJson.Parse, TestContext.Current.CancellationToken));
        Assert.False(drift.NoLockfile);
        Assert.Equal(2, drift.Check!.Drift.Count); // lock check exits 1 on drift and still prints the document
    }

    // --- overview facts ---

    [Fact]
    public void StatusCarriesTheSchedulerAndTheStartTimeForNothingExtra()
    {
        var running = BenchJson.ParseStatus("""{"bench":"/b","name":"b","state":"running","scheduler":true,"started_at":"2026-10-30T10:00:00Z"}""");
        Assert.True(running.Scheduler);
        Assert.Equal(new DateTimeOffset(2026, 10, 30, 10, 0, 0, TimeSpan.Zero), running.StartedAt);
        var old = BenchJson.ParseStatus("""{"bench":"/b","name":"b","state":"stopped"}""");
        Assert.Null(old.Scheduler);
        Assert.Null(old.StartedAt);
        Assert.Equal("Up for 2 h 5 min", OverviewFacts.Uptime(running, running.StartedAt!.Value + TimeSpan.FromMinutes(125)));
        Assert.Null(OverviewFacts.Uptime(running with { State = BenchState.Stopped }, running.StartedAt!.Value.AddHours(1)));
        Assert.Null(OverviewFacts.Uptime(old, DateTimeOffset.UtcNow));
    }

    [Theory]
    [InlineData(20, "less than a minute")]
    [InlineData(60 * 7, "7 min")]
    [InlineData(3600 * 3 + 60 * 4, "3 h 4 min")]
    [InlineData(86400 * 2 + 3600 * 5, "2 d 5 h")]
    public void UptimeIsWrittenInTheLargestUnits(int seconds, string expected)
    {
        Assert.Equal(expected, OverviewFacts.Duration(TimeSpan.FromSeconds(seconds)));
    }

    [Fact]
    public void ANotAdoptedBenchNeedsManagementAndTheSchedulerNoteSaysWhenItCannotChange()
    {
        var bench = new BenchStatus("b", "/b", BenchState.Unknown, null, null, null) { RawState = "not_adopted" };
        Assert.True(OverviewFacts.NeedsService(bench));
        Assert.False(OverviewFacts.NeedsService(bench with { RawState = "stopped" }));
        Assert.Contains("0.4", OverviewFacts.SchedulerNote(null));
        Assert.Contains("restarts a running bench", OverviewFacts.SchedulerNote(false));
        Assert.Equal(GuidanceAction.SetUpManagement, BenchGuidance.For(bench, needsService: OverviewFacts.NeedsService(bench))!.Action);
    }

    // --- terminals ---

    [Fact]
    public void ConsoleAndDatabaseOpenInWindowsTerminalThroughWsl()
    {
        var console = new TerminalLaunch("Ubuntu-24.04", Bench, WslCommands.Console(null));
        Assert.Equal(["-d", "Ubuntu-24.04", "--cd", Bench, "--exec", "bench", "console"], console.WslArguments);
        Assert.Equal(["wsl.exe", "-d", "Ubuntu-24.04", "--cd", Bench, "--exec", "bench", "console"], console.WindowsTerminalArguments);
        var database = new TerminalLaunch("Ubuntu-24.04", Bench, WslCommands.Database(null));
        Assert.Equal(["-d", "Ubuntu-24.04", "--cd", Bench, "--exec", "bench", "mariadb"], database.WslArguments);
        Assert.Equal(["bench", "--site", "one.localhost", "console"], WslCommands.Console("one.localhost"));
        Assert.Equal(["bench", "--site", "one.localhost", "mariadb"], WslCommands.Database("one.localhost"));
        Assert.Equal(["tail", "-f", "-n", "200", "logs/bench.log"], WslCommands.TailLog(false));
        Assert.Equal(["tail", "-f", "-n", "200", "logs/bench.previous.log"], WslCommands.TailLog(true));
    }
}
