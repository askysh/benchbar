namespace BenchBar.Tray.Harness;

internal sealed record ClickSample(double Ms, bool Cold);

internal sealed record DirSize(string Dir, long Bytes, int Files);

internal sealed record Summary(double Median, double Min, double Max, int N);

/// <summary>Everything measured for one shell. All raw samples are kept.</summary>
internal sealed class ShellResults(string name, string exe, string? dir, string? fdDir)
{
    public string Name { get; } = name;
    public string Exe { get; } = exe;
    public string? Dir { get; } = dir;
    public string? FdDir { get; } = fdDir;

    public List<double> PrivateBytes { get; } = [];
    public List<double> WorkingSetBytes { get; } = [];
    public List<double> CpuPercent { get; } = [];
    public List<ClickSample> Clicks { get; } = [];
    public List<double> LogonWarmMs { get; } = [];
    public List<double> LogonColdMs { get; } = [];
    public List<string> Failures { get; } = [];

    public DirSize? Size { get; set; }
    public DirSize? FdSize { get; set; }

    public Summary? Rest => Stats.Of(PrivateBytes);
    public Summary? WorkingSet => Stats.Of(WorkingSetBytes);
    public Summary? Cpu => Stats.Of(CpuPercent);
    public Summary? Click => Stats.Of(Clicks.Select(c => c.Ms).ToList());
    public Summary? LogonWarm => Stats.Of(LogonWarmMs);
    public Summary? LogonCold => Stats.Of(LogonColdMs);
}

internal static class Stats
{
    /// <summary>Median; for an even count the mean of the two middle values.</summary>
    public static double Median(IReadOnlyList<double> values)
    {
        double[] s = [.. values.Order()];
        int n = s.Length;
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0;
    }

    public static Summary? Of(IReadOnlyList<double> values) =>
        values.Count == 0 ? null : new Summary(Median(values), values.Min(), values.Max(), values.Count);

    public static DirSize? Measure(string? dir)
    {
        if (dir is null || !Directory.Exists(dir)) return null;
        var files = new DirectoryInfo(dir).EnumerateFiles("*", SearchOption.AllDirectories).ToList();
        return new DirSize(dir, files.Sum(f => f.Length), files.Count);
    }
}
