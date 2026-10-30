using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>The bench a tab shows, and the site the sidebar selected under it (null for the bench itself). Refreshed by every poll.</summary>
internal sealed record BenchContext(BenchStatus Bench, string? Site);

/// <summary>
/// A tab of the bench page: Sites, Apps and Health implement it. <see cref="Bind"/> is called when the tab is shown and again with
/// every poll while it stays selected, so it must be cheap when nothing it shows changed (compare, then rebuild).
/// </summary>
internal interface IBenchPageView
{
    void Bind(BenchContext context);
}

/// <summary>
/// One bench in the main window: a tab strip (Overview, Sites, Apps, Health) over the selected tab's view (macos BenchPage). Tabs are
/// built the first time they are shown. A site row of the sidebar opens the Sites tab with that site selected; a bench row opens the
/// Overview. A poll that only refreshes the same selection keeps the tab the person is on.
/// </summary>
internal sealed class BenchPage : UserControl
{
    private readonly PageServices _services;
    private readonly TabControl _tabs = new() { BorderThickness = new Thickness(0), Background = System.Windows.Media.Brushes.Transparent, Padding = new Thickness(0, 12, 0, 0) };
    private readonly Dictionary<BenchTab, UIElement> _views = [];
    private readonly Dictionary<BenchTab, TabItem> _items = [];
    private BenchContext? _context;
    private bool _syncing;

    public BenchPage(PageServices services, OverviewView overview)
    {
        _services = services;
        Overview = overview;
        overview.Attach(services, Navigate);
        _views[BenchTab.Overview] = overview;
        foreach (var tab in BenchTabs.All)
        {
            var item = new TabItem { Header = BenchTabs.Label(tab), Tag = tab, Padding = new Thickness(14, 6, 14, 6) };
            if (tab == BenchTab.Overview) item.Content = overview;
            Ui.Name(item, BenchTabs.Label(tab) + " tab");
            _items[tab] = item;
            _tabs.Items.Add(item);
        }
        _tabs.SelectionChanged += OnTabChanged;
        Ui.Name(_tabs, "Bench tabs");
        Content = _tabs;
        _syncing = true;
        _tabs.SelectedIndex = 0;
        _syncing = false;
        Show(BenchTab.Overview);
    }

    public OverviewView Overview { get; }

    public BenchTab Tab { get; private set; } = BenchTab.Overview;

    public SitesView? Sites => _views.GetValueOrDefault(BenchTab.Sites) as SitesView;

    public AppsView? Apps => _views.GetValueOrDefault(BenchTab.Apps) as AppsView;

    public HealthView? Health => _views.GetValueOrDefault(BenchTab.Health) as HealthView;

    /// <summary>The tab headers in order (for tests).</summary>
    public IReadOnlyList<string> TabLabels => _tabs.Items.OfType<TabItem>().Select(t => (string)t.Header).ToList();

    public BenchContext? Context => _context;

    /// <summary>Raised after the person (or <see cref="Select"/>) changed the tab.</summary>
    public event Action<BenchTab>? TabChanged;

    /// <summary>
    /// Shows <paramref name="bench"/>. With <paramref name="navigate"/> (the sidebar selection changed) a site opens the Sites tab and
    /// a bench the Overview; without it the tab stays.
    /// </summary>
    public void Bind(BenchStatus bench, string? site, bool navigate)
    {
        _context = new BenchContext(bench, site);
        if (navigate) Select(site is null ? BenchTab.Overview : BenchTab.Sites);
        BindShown();
    }

    public void Select(BenchTab tab)
    {
        if (!_items.TryGetValue(tab, out var item)) return;
        _syncing = true;
        try { _tabs.SelectedItem = item; }
        finally { _syncing = false; }
        Show(tab);
        BindShown();
    }

    private void OnTabChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncing || e.OriginalSource != _tabs || _tabs.SelectedItem is not TabItem { Tag: BenchTab tab }) return;
        Show(tab);
        BindShown();
        TabChanged?.Invoke(tab);
    }

    private void Show(BenchTab tab)
    {
        Tab = tab;
        if (_views.ContainsKey(tab)) return;
        UIElement view = tab switch
        {
            BenchTab.Sites => new SitesView(_services),
            BenchTab.Apps => new AppsView(_services),
            _ => new HealthView(_services),
        };
        _views[tab] = view;
        _items[tab].Content = new ScrollViewer { Content = view, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(0, 4, 8, 0) };
    }

    private void BindShown()
    {
        if (_context is null) return;
        if (_views.TryGetValue(Tab, out var view) && view is IBenchPageView page) page.Bind(_context);
        if (Tab == BenchTab.Overview)
        {
            Overview.Bind(_context.Bench, _context.Site);
            _ = Overview.EnsureLockChecked(); // once per bench, only while the Overview is the tab shown
        }
    }

    /// <summary>The Overview asks for another tab (guidance: View Health, Repair).</summary>
    private void Navigate(BenchTab tab, bool repair)
    {
        Select(tab);
        TabChanged?.Invoke(tab);
        if (repair) Health?.RequestRepair();
    }
}
