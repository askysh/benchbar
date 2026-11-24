using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>
/// One experiment of <c>labs list --json</c>. The CLI owns the list and the flags, so an experiment this build has never heard of
/// still shows. <see cref="Platforms"/> and <see cref="Available"/> are absent from an older CLI, which then offers every lab everywhere.
/// </summary>
public sealed record LabEntry(string Name, string Title, string Description, string Warning, string Since, bool Enabled,
    IReadOnlyList<string> Commands, IReadOnlyList<string>? Platforms, bool? Available)
{
    /// <summary>The CLI says this experiment does not run on this platform (Linux in WSL counts as Windows).</summary>
    public bool NotHere => Available == false;

    /// <summary>A lab that is off and not available here cannot be turned on; one that is on can always be turned off.</summary>
    public bool CanToggle => !(NotHere && !Enabled);

    /// <summary>Why the lab is not here: "Not on Windows yet. It works on macOS only." Null when it is available.</summary>
    public string? WhyNotHere => NotHere ? LabsText.NotHere(Platforms) : null;
}

public static class LabsText
{
    public static string Footer => UiText.Get("LabsFooter");

    public static string Unsupported => UiText.Get("LabsUnsupported");

    /// <summary>The platform words of the CLI (<c>macos</c>, <c>linux</c>, <c>windows</c>) as people write them.</summary>
    public static string PlatformName(string platform) => platform.Trim().ToLowerInvariant() switch
    {
        "macos" => "macOS",
        "linux" => "Linux",
        "windows" => "Windows",
        var other => other,
    };

    public static string NotHere(IReadOnlyList<string>? platforms)
    {
        var names = (platforms ?? []).Where(p => p.Trim().Length > 0).Select(PlatformName).ToList();
        if (names.Count == 0) return UiText.Get("LabsNotHere");
        return names.Count == 1
            ? UiText.Format("LabsNotHereOne", names[0])
            : UiText.Format("LabsNotHereMany", string.Join(", ", names.Take(names.Count - 1)), names[^1]);
    }
}

public static class LabsJson
{
    /// <summary>
    /// The entries of the document. An entry without a name is left out and counted in <paramref name="skipped"/>; every other field has a
    /// default, so a CLI that drops <c>since</c> does not make every experiment vanish.
    /// </summary>
    public static IReadOnlyList<LabEntry> Parse(JsonObject o, out int skipped)
    {
        if (o["labs"] is not JsonArray array) throw new FormatException("The labs list did not contain a labs array.");
        var entries = new List<LabEntry>();
        skipped = 0;
        foreach (var node in array)
        {
            if (node is not JsonObject lab || JsonRead.Str(lab, "name") is not { Length: > 0 } name)
            {
                skipped++;
                continue;
            }
            IReadOnlyList<string>? platforms = lab["platforms"] is JsonArray ? JsonRead.Strings(lab, "platforms") : null;
            bool? available = lab["available"] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : null;
            entries.Add(new LabEntry(name, JsonRead.Str(lab, "title") is { Length: > 0 } title ? title : name, JsonRead.Str(lab, "description") ?? "",
                JsonRead.Str(lab, "warning") ?? "", JsonRead.Str(lab, "since") ?? "", JsonRead.Bool(lab, "enabled"),
                JsonRead.Strings(lab, "commands"), platforms, available));
        }
        return entries;
    }
}

public enum LabsAvailability { Unknown, Available, Unsupported, CliMissing }

/// <summary>
/// The Labs page (macos Labs, Settings > Labs): the CLI is the source of truth (its <c>LABS</c> key), so the CLI, MCP and the tray agree
/// and the tray keeps no copy of the flags beyond what the last <c>labs list</c> said. <see cref="Changed"/> is raised on the thread that
/// awaited (the UI thread in the app).
/// </summary>
public sealed class LabsModel(ICliClient cli, TimeProvider? time = null)
{
    /// <summary>Calls closer together than this reuse the last answer (the page is selected often).</summary>
    public static readonly TimeSpan MinimumInterval = TimeSpan.FromSeconds(5);

    private readonly TimeProvider _time = time ?? TimeProvider.System;
    private readonly HashSet<string> _busy = [];
    private readonly Dictionary<string, string> _errors = [];
    private long? _lastRefresh;
    private bool _refreshing;

    public event Action? Changed;

