using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using Xunit;
using static Tray.Core.Tests.CliFixture;

namespace Tray.Core.Tests;

/// <summary>The log viewer's parser, buffer, filter and search, and the model's reads and Follow polls.</summary>
public class LogsTests
{
    private const string Bench = "/home/akash/frappe-bench";


    private static (LogViewModel Model, ScriptedStreamRunner Runner) Make(int capacity = 5000)
    {
        var (client, runner) = CliFixture.Scripted();
        return (new LogViewModel(client, Bench, "frappe-bench", capacity) { PollEvery = TimeSpan.FromMilliseconds(15) }, runner);
    }

    /// <summary>A fake clock that says when a timer was asked for and for how long: the Follow loop asks for one whenever it waits.</summary>
    internal sealed class CountingTime : Microsoft.Extensions.Time.Testing.FakeTimeProvider
    {
        private readonly SemaphoreSlim _armed = new(0);
        private int _timers;

        public int Timers => Volatile.Read(ref _timers);
        public TimeSpan LastDue { get; private set; }

        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
        {
            LastDue = dueTime;
            Interlocked.Increment(ref _timers);
            var timer = base.CreateTimer(callback, state, dueTime, period);
            _armed.Release();
            return timer;
        }

        /// <summary>Waits until the loop has asked for its next wait, which is after it finished what it was doing.</summary>
        public async Task NextTimerAsync() =>
            Assert.True(await _armed.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken), "the Follow loop did not wait again");
    }

    private static (LogViewModel Model, ScriptedStreamRunner Runner, CountingTime Time) MakeTimed(TimeSpan? slow = null)
    {
        var (client, runner) = CliFixture.Scripted();
        var time = new CountingTime();
        runner.On("logs", "--json", "-n1000").Print(CliFixture.Lines("logs-first.json"));
        return (new LogViewModel(client, Bench, "frappe-bench", time: time) { SlowEvery = slow ?? TimeSpan.FromSeconds(30) }, runner, time);
    }

    private static int SinceCalls(ScriptedStreamRunner runner) => runner.Runs.Count(r => r.Args.Contains("--since"));

    private static async Task Until(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline) throw new TimeoutException("the condition was not met");
            await Task.Delay(5, TestContext.Current.CancellationToken);
        }
    }

    // --- parser ---

    [Theory]
    [InlineData("10:00:01 web.1     | * Running", "web")]
    [InlineData("10:00:01 redis_queue.1 | ready", "redis_queue")]
    [InlineData("10:00:01 system   | sending SIGTERM", "system")]
    [InlineData("Traceback (most recent call last):", null)]
    [InlineData("  File \"x.py\", line 1", null)]
    [InlineData("10:00:01 two words | x", null)]
    [InlineData("10:00:01 web.1", null)]
    [InlineData("", null)]
    public void TheProcessIsReadFromTheHonchoPrefix(string line, string? expected)
    {
        Assert.Equal(expected, LogParser.Process(line));
    }

    [Fact]
    public void ALineWithoutAPrefixBelongsToTheProcessAboveAndTracebacksAreErrors()
    {
        var buffer = new LogBuffer();
        var added = buffer.Append(["10:00:01 web.1 | ok", "10:00:02 worker.1 | ERROR: job failed", "Traceback (most recent call last):", "  File \"x.py\"", "10:00:03 web.1 | back", "plain"]);
        Assert.Equal(["web", "worker", "worker", "worker", "web", "web"], added.Select(l => l.Process));
        Assert.Equal([false, true, true, true, false, false], added.Select(l => l.IsError));
        Assert.Equal([0, 1, 2, 3, 4, 5], added.Select(l => l.Id));
    }

    [Fact]
    public void TheBufferKeepsTheNewestLinesAndIdsKeepCountingAfterClear()
    {
        var buffer = new LogBuffer(3);
        buffer.Append(["a", "b", "c", "d", "e"]);
        Assert.Equal(["c", "d", "e"], buffer.Lines.Select(l => l.Text));
        Assert.Equal(4, buffer.LastId);
        buffer.Clear();
        Assert.Empty(buffer.Lines);
        Assert.Equal(-1, buffer.LastId);
        Assert.Equal(5, buffer.Append(["f"]).Single().Id);
    }

    [Fact]
    public void TheFilterShowsOneProcessAndTheSearchIgnoresCase()
    {
        var buffer = new LogBuffer();
        var lines = buffer.Append(["10:00:01 web.1 | GET /App 200", "10:00:02 worker.1 | job APP done", "continued", "10:00:03 web.1 | nothing"]);
        var web = new LogQuery("web");
        Assert.Equal([0, 3], web.Visible(lines).Select(l => l.Id));
        Assert.Equal([0, 1, 2, 3], new LogQuery().Visible(lines).Select(l => l.Id));
        Assert.Equal([2], new LogQuery("worker").Visible(lines).Skip(1).Select(l => l.Id));
        Assert.Equal([0, 1], new LogQuery(null, " app ").Matches(lines));
        Assert.Empty(new LogQuery(null, "   ").Matches(lines));
        Assert.Equal(["web", "worker", "socketio", "schedule", "redis_queue", "redis_cache"], LogQuery.Processes);
    }

    [Fact]
    public void SearchTextCountsAndWrapsAround()
    {
        Assert.Equal("", SearchText.Describe(null, 5, searching: false));
        Assert.Equal("no matches", SearchText.Describe(null, 0, searching: true));
        Assert.Equal("5 matches", SearchText.Describe(null, 5, searching: true));
        Assert.Equal("2 of 5", SearchText.Describe(1, 5, searching: true));
        Assert.Equal(0, SearchText.Step(null, 3, forward: true));
        Assert.Equal(2, SearchText.Step(null, 3, forward: false));
        Assert.Equal(0, SearchText.Step(2, 3, forward: true));
        Assert.Equal(2, SearchText.Step(0, 3, forward: false));
        Assert.Null(SearchText.Step(1, 0, forward: true));
    }

    [Fact]
    public void TheLogDocumentAlignsTimesWithLines()
    {
        var chunk = LogsJson.Parse(Doc("logs-first.json"));
        Assert.EndsWith("logs/bench.log", chunk.File);
        Assert.Equal(6, chunk.Lines.Count);
        Assert.Equal(6, chunk.Times.Count);
        Assert.Null(chunk.Times[2]);
        Assert.Equal("2026-10-30T10:00:04Z", chunk.Times[5]);
        var untimed = LogsJson.Parse(new JsonObject { ["lines"] = new JsonArray("a", "b") });
        Assert.Equal([null, null], untimed.Times);
        Assert.Throws<FormatException>(() => LogsJson.Parse(new JsonObject()));
    }

    [Fact]
    public void TheLogCallsUseTheDocumentedArguments()
    {
        Assert.Equal(["logs", "--json", "-n1000", "--bench-dir", Bench], LogArgs.First(Bench, previous: false));
        Assert.Equal(["logs", "--json", "-n1000", "--previous", "--bench-dir", Bench], LogArgs.First(Bench, previous: true));
        Assert.Equal(["logs", "--json", "--since", "2026-10-30T10:00:04Z", "-n2000", "--bench-dir", Bench], LogArgs.Newer(Bench, "2026-10-30T10:00:04Z"));
        Assert.Equal(["logs", "--json", "-n200", "--bench-dir", Bench], LogArgs.Newer(Bench, null));
    }

    [Fact]
    public void OnlyTheLinesAfterWhatIsShownAreNew()
    {
        string[] shown = ["a", "b", "c"];
        AssertNew(shown, ["c", "d"], ["d"], false);
        AssertNew(shown, ["x", "b", "c", "d", "e"], ["d", "e"], false);
        AssertNew(shown, ["b", "c"], [], false);
        AssertNew(shown, [], [], false);
        AssertNew(shown, ["z"], ["z"], true);
        AssertNew([], ["z"], ["z"], false);
    }

    private static void AssertNew(string[] shown, string[] response, string[] expected, bool restarted)
    {
        var (fresh, flag) = LogOverlap.NewLines(shown, response);
        Assert.Equal(expected, fresh);
        Assert.Equal(restarted, flag);
    }

    // --- the model ---

    [Fact]
    public async Task TheFirstReadFillsTheBufferThroughLogsJson()
    {
        var (model, runner) = Make();
        runner.On("logs").Print(CliFixture.Lines("logs-first.json"));
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(LogArgs.First(Bench, false), runner.Runs.Single().Args);
        Assert.Equal(6, model.LineCount);
        Assert.EndsWith("logs/bench.log", model.File);
        Assert.Null(model.Error);
        Assert.False(model.IsLoading);
        Assert.Equal(["web", "worker", "worker", "worker", "web", "socketio"], model.Visible().Select(l => l.Process));
        Assert.Contains("ERROR: job failed", model.VisibleText());
        // nothing reads a file inside WSL by itself: every run is the shim's logs command
        Assert.All(runner.Runs, r => Assert.Equal("logs", r.Args[0]));
    }

    [Fact]
    public async Task AFailedReadShowsTheReason()
    {
        var (model, runner) = Make();
        runner.On("logs").Fail(1, "benchbar: no such bench");
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Contains("no such bench", model.Error);
        Assert.Equal(0, model.LineCount);
    }

    [Fact]
    public async Task TheFilterAndTheSearchWorkOnWhatIsLoaded()
    {
        var (model, runner) = Make();
        runner.On("logs").Print(CliFixture.Lines("logs-first.json"));
        await model.LoadAsync(TestContext.Current.CancellationToken);
        var changes = model.Changes;
        model.SetProcess("web");
        Assert.True(model.Changes > changes);
        Assert.Equal(2, model.Visible().Count);
        model.SetProcess(null);
        model.SetSearch("get");
        Assert.Equal("1 matches", model.SearchSummary);
        Assert.Single(model.Matches());
        Assert.Null(model.CurrentMatchId);
        model.Step(forward: true);
        Assert.Equal(model.Matches()[0], model.CurrentMatchId);
        Assert.Equal("1 of 1", model.SearchSummary);
        model.SetSearch("zzz");
        Assert.Equal("no matches", model.SearchSummary);
        Assert.Single(runner.Runs); // none of this asked the CLI again
    }

    [Fact]
    public async Task SteppingToAMatchTurnsFollowOff()
    {
        var (model, runner) = Make();
        runner.On("logs").Print(CliFixture.Lines("logs-first.json"));
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.True(model.Follow);
        model.SetSearch("web");
        model.Step(forward: true);
        Assert.False(model.Follow);
    }

    [Fact]
    public async Task ClearEmptiesTheViewWithoutTouchingTheFile()
    {
        var (model, runner) = Make();
        runner.On("logs").Print(CliFixture.Lines("logs-first.json"));
        await model.LoadAsync(TestContext.Current.CancellationToken);
        model.Clear();
        Assert.Equal(0, model.LineCount);
        Assert.Single(runner.Runs);
    }

    [Fact]
    public async Task APollAsksForTheLinesSinceTheLastTimeAndAddsOnlyTheNewOnes()
    {
        var (model, runner) = Make();
        runner.On("logs", "--json", "-n1000").Print(CliFixture.Lines("logs-first.json"));
        runner.On(a => a.Contains("--since")).Print(CliFixture.Lines("logs-since.json"));
        await model.LoadAsync(TestContext.Current.CancellationToken);
        var lastId = model.LastId;
        await model.PollOnceAsync(TestContext.Current.CancellationToken);
        Assert.Equal(["logs", "--json", "--since", "2026-10-30T10:00:04Z", "-n2000", "--bench-dir", Bench], runner.Runs[^1].Args);
        Assert.Equal(8, model.LineCount);
        Assert.Equal(["10:00:06 web.1     | GET /app 200", "10:00:07 web.1     | GET /api 500"], model.VisibleAfter(lastId).Select(l => l.Text));
        // the same answer again adds nothing
        await model.PollOnceAsync(TestContext.Current.CancellationToken);
        Assert.Equal(8, model.LineCount);
    }

    [Fact]
    public async Task AClearedViewIsNotFilledAgainByTheNextPoll()
    {
        var (model, runner) = Make();
        runner.On("logs", "--json", "-n1000").Print(CliFixture.Lines("logs-first.json"));
        runner.On(a => a.Contains("--since")).Print(CliFixture.Lines("logs-since.json"));
        await model.LoadAsync(TestContext.Current.CancellationToken);
        model.Clear();
        await model.PollOnceAsync(TestContext.Current.CancellationToken);
        Assert.Equal(["10:00:06 web.1     | GET /app 200", "10:00:07 web.1     | GET /api 500"], model.Visible().Select(l => l.Text));
    }

    [Fact]
    public async Task ALogThatStartedOverIsMarkedAndShownFromTheTop()
    {
        var (model, runner) = Make();
        runner.On("logs", "--json", "-n1000").Print(CliFixture.Lines("logs-first.json"));
        runner.On(a => a.Contains("--since")).Print(CliFixture.Lines("logs-restarted.json"));
        await model.LoadAsync(TestContext.Current.CancellationToken);
        await model.PollOnceAsync(TestContext.Current.CancellationToken);
        var texts = model.Visible().Select(l => l.Text).ToList();
        Assert.Equal("--- log restarted ---", texts[^2]);
        Assert.Equal("11:00:00 web.1     | * Running on http://127.0.0.1:8000", texts[^1]);
    }

    [Fact]
    public async Task ThePreviousLogIsReadWithPreviousAndNeverFollowed()
    {
        var (client, runner) = CliFixture.Scripted();
        var time = new CountingTime();
        var model = new LogViewModel(client, Bench, "frappe-bench", time: time);
        runner.On(a => a.Contains("--previous")).Print(CliFixture.Lines("logs-previous.json"));
        runner.On("logs").Print(CliFixture.Lines("logs-first.json"));
        await model.LoadAsync(TestContext.Current.CancellationToken);
        model.Start();
        Assert.True(model.IsPolling);
        await time.NextTimerAsync();
        model.ShowPrevious = true;
        Assert.False(model.IsPolling);
        await Until(() => model.File?.EndsWith("bench.previous.log", StringComparison.Ordinal) == true);
        Assert.Equal(1, model.LineCount);
        Assert.Contains(runner.Runs, r => r.Args.SequenceEqual(LogArgs.First(Bench, true)));
        time.Advance(TimeSpan.FromHours(1));
        Assert.Equal(0, model.Polls);
        model.ShowPrevious = false;
        Assert.True(model.IsPolling);
        model.Dispose();
    }

    // --- Follow ---

    [Fact]
    public async Task NothingPollsUntilTheViewerIsOpenAndFollowIsOn()
    {
        var (model, runner, time) = MakeTimed();
        runner.On(a => a.Contains("--since")).Print(CliFixture.Lines("logs-since-none.json"));
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(0, time.Timers); // loaded, not started
        Assert.False(model.IsPolling);

        model.Follow = false;
        model.Start();
        Assert.Equal(0, time.Timers); // open, Follow off: no loop, so no timer
        Assert.False(model.IsPolling);

        model.Follow = true;
        await time.NextTimerAsync();
        time.Advance(model.PollEvery);
        await time.NextTimerAsync();
        Assert.Equal(1, model.Polls);
        Assert.True(model.IsPolling);
        model.Follow = false;
        Assert.False(model.IsPolling);
        time.Advance(TimeSpan.FromHours(1));
        Assert.Equal(1, model.Polls);
        model.Dispose();
    }

    [Fact]
    public async Task ClosingTheViewerStopsFollowForGood()
    {
        var (model, runner, time) = MakeTimed();
        runner.On(a => a.Contains("--since")).Print(CliFixture.Lines("logs-since-none.json"));
        await model.LoadAsync(TestContext.Current.CancellationToken);
        model.Start();
        await time.NextTimerAsync();
        time.Advance(model.PollEvery);
        await time.NextTimerAsync();
        Assert.Equal(1, model.Polls);
        model.Dispose();
        Assert.False(model.IsPolling);
        var runs = runner.Runs.Count;
        time.Advance(TimeSpan.FromHours(1));
        Assert.Equal(1, model.Polls);
        Assert.Equal(runs, runner.Runs.Count);
        model.Follow = false;
        model.Follow = true; // switching it on again on a closed viewer starts nothing
        Assert.False(model.IsPolling);
    }

    [Fact]
    public async Task FollowWaitsLongerWhileNothingArrivesAndStartsOverWhenLinesDo()
    {
        var (model, runner, time) = MakeTimed();
        var empty = runner.On(a => a.Contains("--since")).Print(CliFixture.Lines("logs-since-none.json"));
        await model.LoadAsync(TestContext.Current.CancellationToken);
        model.Start();
        var waits = new List<double>();
        for (var i = 0; i < 6; i++)
        {
            await time.NextTimerAsync();
            waits.Add(time.LastDue.TotalSeconds);
            time.Advance(time.LastDue);
        }
        Assert.Equal([2, 4, 8, 10, 10, 10], waits); // doubles from PollEvery, capped at MaxIdleEvery

        empty.Lines.Clear();
        empty.Print(CliFixture.Lines("logs-since.json"));
        await time.NextTimerAsync();
        time.Advance(time.LastDue);
        await time.NextTimerAsync();
        Assert.Equal(2, time.LastDue.TotalSeconds); // lines arrived: back to the quick rate
        model.Dispose();
    }

    [Fact]
    public async Task APollThatBroughtLinesIsOneProcessAndTheDistroIsAskedAgainOnlyAfterAnEmptyOne()
    {
        var (model, runner, time) = MakeTimed();
        var reply = runner.On(a => a.Contains("--since")).Print(CliFixture.Lines("logs-since.json"));
        var probe = new FakeProbe();
        model.DistroProbe = probe;
        model.Distro = () => "Ubuntu-24.04";
        await model.LoadAsync(TestContext.Current.CancellationToken);
        model.Start();
        await time.NextTimerAsync();
        time.Advance(time.LastDue);           // the first poll is always asked behind the probe
        await time.NextTimerAsync();
        Assert.Equal(1, probe.Calls);
        Assert.Equal(1, SinceCalls(runner));

        reply.Lines.Clear();
        reply.Print(CliFixture.Lines("logs-since-none.json"));
        time.Advance(time.LastDue);           // lines came last time: the CLI call alone, no probe
        await time.NextTimerAsync();
        Assert.Equal(1, probe.Calls);
        Assert.Equal(2, SinceCalls(runner));

        time.Advance(time.LastDue);           // that one was empty: probe, then poll
        await time.NextTimerAsync();
        Assert.Equal(2, probe.Calls);
        Assert.Equal(3, SinceCalls(runner));
        model.Dispose();
    }

    [Fact]
    public async Task AHiddenWindowMakesNoPollAndHoldsNoTimerThenCatchesUpOnce()
    {
        var (model, runner, time) = MakeTimed();
        runner.On(a => a.Contains("--since")).Print(CliFixture.Lines("logs-since.json"));
        await model.LoadAsync(TestContext.Current.CancellationToken);
        model.Start();
        await time.NextTimerAsync();

        model.Hidden = true;                  // minimized: the wait in progress is dropped
        var timers = time.Timers;
        time.Advance(TimeSpan.FromHours(8));
        Assert.Equal(0, model.Polls);
        Assert.Equal(timers, time.Timers);

        model.Hidden = false;                 // shown again: one poll now, without waiting, then the normal wait
        await time.NextTimerAsync();
        Assert.Equal(1, model.Polls);
        Assert.Equal(2, time.LastDue.TotalSeconds);
        model.Dispose();
    }

    [Fact]
    public async Task LockAndSleepPauseFollowThroughTheGate()
    {
        var (model, runner, time) = MakeTimed();
        runner.On(a => a.Contains("--since")).Print(CliFixture.Lines("logs-since-none.json"));
        var gate = new FollowGate();
        model.Gate = gate;
        await model.LoadAsync(TestContext.Current.CancellationToken);
        model.Start();
        await time.NextTimerAsync();

        gate.SetAway(true);
        var timers = time.Timers;
        time.Advance(TimeSpan.FromHours(8));
        Assert.Equal(0, model.Polls);
        Assert.Equal(timers, time.Timers);

        gate.SetAway(false);
        await time.NextTimerAsync();
        Assert.Equal(1, model.Polls);
        model.Dispose();
    }

    [Fact]
    public void TheGateSaysPausedWhenAwayEvenInBatterySaverAndRaisesChangedOnlyOnAChange()
    {
        var gate = new FollowGate();
        var raised = 0;
        gate.Changed += () => raised++;
        Assert.Equal(FollowPace.Normal, gate.Pace);
        gate.SetBatterySaver(true);
        Assert.Equal(FollowPace.Slow, gate.Pace);
        gate.SetAway(true);
        Assert.Equal(FollowPace.Paused, gate.Pace);
        gate.SetAway(true);               // no change, no event
        gate.SetAway(false);
        Assert.Equal(FollowPace.Slow, gate.Pace);
        Assert.Equal(3, raised);
    }

    [Fact]
    public async Task BatterySaverStretchesTheWaitAndANewPaceCutsTheWaitShort()
    {
        var (model, runner, time) = MakeTimed();
        runner.On(a => a.Contains("--since")).Print(CliFixture.Lines("logs-since-none.json"));
        var gate = new FollowGate();
        model.Gate = gate;
        await model.LoadAsync(TestContext.Current.CancellationToken);
        model.Start();
        await time.NextTimerAsync();
        Assert.Equal(2, time.LastDue.TotalSeconds);

        gate.SetBatterySaver(true);           // the 2 s wait in progress becomes a 30 s one
        await time.NextTimerAsync();
        Assert.Equal(30, time.LastDue.TotalSeconds);
        time.Advance(TimeSpan.FromSeconds(29));
        Assert.Equal(0, model.Polls);
        time.Advance(TimeSpan.FromSeconds(1));
        await time.NextTimerAsync();
        Assert.Equal(1, model.Polls);
        Assert.Equal(30, time.LastDue.TotalSeconds);
        model.Dispose();
    }
}
