using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>What About asks of the app.</summary>
internal sealed class AboutActions
{
    public string AppVersion { get; set; } = "0.0.0-dev";

    /// <summary>The Microsoft Store updates the programs: the row says so and has no button.</summary>
    public bool UpdatesFromStore { get; set; }
    public Func<Task<string?>> ShimVersion { get; set; } = () => Task.FromResult<string?>(null);

    /// <summary>The Linux CLI's version from the read only setup check (it never boots a stopped distro); null when unknown.</summary>
    public Func<Task<AboutCli>> CliVersion { get; set; } = () => Task.FromResult(AboutCli.Unknown);

    /// <summary>Asks benchbar.exe (<c>self-update --check --json</c>); the answer or the reason there is none.</summary>
    public Func<Task<SelfUpdateCheck>> CheckForUpdates { get; set; } = () => Task.FromResult(SelfUpdateCheck.Failed("not available"));

    /// <summary>The release an earlier check found, shown when About opens; null when none is known.</summary>
    public Func<UpdateOffer?> KnownOffer { get; set; } = () => null;

    /// <summary>True while the update window runs.</summary>
    public Func<bool> UpdateRunning { get; set; } = () => false;

    public Action UpdateNow { get; set; } = () => { };

    public Action ReportBug { get; set; } = () => { };
    public Action<string> OpenUrl { get; set; } = _ => { };
    public Action<string> CopyText { get; set; } = _ => { };
}

/// <summary>About: the app, shim and Linux CLI versions, links, Report a Bug, the MCP line and the licence note.</summary>
internal sealed class AboutWindow : ToolWindow
{
    public const string DocsUrl = "https://benchbar.akashmishra.com/windows/";
    public const string WhatsNewUrl = "https://benchbar.akashmishra.com/whats-new/";
    public const string RepositoryUrl = "https://github.com/askysh/benchbar";

