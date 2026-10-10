using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

public class SequencerTests
{
    private readonly FakeFrameClock _clock = new();
    private readonly List<(RunnerPose Pose, int Frame)> _shown = [];
    private readonly FrameSequencer _sequencer;

    public SequencerTests() =>
        _sequencer = new FrameSequencer(_clock, (p, f) => _shown.Add((p, f)), BenchRunnerArt.FrameCount);

    private static TimeSpan Fps(double fps) => TimeSpan.FromSeconds(1 / fps);

    /// <summary>Fires ticks until nothing is pending, up to a limit (a loop never ends).</summary>
    private int Drain(int limit = 1000)
    {
        var fired = 0;
        while (_clock.HasPending && fired < limit)
        {
            _clock.Fire();
            fired++;
        }
        return fired;
    }

    [Fact]
    public void SettleSleepingPlaysThreeLoopsThenRestsWithNoTimer()
    {
        _sequencer.Play(new RunnerPlan.Settle(RunnerPose.Sleeping, 3));

        Assert.Equal((RunnerPose.Sleeping, 0), _shown[0]);
        Assert.Equal(Fps(2), _clock.PendingDelay);

        var ticks = Drain();

        Assert.Equal(12, ticks); // 3 loops of 4 frames, then the rest frame
        Assert.Equal(13, _shown.Count);
        Assert.Equal(Enumerable.Range(0, 4).Concat(Enumerable.Range(0, 4)).Concat(Enumerable.Range(0, 4)).Append(0),
            _shown.Select(s => s.Frame));
        Assert.All(_shown, s => Assert.Equal(RunnerPose.Sleeping, s.Pose));
        Assert.False(_clock.HasPending);
        Assert.Null(_clock.PendingDelay);
        Assert.False(_sequencer.IsAnimating);
    }

    [Fact]
    public void SettleOfASingleFramePoseSchedulesNothing()
    {
        _sequencer.Play(new RunnerPlan.Settle(RunnerPose.Unknown, 3));
        Assert.Equal([(RunnerPose.Unknown, 0)], _shown);
        Assert.False(_clock.HasPending);
    }

    [Fact]
    public void StumbleThenHeldAlert()
    {
        _sequencer.Play(new RunnerPlan.Stumble(3, RunnerPose.Alert));
        Assert.Equal(Fps(8), _clock.PendingDelay);

        var ticks = Drain();

        Assert.Equal(12, ticks);
        Assert.Equal(13, _shown.Count);
        Assert.Equal(Enumerable.Range(0, 12).Select(i => (RunnerPose.Crashed, i % 4)), _shown.Take(12));
        Assert.Equal((RunnerPose.Alert, 0), _shown[^1]);
        Assert.False(_clock.HasPending); // held: no timer
        Assert.False(_sequencer.IsAnimating);
    }

    [Fact]
    public void StumbleRunsAtEightFpsPerFrame()
    {
        _sequencer.Play(new RunnerPlan.Stumble(3, RunnerPose.Alert));
        for (var i = 0; i < 12; i++)
        {
            Assert.Equal(Fps(8), _clock.PendingDelay);
            _clock.Fire();
        }
        Assert.False(_clock.HasPending);
    }

    [Fact]
    public void LoopWrapsForever()
    {
        _sequencer.Play(new RunnerPlan.Loop(RunnerPose.Starting));
        Assert.Equal(Fps(6), _clock.PendingDelay);
        Assert.Equal(1000, Drain(1000));
        Assert.True(_clock.HasPending);
        Assert.Equal(Enumerable.Range(0, 7).Select(i => i % 6), _shown.Take(7).Select(s => s.Frame));
        Assert.All(_shown, s => Assert.Equal(RunnerPose.Starting, s.Pose));
    }

    [Fact]
    public void RunningFpsFollowsSpeedAndCapsAtThirty()
    {
        _sequencer.Play(new RunnerPlan.Loop(RunnerPose.Running));
        Assert.Equal(Fps(5), _clock.PendingDelay);

        _sequencer.SetSpeed(2);
        _clock.Fire();
        Assert.Equal(Fps(10), _clock.PendingDelay);

        _sequencer.SetSpeed(6);
        _clock.Fire();
        Assert.Equal(Fps(30), _clock.PendingDelay);

        _sequencer.SetSpeed(12);
        _clock.Fire();
        Assert.Equal(Fps(30), _clock.PendingDelay); // 5 * 12 = 60, capped

        _sequencer.SetSpeed(1000);
        Assert.Equal(12, _sequencer.Speed); // clamped

        _sequencer.SetSpeed(0);
        _clock.Fire();
        Assert.Equal(1, _sequencer.Speed);
        Assert.Equal(Fps(5), _clock.PendingDelay);
    }

