using System.Globalization;
using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>One snapshot of a site (docs/json-schema.md, Site snapshots): a backup with files, kept where frappe's pruning never reaches.</summary>
public sealed record SiteSnapshot(string Id, string Stamp, string? Label, DateTimeOffset? Time, long SizeBytes, bool WithFiles, bool Complete,
    bool BeforeRollback, bool? AppsMatch, IReadOnlyList<string> ChangedApps)
{
    /// <summary>The label, else the time stamp.</summary>
    public string Title => Label ?? Stamp;
}

/// <summary><c>site snapshots NAME --json</c>, newest first.</summary>
public sealed record SiteSnapshotList(string Site, int Keep, IReadOnlyList<SiteSnapshot> Snapshots, IReadOnlyList<string> OverLimit,
    string? LastRollbackSnapshot, long TotalBytes, long? FreeBytes);

public static class SnapshotJson
{
    /// <summary>A snapshot without an id is skipped (null). The mocked CLI prints the word <c>null</c> for no label: that and an empty string are no label.</summary>
    public static SiteSnapshot? ParseSnapshot(JsonObject o)
    {
        if (JsonRead.Str(o, "id") is not { Length: > 0 } id) return null;
        var label = JsonRead.Str(o, "label");
        if (string.IsNullOrWhiteSpace(label) || label == "null") label = null;
        DateTimeOffset? time = DateTimeOffset.TryParse(JsonRead.Str(o, "time"), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var t) ? t : null;
        bool? match = o["apps_match"] is JsonValue m && m.TryGetValue<bool>(out var b) ? b : null;
        return new SiteSnapshot(id, JsonRead.Str(o, "stamp") ?? id, label, time, Long(o, "size_bytes") ?? 0, JsonRead.Bool(o, "with_files"),
            !(o["complete"] is JsonValue c && c.TryGetValue<bool>(out var done)) || done, JsonRead.Bool(o, "before_rollback"), match, JsonRead.Strings(o, "changed_apps"));
    }

    public static SiteSnapshotList ParseList(JsonObject o)
    {
        if (o["snapshots"] is not JsonArray array) throw new FormatException("The document has no snapshots list.");
        return new SiteSnapshotList(JsonRead.Str(o, "site") ?? "", JsonRead.Int(o, "keep") ?? 0, array.OfType<JsonObject>().Select(ParseSnapshot).OfType<SiteSnapshot>().ToList(),
            JsonRead.Strings(o, "over_limit"), JsonRead.Str(o, "last_rollback_snapshot") is { Length: > 0 } last && last != "null" ? last : null,
            Long(o, "total_bytes") ?? 0, Long(o, "free_bytes"));
    }

    /// <summary><c>site snapshot NAME --json</c>: the snapshot just taken, null when the document has none.</summary>
    public static SiteSnapshot? ParseTaken(JsonObject o) => o["snapshot"] is JsonObject s ? ParseSnapshot(s) : null;

    private static long? Long(JsonObject o, string key) => o[key] is JsonValue v && v.TryGetValue<long>(out var l) ? l : null;
}

/// <summary>The exact arguments of the snapshot commands. The bench folder goes last as <c>--bench-dir</c>.</summary>
public static class SnapshotCommands
{
    public const int MaxLabel = 120;

    public static string[] List(string site, string bench) => ["site", "snapshots", site, "--json", "--bench-dir", bench];

    public static string[] Take(string site, string? label, string bench) =>
        ["site", "snapshot", site, .. string.IsNullOrWhiteSpace(label) ? [] : new[] { "--label", label.Trim() }, "--json", "--bench-dir", bench];

    /// <summary><c>site snapshot drop</c> never gets <c>--force-undo-point</c>: the undo point of the last rollback stays a Terminal command.</summary>
    public static string[] Remove(string site, string id, string bench) => ["site", "snapshot", "drop", site, id, "--yes", "--json", "--bench-dir", bench];

    /// <summary>The base of the rollback plan; the plan sheet appends the dry run and the apply with the plan's own token.</summary>
    public static string[] Rollback(string site, string id, string bench) => ["site", "rollback", site, "--to", id, "--bench-dir", bench];

    /// <summary>What the CLI takes as a label: up to 120 characters, no quotes, backslashes or control characters. Null when it is fine.</summary>
    public static string? LabelProblem(string? label)
    {
        if (label is null) return null;
        if (label.Trim().Length > MaxLabel) return UiText.Format("SnapshotLabelMax", MaxLabel);
        return label.Any(c => c is '"' or '\'' or '\\' || char.IsControl(c)) ? UiText.Get("SnapshotLabelChars") : null;
    }

