using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>Shared shape of the Logs and Doctor windows: Fluent theme from the resolved appearance, Esc closes, one reload at a time.</summary>
internal abstract class ToolWindow : Window
{
    private CancellationTokenSource? _load;

    protected ToolWindow(string title, double width, double height, ResolvedTheme theme)
    {
        Title = title;
        Width = width;
        Height = height;
        MinWidth = 360;
        MinHeight = 240;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ThemeMode = theme.FlyoutLight ? ThemeMode.Light : ThemeMode.Dark;
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Escape) return;
            e.Handled = true;
            Close();
        };
        Closed += (_, _) => _load?.Cancel();
    }

    /// <summary>Starts a load, cancelling the one still running.</summary>
    protected CancellationToken BeginLoad()
    {
        _load?.Cancel();
        _load = new CancellationTokenSource();
        return _load.Token;
    }

    protected static Button Button(string label, Action click)
    {
        var button = new Button { Content = label, Margin = new Thickness(0, 0, 8, 0), MinWidth = 72 };
        button.Click += (_, _) => click();
        return button;
    }
}

/// <summary>The last lines of one bench's log. Read only; nothing tails in the background, Refresh reloads.</summary>
internal sealed class LogsWindow : ToolWindow
{
    public const int Lines = 300;

    private readonly IBenchSource _source;
    private readonly BenchStatus _bench;
    private readonly Action<string> _copy;
    private readonly TextBox _text = new()
    {
        IsReadOnly = true,
        FontFamily = new FontFamily("Cascadia Mono, Consolas"),
        FontSize = 12,
        TextWrapping = TextWrapping.NoWrap,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
        AcceptsReturn = true,
    };
    private readonly TextBlock _status = new() { Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center };
    private IReadOnlyList<string> _lines = [];

    public LogsWindow(IBenchSource source, BenchStatus bench, ResolvedTheme theme, Action<string> copy)
        : base($"{bench.Name} log", 600, 420, theme)
    {
        _source = source;
        _bench = bench;
        _copy = copy;

        var bar = new DockPanel { Margin = new Thickness(8) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(Button("Refresh", () => _ = LoadAsync()));
        buttons.Children.Add(Button("Copy", () => _copy(string.Join(Environment.NewLine, _lines))));
        buttons.Children.Add(Button("Open in Notepad", OpenInNotepad));
        DockPanel.SetDock(buttons, Dock.Left);
        bar.Children.Add(buttons);
        bar.Children.Add(_status);

        var root = new DockPanel();
        DockPanel.SetDock(bar, Dock.Bottom);
        root.Children.Add(bar);
        _text.Margin = new Thickness(8, 8, 8, 0);
        root.Children.Add(_text);
        Content = root;

        Loaded += (_, _) => _ = LoadAsync();
    }

    public async Task LoadAsync()
    {
        var ct = BeginLoad();
        _status.Text = "Loading...";
        try
        {
            var tail = await _source.LogsAsync(_bench.Path, ct, Lines);
            if (ct.IsCancellationRequested) return;
            _lines = tail.Lines;
            _text.Text = string.Join(Environment.NewLine, tail.Lines);
            _text.ScrollToEnd();
            _status.Text = $"{tail.Lines.Count} lines from {tail.File ?? "the bench log"}";
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
        }
        catch (Exception ex)
        {
            _status.Text = ex is SourceProblemException ? ex.Message : "The log could not be read: " + ex.Message;
        }
    }

    private void OpenInNotepad()
    {
        try
        {
            var dir = Path.Combine(Path.GetTempPath(), "BenchBar");
            Directory.CreateDirectory(dir);
            var file = Path.Combine(dir, TextFormats.SafeFileName(_bench.Name) + "-bench.log");
            File.WriteAllLines(file, _lines);
            var info = new ProcessStartInfo("notepad.exe") { UseShellExecute = false };
            info.ArgumentList.Add(file);
            Process.Start(info)?.Dispose();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            _status.Text = "Notepad could not be opened: " + ex.Message;
        }
    }
}

/// <summary>One bench's doctor result: summary, then the checks FAIL first, each with its fix line and a Copy.</summary>
internal sealed class DoctorWindow : ToolWindow
{
    private static readonly FontFamily Mono = new("Cascadia Mono, Consolas");

