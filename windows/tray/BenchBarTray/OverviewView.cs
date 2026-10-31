using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>What the main window's Overview does for one bench. Every member has a harmless default, so the view works alone in tests.</summary>
internal sealed class OverviewActions
{
    public Func<BenchStatus, Task<ActionResult>> StartStop { get; set; } = _ => Task.FromResult(ActionResult.Success);
    public Func<BenchStatus, Task<ActionResult>> Restart { get; set; } = _ => Task.FromResult(ActionResult.Success);
    public Action<BenchStatus> OpenSite { get; set; } = _ => { };
    public Action<BenchStatus> ShowLogs { get; set; } = _ => { };
    public Action<BenchStatus> ShowHealth { get; set; } = _ => { };
    public Func<BenchStatus, VsCodeOutcome> OpenEditor { get; set; } = _ => VsCodeOutcome.Launched;
    public Func<string> EditorName { get; set; } = () => "VS Code";
    public Action<string> CopyText { get; set; } = _ => { };
    public Action<string> OpenUrl { get; set; } = _ => { };
}

/// <summary>Opens a command in Windows Terminal inside the distro: <c>wt.exe wsl.exe -d DISTRO --cd BENCH -- COMMAND</c>, else <c>wsl.exe</c> in its own console.</summary>
internal static class TerminalLauncher
{
    /// <summary>The reason the terminal did not open, or null.</summary>
    public static string? Open(TerminalLaunch launch)
    {
        try
        {
            var info = new ProcessStartInfo("wt.exe") { UseShellExecute = false };
            foreach (var arg in launch.WindowsTerminalArguments) info.ArgumentList.Add(arg);
            Process.Start(info)?.Dispose();
            return null;
        }
        catch (Win32Exception)
        {
            // no Windows Terminal: wsl.exe opens its own console window
        }
        try
        {
            var info = new ProcessStartInfo("wsl.exe") { UseShellExecute = false, CreateNoWindow = false };
            foreach (var arg in launch.WslArguments) info.ArgumentList.Add(arg);
            Process.Start(info)?.Dispose();
            return null;
        }
        catch (Win32Exception ex)
        {
            return "The terminal could not be opened: " + ex.Message;
        }
    }
}

/// <summary>
/// One bench in the main window: state, uptime and guidance, the actions the flyout row has (Start or Stop, Restart, Open site, Logs,
/// Doctor, Open in editor) and a More menu (Console, Database), the lockfile badge, the port settings and the Scheduler toggle (macos
/// BenchOverview). Rebuilt only when something it shows changed. Everything it adds costs nothing at rest: the uptime is worked out from
/// the status the poll already reads, and <c>lock check</c> runs when the tab is shown, once per bench, and on Check Again.
/// </summary>
internal sealed class OverviewView : UserControl
{
    private readonly OverviewActions _actions;
    private readonly HashSet<string> _busy = [];
    private readonly HashSet<string> _schedulerBusy = [];
    private readonly HashSet<string> _lockRunning = [];
    private readonly Dictionary<string, (string Message, BenchState State)> _failures = [];
    private readonly Dictionary<string, string> _portConflict = [];
    private readonly Dictionary<string, LockOutcome> _locks = [];
    private PageServices? _services;
    private Action<BenchTab, bool> _navigate = (_, _) => { };
    private BenchStatus? _bench;
    private string? _site;
    private string _key = "";
    private int _version;
    private bool _showDrift;

    public OverviewView(OverviewActions actions)
    {
        _actions = actions;
        Margin = new Thickness(0);
    }

    public BenchStatus? Bench => _bench;

    /// <summary>The labels of the buttons, in Tab order (for tests). The More menu is not in the list.</summary>
    public IReadOnlyList<string> ButtonLabels { get; private set; } = [];

    public string MessageText { get; private set; } = "";

    public Button? StartStopButton { get; private set; }

    /// <summary>The line of guidance and its button, or null when there is nothing to say.</summary>
    public NextActionRow? Guidance { get; private set; }

