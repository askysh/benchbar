using System.Text.RegularExpressions;
using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>The focus pin of an app (macos FocusPin): Auto infers, Focus always counts, Ignore never counts.</summary>
public enum FocusPin { Auto, Focus, Ignore }

public static class FocusPins
{
    public static IReadOnlyList<FocusPin> All { get; } = [FocusPin.Auto, FocusPin.Focus, FocusPin.Ignore];

    public static string Title(FocusPin pin) => pin switch { FocusPin.Focus => "Focus", FocusPin.Ignore => "Ignore", _ => "Auto" };

    public static string Help(FocusPin pin) => pin switch
    {
        FocusPin.Focus => "Always a focus app: doctor watches the apps it needs, never the app itself",
        FocusPin.Ignore => "Never a focus app, even with local changes or recent commits of yours",
        _ => "Inferred: local changes, another branch than the profile's, or a commit of yours in the last 14 days",
    };

    public static FocusPin Parse(string? word) => word?.Trim().ToLowerInvariant() switch
    {
        "focus" => FocusPin.Focus,
        "ignore" => FocusPin.Ignore,
        _ => FocusPin.Auto,
    };

    /// <summary>The CLI words that set this pin: <c>app focus NAME [--auto]</c>, <c>app unfocus NAME</c>.</summary>
    public static string[] Words(FocusPin pin, string app) => pin switch
    {
        FocusPin.Focus => ["app", "focus", app],
        FocusPin.Ignore => ["app", "unfocus", app],
        _ => ["app", "focus", app, "--auto"],
    };
}

/// <summary>One app of <c>app list --json</c> (docs/json-schema.md); the focus fields are null from a CLI older than 0.6.</summary>
public sealed record BenchApp(string Name, bool InAppsTxt, string? Repo, string? Remote, string? Branch, string? PolicyBranch, string? Commit,
    bool Dirty, bool Shallow, string? Version, IReadOnlyList<string> Sites, bool? Focus, FocusPin Pin, IReadOnlyList<string> FocusReasons,
    IReadOnlyList<string> Requires, IReadOnlyList<string> NeededBy, string? Upstream, int? Behind, int? BehindDays)
{
    public bool IsFocus => Focus == true;

    /// <summary>"focus app: your commit today"; null when not a focus app.</summary>
    public string? FocusSummary => !IsFocus ? null : FocusReasons.Count == 0 ? "focus app" : "focus app: " + string.Join(", ", FocusReasons);

    /// <summary>"needed by exponent_ecr, 30 commits / 12 days behind upstream/develop"; null unless it is a dependency of a focus app.</summary>
    public string? DependencySummary
    {
        get
        {
            if (IsFocus || NeededBy.Count == 0) return null;
            var who = "needed by " + string.Join(", ", NeededBy);
            if (Behind is not { } behind || behind <= 0) return who;
            var words = $"{behind} commit{(behind == 1 ? "" : "s")}";
            if (BehindDays is { } days && days > 0) words += $" / {days} day{(days == 1 ? "" : "s")}";
            return $"{who}, {words} behind {Upstream ?? "its remote"}";
        }
    }

    /// <summary>A dependency of a focus app that is behind its remote: doctor warns.</summary>
    public bool IsStaleDependency => !IsFocus && NeededBy.Count > 0 && (Behind ?? 0) > 0;

    /// <summary>Why Update is off, or null when it can run. A dirty app is never updated: the fast forward would stop on its changes.</summary>
    public string? UpdateBlocker =>
        Dirty ? $"{Name} has local changes. Commit or stash them first; BenchBar never updates over them."
        : Branch is null ? $"{Name} is on a detached HEAD. Check out a branch first."
        : null;

    /// <summary>The line under the name: "branch version-15  ·  https://github.com/frappe/erpnext".</summary>
    public string SourceLine => string.Join("  ·  ", new[] { Branch is null ? "detached" : "branch " + Branch, Repo }.OfType<string>());
}

public sealed record BenchAppList(IReadOnlyList<BenchApp> Apps, DateTimeOffset? SitesCheckedAt, string? SitesError, string? FetchedAt = null)
{
    /// <summary>False when bench was never asked which sites have each app: the rows then say nothing about sites.</summary>
    public bool SitesKnown => SitesCheckedAt is not null;

