using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;
using H.NotifyIcon;

namespace BenchBar.Tray.Wpf;

/// <summary>
/// The WPF tray shell: no window at startup, a TaskbarIcon created in code, the
/// shared <see cref="TrayController"/> behind it and a lazily created flyout.
/// </summary>
public partial class App : Application, ITrayHost
{
    private TaskbarIcon? _icon;
    private TrayController? _controller;
    private HarnessLink? _link;
    private FlyoutWindow? _flyout;
    private long _flyoutHiddenAt;
    private bool _quitting;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Created first: `hello` is queued until the pipe is up, so nothing sent below is lost.
        _link = HarnessLink.FromEnvironment("WPF");
        if (_link is not null) _link.Command += cmd => Dispatcher.BeginInvoke(() => OnHarnessCommand(cmd));

        // Same order as the WinUI shell: the controller and the first frame exist before NIM_ADD,
        // so "icon-added" means a runner is visible, not an empty slot.
        _controller = new TrayController(BenchSourceFactory.FromEnvironment(), new DispatcherFrameClock(), this, TimeProvider.System);

        _icon = new TaskbarIcon { ToolTipText = "BenchBar", NoLeftClickDelay = true, ContextMenu = BuildMenu() };
        _icon.TrayLeftMouseUp += (_, _) => ToggleFlyout();

        // NIM_ADD succeeded when the core TrayIcon raises Created; IsCreated is the fallback.
        var added = false;
        void IconAdded()
        {
            if (added) return;
            added = true;
            _link?.Send($"icon-added qpc={HarnessLink.Qpc()}");
        }
        _icon.TrayIcon.Created += (_, _) => IconAdded();
        _icon.TrayIcon.UpdateIcon(_controller.Icons.Get(RunnerPose.Unknown, 0));
        _icon.ForceCreate();
        if (_icon.IsCreated) IconAdded();

        _controller.Start();
    }

    // --- ITrayHost ---

    public void SetIcon(IntPtr hicon) => _icon?.TrayIcon.UpdateIcon(hicon);

    public void SetTooltip(string text)
    {
        if (_icon is not null) _icon.ToolTipText = text;
    }

    public void Post(Action action) => Dispatcher.BeginInvoke(action);

    public void BenchesChanged(IReadOnlyList<BenchStatus> benches, string upText) => _flyout?.SetBenches(benches, upText);

    // --- flyout ---

    /// <summary>The one method both the left click and the harness's open-flyout call.</summary>
    private void ShowFlyout()
    {
        if (_quitting || _controller is null) return;
        if (_flyout is null)
        {
            _flyout = new FlyoutWindow(_controller, _link);
            _flyout.Hidden += () => _flyoutHiddenAt = Environment.TickCount64;
            _flyout.SetBenches(_controller.Benches, BenchAggregate.UpText(_controller.Benches.Select(b => b.State).ToList()));
        }
        _flyout.ShowAtTray();
    }

    /// <summary>
    /// A click on the tray icon deactivates the open flyout first (it hides itself), so
    /// the click that follows within a moment means "close", not "open again".
    /// </summary>
    private void ToggleFlyout()
    {
        if (_flyout is { IsVisible: true }) { _flyout.HideFlyout(); return; }
        if (Environment.TickCount64 - _flyoutHiddenAt < 300) return;
        ShowFlyout();
    }

    private void OnHarnessCommand(string command)
    {
        switch (command)
        {
            case "open-flyout": ShowFlyout(); break;
            case "hide-flyout": _flyout?.HideFlyout(); break;
            case "quit": Quit(); break;
        }
    }

    // --- context menu ---

    private ContextMenu BuildMenu()
    {
        var menu = new ContextMenu();
        var site = new MenuItem { Header = "Open site" };
        site.Click += (_, _) =>
        {
            var bench = _controller?.Benches.FirstOrDefault(b => !string.IsNullOrWhiteSpace(b.WebUrl));
            if (bench is not null) _controller!.OpenSite(bench);
        };
        var doctor = new MenuItem { Header = "Doctor" };
        doctor.Click += async (_, _) => { if (_controller is not null) await _controller.RunDoctorAsync(); };
        var quit = new MenuItem { Header = "Quit" };
        quit.Click += (_, _) => Quit();
        menu.Items.Add(site);
        menu.Items.Add(doctor);
        menu.Items.Add(new Separator());
        menu.Items.Add(quit);
        return menu;
    }

    private void Quit()
    {
        if (_quitting) return;
        _quitting = true;
        _controller?.Dispose();
        _flyout?.Close();
        _icon?.Dispose(); // NIM_DELETE
        _link?.Dispose(); // sends bye
        Shutdown();
    }
}
