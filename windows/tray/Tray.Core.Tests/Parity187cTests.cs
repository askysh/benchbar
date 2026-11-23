using System.Globalization;
using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>
/// Tray parity, part 3 (issue 187): site snapshots and rollback, leases, history, the resource charts, operation handles and
/// <c>benchbar run</c>. The fixtures are the CLI's documents (the Mac app's recorded ones for snapshots, history and leases, the
/// docs' for stats, op and run).
/// </summary>
public class Parity187cTests
{
    private const string Bench = "/home/akash/frappe-bench";
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2027-01-15T08:05:00Z", CultureInfo.InvariantCulture);

    private static CommandCatalogue Catalogue(params string[] names) =>
        new(names.Select(n => new CommandInfo(n, "", "", false, n == "op list" ? new List<CommandFlag> { new("--running", null, "") } : new List<CommandFlag>())).ToList(), "0.9.0");

    // --- row 1: snapshots and rollback ---

    [Fact]
    public void TheSnapshotListIsReadNewestFirstWithTheMocksNullLabelAsNone()
    {
        var list = SnapshotJson.ParseList(CliFixture.Doc("snapshots-list.json"));
        Assert.Equal("acme.localhost", list.Site);
        Assert.Equal(["20261121_090000", "20261120_160102-before-upgrade"], list.Snapshots.Select(s => s.Id));
        Assert.Null(list.Snapshots[0].Label); // the word null is no label
        Assert.Equal("20261121_090000", list.Snapshots[0].Title);
        Assert.Equal("Before upgrade", list.Snapshots[1].Title);
        Assert.Equal(false, list.Snapshots[1].AppsMatch);
        Assert.Equal(["erpnext"], list.Snapshots[1].ChangedApps);
        Assert.Null(list.LastRollbackSnapshot);
        Assert.Equal(17537, list.TotalBytes);
        Assert.Equal(10, list.Keep);
        Assert.Equal("Apps changed since: erpnext", SnapshotText.Apps(list.Snapshots[1]));
    }

    [Fact]
    public void ASnapshotListFromAnOlderOrOddCliStillReads()
    {
        var o = (JsonObject)JsonNode.Parse("""{"snapshots":[{"id":"a"},{"label":"no id"},{"id":"b","time":"not a time","complete":false,"size_bytes":"x","apps_match":"yes"}]}""")!;
        var list = SnapshotJson.ParseList(o);
        Assert.Equal(["a", "b"], list.Snapshots.Select(s => s.Id));
        Assert.True(list.Snapshots[0].Complete); // absent counts as complete
        Assert.False(list.Snapshots[1].Complete);
        Assert.Null(list.Snapshots[1].Time);
        Assert.Null(list.Snapshots[1].AppsMatch);
        Assert.Equal(0, list.Snapshots[1].SizeBytes);
        Assert.Null(list.FreeBytes);
        Assert.Throws<FormatException>(() => SnapshotJson.ParseList(new JsonObject()));
    }

    [Fact]
    public void TakeSnapshotIsReadFromTheDocumentAndTheArgumentsAreExact()
    {
        var taken = SnapshotJson.ParseTaken(CliFixture.Doc("snapshot-take.json"))!;
        Assert.Equal("Before upgrade", taken.Title);
        Assert.True(taken.WithFiles);
        Assert.Null(SnapshotJson.ParseTaken((JsonObject)JsonNode.Parse("""{"snapshot":null}""")!)); // a dry run
        Assert.Equal(["site", "snapshot", "a.localhost", "--label", "before the upgrade", "--json", "--bench-dir", Bench], SnapshotCommands.Take("a.localhost", "  before the upgrade ", Bench));
        Assert.Equal(["site", "snapshot", "a.localhost", "--json", "--bench-dir", Bench], SnapshotCommands.Take("a.localhost", "  ", Bench));
        Assert.Equal(["site", "snapshots", "a.localhost", "--json", "--bench-dir", Bench], SnapshotCommands.List("a.localhost", Bench));
    }

