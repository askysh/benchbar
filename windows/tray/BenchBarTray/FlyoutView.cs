using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>What the flyout's buttons do. Every member has a harmless default, so the view works alone in tests.</summary>
internal sealed class FlyoutActions
{
    public Func<BenchStatus, Task<ActionResult>> StartStop { get; set; } = _ => Task.FromResult(ActionResult.Success);
    public Func<BenchStatus, Task<ActionResult>> Restart { get; set; } = _ => Task.FromResult(ActionResult.Success);
    public Action<BenchStatus> OpenSite { get; set; } = _ => { };
    public Action<BenchStatus> ShowLogs { get; set; } = _ => { };
    public Action<BenchStatus> ShowDoctor { get; set; } = _ => { };
    public Action<BenchStatus> CopyPath { get; set; } = _ => { };

    /// <summary>Opens the bench in VS Code, or says why it did not.</summary>
    public Func<BenchStatus, VsCodeOutcome> OpenVsCode { get; set; } = _ => VsCodeOutcome.Launched;

    public Func<bool> VsCodeAvailable { get; set; } = () => true;
    public Action StartDistro { get; set; } = () => { };
    public Action<string> CopyText { get; set; } = _ => { };
    public Action<string> OpenUrl { get; set; } = _ => { };
}

/// <summary>What the flyout shows now.</summary>
internal enum FlyoutMode { Empty, Benches, DistroStopped, Problem }

/// <summary>One bench in the flyout: the row itself is the keyboard stop, its buttons come after it in Tab order.</summary>
internal sealed class BenchRow : Border
{
    public BenchRow(BenchStatus bench) => Bench = bench;

    public BenchStatus Bench { get; }
    public string NameText { get; set; } = "";
    public string StateText { get; set; } = "";
    public string SiteText { get; set; } = "";
    public Button ActionButton { get; set; } = new();
    public List<Button> Buttons { get; } = [];
    public string? FailureText { get; set; }

    /// <summary>The labels of every button in the row, in Tab order.</summary>
    public IReadOnlyList<string> ButtonLabels => Buttons.Select(b => b.Content?.ToString() ?? "").ToList();
}

/// <summary>
/// The flyout's content: a header, then one of: a row per bench, the "distro is stopped" card, or the
/// problem card. A window hosts it (<see cref="FlyoutWindow"/>); tests build it without showing anything.
/// </summary>
internal sealed class FlyoutView : UserControl
{
    public const string DistroHint = "The tray does not start it on its own.";

    private static readonly Brush CardBrush = Frozen(new SolidColorBrush(Color.FromArgb(0x1A, 0x80, 0x80, 0x80)));
    private static readonly Brush FocusBrush = Frozen(new SolidColorBrush(Color.FromArgb(0x26, 0x80, 0x80, 0x80)));
    private static readonly Brush ErrorBrush = Frozen(new SolidColorBrush(Color.FromRgb(0xE5, 0x48, 0x4D)));

    private readonly FlyoutActions _actions;
    private readonly TextBlock _upText = new() { Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel _body = new();
    private readonly StackPanel _message = new() { Visibility = Visibility.Collapsed, Margin = new Thickness(16, 0, 16, 8) };
    private readonly HashSet<string> _busy = [];
    private readonly Dictionary<string, (string Message, BenchState State, string? Reason)> _failures = [];
    private readonly List<BenchRow> _rows = [];
    private TraySnapshot _snapshot = TraySnapshot.Empty;
    private string _key = "";
    private bool _distroStarting;
    private Button? _cardButton;

    /// <summary>The button of the distro or problem card (Start or Copy).</summary>
    public Button? CardButton => _cardButton;

    public FlyoutView(FlyoutActions actions)
    {
        _actions = actions;
        var title = new TextBlock { Text = "BenchBar", FontSize = 16, FontWeight = FontWeights.SemiBold };
        var header = new DockPanel { Margin = new Thickness(16, 14, 16, 8), LastChildFill = false };
        DockPanel.SetDock(_upText, Dock.Right);
        header.Children.Add(title);
        header.Children.Add(_upText);

        var root = new DockPanel();
        DockPanel.SetDock(header, Dock.Top);
        DockPanel.SetDock(_message, Dock.Top);
        root.Children.Add(header);
        root.Children.Add(_message);
        root.Children.Add(new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = _body,
            Margin = new Thickness(8, 0, 8, 10),
        });
        Content = root;
        PreviewKeyDown += OnPreviewKeyDown;
    }

