namespace BenchBar.Tray.Core;

/// <summary>A user kept in the Quick Switch panel for one site (macos PinnedUser). <see cref="FullName"/> is kept so a pin without a label still reads as a person.</summary>
public sealed record PinnedUser(string User, string? Label, string? FullName);

/// <summary>
/// The pinned users of every site, by "bench|site" (macos OpenAsStore). Held as one immutable map that is replaced whole, so the thread that
/// saves the config never sees a half changed list. <see cref="Changed"/> asks the app to save.
/// </summary>
public sealed class OpenAsPins(IReadOnlyDictionary<string, IReadOnlyList<PinnedUser>>? initial = null)
{
    public const int Max = 9;
    public const string Administrator = "Administrator";

    private IReadOnlyDictionary<string, IReadOnlyList<PinnedUser>> _map = initial ?? new Dictionary<string, IReadOnlyList<PinnedUser>>();

    public event Action? Changed;

    public IReadOnlyDictionary<string, IReadOnlyList<PinnedUser>> Map => _map;

    public static string Key(string bench, string site) => bench + "|" + site;

    public IReadOnlyList<PinnedUser> Of(string bench, string site) => _map.GetValueOrDefault(Key(bench, site)) ?? [];

    public bool IsPinned(string user, string bench, string site) => Of(bench, site).Any(p => p.User == user);

    /// <summary>False when the site already has nine pins, or for Administrator, who is always in the panel.</summary>
    public bool Pin(string user, string? fullName, string bench, string site)
    {
        var list = Of(bench, site);
        if (list.Any(p => p.User == user)) return true;
        if (user == Administrator || list.Count >= Max) return false;
        Set(bench, site, [.. list, new PinnedUser(user, null, fullName)]);
        return true;
    }

    public void Unpin(string user, string bench, string site) => Set(bench, site, [.. Of(bench, site).Where(p => p.User != user)]);

    public void SetLabel(string user, string label, string bench, string site) =>
        Set(bench, site, [.. Of(bench, site).Select(p => p.User == user ? p with { Label = string.IsNullOrWhiteSpace(label) ? null : label.Trim() } : p)]);

    /// <summary>The pin's label, else the user's full name, else the name the pin kept, else the user id.</summary>
    public static string Label(string user, string? fullName, IReadOnlyList<PinnedUser> pins)
    {
        var pin = pins.FirstOrDefault(p => p.User == user);
        foreach (var candidate in new[] { pin?.Label, fullName, pin?.FullName })
            if (!string.IsNullOrWhiteSpace(candidate)) return candidate.Trim();
        return user;
    }

    private void Set(string bench, string site, List<PinnedUser> list)
    {
        var copy = new Dictionary<string, IReadOnlyList<PinnedUser>>(_map);
        if (list.Count == 0) copy.Remove(Key(bench, site));
        else copy[Key(bench, site)] = list;
        _map = copy;
        Changed?.Invoke();
    }
}

/// <summary>A site the panel can open: one that is on a running bench with Open as usable.</summary>
public sealed record QuickSwitchTarget(string Bench, string BenchName, string Site)
{
    public string Key => OpenAsPins.Key(Bench, Site);

    public string Title => $"{Site} on {BenchName}";
}

public static class QuickSwitchTargets
{
    /// <summary>Every site of a running bench that Open as can sign in to now (the same rule as the Sites tab), default sites first.</summary>
    public static IReadOnlyList<QuickSwitchTarget> From(IEnumerable<BenchStatus> benches) =>
    [
        .. benches.SelectMany(b => SiteRows.From(b)
            .Where(r => OpenAsRules.For(r, b.State == BenchState.Running, b.Name).State == OpenAsRules.Availability.Available)
            .Select(r => (Target: new QuickSwitchTarget(b.Path, b.Name, r.Name), r.IsDefault)))
            .OrderByDescending(t => t.IsDefault).Select(t => t.Target),
    ];

