using System.Text;
using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

// The guest side of a room, as `benchbar.exe share join|joined|leave|forget ... --json` prints it (docs/json-schema.md, "The guest documents").
// Read leniently, like the host side: a field a CLI does not print gives a default. None of these holds the room code or a key, and the
// address that signs a browser in as the seat (<c>url</c>) is kept out of every text the records print.

/// <summary>Where a joined room is (<c>state</c> of <c>share joined</c>).</summary>
public enum GuestState { Ready, Waiting, Removed, NewRoom, Ended, IdentityChanged, Offline, Closed, Unknown }

/// <summary>A seat of a room where guests pick theirs (<c>seats</c> of <c>share join</c> while <c>state</c> is <c>waiting</c>): free when <see cref="TakenBy"/> is null.</summary>
public sealed record GuestSeat(string Id, string Name, IReadOnlyList<string> Roles, string? TakenBy);

/// <summary>
/// <c>share join --dry-run --json</c>, the look before the code is sent: the room, where it is and the host's key. <see cref="HostKey"/> is
/// the first 16 hex digits of the host's key, the digits <c>share status</c> shows on the host, and <see cref="HostPin"/> the whole hash (64 hex
/// digits, <c>host_pin</c>) that the join is pinned to: the host that shows another key is refused before any request. Nothing here depends on the code.
/// </summary>
public sealed record ShareLook(string HostPin, string HostKey, string Address, int Port, string Room, string Host, bool Locked, bool Full, int People, int Seats, bool Known, bool Paired)
{
    /// <summary>"192.168.1.20:8443": always with the port, so the join goes to the room that was looked at.</summary>
    public string Target => $"{Address}:{Port}";

    /// <summary>"0123 4567 89ab cdef", as the CLI prints it and the host reads it out.</summary>
    public string SpacedKey => ShareGuestText.SpaceKey(HostKey);
}

/// <summary>One room this computer joined (<c>share joined</c>, and what <c>share join</c> ends with).</summary>
public sealed record GuestRoom(string Id, string Room, string Host, string Site, string Address, int Port, string HostKey, bool Forwarding, GuestState State, string? Seat,
    string? Url, bool? HostAssigns, IReadOnlyList<GuestSeat> Seats)
{
    public string Target => $"{Address}:{Port}";

    public string SpacedKey => ShareGuestText.SpaceKey(HostKey);

    /// <summary>The seats nobody holds, for a room where guests pick theirs.</summary>
    public IReadOnlyList<GuestSeat> FreeSeats => [.. Seats.Where(s => s.TakenBy is null)];

    /// <summary>The room is open on this computer: its local address signs a browser in as the seat.</summary>
    public bool CanOpen => State == GuestState.Ready && Url is { Length: > 0 };

    /// <summary>The address signs a browser in as the seat, so it is not printed with the rest.</summary>
    private bool PrintMembers(StringBuilder builder)
    {
        builder.Append("Id = ").Append(Id).Append(", Room = ").Append(Room).Append(", Host = ").Append(Host).Append(", Target = ").Append(Target)
            .Append(", State = ").Append(State).Append(", Seat = ").Append(Seat);
        return true;
    }
}

/// <summary><c>share join --json</c> done: whether this computer joined now (false: it was in the room, no code was used) and the room.</summary>
public sealed record GuestJoin(bool Joined, GuestRoom Room);

public static class ShareGuestJson
{
    public static GuestState State(string? raw) => raw switch
    {
        "ready" => GuestState.Ready,
        "waiting" => GuestState.Waiting,
        "removed" => GuestState.Removed,
        "new_room" => GuestState.NewRoom,
        "ended" => GuestState.Ended,
        "identity_changed" => GuestState.IdentityChanged,
        "offline" => GuestState.Offline,
        "closed" => GuestState.Closed,
        _ => GuestState.Unknown, // "unknown", and a state a newer CLI adds
    };

    /// <summary>The look. A document without the digits of the key or an address is not a look: a join must never go to a room the person did not see.</summary>
    public static ShareLook Look(JsonObject o)
    {
        var key = JsonRead.Str(o, "host_key");
        var pin = JsonRead.Str(o, "host_pin");
        var address = JsonRead.Str(o, "address");
        // without the whole hash there is nothing to pin the join to, so there is no join: the person must not be sent into a room that is not the one looked at
        if (!ShareGuestText.IsKey(key) || !ShareGuestText.IsPin(pin) || !pin!.StartsWith(key!, StringComparison.OrdinalIgnoreCase) || string.IsNullOrEmpty(address) || JsonRead.Int(o, "port") is not { } port)
            throw new FormatException("share join: the look has no host key, host pin or address");
        return new ShareLook(pin.ToLowerInvariant(), key!, address, port, JsonRead.Str(o, "room") ?? "", JsonRead.Str(o, "host") ?? "", JsonRead.Bool(o, "locked"), JsonRead.Bool(o, "full"),
            JsonRead.Int(o, "people") ?? 0, JsonRead.Int(o, "seats") ?? 0, JsonRead.Bool(o, "known"), JsonRead.Bool(o, "paired"));
    }

