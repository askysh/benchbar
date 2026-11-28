using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace BenchBar.Tray.Core;

/// <summary>
/// The guest side of the Sharing tab (macos: the join sheet and the list of joined rooms): this computer in somebody else's room. The CLI
/// does the protocol; this runs <c>share join</c>, <c>joined</c>, <c>leave</c> and <c>forget</c> through the shim and keeps what a person
/// needs to decide. A room needs no bench, so none of the calls has <c>--bench-dir</c>.
/// <para>
/// The room code is typed by the person and goes to the CLI as the first line of its standard input, never as an argument, a variable, a
/// file or a log line. It is held as a <see cref="Secret"/> for the one call and disposed when the call ends, whatever its result; no record
/// of this model holds it, and nothing here is serialised. The address of a room is typed too, so it is checked before it can be an argument.
/// </para>
/// </summary>
public sealed partial class ShareGuestModel(ICliClient cli, CommandSupport? commands = null, TimeProvider? clock = null)
{
    /// <summary>How long what was asked about the CLI (its version, its lab) is kept before a look at the tab asks again.</summary>
    public static readonly TimeSpan Recheck = TimeSpan.FromMinutes(1);

    private readonly TimeProvider _time = clock ?? TimeProvider.System;

    /// <summary>The CLI waits up to 10 minutes for a seat the host gives; the call is not cut short before that.</summary>
    public static readonly TimeSpan JoinTimeout = TimeSpan.FromMinutes(12);

    private CancellationTokenSource? _joinCts;

    /// <summary>The last join or open of each room that was waiting for a seat: <c>share joined</c> does not carry who gives the seats or the free ones, <c>share join</c> does.</summary>
    private readonly Dictionary<string, GuestRoom> _waiting = [];
    private bool _refreshing;
    private string? _catalogueVersion;

    public event Action? Changed;

    /// <summary>The CLI lists <c>share join</c>: false (and the feature hidden) until it was asked, and for a CLI that has none.</summary>
    public bool Supported { get; private set; }

    public IReadOnlyList<GuestRoom> Rooms { get; private set; } = [];

    /// <summary>What the person looked at: the room, its address and the host's key. A join goes to exactly this room.</summary>
    public ShareLook? Look { get; private set; }

    /// <summary>What a running call is doing ("Joining..."); a second action waits until it is null.</summary>
    public string? Busy { get; private set; }

    /// <summary>A join is running, so a Cancel is offered: it ends the wait for a seat, and the place in the room stays.</summary>
    public bool CanCancel => _joinCts is not null;

    /// <summary>The CLI's own sentence for the last failure, cleared by the next action.</summary>
    public string? LastError { get; private set; }

    /// <summary>The last thing that worked ("Left Test Room."), cleared by the next action.</summary>
    public string? Notice { get; private set; }

    // --- the exact calls ---

    public static string[] JoinedArgs() => ["share", "joined", "--json"];

    public static string[] LookArgs(string target) => ["share", "join", target, "--dry-run", "--json"];

    /// <summary>The join. Without <paramref name="wait"/> the CLI ends when the host has not given a seat yet; without a seat id and where guests
    /// pick, it ends with the free seats. <c>--no-open</c>: the CLI never opens a browser for a run with <c>--json</c>, and the tray opens the address itself.</summary>
    public static string[] JoinArgs(string target, string? seat = null, bool wait = true, string? hostPin = null) =>
        ["share", "join", target, .. hostPin is null ? [] : new[] { "--host-key", hostPin }, .. seat is null ? [] : new[] { "--seat", seat }, .. wait ? [] : new[] { "--no-wait" }, "--no-open", "--json"];

    /// <summary>The CLI ends a join with this code when the host shows another key than <c>--host-key</c>, before any request.</summary>
    public const int HostKeyMismatchExit = 3;

    public static string[] LeaveArgs(string id) => ["share", "leave", id, "--json"];

    public static string[] ForgetArgs(string id) => ["share", "forget", id, "--json"];

    /// <summary>The calls a person makes that the CLI refuses without a terminal: the click on the sheet was the person's decision.</summary>
    private static SecretEnvironment Person() => ShareModel.PersonEnvironment();

    [GeneratedRegex("^[0-9a-f]{16}$")]
    private static partial Regex RoomId();

    [GeneratedRegex("^[A-Za-z0-9_-]{1,64}$")]
    private static partial Regex SeatId();

    // --- reading ---

