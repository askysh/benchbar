using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using BenchBar.Tray.Core;

namespace BenchBar.Tray.Wpf;

/// <summary>
/// The flyout: created on first open, then hidden and shown again, never closed
/// until Quit. Borderless, topmost tool window with the Fluent acrylic backdrop.
/// </summary>
internal sealed class FlyoutWindow : Window
{
    private const double FlyoutWidth = 320;
    private const double FlyoutMaxHeight = 400;
    private const double EdgeMargin = 12;

    private readonly TrayController _controller;
    private readonly HarnessLink? _link;
    private readonly TextBlock _upText = new() { Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel _rows = new();
    private readonly HashSet<string> _busy = [];
    private NativeMethods.Rect _work, _mon;
    private uint _dpi;
    private bool _shownOnce;
    private bool _renderPending;

    public FlyoutWindow(TrayController controller, HarnessLink? link)
    {
        _controller = controller;
        _link = link;

        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        ShowActivated = true;
        Width = FlyoutWidth;
        MaxHeight = FlyoutMaxHeight;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.Manual;
        if (HarnessLink.ForcedTheme() is { } theme)
            ThemeMode = theme == "dark" ? ThemeMode.Dark : ThemeMode.Light;

        var header = new DockPanel { Margin = new Thickness(16, 14, 16, 8), LastChildFill = false };
        var title = new TextBlock { Text = "BenchBar", FontSize = 16, FontWeight = FontWeights.SemiBold };
        DockPanel.SetDock(_upText, Dock.Right);
        header.Children.Add(title);
        header.Children.Add(_upText);

        var root = new DockPanel();
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);
        root.Children.Add(new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = _rows,
            Margin = new Thickness(8, 0, 8, 10),
        });
        Content = root;

