using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>One flag of a command in <c>commands --json</c>.</summary>
public sealed record CommandFlag(string Name, string? Value, string Help);

/// <summary>One entry of <c>commands --json</c>: a command or a command and subcommand (<c>"lock write"</c>).</summary>
public sealed record CommandInfo(string Name, string Usage, string Summary, bool Mutating, IReadOnlyList<CommandFlag> Flags);

/// <summary>
/// What this CLI can do, read from <c>commands --json</c>. The tray offers a command only when the CLI it talks to lists it (and the flag
/// it needs), so an older CLI inside the distro never gets a call it would refuse.
/// </summary>
public sealed class CommandCatalogue
{
    public static string[] Args { get; } = ["commands", "--json"];

    private readonly Dictionary<string, CommandInfo> _byName;

    public CommandCatalogue(IReadOnlyList<CommandInfo> commands, string? cliVersion)
    {
        Commands = commands;
        CliVersion = cliVersion;
        _byName = commands.GroupBy(c => c.Name).ToDictionary(g => g.Key, g => g.First());
    }

    public IReadOnlyList<CommandInfo> Commands { get; }

    public string? CliVersion { get; }

    /// <summary>The labs that were on when the CLI printed this catalogue (<c>labs</c>): the commands of a lab that is off are not in it.</summary>
    public IReadOnlyList<string> Labs { get; init; } = [];

    /// <summary>The CLI lists <paramref name="name"/> ("up", "lock write").</summary>
    public bool Has(string name) => _byName.ContainsKey(name);

    /// <summary>The CLI lists <paramref name="name"/> with the flag <paramref name="flag"/> ("doctor", "--ack").</summary>
    public bool HasFlag(string name, string flag) => _byName.TryGetValue(name, out var c) && c.Flags.Any(f => f.Name == flag);

    public static CommandCatalogue Parse(JsonObject o)
    {
        if (o["commands"] is not JsonArray array) throw new FormatException("commands: the document has no commands");
        var commands = new List<CommandInfo>();
        foreach (var c in array.OfType<JsonObject>())
        {
            var name = JsonRead.Str(c, "name");
            if (string.IsNullOrEmpty(name)) continue;
            var flags = (c["flags"] as JsonArray ?? []).OfType<JsonObject>()
                .Where(f => JsonRead.Str(f, "name") is { Length: > 0 })
                .Select(f => new CommandFlag(JsonRead.Str(f, "name")!, JsonRead.Str(f, "value"), JsonRead.Str(f, "help") ?? "")).ToList();
            commands.Add(new CommandInfo(name, JsonRead.Str(c, "usage") ?? "", JsonRead.Str(c, "summary") ?? "", JsonRead.Bool(c, "mutating"), flags));
        }
        return new CommandCatalogue(commands, JsonRead.Str(o, "cli_version")) { Labs = JsonRead.Strings(o, "labs") };
    }
}

/// <summary>
/// Asks for the catalogue once and keeps it. A failed read is not kept: the next ask tries again, and meanwhile nothing that needs the
/// catalogue is offered. Calls that arrive together share one run.
/// </summary>
public sealed class CommandSupport(ICliClient cli)
{
    private readonly object _gate = new();
    private Task<CommandCatalogue?>? _load;

    /// <summary>The catalogue once it was read, else null. Asks nothing: a page that must not start a call of its own reads this.</summary>
    public CommandCatalogue? Current { get; private set; }

    /// <summary>Asks again, for a catalogue that is known to be out of date (read while a lab was off, or before the CLI was updated). Calls that arrive together share one run.</summary>
    public Task<CommandCatalogue?> RefreshAsync()
    {
        lock (_gate) return _load = LoadAsync();
    }

    /// <summary>The catalogue, or null when the CLI could not be asked (no distro, an older CLI without <c>commands</c>).</summary>
    public Task<CommandCatalogue?> GetAsync()
    {
        lock (_gate) return _load ??= LoadAsync();
    }

    private async Task<CommandCatalogue?> LoadAsync()
    {
        await Task.Yield(); // the caller stores this task first, so a failure below can clear it
        var result = await cli.RunJsonAsync(CommandCatalogue.Args, null, CliTimeouts.Read, CommandCatalogue.Parse).ConfigureAwait(false);
        if (result.Value is null)
        {
            lock (_gate) _load = null;
        }
        else Current = result.Value;
        return result.Value;
    }
}
