namespace BenchBar.Tray.Core;

/// <summary>The one button of the Sharing tab, from the status alone (macos SharePrimary).</summary>
public enum SharePrimary { SetUp, FinishSetup, TurnOnProtection, Start, Stop, UpdateCli }

/// <summary>Every word the host side shows, from macos SharePresentation (this computer for this Mac). Pure, so it is tested without a window.</summary>
public static class ShareText
{
    public static readonly IReadOnlyList<int> Hours = [1, 2, 4, 8, 12];
    public const string LabOff = "Sharing is an experiment. Turn on \"Share with people on the same Wi-Fi\" in Labs to use it.";
    public const string NewerCli = "Sharing needs a newer BenchBar command line tool.";
    public const string SetUpIntro = "Share a copy of this site with people on the same Wi-Fi. Setup makes the copy; nothing is shared until you press Start sharing.";
    public const string LiveUpdates = "Guests see changes after a page refresh.";
    public const string CodeNote = "Anyone on this Wi-Fi with the code can join. Remove people anytime.";
    public const string CodeProves = "The code proves someone may join; it does not prove to them that this computer is the host.";
    public const string InviteCopied = "Invite copied. Paste it in your team channel. New code or Stop makes it stop working.";
    public const string CopyInviteHelp = "Copies a message with a link that joins this room in one click, code included.";
    public const string Locked = "Room locked: nobody new can join.";
    public const string Full = "Room full: every seat is taken.";
    public const string BudgetLocked = "Too many wrong codes; the room is locked. New code to reopen.";
    public const string JoinTrouble = "Someone is having trouble joining. Check the code.";
    public const string WipeOwed = "A sign-out is still owed in the copy. BenchBar retries it on the next room action.";
    public const string SetupInterrupted = "Sharing setup was interrupted, so Start does not work yet. Choose Finish setup to refresh the copy (the command line: benchbar share setup --refresh).";
    public const string DriftWarning = "Your apps changed since the copy was made. Guests see the copy's code, not your working tree; Refresh copy to catch up.";
    public const string RefreshConfirm = "Replaces the copy. Anything guests changed in it is lost.";
    public const string Acknowledgement = "This copy contains real customer and employee data that your colleagues will be able to read.";
    public const string RemoveDetail = "They can't join again with the current code. Everyone else stays. To let them back in, copy a new invite and send it to them.";
    public const string CheckedAtStart = "Checked when sharing starts";
    public const string LanGuardAsk = "Network protection changes the firewall rules that keep the bench's ports closed to other computers while sharing. It asks for your password, and only after you confirm here.";
    public const string LanGuardAllowAsk = "This lets sharing through the firewall. It asks for your password, and only after you confirm here.";
    public const string PeopleTitle = "People in the room";
    public const string LanGuardUnavailable = "Network protection is not available on Windows yet, so sharing cannot start here.";
    public const string RootPasswordAdvice = "The tray cannot ask for it. In a terminal, run `benchbar mariadb-password` to read the one BenchBar saved, or run the same command there with MARIADB_ROOT_PASSWORD set.";

    /// <summary>Whether the CLI's LAN guard runs on this platform: the pf anchor is macOS only, and the nftables guard for Linux (so WSL) is not written yet.</summary>
    public const bool LanGuardSupportedHere = false;

    /// <summary>
    /// What to add to a failed run that exited 2 because the MariaDB root password is unknown (<c>share setup</c> stops there). The CLI's own sentence
    /// stays first; the advice is added only when that sentence does not already say how to pass the password.
    /// </summary>
    public static string? RootPasswordHelp(CliStreamResult result)
    {
        if (result.Ok || result.Cancelled || result.Exit != 2 || result.Problem is not { } problem) return null;
        if (!problem.Contains("root password", StringComparison.OrdinalIgnoreCase) || problem.Contains("MARIADB_ROOT_PASSWORD", StringComparison.Ordinal)) return null;
        return RootPasswordAdvice;
    }

    /// <summary>Checks that probe the gateway or the share web process: while sharing is off there is nothing to probe, so they wait for the start.</summary>
    public static readonly IReadOnlySet<string> ChecksOfTheRunningShare = new HashSet<string> { "gateway_reachable", "share_web_lan_closed", "share_traceback_off", "share_debugger_off" };

    public static bool WaitsForStart(ShareCheck check, ShareStatus status) => !status.IsOn && ChecksOfTheRunningShare.Contains(check.Id);

