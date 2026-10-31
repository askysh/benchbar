using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

public sealed record SetupPortSet(int Web, int SocketIo, int RedisQueue, int RedisCache);

/// <summary>One bench of <c>ports plan --json</c>: where its ports are now, where they would move, what blocks it.</summary>
public sealed record SetupPlanEntry(string Path, string Name, string? Site, string Mode, SetupPortSet? Current, SetupPortSet? Proposed,
    IReadOnlyList<string> Conflicts, string? Blocked, bool ServiceInstalled)
{
    public bool Moves => Current is not null && Proposed is not null && Current != Proposed;
}

/// <summary>The document of <c>ports plan --json -- PATH ...</c>.</summary>
public sealed record SetupPlan(string? Token, bool CanApply, IReadOnlyList<SetupPlanEntry> Entries)
{
    public static SetupPlan Parse(JsonObject o)
    {
        if (o["entries"] is not JsonArray array)
            throw new FormatException("The port plan did not contain an entries array.");
        var entries = new List<SetupPlanEntry>();
        foreach (var e in array.OfType<JsonObject>())
        {
            var path = JsonRead.Str(e, "path");
            if (string.IsNullOrEmpty(path)) continue;
            entries.Add(new SetupPlanEntry(path, JsonRead.Str(e, "name") ?? path, JsonRead.Str(e, "site"), JsonRead.Str(e, "mode") ?? "automatic",
                Ports(e["current"] as JsonObject), Ports(e["proposed"] as JsonObject), JsonRead.Strings(e, "conflicts"),
                JsonRead.Str(e, "blocked"), JsonRead.Bool(e, "service_installed")));
        }
        var canApply = o["can_apply"] is not JsonValue v || !v.TryGetValue<bool>(out var can) || can;
        return new SetupPlan(JsonRead.Str(o, "token"), canApply && entries.All(e => e.Blocked is null), entries);
    }

    private static SetupPortSet? Ports(JsonObject? o) => o is null
        ? null
        : new SetupPortSet(JsonRead.Int(o, "web") ?? 0, JsonRead.Int(o, "socketio") ?? 0, JsonRead.Int(o, "redis_queue") ?? 0, JsonRead.Int(o, "redis_cache") ?? 0);

    /// <summary>The first reason a bench is blocked, for the line under the buttons; null when nothing is.</summary>
    public string? FirstBlock => Entries.FirstOrDefault(e => e.Blocked is not null) is { } blocked ? $"{blocked.Name}: {blocked.Blocked}" : null;

    /// <summary>What the sheet shows above the plan: one line per bench, with its port move and its conflicts.</summary>
    public string Summary()
    {
        var lines = new List<string>();
        foreach (var e in Entries)
        {
            if (e.Moves) lines.Add($"{e.Name}: web port {e.Current!.Web} moves to {e.Proposed!.Web} (mode {e.Mode}).");
            else if (e.Proposed is not null) lines.Add($"{e.Name}: web port {e.Proposed.Web} stays.");
            else lines.Add($"{e.Name}: ports are set when it is set up.");
            foreach (var c in e.Conflicts) lines.Add("   Conflict: " + c);
            if (e.Blocked is not null) lines.Add("   Blocked: " + e.Blocked);
        }
        return string.Join('\n', lines);
    }
}
