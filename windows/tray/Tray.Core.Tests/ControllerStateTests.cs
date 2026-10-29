using BenchBar.Tray.Core;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace Tray.Core.Tests;

public class ControllerStateTests
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

    private static (TrayController Controller, FakeHost Host, ScriptedSource Source, FakeTimeProvider Time) Make(
        BenchState state = BenchState.Running, TrayOptions? options = null)
    {
        var source = new ScriptedSource();
        source.States["a"] = state;
        var host = new FakeHost();
        var time = new FakeTimeProvider();
        options ??= new TrayOptions { ListenToSystemEvents = false };
        return (new TrayController(source, new FakeFrameClock(), host, time, options), host, source, time);
    }

    private static BenchStatus Status(BenchState state, string? reason = null) =>
        new("a", "/a", state, reason, null, "a.localhost");

    [Fact]
    public async Task AProblemShowsTheUnknownPoseAndTheFixLineAsTheTooltip()
    {
        var (controller, host, source, _) = Make();
        source.ListFails = new SetupProblemException(ShimBenchSource.NotFoundMessage);
        using (host.Owning(controller))
        {
            host.Ui(controller.Start);
            await UntilAsync(() => host.Changes.Count > 0);

            Assert.Contains(controller.Sequencer.Plan, new RunnerPlan?[]
            {
                new RunnerPlan.Settle(RunnerPose.Unknown, 3),
                new RunnerPlan.Still(RunnerPose.Unknown),
            });
            Assert.Equal(ShimBenchSource.NotFoundMessage, host.Changes[0].Snapshot.Problem);
            Assert.StartsWith("BenchBar: benchbar.exe was not found", host.Tooltip);
            Assert.InRange(host.Tooltip.Length, 1, 127);
            Assert.Equal("needs attention", host.Changes[0].UpText);
        }
    }

    [Fact]
    public async Task AStoppedDistroShowsTheSleepingPoseAndSaysSo()
    {
        var distro = new FakeProbe { Running = false };
        var (controller, host, source, _) = Make(options: new TrayOptions
        {
            ListenToSystemEvents = false,
            DistroProbe = distro,
            Distro = () => "Ubuntu-24.04",
        });
        using (host.Owning(controller))
        {
            host.Ui(controller.Start);
            await UntilAsync(() => host.Changes.Count > 0);

            Assert.True(controller.Snapshot.DistroStopped);
            Assert.Contains(controller.Sequencer.Plan, new RunnerPlan?[]
            {
                new RunnerPlan.Settle(RunnerPose.Sleeping, 3),
                new RunnerPlan.Still(RunnerPose.Sleeping),
            });
            Assert.Equal("BenchBar: Ubuntu-24.04 is not running", host.Tooltip);
            Assert.Equal("distro stopped", host.Changes[0].UpText);
            Assert.Equal(0, source.Lists);
        }
    }

    [Fact]
    public async Task StartDistroStartsKeepaliveAndPollsEveryTwoSecondsUntilTheDistroIsUp()
    {
        var distro = new FakeProbe { Running = false };
        var (controller, host, source, time) = Make(options: new TrayOptions
        {
            ListenToSystemEvents = false,
            DistroProbe = distro,
            Distro = () => "Ubuntu-24.04",
        });
        using (host.Owning(controller))
        {
            host.Ui(controller.Start);
            await UntilAsync(() => host.Changes.Count > 0);
            var calls = distro.Calls;

            // Wait for each poll's reported change, not its probe call: the poller arms the next timer only
            // when the poll has ended (before it reports), so advancing the clock earlier would fire nothing.
            var changes = host.Changes.Count;
            Assert.True(host.Ui(controller.StartDistro));
            Assert.Equal(1, source.DistroStarts);
            await UntilAsync(() => distro.Calls > calls && host.Changes.Count > changes);

            calls = distro.Calls;
            changes = host.Changes.Count;
            time.Advance(TimeSpan.FromSeconds(2));
            await UntilAsync(() => distro.Calls > calls && host.Changes.Count > changes);

            distro.Running = true;
            time.Advance(TimeSpan.FromSeconds(2));
            await UntilAsync(() => !controller.Snapshot.DistroStopped && controller.Snapshot.Benches.Count == 1);
        }
    }

    [Fact]
    public async Task ARestartRunsRestartAndPollsAtOnce()
    {
        var (controller, host, source, _) = Make(BenchState.Running);
        using (host.Owning(controller))
        {
            host.Ui(controller.Start);
            await UntilAsync(() => host.Changes.Count > 0);
            var lists = source.Lists;
            await controller.RestartAsync(Status(BenchState.Running));
            Assert.Equal(["restart --bench-dir /a"], source.Actions);
            await UntilAsync(() => source.Lists > lists);
        }
    }

    [Fact]
    public async Task ActionsKeepPollingFastForAMinute()
    {
        var (controller, host, source, time) = Make(BenchState.Stopped);
        using (host.Owning(controller))
        {
            host.Ui(controller.Start);
            await UntilAsync(() => host.Changes.Count > 0);
            await controller.StartStopAsync(Status(BenchState.Stopped));
            await UntilAsync(() => host.Changes.Count > 1);

            var lists = source.Lists;
            time.Advance(TimeSpan.FromSeconds(2)); // 30 s would be the idle wait
            await UntilAsync(() => source.Lists > lists);
        }
    }

    [Fact]
    public async Task ACrashShowsOneToastAndNotificationsCanBeTurnedOff()
    {
        var (controller, host, source, time) = Make(BenchState.Running);
        using (host.Owning(controller))
        {
            host.Ui(controller.Start);
            await UntilAsync(() => host.Changes.Count > 0);
            Assert.Empty(host.Toasts); // the first snapshot only seeds

            source.Overrides["a"] = Status(BenchState.Crashed, "crash");
            time.Advance(TimeSpan.FromSeconds(30));
            await UntilAsync(() => host.Toasts.Count == 1);
            Assert.Equal("a crashed", host.Toasts[0].Title);

            controller.Notifications = false;
            source.Overrides["a"] = Status(BenchState.Paused, "port_conflict");
            time.Advance(TimeSpan.FromSeconds(120));
            await UntilAsync(() => host.Changes.Count >= 3);
            Assert.Single(host.Toasts);
        }
    }

    [Fact]
    public void ARunnerCanBeSwitchedAndAnUnknownIdFallsBackToTheBench()
    {
        var (controller, host, _, _) = Make();
        using (host.Owning(controller))
        {
            host.Ui(controller.Start);
            host.Ui(() => controller.SetRunner("cup"));
            Assert.Equal("cup", controller.Icons.Runner.Id);
            Assert.NotEmpty(host.Icons);
            host.Ui(() => controller.SetRunner("no-such-runner"));
            Assert.Equal("bench", controller.Icons.Runner.Id);
        }
    }

    [Fact]
    public void TheTooltipIsAtMostOneHundredTwentySevenCharacters()
    {
        var snapshot = new TraySnapshot([], Problem: new string('x', 400));
        Assert.Equal(127, TrayController.Tooltip(snapshot, "").Length);
    }
}
