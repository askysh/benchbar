using System.Security.Cryptography;
using System.Text;

namespace BenchBar.Tray.Core;

/// <summary>The routes a <c>benchbar://</c> link can ask for: launches and start, stop, restart (macos URLRouter.Route).</summary>
public enum LinkRoute { Up, Down, Restart, Open, Logs, Window, Doctor, Console, Db, Editor }

/// <summary>The bench fields the router needs, from the last poll.</summary>
public sealed record LinkBench(string Path, string Name, IReadOnlyList<string> Sites);

/// <summary>
/// Why a link was explained instead of acted on. <see cref="LinkRouter.LogText"/> is fixed: no bench name, site, path or
/// address the link carried reaches the log.
/// </summary>
public enum LinkWhy
{
    ProfileNeedsHttps, SubscribeNeedsGit, NoBench, NeedsBench, BenchNotFound, BenchAmbiguous, SiteNotFound, ShareNotOnWindows,
}

public enum ProfileLinkKind { Import, Subscribe }

/// <summary>What the app should do with one link.</summary>
public abstract record LinkOutcome
{
    /// <summary>Run the route on this bench (its Linux path); <see cref="Site"/> only for open, console and db.</summary>
    public sealed record Run(LinkRoute Route, string BenchPath, string? Site) : LinkOutcome;

    /// <summary>The BenchBar window, with no bench in particular.</summary>
    public sealed record Window : LinkOutcome;

    /// <summary>The window, with a note for the person. The note may name what they asked for; the log never does.</summary>
    public sealed record Explain(string Message, LinkWhy Why) : LinkOutcome;

    /// <summary>Not a link for us, or a route we do not have: log it, do nothing. The text is a fixed sentence.</summary>
    public sealed record Ignore(string Reason) : LinkOutcome;

    /// <summary>Team Profiles with the import or subscribe sheet filled in. The sheet waits for the click; the link fetches nothing.</summary>
    public sealed record Profile(ProfileLinkKind Kind, string Address) : LinkOutcome;
}

/// <summary>
/// <c>benchbar://</c> links, as on the Mac (macos URLRouter): pure, a link and the bench list in, one outcome out, so the rules are
/// tested without the app. Any web page can open such a link, so only launches and start, stop and restart are routes, plus two
/// profile links that only fill in a sheet. Nothing here repairs, drops, restores, pulls, installs or deletes; a route that is not
/// in <see cref="LinkRoute"/> is ignored. Share links are known and answered with a note: rooms are not on Windows yet.
/// </summary>
public static class LinkRouter
{
    public const string Scheme = "benchbar";

    /// <summary>No link is longer than this; a longer one is ignored (and never read to the end).</summary>
    public const int MaxLength = 2048;

    private static readonly Dictionary<string, LinkRoute> Routes = new(StringComparer.Ordinal)
    {
        ["up"] = LinkRoute.Up,
        ["down"] = LinkRoute.Down,
        ["restart"] = LinkRoute.Restart,
        ["open"] = LinkRoute.Open,
        ["logs"] = LinkRoute.Logs,
        ["window"] = LinkRoute.Window,
        ["doctor"] = LinkRoute.Doctor,
        ["console"] = LinkRoute.Console,
        ["db"] = LinkRoute.Db,
        ["editor"] = LinkRoute.Editor,
    };

    /// <summary>The routes <c>site=</c> applies to.</summary>
    public static bool TakesSite(LinkRoute route) => route is LinkRoute.Open or LinkRoute.Console or LinkRoute.Db;

    // --- the arguments of the tray's own start ---

    /// <summary>
    /// The link in the tray's start arguments: the first argument that starts with <c>benchbar:</c>, else null. The registry command
    /// passes the link as one quoted argument; anything else on the command line is not a link, and a link past
    /// <see cref="MaxLength"/> is never passed on.
    /// </summary>
    public static string? FromArguments(IEnumerable<string> args)
    {
        foreach (var arg in args)
        {
            if (arg.Length > MaxLength) continue;
            if (arg.StartsWith(Scheme + ":", StringComparison.OrdinalIgnoreCase)) return arg;
        }
        return null;
    }

    /// <summary>
    /// The arguments the tray reads its own flags from (<c>--resume-setup</c>, <c>--installed</c>, <c>--restarted</c>). When the first
    /// argument is a link, the start came from the scheme's registry command, and everything after it is the link's own text split by
    /// the command line, never the tray's flags: none.
    /// </summary>
    public static IReadOnlyList<string> OwnArguments(IReadOnlyList<string> args) =>
        args.Count > 0 && args[0].StartsWith(Scheme + ":", StringComparison.OrdinalIgnoreCase) ? [] : args;

