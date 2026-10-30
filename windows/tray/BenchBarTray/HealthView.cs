using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>Reads back the text of a built view (for tests and for the lines a sheet exposes).</summary>
internal static class TextProbe
{
    public static List<string> Lines(DependencyObject root)
    {
        var lines = new List<string>();
        Collect(root, lines);
        return lines;
    }

    private static void Collect(DependencyObject node, List<string> lines)
    {
        switch (node)
        {
            case TextBlock { Text.Length: > 0 } block:
                lines.Add(block.Text);
                return;
            case TextBox { Text.Length: > 0 } box:
                lines.Add(box.Text);
                return;
        }
        foreach (var child in LogicalTreeHelper.GetChildren(node).OfType<DependencyObject>()) Collect(child, lines);
    }
}

/// <summary>
/// The Health tab of a bench page (macos BenchHealth): Run Doctor shows the checks of <c>doctor --json</c> with their level, message and
/// a Copy of the fix; Repair... shows the plan first and runs it only after a yes (<see cref="RepairSheet"/>); the Windows checks are
/// the shim's own rows (<c>setup check --json</c>, never <c>--probe</c>). Doctor runs when the tab is first shown for a bench and on
/// request, never on a timer.
/// </summary>
internal sealed class HealthView : UserControl, IBenchPageView
{
    private readonly PageServices _services;
    private readonly bool _autoRun;
    private readonly StackPanel _root = new() { MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Left };
    private BenchContext? _context;
    private HealthModel? _model;
    private bool _repairRequested;
    private bool _showPassing;

    public HealthView(PageServices services, bool autoRun = true)
    {
        _services = services;
        _autoRun = autoRun;
        Content = _root;
        Ui.Name(this, "Health");
    }

    public PageServices Services => _services;

    public BenchContext? Context => _context;

    public HealthModel? Model => _model;

    /// <summary>The labels of the buttons in the header, in order (for tests).</summary>
    public IReadOnlyList<string> ButtonLabels { get; private set; } = [];

    /// <summary>Every line of text shown, in order (for tests).</summary>
    public IReadOnlyList<string> Lines { get; private set; } = [];

    public Button? RunDoctorButton { get; private set; }

    public Button? RepairButton { get; private set; }

    /// <summary>The repair sheet while one is open.</summary>
    public RepairSheet? OpenSheet { get; private set; }

    public void Bind(BenchContext context)
    {
        var changedBench = _context is null || _context.Bench.Path != context.Bench.Path;
        var problemChanged = _context is null || _context.Bench.Problem != context.Bench.Problem;
        _context = context;
        if (changedBench)
        {
            _model?.Dispose();
            _model = new HealthModel(_services.Cli, context.Bench.Path);
            _model.Changed += OnModelChanged;
            _showPassing = false;
            Rebuild();
            if (_autoRun) _ = _model.RunAsync();
        }
        else if (problemChanged)
        {
            Rebuild();
        }
        if (_repairRequested)
        {
            _repairRequested = false;
            StartRepair();
        }
    }

    /// <summary>The Repair action of the guidance row: opens the repair sheet (once the tab is bound).</summary>
    public void RequestRepair()
    {
        if (_context is null)
        {
            _repairRequested = true;
            return;
        }
        StartRepair();
    }

    public Task RunDoctorAsync() => _model?.RunAsync() ?? Task.CompletedTask;

    private void OnModelChanged()
    {
        if (Dispatcher.CheckAccess()) Rebuild();
        else Dispatcher.BeginInvoke(Rebuild);
    }

    /// <summary>Draws the view from the model as it is now.</summary>
    public void Refresh() => Rebuild();