    public static string DefaultSiteNote => UiText.Get("SnapshotDefaultNote");

    /// <summary>
    /// The review of a rollback: the plan by <c>--dry-run --json</c>, the apply by <c>--apply TOKEN --yes --jsonl</c> with that plan's token. Run as the
    /// person (<c>BENCHBAR_NONINTERACTIVE=0</c>), because the CLI allows the rollback of the default site to a person only: the typed
    /// site name before it and the confirmation of the sheet are that person's decision, and the plan says so for the default site.
    /// </summary>
    public static PlanReviewRequest Review(string site, SiteSnapshot snapshot, string bench) =>
        PlanReviewRequest.Tokened(UiText.Format("SnapshotReviewTitle", site), Rollback(site, snapshot.Id, bench)) with
        {
            ConfirmLabel = UiText.Get("SnapshotRollButton"),
            CanStop = false, // a restore is not safe to kill part way
            Summary = UiText.Format("SnapshotReviewSummary", snapshot.Title, site),
            ConfigureEnv = env => env.Set(SetupEnv.NonInteractive, "0"),
            Describe = Describe,
            ExplainFailure = ShareText.RootPasswordHelp,
        };

    /// <summary>The lines under the summary: the default site, whether the apps still match, and whether migrate runs.</summary>
    public static IReadOnlyList<string> Describe(PlanDocument plan)
    {
        var lines = new List<string>();
        var rollback = plan.Raw["rollback"] as JsonObject;
        if (rollback is not null && JsonRead.Bool(rollback, "default_site")) lines.Add(DefaultSiteNote);
        lines.Add(UiText.Format("SnapshotReplaced", JsonRead.Str(plan.Raw, "site") ?? UiText.Get("SnapshotTheSite")));
        if (rollback is not null && rollback["apps_match"] is JsonValue m && m.TryGetValue<bool>(out var match))
        {
            var changed = JsonRead.Strings(rollback, "changed_apps");
            lines.Add(match ? UiText.Get("SnapshotAppsSame")
                : changed.Count > 0 ? UiText.Format("SnapshotAppsChangedList", string.Join(", ", changed)) : UiText.Get("SnapshotAppsChanged"));
        }
        lines.Add(plan.Steps.Any(s => s.Id == "migrate") ? UiText.Get("MoveMigrateRuns") : UiText.Get("SnapshotMigrateSkipped"));
        lines.Add(UiText.Get("SnapshotLeftAlone"));
        return lines;
    }
}

/// <summary>The words of the snapshot list, kept out of the view so a test can read them.</summary>
public static class SnapshotText
{
    /// <summary>"3 hours ago, 5.2 MB, with files".</summary>
    public static string Line(SiteSnapshot snapshot, DateTimeOffset now)
    {
        var age = snapshot.Time is { } t ? ActivityText.Age(t, now) : snapshot.Stamp;
        return snapshot.WithFiles
            ? UiText.Format("SnapshotLineFiles", age, ByteSize.Format(snapshot.SizeBytes))
            : UiText.Format("SnapshotLineDb", age, ByteSize.Format(snapshot.SizeBytes));
    }

    public static string? Apps(SiteSnapshot snapshot) => snapshot.AppsMatch switch
    {
        true => UiText.Get("SnapshotAppsNow"),
        false => snapshot.ChangedApps.Count == 0 ? UiText.Get("SnapshotAppsShort") : UiText.Format("SnapshotAppsSince", string.Join(", ", snapshot.ChangedApps)),
        _ => null,
    };

    public static string Summary(SiteSnapshotList list)
    {
        var parts = new List<string> { UiText.Format("SnapshotHold", ByteSize.Format(list.TotalBytes)) };
        if (list.FreeBytes is { } free) parts.Add(UiText.Format("SnapshotFree", ByteSize.Format(free)));
        if (list.OverLimit.Count > 0) parts.Add(UiText.Format("SnapshotBeyond", list.OverLimit.Count, list.Keep));
        return string.Join(' ', parts);
    }

    /// <summary>Remove is never offered for the undo point of the last rollback (the CLI needs <c>--force-undo-point</c>, which BenchBar never passes).</summary>
    public static bool CanRemove(SiteSnapshot snapshot) => !snapshot.BeforeRollback;
}