    [Fact]
    public void SpeedMovesUnderPointZeroFiveAreIgnored()
    {
        _sequencer.SetSpeed(3);
        _sequencer.SetSpeed(3.04);
        Assert.Equal(3, _sequencer.Speed);
        _sequencer.SetSpeed(3.06);
        Assert.Equal(3.06, _sequencer.Speed);
    }

    [Fact]
    public void OtherPosesIgnoreSpeed()
    {
        _sequencer.SetSpeed(12);
        _sequencer.Play(new RunnerPlan.Loop(RunnerPose.Starting));
        Assert.Equal(Fps(6), _clock.PendingDelay);

        _sequencer.Play(new RunnerPlan.Still(RunnerPose.Running)); // reduce motion shows one frame
        Assert.False(_clock.HasPending);
    }

    [Fact]
    public void ThePlanOnlyRestartsWhenItChanges()
    {
        var crashed = RunnerPlan.ForState(BenchState.Crashed, false);
        _sequencer.Play(crashed);
        _clock.Fire();
        _clock.Fire();
        var shown = _shown.Count;

        _sequencer.Play(RunnerPlan.ForState(BenchState.Paused, false)); // crashed to paused: same plan

        Assert.Equal(shown, _shown.Count);
        Assert.True(_clock.HasPending);
        Assert.Equal(Fps(8), _clock.PendingDelay);
        Assert.Equal(3, _shown.Count);
    }

    [Fact]
    public void ANewPlanCancelsThePendingTickAndStartsFromItsFirstFrame()
    {
        _sequencer.Play(new RunnerPlan.Loop(RunnerPose.Starting));
        _clock.Fire();
        _sequencer.Play(new RunnerPlan.Loop(RunnerPose.Running));

        Assert.Equal((RunnerPose.Running, 0), _shown[^1]);
        Assert.Equal(Fps(5), _clock.PendingDelay);
    }

    [Fact]
    public void StillShowsOneFrameAndNoTimer()
    {
        _sequencer.Play(new RunnerPlan.Still(RunnerPose.Sleeping));
        Assert.Equal([(RunnerPose.Sleeping, 0)], _shown);
        Assert.False(_clock.HasPending);
    }

    [Fact]
    public void PauseDropsTheTimerAndResumeContinuesFromTheSameFrame()
    {
        _sequencer.Play(new RunnerPlan.Loop(RunnerPose.Running));
        _clock.Fire();
        _clock.Fire();
        var shown = _shown.Count;

        _sequencer.Pause();
        Assert.False(_clock.HasPending);
        Assert.True(_sequencer.IsPaused);

        _sequencer.Resume();
        Assert.True(_clock.HasPending);
        Assert.Equal(shown, _shown.Count);
        _clock.Fire();
        Assert.Equal((RunnerPose.Running, 3), _shown[^1]);
    }

    [Fact]
    public void PauseAndResumeAtRestScheduleNothing()
    {
        _sequencer.Play(new RunnerPlan.Settle(RunnerPose.Sleeping, 1));
        Drain();
        _sequencer.Pause();
        _sequencer.Resume();
        Assert.False(_clock.HasPending);
    }

    [Fact]
    public void APlanStartedWhilePausedWaitsForResume()
    {
        _sequencer.Pause();
        _sequencer.Play(new RunnerPlan.Loop(RunnerPose.Starting));
        Assert.False(_clock.HasPending);
        Assert.Single(_shown);
        _sequencer.Resume();
        Assert.True(_clock.HasPending);
    }

    [Fact]
    public void RefreshShowsTheCurrentFrameAgain()
    {
        _sequencer.Play(new RunnerPlan.Loop(RunnerPose.Starting));
        _clock.Fire();
        var count = _shown.Count;
        _sequencer.Refresh();
        Assert.Equal(count + 1, _shown.Count);
        Assert.Equal(_shown[^2], _shown[^1]);
    }

    [Fact]
    public void ARestedSettleSchedulesNothingForALongTime()
    {
        _sequencer.Play(RunnerPlan.ForState(BenchState.Stopped, false));
        Drain();
        var scheduled = _clock.ScheduleCount;
        Assert.False(_clock.HasPending);
        _sequencer.SetSpeed(5);
        _sequencer.Play(RunnerPlan.ForState(BenchState.Stopped, false));
        Assert.Equal(scheduled, _clock.ScheduleCount);
        Assert.False(_clock.HasPending);
    }
}
