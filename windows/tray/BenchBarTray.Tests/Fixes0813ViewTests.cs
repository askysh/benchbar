using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>The 0.8.1 live recheck on screen: the plan fix and blockers, advice buttons, focus rectangles and the beta banner.</summary>
public class Fixes0813ViewTests
{
    private sealed class Host(List<string> copied) : IWizardHost
    {
        public void SetResumeAfterLogon(bool on) { }
        public bool RestartWindows() => true;
        public void AllowForeground() { }
        public string WindowsUserName => "Akash";
        public string? ConfiguredDistro => "Ubuntu-24.04";
        public bool Notifications { get; set; } = true;
        public bool OpenAtLogon { get; set; }
        public void OpenUrl(string url) { }
        public void CopyText(string text) => copied.Add(text);
    }

    private static async Task<WizardModel> ReviewModel(string plan, List<string> copied)
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var model = new WizardModel(WindowViewTests.Fixture(ready: true, plan: plan), new Host(copied));
        await model.ChooseNewBench();
        await model.ContinueFromCheckAsync();
        model.SetAdminPassword(Secret.From("admin-pass"));
        await model.ReviewAsync();
        return model;
    }

    private static WizardView ViewOf(WizardModel model)
    {
        var view = new WizardView(model, new WizardActions());
        view.Update();
        return view;
    }

    [Fact]
    public async Task AFailedPlanShowsItsFixUnderTheMessageAndCopiesOnlyACommand()
    {
        var copied = new List<string>();
        var model = await ReviewModel(
            "{\"schema_version\":1,\"event\":\"done\",\"exit\":1,\"error\":\"Port 3306 is in use.\",\"fix\":\"In the other distro run: sudo systemctl stop mariadb\"}\n", copied);
        Sta.Run(() =>
        {
            var view = ViewOf(model);
            Assert.Contains("Port 3306 is in use.", Texts(view));
            Assert.Contains("In the other distro run: sudo systemctl stop mariadb", Texts(view));
            Assert.Null(FindButton(view, "Copy the fix")); // a sentence is read, not copied
        });

        var command = await ReviewModel(
            "{\"schema_version\":1,\"event\":\"done\",\"exit\":1,\"error\":\"MariaDB is stopped.\",\"fix\":\"sudo systemctl start mariadb\"}\n", copied);
        Sta.Run(() =>
        {
            var view = ViewOf(command);
            Click(ButtonNamed(view, "Copy the fix"));
            Assert.Equal(["sudo systemctl start mariadb"], copied);
            AssertEveryControlIsNamed(view);
        });
    }

    [Fact]
    public async Task PlanBlockersAreListedWithTheirFix()
    {
        var model = await ReviewModel(
            "{\"schema_version\":1,\"event\":\"plan\",\"bench\":\"/b\",\"site\":\"s\",\"steps\":[],\"blockers\":[{\"id\":\"port_3306_in_use\",\"message\":\"Port 3306 is in use.\",\"fix\":\"sudo systemctl stop mariadb\"}]}\n"
            + "{\"schema_version\":1,\"event\":\"done\",\"exit\":1,\"error\":\"The plan has blockers.\"}\n", []);
        Sta.Run(() =>
        {
            var view = ViewOf(model);
            // a command fix sits in a read only box, so look at the text boxes too
            var all = string.Join("\n", Texts(view).Concat(Walk(view).OfType<TextBox>().Select(t => t.Text)));
            Assert.Contains("Port 3306 is in use.", all);
            Assert.Contains("sudo systemctl stop mariadb", all);
            // each once: the red error line and the plan fix are not repeated next to the blocker card
            Assert.Equal(1, all.Split("Port 3306 is in use.").Length - 1);
            Assert.Equal(1, all.Split("sudo systemctl stop mariadb").Length - 1);
            Assert.DoesNotContain("The plan has blockers.", all);
        });
    }

    [Fact]
    public async Task AnAdviceRowWithAnActionShowsSetUpAndSetUpEverythingStaysOff()
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var model = new WizardModel(WindowViewTests.Fixture(ready: true), new Host([]));
        await model.ChooseNewBench();
        Sta.Run(() =>
        {
            var view = ViewOf(model);
            Assert.True(ButtonNamed(view, "Set Up: WSL idle settings").IsEnabled);
            Assert.False(ButtonNamed(view, "Set up everything that is missing").IsEnabled); // advice is not run by it
            Assert.True(ButtonNamed(view, "Continue").IsEnabled);
        });
    }

    [Fact]
    public async Task NoPageContainerCanDrawAFocusRectangle()
    {
        var model = await WindowViewTests.ModelAt(WizardPage.Check);
        Sta.Run(() =>
        {
            var view = ViewOf(model);
            var containers = Walk(view).Where(d => d is Panel or Border or ScrollViewer or UserControl).Cast<FrameworkElement>().ToList();
            Assert.NotEmpty(containers);
            // a container that could take the focus must not draw a rectangle for it
            Assert.All(containers.Where(c => c.Focusable), c => Assert.Null(c.FocusVisualStyle));
            Assert.All(containers.OfType<ScrollViewer>(), s => Assert.False(s.Focusable));
            Assert.All(containers.OfType<ScrollViewer>(), s => Assert.Null(s.FocusVisualStyle));
            Assert.NotNull(FindButton(view, "Check this PC again")); // real controls are still there to take the focus
        });
    }

    [Fact]
    public async Task TheBetaBannerIsOneSlimLineAndGoesWhileTheWizardIsOpen()
    {
        var model = await WindowViewTests.ModelAt(WizardPage.Check);
        Sta.Run(() =>
        {
            var window = new MainWindow(new MainActions { BetaBannerVisible = () => true }, Theme);
            Assert.True(window.BetaBannerShown);
            var line = Walk(window).OfType<TextBlock>().Single(t => t.Text == BetaText.Banner);
            Assert.Equal(TextWrapping.NoWrap, line.TextWrapping);
            Assert.Equal(TextTrimming.CharacterEllipsis, line.TextTrimming);

            window.ShowWizard(ViewOf(model));
            Assert.False(window.BetaBannerShown); // the wizard needs the room
            window.CloseWizard();
            Assert.True(window.BetaBannerShown); // and it comes back, not dismissed
        });
    }

    [Fact]
    public async Task AStepTheUserStoppedOffersNoReportThisProblem()
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var model = new WizardModel(WindowViewTests.Fixture("check-fresh.json", run: "run-wsl_enable-cancelled.jsonl"), new Host([]));
        await model.ChooseNewBench();
        await model.RunStepAsync(SetupIds.WslFeature);
        Assert.Equal(WizardModel.CancelledMessage, model.StepMessages[SetupIds.WslFeature]);
        Sta.Run(() =>
        {
            var view = ViewOf(model);
            Assert.Contains(WizardModel.CancelledMessage, Texts(view)); // the row still says it
            Assert.Null(FindButton(view, "Report this problem: Windows Subsystem for Linux"));
        });
    }

    [Fact]
    public async Task TheReportABugFooterIsLastInTheTabOrder()
    {
        var model = await WindowViewTests.ModelAt(WizardPage.Check);
        Sta.Run(() =>
        {
            var view = ViewOf(model);
            var footer = ButtonNamed(view, "Report a Bug");
            var parent = (Grid)System.Windows.Media.VisualTreeHelper.GetParent(footer);
            var order = parent.Children.OfType<UIElement>().OrderBy(System.Windows.Input.KeyboardNavigation.GetTabIndex).Last();
            Assert.Same(footer, order);
            // the indexes only order the subtrees when the grid cycles and each part is its own Local scope
            Assert.Equal(System.Windows.Input.KeyboardNavigationMode.Cycle, System.Windows.Input.KeyboardNavigation.GetTabNavigation(parent));
            foreach (var part in parent.Children.OfType<UIElement>().Where(p => !ReferenceEquals(p, footer)))
                Assert.Equal(System.Windows.Input.KeyboardNavigationMode.Local, System.Windows.Input.KeyboardNavigation.GetTabNavigation(part));
        });
    }
}
