namespace BenchBar.Tray.Core;

/// <summary>
/// Load to runner speed, as SpeedMapping in macos/BenchBar/Speed/SpeedSource.swift.
/// The spike has no real CPU source: a Windows process cannot sample processes
/// inside WSL, so the fixture's <c>cpu-percent</c> stands in. Where the real
/// number comes from is an open question for the CLI.
/// </summary>
public static class SpeedMapping
{
    public const double Min = 1;
    public const double Max = 12;

    /// <summary>speed = clamp(1 + cpu% / 10, 1, 12). NaN and infinity give 1.</summary>
    public static double Speed(double cpuPercent) =>
        double.IsFinite(cpuPercent) ? Math.Clamp(1 + cpuPercent / 10, Min, Max) : Min;
}

/// <summary>
/// An exponential moving average, so one busy sample does not make the runner
/// sprint and stop: value = alpha * new + (1 - alpha) * value.
/// </summary>
public struct SpeedSmoother
{
    public SpeedSmoother()
    {
        Alpha = 0.35;
        Value = SpeedMapping.Min;
    }

    public double Alpha { get; set; }

    public double Value { get; private set; }

    public double Add(double sample)
    {
        Value = Alpha * sample + (1 - Alpha) * Value;
        return Value;
    }

    public void Reset() => Value = SpeedMapping.Min;
}
