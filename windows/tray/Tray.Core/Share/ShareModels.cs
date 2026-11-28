using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

// The host side of a room, as `benchbar.exe share ... --json` prints it (macos Share/ShareModels.swift). Every field past the few a
// share always has is read leniently: an older CLI that lacks one gives a default, never a failure. Only ShareCode and ShareInvite
// can hold the room code, and neither prints it from ToString or goes through a record's generated members.

public enum ShareState { Off, Starting, On, Expired, Error }

public enum LanGuardState { Installed, Missing, Outdated }

public enum ShareCheckStatus { Ok, Warn, Fail, Skip }

/// <summary>What a check's button does. A value this build does not know is <see cref="None"/>: the row then has no button.</summary>
public enum ShareFixAction { None, InstallNetworkProtection, AllowNodeFirewall, OpenLocalNetworkSettings, RefreshCopy, RerunSetup, RestartSharing, UpdateCli }

public sealed record ShareCheck(string Id, ShareCheckStatus Status, string Message, ShareFixAction Fix);

public sealed record ShareCopy(string? SourceSite, int? AgeSeconds, bool Drifted);

public sealed record SharePerson(string Id, string Name, string? Model, string? Ip, string? SeatId, string? SeatName, bool Online, string? LastSeen);

/// <summary>A seat of the room (<c>seats</c> of <c>share people --json</c>): held by the person <see cref="HeldBy"/> names, or free.</summary>
public sealed record ShareSeat(string Id, string Name, IReadOnlyList<string> Roles, string? HeldBy);

/// <summary><c>share people --json</c>: the people, every seat of the room, and whether the host gives out the seats
/// (<c>seat_mode</c> is <c>host</c>). A CLI before 0.9.0 sends no seats and no mode: an open room with nothing to give.</summary>
public sealed record ShareRoom(IReadOnlyList<SharePerson> People, IReadOnlyList<ShareSeat> Seats, bool HostGivesSeats);

public sealed record ShareUser(string Name, string FullName, IReadOnlyList<string> Roles, IReadOnlyList<string> CodeCapableRoles, bool Selectable);

/// <summary><c>share setup --dry-run --json</c>: what the copy will be, shown before anything is made.</summary>
public sealed record ShareSetupPlan(string Site, double SizeGb, int EstMinutes, int? SourceAgeSeconds, IReadOnlyDictionary<string, int> DataClasses);

/// <summary><c>share status [--preflight] --json</c>. It never carries the code.</summary>
public sealed record ShareStatus(int Protocol, ShareState State, string? Site, string ShareSite, string? Label, string? LanIp, int? Port, int SecondsLeft,
    int CanExtendSeconds, ShareCopy? Copy, IReadOnlyList<string> AllowedUsers, int Seats, int People, int DevicesOnline, bool? Locked, string? LockReason,
    int? BudgetLeft, bool JoinTrouble, int WipeFailed, LanGuardState LanGuard, IReadOnlyList<ShareCheck> Checks, bool SetupInterrupted,
    string? Degraded, string? Error)
{
    /// <summary>The room model (rooms, codes, seats) is protocol 3.</summary>
    public const int RoomProtocol = 3;

    /// <summary>The first 16 hex digits of this host's key (<c>host_key</c>): what a guest's join sheet shows for an invite. Null from a CLI before 0.9.0.</summary>
    public string? HostKey { get; init; }
    /// <summary>The status has <c>seat_mode</c> (null with no room): this CLI takes <c>--assign-seats</c> and <c>--open-seats</c>.
    /// The CLI inside WSL can be older than the tray; one before 0.9.0 has neither the key nor the flags.</summary>
    public bool KnowsSeatMode { get; init; }

    public bool IsOn => State == ShareState.On;

    /// <summary>On or on its way up: turning the lab off ends both.</summary>
    public bool IsLive => State is ShareState.On or ShareState.Starting;

    public bool NeedsNewerCli => Protocol < RoomProtocol;

    public static ShareStatus Parse(JsonObject o) => new(
        JsonRead.Int(o, "protocol") ?? 1, ShareJson.State(JsonRead.Str(o, "state")), JsonRead.Str(o, "site"), JsonRead.Str(o, "share_site") ?? "share.localhost",
        JsonRead.Str(o, "label"), JsonRead.Str(o, "lan_ip"), JsonRead.Int(o, "port"), JsonRead.Int(o, "seconds_left") ?? 0, JsonRead.Int(o, "can_extend_s") ?? 0,
        o["copy"] is JsonObject c ? new ShareCopy(JsonRead.Str(c, "source_site"), JsonRead.Int(c, "age_s"), JsonRead.Bool(c, "drifted")) : null,
        JsonRead.Strings(o, "allowed_users"), JsonRead.Int(o, "seats") ?? 0, JsonRead.Int(o, "people") ?? 0, JsonRead.Int(o, "devices_online") ?? 0,
        o["locked"] is JsonValue l && l.TryGetValue<bool>(out var locked) ? locked : null, JsonRead.Str(o, "lock_reason"), JsonRead.Int(o, "budget_left"),
        JsonRead.Bool(o, "join_trouble"), JsonRead.Int(o, "wipe_failed") ?? 0, ShareJson.Guard(JsonRead.Str(o, "lan_guard")),
        o["preflight"] is JsonObject p && p["checks"] is JsonArray checks ? [.. checks.OfType<JsonObject>().Select(ShareJson.Check)] : [],
        JsonRead.Bool(o, "setup_interrupted"), JsonRead.Str(o, "degraded"), JsonRead.Str(o, "error"))
    { HostKey = JsonRead.Str(o, "host_key"), KnowsSeatMode = o.ContainsKey("seat_mode") };
}