    /// <summary>Start is allowed with no red check (a missing check list counts as not red), leaving out the checks of the running share.</summary>
    public static bool CanStart(ShareStatus status) => !status.Checks.Any(c => c.Status == ShareCheckStatus.Fail && !WaitsForStart(c, status));

    public static SharePrimary Primary(ShareStatus status)
    {
        if (status.NeedsNewerCli) return SharePrimary.UpdateCli;
        if (status.IsLive) return SharePrimary.Stop;
        if (status.SetupInterrupted) return SharePrimary.FinishSetup;
        if (status.Copy is null) return SharePrimary.SetUp;
        return status.LanGuard != LanGuardState.Installed ? SharePrimary.TurnOnProtection : SharePrimary.Start;
    }

    public static string Title(SharePrimary primary) => primary switch
    {
        SharePrimary.SetUp => "Set up sharing",
        SharePrimary.FinishSetup => "Finish setup",
        SharePrimary.TurnOnProtection => "Turn on network protection",
        SharePrimary.Start => "Start sharing",
        SharePrimary.Stop => "Stop",
        _ => "Update",
    };

    /// <summary>3540 s is "59 min", 7260 is "2 h 1 min", 30 is "less than a minute".</summary>
    public static string Countdown(int seconds)
    {
        if (seconds < 60) return "less than a minute";
        int hours = seconds / 3600, minutes = seconds % 3600 / 60;
        if (hours == 0) return $"{minutes} min";
        return minutes == 0 ? $"{hours} h" : $"{hours} h {minutes} min";
    }

    public static string Indicator(ShareStatus status) => $"Sharing on your network · {status.DevicesOnline} online · {Countdown(status.SecondsLeft)} left";

    /// <summary>Extend choices in minutes, none past what the CLI allows.</summary>
    public static IReadOnlyList<(string Label, int Minutes)> ExtendOptions(int canExtendSeconds) =>
        [.. new[] { ("+30 min", 30), ("+1 hour", 60) }.Where(o => o.Item2 * 60 <= canExtendSeconds)];

    public static string StopConfirm(int online) => online switch
    {
        0 => "Stop sharing?",
        1 => "Stop sharing? 1 person is connected and will be signed out.",
        _ => $"Stop sharing? {online} people are connected and will be signed out.",
    };

    public static string StartConfirm(string site) => $"Start sharing {site} on this network? People on this Wi-Fi who have the room code can join a copy of {site} until you stop.";

    // --- who gives out the seats (#159 SHARE-5) ---

    public const string AssignSeatsToggle = "I give out the seats";

    public static string StartConfirm(string site, bool assignSeats) =>
        StartConfirm(site) + (assignSeats ? " They wait until you give each of them a seat." : " Each of them can take any free seat.");

    public static string SeatModeLine(bool hostGivesSeats) => hostGivesSeats
        ? "You give out the seats: a guest who joins waits until you give them one."
        : "Guests pick their own seat: the room code lets them take any free one.";

    public static string SeatCaption(SharePerson person, bool hostGivesSeats) =>
        person.SeatName ?? (hostGivesSeats ? "Waits for a seat from you" : "No seat yet");

    /// <summary>The line above the people while somebody waits for the host; null when nobody does.</summary>
    public static string? WaitingNotice(IReadOnlyList<SharePerson> people, bool hostGivesSeats)
    {
        var waiting = people.Count(p => p.SeatId is null);
        if (!hostGivesSeats || waiting == 0) return null;
        return waiting == 1 ? "1 person waits for a seat. Pick a seat under their name, then Give." : $"{waiting} people wait for a seat. Pick a seat under each name, then Give.";
    }

    /// <summary>A seat with its roles, so the host sees what it may do before giving it.</summary>
    public static string SeatTitle(ShareSeat seat) => seat.Roles.Count switch
    {
        0 => seat.Name,
        <= 3 => $"{seat.Name} · {string.Join(", ", seat.Roles)}",
        _ => $"{seat.Name} · {string.Join(", ", seat.Roles.Take(3))} and {seat.Roles.Count - 3} more",
    };