    /// <summary>
    /// Whether this CLI can join a room. The catalogue of the tray is read once per run of the tray, not at every look at the tab, and it is read
    /// again only when it cannot be right: it was printed while the lan-rooms lab was off (the commands of a lab that is off are left out, and
    /// this tab exists only while the lab is on), or the CLI's version moved on since (a <c>share joined</c> document says it, see
    /// <see cref="RefreshAsync"/>). Both questions are asked once for a catalogue: the answer, also "cannot" and "no labs field", is kept for
    /// <see cref="Recheck"/>, and it is asked again after that (the CLI may have been updated, the lab turned on) or for another catalogue.
    /// </summary>
    public async Task CheckSupportAsync(CancellationToken ct = default)
    {
        var known = commands is null ? await ReadCatalogueAsync(ct).ConfigureAwait(true) : await commands.GetAsync().ConfigureAwait(true);
        if (known is not null && (!ReferenceEquals(known, _settled) || _time.GetElapsedTime(_settledAt) >= Recheck))
        {
            // A CLI that prints no labs field does not leave the commands of a lab out, so a second read would say the same.
            if (commands is not null && known.HasLabsField && !known.Labs.Contains(LabName)) known = await commands.RefreshAsync().ConfigureAwait(true);
            // A CLI that cannot pin gets no look at <c>share joined</c>, whose documents would tell that it was updated: ask its version (any document
            // has it) once, and read the catalogue again when it is not the one the catalogue came from. A version that cannot be read is an answer too.
            if (known is not null && !CanPin(known) && await ProbeVersionAsync(ct).ConfigureAwait(true) is { } version && version != known.CliVersion)
                known = commands is null ? await ReadCatalogueAsync(ct).ConfigureAwait(true) : await commands.RefreshAsync().ConfigureAwait(true);
            _settled = known;
            _settledAt = _time.GetTimestamp();
        }
        Use(known);
        Raise();
    }

    /// <summary>The catalogue whose lab and version were asked about, so a look at the tab with the same catalogue asks nothing.</summary>
    private CommandCatalogue? _settled;
    private long _settledAt;

    private const string LabName = "lan-rooms";

    private async Task<CommandCatalogue?> ReadCatalogueAsync(CancellationToken ct) =>
        (await cli.RunJsonAsync(CommandCatalogue.Args, null, CliTimeouts.Read, CommandCatalogue.Parse, ct).ConfigureAwait(true)).Value;

    private async Task<string?> ProbeVersionAsync(CancellationToken ct)
    {
        var where = await cli.RunJsonAsync(WhereArgs, null, CliTimeouts.Read, ct).ConfigureAwait(true);
        return where.Ok ? JsonRead.Str(where.Value!, "cli_version") : null;
    }

    private static readonly string[] WhereArgs = ["where", "--json"];

    private void Use(CommandCatalogue? catalogue)
    {
        Supported = CanPin(catalogue);
        _catalogueVersion = catalogue?.CliVersion;
    }

    /// <summary>
    /// The CLI joins and can pin the join to the key that was looked at (<c>--host-key</c>). A CLI that has <c>share join</c> without the flag is
    /// treated as one that has no join: the code is never sent to a room the person did not pin.
    /// </summary>
    private static bool CanPin(CommandCatalogue? catalogue) => catalogue?.Has("share join") == true && catalogue.HasFlag("share join", "--host-key");

    /// <summary>
    /// <c>share joined --json</c>: the rooms this computer joined. It dials no room, so it is cheap and asked on every look at the tab. The view
    /// asks only when <see cref="Supported"/>.
    /// </summary>
    public async Task RefreshAsync(CancellationToken ct = default)
    {
        if (_refreshing) return;
        _refreshing = true;
        try
        {
            var result = await cli.RunJsonAsync(JoinedArgs(), null, CliTimeouts.Read, ct).ConfigureAwait(true);
            if (result.Ok)
            {
                Rooms = [.. ShareGuestJson.Rooms(result.Value!).Select(WithSeats)];
                // every document carries the CLI's version: a version other than the one the catalogue was read from means the CLI was updated, so what it can do is asked again
                if (JsonRead.Str(result.Value!, "cli_version") is { Length: > 0 } version && _catalogueVersion is not null && version != _catalogueVersion)
                {
                    Use(commands is null ? await ReadCatalogueAsync(ct).ConfigureAwait(true) : await commands.RefreshAsync().ConfigureAwait(true));
                    if (!Supported) Rooms = [];
                }
            }
            else LastError ??= Refusal(result, UiText.Get("GuestJoinedUnreadable")); // the sentence of the action that came first stays
        }
        finally
        {
            _refreshing = false;
            Raise();
        }
    }

