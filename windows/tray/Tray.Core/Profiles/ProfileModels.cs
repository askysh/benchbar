using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>Where a subscribed profile comes from and how far behind it is (<c>profile list --json</c>, <c>subscription</c>).</summary>
public sealed record ProfileSubscription(string Repo, string Dir, int? Behind, int? Days, string? FetchedAt)
{
    public bool IsOutdated => (Behind ?? 0) > 0;

    /// <summary>"Outdated · 3 commits / 12 days", or null when it is not behind.</summary>
    public string? OutdatedText
    {
        get
        {
            if (Behind is not > 0) return null;
            var text = $"Outdated · {Behind} commit{(Behind == 1 ? "" : "s")}";
            if (Days is > 0) text += $" / {Days} day{(Days == 1 ? "" : "s")}";
            return text;
        }
    }
}

public enum ProfileOrigin { Builtin, User, Imported, Subscribed, Path }

/// <summary>One profile of <c>profile list --json</c>: built in or a team's.</summary>
public sealed record ProfileInfo(string Name, string Kind, string? Source, string File, string? Base, string? Label, string? FrappeBranch,
    bool Valid, string? Error, string? SourceUrl, ProfileSubscription? Subscription, string? ShadowedBy)
{
    /// <summary>A shadowed file has the same name as the one that wins, so the file is part of the id.</summary>
    public string Id => Name + "\t" + File;

    public bool IsTeam => Kind == "team";

    public ProfileOrigin Origin
    {
        get
        {
            if (Kind == "builtin") return ProfileOrigin.Builtin;
            return Source switch
            {
                "imported" => ProfileOrigin.Imported,
                "subscribed" => ProfileOrigin.Subscribed,
                "path" => ProfileOrigin.Path,
                _ => ProfileOrigin.User,
            };
        }
    }

    /// <summary>"built in", "local", "imported", "subscribed · acme/profiles".</summary>
    public string OriginText => Origin switch
    {
        ProfileOrigin.Builtin => "built in",
        ProfileOrigin.User => "local",
        ProfileOrigin.Imported => "imported",
        ProfileOrigin.Path => "profile path",
        _ => Subscription?.Repo is { } repo ? "subscribed · " + ShortRepo(repo) : "subscribed",
    };

    public bool CanExport => IsTeam && Valid;

    public bool CanCheck => IsTeam && Valid;

    public bool CanUpdate => Origin is ProfileOrigin.Imported or ProfileOrigin.Subscribed;

    public bool CanRemove => Origin is ProfileOrigin.Imported or ProfileOrigin.Subscribed;

    /// <summary>"https://github.com/acme/profiles.git" gives "acme/profiles".</summary>
    public static string ShortRepo(string repo)
    {
        var s = repo.Trim();
        if (s.EndsWith('/')) s = s[..^1];
        if (s.EndsWith(".git", StringComparison.Ordinal)) s = s[..^4];
        var parts = s.Split(['/', ':'], StringSplitOptions.RemoveEmptyEntries);
        return parts.Length >= 2 ? parts[^2] + "/" + parts[^1] : repo;
    }
}

public static class ProfileListJson
{
    public static IReadOnlyList<ProfileInfo> Parse(JsonObject o)
    {
        if (o["profiles"] is not JsonArray array)
            throw new FormatException("The profile list did not contain a profiles array.");
        var profiles = new List<ProfileInfo>();
        foreach (var p in array.OfType<JsonObject>())
        {
            var name = JsonRead.Str(p, "name");
            if (string.IsNullOrEmpty(name)) continue;
            ProfileSubscription? sub = null;
            if (p["subscription"] is JsonObject s)
                sub = new ProfileSubscription(JsonRead.Str(s, "repo") ?? "", JsonRead.Str(s, "dir") ?? "", JsonRead.Int(s, "behind"), JsonRead.Int(s, "days"), JsonRead.Str(s, "fetched_at"));
            profiles.Add(new ProfileInfo(name, JsonRead.Str(p, "kind") ?? "team", JsonRead.Str(p, "source"), JsonRead.Str(p, "file") ?? "",
                JsonRead.Str(p, "base"), JsonRead.Str(p, "label"), JsonRead.Str(p, "frappe_branch"),
                !(p["valid"] is JsonValue v && v.TryGetValue<bool>(out var valid)) || valid,
                JsonRead.Str(p, "error"), JsonRead.Str(p, "source_url"), sub, JsonRead.Str(p, "shadowed_by")));
        }
        return profiles;
    }

    /// <summary>The names of the profiles of the subscription a profile belongs to (the remove message lists them).</summary>
    public static IReadOnlyList<string> SiblingsOf(IReadOnlyList<ProfileInfo> all, ProfileInfo profile) =>
        all.Where(p => p.Origin == ProfileOrigin.Subscribed && p.Subscription?.Dir == profile.Subscription?.Dir).Select(p => p.Name).ToList();
}

