using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>The ready dialog as the flow sees it: is it still open, and bring it to the front.</summary>
internal sealed record ReadyHandle(Func<bool> IsOpen, Action BringToFront);

/// <summary>What Report a Bug does on screen. The app fills these in; tests replace them, so the flow runs without a window.</summary>
internal sealed class ReportSeams
{
    /// <summary>Shows "Writing the report..." and returns the thing that removes it.</summary>
    public Func<IDisposable> ShowBusy { get; set; } = () => new Nothing();

    /// <summary>A second click while the report is being written: bring the busy window forward.</summary>
    public Action Refocus { get; set; } = () => { };

    /// <summary>
    /// The one short dialog: what to do with the zip. It opens Explorer and the browser itself, once, after it is on screen, and
    /// keeps itself in front of them. It does not block: the handle lets a later click bring it forward.
    /// </summary>
    public Func<ReportOutcome, ReadyHandle?> ShowReady { get; set; } = _ => null;

    /// <summary>The report could not be written at all (a locked folder, a full disk).</summary>
    public Action<string> ShowFailure { get; set; } = _ => { };

    public Action<string, Exception> Log { get; set; } = (_, _) => { };

    private sealed class Nothing : IDisposable
    {
        public void Dispose() { }
    }
}

/// <summary>
/// Report a Bug from start to end: busy window, the report, then the ready dialog (which opens Explorer and the browser). A second
/// click while one runs or while the dialog is open brings that window forward and starts nothing. benchbar.exe failing to start is
/// not an error here: the reporter writes a tray only zip and the flow goes on.
/// </summary>
internal sealed class ReportFlow(IBugReporter reporter, ReportSeams seams)
{
    private ReadyHandle? _ready;

    public bool IsRunning { get; private set; }

    /// <summary>False when a report is already being written or its dialog is open (the click only brings that window forward).</summary>
    public async Task<bool> RunAsync(ReportRequest request)
    {
        if (IsRunning)
        {
            seams.Refocus();
            return false;
        }
        if (_ready is { } open)
        {
            if (open.IsOpen())
            {
                open.BringToFront();
                return false;
            }
            _ready = null;
        }
        IsRunning = true;
        try
        {
            ReportOutcome outcome;
            using (seams.ShowBusy())
            {
                try
                {
                    outcome = await reporter.CreateAsync(request, CancellationToken.None);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
                {
                    seams.Log("report", ex);
                    seams.ShowFailure("The report could not be written: " + ex.Message);
                    return true;
                }
            }
            _ready = seams.ShowReady(outcome);
            return true;
        }
        finally
        {
            IsRunning = false;
        }
    }

    /// <summary>The Explorer command line that selects one file.</summary>
    public static ProcessStartInfo RevealInfo(string zip)
    {
        var info = new ProcessStartInfo("explorer.exe") { UseShellExecute = false };
        // Explorer parses its own command line: the path is quoted after the comma, so a profile
        // folder with a space still selects the file. A Windows path cannot hold a quote.
        info.Arguments = "/select,\"" + zip.Replace("\"", "", StringComparison.Ordinal) + "\"";
        return info;
    }
}

/// <summary>A small window with "Writing the report..." while the shim works. It has no close button; it goes when the report is done.</summary>
internal sealed class ReportBusyWindow : Window, IDisposable
{
    private bool _done;

    public ReportBusyWindow(ResolvedTheme theme, Window? owner)
    {
        Title = BugReportText.ReadyTitle;
        Width = 320;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStyle = WindowStyle.ToolWindow;
        ShowInTaskbar = owner is null;
        Topmost = owner is null;
        Owner = owner;
        WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;
        Ui.ApplyTheme(this, theme);
        Ui.Name(this, BugReportText.Working);
        var panel = new StackPanel { Margin = new Thickness(20) };
        var line = Ui.Live(Ui.Text(BugReportText.Working, 14));
        panel.Children.Add(line);
        panel.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 6, Margin = new Thickness(0, 12, 0, 0) });
        Content = panel;
        Closing += (_, e) => { if (!_done) e.Cancel = true; };
        // a distro that is missing or does not answer makes each check wait up to 20 seconds: say so instead of sitting still
        _slow = new System.Windows.Threading.DispatcherTimer { Interval = SlowAfter };
        _slow.Tick += (_, _) =>
        {
            _slow.Stop();
            line.Text = BugReportText.StillWorking;
        };
        _slow.Start();
    }

    /// <summary>How long the first text stays before it says the report is still being written.</summary>
    public static readonly TimeSpan SlowAfter = TimeSpan.FromSeconds(6);

    private readonly System.Windows.Threading.DispatcherTimer _slow;

    public void Dispose()
    {
        _done = true;
        _slow.Stop();
        Close();
    }
}

