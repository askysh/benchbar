using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>What the right click menu reads and does. The app fills it in; tests fill it with fakes.</summary>
internal sealed class TrayMenuModel
{
    public Func<bool> LogonEnabled { get; set; } = () => false;
    public Action<bool> SetLogon { get; set; } = _ => { };

    /// <summary>False when the switch cannot be changed here (the packaged startup task turned off in Windows or by a policy, or not read yet).</summary>
    public Func<bool> LogonAvailable { get; set; } = () => true;

    /// <summary>The line that says why it cannot, shown as the item's tooltip.</summary>
    public Func<string?> LogonNote { get; set; } = () => null;

    /// <summary>Asks for a fresh read of the switch (packaged: the startup task); the menu is redrawn when it arrives.</summary>
    public Action RefreshLogon { get; set; } = () => { };

    /// <summary>False when the Store does the updating: no GitHub check, so no item.</summary>
    public bool ShowCheckForUpdates { get; set; } = true;
    public Func<AppearanceMode> Appearance { get; set; } = () => AppearanceMode.System;
    public Action<AppearanceMode> SetAppearance { get; set; } = _ => { };
    public Func<RunnerSet> LoadRunners { get; set; } = () => RunnerSet.BuiltIn;
    public Func<string> RunnerId { get; set; } = () => TrayConfig.DefaultRunnerId;
    public Action<string> SelectRunner { get; set; } = _ => { };
    public Action OpenRunnersFolder { get; set; } = () => { };
    public Func<bool> Notifications { get; set; } = () => true;
    public Action<bool> SetNotifications { get; set; } = _ => { };
    public Func<ResolvedTheme> Theme { get; set; } = () => new ResolvedTheme(false, false);
    public Action OpenMain { get; set; } = () => { };
    public Action OpenSettings { get; set; } = () => { };

    /// <summary>Setup is unfinished: "Set Up BenchBar..." is shown. Read when the menu opens.</summary>
    public Func<bool> SetupPending { get; set; } = () => false;

    /// <summary>Opens the setup wizard, or brings an open one forward.</summary>
    public Action SetUp { get; set; } = () => { };

    public Action CheckForUpdates { get; set; } = () => { };

    /// <summary>The release Update Now can install; null hides "Update to X". Read when the menu opens.</summary>
    public Func<UpdateOffer?> Update { get; set; } = () => null;

    /// <summary>True while the update window runs: the item says so and is off.</summary>
    public Func<bool> UpdateRunning { get; set; } = () => false;

    public Action UpdateNow { get; set; } = () => { };
    public Action Help { get; set; } = () => { };
    public Action ReportBug { get; set; } = () => { };
    public Action Quit { get; set; } = () => { };
}

/// <summary>
/// The tray icon's right click menu. State (checkmarks, the runner list) is read when the menu or the submenu opens,
/// so nothing is built or polled while it is closed.
/// </summary>
internal sealed class TrayMenu
{
    public static string LogonHeader => UiText.Get("MenuLogon");
    public static string SetUpHeader => UiText.Get("MenuSetUp");

    private readonly TrayMenuModel _model;
    private readonly MenuItem _logon = new() { Header = LogonHeader, IsCheckable = true };
    private readonly MenuItem _appearance = new() { Header = UiText.Get("MenuAppearance") };
    private readonly MenuItem _runner = new() { Header = UiText.Get("MenuRunner") };
    private readonly MenuItem _notifications = new() { Header = UiText.Get("MenuNotifications"), IsCheckable = true };
    private readonly MenuItem _update = new() { Visibility = Visibility.Collapsed };
    private readonly MenuItem _setUp = new() { Header = SetUpHeader, Visibility = Visibility.Collapsed };
    private readonly Image _preview = new() { Width = 48, Height = 48, Stretch = Stretch.Uniform, SnapsToDevicePixels = true };
    private readonly TextBlock _previewName = new() { HorizontalAlignment = HorizontalAlignment.Center, Opacity = 0.7, Margin = new Thickness(0, 4, 0, 0) };
    private readonly DispatcherTimer _animation = new(DispatcherPriority.Background);
    private IReadOnlyList<ImageSource> _previewFrames = [];
    private int _previewFrame;

