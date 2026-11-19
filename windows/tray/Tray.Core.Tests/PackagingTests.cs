using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>The Microsoft Store package: one data folder, the logon switch, the update UI, the shim path and the two installs notice, in both states.</summary>
public class PackagingTests
{
    private const string Family = "Askysh.BenchBar_0f196q1bwh8q6";
    private const string Local = @"C:\Users\a\AppData\Local";

    private static IPackageInfo Packaged => PackageInfo.Packaged(Family);

    private static IPackageInfo Plain => PackageInfo.Unpackaged;

    // --- package detection ---

    [Fact]
    public void PackagedHasAFamilyNameAndUnpackagedHasNone()
    {
        Assert.True(Packaged.IsPackaged);
        Assert.Equal(Family, Packaged.FamilyName);
        Assert.False(Plain.IsPackaged);
        Assert.Null(Plain.FamilyName);
        Assert.False(PackageInfo.Packaged("  ").IsPackaged);
    }

    [Fact]
    public void AskingTheRunningProcessNeverThrows()
    {
        // the test host is not packaged; anywhere else the call still answers instead of failing
        var current = PackageInfo.Current;
        Assert.Equal(current.IsPackaged, current.FamilyName is not null);
    }

    [Fact]
    public void TheAliasIsInWindowsApps() =>
        Assert.Equal(Path.Combine(Local, "Microsoft", "WindowsApps", "benchbar.exe"), PackageInfo.AliasPath(Local));

    // --- the data folder ---

    [Fact]
    public void UnpackagedKeepsTheOldFolder() =>
        Assert.Equal(Path.Combine(Local, "BenchBar"), DataFolder.For(Plain, Local));

    [Fact]
    public void PackagedUsesThePhysicalFolderInsideThePackageData()
    {
        var folder = DataFolder.For(Packaged, Local);
        Assert.Equal(Path.Combine(Local, "Packages", Family, "LocalCache", "Local", "BenchBar"), folder);
        Assert.NotEqual(Path.Combine(Local, "BenchBar"), folder); // never the redirected path
        Assert.StartsWith(Path.Combine(Local, "Packages", Family), folder);
    }

    [Fact]
    public void TheFamilyNameIsReadNotWritten()
    {
        var other = DataFolder.For(PackageInfo.Packaged("Other.Name_abc123"), Local);
        Assert.Contains("Other.Name_abc123", other);
        Assert.DoesNotContain(Family, other);
    }

    [Fact]
    public void EveryFileTheTrayKeepsLivesInTheOneFolder()
    {
        var dir = DataFolder.Current;
        Assert.Equal(dir, Path.GetDirectoryName(TrayConfig.DefaultPath));
        Assert.Equal(dir, Path.GetDirectoryName(RunnerSet.DefaultFolder));
        Assert.Equal(dir, Path.GetDirectoryName(RecentFolders.DefaultPath));
        Assert.Equal(dir, Path.GetDirectoryName(TrayOnlyReport.DefaultFolder));
    }

    // --- open at logon ---

    private sealed class FakeShortcut : IShortcutLogon
    {
        public bool On { get; set; }
        public int Calls { get; private set; }
        public bool IsEnabled() { Calls++; return On; }
        public void Enable() { Calls++; On = true; }
        public void Disable() { Calls++; On = false; }
    }

    private sealed class FakeTask(StartupTaskState state) : IStartupTask
    {
        public StartupTaskState State { get; set; } = state;
        public StartupTaskState AfterEnable { get; set; } = StartupTaskState.Enabled;
        public bool Throws { get; set; }
        public bool ThrowOnEnable { get; set; }
        public bool KeepsState { get; set; }
        public TaskCompletionSource<StartupTaskState>? EnableGate { get; set; }
        public List<string> Calls { get; } = [];

        public Task<StartupTaskState> GetStateAsync()
        {
            Calls.Add("get");
            if (Throws) throw new InvalidOperationException("no package identity");
            return Task.FromResult(State);
        }

        public Task<StartupTaskState> RequestEnableAsync()
        {
            Calls.Add("enable");
            if (ThrowOnEnable) throw new InvalidOperationException("request failed");
            if (EnableGate is { } gate) return gate.Task;
            if (State == StartupTaskState.Disabled) State = AfterEnable;
            return Task.FromResult(State);
        }

        public Task DisableAsync()
        {
            Calls.Add("disable");
            if (!KeepsState && State == StartupTaskState.Enabled) State = StartupTaskState.Disabled;
            return Task.CompletedTask;
        }
    }