    /// <summary>The seats a person can be given: the ones nobody in the room holds, by name.</summary>
    public static IReadOnlyList<ShareSeat> FreeSeats(IReadOnlyList<ShareSeat> seats, IReadOnlyList<SharePerson> people)
    {
        var held = people.Where(p => p.SeatId is not null).Select(p => p.SeatId!).ToHashSet(StringComparer.Ordinal);
        return [.. seats.Where(s => s.HeldBy is null && !held.Contains(s.Id)).OrderBy(s => s.Name, StringComparer.OrdinalIgnoreCase)];
    }

    public static string AssignButton(SharePerson person) => person.SeatId is null ? $"Give {person.Name} this seat" : $"Move {person.Name} to this seat";

    public static string RemoveConfirm(SharePerson person, string site) => $"Remove {person.Name}? Closes their connections and signs them out of {site}.";

    public static string ProtectionText(LanGuardState state) => state switch
    {
        LanGuardState.Installed => "Network protection is on.",
        LanGuardState.Outdated => "Network protection needs an update.",
        _ => "Network protection is off. It keeps the bench's own ports closed to the network.",
    };

    public static string? FixLabel(ShareFixAction action) => action switch
    {
        ShareFixAction.InstallNetworkProtection => "Turn on network protection",
        ShareFixAction.AllowNodeFirewall => "Allow...",
        ShareFixAction.UpdateCli => "Update",
        ShareFixAction.RerunSetup => "Set up again",
        ShareFixAction.RefreshCopy => "Refresh copy",
        ShareFixAction.RestartSharing => "Start again",
        _ => null, // open_local_network_settings is a macOS panel: no button here, the CLI's own message stays
    };

    /// <summary>A check's own words where the app has them; the CLI's id as words otherwise.</summary>
    public static string CheckTitle(ShareCheck check) => check.Id switch
    {
        "pf_active" => "Network protection",
        "firewall_node" => "The firewall lets sharing through",
        "bench_redis_up" => "The bench is running",
        "lan_ip" => "This computer has a network address",
        "gateway_reachable" => "The gateway answers on the network",
        "share_traceback_off" => "Error traces are hidden in the copy",
        "share_debugger_off" => "The debugger is off in the copy",
        "copy_present" => "The shared copy is there",
        "share_web_lan_closed" => "The copy is reachable only through BenchBar",
        _ => check.Message.Length > 0 ? check.Message : System.Globalization.CultureInfo.InvariantCulture.TextInfo.ToTitleCase(check.Id.Replace('_', ' ')),
    };

    public static string CheckStatus(ShareCheckStatus status) => status switch
    {
        ShareCheckStatus.Ok => "Passed",
        ShareCheckStatus.Fail => "Failed",
        ShareCheckStatus.Skip => "Skipped",
        _ => "Warning",
    };

    /// <summary>The room's state line: the budget lock wins over a host lock or full.</summary>
    public static string? LockLine(ShareStatus status)
    {
        if (status.LockReason == "budget" || status.BudgetLeft == 0) return BudgetLocked;
        if (status.LockReason == "full") return Full;
        return status.Locked == true ? Locked : null;
    }

    public static string CopyLine(ShareCopy copy) =>
        $"Copy made {(copy.AgeSeconds is { } age ? Countdown(age) + " ago" : "earlier")} from {copy.SourceSite ?? "your site"}. Guests' changes stay in the copy.";

    /// <summary>"Sam · MacBook Air · 192.168.1.31": name and model tell two Sams apart.</summary>
    public static string PersonLine(SharePerson person) => string.Join(" · ", new[] { person.Name, person.Model, person.Ip }.Where(s => !string.IsNullOrEmpty(s)));

    /// <summary>Online first, then the most recently seen (the CLI's timestamps sort as text).</summary>
    public static IReadOnlyList<SharePerson> Sorted(IEnumerable<SharePerson> people) =>
        [.. people.OrderByDescending(p => p.Online).ThenByDescending(p => p.LastSeen ?? "", StringComparer.Ordinal)];

    public static string RemovedNotice(string name) => $"{name} was removed. To let them back in, send a new invite.";

    public static string NeedsDisk(double gb) => $"Needs about {gb.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture)} GB free";

    /// <summary>What the copy holds, one line: "User 5, Customer 3", or none.</summary>
    public static string DataClasses(IReadOnlyDictionary<string, int> classes) =>
        classes.Count == 0 ? "none counted" : string.Join(", ", classes.OrderBy(c => c.Key, StringComparer.Ordinal).Select(c => $"{c.Key} {c.Value}"));
}
