using System.Text.Json;
using System.Text.Json.Serialization;

namespace BenchBar.Tray.Core;

/// <summary>The bench states of <c>status --json</c> (docs/json-schema.md, States).</summary>
public enum BenchState { Unknown, Stopped, Starting, Running, Crashed, Paused }

/// <summary>A site of a bench (<c>sites[]</c> in <c>status --json</c>). Other fields of the CLI are ignored.</summary>
public sealed record SiteInfo(string Name, bool IsDefault);

/// <summary>
/// One bench as <c>status --json</c> reports it. <see cref="Site"/> is null for a bench that has none
/// (<c>not_adopted</c>). <see cref="RawState"/> is the CLI's own word, kept as it came, so a state this
/// build does not know (<see cref="BenchState.Unknown"/>) can still be shown.
/// </summary>
public sealed record BenchStatus(
    string Name,
    string Path,
    BenchState State,
    string? StopReason,
    string? WebUrl,
    string? Site)
{
    /// <summary>The <c>state</c> string as the CLI sent it; empty when it sent none.</summary>
    public string RawState { get; init; } = "";

    /// <summary>The bench log, <c>log</c> in the JSON.</summary>
    public string? LogPath { get; init; }

    public IReadOnlyList<SiteInfo> Sites { get; init; } = [];

    /// <summary>Why this one bench could not be read (its status call failed); null when it answered. Shown under its row.</summary>
    public string? Problem { get; init; }
}

/// <summary>One bench from <c>list --json</c> (<c>benches[]</c>).</summary>
public sealed record BenchEntry(string Name, string Path, bool IsDefault, string? WebUrl);

/// <summary>
/// What one poll found: the benches, or why there are none. With <see cref="DistroStopped"/> the poller
/// asked nothing of the CLI (that would boot the distro). <see cref="Problem"/> is the one line the shim
/// or the tray printed for a setup or CLI failure, to show as it is.
/// </summary>
public sealed record TraySnapshot(
    IReadOnlyList<BenchStatus> Benches,
    bool DistroStopped = false,
    string? Distro = null,
    string? Problem = null)
{
    public static TraySnapshot Empty { get; } = new([]);
}

/// <summary>The words the flyout shows for a bench.</summary>
public static class BenchPresentation
{
    /// <summary>
    /// "running", "starting", "stopped", "crashed", "paused" (crash guard), "port conflict", "paused, needs repair"
    /// (broken), and "unknown (RAW)" for a state name this build does not know.
    /// </summary>
    public static string StateWord(BenchStatus bench) => bench.State switch
    {
        BenchState.Running => "running",
        BenchState.Starting => "starting",
        BenchState.Stopped => "stopped",
        BenchState.Crashed => "crashed",
        BenchState.Paused => bench.StopReason?.Trim().ToLowerInvariant() switch
        {
            "port_conflict" => "port conflict",
            "broken" => "paused, needs repair",
            _ => "paused",
        },
        _ => string.IsNullOrWhiteSpace(bench.RawState) ? "unknown" : $"unknown ({bench.RawState})",
    };
}

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

/// <summary>The level of one doctor check.</summary>
public enum CheckLevel { Unknown, Ok, Warn, Fail }

/// <summary>One check of <c>doctor --json</c> (<c>checks[]</c>). <see cref="FixCommand"/> is null when nothing needs doing.</summary>
public sealed record DoctorCheck(string Id, string Group, string Label, CheckLevel Level, string Message, string? FixCommand);

/// <summary><c>doctor --json</c>.</summary>
public sealed record DoctorReport(string? Bench, string? Profile, IReadOnlyList<DoctorCheck> Checks, int Ok, int Warn, int Fail);

/// <summary><c>logs --json</c>: the newest lines of <see cref="File"/>.</summary>
public sealed record LogTail(string? File, IReadOnlyList<string> Lines);

internal sealed class StatusDto
{
    [JsonPropertyName("bench")] public string? Bench { get; set; }
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("site")] public string? Site { get; set; }
    [JsonPropertyName("state")] public string? State { get; set; }
    [JsonPropertyName("stop_reason")] public string? StopReason { get; set; }
    [JsonPropertyName("web_url")] public string? WebUrl { get; set; }
    [JsonPropertyName("log")] public string? Log { get; set; }
    [JsonPropertyName("sites")] public List<SiteDto>? Sites { get; set; }
}

internal sealed class SiteDto
{
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("default")] public bool? Default { get; set; }
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