    public static GuestRoom Room(JsonObject o)
    {
        var id = JsonRead.Str(o, "id");
        if (string.IsNullOrEmpty(id) || JsonRead.Str(o, "address") is not { Length: > 0 } address) throw new FormatException("share joined: a room has no id or address");
        return new GuestRoom(id, JsonRead.Str(o, "room") ?? "", JsonRead.Str(o, "host") ?? "", JsonRead.Str(o, "site") ?? "", address, JsonRead.Int(o, "port") ?? 8443,
            JsonRead.Str(o, "host_key") ?? id, JsonRead.Bool(o, "forwarding"), State(JsonRead.Str(o, "state")), JsonRead.Str(o, "seat"), JsonRead.Str(o, "url"),
            o["host_assigns"] is JsonValue h && h.TryGetValue<bool>(out var assigns) ? assigns : null, Seats(o));
    }

    public static IReadOnlyList<GuestRoom> Rooms(JsonObject o) =>
        o["rooms"] is JsonArray a ? [.. a.OfType<JsonObject>().Where(r => JsonRead.Str(r, "id") is { Length: > 0 }).Select(Room)] : [];

    public static GuestJoin Join(JsonObject o) => new(JsonRead.Bool(o, "joined"), Room(o));

    private static IReadOnlyList<GuestSeat> Seats(JsonObject o) =>
        o["seats"] is JsonArray a
            ? [.. a.OfType<JsonObject>().Where(s => JsonRead.Str(s, "seat_id") is { Length: > 0 }).Select(s => new GuestSeat(JsonRead.Str(s, "seat_id")!,
                JsonRead.Str(s, "full_name") ?? JsonRead.Str(s, "seat_id")!, JsonRead.Strings(s, "roles"), JsonRead.Str(s, "taken_by")))]
            : [];
}

/// <summary>The rules for what a person types, and the words that are not the CLI's.</summary>
public static class ShareGuestText
{
    /// <summary>The port of a room when the address has none.</summary>
    public const int DefaultPort = 8443;

    public static bool IsKey(string? key) => key is { Length: 16 } && key.All(Uri.IsHexDigit);

    /// <summary>The whole hash of the host's key: 64 hex digits.</summary>
    public static bool IsPin(string? pin) => pin is { Length: 64 } && pin.All(Uri.IsHexDigit);

    /// <summary>"0123456789abcdef" is "0123 4567 89ab cdef".</summary>
    public static string SpaceKey(string key) => key.Length == 16 ? $"{key[..4]} {key[4..8]} {key[8..12]} {key[12..]}" : key;

    /// <summary>
    /// The IPv4 address of a room, with <c>:PORT</c> when its port is not 8443, as the CLI takes it. Anything else is null, and is never passed
    /// on: the CLI refuses a word that looks like a room code or an invite link, but only after the word is in the argument list of a
    /// process, where any program of this computer can read it. A letter, a scheme, a space or a query is not an address.
    /// </summary>
    public static string? Address(string? typed)
    {
        var text = typed?.Trim();
        if (string.IsNullOrEmpty(text)) return null;
        var parts = text.Split(':');
        if (parts.Length > 2) return null;
        var octets = parts[0].Split('.');
        if (octets.Length != 4 || octets.Any(o => o.Length is < 1 or > 3 || !o.All(char.IsAsciiDigit) || int.Parse(o, System.Globalization.CultureInfo.InvariantCulture) > 255)) return null;
        if (parts.Length == 2 && (parts[1].Length is < 1 or > 5 || !parts[1].All(char.IsAsciiDigit) || int.Parse(parts[1], System.Globalization.CultureInfo.InvariantCulture) is < 1 or > 65535)) return null;
        return text;
    }

    /// <summary>The six digits of a room code, from what was typed ("482 913"), or null when it is not six digits.</summary>
    public static string? CodeDigits(string typed)
    {
        var digits = new string([.. typed.Where(c => !char.IsWhiteSpace(c))]);
        return digits.Length == 6 && digits.All(char.IsAsciiDigit) ? digits : null;
    }

    /// <summary>The sentence of what the CLI wrote on stderr (<c>  [FAIL] message</c>), without the colour codes and the tag.</summary>
    public static string? Sentence(string? stderr) => OpenAsRules.CliSentence(stderr);
}
