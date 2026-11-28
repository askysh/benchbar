using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>
/// One entry of <c>notices[]</c> in <c>status --json</c> (0.9): a default an update changed, until it is dismissed. <see cref="SwitchBack"/> is the
/// command or variable that goes back, <see cref="Doc"/> the full URL of the page that explains it.
/// </summary>
public sealed record BenchNotice(string Id, string Title, string Text, string? SwitchBack, string? Doc, string? Since)
{
    /// <summary>The doc link only when it is an https page: a notice is the CLI's text, but a link is opened by the system.</summary>
    public string? SafeDoc => Doc is { Length: > 0 } d && Uri.TryCreate(d, UriKind.Absolute, out var u) && u.Scheme == Uri.UriSchemeHttps ? u.AbsoluteUri : null;
}

/// <summary>
/// <c>ready</c> of <c>status --json</c> (0.9, docs/json-schema.md Readiness). A part is null when the CLI did not ask (<c>workers</c> and
/// <c>stale</c> without <c>--deep</c>) and a null part never makes the bench not ready.
/// </summary>
public sealed record ReadyInfo(bool Ready, bool? Deep, bool? Agent, bool? Processes, bool? Web, bool? Socketio, bool? Redis, bool? Workers,
    bool? Stale, string? StaleFile, IReadOnlyList<string> WaitingOn, string? Fix);

/// <summary>Reads the two 0.9 members of <c>status --json</c>. Both are absent from an older CLI, and a member of the wrong shape counts as absent.</summary>
public static class StatusExtras
{
    public static IReadOnlyList<BenchNotice> ParseNotices(JsonNode? node)
    {
        if (node is not JsonArray array) return [];
        var list = new List<BenchNotice>();
        foreach (var o in array.OfType<JsonObject>())
        {
            var id = JsonRead.Str(o, "id");
            if (string.IsNullOrWhiteSpace(id)) continue;
            var title = JsonRead.Str(o, "title") ?? id;
            list.Add(new BenchNotice(id, title, JsonRead.Str(o, "text") ?? "", Blank(JsonRead.Str(o, "switch_back")), Blank(JsonRead.Str(o, "doc")), Blank(JsonRead.Str(o, "since"))));
        }
        return list;
    }

    public static ReadyInfo? ParseReady(JsonNode? node)
    {
        if (node is not JsonObject o || Flag(o, "ready") is not { } ready) return null;
        return new ReadyInfo(ready, Flag(o, "deep"), Flag(o, "agent"), Flag(o, "processes"), Flag(o, "web"), Flag(o, "socketio"), Flag(o, "redis"),
            Flag(o, "workers"), Flag(o, "stale"), Blank(JsonRead.Str(o, "stale_file")), JsonRead.Strings(o, "waiting_on"), Blank(JsonRead.Str(o, "fix")));
    }

    private static bool? Flag(JsonObject o, string key) => o[key] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : null;

    private static string? Blank(string? s) => string.IsNullOrWhiteSpace(s) ? null : s;
}

/// <summary><c>benchbar notices --dismiss ID</c>: the one command a notice's Dismiss runs. The state it changes is the person's, not a bench's.</summary>
public static class NoticeCommands
{
    public static string[] Dismiss(string id) => ["notices", "--dismiss", id];
}

/// <summary>The words for <c>ready</c>, as the Mac app's headline: "Ready", "Needs restart (code changed)", "Running, not ready".</summary>
public static class ReadinessText
{
    /// <summary>The word for a running bench that reports readiness; null for any other state or a CLI older than 0.9.</summary>
    public static string? Headline(BenchStatus bench)
    {
        if (bench.State != BenchState.Running || bench.Ready is not { } ready) return null;
        if (ready.Stale == true) return UiText.Get("OverviewReadyStale");
        return ready.Ready ? UiText.Get("OverviewReady") : UiText.Get("OverviewReadyNot");
    }

    /// <summary>What a not ready bench waits on, in words ("the realtime server (socketio)"); an unknown part keeps the CLI's name.</summary>
    public static IReadOnlyList<string> WaitingOn(ReadyInfo ready) => [.. ready.WaitingOn.Select(Part)];

    public static string Part(string name) => name switch
    {
        "agent" => UiText.Get("OverviewWaitAgent"),
        "processes" => UiText.Get("OverviewWaitProcesses"),
        "web" => UiText.Get("OverviewWaitWeb"),
        "socketio" => UiText.Get("OverviewWaitSocketio"),
        "redis" => UiText.Get("OverviewWaitRedis"),
        "workers" => UiText.Get("OverviewWaitWorkers"),
        "stale" => UiText.Get("OverviewWaitStale"),
        _ => name,
    };

    /// <summary>The lines under the headline: what it waits on, the file that changed, the command that moves it. Empty when ready.</summary>
    public static IReadOnlyList<string> Detail(BenchStatus bench)
    {
        if (Headline(bench) is null || bench.Ready is not { } ready || ready is { Ready: true, Stale: not true }) return [];
        var lines = new List<string>();
        var waiting = WaitingOn(ready);
        if (waiting.Count > 0) lines.Add(UiText.Format("OverviewWaitingOn", string.Join(", ", waiting)));
        if (ready.Stale == true && ready.StaleFile is { } file) lines.Add(UiText.Format("OverviewFileChanged", file));
        return lines;
    }
}
