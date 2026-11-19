using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>
/// The Sharing tab of one bench (macos ShareStore): the CLI is the source of truth, so this reads <c>share status</c>, <c>share people</c> and
/// <c>share users</c> and runs the room commands, and keeps nothing else. The room code and the invite are held in memory only, until the
/// room ends. Every call that a person must decide (start, code, invite, stop, remove) is made from a click the view
/// confirmed; none runs by itself. <see cref="Changed"/> is raised on the thread that awaited (the UI thread in the app).
/// </summary>
public sealed class ShareModel(ICliClient cli, string benchPath, TimeProvider? time = null)
{
    public static readonly TimeSpan MinimumInterval = TimeSpan.FromSeconds(8);

    private readonly TimeProvider _time = time ?? TimeProvider.System;
    private long? _lastRefresh;
    private bool _refreshing;
    private bool _errorIsFromRead;

    public event Action? Changed;

    public string BenchPath { get; } = benchPath;

    public ShareStatus? Status { get; private set; }

    public IReadOnlyList<SharePerson> People { get; private set; } = [];

    /// <summary>The room code, in memory only. Null until the host asked for it, and again once the room is off.</summary>
    public ShareCode? Code { get; private set; }

    /// <summary>What a running call is doing ("Starting sharing..."); a second action waits until it is null.</summary>
    public string? Busy { get; private set; }

    /// <summary>The CLI's own sentence for the last failure, shown above the tab; cleared by the next action.</summary>
    public string? LastError { get; private set; }

    public bool InviteCopied { get; private set; }

    public string? RemovedName { get; private set; }

    // --- the exact calls ---

    /// <summary>The calls a person makes from the app that the CLI refuses without a terminal: the click was the person's decision.</summary>
    public static SecretEnvironment PersonEnvironment() => new SecretEnvironment().Set(SetupEnv.NonInteractive, "0").Set(SetupEnv.Sudo, "gui");

    private string[] Bench(params string[] args) => [.. args, "--bench-dir", BenchPath];

    public string[] StatusArgs() => Bench("share", "status", "--preflight", "--json");

    public string[] PeopleArgs() => Bench("share", "people", "--json");

    public string[] CodeArgs(bool fresh) => Bench(["share", "code", .. fresh ? new[] { "--new" } : [], "--json"]);

    public string[] InviteArgs() => Bench("share", "invite", "--json");

    public string[] StartArgs(int hours) => Bench("share", "start", "--for", $"{hours}h", "--json");

    public string[] StopArgs() => Bench("share", "stop", "--json");

    public string[] ExtendArgs(int minutes) => Bench("share", "extend", "--by", $"{minutes}m", "--json");

    public string[] LockArgs(bool locked) => Bench("share", locked ? "lock" : "unlock", "--json");

    public string[] RemoveArgs(string person) => Bench("share", "remove", person, "--yes", "--json");

    // --- reading ---

    /// <summary>Status (with the checks), and the people while the room is on. Calls closer together than <see cref="MinimumInterval"/> are skipped unless forced.</summary>
    public async Task RefreshAsync(bool force = false, CancellationToken ct = default)
    {
        if (_refreshing) return;
        var now = _time.GetTimestamp();
        if (!force && _lastRefresh is { } last && _time.GetElapsedTime(last, now) < MinimumInterval) return;
        _refreshing = true;
        try
        {
            var status = await cli.RunJsonAsync(StatusArgs(), null, CliTimeouts.Read, ShareStatus.Parse, ct).ConfigureAwait(true);
            _lastRefresh = _time.GetTimestamp();
            if (status.Value is { } fresh)
            {
                Status = fresh;
                if (_errorIsFromRead) LastError = null; // a failed action's sentence stays until the next action
                _errorIsFromRead = false;
                if (!fresh.IsLive) { Code = null; People = []; }
            }
            else
            {
                LastError = status.Error ?? "Sharing could not be read.";
                _errorIsFromRead = true;
            }
            if (Status is { IsLive: true })
            {
                var people = await cli.RunJsonAsync(PeopleArgs(), null, CliTimeouts.Read, ShareJson.People, ct).ConfigureAwait(true);
                if (people.Value is { } list) People = list;
            }
        }
        finally
        {
            _refreshing = false;
            Raise();
        }
    }