    public TrayMenu(TrayMenuModel model)
    {
        _model = model;
        Menu = new ContextMenu();

        var items = new List<(string Header, Action Click)>();
        if (model.ShowCheckForUpdates) items.Add((UiText.Get("MenuCheckForUpdates"), model.CheckForUpdates));
        items.Add((UiText.Get("MenuHelp"), model.Help));
        items.Add((UiText.Get("MenuReportBug"), model.ReportBug));

        _logon.Click += (_, _) => model.SetLogon(_logon.IsChecked);
        _notifications.Click += (_, _) => model.SetNotifications(_notifications.IsChecked);
        foreach (var (mode, header) in new[] { (AppearanceMode.System, UiText.Get("MenuAppearanceSystem")), (AppearanceMode.Light, UiText.Get("MenuAppearanceLight")), (AppearanceMode.Dark, UiText.Get("MenuAppearanceDark")) })
        {
            var item = new MenuItem { Header = header, IsCheckable = true, Tag = mode };
            item.Click += (_, _) =>
            {
                foreach (var other in _appearance.Items.OfType<MenuItem>()) other.IsChecked = ReferenceEquals(other, item);
                model.SetAppearance(mode);
            };
            _appearance.Items.Add(item);
        }

        _runner.Items.Add(new MenuItem { Header = "Bench" }); // a submenu needs one item to open; replaced on open
        _runner.SubmenuOpened += (_, e) => { if (ReferenceEquals(e.OriginalSource, _runner)) OnRunnerOpened(); };
        _runner.SubmenuClosed += (_, e) => { if (ReferenceEquals(e.OriginalSource, _runner)) OnRunnerClosed(); };
        _animation.Tick += (_, _) => NextPreviewFrame();

        var open = new MenuItem { Header = UiText.Get("MenuOpen"), FontWeight = FontWeights.SemiBold };
        open.Click += (_, _) => model.OpenMain();
        var settings = new MenuItem { Header = UiText.Get("MenuSettings") };
        settings.Click += (_, _) => model.OpenSettings();
        _setUp.Click += (_, _) => model.SetUp();
        Menu.Items.Add(open);
        Menu.Items.Add(_setUp);
        Menu.Items.Add(settings);
        Menu.Items.Add(new Separator());
        Menu.Items.Add(_logon);
        Menu.Items.Add(_appearance);
        Menu.Items.Add(_runner);
        Menu.Items.Add(_notifications);
        Menu.Items.Add(new Separator());
        _update.Click += (_, _) => model.UpdateNow();
        Menu.Items.Add(_update);
        foreach (var (header, click) in items)
        {
            var item = new MenuItem { Header = header };
            item.Click += (_, _) => click();
            Menu.Items.Add(item);
        }
        Menu.Items.Add(new Separator());
        var quit = new MenuItem { Header = UiText.Get("MenuQuit") };
        quit.Click += (_, _) => model.Quit();
        Menu.Items.Add(quit);

        Menu.Opened += (_, _) =>
        {
            RefreshChecks();
            model.RefreshLogon();
        };
        Menu.Closed += (_, _) => _animation.Stop();
    }

    public ContextMenu Menu { get; }

    /// <summary>Whether the preview timer is running: only while the Runner submenu is open.</summary>
    public bool IsAnimating => _animation.IsEnabled;

    /// <summary>The header of every item shown, in order; a separator is "-". A hidden item (Update to X with no update) is left out.</summary>
    public IReadOnlyList<string> Headers =>
        Menu.Items.Cast<object>().Where(i => i is not MenuItem { Visibility: Visibility.Collapsed })
            .Select(i => i is MenuItem m ? m.Header?.ToString() ?? "" : "-").ToList();

    /// <summary>Reads the checkmarks from the model (the logon one touches the Startup folder, so only now).</summary>
    public void RefreshChecks()
    {
        _logon.IsChecked = _model.LogonEnabled();
        _logon.IsEnabled = _model.LogonAvailable();
        _logon.ToolTip = _model.LogonNote();
        _notifications.IsChecked = _model.Notifications();
        _setUp.Visibility = _model.SetupPending() ? Visibility.Visible : Visibility.Collapsed;
        RefreshUpdate();
        var mode = _model.Appearance();
        foreach (var item in _appearance.Items.OfType<MenuItem>()) item.IsChecked = (AppearanceMode)item.Tag == mode;
    }

