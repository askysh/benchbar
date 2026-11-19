using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>Open as in the Sites tab: the opt in is a question the person answers, Find User lists and opens, and no link is ever in sight.</summary>
public class SitesOpenAsViewTests
{
    private static BenchStatus WithOpenAs(SiteOpenAs? one, SiteOpenAs? two = null, BenchState state = BenchState.Running) =>
        Bench(state) with { Sites = [new SiteInfo("one.localhost", true, one), new SiteInfo("two.localhost", false, two)] };

    private static (SitesView View, PageKit Kit, List<(string Title, string Detail, string Button)> Asked) Make(BenchStatus bench, bool answer = true)
    {
        var kit = new PageKit();
        var asked = new List<(string, string, string)>();
        kit.Services.Confirm = (t, d, b) =>
        {
            asked.Add((t, d, b));
            return answer;
        };
        kit.Runner.On("site", "open-as").Print(Fixture("site-open-as-on.json"));
        kit.Runner.On("users").Print(Fixture("users.json"));
        kit.Runner.On("open").Print(Fixture("open-as-opened.json"));
        var view = new SitesView(kit.Services);
        view.Bind(new BenchContext(bench, null));
        return (view, kit, asked);
    }

    private static string[] Menu(SitesView view, string site) => [.. MenuOf(view, "More actions for " + site).Select(i => (string)i.Header)];

    // --- the opt in ---

