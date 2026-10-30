using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>Whether BenchBar may move a bench's ports (<c>ports mode</c>).</summary>
public enum PortMode { Automatic, Fixed }

public static class PortModes
{
    public static string Title(PortMode mode) => mode == PortMode.Fixed ? "Fixed" : "Automatic";

    public static string Word(PortMode mode) => mode == PortMode.Fixed ? "fixed" : "automatic";

    public static PortMode Parse(string? value) => string.Equals(value?.Trim(), "fixed", StringComparison.OrdinalIgnoreCase) ? PortMode.Fixed : PortMode.Automatic;
}

/// <summary>The ports of a bench in the <c>ports plan</c> entries.</summary>
public sealed record BenchPorts(int Web, int Socketio, int RedisQueue, int RedisCache);

/// <summary><c>ports check --json --bench-dir PATH</c>: <c>conflicts</c>, <c>mode</c> and whether this bench's own processes already run.</summary>
public sealed record PortCheck(IReadOnlyList<string> Conflicts, PortMode Mode, bool? AlreadyRunning);

/// <summary>One bench of <c>ports plan --json</c>.</summary>
public sealed record PortPlanEntry(string Path, string Name, string Site, PortMode Mode, BenchPorts Current, BenchPorts Proposed,
    IReadOnlyList<string> Conflicts, string? Blocked, bool ServiceInstalled, string? SetupPlan)
{
    public string CurrentUrl => $"http://{Site}:{Current.Web}";

    public string ProposedUrl => $"http://{Site}:{Proposed.Web}";

    public bool ChangesPorts => Current != Proposed;

    /// <summary>Something to set up: no service yet, a conflict, or new ports. A managed bench on its own ports has none, running or not.</summary>
    public bool NeedsSetup => !ServiceInstalled || Conflicts.Count > 0 || ChangesPorts;
}

/// <summary><c>ports plan --json -- PATH...</c>: one token covers the whole allocation.</summary>
public sealed record PortPlanDocument(string Token, IReadOnlyList<PortPlanEntry> Entries, bool CanApply);

public static class PortsJson
{
    public static PortCheck ParseCheck(JsonObject o)
    {
        if (o["conflicts"] is not JsonArray) throw new FormatException("ports check: the document has no conflicts");
        return new PortCheck(JsonRead.Strings(o, "conflicts"), PortModes.Parse(JsonRead.Str(o, "mode")),
            o["already_running"] is JsonValue v && v.TryGetValue<bool>(out var running) ? running : null);
    }

    public static PortPlanDocument ParsePlan(JsonObject o)
    {
        if (o["entries"] is not JsonArray array) throw new FormatException("ports plan: the document has no entries");
        var entries = new List<PortPlanEntry>();
        foreach (var e in array.OfType<JsonObject>())
        {
            var path = JsonRead.Str(e, "path");
            if (string.IsNullOrEmpty(path)) continue;
            entries.Add(new PortPlanEntry(path, JsonRead.Str(e, "name") ?? System.IO.Path.GetFileName(path.TrimEnd('/')), JsonRead.Str(e, "site") ?? "localhost",
                PortModes.Parse(JsonRead.Str(e, "mode")), Ports(e["current"] as JsonObject), Ports(e["proposed"] as JsonObject),
                JsonRead.Strings(e, "conflicts"), JsonRead.Str(e, "blocked") is { Length: > 0 } b ? b : null, JsonRead.Bool(e, "service_installed"),
                JsonRead.Str(e, "setup_plan")));
        }
        return new PortPlanDocument(JsonRead.Str(o, "token") ?? "", entries, JsonRead.Bool(o, "can_apply"));
    }

    private static BenchPorts Ports(JsonObject? o) => o is null
        ? new BenchPorts(0, 0, 0, 0)
        : new BenchPorts(JsonRead.Int(o, "web") ?? 0, JsonRead.Int(o, "socketio") ?? 0, JsonRead.Int(o, "redis_queue") ?? 0, JsonRead.Int(o, "redis_cache") ?? 0);
}

/// <summary>The exact arguments of the port calls.</summary>
public static class PortArgs
{
    public static string[] Check(string benchPath) => ["ports", "check", "--json", "--bench-dir", benchPath];

    public static string[] Mode(PortMode mode, string benchPath) => ["ports", "mode", PortModes.Word(mode), "--bench-dir", benchPath];

    public static string[] Plan(IReadOnlyList<string> paths) => ["ports", "plan", "--json", "--", .. paths];

    public static string[] Apply(string token, IReadOnlyList<string> paths) => ["ports", "apply", token, "--yes", "--", .. paths];

    public static string[] Start(string benchPath) => ["up", "--bench-dir", benchPath];
}

/// <summary>What the setup output says (macos PortSetupHints). Ports setup never asks for a password: on Linux it runs nothing as root.</summary>
public static class PortSetupHints
{
    /// <summary>The last three <c>[FAIL]</c> lines of the output, or null when it has none.</summary>
    public static string? Failures(IEnumerable<string> lines)
    {
        var fails = lines.Select(l => l.Trim()).Where(l => l.StartsWith("[FAIL]", StringComparison.Ordinal)).TakeLast(3).ToList();
        return fails.Count == 0 ? null : string.Join(Environment.NewLine, fails);
    }
}

/// <summary>The answer to "may this bench start or restart": the ports are checked first, and a conflict refuses.</summary>
public sealed record PortGuardResult(bool Allowed, bool Conflict, string? Refusal, PortCheck? Check);

public enum PortGuardAction { Start, Restart }

public static class PortGuard
{
    public const string ConflictLead = "Port conflict. Review the proposed resolution before starting.";

    /// <summary>
    /// <c>ports check --json --bench-dir PATH</c> before a start or restart (macos BenchStore.run). A start of a bench whose own processes
    /// already run is let through (<c>up</c> is a no-op then). A conflict refuses, and the person reviews the resolution; nothing is killed.
    /// A check that cannot run refuses too, with the reason.
    /// </summary>
    public static async Task<PortGuardResult> CheckAsync(ICliClient cli, string benchPath, PortGuardAction action, CancellationToken ct = default)
    {
        var result = await cli.RunJsonAsync(PortArgs.Check(benchPath), null, CliTimeouts.Read, PortsJson.ParseCheck, ct).ConfigureAwait(false);
        if (result.Value is not { } check)
            return new PortGuardResult(false, false, "The ports could not be checked: " + (result.Error ?? "no answer from benchbar.exe."), null);
        var alreadyRunning = action == PortGuardAction.Start && check.AlreadyRunning == true;
        var conflict = check.Conflicts.Count > 0 && !alreadyRunning;
        return conflict
            ? new PortGuardResult(false, true, ConflictLead + "\n" + string.Join("\n", check.Conflicts), check)
            : new PortGuardResult(true, false, null, check);
    }
}
