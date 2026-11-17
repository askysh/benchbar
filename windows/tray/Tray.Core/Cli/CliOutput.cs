using System.Text.Json;

namespace BenchBar.Tray.Core;

/// <summary>
/// Picks the JSON document out of what <c>benchbar.exe</c> printed, the way <see cref="CliClient"/> does: the whole output when it is one
/// document, else the document among its lines (a shim or CLI of another version may print a line of text first). A document of a newer
/// schema is refused. What cannot be read becomes a <see cref="CliProblemException"/> that names a version mismatch as the likely cause
/// and quotes the first line, never a raw parser message.
/// </summary>
public static class CliOutput
{
    /// <summary>The text of the document in <paramref name="output"/>. <paramref name="what"/> names the command for the message ("list").</summary>
    public static string Document(string output, string what)
    {
        var trimmed = output.Trim();
        if (trimmed.Length > 0 && trimmed[0] == '{' && SchemaOf(trimmed, out var whole))
        {
            RefuseNewer(whole);
            return trimmed;
        }
        var lines = output.Split('\n').Select(l => l.TrimEnd('\r')).ToList();
        // a line of text, then a document that spans several lines (an indented one). This comes before the line by line pick, which
        // would take one inner object of an indented document for the whole answer.
        if (FromFirstBrace(lines) is { } text && SchemaOf(text, out var schema))
        {
            RefuseNewer(schema);
            return text;
        }
        if (CliJson.PickDocument(lines) is { } picked)
        {
            JsonRead.RefuseNewerSchema(picked);
            return picked.ToJsonString();
        }
        throw Unreadable(output, what);
    }

    /// <summary>The first JSON object that starts at the beginning of a line and runs over the following ones; whatever comes after it is ignored.</summary>
    private static string? FromFirstBrace(IReadOnlyList<string> lines)
    {
        for (var i = 0; i < lines.Count; i++)
        {
            if (!lines[i].TrimStart().StartsWith('{')) continue;
            var bytes = System.Text.Encoding.UTF8.GetBytes(string.Join('\n', lines.Skip(i)));
            try
            {
                var reader = new Utf8JsonReader(bytes);
                using var doc = JsonDocument.ParseValue(ref reader);
                if (doc.RootElement.ValueKind == JsonValueKind.Object) return doc.RootElement.GetRawText();
            }
            catch (JsonException)
            {
                // not a document from this line: try the next one
            }
        }
        return null;
    }

    /// <summary>Reads the document with <paramref name="parse"/>; a document that does not have the shape the parser needs is the same readable problem.</summary>
    public static T Parse<T>(string output, string what, Func<string, T> parse)
    {
        var json = Document(output, what);
        try
        {
            return parse(json);
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException or FormatException)
        {
            throw Unreadable(output, what);
        }
    }

    /// <summary>The first line of the output that says anything, cut to a length a notice can hold.</summary>
    public static string FirstLine(string output)
    {
        foreach (var raw in output.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            return line.Length > 120 ? line[..120] + "..." : line;
        }
        return "";
    }

    public static CliProblemException Unreadable(string output, string what)
    {
        var first = FirstLine(output);
        var quote = first.Length == 0 ? "It printed nothing." : $"The first line was: {first}";
        return new CliProblemException(
            $"benchbar.exe {what} gave an answer BenchBar cannot read. {quote} A benchbar.exe of another version than BenchBar is the likely cause: run the installer again so both match.");
    }

    private static bool SchemaOf(string json, out int? schema)
    {
        schema = null;
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return false;
            if (doc.RootElement.TryGetProperty("schema_version", out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var n)) schema = n;
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static void RefuseNewer(int? schema)
    {
        if (schema is { } v && v > JsonRead.SupportedSchema) throw new UnsupportedSchemaException(v);
    }
}
