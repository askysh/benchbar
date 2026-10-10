namespace BenchBar.Tray.Core;

/// <summary>The sets of frames a runner has. Same names as RunnerPose in the Mac app.</summary>
public enum RunnerPose { Sleeping, Starting, Running, Crashed, Alert, Unknown }

public static class RunnerPoses
{
    /// <summary>The fastest any pose plays, whatever speed the load asks for.</summary>
    public const double MaxFps = 30;

    /// <summary>Frames per second at speed 1. Only running speeds up with load.</summary>
    public static double BaseFps(this RunnerPose pose) => pose switch
    {
        RunnerPose.Sleeping => 2,
        RunnerPose.Starting => 6,
        RunnerPose.Running => 5,
        RunnerPose.Crashed => 8,
        RunnerPose.Alert => 2,
        _ => 2,
    };
}

/// <summary>What the tray icon plays for one state: the Mac's RunnerPlan.</summary>
public abstract record RunnerPlan
{
    public const int StumbleTimes = 3;
    public const int SettleTimes = 3;

    /// <summary>Loop the pose's frames forever.</summary>
    public sealed record Loop(RunnerPose Pose) : RunnerPlan;

    /// <summary>Loop the pose <c>Times</c> times, then hold its first frame (no timer after that).</summary>
    public sealed record Settle(RunnerPose Pose, int Times) : RunnerPlan;

    /// <summary>Play the crashed frames <c>Times</c> times, then the alert pose, and hold it.</summary>
    public sealed record Stumble(int Times, RunnerPose Then) : RunnerPlan;

    /// <summary>One frame, no animation (reduce motion).</summary>
    public sealed record Still(RunnerPose Pose) : RunnerPlan;

    /// <summary>Only the running loop follows the speed source.</summary>
    public bool FollowsSpeed => this is Loop { Pose: RunnerPose.Running };

    public static RunnerPlan ForState(BenchState state, bool reduceMotion) => (state, reduceMotion) switch
    {
        (BenchState.Stopped, false) => new Settle(RunnerPose.Sleeping, SettleTimes),
        (BenchState.Stopped, true) => new Still(RunnerPose.Sleeping),
        (BenchState.Starting, false) => new Loop(RunnerPose.Starting),
        (BenchState.Starting, true) => new Still(RunnerPose.Starting),
        (BenchState.Running, false) => new Loop(RunnerPose.Running),
        (BenchState.Running, true) => new Still(RunnerPose.Running),
        (BenchState.Crashed or BenchState.Paused, false) => new Stumble(StumbleTimes, RunnerPose.Alert),
        (BenchState.Crashed or BenchState.Paused, true) => new Still(RunnerPose.Alert),
        (_, false) => new Settle(RunnerPose.Unknown, SettleTimes),
        (_, true) => new Still(RunnerPose.Unknown),
    };
}

/// <summary>
/// A clock with ONE pending one shot callback. Each shell implements it with
/// its own UI dispatcher timer, so ticks run on the UI thread and the cost of
/// each dispatcher is part of what the spike measures.
/// </summary>
public interface IFrameClock
{
    /// <summary>Calls <paramref name="tick"/> once after <paramref name="delay"/>, replacing any pending call.</summary>
    void Schedule(TimeSpan delay, Action tick);

    /// <summary>Drops the pending call, if any.</summary>
    void Cancel();
}

/// <summary>
/// Plays a <see cref="RunnerPlan"/> through an <see cref="IFrameClock"/>. Not
/// thread safe: call it from the thread the clock ticks on. At rest (a settled
/// or held plan) nothing is scheduled, so an idle tray costs no wakeups.
/// </summary>
public sealed class FrameSequencer
{
    private readonly record struct Step(RunnerPose Pose, int Frame, double Fps);

    private readonly IFrameClock _clock;
    private readonly Action<RunnerPose, int> _showFrame;
    private readonly Func<RunnerPose, int> _frameCount;

    private RunnerPlan? _plan;
    private List<Step> _steps = [];
    private bool _loops;
    private int _index;
    private double _speed = SpeedMapping.Min;
    private bool _paused;

    public FrameSequencer(IFrameClock clock, Action<RunnerPose, int> showFrame, Func<RunnerPose, int> frameCount)
    {
        _clock = clock;
        _showFrame = showFrame;
        _frameCount = frameCount;
    }

