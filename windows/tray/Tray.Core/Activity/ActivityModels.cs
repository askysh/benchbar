using System.Globalization;
using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>Words and times the activity pages share (leases, history, operations, snapshots).</summary>
public static class ActivityText
{
    /// <summary>"3 hours ago". A clock a little behind never says "in 2 minutes".</summary>
    public static string Age(DateTimeOffset time, DateTimeOffset now)
    {
        var span = now - time;
        if (span < TimeSpan.FromSeconds(45)) return "just now";
        if (span < TimeSpan.FromMinutes(90)) return Plural((int)Math.Max(1, Math.Round(span.TotalMinutes)), "minute");
        if (span < TimeSpan.FromHours(36)) return Plural((int)Math.Round(span.TotalHours), "hour");
        return Plural((int)Math.Round(span.TotalDays), "day");
    }

    private static string Plural(int n, string unit) => $"{n} {unit}{(n == 1 ? "" : "s")} ago";

    public static DateTimeOffset? Time(JsonObject o, string key) =>
        DateTimeOffset.TryParse(JsonRead.Str(o, key), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var t) ? t : null;

    /// <summary>
    /// The environment of a call that the CLI allows to a person only (removing a snapshot, rolling the default site back, <c>--break-lease</c>): the
    /// click, and for a rollback the typed site name, was that person's decision. Never set for a poll, a link or a read.
    /// </summary>
    public static SecretEnvironment PersonEnvironment() => new SecretEnvironment().Set(SetupEnv.NonInteractive, "0");
}

// --- leases ---

/// <summary>One lease from <c>lease list --json</c> (the id is never read: the tray holds no lease).</summary>
public sealed record LeaseInfo(string Scope, string? Site, string Holder, string? Note, DateTimeOffset? Since, DateTimeOffset? ExpiresAt);

public static class LeaseJson
{
    /// <summary>The active leases. One that has ended since the CLI read it is left out on the tray's clock.</summary>
    public static IReadOnlyList<LeaseInfo> ParseList(JsonObject o, DateTimeOffset now)
    {
        if (o["leases"] is not JsonArray array) throw new FormatException("The document has no leases list.");
        return array.OfType<JsonObject>()
            .Select(l => new LeaseInfo(JsonRead.Str(l, "scope") ?? "bench", JsonRead.Str(l, "site"), JsonRead.Str(l, "holder") ?? "someone",
                JsonRead.Str(l, "note") is { Length: > 0 } n && n != "null" ? n : null, ActivityText.Time(l, "since"), ActivityText.Time(l, "expires_at")))
            .Where(l => l.ExpiresAt is null || l.ExpiresAt > now).ToList();
    }
}

public static class LeaseText
{
    public static string Place(LeaseInfo lease) => lease.Scope == "site" ? $"Site {lease.Site ?? "?"}" : "The whole bench";

    /// <summary>"Site acme.localhost is held by claude-qa until 3:20 PM: running the QA suite".</summary>
    public static string Line(LeaseInfo lease, DateTimeOffset now, TimeZoneInfo? zone = null, CultureInfo? culture = null)
    {
        var text = $"{Place(lease)} is held by {lease.Holder}";
        if (lease.ExpiresAt is { } end) text += " until " + Until(end, now, zone, culture);
        if (lease.Note is { Length: > 0 } note) text += ": " + note;
        return text;
    }

    internal static string Until(DateTimeOffset end, DateTimeOffset now, TimeZoneInfo? zone = null, CultureInfo? culture = null)
    {
        culture ??= CultureInfo.CurrentCulture;
        var local = TimeZoneInfo.ConvertTime(end, zone ?? TimeZoneInfo.Local);
        var today = TimeZoneInfo.ConvertTime(now, zone ?? TimeZoneInfo.Local).Date == local.Date;
        return today ? local.ToString(culture.DateTimeFormat.ShortTimePattern, culture) : UiText.Date(end, zone, culture);
    }
}