    /// <summary>Why there is nothing to open, with its fix (macos Blocker). Null when there is a target.</summary>
    public static string? Blocker(IReadOnlyList<BenchStatus> benches, IReadOnlyList<QuickSwitchTarget> targets)
    {
        if (targets.Count > 0) return null;
        if (benches.Count == 0) return "No bench to open as a user on. Add one in BenchBar.";
        var running = benches.Where(b => b.State == BenchState.Running).ToList();
        if (running.Count == 0) return "No bench is running. Start one first.";
        foreach (var bench in running)
        {
            var rows = SiteRows.From(bench);
            if (rows.FirstOrDefault(r => r.IsDefault) is not { } site) return $"{bench.Name} has no default site. Make one the default in its Sites tab.";
            // a site that Windows cannot find and a CLI that sends no Open as fields have no Allow Open as in the Sites tab: not "turn it on"
            if (site.NeedsSetUp) return $"Set up {site.Name} in the BenchBar window: Windows cannot find that name.";
            if (site.OpenAs is null) return OpenAsRules.UpdateCli + ".";
            if (site.OpenAs is not { Enabled: true }) return $"Open as is off for {site.Name}. Turn it on with Allow Open as... in its Sites tab.";
            var (state, why) = OpenAsRules.For(site, true, bench.Name);
            if (state == OpenAsRules.Availability.Disabled && why is not null) return why;
        }
        return "Open as is not usable on any running bench.";
    }
}

public enum QuickSwitchKind { Administrator, Pin, Other }

/// <summary>One line of the panel. <see cref="Digit"/> switches at once while the field is empty: 0 Administrator, 1 to 9 the pins.</summary>
public sealed record QuickSwitchRow(QuickSwitchKind Kind, string User, string? FullName, string Title, string? Detail, bool IsCurrent, int? Digit)
{
    public string Hint => IsCurrent ? "last opened" : "";

    /// <summary>What a screen reader says: the title, the user id under it and the state.</summary>
    public string Spoken => string.Join(", ", new[] { Title, Detail, Hint.Length > 0 ? Hint : null }.Where(s => !string.IsNullOrEmpty(s)));
}

/// <summary>
/// What the Quick Switch panel decides (macos QuickSwitchModel), as plain values: the rows (Administrator, the pins, then the matches of a
/// search of the site's users), the filter, the selection and the keys. The window only draws this and reports keys. Nothing here opens
/// anything: <see cref="Confirm"/> names the row, and the window runs the one call.
/// </summary>
public sealed class QuickSwitchModel(QuickSwitchTarget target, IReadOnlyList<PinnedUser> pins, string? lastUser)
{
    public const int MinSearchLength = 2;
    public const int SearchLimit = 8;

    private IReadOnlyList<SiteUser> _remote = [];

    public QuickSwitchTarget Target { get; } = target;

    public string Query { get; private set; } = "";

    public int Selection { get; private set; }

    /// <summary>True when a search of the site's users is worth asking for: two characters or more.</summary>
    public bool WantsSearch => Query.Trim().Length >= MinSearchLength;

    public void SetQuery(string text)
    {
        Query = text;
        if (!WantsSearch) _remote = [];
        Selection = 0;
    }

    public void SetRemote(IReadOnlyList<SiteUser> users)
    {
        _remote = users;
        Selection = Math.Clamp(Selection, 0, Math.Max(0, Rows.Count - 1));
    }

    public IReadOnlyList<QuickSwitchRow> Rows
    {
        get
        {
            var rows = new List<QuickSwitchRow> { Row(QuickSwitchKind.Administrator, OpenAsPins.Administrator, null, 0) };
            var digit = 0;
            foreach (var pin in pins) rows.Add(Row(QuickSwitchKind.Pin, pin.User, pin.FullName, ++digit));
            var typed = Query.Trim();
            if (typed.Length > 0)
                rows = [.. rows.Where(r => Matches(r, typed))];
            foreach (var user in _remote.Where(u => rows.All(r => r.User != u.Name)))
                rows.Add(Row(QuickSwitchKind.Other, user.Name, user.FullName, null));
            return rows;
        }
    }

    private QuickSwitchRow Row(QuickSwitchKind kind, string user, string? fullName, int? digit)
    {
        var title = OpenAsPins.Label(user, fullName, pins);
        return new QuickSwitchRow(kind, user, fullName, title, title == user ? null : user, user == lastUser, digit);
    }

    private static bool Matches(QuickSwitchRow row, string typed) =>
        new[] { row.Title, row.User, row.FullName ?? "" }.Any(s => s.Contains(typed, StringComparison.OrdinalIgnoreCase));

    public void Move(int delta)
    {
        var count = Rows.Count;
        Selection = count == 0 ? 0 : (Selection + delta % count + count) % count;
    }

    /// <summary>The row Enter opens, or null when nothing matches.</summary>
    public QuickSwitchRow? Confirm() => Rows.Count == 0 ? null : Rows[Math.Clamp(Selection, 0, Rows.Count - 1)];

    /// <summary>The row a digit key opens, only while the field is empty (typing a digit searches).</summary>
    public QuickSwitchRow? ByDigit(int digit) => Query.Length == 0 ? Rows.FirstOrDefault(r => r.Digit == digit) : null;
}
