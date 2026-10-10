using System.Diagnostics;
using BenchBar.Tray.Core;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.System;
using WinRT.Interop;

namespace BenchBar.Tray.WinUI;

/// <summary>
/// The tray flyout: one borderless tool window, created on the first open, then
/// hidden and shown again (never destroyed).
/// </summary>
internal sealed class Flyout
{
    private const double WidthEpx = 320;
    private const double MaxHeightEpx = 400;

    private readonly TrayController _controller;
    private readonly HarnessLink? _link;
    private readonly string? _theme;
    private readonly HashSet<string> _busy = [];

    private Window? _window;
    private Grid? _root;
    private TextBlock? _upText;
    private StackPanel? _rows;
    private IReadOnlyList<BenchStatus> _benches = [];
    private string _up = "none up";
    private bool _cold = true;
    private bool _visible;
    private long _hiddenAt;

    public Flyout(TrayController controller, HarnessLink? link, string? theme)
    {
        _controller = controller;
        _link = link;
        _theme = theme;
    }

    public bool IsVisible => _visible;

    /// <summary>The same entry for the tray click and the harness command.</summary>
    public void Show()
    {
        var window = _window ??= Create();
        var cold = _cold;
        _cold = false;

        Resize(window);
        FirstFrame(cold);
        _visible = true;
        window.Activate();
        Native.SetForegroundWindow(WindowNative.GetWindowHandle(window));
        _controller.FlyoutOpened();
    }

    public void Hide()
    {
        if (!_visible || _window is null) return;
        _visible = false;
        _hiddenAt = Stopwatch.GetTimestamp();
        _window.AppWindow.Hide();
        _controller.FlyoutClosed();
        _link?.Send("flyout-hidden");
    }

    /// <summary>A tray click right after a deactivate hid the flyout means close it, not open it again.</summary>
    public bool JustHidden() =>
        _hiddenAt != 0 && Stopwatch.GetElapsedTime(_hiddenAt).TotalMilliseconds < 300;

    public void Update(IReadOnlyList<BenchStatus> benches, string upText)
    {
        var same = upText == _up && benches.SequenceEqual(_benches);
        _benches = benches;
        _up = upText;
        if (same) return;
        Rebuild();
        if (_visible && _window is not null) Resize(_window);
    }

    private void FirstFrame(bool cold)
    {
        void OnRendering(object? sender, object e)
        {
            CompositionTarget.Rendering -= OnRendering;
            var qpc = HarnessLink.Qpc();
            if (_link is null || _window is null) return;
            var hwnd = WindowNative.GetWindowHandle(_window);
            Native.GetWindowRect(hwnd, out var r);
            _link.Send($"flyout-rendered qpc={qpc} cold={(cold ? "true" : "false")} hwnd=0x{hwnd:X} rect={r.Left},{r.Top},{r.Right},{r.Bottom}");
        }
        CompositionTarget.Rendering += OnRendering;
    }

