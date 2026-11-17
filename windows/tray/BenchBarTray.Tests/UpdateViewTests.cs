using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>Update Now in every place the update is announced: the window's banner, the flyout line, the tray menu and About.</summary>
public class UpdateViewTests
{
    private static readonly UpdateOffer Installer = new("0.9.0", "https://github.com/askysh/benchbar/releases/tag/v0.9.0", CanUpdateNow: true);
    private static readonly UpdateOffer CopyOnly = new("0.9.0", "https://github.com/askysh/benchbar/releases/tag/v0.9.0");

    [Fact]
    public void TheBannerOffersUpdateNowAndKeepsTheLineUnderOtherWays() => Sta.Run(() =>
    {
        var updates = 0;
        var copied = new List<string>();
        var opened = new List<string>();
        var window = new MainWindow(new MainActions { UpdateNow = () => updates++, CopyText = copied.Add, OpenUrl = opened.Add }, Theme);
        window.SetUpdate(Installer, () => { });

        Assert.Contains("BenchBar 0.9.0 is out.", Texts(window));
        Assert.Contains(UpdateLinks.UpdateNowExplanation, Texts(window));
        Click(ButtonNamed(window, "Update BenchBar now"));
        Assert.Equal(1, updates);
        Assert.Equal(["Copy Update Line", "Release Page"], MenuOf(window, "Other ways to update").Select(i => (string)i.Header));
        ClickMenu(window, "Other ways to update", "Copy Update Line");
        ClickMenu(window, "Other ways to update", "Release Page");
        Assert.Equal([UpdateLinks.InstallCommand], copied);
        Assert.Equal([Installer.Url], opened);
        Assert.NotNull(FindButton(window, "Dismiss the update notice"));
    });

    [Fact]
    public void WhileTheUpdateRunsTheBannerSaysSoAndOffersNothingNew() => Sta.Run(() =>
    {
        var window = new MainWindow(new MainActions(), Theme);
        window.SetUpdate(Installer, () => { }, running: true);

        Assert.True(window.UpdateRunning);
        Assert.Contains("Updating to BenchBar 0.9.0.", Texts(window));
        Assert.Contains(UpdateLinks.UpdatingExplanation, Texts(window));
        var update = ButtonNamed(window, "Update BenchBar now");
        Assert.False(update.IsEnabled);
        Assert.Equal("Updating...", update.Content);
        Assert.Null(FindButton(window, "Dismiss the update notice"));

        window.SetUpdate(null, () => { });
        Assert.False(window.UpdateRunning);
        Assert.Null(window.Offer);
    });

    [Fact]
    public void TheFlyoutHasOneUpdateLine() => Sta.Run(() =>
    {
        var updates = 0;
        var copied = new List<string>();
        var view = new FlyoutView(new FlyoutActions { UpdateNow = () => updates++, CopyText = copied.Add });
        Assert.Equal("", view.UpdateText);

        view.SetUpdate(Installer, running: false);
        Assert.Equal("BenchBar 0.9.0 is out.", view.UpdateText);
        Click(ButtonNamed(view, "Update BenchBar now"));
        Click(ButtonNamed(view, "Copy the update line for PowerShell"));
        Assert.Equal(1, updates);
        Assert.Equal([UpdateLinks.InstallCommand], copied);

        view.SetUpdate(Installer, running: true);
        Assert.Equal("Updating to BenchBar 0.9.0.", view.UpdateText);
        Assert.False(ButtonNamed(view, "Update BenchBar now").IsEnabled);

        view.SetUpdate(CopyOnly, running: false);
        Assert.Null(FindButton(view, "Update BenchBar now"));
        Assert.NotNull(FindButton(view, "Copy the update line for PowerShell"));

        view.SetUpdate(null, running: false);
        Assert.Equal("", view.UpdateText);
    });