    private GuestRoom WithSeats(GuestRoom room) =>
        room.State == GuestState.Waiting && _waiting.TryGetValue(room.Id, out var known) ? room with { HostAssigns = known.HostAssigns, Seats = known.Seats } : room;

    private void Remember(GuestRoom room)
    {
        if (room.State == GuestState.Waiting) _waiting[room.Id] = room;
        else _waiting.Remove(room.Id);
    }

    // --- the look, then the join ---

    /// <summary>
    /// <c>share join ADDRESS --dry-run --json</c>: nothing that depends on the code is sent and nothing is saved. False, with
    /// <see cref="LastError"/>, when the address is not an address (it is never passed on then) or the CLI refused.
    /// </summary>
    public async Task<bool> LookAsync(string typedAddress, CancellationToken ct = default)
    {
        if (!Begin(UiText.Get("GuestBusyLooking"))) return false;
        try
        {
            Look = null;
            if (ShareGuestText.Address(typedAddress) is not { } address)
            {
                LastError = UiText.Get("GuestAddressInvalid");
                return false;
            }
            var result = await cli.RunJsonAsync(LookArgs(address.Contains(':') ? address : $"{address}:{ShareGuestText.DefaultPort}"), Person(), CliTimeouts.Read, ct).ConfigureAwait(true);
            if (!result.Ok)
            {
                LastError = Refusal(result, UiText.Get("GuestLookFailed"));
                return false;
            }
            try
            {
                Look = ShareGuestJson.Look(result.Value!);
            }
            catch (FormatException)
            {
                LastError = UiText.Get("GuestLookUnreadable");
                return false;
            }
            return true;
        }
        catch (OperationCanceledException)
        {
            LastError = UiText.Get("GuestStopped");
            return false;
        }
        finally { End(); }
    }

    /// <summary>Forgets the look (the person changed the address, or cancelled the sheet).</summary>
    public void ClearLook()
    {
        Look = null;
        LastError = null;
        Raise();
    }

    /// <summary>
    /// Joins the room that was looked at. <paramref name="code"/> is the six digits typed (spaces allowed); it is not needed when this computer is
    /// in the room already. Where the host gives out the seats the CLI waits for one (up to 10 minutes) and <see cref="CancelJoin"/> ends the wait;
    /// <paramref name="seat"/> is for a room where guests pick theirs. The code is disposed when the call ends.
    /// </summary>
    public async Task<bool> JoinAsync(Secret? code, string? seat = null, CancellationToken ct = default)
    {
        using var typed = code;
        if (Look is not { } look)
        {
            LastError = UiText.Get("GuestLookFirst");
            Raise();
            return false;
        }
        if (NotJoinable(look) is { } closed)
        {
            LastError = closed;
            Raise();
            return false;
        }
        if (seat is not null && !SeatId().IsMatch(seat))
        {
            LastError = UiText.Get("GuestSeatInvalid");
            Raise();
            return false;
        }
        Secret? line = null;
        if (!look.Paired)
        {
            var digits = typed is null ? null : ShareGuestText.CodeDigits(typed.Reveal());
            if (digits is null)
            {
                LastError = UiText.Get("GuestCodeInvalid");
                Raise();
                return false;
            }
            line = Secret.From(digits);
        }
        using (line)
        {
            if (!Begin(look.Paired ? UiText.Get("GuestBusyOpening") : UiText.Get("GuestBusyJoining"))) return false;
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            _joinCts = cts;
            Raise(); // the Cancel button is drawn from CanCancel
            try
            {
                var result = await cli.RunJsonAsync(JoinArgs(look.Target, seat, hostPin: look.HostPin), Person().Stdin(line), JoinTimeout, cts.Token).ConfigureAwait(true);
                if (!result.Ok)
                {
                    if (result.Exit == HostKeyMismatchExit)
                    {
                        // the host shows another key than the one looked at: nothing was sent; the person looks again and compares the digits
                        LastError = UiText.Format("GuestKeyMismatch", look.Host);
                        Look = null;
                    }
                    else LastError = Refusal(result, UiText.Get("GuestJoinFailed"));
                    return false;
                }
                GuestJoin joined;
                try
                {
                    joined = ShareGuestJson.Join(result.Value!);
                }
                catch (FormatException)
                {
                    LastError = UiText.Get("GuestJoinUnreadable");
                    return false;
                }
                Remember(joined.Room);
                Notice = joined.Room.State switch
                {
                    GuestState.Ready => UiText.Format("GuestJoinedReady", joined.Room.Room, joined.Room.Seat ?? ""),
                    GuestState.Waiting when joined.Room.HostAssigns == false => UiText.Format("GuestJoinedPick", joined.Room.Room),
                    GuestState.Waiting => UiText.Format("GuestJoinedWaiting", joined.Room.Room, joined.Room.Host),
                    _ => UiText.Format("GuestJoinedOther", joined.Room.Room, StateText(joined.Room)),
                };
                Look = null;
                return true;
            }
            catch (OperationCanceledException)
            {
                LastError = UiText.Get("GuestStopped"); // the place in the room stays: the list shows the room as waiting
                return false;
            }
            finally
            {
                _joinCts = null;
                End();
                await RefreshAsync(CancellationToken.None).ConfigureAwait(true);
            }
        }
    }

