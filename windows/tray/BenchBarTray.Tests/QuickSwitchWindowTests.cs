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

    private static bool Press(Key key, QuickSwitchWindow window, ModifierKeys modifiers = ModifierKeys.None) => window.HandleKey(key, modifiers);

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
        failing.On("open").Fail(1, Fixture("open-as-refused.stderr.txt")[0].Trim()); // nothing on stdout, "  [FAIL] message" on stderr
        var host = new QuickSwitchHost { Cli = new CliClient(failing, () => "benchbar.exe"), Benches = () => [Ready()], Opened = (t, u) => opened.Add((t, u)) };
        var panel = new QuickSwitchWindow(host, Theme);
        Press(Key.D0, panel);
        Wait(panel.OpenTask);
        Assert.Equal("one.localhost is not in developer mode, so benchbar will not sign in as another user.", panel.StatusText);
        Assert.Empty(opened);
    });

    [Theory]
    [InlineData(Key.D1, ModifierKeys.Shift)]
    [InlineData(Key.D0, ModifierKeys.Shift)]
    [InlineData(Key.D1, ModifierKeys.Control)]
    [InlineData(Key.D1, ModifierKeys.Alt)]
    [InlineData(Key.D1, ModifierKeys.Windows)]
    [InlineData(Key.NumPad1, ModifierKeys.Shift)]
    [InlineData(Key.D1, ModifierKeys.Control | ModifierKeys.Shift)]
    public void ADigitWithAModifierIsNotAShortcutAndOpensNothing(Key key, ModifierKeys modifiers) => Sta.Run(() =>
    {
        var (window, runner, opened, _) = Make(Ready());
        Assert.False(Press(key, window, modifiers)); // Shift+1 on an empty field is "!", not pin 1
        Assert.True(window.OpenTask.IsCompleted);
        Assert.DoesNotContain(runner.Runs, r => r.Args[0] == "open");
        Assert.Empty(opened);
        Assert.True(Press(Key.D1, window)); // the plain digit still opens
    });

    [Fact]
    public void NoUsersMatchGoesWhenTheTextChangesAndASearchErrorDoesNotColourTheNextLine() => Sta.Run(() =>
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var runner = new ScriptedStreamRunner();
        runner.On("users").Fail(1, "[FAIL] The bench is not running.");
        var host = new QuickSwitchHost { Cli = new CliClient(runner, () => "benchbar.exe"), Benches = () => [Ready()], Pins = new OpenAsPins(), Debounce = TimeSpan.Zero };
        var window = new QuickSwitchWindow(host, Theme);
        window.SearchBox.Text = "zz"; // matches no pin and Administrator: the list is empty
        Wait(window.SearchAsync());
        Assert.Equal("Could not search users: The bench is not running.", window.StatusText);
        Assert.True(window.StatusIsError);

        window.SearchBox.Text = "z"; // under two characters: no search, the list is empty, the line says so in the normal colour
        Assert.Equal("No users match", window.StatusText);
        Assert.False(window.StatusIsError);
        window.SearchBox.Text = "adm"; // a row matches: nothing is left of the old line
        Assert.Equal("", window.StatusText);
        Assert.Contains(window.RowTexts, t => t.Contains("Administrator"));
    });

    [Fact]
    public void WhileTheSearchIsAskedAnEmptyListIsNotYetNoMatchAndSearchingHasTheNormalColour() => Sta.Run(() =>
    {
        var (window, runner, _, _) = Make(Ready());
        window.SearchBox.Text = "zz";
        Assert.Equal("", window.StatusText); // the debounce has not fired: the CLI has not answered, so "no match" would be a guess
        Wait(window.SearchAsync());
        Assert.DoesNotContain(runner.Runs, r => r.Env.ContainsKey("BENCHBAR_NONINTERACTIVE") && r.Args[0] == "users"); // a typed search is a read, not a click
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