    /// <summary>
    /// Characters a link may not hold. The registry command is <c>"BenchBarTray.exe" "%1"</c>: a <c>"</c> ends the quoted link and what
    /// follows becomes arguments of the tray, a <c>\</c> before the closing quote can swallow it, and the rest are what a command line
    /// or shell treats specially. A real link percent encodes all of these. (<c>&amp;</c> stays: it separates query pairs, and no
    /// launch goes through a shell.)
    /// </summary>
    private static bool HasCommandLineCharacter(string text) => text.IndexOfAny(['"', '\\', '^', '|', '<', '>', '`']) >= 0;

    /// <summary>The longest piece of a link's own text a note repeats back.</summary>
    private const int NoteLength = 40;

    private static string Short(string text)
    {
        if (text.Length <= NoteLength) return text;
        var cut = char.IsHighSurrogate(text[NoteLength - 1]) ? NoteLength - 1 : NoteLength; // never half of an emoji
        return text[..cut] + "...";
    }

    // --- parse ---

    private sealed record Parts(string[] Words, IReadOnlyList<(string Name, string Value)> Query);

    private static bool TryParts(string link, out Parts parts)
    {
        parts = new Parts([], []);
        var text = link.Trim();
        if (text.Length == 0 || text.Length > MaxLength || text.Any(c => char.IsControl(c) || char.IsWhiteSpace(c)) || HasCommandLineCharacter(text)) return false;
        if (!text.StartsWith(Scheme + ":", StringComparison.OrdinalIgnoreCase)) return false;
        var rest = text[(Scheme.Length + 1)..];
        var hash = rest.IndexOf('#');
        if (hash >= 0) rest = rest[..hash];
        var mark = rest.IndexOf('?');
        var path = mark >= 0 ? rest[..mark] : rest;
        var queryText = mark >= 0 ? rest[(mark + 1)..] : "";
        // benchbar://up and benchbar:up both mean the route "up": the words are what is left of the slashes
        var words = path.Split('/', StringSplitOptions.RemoveEmptyEntries).Select(w => Unescape(w).Trim().ToLowerInvariant()).ToArray();
        var query = new List<(string, string)>();
        foreach (var pair in queryText.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = pair.IndexOf('=');
            var name = Unescape(eq >= 0 ? pair[..eq] : pair).ToLowerInvariant();
            var value = eq >= 0 ? Unescape(pair[(eq + 1)..]) : "";
            query.Add((name, value));
        }
        parts = new Parts(words, query);
        return true;
    }

    private static string Unescape(string text)
    {
        try { return Uri.UnescapeDataString(text); }
        catch (UriFormatException) { return text; }
    }

    private static string? Value(Parts parts, string key)
    {
        var found = parts.Query.LastOrDefault(q => q.Name == key);
        var text = found.Value?.Trim();
        return string.IsNullOrEmpty(text) ? null : text;
    }

    // --- the decision ---

    /// <summary>
    /// The whole decision: parse, then pick the bench. <paramref name="selected"/> is the bench path the BenchBar window has selected, if any.
    /// </summary>
    public static LinkOutcome Route(string link, IReadOnlyList<LinkBench> benches, string? selected)
    {
        if (!TryParts(link, out var parts)) return new LinkOutcome.Ignore(LinkIgnore.NotOurScheme);
        var first = parts.Words.Length > 0 ? parts.Words[0] : "";
        if (first == "share")
            return new LinkOutcome.Explain(UiText.Get("CommonLinkRooms"), LinkWhy.ShareNotOnWindows);
        if (first == "profile") return ProfileRoute(parts);
        if (first.Length == 0) return new LinkOutcome.Ignore(LinkIgnore.NoRoute);
        if (!Routes.TryGetValue(first, out var route)) return new LinkOutcome.Ignore(LinkIgnore.UnknownRoute);
        return Resolve(route, Value(parts, "bench"), Value(parts, "site"), benches, selected);
    }

