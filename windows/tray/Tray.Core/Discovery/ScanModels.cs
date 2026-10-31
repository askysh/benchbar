using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>The four ports of a bench (<c>ports</c> of a <c>list</c> or <c>scan</c> entry).</summary>
public sealed record FoundPorts(int Web, int SocketIo, int RedisQueue, int RedisCache)
{
    public IReadOnlyList<int> All => [Web, SocketIo, RedisQueue, RedisCache];
}

/// <summary>One bench of <c>scan --json</c> or <c>list --json</c> (<c>benches[]</c>), as docs/json-schema.md describes it.</summary>
public sealed record FoundBench(string Path, string Name, string Site, string? WebUrl, FoundPorts Ports, bool ServiceInstalled, bool IsDefault);

/// <summary>The document of <c>scan FOLDER --json</c>: the canonical root, the benches, and the folders that were skipped.</summary>
public sealed record ScanResult(string Root, IReadOnlyList<FoundBench> Benches, IReadOnlyList<string> Warnings);

/// <summary>What the pane says about a found bench.</summary>
public enum FoundState
{
    /// <summary>BenchBar runs it as a service: nothing to add or set up.</summary>
    Managed,

    /// <summary>Remembered (<c>register</c>), but without a service: it needs Set Up Management.</summary>
    AddedNeedsSetup,

    /// <summary>Found in the folder, not known to BenchBar.</summary>
    NotAdopted,
}

/// <summary>Reads the documents of <c>scan</c>, <c>list</c> and <c>register</c> (the last returns the <c>list</c> document).</summary>
public static class ScanJson
{
    public static ScanResult ParseScan(JsonObject o)
    {
        if (o["benches"] is not JsonArray)
            throw new FormatException("The scan did not list any benches array.");
        return new ScanResult(JsonRead.Str(o, "root") ?? "", ParseBenches(o), JsonRead.Strings(o, "warnings"));
    }

    /// <summary>The benches of a <c>list --json</c> (or <c>register --json</c>) document.</summary>
    public static IReadOnlyList<FoundBench> ParseList(JsonObject o)
    {
        if (o["benches"] is not JsonArray)
            throw new FormatException("The list did not contain a benches array.");
        return ParseBenches(o);
    }

    private static List<FoundBench> ParseBenches(JsonObject o)
    {
        var benches = new List<FoundBench>();
        foreach (var b in ((JsonArray)o["benches"]!).OfType<JsonObject>())
        {
            var path = JsonRead.Str(b, "path");
            if (string.IsNullOrEmpty(path)) continue;
            var ports = b["ports"] as JsonObject;
            benches.Add(new FoundBench(
                path,
                JsonRead.Str(b, "name") ?? path.TrimEnd('/').Split('/').Last(),
                JsonRead.Str(b, "site") ?? "",
                JsonRead.Str(b, "web_url"),
                new FoundPorts(
                    ports is null ? 0 : JsonRead.Int(ports, "web") ?? 0,
                    ports is null ? 0 : JsonRead.Int(ports, "socketio") ?? 0,
                    ports is null ? 0 : JsonRead.Int(ports, "redis_queue") ?? 0,
                    ports is null ? 0 : JsonRead.Int(ports, "redis_cache") ?? 0),
                JsonRead.Bool(b, "service_installed"),
                JsonRead.Bool(b, "default")));
        }
        return benches;
    }

    /// <summary>
    /// The scan's warnings as the pane lists them (macos BenchDiscovery.warningLines): every "Stopped at N folders deep: PATH" in one
    /// line (a scan of the home folder has hundreds), then the others as they are.
    /// </summary>
    public static IReadOnlyList<string> WarningLines(IReadOnlyList<string> warnings)
    {
        const string prefix = "Stopped at ";
        var deep = warnings.Where(w => w.StartsWith(prefix, StringComparison.Ordinal) && w.Contains(" folders deep: ", StringComparison.Ordinal)).ToList();
        var others = warnings.Where(w => !deep.Contains(w)).ToList();
        if (deep.Count == 0) return others;
        var depth = new string(deep[0][prefix.Length..].TakeWhile(char.IsAsciiDigit).ToArray());
        var summary = deep.Count == 1
            ? deep[0]
            : $"Stopped at {depth} folders deep in {deep.Count} folders: a bench deeper than that is not found. Choose a folder closer to it.";
        return [summary, .. others];
    }

    /// <summary>"1 scan warning" or "N scan warnings".</summary>
    public static string WarningsTitle(int count) => count == 1 ? "1 scan warning" : $"{count} scan warnings";
}
