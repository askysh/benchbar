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
    public const string NeutralisedText = "Integrations are switched off and stored passwords are cleared on the copy; the Administrator login is kept. Email is muted and the scheduler paused. Customer data is not touched.";

    public const string KeptText = "Production's passwords, webhooks and integrations stay on the copy. Email is muted and the scheduler paused, but the copy can still talk to the outside.";

    /// <summary>The base of both calls. <c>--keep-secrets</c> is there only when the person chose it.</summary>
    public static string[] Base(PullInput input, string bench) =>
    [
        "pull", .. input.FromFolder ? new[] { "--from-dir", input.Source } : [input.Source],
        "--as", input.Name, .. input.KeepSecrets ? new[] { "--keep-secrets" } : [], "--bench-dir", bench,
    ];

    public static PlanReviewRequest Review(PullInput input, string bench) => PlanReviewRequest.Tokened($"Pull {input.Name}", Base(input, bench)) with
    {
        ConfirmLabel = "Pull",
        CanStop = false, // a restore is not safe to kill part way
        UsesSudoEnv = false,
        Summary = input.FromFolder
            ? $"Copies the backup in {input.Source} into a new site, {input.Name}. Nothing is read from a server."
            : $"Copies the latest backup of {input.Source} into a new site, {input.Name}. Production is only read.",
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
            if (string.IsNullOrWhiteSpace(input.Source)) return "Enter the folder of the backup, as a path inside Ubuntu.";
            if (!input.Source.Trim().StartsWith('/') && !input.Source.Trim().StartsWith('~')) return "The folder is a path inside Ubuntu, such as /home/you/backup or ~/backup.";
        }
        else if (!IsValidSsh(input.Source)) return "Enter the server as HOST:SITE, for example prod:erp.example.com. HOST is a Host of ~/.ssh/config in Ubuntu.";
        if (!SiteNames.IsValid(input.Name)) return input.Name.Length == 0 ? "Enter a name for the new site." : SiteNames.Rule;
        if (existingSites.Contains(input.Name)) return $"{input.Name} is already a site of this bench. Pull never overwrites one here.";
        return null;
    }

    /// <summary>The lines of the plan the sheet shows above its steps: where the copy comes from, what it loses, the apps that differ.</summary>
    public static IReadOnlyList<string> Describe(PlanDocument plan)
    {
        var o = plan.Raw;
        var lines = new List<string>();
        var neutralise = o["neutralise"] is JsonValue n && n.TryGetValue<bool>(out var on) && on; // absent counts as not neutralised, never as neutralised
        if (!neutralise) lines.Add("Warning: the copy keeps production's secrets. Do not start its scheduler or workers unless you mean to reach the same services as production.");
        if (BackupLine(o["backup"] as JsonObject) is { } backup) lines.Add("Backup: " + backup);
        var site = JsonRead.Str(o, "site");
        if (site is not null)
        {
            var creates = !(o["create_site"] is JsonValue c && c.TryGetValue<bool>(out var create)) || create;
            lines.Add("Local site: " + (creates ? $"{site} is created on this bench." : $"{site} is replaced, after a backup."));
            if (!SiteNames.ResolvesOnWindows(site))
                lines.Add($"Windows finds only names that end in .localhost. {site} needs a line in the Windows hosts file to open in your browser, and BenchBar never edits it.");
        }
        lines.Add("The copy: " + (neutralise ? NeutralisedText : KeptText));
        if (o["encryption_key"] is JsonValue k && k.TryGetValue<bool>(out var key) && key)
            lines.Add("Encryption key: production's key comes over, so stored passwords that are kept still decrypt.");
        if (o["apps"] is JsonArray apps)
        {
            foreach (var app in apps.OfType<JsonObject>())
            {
                var status = JsonRead.Str(app, "status");
                if (status is null or "ok" or "skipped") continue;
                lines.Add("App that differs: " + AppLine(app, status));
            }
        }
        lines.Add("Left alone: production (nothing is written there) and every other site of this bench.");
        if (plan.Token is null) lines.Add("This command line tool does not give a plan token, so BenchBar cannot run exactly this plan. Update it, then review again.");
        return lines;
    }

    /// <summary>"20260925_020000-erp_example_com-database.sql.gz, 7.0 MB, 31 hours old"; a backup that does not exist yet says a new one is taken.</summary>
    public static string? BackupLine(JsonObject? backup)
    {
        if (backup is null) return null;
        var name = JsonRead.Str(backup, "name");
        if (name is null) return "a new backup is taken on the server first.";
        var parts = new List<string> { name };
        if (backup["bytes"] is JsonValue b && b.TryGetValue<long>(out var bytes)) parts.Add(ByteSize.Format(bytes));
        if (JsonRead.Int(backup, "age_hours") is { } hours) parts.Add(hours >= 48 ? $"{hours / 24} days old" : $"{hours} hours old");
        if (JsonRead.Bool(backup, "encrypted")) parts.Add("encrypted, decrypted here with gpg");
        return string.Join(", ", parts);
    }

    private static string AppLine(JsonObject app, string status)
    {
        var name = JsonRead.Str(app, "app") ?? "an app";
        var versions = new List<string>();
        if (JsonRead.Str(app, "local_version") is { Length: > 0 } local) versions.Add($"{local} here");
        if (JsonRead.Str(app, "production_version") is { Length: > 0 } prod) versions.Add($"{prod} on production");
        return versions.Count == 0 ? $"{name}: {status}" : $"{name}: {string.Join(", ", versions)} ({status})";
    }
}
