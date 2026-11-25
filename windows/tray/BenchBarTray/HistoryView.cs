using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// History (macos HistoryPane): every run that changed something on this machine, newest first, from <c>benchbar.exe history --json</c>: what ran,
/// who started it (BenchBar, Terminal, an agent through MCP, a script), how it ended and what it changed. It is the CLI's own record and
/// read only: nothing here runs anything again. Read when the pane is shown and on Refresh, never on a timer. A CLI without <c>history</c>
/// gets one line saying so.
/// </summary>
internal sealed class HistoryView : UserControl
{
    private readonly PageServices _services;
    private readonly StackPanel _body = new();
    private readonly Button _refresh;
    private bool _loading;
    private string? _problem;
    private bool _unsupported;

    public HistoryView(PageServices services)
    {
        _services = services;
        var root = new StackPanel { MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Left };
        var head = new DockPanel();
        _refresh = Ui.Button(UiText.Get("HistoryRefresh"), () => Load().Forget(), UiText.Get("HistoryRefreshName"), minWidth: 0);
        DockPanel.SetDock(_refresh, Dock.Right);
        head.Children.Add(_refresh);
        head.Children.Add(Ui.Title(UiText.Get("HistoryTitle")));
        root.Children.Add(head);
        root.Children.Add(Ui.Text(UiText.Get("HistoryIntro"), 14, opacity: 0.75, margin: new Thickness(0, 6, 0, 12)));
        root.Children.Add(_body);
        Content = new ScrollViewer { Content = root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(0, 0, 12, 0) };
        Ui.Name(this, UiText.Get("HistoryTitle"));
        Render();
    }

    /// <summary>The entries shown, newest first.</summary>
    public IReadOnlyList<HistoryEntry> Entries { get; private set; } = [];

    /// <summary>Every line of text shown, in order (for tests).</summary>
    public IReadOnlyList<string> Lines { get; private set; } = [];

    /// <summary>Now, for the age of an entry. Tests set it.</summary>
    public Func<DateTimeOffset> Clock { get; set; } = () => DateTimeOffset.UtcNow;

    public bool IsLoading => _loading;

    /// <summary>Called each time the pane is selected in the sidebar: one read.</summary>
    public void OnShown() => Load().Forget();

    /// <summary>Reads the history. Public so a test can await it.</summary>
    public async Task Load()
    {
        if (_loading) return;
        _loading = true;
        _refresh.IsEnabled = false;
        Render();
        try
        {
            var catalogue = await _services.Commands.GetAsync().ConfigureAwait(true);
            _unsupported = catalogue is not null && !catalogue.Has("history");
            if (_unsupported)
            {
                Entries = [];
                _problem = null;
                return;
            }
            var r = await _services.Cli.RunJsonAsync(HistoryJson.Args(), null, CliTimeouts.Read, HistoryJson.Parse).ConfigureAwait(true);
            if (r.Value is { } entries)
            {
                Entries = entries;
                _problem = null;
            }
            else
            {
                _problem = r.Error ?? UiText.Get("HistoryNotRead");
            }
        }
        finally
        {
            _loading = false;
            _refresh.IsEnabled = true;
            Render();
        }
    }

    private void Render()
    {
        _body.Children.Clear();
        var lines = new List<string>();
        void Line(string text, double size = 13, double opacity = 1, System.Windows.Media.Brush? brush = null)
        {
            var block = Ui.Text(text, size, null, opacity, new Thickness(0, 2, 0, 0));
            if (brush is not null) block.Foreground = brush;
            _body.Children.Add(block);
            lines.Add(text);
        }
        if (_unsupported) Line(UiText.Get("HistoryUnsupported"), 14, 0.8);
        if (_problem is { } problem) Line(UiText.Format("HistoryNotReadLine", problem), 13, brush: Ui.CriticalBrush);
        if (_loading && Entries.Count == 0) Line(UiText.Get("HistoryReading"), 14, 0.8);
        else if (!_unsupported && _problem is null && Entries.Count == 0) Line(UiText.Get("HistoryNothing"), 14, 0.8);
        var now = Clock();
        foreach (var entry in Entries) _body.Children.Add(Row(entry, now, lines));
        Lines = lines;
    }

    private UIElement Row(HistoryEntry entry, DateTimeOffset now, List<string> lines)
    {
        var ok = entry.Exit == 0;
        var grid = new Grid { Margin = new Thickness(0, 0, 0, 2) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var glyph = Ui.Glyph(ok ? Ui.CheckGlyph : Ui.ErrorGlyph, 16, Ui.StatusBrush(ok ? SetupStatus.Ok : SetupStatus.Fail), HistoryText.Result(entry));
        glyph.Margin = new Thickness(0, 2, 10, 0);
        grid.Children.Add(glyph);
        var text = new StackPanel();
        var title = HistoryText.Title(entry);
        var who = UiText.Format("HistoryWho", HistoryText.Who(entry), HistoryText.Result(entry));
        text.Children.Add(Ui.Text(title, 14, FontWeights.SemiBold));
        text.Children.Add(Ui.Text(who, 12, opacity: 0.75));
        lines.Add(title);
        lines.Add(who);
        if (HistoryText.Changes(entry) is { } changes)
        {
            text.Children.Add(Ui.Text(changes, 12, opacity: 0.75));
            lines.Add(changes);
        }
        if (HistoryText.BenchName(entry) is { } bench)
        {
            text.Children.Add(Ui.Text(bench, 11, opacity: 0.6));
            lines.Add(bench);
        }
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        var side = new StackPanel { HorizontalAlignment = HorizontalAlignment.Right };
        if (entry.StartedAt is { } started)
        {
            var when = ActivityText.Age(started, now);
            side.Children.Add(Ui.Text(when, 12, opacity: 0.75, margin: new Thickness(8, 2, 0, 0)));
            lines.Add(when);
        }
        if (entry.Log is { Length: > 0 } log)
        {
            var copy = Ui.Link(UiText.Get("HistoryCopyLog"), () => _services.CopyText(log), UiText.Format("HistoryCopyLogName", title));
            copy.Margin = new Thickness(8, 2, 0, 0);
            side.Children.Add(copy);
        }
        Grid.SetColumn(side, 2);
        grid.Children.Add(side);
        return Ui.CardOf(grid, new Thickness(0, 0, 0, 4));
    }
}