    /// <summary>Ends a join that is waiting for a seat. The call is killed with its children; the host keeps this computer's place for a few minutes.</summary>
    public void CancelJoin() => _joinCts?.Cancel();

    /// <summary>Why this room cannot be joined right now (the host locked it, or every seat is taken), else null. A computer in the room already is not turned away.</summary>
    public static string? NotJoinable(ShareLook look) =>
        look.Paired ? null : look.Locked ? UiText.Format("GuestLocked", look.Host) : look.Full ? UiText.Format("GuestFull", look.Host) : null;

    // --- the rooms joined ---

    /// <summary>
    /// The address to open in the browser for <paramref name="room"/>, or null with <see cref="LastError"/>. A room whose local address is closed is
    /// opened again first (<c>share join ADDRESS</c> needs no code once this computer is in the room). Only an http address on a <c>.localhost</c>
    /// name of this computer is ever returned: what the CLI printed is not trusted to name any other place.
    /// </summary>
    public async Task<string?> OpenUrlAsync(GuestRoom room, CancellationToken ct = default)
    {
        var url = room.CanOpen ? room.Url : null;
        if (url is null)
        {
            if (!Begin(UiText.Get("GuestBusyOpening"))) return null;
            try
            {
                var result = await cli.RunJsonAsync(JoinArgs(room.Target, null, wait: false), Person(), CliTimeouts.Plan, ct).ConfigureAwait(true);
                if (!result.Ok)
                {
                    LastError = Refusal(result, UiText.Get("GuestOpenFailed"));
                    return null;
                }
                var again = ShareGuestJson.Room(result.Value!);
                Remember(again);
                url = again.CanOpen ? again.Url : null;
                if (url is null)
                {
                    var why = UiText.Format("GuestNotOpen", room.Room, StateText(again));
                    if (again.State == GuestState.Waiting) Notice = why; // not a failure: the seat is still to come
                    else LastError = why;
                }
            }
            catch (OperationCanceledException)
            {
                LastError = UiText.Get("GuestStopped");
            }
            catch (FormatException)
            {
                LastError = UiText.Get("GuestJoinUnreadable");
            }
            finally
            {
                End();
                await RefreshAsync(CancellationToken.None).ConfigureAwait(true);
            }
            if (url is null) return null;
        }
        if (!IsLocalAddress(url))
        {
            LastError = UiText.Get("GuestAddressNotLocal");
            Raise();
            return null;
        }
        return url;
    }

    /// <summary>A room where guests pick their seat: takes the seat <paramref name="seatId"/> (no code: this computer is in the room).</summary>
    public async Task<bool> TakeSeatAsync(GuestRoom room, string seatId, CancellationToken ct = default)
    {
        if (!SeatId().IsMatch(seatId))
        {
            LastError = UiText.Get("GuestSeatInvalid");
            Raise();
            return false;
        }
        if (!Begin(UiText.Get("GuestBusySeat"))) return false;
        try
        {
            var result = await cli.RunJsonAsync(JoinArgs(room.Target, seatId, wait: false), Person(), CliTimeouts.Plan, ct).ConfigureAwait(true);
            if (!result.Ok)
            {
                LastError = Refusal(result, UiText.Get("GuestSeatFailed"));
                return false;
            }
            var taken = ShareGuestJson.Room(result.Value!);
            Remember(taken);
            Notice = UiText.Format("GuestSeatTaken", room.Room, taken.Seat ?? seatId);
            return true;
        }
        catch (OperationCanceledException)
        {
            LastError = UiText.Get("GuestStopped");
            return false;
        }
        catch (FormatException)
        {
            LastError = UiText.Get("GuestJoinUnreadable");
            return false;
        }
        finally
        {
            End();
            await RefreshAsync(CancellationToken.None).ConfigureAwait(true);
        }
    }

    /// <summary>Tells the host and closes the local address. The room and this computer's key for it stay in the list.</summary>
    public Task<bool> LeaveAsync(GuestRoom room, CancellationToken ct = default) =>
        EndAsync(room, UiText.Get("GuestBusyLeaving"), LeaveArgs(room.Id), UiText.Format("GuestLeft", room.Room), ct);

