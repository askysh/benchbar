using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>One line of the log viewer (macos LogLine).</summary>
/// <param name="Id">Grows by one per line for the life of the viewer; stable across filters.</param>
/// <param name="Process">The honcho process (web, worker, socketio...). A line without a prefix belongs to the process above it.</param>
/// <param name="IsError">ERROR, CRITICAL, an exception or a traceback: tinted in the view.</param>
public sealed record LogLine(int Id, string Text, string? Process, bool IsError);

public static class LogParser
{
    private static readonly string[] ErrorMarkers = ["ERROR", "CRITICAL", "Traceback (most recent call last)", "Exception:", "Error:"];

    /// <summary>honcho writes <c>HH:MM:SS name.N   | text</c> (<c>system |</c> has no number). Null for a line without that prefix.</summary>
    public static string? Process(string line)
    {
        if (line.Length <= 10 || line[2] != ':' || line[5] != ':' || line[8] != ' ') return null;
        var rest = line.AsSpan(9);
        var bar = rest.IndexOf('|');
        if (bar < 0) return null;
        var name = rest[..bar].Trim().ToString();
        if (name.Length == 0 || name.Contains(' ')) return null;
        var dot = name.IndexOf('.');
        var baseName = dot >= 0 ? name[..dot] : name;
        return baseName.Length > 0 && baseName.All(c => char.IsLetter(c) || c == '_') ? baseName : null;
    }

    public static bool LooksLikeError(string line) => ErrorMarkers.Any(m => line.Contains(m, StringComparison.Ordinal));

    public const string TracebackMarker = "Traceback (most recent call last)";
}

/// <summary>The last <see cref="Capacity"/> lines. Ids keep counting after <see cref="Clear"/>. Not thread safe: the model locks around it.</summary>
public sealed class LogBuffer(int capacity = 5000)
{
    private readonly List<LogLine> _lines = [];
    private int _nextId;
    private string? _lastProcess;
    private bool _inTraceback;

    public int Capacity { get; } = capacity;

    public IReadOnlyList<LogLine> Lines => _lines;

    public int LastId => _lines.Count == 0 ? -1 : _lines[^1].Id;

    /// <summary>Adds the lines; returns the ones added.</summary>
    public IReadOnlyList<LogLine> Append(IEnumerable<string> raw)
    {
        var added = new List<LogLine>();
        foreach (var text in raw)
        {
            var process = LogParser.Process(text);
            if (process is not null)
            {
                _lastProcess = process;
                _inTraceback = text.Contains(LogParser.TracebackMarker, StringComparison.Ordinal);
            }
            else if (text.Contains(LogParser.TracebackMarker, StringComparison.Ordinal))
            {
                _inTraceback = true;
            }
            var isError = LogParser.LooksLikeError(text) || (process is null && _inTraceback);
            added.Add(new LogLine(_nextId++, text, process ?? _lastProcess, isError));
        }
        _lines.AddRange(added);
        if (_lines.Count > Capacity) _lines.RemoveRange(0, _lines.Count - Capacity);
        return added;
    }

    /// <summary>Empties the view (the file is not touched); ids keep counting.</summary>
    public void Clear()
    {
        _lines.Clear();
        _inTraceback = false;
    }
}

/// <summary>What the viewer shows: one process or all, and a search.</summary>
public sealed record LogQuery(string? Process = null, string Search = "")
{
    /// <summary>The processes offered in the filter, in Procfile order.</summary>
    public static IReadOnlyList<string> Processes { get; } = ["web", "worker", "socketio", "schedule", "redis_queue", "redis_cache"];

    public bool Shows(LogLine line) => Process is null || line.Process == Process;

    public IReadOnlyList<LogLine> Visible(IEnumerable<LogLine> lines) => Process is null ? lines.ToList() : lines.Where(Shows).ToList();