/// <summary>The access words the CLI uses for a repository.</summary>
public static class RepoAccess
{
    public static string Label(string? access) => access switch
    {
        "public" => "public",
        "private" => "private",
        "personal" => "personal account",
        _ => "unknown",
    };
}

// --- export ---

public sealed record ProfileExportApp(string Name, string Repo, string ExportedRepo, string? CurrentBranch, string ExportedBranch,
    string? DefaultBranch, bool BranchVerified, string Access, IReadOnlyList<string> Requires, bool Keep);

/// <summary><c>profile export NAME --plan --json</c>: read only.</summary>
public sealed record ProfileExportPlan(string Name, string? Base, IReadOnlyList<ProfileExportApp> Apps, IReadOnlyList<string> Warnings, string? Digest)
{
    public static ProfileExportPlan Parse(JsonObject o)
    {
        if (o["apps"] is not JsonArray array)
            throw new FormatException("The export plan did not contain an apps array.");
        var apps = new List<ProfileExportApp>();
        foreach (var a in array.OfType<JsonObject>())
        {
            var name = JsonRead.Str(a, "name");
            if (string.IsNullOrEmpty(name)) continue;
            var repo = JsonRead.Str(a, "repo") ?? "";
            apps.Add(new ProfileExportApp(name, repo, JsonRead.Str(a, "exported_repo") ?? repo, JsonRead.Str(a, "current_branch"),
                JsonRead.Str(a, "exported_branch") ?? "", JsonRead.Str(a, "default_branch"), JsonRead.Bool(a, "branch_verified"),
                JsonRead.Str(a, "access") ?? "unknown", JsonRead.Strings(a, "requires"),
                !(a["keep"] is JsonValue k && k.TryGetValue<bool>(out var keep)) || keep));
        }
        return new ProfileExportPlan(JsonRead.Str(o, "name") ?? "", JsonRead.Str(o, "base"), apps, JsonRead.Strings(o, "warnings"), JsonRead.Str(o, "digest"));
    }
}

/// <summary><c>profile export NAME --out FILE ... --yes --json</c>.</summary>
public sealed record ProfileExportResult(string Path, int Apps, IReadOnlyList<string> Dropped)
{
    public static ProfileExportResult Parse(JsonObject o) =>
        new(JsonRead.Str(o, "path") ?? throw new FormatException("The export result has no path."), JsonRead.Int(o, "apps") ?? 0, JsonRead.Strings(o, "dropped"));
}

/// <summary>What the person picked in the export sheet: a branch per app and which apps to keep. Pure, so the rules are tested alone.</summary>
public sealed class ProfileExportChoices
{
    private readonly Dictionary<string, string> _branches = new(StringComparer.Ordinal);
    private readonly Dictionary<string, bool> _keep = new(StringComparer.Ordinal);

    public ProfileExportChoices(ProfileExportPlan plan)
    {
        foreach (var app in plan.Apps)
        {
            _branches.TryAdd(app.Name, app.ExportedBranch);
            _keep.TryAdd(app.Name, app.Keep);
        }
    }

    public bool Keeps(string app) => _keep.GetValueOrDefault(app, true);

    public string Branch(ProfileExportApp app) => _branches.GetValueOrDefault(app.Name, app.ExportedBranch);

    public void SetKeep(string app, bool keep) => _keep[app] = keep;

    public void SetBranch(string app, string branch) => _branches[app] = branch;

    /// <summary>Why Export is off, or null when it can run.</summary>
    public string? Problem(ProfileExportPlan plan)
    {
        foreach (var dropped in plan.Apps.Where(a => !Keeps(a.Name)))
        {
            var by = plan.Apps.Where(a => Keeps(a.Name) && a.Requires.Contains(dropped.Name)).Select(a => a.Name).ToList();
            if (by.Count > 0) return $"{dropped.Name} is required by {string.Join(", ", by)}: keep it, or drop those too.";
        }
        if (!plan.Apps.Any(a => Keeps(a.Name))) return "Keep at least one app.";
        foreach (var app in plan.Apps.Where(a => Keeps(a.Name)))
        {
            if (!IsBranch(Branch(app).Trim())) return $"{app.Name} needs a branch name.";
        }
        return null;
    }

    /// <summary>
    /// <c>--branch APP=BR</c> for every kept app (not only the edited ones: the CLI would work out a default again, which may differ
    /// from the one the sheet showed) and <c>--drop APP</c> for every dropped app.
    /// </summary>
    public IReadOnlyList<string> Arguments(ProfileExportPlan plan)
    {
        var args = new List<string>();
        foreach (var app in plan.Apps.Where(a => Keeps(a.Name))) args.AddRange(["--branch", $"{app.Name}={Branch(app).Trim()}"]);
        foreach (var app in plan.Apps.Where(a => !Keeps(a.Name))) args.AddRange(["--drop", app.Name]);
        return args;
    }

