using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>What the main window's Overview does for one bench. Every member has a harmless default, so the view works alone in tests.</summary>
internal sealed class OverviewActions
{
    public Func<BenchStatus, Task<ActionResult>> StartStop { get; set; } = _ => Task.FromResult(ActionResult.Success);
    public Func<BenchStatus, Task<ActionResult>> Restart { get; set; } = _ => Task.FromResult(ActionResult.Success);
    public Action<BenchStatus> OpenSite { get; set; } = _ => { };
    public Action<BenchStatus> ShowLogs { get; set; } = _ => { };
    public Action<BenchStatus> ShowDoctor { get; set; } = _ => { };
    public Func<BenchStatus, VsCodeOutcome> OpenEditor { get; set; } = _ => VsCodeOutcome.Launched;
    public Func<string> EditorName { get; set; } = () => "VS Code";
    public Action<string> CopyText { get; set; } = _ => { };
    public Action<string> OpenUrl { get; set; } = _ => { };
}

/// <summary>
/// One bench in the main window: its state, address and the actions the flyout row has (Start or Stop, Restart, Open site, Logs,
/// Doctor, Open in editor). Phase 2 grows this into the bench pages. Rebuilt only when something it shows changed.
/// </summary>
internal sealed class OverviewView : UserControl
{
    private readonly OverviewActions _actions;
    private readonly HashSet<string> _busy = [];
    private readonly Dictionary<string, (string Message, BenchState State)> _failures = [];
    private BenchStatus? _bench;
    private string? _site;
    private string _key = "";

    public OverviewView(OverviewActions actions)
    {
        _actions = actions;
        Margin = new Thickness(0);
    }

    public BenchStatus? Bench => _bench;

    /// <summary>The labels of the buttons, in Tab order (for tests).</summary>
    public IReadOnlyList<string> ButtonLabels { get; private set; } = [];

    public string MessageText { get; private set; } = "";

    public Button? StartStopButton { get; private set; }

    public void Bind(BenchStatus bench, string? site)
    {
        if (_failures.TryGetValue(bench.Path, out var f) && f.State != bench.State) _failures.Remove(bench.Path);
        var key = string.Join('|', bench.Path, bench.Name, bench.State, bench.RawState, bench.StopReason, bench.WebUrl, bench.Site, site,
            _busy.Contains(bench.Path), _failures.TryGetValue(bench.Path, out var g) ? g.Message : "", bench.Problem, MessageText);
        _bench = bench;
        _site = site;
        if (key == _key) return;
        _key = key;
        Rebuild(bench);
    }

    private void Rebuild(BenchStatus bench)
    {
        var buttons = OverviewButtons.For(bench, _busy.Contains(bench.Path));
        var root = new StackPanel { MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Left };

        var head = new StackPanel { Orientation = Orientation.Horizontal };
        var dot = Ui.Dot(bench.State, 12);
        dot.Margin = new Thickness(0, 4, 10, 0);
        head.Children.Add(dot);
        head.Children.Add(Ui.Text(_site ?? bench.Name, 26, FontWeights.SemiBold));
        root.Children.Add(head);

        var state = BenchPresentation.StateWord(bench);
        root.Children.Add(Ui.Text(_site is null ? state : $"{bench.Name}, {state}", 14, opacity: 0.75, margin: new Thickness(22, 2, 0, 12)));

        var labels = new List<string>();
        var strip = new WrapPanel { Margin = new Thickness(0, 0, 0, 12) };
        StartStopButton = Add(strip, labels, buttons.StartStopLabel, () => _ = RunAsync(bench, _actions.StartStop), buttons.CanStartStop, primary: true);
        Add(strip, labels, "Restart", () => _ = RunAsync(bench, _actions.Restart), buttons.CanRestart);
        Add(strip, labels, "Open Site", () => _actions.OpenSite(bench), buttons.CanOpenSite);
        Add(strip, labels, "Logs", () => _actions.ShowLogs(bench), true);
        Add(strip, labels, "Doctor", () => _actions.ShowDoctor(bench), true);
        var editor = _actions.EditorName();
        Add(strip, labels, "Open in " + editor, () => OpenEditor(bench), true);
        root.Children.Add(strip);
        ButtonLabels = labels;

        if (_failures.TryGetValue(bench.Path, out var failure)) root.Children.Add(Banner(failure.Message));
        else if (bench.Problem is { } problem) root.Children.Add(Banner(problem));
        if (MessageText.Length > 0) root.Children.Add(Banner(MessageText));

        var details = new StackPanel();
        details.Children.Add(Detail("Address", string.IsNullOrWhiteSpace(bench.WebUrl) ? "no site" : bench.WebUrl, bench.WebUrl));
        details.Children.Add(Detail("Site", bench.Site ?? "no site", null));
        if (bench.Sites.Count > 1)
            details.Children.Add(Detail("Sites", string.Join(", ", bench.Sites.Select(s => s.Name)), null));
        details.Children.Add(Detail("Folder", bench.Path, bench.Path));
        if (bench.LogPath is { Length: > 0 } log) details.Children.Add(Detail("Log", log, log));
        root.Children.Add(Ui.CardOf(details));

        Content = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = root, Padding = new Thickness(0, 0, 8, 0) };
    }

    private Button Add(Panel into, List<string> labels, string label, Action click, bool enabled, bool primary = false)
    {
        var button = Ui.Button(label, click, label + " " + (_bench?.Name ?? ""), primary: primary && enabled);
        button.IsEnabled = enabled;
        into.Children.Add(button);
        labels.Add(label);
        return button;
    }

    private UIElement Detail(string label, string value, string? copy)
    {
        var grid = new Grid { Margin = new Thickness(0, 3, 0, 3) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(90) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var l = Ui.Text(label, 13, opacity: 0.7);
        var v = Ui.Text(value, 14);
        v.IsHitTestVisible = true;
        Grid.SetColumn(v, 1);
        grid.Children.Add(l);
        grid.Children.Add(v);
        if (copy is not null)
        {
            var button = Ui.Button("Copy", () => _actions.CopyText(copy), "Copy " + label, minWidth: 56);
            button.Margin = new Thickness(8, 0, 0, 0);
            button.Padding = new Thickness(8, 2, 8, 2);
            Grid.SetColumn(button, 2);
            grid.Children.Add(button);
        }
        return grid;
    }

    private static UIElement Banner(string text) => Ui.CardOf(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, Foreground = Ui.CriticalBrush });

    private async Task RunAsync(BenchStatus bench, Func<BenchStatus, Task<ActionResult>> action)
    {
        _busy.Add(bench.Path);
        _failures.Remove(bench.Path);
        Refresh();
        ActionResult result;
        try
        {
            result = await action(bench);
        }
        catch (SourceProblemException ex)
        {
            result = ActionResult.Failure(ex.Message);
        }
        _busy.Remove(bench.Path);
        if (!result.Ok) _failures[bench.Path] = (result.Message ?? "It did not work.", bench.State);
        Refresh();
    }

    private void OpenEditor(BenchStatus bench)
    {
        MessageText = _actions.OpenEditor(bench) switch
        {
            VsCodeOutcome.NotFound => VsCode.InstallMessage.Replace("VS Code", _actions.EditorName()),
            VsCodeOutcome.BadPath => VsCode.BadPathMessage(bench.Path),
            _ => "",
        };
        Refresh();
    }

    private void Refresh()
    {
        if (_bench is { } bench) Bind(bench, _site);
    }
}
