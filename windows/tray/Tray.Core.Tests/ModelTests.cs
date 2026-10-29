using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

public class AggregateTests
{
    [Theory]
    [InlineData(new BenchState[0], BenchState.Unknown)]
    [InlineData(new[] { BenchState.Unknown, BenchState.Unknown }, BenchState.Unknown)]
    [InlineData(new[] { BenchState.Stopped }, BenchState.Stopped)]
    [InlineData(new[] { BenchState.Stopped, BenchState.Unknown }, BenchState.Stopped)]
    [InlineData(new[] { BenchState.Running, BenchState.Stopped }, BenchState.Running)]
    [InlineData(new[] { BenchState.Running, BenchState.Starting }, BenchState.Starting)]
    [InlineData(new[] { BenchState.Starting, BenchState.Paused, BenchState.Running }, BenchState.Paused)]
    [InlineData(new[] { BenchState.Paused, BenchState.Crashed }, BenchState.Crashed)]
    [InlineData(new[] { BenchState.Unknown, BenchState.Crashed, BenchState.Running }, BenchState.Crashed)]
    public void WorstStateWins(BenchState[] states, BenchState expected) =>
        Assert.Equal(expected, BenchAggregate.State(states));

    [Fact]
    public void UpTextCountsRunningAndStarting()
    {
        Assert.Equal("none up", BenchAggregate.UpText([]));
        Assert.Equal("none up", BenchAggregate.UpText([BenchState.Stopped, BenchState.Crashed]));
        Assert.Equal("2 of 3 up", BenchAggregate.UpText([BenchState.Running, BenchState.Starting, BenchState.Paused]));
        Assert.Equal("1 of 1 up", BenchAggregate.UpText([BenchState.Running]));
    }

    [Fact]
    public void TooltipNamesTheCountAndTheUpText()
    {
        Assert.Equal("BenchBar: 2 benches, none up", TrayController.Tooltip(2, "none up"));
        Assert.Equal("BenchBar: 1 bench, 1 of 1 up", TrayController.Tooltip(1, "1 of 1 up"));
    }
}

public class PlanTests
{
    [Theory]
    [InlineData(BenchState.Stopped, false, "Settle", RunnerPose.Sleeping)]
    [InlineData(BenchState.Starting, false, "Loop", RunnerPose.Starting)]
    [InlineData(BenchState.Running, false, "Loop", RunnerPose.Running)]
    [InlineData(BenchState.Unknown, false, "Settle", RunnerPose.Unknown)]
    [InlineData(BenchState.Stopped, true, "Still", RunnerPose.Sleeping)]
    [InlineData(BenchState.Starting, true, "Still", RunnerPose.Starting)]
    [InlineData(BenchState.Running, true, "Still", RunnerPose.Running)]
    [InlineData(BenchState.Crashed, true, "Still", RunnerPose.Alert)]
    [InlineData(BenchState.Paused, true, "Still", RunnerPose.Alert)]
    [InlineData(BenchState.Unknown, true, "Still", RunnerPose.Unknown)]
    public void ForStateFollowsTheMacTable(BenchState state, bool reduceMotion, string kind, RunnerPose pose)
    {
        var plan = RunnerPlan.ForState(state, reduceMotion);
        Assert.Equal(kind, plan.GetType().Name);
        RunnerPlan expected = kind switch
        {
            "Settle" => new RunnerPlan.Settle(pose, 3),
            "Loop" => new RunnerPlan.Loop(pose),
            _ => new RunnerPlan.Still(pose),
        };
        Assert.Equal(expected, plan);
    }

    [Theory]
    [InlineData(BenchState.Crashed)]
    [InlineData(BenchState.Paused)]
    public void CrashedAndPausedStumbleThreeTimesThenAlert(BenchState state) =>
        Assert.Equal(new RunnerPlan.Stumble(3, RunnerPose.Alert), RunnerPlan.ForState(state, false));

    [Fact]
    public void CrashedAndPausedAreTheSamePlan() =>
        Assert.Equal(RunnerPlan.ForState(BenchState.Crashed, false), RunnerPlan.ForState(BenchState.Paused, false));

    [Fact]
    public void OnlyTheRunningLoopFollowsSpeed()
    {
        Assert.True(RunnerPlan.ForState(BenchState.Running, false).FollowsSpeed);
        Assert.False(RunnerPlan.ForState(BenchState.Running, true).FollowsSpeed);
        Assert.False(RunnerPlan.ForState(BenchState.Starting, false).FollowsSpeed);
        Assert.False(RunnerPlan.ForState(BenchState.Stopped, false).FollowsSpeed);
    }

    [Fact]
    public void BaseFpsMatchesTheMac()
    {
        Assert.Equal(2, RunnerPose.Sleeping.BaseFps());
        Assert.Equal(6, RunnerPose.Starting.BaseFps());
        Assert.Equal(5, RunnerPose.Running.BaseFps());
        Assert.Equal(8, RunnerPose.Crashed.BaseFps());
        Assert.Equal(2, RunnerPose.Alert.BaseFps());
        Assert.Equal(2, RunnerPose.Unknown.BaseFps());
        Assert.Equal(30, RunnerPoses.MaxFps);
    }
}

public class SpeedTests
{
    [Theory]
    [InlineData(0, 1)]
    [InlineData(-50, 1)]
    [InlineData(10, 2)]
    [InlineData(55, 6.5)]
    [InlineData(110, 12)]
    [InlineData(250, 12)]
    [InlineData(double.NaN, 1)]
    [InlineData(double.PositiveInfinity, 1)]
    [InlineData(double.NegativeInfinity, 1)]
    public void SpeedIsOnePlusCpuOverTenClamped(double cpu, double expected) =>
        Assert.Equal(expected, SpeedMapping.Speed(cpu), 10);

    [Fact]
    public void SmootherStartsAtOneAndAveragesWithAlpha()
    {
        var smoother = new SpeedSmoother();
        Assert.Equal(1, smoother.Value);
        Assert.Equal(0.35, smoother.Alpha);
        Assert.Equal(0.35 * 12 + 0.65 * 1, smoother.Add(12), 10);
        var second = smoother.Add(12);
        Assert.Equal(0.35 * 12 + 0.65 * (0.35 * 12 + 0.65), second, 10);
        Assert.Equal(second, smoother.Value);
    }

    [Fact]
    public void SmootherConvergesAndResets()
    {
        var smoother = new SpeedSmoother();
        for (var i = 0; i < 40; i++) smoother.Add(12);
        Assert.Equal(12, smoother.Value, 3);
        smoother.Reset();
        Assert.Equal(1, smoother.Value);
    }
}
