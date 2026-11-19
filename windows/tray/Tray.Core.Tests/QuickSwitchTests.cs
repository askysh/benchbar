using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>Quick Switch: the pins, the targets and why there are none, and the rows and keys of the panel. Nothing here starts a process.</summary>
public class QuickSwitchTests
{
    private const string Bench = "/home/akash/frappe-bench";

    private static BenchStatus Running(BenchState state = BenchState.Running, SiteOpenAs? one = null, SiteOpenAs? two = null, string path = Bench, string name = "frappe-bench") =>
        new(name, path, state, null, "http://one.localhost:8000", "one.localhost")
        {
            Sites = [new SiteInfo("one.localhost", true, one), new SiteInfo("two.localhost", false, two)],
        };

    private static readonly SiteOpenAs Ready = new(true, true, true);

    // --- pins ---

    [Fact]
    public void ASiteKeepsNinePinsAndAdministratorIsNeverOneOfThem()
    {
        var pins = new OpenAsPins();
        var changes = 0;
        pins.Changed += () => changes++;
        for (var i = 1; i <= 9; i++) Assert.True(pins.Pin($"u{i}@example.com", $"User {i}", Bench, "one.localhost"));
        Assert.False(pins.Pin("u10@example.com", null, Bench, "one.localhost")); // the tenth
        Assert.False(pins.Pin("Administrator", null, Bench, "two.localhost"));
        Assert.True(pins.Pin("u1@example.com", null, Bench, "one.localhost")); // already there: no change
        Assert.Equal(9, changes);
        Assert.Equal(9, pins.Of(Bench, "one.localhost").Count);
        Assert.Empty(pins.Of(Bench, "two.localhost"));
    }

    [Fact]
    public void ALabelIsTrimmedAndEmptyClearsItAndUnpinningTheLastDropsTheKey()
    {
        var pins = new OpenAsPins();
        pins.Pin("a@example.com", "Priya N", Bench, "one.localhost");
        pins.SetLabel("a@example.com", "  NE Pune ", Bench, "one.localhost");
        Assert.Equal("NE Pune", OpenAsPins.Label("a@example.com", "Priya N", pins.Of(Bench, "one.localhost")));
        pins.SetLabel("a@example.com", "   ", Bench, "one.localhost");
        Assert.Equal("Priya N", OpenAsPins.Label("a@example.com", null, pins.Of(Bench, "one.localhost"))); // the pin kept the name
        Assert.Equal("b@example.com", OpenAsPins.Label("b@example.com", null, pins.Of(Bench, "one.localhost")));
        pins.Unpin("a@example.com", Bench, "one.localhost");
        Assert.Empty(pins.Map);
    }