internal sealed class DoctorDto
{
    [JsonPropertyName("bench")] public string? Bench { get; set; }
    [JsonPropertyName("profile")] public string? Profile { get; set; }
    [JsonPropertyName("checks")] public List<DoctorCheckDto>? Checks { get; set; }
    [JsonPropertyName("summary")] public DoctorSummaryDto? Summary { get; set; }
}

internal sealed class DoctorCheckDto
{
    [JsonPropertyName("id")] public string? Id { get; set; }
    [JsonPropertyName("group")] public string? Group { get; set; }
    [JsonPropertyName("label")] public string? Label { get; set; }
    [JsonPropertyName("level")] public string? Level { get; set; }
    [JsonPropertyName("status")] public string? Status { get; set; }
    [JsonPropertyName("message")] public string? Message { get; set; }
    [JsonPropertyName("fix_command")] public string? FixCommand { get; set; }
    [JsonPropertyName("fix")] public string? Fix { get; set; }
}

internal sealed class DoctorSummaryDto
{
    [JsonPropertyName("ok")] public int? Ok { get; set; }
    [JsonPropertyName("warn")] public int? Warn { get; set; }
    [JsonPropertyName("fail")] public int? Fail { get; set; }
}

internal sealed class LogsDto
{
    [JsonPropertyName("file")] public string? File { get; set; }
    [JsonPropertyName("lines")] public List<string?>? Lines { get; set; }
}

internal sealed class ReportDto
{
    [JsonPropertyName("zip")] public string? Zip { get; set; }
}

[JsonSerializable(typeof(StatusDto))]
[JsonSerializable(typeof(ListDto))]
[JsonSerializable(typeof(DoctorDto))]
[JsonSerializable(typeof(LogsDto))]
[JsonSerializable(typeof(ReportDto))]
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
        var sites = (dto.Sites ?? [])
            .Where(x => !string.IsNullOrEmpty(x.Name))
            .Select(x => new SiteInfo(x.Name!, x.Default ?? false))
            .ToList();
        return new BenchStatus(name, path, ParseState(dto.State), dto.StopReason, dto.WebUrl, dto.Site)
        {
            RawState = dto.State?.Trim() ?? "",
            LogPath = dto.Log,
            Sites = sites,
        };
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

    public static CheckLevel ParseLevel(string? value) => value?.Trim().ToLowerInvariant() switch
    {
        "ok" => CheckLevel.Ok,
        "warn" => CheckLevel.Warn,
        "fail" => CheckLevel.Fail,
        _ => CheckLevel.Unknown,
    };

    /// <summary><c>doctor --json</c>. <c>level</c> and <c>fix_command</c>, with the 0.2.0 names as the fallback.</summary>
    public static DoctorReport ParseDoctor(string json)
    {
        var dto = JsonSerializer.Deserialize(json, BenchJsonContext.Default.DoctorDto)
                  ?? throw new JsonException("doctor: empty document");
        var checks = new List<DoctorCheck>();
        foreach (var c in dto.Checks ?? [])
        {
            var fix = string.IsNullOrWhiteSpace(c.FixCommand) ? c.Fix : c.FixCommand;
            checks.Add(new DoctorCheck(
                c.Id ?? "",
                c.Group ?? "",
                c.Label ?? c.Id ?? "",
                ParseLevel(c.Level ?? c.Status),
                c.Message ?? "",
                string.IsNullOrWhiteSpace(fix) ? null : fix));
        }
        var summary = dto.Summary;
        return new DoctorReport(
            dto.Bench,
            dto.Profile,
            checks,
            summary?.Ok ?? checks.Count(c => c.Level == CheckLevel.Ok),
            summary?.Warn ?? checks.Count(c => c.Level == CheckLevel.Warn),
            summary?.Fail ?? checks.Count(c => c.Level == CheckLevel.Fail));
    }

    /// <summary><c>logs --json</c>: the lines and the file they came from.</summary>
    public static LogTail ParseLogs(string json)
    {
        var dto = JsonSerializer.Deserialize(json, BenchJsonContext.Default.LogsDto)
                  ?? throw new JsonException("logs: empty document");
        return new LogTail(dto.File, (dto.Lines ?? []).Select(l => l ?? "").ToList());
    }

    /// <summary><c>report --json</c>: the zip's path, a path inside the distro.</summary>
    public static string ParseReport(string json)
    {
        var dto = JsonSerializer.Deserialize(json, BenchJsonContext.Default.ReportDto)
                  ?? throw new JsonException("report: empty document");
        return string.IsNullOrWhiteSpace(dto.Zip) ? throw new JsonException("report: no zip path") : dto.Zip;
    }
}
