using System.Text.RegularExpressions;

namespace BenchBar.Tray.Core;

/// <summary>The words a Check Your PC row shows for a step's detail, when the shim's own line is written for a terminal.</summary>
public static partial class StepText
{
    [GeneratedRegex(@"\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b|\b(?:reboot|distro|systemd|cli|linger|keepalive|wslconfig)\b", RegexOptions.CultureInvariant)]
    private static partial Regex IdPattern();

    [GeneratedRegex(@"^keepalive keeps (?<have>\S+) alive, but BenchBar uses (?<want>\S+)$", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase)]
    private static partial Regex OtherDistroPattern();

    /// <summary>"waits for wsl_feature" becomes "waits for Turn on WSL" (the step's title); the keepalive line about another distro says it is advice.</summary>
    public static string Detail(SetupStepInfo step, IReadOnlyList<SetupStepInfo> all)
    {
        var detail = step.Detail;
        if (step.Id == SetupIds.Keepalive && OtherDistroPattern().Match(detail.Trim()) is { Success: true } m)
        {
            return $"The keep awake task keeps {m.Groups["have"].Value} running, but BenchBar uses {m.Groups["want"].Value}. "
                + $"Set Up points the task at {m.Groups["want"].Value}.";
        }
        if (step.Waits)
        {
            const string prefix = "waits for";
            var rest = detail[prefix.Length..];
            rest = IdPattern().Replace(rest, id => all.FirstOrDefault(s => s.Id == id.Value)?.Title ?? id.Value);
            return prefix + rest;
        }
        return detail;
    }
}