/// <summary>
/// What a command that a lease stands in front of ends with (error id <c>lease_held</c>, exit 1, nothing changed):
/// "The site acme.localhost of /path is leased by claude-qa until 2026-11-19T15:20:00Z (running the QA suite). Nothing was changed."
/// </summary>
public sealed record LeaseRefusal(string Holder, DateTimeOffset? Until, string UntilText, string? Note)
{
    /// <summary>Null when the message is not a lease refusal. Several leases in one message: the first is named.</summary>
    public static LeaseRefusal? Parse(string? message)
    {
        if (message is null) return null;
        var marker = message.IndexOf(" is leased by ", StringComparison.Ordinal);
        if (marker < 0) return null;
        var rest = message[(marker + " is leased by ".Length)..];
        var untilMarker = rest.IndexOf(" until ", StringComparison.Ordinal);
        if (untilMarker <= 0) return null;
        var holder = rest[..untilMarker];
        if (holder.Contains(' ')) return null;
        var after = rest[(untilMarker + " until ".Length)..];
        var untilText = new string(after.TakeWhile(c => !char.IsWhiteSpace(c)).ToArray());
        string? note = null;
        var tail = after[untilText.Length..];
        if (tail.StartsWith(" (", StringComparison.Ordinal) && tail.IndexOf(").", StringComparison.Ordinal) is var close and > 0) note = tail[2..close];
        untilText = untilText.TrimEnd('.');
        DateTimeOffset? until = DateTimeOffset.TryParse(untilText, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var t) ? t : null;
        return new LeaseRefusal(holder, until, untilText, note);
    }

    /// <summary>"Held by claude-qa until 11/19/2026 3:20 PM (running the QA suite)."</summary>
    public string Sentence()
    {
        var text = "Held by " + Holder;
        if (Until is { } u) text += " until " + UiText.Date(u);
        else if (UntilText.Length > 0) text += " until " + UntilText;
        if (Note is { Length: > 0 }) text += $" ({Note})";
        return text + ".";
    }

    public const string BreakHelp = "Run it anyway. The holder is not told, and what they are doing may break.";

    public string BreakQuestion(string what) =>
        $"{Sentence()} Breaking it runs \"{what}\" anyway, as you: whoever holds the lease may be in the middle of work on it. The run is recorded in the history.";
}

public static class LeaseCommands
{
    public static string[] List(string bench) => ["lease", "list", "--bench", bench, "--json"];

    /// <summary>The same change again with <c>--break-lease</c>, before a <c>--</c> when the arguments have one (the words after it are the bench's).</summary>
    public static string[] WithBreak(IReadOnlyList<string> args)
    {
        var at = args.ToList().IndexOf("--");
        return at < 0 ? [.. args, "--break-lease"] : [.. args.Take(at), "--break-lease", .. args.Skip(at)];
    }
}

// --- history ---

public sealed record HistoryChange(string Kind, string Name);

/// <summary>One finished run from <c>history --json</c>: what ran, who started it, how it ended and what it changed.</summary>
public sealed record HistoryEntry(string? OpId, string? Command, IReadOnlyList<string> Argv, string Caller, string? McpClient, string? Bench, string? Site,
    DateTimeOffset? StartedAt, int Exit, IReadOnlyList<HistoryChange> Changed, int ChangedMore, string? Log);

public static class HistoryJson
{
    public static IReadOnlyList<HistoryEntry> Parse(JsonObject o)
    {
        if (o["history"] is not JsonArray array) throw new FormatException("The document has no history list.");
        var entries = new List<HistoryEntry>();
        foreach (var e in array.OfType<JsonObject>())
        {
            var changed = (e["changed"] as JsonArray ?? []).OfType<JsonObject>()
                .Where(c => JsonRead.Str(c, "name") is { Length: > 0 })
                .Select(c => new HistoryChange(JsonRead.Str(c, "kind") ?? "", JsonRead.Str(c, "name")!)).ToList();
            entries.Add(new HistoryEntry(JsonRead.Str(e, "op_id"), JsonRead.Str(e, "command"), JsonRead.Strings(e, "argv"), JsonRead.Str(e, "caller") ?? "unknown",
                (e["mcp"] as JsonObject) is { } mcp ? JsonRead.Str(mcp, "client") : null, JsonRead.Str(e, "bench"), JsonRead.Str(e, "site"),
                ActivityText.Time(e, "started_at"), JsonRead.Int(e, "exit") ?? 1, changed, JsonRead.Int(e, "changed_more") ?? 0, JsonRead.Str(e, "log")));
        }
        return entries;
    }

    public static string[] Args(int limit = 100) => ["history", "--json", "--limit", limit.ToString(CultureInfo.InvariantCulture)];
}

public static class HistoryText
{
    /// <summary>"site backup acme.localhost": the command and what it was aimed at.</summary>
    public static string Title(HistoryEntry e)
    {
        var command = e.Command ?? e.Argv.FirstOrDefault() ?? "a command";
        return e.Site is { Length: > 0 } site && !command.Contains(site, StringComparison.Ordinal) ? $"{command} {site}" : command;
    }

