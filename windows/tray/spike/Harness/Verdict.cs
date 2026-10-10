using System.Globalization;

namespace BenchBar.Tray.Harness;

/// <summary>
/// The decision rule from windows/tray/DECISIONS.md, applied mechanically:
/// choose the shell with the lower private bytes at rest and CPU while animating,
/// unless click to flyout is above 150 ms or logon to icon is above 2 s for that shell.
/// A difference under 10% of the larger value is a tie. An overall tie goes to
/// deployment friction, which the lead decides.
/// </summary>
internal static class Verdict
{
    public const double ClickLimitMs = 150;
    public const double LogonLimitMs = 2000;
    public const double TieFraction = 0.10;

    private static string F(double v, string format) => v.ToString(format, CultureInfo.InvariantCulture);

    /// <summary>Winner of a lower-is-better comparison: 0 tie, 1 first, 2 second.</summary>
    public static (int Winner, double Diff) Compare(double a, double b)
    {
        double larger = Math.Max(a, b);
        double diff = larger <= 0 ? 0 : Math.Abs(a - b) / larger;
        if (diff < TieFraction) return (0, diff);
        return (a < b ? 1 : 2, diff);
    }

    public static (List<string> Lines, string Outcome) Apply(ShellResults a, ShellResults b)
    {
        var lines = new List<string>();
        bool incomplete = false;

        // Step 1: the gates, per shell.
        lines.Add("**Step 1, gates** (a shell above a limit is not chosen):");
        bool passA = Gate(a, lines, ref incomplete);
        bool passB = Gate(b, lines, ref incomplete);

        // Step 2: the two metrics.
        lines.Add("");
        lines.Add("**Step 2, metrics** (lower is better; a difference under 10% of the larger value is a tie):");
        int wp = Metric(lines, "Private bytes at rest", a.Name, b.Name, a.Rest?.Median / 1048576.0, b.Rest?.Median / 1048576.0, "MB", "0.0", ref incomplete);
        int wc = Metric(lines, "CPU while animating", a.Name, b.Name, a.Cpu?.Median, b.Cpu?.Median, "% of one core", "0.00", ref incomplete);

        // A CPU number only compares if both shells drew the same frames.
        // Both must really animate (the timer gives 21.3 fps at the 30 fps target) and at the same rate.
        const double MinFps = 15;
        bool fpsOk = a.Fps is { } fa && b.Fps is { } fb && fa.Median >= MinFps && fb.Median >= MinFps
            && Compare(fa.Median, fb.Median).Winner == 0;
        lines.Add(fpsOk
            ? $"- Achieved frame rate: {a.Name} {F(a.Fps!.Median, "0.0")} fps, {b.Name} {F(b.Fps!.Median, "0.0")} fps; within 10%, so the CPU numbers compare"
            : $"- Achieved frame rate: missing, under {F(MinFps, "0")} fps or more than 10% apart, so the CPU numbers do not compare");

        // Step 3: the outcome.
        lines.Add("");
        string outcome;
        if (!fpsOk)
        {
            outcome = "Not comparable: the shells did not animate at the same frame rate, so CPU while animating says nothing. See the frame rate table.";
        }
        else if (incomplete)
        {
            outcome = "Incomplete: at least one metric has no samples, so the rule cannot be applied. See Failures.";
        }
        else if (!passA && !passB)
        {
            outcome = "Neither shell passes the gates. The rule picks no shell: decided by the lead.";
        }
        else if (passA != passB)
        {
            string chosen = passA ? a.Name : b.Name;
            string other = passA ? b.Name : a.Name;
            outcome = $"{chosen}. {other} is above a gate limit, so the rule does not choose it.";
        }
        else if (wp == 0 && wc == 0)
        {
            outcome = "Overall tie on private bytes and CPU. Tie breaker: deployment friction: decided by the lead.";
        }
        else if (wp != 0 && wc != 0 && wp != wc)
        {
            string byMem = wp == 1 ? a.Name : b.Name;
            string byCpu = wc == 1 ? a.Name : b.Name;
            outcome = $"Split: {byMem} is lower on private bytes, {byCpu} is lower on CPU. The rule does not say how to weigh the two: decided by the lead.";
        }
        else
        {
            int w = wp != 0 ? wp : wc;
            string chosen = w == 1 ? a.Name : b.Name;
            string why = wp != 0 && wc != 0 ? "lower on private bytes and on CPU"
                : wp != 0 ? "lower on private bytes, tie on CPU"
                : "lower on CPU, tie on private bytes";
            outcome = $"{chosen}: {why}, and within both gate limits.";
        }
        if (a.Failures.Count + b.Failures.Count > 0) outcome += " (With failures: some runs gave no sample, see Failures.)";
        lines.Add($"**Step 3, outcome: {outcome}**");
        return (lines, outcome);
    }

    private static bool Gate(ShellResults s, List<string> lines, ref bool incomplete)
    {
        bool pass = true;

        if (s.Click is { } click)
        {
            bool ok = click.Median <= ClickLimitMs;
            pass &= ok;
            lines.Add($"- {s.Name} click to flyout: median {F(click.Median, "0.0")} ms over {click.N} opens, limit {F(ClickLimitMs, "0")} ms: {(ok ? "pass" : "FAIL")}");
        }
        else
        {
            incomplete = true;
            lines.Add($"- {s.Name} click to flyout: no samples");
        }

        // The harder case gates: cold when it was measured, else the warm approximation.
        Summary? logon = s.LogonCold ?? s.LogonWarm;
        string kind = s.LogonCold is not null ? "cold" : "warm";
        if (logon is not null)
        {
            bool ok = logon.Median <= LogonLimitMs;
            pass &= ok;
            lines.Add($"- {s.Name} logon to icon ({kind}): median {F(logon.Median, "0")} ms over {logon.N} runs, limit {F(LogonLimitMs, "0")} ms: {(ok ? "pass" : "FAIL")}");
        }
        else
        {
            incomplete = true;
            lines.Add($"- {s.Name} logon to icon: no samples");
        }
        return pass;
    }

    private static int Metric(List<string> lines, string label, string na, string nb, double? a, double? b, string unit, string format, ref bool incomplete)
    {
        if (a is null || b is null)
        {
            incomplete = true;
            lines.Add($"- {label}: no samples for {(a is null ? na : nb)}");
            return 0;
        }
        (int w, double diff) = Compare(a.Value, b.Value);
        string pct = F(diff * 100, "0.0") + "%";
        string text = w switch
        {
            0 => $"difference {pct} of the larger value, under 10%: tie",
            1 => $"difference {pct} of the larger value, {na} is lower",
            _ => $"difference {pct} of the larger value, {nb} is lower",
        };
        lines.Add($"- {label}: {na} {F(a.Value, format)} {unit}, {nb} {F(b.Value, format)} {unit}; {text}");
        return w;
    }
}