    private readonly IBenchSource _source;
    private readonly BenchStatus _bench;
    private readonly Action<string> _copy;
    private readonly TextBlock _summary = new() { FontSize = 16, FontWeight = FontWeights.SemiBold };
    private readonly TextBlock _progress = new() { Opacity = 0.7, Margin = new Thickness(0, 4, 0, 0) };
    private readonly StackPanel _list = new();
    private readonly Button _copyAll;
    private DoctorReport? _report;

    public DoctorWindow(IBenchSource source, BenchStatus bench, ResolvedTheme theme, Action<string> copy)
        : base($"{bench.Name} doctor", 640, 480, theme)
    {
        _source = source;
        _bench = bench;
        _copy = copy;

        _copyAll = Button("Copy all", () => { if (_report is not null) _copy(TextFormats.Doctor(_report)); });
        _copyAll.IsEnabled = false;
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
        bar.Children.Add(Button("Check again", () => _ = RunAsync()));
        bar.Children.Add(_copyAll);

        var head = new StackPanel { Margin = new Thickness(16, 14, 16, 8) };
        head.Children.Add(_summary);
        head.Children.Add(_progress);
        head.Children.Add(bar);

        var root = new DockPanel();
        DockPanel.SetDock(head, Dock.Top);
        root.Children.Add(head);
        root.Children.Add(new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = _list, Margin = new Thickness(8, 0, 8, 8) });
        Content = root;

        Loaded += (_, _) => _ = RunAsync();
    }

    public async Task RunAsync()
    {
        var ct = BeginLoad();
        _summary.Text = _bench.Name;
        _progress.Text = "Running checks...";
        _progress.Visibility = Visibility.Visible;
        _copyAll.IsEnabled = false;
        try
        {
            var report = await _source.DoctorAsync(_bench.Path, ct);
            if (ct.IsCancellationRequested) return;
            _report = report;
            Show(report);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
        }
        catch (Exception ex)
        {
            _list.Children.Clear();
            _summary.Text = "Doctor could not run";
            _progress.Text = ex.Message;
        }
    }

    private void Show(DoctorReport report)
    {
        _summary.Text = TextFormats.Summary(report);
        _progress.Visibility = Visibility.Collapsed;
        _copyAll.IsEnabled = report.Checks.Count > 0;
        _list.Children.Clear();
        CheckLevel? group = null;
        foreach (var check in TextFormats.ByLevel(report))
        {
            if (group != check.Level)
            {
                group = check.Level;
                var count = report.Checks.Count(c => c.Level == check.Level);
                _list.Children.Add(new TextBlock
                {
                    Text = $"{LevelWord(check.Level)} ({count})",
                    FontWeight = FontWeights.SemiBold,
                    Margin = new Thickness(8, 12, 8, 4),
                });
            }
            _list.Children.Add(CheckRow(check));
        }
    }

    private UIElement CheckRow(DoctorCheck check)
    {
        var panel = new StackPanel { Margin = new Thickness(8, 4, 8, 4) };
        var top = new TextBlock { TextWrapping = TextWrapping.Wrap };
        top.Inlines.Add(new System.Windows.Documents.Run(check.Label) { FontWeight = FontWeights.SemiBold });
        panel.Children.Add(top);
        panel.Children.Add(new TextBlock { Text = check.Message, TextWrapping = TextWrapping.Wrap, Opacity = 0.85 });
        if (check.FixCommand is { Length: > 0 } fix)
        {
            var line = new DockPanel { Margin = new Thickness(0, 4, 0, 0), LastChildFill = true };
            var copy = new Button { Content = "Copy", Padding = new Thickness(8, 2, 8, 2), Margin = new Thickness(8, 0, 0, 0) };
            copy.Click += (_, _) => _copy(fix);
            DockPanel.SetDock(copy, Dock.Right);
            line.Children.Add(copy);
            line.Children.Add(new TextBlock { Text = fix, FontFamily = Mono, FontSize = 12, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center });
            panel.Children.Add(line);
        }
        return panel;
    }

    private static string LevelWord(CheckLevel level) => level switch
    {
        CheckLevel.Fail => "FAIL",
        CheckLevel.Warn => "WARN",
        CheckLevel.Ok => "OK",
        _ => "Other",
    };
}
