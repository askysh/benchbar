namespace BenchBar.Tray.Core;

/// <summary>The one button of the Sharing tab, from the status alone (macos SharePrimary).</summary>
public enum SharePrimary { SetUp, FinishSetup, TurnOnProtection, Start, Stop, UpdateCli }

/// <summary>Every word the host side shows, from macos SharePresentation (this computer for this Mac). Pure, so it is tested without a window.</summary>
public static class ShareText
{
    public static readonly IReadOnlyList<int> Hours = [1, 2, 4, 8, 12];
    public static string LabOff => UiText.Get("ShareLabOff");
    public static string NewerCli => UiText.Get("ShareNewerCli");
    public static string SetUpIntro => UiText.Get("ShareSetUpIntro");
    public static string LiveUpdates => UiText.Get("ShareLiveUpdates");
    public static string CodeNote => UiText.Get("ShareCodeNote");
    public static string CodeProves => UiText.Get("ShareCodeProves");
    public static string InviteCopied => UiText.Get("ShareInviteCopied");
    public static string CopyInviteHelp => UiText.Get("ShareCopyInviteHelp");
    public static string Locked => UiText.Get("ShareLocked");
    public static string Full => UiText.Get("ShareFull");
    public static string BudgetLocked => UiText.Get("ShareBudgetLocked");
    public static string JoinTrouble => UiText.Get("ShareJoinTrouble");
    public static string WipeOwed => UiText.Get("ShareWipeOwed");
    public static string SetupInterrupted => UiText.Get("ShareSetupInterrupted");
    public static string DriftWarning => UiText.Get("ShareDriftWarning");
    public static string RefreshConfirm => UiText.Get("ShareRefreshConfirm");
    public static string Acknowledgement => UiText.Get("ShareAcknowledgement");
    public static string RemoveDetail => UiText.Get("ShareRemoveDetail");
    public static string CheckedAtStart => UiText.Get("ShareCheckedAtStart");
    public static string LanGuardAsk => UiText.Get("ShareLanGuardAsk");
    public static string LanGuardAllowAsk => UiText.Get("ShareLanGuardAllowAsk");
    public static string PeopleTitle => UiText.Get("SharePeopleTitle");
    public static string LanGuardUnavailable => UiText.Get("ShareLanGuardUnavailable");
    public static string RootPasswordAdvice => UiText.Get("ShareRootPasswordAdvice");

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
        SharePrimary.SetUp => UiText.Get("ShareTitleSetUp"),
        SharePrimary.FinishSetup => UiText.Get("ShareTitleFinishSetup"),
        SharePrimary.TurnOnProtection => UiText.Get("ShareTitleTurnOnProtection"),
        SharePrimary.Start => UiText.Get("ShareTitleStart"),
        SharePrimary.Stop => UiText.Get("ShareTitleStop"),
        _ => UiText.Get("ShareTitleUpdate"),
    };

    /// <summary>3540 s is "59 min", 7260 is "2 h 1 min", 30 is "less than a minute".</summary>
    public static string Countdown(int seconds)
    {
        if (seconds < 60) return UiText.Get("ShareCountdownLessThanAMinute");
        int hours = seconds / 3600, minutes = seconds % 3600 / 60;
        if (hours == 0) return UiText.Format("ShareCountdownMinutes", minutes);
        return minutes == 0 ? UiText.Format("ShareCountdownHours", hours) : UiText.Format("ShareCountdownHoursMinutes", hours, minutes);
    }

    public static string Indicator(ShareStatus status) => UiText.Format("ShareIndicator", status.DevicesOnline, Countdown(status.SecondsLeft));

    /// <summary>Extend choices in minutes, none past what the CLI allows.</summary>
    public static IReadOnlyList<(string Label, int Minutes)> ExtendOptions(int canExtendSeconds) =>
        [.. new[] { (UiText.Get("ShareExtend30"), 30), (UiText.Get("ShareExtend60"), 60) }.Where(o => o.Item2 * 60 <= canExtendSeconds)];

    public static string StopConfirm(int online) => online switch
    {
        0 => UiText.Get("ShareStopConfirmNobody"),
        1 => UiText.Get("ShareStopConfirmOne"),
        _ => UiText.Format("ShareStopConfirmMany", online),
    };

    public static string StartConfirm(string site) => UiText.Format("ShareStartConfirm", site);

    // --- the host's key (#159 SHARE-8) ---

    /// <summary>"Host key: 0123 4567 89ab cdef": the digits a guest sees on the join sheet of an invite, for the host to read out.
    /// Null without 16 hex digits.</summary>
    public static string? HostKeyLine(ShareStatus status)
    {
        if (status.HostKey is not { Length: 16 } key || !key.All(Uri.IsHexDigit)) return null;
        return UiText.Format("ShareHostKeyLine", key[..4], key[4..8], key[8..12], key[12..]);
    }

    public static string HostKeyHelp => UiText.Get("ShareHostKeyHelp");

    // --- who gives out the seats (#159 SHARE-5) ---

    public static string AssignSeatsToggle => UiText.Get("ShareAssignSeatsToggle");
    public static string SeatsNeedNewerCli => UiText.Get("ShareSeatsNeedNewerCli");

    public static string StartConfirm(string site, bool assignSeats) =>
        StartConfirm(site) + (assignSeats ? UiText.Get("ShareStartConfirmHostGives") : UiText.Get("ShareStartConfirmOpen"));

    public static string SeatModeLine(bool hostGivesSeats) => hostGivesSeats
        ? UiText.Get("ShareSeatModeHost")
        : UiText.Get("ShareSeatModeOpen");

    public static string SeatCaption(SharePerson person, bool hostGivesSeats) =>
        person.SeatName ?? (hostGivesSeats ? UiText.Get("ShareSeatCaptionHostWaits") : UiText.Get("ShareSeatCaptionNone"));

    /// <summary>The line above the people while somebody waits for the host; null when nobody does.</summary>
    public static string? WaitingNotice(IReadOnlyList<SharePerson> people, bool hostGivesSeats)
    {
        var waiting = people.Count(p => p.SeatId is null);
        if (!hostGivesSeats || waiting == 0) return null;
        return waiting == 1 ? UiText.Get("ShareWaitingOne") : UiText.Format("ShareWaitingMany", waiting);
    }

    /// <summary>A seat with its roles, so the host sees what it may do before giving it.</summary>
    public static string SeatTitle(ShareSeat seat) => seat.Roles.Count switch
    {
        0 => seat.Name,
        <= 3 => UiText.Format("ShareSeatTitleRoles", seat.Name, string.Join(", ", seat.Roles)),
        _ => UiText.Format("ShareSeatTitleMore", seat.Name, string.Join(", ", seat.Roles.Take(3)), seat.Roles.Count - 3),
    };

    /// <summary>The seats a person can be given: the ones nobody in the room holds, by name.</summary>
    public static IReadOnlyList<ShareSeat> FreeSeats(IReadOnlyList<ShareSeat> seats, IReadOnlyList<SharePerson> people)
    {
        var held = people.Where(p => p.SeatId is not null).Select(p => p.SeatId!).ToHashSet(StringComparer.Ordinal);
        return [.. seats.Where(s => s.HeldBy is null && !held.Contains(s.Id)).OrderBy(s => s.Name, StringComparer.OrdinalIgnoreCase)];
    }

    public static string AssignButton(SharePerson person) => person.SeatId is null ? UiText.Format("ShareAssignGive", person.Name) : UiText.Format("ShareAssignMove", person.Name);

    public static string RemoveConfirm(SharePerson person, string site) => UiText.Format("ShareRemoveConfirm", person.Name, site);

    public static string ProtectionText(LanGuardState state) => state switch
    {
        LanGuardState.Installed => UiText.Get("ShareProtectionOn"),
        LanGuardState.Outdated => UiText.Get("ShareProtectionOutdated"),
        _ => UiText.Get("ShareProtectionOff"),
    };

    public static string? FixLabel(ShareFixAction action) => action switch
    {
        ShareFixAction.InstallNetworkProtection => UiText.Get("ShareFixInstall"),
        ShareFixAction.AllowNodeFirewall => UiText.Get("ShareFixAllow"),
        ShareFixAction.UpdateCli => UiText.Get("ShareFixUpdate"),
        ShareFixAction.RerunSetup => UiText.Get("ShareFixRerun"),
        ShareFixAction.RefreshCopy => UiText.Get("ShareFixRefresh"),
        ShareFixAction.RestartSharing => UiText.Get("ShareFixRestart"),
        _ => null, // open_local_network_settings is a macOS panel: no button here, the CLI's own message stays
    };

    /// <summary>A check's own words where the app has them; the CLI's id as words otherwise.</summary>
    public static string CheckTitle(ShareCheck check) => check.Id switch
    {
        "pf_active" => UiText.Get("ShareCheckPfActive"),
        "firewall_node" => UiText.Get("ShareCheckFirewallNode"),
        "bench_redis_up" => UiText.Get("ShareCheckBenchRedis"),
        "lan_ip" => UiText.Get("ShareCheckLanIp"),
        "gateway_reachable" => UiText.Get("ShareCheckGateway"),
        "share_traceback_off" => UiText.Get("ShareCheckTraceback"),
        "share_debugger_off" => UiText.Get("ShareCheckDebugger"),
        "copy_present" => UiText.Get("ShareCheckCopyPresent"),
        "share_web_lan_closed" => UiText.Get("ShareCheckWebClosed"),
        _ => check.Message.Length > 0 ? check.Message : System.Globalization.CultureInfo.InvariantCulture.TextInfo.ToTitleCase(check.Id.Replace('_', ' ')),
    };

    public static string CheckStatus(ShareCheckStatus status) => status switch
    {
        ShareCheckStatus.Ok => UiText.Get("ShareCheckPassed"),
        ShareCheckStatus.Fail => UiText.Get("ShareCheckFailed"),
        ShareCheckStatus.Skip => UiText.Get("ShareCheckSkipped"),
        _ => UiText.Get("ShareCheckWarning"),
    };

    /// <summary>The room's state line: the budget lock wins over a host lock or full.</summary>
    public static string? LockLine(ShareStatus status)
    {
        if (status.LockReason == "budget" || status.BudgetLeft == 0) return BudgetLocked;
        if (status.LockReason == "full") return Full;
        return status.Locked == true ? Locked : null;
    }

    public static string CopyLine(ShareCopy copy) =>
        UiText.Format("ShareCopyLine", copy.AgeSeconds is { } age ? UiText.Format("ShareCopyAgo", Countdown(age)) : UiText.Get("ShareCopyEarlier"), copy.SourceSite ?? UiText.Get("ShareCopyYourSite"));

    /// <summary>"Sam · MacBook Air · 192.168.1.31": name and model tell two Sams apart.</summary>
    public static string PersonLine(SharePerson person) => string.Join(" · ", new[] { person.Name, person.Model, person.Ip }.Where(s => !string.IsNullOrEmpty(s)));

    /// <summary>Online first, then the most recently seen (the CLI's timestamps sort as text).</summary>
    public static IReadOnlyList<SharePerson> Sorted(IEnumerable<SharePerson> people) =>
        [.. people.OrderByDescending(p => p.Online).ThenByDescending(p => p.LastSeen ?? "", StringComparer.Ordinal)];

    public static string RemovedNotice(string name) => UiText.Format("ShareRemovedNotice", name);

    public static string NeedsDisk(double gb) => UiText.Format("ShareNeedsDisk", UiText.OneDecimal(gb));

    /// <summary>What the copy holds, one line: "User 5, Customer 3", or none.</summary>
    public static string DataClasses(IReadOnlyDictionary<string, int> classes) =>
        classes.Count == 0 ? UiText.Get("ShareDataNone") : string.Join(", ", classes.OrderBy(c => c.Key, StringComparer.Ordinal).Select(c => $"{c.Key} {c.Value}"));
}
