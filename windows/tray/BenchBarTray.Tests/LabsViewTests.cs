using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>The Labs page: a switch per experiment, the why for one that is not on Windows, the CLI's call behind each switch.</summary>
public class LabsViewTests
{
    private static (LabsView View, PageKit Kit) Rig()
    {
        var kit = new PageKit();
        kit.Runner.On("labs", "list").Print(Fixture("labs-list.json"));
        kit.Runner.On("labs", "off").Print("""{"schema_version":1,"exit":0,"lab":"example-linux","enabled":false}""");
        return (new LabsView(kit.Services), kit);
    }

    [Fact]
    public void EachExperimentHasANamedSwitchAndAnExperimentNotOnWindowsSaysWhy() => Sta.Run(() =>
    {
        var (view, _) = Rig();
        Wait(view.Model.RefreshAsync());
        Assert.Equal(["lan-rooms", "quick-switch", "example-linux"], view.Switches.Keys);
        Assert.Contains("Share with people on the same Wi-Fi", view.Lines);
        Assert.Contains("Not on Windows yet. It works on macOS only.", view.Lines);
        Assert.Contains("since 0.8.2", view.Lines);
        AssertEveryControlIsNamed(view);

        var rooms = view.Switches["lan-rooms"];
        Assert.False(rooms.IsChecked);
        Assert.False(rooms.IsEnabled); // off and not here: it cannot be turned on
        var linux = view.Switches["example-linux"];
        Assert.True(linux.IsChecked);
        Assert.True(linux.IsEnabled);
        Assert.Contains("Warning: It can change or disappear.", view.Lines); // an experiment that is on shows its warning as one
    });

    [Fact]
    public void TheSwitchRunsLabsOffThroughTheCliAndThePageShowsTheNewState() => Sta.Run(() =>
    {
        var (view, kit) = Rig();
        Wait(view.Model.RefreshAsync());
        ClickToggle(view.Switches["example-linux"]); // the scripted CLI answers at once, so the page has changed when the click returns
        Assert.Equal(["labs", "off", "example-linux", "--yes", "--json"], kit.Runner.Runs.Last(r => r.Args[1] == "off").Args);
        Assert.False(view.Model.IsOn("example-linux"));
        Assert.False(view.Switches["example-linux"].IsChecked);
    });

    [Fact]
    public void ACliWithoutLabsSaysSoInsteadOfAnEmptyList() => Sta.Run(() =>
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var runner = new ScriptedStreamRunner();
        runner.On("labs").Fail(2, "[FAIL] Unknown command: labs");
        var view = new LabsView(new LabsModel(new CliClient(runner, () => "benchbar.exe")));
        Wait(view.Model.RefreshAsync());
        Assert.Equal([LabsText.Unsupported], view.Lines);
        Assert.Empty(view.Switches);
    });

    [Fact]
    public void ALabsPaneOpensBelowTheBenchesAndReadsTheListWhenShown() => Sta.Run(() =>
    {
        var kit = new PageKit();
        kit.Runner.On("labs", "list").Print(Fixture("labs-list.json"));
        var window = new MainWindow(new MainActions { Services = kit.Services }, new ResolvedTheme(true, true));
        window.SetSnapshot(new TraySnapshot([Bench()]), "1 of 1 up");
        window.ShowTool(SidebarTool.Labs);
        Assert.Equal("tool|Labs", window.ContentKind);
        Assert.Equal(SidebarTool.Labs, window.Tool);
        Assert.Contains(kit.Runner.Runs, r => r.Args.SequenceEqual(["labs", "list", "--json"]));
        Assert.Contains("Labs", ButtonLabels(window));
    });
}
