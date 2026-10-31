using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// Port Settings and Setup, and Resolve and Start (macos PortSetupSheet): the ports of a bench and the mode (Automatic or Fixed), the plan
/// of <c>ports plan --json</c>, Refresh Preview, and Apply. Applying changes ports only after the person reviewed this plan. It cannot be
/// closed while the apply runs. It only draws <see cref="PortSetupModel"/>.
/// </summary>
internal sealed class PortSetupSheet : Window
{
    private readonly ContentControl _body = new() { IsTabStop = false };
    private readonly DockPanel _bar = new() { Margin = new Thickness(0, 16, 0, 0), LastChildFill = false };
    private readonly StackPanel _right = new() { Orientation = Orientation.Horizontal };

    public PortSetupSheet(PortSetupModel model, ResolvedTheme theme, Window? owner, Action<string> copy, bool load = true)
    {
        Model = model;
        Title = model.Title;
        Width = 660;
        MaxHeight = 780;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = owner is null;
        Owner = owner;
        WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;
        Ui.ApplyTheme(this, theme);
        Ui.Name(this, model.Title);

        var grid = new Grid { Margin = new Thickness(24) };
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Auto) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var scroll = new ScrollViewer { Content = _body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = 640 };
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
        if (load) Loaded += (_, _) => model.LoadPlanAsync().Forget();
    }

    public PortSetupModel Model { get; }

    /// <summary>The labels of the buttons of the bar, left side first (for tests).</summary>
    public IReadOnlyList<string> ButtonLabels { get; private set; } = [];

    /// <summary>Every line of text in the body, in order (for tests).</summary>
    public IReadOnlyList<string> Lines { get; private set; } = [];

    /// <summary>The mode pickers of the entries, by the bench path (for tests).</summary>
    public IReadOnlyDictionary<string, ComboBox> ModePickers { get; private set; } = new Dictionary<string, ComboBox>();

    /// <summary>
    /// Opens the sheet for one bench over the owner window and returns when it closes: true when the setup ran to its end. The app polls
    /// again afterwards, since the apply may have changed the service or the ports.
    /// </summary>
    public static bool Show(PageServices services, BenchStatus bench, bool startAfterSetup, bool opensSettings)
    {
        var model = new PortSetupModel(services.Cli, [new PortBench(bench.Path, bench.Name)], startAfterSetup, opensSettings);
        var sheet = new PortSetupSheet(model, services.Theme(), services.Owner(), services.CopyText);
        sheet.ShowDialog();
        var finished = model.Phase == PortSetupPhase.Finished;
        services.RefreshNow();
        return finished;
    }

    private void OnChanged()
    {
        if (Dispatcher.CheckAccess()) Rebuild();
        else Dispatcher.BeginInvoke(Rebuild);
    }

    /// <summary>Draws the sheet from the model as it is now.</summary>
    public void Refresh() => Rebuild();

    private void Rebuild()
    {
        var panel = new StackPanel { Width = 610 };
        var calm = Model.NothingToSetUp;
        var pickers = new Dictionary<string, ComboBox>();
        panel.Children.Add(Ui.Text(Model.Title, 18, FontWeights.SemiBold));
        var explanation = Model.Phase == PortSetupPhase.Planning
            ? "Checking ports and preparing the selection..."
            : calm
                ? "The ports this bench uses, and whether BenchBar may move them. Nothing needs setting up."
                : "Review the addresses and service changes before applying. Existing apps and databases are preserved.";
        panel.Children.Add(Ui.Text(explanation, 14, opacity: 0.8, margin: new Thickness(0, 6, 0, 8)));
        if (Model.ModeError is { Length: > 0 } modeError) panel.Children.Add(Ui.CriticalText(modeError));
        if (Model.Phase == PortSetupPhase.Running) panel.Children.Add(Ui.Text("Applying changes...", 14, FontWeights.SemiBold, margin: new Thickness(0, 4, 0, 4)));
        if (Model.Phase == PortSetupPhase.Failed)
        {
            panel.Children.Add(Ui.Text("Setup did not finish", 16, FontWeights.SemiBold, margin: new Thickness(0, 4, 0, 0)));
            if (Model.Error is { Length: > 0 } error) panel.Children.Add(Ui.CriticalText(error));
        }
        if (Model.Phase == PortSetupPhase.Finished) panel.Children.Add(Ui.Text(Model.SuccessText, 14, FontWeights.SemiBold, margin: new Thickness(0, 4, 0, 4)));

        if (Model.Plan is { } plan)
        {
            foreach (var entry in plan.Entries) panel.Children.Add(Entry(entry, calm, pickers));
            if (Model.Phase == PortSetupPhase.Review && !plan.CanApply && !calm)
                panel.Children.Add(Ui.Text("Resolve the blocked benches before applying. Fixed mode keeps the current ports; Automatic allows a new allocation after review.", 13, opacity: 0.8, margin: new Thickness(0, 8, 0, 0)));
        }
        if (Model.Output.Length > 0)
        {
            var output = new Expander { Header = "Setup output", Margin = new Thickness(0, 8, 0, 0), Content = Ui.Mono(Model.Output) };
            Ui.Name(output, "Setup output");
            panel.Children.Add(output);
        }
        panel.Children.Add(Ui.Text(calm
            ? "Fixed keeps these ports. Automatic lets BenchBar propose new ones, for your approval, when another bench or app takes them. A change of mode is saved at once."
            : "Changing the mode saves your preference immediately; ports change only when you apply. Apply writes the service files; it never starts a bench unless you chose Resolve and Start.",
            12, opacity: 0.7, margin: new Thickness(0, 10, 0, 0)));
        Lines = TextProbe.Lines(panel);
        ModePickers = pickers;
        _body.Content = panel;

        _bar.Children.Clear();
        _right.Children.Clear();
        var labels = new List<string>();
        if (!Model.IsBusy && Model.Phase != PortSetupPhase.Finished)
        {
            var refresh = calm ? "Check Again" : "Refresh Preview";
            var button = Ui.Button(refresh, () => Model.LoadPlanAsync().Forget(), refresh);
            DockPanel.SetDock(button, Dock.Left);
            _bar.Children.Add(button);
            labels.Add(refresh);
        }
        void Right(string label, Action click, bool primary = false, bool enabled = true, bool dismiss = false)
        {
            var b = Ui.Button(label, click, label, primary);
            b.IsEnabled = enabled;
            if (dismiss) b.IsCancel = Model.IsDismissible;
            _right.Children.Add(b);
            labels.Add(label);
        }
        switch (Model.Phase)
        {
            case PortSetupPhase.Review when calm:
                Right("Done", Close, true, dismiss: true);
                break;
            case PortSetupPhase.Review:
                Right("Cancel", Close, dismiss: true);
                Right(Model.ApplyLabel, () => Model.ApplyAsync().Forget(), true, Model.CanApply);
                break;
            case PortSetupPhase.Planning:
                Right("Cancel", Close, dismiss: true);
                break;
            case PortSetupPhase.Running:
                break;
            default:
                Right("Done", Close, true, dismiss: true);
                break;
        }
        DockPanel.SetDock(_right, Dock.Right);
        _bar.Children.Add(_right);
        ButtonLabels = labels;
    }

    private UIElement Entry(PortPlanEntry entry, bool calm, Dictionary<string, ComboBox> pickers)
    {
        var box = new StackPanel { Margin = new Thickness(0, 6, 0, 10) };
        box.Children.Add(Ui.Text(entry.Name, 16, FontWeights.SemiBold));
        box.Children.Add(Ui.Text(entry.Path, 12, opacity: 0.7));
        if (calm)
        {
            box.Children.Add(Pair("Address", entry.CurrentUrl));
        }
        else
        {
            box.Children.Add(Pair("Current address", entry.CurrentUrl));
            box.Children.Add(Pair(entry.ChangesPorts ? "New address" : "Address stays", entry.ProposedUrl));
        }
        var p = entry.Proposed;
        box.Children.Add(Ui.Text($"Web {p.Web} | Socket.IO {p.Socketio} | Redis {p.RedisQueue}/{p.RedisCache}", 12, margin: new Thickness(0, 2, 0, 4)));
        if (!calm && entry.SetupPlan is { Length: > 0 } setup)
        {
            var head = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 2) };
            head.Children.Add(Ui.Text("Service changes", 13, FontWeights.SemiBold));
            box.Children.Add(head);
            box.Children.Add(Ui.Mono(setup));
        }

        var mode = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
        mode.Children.Add(Ui.Text("Port mode", 13, margin: new Thickness(0, 4, 10, 0)));
        var picker = new ComboBox { MinWidth = 140, IsEnabled = Model.Phase == PortSetupPhase.Review };
        picker.Items.Add(new ComboBoxItem { Content = PortModes.Title(PortMode.Automatic), Tag = PortMode.Automatic });
        picker.Items.Add(new ComboBoxItem { Content = PortModes.Title(PortMode.Fixed), Tag = PortMode.Fixed });
        picker.SelectedIndex = entry.Mode == PortMode.Fixed ? 1 : 0;
        picker.SelectionChanged += (_, e) =>
        {
            if (e.AddedItems.Count == 1 && e.RemovedItems.Count == 1 && e.AddedItems[0] is ComboBoxItem { Tag: PortMode chosen })
                Model.SetModeAsync(chosen, entry.Path).Forget();
        };
        Ui.Name(picker, "Port mode " + entry.Name, "Fixed keeps the current ports. Automatic can propose new ports for your approval.");
        pickers[entry.Path] = picker;
        mode.Children.Add(picker);
        box.Children.Add(mode);

        if (!calm && entry.Blocked is { Length: > 0 } blocked) box.Children.Add(Ui.CriticalText(blocked));
        else if (entry.ChangesPorts) box.Children.Add(Ui.Text("Port conflict resolved by the proposed allocation", 13, opacity: 0.8, margin: new Thickness(0, 6, 0, 0)));
        if (entry.Conflicts.Count > 0)
        {
            var details = new StackPanel();
            foreach (var conflict in entry.Conflicts) details.Children.Add(Ui.Text(conflict, 12));
            var expander = new Expander { Header = "Conflict details", Content = details, Margin = new Thickness(0, 6, 0, 0) };
            Ui.Name(expander, "Conflict details " + entry.Name);
            box.Children.Add(expander);
        }
        return box;
    }

    private static UIElement Pair(string label, string value)
    {
        var row = new Grid { Margin = new Thickness(0, 2, 0, 2) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(Ui.Text(label, 13, opacity: 0.7));
        var text = Ui.Text(value, 14);
        Grid.SetColumn(text, 1);
        row.Children.Add(text);
        return row;
    }
}
