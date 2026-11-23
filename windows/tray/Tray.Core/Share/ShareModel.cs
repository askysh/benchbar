using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>What the setup form asks <c>share setup</c> for.</summary>
public sealed record ShareSetupRequest(string Site, IReadOnlyList<string> Users, bool BackupNow, bool Refresh)
{
    public IReadOnlyList<string> Arguments =>
        ["--site", Site, "--users", string.Join(',', Users), .. BackupNow ? new[] { "--backup-now" } : ["--from", "latest"], .. Refresh ? new[] { "--refresh" } : []];
}

/// <summary>The setup form: the people (seats), the source, and the acknowledgement that the copy holds real data. Run is off until all three are set.</summary>
public sealed class ShareSetupForm(string site)
{
    public string Site { get; } = site;

    public SortedSet<string> Picked { get; } = new(StringComparer.Ordinal);

    public bool BackupNow { get; set; } = true;

    public bool Acknowledged { get; set; }

    public bool CanRun => Picked.Count > 0 && Acknowledged && Site.Length > 0;

    public ShareSetupRequest Request(bool refresh) => new(Site, [.. Picked], BackupNow, refresh);

    public static string SourceLabel(bool backupNow, int? estMinutes, int? backupAgeSeconds) =>
        backupNow ? $"Copy my site as it is now (about {estMinutes ?? 1} min)"
            : backupAgeSeconds is { } age ? $"Use the backup from {ShareText.Countdown(age)} ago" : "Use the newest backup"; // no age until a plan has read the backup
}

