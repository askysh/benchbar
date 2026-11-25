using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>
/// The result envelope of docs/json-schema.md ("The result envelope"): the fields the last stdout line of a command carries, whether
/// it is the <c>done</c> line of a stream, the document of a command that changed things or the document of a read. This is the one
/// decoder (macos ResultEnvelope.swift is its twin), so no page parses <c>exit</c>, <c>error</c>, <c>warnings</c> or <c>next_actions</c>
/// on its own. Every field is read on its own: a member of another type (a newer CLI) is dropped and never costs the members around it.
/// </summary>
public sealed record ResultEnvelope(int Exit, int? SchemaVersion, string? CliVersion, string? OpId, string? Error, string? ErrorId, string? Fix,
    IReadOnlyList<CliChange> Changed, IReadOnlyList<string> Warnings, IReadOnlyList<CliNextAction> NextActions, IReadOnlyList<string> Missing,
    JsonObject? StateAfter, string? Log)
{
    public bool Succeeded => Exit == 0;

    /// <summary>The first thing to tell the person about a failure: the error, else the fix.</summary>
    public string? Problem => Blank(Error) ?? Blank(Fix);

    /// <summary>The error and, when it adds something, the fix after it (the CLI's hint), as one text for a refusal.</summary>
    public string? Explained => Explain(Error, Fix);

    /// <summary>The longest error or hint shown: a pull host's or ssh's output can be long, and the line is cut, not wrapped over the page.</summary>
    public const int MaxShown = 400;

    /// <summary>The text of an error or a hint as one line of plain text (no control characters, line breaks or bidi marks), cut at <see cref="MaxShown"/>.</summary>
    public static string? Shown(string? text) => Blank(text) is { } t && ShareGuestText.Clean(t, MaxShown) is { Length: > 0 } clean ? clean : null;

    internal static string? Explain(string? error, string? fix)
    {
        var e = Shown(error);
        var f = Shown(fix);
        if (e is null || f is null) return e ?? f;
        return e.Contains(f, StringComparison.Ordinal) ? e : e.TrimEnd().EndsWith('.') ? $"{e} {f}" : $"{e}. {f}";
    }

    /// <summary>The envelope of one JSON object; null when it has no integer <c>exit</c> (the first release's <c>exit_code</c> reads too).</summary>
    public static ResultEnvelope? From(JsonObject o)
    {
        var exit = JsonRead.Int(o, "exit") ?? JsonRead.Int(o, "exit_code");
        if (exit is null) return null;
        return new ResultEnvelope(exit.Value, JsonRead.Int(o, "schema_version"), JsonRead.Str(o, "cli_version"), JsonRead.Str(o, "op_id"),
            JsonRead.Str(o, "error"), JsonRead.Str(o, "error_id"), JsonRead.Str(o, "fix"), Changes(o), JsonRead.Strings(o, "warnings"), Next(o),
            JsonRead.Strings(o, "missing"), o["state_after"] as JsonObject, JsonRead.Str(o, "log"));
    }

    /// <summary>The envelope of the last line that is a JSON object with an <c>exit</c>; null when no line has one. Text lines are skipped.</summary>
    public static ResultEnvelope? Last(IReadOnlyList<string> lines)
    {
        for (var i = lines.Count - 1; i >= 0; i--)
        {
            if (JsonRead.TryObject(lines[i], out var o) && From(o) is { } envelope) return envelope;
        }
        return null;
    }

    /// <summary><c>next_actions[]</c> of an object: <c>{command, why, quoted?}</c> items, and the older bare strings.</summary>
    public static IReadOnlyList<CliNextAction> Next(JsonObject o)
    {
        var next = new List<CliNextAction>();
        if (o["next_actions"] is not JsonArray array) return next;
        foreach (var item in array)
        {
            if (item is JsonObject obj && JsonRead.Str(obj, "command") is { Length: > 0 } command)
                next.Add(new CliNextAction(command, JsonRead.Str(obj, "why"), obj["quoted"] is JsonValue q && q.TryGetValue<bool>(out var quoted) && quoted));
            else if (item is JsonValue v && v.TryGetValue<string>(out var text) && text.Length > 0) next.Add(new CliNextAction(text, null));
        }
        return next;
    }

    private static IReadOnlyList<CliChange> Changes(JsonObject o)
    {
        var changed = new List<CliChange>();
        if (o["changed"] is not JsonArray array) return changed;
        foreach (var item in array.OfType<JsonObject>())
            changed.Add(new CliChange(JsonRead.Str(item, "kind") ?? "", JsonRead.Str(item, "name") ?? "", JsonRead.Str(item, "detail")));
        return changed;
    }

    private static string? Blank(string? s) => string.IsNullOrWhiteSpace(s) ? null : s;
}
