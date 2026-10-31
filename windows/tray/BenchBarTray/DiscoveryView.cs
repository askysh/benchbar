using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// The Find Benches pane (macos DiscoveryPane): scan a folder inside the distro, list the benches with their state, add the ones to
/// remember, and set up management through the plan review sheet. There is no Windows folder picker, because benches live in WSL:
/// the folder is a text box with the recent folders one click away. It is not about one bench, so it gets no bench context.
/// </summary>
internal sealed class DiscoveryView : UserControl
{
    private readonly PageServices _services;
    private readonly DiscoveryModel _model;
    private readonly TextBox _folderBox;
    private readonly Button _chooseButton;
    private readonly Button _scanButton;
    private readonly StackPanel _body = new();
    private bool _working;

    public DiscoveryView(PageServices services)
        : this(services, new WslHost(new SystemProcessRunner(), () => DistroName.Resolve(TrayConfig.Load().Distro)), new RecentFolders(RecentFolders.DefaultPath))
    {
    }

    /// <summary>For tests: a fake WSL and a recent list in memory.</summary>
    internal DiscoveryView(PageServices services, IWslHost wsl, RecentFolders recent)
    {
        _services = services;
        _model = new DiscoveryModel(services.Cli, wsl, recent);
        var root = new StackPanel { MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Left };
        root.Children.Add(Ui.Title("Find Benches"));
        root.Children.Add(Ui.Text("BenchBar searches a folder inside Linux for existing Frappe benches.", 14, opacity: 0.75, margin: new Thickness(0, 6, 0, 12)));

        var folderRow = new DockPanel { Margin = new Thickness(0, 0, 0, 8), LastChildFill = true };
        _scanButton = Ui.Button("Scan", () => _model.ScanAsync().Forget(), "Scan this folder", minWidth: 64);
        _scanButton.Margin = new Thickness(8, 0, 0, 0);
        _chooseButton = Ui.Button("Choose Folder...", ShowFolderMenu, "Choose Folder", minWidth: 0);
        _chooseButton.Margin = new Thickness(8, 0, 0, 0);
        DockPanel.SetDock(_scanButton, Dock.Right);
        DockPanel.SetDock(_chooseButton, Dock.Right);
        _folderBox = Ui.Field("Folder to search in Linux", "", text => _model.Folder = text, width: double.NaN);
        _folderBox.HorizontalAlignment = HorizontalAlignment.Stretch;
        _folderBox.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && !_model.IsBusy && !_working) _model.ScanAsync().Forget();
        };
        folderRow.Children.Add(_scanButton);
        folderRow.Children.Add(_chooseButton);
        folderRow.Children.Add(_folderBox);
        root.Children.Add(folderRow);
        root.Children.Add(_body);
        Content = root;
        Ui.Name(this, "Find Benches");

        _model.Changed += Render;
        Render();
    }

    public PageServices Services => _services;

    internal DiscoveryModel Model => _model;

    /// <summary>The text of the folder box (for tests).</summary>
    internal string FolderText => _folderBox.Text;

    /// <summary>Called each time the pane is selected in the sidebar (fills the folder box the first time; a scan starts only when asked).</summary>
    public void OnShown() => EnterAsync().Forget();

    internal async Task EnterAsync()
    {
        await _model.EnterAsync();
        SyncFolderBox();
    }

    // --- actions ---

    /// <summary>Add Selected: <c>register --json -- PATHS</c>.</summary>
    internal async Task AddSelectedAsync()
    {
        await _model.AddSelectedAsync();
        _services.RefreshNow();
    }

    /// <summary>Set Up Selected...: the port plan, then the plan review sheet.</summary>
    internal Task SetUpSelectedAsync() => RunSetupAsync(async () =>
    {
        var prep = await _model.PrepareSetupAsync(_model.SelectedInOrder());
        return prep.Request;
    });

    /// <summary>Set Up Management... on one row: <c>adopt PATH --dry-run --json</c>, then the sheet.</summary>
    internal Task SetUpManagementAsync(FoundBench bench) =>
        RunSetupAsync(() => Task.FromResult<PlanReviewRequest?>(DiscoveryModel.AdoptRequest(bench.Path, bench.Name)));

    private async Task RunSetupAsync(Func<Task<PlanReviewRequest?>> prepare)
    {
        if (_working || _model.IsBusy) return;
        _working = true;
        Render();
        try
        {
            if (await prepare() is not { } request) return;
            var outcome = await _services.ReviewPlan(request);
            await _model.SetupFinishedAsync(outcome);
        }
        finally
        {
            _working = false;
            Render();
        }
    }

    internal IReadOnlyList<string> ChooseFolderItems() => ["Home folder (~)", .. _model.RecentList];

    private void ShowFolderMenu()
    {
        var menu = new ContextMenu { PlacementTarget = _chooseButton, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
        Ui.Name(menu, "Folders");
        var home = new MenuItem { Header = "Home folder (~)" };
        home.Click += (_, _) => Pick("~");
        menu.Items.Add(home);
        if (_model.RecentList.Count > 0) menu.Items.Add(new Separator());
        foreach (var folder in _model.RecentList)
        {
            var item = new MenuItem { Header = folder.Replace("_", "__") };
            var chosen = folder;
            item.Click += (_, _) => Pick(chosen);
            menu.Items.Add(item);
        }
        menu.IsOpen = true;
    }

    private void Pick(string folder)
    {
        if (_model.IsBusy || _working) return;
        _model.Folder = folder;
        SyncFolderBox();
        _model.ScanAsync().Forget();
    }

    private void SyncFolderBox()
    {
        if (_folderBox.Text != _model.Folder) _folderBox.Text = _model.Folder;
    }

    // --- drawing ---

    /// <summary>Every line of text in the body, in order (for tests).</summary>
    internal IReadOnlyList<string> Lines { get; private set; } = [];

    /// <summary>The labels of the body's buttons, in order (for tests).</summary>
    internal IReadOnlyList<string> ButtonLabels { get; private set; } = [];

    private void Render()
    {
        var lines = new List<string>();
        var buttons = new List<string>();
        _body.Children.Clear();
        var busy = _model.IsBusy || _working;
        _scanButton.IsEnabled = !busy;
        _chooseButton.IsEnabled = !busy;
        _folderBox.IsEnabled = !busy;

        void Line(string text, double size = 14, double opacity = 1, Brush? brush = null, Thickness? margin = null)
        {
            var block = Ui.Text(text, size, null, opacity, margin);
            if (brush is not null) block.Foreground = brush;
            _body.Children.Add(block);
            lines.Add(text);
        }

        if (_model.IsScanning)
        {
            var row = new DockPanel { Margin = new Thickness(0, 4, 0, 8) };
            var cancel = Ui.Button("Cancel Scan", _model.CancelScan, "Cancel Scan", minWidth: 0);
            cancel.Margin = new Thickness(12, 0, 0, 0);
            DockPanel.SetDock(cancel, Dock.Right);
            row.Children.Add(cancel);
            row.Children.Add(Ui.Text("Searching folders...", 14, opacity: 0.8));
            _body.Children.Add(row);
            lines.Add("Searching folders...");
            buttons.Add("Cancel Scan");
        }
        if (_model.Error is { } error) Line(error, brush: Ui.CriticalBrush, margin: new Thickness(0, 4, 0, 8));
        if (_model.Message is { } message) Line(message, opacity: 0.8, margin: new Thickness(0, 4, 0, 8));
        if (_model.Warnings.Count > 0) AddWarnings(lines);

        if (_model.HasScanned && _model.Results.Count == 0)
        {
            AddEmpty("No benches found",
                "Choose a folder containing a bench or its parent projects. Hidden folders, dependencies, tests and symlinks are skipped.",
                "Choose Another Folder...", ShowFolderMenu, lines, buttons, !busy);
        }
        else if (_model.Results.Count > 0)
        {
            AddResults(lines, buttons, busy);
        }
        else if (!_model.IsScanning)
        {
            AddEmpty("Your benches, in one place",
                "Scan a folder such as your home to find benches, then add the ones you want BenchBar to manage.",
                "Scan Folder", () => _model.ScanAsync().Forget(), lines, buttons, !busy);
        }

        Line("Scanning only reads folders. Add Selected remembers your benches; Set Up Management previews the service changes before you apply them.",
            12, 0.7, margin: new Thickness(0, 16, 0, 0));
        Lines = lines;
        ButtonLabels = buttons;
    }

    private void AddEmpty(string title, string line, string actionLabel, Action action, List<string> lines, List<string> buttons, bool enabled)
    {
        var panel = new StackPanel { Margin = new Thickness(0, 24, 0, 8) };
        panel.Children.Add(Ui.Text(title, 18, FontWeights.SemiBold));
        panel.Children.Add(Ui.Text(line, 14, opacity: 0.75, margin: new Thickness(0, 6, 0, 12)));
        var button = Ui.Button(actionLabel, action, actionLabel, primary: true, minWidth: 0);
        button.HorizontalAlignment = HorizontalAlignment.Left;
        button.IsEnabled = enabled;
        panel.Children.Add(button);
        _body.Children.Add(panel);
        lines.Add(title);
        lines.Add(line);
        buttons.Add(actionLabel);
    }

    private void AddWarnings(List<string> lines)
    {
        var warnings = _model.WarningLines;
        var title = ScanJson.WarningsTitle(warnings.Count);
        var list = new StackPanel { Margin = new Thickness(0, 4, 0, 0) };
        lines.Add(title);
        foreach (var w in warnings)
        {
            list.Children.Add(Ui.Text(w, 12, margin: new Thickness(0, 0, 0, 2)));
            lines.Add(w);
        }
        var expander = new Expander { Header = title, Content = list, Margin = new Thickness(0, 0, 0, 8) };
        Ui.Name(expander, title);
        _body.Children.Add(expander);
    }

    private void AddResults(List<string> lines, List<string> buttons, bool busy)
    {
        var head = new DockPanel { Margin = new Thickness(0, 8, 0, 6) };
        var all = _model.AllSelected;
        var toggleLabel = all ? "Deselect All" : "Select All";
        var toggle = Ui.Button(toggleLabel, () => { if (all) _model.DeselectAll(); else _model.SelectAll(); }, toggleLabel, minWidth: 0);
        toggle.Margin = new Thickness(0);
        toggle.IsEnabled = !busy && (all ? _model.Selected.Count > 0 : _model.SelectablePaths.Count > 0);
        DockPanel.SetDock(toggle, Dock.Right);
        var count = _model.Results.Count == 1 ? "1 bench found" : $"{_model.Results.Count} benches found";
        head.Children.Add(toggle);
        head.Children.Add(Ui.Text(count, 16, FontWeights.SemiBold));
        _body.Children.Add(head);
        lines.Add(count);
        buttons.Add(toggleLabel);

        foreach (var bench in _model.Results) _body.Children.Add(ResultRow(bench, lines, buttons, busy));

        var bar = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
        var setUp = Ui.Button("Set Up Selected...", () => SetUpSelectedAsync().Forget(), "Set Up Selected", primary: true, minWidth: 0);
        setUp.Margin = new Thickness(0);
        setUp.IsEnabled = _model.CanSetUp && !_working;
        var add = Ui.Button("Add Selected", () => AddSelectedAsync().Forget(), "Add Selected", minWidth: 0);
        add.Margin = new Thickness(0, 0, 8, 0);
        add.IsEnabled = _model.CanAdd && !_working;
        var selected = $"{_model.Selected.Count} selected";
        DockPanel.SetDock(setUp, Dock.Right);
        DockPanel.SetDock(add, Dock.Right);
        bar.Children.Add(setUp);
        bar.Children.Add(add);
        bar.Children.Add(Ui.Text(selected, 14, opacity: 0.7));
        _body.Children.Add(bar);
        lines.Add(selected);
        buttons.Add("Add Selected");
        buttons.Add("Set Up Selected...");
    }

    private static string SiteLine(FoundBench bench) =>
        bench.Ports.Web > 0 ? (bench.Site.Length > 0 ? $"{bench.Site} · Port {bench.Ports.Web}" : $"Port {bench.Ports.Web}") : bench.Site;

    private UIElement ResultRow(FoundBench bench, List<string> lines, List<string> buttons, bool busy)
    {
        var state = _model.StateOf(bench);
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        if (state == FoundState.Managed)
        {
            var mark = Ui.Text("✓", 16, margin: new Thickness(2, 0, 12, 0));
            mark.Foreground = Ui.StepBrush(InstallStepStatus.Done);
            Ui.Name(mark, $"{bench.Name} is managed by BenchBar");
            grid.Children.Add(mark);
        }
        else
        {
            var box = new CheckBox { IsChecked = _model.Selected.Contains(bench.Path), IsEnabled = !busy, Margin = new Thickness(0, 2, 12, 0), VerticalAlignment = VerticalAlignment.Top };
            Ui.Name(box, $"Select {bench.Name} at {bench.Path}");
            var path = bench.Path;
            box.Click += (_, _) => _model.SetSelected(path, box.IsChecked == true);
            grid.Children.Add(box);
        }

        var text = new StackPanel();
        Grid.SetColumn(text, 1);
        text.Children.Add(Ui.Text(bench.Name, 15, FontWeights.SemiBold));
        text.Children.Add(Ui.Caption(bench.Path));
        text.Children.Add(Ui.Caption(SiteLine(bench)));
        lines.Add(bench.Name);
        lines.Add(bench.Path);
        lines.Add(SiteLine(bench));
        if (_model.HasPortConflict(bench))
        {
            const string conflict = "Port conflict · Review during setup";
            var block = Ui.Caption(conflict);
            block.Foreground = Ui.StepBrush(InstallStepStatus.Failed);
            text.Children.Add(block);
            lines.Add(conflict);
        }
        var label = state switch
        {
            FoundState.Managed => "Managed by BenchBar",
            FoundState.AddedNeedsSetup => "Added · Management needs setup",
            _ => "Not adopted",
        };
        text.Children.Add(Ui.Caption(label));
        lines.Add(label);
        grid.Children.Add(text);

        if (state != FoundState.Managed)
        {
            var setup = Ui.Button("Set Up Management...", () => SetUpManagementAsync(bench).Forget(), $"Set Up Management for {bench.Name}", minWidth: 0);
            setup.Margin = new Thickness(12, 0, 0, 0);
            setup.VerticalAlignment = VerticalAlignment.Top;
            setup.IsEnabled = !busy;
            Grid.SetColumn(setup, 2);
            grid.Children.Add(setup);
            buttons.Add("Set Up Management...");
        }
        return Ui.CardOf(grid, new Thickness(0, 0, 0, 6));
    }
}