    // --- the code and the invite: the only documents that hold it ---

    /// <summary>Reads the code into memory. A failure says only that it failed: stdout is never repeated.</summary>
    public async Task<bool> LoadCodeAsync(bool fresh = false, CancellationToken ct = default)
    {
        if (!Begin(fresh ? "Drawing a new code..." : "Reading the room code...")) return false;
        try
        {
            var result = await cli.RunJsonAsync(CodeArgs(fresh), PersonEnvironment(), CliTimeouts.Read,
                o => JsonRead.Str(o, "code") is { Length: > 0 } code ? new ShareCode(code, JsonRead.Int(o, "budget_left")) : throw new FormatException("share code"), ct).ConfigureAwait(true);
            if (result.Value is { } code) { Code = code; RemovedName = null; return true; }
            LastError = result.Error is { } e && !e.Contains("share code", StringComparison.Ordinal) ? e : "The room code could not be read.";
            return false;
        }
        finally { End(); }
    }

    /// <summary>The invite text for the clipboard: the click on Copy invite is the only way it leaves this call. Null when it could not be read.</summary>
    public async Task<ShareInvite?> ReadInviteAsync(CancellationToken ct = default)
    {
        if (!Begin("Making the invite...")) return null;
        try
        {
            var result = await cli.RunJsonAsync(InviteArgs(), PersonEnvironment(), CliTimeouts.Read,
                o => JsonRead.Str(o, "text") is { Length: > 0 } text ? new ShareInvite(text) : throw new FormatException("share invite"), ct).ConfigureAwait(true);
            if (result.Value is { } invite) { InviteCopied = true; return invite; }
            LastError = result.Error is { } e && !e.Contains("share invite", StringComparison.Ordinal) ? e : "The invite could not be made.";
            return null;
        }
        finally { End(); }
    }

    // --- room commands ---

    public Task<bool> StartAsync(int hours, CancellationToken ct = default) => RunAsync("Starting sharing...", StartArgs(hours), PersonEnvironment(), CliTimeouts.Apply, ct);

    public async Task<bool> StopAsync(CancellationToken ct = default)
    {
        var ok = await RunAsync("Stopping sharing...", StopArgs(), null, CliTimeouts.Apply, ct).ConfigureAwait(true);
        if (ok) Code = null;
        return ok;
    }

    public Task<bool> ExtendAsync(int minutes, CancellationToken ct = default) => RunAsync("Extending...", ExtendArgs(minutes), null, CliTimeouts.Plan, ct);

    public Task<bool> SetLockedAsync(bool locked, CancellationToken ct = default) => RunAsync(locked ? "Locking the room..." : "Unlocking the room...", LockArgs(locked), null, CliTimeouts.Plan, ct);

    public async Task<bool> RemoveAsync(SharePerson person, CancellationToken ct = default)
    {
        var ok = await RunAsync($"Removing {person.Name}...", RemoveArgs(person.Id), null, CliTimeouts.Plan, ct).ConfigureAwait(true);
        if (ok)
        {
            RemovedName = person.Name;
            Raise();
        }
        return ok;
    }

    private async Task<bool> RunAsync(string busy, string[] args, SecretEnvironment? env, TimeSpan timeout, CancellationToken ct)
    {
        if (!Begin(busy)) return false;
        try
        {
            var result = await cli.RunStreamAsync(args, env, timeout, _ => { }, ct).ConfigureAwait(true);
            if (!result.Ok) LastError = result.Cancelled ? "Stopped." : result.Problem ?? $"The command failed (exit {result.Exit}).";
            return result.Ok;
        }
        finally
        {
            End();
            await RefreshAsync(true, CancellationToken.None).ConfigureAwait(true);
        }
    }

    private bool Begin(string busy)
    {
        if (Busy is not null) return false;
        Busy = busy;
        LastError = null;
        _errorIsFromRead = false;
        InviteCopied = false;
        Raise();
        return true;
    }

    private void End()
    {
        Busy = null;
        Raise();
    }

    private void Raise() => Changed?.Invoke();
}