    /// <summary>The titles of the More menu, in order (for tests).</summary>
    public IReadOnlyList<string> MoreItems { get; private set; } = [];

    public Button? MoreButton { get; private set; }

    public MenuItem? ConsoleItem { get; private set; }

    public MenuItem? DatabaseItem { get; private set; }

    public CheckBox? SchedulerToggle { get; private set; }

    public Button? PortSettingsButton { get; private set; }

    /// <summary>The words of the lockfile badge ("In sync", "2 differences"), null when the section is not shown.</summary>
    public string? LockBadge { get; private set; }

    /// <summary>"Up for 2 h 5 min", null unless the bench runs.</summary>
    public string? UptimeText { get; private set; }

    /// <summary>Every line of text shown, in order (for tests).</summary>
    public IReadOnlyList<string> Lines { get; private set; } = [];

    /// <summary>The clock for the uptime. Tests set it.</summary>
    public Func<DateTimeOffset> Now { get; set; } = () => DateTimeOffset.UtcNow;

    /// <summary>Asks before the scheduler is changed (a yes answers true). The default is a message box over the main window.</summary>
    public Func<string, string, bool> Confirm { get; set; } = (_, _) => true;

    /// <summary>Opens the port setup sheet. The default shows <see cref="PortSetupSheet"/>; tests replace it.</summary>
    public Action<BenchStatus, bool, bool>? ShowPortSetup { get; set; }

    /// <summary>
    /// Gives the view the page services (the CLI client for the port check, the lockfile and the scheduler, the sheets and the terminal)
    /// and a way to switch to another tab (Health, with the repair sheet when asked). Without it the view only does what its actions do.
    /// </summary>
    public void Attach(PageServices services, Action<BenchTab, bool> navigate)
    {
        _services = services;
        _navigate = navigate;
        Confirm = (title, message) =>
            MessageBox.Show(services.Owner(), message, title, MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) == MessageBoxResult.Yes;
    }

    public void Bind(BenchStatus bench, string? site)
    {
        if (_failures.TryGetValue(bench.Path, out var f) && f.State != bench.State) _failures.Remove(bench.Path);
        UptimeText = OverviewFacts.Uptime(bench, Now());
        var key = string.Join('|', bench.Path, bench.Name, bench.State, bench.RawState, bench.StopReason, bench.WebUrl, bench.Site, site,
            _busy.Contains(bench.Path), _failures.TryGetValue(bench.Path, out var g) ? g.Message : "", bench.Problem, MessageText,
            bench.Scheduler, UptimeText, _portConflict.ContainsKey(bench.Path), _schedulerBusy.Contains(bench.Path), _version, _showDrift);
        _bench = bench;
        _site = site;
        if (key == _key) return;
        _key = key;
        Rebuild(bench);
    }

    /// <summary>
    /// Compares the bench with its lockfile the first time the Overview is shown for it (<c>lock check --json</c>); later polls and
    /// returns to the tab do not ask again. Check Again asks again. Nothing runs without the page services or while another check runs.
    /// </summary>
    public Task EnsureLockChecked()
    {
        if (_services is null || _bench is not { } bench) return Task.CompletedTask;
        if (_locks.ContainsKey(bench.Path) || _lockRunning.Contains(bench.Path)) return Task.CompletedTask;
        return CheckLockAsync(bench);
    }

    private async Task CheckLockAsync(BenchStatus bench)
    {
        if (_services is null || !_lockRunning.Add(bench.Path)) return;
        _version++;
        Refresh();
        var result = await _services.Cli.RunJsonAsync(HealthArgs.LockCheck(bench.Path), null, CliTimeouts.Read, LockJson.Parse).ConfigureAwait(true);
        _lockRunning.Remove(bench.Path);
        _locks[bench.Path] = LockOutcome.Parse(result);
        _version++;
        Refresh();
    }