/// <summary>
/// The room code, from <c>share code --json</c>, the one document that holds it. Kept in memory by the model, shown only when the host
/// asks, and never logged, stored or printed: <see cref="ToString"/> hides it and nothing else exposes it.
/// </summary>
public sealed class ShareCode(string code, int? budgetLeft)
{
    public string Code { get; } = code;

    public int? BudgetLeft { get; } = budgetLeft;

    /// <summary>"482 913", as the card shows it.</summary>
    public string Spaced => Code.Length == 6 ? $"{Code[..3]} {Code[3..]}" : Code;

    public override string ToString() => "ShareCode(hidden)";
}

/// <summary>The invite message of <c>share invite --json</c>: its text and link hold the code. Read for the clipboard and nothing else.</summary>
public sealed class ShareInvite(string text)
{
    public string Text { get; } = text;

    public override string ToString() => "ShareInvite(hidden)";
}

public static class ShareJson
{
    public static ShareState State(string? raw) => raw switch
    {
        "off" => ShareState.Off,
        "starting" => ShareState.Starting,
        "on" => ShareState.On,
        "expired" => ShareState.Expired,
        _ => ShareState.Error, // a state this build does not know is shown as a problem, not as sharing that is off
    };

    public static LanGuardState Guard(string? raw) => raw switch
    {
        "installed" => LanGuardState.Installed,
        "outdated" => LanGuardState.Outdated,
        _ => LanGuardState.Missing,
    };

    public static ShareCheck Check(JsonObject o) => new(JsonRead.Str(o, "id") ?? "", JsonRead.Str(o, "status") switch
    {
        "ok" => ShareCheckStatus.Ok,
        "fail" => ShareCheckStatus.Fail,
        "skip" => ShareCheckStatus.Skip,
        _ => ShareCheckStatus.Warn,
    }, JsonRead.Str(o, "message") ?? "", JsonRead.Str(o, "fix_action") switch
    {
        "install_network_protection" => ShareFixAction.InstallNetworkProtection,
        "allow_node_firewall" => ShareFixAction.AllowNodeFirewall,
        "open_local_network_settings" => ShareFixAction.OpenLocalNetworkSettings,
        "refresh_copy" => ShareFixAction.RefreshCopy,
        "rerun_setup" => ShareFixAction.RerunSetup,
        "restart_sharing" => ShareFixAction.RestartSharing,
        "update_cli" => ShareFixAction.UpdateCli,
        _ => ShareFixAction.None,
    });

    public static IReadOnlyList<SharePerson> People(JsonObject o) =>
        o["people"] is JsonArray a
            ? [.. a.OfType<JsonObject>().Where(p => JsonRead.Str(p, "id") is { Length: > 0 }).Select(p => new SharePerson(JsonRead.Str(p, "id")!,
                ShareGuestText.Clean(JsonRead.Str(p, "name") ?? JsonRead.Str(p, "id")), NullIfEmpty(JsonRead.Str(p, "model")), JsonRead.Str(p, "ip"), JsonRead.Str(p, "seat_id"),
                NullIfEmpty(JsonRead.Str(p, "seat_full_name")), JsonRead.Bool(p, "online"), JsonRead.Str(p, "last_seen")))]
            : [];

    public static IReadOnlyList<ShareSeat> Seats(JsonObject o) =>
        o["seats"] is JsonArray a
            ? [.. a.OfType<JsonObject>().Where(s => JsonRead.Str(s, "seat_id") is { Length: > 0 }).Select(s => new ShareSeat(JsonRead.Str(s, "seat_id")!,
                ShareGuestText.Clean(JsonRead.Str(s, "full_name") ?? JsonRead.Str(s, "seat_id")), JsonRead.Strings(s, "roles"), JsonRead.Str(s, "held_by")))]
            : [];

    /// <summary>The name, model and seat of a guest are what the guest chose: one line of plain text on the host's screen too.</summary>
    private static string? NullIfEmpty(string? text) => text is null ? null : ShareGuestText.Clean(text) is { Length: > 0 } clean ? clean : null;

    public static ShareRoom Room(JsonObject o) => new(People(o), Seats(o), JsonRead.Str(o, "seat_mode") == "host");

    public static IReadOnlyList<ShareUser> Users(JsonObject o) =>
        o["users"] is JsonArray a
            ? [.. a.OfType<JsonObject>().Where(u => JsonRead.Str(u, "name") is { Length: > 0 }).Select(u =>
            {
                var name = JsonRead.Str(u, "name")!;
                var selectable = u["selectable"] is JsonValue s && s.TryGetValue<bool>(out var pick)
                    ? pick
                    : (u["enabled"] is not JsonValue e || !e.TryGetValue<bool>(out var on) || on) && (JsonRead.Str(u, "user_type") ?? "System User") == "System User";
                return new ShareUser(name, JsonRead.Str(u, "full_name") ?? name, JsonRead.Strings(u, "roles"), JsonRead.Strings(u, "code_capable_roles"), selectable);
            })]
            : [];

    public static ShareSetupPlan SetupPlan(JsonObject o)
    {
        var classes = new Dictionary<string, int>();
        if (o["data_classes"] is JsonObject d)
            foreach (var (key, value) in d)
                if (value is JsonValue v && v.TryGetValue<int>(out var n)) classes[key] = n;
        double size = o["size_gb"] is JsonValue g && g.TryGetValue<double>(out var gb) ? gb : 0;
        return new ShareSetupPlan(JsonRead.Str(o, "site") ?? "", size, JsonRead.Int(o, "est_minutes") ?? 0, JsonRead.Int(o, "source_age_s"), classes);
    }
}