    public FlyoutMode Mode { get; private set; } = FlyoutMode.Empty;

    public string UpText => _upText.Text;

    /// <summary>The title of the distro or problem card.</summary>
    public string CardTitle { get; private set; } = "";

    /// <summary>The second line of the card (the hint under "is stopped").</summary>
    public string CardHint { get; private set; } = "";

    public IReadOnlyList<string> CardButtons { get; private set; } = [];

    public IReadOnlyList<BenchRow> Rows => _rows;

    /// <summary>The text of the VS Code message strip; empty when it is hidden.</summary>
    public string MessageText { get; private set; } = "";

    public void SetSnapshot(TraySnapshot snapshot, string upText)
    {
        _upText.Text = upText;
        DropStaleFailures(snapshot);
        var key = KeyOf(snapshot);
        _snapshot = snapshot;
        if (key == _key) return;
        _key = key;
        Rebuild();
    }

    public void ShowVsCodeMissing() => ShowMessage(VsCode.InstallMessage, "Learn more", VsCode.HelpUrl);

    public void ShowVsCodeBadPath(string benchPath) => ShowMessage(VsCode.BadPathMessage(benchPath), null, null);

    public void ClearMessage()
    {
        MessageText = "";
        _message.Children.Clear();
        _message.Visibility = Visibility.Collapsed;
    }

    /// <summary>Puts the keyboard on the first row, or the first button of a card.</summary>
    public void FocusFirst()
    {
        if (_rows.Count > 0) _rows[0].Focus();
        else _cardButton?.Focus();
    }

    // --- building ---

    private void DropStaleFailures(TraySnapshot snapshot)
    {
        foreach (var path in _failures.Keys.ToList())
        {
            var bench = snapshot.Benches.FirstOrDefault(b => b.Path == path);
            var f = _failures[path];
            if (bench is null || bench.State != f.State || bench.StopReason != f.Reason) _failures.Remove(path);
        }
        if (!snapshot.DistroStopped) _distroStarting = false;
    }

    private string KeyOf(TraySnapshot s) => string.Join('\n',
        s.DistroStopped ? $"stopped|{s.Distro}|{_distroStarting}" : "up",
        s.Problem ?? "",
        string.Join('\n', s.Benches.Select(b =>
            $"{b.Path}|{b.Name}|{b.State}|{b.RawState}|{b.StopReason}|{b.Site}|{b.WebUrl}|{_busy.Contains(b.Path)}|{(_failures.TryGetValue(b.Path, out var f) ? f.Message : "")}|{b.Problem}")));

    private void Rebuild()
    {
        var focusedPath = _rows.FirstOrDefault(r => r.IsKeyboardFocusWithin)?.Bench.Path;
        _body.Children.Clear();
        _rows.Clear();
        _cardButton = null;
        CardTitle = CardHint = "";
        CardButtons = [];

        if (_snapshot.Problem is { } problem)
        {
            Mode = FlyoutMode.Problem;
            _body.Children.Add(ProblemCard(problem));
        }
        else if (_snapshot.DistroStopped)
        {
            Mode = FlyoutMode.DistroStopped;
            _body.Children.Add(DistroCard(_snapshot.Distro ?? "The WSL distro"));
        }
        else if (_snapshot.Benches.Count == 0)
        {
            Mode = FlyoutMode.Empty;
            _body.Children.Add(new TextBlock { Text = "No benches found.", Opacity = 0.7, Margin = new Thickness(12, 8, 12, 8) });
        }
        else
        {
            Mode = FlyoutMode.Benches;
            foreach (var bench in _snapshot.Benches)
            {
                var row = BuildRow(bench);
                _rows.Add(row);
                _body.Children.Add(row);
            }
            if (focusedPath is not null) _rows.FirstOrDefault(r => r.Bench.Path == focusedPath)?.Focus();
        }
    }

    private Border Card(UIElement content) => new()
    {
        Background = CardBrush,
        CornerRadius = new CornerRadius(6),
        Padding = new Thickness(12),
        Margin = new Thickness(0, 0, 0, 4),
        Child = content,
    };

    private Border DistroCard(string distro)
    {
        var button = new Button { Content = "Start", MinWidth = 64, IsEnabled = !_distroStarting, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 10, 0, 0) };
        button.Click += (_, _) =>
        {
            _distroStarting = true;
            _actions.StartDistro();
            _key = "";
            SetSnapshot(_snapshot, _upText.Text);
        };
        _cardButton = button;
        CardTitle = $"{distro} is stopped";
        CardHint = DistroHint;
        CardButtons = ["Start"];
        var panel = new StackPanel();
        panel.Children.Add(new TextBlock { Text = CardTitle, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(new TextBlock { Text = CardHint, Opacity = 0.7, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) });
        panel.Children.Add(button);
        return Card(panel);
    }

