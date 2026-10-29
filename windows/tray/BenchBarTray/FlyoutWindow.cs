using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// The flyout: created on first open, then hidden and shown again, never closed until Quit.
/// Borderless, topmost tool window with the Fluent acrylic backdrop, 340 DIP wide, placed at the notification area.
/// </summary>
internal sealed class FlyoutWindow : Window
{
    public const double FlyoutWidth = 340;
    private const double FlyoutMaxHeight = 460;
    private const double EdgeMargin = 12;

    private readonly TrayController _controller;
    private readonly HarnessLink? _link;
    private NativeMethods.Rect _work, _mon;
    private uint _dpi;
    private bool _shownOnce;
    private bool _renderPending;
    private bool _open;

    public FlyoutWindow(TrayController controller, FlyoutView view, HarnessLink? link)
    {
        _controller = controller;
        _link = link;
        View = view;

        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        ShowActivated = true;
        Width = FlyoutWidth;
        MaxHeight = FlyoutMaxHeight;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Content = view;

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
    }

    public FlyoutView View { get; }

    /// <summary>Raised after the flyout was shown.</summary>
    public event Action? Opened;

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

    /// <summary>Shows the flyout above the notification area of the taskbar's monitor, in the theme Appearance resolves to.</summary>
    public void ShowAtTray()
    {
        if (IsVisible)
        {
            Activate();
            return;
        }

        ThemeMode = ThemeResolver.Resolve(_controller.Appearance).FlyoutLight ? ThemeMode.Light : ThemeMode.Dark;
        View.ClearMessage();

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
        // The stamp is the first Rendering after Show, on every open, the first included.
        CompositionTarget.Rendering += OnFirstRender;
        // Opened and Hidden are strictly paired: _open is set and Opened raised before Show, so a Deactivated that fires
        // during Show hides through OnVisibleChanged with a matching Hidden, and a hide when not open raises nothing.
        _open = true;
        Opened?.Invoke();
        _controller.FlyoutOpened();
        Show();
        // The measure above runs before the first show applied the theme's template, so it can be short (80 DIP
        // against 123 for one bench), and a new handle may have taken another DPI: anchor the real window.
        UpdateLayout();
        Reanchor();
        Activate();
        Dispatcher.BeginInvoke(View.FocusFirst, System.Windows.Threading.DispatcherPriority.Loaded);
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
        Reanchor();
    }

    /// <summary>
    /// Puts the window's real rectangle (GetWindowRect, which the Fluent window chrome can make larger than
    /// ActualHeight) in the anchor corner.
    /// </summary>
    private void Reanchor()
    {
        if (!NativeMethods.GetWindowRect(Hwnd, out var r)) return;
        var (x, y) = Anchor(r.Right - r.Left, r.Bottom - r.Top);
        if (x == r.Left && y == r.Top) return;
        NativeMethods.SetWindowPos(Hwnd, IntPtr.Zero, x, y, 0, 0,
            NativeMethods.SwpNoSize | NativeMethods.SwpNoZOrder | NativeMethods.SwpNoActivate);
    }

    public void HideFlyout()
    {
        if (IsVisible) Hide();
    }

    private void OnVisibleChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (IsVisible || !_open) return;
        _open = false;
        _controller.FlyoutClosed();
        _link?.Send("flyout-hidden");
        Hidden?.Invoke();
    }

    private void OnFirstRender(object? sender, EventArgs e)
    {
        CompositionTarget.Rendering -= OnFirstRender;
        var cold = !_shownOnce;
        _shownOnce = true;
        if (!_renderPending) return;
        _renderPending = false;
        var qpc = HarnessLink.Qpc();
        var hwnd = Hwnd;
        NativeMethods.GetWindowRect(hwnd, out var r);
        _link?.Send($"flyout-rendered qpc={qpc} cold={(cold ? "true" : "false")} hwnd=0x{hwnd.ToInt64():X} rect={r.Left},{r.Top},{r.Right},{r.Bottom}");
    }
}