    [Fact]
    public void ALabelFollowsTheCliRule()
    {
        Assert.Null(SnapshotCommands.LabelProblem(null));
        Assert.Null(SnapshotCommands.LabelProblem("before the upgrade"));
        Assert.NotNull(SnapshotCommands.LabelProblem(new string('x', 121)));
        Assert.NotNull(SnapshotCommands.LabelProblem("say \"hi\""));
        Assert.NotNull(SnapshotCommands.LabelProblem("it's"));
        Assert.NotNull(SnapshotCommands.LabelProblem("a\\b"));
        Assert.NotNull(SnapshotCommands.LabelProblem("a\nb"));
    }

    [Fact]
    public void RemoveNeverPassesForceUndoPointAndTheUndoPointIsNeverOffered()
    {
        var args = SnapshotCommands.Remove("a.localhost", "20261121_090000", Bench);
        Assert.Equal(["site", "snapshot", "drop", "a.localhost", "20261121_090000", "--yes", "--json", "--bench-dir", Bench], args);
        Assert.DoesNotContain("--force-undo-point", args);
        var undo = SnapshotJson.ParseSnapshot((JsonObject)JsonNode.Parse("""{"id":"x-before-rollback","before_rollback":true}""")!)!;
        Assert.False(SnapshotText.CanRemove(undo));
        Assert.True(SnapshotText.CanRemove(SnapshotJson.ParseList(CliFixture.Doc("snapshots-list.json")).Snapshots[0]));
    }

    [Fact]
    public void TheSnapshotLineSaysAgeSizeAndFiles()
    {
        var snapshot = SnapshotJson.ParseList(CliFixture.Doc("snapshots-list.json")).Snapshots[1];
        var line = SnapshotText.Line(snapshot, DateTimeOffset.Parse("2026-11-21T21:07:50Z", CultureInfo.InvariantCulture));
        Assert.StartsWith("3 hours ago, ", line);
        Assert.EndsWith(" KB, with files", line);
        Assert.Contains("beyond", SnapshotText.Summary(new SiteSnapshotList("a", 2, [], ["x", "y", "z"], null, 10, 5_000_000)));
    }