    private static LinkOutcome ProfileRoute(Parts parts)
    {
        var action = parts.Words.Length > 1 ? parts.Words[1] : "";
        if (parts.Words.Length != 2 || action is not ("import" or "subscribe")) return new LinkOutcome.Ignore(LinkIgnore.UnknownRoute);
        var address = Value(parts, "url") ?? "";
        if (action == "import")
        {
            return ProfileSourceRule.IsImportUrl(address)
                ? new LinkOutcome.Profile(ProfileLinkKind.Import, address)
                : new LinkOutcome.Explain(UiText.Get("CommonLinkProfileUrl"), LinkWhy.ProfileNeedsHttps);
        }
        return ProfileSourceRule.IsGitUrl(address)
            ? new LinkOutcome.Profile(ProfileLinkKind.Subscribe, address)
            : new LinkOutcome.Explain(UiText.Get("CommonLinkSubscribeUrl"), LinkWhy.SubscribeNeedsGit);
    }

    private static LinkOutcome Resolve(LinkRoute route, string? benchQuery, string? siteQuery, IReadOnlyList<LinkBench> benches, string? selected)
    {
        LinkBench bench;
        switch (Pick(benchQuery, benches, selected))
        {
            case Picked { Bench: { } found }:
                bench = found;
                break;
            case NoPick when route == LinkRoute.Window:
                return new LinkOutcome.Window();
            case NoPick:
                return benches.Count == 0
                    ? new LinkOutcome.Explain(UiText.Get("CommonLinkNoBench"), LinkWhy.NoBench)
                    : new LinkOutcome.Explain(UiText.Get("CommonLinkNeedsBench"), LinkWhy.NeedsBench);
            case NotFound nf:
                return new LinkOutcome.Explain(UiText.Format("CommonLinkBenchNotFound", Short(nf.Query)), LinkWhy.BenchNotFound);
            case Ambiguous am:
                return new LinkOutcome.Explain(UiText.Format("CommonLinkAmbiguous", Short(am.Query)), LinkWhy.BenchAmbiguous);
            default:
                return new LinkOutcome.Ignore(LinkIgnore.UnknownRoute);
        }

        string? site = null;
        if (TakesSite(route) && siteQuery is { } wanted)
        {
            site = bench.Sites.FirstOrDefault(s => string.Equals(s, wanted, StringComparison.OrdinalIgnoreCase));
            if (site is null) return new LinkOutcome.Explain(UiText.Format("CommonLinkNoSite", bench.Name, Short(wanted)), LinkWhy.SiteNotFound);
        }
        return new LinkOutcome.Run(route, bench.Path, site);
    }

    private abstract record Choice;

    private sealed record Picked(LinkBench Bench) : Choice;

    private sealed record NoPick : Choice;

    private sealed record NotFound(string Query) : Choice;

    private sealed record Ambiguous(string Query) : Choice;

    /// <summary>
    /// An absolute Linux path (or <c>~/...</c>, which matches a bench under <c>/home/USER/</c> or <c>/root/</c>) matches the path,
    /// anything else the name. Without <c>bench=</c>: the selected bench, else the only one.
    /// </summary>
    private static Choice Pick(string? query, IReadOnlyList<LinkBench> benches, string? selected)
    {
        if (query is null)
        {
            if (selected is not null && benches.FirstOrDefault(b => NormalizePath(b.Path) == NormalizePath(selected)) is { } chosen) return new Picked(chosen);
            return benches.Count == 1 ? new Picked(benches[0]) : new NoPick();
        }
        if (query.StartsWith('/') || query.StartsWith('~'))
        {
            var matches = query.StartsWith('~')
                ? benches.Where(b => UnderHome(NormalizePath(b.Path), NormalizePath(query[1..]))).ToList()
                : benches.Where(b => NormalizePath(b.Path) == NormalizePath(query)).ToList();
            return matches.Count switch { 0 => new NotFound(query), 1 => new Picked(matches[0]), _ => new Ambiguous(query) };
        }
        var named = benches.Where(b => string.Equals(b.Name, query, StringComparison.OrdinalIgnoreCase)).ToList();
        return named.Count switch { 0 => new NotFound(query), 1 => new Picked(named[0]), _ => new Ambiguous(query) };
    }

    /// <summary>The path in the distro's home folder: <c>/home/USER/rest</c> or <c>/root/rest</c> for <c>~/rest</c>.</summary>
    private static bool UnderHome(string path, string rest)
    {
        if (rest.Length == 0) return false;
        if (path.StartsWith("/root", StringComparison.Ordinal) && path[5..] == rest) return true;
        if (!path.StartsWith("/home/", StringComparison.Ordinal)) return false;
        var afterUser = path.IndexOf('/', 6);
        return afterUser > 0 && path[afterUser..] == rest;
    }