/// <summary>
/// The Sharing tab of one bench (macos ShareStore): the CLI is the source of truth, so this reads <c>share status</c>, <c>share people</c> and
/// <c>share users</c> and runs the room commands, and keeps nothing else. The room code and the invite are held in memory only, until the
/// room ends. Every call that a person must decide (setup, start, code, invite, stop, remove, lan-guard) is made from a click the view
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

    /// <summary>
    /// Whether this computer can run <c>lan-guard install</c> and <c>allow-node</c>. The CLI's guard is a pf anchor and a macOS firewall rule, and a bench
    /// on Windows runs in Linux, which has no guard until the nftables one lands. False until then, so the buttons are not drawn and nothing runs.
    /// </summary>
    public bool LanGuardSupported { get; init; } = ShareText.LanGuardSupportedHere;

    public ShareStatus? Status { get; private set; }

    public IReadOnlyList<SharePerson> People { get; private set; } = [];

    /// <summary>Every seat of the room that is on, so a seat can be given before anybody held it.</summary>
    public IReadOnlyList<ShareSeat> Seats { get; private set; } = [];

    /// <summary>The host gives out the seats of the room that is on: a guest who joins waits for <see cref="AssignAsync"/>.</summary>
    public bool HostGivesSeats { get; private set; }

    public IReadOnlyList<ShareUser> Users { get; private set; } = [];

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

    public string[] UsersArgs(string site) => Bench("share", "users", "--site", site, "--json");

    public string[] CodeArgs(bool fresh) => Bench(["share", "code", .. fresh ? new[] { "--new" } : [], "--json"]);

    public string[] InviteArgs() => Bench("share", "invite", "--json");

    /// <summary><paramref name="assignSeats"/>: the host gives out the seats (<c>--assign-seats</c>, the CLI's default since 0.9.0);
    /// false is <c>--open-seats</c>. One of the two is always passed, so the room is what the box said.</summary>
    public string[] StartArgs(int hours, bool assignSeats = true) =>
        Bench("share", "start", "--for", $"{hours}h", assignSeats ? "--assign-seats" : "--open-seats", "--json");

    public string[] StopArgs() => Bench("share", "stop", "--json");

    public string[] ExtendArgs(int minutes) => Bench("share", "extend", "--by", $"{minutes}m", "--json");

    public string[] LockArgs(bool locked) => Bench("share", locked ? "lock" : "unlock", "--json");

    public string[] RemoveArgs(string person) => Bench("share", "remove", person, "--yes", "--json");

    public string[] AssignArgs(string person, string seat) => Bench("share", "assign", person, seat, "--json");

    public string[] SetupPlanArgs(ShareSetupRequest request) => Bench(["share", "setup", .. request.Arguments, "--dry-run", "--json"]);

    /// <summary>
    /// The setup as the plan sheet runs it: <c>--dry-run</c> to review, then <c>--acknowledge-data --yes</c> to make the copy. There is no
    /// token in this plan. The sheet's confirm is the person's, and the summary above it says what the copy holds.
    /// </summary>
    public PlanReviewRequest SetupReview(ShareSetupRequest request, ShareSetupPlan plan) => new(request.Refresh ? "Refresh the shared copy" : "Set up sharing",
        SetupPlanArgs(request), _ => Bench(["share", "setup", .. request.Arguments, "--acknowledge-data", "--yes", "--json"]))
    {
        ConfirmLabel = request.Refresh ? "Refresh copy" : "Make the copy",
        RequiresToken = false,
        ConfigureEnv = env => { foreach (var (name, value) in PersonEnvironment().Materialize()) env.Set(name, value); },
        ExplainFailure = ShareText.RootPasswordHelp,
        Summary = $"Makes a hardened copy of {plan.Site} in share.localhost, about {plan.SizeGb.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture)} GB and {plan.EstMinutes} min. " +
            $"The copy holds: {ShareText.DataClasses(plan.DataClasses)}. {ShareText.Acknowledgement}",
    };

    public static string[] LanGuardInstallArgs() => ["lan-guard", "install", "--yes", "--json"];

    public static string[] LanGuardAllowNodeArgs() => ["lan-guard", "allow-node", "--yes", "--json"];

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
            var result = await cli.RunJsonAsync(StatusArgs(), null, CliTimeouts.Read, ct).ConfigureAwait(true);
            _lastRefresh = _time.GetTimestamp();
            // a refusal (the lab is off: exit 2 and an error, no state) is not a status; only a document that is ok keeps the
            // "needs a newer command line tool" reading when it lacks the protocol fields
            if (result.Value is { } document && (result.Ok || document.ContainsKey("state")))
            {
                var fresh = ShareStatus.Parse(document);
                Status = fresh;
                if (_errorIsFromRead) LastError = null; // a failed action's sentence stays until the next action
                _errorIsFromRead = false;
                if (!fresh.IsLive) { Code = null; People = []; Seats = []; HostGivesSeats = false; }
            }
            else
            {
                LastError = result.Error is { Length: > 0 } e ? e : result.Value is { } refused && JsonRead.Str(refused, "error") is { Length: > 0 } text ? text : "Sharing could not be read.";
                _errorIsFromRead = true;
            }
            if (Status is { IsLive: true })
            {
                var room = await cli.RunJsonAsync(PeopleArgs(), null, CliTimeouts.Read, ShareJson.Room, ct).ConfigureAwait(true);
                if (room.Value is { } read) { People = read.People; Seats = read.Seats; HostGivesSeats = read.HostGivesSeats; }
            }
        }
        finally
        {
            _refreshing = false;
            Raise();
        }
    }

    public async Task LoadUsersAsync(string site, CancellationToken ct = default)
    {
        // read as a document: a refusal (the lab is off, exit 2) shows its error and an empty list, never an empty list alone
        var result = await cli.RunJsonAsync(UsersArgs(site), null, CliTimeouts.Read, ct).ConfigureAwait(true);
        if (result.Ok) Users = ShareJson.Users(result.Value!);
        else
        {
            Users = [];
            LastError = Refusal(result, "The site's users could not be read.");
        }
        Raise();
    }

    /// <summary><c>share setup --dry-run --json</c>: nothing changes. Null with <see cref="LastError"/> set when the CLI refused.</summary>
    public async Task<ShareSetupPlan?> PlanSetupAsync(ShareSetupRequest request, CancellationToken ct = default)
    {
        var result = await cli.RunJsonAsync(SetupPlanArgs(request), PersonEnvironment(), CliTimeouts.Plan, ShareJson.SetupPlan, ct).ConfigureAwait(true);
        LastError = result.Value is null ? result.Error ?? "The setup could not be planned." : null;
        Raise();
        return result.Value;
    }

    // --- the code and the invite: the only documents that hold it ---

    /// <summary>Reads the code into memory. A failure says only that it failed: stdout is never repeated.</summary>
    public async Task<bool> LoadCodeAsync(bool fresh = false, CancellationToken ct = default)
    {
        if (!Begin(fresh ? "Drawing a new code..." : "Reading the room code...")) return false;
        try
        {
            // the document is read as it is: a refusal (exit 2, an error and no code) shows the CLI's sentence, an ok document without a code does not
            var result = await cli.RunJsonAsync(CodeArgs(fresh), PersonEnvironment(), CliTimeouts.Read, ct).ConfigureAwait(true);
            if (result.Ok && JsonRead.Str(result.Value!, "code") is { Length: > 0 } code)
            {
                Code = new ShareCode(code, JsonRead.Int(result.Value!, "budget_left"));
                RemovedName = null;
                return true;
            }
            LastError = Refusal(result, "The room code could not be read.");
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
            var result = await cli.RunJsonAsync(InviteArgs(), PersonEnvironment(), CliTimeouts.Read, ct).ConfigureAwait(true);
            if (result.Ok && JsonRead.Str(result.Value!, "text") is { Length: > 0 } text) { InviteCopied = true; return new ShareInvite(text); }
            LastError = Refusal(result, "The invite could not be made.");
            return null;
        }
        finally { End(); }
    }

    // --- room commands ---

    /// <summary>
    /// The time a change to the room may take: none is cut short. Assign and remove wait for the gateway to end the seat's sessions
    /// (a wipe in the copy), and a kill part way leaves a seat whose sessions are owed; extend rewrites the deadline. The 3 minutes
    /// of a plan are a kill, not a wait.
    /// </summary>
    public static TimeSpan RoomChangeTimeout => CliTimeouts.Apply;

        public Task<bool> StartAsync(int hours, CancellationToken ct = default) => StartAsync(hours, true, ct);

    public Task<bool> StartAsync(int hours, bool assignSeats, CancellationToken ct = default) =>
        RunAsync("Starting sharing...", StartArgs(hours, assignSeats), PersonEnvironment(), CliTimeouts.Apply, ct);

    /// <summary>Gives a person a free seat, or moves them to it (<c>share assign</c>); the old seat's sessions end first.</summary>
    public Task<bool> AssignAsync(SharePerson person, ShareSeat seat, CancellationToken ct = default) =>
        RunAsync($"Giving {person.Name} the seat {seat.Name}...", AssignArgs(person.Id, seat.Id), null, RoomChangeTimeout, ct);

    public async Task<bool> StopAsync(CancellationToken ct = default)
    {
        var ok = await RunAsync("Stopping sharing...", StopArgs(), null, CliTimeouts.Apply, ct).ConfigureAwait(true);
        if (ok) Code = null;
        return ok;
    }

    public Task<bool> ExtendAsync(int minutes, CancellationToken ct = default) => RunAsync("Extending...", ExtendArgs(minutes), null, RoomChangeTimeout, ct);

    public Task<bool> SetLockedAsync(bool locked, CancellationToken ct = default) => RunAsync(locked ? "Locking the room..." : "Unlocking the room...", LockArgs(locked), null, CliTimeouts.Plan, ct);

    public async Task<bool> RemoveAsync(SharePerson person, CancellationToken ct = default)
    {
        var ok = await RunAsync($"Removing {person.Name}...", RemoveArgs(person.Id), null, RoomChangeTimeout, ct).ConfigureAwait(true);
        if (ok)
        {
            RemovedName = person.Name;
            Raise();
        }
        return ok;
    }

    /// <summary>
    /// <c>lan-guard install</c> or <c>allow-node</c>: the view asked first, as the Mac's alert does. Never called by a poll, a link or a refresh.
    /// What the CLI says (including that this platform has no LAN guard yet) is shown as it is.
    /// </summary>
    public Task<bool> RunLanGuardAsync(bool allowNode, CancellationToken ct = default) =>
        !LanGuardSupported ? Refuse(ShareText.LanGuardUnavailable) : RunAsync(allowNode ? "Allowing sharing through the firewall..." : "Turning on network protection...", allowNode ? LanGuardAllowNodeArgs() : LanGuardInstallArgs(),
            PersonEnvironment(), CliTimeouts.Apply, ct);

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

    private Task<bool> Refuse(string sentence)
    {
        LastError = sentence;
        Raise();
        return Task.FromResult(false);
    }

    /// <summary>The CLI's sentence for a call that did not work (its <c>error</c> or stderr), else <paramref name="generic"/>. Never a field of stdout.</summary>
    private static string Refusal<T>(CliResult<T> result, string generic) => !result.Ok && result.Error is { Length: > 0 } error ? error : generic;

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
