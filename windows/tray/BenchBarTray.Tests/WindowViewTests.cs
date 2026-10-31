using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;

namespace BenchBar.Tray.Tests;

public class WindowViewTests
{
    private sealed class Host : IWizardHost
    {
        public void SetResumeAfterLogon(bool on) { }
        public bool RestartWindows() => true;
        public void AllowForeground() { }
        public string WindowsUserName => "Akash";
        public string? ConfiguredDistro => "Ubuntu-24.04";
        public bool Notifications { get; set; } = true;
        public bool OpenAtLogon { get; set; }
        public void OpenUrl(string url) { }
        public void CopyText(string text) { }
    }

    /// <summary>A scratch copy of fixtures/setup in the DIR/setup layout; check.json is replaced by <paramref name="check"/> (ready or not).</summary>
    internal static FixtureSetupService Fixture(string check = "check.json", bool ready = false, string? install = null, bool noUser = false, string? plan = null, string? run = null)
    {
        string? source = null;
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "fixtures", "setup");
            if (Directory.Exists(candidate)) { source = candidate; break; }
        }
        Assert.NotNull(source);
        var root = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"));
        var target = Path.Combine(root, "setup");
        Directory.CreateDirectory(target);
        foreach (var file in Directory.GetFiles(source)) File.Copy(file, Path.Combine(target, Path.GetFileName(file)));
        var text = File.ReadAllText(Path.Combine(source, check));
        if (ready) text = text.Replace("\"ready\":false", "\"ready\":true");
        if (noUser)
            text = text.Replace("{\"id\":\"distro_user\",\"status\":\"ok\",\"title\":\"Linux user\",\"detail\":\"akash\",\"action\":null", "{\"id\":\"distro_user\",\"status\":\"missing\",\"title\":\"Linux user\",\"detail\":\"no user\",\"action\":\"distro_user\"");
        File.WriteAllText(Path.Combine(target, "check.json"), text);
        if (run is not null) File.Copy(Path.Combine(source, run), Path.Combine(target, "run-wsl_enable.jsonl"), overwrite: true);
        if (plan is not null) File.WriteAllText(Path.Combine(target, "plan.jsonl"), plan);
        if (install is not null) File.Copy(Path.Combine(source, install), Path.Combine(target, "install.jsonl"), overwrite: true);
        return new FixtureSetupService(root);
    }

    private static Secret Pass(string text) => Secret.From(text);

    /// <summary>Drives a model to a page with no WPF object alive yet, so no dispatcher context is captured.</summary>
    internal static async Task<WizardModel> ModelAt(WizardPage page)
    {
        SynchronizationContext.SetSynchronizationContext(null);
        switch (page)
        {
            case WizardPage.Welcome:
                return new WizardModel(Fixture(), new Host());
            case WizardPage.CliOnly:
                var cli = new WizardModel(Fixture(), new Host());
                cli.ChooseCommandLineOnly();
                return cli;
            case WizardPage.Check:
                var check = new WizardModel(Fixture("check-fresh.json"), new Host());
                await check.ChooseNewBench();
                return check;
            case WizardPage.LinuxUser:
                var user = new WizardModel(Fixture(noUser: true), new Host());
                await user.ChooseNewBench();
                await user.RunStepAsync(SetupIds.DistroUser);
                return user;
            case WizardPage.ExistingBench:
                var existing = new WizardModel(Fixture(ready: true), new Host());
                await existing.ChooseExistingBench();
                await existing.ContinueFromCheckAsync();
                return existing;
            default:
                var m = new WizardModel(Fixture(ready: true, install: page == WizardPage.Install ? "install-failed.jsonl" : null), new Host());
                await m.ChooseNewBench();
                await m.ContinueFromCheckAsync();
                if (page == WizardPage.NewBench) return m;
                m.SetAdminPassword(Pass("admin-pass"));
                await m.ReviewAsync();
                if (page == WizardPage.Review) return m;
                m.SetPassword(Pass("linux-pass"));
                await m.StartInstallAsync();
                return m;
        }
    }

    private static IEnumerable<DependencyObject> Walk(DependencyObject root)
    {
        yield return root;
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
        {
            foreach (var d in Walk(child)) yield return d;
        }
    }

    private static void AssertEveryControlIsNamed(DependencyObject root)
    {
        foreach (var d in Walk(root))
        {
            var named = !string.IsNullOrWhiteSpace(AutomationProperties.GetName(d));
            switch (d)
            {
                case Button { Content: string text } when text.Length > 0:
                    break;
                case Button or TextBox or PasswordBox or ComboBox or CheckBox or RadioButton or ListBox or TabControl:
                    Assert.True(named, $"{d.GetType().Name} has no AutomationProperties.Name");
                    break;
            }
        }
    }

    public static TheoryData<WizardPage, string> Pages => new()
    {
        { WizardPage.Welcome, "Welcome to BenchBar" },
        { WizardPage.CliOnly, "Just the Command Line Tool" },
        { WizardPage.Check, "Check Your PC" },
        { WizardPage.LinuxUser, "Create Your Linux User" },
        { WizardPage.ExistingBench, "Use an Existing Bench" },
        { WizardPage.NewBench, "New Bench" },
        { WizardPage.Review, "Review" },
        { WizardPage.Install, "Install Failed" }, // the fixture install fails
        { WizardPage.Done, "Your Bench Is Ready" },
    };

    [Theory]
    [MemberData(nameof(Pages))]
    public async Task EveryWizardPageBuildsWithNamedControls(WizardPage page, string title)
    {
        var model = await ModelAt(page);
        Assert.Equal(page, model.Page);
        Sta.Run(() =>
        {
            var view = new WizardView(model, new WizardActions());
            view.Update();
            Assert.Equal(title, view.TitleText);
            AssertEveryControlIsNamed(view);
        });
    }

    [Fact]
    public async Task TheCheckPageShowsShieldsAndDisabledWaitingRows()
    {
        var model = await ModelAt(WizardPage.Check);
        Sta.Run(() =>
        {
            var view = new WizardView(model, new WizardActions());
            view.Update();
            var buttons = Walk(view).OfType<Button>().ToList();
            var turnOn = buttons.Single(b => AutomationProperties.GetName(b).StartsWith("Turn On"));
            Assert.True(turnOn.IsEnabled);
            Assert.IsType<StackPanel>(turnOn.Content); // the shield and the word
            var setUp = buttons.Where(b => AutomationProperties.GetName(b).StartsWith("Set Up:")).ToList();
            Assert.NotEmpty(setUp);
            Assert.All(setUp, b => Assert.False(b.IsEnabled));
            var texts = Walk(view).OfType<TextBlock>().Select(t => t.Text).ToList();
            Assert.Contains(WizardModel.AdminNote, texts);
            Assert.False(buttons.Single(b => b.Content as string == "Continue").IsEnabled);
        });
    }

    [Fact]
    public async Task TheRestartButtonAsksBeforeItRestarts()
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var model = new WizardModel(Fixture("check-reboot.json"), new Host());
        await model.ChooseNewBench();
        var asked = 0;
        Sta.Run(() =>
        {
            var view = new WizardView(model, new WizardActions { ConfirmRestart = () => { asked++; return false; } });
            view.Update();
            var restart = Walk(view).OfType<Button>().First(b => AutomationProperties.GetName(b).StartsWith("Restart Now"));
            restart.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        });
        Assert.Equal(1, asked);
        Assert.False(model.RestartRequested);
    }

    [Fact]
    public async Task TheInstallPageShowsTheFailureWithRetry()
    {
        var model = await ModelAt(WizardPage.Install);
        Assert.Equal(InstallPhase.Failed, model.Phase);
        Sta.Run(() =>
        {
            var view = new WizardView(model, new WizardActions());
            view.Update();
            var buttons = Walk(view).OfType<Button>().ToList();
            var retry = buttons.Single(b => b.Content as string == "Retry");
            Assert.Equal(Visibility.Visible, retry.Visibility);
            Assert.Equal(Visibility.Collapsed, buttons.Single(b => b.Content as string == "Stop").Visibility);
            Assert.Contains(Walk(view).OfType<TextBlock>(), t => t.Text.Contains("bench init failed"));
        });
    }

    [Fact]
    public void ThePasswordDialogNamesTheStepCount() => Sta.Run(() =>
    {
        var dialog = new LinuxPasswordDialog(new LinuxPasswordRequest(2, WasWrong: true), new ResolvedTheme(true, true), null);
        var texts = Walk((DependencyObject)dialog.Content).OfType<TextBlock>().Select(t => t.Text).ToList();
        Assert.Contains("BenchBar needs your Linux password for 2 steps that use sudo.", texts);
        Assert.Contains(texts, t => t.Contains("did not accept"));
        Assert.Null(dialog.Answer);
        AssertEveryControlIsNamed(dialog);
    });

    [Fact]
    public void TheMainWindowListsBenchesWithTheirSites() => Sta.Run(() =>
    {
        var bench = new BenchStatus("frappe-bench", "/home/a/frappe-bench", BenchState.Running, null, "http://one.localhost:8000", "one.localhost")
        {
            Sites = [new SiteInfo("one.localhost", true), new SiteInfo("two.localhost", false)],
        };
        var window = new MainWindow(new MainActions(), new ResolvedTheme(true, true));
        window.SetSnapshot(new TraySnapshot([bench]), "1 of 1 up");
        Assert.Equal(3, window.Items.Count);
        Assert.Equal("overview", window.ContentKind);
        Assert.Equal(["Stop", "Restart", "Open Site", "Logs", "Health", "Open in VS Code"], window.Overview.ButtonLabels);
        AssertEveryControlIsNamed(window);
    });

    [Fact]
    public void TheMainWindowShowsTheEmptyStateTheDistroCardAndProblems() => Sta.Run(() =>
    {
        var window = new MainWindow(new MainActions(), new ResolvedTheme(true, true));
        window.SetSnapshot(new TraySnapshot([]), "none up");
        Assert.Equal("empty", window.ContentKind);
        window.SetSnapshot(new TraySnapshot([], DistroStopped: true, Distro: "Ubuntu-24.04"), "distro stopped");
        Assert.Equal("stopped|Ubuntu-24.04", window.ContentKind);
        window.SetSnapshot(new TraySnapshot([], Problem: "benchbar.exe was not found."), "needs attention");
        Assert.Equal("problem", window.ContentKind);
    });

    [Fact]
    public void TheUpdateBannerOffersTheReleaseAndCanBeDismissed() => Sta.Run(() =>
    {
        var window = new MainWindow(new MainActions(), new ResolvedTheme(true, true));
        var dismissed = 0;
        window.SetUpdate(new UpdateOffer("0.9.0", "https://example.test/r"), () => dismissed++);
        Assert.Equal("0.9.0", window.Offer!.Version);
        // the beta banner comes first, the update banner second
        var banner = (Border)((DockPanel)((Grid)window.Content).Children[1]).Children[1];
        Assert.Equal(Visibility.Visible, banner.Visibility);
        var later = Walk(banner).OfType<Button>().Single(b => b.Content as string == "Not Now");
        later.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Assert.Equal(1, dismissed);
        Assert.Null(window.Offer);
        Assert.Equal(Visibility.Collapsed, banner.Visibility);
    });

    [Fact]
    public void TheWizardReplacesTheContentAndCloseBringsTheHomeBack() => Sta.Run(() =>
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var window = new MainWindow(new MainActions(), new ResolvedTheme(true, true));
        window.SetSnapshot(new TraySnapshot([]), "none up");
        var model = new WizardModel(Fixture(), new Host());
        window.ShowWizard(new WizardView(model, new WizardActions()));
        Assert.Equal(MainMode.Wizard, window.Mode);
        window.SetSnapshot(new TraySnapshot([]), "none up"); // a poll must not push the wizard out
        Assert.Equal(MainMode.Wizard, window.Mode);
        window.CloseWizard();
        Assert.Equal(MainMode.Home, window.Mode);
        Assert.Equal("empty", window.ContentKind);
    });

    [Fact]
    public void SettingsAndAboutBuildWithNamedControls() => Sta.Run(() =>
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var service = Fixture();
        var config = TrayConfig.Load(Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"), "config.json"));
        var model = new SettingsModel(config, new SettingsHostStub(), service, () => { });
        var settings = new SettingsWindow(model, () => RunnerSet.BuiltIn, _ => { }, new ResolvedTheme(true, true));
        AssertEveryControlIsNamed(settings);
        var about = new AboutWindow(new AboutActions { AppVersion = "0.9.0+abc" }, new ResolvedTheme(true, true));
        AssertEveryControlIsNamed(about);
        var texts = Walk(about).OfType<TextBlock>().Select(t => t.Text).ToList();
        Assert.Contains("0.9.0", texts);
        Assert.Contains(texts, t => t.Contains("MIT License"));
        Assert.Contains(Walk(about).OfType<TextBox>(), t => t.Text == "claude mcp add benchbar -- benchbar.exe mcp");
    });

    private sealed class SettingsHostStub : ISettingsHost
    {
        public bool OpenAtLogon { get; set; }
        public void ApplyAppearance(AppearanceMode mode) { }
        public void ApplyRunner(string id) { }
        public void ApplyNotifications(bool on) { }
        public string? ShimPath => null;
    }

    [Fact]
    public void TheOverviewShowsAFailureUntilTheStateChangesAndAMissingEditor() => Sta.Run(() =>
    {
        var actions = new OverviewActions
        {
            StartStop = _ => Task.FromResult(ActionResult.Failure("port 8000 is taken")),
            OpenEditor = _ => VsCodeOutcome.NotFound,
            EditorName = () => "Cursor",
        };
        var view = new OverviewView(actions);
        var stopped = new BenchStatus("a", "/a", BenchState.Stopped, null, null, null);
        view.Bind(stopped, null);
        Assert.Equal("Open in Cursor", view.ButtonLabels[^1]);
        Assert.False(OverviewButtons.For(stopped, false).CanRestart);
        view.StartStopButton!.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        // the failed action completes synchronously, so the line is there now
        Assert.Contains(Walk(view).OfType<TextBlock>(), t => t.Text == "port 8000 is taken");
        view.Bind(stopped with { State = BenchState.Running }, null);
        Assert.DoesNotContain(Walk(view).OfType<TextBlock>(), t => t.Text == "port 8000 is taken");
    });

    [Fact]
    public void TheEditorLauncherFollowsTheChoice()
    {
        var found = VsCode.FindEditor("cursor", pathVariable: @"C:\x", localAppData: @"C:\u", exists: p => p == @"C:\x\cursor.cmd");
        Assert.Equal(@"C:\x\cursor.cmd", found);
        Assert.Null(VsCode.FindEditor("insiders", pathVariable: @"C:\x", localAppData: @"C:\u", exists: _ => false));
        var user = VsCode.FindEditor("insiders", pathVariable: "", localAppData: @"C:\u", exists: p => p.EndsWith("code-insiders.cmd", StringComparison.Ordinal));
        Assert.Equal(@"C:\u\Programs\Microsoft VS Code Insiders\bin\code-insiders.cmd", user);
        Assert.Equal(@"C:\x\code.cmd", VsCode.Find(@"C:\x", @"C:\u", p => p == @"C:\x\code.cmd"));
    }

    [Fact]
    public void TheResumeFlagIsConsumedWhenTheWizardOpensForAResumeOnEitherPath()
    {
        var consumed = 0;
        var gate = new ResumeGate(() => consumed++);
        gate.Opening(resume: false); // a normal open, or + > New Bench
        Assert.Equal(0, consumed);
        gate.Opening(resume: true); // the tray started with --resume-setup
        gate.Opening(resume: true); // or a second instance signalled the running one
        Assert.Equal(2, consumed);
    }

    [Fact]
    public void RemovingAMissingResumeFlagIsHarmless()
    {
        var folder = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"));
        new StartupShortcut(folder, @"C: BenchBarTray.exe", StartupShortcut.ResumeFileName, StartupShortcut.ResumeArgument).Disable();
    }

    [Fact]
    public void ThePasswordDialogSaysTheUserAlreadyExisted() => Sta.Run(() =>
    {
        var dialog = new LinuxPasswordDialog(new LinuxPasswordRequest(1, false, UserExisted: true), new ResolvedTheme(true, true), null);
        Assert.Contains(Walk((DependencyObject)dialog.Content).OfType<TextBlock>(), t => t.Text.Contains("already existed"));
    });

    [Fact]
    public void TheResumeFlagIsItsOwnShortcutWithAnArgument()
    {
        var folder = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"));
        var flag = new StartupShortcut(folder, @"C:\Program Files\BenchBar\BenchBarTray.exe", StartupShortcut.ResumeFileName, StartupShortcut.ResumeArgument);
        Assert.EndsWith("BenchBar Setup Resume.lnk", flag.LinkPath);
        flag.Enable();
        Assert.True(File.Exists(flag.LinkPath));
        Assert.False(File.Exists(Path.Combine(folder, StartupShortcut.FileName))); // the normal logon shortcut is not touched
        flag.Disable();
        Assert.False(File.Exists(flag.LinkPath));
    }
}
