using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>One check of <c>doctor --json</c> with the fields the Health tab needs (macos DoctorCheck): the repair <see cref="Action"/> and whether it was acknowledged.</summary>
public sealed record HealthCheck(string Id, string Group, string Label, CheckLevel Level, string Message, string? FixCommand, string? Action, bool Acked)
{
    /// <summary><c>dependency_behind</c> appears once per dependency, so the id alone is not a key.</summary>
    public string RowKey => Id + "|" + Message;

    public bool Repairable => Level != CheckLevel.Ok && Action is { Length: > 0 };
}

/// <summary><c>doctor --json</c> for the Health tab (macos DoctorReport). Counts come from <c>summary</c>, else from the checks.</summary>
public sealed record HealthReport(string? Bench, string? Site, string? Profile, string? ProfileSource, IReadOnlyList<HealthCheck> Checks, int Ok, int Warn, int Fail)
{
    /// <summary>The profile is only the default: no profile matches this bench's Frappe.</summary>
    public bool ProfileIsDefault => ProfileSource == "default";

    /// <summary>Checks worth reading first: fail, then warn, then anything unknown.</summary>
    public IReadOnlyList<HealthCheck> NeedsAttention => Checks.Where(c => c.Level != CheckLevel.Ok).OrderBy(c => Rank(c.Level)).ToList();

    public IReadOnlyList<HealthCheck> Passing => Checks.Where(c => c.Level == CheckLevel.Ok).ToList();

    /// <summary>Something repair can fix: a check that is not ok and names a repair action.</summary>
    public bool Repairable => Checks.Any(c => c.Repairable);

    /// <summary>"1 failure, 2 warnings", null when nothing needs attention.</summary>
    public string? Attention
    {
        get
        {
            var parts = new List<string>();
            if (Fail > 0) parts.Add(Fail == 1 ? "1 failure" : $"{Fail} failures");
            if (Warn > 0) parts.Add(Warn == 1 ? "1 warning" : $"{Warn} warnings");
            return parts.Count == 0 ? null : string.Join(", ", parts);
        }
    }

    /// <summary>"45 passing, 1 failure, 2 warnings", for the header.</summary>
    public string SummaryText => Attention is { } a ? $"{Ok} passing, {a}" : $"{Ok} passing";

    private static int Rank(CheckLevel level) => level switch { CheckLevel.Fail => 0, CheckLevel.Warn => 1, _ => 2 };
}

public static class HealthJson
{
    /// <summary>
    /// <c>doctor --json</c>. Reads <c>level</c> and <c>fix_command</c>, else the 0.2.0 names <c>status</c> and <c>fix</c> (an empty fix is none).
    /// A document without <c>checks</c> is refused with a <see cref="FormatException"/>.
    /// </summary>
    public static HealthReport ParseDoctor(JsonObject o)
    {
        if (o["checks"] is not JsonArray array) throw new FormatException("doctor: the document has no checks");
        var checks = new List<HealthCheck>();
        foreach (var c in array.OfType<JsonObject>())
        {
            var id = JsonRead.Str(c, "id");
            if (string.IsNullOrEmpty(id)) continue;
            var fix = JsonRead.Str(c, "fix_command") ?? JsonRead.Str(c, "fix");
            checks.Add(new HealthCheck(id, JsonRead.Str(c, "group") ?? "", JsonRead.Str(c, "label") ?? id,
                BenchJson.ParseLevel(JsonRead.Str(c, "level") ?? JsonRead.Str(c, "status")), JsonRead.Str(c, "message") ?? "",
                string.IsNullOrWhiteSpace(fix) ? null : fix, JsonRead.Str(c, "action") is { Length: > 0 } a ? a : null, JsonRead.Bool(c, "acked")));
        }
        var summary = o["summary"] as JsonObject;
        int Count(string key, CheckLevel level) => summary is not null && JsonRead.Int(summary, key) is { } n ? n : checks.Count(c => c.Level == level);
        return new HealthReport(JsonRead.Str(o, "bench"), JsonRead.Str(o, "site"), JsonRead.Str(o, "profile"), JsonRead.Str(o, "profile_source"),
            checks, Count("ok", CheckLevel.Ok), Count("warn", CheckLevel.Warn), Count("fail", CheckLevel.Fail));
    }

    /// <summary><c>setup check --json</c> (the shim's own rows, without <c>--probe</c>) from the document the client already parsed.</summary>
    public static SetupReport ParseSetupCheck(JsonObject o) => SetupJson.ParseCheck(o.ToJsonString());
}

/// <summary>The text a check copies: the layout of the CLI's own output.</summary>
public static class HealthText
{
    public static string Tag(CheckLevel level) => level switch { CheckLevel.Ok => "OK", CheckLevel.Warn => "WARN", CheckLevel.Fail => "FAIL", _ => "?" };

    /// <summary>"[FAIL] Built assets: message" and a "   fix: command" line when there is one.</summary>
    public static string Row(HealthCheck check)
    {
        var text = $"[{Tag(check.Level)}] {check.Label}: {check.Message}";
        return check.FixCommand is { Length: > 0 } fix ? text + Environment.NewLine + "   fix: " + fix : text;
    }

    /// <summary>The word for a shim row: ok, warn, missing, blocked.</summary>
    public static string ShimWord(SetupStatus status) => status switch
    {
        SetupStatus.Ok => "OK",
        SetupStatus.Warn => "WARN",
        SetupStatus.Missing => "MISSING",
        SetupStatus.Fail => "FAIL",
        _ => "?",
    };
}