    /// <summary>A git branch name, loosely: no spaces, no leading dash, no "..", no "=".</summary>
    public static bool IsBranch(string text) =>
        text.Length > 0 && !text.StartsWith('-') && !text.Contains("..", StringComparison.Ordinal) && !text.Any(c => char.IsWhiteSpace(c) || c == '=');
}

// --- import, check ---

/// <summary>One repository's reachability with the person's own credentials; <see cref="Reachable"/> is null when the machine is offline.</summary>
public sealed record ProfileRepoCheck(string App, string Repo, bool? Reachable, string? Reason)
{
    /// <summary>A check mark, a cross or a question mark.</summary>
    public string Mark => Reachable switch { true => "✓", false => "✗", null => "?" };

    public string Accessibility => Reachable switch { true => "reachable", false => "not reachable", null => "not checked" };

    public static ProfileRepoCheck Parse(JsonObject o) => new(JsonRead.Str(o, "app") ?? "", JsonRead.Str(o, "repo") ?? "",
        o["reachable"] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : null, JsonRead.Str(o, "reason"));

    public static IReadOnlyList<ProfileRepoCheck> ParseAll(JsonArray? array) =>
        array is null ? [] : array.OfType<JsonObject>().Select(Parse).ToList();
}

public sealed record ProfileImportApp(string Name, string Repo, string? Branch, string? Access, IReadOnlyList<string> Requires);

/// <summary><c>profile import SRC [--as NAME] --plan --json</c>: nothing is written.</summary>
public sealed record ProfileImportPlan(string Name, string Source, bool Exists, string? Diff, string? Base, IReadOnlyList<ProfileImportApp> Apps,
    IReadOnlyList<ProfileRepoCheck> Checks, IReadOnlyList<string> SkippedApps, string? Digest)
{
    public ProfileRepoCheck? CheckFor(string app) => Checks.FirstOrDefault(c => c.App == app);

    public static ProfileImportPlan Parse(JsonObject o)
    {
        var name = JsonRead.Str(o, "name") ?? throw new FormatException("The import plan has no profile name.");
        var apps = new List<ProfileImportApp>();
        if (o["apps"] is JsonArray array)
        {
            foreach (var a in array.OfType<JsonObject>())
                apps.Add(new ProfileImportApp(JsonRead.Str(a, "name") ?? "", JsonRead.Str(a, "repo") ?? "", JsonRead.Str(a, "branch"), JsonRead.Str(a, "access"), JsonRead.Strings(a, "requires")));
        }
        var checks = ProfileRepoCheck.ParseAll((o["check"] as JsonObject)?["repos"] as JsonArray);
        return new ProfileImportPlan(name, JsonRead.Str(o, "source") ?? "", JsonRead.Bool(o, "exists"), JsonRead.Str(o, "diff"), JsonRead.Str(o, "base"),
            apps, checks, JsonRead.Strings(o, "skipped_apps"), JsonRead.Str(o, "digest"));
    }
}

/// <summary><c>profile import SRC --yes --json</c>.</summary>
public sealed record ProfileImportResult(string Name, string Path, string Source)
{
    public static ProfileImportResult Parse(JsonObject o) =>
        new(JsonRead.Str(o, "name") ?? throw new FormatException("The import result has no name."), JsonRead.Str(o, "path") ?? "", JsonRead.Str(o, "source") ?? "");
}

/// <summary><c>profile check NAME --json</c>.</summary>
public sealed record ProfileCheck(string Name, IReadOnlyList<ProfileRepoCheck> Repos, IReadOnlyList<string> SkippedApps)
{
    public static ProfileCheck Parse(JsonObject o)
    {
        if (o["repos"] is not JsonArray array)
            throw new FormatException("The access check did not contain a repos array.");
        return new ProfileCheck(JsonRead.Str(o, "name") ?? "", ProfileRepoCheck.ParseAll(array), JsonRead.Strings(o, "skipped_apps"));
    }

    /// <summary>The headline of the check sheet: every repository reachable, or how many are not and what a bench would skip.</summary>
    public (bool Warning, string Title, string? Detail) Verdict()
    {
        var missing = Repos.Count(r => r.Reachable != true);
        if (missing == 0 && SkippedApps.Count == 0) return (false, "This machine can reach every repository", null);
        var title = missing == 0 ? "Some apps would be left out" : missing == 1 ? "1 repository is not reachable" : $"{missing} repositories are not reachable";
        var detail = SkippedApps.Count == 0
            ? "Ask the repository owner for access, then check again."
            : $"A bench set up from this profile now would skip: {string.Join(", ", SkippedApps)}. Ask the repository owner for access, then check again.";
        return (true, title, detail);
    }
}