    private readonly AboutActions _actions;
    private readonly TextBlock _shim = Ui.Text(UiText.Get("AboutReading"), 14);
    private readonly TextBlock _cli = Ui.Text(UiText.Get("AboutReading"), 14);
    private readonly TextBlock _update = Ui.Text("", 13, opacity: 0.85);
    private readonly StackPanel _updateButtons = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0), Visibility = Visibility.Collapsed };

    public AboutWindow(AboutActions actions, ResolvedTheme theme) : base(UiText.Get("AboutTitle"), 560, 640, theme)
    {
        _actions = actions;
        Ui.ApplyMica(this);
        Ui.Name(this, UiText.Get("AboutTitle"));

        var panel = new StackPanel { Margin = new Thickness(28, 24, 28, 24) };
        var name = new StackPanel { Orientation = Orientation.Horizontal };
        name.Children.Add(Ui.Text("BenchBar", 28, FontWeights.SemiBold));
        name.Children.Add(Ui.Pill());
        panel.Children.Add(name);
        panel.Children.Add(Ui.Text(UiText.Get("AboutTagline"), 14, opacity: 0.75, margin: new Thickness(0, 2, 0, 8)));
        panel.Children.Add(Ui.Text(BetaText.AboutText, 13, opacity: 0.9, margin: new Thickness(0, 0, 0, 16)));

        var versions = new StackPanel();
        versions.Children.Add(Row("BenchBar", Ui.Text(actions.AppVersion.Split('+')[0], 14)));
        versions.Children.Add(Row("benchbar.exe", _shim));
        versions.Children.Add(Row(UiText.Get("AboutLinuxCli"), _cli));
        var update = new StackPanel();
        if (actions.UpdatesFromStore)
        {
            update.Children.Add(Ui.Text(UpdatePolicy.StoreLine, 13, opacity: 0.85));
        }
        else
        {
            var check = Ui.Button(UiText.Get("AboutCheckUpdates"), () => CheckAsync().Forget(), UiText.Get("AboutCheckUpdatesName"));
            update.Children.Add(check);
            update.Children.Add(_update);
            update.Children.Add(_updateButtons);
        }
        versions.Children.Add(Row(UiText.Get("AboutUpdates"), update));
        panel.Children.Add(Section(UiText.Get("AboutVersions"), Ui.CardOf(versions)));

        var links = new StackPanel();
        links.Children.Add(Ui.Link(UiText.Get("AboutDocs"), () => _actions.OpenUrl(DocsUrl)));
        links.Children.Add(Ui.Link(UiText.Get("AboutWhatsNew"), () => _actions.OpenUrl(WhatsNewUrl)));
        links.Children.Add(Ui.Link(UiText.Get("AboutSource"), () => _actions.OpenUrl(RepositoryUrl), UiText.Get("AboutSourceName")));
        var bug = Ui.Button(UiText.Get("MenuReportBug"), () => _actions.ReportBug(), UiText.Get("AboutReportBugName"), minWidth: 120);
        bug.Margin = new Thickness(0, 10, 0, 0);
        links.Children.Add(bug);
        links.Children.Add(Ui.Caption(UiText.Get("AboutReportHint")));
        panel.Children.Add(Section(UiText.Get("AboutHelp"), Ui.CardOf(links)));

        var mcp = new StackPanel();
        mcp.Children.Add(Ui.Text(UiText.Get("AboutMcpIntro"), 13, margin: new Thickness(0, 0, 0, 8)));
        var line = new DockPanel();
        var copy = Ui.Button(UiText.Get("Copy"), () => _actions.CopyText(WizardModel.McpLine), UiText.Get("AboutCopyMcp"), minWidth: 64);
        copy.Margin = new Thickness(8, 0, 0, 0);
        DockPanel.SetDock(copy, Dock.Right);
        var box = new TextBox { Text = WizardModel.McpLine, IsReadOnly = true, FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"), FontSize = 12, Padding = new Thickness(8, 6, 8, 6) };
        Ui.Name(box, UiText.Get("AboutMcpCommand"));
        line.Children.Add(copy);
        line.Children.Add(box);
        mcp.Children.Add(line);
        mcp.Children.Add(Ui.Text(UiText.Get("AboutMcpOther"), 13, margin: new Thickness(0, 10, 0, 8)));
        var jsonLine = new DockPanel();
        var copyJson = Ui.Button(UiText.Get("Copy"), () => _actions.CopyText(WizardModel.McpJson), UiText.Get("AboutCopyJson"), minWidth: 64);
        copyJson.Margin = new Thickness(8, 0, 0, 0);
        DockPanel.SetDock(copyJson, Dock.Right);
        var jsonBox = new TextBox { Text = WizardModel.McpJson, IsReadOnly = true, FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"), FontSize = 12, Padding = new Thickness(8, 6, 8, 6) };
        Ui.Name(jsonBox, UiText.Get("AboutMcpJson"));
        jsonLine.Children.Add(copyJson);
        jsonLine.Children.Add(jsonBox);
        mcp.Children.Add(jsonLine);
        panel.Children.Add(Section(UiText.Get("AboutAgents"), Ui.CardOf(mcp)));

        panel.Children.Add(Ui.Text(UiText.Get("AboutLicense"), 12, opacity: 0.7, margin: new Thickness(0, 8, 0, 2)));
        panel.Children.Add(Ui.Text(UiText.Get("AboutTrademark"), 12, opacity: 0.7));

        Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Loaded += (_, _) => LoadVersionsAsync().Forget();
        if (actions.KnownOffer() is { } known)
        {
            _update.Text = UiText.Format("AboutIsOut", known.Version);
            ShowOffer(known);
        }
    }

    /// <summary>The text under Check for Updates (for tests).</summary>
    public string UpdateText => _update.Text;

    private static UIElement Section(string title, UIElement body)
    {
        var panel = new StackPanel { Margin = new Thickness(0, 0, 0, 8) };
        panel.Children.Add(Ui.Text(title, 13, FontWeights.SemiBold, 0.8, new Thickness(2, 6, 0, 6)));
        panel.Children.Add(body);
        return panel;
    }

    private static UIElement Row(string label, UIElement value)
    {
        var grid = new Grid { Margin = new Thickness(0, 4, 0, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(190) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var l = Ui.Text(label, 13, opacity: 0.7);
        Grid.SetColumn(value, 1);
        grid.Children.Add(l);
        grid.Children.Add(value);
        return grid;
    }

    private async Task LoadVersionsAsync()
    {
        _shim.Text = await _actions.ShimVersion() ?? UiText.Get("AboutNotFound");
        _cli.Text = (await _actions.CliVersion()).Text;
    }

    internal async Task CheckAsync()
    {
        _update.Text = UiText.Get("AboutChecking");
        ShowOffer(null);
        var check = await _actions.CheckForUpdates();
        _update.Text = UpdatePlanner.CheckText(check);
        ShowOffer(UpdatePlanner.Offer(check.Status));
    }

    /// <summary>
    /// Update Now beside the version when this install can run it (off while the update window runs), and Copy Update Line for anyone who
    /// prefers to run it in PowerShell.
    /// </summary>
    internal void ShowOffer(UpdateOffer? offer)
    {
        _updateButtons.Children.Clear();
        _updateButtons.Visibility = offer is null ? Visibility.Collapsed : Visibility.Visible;
        if (offer is null) return;
        if (offer.CanUpdateNow)
        {
            var running = _actions.UpdateRunning();
            var now = Ui.Button(running ? UiText.Get("AboutUpdating") : UiText.Get("AboutUpdateNow"), () =>
            {
                _actions.UpdateNow();
                ShowOffer(offer);
            }, UiText.Get("AboutUpdateNowName"), primary: true);
            now.IsEnabled = !running;
            _updateButtons.Children.Add(now);
        }
        Button? copy = null;
        copy = Ui.Button(UiText.Get("AboutCopyUpdateLine"), () =>
        {
            _actions.CopyText(offer.Command);
            if (copy is not null) copy.Content = UiText.Get("AboutCopied");
        }, UiText.Get("AboutCopyUpdateLineName"));
        _updateButtons.Children.Add(copy);
    }
}
