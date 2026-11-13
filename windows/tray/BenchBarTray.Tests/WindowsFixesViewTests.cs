using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>The Windows onboarding fixes that live in the app: logon switch, updates, notices, run marker, awake guard, placement, colors, the wizard view.</summary>
public class WindowsFixesViewTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (IOException) { }
    }

    // --- 10: Open at logon and Windows' own switch ---

    private sealed class FakeApproval : IStartupApproval
    {
        public Dictionary<string, byte[]> Values { get; } = new(StringComparer.OrdinalIgnoreCase);

        public byte[]? Get(string fileName) => Values.GetValueOrDefault(fileName);

        public void Clear(string fileName) => Values.Remove(fileName);
    }

    private static readonly byte[] Off = [3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    private static readonly byte[] On = [2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

    private StartupShortcut Shortcut(FakeApproval approval, string? fileName = null)
    {
        Directory.CreateDirectory(_dir);
        var exe = Path.Combine(_dir, "BenchBarTray.exe");
        File.WriteAllText(exe, "x");
        return new StartupShortcut(Path.Combine(_dir, "Startup"), exe, fileName, approval: approval);
    }

    [Theory]
    [InlineData(null, false)]
    [InlineData(new byte[0], false)]
    [InlineData(new byte[] { 2, 0, 0, 0 }, false)]
    [InlineData(new byte[] { 3, 0, 0, 0 }, true)]
    [InlineData(new byte[] { 1 }, true)]
    [InlineData(new byte[] { 4 }, false)]
    public void AnOddFirstByteMeansWindowsHasTheEntryOff(byte[]? value, bool off) =>
        Assert.Equal(off, StartupShortcut.IsDisabledValue(value));

    [Fact]
    public void LogonReadsOffWhileWindowsHasTheEntryOffAndEnableClearsIt() => Sta.Run(() =>
    {
        var approval = new FakeApproval();
        var shortcut = Shortcut(approval);

        Assert.False(shortcut.IsEnabled()); // no file
        shortcut.Enable();
        Assert.True(shortcut.IsEnabled());

        approval.Values[StartupShortcut.FileName] = Off; // switched off in Settings or Task Manager
        Assert.True(File.Exists(shortcut.LinkPath));
        Assert.False(shortcut.IsEnabled());
        Assert.True(shortcut.IsApprovedOff());

        shortcut.Enable(); // turning it on again clears Windows' off switch
        Assert.True(shortcut.IsEnabled());
        Assert.Empty(approval.Values);
    });

    [Fact]
    public void AnEnabledValueOrNoValueKeepsLogonOn() => Sta.Run(() =>
    {
        var approval = new FakeApproval();
        var shortcut = Shortcut(approval);
        shortcut.Enable();
        approval.Values[StartupShortcut.FileName] = On;
        Assert.True(shortcut.IsEnabled());
    });

    [Fact]
    public void DisablingRemovesTheShortcutAndWindowsEntry() => Sta.Run(() =>
    {
        var approval = new FakeApproval();
        var shortcut = Shortcut(approval);
        shortcut.Enable();
        approval.Values[StartupShortcut.FileName] = On;
        shortcut.Disable();
        Assert.False(File.Exists(shortcut.LinkPath));
        Assert.Empty(approval.Values);
        Assert.False(shortcut.IsEnabled());
    });

    [Fact]
    public void TheResumeShortcutHasTheSameRuleUnderItsOwnName() => Sta.Run(() =>
    {
        var approval = new FakeApproval();
        var shortcut = Shortcut(approval, StartupShortcut.ResumeFileName);
        shortcut.Enable();
        Assert.True(shortcut.IsEnabled());
        approval.Values[StartupShortcut.FileName] = Off; // the other entry's switch: not this one's
        Assert.True(shortcut.IsEnabled());
        approval.Values[StartupShortcut.ResumeFileName] = Off;
        Assert.False(shortcut.IsEnabled());
    });

    private sealed class ThrowingApproval : IStartupApproval
    {
        public byte[]? Get(string fileName) => throw new UnauthorizedAccessException();

        public void Clear(string fileName) => throw new UnauthorizedAccessException();
    }

    [Fact]
    public void ARegistryThatCannotBeReadLeavesTheFileInCharge() => Sta.Run(() =>
    {
        Directory.CreateDirectory(_dir);
        var exe = Path.Combine(_dir, "BenchBarTray.exe");
        File.WriteAllText(exe, "x");
        var shortcut = new StartupShortcut(Path.Combine(_dir, "Startup"), exe, approval: new ThrowingApproval());
        shortcut.Enable(); // the clear fails quietly
        Assert.True(shortcut.IsEnabled());
    });

    // --- 9: updates ---

    private const string ReleaseJson = """
        {"tag_name":"v0.9.0","html_url":"https://github.com/askysh/benchbar/releases/tag/v0.9.0","assets":[
          {"name":"BenchBar-0.9.0.dmg"},{"name":"benchbar-windows-0.9.0-amd64.zip"},{"name":"benchbar-windows-0.9.0-SHA256SUMS.txt"}]}
        """;

    [Fact]
    public void TheReleaseListsItsFiles()
    {
        var release = UpdateCheck.ParseReleaseInfo(ReleaseJson)!;
        Assert.Equal("v0.9.0", release.Tag);
        Assert.Equal("0.9.0", release.Version);
        Assert.Equal(3, release.Assets.Count);
        Assert.Equal("benchbar-windows-0.9.0-arm64.zip", release.ZipName("arm64"));
        Assert.True(release.HasWindowsZip("amd64"));
        Assert.False(release.HasWindowsZip("arm64"));
        Assert.Null(UpdateCheck.ParseReleaseInfo("""{"message":"Not Found"}"""));
        Assert.Empty(UpdateCheck.ParseReleaseInfo("""{"tag_name":"v1.0.0","html_url":"https://x"}""")!.Assets);
    }

    [Fact]
    public void AReleaseIsOfferedOnlyWithItsWindowsZipForThisCpu()
    {
        var release = UpdateCheck.ParseReleaseInfo(ReleaseJson);
        Assert.Same(release, UpdateCheck.Offer(release, "0.8.2", "amd64"));
        Assert.Null(UpdateCheck.Offer(release, "0.8.2", "arm64"));          // no arm64 zip yet
        Assert.Null(UpdateCheck.Offer(release, "0.9.0", "amd64"));          // not newer
        Assert.Null(UpdateCheck.Offer(null, "0.8.2", "amd64"));

        var macOnly = UpdateCheck.ParseReleaseInfo("""{"tag_name":"v0.9.0","html_url":"https://x","assets":[{"name":"BenchBar-0.9.0.dmg"}]}""");
        Assert.Null(UpdateCheck.Offer(macOnly, "0.8.2", "amd64"));          // the Mac side shipped first

        Assert.Equal(UpdateState.Available, UpdateCheck.State(release, "0.8.2", "amd64"));
        Assert.Equal(UpdateState.NoWindowsBuild, UpdateCheck.State(macOnly, "0.8.2", "amd64"));
        Assert.Equal(UpdateState.NoWindowsBuild, UpdateCheck.State(release, "0.8.2", "arm64"));
        Assert.Equal(UpdateState.Current, UpdateCheck.State(release, "0.9.0", "amd64"));
        Assert.Equal(UpdateState.Current, UpdateCheck.State(null, "0.8.2", "amd64"));
        Assert.Contains(UpdateCheck.Arch(), new[] { "amd64", "arm64" });
    }

    [Fact]
    public void TheUpdateLineIsTheDocumentedOne()
    {
        Assert.Equal("irm https://raw.githubusercontent.com/askysh/benchbar/main/install.ps1 | iex", UpdateCheck.InstallCommand);
        Assert.Contains("closes BenchBar and starts it again", UpdateCheck.InstallExplanation);
        Assert.Equal(UpdateCheck.InstallCommand, new UpdateOffer("0.9.0", "https://x").Command);
    }

    [Fact]
    public void TheBannerCopiesTheUpdateLineAndKeepsTheReleasePage() => Sta.Run(() =>
    {
        var copied = new List<string>();
        var opened = new List<string>();
        var window = new MainWindow(new MainActions { CopyText = copied.Add, OpenUrl = opened.Add }, Theme);
        window.SetUpdate(new UpdateOffer("0.9.0", "https://github.com/askysh/benchbar/releases/tag/v0.9.0"), () => { });

        Assert.Contains("BenchBar 0.9.0 is out.", Texts(window));
        Assert.Contains(UpdateCheck.InstallExplanation, Texts(window));
        Click(ButtonNamed(window, "Copy the update line for PowerShell"));
        Click(ButtonNamed(window, "Open the release page"));
        Assert.Equal([UpdateCheck.InstallCommand], copied);
        Assert.Equal(["https://github.com/askysh/benchbar/releases/tag/v0.9.0"], opened);
    });

    // --- 8: the run marker and the notices ---

    [Fact]
    public void ARunThatLeftItsMarkerBehindIsReportedAtTheNextStart()
    {
        var marker = new RunMarker(Path.Combine(_dir, "running"));
        Assert.False(marker.Begin("0.8.2"));      // first start ever
        Assert.True(File.Exists(marker.Path));
        Assert.True(new RunMarker(marker.Path).Begin("0.8.2")); // the file was never removed: it ended some other way
        marker.End();
        Assert.False(File.Exists(marker.Path));
        Assert.False(new RunMarker(marker.Path).Begin("0.8.2")); // a clean exit leaves nothing
    }

    [Fact]
    public void AnUpdateThatReplacedTheRunningVersionIsNotACrash()
    {
        var marker = new RunMarker(Path.Combine(_dir, "running"));
        marker.Begin("0.8.2");
        Assert.False(new RunMarker(marker.Path).Begin("0.8.3")); // the installer closed the old tray
        Assert.True(new RunMarker(marker.Path).Begin("0.8.3"));
    }

    [Fact]
    public void TheMarkerNeverThrows()
    {
        var blocked = new RunMarker(Path.Combine(_dir, "file"));
        Directory.CreateDirectory(_dir);
        File.WriteAllText(Path.Combine(_dir, "file"), "x");
        var underAFile = new RunMarker(Path.Combine(_dir, "file", "running")); // its folder is a file
        Assert.False(underAFile.Begin("1.0.0"));
        underAFile.End();
        blocked.End();
    }

    [Fact]
    public void TheNoticeBoardKeepsOneNoticePerKey()
    {
        var board = new NoticeBoard();
        var changes = 0;
        board.Changed += () => changes++;
        board.Set(new Notice("a", "first"));
        board.Set(new Notice("a", "first"));    // the same again: nothing changed
        board.Set(new Notice("a", "second"));
        board.Set(new Notice("b", "other", "Fix", () => { }, Dismissible: false));
        Assert.Equal(["second", "other"], board.All.Select(n => n.Text));
        Assert.Equal(3, changes);
        board.Remove("a");
        board.Remove("a");
        Assert.False(board.Has("a"));
        Assert.True(board.Has("b"));
        Assert.Equal(4, changes);
    }

    [Fact]
    public void TheWindowShowsNoticesWithTheirButtons() => Sta.Run(() =>
    {
        var reported = 0;
        var dismissed = new List<string>();
        var window = new MainWindow(new MainActions(), Theme);
        window.SetNotices(
        [
            new Notice("crashed", "BenchBar closed unexpectedly last time.", "Report a Bug", () => reported++),
            new Notice("shim-version", "benchbar.exe is version 0.8.1 but BenchBar is 0.8.2.", "Copy Install Line", () => { }, Dismissible: false),
        ], dismissed.Add);

        Assert.Equal(["BenchBar closed unexpectedly last time.", "benchbar.exe is version 0.8.1 but BenchBar is 0.8.2."], window.NoticeTexts);
        Click(ButtonNamed(window, "Report a Bug"));
        Assert.Equal(1, reported);
        Click(ButtonNamed(window, "Dismiss: BenchBar closed unexpectedly last time."));
        Assert.Equal(["crashed"], dismissed);
        Assert.Null(FindButton(window, "Dismiss: benchbar.exe is version 0.8.1 but BenchBar is 0.8.2.")); // the version notice stays

        window.SetNotices([], dismissed.Add);
        Assert.Empty(window.NoticeTexts);
    });

    [Fact]
    public void TheFlyoutShowsItsVersionAndTheNotices() => Sta.Run(() =>
    {
        var view = new FlyoutView(new FlyoutActions());
        Assert.Equal("", view.FooterText);
        view.SetFooter("BenchBar 0.8.2");
        Assert.Equal("BenchBar 0.8.2", view.FooterText);

        var dismissed = new List<string>();
        view.SetNotices([new Notice("shim-version", "Versions differ.", "Copy Install Line", () => { }, Dismissible: false)], dismissed.Add);
        Assert.Equal(["Versions differ."], view.NoticeTexts);
        Assert.Contains("Versions differ.", Texts(view));
        Assert.Contains("Copy Install Line", Texts(view).Concat(ButtonLabels(view)).Concat(ContentsOfButtons(view)));
        view.SetNotices([], dismissed.Add);
        Assert.Empty(view.NoticeTexts);
    });

    private static IEnumerable<string> ContentsOfButtons(DependencyObject root)
    {
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
        {
            if (child is Button { Content: string text }) yield return text;
            foreach (var inner in ContentsOfButtons(child)) yield return inner;
        }
    }

    // --- 1: the awake guard ---

    [Fact]
    public void TheAwakeGuardHoldsTheSystemAndLetsGo()
    {
        var flags = new List<uint>();
        var guard = new KeepAwakeGuard(f =>
        {
            flags.Add(f);
            return 1;
        });
        Assert.True(guard.Set(true));
        Assert.True(guard.IsOn);
        Assert.True(guard.Set(false));
        Assert.False(guard.IsOn);
        Assert.Equal([0x80000001u, 0x80000000u], flags); // ES_CONTINUOUS | ES_SYSTEM_REQUIRED, then ES_CONTINUOUS
    }

    [Fact]
    public void ARefusalIsReportedAndLeavesTheStateAlone()
    {
        var guard = new KeepAwakeGuard(_ => 0);
        Assert.False(guard.Set(true));
        Assert.False(guard.IsOn);
    }

    // --- 15: placement and colors ---

    private static NativeMethods.Rect R(int l, int t, int r, int b) => new() { Left = l, Top = t, Right = r, Bottom = b };

    [Fact]
    public void TheFlyoutSitsInTheCornerNextToTheTaskbarOfItsMonitor()
    {
        // taskbar at the bottom of the primary monitor
        Assert.Equal((1920 - 340 - 12, 1040 - 200 - 12), FlyoutPlacement.Anchor(R(0, 0, 1920, 1040), R(0, 0, 1920, 1080), 96, 340, 200));
        // the same taskbar on a monitor to the right: coordinates follow that monitor
        Assert.Equal((3840 - 340 - 12, 1040 - 200 - 12), FlyoutPlacement.Anchor(R(1920, 0, 3840, 1040), R(1920, 0, 3840, 1080), 96, 340, 200));
        // taskbar on top
        Assert.Equal((1920 - 340 - 12, 40 + 12), FlyoutPlacement.Anchor(R(0, 40, 1920, 1080), R(0, 0, 1920, 1080), 96, 340, 200));
        // taskbar on the left
        Assert.Equal((60 + 12, 1080 - 200 - 12), FlyoutPlacement.Anchor(R(60, 0, 1920, 1080), R(0, 0, 1920, 1080), 96, 340, 200));
    }

    [Fact]
    public void TheMarginFollowsTheMonitorsDpi() =>
        Assert.Equal((1920 - 510 - 18, 1040 - 300 - 18), FlyoutPlacement.Anchor(R(0, 0, 1920, 1040), R(0, 0, 1920, 1080), 144, 510, 300));

    [Fact]
    public void ACursorPositionGivesAMonitor() => Assert.NotEqual(IntPtr.Zero, FlyoutPlacement.MonitorOfClick());

    private static readonly Color[] LightBackgrounds = [Color.FromRgb(0xFF, 0xFF, 0xFF), Color.FromRgb(0xF2, 0xF2, 0xF2), Color.FromRgb(0xEA, 0xEA, 0xEA)];
    private static readonly Color[] DarkBackgrounds = [Color.FromRgb(0x20, 0x20, 0x20), Color.FromRgb(0x2A, 0x2A, 0x2A)];

    [Fact]
    public void TheLightThemeTextColorsPassFourPointFiveToOne()
    {
        foreach (var background in LightBackgrounds)
        {
            Assert.True(Ui.ContrastRatio(Ui.CriticalTextLight, background) >= 4.5, $"critical on {background}");
            Assert.True(Ui.ContrastRatio(Ui.CautionTextLight, background) >= 4.5, $"caution on {background}");
        }
        // the colors they replace did not, on the card
        Assert.True(Ui.ContrastRatio(Color.FromRgb(0xE5, 0x48, 0x4D), LightBackgrounds[1]) < 4.5);
        Assert.True(Ui.ContrastRatio(Color.FromRgb(0xD9, 0x8E, 0x04), LightBackgrounds[1]) < 4.5);
    }

    [Fact]
    public void TheDarkThemeTextColorsPassToo()
    {
        foreach (var background in DarkBackgrounds)
        {
            Assert.True(Ui.ContrastRatio(Ui.CriticalTextDark, background) >= 4.5, $"critical on {background}");
            Assert.True(Ui.ContrastRatio(Ui.CautionTextDark, background) >= 4.5, $"caution on {background}");
        }
    }

    [Fact]
    public void TheTextBrushFollowsTheThemeAndHighContrastUsesTheSystem() => Sta.Run(() =>
    {
        var before = Ui.LightTheme;
        try
        {
            if (!Ui.HighContrast)
            {
                Ui.LightTheme = true;
                Assert.Equal(Ui.CriticalTextLight, ((SolidColorBrush)Ui.CriticalBrush).Color);
                Assert.Equal(Ui.CautionTextLight, ((SolidColorBrush)Ui.CautionTextBrush).Color);
                Ui.LightTheme = false;
                Assert.Equal(Ui.CriticalTextDark, ((SolidColorBrush)Ui.CriticalBrush).Color);
                Assert.Equal(Ui.CautionTextDark, ((SolidColorBrush)Ui.CautionTextBrush).Color);
            }
            else
            {
                Assert.Same(SystemColors.HotTrackBrush, Ui.CriticalBrush);
                Assert.Same(SystemColors.HotTrackBrush, Ui.CautionTextBrush);
            }
        }
        finally
        {
            Ui.LightTheme = before;
        }
    });

    // --- 13 and 16: the wizard view ---

    [Fact]
    public async Task AWizardViewThatIsShownAgainStaysSubscribed()
    {
        var model = await WindowViewTests.ModelAt(WizardPage.Welcome);
        Sta.Run(() =>
        {
            var view = new WizardView(model, new WizardActions());
            view.Update();
            Assert.Equal("Welcome to BenchBar", view.TitleText);

            view.RaiseEvent(new RoutedEventArgs(FrameworkElement.UnloadedEvent));
            view.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent)); // shown again, as when the wizard moves between hosts
            model.ChooseCommandLineOnly();
            Dispatcher.CurrentDispatcher.Invoke(() => { }, DispatcherPriority.ApplicationIdle);

            Assert.Equal("Just the Command Line Tool", view.TitleText);
        });
    }

    [Fact]
    public async Task TheNewBenchPageSaysBrowsersOpenLocalhostNames()
    {
        var model = await WindowViewTests.ModelAt(WizardPage.NewBench);
        Sta.Run(() =>
        {
            var view = new WizardView(model, new WizardActions());
            view.Update();
            var hint = Assert.Single(Texts(view), t => t.Contains(".localhost needs no hosts line"));
            Assert.Contains("browsers", hint);
            Assert.Contains("Edge and Chrome", hint);
            Assert.Contains("PowerShell and ping do not resolve it", hint);
            Assert.DoesNotContain("Windows resolves it", hint);
        });
    }

    [Fact]
    public async Task TheInstallPageHasTheAwakeLineAndOnlyShowsItWhileItRuns()
    {
        var model = await WindowViewTests.ModelAt(WizardPage.Install); // the fixture install fails, so nothing runs now
        Sta.Run(() =>
        {
            var view = new WizardView(model, new WizardActions());
            view.Update();
            Assert.Contains(WizardModel.KeepAwakeNote, Texts(view));
            var note = AllTextBlocks(view).Single(t => t.Text == WizardModel.KeepAwakeNote);
            Assert.Equal(Visibility.Collapsed, note.Visibility);
        });
    }

    private static IEnumerable<TextBlock> AllTextBlocks(DependencyObject root)
    {
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
        {
            if (child is TextBlock block) yield return block;
            foreach (var inner in AllTextBlocks(child)) yield return inner;
        }
    }
}