    [Fact]
    public void OpenAsIsOffAndOnlyTheOptInIsOfferedUntilThePersonTurnsItOn() => Sta.Run(() =>
    {
        var (view, _, _) = Make(WithOpenAs(new SiteOpenAs(false, true, false)));
        Assert.Contains("Allow Open as...", Menu(view, "one.localhost"));
        Assert.DoesNotContain("Open as...", Menu(view, "one.localhost"));
        Assert.DoesNotContain(Texts(view), t => t.StartsWith("Open as is on"));
        AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void AnOlderCliShowsNoOpenAsAtAll() => Sta.Run(() =>
    {
        var (view, _, _) = Make(WithOpenAs(null));
        Assert.DoesNotContain(Menu(view, "one.localhost"), h => h.Contains("Open as"));
    });

    [Fact]
    public void AllowAsksTheMacsQuestionFirstAndRunsNothingWhenTheAnswerIsNo() => Sta.Run(() =>
    {
        var (view, kit, asked) = Make(WithOpenAs(new SiteOpenAs(false, true, false)), answer: false);
        ClickMenu(view, "More actions for one.localhost", "Allow Open as...");
        Wait(view.Pending);
        Assert.Equal(("Allow Open as on one.localhost?", OpenAsRules.AllowMessage, "Allow Open as"), asked.Single());
        Assert.Empty(kit.RunsOf("site", "open-as"));
    });

    [Fact]
    public void AllowRunsTheCliAsAPersonAfterAYesAndTheTabPollsAgain() => Sta.Run(() =>
    {
        var (view, kit, _) = Make(WithOpenAs(new SiteOpenAs(false, true, false)));
        ClickMenu(view, "More actions for one.localhost", "Allow Open as...");
        Wait(view.Pending);
        var run = kit.Runner.Runs.Single(r => r.Args[0] == "site");
        Assert.Equal(["site", "open-as", "on", "one.localhost", "--yes", "--json", "--bench-dir", PageKit.BenchPath], run.Args);
        Assert.Equal("0", run.Env["BENCHBAR_NONINTERACTIVE"]);
        Assert.Equal(OpenAsRules.TurnedOn("one.localhost"), view.Message);
        Assert.Equal(1, kit.Refreshes);
    });

    [Fact]
    public void ARefusalOfTheCliIsShownAsItIsWorded() => Sta.Run(() =>
    {
        var failing = new PageKit();
        failing.Services.Confirm = (_, _, _) => true;
        failing.Runner.On("site", "open-as").Print(Fixture("site-open-as-refused.jsonl")).Fail(1);
        var view = new SitesView(failing.Services);
        view.Bind(new BenchContext(WithOpenAs(new SiteOpenAs(false, true, false)), null));
        ClickMenu(view, "More actions for one.localhost", "Allow Open as...");
        Wait(view.Pending);
        Assert.True(view.MessageIsError);
        Assert.Contains("needs a person at a terminal", view.Message);
    });

    [Fact]
    public void TurnOffNeedsNoQuestionAndSaysSignInsAlreadyMadeStayValid() => Sta.Run(() =>
    {
        var (view, kit, asked) = Make(WithOpenAs(new SiteOpenAs(true, true, true)));
        ClickMenu(view, "More actions for one.localhost", "Turn Off Open as");
        Wait(view.Pending);
        Assert.Empty(asked);
        Assert.Equal(["site", "open-as", "off", "one.localhost", "--yes", "--json", "--bench-dir", PageKit.BenchPath], kit.Runner.Runs.Single(r => r.Args[0] == "site").Args);
        Assert.Equal("Open as is off for one.localhost. Sign ins already made stay valid.", view.Message);
    });

    // --- the line and the menu while it is on ---

    [Fact]
    public void WhileItIsOnTheRowSaysReadyOrWhyNotAndTheMenuHasOpenAs() => Sta.Run(() =>
    {
        var (view, _, _) = Make(WithOpenAs(new SiteOpenAs(true, true, true), new SiteOpenAs(true, true, false)));
        Assert.Contains("Open as is on", Texts(view));
        Assert.Contains("Open as...", Menu(view, "one.localhost"));
        Assert.Contains("Turn Off Open as", Menu(view, "one.localhost"));
        Assert.DoesNotContain("Open as...", Menu(view, "two.localhost")); // not the default site: it cannot be used
        Assert.Contains(Texts(view), t => t.StartsWith("Open as is on, but not usable. Only the default site can be used"));
        AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void ABenchThatIsStoppedShowsOpenAsDisabled() => Sta.Run(() =>
    {
        var (view, _, _) = Make(WithOpenAs(new SiteOpenAs(true, true, true), state: BenchState.Stopped));
        Assert.False(MenuOf(view, "More actions for one.localhost").Single(i => (string)i.Header == "Open as...").IsEnabled);
    });

    // --- Find User ---

    [Fact]
    public void FindUserListsTheUsersAndOpenSignsTheBrowserInThroughTheCli() => Sta.Run(() =>
    {
        var (view, kit, _) = Make(WithOpenAs(new SiteOpenAs(true, true, true)));
        ClickMenu(view, "More actions for one.localhost", "Open as...");
        Wait(view.Pending);
        Drain();
        Assert.Equal(["Administrator", "priya@example.com", "web@example.com"], view.FindButtons.Keys);
        Assert.Contains("Priya N", Texts(view));
        Assert.Contains("Web User (Website User)", Texts(view));
        Assert.Contains("Showing the first 50; refine the search.", Texts(view));
        AssertEveryControlIsNamed(view);
        Assert.Equal(["users", "--site", "one.localhost", "--limit", "50", "--json", "--bench-dir", PageKit.BenchPath], kit.Runner.Runs.Single(r => r.Args[0] == "users").Args);

        Click(view.FindButtons["priya@example.com"]);
        Wait(view.Pending);
        Drain();
        var open = kit.Runner.Runs.Single(r => r.Args[0] == "open");
        Assert.Equal(["open", "--site", "one.localhost", "--as", "priya@example.com", "--json", "--bench-dir", PageKit.BenchPath], open.Args);
        Assert.Contains("one.localhost opened in your browser as Priya N.", Texts(view));
        Assert.Empty(kit.Opened); // the tray opens nothing itself: the CLI did, and no link came back
    });

    [Fact]
    public void PinKeepsAUserInQuickSwitchAndUnpinRemovesItButAdministratorHasNoPin() => Sta.Run(() =>
    {
        var (view, kit, _) = Make(WithOpenAs(new SiteOpenAs(true, true, true)));
        ClickMenu(view, "More actions for one.localhost", "Open as...");
        Wait(view.Pending);
        Drain();
        Assert.Equal(["priya@example.com", "web@example.com"], view.PinButtons.Keys); // Administrator is always in the panel
        Click(view.PinButtons["priya@example.com"]);
        Assert.True(kit.Services.Pins.IsPinned("priya@example.com", PageKit.BenchPath, "one.localhost"));
        Assert.Equal("Priya N", kit.Services.Pins.Of(PageKit.BenchPath, "one.localhost").Single().FullName);
        Assert.Equal("Unpin", System.Windows.Automation.AutomationProperties.GetName(view.PinButtons["priya@example.com"]).Split(' ')[0]);
        var label = Walk(view).OfType<TextBox>().Single(t => System.Windows.Automation.AutomationProperties.GetName(t) == "Label for priya@example.com");
        label.Text = " NE ";
        Assert.Equal("NE", kit.Services.Pins.Of(PageKit.BenchPath, "one.localhost").Single().Label);
        Click(view.PinButtons["priya@example.com"]);
        Assert.Empty(kit.Services.Pins.Map);
    });

    [Fact]
    public void ATenthPinIsRefusedWithAnExplanation() => Sta.Run(() =>
    {
        var (view, kit, _) = Make(WithOpenAs(new SiteOpenAs(true, true, true)));
        for (var i = 1; i <= 9; i++) kit.Services.Pins.Pin($"u{i}@example.com", null, PageKit.BenchPath, "one.localhost");
        ClickMenu(view, "More actions for one.localhost", "Open as...");
        Wait(view.Pending);
        Drain();
        Click(view.PinButtons["priya@example.com"]);
        Assert.False(kit.Services.Pins.IsPinned("priya@example.com", PageKit.BenchPath, "one.localhost"));
        Assert.Contains("A site keeps 9 pinned users at most. Unpin one first.", Texts(view));
    });

    [Fact]
    public void ClosingTheBenchPanelDropsFindUser() => Sta.Run(() =>
    {
        var (view, _, _) = Make(WithOpenAs(new SiteOpenAs(true, true, true)));
        ClickMenu(view, "More actions for one.localhost", "Open as...");
        Wait(view.Pending);
        Assert.NotNull(view.Find);
        Click(ButtonNamed(view, "Close"));
        Assert.Null(view.Find);
        Assert.Null(view.OpenPanel);
    });
}
