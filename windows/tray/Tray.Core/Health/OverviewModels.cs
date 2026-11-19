using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>One difference of <c>lock check --json</c> (macos LockCheck.Drift).</summary>
public sealed record LockDrift(string Kind, string? App, string? Site, string? Expected, string? Actual, string Level)
{
    /// <summary>"erpnext: commit behind (is a1b2c3d, lock b5f7846)".</summary>
    public string Text
    {
        get
        {
            var what = Kind.Replace('_', ' ');
            var subject = string.Join(' ', new[] { App, Site is null ? null : "on " + Site }.OfType<string>());
            if (subject.Length == 0) subject = "bench";
            var detail = string.Join(", ", new[] { Actual is null ? null : "is " + Actual, Expected is null ? null : "lock " + Expected }.OfType<string>());
            return $"{subject}: {what}" + (detail.Length == 0 ? "" : $" ({detail})");
        }
    }

    public bool IsFail => Level == "fail";
}

/// <summary><c>lock check --json</c>: the bench compared with its lockfile.</summary>
public sealed record LockCheck(string? LockFile, bool InSync, IReadOnlyList<LockDrift> Drift)
{
    /// <summary>"In sync", "1 difference" or "3 differences".</summary>
    public string Badge => InSync ? "In sync" : Drift.Count == 1 ? "1 difference" : $"{Drift.Count} differences";

    public string Footer => $"Compared with {LockFile}. To bring the bench in line, run benchbar lock apply in a terminal.";
}

/// <summary>What asking about the lockfile found: a check, a bench without a lockfile (nothing to show), or a failure.</summary>
public sealed record LockOutcome(LockCheck? Check, bool NoLockfile, string? Error)
{
    public static LockOutcome Parse(CliResult<LockCheck> result)
    {
        if (result.Value is { } check) return new LockOutcome(check, false, null);
        var error = result.Error ?? "The lockfile could not be checked.";
        return new LockOutcome(null, error.Contains("No lockfile", StringComparison.OrdinalIgnoreCase), error);
    }
}

public static class LockJson
{
    public static LockCheck Parse(JsonObject o)
    {
        if (o["drift"] is not JsonArray array) throw new FormatException("lock check: the document has no drift");
        var drift = array.OfType<JsonObject>().Select(d => new LockDrift(JsonRead.Str(d, "kind") ?? "", JsonRead.Str(d, "app"), JsonRead.Str(d, "site"),
            JsonRead.Str(d, "expected"), JsonRead.Str(d, "actual"), JsonRead.Str(d, "level") ?? "warn")).ToList();
        return new LockCheck(JsonRead.Str(o, "lock_file"), JsonRead.Bool(o, "in_sync"), drift);
    }
}

/// <summary>The Overview facts that come for free from the status the poll already reads.</summary>
public static class OverviewFacts
{
    /// <summary>The CLI's own word for a folder that is a bench with no BenchBar service: nothing can start it until it is set up.</summary>
    public static bool NeedsService(BenchStatus bench) => string.Equals(bench.RawState, "not_adopted", StringComparison.OrdinalIgnoreCase);

    /// <summary>"Up for 2 h 5 min", null unless the bench runs and says since when.</summary>
    public static string? Uptime(BenchStatus bench, DateTimeOffset now) =>
        bench.State == BenchState.Running && bench.StartedAt is { } since && now >= since ? "Up for " + Duration(now - since) : null;

    public static string Duration(TimeSpan span)
    {
        if (span.TotalMinutes < 1) return "less than a minute";
        if (span.TotalHours < 1) return $"{(int)span.TotalMinutes} min";
        if (span.TotalDays < 1) return $"{(int)span.TotalHours} h {span.Minutes} min";
        return $"{(int)span.TotalDays} d {span.Hours} h";
    }

    public static string SchedulerNote(bool? scheduler) => scheduler is null
        ? "Needs benchbar 0.4 or later"
        : "Runs scheduled jobs (bench schedule) in the background. Changing it restarts a running bench.";
}