    /// <summary>"Update to X" when Update Now can install a newer release; "Updating to X..." and off while the update window runs.</summary>
    public void RefreshUpdate()
    {
        if (_model.Update() is not { CanUpdateNow: true } offer)
        {
            _update.Visibility = Visibility.Collapsed;
            return;
        }
        var running = _model.UpdateRunning();
        _update.Header = running ? UiText.Format("MenuUpdating", offer.Version) : UiText.Format("MenuUpdateTo", offer.Version);
        _update.IsEnabled = !running;
        _update.Visibility = Visibility.Visible;
    }

    // --- the Runner submenu ---

    /// <summary>Builds the submenu from a fresh RunnerSet: a preview, one item per runner, the folder item.</summary>
    public void BuildRunnerItems()
    {
        var set = _model.LoadRunners();
        var selected = _model.RunnerId();
        var light = _model.Theme().FlyoutLight;
        _runner.Items.Clear();

        var header = new StackPanel { Margin = new Thickness(12, 8, 12, 8), IsHitTestVisible = false, MinWidth = 160 };
        header.Children.Add(_preview);
        header.Children.Add(_previewName);
        _runner.Items.Add(header);
        _runner.Items.Add(new Separator());

        RunnerInfo? current = null;
        foreach (var info in set.Runners)
        {
            var item = new MenuItem
            {
                Header = info.DisplayName,
                IsCheckable = true,
                IsChecked = info.IsUsable && string.Equals(info.Id, selected, StringComparison.OrdinalIgnoreCase),
                IsEnabled = info.IsUsable,
                Tag = info,
            };
            if (!info.IsUsable)
            {
                item.ToolTip = info.Error;
                ToolTipService.SetShowOnDisabled(item, true);
            }
            else
            {
                item.Icon = new Image { Width = 20, Height = 20, Source = RunnerImages.Frame(info.Art!, RunnerPose.Running, 0, 20, light) };
                item.MouseEnter += (_, _) => ShowPreview(info, light);
                item.GotKeyboardFocus += (_, _) => ShowPreview(info, light);
                item.Click += (_, _) =>
                {
                    foreach (var other in _runner.Items.OfType<MenuItem>().Where(m => m.Tag is RunnerInfo)) other.IsChecked = ReferenceEquals(other, item);
                    _model.SelectRunner(info.Id);
                };
                if (item.IsChecked) current = info;
            }
            _runner.Items.Add(item);
        }

        _runner.Items.Add(new Separator());
        var folder = new MenuItem { Header = UiText.Get("MenuOpenRunnersFolder") };
        folder.Click += (_, _) => _model.OpenRunnersFolder();
        _runner.Items.Add(folder);

        ShowPreview(current ?? set.Runners.First(), light);
    }

    /// <summary>The runner shown in the preview and its running frames; the timer plays them at the running pace.</summary>
    public string PreviewName => _previewName.Text;

    private void ShowPreview(RunnerInfo info, bool light)
    {
        if (info.Art is null) return;
        _previewName.Text = info.DisplayName;
        _previewFrames = RunnerImages.RunningFrames(info.Art, 48, light);
        _previewFrame = 0;
        _preview.Source = _previewFrames.Count > 0 ? _previewFrames[0] : null;
        _animation.Interval = TimeSpan.FromSeconds(1 / RunnerPose.Running.BaseFps());
    }

    private void NextPreviewFrame()
    {
        if (_previewFrames.Count < 2) return;
        _previewFrame = (_previewFrame + 1) % _previewFrames.Count;
        _preview.Source = _previewFrames[_previewFrame];
    }

    private void OnRunnerOpened()
    {
        BuildRunnerItems(); // the folder may have changed since the last time
        _animation.Start();
    }

    private void OnRunnerClosed() => _animation.Stop();
}