/// <summary>
/// The one dialog after a report: Open Issue, Show Zip, Copy Path. Once it is on screen it opens the GitHub issue and Explorer (once)
/// and then brings itself back in front, because both steal the focus and used to cover it.
/// </summary>
internal sealed class ReportReadyDialog : Window
{
    /// <summary>How long the dialog keeps winning the focus back from the browser and Explorer.</summary>
    public static readonly TimeSpan SettleTime = TimeSpan.FromSeconds(3);

    private readonly ReportOutcome _outcome;
    private readonly Action<string> _reveal;
    private readonly Action<string> _openUrl;
    private readonly System.Windows.Threading.DispatcherTimer _settle = new() { Interval = SettleTime };
    private bool _launched;
    private bool _settling;

    public ReportReadyDialog(ReportOutcome outcome, ResolvedTheme theme, Window? owner, Action<string> copy, Action<string> reveal, Action<string> openUrl)
    {
        _outcome = outcome;
        _reveal = reveal;
        _openUrl = openUrl;
        Title = BugReportText.ReadyTitle;
        Width = 480;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = true;
        Topmost = true; // until the browser and Explorer have settled; then it is an ordinary window
        Owner = owner;
        WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;
        Ui.ApplyTheme(this, theme);
        Ui.Name(this, BugReportText.ReadyTitle);

        var panel = new StackPanel { Margin = new Thickness(24) };
        panel.Children.Add(Ui.Text(BugReportText.ReadyMessage, 14));
        var path = Ui.Mono(outcome.ZipPath);
        path.Margin = new Thickness(0, 10, 0, 0);
        panel.Children.Add(path);
        if (outcome.Note is { Length: > 0 } note)
            panel.Children.Add(Ui.Text("benchbar.exe could not run, so this zip holds the tray's details only. " + note, 12, opacity: 0.8, margin: new Thickness(0, 8, 0, 0)));
        var bar = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        bar.Children.Add(Ui.Button("Copy Path", () => copy(outcome.ZipPath), "Copy the path of the report zip"));
        bar.Children.Add(Ui.Button("Show Zip", () => reveal(outcome.ZipPath), "Show the report zip in Explorer"));
        bar.Children.Add(Ui.Button("Open Issue", () => openUrl(outcome.IssueUrl), "Open the GitHub issue"));
        var close = Ui.Button("Close", Close, "Close", primary: true);
        close.IsDefault = close.IsCancel = true;
        close.Margin = new Thickness(0);
        bar.Children.Add(close);
        panel.Children.Add(bar);
        Content = panel;

        ContentRendered += (_, _) =>
        {
            Activate();
            LaunchOnce();
        };
        Deactivated += (_, _) =>
        {
            if (_settling) Activate();
        };
        _settle.Tick += (_, _) => Settled();
        Closed += (_, _) => _settle.Stop();
    }

    /// <summary>Opens Explorer with the zip selected and the GitHub issue, the first time only, then holds the front for <see cref="SettleTime"/>.</summary>
    internal void LaunchOnce()
    {
        if (_launched) return;
        _launched = true;
        _settling = true;
        _reveal(_outcome.ZipPath);
        _openUrl(_outcome.IssueUrl);
        _settle.Start();
        BringToFront();
    }

    private void Settled()
    {
        _settle.Stop();
        _settling = false;
        BringToFront();
        Topmost = false;
    }

    /// <summary>In front of everything, even of a window that was opened after it.</summary>
    public void BringToFront()
    {
        if (!IsVisible) return;
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Topmost = true;
        Activate();
        if (!_settling) Topmost = false; // topmost for the activation only

    }
}