    /// <summary>Who started it, as a person says it. A caller this build does not know is shown as it is.</summary>
    public static string Who(HistoryEntry e) => e.Caller switch
    {
        "app" => "BenchBar app",
        "terminal" => "Terminal",
        "tray" => "Windows tray",
        "script" => "A script",
        "agent" => "An agent",
        "mcp" => "An agent through MCP" + (e.McpClient is { Length: > 0 } c ? $" ({c})" : ""),
        _ => e.Caller,
    };

    public static string Result(HistoryEntry e) => e.Exit == 0 ? "Done" : $"Failed (exit {e.Exit})";

    /// <summary>"site acme.localhost, snapshot acme.localhost": what the run changed, as the CLI recorded it. Null when it changed nothing.</summary>
    public static string? Changes(HistoryEntry e)
    {
        if (e.Changed.Count == 0) return null;
        var parts = e.Changed.Select(c => $"{c.Kind} {c.Name}").ToList();
        if (e.ChangedMore > 0) parts.Add($"{e.ChangedMore} more");
        return string.Join(", ", parts);
    }

    /// <summary>The Windows form of a bench folder inside the distro is not needed here: the folder's own name says which bench.</summary>
    public static string? BenchName(HistoryEntry e) => e.Bench is { Length: > 0 } b ? b.TrimEnd('/').Split('/').Last() : null;
}

// --- operation handles ---

/// <summary>One record of <c>op list --json</c> (docs/json-schema.md, Operation handles). An unknown state is kept as it came.</summary>
public sealed record OpRecord(string OpId, string State, string? Command, string? Bench, string? Site, DateTimeOffset? StartedAt, int? Exit, string? Step, string? Progress)
{
    public bool IsActive => State is "starting" or "running";
}

public static class OpJson
{
    public static IReadOnlyList<OpRecord> ParseList(JsonObject o)
    {
        if (o["ops"] is not JsonArray array) throw new FormatException("The document has no ops list.");
        var ops = new List<OpRecord>();
        foreach (var r in array.OfType<JsonObject>())
        {
            if (JsonRead.Str(r, "op_id") is not { Length: > 0 } id) continue;
            var step = r["step"] is JsonObject s ? JsonRead.Str(s, "name") : null;
            var progress = r["progress"] is JsonObject p ? JsonRead.Str(p, "label") : null;
            ops.Add(new OpRecord(id, JsonRead.Str(r, "state") ?? "unknown", JsonRead.Str(r, "command"), JsonRead.Str(r, "bench"), JsonRead.Str(r, "site"),
                ActivityText.Time(r, "started_at"), JsonRead.Int(r, "exit"), step, progress));
        }
        return ops;
    }

    /// <summary><c>op list --running --json</c> when the CLI has the flag, else the plain list (the caller filters).</summary>
    public static string[] List(bool running = false) => ["op", "list", .. running ? new[] { "--running" } : [], "--json"];

    /// <summary>The runs of this bench that are still going: the ones <c>op list</c> says run, for this bench folder.</summary>
    public static IReadOnlyList<OpRecord> RunningFor(IEnumerable<OpRecord> ops, string bench) =>
        ops.Where(o => o.IsActive && (o.Bench is null || o.Bench == bench)).ToList();

    /// <summary>"site backup acme.localhost, running: Back up acme.localhost (12 s)".</summary>
    public static string Line(OpRecord op, DateTimeOffset now)
    {
        var text = (op.Command ?? "a command") + (op.Site is { Length: > 0 } site && op.Command?.Contains(site, StringComparison.Ordinal) != true ? " " + site : "");
        text += op.State == "starting" ? ", starting" : ", running";
        if (op.Step is { Length: > 0 } step) text += ": " + step;
        if (op.Progress is { Length: > 0 } progress) text += $" ({progress})";
        if (op.StartedAt is { } at) text += $", started {ActivityText.Age(at, now)}";
        return text;
    }
}

// --- resources (stats) ---

/// <summary>One sample of <c>stats --json</c>: CPU as percent of one core, resident memory of the bench's processes, and the runner speed.</summary>
public sealed record ResourceSample(double CpuPercent, long MemoryBytes, int Processes, double Speed, DateTimeOffset At);

public static class StatsJson
{
    public static string[] Args(string bench) => ["stats", "--json", "--bench-dir", bench];

