using BenchBar.Tray.Core;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace Tray.Core.Tests;

public class PollerDistroTests
{
    private static TimeSpan S(double seconds) => TimeSpan.FromSeconds(seconds);

    private static (BenchPoller Poller, ScriptedSource Source, FakeTimeProvider Time, PollerTests.Probe Probe, FakeProbe Distro) Make(
        bool running, BenchState state = BenchState.Stopped)
    {
        var distro = new FakeProbe { Running = running };
        var (poller, source, time, probe) = PollerTests.Make(state, distro);
        return (poller, source, time, probe, distro);
    }

    [Fact]
    public async Task AStoppedDistroGetsNoListOrStatusCallAndIsReported()
    {
        var (poller, source, _, probe, distro) = Make(running: false);
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();

            var snapshot = poller.Last;
            Assert.True(snapshot.DistroStopped);
            Assert.Equal("Ubuntu-24.04", snapshot.Distro);
            Assert.Empty(snapshot.Benches);
            Assert.Null(snapshot.Problem);
            Assert.Equal(1, distro.Calls);
            Assert.Equal(0, source.Lists);
            Assert.Equal(0, source.Statuses);
        }
    }

    [Fact]
    public async Task TheProbeBacksOffThirtySixtyOneTwentyThreeHundredWhileTheDistroIsStopped()
    {
        var (poller, source, time, probe, distro) = Make(running: false);
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();
            var calls = 1;
            foreach (var seconds in new double[] { 30, 60, 120, 300, 300 })
            {
                time.Advance(S(seconds - 0.5));
                await probe.NoneForAsync(100);
                Assert.Equal(calls, distro.Calls);
                time.Advance(S(0.5));
                await probe.NextAsync();
                Assert.Equal(++calls, distro.Calls);
            }
            Assert.Equal(0, source.Lists);
        }
    }

    [Fact]
    public async Task AnOpenFlyoutProbesEveryFiveSecondsAndAKickResetsTheBackOff()
    {
        var (poller, source, time, probe, distro) = Make(running: false);
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();
            time.Advance(S(30));
            await probe.NextAsync();
            time.Advance(S(60));
            await probe.NextAsync(); // the next wait is 120 s

            poller.SetFlyoutOpen(true);
            time.Advance(S(5));
            await probe.NextAsync();
            poller.SetFlyoutOpen(false);

            poller.Kick();
            await probe.NextAsync();
            time.Advance(S(29.5));
            await probe.NoneForAsync(100);
            time.Advance(S(0.5)); // back at 30 s, not 120
            await probe.NextAsync();
            Assert.Equal(0, source.Lists);
            Assert.Equal(6, distro.Calls);
        }
    }

    [Fact]
    public async Task WhenTheDistroComesUpTheNextPollReadsTheBenches()
    {
        var (poller, source, time, probe, distro) = Make(running: false, BenchState.Running);
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();
            Assert.True(poller.Last.DistroStopped);

            distro.Running = true;
            time.Advance(S(30));
            await probe.NextAsync();

            Assert.False(poller.Last.DistroStopped);
            Assert.Equal(BenchState.Running, Assert.Single(poller.Last.Benches).State);
            Assert.Equal(1, source.Lists);
        }
    }

    [Fact]
    public async Task AProbeThatFailsIsAProblemAndTheCliIsNeverAsked()
    {
        var (poller, source, time, probe, distro) = Make(running: true, BenchState.Running);
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();
            Assert.Equal(1, source.Lists);

            distro.Throws = new TimeoutException("wsl.exe hung");
            time.Advance(S(30));
            await probe.NextAsync();

            Assert.Equal(BenchPoller.WslSilentMessage, poller.Last.Problem);
            Assert.Equal("wsl.exe did not answer: WSL may be starting or stuck. Run wsl.exe --status.", poller.Last.Problem);
            Assert.False(poller.Last.DistroStopped);
            Assert.Equal(BenchState.Unknown, Assert.Single(poller.Last.Benches).State); // the last benches, as unknown
            Assert.Equal(1, source.Lists); // no list or status call: that could boot the distro
            Assert.Equal(1, source.Statuses);
        }
    }

    [Fact]
    public async Task AMissingWslExeIsItsOwnProblem()
    {
        var (poller, source, _, probe, distro) = Make(running: true);
        distro.Throws = new System.ComponentModel.Win32Exception("The system cannot find the file specified");
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();
            Assert.Equal("WSL is not installed: wsl.exe --install", poller.Last.Problem);
            Assert.Equal(0, source.Lists);
        }
    }

    [Fact]
    public async Task AFailingProbeBacksOffOnTheIdleStepsAndAKickResetsIt()
    {
        var (poller, source, time, probe, distro) = Make(running: true);
        distro.Throws = new TimeoutException();
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();
            foreach (var seconds in new double[] { 30, 60, 120 })
            {
                time.Advance(S(seconds - 0.5));
                await probe.NoneForAsync(100);
                time.Advance(S(0.5));
                await probe.NextAsync();
            }

            poller.Kick();
            await probe.NextAsync();
            time.Advance(S(29.5)); // reset: 30 s again, not 300
            await probe.NoneForAsync(100);
            time.Advance(S(0.5));
            await probe.NextAsync();
            Assert.Equal(0, source.Lists);
        }
    }

    [Fact]
    public async Task WithoutADistroNameTheGateIsSkipped()
    {
        var distro = new FakeProbe { Running = false };
        var source = new ScriptedSource();
        var time = new FakeTimeProvider();
        using var poller = new BenchPoller(source, time, distro, () => null);
        using var probe = new PollerTests.Probe(poller);
        poller.Start();
        await probe.NextAsync();
        Assert.Equal(0, distro.Calls);
        Assert.Equal(1, source.Lists);
    }

    [Fact]
    public async Task AnActionBoostPollsEveryTwoSecondsForAMinuteThenBacksOffNormally()
    {
        var (poller, _, time, probe, _) = Make(running: true);
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();

            poller.BoostFor(BenchPoller.ActionBoost);
            await probe.NextAsync();
            for (var i = 0; i < 30; i++)
            {
                time.Advance(S(2));
                await probe.NextAsync();
            }

            time.Advance(S(29.5)); // the boost is over: the idle 30 s again
            await probe.NoneForAsync(100);
            time.Advance(S(0.5));
            await probe.NextAsync();
        }
    }

    [Fact]
    public async Task StartingTheDistroPollsFastUntilItIsUp()
    {
        var (poller, _, time, probe, distro) = Make(running: false);
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();

            poller.BoostFor(BenchPoller.ActionBoost, untilDistroUp: true);
            await probe.NextAsync();
            Assert.True(poller.Last.DistroStopped);
            for (var i = 0; i < 3; i++)
            {
                time.Advance(S(2));
                await probe.NextAsync();
                Assert.True(poller.Last.DistroStopped);
            }

            distro.Running = true;
            time.Advance(S(2));
            await probe.NextAsync();
            Assert.False(poller.Last.DistroStopped);

            time.Advance(S(29.5)); // up: the fast window ended with it
            await probe.NoneForAsync(100);
            time.Advance(S(0.5));
            await probe.NextAsync();
        }
    }

    [Fact]
    public async Task ASetupProblemIsCarriedAsTheOneLineFix()
    {
        var (poller, source, _, probe) = PollerTests.Make();
        source.ListFails = new SetupProblemException(ShimBenchSource.NotFoundMessage);
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();
            Assert.Equal(ShimBenchSource.NotFoundMessage, poller.Last.Problem);
            Assert.Empty(poller.Last.Benches);
            Assert.False(poller.Last.DistroStopped);
        }
    }

    [Fact]
    public async Task OneBenchThatCannotBeReadIsUnknownWithItsOwnLineAndTheSnapshotHasNoProblem()
    {
        var (poller, source, _, probe) = PollerTests.Make(BenchState.Crashed);
        source.Entries.Add(new BenchEntry("b", "/b", false, null)); // no state for b: its status call throws
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();
            Assert.Null(poller.Last.Problem);
            Assert.Equal(BenchState.Crashed, poller.Last.Benches[0].State);
            Assert.Null(poller.Last.Benches[0].Problem);
            Assert.Equal(BenchState.Unknown, poller.Last.Benches[1].State);
            Assert.Equal("benchbar.exe status gave no usable answer.", poller.Last.Benches[1].Problem);
        }
    }

    [Fact]
    public async Task ASourceProblemOfOneBenchKeepsItsMessage()
    {
        var (poller, source, _, probe) = PollerTests.Make();
        source.StatusFails = new CliProblemException("bench dir is gone");
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();
            Assert.Null(poller.Last.Problem);
            Assert.Equal("bench dir is gone", Assert.Single(poller.Last.Benches).Problem);
        }
    }

    [Fact]
    public async Task ACliFailureAfterASuccessShowsTheKnownBenchesAsUnknownWithTheProblem()
    {
        var (poller, source, time, probe) = PollerTests.Make(BenchState.Running);
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();
            Assert.Null(poller.Last.Problem);

            source.ListFails = new CliProblemException("no distro: run benchbar.exe adopt-distro");
            time.Advance(S(30));
            await probe.NextAsync();

            Assert.Equal("no distro: run benchbar.exe adopt-distro", poller.Last.Problem);
            var bench = Assert.Single(poller.Last.Benches);
            Assert.Equal(BenchState.Unknown, bench.State);
            Assert.Equal("a", bench.Name);
        }
    }

    [Fact]
    public async Task AnUntypedFailureGivesAGenericLine()
    {
        var (poller, source, _, probe) = PollerTests.Make();
        source.ListFails = new System.Text.Json.JsonException("bad");
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();
            Assert.Contains("benchbar.exe", poller.Last.Problem);
        }
    }

    [Fact]
    public void BoostBeatsEveryOtherDelay()
    {
        Assert.Equal(S(2), BenchPoller.NextDelay([BenchState.Running], flyoutOpen: false, idleStep: 0, boost: true));
        Assert.Equal(S(2), BenchPoller.NextDelay([], flyoutOpen: true, idleStep: 3, boost: true));
        Assert.Equal(S(5), BenchPoller.NextDelay([], flyoutOpen: true, idleStep: 3));
    }
}
