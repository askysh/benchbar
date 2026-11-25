using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>
/// What <c>status --json</c> says about Open as for one site: <see cref="Enabled"/> is the person's opt-in (<c>open_as_enabled</c>),
/// <see cref="DeveloperMode"/> the site's <c>developer_mode</c> and <see cref="Usable"/> the CLI's own verdict (<c>open_as</c>: opted in,
/// developer mode on and the site the web process answers as). A null here means the CLI is older than 0.8.1 and does not say.
/// </summary>
public sealed record SiteOpenAs(bool Enabled, bool? DeveloperMode, bool? Usable);

/// <summary>One enabled user of a site, from <c>users --json</c>, with the roles that set the user apart first.</summary>
public sealed record SiteUser(string Name, string FullName, string UserType, IReadOnlyList<string> Roles, int RoleCount)
{
    public string Title => FullName.Length > 0 ? FullName : Name;

    /// <summary>"Sales User, Accounts User +2 more"; empty without roles.</summary>
    public string RolesLine => Roles.Count == 0 ? "" : RoleCount > Roles.Count ? UiText.Format("OpenAsRolesMore", string.Join(", ", Roles), RoleCount - Roles.Count) : string.Join(", ", Roles);
}

public sealed record SiteUserList(string Site, IReadOnlyList<SiteUser> Users, bool Truncated);

/// <summary>The words and rules of Open as (macos OpenAsMenuModel), with Windows' own: only a name Windows resolves can be signed in to.</summary>
public static class OpenAsRules
{
    public const int Limit = 50;

    /// <summary>What the question says before Open as is turned on. The CLI says the same before it asks in a terminal.</summary>
    public static string AllowMessage => UiText.Get("OpenAsAllowMessage");

    /// <summary>What an opted in site says when the CLI sends no developer mode field (older than 0.8.1).</summary>
    public static string UpdateCli => UiText.Get("OpenAsUpdateCli");

    public enum Availability { Hidden, Available, Disabled }

    /// <summary>
    /// Whether the controls show, and when they are shown but cannot be used, why. Not opted in, a name Windows cannot find, an older CLI,
    /// or an opted in site that cannot be used and is not the default: hidden.
    /// </summary>
    public static (Availability State, string? Why) For(SiteRowInfo row, bool benchRunning, string benchName)
    {
        if (row.OpenAs is not { Enabled: true } || row.NeedsSetUp) return (Availability.Hidden, null);
        if (row.OpenAs.Usable == true) return benchRunning ? (Availability.Available, null) : (Availability.Disabled, UiText.Format("OpenAsStartFirst", benchName));
        if (!row.IsDefault) return (Availability.Hidden, null);
        return (Availability.Disabled, Reasons(row).FirstOrDefault() ?? UiText.Format("OpenAsNotUsableNow", row.Name));
    }

    /// <summary>Why an opted in site cannot be used, in the order to fix them.</summary>
    public static IReadOnlyList<string> Reasons(SiteRowInfo row)
    {
        if (row.OpenAs is not { Enabled: true } state || state.Usable == true) return [];
        var reasons = new List<string>();
        if (state.DeveloperMode is null) reasons.Add(UpdateCli);
        else if (state.DeveloperMode == false) reasons.Add(UiText.Format("OpenAsNoDevMode", row.Name));
        if (!row.IsDefault) reasons.Add(UiText.Get("OpenAsOnlyDefault"));
        else if (state.DeveloperMode == true) reasons.Add(UiText.Format("OpenAsOtherSite", row.Name));
        return reasons;
    }

    /// <summary>The line under a site's name while Open as is on; null while it is off.</summary>
    public static (string Text, bool Warning)? StatusLine(SiteRowInfo row)
    {
        if (row.OpenAs is not { Enabled: true } || row.NeedsSetUp) return null;
        var why = Reasons(row);
        return why.Count == 0 ? (UiText.Get("OpenAsIsOn"), false) : (UiText.Format("OpenAsIsOnNotUsable", string.Join(' ', why)), true);
    }

    public static string AllowTitle(string site) => UiText.Format("OpenAsAllowTitle", site);

    public static string TurnedOn(string site) => UiText.Format("OpenAsTurnedOn", site);

    public static string TurnedOff(string site) => UiText.Format("OpenAsTurnedOff", site);

    public static string Opened(string site, SiteUser user) => UiText.Format("OpenAsOpened", site, user.Title);

    /// <summary>
    /// The CLI's sentence from what it wrote to stderr. <c>open</c> and <c>users</c> are not in the JSON modes, so a refusal prints nothing on
    /// stdout and one <c>  [FAIL] message</c> line on stderr: the colour codes and the tag are dropped, the sentence stays as it is worded.
    /// </summary>
    public static string? CliSentence(string? stderr)
    {
        if (stderr is null) return null;
        var text = System.Text.RegularExpressions.Regex.Replace(stderr, @"\x1b\[[0-9;]*m", "").Trim();
        if (text.StartsWith("[FAIL]", StringComparison.Ordinal)) text = text["[FAIL]".Length..].Trim();
        return text.Length == 0 ? null : text;
    }
}