    private void Rebuild()
    {
        if (_context is null || _model is null) return;
        var bench = _context.Bench;
        var model = _model;
        _root.Children.Clear();
        _root.Children.Add(Ui.Title("Health"));
        _root.Children.Add(Ui.Text(bench.Name, 14, opacity: 0.75, margin: new Thickness(0, 2, 0, 12)));

        if (bench.Problem is { Length: > 0 } problem) _root.Children.Add(Banner(problem));

        // the doctor section
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        DockPanel.SetDock(buttons, Dock.Right);
        var labels = new List<string>();
        RunDoctorButton = Ui.Button("Run Doctor", () => _ = model.RunAsync(), "Run Doctor " + bench.Name);
        RunDoctorButton.IsEnabled = !model.IsRunning;
        buttons.Children.Add(RunDoctorButton);
        labels.Add("Run Doctor");
        var repairable = model.Repairable;
        RepairButton = Ui.Button("Repair...", StartRepair, "Repair " + bench.Name, primary: repairable);
        RepairButton.IsEnabled = repairable && !model.IsRunning && OpenSheet is null;
        Ui.Name(RepairButton, "Repair " + bench.Name, repairable ? "Shows the plan first; nothing changes until you confirm" : "Nothing repair can fix");
        buttons.Children.Add(RepairButton);
        labels.Add("Repair...");
        ButtonLabels = labels;
        head.Children.Add(buttons);
        var title = new StackPanel { Orientation = Orientation.Horizontal };
        title.Children.Add(Ui.Text("Doctor", 18, FontWeights.SemiBold));
        if (model.Report is { } summary) title.Children.Add(Ui.Text(summary.SummaryText, 13, opacity: 0.75, margin: new Thickness(10, 5, 0, 0)));
        head.Children.Add(title);
        _root.Children.Add(head);

        var card = new StackPanel();
        if (model.Report is { } report)
        {
            if (report.ProfileIsDefault && report.Profile is { Length: > 0 } profile)
                card.Children.Add(Ui.Text($"Profile {profile} is only the default: no profile matches this bench's Frappe, so the env checks warn instead of offering a rebuild.", 13, opacity: 0.75, margin: new Thickness(0, 0, 0, 8)));
            if (report.NeedsAttention.Count == 0)
                card.Children.Add(Line(Ui.CheckGlyph, Ui.StatusBrush(SetupStatus.Ok), "Every check passes."));
            foreach (var check in report.NeedsAttention) card.Children.Add(CheckRow(check));
            if (report.Passing.Count > 0) card.Children.Add(PassingGroup(report));
        }
        else if (model.IsRunning)
        {
            card.Children.Add(Ui.Text("Running doctor...", 14, opacity: 0.75));
        }
        else if (!model.HasRun)
        {
            card.Children.Add(Ui.Text("Doctor has not run yet.", 14, opacity: 0.75));
        }
        if (model.IsRunning && model.Report is not null) card.Children.Add(Ui.Text("Running doctor...", 12, opacity: 0.7, margin: new Thickness(0, 6, 0, 0)));
        if (model.Error is { Length: > 0 } error) card.Children.Add(Banner(error, nested: true));
        _root.Children.Add(Ui.CardOf(card));
        _root.Children.Add(Ui.Text("Doctor is read only. Repair shows its plan, and runs only after you confirm, with a backup before each change.", 12, opacity: 0.7, margin: new Thickness(0, 0, 0, 16)));

        // the Windows section: the shim's own rows
        _root.Children.Add(Ui.Text("Windows", 18, FontWeights.SemiBold, margin: new Thickness(0, 0, 0, 8)));
        var windows = new StackPanel();
        if (model.Shim is { } shim && shim.Steps.Count > 0)
        {
            foreach (var step in shim.Steps) windows.Children.Add(ShimRow(step));
        }
        else if (model.ShimError is { Length: > 0 } shimError)
        {
            windows.Children.Add(Banner(shimError, nested: true));
        }
        else
        {
            windows.Children.Add(Ui.Text(model.IsRunning ? "Checking Windows..." : "Not checked yet.", 14, opacity: 0.75));
        }
        _root.Children.Add(Ui.CardOf(windows));
        _root.Children.Add(Ui.Text("These are the rows of benchbar.exe setup check. They never start a stopped distro.", 12, opacity: 0.7));
        Lines = TextProbe.Lines(_root);
    }