/// <summary>The exact arguments of the Overview's own calls.</summary>
public static class OverviewArgs
{
    /// <summary><c>service --yes --with-schedule</c> or <c>--without-schedule</c> for one bench.</summary>
    public static string[] Scheduler(bool on, string benchPath) => ["service", "--yes", on ? "--with-schedule" : "--without-schedule", "--bench-dir", benchPath];

    /// <summary><c>up --services-only</c>: the bench's Redis and nothing else, for a restore or a migrate. <c>down</c> stops it again.</summary>
    public static string[] ServicesOnly(string benchPath) => ["up", "--services-only", "--json", "--bench-dir", benchPath];

    public static string[] StopServices(string benchPath) => ["down", "--json", "--bench-dir", benchPath];

    /// <summary><c>autostart</c> without a word reads the setting; <c>on</c> or <c>off</c> changes it. There is no JSON mode.</summary>
    public static string[] AutostartRead(string benchPath) => ["autostart", "--bench-dir", benchPath];

    public static string[] Autostart(bool on, string benchPath) => ["autostart", on ? "on" : "off", "--bench-dir", benchPath];

    /// <summary>The plan and apply of <c>service</c>: <c>--dry-run --json</c>, then <c>--apply TOKEN --yes --jsonl</c> (<see cref="PlanReviewRequest.Tokened"/>).</summary>
    public static string[] ServiceBase(string benchPath, bool? scheduler = null) =>
        scheduler is { } on ? ["service", on ? "--with-schedule" : "--without-schedule", "--bench-dir", benchPath] : ["service", "--bench-dir", benchPath];

    /// <summary>
    /// <c>watch</c> and <c>fg</c> run until the person ends them and have no JSON, so they open in a terminal the person closes. The command
    /// is the CLI itself with the PATH the shim uses; the bench path is an argument of the shell script, never part of it.
    /// </summary>
    public static string[] InTerminal(string verb, string benchPath) =>
        ["/bin/sh", "-c", "PATH=\"$HOME/.local/bin:$PATH\"; exec benchbar \"$@\"", "benchbar", verb, "--bench-dir", benchPath];
}

/// <summary>The lockfile calls that change things. The CLI has no plan or token for them, so the sheet shows what <c>--dry-run</c> prints and applies with <c>--yes</c>.</summary>
public static class LockArgs
{
    public static string[] Preview(string verb, string benchPath) => ["lock", verb, "--dry-run", "--bench-dir", benchPath];

    public static string[] Run(string verb, string benchPath) => ["lock", verb, "--yes", "--bench-dir", benchPath];

    /// <summary>The sheet's request: the dry run's own text, then <c>--yes</c> after the person's yes.</summary>
    public static PlanReviewRequest Review(string verb, string benchPath) => verb == "write"
        ? new PlanReviewRequest("Write the lockfile", Preview(verb, benchPath), _ => Run(verb, benchPath))
        {
            ConfirmLabel = "Write", RequiresToken = false, PlanIsText = true,
            Summary = "Writes benchbar.toml from this bench. The old file is backed up first.",
        }
        : new PlanReviewRequest("Apply the lockfile", Preview(verb, benchPath), _ => Run(verb, benchPath))
        {
            ConfirmLabel = "Apply", RequiresToken = false, PlanIsText = true,
            Summary = "Clones missing apps, switches branches and fast forwards to the pinned commits. No site is touched.",
        };
}

/// <summary>The setting <c>autostart</c> prints: "autostart is on (...)" or "autostart is off".</summary>
public static class AutostartText
{
    /// <summary>True for on, false for off, null when the lines say neither (an unknown CLI wording: the control stays off).</summary>
    public static bool? Parse(IEnumerable<string> lines)
    {
        foreach (var line in lines)
        {
            if (line.Contains("autostart is on", StringComparison.OrdinalIgnoreCase)) return true;
            if (line.Contains("autostart is off", StringComparison.OrdinalIgnoreCase)) return false;
        }
        return null;
    }
}
