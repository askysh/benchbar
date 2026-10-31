using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>The 0.8.1 live QA fixes that show on screen: icons, headings, advice lines, hints and the empty states.</summary>
public class Fixes081ViewTests
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

    /// <summary>A model on the Install page after the given install file ran (the Linux password question is answered).</summary>
    private static async Task<WizardModel> InstallModel(string install)
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var m = new WizardModel(WindowViewTests.Fixture(ready: true, install: install), new Host());
        m.AskLinuxPassword = _ => Task.FromResult<Secret?>(Secret.From("linux-pass"));
        await m.ChooseNewBench();
        await m.ContinueFromCheckAsync();
        m.SetAdminPassword(Secret.From("admin-pass"));
        await m.ReviewAsync();
        await m.StartInstallAsync();
        return m;
    }

    private static WizardView ViewOf(WizardModel model)
    {
        var view = new WizardView(model, new WizardActions());
        view.Update();
        return view;
    }

    // --- icons ---

    [Fact]
    public void AGlyphWithoutABrushInheritsItsColorInsteadOfBeingDrawnInNone() => Sta.Run(() =>
    {
        var glyph = Ui.Glyph("", 14);
        Assert.Equal(DependencyProperty.UnsetValue, glyph.ReadLocalValue(TextBlock.ForegroundProperty));
        Assert.Equal("Segoe Fluent Icons, Segoe MDL2 Assets", glyph.FontFamily.Source);
        var colored = Ui.Glyph("", 14, System.Windows.Media.Brushes.Red);
        Assert.Same(System.Windows.Media.Brushes.Red, colored.Foreground);
    });

    [Fact]
    public void AMoreButtonHasANameAndATooltip() => Sta.Run(() =>
    {
        var button = PagePanels.MoreButton("More actions for one.localhost", [new PageMenuEntry("Backup", true, false, () => { })], true);
        Assert.Equal("More actions for one.localhost", AutomationProperties.GetName(button));
        Assert.Equal("More actions", button.ToolTip);
        var glyph = Assert.IsType<TextBlock>(button.Content);
        Assert.Equal(DependencyProperty.UnsetValue, glyph.ReadLocalValue(TextBlock.ForegroundProperty));
    });

    // --- the wizard ---

    [Fact]
    public async Task TheHeadingIsNamedByItsTextNotPageTitle()
    {
        var model = await WindowViewTests.ModelAt(WizardPage.Welcome);
        Sta.Run(() =>
        {
            var title = VisualHeading(ViewOf(model));
            Assert.Equal("Welcome to BenchBar", AutomationProperties.GetName(title));
        });
    }

    private static TextBlock VisualHeading(WizardView view)
    {
        view.Measure(new Size(1000, 700));
        view.Arrange(new Rect(0, 0, 1000, 700));
        view.UpdateLayout();
        return VisualWalk(view).OfType<TextBlock>().First(t => t.Text == view.TitleText);
    }

    private static IEnumerable<DependencyObject> VisualWalk(DependencyObject root)
    {
        yield return root;
        var count = System.Windows.Media.VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < count; i++)
        {
            foreach (var d in VisualWalk(System.Windows.Media.VisualTreeHelper.GetChild(root, i))) yield return d;
        }
    }

    [Fact]
    public async Task AFailedInstallSaysInstallFailedAndWhatToDo()
    {
        var model = await WindowViewTests.ModelAt(WizardPage.Install);
        Sta.Run(() =>
        {
            var view = ViewOf(model);
            Assert.Equal("Install Failed", view.TitleText);
            var texts = Texts(view);
            Assert.DoesNotContain(texts, t => t.StartsWith("This takes a while", StringComparison.Ordinal));
            Assert.Contains("What to do:", texts);
            Assert.NotNull(FindButton(view, "Report this problem"));
            Assert.NotNull(FindButton(view, "Open the install log"));
            Assert.NotNull(FindButton(view, "Retry"));
        });
    }

    [Fact]
    public async Task AWrongLinuxPasswordTellsWhichPasswordItIsAndLeavesNoFocusRectangle()
    {
        var model = await InstallModel("install-wrong-password.jsonl");
        Assert.Equal(InstallPhase.NeedsLinuxPassword, model.Phase);
        Sta.Run(() =>
        {
            var view = ViewOf(model);
            Assert.Equal("Wrong Linux Password", view.TitleText);
            Assert.Contains("The Linux password is the one you chose for your Linux user. Type it again.", Texts(view));
            Assert.Null(view.FocusVisualStyle);
            Assert.False(view.Focusable);
        });
    }

    [Fact]
    public async Task TheRootPasswordHintIsReadNotCopied()
    {
        var model = await InstallModel("install-root-password.jsonl");
        Assert.Equal(InstallPhase.NeedsRootPassword, model.Phase);
        Sta.Run(() =>
        {
            var view = ViewOf(model);
            Assert.Contains("Pass MARIADB_ROOT_PASSWORD.", Texts(view));
            Assert.Null(FindButton(view, "Copy Fix")); // a sentence is not a command
        });
    }

    [Fact]
    public async Task TheReviewPageGivesATimeEstimate()
    {
        var model = await WindowViewTests.ModelAt(WizardPage.Review);
        Sta.Run(() => Assert.Contains("The install takes about 15 to 30 minutes, most of it downloads.", Texts(ViewOf(model))));
    }

    [Fact]
    public async Task TheDonePageSaysWhereTheIconMayHide()
    {
        var model = await WindowViewTests.ModelAt(WizardPage.Done);
        Sta.Run(() => Assert.Contains(Texts(ViewOf(model)), t => t.Contains("^ arrow") && t.Contains("Other system tray icons")));
    }

    [Fact]
    public async Task NewBenchSaysWhatReviewWaitsFor()
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var model = new WizardModel(WindowViewTests.Fixture(ready: true), new Host());
        await model.ChooseNewBench();
        await model.ContinueFromCheckAsync();
        Assert.Equal(WizardPage.NewBench, model.Page);
        Sta.Run(() =>
        {
            var view = ViewOf(model);
            Assert.False(PageKit.ButtonNamed(view, "Review").IsEnabled);
            Assert.Contains("Review is off. Choose the Administrator password for the site.", Texts(view));
        });
    }

    [Fact]
    public async Task CreateUserSaysWhatItWaitsFor()
    {
        var model = await WindowViewTests.ModelAt(WizardPage.LinuxUser);
        Sta.Run(() =>
        {
            var view = ViewOf(model);
            Assert.False(PageKit.ButtonNamed(view, "Create User").IsEnabled);
            Assert.Contains(Texts(view), t => t.StartsWith("Create User is off. Choose a password", StringComparison.Ordinal));
        });
    }

    [Fact]
    public async Task TheCheckPageShowsStepTitlesAndNoRawIds()
    {
        var model = await WindowViewTests.ModelAt(WizardPage.Check);
        Sta.Run(() =>
        {
            var texts = Texts(ViewOf(model));
            Assert.Contains("waits for Windows Subsystem for Linux", texts);
            Assert.DoesNotContain(texts, t => t.Contains("wsl_feature", StringComparison.Ordinal));
        });
    }

    [Fact]
    public void WelcomeChoicesAreAllTheSameWidth() => Sta.Run(() =>
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var model = new WizardModel(WindowViewTests.Fixture(), new Host());
        var view = ViewOf(model);
        view.Measure(new Size(1000, 700));
        view.Arrange(new Rect(0, 0, 1000, 700));
        view.UpdateLayout();
        var choices = VisualWalk(view).OfType<Button>().Where(b => b.Content is StackPanel).ToList();
        Assert.Equal(3, choices.Count);
        Assert.Single(choices.Select(b => Math.Round(b.ActualWidth)).Distinct());
    });

    // --- the confirmation ---

    [Fact]
    public void TheRestartQuestionIsAThemedDialogWhoseDefaultIsCancel() => Sta.Run(() =>
    {
        var dialog = new ConfirmDialog("Restart Windows", "Windows restarts in 15 seconds. Save your work first.", "Restart Now", Theme, null);
        Assert.Contains("Windows restarts in 15 seconds. Save your work first.", Texts(dialog));
        var cancel = ButtonNamed(dialog, "Cancel");
        Assert.True(cancel.IsDefault);
        Assert.True(cancel.IsCancel);
        Assert.False(dialog.Confirm.IsDefault);
        AssertEveryControlIsNamed(dialog);
    });

    // --- the flyout and the window ---

    [Fact]
    public void AnEmptyFlyoutOffersToSetUpABench() => Sta.Run(() =>
    {
        var asked = 0;
        var view = new FlyoutView(new FlyoutActions { SetUpBench = () => asked++ });
        view.SetSnapshot(new TraySnapshot([]), "none up");
        Assert.Equal(FlyoutMode.Empty, view.Mode);
        Assert.Equal(["Set Up a Bench"], view.CardButtons);
        Click(view.CardButton!);
        Assert.Equal(1, asked);
    });

    [Fact]
    public void AMissingDistroIsNotOfferedAStart() => Sta.Run(() =>
    {
        var asked = 0;
        var view = new FlyoutView(new FlyoutActions { SetUpBench = () => asked++, StartDistro = () => throw new InvalidOperationException("must not start") });
        view.SetSnapshot(new TraySnapshot([], DistroStopped: true, Distro: "BenchBarQA", DistroMissing: true), "distro not installed");
        Assert.Equal("BenchBarQA is not installed", view.CardTitle);
        Assert.Equal(["Set Up a Bench"], view.CardButtons);
        Click(view.CardButton!);
        Assert.Equal(1, asked);
    });

    [Fact]
    public void ThePlusMenuUsesTitleCaseAndHasATooltip() => Sta.Run(() =>
    {
        var window = new MainWindow(new MainActions(), Theme);
        var add = ButtonNamed(window, "Add a bench");
        Assert.Equal("Add a Bench", add.ToolTip);
        Assert.Equal(["New Bench...", "I Already Have a Bench..."], add.ContextMenu!.Items.OfType<MenuItem>().Select(i => (string)i.Header));
    });

    [Fact]
    public void TheMainWindowNamesAMissingDistroInItsCard() => Sta.Run(() =>
    {
        var window = new MainWindow(new MainActions(), Theme);
        window.SetSnapshot(new TraySnapshot([], DistroStopped: true, Distro: "BenchBarQA", DistroMissing: true), "distro not installed");
        Assert.Equal("missing|BenchBarQA", window.ContentKind);
        Assert.Contains("BenchBarQA is not installed", Texts(window));
        Assert.NotNull(FindButton(window, "Set Up BenchBar"));
        Assert.Null(FindButton(window, "Start"));
    });
}
