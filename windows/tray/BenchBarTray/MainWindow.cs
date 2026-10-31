using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>What the main window asks the app for. Harmless defaults, so tests build the window without an app.</summary>
internal sealed class MainActions
{
    public OverviewActions Overview { get; set; } = new();

    /// <summary>The CLI client and shared sheets every page uses.</summary>
    public PageServices Services { get; set; } = new();
    public Action StartDistro { get; set; } = () => { };
    public Action ShowSettings { get; set; } = () => { };
    public Action ShowAbout { get; set; } = () => { };
    public Action NewBench { get; set; } = () => { };
    public Action ExistingBench { get; set; } = () => { };
    public Action<string> CopyText { get; set; } = _ => { };
    public Action<string> OpenUrl { get; set; } = _ => { };
    public Action RefreshNow { get; set; } = () => { };

    /// <summary>Report a Bug: the entry point ("Beta banner") and a problem text when the button sits next to one.</summary>
    public Action<string, string?> ReportBug { get; set; } = (_, _) => { };

    /// <summary>The beta notice at the top shows until it is dismissed once; the app remembers that in the config.</summary>
    public Func<bool> BetaBannerVisible { get; set; } = () => false;

    public Action DismissBetaBanner { get; set; } = () => { };
}

/// <summary>A newer release the banner offers.</summary>
internal sealed record UpdateOffer(string Version, string Url);

/// <summary>
/// The BenchBar window: a sidebar of benches (a state dot, each site as a child row) with Settings and About at the foot, and
/// the content to its right: the Overview of the selected bench, a card when the distro is stopped or the shim has a problem,
/// the empty state, or the first run wizard. Windows 11 look: the Fluent theme, Mica where the theme draws it.
/// </summary>
internal sealed class MainWindow : Window
{
    private readonly MainActions _actions;
    private readonly ListBox _list = new() { BorderThickness = new Thickness(0), Background = Brushes.Transparent, Margin = new Thickness(4, 0, 4, 0) };
    private readonly TextBlock _summary = Ui.Text("", 12, opacity: 0.7, margin: new Thickness(16, 0, 16, 8));
    private readonly Border _banner = new() { Visibility = Visibility.Collapsed, Margin = new Thickness(24, 16, 24, 0) };
    private readonly Border _beta = new() { Visibility = Visibility.Collapsed, Margin = new Thickness(24, 16, 24, 0) };
    private readonly ContentControl _content = new() { Margin = new Thickness(24, 20, 24, 20), IsTabStop = false };
    private readonly BenchPage _page;
    private readonly DiscoveryView _discovery;
    private readonly ProfilesView _profiles;
    private readonly Dictionary<SidebarTool, Button> _toolButtons = [];
    private SidebarTool _tool = SidebarTool.None;
    private TraySnapshot _snapshot = TraySnapshot.Empty;
    private IReadOnlyList<SidebarItem> _items = [];
    private string? _selectedKey;
    private string _sidebarKey = "";
    private string _contentKey = "";
    private WizardView? _wizard;
    private UpdateOffer? _offer;
    private bool _syncing;