public static class OpenAsCommands
{
    /// <summary>
    /// The calls a person makes that the CLI refuses without a terminal (<c>site open-as on</c>, <c>open --as</c>): the click or Enter was
    /// the person's decision, as the Mac's alert is. Never set for anything a poll, a link, an agent or a read such as <c>users</c> runs.
    /// </summary>
    public static SecretEnvironment PersonEnvironment() => new SecretEnvironment().Set(SetupEnv.NonInteractive, "0").Set(SetupEnv.Sudo, "gui");

    /// <summary><c>site open-as on|off SITE --yes --json</c>. <c>--yes</c> skips the CLI's question, which the tray asked before.</summary>
    public static string[] Set(string site, bool on, string bench) => ["site", "open-as", on ? "on" : "off", site, "--yes", "--json", "--bench-dir", bench];

    public static string[] Users(string site, string? search, string bench, int limit = OpenAsRules.Limit) =>
        ["users", "--site", site, .. string.IsNullOrWhiteSpace(search) ? [] : new[] { "--search", search.Trim() },
            "--limit", limit.ToString(System.Globalization.CultureInfo.InvariantCulture), "--json", "--bench-dir", bench];

    /// <summary>
    /// <c>open --site SITE --as USER --json</c>: the CLI makes the session and opens the browser itself, so the sign in link never reaches
    /// the tray. There is no <c>--print-url</c> here and there never is: the link holds a session id, which is a credential.
    /// </summary>
    public static string[] OpenAs(string site, string user, string bench) => ["open", "--site", site, "--as", user, "--json", "--bench-dir", bench];
}

public static class OpenAsJson
{
    /// <summary>The <c>opened</c> of <c>open --as --json</c>: the CLI opened the browser. The document never holds the sign in link.</summary>
    public static bool Opened(JsonObject o) => JsonRead.Bool(o, "opened");

    public static SiteUserList ParseUsers(JsonObject o)
    {
        if (o["users"] is not JsonArray array) throw new FormatException("The document has no users list.");
        var users = array.OfType<JsonObject>().Where(u => JsonRead.Str(u, "name") is { Length: > 0 }).Select(u => new SiteUser(JsonRead.Str(u, "name")!,
            JsonRead.Str(u, "full_name") ?? "", JsonRead.Str(u, "user_type") ?? "System User", JsonRead.Strings(u, "roles"), JsonRead.Int(u, "role_count") ?? 0)).ToList();
        return new SiteUserList(JsonRead.Str(o, "site") ?? "", users, JsonRead.Bool(o, "truncated"));
    }
}

/// <summary>Find User for one site: the users the CLI lists, searched on demand, and Open as one of them.</summary>
public sealed class FindUserModel(ICliClient cli, string bench, string site)
{
    public string Site { get; } = site;

    public SiteUserList? List { get; private set; }

    /// <summary>The CLI's sentence when the list could not be read (Open as off, the bench stopped, an older CLI).</summary>
    public string? Error { get; private set; }

    /// <summary>The last user opened and what came of it; the page shows it under the list.</summary>
    public string? Note { get; private set; }

    public bool NoteIsError { get; private set; }

    public async Task SearchAsync(string? query, CancellationToken ct = default)
    {
        var result = await cli.RunJsonAsync(OpenAsCommands.Users(Site, query, bench), null, CliTimeouts.Read, OpenAsJson.ParseUsers, ct).ConfigureAwait(true);
        List = result.Value ?? List;
        Error = result.Value is null ? OpenAsRules.CliSentence(result.Error) ?? UiText.Get("OpenAsUsersFailed") : null;
    }

    /// <summary>Opens the site in the browser signed in as <paramref name="user"/>. The answer is the CLI's: <c>opened</c> true, or its refusal as it words it.</summary>
    public async Task<bool> OpenAsync(SiteUser user, CancellationToken ct = default)
    {
        var result = await cli.RunJsonAsync(OpenAsCommands.OpenAs(Site, user.Name, bench), OpenAsCommands.PersonEnvironment(), CliTimeouts.Plan, OpenAsJson.Opened, ct).ConfigureAwait(true);
        var ok = result.Ok && result.Value;
        NoteIsError = !ok;
        Note = ok ? OpenAsRules.Opened(Site, user) : OpenAsRules.CliSentence(result.Error) ?? UiText.Format("QuickSwitchCouldNotOpen", Site, user.Title);
        return ok;
    }
}
