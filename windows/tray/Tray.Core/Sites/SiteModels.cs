using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>The rule for a site name (the CLI's <c>fl_site_valid_name</c>) and what Windows can resolve.</summary>
public static class SiteNames
{
    public const string Rule = "Lowercase letters, digits, '-' and '.' only.";

    public static bool IsValid(string? name)
    {
        if (string.IsNullOrEmpty(name)) return false;
        if (!(char.IsAsciiLetterLower(name[0]) || char.IsAsciiDigit(name[0]))) return false;
        return name.All(c => char.IsAsciiLetterLower(c) || char.IsAsciiDigit(c) || c is '-' or '.');
    }

    /// <summary>Windows resolves <c>*.localhost</c> to 127.0.0.1 by itself; any other name needs a hosts line, which the tray never writes.</summary>
    public static bool ResolvesOnWindows(string name) =>
        name == "localhost" || name.EndsWith(".localhost", StringComparison.Ordinal);

    /// <summary>The name with <c>.localhost</c> added, unless it already resolves.</summary>
    public static string WithLocalhost(string name) => ResolvesOnWindows(name) ? name : name.TrimEnd('.') + ".localhost";
}

/// <summary>One row of the Sites tab.</summary>
public sealed record SiteRowInfo(string Name, bool IsDefault, string? Url, bool CanOpen, bool NeedsSetUp)
{
    /// <summary>"Open" for a site Windows can reach, "Set Up..." for one it cannot.</summary>
    public string ActionLabel => NeedsSetUp ? "Set Up..." : "Open";
}

public static class SiteRows
{
    public static IReadOnlyList<SiteRowInfo> From(BenchStatus bench)
    {
        var rows = new List<SiteRowInfo>();
        foreach (var site in bench.Sites)
        {
            var needsSetUp = !SiteNames.ResolvesOnWindows(site.Name);
            var url = UrlFor(bench.WebUrl, site.Name);
            rows.Add(new SiteRowInfo(site.Name, site.IsDefault, url, !needsSetUp && url is not null && bench.State == BenchState.Running, needsSetUp));
        }
        return rows;
    }

    /// <summary>The bench's web address with <paramref name="site"/> as the host (<c>http://one.localhost:8000</c>); null without an address.</summary>
    public static string? UrlFor(string? webUrl, string site)
    {
        if (!Uri.TryCreate(webUrl, UriKind.Absolute, out var uri)) return null;
        return uri.IsDefaultPort ? $"{uri.Scheme}://{site}" : $"{uri.Scheme}://{site}:{uri.Port}";
    }
}

public enum SiteAction { MakeDefault, BackUp, BackUpWithFiles, Backups, Restore, Console, Database, Drop }

public sealed record SiteMenuItem(SiteAction Action, string Label, bool Enabled, bool Destructive = false);

/// <summary>The per site menu: what it lists and which entries are off.</summary>
public static class SiteMenu
{
    public static IReadOnlyList<SiteMenuItem> For(SiteRowInfo row, bool onlySite)
    {
        var items = new List<SiteMenuItem>();
        if (!row.IsDefault) items.Add(new(SiteAction.MakeDefault, "Make Default", true));
        items.Add(new(SiteAction.BackUp, "Back Up", true));
        items.Add(new(SiteAction.BackUpWithFiles, "Back Up with Files", true));
        items.Add(new(SiteAction.Backups, "Backups...", true));
        items.Add(new(SiteAction.Restore, "Restore...", true));
        items.Add(new(SiteAction.Console, "Open Console", true));
        items.Add(new(SiteAction.Database, "Open Database", true));
        items.Add(new(SiteAction.Drop, "Drop Site...", !onlySite, Destructive: true));
        return items;
    }
}

/// <summary>The exact CLI arguments of every Sites action. The bench folder always goes last as <c>--bench-dir</c>.</summary>
public static class SiteCommands
{
    public static string[] MakeDefault(string site, string bench) => ["site", "default", site, "--jsonl", "--bench-dir", bench];

    public static string[] BackUp(string site, bool withFiles, string bench) =>
        ["site", "backup", site, .. withFiles ? new[] { "--with-files" } : [], "--json", "--bench-dir", bench];

    public static string[] Backups(string site, string bench) => ["site", "backups", site, "--json", "--bench-dir", bench];

    /// <summary>The base of the add plan; the plan sheet appends <c>--dry-run --json</c>, then <c>--apply TOKEN --yes --jsonl</c>.</summary>
    public static string[] Add(string site, string bench) => ["site", "add", site, "--bench-dir", bench];

    /// <summary>The base of the restore plan; the plan sheet appends the dry run and the apply.</summary>
    public static string[] Restore(string site, SiteBackup backup, string bench) =>
        ["site", "restore", site, "--from", backup.Stamp, .. backup.WithFiles ? new[] { "--with-files" } : [], "--bench-dir", bench];

    public static string[] DropPlan(string site, string? newDefault, string bench) =>
        ["site", "drop", site, "--confirm-site", site, .. NewDefault(newDefault), "--dry-run", "--json", "--bench-dir", bench];

    /// <summary><paramref name="confirm"/> is what the person typed: the CLI refuses unless it is the site name exactly.</summary>
    public static string[] Drop(string site, string confirm, string? newDefault, string bench) =>
        ["site", "drop", site, "--confirm-site", confirm, .. NewDefault(newDefault), "--json", "--bench-dir", bench];

    private static string[] NewDefault(string? name) => string.IsNullOrEmpty(name) ? [] : ["--new-default", name];
}

/// <summary>A backup set of a site (docs/json-schema.md, Site backups).</summary>
public sealed record SiteBackup(string Stamp, DateTimeOffset? Time, string? Path, string? Database, string? Files, string? PrivateFiles,
    string? Config, long SizeBytes, bool WithFiles, bool Encrypted, bool Partial)
{
    /// <summary>The restore reads a plain set with its database; an encrypted or partial one is refused by the CLI.</summary>
    public bool CanRestore => !Encrypted && !Partial && (Database ?? Path) is not null;

    public string WhyNotRestorable => Encrypted ? "This backup is encrypted; site restore takes a plain set."
        : Partial ? "This is a partial backup; site restore takes a full set."
        : "This backup has no database file.";

    /// <summary>"Sep 29 2026 10:15, 5.0 MB, with files".</summary>
    public string Summary(TimeZoneInfo? zone = null)
    {
        var parts = new List<string>();
        if (Time is { } t) parts.Add(TimeZoneInfo.ConvertTime(t, zone ?? TimeZoneInfo.Local).ToString("MMM d yyyy HH:mm", System.Globalization.CultureInfo.InvariantCulture));
        else parts.Add(Stamp);
        parts.Add(ByteSize.Format(SizeBytes));
        if (WithFiles) parts.Add("with files");
        if (Encrypted) parts.Add("encrypted");
        if (Partial) parts.Add("partial");
        return string.Join(", ", parts);
    }
}

public sealed record SiteBackupList(string Site, string? Folder, IReadOnlyList<SiteBackup> Backups);

public sealed record SiteBackupResult(string Site, SiteBackup? Backup);

public static class ByteSize
{
    public static string Format(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        double value = bytes;
        var i = 0;
        while (value >= 1024 && i < units.Length - 1) { value /= 1024; i++; }
        return i == 0 ? $"{bytes} B" : value.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + " " + units[i];
    }
}

/// <summary>Readers for the documents of <c>site backup</c>, <c>site backups</c> and <c>site drop</c>.</summary>
public static class SiteJson
{
    public static SiteBackup ParseBackup(JsonObject o)
    {
        var stamp = JsonRead.Str(o, "stamp");
        if (string.IsNullOrEmpty(stamp)) throw new FormatException("A backup has no stamp.");
        DateTimeOffset? time = DateTimeOffset.TryParse(JsonRead.Str(o, "time"), System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.AssumeUniversal, out var t) ? t : null;
        var size = o["size_bytes"] is JsonValue v && v.TryGetValue<long>(out var l) ? l : 0;
        return new SiteBackup(stamp, time, JsonRead.Str(o, "path"), JsonRead.Str(o, "database"), JsonRead.Str(o, "files"),
            JsonRead.Str(o, "private_files"), JsonRead.Str(o, "config"), size, JsonRead.Bool(o, "with_files"),
            JsonRead.Bool(o, "encrypted"), JsonRead.Bool(o, "partial"));
    }

    public static SiteBackupList ParseList(JsonObject o)
    {
        if (o["backups"] is not JsonArray array) throw new FormatException("The document has no backups list.");
        return new SiteBackupList(JsonRead.Str(o, "site") ?? "", JsonRead.Str(o, "folder"),
            array.OfType<JsonObject>().Select(ParseBackup).ToList());
    }

    public static SiteBackupResult ParseBackupResult(JsonObject o) =>
        new(JsonRead.Str(o, "site") ?? "", o["backup"] is JsonObject b ? ParseBackup(b) : null);

    public static SiteDropPlan ParseDropPlan(JsonObject o)
    {
        var steps = new List<SiteDropStep>();
        if (o["steps"] is JsonArray array)
        {
            foreach (var s in array.OfType<JsonObject>())
                steps.Add(new SiteDropStep(JsonRead.Str(s, "title") ?? JsonRead.Str(s, "name") ?? "", JsonRead.Str(s, "command"), JsonRead.Bool(s, "needs_password")));
        }
        if (JsonRead.Str(o, "site") is not { Length: > 0 } site) throw new FormatException("The drop plan names no site.");
        return new SiteDropPlan(site, JsonRead.Bool(o, "is_default"), JsonRead.Str(o, "new_default"), steps);
    }

    public static SiteDropResult ParseDropResult(JsonObject o) =>
        new(JsonRead.Bool(o, "dropped"), JsonRead.Str(o, "archived_path"), o["backup"] is JsonObject b ? ParseBackup(b) : null, JsonRead.Str(o, "new_default"));
}

public sealed record SiteDropStep(string Title, string? Command, bool NeedsPassword);

public sealed record SiteDropPlan(string Site, bool IsDefault, string? NewDefault, IReadOnlyList<SiteDropStep> Steps);

public sealed record SiteDropResult(bool Dropped, string? ArchivedPath, SiteBackup? Backup, string? NewDefault);

/// <summary>What can stop a drop before the CLI is asked.</summary>
public static class SiteDropRules
{
    /// <summary>The sites a default site could hand the default to.</summary>
    public static IReadOnlyList<string> Successors(IEnumerable<SiteRowInfo> rows, string site) =>
        rows.Select(r => r.Name).Where(n => n != site).ToList();

    public static string? Blocker(IReadOnlyList<SiteRowInfo> rows, string site) =>
        rows.Count(r => r.Name != site) == 0 ? $"{site} is the only site of this bench. Add another site before dropping it." : null;
}

public enum SiteShellKind { Console, Database }
