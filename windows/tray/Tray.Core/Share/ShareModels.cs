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

/// <summary><c>share status [--preflight] --json</c>. It never carries the code.</summary>
public sealed record ShareStatus(int Protocol, ShareState State, string? Site, string ShareSite, string? Label, string? LanIp, int? Port, int SecondsLeft,
    int CanExtendSeconds, ShareCopy? Copy, IReadOnlyList<string> AllowedUsers, int Seats, int People, int DevicesOnline, bool? Locked, string? LockReason,
    int? BudgetLeft, bool JoinTrouble, int WipeFailed, LanGuardState LanGuard, IReadOnlyList<ShareCheck> Checks, bool SetupInterrupted,
    string? Degraded, string? Error)
{
    /// <summary>The room model (rooms, codes, seats) is protocol 3.</summary>
    public const int RoomProtocol = 3;

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
        JsonRead.Bool(o, "setup_interrupted"), JsonRead.Str(o, "degraded"), JsonRead.Str(o, "error"));
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
                JsonRead.Str(p, "name") ?? JsonRead.Str(p, "id")!, JsonRead.Str(p, "model"), JsonRead.Str(p, "ip"), JsonRead.Str(p, "seat_id"),
                JsonRead.Str(p, "seat_full_name"), JsonRead.Bool(p, "online"), JsonRead.Str(p, "last_seen")))]
            : [];
}
