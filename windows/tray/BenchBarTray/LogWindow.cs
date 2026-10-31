using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>One line in the list, with the brushes it is drawn in.</summary>
internal sealed class LogRow(LogLine line, Brush background)
{
    public int Id { get; } = line.Id;

    public string Text { get; } = line.Text;

    public bool IsError { get; } = line.IsError;

    public Brush Background { get; } = background;
}

/// <summary>
/// The log viewer of one bench (macos LogView): a process filter, a search with next and previous, a Previous log toggle, Follow, Clear
/// view, Copy and Open in Terminal. It reads through <c>logs --json</c>, never through <c>\\wsl$</c>. Follow polls every 2 seconds only
/// while this window is open and Follow is on; closing the window stops it. There is one window per bench (the app keeps them).
/// It only draws <see cref="LogViewModel"/>.
/// </summary>
internal sealed class LogWindow : ToolWindow
{
    private static readonly Brush Plain = Brushes.Transparent;
    private static readonly Brush MatchBack = Freeze(Color.FromArgb(0x55, 0xFF, 0xD2, 0x3F));
    private static readonly Brush CurrentBack = Freeze(Color.FromArgb(0x88, 0xFF, 0x8C, 0x00));

    private readonly PageServices _services;
    private readonly BenchStatus _bench;
    private readonly ObservableCollection<LogRow> _rows = [];
    private readonly ListBox _list = new()
    {
        FontFamily = new FontFamily("Cascadia Mono, Consolas"),
        FontSize = 12,
        SelectionMode = SelectionMode.Extended,
        BorderThickness = new Thickness(0),
    };
    private readonly ComboBox _process = new() { Width = 150, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBox _search = new() { MinWidth = 140, Padding = new Thickness(6, 3, 6, 3), VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _searchSummary = new() { Opacity = 0.7, Margin = new Thickness(8, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center, MinWidth = 60 };
    private readonly CheckBox _previous = new() { Content = "Previous log", Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly CheckBox _follow = new() { Content = "Follow", Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _status = new() { Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    private int _drawnChanges = -1;
    private int _drawnThrough = -1;
    private bool _syncing;
    private bool _scrolling;
    private bool _started;
    private string? _notice;

    public LogWindow(PageServices services, BenchStatus bench, ResolvedTheme theme, LogViewModel? model = null)
        : base($"{bench.Name} log", 780, 460, theme)
    {
        _services = services;
        _bench = bench;
        Model = model ?? new LogViewModel(services.Cli, bench.Path, bench.Name) { DistroProbe = new WslDistroProbe(), Distro = services.Distro };
        MinWidth = 620;
        MinHeight = 320;
        Ui.Name(this, $"{bench.Name} log");

        _process.Items.Add("All processes");
        foreach (var process in LogQuery.Processes) _process.Items.Add(process);
        _process.SelectedIndex = 0;
        _process.SelectionChanged += (_, _) =>
        {
            if (_syncing) return;
            Model.SetProcess(_process.SelectedIndex <= 0 ? null : (string)_process.SelectedItem);
        };
        Ui.Name(_process, "Process filter");
        Ui.Name(_search, "Search the log");
        _search.TextChanged += (_, _) =>
        {
            if (!_syncing) Model.SetSearch(_search.Text);
        };
        _search.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            e.Handled = true;
            Model.Step(forward: !Keyboard.Modifiers.HasFlag(ModifierKeys.Shift));
        };
        Ui.Name(_searchSummary, "Search result");
        Ui.Name(_previous, "Previous log", "logs/bench.previous.log: the end of the log before the last start");
        Ui.Name(_follow, "Follow", "Stick to the newest line; scrolling up turns it off");
        _previous.Checked += (_, _) => OnPrevious(true);
        _previous.Unchecked += (_, _) => OnPrevious(false);
        _follow.IsChecked = true;
        _follow.Checked += (_, _) => OnFollow(true);
        _follow.Unchecked += (_, _) => OnFollow(false);

        var bar = new DockPanel { Margin = new Thickness(10, 8, 10, 8), LastChildFill = false };
        var left = new StackPanel { Orientation = Orientation.Horizontal };
        left.Children.Add(_process);
        _search.Margin = new Thickness(8, 0, 0, 0);
        left.Children.Add(_search);
        left.Children.Add(_searchSummary);
        PreviousMatch = Ui.Button("Previous", () => Model.Step(forward: false), "Previous match", minWidth: 0);
        NextMatch = Ui.Button("Next", () => Model.Step(forward: true), "Next match", minWidth: 0);
        PreviousMatch.Margin = new Thickness(0, 0, 4, 0);
        PreviousMatch.Padding = NextMatch.Padding = new Thickness(8, 2, 8, 2);
        left.Children.Add(PreviousMatch);
        left.Children.Add(NextMatch);
        DockPanel.SetDock(left, Dock.Left);
        bar.Children.Add(left);
        var right = new StackPanel { Orientation = Orientation.Horizontal };
        right.Children.Add(_previous);
        right.Children.Add(_follow);
        ClearButton = Ui.Button("Clear", () => Model.Clear(), "Clear view", minWidth: 0);
        CopyButton = Ui.Button("Copy", CopyAll, "Copy the visible lines", minWidth: 0);
        TerminalButton = Ui.Button("Open in Terminal", OpenInTerminal, "Open in Terminal", minWidth: 0);
        foreach (var b in new[] { ClearButton, CopyButton, TerminalButton })
        {
            b.Margin = new Thickness(8, 0, 0, 0);
            b.Padding = new Thickness(10, 2, 10, 2);
            right.Children.Add(b);
        }
        ClearButton.ToolTip = "Empty the view; the file is not touched";
        DockPanel.SetDock(right, Dock.Right);
        bar.Children.Add(right);

        _list.ItemsSource = _rows;
        var text = new FrameworkElementFactory(typeof(TextBlock));
        text.SetBinding(TextBlock.TextProperty, new Binding(nameof(LogRow.Text)));
        text.Name = "text";
        text.SetBinding(TextBlock.BackgroundProperty, new Binding(nameof(LogRow.Background)));
        text.SetValue(FrameworkElement.MarginProperty, new Thickness(6, 0, 6, 0));
        var template = new DataTemplate { VisualTree = text };
        var error = new DataTrigger { Binding = new Binding(nameof(LogRow.IsError)), Value = true };
        error.Setters.Add(new Setter(TextBlock.ForegroundProperty, Ui.CriticalBrush, "text"));
        template.Triggers.Add(error);
        _list.ItemTemplate = template;
        _list.AddHandler(ScrollViewer.ScrollChangedEvent, new ScrollChangedEventHandler(OnScrolled));
        _list.KeyDown += (_, e) =>
        {
            if (e.Key != Key.C || !Keyboard.Modifiers.HasFlag(ModifierKeys.Control) || _list.SelectedItems.Count == 0) return;
            e.Handled = true;
            _services.CopyText(string.Join(Environment.NewLine, _list.SelectedItems.OfType<LogRow>().Select(r => r.Text)));
        };
        VirtualizingPanel.SetIsVirtualizing(_list, true);
        VirtualizingPanel.SetVirtualizationMode(_list, VirtualizationMode.Recycling);
        ScrollViewer.SetHorizontalScrollBarVisibility(_list, ScrollBarVisibility.Auto);
        Ui.Name(_list, "Log lines");

        var statusBar = new DockPanel { Margin = new Thickness(10, 6, 10, 6) };
        statusBar.Children.Add(_status);
        var root = new DockPanel();
        DockPanel.SetDock(bar, Dock.Top);
        DockPanel.SetDock(statusBar, Dock.Bottom);
        root.Children.Add(bar);
        root.Children.Add(statusBar);
        root.Children.Add(_list);
        Content = root;

        Model.Changed += OnModelChanged;
        Closed += (_, _) =>
        {
            Model.Changed -= OnModelChanged;
            Model.Dispose();
        };
        Loaded += (_, _) => StartAsync().Forget();
        Sync();
    }

    public LogViewModel Model { get; }

    public IReadOnlyList<LogRow> Rows => _rows;

    public Button PreviousMatch { get; }

    public Button NextMatch { get; }

    public Button ClearButton { get; }

    public Button CopyButton { get; }

    public Button TerminalButton { get; }

    public ComboBox ProcessPicker => _process;

    public TextBox SearchBox => _search;

    public CheckBox PreviousToggle => _previous;

    public CheckBox FollowToggle => _follow;

    /// <summary>The status line under the list (for tests).</summary>
    public string StatusText => _status.Text;

    /// <summary>Reads the log, then lets Follow poll. Called once when the window loads (a test calls it without showing the window).</summary>
    public async Task StartAsync()
    {
        if (_started) return;
        _started = true;
        await Model.LoadAsync().ConfigureAwait(true);
        Model.Start();
        OnModelChanged();
    }

    /// <summary>The window is asked for again: bring it forward.</summary>
    public void Reopen()
    {
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
    }

    private void OnPrevious(bool on)
    {
        if (_syncing) return;
        Model.ShowPrevious = on;
    }

    private void OnFollow(bool on)
    {
        if (_syncing) return;
        Model.Follow = on;
    }

    private void OnScrolled(object sender, ScrollChangedEventArgs e)
    {
        // the person scrolled (not the list growing): at the bottom follows, higher up stops following
        if (_scrolling || e.VerticalChange == 0 || e.ExtentHeightChange != 0) return;
        var atBottom = e.VerticalOffset + e.ViewportHeight >= e.ExtentHeight - 1;
        if (Model.Follow != atBottom) Model.Follow = atBottom;
    }

    private void OnModelChanged()
    {
        if (Dispatcher.CheckAccess()) Sync();
        else Dispatcher.BeginInvoke(Sync);
    }

    /// <summary>Draws the window from the model as it is now.</summary>
    public void Sync()
    {
        _syncing = true;
        try
        {
            if (_follow.IsChecked != Model.Follow) _follow.IsChecked = Model.Follow;
            if (_previous.IsChecked != Model.ShowPrevious) _previous.IsChecked = Model.ShowPrevious;
            var query = Model.Query;
            var want = query.Process is null ? 0 : _process.Items.IndexOf(query.Process);
            if (_process.SelectedIndex != want) _process.SelectedIndex = want;
            DrawRows(query);
        }
        finally
        {
            _syncing = false;
        }
        _searchSummary.Text = Model.SearchSummary;
        _status.Text = StatusLine();
        if (_rows.Count == 0) return;
        _scrolling = true;
        try
        {
            if (Model.CurrentMatchId is { } id && _rows.FirstOrDefault(r => r.Id == id) is { } match) _list.ScrollIntoView(match);
            else if (Model.Follow) _list.ScrollIntoView(_rows[^1]);
        }
        finally
        {
            _scrolling = false;
        }
    }

    private void DrawRows(LogQuery query)
    {
        if (Model.Changes != _drawnChanges)
        {
            var visible = Model.Visible();
            var matches = query.Matches(visible).ToHashSet();
            var current = Model.CurrentMatchId;
            _rows.Clear();
            foreach (var line in visible) _rows.Add(Row(line, matches, current));
            _drawnChanges = Model.Changes;
        }
        else
        {
            // lines the buffer dropped from its top leave the list too, while the end is followed (a scrolled list keeps its place)
            var first = Model.FirstId;
            while (Model.Follow && _rows.Count > 0 && _rows[0].Id < first) _rows.RemoveAt(0);
            var added = Model.VisibleAfter(_drawnThrough);
            var matches = query.Matches(added).ToHashSet();
            foreach (var line in added) _rows.Add(Row(line, matches, null));
        }
        _drawnThrough = Model.LastId;
    }

    private static LogRow Row(LogLine line, HashSet<int> matches, int? current) => new(line,
        current == line.Id ? CurrentBack : matches.Contains(line.Id) ? MatchBack : Plain);

    private string StatusLine()
    {
        if (_notice is not null) return _notice;
        if (Model.Error is { Length: > 0 } error) return error;
        if (Model.IsLoading) return "Loading...";
        var count = Model.LineCount;
        return $"{count} {(count == 1 ? "line" : "lines")} from {Model.File ?? "the bench log"}{(Model.Follow ? ", following" : "")}";
    }

    private void CopyAll()
    {
        _services.CopyText(Model.VisibleText());
    }

    private void OpenInTerminal()
    {
        var distro = _services.Distro();
        _notice = distro is null
            ? WslCommands.NoDistroMessage
            : _services.OpenTerminal(new TerminalLaunch(distro, _bench.Path, WslCommands.TailLog(Model.ShowPrevious)));
        _status.Text = StatusLine();
    }

    private static Brush Freeze(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }
}
