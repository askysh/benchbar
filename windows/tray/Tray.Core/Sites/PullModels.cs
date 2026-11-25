using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>What the Pull form asks for. <see cref="Source"/> is <c>HOST:SITE</c> over SSH, or a backup folder inside the distro.</summary>
public sealed record PullInput(string Source, bool FromFolder, string Name, bool KeepSecrets);

/// <summary>
/// <c>benchbar pull</c> as the Pull sheet runs it: <c>--dry-run --json</c> for the plan, then <c>--apply TOKEN --yes --jsonl</c> with the
/// same arguments. The token is the one the plan printed; the tray never computes it.
/// </summary>
public static class PullCommands
{
    public static string NeutralisedText => UiText.Get("PullNeutralised");

    public static string KeptText => UiText.Get("PullKept");

    /// <summary>The base of both calls. <c>--keep-secrets</c> is there only when the person chose it.</summary>
    public static string[] Base(PullInput input, string bench) =>
    [
        "pull", .. input.FromFolder ? new[] { "--from-dir", input.Source } : [input.Source],
        "--as", input.Name, .. input.KeepSecrets ? new[] { "--keep-secrets" } : [], "--bench-dir", bench,
    ];

    public static PlanReviewRequest Review(PullInput input, string bench) => PlanReviewRequest.Tokened(UiText.Format("PullTitle", input.Name), Base(input, bench)) with
    {
        ConfirmLabel = UiText.Get("PullConfirm"),
        CanStop = false, // a restore is not safe to kill part way
        UsesSudoEnv = false,
        Summary = input.FromFolder
            ? UiText.Format("PullSummaryFolder", input.Source, input.Name)
            : UiText.Format("PullSummaryServer", input.Source, input.Name),
        Describe = Describe,
        ExplainFailure = ShareText.RootPasswordHelp,
    };

    /// <summary><c>HOST:SITE</c> with nothing else in it: the CLI splits on the first colon; HOST is a Host of <c>~/.ssh/config</c> and does not start with a dash (it would be an option of ssh).</summary>
    public static bool IsValidSsh(string? text)
    {
        if (string.IsNullOrEmpty(text)) return false;
        var parts = text.Split(':');
        return parts.Length == 2 && parts[0].Length > 0 && parts[0][0] != '-' && parts[1].Length > 0 && text.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-' or ':');
    }

    /// <summary>The default local name, as the CLI's own: the production site's name with <c>.local</c> (empty until there is one).</summary>
    public static string DefaultName(string? source)
    {
        var parts = (source ?? "").Split(':');
        return parts.Length > 1 && parts[1].Length > 0 ? parts[1].ToLowerInvariant() + ".local" : "";
    }

    /// <summary>What is wrong with the form, or null when it can go to the plan. Pull never overwrites a site, so a name in use is refused.</summary>
    public static string? Problem(PullInput input, IEnumerable<string> existingSites)
    {
        if (input.FromFolder)
        {
            if (string.IsNullOrWhiteSpace(input.Source)) return UiText.Get("PullEnterFolder");
            if (!input.Source.Trim().StartsWith('/') && !input.Source.Trim().StartsWith('~')) return UiText.Get("PullFolderPath");
        }
        else if (!IsValidSsh(input.Source)) return UiText.Get("PullEnterServer");
        if (!SiteNames.IsValid(input.Name)) return input.Name.Length == 0 ? UiText.Get("PullEnterName") : SiteNames.Rule;
        if (existingSites.Contains(input.Name)) return UiText.Format("PullNameTaken", input.Name);
        return null;
    }

    /// <summary>The lines of the plan the sheet shows above its steps: where the copy comes from, what it loses, the apps that differ.</summary>
    public static IReadOnlyList<string> Describe(PlanDocument plan)
    {
        var o = plan.Raw;
        var lines = new List<string>();
        var neutralise = o["neutralise"] is JsonValue n && n.TryGetValue<bool>(out var on) && on; // absent counts as not neutralised, never as neutralised
        if (!neutralise) lines.Add(UiText.Get("PullWarnSecrets"));
        if (BackupLine(o["backup"] as JsonObject) is { } backup) lines.Add(UiText.Format("PullBackupLine", backup));
        var site = JsonRead.Str(o, "site");
        if (site is not null)
        {
            var creates = !(o["create_site"] is JsonValue c && c.TryGetValue<bool>(out var create)) || create;
            lines.Add(creates ? UiText.Format("PullLocalCreated", site) : UiText.Format("PullLocalReplaced", site));
            if (!SiteNames.ResolvesOnWindows(site))
                lines.Add(UiText.Format("PullHostsLine", site));
        }
        lines.Add(UiText.Format("PullCopyLine", neutralise ? NeutralisedText : KeptText));
        if (o["encryption_key"] is JsonValue k && k.TryGetValue<bool>(out var key) && key)
            lines.Add(UiText.Get("PullEncryptionKey"));
        if (o["apps"] is JsonArray apps)
        {
            foreach (var app in apps.OfType<JsonObject>())
            {
                var status = JsonRead.Str(app, "status");
                if (status is null or "ok" or "skipped") continue;
                lines.Add(UiText.Format("PullAppDiffers", AppLine(app, status)));
            }
        }
        lines.Add(UiText.Get("PullLeftAlone"));
        if (plan.Token is null) lines.Add(UiText.Get("PullNoToken"));
        return lines;
    }

    /// <summary>"20260925_020000-erp_example_com-database.sql.gz, 7.0 MB, 31 hours old"; a backup that does not exist yet says a new one is taken.</summary>
    public static string? BackupLine(JsonObject? backup)
    {
        if (backup is null) return null;
        var name = JsonRead.Str(backup, "name");
        if (name is null) return UiText.Get("PullBackupNew");
        var parts = new List<string> { name };
        if (backup["bytes"] is JsonValue b && b.TryGetValue<long>(out var bytes)) parts.Add(ByteSize.Format(bytes));
        if (JsonRead.Int(backup, "age_hours") is { } hours) parts.Add(hours >= 48 ? UiText.Format("PullDaysOld", hours / 24) : UiText.Format("PullHoursOld", hours));
        if (JsonRead.Bool(backup, "encrypted")) parts.Add(UiText.Get("PullEncrypted"));
        return string.Join(", ", parts);
    }

    private static string AppLine(JsonObject app, string status)
    {
        var name = JsonRead.Str(app, "app") ?? UiText.Get("PullAnApp");
        var versions = new List<string>();
        if (JsonRead.Str(app, "local_version") is { Length: > 0 } local) versions.Add(UiText.Format("PullVersionHere", local));
        if (JsonRead.Str(app, "production_version") is { Length: > 0 } prod) versions.Add(UiText.Format("PullVersionProd", prod));
        return versions.Count == 0 ? UiText.Format("OverviewDriftLine", name, status) : UiText.Format("OverviewDriftLineDetail", name, string.Join(", ", versions), status);
    }
}