    /// <summary>The ids of the lines that contain the search (case insensitive), in order.</summary>
    public IReadOnlyList<int> Matches(IEnumerable<LogLine> lines)
    {
        var needle = Search.Trim();
        return needle.Length == 0 ? [] : lines.Where(l => l.Text.Contains(needle, StringComparison.OrdinalIgnoreCase)).Select(l => l.Id).ToList();
    }
}

/// <summary>"3 of 12", "no matches", or nothing without a search.</summary>
public static class SearchText
{
    public static string Describe(int? current, int total, bool searching)
    {
        if (!searching) return "";
        if (total == 0) return "no matches";
        return current is { } c ? $"{c + 1} of {total}" : $"{total} matches";
    }

    /// <summary>The next (or previous) match index, wrapping around.</summary>
    public static int? Step(int? current, int total, bool forward)
    {
        if (total == 0) return null;
        if (current is not { } c) return forward ? 0 : total - 1;
        return forward ? (c + 1) % total : (c - 1 + total) % total;
    }
}

/// <summary><c>logs --json</c>: the lines, and for each its time where it has one.</summary>
public sealed record LogChunk(string? File, IReadOnlyList<string> Lines, IReadOnlyList<string?> Times, string? Mtime, string? Since, int? TruncatedTo);

public static class LogsJson
{
    public static LogChunk Parse(JsonObject o)
    {
        if (o["lines"] is not JsonArray array) throw new FormatException("logs: the document has no lines");
        var lines = array.Select(n => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : "").ToList();
        var times = new List<string?>();
        if (o["ts"] is JsonArray ts) times.AddRange(ts.Select(n => n is JsonValue v && v.TryGetValue<string>(out var s) && s.Length > 0 ? s : null));
        while (times.Count < lines.Count) times.Add(null);
        if (times.Count > lines.Count) times.RemoveRange(lines.Count, times.Count - lines.Count);
        return new LogChunk(JsonRead.Str(o, "file"), lines, times, JsonRead.Str(o, "mtime"), JsonRead.Str(o, "since"), JsonRead.Int(o, "truncated_to"));
    }
}

/// <summary>The exact arguments of the log calls. <c>-nN</c> is one argument, as the CLI reads it.</summary>
public static class LogArgs
{
    public const int FirstLines = 1000;
    public const int PollLines = 2000;

    public static string[] First(string benchPath, bool previous) =>
        previous ? ["logs", "--json", $"-n{FirstLines}", "--previous", "--bench-dir", benchPath] : ["logs", "--json", $"-n{FirstLines}", "--bench-dir", benchPath];

    /// <summary>The newer lines: <c>--since TIME</c> when a line had a time, else the newest lines to compare with what is shown.</summary>
    public static string[] Newer(string benchPath, string? since) =>
        since is null ? ["logs", "--json", "-n200", "--bench-dir", benchPath] : ["logs", "--json", "--since", since, $"-n{PollLines}", "--bench-dir", benchPath];
}

/// <summary>Finds which lines of a poll are new. The poll starts at the last time seen, so its first lines are ones already shown.</summary>
public static class LogOverlap
{
    private const int Window = 40;

    /// <summary>
    /// The lines of <paramref name="response"/> that come after the longest run of the last shown lines found in it (the latest place
    /// when it is found twice). Nothing in common means the log started over (or more than a poll's worth came at once).
    /// </summary>
    public static (IReadOnlyList<string> New, bool Restarted) NewLines(IReadOnlyList<string> shown, IReadOnlyList<string> response)
    {
        if (response.Count == 0) return ([], false);
        var max = Math.Min(Math.Min(shown.Count, response.Count), Window);
        for (var k = max; k >= 1; k--)
        {
            for (var j = response.Count - k; j >= 0; j--)
            {
                var match = true;
                for (var i = 0; i < k && match; i++) match = shown[shown.Count - k + i] == response[j + i];
                if (match) return (response.Skip(j + k).ToList(), false);
            }
        }
        return (response, shown.Count > 0);
    }
}