    [Fact]
    public async Task UnpackagedUsesTheShortcutAndNeverTheTask()
    {
        var shortcut = new FakeShortcut();
        var task = new FakeTask(StartupTaskState.Enabled);
        var model = new LogonModel(Plain, shortcut, task);

        await model.RefreshAsync();
        Assert.Equal(new LogonView(false, true), model.View);
        await model.SetAsync(true);
        Assert.True(shortcut.On);
        Assert.Equal(new LogonView(true, true), model.View);
        await model.SetAsync(false);
        Assert.False(shortcut.On);
        Assert.Empty(task.Calls);
    }

    [Fact]
    public async Task PackagedUsesTheStartupTaskAndNeverTheStartupFolder()
    {
        var shortcut = new FakeShortcut { On = true }; // the other install's real shortcut
        var task = new FakeTask(StartupTaskState.Disabled);
        var model = new LogonModel(Packaged, shortcut, task);

        Assert.Equal(LogonView.Loading, model.View); // off and not changeable until the task answers
        await model.RefreshAsync();
        Assert.Equal(new LogonView(false, true), model.View); // not the shortcut's "on"
        await model.SetAsync(true);
        Assert.Equal(new LogonView(true, true), model.View);
        await model.SetAsync(false);
        Assert.Equal(new LogonView(false, true), model.View);
        Assert.Equal(["get", "enable", "disable", "get"], task.Calls);
        Assert.Equal(0, shortcut.Calls);
        Assert.True(shortcut.On);
    }

    [Theory]
    [InlineData(StartupTaskState.Enabled, true, true)]
    [InlineData(StartupTaskState.Disabled, false, true)]
    [InlineData(StartupTaskState.EnabledByPolicy, true, false)]
    [InlineData(StartupTaskState.DisabledByUser, false, false)]
    [InlineData(StartupTaskState.DisabledByPolicy, false, false)]
    public void EachTaskStateShowsTheSwitchTheRightWay(StartupTaskState state, bool on, bool canChange)
    {
        var view = LogonView.FromTask(state);
        Assert.Equal(on, view.IsOn);
        Assert.Equal(canChange, view.CanChange);
    }

    [Fact]
    public void WhenWindowsHasItOffTheAppSaysWhereToTurnItOn()
    {
        var user = LogonView.FromTask(StartupTaskState.DisabledByUser);
        Assert.Contains("Settings > Apps > Startup", user.Note);
        Assert.True(user.ShowSettingsButton);
        var policy = LogonView.FromTask(StartupTaskState.DisabledByPolicy);
        Assert.Contains("Settings > Apps > Startup", policy.Note);
        Assert.True(policy.ShowSettingsButton);
        var forced = LogonView.FromTask(StartupTaskState.EnabledByPolicy);
        Assert.NotNull(forced.Note);
        Assert.False(forced.ShowSettingsButton);
        Assert.Null(LogonView.FromTask(StartupTaskState.Enabled).Note);
        Assert.Equal("ms-settings:startupapps", LogonView.SettingsUri);
    }

    [Fact]
    public async Task TurningItOnWhileWindowsHasItOffStaysOff()
    {
        var task = new FakeTask(StartupTaskState.DisabledByUser);
        var model = new LogonModel(Packaged, new FakeShortcut(), task);
        await model.SetAsync(true);
        Assert.False(model.View.IsOn);
        Assert.False(model.View.CanChange);
        Assert.True(model.View.ShowSettingsButton);
    }

    [Fact]
    public async Task AFailedReadIsAnOffSwitchWithALineAndTheFault()
    {
        var faults = new List<Exception>();
        var model = new LogonModel(Packaged, new FakeShortcut(), new FakeTask(StartupTaskState.Enabled) { Throws = true }, faults.Add);
        await model.RefreshAsync();
        Assert.False(model.View.IsOn);
        Assert.False(model.View.CanChange);
        Assert.Equal(LogonView.Unreadable, model.View.Note);
        Assert.Single(faults);
    }

    [Fact]
    public async Task ChangedFiresWhenTheViewChangesAndOnTheFirstRead()
    {
        var model = new LogonModel(Packaged, new FakeShortcut(), new FakeTask(StartupTaskState.Disabled));
        var changes = 0;
        model.Changed += () => changes++;
        await model.RefreshAsync();
        Assert.Equal(1, changes);
        await model.RefreshAsync();
        Assert.Equal(1, changes);
        await model.SetAsync(true);
        Assert.Equal(2, changes);
    }

