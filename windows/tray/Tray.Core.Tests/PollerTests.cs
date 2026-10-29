using BenchBar.Tray.Core;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace Tray.Core.Tests;

public class PollerTests
{
    private static readonly TimeSpan Wait = TimeSpan.FromSeconds(10);

    private static TimeSpan S(double seconds) => TimeSpan.FromSeconds(seconds);

    [Theory]
    [InlineData(new[] { BenchState.Stopped }, false, 0, 30)]
    [InlineData(new[] { BenchState.Stopped }, false, 1, 60)]
    [InlineData(new[] { BenchState.Stopped }, false, 2, 120)]
    [InlineData(new[] { BenchState.Stopped }, false, 3, 300)]
    [InlineData(new[] { BenchState.Stopped }, false, 99, 300)]
    [InlineData(new[] { BenchState.Stopped }, false, -4, 30)]
    [InlineData(new[] { BenchState.Crashed, BenchState.Paused, BenchState.Unknown }, false, 2, 120)]
    [InlineData(new BenchState[0], false, 0, 30)]
    [InlineData(new[] { BenchState.Running, BenchState.Stopped }, false, 3, 30)]
    [InlineData(new[] { BenchState.Starting, BenchState.Running }, false, 3, 2)]
    [InlineData(new[] { BenchState.Starting }, false, 0, 2)]
    [InlineData(new[] { BenchState.Stopped }, true, 3, 5)]
    [InlineData(new[] { BenchState.Starting }, true, 0, 5)]
    public void NextDelayTable(BenchState[] states, bool flyoutOpen, int step, double seconds) =>
        Assert.Equal(S(seconds), BenchPoller.NextDelay(states, flyoutOpen, step));

    /// <summary>Counts polls as they end; the timer is already re-armed when the event fires.</summary>
    private sealed class Probe : IDisposable
    {
        private readonly SemaphoreSlim _updates = new(0);
        private int _count;

        public Probe(BenchPoller poller) => poller.Updated += _ =>
        {
            Interlocked.Increment(ref _count);
            _updates.Release();
        };

        public int Count => Volatile.Read(ref _count);

        public async Task NextAsync() =>
            Assert.True(await _updates.WaitAsync(Wait, TestContext.Current.CancellationToken), "no poll finished in time");

        public async Task NoneForAsync(int milliseconds)
        {
            await Task.Delay(milliseconds, TestContext.Current.CancellationToken);
            Assert.Equal(0, _updates.CurrentCount);
        }

        public void Dispose() => _updates.Dispose();
    }

    private static (BenchPoller Poller, ScriptedSource Source, FakeTimeProvider Time, Probe Probe) Make(BenchState state = BenchState.Stopped)
    {
        var source = new ScriptedSource();
        source.States["a"] = state;
        var time = new FakeTimeProvider();
        var poller = new BenchPoller(source, time);
        return (poller, source, time, new Probe(poller));
    }