    public RunnerPlan? Plan => _plan;

    public double Speed => _speed;

    public bool IsPaused => _paused;

    /// <summary>True while a tick is pending, false at rest.</summary>
    public bool IsAnimating => !_paused && HasNext;

    /// <summary>Plays a plan from its start. The same plan again is a no op: crashed to paused does not restart the stumble.</summary>
    public void Play(RunnerPlan plan)
    {
        if (plan == _plan) return;
        _plan = plan;
        _clock.Cancel();
        Build(plan);
        _index = 0;
        Show();
        ScheduleNext();
    }

    /// <summary>Speed of the running loop, clamped to 1..12; a move under 0.05 is ignored.</summary>
    public void SetSpeed(double speed)
    {
        var clamped = Math.Clamp(speed, SpeedMapping.Min, SpeedMapping.Max);
        if (Math.Abs(clamped - _speed) < 0.05) return;
        _speed = clamped; // the next tick's delay picks it up
    }

    /// <summary>Freezes the current frame (sleep, lock, tray hidden): no timer.</summary>
    public void Pause()
    {
        if (_paused) return;
        _paused = true;
        _clock.Cancel();
    }

    public void Resume()
    {
        if (!_paused) return;
        _paused = false;
        ScheduleNext();
    }

    /// <summary>Shows the current frame again, for example after the icon handles were rebuilt.</summary>
    public void Refresh()
    {
        if (_plan is not null) Show();
    }

    private bool HasNext => _plan is not null && (_loops ? _steps.Count > 1 : _index < _steps.Count - 1);

    private void Build(RunnerPlan plan)
    {
        _loops = false;
        _steps = [];
        switch (plan)
        {
            case RunnerPlan.Still(var pose):
                _steps.Add(Rest(pose));
                break;

            case RunnerPlan.Loop(var pose):
                _loops = true;
                AddFrames(pose, 1);
                if (_steps.Count == 0) _steps.Add(new Step(pose, 0, pose.BaseFps()));
                break;

            case RunnerPlan.Settle(var pose, var times):
                if (_frameCount(pose) > 1)
                {
                    AddFrames(pose, Math.Max(times, 1));
                }
                _steps.Add(Rest(pose));
                break;

            case RunnerPlan.Stumble(var times, var then):
                if (_frameCount(then) > 0 && _frameCount(RunnerPose.Crashed) > 0)
                {
                    AddFrames(RunnerPose.Crashed, Math.Max(times, 1));
                    AddFrames(then, 1);
                }
                _steps.Add(Rest(then));
                // the alert pose is the last step already when it has frames: do not repeat it
                if (_steps.Count >= 2 && _steps[^1] == _steps[^2]) _steps.RemoveAt(_steps.Count - 1);
                break;
        }
    }

    private void AddFrames(RunnerPose pose, int times)
    {
        var count = _frameCount(pose);
        for (var t = 0; t < times; t++)
            for (var f = 0; f < count; f++)
                _steps.Add(new Step(pose, f, pose.BaseFps()));
    }

    /// <summary>The alert pose rests on its last frame, every other pose on its first.</summary>
    private Step Rest(RunnerPose pose) =>
        new(pose, pose == RunnerPose.Alert ? Math.Max(_frameCount(pose) - 1, 0) : 0, pose.BaseFps());

    private void Show()
    {
        var step = _steps[_index];
        _showFrame(step.Pose, step.Frame);
    }

    private void ScheduleNext()
    {
        if (_paused || !HasNext) return;
        _clock.Schedule(DelayFor(_steps[_index]), Tick);
    }

    private void Tick()
    {
        if (_paused || !HasNext) return;
        _index = _loops ? (_index + 1) % _steps.Count : _index + 1;
        Show();
        ScheduleNext();
    }

    private TimeSpan DelayFor(Step step)
    {
        var fps = step.Pose == RunnerPose.Running && _plan is { FollowsSpeed: true }
            ? step.Fps * _speed
            : step.Fps;
        fps = Math.Min(fps, RunnerPoses.MaxFps);
        return TimeSpan.FromSeconds(1 / fps);
    }
}
