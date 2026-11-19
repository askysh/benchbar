using System.Windows.Input;
using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>The Quick Switch panel: what it shows, the keys, the one call each opens with, and what it says when it cannot.</summary>
public class QuickSwitchWindowTests
{
    private static BenchStatus Ready() => Bench() with { Sites = [new SiteInfo("one.localhost", true, new SiteOpenAs(true, true, true)), new SiteInfo("two.localhost", false)] };

    private static (QuickSwitchWindow Window, ScriptedStreamRunner Runner, List<(QuickSwitchTarget, string)> Opened, OpenAsPins Pins) Make(params BenchStatus[] benches)
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var runner = new ScriptedStreamRunner();
        runner.On("open").Print(Fixture("open-as-opened.json"));
        runner.On("users").Print(Fixture("users.json"));
        var opened = new List<(QuickSwitchTarget, string)>();
        var pins = new OpenAsPins();
        pins.Pin("priya@example.com", "Priya N", BenchPath, "one.localhost");
        var host = new QuickSwitchHost
        {
            Cli = new CliClient(runner, () => "benchbar.exe"),
            Benches = () => benches,
            Pins = pins,
            LastUser = _ => "priya@example.com",
            Opened = (t, u) => opened.Add((t, u)),
            Debounce = TimeSpan.Zero,
        };
        return (new QuickSwitchWindow(host, Theme), runner, opened, pins);
    }

    private static bool Press(Key key, QuickSwitchWindow window) => window.HandleKey(key);

    [Fact]
    public void ThePanelListsAdministratorAndThePinsWithTheirDigitsAndMarksTheLastOpened() => Sta.Run(() =>
    {
        var (window, _, _, _) = Make(Ready());
        Assert.Null(window.Blocker);
        Assert.Equal(["0   Administrator", "1   Priya N   priya@example.com   last opened"], window.RowTexts);
        AssertEveryControlIsNamed(window);
    });

    [Fact]
    public void ADigitOpensTheSiteAsThatUserWithOneCallAndClosesThePanel() => Sta.Run(() =>
    {
        var (window, runner, opened, _) = Make(Ready());
        Assert.True(Press(Key.D1, window));
        Wait(window.OpenTask);
        Assert.Equal(["open", "--site", "one.localhost", "--as", "priya@example.com", "--json", "--bench-dir", BenchPath], runner.Runs.Single(r => r.Args[0] == "open").Args);
        Assert.DoesNotContain("--print-url", runner.Runs.Single(r => r.Args[0] == "open").Args);
        Assert.Equal("priya@example.com", opened.Single().Item2);
    });

    [Fact]
    public void EnterOpensTheSelectedRowAndAnArrowMovesTheSelection() => Sta.Run(() =>
    {
        var (window, runner, opened, _) = Make(Ready());
        Press(Key.Down, window);
        Press(Key.Enter, window);
        Wait(window.OpenTask);
        Assert.Equal("priya@example.com", opened.Single().Item2);
        Assert.Single(runner.Runs, r => r.Args[0] == "open");
    });

    [Fact]
    public void ARefusalStaysInThePanelInTheCliWordsAndOpensNothing() => Sta.Run(() =>
    {
        var opened = new List<(QuickSwitchTarget, string)>();
        var failing = new ScriptedStreamRunner();
        failing.On("open").Print(Fixture("open-as-refused.jsonl")).Fail(1);
        var host = new QuickSwitchHost { Cli = new CliClient(failing, () => "benchbar.exe"), Benches = () => [Ready()], Opened = (t, u) => opened.Add((t, u)) };
        var panel = new QuickSwitchWindow(host, Theme);
        Press(Key.D0, panel);
        Wait(panel.OpenTask);
        Assert.Contains("not in developer mode", panel.StatusText);
        Assert.Empty(opened);
    });

    [Fact]
    public void TypingSearchesTheSitesUsersAfterTwoCharactersWithAShortLimit() => Sta.Run(() =>
    {
        var (window, runner, _, _) = Make(Ready());
        window.SearchBox.Text = "p";
        Wait(window.SearchAsync());
        Assert.DoesNotContain(runner.Runs, r => r.Args[0] == "users"); // one character does not ask
        window.SearchBox.Text = "web";
        Wait(window.SearchAsync());
        Assert.Equal(["users", "--site", "one.localhost", "--search", "web", "--limit", "8", "--json", "--bench-dir", BenchPath], runner.Runs.Single(r => r.Args[0] == "users").Args);
        Assert.Contains(window.RowTexts, t => t.Contains("web@example.com"));
        Assert.False(Press(Key.D1, window)); // with text in the field a digit is typed, not a shortcut
    });

    [Fact]
    public void WithNoSiteToOpenThePanelOnlySaysWhyAndNothingCanRun() => Sta.Run(() =>
    {
        var (window, runner, _, _) = Make(Bench() with { Sites = [new SiteInfo("one.localhost", true, new SiteOpenAs(false, true, false))] });
        Assert.Equal("Open as is off for one.localhost. Turn it on with Allow Open as... in its Sites tab.", window.Blocker);
        Assert.Empty(window.RowTexts);
        Assert.Empty(runner.Runs);
    });
}