    private Window Create()
    {
        _root = new Grid { Padding = new Thickness(16, 14, 16, 14), RowSpacing = 8 };
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        if (_theme is not null) _root.RequestedTheme = _theme == "dark" ? ElementTheme.Dark : ElementTheme.Light;

        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        header.Children.Add(new TextBlock { Text = "BenchBar", FontSize = 16, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        _upText = new TextBlock { Opacity = 0.7, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 1) };
        header.Children.Add(_upText);
        _root.Children.Add(header);

        _rows = new StackPanel { Spacing = 6 };
        var scroll = new ScrollViewer { Content = _rows, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetRow(scroll, 1);
        _root.Children.Add(scroll);

        var escape = new KeyboardAccelerator { Key = VirtualKey.Escape };
        escape.Invoked += (_, args) => { args.Handled = true; Hide(); };
        _root.KeyboardAccelerators.Add(escape);

        var window = new Window
        {
            Content = _root,
            SystemBackdrop = new DesktopAcrylicBackdrop(),
            Title = "BenchBar",
        };
        if (window.AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.SetBorderAndTitleBar(false, false);
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
            presenter.IsAlwaysOnTop = true;
        }
        window.AppWindow.IsShownInSwitchers = false;
        var hwnd = WindowNative.GetWindowHandle(window);
        var ex = Native.GetWindowLongPtr(hwnd, Native.GWL_EXSTYLE);
        Native.SetWindowLongPtr(hwnd, Native.GWL_EXSTYLE, (ex | (nint)Native.WS_EX_TOOLWINDOW) & ~(nint)Native.WS_EX_APPWINDOW);

        window.Activated += (_, args) =>
        {
            if (args.WindowActivationState == WindowActivationState.Deactivated) Hide();
        };
        Rebuild();
        return window;
    }

    /// <summary>Content height up to 400 epx, then the bench list scrolls. Placed above the notification area.</summary>
    private void Resize(Window window)
    {
        var placement = TaskbarPlacement.Find();
        _root!.Measure(new Windows.Foundation.Size(WidthEpx, double.PositiveInfinity));
        var heightEpx = Math.Clamp(_root.DesiredSize.Height, 96, MaxHeightEpx);
        var scale = placement.Dpi / 96.0;
        var w = (int)Math.Round(WidthEpx * scale);
        var h = (int)Math.Round(heightEpx * scale);
        var (x, y) = placement.Place(w, h);
        window.AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(x, y, w, h));
    }

    private void Rebuild()
    {
        if (_rows is null || _upText is null) return;
        _upText.Text = _up;
        _rows.Children.Clear();
        if (_benches.Count == 0)
        {
            _rows.Children.Add(new TextBlock { Text = "No benches", Opacity = 0.7 });
            return;
        }
        foreach (var bench in _benches) _rows.Children.Add(Row(bench));
    }

    private Grid Row(BenchStatus bench)
    {
        var grid = new Grid { ColumnSpacing = 10, MinHeight = 36 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        grid.Children.Add(StateDot(bench.State));

        var name = new TextBlock { Text = bench.Name, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        Grid.SetColumn(name, 1);
        grid.Children.Add(name);

        var word = new TextBlock { Text = StateWord(bench.State), Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(word, 2);
        grid.Children.Add(word);

        var stop = bench.State is BenchState.Running or BenchState.Starting;
        var button = new Button
        {
            Content = stop ? "Stop" : "Start",
            MinWidth = 64,
            IsEnabled = !_busy.Contains(bench.Path),
        };
        button.Click += async (_, _) =>
        {
            _busy.Add(bench.Path);
            Rebuild();
            try { await _controller.StartStopAsync(bench); }
            finally
            {
                _busy.Remove(bench.Path);
                Rebuild();
            }
        };
        Grid.SetColumn(button, 3);
        grid.Children.Add(button);
        return grid;
    }

    private static Ellipse StateDot(BenchState state)
    {
        var dot = new Ellipse { Width = 10, Height = 10, VerticalAlignment = VerticalAlignment.Center };
        var color = state switch
        {
            BenchState.Running => ColorHelper.FromArgb(255, 0x2E, 0xA0, 0x43),
            BenchState.Starting => ColorHelper.FromArgb(255, 0xE0, 0x9B, 0x1A),
            BenchState.Crashed or BenchState.Paused => ColorHelper.FromArgb(255, 0xD1, 0x34, 0x38),
            _ => ColorHelper.FromArgb(255, 0x8A, 0x8A, 0x8A),
        };
        if (state == BenchState.Unknown)
        {
            dot.Stroke = new SolidColorBrush(color);
            dot.StrokeThickness = 1.5;
        }
        else dot.Fill = new SolidColorBrush(color);
        return dot;
    }

    private static string StateWord(BenchState state) => state switch
    {
        BenchState.Running => "running",
        BenchState.Starting => "starting",
        BenchState.Crashed => "crashed",
        BenchState.Paused => "paused",
        BenchState.Stopped => "stopped",
        _ => "unknown",
    };
}