    /// <summary>
    /// The sample, or null while nothing serves the site (<c>resources</c> is null: a stopped bench). An absent <c>speed</c> falls back to
    /// the Mac's mapping of the CPU (<see cref="SpeedMapping"/>); an unusable number is no sample.
    /// </summary>
    public static ResourceSample? Parse(JsonObject o, DateTimeOffset now)
    {
        if (o["resources"] is not JsonObject r) return null;
        if (r["cpu_percent"] is not JsonValue c || !c.TryGetValue<double>(out var cpu) || !double.IsFinite(cpu) || cpu < 0) return null;
        var memory = r["memory_bytes"] is JsonValue m && m.TryGetValue<long>(out var bytes) && bytes >= 0 ? bytes : 0;
        var speed = r["speed"] is JsonObject s && s["raw"] is JsonValue sv && sv.TryGetValue<double>(out var raw) && double.IsFinite(raw) ? Math.Clamp(raw, SpeedMapping.Min, SpeedMapping.Max) : SpeedMapping.Speed(cpu);
        return new ResourceSample(cpu, memory, JsonRead.Int(r, "processes") ?? 0, speed, ActivityText.Time(r, "sampled_at") ?? now);
    }
}

/// <summary>
/// The last minutes of samples for the charts. The runner speed is smoothed the way the Mac app does it (<see cref="SpeedSmoother"/>, alpha
/// 0.35, starting at 1), so one busy sample does not make the chart jump. The oldest sample goes at <see cref="Capacity"/>.
/// </summary>
public sealed class ResourceHistory
{
    public const int Capacity = 60;

    private readonly List<ResourceSample> _samples = [];
    private SpeedSmoother _smoother = new();

    public IReadOnlyList<ResourceSample> Samples => _samples;

    public ResourceSample? Latest => _samples.Count == 0 ? null : _samples[^1];

    /// <summary>The smoothed runner speed after the last sample (1 when there is none).</summary>
    public double Speed => _smoother.Value;

    public void Add(ResourceSample sample)
    {
        _smoother.Add(sample.Speed);
        _samples.Add(sample);
        if (_samples.Count > Capacity) _samples.RemoveAt(0);
    }

    /// <summary>A stopped bench ends the chart: the next run starts from nothing, not from the old speed.</summary>
    public void Clear()
    {
        _samples.Clear();
        _smoother.Reset();
    }

    /// <summary>"CPU 112.8 percent, memory 25.4 MB, 4 processes, runner speed 5.2".</summary>
    public static string Line(ResourceSample s, double smoothedSpeed, CultureInfo? culture = null) =>
        $"CPU {UiText.OneDecimal(s.CpuPercent, culture)} percent, memory {ByteSize.Format(s.MemoryBytes, culture)}, {s.Processes} {(s.Processes == 1 ? "process" : "processes")}, runner speed {UiText.OneDecimal(smoothedSpeed, culture)}";

    /// <summary>The points of a chart of <paramref name="values"/> in a box of <paramref name="width"/> by <paramref name="height"/>, scaled to <paramref name="max"/> (at least 1).</summary>
    public static IReadOnlyList<(double X, double Y)> Points(IReadOnlyList<double> values, double max, double width, double height)
    {
        if (values.Count == 0) return [];
        var top = Math.Max(max, 1);
        var step = values.Count > 1 ? width / (Capacity - 1) : 0;
        var start = width - step * (values.Count - 1); // the newest sample sits at the right edge
        return values.Select((v, i) => (start + step * i, height - Math.Clamp(v / top, 0, 1) * height)).ToList();
    }
}

// --- benchbar run ---

/// <summary>One command of the allow list of <c>benchbar run</c> (docs/reference/cli/run.md). The CLI refuses anything else with exit 64.</summary>
public sealed record RunCommandInfo(string Name, bool Changes, bool NeedsSite, string Help, IReadOnlyList<string> Switches, IReadOnlyList<string> Valued);

public static class RunAllowList
{
    public static IReadOnlyList<RunCommandInfo> All { get; } =
    [
        new("migrate", true, true, "Patches, schema sync and fixtures of the site, after a backup of it.", ["--skip-failing", "--skip-search-index"], []),
        new("clear-cache", true, true, "Clears the cache of the site.", [], []),
        new("clear-website-cache", true, true, "Clears the website cache of the site.", [], []),
        new("build", true, false, "Builds the bench's assets.", [], ["--app"]),
        new("run-tests", true, true, "Runs the apps' tests. It writes test records into the site's database: use a throwaway site, not one you keep.", ["--failfast"], ["--app", "--module", "--doctype", "--test", "--case"]),
        new("doctor", false, true, "Checks the site's setup (a read).", [], []),
        new("list-apps", false, true, "Lists the apps installed on the site (a read).", [], ["--format"]),
        new("version", false, false, "Prints the versions of the bench's apps (a read).", [], []),
    ];

    public static RunCommandInfo? Find(string name) => All.FirstOrDefault(c => c.Name == name);
}

/// <summary>What the Run bench command dialog asks for, checked before the CLI is asked.</summary>
public sealed record RunInput(string Command, string? Site, string Options);