    [Fact]
    public void PinsSurviveASaveAndKeepTheShimsKeys()
    {
        var path = Path.Combine(Path.GetTempPath(), "bb-pins-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            File.WriteAllText(path, """{"distro":"Ubuntu","tray":{"appearance":"dark"}}""");
            var config = TrayConfig.Load(path);
            config.Pins.Pin("a@example.com", "Priya N", Bench, "one.localhost");
            config.Pins.SetLabel("a@example.com", "NE", Bench, "one.localhost");
            config.Save();
            var again = TrayConfig.Load(path);
            var pin = Assert.Single(again.Pins.Of(Bench, "one.localhost"));
            Assert.Equal(new PinnedUser("a@example.com", "NE", "Priya N"), pin);
            Assert.Equal(AppearanceMode.Dark, again.Appearance);
            Assert.Equal("Ubuntu", again.Distro);
        }
        finally
        {
            File.Delete(path);
        }
    }

    // --- targets ---

    [Fact]
    public void OnlyASiteOfARunningBenchThatOpenAsCanSignInToIsATargetAndTheDefaultComesFirst()
    {
        var targets = QuickSwitchTargets.From([Running(one: Ready, two: new SiteOpenAs(true, true, false)), Running(BenchState.Stopped, Ready, Ready, "/home/akash/b2", "b2")]);
        Assert.Equal(["one.localhost on frappe-bench"], targets.Select(t => t.Title)); // two.localhost is not the default: not usable; b2 is stopped
        Assert.Equal(OpenAsPins.Key(Bench, "one.localhost"), targets[0].Key);
    }

    [Theory]
    [InlineData("none", "No bench to open as a user on. Add one in BenchBar.")]
    [InlineData("stopped", "No bench is running. Start one first.")]
    [InlineData("off", "Open as is off for one.localhost. Turn it on with Allow Open as... in its Sites tab.")]
    [InlineData("nodev", "one.localhost is not in developer mode. Run: bench --site one.localhost set-config developer_mode 1")]
    public void WhenThereIsNothingToOpenThePanelSaysWhyAndHowToFixIt(string scenario, string text)
    {
        IReadOnlyList<BenchStatus> benches = scenario switch
        {
            "none" => [],
            "stopped" => [Running(BenchState.Stopped, Ready)],
            "off" => [Running(one: new SiteOpenAs(false, true, false))],
            _ => [Running(one: new SiteOpenAs(true, false, false))],
        };
        Assert.Equal(text, QuickSwitchTargets.Blocker(benches, QuickSwitchTargets.From(benches)));
    }

    [Fact]
    public void ThereIsNoBlockerWhileATargetExists()
    {
        var benches = new[] { Running(one: Ready) };
        Assert.Null(QuickSwitchTargets.Blocker(benches, QuickSwitchTargets.From(benches)));
    }

    // --- the panel's rows and keys ---

    private static QuickSwitchModel Model(string? last = null) => new(new QuickSwitchTarget(Bench, "frappe-bench", "one.localhost"),
        [new PinnedUser("priya@example.com", "NE", "Priya N"), new PinnedUser("sam@example.com", null, "Sam Seat")], last);

    [Fact]
    public void TheRowsAreAdministratorThenThePinsWithDigitsAndTheLastOpenedIsMarked()
    {
        var rows = Model("sam@example.com").Rows;
        Assert.Equal(["Administrator", "NE", "Sam Seat"], rows.Select(r => r.Title));
        Assert.Equal([0, 1, 2], rows.Select(r => r.Digit));
        Assert.Equal([null, "priya@example.com", "sam@example.com"], rows.Select(r => r.Detail));
        Assert.Equal("Sam Seat, sam@example.com, last opened", rows[2].Spoken);
        Assert.Equal("Administrator", rows[0].Spoken);
    }

    [Fact]
    public void DigitsOpenAtOnceOnlyWhileTheFieldIsEmptyAndTypingFilters()
    {
        var model = Model();
        Assert.Equal("priya@example.com", model.ByDigit(1)!.User);
        Assert.Equal("Administrator", model.ByDigit(0)!.User);
        Assert.Null(model.ByDigit(5));
        model.SetQuery("sam");
        Assert.Null(model.ByDigit(1)); // a digit typed into a search is a search
        Assert.Equal(["Sam Seat"], model.Rows.Select(r => r.Title));
        Assert.True(model.WantsSearch);
        model.SetQuery("s");
        Assert.False(model.WantsSearch);
        model.SetQuery("pri");
        Assert.Equal(["NE"], model.Rows.Select(r => r.Title)); // matches the pin's id, name or label
    }

    [Fact]
    public void ASearchAddsTheSitesUsersAfterThePinsWithoutRepeatingOne()
    {
        var model = Model();
        model.SetQuery("sam");
        model.SetRemote([new SiteUser("sam@example.com", "Sam Seat", "System User", [], 0), new SiteUser("samuel@example.com", "Samuel", "System User", [], 0)]);
        Assert.Equal(["Sam Seat", "Samuel"], model.Rows.Select(r => r.Title)); // sam is already a pin and is not repeated
        Assert.Equal(QuickSwitchKind.Other, model.Rows.Last().Kind);
        model.SetQuery(""); // emptied: the search results go with the text
        Assert.Equal(3, model.Rows.Count);
    }

    [Fact]
    public void TheSelectionWrapsAndEnterNamesTheSelectedRowOrNothing()
    {
        var model = Model();
        Assert.Equal("Administrator", model.Confirm()!.User);
        model.Move(-1);
        Assert.Equal("sam@example.com", model.Confirm()!.User);
        model.Move(1);
        Assert.Equal("Administrator", model.Confirm()!.User);
        model.SetQuery("zzz");
        Assert.Null(model.Confirm());
    }
}
