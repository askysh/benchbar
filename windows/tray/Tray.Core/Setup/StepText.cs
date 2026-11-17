using System.Text.RegularExpressions;

namespace BenchBar.Tray.Core;

/// <summary>The words a Check Your PC row shows for a step's detail, when the shim's own line is written for a terminal.</summary>
public static partial class StepText
{
    [GeneratedRegex(@"\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\b|\b(?:reboot|distro|systemd|cli|linger|keepalive|wslconfig)\b", RegexOptions.CultureInvariant)]
    private static partial Regex IdPattern();

    [GeneratedRegex(@"^keepalive keeps (?<have>\S+) alive, but BenchBar uses (?<want>\S+)$", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase)]
    private static partial Regex OtherDistroPattern();

    /// <summary>The keep awake row says it serves another distro than the one BenchBar uses: its button moves it.</summary>
    public static bool KeepaliveServesOtherDistro(SetupStepInfo step) =>
        step.Id == SetupIds.Keepalive && OtherDistroPattern().IsMatch(step.Detail.Trim());

    /// <summary>"waits for wsl_feature" becomes "waits for Turn on WSL" (the step's title); the keepalive line about another distro says it is advice.</summary>
    public static string Detail(SetupStepInfo step, IReadOnlyList<SetupStepInfo> all)
    {
        var detail = step.Detail;
        if (step.Id == SetupIds.Keepalive && OtherDistroPattern().Match(detail.Trim()) is { Success: true } m)
        {
            return $"The keep awake task serves {m.Groups["have"].Value}. "
                + $"Move Keep Awake makes it serve {m.Groups["want"].Value} instead. {m.Groups["have"].Value} is then no longer kept awake: it can go idle and stop, and so can any benches in it.";
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
