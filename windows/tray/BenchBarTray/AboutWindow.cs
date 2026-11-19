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
    private readonly TextBlock _shim = Ui.Text("reading...", 14);
    private readonly TextBlock _cli = Ui.Text("reading...", 14);
    private readonly TextBlock _update = Ui.Text("", 13, opacity: 0.85);
    private readonly StackPanel _updateButtons = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0), Visibility = Visibility.Collapsed };

    public AboutWindow(AboutActions actions, ResolvedTheme theme) : base("About BenchBar", 560, 640, theme)
    {
        _actions = actions;
        Ui.ApplyMica(this);
        Ui.Name(this, "About BenchBar");

        var panel = new StackPanel { Margin = new Thickness(28, 24, 28, 24) };
        var name = new StackPanel { Orientation = Orientation.Horizontal };
        name.Children.Add(Ui.Text("BenchBar", 28, FontWeights.SemiBold));
        name.Children.Add(Ui.Pill());
        panel.Children.Add(name);
        panel.Children.Add(Ui.Text("Frappe benches in WSL, from the notification area.", 14, opacity: 0.75, margin: new Thickness(0, 2, 0, 8)));
        panel.Children.Add(Ui.Text(BetaText.AboutText, 13, opacity: 0.9, margin: new Thickness(0, 0, 0, 16)));

        var versions = new StackPanel();
        versions.Children.Add(Row("BenchBar", Ui.Text(actions.AppVersion.Split('+')[0], 14)));
        versions.Children.Add(Row("benchbar.exe", _shim));
        versions.Children.Add(Row("Linux command line tool", _cli));
        var update = new StackPanel();
        if (actions.UpdatesFromStore)
        {
            update.Children.Add(Ui.Text(UpdatePolicy.StoreLine, 13, opacity: 0.85));
        }
        else
        {
            var check = Ui.Button("Check for Updates", () => CheckAsync().Forget(), "Check for updates");
            update.Children.Add(check);
            update.Children.Add(_update);
            update.Children.Add(_updateButtons);
        }
        versions.Children.Add(Row("Updates", update));
        panel.Children.Add(Section("Versions", Ui.CardOf(versions)));

        var links = new StackPanel();
        links.Children.Add(Ui.Link("Documentation", () => _actions.OpenUrl(DocsUrl)));
        links.Children.Add(Ui.Link("What's new", () => _actions.OpenUrl(WhatsNewUrl)));
        links.Children.Add(Ui.Link("Source code (github.com/askysh/benchbar)", () => _actions.OpenUrl(RepositoryUrl), "Source code on GitHub"));
        var bug = Ui.Button("Report a Bug", () => _actions.ReportBug(), "Report a bug", minWidth: 120);
        bug.Margin = new Thickness(0, 10, 0, 0);
        links.Children.Add(bug);
        links.Children.Add(Ui.Caption("Writes a redacted report zip, opens its folder and opens a GitHub issue to attach it to."));
        panel.Children.Add(Section("Help", Ui.CardOf(links)));

        var mcp = new StackPanel();
        mcp.Children.Add(Ui.Text("benchbar mcp lets Claude Code, Cursor and other agents list your benches, read status, doctor and logs, and start, stop or restart them. Add it once:", 13, margin: new Thickness(0, 0, 0, 8)));
        var line = new DockPanel();
        var copy = Ui.Button("Copy", () => _actions.CopyText(WizardModel.McpLine), "Copy the command that adds benchbar mcp", minWidth: 64);
        copy.Margin = new Thickness(8, 0, 0, 0);
        DockPanel.SetDock(copy, Dock.Right);
        var box = new TextBox { Text = WizardModel.McpLine, IsReadOnly = true, FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"), FontSize = 12, Padding = new Thickness(8, 6, 8, 6) };
        Ui.Name(box, "MCP command");
        line.Children.Add(copy);
        line.Children.Add(box);
        mcp.Children.Add(line);
        panel.Children.Add(Section("For coding agents", Ui.CardOf(mcp)));

        panel.Children.Add(Ui.Text("BenchBar is free software under the MIT License.", 12, opacity: 0.7, margin: new Thickness(0, 8, 0, 2)));
        panel.Children.Add(Ui.Text("Frappe and ERPNext are trademarks of Frappe Technologies; BenchBar is not affiliated with or endorsed by them.", 12, opacity: 0.7));

        Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Loaded += (_, _) => LoadVersionsAsync().Forget();
        if (actions.KnownOffer() is { } known)
        {
            _update.Text = $"BenchBar {known.Version} is out.";
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
        _shim.Text = await _actions.ShimVersion() ?? "not found";
        _cli.Text = (await _actions.CliVersion()).Text;
    }

    internal async Task CheckAsync()
    {
        _update.Text = "Checking...";
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
            var now = Ui.Button(running ? "Updating..." : "Update Now", () =>
            {
                _actions.UpdateNow();
                ShowOffer(offer);
            }, "Update BenchBar now", primary: true);
            now.IsEnabled = !running;
            _updateButtons.Children.Add(now);
        }
        Button? copy = null;
        copy = Ui.Button("Copy Update Line", () =>
        {
            _actions.CopyText(offer.Command);
            if (copy is not null) copy.Content = "Copied";
        }, "Copy the update line for PowerShell");
        _updateButtons.Children.Add(copy);
    }
}