        SourceInitialized += OnSourceInitialized;
        Deactivated += (_, _) => HideFlyout();
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Escape) return;
            e.Handled = true;
            HideFlyout();
        };
        IsVisibleChanged += OnVisibleChanged;
        SizeChanged += OnSizeChanged;
        ContentRendered += OnContentRendered;
    }

    /// <summary>Raised after the flyout was hidden.</summary>
    public event Action? Hidden;

    private IntPtr Hwnd => new WindowInteropHelper(this).Handle;

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        var hwnd = Hwnd;
        // tool window: no taskbar button, not in Alt+Tab
        NativeMethods.SetWindowLong(hwnd, NativeMethods.GwlExStyle,
            NativeMethods.GetWindowLong(hwnd, NativeMethods.GwlExStyle) | NativeMethods.WsExToolWindow);
        ApplyAcrylic();
    }

    /// <summary>
    /// The .NET 10 Fluent theme draws a Mica backdrop on windows through the internal
    /// Window.WindowBackdropType property (the type is not public). TransientWindow is
    /// DWM acrylic, so it is set by reflection; if that fails Mica stays.
    /// </summary>
    private void ApplyAcrylic()
    {
        try
        {
            var property = typeof(Window).GetProperty("WindowBackdropType", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public);
            if (property is null) return;
            property.SetValue(this, Enum.Parse(property.PropertyType, "TransientWindow"));
        }
        catch (Exception)
        {
            // keep the theme default backdrop
        }
    }

    public void SetBenches(IReadOnlyList<BenchStatus> benches, string upText)
    {
        _upText.Text = upText;
        _rows.Children.Clear();
        foreach (var bench in benches) _rows.Children.Add(BuildRow(bench));
    }

    private UIElement BuildRow(BenchStatus bench)
    {
        var grid = new Grid { Margin = new Thickness(8, 6, 8, 6) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var dot = StateDot(bench.State);
        Grid.SetColumn(dot, 0);

        var name = new TextBlock { Text = bench.Name, Margin = new Thickness(10, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        Grid.SetColumn(name, 1);

        var word = new TextBlock { Text = StateWord(bench.State), Opacity = 0.7, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(word, 2);

        var running = bench.State is BenchState.Running or BenchState.Starting;
        var button = new Button
        {
            Content = running ? "Stop" : "Start",
            MinWidth = 64,
            IsEnabled = !_busy.Contains(bench.Path),
        };
        button.Click += async (_, _) =>
        {
            _busy.Add(bench.Path);
            button.IsEnabled = false;
            try { await _controller.StartStopAsync(bench); }
            finally
            {
                _busy.Remove(bench.Path);
                button.IsEnabled = true;
            }
        };
        Grid.SetColumn(button, 3);

        grid.Children.Add(dot);
        grid.Children.Add(name);
        grid.Children.Add(word);
        grid.Children.Add(button);
        return grid;
    }

    private static Ellipse StateDot(BenchState state)
    {
        var dot = new Ellipse { Width = 10, Height = 10, VerticalAlignment = VerticalAlignment.Center };
        Color? color = state switch
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

    private static string StateWord(BenchState state) => state switch
    {
        BenchState.Running => "running",
        BenchState.Starting => "starting",
        BenchState.Crashed => "crashed",
        BenchState.Paused => "paused",
        BenchState.Stopped => "stopped",
        _ => "unknown",
    };

    // --- showing and hiding ---

    /// <summary>Shows the flyout above the notification area of the taskbar's monitor.</summary>
    public void ShowAtTray()
    {
        if (IsVisible)
        {
            Activate();
            return;
        }

        var taskbar = NativeMethods.FindWindow("Shell_TrayWnd", null);
        var monitor = NativeMethods.MonitorFromWindow(taskbar, NativeMethods.MonitorDefaultToPrimary);
        var info = new NativeMethods.MonitorInfo { Size = Marshal.SizeOf<NativeMethods.MonitorInfo>() };
        NativeMethods.GetMonitorInfo(monitor, ref info);
        uint dpi = 96;
        if (NativeMethods.GetDpiForMonitor(monitor, NativeMethods.MdtEffectiveDpi, out var dpiX, out _) == 0 && dpiX > 0) dpi = dpiX;
        var scale = dpi / 96.0;

        // height in DIPs from the content, so the placement is exact before the first frame
        Measure(new Size(FlyoutWidth, FlyoutMaxHeight));
        var heightDip = Math.Min(FlyoutMaxHeight, Math.Max(80, DesiredSize.Height));
        var widthPx = (int)Math.Round(FlyoutWidth * scale);
        var heightPx = (int)Math.Round(heightDip * scale);
        _work = info.Work;
        _mon = info.Monitor;
        _dpi = dpi;
        var (x, y) = Anchor(widthPx, heightPx);

        Left = x * 96.0 / dpi;
        Top = y * 96.0 / dpi;

        _renderPending = true;
        if (_shownOnce) CompositionTarget.Rendering += OnFirstRender;
        Show();
        // a new handle may have taken another DPI; put the window exactly where computed
        NativeMethods.SetWindowPos(Hwnd, IntPtr.Zero, x, y, 0, 0,
            NativeMethods.SwpNoSize | NativeMethods.SwpNoZOrder | NativeMethods.SwpNoActivate);
        Activate();
        _controller.FlyoutOpened();
    }

    /// <summary>The corner nearest the notification area, for a window of this physical size.</summary>
    private (int X, int Y) Anchor(int widthPx, int heightPx)
    {
        var margin = (int)Math.Round(EdgeMargin * _dpi / 96.0);
        if (_work.Top > _mon.Top) return (_work.Right - widthPx - margin, _work.Top + margin);        // taskbar on top
        if (_work.Left > _mon.Left) return (_work.Left + margin, _work.Bottom - heightPx - margin);   // taskbar on the left
        return (_work.Right - widthPx - margin, _work.Bottom - heightPx - margin);                    // bottom or right
    }

    /// <summary>The content grew or shrank after the first placement (benches arrived): keep the anchor corner.</summary>
    private void OnSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!IsVisible || _dpi == 0) return;
        var scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
        var (x, y) = Anchor((int)Math.Round(ActualWidth * scale), (int)Math.Round(ActualHeight * scale));
        NativeMethods.SetWindowPos(Hwnd, IntPtr.Zero, x, y, 0, 0,
            NativeMethods.SwpNoSize | NativeMethods.SwpNoZOrder | NativeMethods.SwpNoActivate);
    }

    public void HideFlyout()
    {
        if (IsVisible) Hide();
    }

    private void OnVisibleChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (IsVisible) return;
        _controller.FlyoutClosed();
        _link?.Send("flyout-hidden");
        Hidden?.Invoke();
    }

    // --- first rendered frame ---

    private void OnContentRendered(object? sender, EventArgs e)
    {
        if (_shownOnce) return;
        _shownOnce = true;
        ReportRendered(cold: true);
    }

    private void OnFirstRender(object? sender, EventArgs e)
    {
        CompositionTarget.Rendering -= OnFirstRender;
        ReportRendered(cold: false);
    }

    private void ReportRendered(bool cold)
    {
        if (!_renderPending) return;
        _renderPending = false;
        var qpc = HarnessLink.Qpc();
        var hwnd = Hwnd;
        NativeMethods.GetWindowRect(hwnd, out var r);
        _link?.Send($"flyout-rendered qpc={qpc} cold={(cold ? "true" : "false")} hwnd=0x{hwnd.ToInt64():X} rect={r.Left},{r.Top},{r.Right},{r.Bottom}");
    }
}