    private void Rebuild(BenchStatus bench)
    {
        var needsService = OverviewFacts.NeedsService(bench);
        var busy = _busy.Contains(bench.Path);
        var buttons = OverviewButtons.For(bench, busy);
        var canStartStop = buttons.CanStartStop && !needsService;
        var canRestart = buttons.CanRestart && !needsService;
        var root = new StackPanel { MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Left };

        var head = new StackPanel { Orientation = Orientation.Horizontal };
        var dot = Ui.Dot(bench.State, 12);
        dot.Margin = new Thickness(0, 4, 10, 0);
        head.Children.Add(dot);
        head.Children.Add(Ui.Text(_site ?? bench.Name, 26, FontWeights.SemiBold));
        root.Children.Add(head);

        var state = BenchPresentation.StateWord(bench);
        var stateLine = _site is null ? state : $"{bench.Name}, {state}";
        if (UptimeText is { } up) stateLine += ", " + up.ToLowerInvariant();
        root.Children.Add(Ui.Text(stateLine, 14, opacity: 0.75, margin: new Thickness(22, 2, 0, 12)));

        Guidance = NextActionRow.For(BenchGuidance.For(bench, needsService, _portConflict.ContainsKey(bench.Path), busy), PerformGuidance, GuidanceAction.Start, enabled: !busy);
        if (Guidance is not null) root.Children.Add(Guidance);

        var labels = new List<string>();
        var strip = new WrapPanel { Margin = new Thickness(0, 0, 0, 12) };
        StartStopButton = Add(strip, labels, buttons.StartStopLabel, () => RunAsync(bench, Guarded(_actions.StartStop, b => b.State is BenchState.Running or BenchState.Starting ? null : PortGuardAction.Start)).Forget(), canStartStop, primary: true);
        Add(strip, labels, "Restart", () => RunAsync(bench, Guarded(_actions.Restart, _ => PortGuardAction.Restart)).Forget(), canRestart);
        Add(strip, labels, "Open Site", () => _actions.OpenSite(bench), buttons.CanOpenSite);
        Add(strip, labels, "Logs", () => _actions.ShowLogs(bench), true);
        Add(strip, labels, "Health", () => _actions.ShowHealth(bench), true);
        var editor = _actions.EditorName();
        Add(strip, labels, "Open in " + editor, () => OpenEditor(bench), true);
        strip.Children.Add(MoreMenu(bench));
        root.Children.Add(strip);
        ButtonLabels = labels;

        if (_failures.TryGetValue(bench.Path, out var failure)) root.Children.Add(Banner(failure.Message));
        else if (bench.Problem is { } problem) root.Children.Add(Banner(problem));
        if (MessageText.Length > 0) root.Children.Add(Banner(MessageText));

        var details = new StackPanel();
        details.Children.Add(Detail("Address", string.IsNullOrWhiteSpace(bench.WebUrl) ? "no site" : bench.WebUrl, bench.WebUrl));
        details.Children.Add(Detail("Site", bench.Site ?? "no site", null));
        if (bench.Sites.Count > 1)
            details.Children.Add(Detail("Sites", string.Join(", ", bench.Sites.Select(s => s.Name)), null));
        details.Children.Add(Detail("Folder", bench.Path, bench.Path));
        if (bench.LogPath is { Length: > 0 } log) details.Children.Add(Detail("Log", log, log));
        PortSettingsButton = Ui.Button("Port Settings and Setup...", () => OpenPortSetup(bench, startAfterSetup: false, opensSettings: true), "Port Settings and Setup " + bench.Name, minWidth: 0);
        PortSettingsButton.Margin = new Thickness(0, 8, 0, 0);
        PortSettingsButton.HorizontalAlignment = HorizontalAlignment.Left;
        PortSettingsButton.IsEnabled = !busy && !needsService;
        details.Children.Add(PortSettingsButton);
        root.Children.Add(Ui.CardOf(details));

        if (LockSection(bench) is { } lockSection) root.Children.Add(lockSection);
        root.Children.Add(SchedulerSection(bench, needsService));

        Lines = TextProbe.Lines(root);
        Content = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = root, Padding = new Thickness(0, 0, 8, 0) };
    }

    // --- guidance ---

    private Action PerformGuidance(GuidanceAction action) => () =>
    {
        if (_bench is not { } bench) return;
        switch (action)
        {
            case GuidanceAction.Start:
                RunAsync(bench, Guarded(_actions.StartStop, _ => PortGuardAction.Start)).Forget();
                break;
            case GuidanceAction.ViewHealth:
                _navigate(BenchTab.Health, false);
                break;
            case GuidanceAction.Repair:
                _navigate(BenchTab.Health, true);
                break;
            case GuidanceAction.ReviewPortConflict:
                OpenPortSetup(bench, startAfterSetup: true, opensSettings: false);
                break;
            default:
                OpenPortSetup(bench, startAfterSetup: false, opensSettings: false);
                break;
        }
    };

    private void OpenPortSetup(BenchStatus bench, bool startAfterSetup, bool opensSettings)
    {
        if (ShowPortSetup is { } custom)
        {
            custom(bench, startAfterSetup, opensSettings);
            return;
        }
        if (_services is null) return;
        var finished = PortSetupSheet.Show(_services, bench, startAfterSetup, opensSettings);
        if (finished) _portConflict.Remove(bench.Path);
        _version++;
        Refresh();
    }

    // --- start and restart: the ports first ---

    /// <summary>
    /// Start and Restart check the ports first (<c>ports check --json</c>) when the page services are attached. A conflict refuses with the
    /// reason and the guidance row offers the review; nothing is killed. A start of a bench that already runs is let through.
    /// </summary>
    private Func<BenchStatus, Task<ActionResult>> Guarded(Func<BenchStatus, Task<ActionResult>> action, Func<BenchStatus, PortGuardAction?> kind) => async bench =>
    {
        if (_services is not null && kind(bench) is { } guardKind)
        {
            var guard = await PortGuard.CheckAsync(_services.Cli, bench.Path, guardKind).ConfigureAwait(true);
            if (!guard.Allowed)
            {
                if (guard.Conflict) _portConflict[bench.Path] = guard.Refusal ?? PortGuard.ConflictLead;
                return ActionResult.Failure(guard.Refusal ?? "The ports could not be checked.");
            }
            _portConflict.Remove(bench.Path);
        }
        return await action(bench).ConfigureAwait(true);
    };

    // --- the More menu ---

    private UIElement MoreMenu(BenchStatus bench)
    {
        var menu = new ContextMenu();
        ConsoleItem = new MenuItem { Header = "Open Console" };
        DatabaseItem = new MenuItem { Header = "Open Database" };
        ConsoleItem.ToolTip = "bench console, in Windows Terminal";
        DatabaseItem.ToolTip = "bench mariadb, in Windows Terminal";
        ConsoleItem.Click += (_, _) => OpenShell(_site, WslCommands.Console);
        DatabaseItem.Click += (_, _) => OpenShell(_site, WslCommands.Database);
        Ui.Name(ConsoleItem, "Open Console");
        Ui.Name(DatabaseItem, "Open Database");
        menu.Items.Add(ConsoleItem);
        menu.Items.Add(DatabaseItem);
        MoreItems = ["Open Console", "Open Database"];
        var more = Ui.Button("...", () =>
        {
            menu.PlacementTarget = MoreButton;
            menu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
            menu.IsOpen = true;
        }, "More actions " + bench.Name, minWidth: 40);
        more.ToolTip = "Console and database, in Windows Terminal";
        more.IsEnabled = !OverviewFacts.NeedsService(bench);
        MoreButton = more;
        return more;
    }

    internal void OpenShell(string? site, Func<string?, string[]> command)
    {
        if (_bench is not { } bench) return;
        var distro = _services?.Distro();
        if (site is not null && !SiteNames.IsValid(site))
        {
            MessageText = $"{site} is not a name the terminal can take.";
            Refresh();
            return;
        }
        if (_services is null || distro is null)
        {
            MessageText = WslCommands.NoDistroMessage;
        }
        else
        {
            MessageText = _services.OpenTerminal(new TerminalLaunch(distro, bench.Path, command(site))) ?? "";
        }
        Refresh();
    }

    // --- the lockfile ---

    private UIElement? LockSection(BenchStatus bench)
    {
        LockBadge = null;
        _locks.TryGetValue(bench.Path, out var outcome);
        var running = _lockRunning.Contains(bench.Path);
        if (outcome is { NoLockfile: true } && !running) return null;
        if (_services is null || (outcome is null && !running)) return null;

        var panel = new StackPanel();
        var row = new DockPanel();
        var again = Ui.Button("Check Again", () => CheckLockAsync(bench).Forget(), "Check the lockfile again " + bench.Name, minWidth: 0);
        again.Margin = new Thickness(12, 0, 0, 0);
        again.IsEnabled = !running;
        DockPanel.SetDock(again, Dock.Right);
        row.Children.Add(again);
        var text = new StackPanel { Orientation = Orientation.Horizontal };
        text.Children.Add(Ui.Text("Lockfile", 16, FontWeights.SemiBold, margin: new Thickness(0, 0, 12, 0)));
        if (running && outcome?.Check is null)
        {
            text.Children.Add(Ui.Text("Comparing with the lockfile...", 14, opacity: 0.75));
        }
        else if (outcome?.Check is { } check)
        {
            LockBadge = check.Badge;
            var glyph = Ui.Glyph(check.InSync ? Ui.CheckGlyph : Ui.WarningGlyph, 16, Ui.StatusBrush(check.InSync ? SetupStatus.Ok : SetupStatus.Warn), check.InSync ? "In sync" : "Differs");
            glyph.Margin = new Thickness(0, 0, 8, 0);
            text.Children.Add(glyph);
            text.Children.Add(Ui.Text(check.Badge, 14));
        }
        else if (outcome?.Error is { } error)
        {
            text.Children.Add(Ui.Text(error, 13, opacity: 0.75));
        }
        row.Children.Add(text);
        panel.Children.Add(row);
        if (outcome?.Check is { Drift.Count: > 0 } drifted)
        {
            var list = new StackPanel { Visibility = _showDrift ? Visibility.Visible : Visibility.Collapsed, Margin = new Thickness(0, 6, 0, 0) };
            foreach (var d in drifted.Drift)
            {
                var line = Ui.Text(d.Text, 13);
                if (d.IsFail) line.Foreground = Ui.CriticalBrush;
                list.Children.Add(line);
            }
            panel.Children.Add(Ui.Link(_showDrift ? "Hide differences" : "Show differences", () =>
            {
                _showDrift = !_showDrift;
                Refresh();
            }, "Differences"));
            panel.Children.Add(list);
            panel.Children.Add(Ui.Text(drifted.Footer, 12, opacity: 0.7, margin: new Thickness(0, 6, 0, 0)));
        }
        else if (outcome?.Check is { } synced && synced.LockFile is not null)
        {
            panel.Children.Add(Ui.Text(synced.Footer, 12, opacity: 0.7, margin: new Thickness(0, 6, 0, 0)));
        }
        return Ui.CardOf(panel);
    }

    // --- the scheduler ---

    private UIElement SchedulerSection(BenchStatus bench, bool needsService)
    {
        var busy = _schedulerBusy.Contains(bench.Path);
        var toggle = new CheckBox
        {
            Content = "Scheduler",
            IsChecked = bench.Scheduler == true,
            IsEnabled = bench.Scheduler is not null && !busy && !needsService && !_busy.Contains(bench.Path),
        };
        Ui.Name(toggle, "Scheduler " + bench.Name, OverviewFacts.SchedulerNote(bench.Scheduler));
        toggle.Click += (_, _) =>
        {
            var want = toggle.IsChecked == true;
            toggle.IsChecked = !want; // the status says what it is; the poll shows the new value
            SetSchedulerAsync(bench, want).Forget();
        };
        SchedulerToggle = toggle;
        var panel = new StackPanel();
        panel.Children.Add(Ui.Text("Background jobs", 16, FontWeights.SemiBold, margin: new Thickness(0, 0, 0, 6)));
        panel.Children.Add(toggle);
        panel.Children.Add(Ui.Text(busy ? "Changing the scheduler..." : OverviewFacts.SchedulerNote(bench.Scheduler), 12, opacity: 0.7, margin: new Thickness(22, 2, 0, 0)));
        return Ui.CardOf(panel);
    }

    /// <summary>
    /// <c>service --yes --with-schedule</c> or <c>--without-schedule</c> after a question, then a restart when the bench runs. Public so a test
    /// can await it.
    /// </summary>
    public async Task SetSchedulerAsync(BenchStatus bench, bool on)
    {
        if (_services is null) return;
        var title = on ? $"Run the scheduler for {bench.Name}?" : $"Stop the scheduler for {bench.Name}?";
        var message = $"BenchBar runs benchbar service {(on ? "--with-schedule" : "--without-schedule")}, then restarts the bench if it is running.";
        if (!Confirm(title, message)) return;
        if (!_schedulerBusy.Add(bench.Path)) return;
        _failures.Remove(bench.Path);
        Refresh();
        var result = await _services.Cli.RunStreamAsync(OverviewArgs.Scheduler(on, bench.Path), null, CliTimeouts.Apply, _ => { }).ConfigureAwait(true);
        _schedulerBusy.Remove(bench.Path);
        if (!result.Ok)
        {
            _failures[bench.Path] = (result.Problem ?? $"The scheduler could not be changed (exit {result.Exit}).", _bench?.State ?? bench.State);
            Refresh();
            return;
        }
        _services.RefreshNow();
        var current = _bench ?? bench;
        if (current.State is BenchState.Running or BenchState.Starting)
            await RunAsync(current, Guarded(_actions.Restart, _ => PortGuardAction.Restart)).ConfigureAwait(true);
        else
            Refresh();
    }

    // --- building blocks ---

    private Button Add(Panel into, List<string> labels, string label, Action click, bool enabled, bool primary = false)
    {
        var button = Ui.Button(label, click, label + " " + (_bench?.Name ?? ""), primary: primary && enabled);
        button.IsEnabled = enabled;
        into.Children.Add(button);
        labels.Add(label);
        return button;
    }

    private UIElement Detail(string label, string value, string? copy)
    {
        var grid = new Grid { Margin = new Thickness(0, 3, 0, 3) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(90) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var l = Ui.Text(label, 13, opacity: 0.7);
        var v = Ui.Text(value, 14);
        v.IsHitTestVisible = true;
        Grid.SetColumn(v, 1);
        grid.Children.Add(l);
        grid.Children.Add(v);
        if (copy is not null)
        {
            var button = Ui.Button("Copy", () => _actions.CopyText(copy), "Copy " + label, minWidth: 56);
            button.Margin = new Thickness(8, 0, 0, 0);
            button.Padding = new Thickness(8, 2, 8, 2);
            Grid.SetColumn(button, 2);
            grid.Children.Add(button);
        }
        return grid;
    }

    private static UIElement Banner(string text) => Ui.CardOf(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, Foreground = Ui.CriticalBrush });

    private async Task RunAsync(BenchStatus bench, Func<BenchStatus, Task<ActionResult>> action)
    {
        _busy.Add(bench.Path);
        _failures.Remove(bench.Path);
        Refresh();
        ActionResult result;
        try
        {
            result = await action(bench);
        }
        catch (SourceProblemException ex)
        {
            result = ActionResult.Failure(ex.Message);
        }
        _busy.Remove(bench.Path);
        if (!result.Ok) _failures[bench.Path] = (result.Message ?? "It did not work.", bench.State);
        Refresh();
    }

    private void OpenEditor(BenchStatus bench)
    {
        MessageText = _actions.OpenEditor(bench) switch
        {
            VsCodeOutcome.NotFound => VsCode.InstallMessage.Replace("VS Code", _actions.EditorName()),
            VsCodeOutcome.BadPath => VsCode.BadPathMessage(bench.Path),
            _ => "",
        };
        Refresh();
    }

    private void Refresh()
    {
        if (_bench is { } bench) Bind(bench, _site);
    }
}