    [Fact]
    public void TheMenuOffersUpdateToXOnlyWhenUpdateNowCanRunIt() => Sta.Run(() =>
    {
        UpdateOffer? offer = null;
        var running = false;
        var updates = 0;
        var menu = new TrayMenu(new TrayMenuModel { Update = () => offer, UpdateRunning = () => running, UpdateNow = () => updates++ });
        menu.RefreshChecks();
        Assert.DoesNotContain(menu.Headers, h => h.StartsWith("Update", StringComparison.Ordinal));
        Assert.Contains("Check for Updates", menu.Headers);

        offer = CopyOnly;
        menu.RefreshChecks();
        Assert.DoesNotContain("Update to 0.9.0", menu.Headers);

        offer = Installer;
        menu.RefreshChecks();
        var headers = menu.Headers.ToList();
        Assert.Equal(headers.IndexOf("Check for Updates") - 1, headers.IndexOf("Update to 0.9.0"));
        var item = menu.Menu.Items.OfType<MenuItem>().Single(i => (string)i.Header == "Update to 0.9.0");
        item.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        Assert.Equal(1, updates);

        running = true;
        menu.RefreshChecks();
        Assert.Contains("Updating to 0.9.0...", menu.Headers);
        Assert.False(item.IsEnabled);
    });

    [Fact]
    public void AboutShowsUpdateNowBesideTheVersion() => Sta.Run(() =>
    {
        var updates = 0;
        var running = false;
        var window = new AboutWindow(new AboutActions
        {
            AppVersion = "0.8.4",
            KnownOffer = () => Installer,
            UpdateRunning = () => running,
            UpdateNow = () => { updates++; running = true; },
        }, Theme);

        Assert.Equal("BenchBar 0.9.0 is out.", window.UpdateText);
        Click(ButtonNamed(window, "Update BenchBar now"));
        Assert.Equal(1, updates);
        Assert.False(ButtonNamed(window, "Update BenchBar now").IsEnabled); // the second click starts nothing
        Assert.NotNull(FindButton(window, "Copy the update line for PowerShell"));
        window.Close();
    });

    [Fact]
    public void AboutSaysTheStoreLineAndOffersNothingForAPackagedCopy() => Sta.Run(() =>
    {
        var store = SelfUpdateStatus.Parse("""{"current":"0.8.4","latest":"0.9.0","update_available":true,"install":"store","error":null}""");
        var window = new AboutWindow(new AboutActions { CheckForUpdates = () => Task.FromResult(new SelfUpdateCheck(store, null)) }, Theme);
        Assert.True(window.CheckAsync().IsCompleted); // the answer is already there, so the check ends without a dispatcher turn
        Assert.Equal(UpdateLinks.StoreLine, window.UpdateText);
        Assert.Null(FindButton(window, "Update BenchBar now"));
        Assert.Null(FindButton(window, "Copy the update line for PowerShell"));
        window.Close();
    });

    [Fact]
    public void TheUpdatedNoticeIsNewsWithWhatsNew() => Sta.Run(() =>
    {
        var opened = 0;
        var dismissed = new List<string>();
        var window = new MainWindow(new MainActions(), Theme);
        window.SetNotices([new Notice("updated", "BenchBar was updated to 0.9.0.", "What's New", () => opened++, Critical: false)], dismissed.Add);

        Assert.Equal(["BenchBar was updated to 0.9.0."], window.NoticeTexts);
        Click(ButtonNamed(window, "What's New"));
        Click(ButtonNamed(window, "Dismiss: BenchBar was updated to 0.9.0."));
        Assert.Equal(1, opened);
        Assert.Equal(["updated"], dismissed);
        var text = Walk(window).OfType<TextBlock>().Single(t => t.Text == "BenchBar was updated to 0.9.0.");
        Assert.NotEqual(Ui.CriticalBrush, text.Foreground); // news, not a warning
    });

    [Fact]
    public void TheRunningHintNamesTheClockAndTheStartMenu()
    {
        Assert.Contains("notification area near the clock", RunningHint.Text);
        Assert.Contains("Start menu", RunningHint.Text);
    }
}
