using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>The Sharing tab: what it shows per state, that every change asks first, and that the room code is on screen only when the host asks.</summary>
public class SharingViewTests
{
    /// <summary>The off room with every check passing, so Start is offered.</summary>
    private static string Clean(string from = "share-status-off.json") => Fixture(from)[0].Replace("\"fail\"", "\"ok\"");

    private static (SharingView View, PageKit Kit, List<string> Asked) Make(string status, bool answer = true, Func<string, string>? tweak = null)
    {
        var kit = new PageKit();
        kit.Runner.On("share", "status").Print(tweak is null ? Fixture(status)[0] : tweak(Fixture(status)[0]));
        kit.Runner.On("share", "people").Print(Fixture("share-people.json"));
        kit.Runner.On("share", "code").Print(Fixture("share-code.json"));
        kit.Runner.On("share", "invite").Print(Fixture("share-invite.json"));
        kit.Runner.On("share").Print(Fixture("share-done.jsonl"));
        var asked = new List<string>();
        var view = new SharingView(kit.Services, bench => new ShareModel(kit.Services.Cli, bench))
        {
            Confirm = (title, _, _) =>
            {
                asked.Add(title);
                return answer;
            },
        };
        view.Bind(new BenchContext(Bench(), null));
        Wait(view.Pending);
        return (view, kit, asked);
    }

    private static int Calls(PageKit kit, params string[] prefix) =>
        kit.Runner.Runs.Count(r => r.Args.Length >= prefix.Length && r.Args.Take(prefix.Length).SequenceEqual(prefix));

    // --- the tab comes with the lab ---

    [Fact]
    public void TheSharingTabIsOnThePageOnlyWhileTheLabIsOn() => Sta.Run(() =>
    {
        var page = new BenchPage(new PageServices(), new OverviewView(new OverviewActions()));
        Assert.Equal(["Overview", "Sites", "Apps", "Health"], page.TabLabels);
        page.SetSharingVisible(true);
        page.SetSharingVisible(true); // twice is one tab
        Assert.Equal(["Overview", "Sites", "Apps", "Health", "Sharing"], page.TabLabels);
        page.Bind(Bench(), null, navigate: true);
        page.Select(BenchTab.Sharing);
        Assert.NotNull(page.Sharing);
        page.SetSharingVisible(false); // turned off while it is the tab shown: back to the Overview
        Assert.Equal(["Overview", "Sites", "Apps", "Health"], page.TabLabels);
        Assert.Equal(BenchTab.Overview, page.Tab);
        Assert.Null(page.Sharing);
        page.SetSharingVisible(true);
        page.Select(BenchTab.Sharing);
        Assert.NotNull(page.Sharing); // a fresh view the second time
        AssertEveryControlIsNamed(page);
    });

    // --- states ---

