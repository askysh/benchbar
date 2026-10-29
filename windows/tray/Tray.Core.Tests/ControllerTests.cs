using BenchBar.Tray.Core;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace Tray.Core.Tests;

public class ControllerTests
{
    private static async Task UntilAsync(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "condition not met in time");
            await Task.Delay(10, TestContext.Current.CancellationToken);
        }
    }

    private static (TrayController Controller, FakeHost Host, FakeFrameClock Clock, ScriptedSource Source, FakeTimeProvider Time) Make(
        BenchState state, TrayOptions? options = null)
    {
        var source = new ScriptedSource();
        source.States["a"] = state;
        var host = new FakeHost();
        var clock = new FakeFrameClock();
        var time = new FakeTimeProvider();
        options ??= new TrayOptions { ListenToSystemEvents = false };
        return (new TrayController(source, clock, host, time, options), host, clock, source, time);
    }

    [Fact]
    public async Task StartShowsTheUnknownPoseThenFollowsTheFirstPoll()
    {
        var (controller, host, clock, _, _) = Make(BenchState.Stopped);
        using (host.Owning(controller))
        {
            host.Ui(controller.Start);
            Assert.NotEmpty(host.Icons);
            await UntilAsync(() => host.Changes.Count > 0);

            Assert.Equal("BenchBar: 1 bench, none up", host.Tooltip);
            Assert.Equal("none up", host.Changes[0].UpText);
            Assert.Contains(controller.Sequencer.Plan, new RunnerPlan?[]
            {
                new RunnerPlan.Settle(RunnerPose.Sleeping, 3),
                new RunnerPlan.Still(RunnerPose.Sleeping),
            });

            while (clock.HasPending) clock.Fire(); // the settle ends
            Assert.False(clock.HasPending);
            Assert.NotEqual(IntPtr.Zero, host.Icons[^1]);
        }
    }

    [Fact]
    public async Task ARunningBenchAtHighLoadSpeedsTheRunnerUp()
    {
        var (controller, host, _, source, _) = Make(BenchState.Running);
        source.CpuPercent = 250;
        using (host.Owning(controller))
        {
            host.Ui(controller.Start);
            await UntilAsync(() => host.Changes.Count > 0);
            Assert.Equal("1 of 1 up", host.Changes[0].UpText);
            Assert.Equal(0.35 * 12 + 0.65, controller.Sequencer.Speed, 6);
        }
    }

    [Fact]
    public async Task StartStopAsyncRunsUpOrDownAndPollsAtOnce()
    {
        var (controller, host, _, source, _) = Make(BenchState.Stopped);
        using (host.Owning(controller))
        {
            host.Ui(controller.Start);
            await UntilAsync(() => host.Changes.Count > 0);
            var lists = source.Lists;

            await controller.StartStopAsync(new BenchStatus("a", "/a", BenchState.Stopped, null, null, null));
            await controller.StartStopAsync(new BenchStatus("a", "/a", BenchState.Running, null, null, null));
            await controller.StartStopAsync(new BenchStatus("a", "/a", BenchState.Starting, null, null, null));

            Assert.Equal(["up --bench-dir /a", "down --bench-dir /a", "down --bench-dir /a"], source.Actions);
            await UntilAsync(() => source.Lists > lists);
        }
    }

    [Fact]
    public async Task OpeningTheFlyoutKicksThePoller()
    {
        var (controller, host, _, source, time) = Make(BenchState.Stopped);
        using (host.Owning(controller))
        {
            host.Ui(controller.Start);
            await UntilAsync(() => host.Changes.Count > 0);
            var lists = source.Lists;

            // Wait for the kicked poll to report, not just to list: its timer is armed only when it ends.
            var changes = host.Changes.Count;
            host.Ui(controller.FlyoutOpened);
            await UntilAsync(() => source.Lists > lists && host.Changes.Count > changes);

            lists = source.Lists;
            time.Advance(TimeSpan.FromSeconds(5)); // the 5 s flyout interval
            await UntilAsync(() => source.Lists > lists);
            host.Ui(controller.FlyoutClosed);
        }
    }

    [Fact]
    public async Task APausedBenchStandsAlertWithoutStumbling()
    {
        var (controller, host, clock, _, _) = Make(BenchState.Paused);
        using (host.Owning(controller))
        {
            host.Ui(controller.Start);
            await UntilAsync(() => host.Changes.Count > 0);
            Assert.Equal(new RunnerPlan.Still(RunnerPose.Alert), controller.Sequencer.Plan);
            Assert.False(clock.HasPending);
        }
    }
}
