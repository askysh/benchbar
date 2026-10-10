using BenchBar.Tray.Core;
using H.NotifyIcon;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace BenchBar.Tray.WinUI;

/// <summary>
/// No window at startup: only the tray icon. Left click and the harness command
/// <c>open-flyout</c> both call <see cref="ShowFlyout"/>.
/// </summary>
public partial class App : Application, ITrayHost, IFrameClock
{
    private readonly DispatcherQueue _queue = DispatcherQueue.GetForCurrentThread();
    private readonly DispatcherQueueTimer _frameTimer;
    private Action? _tick;

    private TaskbarIcon? _icon;
    private TrayController? _controller;
    private Flyout? _flyout;
    private HarnessLink? _link;
    private string _tooltip = "";
    private bool _quitting;

    public App()
    {
        InitializeComponent();
        _frameTimer = _queue.CreateTimer();
        _frameTimer.IsRepeating = false;
        _frameTimer.Tick += (_, _) =>
        {
            var tick = _tick;
            _tick = null;
            tick?.Invoke();
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _link = HarnessLink.FromEnvironment("WinUI");
        _controller = new TrayController(BenchSourceFactory.FromEnvironment(), this, this, TimeProvider.System);
        _flyout = new Flyout(_controller, _link, HarnessLink.ForcedTheme());

        _icon = new TaskbarIcon
        {
            ToolTipText = "BenchBar",
            NoLeftClickDelay = true,
            ContextMenuMode = ContextMenuMode.PopupMenu,
            ContextFlyout = BuildMenu(),
            LeftClickCommand = new Command(OnTrayClick),
        };

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

        if (_link is not null) _link.Command += cmd => _queue.TryEnqueue(() => OnCommand(cmd));
        _controller.Start();
    }

    private MenuFlyout BuildMenu()
    {
        var menu = new MenuFlyout();
        var site = new MenuFlyoutItem { Text = "Open site" };
        site.Click += (_, _) =>
        {
            var bench = _controller?.Benches.FirstOrDefault(b => !string.IsNullOrWhiteSpace(b.WebUrl));
            if (bench is not null) _controller!.OpenSite(bench);
        };
        var doctor = new MenuFlyoutItem { Text = "Doctor" };
        doctor.Click += async (_, _) => await _controller!.RunDoctorAsync();
        var quit = new MenuFlyoutItem { Text = "Quit" };
        quit.Click += (_, _) => Quit();
        menu.Items.Add(site);
        menu.Items.Add(doctor);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(quit);
        return menu;
    }

    private void OnTrayClick()
    {
        if (_flyout!.IsVisible) _flyout.Hide();
        else if (!_flyout.JustHidden()) ShowFlyout();
    }

    /// <summary>Shows the flyout. The tray click and the harness call this same method.</summary>
    internal void ShowFlyout() => _flyout?.Show();

    private void OnCommand(string command)
    {
        switch (command)
        {
            case "open-flyout": ShowFlyout(); break;
            case "hide-flyout": _flyout?.Hide(); break;
            case "quit": Quit(); break;
        }
    }

    private void Quit()
    {
        if (_quitting) return;
        _quitting = true;
        _frameTimer.Stop();
        _controller?.Dispose();
        _icon?.Dispose();
        _link?.Dispose();
        Exit();
    }

    // --- ITrayHost ---

    public void SetIcon(IntPtr hicon)
    {
        if (!_quitting) _icon?.TrayIcon.UpdateIcon(hicon);
    }

    public void SetTooltip(string text)
    {
        if (_icon is null || text == _tooltip) return;
        _tooltip = text;
        _icon.ToolTipText = text;
    }

    public void Post(Action action) => _queue.TryEnqueue(() => action());

    public void BenchesChanged(IReadOnlyList<BenchStatus> benches, string upText) => _flyout?.Update(benches, upText);

    // --- IFrameClock: one pending one shot on the UI thread's dispatcher ---

    public void Schedule(TimeSpan delay, Action tick)
    {
        _frameTimer.Stop();
        _tick = tick;
        _frameTimer.Interval = delay < TimeSpan.FromMilliseconds(1) ? TimeSpan.FromMilliseconds(1) : delay;
        _frameTimer.Start();
    }

    public void Cancel()
    {
        _frameTimer.Stop();
        _tick = null;
    }

    private sealed class Command(Action run) : System.Windows.Input.ICommand
    {
        public event EventHandler? CanExecuteChanged { add { } remove { } }
        public bool CanExecute(object? parameter) => true;
        public void Execute(object? parameter) => run();
    }
}