// --- subscribe, update, remove ---

/// <summary><c>profile subscribe GIT_URL --yes --json</c>.</summary>
public sealed record ProfileSubscribeResult(string Repo, string Dir, IReadOnlyList<string> Profiles)
{
    public static ProfileSubscribeResult Parse(JsonObject o) =>
        new(JsonRead.Str(o, "repo") ?? "", JsonRead.Str(o, "dir") ?? "", JsonRead.Strings(o, "profiles"));
}

public sealed record ProfileUpdate(string Name, string Kind, int? Behind, string? Diff)
{
    public bool HasChanges => (Behind ?? 0) > 0 || !string.IsNullOrWhiteSpace(Diff);
}

/// <summary><c>profile update NAME --plan --json</c>, and with <c>--yes</c> the same plus <c>applied</c>.</summary>
public sealed record ProfileUpdatePlan(IReadOnlyList<ProfileUpdate> Updates, bool? Applied, string? Digest)
{
    public bool HasChanges => Updates.Any(u => u.HasChanges);

    public static ProfileUpdatePlan Parse(JsonObject o)
    {
        if (o["updates"] is not JsonArray array)
            throw new FormatException("The update plan did not contain an updates array.");
        var updates = array.OfType<JsonObject>().Select(u => new ProfileUpdate(JsonRead.Str(u, "name") ?? "", JsonRead.Str(u, "kind") ?? "",
            JsonRead.Int(u, "behind"), JsonRead.Str(u, "diff"))).ToList();
        return new ProfileUpdatePlan(updates, o["applied"] is JsonValue v && v.TryGetValue<bool>(out var applied) ? applied : null, JsonRead.Str(o, "digest"));
    }
}

/// <summary><c>profile remove NAME --yes --json</c>.</summary>
public sealed record ProfileRemoveResult(string Name, string MovedTo)
{
    public static ProfileRemoveResult Parse(JsonObject o) =>
        new(JsonRead.Str(o, "name") ?? "", JsonRead.Str(o, "moved_to") ?? "");
}

// --- rules ---

public static class ProfileName
{
    /// <summary>The CLI's rule: <c>^[a-z0-9][a-z0-9._-]*$</c>. Unlike a site name, an underscore is allowed.</summary>
    public static bool IsValid(string name)
    {
        if (name.Length == 0 || !LowerOrDigit(name[0])) return false;
        return name.All(c => LowerOrDigit(c) || c is '.' or '_' or '-');
    }

    private static bool LowerOrDigit(char c) => c is >= 'a' and <= 'z' or >= '0' and <= '9';
}

/// <summary>
/// What may be imported or subscribed to, from a text field. The CLI checks again; this keeps an odd string (a flag, an
/// <c>ext::</c> transport) from ever reaching its argument list. A file may be a Windows path: it is converted before the call.
/// </summary>
public static class ProfileSourceRule
{
    /// <summary>An https URL with a host: the only remote source import accepts.</summary>
    public static bool IsImportUrl(string text)
    {
        var s = text.Trim();
        if (s.Length == 0 || s.StartsWith('-') || s.Any(char.IsWhiteSpace)) return false;
        return Uri.TryCreate(s, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps && uri.Host.Length > 0;
    }

    /// <summary>A local .toml file: a Windows path (<c>C:\x\a.toml</c>, a UNC path) or a Linux path (<c>/home/a/a.toml</c>).</summary>
    public static bool IsLocalFile(string text)
    {
        var s = text.Trim();
        if (!s.EndsWith(".toml", StringComparison.OrdinalIgnoreCase)) return false;
        return s.StartsWith('/') || WslPaths.IsWindowsPath(s);
    }

    public static bool IsImportSource(string text) => IsImportUrl(text) || IsLocalFile(text);

    /// <summary>A git remote: https or ssh URL, or scp style <c>user@host:owner/repo</c>. No file://, no local paths, no <c>ext::</c>.</summary>
    public static bool IsGitUrl(string text)
    {
        var s = text.Trim();
        if (s.Length == 0 || s.StartsWith('-') || s.Any(char.IsWhiteSpace) || s.Contains("::", StringComparison.Ordinal)) return false;
        if (s.Contains("://", StringComparison.Ordinal))
        {
            if (!Uri.TryCreate(s, UriKind.Absolute, out var uri)) return false;
            return uri.Scheme is "https" or "ssh" && uri.Host.Length > 0 && uri.AbsolutePath.Length > 1;
        }
        var at = s.IndexOf('@');
        if (at <= 0) return false;
        var colon = s.IndexOf(':', at);
        if (colon < 0) return false;
        var host = s[(at + 1)..colon];
        var path = s[(colon + 1)..];
        return host.Length > 0 && !host.Contains('/') && path.Length > 0 && !path.StartsWith('/');
    }
}
