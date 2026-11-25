using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>One entry of <c>changed[]</c> in the done fields: what a run really changed.</summary>
public sealed record CliChange(string Kind, string Name, string? Detail);

/// <summary>One entry of <c>next_actions[]</c>: a command to run and why. <see cref="Quoted"/>: every word is quoted for the shell, so a program may split it.</summary>
public sealed record CliNextAction(string Command, string? Why, bool Quoted = false);

/// <summary>
/// The done fields of docs/json-schema.md, from the <c>done</c> line of a stream or from the one document a command prints.
/// <see cref="Raw"/> keeps the whole object, so a page reads the fields only its command has (<c>site</c>, <c>url</c>, ...).
/// </summary>
public sealed record CliDone(int Exit, IReadOnlyList<CliChange> Changed, IReadOnlyList<string> Warnings, IReadOnlyList<CliNextAction> NextActions,
    JsonObject? StateAfter, string? ErrorId, IReadOnlyList<string> Missing, string? Error, string? Fix, string? Log, JsonObject Raw,
    int? SchemaVersion = null, string? CliVersion = null, string? OpId = null)
{
    public bool Ok => Exit == 0;

    /// <summary>The sudo password in <c>BENCHBAR_SUDO_PASSWORD</c> was refused, before any change.</summary>
    public bool WrongSudoPassword => ErrorId == InstallErrors.SudoPasswordWrong;

    /// <summary>The first thing to tell the person about a failure: the error, else the fix.</summary>
    public string? Problem => Error ?? Fix;

    /// <summary>The error and the CLI's hint (its <c>fix</c>) after it: what a refusal shows.</summary>
    public string? Explained => ResultEnvelope.Explain(Error, Fix);
}

/// <summary>A <c>step</c> line of a stream. <see cref="Id"/> is the line's <c>id</c>, else its <c>action</c> or <c>kind</c>.</summary>
public sealed record CliStep(string Id, string Name, InstallStepStatus Status, string? Message, string? Command, int? Secs, string? Parent = null)
{
    /// <summary>A sub step (<c>site move</c>'s restore) shares the id of its parent and names it in <c>parent</c>: it is progress, not a row of its own.</summary>
    public bool IsSubStep => !string.IsNullOrEmpty(Parent);
}

/// <summary>A line of a <c>--json</c> or <c>--jsonl</c> stream.</summary>
public abstract record CliEvent
{
    public sealed record Plan(JsonObject Value) : CliEvent;

    public sealed record Step(CliStep Value) : CliEvent;

    public sealed record Progress(string StepId, string Label, int Elapsed) : CliEvent;

    public sealed record Done(CliDone Value) : CliEvent;

    /// <summary>A JSON object of an event this reader does not know.</summary>
    public sealed record Other(JsonObject Value) : CliEvent;

    /// <summary>A line that is not JSON (the progress text of a command without a JSON mode, such as <c>ports apply</c>).</summary>
    public sealed record Text(string Line) : CliEvent;
}

/// <summary>The result of a one document call. <see cref="Value"/> is null when there was no document or the parser refused it.</summary>
public sealed record CliResult<T>(int Exit, T? Value, CliDone? Done, string? Error)
{
    public bool Ok => Exit == 0 && Value is not null && (Done is null || Done.Exit == 0);

    public static CliResult<T> Failure(string error) => new(1, default, null, error);
}

/// <summary>How a streamed call ended. <see cref="Exit"/> is the done line's, else the process's.</summary>
public sealed record CliStreamResult(int Exit, CliDone? Done, string? Error, bool Cancelled, IReadOnlyList<string> TextLines)
{
    public bool Ok => Exit == 0 && !Cancelled;

    /// <summary>The line to show for a failure: the done line's problem, else stderr.</summary>
    public string? Problem => Done?.Problem ?? Error;

    public static CliStreamResult Failure(string error) => new(1, null, error, false, []);
}

public static class CliJson
{
    /// <summary>The done fields of one object, through the one <see cref="ResultEnvelope"/> decoder; null when it has no <c>exit</c>.</summary>
    public static CliDone? ParseDone(JsonObject o) => ResultEnvelope.From(o) is { } e
        ? new CliDone(e.Exit, e.Changed, e.Warnings, e.NextActions, e.StateAfter, e.ErrorId, e.Missing, e.Error, e.Fix, e.Log, o, e.SchemaVersion, e.CliVersion, e.OpId)
        : null;

    /// <summary>One line of a stream. A schema above 1 throws <see cref="UnsupportedSchemaException"/>.</summary>
    public static CliEvent ParseLine(string line)
    {
        if (!JsonRead.TryObject(line, out var o)) return new CliEvent.Text(line);
        JsonRead.RefuseNewerSchema(o);
        switch (JsonRead.Str(o, "event"))
        {
            case "plan":
                return new CliEvent.Plan(o);
            case "step":
                var id = JsonRead.Str(o, "id") ?? JsonRead.Str(o, "action") ?? JsonRead.Str(o, "kind");
                if (string.IsNullOrEmpty(id)) return new CliEvent.Other(o);
                return new CliEvent.Step(new CliStep(id, JsonRead.Str(o, "name") ?? id, InstallJson.ParseStatus(JsonRead.Str(o, "status")),
                    JsonRead.Str(o, "message"), JsonRead.Str(o, "command"), JsonRead.Int(o, "secs"), JsonRead.Str(o, "parent")));
            case "progress":
                return new CliEvent.Progress(JsonRead.Str(o, "step") ?? "", JsonRead.Str(o, "label") ?? DownloadLabel(o), JsonRead.Int(o, "elapsed") ?? 0);
            case "done":
                return ParseDone(o) is { } d ? new CliEvent.Done(d) : new CliEvent.Other(o);
            default:
                return new CliEvent.Other(o);
        }
    }

    /// <summary>The <c>progress</c> line of <c>pull</c> has <c>file</c>, <c>bytes</c> and <c>total</c> and no label: "Downloaded 7.0 MB of 12.0 MB".</summary>
    private static string DownloadLabel(JsonObject o)
    {
        if (o["bytes"] is not JsonValue b || !b.TryGetValue<long>(out var bytes)) return "";
        var total = o["total"] is JsonValue t && t.TryGetValue<long>(out var all) && all > 0 ? UiText.Format("CommonDownloadedOf", ByteSize.Format(all)) : "";
        return UiText.Format("CommonDownloaded", ByteSize.Format(bytes), total);
    }

    /// <summary>
    /// The document in the output of a one document call: the whole output when it is one JSON object, else (a stream such as a
    /// service plan) the <c>plan</c> line, else the first object that is not a <c>done</c>, <c>step</c> or <c>progress</c> line.
    /// </summary>
    public static JsonObject? PickDocument(IReadOnlyList<string> lines)
    {
        var whole = string.Join('\n', lines);
        if (JsonRead.TryObject(whole, out var single)) return single;
        JsonObject? first = null;
        foreach (var line in lines)
        {
            if (!JsonRead.TryObject(line, out var o)) continue;
            var kind = JsonRead.Str(o, "event");
            if (kind == "plan") return o;
            if (kind is "done" or "step" or "progress") continue;
            first ??= o;
        }
        return first;
    }

    /// <summary>The last <c>done</c> line among the lines, if any.</summary>
    public static CliDone? FindDone(IReadOnlyList<string> lines)
    {
        for (var i = lines.Count - 1; i >= 0; i--)
        {
            if (JsonRead.TryObject(lines[i], out var o) && JsonRead.Str(o, "event") == "done" && ParseDone(o) is { } d) return d;
        }
        return null;
    }
}