    [Fact]
    public async Task RollbackRunsThePlanThenTheApplyByTheTokenOfThatPlanAsThePerson()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On(a => a.Contains("--dry-run")).Print(CliFixture.Lines("snapshot-rollback-plan.json"));
        runner.On(a => a.Contains("--apply")).Print(CliFixture.Lines("snapshot-rollback.json"));
        var snapshot = SnapshotJson.ParseList(CliFixture.Doc("snapshots-list.json")).Snapshots[1];
        var model = new PlanReviewModel(SnapshotCommands.Review("acme.localhost", snapshot, Bench), client);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(PlanPhase.Review, model.Phase);
        Assert.Equal(["site", "rollback", "acme.localhost", "--to", "20261120_160102-before-upgrade", "--bench-dir", Bench, "--dry-run", "--json"], runner.Runs[0].Args);
        await model.ConfirmAsync();
        Assert.Equal(PlanPhase.Finished, model.Phase);
        Assert.True(model.Outcome.Applied);
        var apply = runner.Runs[1].Args;
        Assert.Equal(["--apply", model.Plan!.Token, "--yes", "--jsonl"], apply[^4..]);
        Assert.Equal("92c48b5c022f153a4672ee88277c0895050ab6df2b24a1ee434790cbda1c4b5a", model.Plan.Token);
        // the typed name was the person's decision: both calls run as a person, which the CLI needs for the default site
        Assert.All(runner.Runs, r => Assert.Equal("0", r.Env["BENCHBAR_NONINTERACTIVE"]));
    }

    [Fact]
    public void TheDefaultSitesRollbackIsLabelledAndAnotherSiteIsNot()
    {
        var other = SnapshotCommands.Describe(PlanDocument.FromJson(CliFixture.Doc("snapshot-rollback-plan.json")));
        var def = SnapshotCommands.Describe(PlanDocument.FromJson(CliFixture.Doc("snapshot-rollback-plan-default.json")));
        Assert.DoesNotContain(SnapshotCommands.DefaultSiteNote, other);
        Assert.Contains(SnapshotCommands.DefaultSiteNote, def);
        Assert.Contains(other, l => l.StartsWith("Apps: the bench's apps changed since this snapshot", StringComparison.Ordinal) || l.StartsWith("Apps: the same apps", StringComparison.Ordinal));
        Assert.Contains(other, l => l.StartsWith("Migrate:", StringComparison.Ordinal));
        Assert.Contains(other, l => l.StartsWith("Left alone:", StringComparison.Ordinal));
    }

    [Fact]
    public void TheSnapshotsEntryIsInTheMenuOnlyWhenTheCliHasTheCommands()
    {
        var row = new SiteRowInfo("a.localhost", false, "http://a.localhost:8000", true, false);
        Assert.DoesNotContain(SiteMenu.For(row, false), i => i.Action == SiteAction.Snapshots);
        var items = SiteMenu.For(row, false, snapshots: true);
        Assert.Equal("Snapshots...", items.Single(i => i.Action == SiteAction.Snapshots).Label);
        Assert.True(items.Single(i => i.Action == SiteAction.Snapshots).Enabled);
    }

    // --- row 2: leases ---

    [Fact]
    public void ALeaseIsReadWithItsHolderNoteAndEnd()
    {
        var leases = LeaseJson.ParseList(CliFixture.Doc("lease-list.json"), Now);
        var lease = Assert.Single(leases);
        Assert.Equal("claude-qa", lease.Holder);
        Assert.Equal("running the QA suite", lease.Note);
        Assert.Equal("Site acme.localhost is held by claude-qa until " + LeaseText.Until(lease.ExpiresAt!.Value, Now) + ": running the QA suite", LeaseText.Line(lease, Now));
        Assert.Empty(LeaseJson.ParseList(CliFixture.Doc("lease-list.json"), Now.AddHours(1))); // it ended since the read
        Assert.Throws<FormatException>(() => LeaseJson.ParseList(new JsonObject(), Now));
    }

    [Fact]
    public void ABenchLeaseSaysTheWholeBenchAndAMissingNoteIsNone()
    {
        var o = (JsonObject)JsonNode.Parse("""{"leases":[{"scope":"bench","holder":"agent","note":null}]}""")!;
        var lease = Assert.Single(LeaseJson.ParseList(o, Now));
        Assert.Equal("The whole bench is held by agent", LeaseText.Line(lease, Now));
    }

    [Fact]
    public void TheRefusalOfTheDoneLineNamesHolderEndAndNote()
    {
        var done = CliFixture.Lines("lease-refused-apply.jsonl").Select(l => (JsonObject)JsonNode.Parse(l)!).Single();
        var refusal = LeaseRefusal.Parse(done["error"]!.GetValue<string>())!;
        Assert.Equal("claude-qa", refusal.Holder);
        Assert.Equal("running the QA suite", refusal.Note);
        Assert.Equal(DateTimeOffset.Parse("2026-11-19T15:20:00Z", CultureInfo.InvariantCulture), refusal.Until);
        Assert.StartsWith("Held by claude-qa until ", refusal.Sentence());
        Assert.EndsWith("(running the QA suite).", refusal.Sentence());
        Assert.Contains("recorded in the history", refusal.BreakQuestion("Restart frappe-bench"));
        var plain = LeaseRefusal.Parse(string.Join('\n', CliFixture.Lines("lease-refused.txt")))!; // the text form of the same refusal
        Assert.Equal("claude-qa", plain.Holder);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("The ports are in use.")]
    [InlineData("something is leased by until")]
    [InlineData("The site x is leased by two words until 2026-11-19T15:20:00Z.")]
    public void AnythingThatIsNotALeaseRefusalIsNot(string? message) => Assert.Null(LeaseRefusal.Parse(message));

    [Fact]
    public void BreakLeaseGoesBeforeTheDoubleDash()
    {
        Assert.Equal(["restart", "--break-lease"], LeaseCommands.WithBreak(["restart"]));
        Assert.Equal(["run", "--apply", "T", "--yes", "--break-lease", "--", "migrate", "--skip-failing"], LeaseCommands.WithBreak(["run", "--apply", "T", "--yes", "--", "migrate", "--skip-failing"]));
        Assert.Equal(["lease", "list", "--bench", Bench, "--json"], LeaseCommands.List(Bench));
    }

    private static async Task<(PlanReviewModel Model, ScriptedStreamRunner Runner)> RefusedApply()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On(a => a.Contains("--dry-run")).Print(CliFixture.Lines("snapshot-rollback-plan.json"));
        var apply = runner.On(a => a.Contains("--apply") && !a.Contains("--break-lease")).Print(CliFixture.Lines("lease-refused-apply.jsonl")).Fail(1);
        _ = apply;
        var snapshot = SnapshotJson.ParseList(CliFixture.Doc("snapshots-list.json")).Snapshots[1];
        var model = new PlanReviewModel(SnapshotCommands.Review("acme.localhost", snapshot, Bench), client);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        await model.ConfirmAsync();
        return (model, runner);
    }

    [Fact]
    public async Task ARefusedApplyShowsTheHolderAndRunsNothingElseOnItsOwn()
    {
        var (model, runner) = await RefusedApply();
        Assert.Equal(PlanPhase.Finished, model.Phase);
        Assert.False(model.Outcome.Applied);
        Assert.Equal("claude-qa", model.LeaseRefused!.Holder);
        Assert.Equal(2, runner.Runs.Count); // the plan and the refused apply: nothing broke the lease
        Assert.DoesNotContain(runner.Runs, r => r.Args.Contains("--break-lease"));
    }

    [Fact]
    public async Task BreakLeaseRunsTheSameApplyAgainWithTheFlagAsThePerson()
    {
        var (model, runner) = await RefusedApply();
        runner.On(a => a.Contains("--break-lease")).Print(CliFixture.Lines("snapshot-rollback.json"));
        await model.BreakLeaseAsync();
        Assert.Equal(3, runner.Runs.Count);
        var again = runner.Runs[2];
        Assert.Equal(runner.Runs[1].Args.Concat(["--break-lease"]).ToArray(), again.Args);
        Assert.Equal("0", again.Env["BENCHBAR_NONINTERACTIVE"]);
        Assert.Equal(PlanPhase.Finished, model.Phase);
        Assert.True(model.Outcome.Applied);
        Assert.Null(model.LeaseRefused);
    }

    [Fact]
    public async Task BreakLeaseDoesNothingWithoutARefusal()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On(a => a.Contains("--dry-run")).Print(CliFixture.Lines("snapshot-rollback-plan.json"));
        runner.On(a => a.Contains("--apply")).Print(CliFixture.Lines("snapshot-rollback.json"));
        var snapshot = SnapshotJson.ParseList(CliFixture.Doc("snapshots-list.json")).Snapshots[1];
        var model = new PlanReviewModel(SnapshotCommands.Review("acme.localhost", snapshot, Bench), client);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        await model.ConfirmAsync();
        Assert.Null(model.LeaseRefused);
        await model.BreakLeaseAsync();
        Assert.Equal(2, runner.Runs.Count);
    }

    // --- row 3: history ---

    [Fact]
    public void TheHistoryIsReadWithWhoStartedItAndHowItEnded()
    {
        var entries = HistoryJson.Parse(CliFixture.Doc("history.json"));
        Assert.True(entries.Count >= 3);
        var first = entries[0];
        Assert.Equal("site snapshot drop", first.Command);
        Assert.Equal("Done", HistoryText.Result(first));
        Assert.Equal("script", first.Caller);
        Assert.Equal("A script", HistoryText.Who(first));
        Assert.Equal("snapshot acme.localhost", HistoryText.Changes(first));
        Assert.Equal("frappe-bench", HistoryText.BenchName(first));
        Assert.Equal("site rollback acme.localhost", HistoryText.Title(entries[1]));
        Assert.Equal("snapshot acme.localhost, site acme.localhost", HistoryText.Changes(entries[1]));
    }

    [Fact]
    public void AFailedRunAnUnknownCallerAndMissingFieldsAreShownAsTheyCame()
    {
        var o = (JsonObject)JsonNode.Parse("""{"history":[{"caller":"mcp","mcp":{"tool":"benchbar_app_add","client":"claude-code 2.1"},"exit":2,"argv":["app","add"],"changed":[{"kind":"app","name":"hrms"},{"kind":"x"}],"changed_more":3},{"caller":"future-thing","exit":0},{}]}""")!;
        var entries = HistoryJson.Parse(o);
        Assert.Equal("An agent through MCP (claude-code 2.1)", HistoryText.Who(entries[0]));
        Assert.Equal("Failed (exit 2)", HistoryText.Result(entries[0]));
        Assert.Equal("app add", HistoryText.Title(entries[0]));
        Assert.Equal("app hrms, 3 more", HistoryText.Changes(entries[0]));
        Assert.Equal("future-thing", HistoryText.Who(entries[1]));
        Assert.Equal("a command", HistoryText.Title(entries[1]));
        Assert.Equal("unknown", entries[2].Caller);
        Assert.Equal("Windows tray", HistoryText.Who(entries[2] with { Caller = "tray" }));
        Assert.Throws<FormatException>(() => HistoryJson.Parse(new JsonObject()));
        Assert.Equal(["history", "--json", "--limit", "100"], HistoryJson.Args());
    }

    // --- row 4: speed and resource charts ---

    [Fact]
    public void AStatsSampleIsReadWithTheSpeedTheMacAppUses()
    {
        var sample = StatsJson.Parse(CliFixture.Doc("stats.json"), Now)!;
        Assert.Equal(112.8, sample.CpuPercent);
        Assert.Equal(26624000, sample.MemoryBytes);
        Assert.Equal(4, sample.Processes);
        Assert.Equal(12, sample.Speed);
        Assert.Equal(DateTimeOffset.Parse("2026-11-20T11:09:20Z", CultureInfo.InvariantCulture), sample.At);
        Assert.Null(StatsJson.Parse(CliFixture.Doc("stats-stopped.json"), Now)); // a stopped bench has no resources
        Assert.Equal(["stats", "--json", "--bench-dir", Bench], StatsJson.Args(Bench));
    }

    [Fact]
    public void WithoutASpeedTheMacsMappingOfTheCpuIsUsedAndAnUnusableNumberIsNoSample()
    {
        var noSpeed = (JsonObject)JsonNode.Parse("""{"resources":{"cpu_percent":30,"memory_bytes":100}}""")!;
        Assert.Equal(4, StatsJson.Parse(noSpeed, Now)!.Speed);
        Assert.Equal(Now, StatsJson.Parse(noSpeed, Now)!.At);
        Assert.Null(StatsJson.Parse((JsonObject)JsonNode.Parse("""{"resources":{"cpu_percent":"lots"}}""")!, Now));
        Assert.Null(StatsJson.Parse((JsonObject)JsonNode.Parse("""{"resources":{"memory_bytes":100}}""")!, Now));
        Assert.Null(StatsJson.Parse((JsonObject)JsonNode.Parse("""{"resources":{"cpu_percent":-3}}""")!, Now));
        Assert.Equal(12, StatsJson.Parse((JsonObject)JsonNode.Parse("""{"resources":{"cpu_percent":1,"speed":{"raw":99}}}""")!, Now)!.Speed); // clamped to the Mac's top speed
        Assert.Null(StatsJson.Parse(new JsonObject(), Now));
    }

    [Fact]
    public void TheHistoryKeepsTheLastMinutesAndSmoothsTheSpeedLikeTheMac()
    {
        var history = new ResourceHistory();
        Assert.Null(history.Latest);
        Assert.Equal(1, history.Speed);
        history.Add(new ResourceSample(110, 1, 1, 12, Now));
        Assert.Equal(0.35 * 12 + 0.65 * 1, history.Speed, 6);
        for (var i = 0; i < ResourceHistory.Capacity + 10; i++) history.Add(new ResourceSample(i, i, 1, 1, Now));
        Assert.Equal(ResourceHistory.Capacity, history.Samples.Count);
        Assert.Equal(ResourceHistory.Capacity + 9, history.Latest!.CpuPercent);
        history.Clear();
        Assert.Empty(history.Samples);
        Assert.Equal(1, history.Speed);
    }

    [Fact]
    public void TheChartPutsTheNewestSampleAtTheRightEdgeAndScalesToTheMax()
    {
        var points = ResourceHistory.Points([0, 50, 100], 100, 590, 40);
        Assert.Equal(3, points.Count);
        Assert.Equal(590, points[^1].X, 6);
        Assert.Equal(40, points[0].Y, 6);
        Assert.Equal(20, points[1].Y, 6);
        Assert.Equal(0, points[2].Y, 6);
        Assert.Empty(ResourceHistory.Points([], 100, 590, 40));
        Assert.Equal(0, ResourceHistory.Points([500], 0, 590, 40)[0].Y); // a zero max does not divide by zero, and a value above the max is clamped
        Assert.Equal("CPU 112.8 percent, memory 25.4 MB, 4 processes, runner speed 5.2", ResourceHistory.Line(new ResourceSample(112.8, 26624000, 4, 12, Now), 5.2, CultureInfo.InvariantCulture));
    }

    [Theory]
    [InlineData(true, true, true, true, false, true)]
    [InlineData(true, true, true, true, true, false)] // minimised: WPF keeps IsVisible true, the rule still says off
    [InlineData(true, true, false, true, false, false)] // hidden to the tray
    [InlineData(true, true, true, false, false, false)]
    [InlineData(false, true, true, true, false, false)]
    [InlineData(true, false, true, true, false, false)]
    public void TheCardPollsOnlyWhileBoundVisibleAndNotMinimised(bool bound, bool catalogue, bool visible, bool loaded, bool minimised, bool expected) =>
        Assert.Equal(expected, ActivityRules.ShouldPoll(bound, catalogue, visible, loaded, minimised));

    // --- row 5: operation handles ---

    [Fact]
    public void TheRunningOperationsOfThisBenchAreListed()
    {
        var ops = OpJson.ParseList(CliFixture.Doc("op-list.json"));
        Assert.Equal(["running", "done", "interrupted"], ops.Select(o => o.State));
        var mine = OpJson.RunningFor(ops, Bench);
        var op = Assert.Single(mine);
        Assert.Equal("op-20261119-101500-4242", op.OpId);
        Assert.Equal("site backup acme.localhost, running: Back up acme.localhost (dumping the database), started 2 days ago",
            OpJson.Line(op, DateTimeOffset.Parse("2026-11-21T10:15:00Z", CultureInfo.InvariantCulture)));
        Assert.Empty(OpJson.RunningFor(ops, "/home/akash/other-bench")); // interrupted is not running
        Assert.Equal(["op", "list", "--running", "--json"], OpJson.List(true));
        Assert.Equal(["op", "list", "--json"], OpJson.List());
    }

    [Fact]
    public void AnUnknownStateAndARecordWithoutAnIdAreHandledAndNeverCountAsRunning()
    {
        var o = (JsonObject)JsonNode.Parse("""{"ops":[{"op_id":"a","state":"paused-soon"},{"state":"running"},{"op_id":"b"}]}""")!;
        var ops = OpJson.ParseList(o);
        Assert.Equal(["a", "b"], ops.Select(x => x.OpId));
        Assert.Equal(["paused-soon", "unknown"], ops.Select(x => x.State));
        Assert.Empty(OpJson.RunningFor(ops, Bench));
        Assert.Throws<FormatException>(() => OpJson.ParseList(new JsonObject()));
    }

    // --- the model that polls (rows 2, 4 and 5) ---

    private static (ActivityModel Model, ScriptedStreamRunner Runner) Polling()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("lease", "list").Print(CliFixture.Lines("lease-list.json"));
        runner.On("stats").Print(CliFixture.Lines("stats.json"));
        runner.On("op", "list").Print(CliFixture.Lines("op-list.json"));
        return (new ActivityModel(client, () => Now), runner);
    }

    [Fact]
    public async Task OnlyWhatTheCatalogueListsIsAsked()
    {
        var (model, runner) = Polling();
        await model.PollAsync(Bench, true, Catalogue("up", "stats"), true, TestContext.Current.CancellationToken);
        Assert.Equal([["stats", "--json", "--bench-dir", Bench]], runner.Runs.Select(r => r.Args));
        Assert.Empty(model.Leases);
        Assert.NotNull(model.Resources.Latest);
        runner.Runs.Clear();
        await model.PollAsync(Bench, true, null, true, TestContext.Current.CancellationToken); // no catalogue yet: nothing is asked
        Assert.Empty(runner.Runs);
    }

    [Fact]
    public async Task APollReadsLeasesChartsAndOperationsAndSaysSo()
    {
        var (model, runner) = Polling();
        var changed = 0;
        model.Changed += () => changed++;
        await model.PollAsync(Bench, true, Catalogue("lease list", "stats", "op list"), true, TestContext.Current.CancellationToken);
        Assert.Single(model.Leases);
        Assert.Equal(112.8, model.Resources.Latest!.CpuPercent);
        Assert.Single(model.Ops);
        Assert.True(model.HasContent);
        Assert.Equal(1, changed);
        Assert.Equal(["lease", "list", "--bench", Bench, "--json"], runner.Runs[0].Args);
        Assert.Equal(["op", "list", "--running", "--json"], runner.Runs[2].Args); // the CLI lists the flag, so it filters
        await model.PollAsync(Bench, true, Catalogue("lease list", "op list"), false, TestContext.Current.CancellationToken); // leases are not due
        Assert.Equal(1, changed); // nothing differs, so nothing is redrawn
        Assert.DoesNotContain(runner.Runs.Skip(3), r => r.Args[0] == "lease");
    }

    [Fact]
    public async Task AStoppedBenchHasNoChartAndMakesNoStatsCall()
    {
        var (model, runner) = Polling();
        var catalogue = Catalogue("stats");
        await model.PollAsync(Bench, true, catalogue, true, TestContext.Current.CancellationToken);
        Assert.NotNull(model.Resources.Latest);
        runner.Runs.Clear();
        await model.PollAsync(Bench, false, catalogue, true, TestContext.Current.CancellationToken);
        Assert.Empty(runner.Runs);
        Assert.Null(model.Resources.Latest);
        Assert.False(model.HasContent);
    }

    [Fact]
    public async Task ANullResourcesAnswerEndsTheChartAndAFailedReadKeepsWhatWasKnown()
    {
        var catalogue = Catalogue("stats");
        var sample = new ResourceSample(50, 1000, 2, 6, Now);

        var (stoppedClient, stopped) = CliFixture.Scripted();
        stopped.On("stats").Print(CliFixture.Lines("stats-stopped.json"));
        var ended = new ActivityModel(stoppedClient, () => Now);
        await ended.PollAsync(Bench, true, catalogue, true, TestContext.Current.CancellationToken); // seeds the bench
        ended.Resources.Add(sample);
        var changed = 0;
        ended.Changed += () => changed++;
        await ended.PollAsync(Bench, true, catalogue, true, TestContext.Current.CancellationToken);
        Assert.Null(ended.Resources.Latest); // nothing serves the site now: the chart ends
        Assert.Equal(1, changed);

        var failing = new ScriptedStreamRunner();
        failing.On("stats").Fail(1, "boom");
        var failed = new ActivityModel(new CliClient(failing, () => "benchbar.exe"), () => Now);
        await failed.PollAsync(Bench, true, catalogue, true, TestContext.Current.CancellationToken);
        failed.Resources.Add(sample);
        await failed.PollAsync(Bench, true, catalogue, true, TestContext.Current.CancellationToken);
        Assert.Same(sample, failed.Resources.Latest); // a failed read keeps what was known and invents nothing
    }

    [Fact]
    public async Task AnotherBenchStartsThePictureOver()
    {
        var (model, _) = Polling();
        var catalogue = Catalogue("lease list", "stats", "op list");
        await model.PollAsync(Bench, true, catalogue, true, TestContext.Current.CancellationToken);
        Assert.NotEmpty(model.Leases);
        await model.PollAsync("/home/akash/other", false, Catalogue("up"), true, TestContext.Current.CancellationToken);
        Assert.Empty(model.Leases);
        Assert.Empty(model.Ops);
        Assert.Null(model.Resources.Latest);
    }

    // --- row 6: benchbar run ---

    [Fact]
    public void TheAllowListHasTheDocumentedCommands()
    {
        Assert.Equal(["migrate", "clear-cache", "clear-website-cache", "build", "run-tests", "doctor", "list-apps", "version"], RunAllowList.All.Select(c => c.Name));
        Assert.All(RunAllowList.All.Where(c => !c.Changes), c => Assert.True(c.Help.Contains("read", StringComparison.Ordinal)));
        Assert.False(RunAllowList.Find("build")!.NeedsSite);
        Assert.True(RunAllowList.Find("migrate")!.NeedsSite);
        Assert.Null(RunAllowList.Find("update")); // refused by the CLI, never offered
    }

    [Theory]
    [InlineData("migrate", "--skip-failing", true)]
    [InlineData("migrate", "--skip-failing --skip-search-index", true)]
    [InlineData("migrate", "--force", false)]
    [InlineData("migrate", "--skip-failing; rm", false)]
    [InlineData("build", "--app erpnext", true)]
    [InlineData("build", "--app", false)]
    [InlineData("build", "--app -x", false)]
    [InlineData("build", "--app a/b", false)]
    [InlineData("run-tests", "--app erpnext --module accounts --failfast", true)]
    [InlineData("clear-cache", "--all", false)]
    [InlineData("version", "", true)]
    public void TheFlagsAreOnlyTheOnesTheCommandNamesAndTheirValuesArePlainWords(string command, string options, bool ok) =>
        Assert.Equal(ok, RunCommands.Flags(RunAllowList.Find(command)!, options).Problem is null);

    [Fact]
    public void ARunNeedsASiteOfThisBenchWhereTheCommandNeedsOne()
    {
        string[] sites = ["a.localhost", "b.localhost"];
        Assert.Null(RunCommands.Problem(new RunInput("migrate", "a.localhost", ""), sites));
        Assert.NotNull(RunCommands.Problem(new RunInput("migrate", null, ""), sites));
        Assert.NotNull(RunCommands.Problem(new RunInput("migrate", "c.localhost", ""), sites));
        Assert.Null(RunCommands.Problem(new RunInput("build", null, ""), sites));
        Assert.NotNull(RunCommands.Problem(new RunInput("execute", "a.localhost", ""), sites));
    }

    [Fact]
    public void ARunsArgumentsKeepTheBenchCommandAfterTheDoubleDash()
    {
        var input = new RunInput("migrate", "acme.localhost", "--skip-failing");
        Assert.Equal(["run", "--site", "acme.localhost", "--bench-dir", Bench, "--json", "--", "migrate", "--skip-failing"], RunCommands.Read(input, Bench));
        Assert.Equal(["run", "--bench-dir", Bench, "--json", "--", "build", "--app", "erpnext"], RunCommands.Read(new RunInput("build", "ignored.localhost", "--app erpnext"), Bench));
        var request = RunCommands.Review(input, Bench);
        Assert.Equal(["run", "--site", "acme.localhost", "--bench-dir", Bench, "--dry-run", "--json", "--", "migrate", "--skip-failing"], request.PlanArgs);
        var plan = PlanDocument.FromJson(CliFixture.Doc("run-plan.json"));
        Assert.Equal(["run", "--site", "acme.localhost", "--bench-dir", Bench, "--apply", plan.Token!, "--yes", "--jsonl", "--", "migrate", "--skip-failing"], request.ApplyArgs(plan));
        Assert.False(request.CanStop);
    }

    [Fact]
    public async Task AChangeRunsThePlanThenTheApplyByTheTokenOfThatPlan()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On(a => a.Contains("--dry-run")).Print(CliFixture.Lines("run-plan.json"));
        runner.On(a => a.Contains("--apply")).Print("""{"schema_version":1,"event":"done","exit":0,"changed":[],"warnings":[],"next_actions":[]}""");
        var model = new PlanReviewModel(RunCommands.Review(new RunInput("migrate", "acme.localhost", "--skip-failing"), Bench), client);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.True(model.CanConfirm);
        var lines = RunCommands.Describe(model.Plan!);
        Assert.Contains("bench migrate: patches, schema sync and fixtures of the site, after a backup of it.", lines);
        Assert.Contains("Command: bench --site acme.localhost migrate --skip-failing", lines);
        Assert.Contains("A database backup of the site is taken first.", lines);
        Assert.Contains("Deadline: 30 minutes.", lines);
        await model.ConfirmAsync();
        Assert.True(model.Outcome.Applied);
        Assert.Equal("8f1c5d0e2a7b4c9d1e3f6a8b0c2d4e6f8a0b1c3d5e7f9a1b2c4d6e8f0a1b3c5d", runner.Runs[1].Args[runner.Runs[1].Args.ToList().IndexOf("--apply") + 1]);
    }

    [Fact]
    public void AReadAnswersWithItsOutputAndHowItEnded()
    {
        var read = RunCommands.ParseRead(CliFixture.Doc("run-read.json"));
        Assert.True(read.Ok);
        Assert.Equal(0, read.CommandExit);
        Assert.Contains("erpnext 15.38.1", read.Output);
        var failed = RunCommands.ParseRead((JsonObject)JsonNode.Parse("""{"ok":false,"command_exit":1,"timed_out":true}""")!);
        Assert.False(failed.Ok);
        Assert.True(failed.TimedOut);
        Assert.Equal("", failed.Output);
    }
}
