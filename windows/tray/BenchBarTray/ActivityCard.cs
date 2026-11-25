using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// The Overview's live part: who holds a lease on the bench or a site, the resource charts (CPU, memory, processes and the runner speed of
/// <c>benchbar.exe stats --json</c>) and the background operations that run on the bench (<c>op list</c>). Each part shows only when the CLI
/// lists its command and there is something to show. The timer runs only while the card is on screen and a bench is bound, and a round
/// never starts while the last one is still going, so a hidden or minimised page costs nothing. BenchBar never takes, renews or releases a
/// lease: an agent holds it, and a change it refuses shows the holder (the Break Lease button of that change is the person's own choice).
/// </summary>
internal sealed class ActivityCard : UserControl
{
    private const int LeaseEvery = 3; // the leases are asked every third round, the charts every round

    private readonly ActivityModel _model;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(5) };
    private readonly StackPanel _body = new();
    private BenchStatus? _bench;
    private CommandCatalogue? _catalogue;
    private int _round;
    private int _inFlight;

    public ActivityCard(ICliClient cli)
    {
        _model = new ActivityModel(cli, () => Clock());
        Content = _body; // empty (no size) until there is something to show; it stays Visible so IsVisible can start the timer
        _model.Changed += Render;
        _timer.Tick += (_, _) => PollAsync().Forget();
        IsVisibleChanged += (_, _) => Sync();
        Loaded += (_, _) => Sync();
        Unloaded += (_, _) =>
        {
            _timer.Stop();
            Watch(null);
        };
        Ui.Name(this, UiText.Get("ActivityName"));
    }

    internal ActivityModel Model => _model;

    /// <summary>Every line of text shown, in order (for tests).</summary>
    public IReadOnlyList<string> Lines { get; private set; } = [];

    /// <summary>The chart lines drawn: the number of points of the CPU and memory charts (for tests).</summary>
    public (int Cpu, int Memory) ChartPoints { get; private set; }

    /// <summary>Now, for the age and the end of a lease. Tests set it.</summary>
    public Func<DateTimeOffset> Clock { get; set; } = () => DateTimeOffset.UtcNow;

    /// <summary>Whether the timer runs (for tests).</summary>
    public bool Polling => _timer.IsEnabled;

    public TimeSpan Interval
    {
        get => _timer.Interval;
        set => _timer.Interval = value;
    }

    /// <summary>The bench and what the CLI can do. A new bench starts a round at once; the same one only updates what it knows.</summary>
    public void Bind(BenchStatus bench, CommandCatalogue? catalogue)
    {
        var changedBench = _bench?.Path != bench.Path;
        var started = _bench?.State != bench.State;
        var catalogueArrived = _catalogue is null && catalogue is not null;
        _bench = bench;
        _catalogue = catalogue;
        Sync();
        if (changedBench || started || catalogueArrived) PollAsync(leases: true).Forget();
    }

    private Window? _window;

    /// <summary>A minimised window keeps IsVisible true, so its state is watched while the card is in it: minimise stops the timer, restore starts it.</summary>
    private void Watch(Window? window)
    {
        if (ReferenceEquals(window, _window)) return;
        if (_window is not null) _window.StateChanged -= OnWindowState;
        _window = window;
        if (_window is not null) _window.StateChanged += OnWindowState;
    }

    private void OnWindowState(object? sender, EventArgs e) => Sync();

    private void Sync()
    {
        Watch(Window.GetWindow(this));
        var on = ActivityRules.ShouldPoll(_bench is not null, _catalogue is not null, IsVisible, IsLoaded, _window?.WindowState == WindowState.Minimized);
        if (on && !_timer.IsEnabled) _timer.Start();
        else if (!on && _timer.IsEnabled) _timer.Stop();
    }

    /// <summary>One round of reads. Public so a test can await it; a round that finds the last one still going does nothing.</summary>
    public async Task PollAsync(bool? leases = null)
    {
        if (_bench is not { } bench || _catalogue is not { } catalogue) return;
        if (Interlocked.Exchange(ref _inFlight, 1) == 1) return;
        try
        {
            var due = leases ?? (_round++ % LeaseEvery == 0);
            await _model.PollAsync(bench.Path, bench.State is BenchState.Running or BenchState.Starting, catalogue, due).ConfigureAwait(true);
        }
        finally
        {
            Interlocked.Exchange(ref _inFlight, 0);
        }
    }

    private void Render()
    {
        _body.Children.Clear();
        var lines = new List<string>();
        var now = Clock();
        ChartPoints = (0, 0);
        if (!_model.HasContent)
        {
            Lines = lines;
            return;
        }
        var panel = new StackPanel();
        if (_model.Leases.Count > 0)
        {
            Heading(panel, lines, UiText.Get("ActivityLeases"));
            foreach (var lease in _model.Leases) Add(panel, lines, LeaseText.Line(lease, now), 13);
            Add(panel, lines, UiText.Get("ActivityLeaseNote"), 12, 0.7);
        }
        if (_model.Resources.Latest is { } latest)
        {
            Heading(panel, lines, UiText.Get("ActivityResources"));
            Add(panel, lines, ResourceHistory.Line(latest, _model.Resources.Speed), 13);
            ChartPoints = (Chart(panel, UiText.Get("ActivityChartCpu"), _model.Resources.Samples.Select(s => s.CpuPercent).ToList(), Math.Max(100, _model.Resources.Samples.Max(s => s.CpuPercent)),
                    UiText.Format("ActivityChartCpuDescription", _model.Resources.Samples.Count, ResourceHistory.Line(latest, _model.Resources.Speed))),
                Chart(panel, UiText.Get("ActivityChartMemory"), _model.Resources.Samples.Select(s => (double)s.MemoryBytes).ToList(), _model.Resources.Samples.Max(s => (double)s.MemoryBytes),
                    UiText.Format("ActivityChartMemoryDescription", _model.Resources.Samples.Count, ByteSize.Format(latest.MemoryBytes))));
            Add(panel, lines, UiText.Get("ActivityResourcesNote"), 12, 0.7);
        }
        if (_model.Ops.Count > 0)
        {
            Heading(panel, lines, UiText.Get("ActivityRunningNow"));
            foreach (var op in _model.Ops) Add(panel, lines, OpJson.Line(op, now), 13);
        }
        _body.Children.Add(Ui.CardOf(panel));
        Lines = lines;
    }

    private static void Heading(StackPanel panel, List<string> lines, string text)
    {
        panel.Children.Add(Ui.Text(text, 16, FontWeights.SemiBold, margin: new Thickness(0, panel.Children.Count == 0 ? 0 : 12, 0, 4)));
        lines.Add(text);
    }

    private static void Add(StackPanel panel, List<string> lines, string text, double size, double opacity = 1)
    {
        panel.Children.Add(Ui.Text(text, size, opacity: opacity, margin: new Thickness(0, 2, 0, 0)));
        lines.Add(text);
    }

    private const double ChartWidth = 300;
    private const double ChartHeight = 36;

    /// <summary>A small line chart of the last minutes: the newest sample at the right edge. Returns how many points it drew.</summary>
    private static int Chart(StackPanel panel, string name, IReadOnlyList<double> values, double max, string description)
    {
        var points = ResourceHistory.Points(values, max, ChartWidth, ChartHeight);
        var line = new Polyline { Stroke = SystemColors.HighlightBrush, StrokeThickness = 1.5, StrokeLineJoin = PenLineJoin.Round };
        foreach (var (x, y) in points) line.Points.Add(new Point(x, y));
        var canvas = new Canvas { Width = ChartWidth, Height = ChartHeight, Margin = new Thickness(0, 4, 0, 0), HorizontalAlignment = HorizontalAlignment.Left, ClipToBounds = true };
        canvas.Children.Add(new Rectangle { Width = ChartWidth, Height = ChartHeight, Fill = Ui.Card });
        canvas.Children.Add(line);
        Ui.Name(canvas, UiText.Format("ActivityChartName", name), description);
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(Ui.Text(name, 12, opacity: 0.7, margin: new Thickness(0, 6, 8, 0)));
        row.Children.Add(canvas);
        panel.Children.Add(row);
        return points.Count;
    }
}