    [Theory]
    [InlineData(StartupTaskState.Disabled)]
    [InlineData(StartupTaskState.DisabledByUser)]
    public async Task ARequestThatEndsOffPublishesOffNeverTheClicksGuess(StartupTaskState after)
    {
        var task = new FakeTask(StartupTaskState.Disabled) { AfterEnable = after };
        var model = new LogonModel(Packaged, new FakeShortcut(), task);
        await model.RefreshAsync();
        await model.SetAsync(true);
        Assert.False(model.View.IsOn);
        Assert.Equal(after == StartupTaskState.DisabledByUser ? LogonView.TurnedOffInWindows : null, model.View.Note);
    }

    [Fact]
    public async Task ARequestThatThrowsPublishesOffWithTheUnreadableLine()
    {
        var faults = new List<Exception>();
        var task = new FakeTask(StartupTaskState.Disabled) { ThrowOnEnable = true };
        var model = new LogonModel(Packaged, new FakeShortcut(), task, faults.Add);
        await model.RefreshAsync();
        await model.SetAsync(true);
        Assert.False(model.View.IsOn);
        Assert.Equal(LogonView.Unreadable, model.View.Note);
        Assert.Single(faults);
    }

    [Fact]
    public async Task ADisableShowsWhatTheTaskReportsAfterwards()
    {
        var task = new FakeTask(StartupTaskState.Enabled) { KeepsState = true };
        var model = new LogonModel(Packaged, new FakeShortcut(), task);
        await model.RefreshAsync();
        await model.SetAsync(false);
        Assert.True(model.View.IsOn); // Disable() did not take: the box says so
    }

    [Fact]
    public async Task AToggleWhileARequestIsInFlightIsIgnored()
    {
        var gate = new TaskCompletionSource<StartupTaskState>();
        var task = new FakeTask(StartupTaskState.Disabled) { EnableGate = gate };
        var model = new LogonModel(Packaged, new FakeShortcut(), task);
        await model.RefreshAsync();
        var first = model.SetAsync(true);
        await model.SetAsync(false); // ignored
        Assert.Equal(["get", "enable"], task.Calls);
        gate.SetResult(StartupTaskState.Enabled);
        await first;
        Assert.True(model.View.IsOn);
        Assert.Equal(["get", "enable"], task.Calls);
    }

    // --- Settings ---

    private sealed class Host(IPackageInfo package, ILogonControl? logon = null) : ISettingsHost
    {
        public bool OpenAtLogon { get; set; }
        public string? ShimPath => ShimPathDisplay.For(package, @"C:\Program Files\WindowsApps\Askysh.BenchBar_0.9.0.0_x64__0f196q1bwh8q6\benchbar.exe", Local);
        public IPackageInfo Package => package;
        public ILogonControl? Logon => logon;
        public int StartupSettings { get; private set; }
        public void OpenStartupSettings() => StartupSettings++;
        public void ApplyAppearance(AppearanceMode mode) { }
        public void ApplyRunner(string id) { }
        public void ApplyNotifications(bool on) { }
    }

    private static SettingsModel Settings(Host host)
    {
        var path = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"), "config.json");
        return new SettingsModel(TrayConfig.Load(path), host, new SetupFixture().Service, () => { });
    }

    [Fact]
    public void PackagedSettingsShowTheAliasAndNoUpdateCheck()
    {
        var model = Settings(new Host(Packaged));
        Assert.Equal(PackageInfo.AliasPath(Local), model.CliPathText);
        Assert.DoesNotContain("WindowsApps\\Askysh", model.CliPathText);
        Assert.False(model.ShowsUpdateCheck);
        Assert.True(model.IsPackaged);
    }

    [Fact]
    public void UnpackagedSettingsShowTheShimNextToTheTrayAndTheUpdateCheck()
    {
        var model = Settings(new Host(Plain));
        Assert.Contains("WindowsApps", model.CliPathText); // the host's own path, unchanged
        Assert.True(model.ShowsUpdateCheck);
        Assert.False(model.IsPackaged);
    }

    [Fact]
    public async Task SettingsUseTheLogonControlWhenThereIsOne()
    {
        var logon = new LogonModel(Packaged, new FakeShortcut(), new FakeTask(StartupTaskState.DisabledByUser));
        var host = new Host(Packaged, logon);
        var model = Settings(host);
        var changes = 0;
        model.Changed += () => changes++;

        Assert.Equal(LogonView.Loading, model.LogonView);
        await model.LoadLogonAsync();
        Assert.True(changes >= 1);
        Assert.Equal(LogonView.FromTask(StartupTaskState.DisabledByUser), model.LogonView);
        Assert.False(model.OpenAtLogon);
        model.OpenStartupSettings();
        Assert.Equal(1, host.StartupSettings);
        model.Detach();
    }