    /// <summary>Only Frappe is there: the empty state of the page.</summary>
    public bool OnlyFrappe => Apps.All(a => a.Name == "frappe");
}

/// <summary>The commit list and steps of <c>app update NAME --dry-run --json</c>.</summary>
public sealed record AppUpdatePlan(string App, string? Branch, string? From, string? To, IReadOnlyList<AppCommit> Commits, int CommitsTotal,
    int NewerCommits, bool HasPending, IReadOnlyList<string> Sites, bool SkipBackup, IReadOnlyList<AppUpdateStep> Steps)
{
    public bool IsUpToDate => (From is not null && From == To) || Steps.Count == 0;
}

public sealed record AppCommit(string Sha, string Subject);

public sealed record AppUpdateStep(string Name, string? Command, string? Kind, string? Target);

public static class AppJson
{
    public static BenchAppList ParseList(JsonObject o)
    {
        if (o["apps"] is not JsonArray array) throw new FormatException("The document has no apps list.");
        DateTimeOffset? checkedAt = DateTimeOffset.TryParse(JsonRead.Str(o, "sites_checked_at"), System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.AssumeUniversal, out var t) ? t : null;
        return new BenchAppList(array.OfType<JsonObject>().Select(ParseApp).ToList(), checkedAt, JsonRead.Str(o, "sites_error"), JsonRead.Str(o, "fetched_at"));
    }

    public static BenchApp ParseApp(JsonObject o)
    {
        var name = JsonRead.Str(o, "name");
        if (string.IsNullOrEmpty(name)) throw new FormatException("An app has no name.");
        return new BenchApp(name, !o.ContainsKey("in_apps_txt") || JsonRead.Bool(o, "in_apps_txt"), JsonRead.Str(o, "repo"), JsonRead.Str(o, "remote"),
            JsonRead.Str(o, "branch"), JsonRead.Str(o, "policy_branch"), JsonRead.Str(o, "commit"), JsonRead.Bool(o, "dirty"), JsonRead.Bool(o, "shallow"),
            JsonRead.Str(o, "version"), JsonRead.Strings(o, "sites"), o["focus"] is JsonValue f && f.TryGetValue<bool>(out var focus) ? focus : null,
            FocusPins.Parse(JsonRead.Str(o, "focus_pin")), JsonRead.Strings(o, "focus_reasons"), JsonRead.Strings(o, "requires"),
            JsonRead.Strings(o, "needed_by"), JsonRead.Str(o, "upstream"), JsonRead.Int(o, "behind"), JsonRead.Int(o, "behind_days"));
    }

    /// <summary>The document of <c>app focus --fetch --json</c>: the apps with their focus fields, and when benchbar last fetched.</summary>
    public static BenchAppList ParseFocusReport(JsonObject o) => ParseList(o);

    public static AppUpdatePlan ParseUpdatePlan(JsonObject o)
    {
        var app = JsonRead.Str(o, "app");
        if (string.IsNullOrEmpty(app)) throw new FormatException("The update plan names no app.");
        var commits = o["commits"] is JsonArray c
            ? c.OfType<JsonObject>().Select(x => new AppCommit(JsonRead.Str(x, "sha") ?? "", JsonRead.Str(x, "subject") ?? "")).ToList()
            : [];
        var steps = o["steps"] is JsonArray s
            ? s.OfType<JsonObject>().Select(x => new AppUpdateStep(JsonRead.Str(x, "name") ?? JsonRead.Str(x, "kind") ?? "", JsonRead.Str(x, "command"),
                JsonRead.Str(x, "kind"), JsonRead.Str(x, "target"))).ToList()
            : [];
        return new AppUpdatePlan(app, JsonRead.Str(o, "branch"), JsonRead.Str(o, "from"), JsonRead.Str(o, "to"), commits,
            JsonRead.Int(o, "commits_total") ?? commits.Count, JsonRead.Int(o, "newer_commits") ?? 0, o["pending"] is JsonObject,
            JsonRead.Strings(o, "sites"), JsonRead.Bool(o, "skip_backup"), steps);
    }
}