    private Border ProblemCard(string problem)
    {
        var copy = new Button { Content = "Copy", MinWidth = 64, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 10, 0, 0) };
        copy.Click += (_, _) => _actions.CopyText(problem);
        _cardButton = copy;
        CardTitle = problem;
        CardButtons = ["Copy"];
        var panel = new StackPanel();
        panel.Children.Add(new TextBlock { Text = problem, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(copy);
        return Card(panel);
    }

    private BenchRow BuildRow(BenchStatus bench)
    {
        var row = new BenchRow(bench)
        {
            Focusable = true,
            Margin = new Thickness(0, 0, 0, 2),
            Padding = new Thickness(8, 6, 8, 6),
            CornerRadius = new CornerRadius(6),
            Background = Brushes.Transparent,
            NameText = bench.Name,
            StateText = BenchPresentation.StateWord(bench),
            SiteText = DefaultSite(bench),
        };
        row.GotKeyboardFocus += (_, e) => { if (e.OriginalSource == row) row.Background = FocusBrush; };
        row.LostKeyboardFocus += (_, _) => row.Background = Brushes.Transparent;
        row.FocusVisualStyle = null;
        AutomationProperties(row, $"{bench.Name}, {row.StateText}");

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var dot = StateDot(bench);
        Grid.SetColumn(dot, 0);

        var names = new StackPanel { Margin = new Thickness(10, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        names.Children.Add(new TextBlock { Text = row.NameText, TextTrimming = TextTrimming.CharacterEllipsis });
        names.Children.Add(new TextBlock { Text = row.SiteText, FontSize = 11, Opacity = 0.65, TextTrimming = TextTrimming.CharacterEllipsis });
        Grid.SetColumn(names, 1);

        var word = new TextBlock { Text = row.StateText, Opacity = 0.7, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(word, 2);

        var running = bench.State is BenchState.Running or BenchState.Starting;
        var action = new Button
        {
            Content = running ? "Stop" : "Start",
            MinWidth = 64,
            IsEnabled = !_busy.Contains(bench.Path) && bench.State != BenchState.Unknown,
        };
        action.Click += async (_, _) => await RunAsync(bench, _actions.StartStop);
        Grid.SetColumn(action, 3);
        row.ActionButton = action;

        var more = new Button { Content = "⋯", Margin = new Thickness(4, 0, 0, 0), MinWidth = 32, ToolTip = "More" };
        AutomationProperties(more, "More actions");
        more.Click += (_, _) => OpenMoreMenu(more, bench);
        Grid.SetColumn(more, 4);

        grid.Children.Add(dot);
        grid.Children.Add(names);
        grid.Children.Add(word);
        grid.Children.Add(action);
        grid.Children.Add(more);

        var strip = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(18, 2, 0, 0) };
        var site = TextButton("Open site", () => _actions.OpenSite(bench), enabled: !string.IsNullOrWhiteSpace(bench.WebUrl));
        var logs = TextButton("Logs", () => _actions.ShowLogs(bench));
        var code = TextButton("VS Code", () => {
            switch (_actions.OpenVsCode(bench))
            {
                case VsCodeOutcome.NotFound: ShowVsCodeMissing(); break;
                case VsCodeOutcome.BadPath: ShowVsCodeBadPath(bench.Path); break;
            }
        });
        code.ToolTip = _actions.VsCodeAvailable() ? "Open the bench in VS Code" : VsCode.InstallMessage;
        var doctor = TextButton("Doctor", () => _actions.ShowDoctor(bench));
        foreach (var b in new[] { site, logs, code, doctor }) strip.Children.Add(b);

        row.Buttons.AddRange([action, more, site, logs, code, doctor]);

        var stack = new StackPanel();
        stack.Children.Add(grid);
        stack.Children.Add(strip);
        // an action's failure line wins; else the line of a bench whose status call failed
        var line = _failures.TryGetValue(bench.Path, out var failure) ? failure.Message : bench.Problem;
        if (line is not null)
        {
            row.FailureText = line;
            stack.Children.Add(new TextBlock
            {
                Text = line,
                Foreground = ErrorBrush,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(18, 4, 0, 0),
            });
        }
        row.Child = stack;
        return row;
    }

    private async Task RunAsync(BenchStatus bench, Func<BenchStatus, Task<ActionResult>> action)
    {
        _busy.Add(bench.Path);
        _failures.Remove(bench.Path);
        Refresh();
        ActionResult result;
        try { result = await action(bench); }
        catch (Exception ex) { result = ActionResult.Failure(ex.Message); }
        _busy.Remove(bench.Path);
        // the line stays under the row until the bench changes state
        if (!result.Ok) _failures[bench.Path] = (result.Message ?? "The command failed.", bench.State, bench.StopReason);
        Refresh();
    }

    private void Refresh()
    {
        _key = "";
        SetSnapshot(_snapshot, _upText.Text);
    }

    private void OpenMoreMenu(Button anchor, BenchStatus bench)
    {
        var menu = new ContextMenu { PlacementTarget = anchor, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
        var restart = new MenuItem { Header = "Restart", IsEnabled = bench.State != BenchState.Unknown };
        restart.Click += async (_, _) => await RunAsync(bench, _actions.Restart);
        var copy = new MenuItem { Header = "Copy path" };
        copy.Click += (_, _) => _actions.CopyPath(bench);
        menu.Items.Add(restart);
        menu.Items.Add(copy);
        menu.IsOpen = true;
    }

    // --- keyboard ---

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (_rows.Count == 0 || e.OriginalSource is TextBox) return;
        switch (e.Key)
        {
            case Key.Down: MoveFocus(+1); e.Handled = true; break;
            case Key.Up: MoveFocus(-1); e.Handled = true; break;
            case Key.Enter when e.OriginalSource is BenchRow row:
                _actions.OpenSite(row.Bench);
                e.Handled = true;
                break;
        }
    }

    private void MoveFocus(int delta)
    {
        var current = _rows.FindIndex(r => r.IsKeyboardFocusWithin);
        var next = current < 0 ? (delta > 0 ? 0 : _rows.Count - 1) : Math.Clamp(current + delta, 0, _rows.Count - 1);
        _rows[next].Focus();
    }

    // --- small pieces ---

    private static string DefaultSite(BenchStatus bench)
    {
        if (bench.Sites.FirstOrDefault(s => s.IsDefault) is { } def) return def.Name;
        return string.IsNullOrWhiteSpace(bench.Site) ? "no site" : bench.Site;
    }

    private void ShowMessage(string text, string? linkText, string? url)
    {
        MessageText = text;
        _message.Children.Clear();
        var block = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12 };
        block.Inlines.Add(new Run(linkText is null ? text : text + " "));
        if (linkText is not null && url is not null)
        {
            var link = new Hyperlink(new Run(linkText)) { NavigateUri = new Uri(url) };
            link.RequestNavigate += (_, e) =>
            {
                e.Handled = true;
                _actions.OpenUrl(e.Uri.AbsoluteUri);
            };
            block.Inlines.Add(link);
        }
        _message.Children.Add(block);
        _message.Visibility = Visibility.Visible;
    }

    private static Button TextButton(string label, Action click, bool enabled = true)
    {
        var button = new Button
        {
            Content = label,
            FontSize = 12,
            Padding = new Thickness(6, 2, 6, 2),
            Margin = new Thickness(0, 0, 4, 0),
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            IsEnabled = enabled,
        };
        button.Click += (_, _) => click();
        return button;
    }

    private static void AutomationProperties(DependencyObject element, string name) =>
        System.Windows.Automation.AutomationProperties.SetName(element, name);

    private static Ellipse StateDot(BenchStatus bench)
    {
        var dot = new Ellipse { Width = 10, Height = 10, VerticalAlignment = VerticalAlignment.Center };
        Color? color = bench.State switch
        {
            BenchState.Running => Color.FromRgb(0x2E, 0xB8, 0x5C),
            BenchState.Starting => Color.FromRgb(0xF2, 0xA9, 0x00),
            BenchState.Crashed or BenchState.Paused => Color.FromRgb(0xE5, 0x48, 0x4D),
            BenchState.Stopped => Color.FromRgb(0x8A, 0x8A, 0x8A),
            _ => null,
        };
        if (color is { } c) dot.Fill = new SolidColorBrush(c);
        else
        {
            // unknown: hollow
            dot.Stroke = new SolidColorBrush(Color.FromRgb(0x8A, 0x8A, 0x8A));
            dot.StrokeThickness = 1.5;
        }
        return dot;
    }

    private static Brush Frozen(SolidColorBrush brush)
    {
        brush.Freeze();
        return brush;
    }
}
