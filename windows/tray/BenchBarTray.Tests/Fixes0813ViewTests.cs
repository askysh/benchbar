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
            var texts = Texts(ViewOf(model));
            Assert.Contains("Port 3306 is in use.", texts);
            Assert.Contains("sudo systemctl stop mariadb", texts);
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
}
