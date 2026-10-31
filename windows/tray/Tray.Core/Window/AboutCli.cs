namespace BenchBar.Tray.Core;

/// <summary>What About says for the Linux command line tool: its version, or the reason there is none.</summary>
public sealed record AboutCli(string? Version, string Text)
{
    public static AboutCli Unknown { get; } = new(null, "unknown");

    public static AboutCli Stopped { get; } = new(null, "unknown (the distro may be stopped)");

    public static AboutCli NotInstalled { get; } = new(null, "not installed yet");

    /// <summary>From the read only setup check: the version when the CLI answers; "not installed yet" when WSL, the distro or the CLI is missing; the stopped words when the check skipped the distro.</summary>
    public static AboutCli From(SetupReport report)
    {
        if (report.Step(SetupIds.Cli) is { IsOk: true, Detail.Length: > 0 } cli) return new AboutCli(cli.Detail, cli.Detail);
        foreach (var id in new[] { SetupIds.WslFeature, SetupIds.WslVersion, SetupIds.Distro, SetupIds.Cli })
        {
            if (report.Step(id) is { } step && !step.NotChecked && step.Status is SetupStatus.Missing or SetupStatus.Fail) return NotInstalled;
        }
        if (report.Steps.Any(s => s.NotChecked)) return Stopped;
        return Unknown;
    }
}
