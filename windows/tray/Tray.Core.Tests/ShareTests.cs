using BenchBar.Tray.Core;
using Xunit;
using static Tray.Core.Tests.CliFixture;

namespace Tray.Core.Tests;

/// <summary>The host side of a room: the documents as the CLI prints them, the exact calls, the refusals and the texts. Nothing here starts a process.</summary>
public class ShareTests
{
    private const string Bench = "/home/akash/frappe-bench";

    private static (ShareModel Model, ScriptedStreamRunner Runner) Rig()
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var (client, runner) = Scripted();
        return (new ShareModel(client, Bench), runner);
    }

    // --- the documents ---

    [Fact]
    public void ARunningRoomIsReadWithItsCountsLockAndChecks()
    {
        var status = ShareStatus.Parse(Doc("share-status-on.json"));
        Assert.True(status.IsOn && status.IsLive && !status.NeedsNewerCli);
        Assert.Equal((2, 1, 3540, 3600), (status.Seats, status.DevicesOnline, status.SecondsLeft, status.CanExtendSeconds));
        Assert.Equal(["priya@example.com", "sam@example.com"], status.AllowedUsers);
        Assert.Equal((true, "full", true, 1), (status.Locked, status.LockReason, status.JoinTrouble, status.WipeFailed));
        Assert.Equal(ShareText.Full, ShareText.LockLine(status));
        Assert.Equal("Sharing on your network · 1 online · 59 min left", ShareText.Indicator(status));
        Assert.Equal(ShareCheckStatus.Ok, Assert.Single(status.Checks).Status);
    }

    [Fact]
    public void AnEmptyBenchGetsSetUpAndAnOldCliAsksForAnUpdate()
    {
        var unset = ShareStatus.Parse(Doc("share-status-unset.json"));
        Assert.Equal(SharePrimary.SetUp, ShareText.Primary(unset));
        var old = ShareStatus.Parse(Doc("share-status-old.json"));
        Assert.True(old.NeedsNewerCli);
        Assert.Equal(SharePrimary.UpdateCli, ShareText.Primary(old));
        Assert.Equal(SharePrimary.FinishSetup, ShareText.Primary(unset with { SetupInterrupted = true }));
    }

    [Fact]
    public void TheButtonFollowsTheStateAndAFailedCheckBlocksStartButOneOfTheRunningShareDoesNot()
    {
        var off = ShareStatus.Parse(Doc("share-status-off.json"));
        Assert.Equal(SharePrimary.Start, ShareText.Primary(off));
        Assert.False(ShareText.CanStart(off)); // firewall_node failed
        var gateway = off.Checks.Single(c => c.Id == "gateway_reachable");
        Assert.True(ShareText.WaitsForStart(gateway, off)); // nothing to probe while sharing is off
        Assert.True(ShareText.CanStart(off with { Checks = [gateway] }));
        Assert.Equal(SharePrimary.TurnOnProtection, ShareText.Primary(off with { LanGuard = LanGuardState.Missing }));
        Assert.Equal(SharePrimary.Stop, ShareText.Primary(off with { State = ShareState.Starting }));
    }

    [Fact]
    public void AFixActionThisBuildDoesNotKnowHasNoButtonAndAStateItDoesNotKnowIsAProblem()
    {
        var checks = ShareStatus.Parse(Doc("share-status-off.json")).Checks;
        var unknown = checks.Single(c => c.Id == "future_check");
        Assert.Equal((ShareCheckStatus.Warn, ShareFixAction.None), (unknown.Status, unknown.Fix));
        Assert.Null(ShareText.FixLabel(unknown.Fix));
        Assert.Equal("Allow...", ShareText.FixLabel(checks.Single(c => c.Id == "firewall_node").Fix));
        Assert.Equal(ShareState.Error, ShareJson.State("sharing-now-v2"));
    }

    [Fact]
    public void TheCopyLineSaysHowOldItIsAndWarnsWhenTheAppsMoved()
    {
        var copy = ShareStatus.Parse(Doc("share-status-off.json")).Copy!;
        Assert.True(copy.Drifted);
        Assert.Equal("Copy made 2 h 1 min ago from one.localhost. Guests' changes stay in the copy.", ShareText.CopyLine(copy));
        Assert.Equal("less than a minute", ShareText.Countdown(30));
    }

    [Fact]
    public void PeopleAreReadWithoutAnIdLeftOutAndSortedOnlineFirst()
    {
        var people = ShareJson.People(Doc("share-people.json"));
        Assert.Equal(["Priya", "Sam"], ShareText.Sorted(people).Select(p => p.Name));
        Assert.Equal("Priya · ThinkPad · 192.168.1.32", ShareText.PersonLine(people.Single(p => p.Name == "Priya")));
    }

    [Fact]
    public void OnlyEnabledSystemUsersCanTakeASeatAndOneThatLosesRolesSaysSo()
    {
        var users = ShareJson.Users(Doc("share-users.json"));
        Assert.Equal(["priya@example.com", "sam@example.com"], users.Where(u => u.Selectable).Select(u => u.Name));
        Assert.Equal(["System Manager"], users[0].CodeCapableRoles);
    }

    [Fact]
    public void TheSetupPlanSaysWhatTheCopyHolds()
    {
        var plan = ShareJson.SetupPlan(Doc("share-setup-plan.json"));
        Assert.Equal((1.5, 4), (plan.SizeGb, plan.EstMinutes));
        Assert.Equal("Customer 3, User 5", ShareText.DataClasses(plan.DataClasses));
        Assert.Equal("Needs about 1.5 GB free", ShareText.NeedsDisk(plan.SizeGb));
    }

    // --- the secrets ---

    [Fact]
    public void TheCodeAndTheInviteNeverPrintThemselves()
    {
        var code = new ShareCode("123456", 10);
        Assert.Equal("123 456", code.Spaced);
        Assert.DoesNotContain("123456", code.ToString());
        var invite = new ShareInvite("benchbar://share/join?c=123456");
        Assert.DoesNotContain("123456", invite.ToString());
    }

    [Fact]
    public async Task TheCodeIsReadAsAPersonAndAFailureNeverRepeatsStdout()
    {
        var (model, runner) = Rig();
        runner.On("share", "code").Print(Lines("share-code.json"));
        Assert.True(await model.LoadCodeAsync(true, TestContext.Current.CancellationToken));
        Assert.Equal("000 000", model.Code!.Spaced);
        var run = runner.Runs.Single();
        Assert.Equal(["share", "code", "--new", "--json", "--bench-dir", Bench], run.Args);
        Assert.Equal("0", run.Env["BENCHBAR_NONINTERACTIVE"]);

        var (broken, brokenRunner) = Rig();
        brokenRunner.On("share", "code").Print("""{"schema_version":1,"code":"","note":"654321"}""");
        Assert.False(await broken.LoadCodeAsync(false, TestContext.Current.CancellationToken));
        Assert.Null(broken.Code);
        Assert.DoesNotContain("654321", broken.LastError);
        Assert.Equal("The room code could not be read.", broken.LastError);
    }

    [Fact]
    public async Task TheInviteIsReadOnlyForTheClipboardAndTheModelKeepsNoCopyOfIt()
    {
        var (model, runner) = Rig();
        runner.On("share", "invite").Print(Lines("share-invite.json"));
        var invite = await model.ReadInviteAsync(TestContext.Current.CancellationToken);
        Assert.StartsWith("Join my BenchBar room", invite!.Text);
        Assert.True(model.InviteCopied);
        Assert.DoesNotContain(typeof(ShareModel).GetProperties(), p => p.PropertyType == typeof(ShareInvite));
    }

    // --- the exact calls ---

    [Fact]
    public async Task RefreshReadsStatusWithTheChecksAndThePeopleOnlyWhileTheRoomIsOn()
    {
        var (model, runner) = Rig();
        runner.On("share", "status").Print(Lines("share-status-on.json"));
        runner.On("share", "people").Print(Lines("share-people.json"));
        await model.RefreshAsync(true, TestContext.Current.CancellationToken);
        Assert.Equal(["share", "status", "--preflight", "--json", "--bench-dir", Bench], runner.Runs[0].Args);
        Assert.Equal(["share", "people", "--json", "--bench-dir", Bench], runner.Runs[1].Args);
        Assert.Equal(2, model.People.Count);

        // a model that sees the room off drops the people and the code
        var (off, offRunner) = Rig();
        offRunner.On("share", "status").Print(Lines("share-status-off.json"));
        await off.RefreshAsync(true, TestContext.Current.CancellationToken);
        Assert.Single(offRunner.Runs);
        Assert.Empty(off.People);
        Assert.Null(off.Code);
    }

    [Fact]
    public async Task TwoReadsCloseTogetherAreOneCall()
    {
        var (model, runner) = Rig();
        runner.On("share", "status").Print(Lines("share-status-unset.json"));
        await model.RefreshAsync(false, TestContext.Current.CancellationToken);
        await model.RefreshAsync(false, TestContext.Current.CancellationToken);
        Assert.Single(runner.Runs);
    }

    [Fact]
    public async Task StartRunsAsAPersonForTheChosenHours()
    {
        var (model, runner) = Rig();
        runner.On("share", "start").Print(Lines("share-done.jsonl"));
        runner.On("share", "status").Print(Lines("share-status-on.json"));
        runner.On("share", "people").Print(Lines("share-people.json"));
        Assert.True(await model.StartAsync(4, TestContext.Current.CancellationToken));
        Assert.Equal(["share", "start", "--for", "4h", "--json", "--bench-dir", Bench], runner.Runs[0].Args);
        Assert.Equal("0", runner.Runs[0].Env["BENCHBAR_NONINTERACTIVE"]);
        Assert.Equal("gui", runner.Runs[0].Env["BENCHBAR_SUDO"]);
        Assert.True(model.Status!.IsOn); // a run is followed by one read
    }

    [Fact]
    public async Task ARefusalOfTheCliIsShownAsItIsAndFixesNothing()
    {
        var (model, runner) = Rig();
        runner.On("lan-guard", "install").Print(Lines("share-refused.jsonl")).Fail(1);
        runner.On("share", "status").Print(Lines("share-status-off.json"));
        Assert.False(await model.RunLanGuardAsync(false, TestContext.Current.CancellationToken));
        Assert.Equal(["lan-guard", "install", "--yes", "--json"], runner.Runs[0].Args);
        Assert.Contains(runner.Runs, r => r.Args[0] == "share"); // read again afterwards
        Assert.Equal("There is no LAN guard on this platform yet.", model.LastError);
    }

    [Fact]
    public async Task AllowNodeIsItsOwnCommandAndTheOtherRoomCallsHaveTheirExactArguments()
    {
        var (model, runner) = Rig();
        runner.On("lan-guard").Print(Lines("share-done.jsonl"));
        runner.On("share").Print(Lines("share-done.jsonl"));
        await model.RunLanGuardAsync(true, TestContext.Current.CancellationToken);
        Assert.Equal(["lan-guard", "allow-node", "--yes", "--json"], runner.Runs[0].Args);
        await model.StopAsync(TestContext.Current.CancellationToken);
        Assert.Equal(["share", "stop", "--json", "--bench-dir", Bench], runner.Runs.First(r => r.Args[1] == "stop").Args);
        Assert.Equal(["share", "extend", "--by", "30m", "--json", "--bench-dir", Bench], model.ExtendArgs(30));
        Assert.Equal(["share", "unlock", "--json", "--bench-dir", Bench], model.LockArgs(false));
        Assert.Equal(["share", "remove", "d_0a1b2c3d", "--yes", "--json", "--bench-dir", Bench], model.RemoveArgs("d_0a1b2c3d"));
    }

    [Fact]
    public void ExtendOffersOnlyWhatTheCliAllows()
    {
        Assert.Equal([("+30 min", 30), ("+1 hour", 60)], ShareText.ExtendOptions(3600));
        Assert.Equal([("+30 min", 30)], ShareText.ExtendOptions(1800));
        Assert.Empty(ShareText.ExtendOptions(0));
    }

    // --- set up ---

    [Fact]
    public async Task SetupPlansWithADryRunThenMakesTheCopyOnlyWhenTheSheetConfirms()
    {
        var (model, runner) = Rig();
        runner.On("share", "setup").Print(Lines("share-setup-plan.json"));
        var form = new ShareSetupForm("one.localhost");
        Assert.False(form.CanRun);
        form.Picked.Add("sam@example.com");
        form.Picked.Add("priya@example.com");
        Assert.False(form.CanRun); // the acknowledgement is not given
        form.Acknowledged = true;
        Assert.True(form.CanRun);
        var request = form.Request(false);
        var plan = await model.PlanSetupAsync(request, TestContext.Current.CancellationToken);
        Assert.Equal(["share", "setup", "--site", "one.localhost", "--users", "priya@example.com,sam@example.com", "--backup-now", "--dry-run", "--json", "--bench-dir", Bench], runner.Runs[0].Args);

        var review = model.SetupReview(request, plan!);
        Assert.False(review.RequiresToken);
        Assert.Equal("Make the copy", review.ConfirmLabel);
        Assert.Contains("User 5", review.Summary);
        Assert.Contains(ShareText.Acknowledgement, review.Summary);
        Assert.Equal(["share", "setup", "--site", "one.localhost", "--users", "priya@example.com,sam@example.com", "--backup-now", "--acknowledge-data", "--yes", "--json", "--bench-dir", Bench], review.ApplyArgs(null!));
        var env = new SecretEnvironment();
        review.ConfigureEnv!(env);
        Assert.Equal("0", env.Materialize()["BENCHBAR_NONINTERACTIVE"]);
    }

    [Fact]
    public void ARefreshUsesTheLatestBackupWhenTheCopyIsNotMadeFromANewOne()
    {
        var request = new ShareSetupRequest("one.localhost", ["a"], false, true);
        Assert.Equal(["--site", "one.localhost", "--users", "a", "--from", "latest", "--refresh"], request.Arguments);
        Assert.Equal("Use the backup from 2 h ago", ShareSetupForm.SourceLabel(false, null, 7200));
        Assert.Equal("Copy my site as it is now (about 4 min)", ShareSetupForm.SourceLabel(true, 4, null));
    }
}