    public IReadOnlyList<LabEntry> Entries { get; private set; } = [];

    public LabsAvailability Availability { get; private set; } = LabsAvailability.Unknown;

    /// <summary>The last failed refresh that is no verdict (the entries stay); shown above the list.</summary>
    public string? RefreshError { get; private set; }

    /// <summary>A refresh is running.</summary>
    public bool IsLoading => _refreshing;

    /// <summary>Names with a CLI call running: their switch is off.</summary>
    public bool IsBusy(string name) => _busy.Contains(name);

    /// <summary>The last failure of this lab, shown under its row; cleared by the next flip.</summary>
    public string? ErrorOf(string name) => _errors.GetValueOrDefault(name);

    public bool IsOn(string name) => Entries.FirstOrDefault(e => e.Name == name)?.Enabled ?? false;

    // --- the exact calls ---

    public static string[] ListArgs() => ["labs", "list", "--json"];

    /// <summary><c>labs on NAME --yes --json</c> or <c>labs off NAME --yes --json</c>. <c>--yes</c> skips only the CLI's own question.</summary>
    public static string[] SetArgs(string name, bool on) => ["labs", on ? "on" : "off", name, "--yes", "--json"];

    /// <summary>
    /// Like <c>site open-as on</c>: the CLI refuses <c>labs on</c> under <c>BENCHBAR_NONINTERACTIVE=1</c> so that no agent can turn an
    /// experiment on. Here the click is the person's decision (the warning is on the row), so the call says the run is interactive.
    /// </summary>
    public static SecretEnvironment SetEnvironment() => new SecretEnvironment().Set(SetupEnv.NonInteractive, "0");

    // --- refresh ---

    /// <summary>One CLI call; skipped when the last one was under 5 s ago (unless <paramref name="force"/>) or one is running.</summary>
    public async Task RefreshAsync(bool force = false, CancellationToken ct = default)
    {
        if (_refreshing) return;
        var now = _time.GetTimestamp();
        if (!force && _lastRefresh is { } last && _time.GetElapsedTime(last, now) < MinimumInterval) return;
        _refreshing = true;
        Raise();
        try
        {
            var result = await cli.RunJsonAsync(ListArgs(), null, CliTimeouts.Read, o => LabsJson.Parse(o, out _), ct).ConfigureAwait(true);
            _lastRefresh = _time.GetTimestamp();
            if (result.Ok && result.Value is { } fresh)
            {
                Availability = LabsAvailability.Available;
                RefreshError = null;
                Entries = fresh;
            }
            else
            {
                var message = result.Error ?? UiText.Get("LabsNotRead");
                if (message == ShimBenchSource.NotFoundMessage)
                {
                    Availability = LabsAvailability.CliMissing;
                    RefreshError = message;
                }
                else if (message.Contains("unknown command", StringComparison.OrdinalIgnoreCase))
                {
                    // only the CLI's own "Unknown command" means a CLI without `labs`
                    Availability = LabsAvailability.Unsupported;
                    RefreshError = null;
                    Entries = [];
                }
                else
                {
                    RefreshError = message; // a transient failure is no verdict: keep what the last list said
                }
            }
        }
        finally
        {
            _refreshing = false;
            Raise();
        }
    }

    // --- turn on and off ---

    /// <summary>
    /// Turns one experiment on or off through the CLI. A second call for the same name while one runs is ignored. On success the entry
    /// flips at once; on a failure the CLI's own sentence stays under the row. Returns true when the CLI did it.
    /// </summary>
    public async Task<bool> SetAsync(string name, bool on, CancellationToken ct = default)
    {
        if (!_busy.Add(name)) return false;
        _errors.Remove(name);
        Raise();
        try
        {
            var result = await cli.RunJsonAsync(SetArgs(name, on), SetEnvironment(), CliTimeouts.Plan, o => o, ct).ConfigureAwait(true);
            if (!result.Ok)
            {
                _errors[name] = result.Error ?? (on ? UiText.Get("LabsCouldNotTurnOn") : UiText.Get("LabsCouldNotTurnOff"));
                return false;
            }
            Entries = [.. Entries.Select(e => e.Name == name ? e with { Enabled = on } : e)];
            return true;
        }
        finally
        {
            _busy.Remove(name);
            Raise();
        }
    }

    private void Raise() => Changed?.Invoke();
}
