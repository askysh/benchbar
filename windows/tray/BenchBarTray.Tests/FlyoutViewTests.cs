using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;

namespace BenchBar.Tray.Tests;

public class FlyoutViewTests
{
    private static string FixtureDir()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "fixtures", "recorded-v1");
            if (Directory.Exists(candidate)) return candidate;
        }
        throw new DirectoryNotFoundException("fixtures/recorded-v1 not found above " + AppContext.BaseDirectory);
    }

    private static BenchStatus Status(string name, string state, string? reason = null, string? site = "x.localhost")
    {
        static string Q(string? s) => s is null ? "null" : "\"" + s + "\"";
        return BenchJson.ParseStatus(
            "{\"bench\":\"/home/a/" + name + "\",\"name\":\"" + name + "\",\"site\":" + Q(site) + ",\"state\":\"" + state + "\"," +
            "\"stop_reason\":" + Q(reason) + ",\"web_url\":" + Q(site is null ? null : "http://" + site + ":8000") + "}");
    }

    /// <summary>The recorded running bench read through the fixture source, a paused port conflict and a not adopted one.</summary>
    private static TraySnapshot ThreeBenches()
    {
        var source = new FixtureBenchSource(FixtureDir());
        var entry = source.ListAsync(CancellationToken.None).GetAwaiter().GetResult().Single();
        var running = source.StatusAsync(entry, CancellationToken.None).GetAwaiter().GetResult();
        return new TraySnapshot([running, Status("v16-bench", "paused", "port_conflict", "v16dev.localhost"), Status("new-bench", "not_adopted", null, site: null)]);
    }

    private static void Click(Button button) => button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));

    [Fact]
    public void ARowPerBenchWithNameStateWordSiteAndButtons() => Sta.Run(() =>
    {
        var view = new FlyoutView(new FlyoutActions());
        view.SetSnapshot(ThreeBenches(), "1 of 3 up");

        Assert.Equal(FlyoutMode.Benches, view.Mode);
        Assert.Equal("1 of 3 up", view.UpText);
        Assert.Equal(["frappe-bench", "v16-bench", "new-bench"], view.Rows.Select(r => r.NameText));
        Assert.Equal(["running", "port conflict", "unknown (not_adopted)"], view.Rows.Select(r => r.StateText));
        Assert.Equal(["linuxdev.localhost", "v16dev.localhost", "no site"], view.Rows.Select(r => r.SiteText));

        string[] strip = ["⋯", "Open site", "Logs", "VS Code", "Doctor"];
        Assert.Equal(["Stop", .. strip], view.Rows[0].ButtonLabels);
        Assert.Equal(["Start", .. strip], view.Rows[1].ButtonLabels);
        Assert.Equal(["Start", .. strip], view.Rows[2].ButtonLabels);
        Assert.True(view.Rows[0].ActionButton.IsEnabled);
        Assert.False(view.Rows[2].ActionButton.IsEnabled); // not adopted: nothing to start
        Assert.False(view.Rows[2].Buttons[2].IsEnabled); // no site, no Open site
    });

    [Fact]
    public void ThePolledDefaultSiteWinsOverTheFirstSite() => Sta.Run(() =>
    {
        var bench = BenchJson.ParseStatus("""{"bench":"/b","name":"b","site":"a.localhost","state":"running","sites":[{"name":"a.localhost","default":false},{"name":"z.localhost","default":true}]}""");
        var view = new FlyoutView(new FlyoutActions());
        view.SetSnapshot(new TraySnapshot([bench]), "1 of 1 up");
        Assert.Equal("z.localhost", view.Rows[0].SiteText);
    });

    [Fact]
    public void ADistroThatIsStoppedShowsOneCardWithAStartButton() => Sta.Run(() =>
    {
        var started = 0;
        var view = new FlyoutView(new FlyoutActions { StartDistro = () => started++ });
        view.SetSnapshot(new TraySnapshot([], DistroStopped: true, Distro: "Ubuntu-24.04"), "distro stopped");

        Assert.Equal(FlyoutMode.DistroStopped, view.Mode);
        Assert.Empty(view.Rows);
        Assert.Equal("Ubuntu-24.04 is stopped", view.CardTitle);
        Assert.Equal("The tray does not start it on its own.", view.CardHint);
        Assert.Equal(["Start"], view.CardButtons);

        Click(view.CardButton!);
        Assert.Equal(1, started);
        Assert.False(view.CardButton!.IsEnabled); // asked once; the poll that finds it up replaces the card
    });

    [Fact]
    public void AProblemShowsItsLineInACardWithCopy() => Sta.Run(() =>
    {
        string? copied = null;
        var view = new FlyoutView(new FlyoutActions { CopyText = t => copied = t });
        view.SetSnapshot(new TraySnapshot([], Problem: ShimBenchSource.NotFoundMessage), "needs attention");

        Assert.Equal(FlyoutMode.Problem, view.Mode);
        Assert.Equal(ShimBenchSource.NotFoundMessage, view.CardTitle);
        Assert.Equal(["Copy"], view.CardButtons);
        Click(view.CardButton!);
        Assert.Equal(ShimBenchSource.NotFoundMessage, copied);
    });

    [Fact]
    public void NoBenchesSaysSo() => Sta.Run(() =>
    {
        var view = new FlyoutView(new FlyoutActions());
        view.SetSnapshot(new TraySnapshot([]), "none up");
        Assert.Equal(FlyoutMode.Empty, view.Mode);
        Assert.Empty(view.Rows);
    });

    [Fact]
    public void AFailedStartShowsItsLineUnderTheRowUntilTheStateChanges() => Sta.Run(() =>
    {
        var stopped = Status("b", "stopped", "manual");
        var view = new FlyoutView(new FlyoutActions
        {
            StartStop = _ => Task.FromResult(new ActionResult(1, "Port 8000 is held by another bench.")),
        });
        view.SetSnapshot(new TraySnapshot([stopped]), "none up");
        Assert.Null(view.Rows[0].FailureText);

        Click(view.Rows[0].ActionButton);
        Assert.Equal("Port 8000 is held by another bench.", view.Rows[0].FailureText);
        Assert.True(view.Rows[0].ActionButton.IsEnabled); // can try again

        view.SetSnapshot(new TraySnapshot([Status("b", "stopped", "manual")]), "none up"); // a poll that changed nothing
        Assert.Equal("Port 8000 is held by another bench.", view.Rows[0].FailureText);

        view.SetSnapshot(new TraySnapshot([Status("b", "starting")]), "1 of 1 up"); // the state changed
        Assert.Null(view.Rows[0].FailureText);
    });

    [Fact]
    public void AnActionThatThrowsIsAFailureLineToo() => Sta.Run(() =>
    {
        var view = new FlyoutView(new FlyoutActions { StartStop = _ => throw new InvalidOperationException("boom") });
        view.SetSnapshot(new TraySnapshot([Status("b", "stopped")]), "none up");
        Click(view.Rows[0].ActionButton);
        Assert.Equal("boom", view.Rows[0].FailureText);
    });

    [Fact]
    public void VsCodeNotFoundShowsTheInstallMessageInTheFlyout() => Sta.Run(() =>
    {
        var view = new FlyoutView(new FlyoutActions { OpenVsCode = _ => VsCodeOutcome.NotFound, VsCodeAvailable = () => false });
        view.SetSnapshot(new TraySnapshot([Status("b", "running")]), "1 of 1 up");
        var code = view.Rows[0].Buttons.Single(b => b.Content as string == "VS Code");
        Assert.Equal(VsCode.InstallMessage, code.ToolTip);
        Assert.Equal("", view.MessageText);

        Click(code);
        Assert.Equal("Install VS Code and its WSL extension (ms-vscode-remote.remote-wsl), then try again.", view.MessageText);
        view.ClearMessage();
        Assert.Equal("", view.MessageText);
    });

    [Fact]
    public void TheStripButtonsCallTheirActions() => Sta.Run(() =>
    {
        var calls = new List<string>();
        var view = new FlyoutView(new FlyoutActions
        {
            OpenSite = b => calls.Add("site " + b.Name),
            ShowLogs = b => calls.Add("logs " + b.Name),
            ShowDoctor = b => calls.Add("doctor " + b.Name),
            OpenVsCode = b => { calls.Add("code " + b.Name); return VsCodeOutcome.Launched; },
        });
        view.SetSnapshot(new TraySnapshot([Status("b", "running")]), "1 of 1 up");
        foreach (var label in new[] { "Open site", "Logs", "VS Code", "Doctor" })
            Click(view.Rows[0].Buttons.Single(b => b.Content as string == label));
        Assert.Equal(["site b", "logs b", "code b", "doctor b"], calls);
    });

    [Fact]
    public void APollThatChangedNothingKeepsTheSameRows() => Sta.Run(() =>
    {
        var view = new FlyoutView(new FlyoutActions());
        view.SetSnapshot(new TraySnapshot([Status("b", "running")]), "1 of 1 up");
        var first = view.Rows[0];
        view.SetSnapshot(new TraySnapshot([Status("b", "running")]), "1 of 1 up");
        Assert.Same(first, view.Rows[0]);
        view.SetSnapshot(new TraySnapshot([Status("b", "stopped")]), "none up");
        Assert.NotSame(first, view.Rows[0]);
    });
}