    public MainWindow(MainActions actions, ResolvedTheme theme)
    {
        _actions = actions;
        _page = new BenchPage(actions.Services, new OverviewView(actions.Overview));
        _page.TabChanged += _ => SyncContentKey();
        _discovery = new DiscoveryView(actions.Services);
        _profiles = new ProfilesView(actions.Services);

        Title = BetaText.WindowTitle;
        Width = 1000;
        Height = 680;
        MinWidth = 760;
        MinHeight = 520;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Ui.ApplyTheme(this, theme);
        Ui.ApplyMica(this);
        Ui.Name(this, BetaText.WindowTitle);

        var sidebar = BuildSidebar();
        BuildBetaBanner();
        var right = new DockPanel();
        DockPanel.SetDock(_beta, Dock.Top);
        DockPanel.SetDock(_banner, Dock.Top);
        right.Children.Add(_beta);
        right.Children.Add(_banner);
        right.Children.Add(_content);

        var root = new Grid();
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(250) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(sidebar, 0);
        Grid.SetColumn(right, 1);
        root.Children.Add(sidebar);
        root.Children.Add(right);
        Content = root;

        InputBindings.Add(new KeyBinding(new RelayCommand(_actions.NewBench), Key.N, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new RelayCommand(_actions.ShowSettings), Key.OemComma, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(new RelayCommand(_actions.RefreshNow), Key.F5, ModifierKeys.None));

        _list.SelectionChanged += OnSelectionChanged;
        Rebuild();
    }

    public MainMode Mode { get; private set; } = MainMode.Home;

    /// <summary>The wizard shown now, if any.</summary>
    public WizardView? Wizard => _wizard;

    /// <summary>The rows of the sidebar (for tests).</summary>
    public IReadOnlyList<SidebarItem> Items => _items;

    public OverviewView Overview => _page.Overview;

    /// <summary>The bench page (tabs) shown for the selected bench or site.</summary>
    public BenchPage Page => _page;

    public DiscoveryView Discovery => _discovery;

    public ProfilesView Profiles => _profiles;

    /// <summary>The pane below the benches that is open now, or None.</summary>
    public SidebarTool Tool => _tool;

    public string ContentKind => _contentKey;

    public UpdateOffer? Offer => _offer;

    /// <summary>The beta notice: shown until dismissed, with Report a Bug and Dismiss.</summary>
    public bool BetaBannerShown => _beta.Visibility == Visibility.Visible;

    private void BuildBetaBanner()
    {
        var line = new DockPanel();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(Ui.Button(BetaText.ReportABug, () => _actions.ReportBug("Beta banner", null), "Report a bug", primary: true));
        var dismiss = Ui.Button("Dismiss", () =>
        {
            _beta.Visibility = Visibility.Collapsed;
            _actions.DismissBetaBanner();
        }, "Dismiss the beta notice");
        dismiss.Margin = new Thickness(0);
        buttons.Children.Add(dismiss);
        DockPanel.SetDock(buttons, Dock.Right);
        line.Children.Add(buttons);
        line.Children.Add(new TextBlock
        {
            Text = BetaText.Banner,
            VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 12, 0),
        });
        _beta.Background = Ui.Card;
        _beta.CornerRadius = new CornerRadius(8);
        _beta.Padding = new Thickness(16, 10, 12, 10);
        _beta.Child = line;
        Ui.Name(_beta, "Beta notice: " + BetaText.Banner);
        _beta.Visibility = _actions.BetaBannerVisible() ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>Where the person is in this window, for a bug report. No bench names or paths.</summary>
    public string ReportWhere =>
        Mode == MainMode.Wizard ? (_wizard is null ? "Main window, setup wizard" : ReportContext.Wizard(_wizard.Model.Page, _wizard.Model.Flow, _wizard.Model.BusyStepId))
        : _snapshot.Problem is not null ? "Main window, problem card"
        : _snapshot.DistroStopped ? "Main window, distro stopped card"
        : _tool != SidebarTool.None ? "Main window, " + SidebarTools.Title(_tool)
        : _snapshot.Benches.Count == 0 ? "Main window, no benches yet"
        : "Main window, " + _page.Tab + " tab";

    /// <summary>The bench the sidebar has selected (a bench row, or the bench of a site row); null in a tool pane or with no bench.</summary>
    public string? SelectedBenchPath => _tool == SidebarTool.None ? _items.FirstOrDefault(i => i.Key == _selectedKey)?.BenchPath : null;

    // --- sidebar ---

    private UIElement BuildSidebar()
    {
        var head = new DockPanel { Margin = new Thickness(16, 16, 12, 8) };
        var add = Ui.Button("+", () => { }, "Add a bench", minWidth: 36);
        add.Margin = new Thickness(0);
        add.Padding = new Thickness(8, 2, 8, 2);
        add.FontSize = 16;
        var menu = new ContextMenu();
        var fresh = new MenuItem { Header = "New Bench..." };
        fresh.Click += (_, _) => _actions.NewBench();
        var existing = new MenuItem { Header = "I Already Have a Bench..." };
        existing.Click += (_, _) => _actions.ExistingBench();
        Ui.Name(fresh, "New Bench");
        Ui.Name(existing, "I already have a bench");
        menu.Items.Add(fresh);
        menu.Items.Add(existing);
        add.ContextMenu = menu;
        add.Click += (_, _) =>
        {
            menu.PlacementTarget = add;
            menu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
            menu.IsOpen = true;
        };
        DockPanel.SetDock(add, Dock.Right);
        head.Children.Add(add);
        head.Children.Add(Ui.Text("Benches", 18, FontWeights.SemiBold));

        var app = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(16, 16, 12, 0) };
        app.Children.Add(Ui.Text("BenchBar", 13, FontWeights.SemiBold, 0.8));
        app.Children.Add(Ui.Pill());
        head.Margin = new Thickness(16, 8, 12, 8);

        var foot = new StackPanel { Margin = new Thickness(12, 8, 12, 16) };
        var settings = FootButton("Settings", "", _actions.ShowSettings);
        var about = FootButton("About", "", _actions.ShowAbout);
        foot.Children.Add(settings);
        foot.Children.Add(about);

        var tools = new StackPanel { Margin = new Thickness(12, 4, 12, 0) };
        foreach (var tool in SidebarTools.All)
        {
            var button = FootButton(SidebarTools.Title(tool), tool == SidebarTool.FindBenches ? "" : "", () => ShowTool(tool));
            _toolButtons[tool] = button;
            tools.Children.Add(button);
        }

        Ui.Name(_list, "Benches");
        var panel = new DockPanel();
        DockPanel.SetDock(app, Dock.Top);
        DockPanel.SetDock(head, Dock.Top);
        DockPanel.SetDock(_summary, Dock.Top);
        DockPanel.SetDock(foot, Dock.Bottom);
        DockPanel.SetDock(tools, Dock.Bottom);
        panel.Children.Add(app);
        panel.Children.Add(head);
        panel.Children.Add(_summary);
        panel.Children.Add(foot);
        panel.Children.Add(tools);
        panel.Children.Add(_list);
        return panel;
    }