public static class RunCommands
{
    /// <summary>The flags of the command as words, or the reason they cannot be sent. A value is one plain word the CLI takes: letters, digits, <c>.</c>, <c>_</c>, <c>:</c>, <c>-</c>, not starting with <c>-</c>.</summary>
    public static (IReadOnlyList<string> Words, string? Problem) Flags(RunCommandInfo command, string options)
    {
        var tokens = options.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var words = new List<string>();
        for (var i = 0; i < tokens.Length; i++)
        {
            var t = tokens[i];
            if (command.Switches.Contains(t)) { words.Add(t); continue; }
            if (!command.Valued.Contains(t))
                return ([], command.Switches.Count + command.Valued.Count == 0 ? $"{command.Name} takes no flags." : $"{t} is not a flag of {command.Name}. It takes: {string.Join(", ", command.Switches.Concat(command.Valued))}.");
            if (i + 1 >= tokens.Length) return ([], $"{t} needs a value.");
            var value = tokens[++i];
            if (value[0] == '-' || !value.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or ':' or '-')) return ([], $"The value of {t} is one plain word: letters, digits, '.', '_', ':' and '-'.");
            words.Add(t);
            words.Add(value);
        }
        return (words, null);
    }

    public static string? Problem(RunInput input, IEnumerable<string> sites)
    {
        if (RunAllowList.Find(input.Command) is not { } command) return $"{input.Command} is not on the list of commands benchbar run takes.";
        if (command.NeedsSite && (string.IsNullOrEmpty(input.Site) || !sites.Contains(input.Site))) return $"{command.Name} needs one of the sites of this bench.";
        return Flags(command, input.Options).Problem;
    }

    private static string[] Front(RunInput input, string bench) =>
        ["run", .. RunAllowList.Find(input.Command)?.NeedsSite == true && input.Site is { Length: > 0 } s ? new[] { "--site", s } : [], "--bench-dir", bench];

    private static string[] Back(RunInput input) => ["--", input.Command, .. RunAllowList.Find(input.Command) is { } c ? Flags(c, input.Options).Words : []];

    /// <summary>A read runs at once: <c>run --site S --json -- list-apps</c>.</summary>
    public static string[] Read(RunInput input, string bench) => [.. Front(input, bench), "--json", .. Back(input)];

    /// <summary>The plan and the apply of a change. The words of the bench command stay after <c>--</c>, the plan's own token before it.</summary>
    public static PlanReviewRequest Review(RunInput input, string bench)
    {
        var front = Front(input, bench);
        var back = Back(input);
        var what = $"bench {string.Join(' ', back.Skip(1))}";
        return new PlanReviewRequest($"Run {input.Command}", [.. front, "--dry-run", "--json", .. back],
            plan => [.. front, "--apply", plan.Token ?? "", "--yes", "--jsonl", .. back])
        {
            ConfirmLabel = "Run",
            CanStop = false, // a migrate is not safe to kill part way
            Summary = $"Runs {what}{(input.Site is { Length: > 0 } site && RunAllowList.Find(input.Command)?.NeedsSite == true ? " on " + site : "")}. Nothing else runs.",
            Describe = Describe,
        };
    }

    public static IReadOnlyList<string> Describe(PlanDocument plan)
    {
        var lines = new List<string>();
        if (JsonRead.Str(plan.Raw, "summary") is { Length: > 0 } summary) lines.Add(summary);
        if (JsonRead.Strings(plan.Raw, "argv") is { Count: > 0 } argv) lines.Add("Command: " + string.Join(' ', argv));
        if (JsonRead.Bool(plan.Raw, "backup_first")) lines.Add("A database backup of the site is taken first.");
        if (JsonRead.Int(plan.Raw, "timeout_s") is { } seconds) lines.Add($"Deadline: {(seconds >= 120 ? seconds / 60 + " minutes" : seconds + " seconds")}.");
        lines.Add("The output goes to the run's log. The code of the bench's apps runs, so use a bench whose apps you trust.");
        return lines;
    }

    /// <summary>What a read answered: its command's exit, whether the deadline stopped it, and the tail of its output (data from the bench).</summary>
    public sealed record ReadResult(bool Ok, int CommandExit, bool TimedOut, string Output);

    public static ReadResult ParseRead(JsonObject o)
    {
        var tail = JsonRead.Str(o, "output_tail") ?? "";
        var exit = JsonRead.Int(o, "command_exit") ?? JsonRead.Int(o, "exit") ?? 1;
        return new ReadResult(JsonRead.Bool(o, "ok") || (o["ok"] is null && exit == 0), exit, JsonRead.Bool(o, "timed_out"), tail);
    }
}