    [Fact]
    public void ABenchThatWasNeverSetUpOffersSetUpAndNothingStartsByItself() => Sta.Run(() =>
    {
        var (view, kit, _) = Make("share-status-unset.json");
        Assert.Contains(ShareText.SetUpIntro, view.Lines);
        Assert.Contains(ShareText.SetUpElsewhere, view.Lines);
        Assert.DoesNotContain(view.Lines, l => l.StartsWith("[")); // no button starts anything here
        Assert.DoesNotContain(view.Lines, l => l.StartsWith("Checks"));
        Assert.Equal(1, Calls(kit, "share", "status"));
        Assert.Equal(0, Calls(kit, "share", "start") + Calls(kit, "share", "setup") + Calls(kit, "lan-guard") + Calls(kit, "share", "code"));
        AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void AnOffRoomShowsTheChecksTheCopyAndStartIsOffWhileACheckFails() => Sta.Run(() =>
    {
        var (view, _, _) = Make("share-status-off.json");
        Assert.Contains("Failed: The firewall lets sharing through", view.Lines);
        Assert.Contains("Passed: The shared copy is there", view.Lines);
        Assert.Contains("The gateway answers on the network: " + ShareText.CheckedAtStart, view.Lines);
        Assert.Contains("Copy made 2 h 1 min ago from one.localhost. Guests' changes stay in the copy.", view.Lines);
        Assert.Contains(ShareText.DriftWarning, view.Lines);
        Assert.False(view.Buttons["Start sharing"].IsEnabled);
        Assert.False(view.Buttons.ContainsKey("Stop"));
        AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void ARunningRoomShowsTheCountdownThePeopleAndTheNotices() => Sta.Run(() =>
    {
        var (view, _, _) = Make("share-status-on.json");
        Assert.Contains("Sharing on your network · 1 online · 59 min left", view.Lines);
        Assert.Contains(ShareText.Full, view.Lines);
        Assert.Contains(ShareText.JoinTrouble, view.Lines);
        Assert.Contains(ShareText.WipeOwed, view.Lines);
        Assert.Contains("Online: Priya · ThinkPad · 192.168.1.32 · Priya N", view.Lines);
        Assert.Contains("Offline: Sam · MacBook Air · 192.168.1.31 · Sam Seat", view.Lines);
        Assert.True(view.Buttons["+30 min"].IsEnabled && view.Buttons["+1 hour"].IsEnabled);
        Assert.Contains("Unlock", view.Buttons.Keys);
        AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void AnOldCliOnlyOffersTheUpdate() => Sta.Run(() =>
    {
        var (view, _, _) = Make("share-status-old.json");
        Assert.Equal([ShareText.NewerCli, "[Update]"], view.Lines);
    });

    // --- the code ---

    [Fact]
    public void StartingAsksFirstAndReadsTheCodeOnlyAfterTheHostSaidYes() => Sta.Run(() =>
    {
        var (declined, declinedKit, asked) = Make("share-status-off.json", answer: false, Clean0);
        Click(declined.Buttons["Start sharing"]);
        Wait(declined.Pending);
        Assert.Single(asked, a => a.StartsWith("Start sharing one.localhost"));
        Assert.Equal(0, Calls(declinedKit, "share", "start") + Calls(declinedKit, "share", "code"));

        var (view, kit, _) = Make("share-status-off.json", answer: true, Clean0);
        kit.Runner.On(a => a.Length > 1 && a[1] == "start").Print(Fixture("share-done.jsonl")); // the first reply that matches wins, so this one is not reached before the others
        Click(view.Buttons["Start sharing"]);
        Wait(view.Pending);
        Assert.Equal(["share", "start", "--for", "4h", "--json", "--bench-dir", P], kit.Runner.Runs.Single(r => r.Args[1] == "start").Args);
        Assert.Equal(1, Calls(kit, "share", "code"));
    });

    private static string Clean0(string text) => text.Replace("\"fail\"", "\"ok\"");

    [Fact]
    public void TheCodeNeverAppearsInTheShownLinesAndOnlyInTheCardAfterShow() => Sta.Run(() =>
    {
        var (view, kit, _) = Make("share-status-on.json");
        Assert.Contains("Room code: hidden", view.Lines);
        Assert.Equal(0, Calls(kit, "share", "code")); // opening the tab never reads the code
        Click(view.Buttons["New code"]);
        Wait(view.Pending);
        Assert.Equal(["share", "code", "--new", "--json", "--bench-dir", P], kit.Runner.Runs.Single(r => r.Args[1] == "code").Args);
        Assert.Contains("Room code: shown", view.Lines);
        Assert.Contains("000 000", Texts(view)); // the card, drawn for the host
        Assert.DoesNotContain(view.Lines, l => l.Contains("000000") || l.Contains("000 000"));
        Click(view.Buttons["Hide"]);
        Assert.DoesNotContain("000 000", Texts(view));
    });

    private const string P = PageKit.BenchPath;

    [Fact]
    public void CopyAndCopyInviteUseTheSecretClipboardOnly() => Sta.Run(() =>
    {
        var (view, kit, _) = Make("share-status-on.json");
        var secrets = new List<string>();
        var plain = new List<string>();
        kit.Services.CopySecret = secrets.Add;
        kit.Services.CopyText = plain.Add;
        Assert.False(view.Buttons["Copy"].IsEnabled); // no code read yet
        Click(view.Buttons["Copy invite"]);
        Wait(view.Pending);
        Assert.Single(secrets);
        Assert.StartsWith("Join my BenchBar room", secrets[0]);
        Assert.Empty(plain);
        Assert.Contains(ShareText.InviteCopied, view.Lines);
    });

    // --- every change asks first ---

    [Fact]
    public void StopAndRemoveAskFirstWithThePeopleConnected() => Sta.Run(() =>
    {
        var (view, kit, asked) = Make("share-status-on.json", answer: false);
        Click(view.Buttons["Stop"]);
        Click(view.Buttons["Remove Sam"]);
        Wait(view.Pending);
        Assert.Equal(["Stop sharing? 1 person is connected and will be signed out.", "Remove Sam? Closes their connections and signs them out of one.localhost."], asked);
        Assert.Equal(0, Calls(kit, "share", "stop") + Calls(kit, "share", "remove"));

        var (yes, yesKit, _) = Make("share-status-on.json");
        Click(yes.Buttons["Remove Sam"]);
        Wait(yes.Pending);
        Assert.Equal(["share", "remove", "d_0a1b2c3d", "--yes", "--json", "--bench-dir", P], yesKit.Runner.Runs.Single(r => r.Args[1] == "remove").Args);
        Assert.Contains("Sam was removed. To let them back in, send a new invite.", yes.Lines);
    });
}