    private UIElement CheckRow(HealthCheck check)
    {
        var brush = check.Level == CheckLevel.Ok ? Ui.StatusBrush(SetupStatus.Ok) : check.Level == CheckLevel.Fail ? Ui.CriticalBrush : Ui.StatusBrush(SetupStatus.Warn);
        var grid = new Grid { Margin = new Thickness(0, 4, 0, 8) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(26) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var glyph = Ui.Glyph(check.Level == CheckLevel.Ok ? Ui.CheckGlyph : check.Level == CheckLevel.Fail ? Ui.ErrorGlyph : Ui.WarningGlyph, 16, brush, HealthText.Tag(check.Level));
        glyph.VerticalAlignment = VerticalAlignment.Top;
        glyph.Margin = new Thickness(0, 2, 0, 0);
        grid.Children.Add(glyph);
        var body = new StackPanel();
        Grid.SetColumn(body, 1);
        var top = new StackPanel { Orientation = Orientation.Horizontal };
        top.Children.Add(Ui.Text(check.Label, 14, FontWeights.SemiBold));
        if (check.Acked) top.Children.Add(Ui.Text("acknowledged", 12, opacity: 0.7, margin: new Thickness(8, 2, 0, 0)));
        body.Children.Add(top);
        body.Children.Add(Ui.Text(check.Message, 13, opacity: 0.85));
        if (check.FixCommand is { Length: > 0 } fix)
        {
            var line = new DockPanel { Margin = new Thickness(0, 4, 0, 0) };
            var copy = Ui.Button("Copy fix", () => _services.CopyText(fix), "Copy fix for " + check.Label, minWidth: 0);
            copy.Margin = new Thickness(8, 0, 0, 0);
            copy.Padding = new Thickness(8, 2, 8, 2);
            DockPanel.SetDock(copy, Dock.Right);
            line.Children.Add(copy);
            var text = new TextBox
            {
                Text = fix,
                IsReadOnly = true,
                BorderThickness = new Thickness(0),
                Background = Brushes.Transparent,
                FontFamily = new FontFamily("Cascadia Mono, Consolas"),
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                Padding = new Thickness(0),
                VerticalAlignment = VerticalAlignment.Center,
            };
            Ui.Name(text, "Fix for " + check.Label);
            line.Children.Add(text);
            body.Children.Add(line);
        }
        grid.Children.Add(body);
        return grid;
    }

    private UIElement PassingGroup(HealthReport report)
    {
        var panel = new StackPanel { Margin = new Thickness(0, 4, 0, 0) };
        var rows = new StackPanel { Visibility = _showPassing ? Visibility.Visible : Visibility.Collapsed };
        foreach (var check in report.Passing) rows.Children.Add(CheckRow(check));
        var toggle = Ui.Link(_showPassing ? $"Hide {report.Passing.Count} passing" : $"Show {report.Passing.Count} passing", () =>
        {
            _showPassing = !_showPassing;
            Rebuild();
        }, "Passing checks");
        panel.Children.Add(toggle);
        panel.Children.Add(rows);
        return panel;
    }

    private static UIElement ShimRow(SetupStepInfo step)
    {
        var row = new Grid { Margin = new Thickness(0, 4, 0, 4) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(26) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var glyph = Ui.StatusGlyph(step.Status);
        glyph.VerticalAlignment = VerticalAlignment.Top;
        glyph.Margin = new Thickness(0, 2, 0, 0);
        row.Children.Add(glyph);
        var body = new StackPanel();
        Grid.SetColumn(body, 1);
        body.Children.Add(Ui.Text(step.Title, 14, FontWeights.SemiBold));
        if (step.Detail.Length > 0) body.Children.Add(Ui.Text(step.Detail, 13, opacity: 0.8));
        row.Children.Add(body);
        return row;
    }

    private static UIElement Line(string glyph, Brush brush, string text)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 0, 6) };
        var icon = Ui.Glyph(glyph, 16, brush);
        icon.Margin = new Thickness(0, 0, 10, 0);
        row.Children.Add(icon);
        row.Children.Add(Ui.Text(text, 14));
        return row;
    }

    private static UIElement Banner(string text, bool nested = false)
    {
        var block = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, Foreground = Ui.CriticalBrush, Margin = new Thickness(0, 4, 0, 8) };
        return nested ? block : Ui.CardOf(block);
    }

    // --- repair ---

    /// <summary>Creates the sheet for the current bench without showing it (for tests, and used by <see cref="StartRepair"/>).</summary>
    public RepairSheet CreateRepairSheet(bool load = true)
    {
        var bench = _context!.Bench;
        var model = new RepairModel(_services.Cli, bench.Path, bench.Name) { AskLinuxPassword = _services.AskLinuxPassword };
        return new RepairSheet(model, _services.Theme(), _services.Owner(), _services.CopyText, load);
    }

    /// <summary>Shows the repair sheet: the plan first, and Repair only on the person's yes. Returns when it closes.</summary>
    public void StartRepair()
    {
        if (_context is null || OpenSheet is not null) return;
        var sheet = CreateRepairSheet();
        OpenSheet = sheet;
        Rebuild();
        sheet.ShowDialog();
        OpenSheet = null;
        // the answer is old once a repair ran: ask doctor again, and let the sidebar catch up
        if (sheet.Model.Ran)
        {
            _services.RefreshNow();
            if (_model is not null && _context?.Bench.Path == sheet.Model.BenchPath) _ = _model.RunAsync();
        }
        Rebuild();
    }
}