/// <summary>What Add App collects: where the app comes from, the branch or a pinned commit, and the sites to install it on.</summary>
public sealed record AppAddInput(string Source, string Branch = "", string Commit = "", IReadOnlyList<string>? InstallOn = null)
{
    private static readonly Regex CommitShape = new("^[0-9a-fA-F]{7,40}$", RegexOptions.CultureInvariant);

    public string TrimmedSource => Source.Trim();

    public string? Problem =>
        TrimmedSource.Length == 0 ? "Enter an app name or a git URL."
        : TrimmedSource.StartsWith('-') ? "The app name or URL cannot start with a dash."
        : TrimmedSource.Any(char.IsWhiteSpace) ? "The app name or URL has no spaces."
        : Branch.Trim().StartsWith('-') ? "A branch cannot start with a dash."
        : Branch.Trim().Any(char.IsWhiteSpace) ? "A branch has no spaces."
        : Commit.Trim().Length > 0 && !CommitShape.IsMatch(Commit.Trim()) ? "A commit is 7 to 40 hex characters."
        : null;

    public bool CanReview => Problem is null;

    /// <summary>The name the sheet title uses: the last part of a URL without <c>.git</c>, else the name.</summary>
    public string DisplayName => AppSource.DisplayName(TrimmedSource);
}

public static class AppSource
{
    public static bool IsUrl(string source)
    {
        var s = source.Trim();
        return s.Contains("://", StringComparison.Ordinal) || s.StartsWith("git@", StringComparison.Ordinal);
    }

    public static string DisplayName(string source)
    {
        var s = source.Trim().TrimEnd('/');
        if (!IsUrl(s)) return s;
        var tail = s[(s.LastIndexOfAny(['/', ':']) + 1)..];
        return tail.EndsWith(".git", StringComparison.OrdinalIgnoreCase) ? tail[..^4] : tail;
    }
}

/// <summary>The exact CLI arguments of every Apps action. The bench folder always goes last as <c>--bench-dir</c>.</summary>
public static class AppCommands
{
    /// <summary>The list from the cached site lists; no MariaDB is needed.</summary>
    public static string[] List(string bench) => ["app", "list", "--json", "--no-sites", "--bench-dir", bench];

    /// <summary>Refresh: bench is asked which sites have which app (needs MariaDB, up to 15 seconds per site).</summary>
    public static string[] ListLive(string bench) => ["app", "list", "--json", "--bench-dir", bench];

    public static string[] CheckRemotes(string bench) => ["app", "focus", "--fetch", "--json", "--bench-dir", bench];

    /// <summary>The base of the add plan; the plan sheet appends <c>--dry-run --json</c>, then <c>--apply TOKEN --yes --jsonl</c>.</summary>
    public static string[] Add(AppAddInput input, string bench)
    {
        var args = new List<string> { "app", "add", input.TrimmedSource };
        if (input.Branch.Trim().Length > 0) args.AddRange(["--branch", input.Branch.Trim()]);
        if (input.Commit.Trim().Length > 0) args.AddRange(["--commit", input.Commit.Trim()]);
        if (input.InstallOn is { Count: > 0 } sites) args.AddRange(["--install-on", string.Join(',', sites)]);
        args.AddRange(["--bench-dir", bench]);
        return [.. args];
    }

    public static string[] Install(string app, string site, string bench) => ["app", "install", app, "--site", site, "--yes", "--plain", "--bench-dir", bench];

    public static string[] UpdatePlan(string app, string bench) => ["app", "update", app, "--dry-run", "--json", "--bench-dir", bench];

    public static string[] Update(string app, string bench) => ["app", "update", app, "--yes", "--jsonl", "--bench-dir", bench];

    public static string[] SetFocus(string app, FocusPin pin, string bench) => [.. FocusPins.Words(pin, app), "--json", "--bench-dir", bench];
}

/// <summary>Which sites an app can still be installed on.</summary>
public static class AppSites
{
    /// <summary>The sites without the app. Empty for Frappe (it is on every site) and when bench was never asked which sites have the app.</summary>
    public static IReadOnlyList<string> Missing(BenchApp app, IEnumerable<string> siteNames, bool sitesKnown) =>
        app.Name == "frappe" || !sitesKnown ? [] : siteNames.Where(s => !app.Sites.Contains(s)).ToList();
}