    /// <summary>
    /// Collapses repeated slashes, drops a trailing one and resolves <c>.</c> and <c>..</c> (the Mac's <c>standardizedFileURL</c>); a
    /// <c>..</c> at the root stays at the root.
    /// </summary>
    internal static string NormalizePath(string path)
    {
        var kept = new List<string>();
        foreach (var part in path.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            if (part == ".") continue;
            if (part == "..")
            {
                if (kept.Count > 0) kept.RemoveAt(kept.Count - 1);
                continue;
            }
            kept.Add(part);
        }
        return "/" + string.Join('/', kept);
    }

    // --- the log ---

    /// <summary>
    /// What a link is called in the log: the scheme and the action word, never the host, path, query or userinfo (a profile link can
    /// carry a token, a share link a room code). A link that is not one of ours, or has a route we do not have, is only a short
    /// hash, enough to tell two apart and nothing to read back.
    /// </summary>
    public static string LogLabel(string link)
    {
        if (TryParts(link, out var parts) && parts.Words.Length > 0)
        {
            var first = parts.Words[0];
            if (Routes.ContainsKey(first)) return $"{Scheme}://{first}";
            if (first == "share") return $"{Scheme}://share";
            if (first == "profile" && parts.Words.Length > 1 && parts.Words[1] is "import" or "subscribe") return $"{Scheme}://profile/{parts.Words[1]}";
        }
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(link));
        return "other link, hash " + Convert.ToHexString(digest, 0, 6).ToLowerInvariant();
    }

    /// <summary>The fixed sentence for an explained link: no bench, site, path or address.</summary>
    public static string LogText(LinkWhy why) => why switch
    {
        LinkWhy.ProfileNeedsHttps => "profile link refused: no https address",
        LinkWhy.SubscribeNeedsGit => "subscribe link refused: no git address",
        LinkWhy.NoBench => "link refused: no bench is known",
        LinkWhy.NeedsBench => "link refused: it does not say which bench",
        LinkWhy.BenchNotFound => "link refused: no such bench",
        LinkWhy.BenchAmbiguous => "link refused: the bench name is not unique",
        LinkWhy.SiteNotFound => "link refused: no such site",
        _ => "share link: rooms are not on Windows yet",
    };

    /// <summary>
    /// The one log line for a link the tray ignored or explained, from fixed texts and <see cref="LogLabel"/> only. Null for an outcome that
    /// is not logged here.
    /// </summary>
    public static string? RejectionLogLine(string label, LinkOutcome outcome) => outcome switch
    {
        LinkOutcome.Ignore ignore => $"Ignored {label}: {ignore.Reason}",
        LinkOutcome.Explain explain => $"{label}: {LogText(explain.Why)}",
        _ => null,
    };
}

/// <summary>The fixed sentences of an ignored link: they are logged, so they never repeat a part of the link.</summary>
public static class LinkIgnore
{
    public const string NotOurScheme = "not a benchbar:// link";
    public const string UnknownRoute = "unknown route";
    public const string NoRoute = "no route in the link";
}

/// <summary>
/// The optional confirm for a link that starts, stops or restarts a bench or opens a console (Settings, "Ask before a link acts", off by
/// default). Any web page or app can open such a link, and a browser's "always allow" removes its own question, so this is the tray's.
/// Pure: the dialog itself is shown by the app.
/// </summary>
public static class LinkConfirm
{
    /// <summary>The routes that act on a bench. The others only show a window, a log or a page.</summary>
    public static bool NeedsAsking(LinkRoute route, bool setting) =>
        setting && route is LinkRoute.Up or LinkRoute.Down or LinkRoute.Restart or LinkRoute.Console or LinkRoute.Db;

    public sealed record Question(string Title, string Detail, string Button);

    public static Question Ask(LinkRoute route, string bench)
    {
        var (title, button) = route switch
        {
            LinkRoute.Up => (UiText.Format("CommonLinkStartAsk", bench), UiText.Get("CommonStart")),
            LinkRoute.Down => (UiText.Format("CommonLinkStopAsk", bench), UiText.Get("CommonStop")),
            LinkRoute.Restart => (UiText.Format("CommonLinkRestartAsk", bench), UiText.Get("OverviewRestart")),
            LinkRoute.Console => (UiText.Format("CommonLinkConsoleAsk", bench), UiText.Get("CommonOpenTerminal")),
            LinkRoute.Db => (UiText.Format("CommonLinkDbAsk", bench), UiText.Get("CommonOpenTerminal")),
            _ => (UiText.Format("CommonLinkOpenAsk", bench), UiText.Get("CommonOpen")),
        };
        return new Question(title, UiText.Get("CommonLinkAskDetail"), button);
    }
}