    [Fact]
    public async Task StartPollsAtOnceAndReportsTheBenches()
    {
        var (poller, source, _, probe) = Make(BenchState.Running);
        source.CpuPercent = 40;
        IReadOnlyList<BenchStatus>? seen = null;
        poller.Updated += s => seen = s;
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();
            Assert.Equal(BenchState.Running, Assert.Single(seen!).State);
            Assert.Equal(40, poller.CpuPercent);
            Assert.Single(poller.Last);
        }
    }

    [Fact]
    public async Task IdleBenchesBackOffThirtySixtyOneTwentyThenThreeHundred()
    {
        var (poller, _, time, probe) = Make();
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();

            foreach (var seconds in new double[] { 30, 60, 120, 300, 300 })
            {
                time.Advance(S(seconds - 0.5));
                await probe.NoneForAsync(100);
                time.Advance(S(0.5));
                await probe.NextAsync();
            }
        }
    }

    [Fact]
    public async Task KickPollsNowAndResetsTheBackOff()
    {
        var (poller, source, time, probe) = Make();
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();
            time.Advance(S(30));
            await probe.NextAsync();
            time.Advance(S(60));
            await probe.NextAsync(); // the next wait is now 120 s

            poller.Kick();
            await probe.NextAsync();
            Assert.Equal(4, source.Lists);

            time.Advance(S(29.5));
            await probe.NoneForAsync(100);
            time.Advance(S(0.5)); // back at 30 s, not 120
            await probe.NextAsync();
        }
    }

    [Fact]
    public async Task RunningBenchesPollEveryThirtySecondsStartingEveryTwo()
    {
        var (poller, source, time, probe) = Make(BenchState.Running);
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();
            for (var i = 0; i < 3; i++)
            {
                time.Advance(S(30));
                await probe.NextAsync();
            }

            source.States["a"] = BenchState.Starting;
            time.Advance(S(30));
            await probe.NextAsync();
            for (var i = 0; i < 3; i++)
            {
                time.Advance(S(2));
                await probe.NextAsync();
            }
        }
    }

    [Fact]
    public async Task OpeningTheFlyoutRearmsTheTimerAtFiveSeconds()
    {
        var (poller, _, time, probe) = Make();
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();

            poller.SetFlyoutOpen(true);
            time.Advance(S(4.9));
            await probe.NoneForAsync(100);
            time.Advance(S(0.1));
            await probe.NextAsync();

            poller.SetFlyoutOpen(false);
            time.Advance(S(29.9));
            await probe.NoneForAsync(100);
            time.Advance(S(0.1));
            await probe.NextAsync();
        }
    }

    [Fact]
    public async Task KicksDuringAPollAreCoalescedIntoOneMorePollAndCallsNeverOverlap()
    {
        var (poller, source, _, probe) = Make();
        source.Latency = TimeSpan.FromMilliseconds(300);
        using (poller)
        using (probe)
        {
            poller.Start();
            await Task.Delay(50, TestContext.Current.CancellationToken); // inside the first poll
            for (var i = 0; i < 6; i++) poller.Kick();

            await probe.NextAsync();
            await probe.NextAsync();
            await Task.Delay(700, TestContext.Current.CancellationToken);

            Assert.Equal(2, probe.Count);
            Assert.Equal(2, source.Lists);
            Assert.Equal(1, source.MaxConcurrent);
        }
    }

    [Fact]
    public async Task SuspendMeansNoTimerAtAllUntilResume()
    {
        var (poller, source, time, probe) = Make();
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();

            poller.Suspend();
            time.Advance(TimeSpan.FromHours(3));
            poller.Kick(); // an action while suspended does not poll either
            await probe.NoneForAsync(200);
            Assert.Equal(1, source.Lists);

            poller.Resume();
            await probe.NextAsync();
            Assert.Equal(2, source.Lists);
            time.Advance(S(30));
            await probe.NextAsync();
        }
    }

    [Fact]
    public async Task SuspendDuringAPollLeavesNoTimerBehind()
    {
        var (poller, source, time, probe) = Make();
        source.Latency = TimeSpan.FromMilliseconds(250);
        using (poller)
        using (probe)
        {
            poller.Start();
            await Task.Delay(50, TestContext.Current.CancellationToken);
            poller.Suspend();
            await probe.NextAsync(); // the poll in progress still reports
            time.Advance(TimeSpan.FromHours(1));
            await probe.NoneForAsync(200);
            Assert.Equal(1, source.Lists);
        }
    }

    [Fact]
    public async Task ABenchThatFailsToAnswerIsUnknown()
    {
        var (poller, source, _, probe) = Make(BenchState.Running);
        IReadOnlyList<BenchStatus>? seen = null;
        poller.Updated += s => seen = s;
        using (poller)
        using (probe)
        {
            source.States.Clear(); // StatusAsync now throws
            poller.Start();
            await probe.NextAsync();
            var status = Assert.Single(seen!);
            Assert.Equal(BenchState.Unknown, status.State);
            Assert.Equal("a", status.Name);
        }
    }

    [Fact]
    public async Task DisposeStopsPolling()
    {
        var (poller, source, time, probe) = Make();
        poller.Start();
        await probe.NextAsync();
        poller.Dispose();
        time.Advance(TimeSpan.FromHours(1));
        await probe.NoneForAsync(200);
        Assert.Equal(1, source.Lists);
        probe.Dispose();
    }
}