    /// <summary>Leaves, and deletes the room and this computer's key: to the host a later join is a new computer. The view asks first.</summary>
    public Task<bool> ForgetAsync(GuestRoom room, CancellationToken ct = default) =>
        EndAsync(room, UiText.Get("GuestBusyForgetting"), ForgetArgs(room.Id), UiText.Format("GuestForgot", room.Room), ct);

    private async Task<bool> EndAsync(GuestRoom room, string busy, string[] args, string done, CancellationToken ct)
    {
        if (!RoomId().IsMatch(room.Id))
        {
            LastError = UiText.Get("GuestRoomInvalid");
            Raise();
            return false;
        }
        if (!Begin(busy)) return false;
        try
        {
            var result = await cli.RunJsonAsync(args, Person(), CliTimeouts.Plan, ct).ConfigureAwait(true);
            if (!result.Ok)
            {
                LastError = Refusal(result, UiText.Get("GuestLeaveFailed"));
                return false;
            }
            _waiting.Remove(room.Id);
            var note = done;
            if (result.Value is { } doc)
            {
                if (doc["told_host"] is JsonValue t && t.TryGetValue<bool>(out var told) && !told) note += " " + UiText.Format("GuestHostNotTold", room.Host);
                // forwarder_stopped (since the review fixes of #344): false means the process of the local address did not end with the command
                if (doc["forwarder_stopped"] is JsonValue f && f.TryGetValue<bool>(out var stopped) && !stopped) note += " " + UiText.Format("GuestForwarderOpen", room.Room);
            }
            Notice = note;
            return true;
        }
        catch (OperationCanceledException)
        {
            LastError = UiText.Get("GuestStopped");
            return false;
        }
        finally
        {
            End();
            await RefreshAsync(CancellationToken.None).ConfigureAwait(true);
        }
    }

    // --- words ---

    /// <summary>What a room's state means for this computer, in a sentence.</summary>
    public static string StateText(GuestRoom room) => room.State switch
    {
        GuestState.Ready => UiText.Format("GuestStateReady", room.Seat ?? ""),
        GuestState.Waiting when room.HostAssigns == false => UiText.Get("GuestStatePick"),
        GuestState.Waiting when room.HostAssigns == true => UiText.Format("GuestStateWaiting", room.Host),
        GuestState.Waiting => UiText.Get("GuestStateWaitingAny"),
        GuestState.Removed => UiText.Format("GuestStateRemoved", room.Host),
        GuestState.NewRoom => UiText.Format("GuestStateNewRoom", room.Host),
        GuestState.Ended => UiText.Format("GuestStateEnded", room.Host),
        GuestState.IdentityChanged => UiText.Get("GuestStateIdentity"),
        GuestState.Offline => UiText.Format("GuestStateOffline", room.Host),
        GuestState.Closed => UiText.Get("GuestStateClosed"),
        _ => UiText.Get("GuestStateUnknown"),
    };

    /// <summary>The address of a room's local forwarder: http, on a <c>.localhost</c> name, which the browser sends to this computer.</summary>
    public static bool IsLocalAddress(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttp && uri.Host.EndsWith(".localhost", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// The CLI's sentence for a call that did not work (its <c>error</c> or the <c>[FAIL]</c> line of stderr). Any other line of stderr is shown
    /// after the generic sentence, with the exit code, as one line of plain text (<see cref="ShareGuestText.Detail"/>): it is what the shim or WSL
    /// said ("WSL is not installed", "not found"), unless it is a line of the room's own block, which is the host's text and is never the reason.
    /// </summary>
    private static string Refusal(CliResult<JsonObject> result, string generic)
    {
        if (result.Ok) return generic;
        // A sentence is the CLI's when it comes in its document, or from a stderr line that starts with the tag. Any other first line of a refused
        // join is the room's own text (its name, chosen by the host) or something that is not the CLI's.
        var tagged = result.Value is not null || result.Done is not null || result.Error?.TrimStart().StartsWith("[FAIL]", StringComparison.Ordinal) == true;
        if (tagged && ShareGuestText.Sentence(result.Error) is { Length: > 0 } sentence) return sentence;
        return ShareGuestText.Detail(result.Error) is { Length: > 0 } line ? UiText.Format("GuestFailedWith", generic, line, result.Exit) : generic;
    }

    private bool Begin(string busy)
    {
        if (Busy is not null) return false;
        Busy = busy;
        LastError = null;
        Notice = null;
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
