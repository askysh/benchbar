using System.Text.Json;
using System.Text.Json.Serialization;

namespace BenchBar.Tray.Core;

/// <summary>The bench states of <c>status --json</c> (docs/json-schema.md, States).</summary>
public enum BenchState { Unknown, Stopped, Starting, Running, Crashed, Paused }

/// <summary>One bench as <c>status --json</c> reports it.</summary>
public sealed record BenchStatus(
    string Name,
    string Path,
    BenchState State,
    string? StopReason,
    string? WebUrl,
    string? Site);

/// <summary>One bench from <c>list --json</c> (<c>benches[]</c>).</summary>
public sealed record BenchEntry(string Name, string Path, bool IsDefault, string? WebUrl);

/// <summary>
/// How a set of benches shows as one: the same rules as BenchAggregate in
/// macos/BenchBar/Popover/BenchPresentation.swift.
/// </summary>
public static class BenchAggregate
{
    /// <summary>Worst wins: crashed, paused, starting, running, else stopped. Nothing known is unknown.</summary>
    public static BenchState State(IEnumerable<BenchState> states)
    {
        var known = states.Where(s => s != BenchState.Unknown).ToList();
        if (known.Count == 0) return BenchState.Unknown;
        if (known.Contains(BenchState.Crashed)) return BenchState.Crashed;
        if (known.Contains(BenchState.Paused)) return BenchState.Paused;
        if (known.Contains(BenchState.Starting)) return BenchState.Starting;
        if (known.Contains(BenchState.Running)) return BenchState.Running;
        return BenchState.Stopped;
    }

    /// <summary>Benches that are up (running or starting).</summary>
    public static int UpCount(IReadOnlyList<BenchState> states) =>
        states.Count(s => s is BenchState.Running or BenchState.Starting);

    /// <summary>"2 of 3 up", "none up".</summary>
    public static string UpText(IReadOnlyList<BenchState> states)
    {
        var up = UpCount(states);
        return up == 0 ? "none up" : $"{up} of {states.Count} up";
    }
}

internal sealed class StatusDto
{
    [JsonPropertyName("bench")] public string? Bench { get; set; }
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("site")] public string? Site { get; set; }
    [JsonPropertyName("state")] public string? State { get; set; }
    [JsonPropertyName("stop_reason")] public string? StopReason { get; set; }
    [JsonPropertyName("web_url")] public string? WebUrl { get; set; }
}

internal sealed class ListDto
{
    [JsonPropertyName("default_bench")] public string? DefaultBench { get; set; }
    [JsonPropertyName("benches")] public List<ListBenchDto>? Benches { get; set; }
}

internal sealed class ListBenchDto
{
    [JsonPropertyName("path")] public string? Path { get; set; }
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("default")] public bool? Default { get; set; }
    [JsonPropertyName("web_url")] public string? WebUrl { get; set; }
}

[JsonSerializable(typeof(StatusDto))]
[JsonSerializable(typeof(ListDto))]
internal sealed partial class BenchJsonContext : JsonSerializerContext;

/// <summary>
/// Parsing of the CLI's JSON. Source generated (no reflection). Unknown and
/// missing fields are fine; a state string it does not know is
/// <see cref="BenchState.Unknown"/>. Malformed JSON throws <see cref="JsonException"/>.
/// </summary>
public static class BenchJson
{
    public static BenchState ParseState(string? value) => value?.Trim().ToLowerInvariant() switch
    {
        "stopped" => BenchState.Stopped,
        "starting" => BenchState.Starting,
        "running" => BenchState.Running,
        "crashed" => BenchState.Crashed,
        "paused" => BenchState.Paused,
        _ => BenchState.Unknown,
    };

    public static BenchStatus ParseStatus(string json)
    {
        var dto = JsonSerializer.Deserialize(json, BenchJsonContext.Default.StatusDto)
                  ?? throw new JsonException("status: empty document");
        var path = dto.Bench ?? "";
        var name = dto.Name ?? System.IO.Path.GetFileName(path.TrimEnd('/', '\\'));
        return new BenchStatus(name, path, ParseState(dto.State), dto.StopReason, dto.WebUrl, dto.Site);
    }

    public static IReadOnlyList<BenchEntry> ParseList(string json)
    {
        var dto = JsonSerializer.Deserialize(json, BenchJsonContext.Default.ListDto)
                  ?? throw new JsonException("list: empty document");
        var result = new List<BenchEntry>();
        foreach (var b in dto.Benches ?? [])
        {
            var path = b.Path ?? "";
            var name = b.Name ?? System.IO.Path.GetFileName(path.TrimEnd('/', '\\'));
            var isDefault = b.Default ?? (dto.DefaultBench is not null && dto.DefaultBench == path);
            result.Add(new BenchEntry(name, path, isDefault, b.WebUrl));
        }
        return result;
    }
}