/// <summary>
/// The repair sheet (macos RepairSheet): the plan, a confirmation, then each step as it runs. The steps stay on screen while it runs,
/// after it and after a failure. While it runs it cannot be closed. It only draws <see cref="RepairModel"/>.
/// </summary>
internal sealed class RepairSheet : Window
{
    private readonly Action<string> _copy;
    private readonly ContentControl _body = new() { IsTabStop = false };
    private readonly StackPanel _bar = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };

    public RepairSheet(RepairModel model, ResolvedTheme theme, Window? owner, Action<string> copy, bool load = true)
    {
        Model = model;
        _copy = copy;
        Title = "Repair " + model.BenchName;
        Width = 600;
        MaxHeight = 760;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = owner is null;
        Owner = owner;
        WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;
        Ui.ApplyTheme(this, theme);
        Ui.Name(this, "Repair " + model.BenchName);

        var grid = new Grid { Margin = new Thickness(24) };
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Auto) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var scroll = new ScrollViewer { Content = _body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = 600 };
        Grid.SetRow(scroll, 0);
        Grid.SetRow(_bar, 1);
        grid.Children.Add(scroll);
        grid.Children.Add(_bar);
        Content = grid;

        model.Changed += OnChanged;
        Closing += (_, e) =>
        {
            if (!Model.IsDismissible) e.Cancel = true;
        };
        Closed += (_, _) =>
        {
            model.Changed -= OnChanged;
            model.Dispose();
        };
        Rebuild();
        if (load) Loaded += (_, _) => _ = model.LoadPlanAsync();
    }

    public RepairModel Model { get; }

    /// <summary>The labels of the buttons in the bar, left to right (for tests).</summary>
    public IReadOnlyList<string> ButtonLabels { get; private set; } = [];

    /// <summary>Every line of text in the body, in order (for tests).</summary>
    public IReadOnlyList<string> Lines { get; private set; } = [];

    private void OnChanged()
    {
        if (Dispatcher.CheckAccess()) Rebuild();
        else Dispatcher.BeginInvoke(Rebuild);
    }

    /// <summary>Draws the sheet from the model as it is now.</summary>
    public void Refresh() => Rebuild();

    private void Rebuild()
    {
        var panel = new StackPanel { Width = 550 };
        var buttons = new List<(string Label, Action Click, bool Primary, bool Enabled)>();
        switch (Model.Phase)
        {
            case RepairPhase.Planning:
                panel.Children.Add(Ui.Text("Repair " + Model.BenchName, 18, FontWeights.SemiBold));
                panel.Children.Add(Ui.Text("Reading the plan (benchbar repair --dry-run)...", 14, opacity: 0.75, margin: new Thickness(0, 8, 0, 0)));
                buttons.Add(("Cancel", Close, false, true));
                break;
            case RepairPhase.Review:
                Header(panel, "Repair " + Model.BenchName, "Runs the fixes doctor found, in order, with a backup before each change.");
                if (Model.Message is { Length: > 0 } message) panel.Children.Add(Ui.CriticalText(message));
                if (Model.Steps.Count == 0) panel.Children.Add(Ui.Text("Nothing to repair.", 14, FontWeights.SemiBold, margin: new Thickness(0, 12, 0, 0)));
                else Steps(panel);
                panel.Children.Add(Ui.Text("A backup is taken before every change. Broken folders are moved aside, never deleted.", 13, opacity: 0.8, margin: new Thickness(0, 12, 0, 0)));
                if (Model.HasSudoSteps)
                    panel.Children.Add(Ui.Text($"{Model.SudoSteps} {(Model.SudoSteps == 1 ? "step uses" : "steps use")} sudo. BenchBar asks for your Linux password when you press Repair; it is used for this run only. Cancel the question and nothing runs.", 13, margin: new Thickness(0, 8, 0, 0)));
                buttons.Add(("Repair", () => _ = Model.RunAsync(), true, Model.CanRepair));
                buttons.Add(("Cancel", Close, false, true));
                break;
            case RepairPhase.Running:
                Header(panel, "Repairing...", "This cannot be stopped part way. Keep the window open until it ends.");
                Steps(panel);
                LogLine(panel);
                break;
            case RepairPhase.Finished:
                Header(panel, Model.Succeeded ? "Repair finished; every check passes." : "Repair finished with problems left", Model.Succeeded ? null : "See the steps below and the log.");
                Steps(panel);
                LogLine(panel);
                buttons.Add(("Close", Close, true, true));
                break;
            default:
                Header(panel, Model.Steps.Count == 0 ? "No repair plan" : "Repair stopped", null);
                if (Model.Message is { Length: > 0 } failure) panel.Children.Add(Ui.CriticalText(failure));
                Steps(panel);
                LogLine(panel);
                if (Model.Steps.Count == 0) buttons.Add(("Read Plan Again", () => _ = Model.LoadPlanAsync(), true, true));
                buttons.Add(("Close", Close, Model.Steps.Count > 0, true));
                break;
        }
        Lines = TextProbe.Lines(panel);
        _body.Content = panel;

        _bar.Children.Clear();
        foreach (var (label, click, primary, enabled) in buttons)
        {
            var button = Ui.Button(label, click, label, primary);
            button.IsEnabled = enabled;
            if (label is "Cancel" or "Close") button.IsCancel = Model.IsDismissible;
            _bar.Children.Add(button);
        }
        ButtonLabels = buttons.Select(b => b.Label).ToList();
    }

    private static void Header(StackPanel panel, string title, string? line)
    {
        panel.Children.Add(Ui.Text(title, 18, FontWeights.SemiBold));
        if (line is not null) panel.Children.Add(Ui.Text(line, 14, opacity: 0.8, margin: new Thickness(0, 6, 0, 0)));
    }

    private void Steps(StackPanel panel)
    {
        var steps = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
        foreach (var step in Model.Steps)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 2) };
            var glyph = Ui.Glyph(StepGlyph(step.Status), 14, Ui.StepBrush(step.Status), StepWord(step.Status));
            glyph.Margin = new Thickness(0, 0, 8, 0);
            glyph.VerticalAlignment = VerticalAlignment.Top;
            row.Children.Add(glyph);
            var text = new StackPanel();
            text.Children.Add(Ui.Text(step.Label + (step.Sudo ? "  (asks for your Linux password)" : ""), 14));
            if (step.Message.Length > 0 && step.Status != InstallStepStatus.Done) text.Children.Add(Ui.Text(step.Message, 12, opacity: 0.7));
            row.Children.Add(text);
            steps.Children.Add(row);
        }
        panel.Children.Add(steps);
    }

    private void LogLine(StackPanel panel)
    {
        if (Model.Log is not { Length: > 0 } log) return;
        var row = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
        var copy = Ui.Button("Copy Log Path", () => _copy(log), "Copy the repair log path", minWidth: 0);
        copy.Margin = new Thickness(8, 0, 0, 0);
        DockPanel.SetDock(copy, Dock.Right);
        row.Children.Add(copy);
        row.Children.Add(new TextBlock { Text = log, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12, Opacity = 0.7, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center });
        panel.Children.Add(row);
    }

    private static string StepGlyph(InstallStepStatus status) => status switch
    {
        InstallStepStatus.Done or InstallStepStatus.Unchanged => Ui.CheckGlyph,
        InstallStepStatus.Failed => Ui.ErrorGlyph,
        InstallStepStatus.Warning or InstallStepStatus.Skipped or InstallStepStatus.Stopped => Ui.WarningGlyph,
        _ => Ui.PendingGlyph,
    };

    /// <summary>What a screen reader says for the icon (macos StepIcon.label).</summary>
    public static string StepWord(InstallStepStatus status) => status switch
    {
        InstallStepStatus.Running => "running",
        InstallStepStatus.Done or InstallStepStatus.Unchanged => "done",
        InstallStepStatus.Skipped => "skipped",
        InstallStepStatus.Failed => "failed",
        _ => "not started",
    };
}