    [Fact]
    public void WithoutALogonControlSettingsKeepTheBooleanSwitch()
    {
        var host = new Host(Plain) { OpenAtLogon = true };
        var model = Settings(host);
        Assert.Equal(new LogonView(true, true), model.LogonView);
        model.OpenAtLogon = false;
        Assert.False(host.OpenAtLogon);
    }

    // --- updates and the shim path ---

    [Fact]
    public void OnlyAnUnpackagedTrayAsksGitHub()
    {
        Assert.True(UpdatePolicy.ChecksGitHub(Plain));
        Assert.False(UpdatePolicy.ChecksGitHub(Packaged));
        Assert.Equal("Updates come from the Microsoft Store", UpdatePolicy.StoreLine);
    }

    [Fact]
    public void ThePackagedShimPathIsTheAliasAndTheOtherIsAsGiven()
    {
        const string versioned = @"C:\Program Files\WindowsApps\Askysh.BenchBar_0.9.0.0_x64__0f196q1bwh8q6\benchbar.exe";
        Assert.Equal(PackageInfo.AliasPath(Local), ShimPathDisplay.For(Packaged, versioned, Local));
        Assert.Equal(PackageInfo.AliasPath(Local), ShimPathDisplay.For(Packaged, null, Local));
        Assert.Equal(versioned, ShimPathDisplay.For(Plain, versioned, Local));
        Assert.Null(ShimPathDisplay.For(Plain, null, Local));
    }

    [Fact]
    public void TheVersionMismatchNoticeStillSaysSoWhenPackaged() =>
        Assert.NotNull(VersionMismatch.Notice("benchbar.exe 0.8.1", "0.8.2", PackageInfo.AliasPath(Local)));

    // --- two installs ---

    [Fact]
    public void TheNoticeAppliesOnlyToThePackageWithTheOtherCopyPresent()
    {
        var other = TwoInstalls.UnpackagedTrayPath(Local);
        Assert.Equal(Path.Combine(Local, "Programs", "BenchBar", "BenchBarTray.exe"), other);
        Assert.True(TwoInstalls.Applies(Packaged, Local, p => p == other));
        Assert.False(TwoInstalls.Applies(Packaged, Local, _ => false));
        Assert.False(TwoInstalls.Applies(Plain, Local, _ => true)); // the unpackaged tray says nothing
    }

    [Fact]
    public void ADismissedNoticeStaysAwayUntilTheConditionChanges()
    {
        Assert.True(TwoInstalls.ShouldShow(applies: true, dismissed: false, out var keep));
        Assert.False(keep);
        Assert.False(TwoInstalls.ShouldShow(applies: true, dismissed: true, out keep)); // dismissed: quiet
        Assert.True(keep);
        Assert.False(TwoInstalls.ShouldShow(applies: false, dismissed: true, out keep)); // the old install is gone: forget the dismissal
        Assert.False(keep);
        Assert.True(TwoInstalls.ShouldShow(applies: true, dismissed: keep, out _)); // and it came back: tell once more
    }

    [Fact]
    public void TheUninstallLineIsTheDocumentedOne()
    {
        Assert.Equal("& ([scriptblock]::Create((irm https://raw.githubusercontent.com/askysh/benchbar/main/install.ps1))) -Uninstall", TwoInstalls.UninstallLine);
        Assert.Contains("uninstall", TwoInstalls.Text);
    }

    [Fact]
    public void TheDismissalIsKeptInTheConfig()
    {
        var path = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"), "config.json");
        var config = TrayConfig.Load(path);
        Assert.False(config.TwoInstallsDismissed);
        config.TwoInstallsDismissed = true;
        config.Save();
        Assert.True(TrayConfig.Load(path).TwoInstallsDismissed);
    }

    [Fact]
    public void NoTextHereHoldsADash()
    {
        var all = string.Concat(LogonView.TurnedOffInWindows, LogonView.TurnedOffByPolicy, LogonView.TurnedOnByPolicy, LogonView.Unreadable,
            LogonView.SettingsButton, UpdatePolicy.StoreLine, TwoInstalls.Text, TwoInstalls.CopyLabel, TwoInstalls.UninstallLine);
        Assert.DoesNotContain('\u2014', all);
        Assert.DoesNotContain('\u2013', all);
    }
}
