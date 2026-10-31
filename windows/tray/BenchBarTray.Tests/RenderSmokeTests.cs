using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using BenchBar.Tray.Core;
using Xunit;

namespace BenchBar.Tray.Tests;

/// <summary>
/// Every page and view is measured and arranged in a 1000 by 700 window on an STA thread, as the real window does. A page whose layout
/// throws, or whose content measures wider than the window (the Check page did, with "Set Up Everything" at x=3048), fails here. The
/// Fluent theme is not applied in a test, so this finds layout mistakes of ours, not the theme's own.
/// </summary>
public class RenderSmokeTests
{
    private const double Width = 1000;
    private const double Height = 700;
    private const double Slack = 0.5;

    private static void Lay(FrameworkElement root, double width = Width, double height = Height)
    {
        root.Measure(new Size(width, height));
        root.Arrange(new Rect(0, 0, width, height));
        root.UpdateLayout();
    }

    private static IEnumerable<DependencyObject> VisualWalk(DependencyObject root)
    {
        yield return root;
        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < count; i++)
        {
            foreach (var d in VisualWalk(VisualTreeHelper.GetChild(root, i))) yield return d;
        }
    }

    private static bool IsShown(DependencyObject node)
    {
        for (DependencyObject? n = node; n is not null; n = VisualTreeHelper.GetParent(n))
        {
            if (n is UIElement { Visibility: not Visibility.Visible }) return false;
        }
        return true;
    }

    private static bool InsideScroller(DependencyObject node, DependencyObject root)
    {
        for (var n = VisualTreeHelper.GetParent(node); n is not null && !ReferenceEquals(n, root); n = VisualTreeHelper.GetParent(n))
        {
            if (n is ScrollViewer) return true;
        }
        return false;
    }

    /// <summary>The content is no wider than the window, and every button that is shown has a finite place whose right edge is inside it.</summary>
    private static void AssertFits(FrameworkElement root, string what, double width = Width, double height = Height)
    {
        Assert.True(root.DesiredSize.Width <= width + Slack, $"{what}: desired width {root.DesiredSize.Width} is wider than the {width} px window");
        Assert.True(root.ActualWidth <= width + Slack, $"{what}: actual width {root.ActualWidth}");
        foreach (var button in VisualWalk(root).OfType<ButtonBase>())
        {
            if (!IsShown(button) || button.ActualWidth <= 0) continue;
            var name = AutomationProperties.GetName(button);
            var at = button.TransformToAncestor(root).Transform(new Point(0, 0));
            Assert.True(double.IsFinite(at.X) && double.IsFinite(at.Y), $"{what}: '{name}' has no finite position");
            Assert.True(at.X >= -Slack, $"{what}: '{name}' starts left of the window at x={at.X}");
            Assert.True(at.X + button.ActualWidth <= width + Slack, $"{what}: '{name}' ends at x={at.X + button.ActualWidth}, outside the {width} px window");
            if (!InsideScroller(button, root))
                Assert.True(at.Y + button.ActualHeight <= height + Slack, $"{what}: '{name}' ends at y={at.Y + button.ActualHeight}, outside the {height} px window");
        }
    }

    public static TheoryData<WizardPage> Pages => new()
    {
        WizardPage.Welcome, WizardPage.CliOnly, WizardPage.Check, WizardPage.LinuxUser, WizardPage.ExistingBench,
        WizardPage.NewBench, WizardPage.Review, WizardPage.Install, WizardPage.Done,
    };

    [Theory]
    [MemberData(nameof(Pages))]
    public async Task EveryWizardPageFitsA1000By700Window(WizardPage page)
    {
        var model = await WindowViewTests.ModelAt(page);
        Sta.Run(() =>
        {
            var view = new WizardView(model, new WizardActions());
            view.Update();
            Lay(view);
            AssertFits(view, "wizard page " + page);
            foreach (var button in view.Current!.Right.Concat(view.Current.Left).Where(b => b.Visibility == Visibility.Visible))
                Assert.True(button.ActualWidth > 0, $"wizard page {page}: '{button.Content}' was not laid out");
        });
    }

    [Fact]
    public async Task TheCheckPagesBigButtonIsInsideTheWindow()
    {
        var model = await WindowViewTests.ModelAt(WizardPage.Check);
        Sta.Run(() =>
        {
            var view = new WizardView(model, new WizardActions());
            view.Update();
            Lay(view);
            var all = PageKit.ButtonNamed(view, "Set up everything that is missing");
            var at = all.TransformToAncestor(view).Transform(new Point(0, 0));
            Assert.True(at.X + all.ActualWidth <= Width, $"Set Up Everything ends at x={at.X + all.ActualWidth}");
        });
    }

    [Fact]
    public async Task ThePageColumnKeepsOneWidthWhateverTheRowsSay()
    {
        var model = await WindowViewTests.ModelAt(WizardPage.Check);
        Sta.Run(() =>
        {
            var view = new WizardView(model, new WizardActions());
            view.Update();
            Lay(view);
            var widths = VisualWalk(view).OfType<Border>().Where(b => ReferenceEquals(b.Background, Ui.Card) && IsShown(b)).Select(b => Math.Round(b.ActualWidth)).Distinct().ToList();
            Assert.Single(widths); // every row card is as wide as the column, not as wide as its own words
            Assert.Equal(WizardView.MaxWidthOf(WizardPage.Check), widths[0]);
        });
    }

    [Fact]
    public void TheMainWindowFitsWithEveryStateAndTab() => Sta.Run(() =>
    {
        var kit = new PageKit();
        kit.Runner.On("app", "list").Print(PageKit.Fixture("apps-list.json"));
        var window = new MainWindow(new MainActions { Services = kit.Services, BetaBannerVisible = () => true }, PageKit.Theme);
        var root = (FrameworkElement)window.Content;

        window.SetSnapshot(new TraySnapshot([PageKit.Bench()]), "1 of 1 up");
        Lay(root);
        AssertFits(root, "overview");
        foreach (var tab in new[] { BenchTab.Sites, BenchTab.Apps })
        {
            window.Page.Select(tab);
            PageKit.Drain();
            Lay(root);
            AssertFits(root, "tab " + tab);
        }

        window.SetSnapshot(new TraySnapshot([]), "none up");
        Lay(root);
        AssertFits(root, "empty");
        window.SetSnapshot(new TraySnapshot([], DistroStopped: true, Distro: "Ubuntu-24.04"), "distro stopped");
        Lay(root);
        AssertFits(root, "distro stopped");
        window.SetSnapshot(new TraySnapshot([], DistroStopped: true, Distro: "Ubuntu-24.04", DistroMissing: true), "distro not installed");
        Lay(root);
        AssertFits(root, "distro not installed");
        window.SetSnapshot(new TraySnapshot([], Problem: "benchbar.exe was not found."), "needs attention");
        Lay(root);
        AssertFits(root, "problem");
    });

    [Fact]
    public void TheHealthTabAndTheToolPanesFit() => Sta.Run(() =>
    {
        var (services, _) = PageKit.ScriptedServices();
        SynchronizationContext.SetSynchronizationContext(null);
        var health = new HealthView(services, autoRun: false);
        health.Bind(new BenchContext(PageKit.BenchWith(BenchState.Running), null));
        Lay(health);
        AssertFits(health, "health");

        var discovery = new DiscoveryView(services);
        Lay(discovery);
        AssertFits(discovery, "find benches");
        var profiles = new ProfilesView(services);
        Lay(profiles);
        AssertFits(profiles, "team profiles");
    });

    [Fact]
    public void TheLogToolbarFitsTheDefaultWindowWidth() => Sta.Run(() =>
    {
        var (services, runner) = PageKit.ScriptedServices();
        runner.On("logs").Print(PageKit.Fixture("logs-first.json"));
        SynchronizationContext.SetSynchronizationContext(null);
        var model = new LogViewModel(services.Cli, PageKit.BenchPath, "frappe-bench") { PollEvery = TimeSpan.FromHours(1) };
        var window = new LogWindow(services, PageKit.BenchWith(BenchState.Running), PageKit.Theme, model);
        var root = (FrameworkElement)window.Content;
        Lay(root, window.Width, window.Height);
        AssertFits(root, "log window", window.Width, window.Height);
        foreach (var name in new[] { "Clear view", "Copy the visible lines", "Open in Terminal" })
        {
            var button = PageKit.ButtonNamed(window, name);
            var at = button.TransformToAncestor(root).Transform(new Point(0, 0));
            Assert.True(at.X + button.ActualWidth <= window.Width, $"{name} ends at x={at.X + button.ActualWidth} in a window {window.Width} wide");
        }
        window.Close();
    });

    [Fact]
    public void SettingsFitsItsDefaultSize() => Sta.Run(() =>
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var config = TrayConfig.Load(Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"), "config.json"));
        var model = new SettingsModel(config, new Host(), WindowViewTests.Fixture(), () => { });
        var settings = new SettingsWindow(model, () => RunnerSet.BuiltIn, _ => { }, PageKit.Theme);
        var root = (FrameworkElement)settings.Content;
        Lay(root, settings.Width, settings.Height);
        AssertFits(root, "settings", settings.Width, settings.Height);
    });

    private sealed class Host : ISettingsHost
    {
        public bool OpenAtLogon { get; set; }
        public string? ShimPath => null;
        public void ApplyAppearance(AppearanceMode mode) { }
        public void ApplyRunner(string id) { }
        public void ApplyNotifications(bool on) { }
    }
}
