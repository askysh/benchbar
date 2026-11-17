using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;

namespace BenchBar.Tray.Tests;

/// <summary>The Microsoft Store package, in the app: the restart marker, the update offer, the menu, the resume flag and Settings.</summary>
public class PackagedViewTests : IDisposable
{
    private const string Family = "Askysh.BenchBar_0f196q1bwh8q6";

    private readonly string _dir = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (IOException) { }
    }

    [Fact]
    public void AStartByWindowsAfterAnUpdateIsNotACrash()
    {
        var marker = new RunMarker(Path.Combine(_dir, "running"));
        marker.Begin("0.9.0");
        // the update ended the tray without a clean exit, and Windows started it again with --restarted
        Assert.False(new RunMarker(marker.Path).Begin("0.9.0", restartedByWindows: true));
        // an ordinary start that finds the same marker is still a crash
        Assert.True(new RunMarker(marker.Path).Begin("0.9.0"));
    }

    [Fact]
    public void AForcedShutdownRemovesTheMarker()
    {
        var marker = new RunMarker(Path.Combine(_dir, "running"));
        marker.Begin("0.9.0");
        marker.End(); // what the session ending handler calls
        Assert.False(File.Exists(marker.Path));
        Assert.False(new RunMarker(marker.Path).Begin("0.9.0"));
    }

    private const string ReleaseJson = """{"tag_name":"v0.9.0","html_url":"https://x","assets":[{"name":"benchbar-windows-0.9.0-amd64.zip"}]}""";

    [Fact]
    public void ThePackagedTrayOffersNoUpdateAndTheOtherOneDoes()
    {
        var release = UpdateCheck.ParseReleaseInfo(ReleaseJson);
        Assert.Same(release, UpdateCheck.OfferFor(PackageInfo.Unpackaged, release, "0.8.2", "amd64"));
        Assert.Null(UpdateCheck.OfferFor(PackageInfo.Packaged(Family), release, "0.8.2", "amd64"));
    }

    [Fact]
    public void ThePackagedMenuHasNoCheckForUpdates() => Sta.Run(() =>
    {
        var menu = new TrayMenu(new TrayMenuModel { ShowCheckForUpdates = false });
        Assert.DoesNotContain("Check for Updates", menu.Headers);
        Assert.Contains("Help", menu.Headers);
    });

    [Fact]
    public void ADisabledLogonItemShowsItsReason() => Sta.Run(() =>
    {
        var model = new TrayMenuModel
        {
            LogonEnabled = () => false,
            LogonAvailable = () => false,
            LogonNote = () => LogonView.TurnedOffInWindows,
        };
        var menu = new TrayMenu(model);
        menu.RefreshChecks();
        var logon = menu.Menu.Items.OfType<MenuItem>().First(i => (string?)i.Header == TrayMenu.LogonHeader);
        Assert.False(logon.IsEnabled);
        Assert.False(logon.IsChecked);
        Assert.Equal(LogonView.TurnedOffInWindows, logon.ToolTip);
    });

    [Fact]
    public void ThePackagedResumeFlagIsAFileInTheDataFolderAndTouchesNoStartupFolder()
    {
        var startup = Path.Combine(_dir, "Startup");
        var marker = Path.Combine(_dir, "data", ResumeFlag.MarkerName);
        var flag = new ResumeFlag(PackageInfo.Packaged(Family), new StartupShortcut(startup, Path.Combine(_dir, "BenchBarTray.exe"), StartupShortcut.ResumeFileName), marker);

        Assert.False(flag.IsSet);
        flag.Enable();
        Assert.True(flag.IsSet);
        Assert.False(Directory.Exists(startup));
        flag.Disable();
        Assert.False(flag.IsSet);
        Assert.False(Directory.Exists(startup));
    }

    [Fact]
    public void TheUnpackagedResumeFlagStaysTheShortcut() => Sta.Run(() =>
    {
        Directory.CreateDirectory(_dir);
        var exe = Path.Combine(_dir, "BenchBarTray.exe");
        File.WriteAllText(exe, "x");
        var startup = Path.Combine(_dir, "Startup");
        var shortcut = new StartupShortcut(startup, exe, StartupShortcut.ResumeFileName, StartupShortcut.ResumeArgument, new NoApproval());
        var flag = new ResumeFlag(PackageInfo.Unpackaged, shortcut, Path.Combine(_dir, "data", ResumeFlag.MarkerName));

        flag.Enable();
        Assert.True(File.Exists(shortcut.LinkPath));
        Assert.False(flag.IsSet); // the shortcut's flag arrives as an argument, not as a file
        flag.Disable();
        Assert.False(File.Exists(shortcut.LinkPath));
    });

    private sealed class NoApproval : IStartupApproval
    {
        public byte[]? Get(string fileName) => null;
        public void Clear(string fileName) { }
    }

    [Fact]
    public void TheStartupTaskStatesMapOneToOne()
    {
        Assert.Equal(StartupTaskState.Enabled, WinRtStartupTask.Map(Windows.ApplicationModel.StartupTaskState.Enabled));
        Assert.Equal(StartupTaskState.Disabled, WinRtStartupTask.Map(Windows.ApplicationModel.StartupTaskState.Disabled));
        Assert.Equal(StartupTaskState.DisabledByUser, WinRtStartupTask.Map(Windows.ApplicationModel.StartupTaskState.DisabledByUser));
        Assert.Equal(StartupTaskState.DisabledByPolicy, WinRtStartupTask.Map(Windows.ApplicationModel.StartupTaskState.DisabledByPolicy));
        Assert.Equal(StartupTaskState.EnabledByPolicy, WinRtStartupTask.Map(Windows.ApplicationModel.StartupTaskState.EnabledByPolicy));
        Assert.Equal("BenchBarTrayLogon", WinRtStartupTask.TaskId); // the TaskId in windows/msix/AppxManifest.xml
    }

    private sealed class Host(IPackageInfo package, ILogonControl logon) : ISettingsHost
    {
        public bool OpenAtLogon { get; set; }
        public string? ShimPath => ShimPathDisplay.For(package, null, @"C:\u\AppData\Local");
        public IPackageInfo Package => package;
        public ILogonControl? Logon => logon;
        public void ApplyAppearance(AppearanceMode mode) { }
        public void ApplyRunner(string id) { }
        public void ApplyNotifications(bool on) { }
    }

    private sealed class FixedLogon(LogonView view) : ILogonControl
    {
        public LogonView View => view;
        public event Action? Changed { add { } remove { } }
        public Task RefreshAsync() => Task.CompletedTask;
        public Task SetAsync(bool on) => Task.CompletedTask;
    }

    private static List<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        var found = new List<T>();
        void Walk(DependencyObject node)
        {
            if (node is T t) found.Add(t);
            foreach (var child in LogicalTreeHelper.GetChildren(node).OfType<DependencyObject>()) Walk(child);
        }
        Walk(root);
        return found;
    }

    [Fact]
    public void PackagedSettingsShowTheLineTheButtonAndNoUpdateCheck() => Sta.Run(() =>
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var config = TrayConfig.Load(Path.Combine(_dir, "config.json"));
        var host = new Host(PackageInfo.Packaged(Family), new FixedLogon(LogonView.FromTask(StartupTaskState.DisabledByUser)));
        var model = new SettingsModel(config, host, WindowViewTests.Fixture(), () => { });
        var window = new SettingsWindow(model, () => RunnerSet.BuiltIn, _ => { }, PageKit.Theme);

        var texts = Descendants<TextBlock>((DependencyObject)window.Content).Where(t => t.Visibility == Visibility.Visible).Select(t => t.Text).ToList();
        Assert.Contains(LogonView.TurnedOffInWindows, texts);
        Assert.Contains(UpdatePolicy.StoreLine, texts);

        var buttons = Descendants<Button>((DependencyObject)window.Content).Where(b => b.Visibility == Visibility.Visible).Select(b => b.Content as string).ToList();
        Assert.Contains(LogonView.SettingsButton, buttons);

        var boxes = Descendants<CheckBox>((DependencyObject)window.Content);
        var logon = boxes.Single(b => (string?)b.Content == "Open BenchBar at logon");
        Assert.False(logon.IsEnabled);
        Assert.False(logon.IsChecked);
        var updates = boxes.Single(b => ((string?)b.Content)?.StartsWith("Check for updates", StringComparison.Ordinal) == true);
        Assert.Equal(Visibility.Collapsed, updates.Visibility);
        window.Close();
    });
}