    private static Button FootButton(string label, string glyph, Action click)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal };
        var icon = Ui.Glyph(glyph, 16);
        icon.Margin = new Thickness(0, 0, 10, 0);
        line.Children.Add(icon);
        line.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center });
        var button = new Button
        {
            Content = line,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            Padding = new Thickness(12, 8, 12, 8),
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Margin = new Thickness(0, 0, 0, 2),
        };
        button.Click += (_, _) => click();
        Ui.Name(button, label);
        return button;
    }

    private ListBoxItem ItemFor(SidebarItem item)
    {
        var grid = new Grid { Margin = new Thickness(item.Kind == SidebarKind.Site ? 22 : 4, 4, 4, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var dot = item.Kind == SidebarKind.Bench ? Ui.Dot(item.State, 9) : (UIElement)Ui.Glyph("", 12, null);
        if (dot is FrameworkElement fe) fe.HorizontalAlignment = HorizontalAlignment.Left;
        var text = new StackPanel();
        text.Children.Add(new TextBlock { Text = item.Title, TextTrimming = TextTrimming.CharacterEllipsis, FontWeight = item.Kind == SidebarKind.Bench ? FontWeights.SemiBold : FontWeights.Normal });
        if (item.Detail.Length > 0) text.Children.Add(new TextBlock { Text = item.Detail, FontSize = 12, Opacity = 0.65, TextTrimming = TextTrimming.CharacterEllipsis });
        Grid.SetColumn(text, 1);
        grid.Children.Add(dot);
        grid.Children.Add(text);
        var entry = new ListBoxItem { Content = grid, Tag = item, Padding = new Thickness(6, 2, 6, 2) };
        Ui.Name(entry, item.Kind == SidebarKind.Bench ? $"{item.Title}, {item.Detail}" : $"Site {item.Title}, {(item.Detail.Length > 0 ? item.Detail : "of " + item.BenchPath)}");
        return entry;
    }

    // --- state in ---

    public void SetSnapshot(TraySnapshot snapshot, string upText)
    {
        _snapshot = snapshot;
        _summary.Text = upText;
        var items = SidebarModel.Build(snapshot);
        var key = string.Join('\n', items.Select(i => $"{i.Key}|{i.Title}|{i.Detail}|{i.State}"));
        if (key != _sidebarKey)
        {
            _sidebarKey = key;
            _items = items;
            RebuildSidebar();
        }
        if (Mode == MainMode.Home) ShowHome();
    }

    private void RebuildSidebar()
    {
        _syncing = true;
        try
        {
            _list.Items.Clear();
            foreach (var item in _items) _list.Items.Add(ItemFor(item));
            var selected = _items.FirstOrDefault(i => i.Key == _selectedKey) ?? _items.FirstOrDefault(i => i.Kind == SidebarKind.Bench);
            _selectedKey = selected?.Key;
            if (selected is not null && _tool == SidebarTool.None) _list.SelectedIndex = _items.ToList().IndexOf(selected);
        }
        finally
        {
            _syncing = false;
        }
    }

    private void OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncing || _list.SelectedItem is not ListBoxItem { Tag: SidebarItem item }) return;
        _selectedKey = item.Key;
        _tool = SidebarTool.None;
        MarkTools();
        if (Mode == MainMode.Home) ShowHome(navigate: true);
    }

    /// <summary>Opens the Health tab of the bench page that is showing (the Overview's Health button).</summary>
    public void ShowHealth()
    {
        if (_page.Context is null) return;
        _page.Select(BenchTab.Health);
        SyncContentKey();
    }

    /// <summary>Selects a bench or site row as a click would (for tests and for deep links from other panes).</summary>
    public void Select(SidebarItem item)
    {
        var index = _items.ToList().FindIndex(i => i.Key == item.Key);
        if (index >= 0) _list.SelectedIndex = index;
    }

    /// <summary>Opens the Find Benches or Team Profiles pane and clears the bench selection in the sidebar.</summary>
    public void ShowTool(SidebarTool tool)
    {
        if (Mode == MainMode.Wizard) return; // the buttons are off then; a shortcut must not change what is hidden behind the wizard
        _tool = tool;
        _syncing = true;
        try { _list.SelectedIndex = -1; }
        finally { _syncing = false; }
        MarkTools();
        if (Mode == MainMode.Home) ShowHome(navigate: true);
    }

    private void MarkTools()
    {
        foreach (var (tool, button) in _toolButtons) button.Background = tool == _tool ? Ui.Card : Brushes.Transparent;
    }

    public const string ToolsOffWhileSetupTip = "Finish or close the setup first.";

    /// <summary>Find Benches and Team Profiles do nothing while the wizard covers the window, so they are off, with the reason.</summary>
    private void UpdateToolButtons()
    {
        var off = Mode == MainMode.Wizard;
        foreach (var button in _toolButtons.Values)
        {
            button.IsEnabled = !off;
            button.ToolTip = off ? ToolsOffWhileSetupTip : null;
        }
    }

    private void SyncContentKey() => _contentKey = _page.Tab == BenchTab.Overview ? "overview" : "bench|" + _page.Tab.ToString().ToLowerInvariant();

    // --- content ---

    private void Rebuild()
    {
        RebuildSidebar();
        ShowHome();
    }

    /// <summary>Shows what the sidebar selected. <paramref name="navigate"/> is true when the selection just changed (a poll passes false and keeps the tab).</summary>
    public void ShowHome(bool navigate = false)
    {
        Mode = MainMode.Home;
        var selected = _items.FirstOrDefault(i => i.Key == _selectedKey);
        if (_snapshot.Problem is { } problem)
        {
            SetContent("problem", () => CardPage("BenchBar needs attention", problem, "Copy", () => _actions.CopyText(problem), "Set Up BenchBar", _actions.NewBench));
        }
        else if (_snapshot.DistroStopped)
        {
            var distro = _snapshot.Distro ?? "The WSL distro";
            SetContent("stopped|" + distro, () => CardPage($"{distro} is stopped", FlyoutView.DistroHint, "Start", _actions.StartDistro));
        }
        else if (_tool != SidebarTool.None)
        {
            var key = "tool|" + _tool;
            var pane = _tool == SidebarTool.FindBenches ? (UserControl)_discovery : _profiles;
            var changed = _contentKey != key || !ReferenceEquals(_content.Content, pane);
            _contentKey = key;
            _content.Content = pane;
            if (changed && navigate)
            {
                if (_tool == SidebarTool.FindBenches) _discovery.OnShown();
                else _profiles.OnShown();
            }
        }
        else if (_snapshot.Benches.Count == 0)
        {
            SetContent("empty", () => CardPage("No benches yet", "Set up Frappe in WSL with a few clicks, or point BenchBar at a bench you already have.", "Set Up a New Bench", _actions.NewBench));
        }
        else if (selected is not null && _snapshot.Benches.FirstOrDefault(b => b.Path == selected.BenchPath) is { } bench)
        {
            var shown = ReferenceEquals(_content.Content, _page);
            if (!shown) _content.Content = _page;
            _page.Bind(bench, selected.Kind == SidebarKind.Site ? selected.Title : null, navigate || !shown);
            SyncContentKey();
        }
    }

    private void SetContent(string key, Func<UIElement> build)
    {
        if (key == _contentKey && _content.Content is not null) return;
        _contentKey = key;
        _content.Content = build();
    }

    private UIElement CardPage(string title, string text, string button, Action click, string? second = null, Action? secondClick = null)
    {
        var panel = new StackPanel { MaxWidth = 560, HorizontalAlignment = HorizontalAlignment.Left };
        panel.Children.Add(Ui.Text(title, 24, FontWeights.SemiBold));
        panel.Children.Add(Ui.Text(text, 14, opacity: 0.8, margin: new Thickness(0, 6, 0, 16)));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(Ui.Button(button, click, button, primary: second is null));
        if (second is not null && secondClick is not null) buttons.Children.Add(Ui.Button(second, secondClick, second, primary: true));
        panel.Children.Add(buttons);
        return panel;
    }

    public void ShowWizard(WizardView wizard)
    {
        Mode = MainMode.Wizard;
        _wizard = wizard;
        _contentKey = "wizard";
        _content.Content = wizard;
        UpdateToolButtons();
    }

    public void CloseWizard()
    {
        _wizard = null;
        _contentKey = "";
        Mode = MainMode.Home;
        UpdateToolButtons();
        ShowHome();
    }

    // --- update banner ---

    public void SetUpdate(UpdateOffer? offer, Action dismiss)
    {
        _offer = offer;
        if (offer is null)
        {
            _banner.Visibility = Visibility.Collapsed;
            return;
        }
        var line = new DockPanel();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(Ui.Button("Open Release Page", () => _actions.OpenUrl(offer.Url), "Open the release page", primary: true));
        var later = Ui.Button("Not Now", () =>
        {
            dismiss();
            SetUpdate(null, dismiss);
        }, "Dismiss the update notice");
        later.Margin = new Thickness(0);
        buttons.Children.Add(later);
        DockPanel.SetDock(buttons, Dock.Right);
        line.Children.Add(buttons);
        line.Children.Add(new TextBlock
        {
            Text = $"BenchBar {offer.Version} is out.",
            VerticalAlignment = VerticalAlignment.Center,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 0, 12, 0),
        });
        _banner.Background = Ui.Card;
        _banner.CornerRadius = new CornerRadius(8);
        _banner.Padding = new Thickness(16, 10, 12, 10);
        _banner.Child = line;
        Ui.Name(_banner, $"BenchBar {offer.Version} is out");
        _banner.Visibility = Visibility.Visible;
    }

    private sealed class RelayCommand(Action run) : ICommand
    {
        public event EventHandler? CanExecuteChanged { add { } remove { } }

        public bool CanExecute(object? parameter) => true;

        public void Execute(object? parameter) => run();
    }
}

internal enum MainMode { Home, Wizard }
