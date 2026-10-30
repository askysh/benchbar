using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// The Sites tab of a bench page (macos BenchPage, the sites part): a row per site with Open or Set Up, a menu of the per site actions,
/// and Add Site. Add, Backups, Restore, Drop and Set Up show a panel in the page; the plan sheet and the typed confirmation come from
/// <see cref="PageServices"/>. Nothing here edits a hosts file: Windows resolves <c>*.localhost</c> by itself.
/// </summary>
internal sealed class SitesView : UserControl, IBenchPageView
{
    private readonly PageServices _services;
    private readonly StackPanel _root = new() { MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly ContentControl _panelHost = new();
    private BenchContext? _context;
    private string _key = "";
    private bool _busy;
    private string? _message;
    private bool _messageIsError;
    private int _panelGeneration;

    // the Add Site form is built once per opening, so a rebuild does not empty the password boxes
    private TextBox? _addName;
    private PasswordBox? _addPassword;
    private PasswordBox? _addConfirm;
    private TextBlock? _addProblem;

    public SitesView(PageServices services)
    {
        _services = services;
        Content = _root;
        Ui.Name(this, "Sites");
    }

    public PageServices Services => _services;

    public BenchContext? Context => _context;

    /// <summary>The site the sidebar selected, or null.</summary>
    public string? SelectedSite => _context?.Site;

    /// <summary>The last action started by a button; tests wait on it.</summary>
    public Task Pending { get; private set; } = Task.CompletedTask;

    public bool IsBusy => _busy;

    /// <summary>The line under the title: what the last action did, or why it did not work.</summary>
    public string? Message => _message;

    public bool MessageIsError => _messageIsError;

    public IReadOnlyList<SiteRowInfo> Rows { get; private set; } = [];

    /// <summary>The panel in the page now (Add Site, Backups, Drop, Set Up), or null.</summary>
    public UIElement? OpenPanel => _panelHost.Content as UIElement;

    // --- seam the tests replace ---

    /// <summary>Opens a Windows folder (or UNC path) in Explorer.</summary>
    public Action<string> FolderOpener { get; set; } = path => Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { path }, UseShellExecute = false })?.Dispose();

    private BenchStatus Bench => _context!.Bench;

    public void Bind(BenchContext context)
    {
        var key = string.Join('|', context.Bench.Path, context.Bench.State, context.Bench.WebUrl, context.Site,
            string.Join(',', context.Bench.Sites.Select(s => s.Name + (s.IsDefault ? "*" : ""))));
        // one view serves every bench: a panel opened for another bench must not outlive the switch
        if (_context is not null && _context.Bench.Path != context.Bench.Path)
        {
            ClosePanel();
            _message = null;
        }
        _context = context;
        if (key == _key) return;
        _key = key;
        Rebuild();
    }

    // --- drawing ---

    private void Rebuild()
    {
        if (_context is null) return;
        Rows = SiteRows.From(Bench);
        _root.Children.Clear();

        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
        var add = Ui.Button("Add Site...", () => OpenAdd(null), primary: true);
        add.IsEnabled = !_busy;
        add.Margin = new Thickness(0);
        DockPanel.SetDock(add, Dock.Right);
        if (Rows.Count > 0) head.Children.Add(add); // without sites the empty state below has the one action
        head.Children.Add(Ui.Title("Sites"));
        _root.Children.Add(head);
        _root.Children.Add(Ui.Text("The default site is the one benchup waits for, the runner pings and Open uses.", 12, opacity: 0.7, margin: new Thickness(0, 0, 0, 12)));

        if (_message is not null) _root.Children.Add(PagePanels.Banner(_message, _messageIsError));
        _panelHost.IsEnabled = !_busy;
        _root.Children.Add(_panelHost);

        if (Rows.Count == 0)
        {
            _root.Children.Add(PagePanels.EmptyState($"{Bench.Name} has no site yet.", "Add Site...", () => OpenAdd(null), !_busy));
            return;
        }
        foreach (var row in Rows) _root.Children.Add(RowView(row, Rows.Count == 1));
    }

    private UIElement RowView(SiteRowInfo row, bool onlySite)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var nameLine = new StackPanel { Orientation = Orientation.Horizontal };
        nameLine.Children.Add(Ui.Text(row.Name, 15, FontWeights.SemiBold));
        if (row.IsDefault)
        {
            var badge = Ui.Text("default", 11, FontWeights.SemiBold, margin: new Thickness(0));
            var pill = new Border { Child = badge, Background = Ui.Card, CornerRadius = new CornerRadius(8), Padding = new Thickness(7, 1, 7, 2), Margin = new Thickness(8, 1, 0, 0) };
            Ui.Name(pill, "default site");
            nameLine.Children.Add(pill);
        }
        text.Children.Add(nameLine);
        var detail = Ui.Text(row.NeedsSetUp ? "Windows cannot find this name" : row.Url ?? "no address", 12, opacity: row.NeedsSetUp ? 1 : 0.7);
        if (row.NeedsSetUp) detail.Foreground = new SolidColorBrush(Color.FromRgb(0xD9, 0x8E, 0x04));
        text.Children.Add(detail);
        grid.Children.Add(text);

        var action = Ui.Button(row.ActionLabel, () => RowAction(row), $"{row.ActionLabel} {row.Name}", minWidth: 84);
        action.IsEnabled = !_busy && (row.NeedsSetUp || row.CanOpen);
        action.Margin = new Thickness(8, 0, 6, 0);
        if (!row.NeedsSetUp && !row.CanOpen) action.ToolTip = "Start the bench to open the site";
        Grid.SetColumn(action, 1);
        grid.Children.Add(action);

        var entries = SiteMenu.For(row, onlySite).Select(item => new PageMenuEntry(item.Label, item.Enabled, item.Destructive, () => MenuAction(row, item.Action)));
        var more = PagePanels.MoreButton($"More actions for {row.Name}", entries, !_busy);
        Grid.SetColumn(more, 2);
        grid.Children.Add(more);

        var card = Ui.CardOf(grid, new Thickness(0, 0, 0, 6));
        Ui.Name(card, $"Site {row.Name}");
        if (_context?.Site == row.Name)
        {
            card.BorderBrush = PagePanels.SelectedBrush;
            card.BorderThickness = new Thickness(1);
        }
        return card;
    }

    private void RowAction(SiteRowInfo row)
    {
        if (row.NeedsSetUp) ShowSetUp(row);
        else if (row.Url is { } url) _services.OpenUrl(url);
    }

    private void MenuAction(SiteRowInfo row, SiteAction action)
    {
        switch (action)
        {
            case SiteAction.MakeDefault: Start(() => MakeDefaultAsync(row.Name)); break;
            case SiteAction.BackUp: Start(() => BackUpAsync(row.Name, false)); break;
            case SiteAction.BackUpWithFiles: Start(() => BackUpAsync(row.Name, true)); break;
            case SiteAction.Backups: Start(() => ShowBackupsAsync(row.Name, restore: false)); break;
            case SiteAction.Restore: Start(() => ShowBackupsAsync(row.Name, restore: true)); break;
            case SiteAction.Console: OpenShell(SiteShellKind.Console, row.Name); break;
            case SiteAction.Database: OpenShell(SiteShellKind.Database, row.Name); break;
            case SiteAction.Drop: StartDrop(row.Name); break;
        }
    }

    private void Start(Func<Task> work) => Pending = Guarded(work);

    private async Task Guarded(Func<Task> work)
    {
        try
        {
            await work();
        }
        catch (Exception ex)
        {
            PagePanels.OnUi(this, () => { SetBusy(false); Say(ex.Message, true); Rebuild(); });
        }
    }

    private void SetBusy(bool busy)
    {
        if (busy == _busy) return;
        _busy = busy;
        if (busy) _services.RunStarted();
        else _services.RunEnded();
    }

    private void Say(string? text, bool error)
    {
        _message = text;
        _messageIsError = error;
        if (!IsLoaded && text is { Length: > 0 }) _services.Notify(text); // the window was closed while the run went on
    }

    /// <summary>The bench the open panel was opened for. An action of the panel runs against this path, never against whatever is bound now.</summary>
    private string? _panelBench;

    private string PanelBench => _panelBench ?? Bench.Path;

    private bool PanelIsStale => _panelBench is not null && _context is not null && _panelBench != Bench.Path;

    private void SetPanel(UIElement? panel)
    {
        _panelGeneration++;
        _panelBench = panel is null ? null : (_panelBench ?? Bench.Path);
        _panelHost.Content = panel;
        _panelHost.IsEnabled = !_busy;
    }

    private void ClosePanel()
    {
        _addName = null;
        _addPassword = null;
        _addConfirm = null;
        _addProblem = null;
        _drop = null;
        SetPanel(null);
    }

    // --- a change that runs a command and says how it went ---

    private async Task RunBusy(string working, Func<Task<(bool Ok, string Text)>> work)
    {
        SetBusy(true);
        Say(working, false);
        Rebuild();
        (bool Ok, string Text) result;
        try
        {
            result = await work();
        }
        catch (Exception ex)
        {
            result = (false, ex.Message);
        }
        PagePanels.OnUi(this, () =>
        {
            SetBusy(false);
            Say(result.Text, !result.Ok);
            Rebuild();
            if (result.Ok) _services.RefreshNow();
        });
    }

    private static string Why(CliStreamResult r) => r.Problem ?? $"The command failed (exit {r.Exit}).";

    private static string Why<T>(CliResult<T> r) => r.Error ?? r.Done?.Problem ?? $"The command failed (exit {r.Exit}).";

    // --- Make Default, Back Up ---

    internal Task MakeDefaultAsync(string site) => RunBusy($"Making {site} the default site...", async () =>
    {
        var r = await _services.Cli.RunStreamAsync(SiteCommands.MakeDefault(site, Bench.Path), null, CliTimeouts.Plan, _ => { });
        return r.Ok ? (true, $"{site} is now the default site.") : (false, Why(r));
    });

    internal Task BackUpAsync(string site, bool withFiles) => RunBusy($"Backing up {site}{(withFiles ? " with its files" : "")}... this can take a few minutes.", async () =>
    {
        var r = await _services.Cli.RunJsonAsync(SiteCommands.BackUp(site, withFiles, Bench.Path), null, CliTimeouts.Apply, SiteJson.ParseBackupResult);
        if (!r.Ok) return (false, Why(r));
        var backup = r.Value!.Backup;
        return (true, backup is null ? $"{site} was backed up." : $"{site} was backed up: {backup.Stamp}, {ByteSize.Format(backup.SizeBytes)}{(backup.WithFiles ? ", with files" : "")}.");
    });

    // --- Console, Database ---

    internal void OpenShell(SiteShellKind kind, string site)
    {
        string? error = null;
        if (_services.Distro() is not { Length: > 0 } distro) error = WslCommands.NoDistroMessage;
        else if (!SiteNames.IsValid(site)) error = $"{site} is not a name the console can take.";
        else
        {
            var command = kind == SiteShellKind.Console ? WslCommands.Console(site) : WslCommands.Database(site);
            error = _services.OpenTerminal(new TerminalLaunch(distro, Bench.Path, command));
        }
        var what = kind == SiteShellKind.Console ? "console" : "database shell";
        Say(error is null ? null : $"The {what} did not open: {error}", error is not null);
        Rebuild();
    }

    // --- Set Up (a name Windows cannot resolve) ---

    private void ShowSetUp(SiteRowInfo row)
    {
        var suggestion = SiteNames.WithLocalhost(row.Name);
        var panel = PagePanels.Panel($"Set up {row.Name}", null,
            [PagePanels.Line($"Windows finds only names that end in .localhost. {row.Name} would need a line in the Windows hosts file, and BenchBar never edits it."),
             PagePanels.Line($"Add the site as {suggestion} instead; it opens in your browser without any setup.")],
            [Ui.Button($"Add {suggestion}...", () => OpenAdd(suggestion), primary: true), Ui.Button("Close", ClosePanel)]);
        SetPanel(panel);
    }

    // --- Add Site ---

    private void OpenAdd(string? name)
    {
        _addName = Ui.Field("Site name", name ?? "", _ => HideAddProblem(), 360);
        _addPassword = Ui.Password("Administrator password", _ => { });
        _addConfirm = Ui.Password("Confirm password", _ => { });
        _addProblem = PagePanels.Line("", error: true);
        _addProblem.Visibility = Visibility.Collapsed;
        var hint = Ui.Text("Names that end in .localhost open in your browser without any setup.", 12, opacity: 0.7, margin: new Thickness(0, 0, 0, 10));
        var panel = PagePanels.Panel($"Add a site to {Bench.Name}",
            "A new site on the same MariaDB, with only Frappe installed. Add apps from the Apps tab afterwards.",
            [Ui.Labeled("Site name", _addName), hint, Ui.Labeled("Administrator password", _addPassword), Ui.Labeled("Confirm password", _addConfirm), _addProblem],
            [Ui.Button("Review Plan...", () => Start(AddSiteAsync), primary: true), Ui.Button("Cancel", ClosePanel)]);
        SetPanel(panel);
        _addName.Focus();
    }

    private void HideAddProblem()
    {
        if (_addProblem is not null) _addProblem.Visibility = Visibility.Collapsed;
    }

    /// <summary>The text boxes of the open Add Site form (for tests); null when it is not open.</summary>
    internal (TextBox Name, PasswordBox Password, PasswordBox Confirm)? AddForm =>
        _addName is not null && _addPassword is not null && _addConfirm is not null ? (_addName, _addPassword, _addConfirm) : null;

    /// <summary>The problem the Add Site form shows, or null.</summary>
    internal string? AddProblemText => _addProblem is { Visibility: Visibility.Visible } p ? p.Text : null;

    /// <summary>The problem with the Add Site form, or null when it can go to the plan.</summary>
    internal string? AddFormProblem(string name, Secret password, Secret confirm)
    {
        if (!SiteNames.IsValid(name)) return name.Length == 0 ? "Enter a site name." : SiteNames.Rule;
        if (Rows.Any(r => r.Name == name)) return $"{name} is already a site of this bench.";
        if (password.IsEmpty) return "Enter an Administrator password.";
        if (!password.SameAs(confirm)) return "The two passwords are not the same.";
        return null;
    }

    internal async Task AddSiteAsync()
    {
        if (_addName is null || _addPassword is null || _addConfirm is null) return;
        var name = _addName.Text.Trim();
        using var password = Secret.From(_addPassword.SecurePassword);
        using var confirm = Secret.From(_addConfirm.SecurePassword);
        if (AddFormProblem(name, password, confirm) is { } problem)
        {
            if (_addProblem is not null)
            {
                _addProblem.Text = problem;
                _addProblem.Visibility = Visibility.Visible;
            }
            return;
        }
        if (PanelIsStale) return;
        var benchPath = PanelBench;
        var request = PlanReviewRequest.Tokened($"Add {name}", SiteCommands.Add(name, benchPath)) with
        {
            ConfirmLabel = "Add Site",
            UsesSudoEnv = false,
            CanStop = false,
            Summary = $"Creates {name} on this bench's MariaDB with only Frappe installed. The password goes to benchbar in its environment, never on a command line.",
            ConfigureEnv = env => env.Set("ADMIN_PASSWORD", password),
        };
        SetBusy(true);
        Rebuild();
        PlanOutcome outcome;
        try
        {
            outcome = await _services.ReviewPlan(request);
        }
        catch (Exception ex)
        {
            outcome = PlanOutcome.None;
            Say(ex.Message, true);
        }
        PagePanels.OnUi(this, () =>
        {
            SetBusy(false);
            if (_context is null || Bench.Path != benchPath)
            {
                if (outcome.Applied) _services.RefreshNow();
                return; // the person moved to another bench meanwhile: say nothing about this one there
            }
            if (outcome.Applied)
            {
                ClosePanel();
                Say($"{name} was added.", false);
                _services.RefreshNow();
            }
            Rebuild();
        });
    }

    // --- Backups, Restore ---

    internal async Task ShowBackupsAsync(string site, bool restore)
    {
        var title = restore ? $"Restore {site}" : $"Backups of {site}";
        SetPanel(PagePanels.Panel(title, null, [PagePanels.Line("Reading the backups...")], [Ui.Button("Close", ClosePanel)]));
        var generation = _panelGeneration;
        var r = await _services.Cli.RunJsonAsync(SiteCommands.Backups(site, Bench.Path), null, CliTimeouts.Read, SiteJson.ParseList);
        PagePanels.OnUi(this, () =>
        {
            if (generation != _panelGeneration) return; // the person opened something else meanwhile
            SetPanel(r.Value is { } list ? BackupsPanel(site, restore, list) : PagePanels.Panel(title, null, [PagePanels.Line(Why(r), error: true)], [Ui.Button("Close", ClosePanel)]));
        });
    }

    private UIElement BackupsPanel(string site, bool restore, SiteBackupList list)
    {
        var title = restore ? $"Restore {site}" : $"Backups of {site}";
        if (list.Backups.Count == 0)
        {
            return PagePanels.Panel(title, null, [PagePanels.Line($"{site} has no backup yet.")],
                [Ui.Button("Back Up", () => { ClosePanel(); Start(() => BackUpAsync(site, false)); }, $"Back Up {site}", primary: true), Ui.Button("Close", ClosePanel)]);
        }
        var rows = new List<UIElement>();
        foreach (var backup in list.Backups)
        {
            var grid = new Grid { Margin = new Thickness(0, 3, 0, 3) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var text = new StackPanel();
            text.Children.Add(Ui.Text(backup.Summary(), 13));
            text.Children.Add(Ui.Text(backup.Stamp, 11, opacity: 0.6));
            grid.Children.Add(text);
            var current = backup;
            var button = Ui.Button("Restore...", () => Start(() => RestoreAsync(site, current)), $"Restore {site} from {backup.Stamp}", minWidth: 84);
            button.Margin = new Thickness(8, 0, 0, 0);
            button.IsEnabled = backup.CanRestore;
            if (!backup.CanRestore) button.ToolTip = backup.WhyNotRestorable;
            Grid.SetColumn(button, 1);
            grid.Children.Add(button);
            rows.Add(grid);
        }
        var buttons = new List<Button>();
        if (list.Folder is { Length: > 0 } folder)
            buttons.Add(Ui.Button("Open Folder", () => OpenBackupFolder(folder), $"Open the backup folder of {site}"));
        buttons.Add(Ui.Button("Close", ClosePanel));
        return PagePanels.Panel(title,
            restore ? $"Pick the backup to restore. {site} is backed up first, then its database is replaced." : null,
            rows, buttons);
    }

    internal void OpenBackupFolder(string linuxFolder)
    {
        var distro = _services.Distro();
        if (distro is null)
        {
            Say("No WSL distro is set. Pick one in Settings, then try again.", true);
            Rebuild();
            return;
        }
        try
        {
            FolderOpener(TextFormats.WslToWindows(distro, linuxFolder));
        }
        catch (Exception ex)
        {
            Say($"The folder did not open: {ex.Message}", true);
            Rebuild();
        }
    }

    internal async Task RestoreAsync(string site, SiteBackup backup)
    {
        var typed = _services.ConfirmTyped(new TypedConfirmRequest($"Restore {site}",
            $"This replaces the database{(backup.WithFiles ? " and the files" : "")} of {site} with backup {backup.Stamp}. {site} is backed up first.",
            site, "Restore"));
        if (typed is null || !TypedConfirm.Matches(site, typed)) return;
        if (PanelIsStale) return;
        var benchPath = PanelBench;
        var request = PlanReviewRequest.Tokened($"Restore {site} from {backup.Stamp}", SiteCommands.Restore(site, backup, benchPath)) with
        {
            ConfirmLabel = "Restore",
            CanStop = false,
            UsesSudoEnv = false,
            Summary = $"Backs up {site}, replaces it with backup {backup.Stamp}, then runs bench migrate.",
        };
        SetBusy(true);
        Rebuild();
        PlanOutcome outcome;
        try
        {
            outcome = await _services.ReviewPlan(request);
        }
        catch (Exception ex)
        {
            outcome = PlanOutcome.None;
            Say(ex.Message, true);
        }
        PagePanels.OnUi(this, () =>
        {
            SetBusy(false);
            if (_context is null || Bench.Path != benchPath)
            {
                if (outcome.Applied) _services.RefreshNow();
                return; // the person moved to another bench meanwhile: say nothing about this one there
            }
            if (outcome.Applied)
            {
                ClosePanel();
                Say($"{site} was restored from {backup.Stamp}.", false);
                _services.RefreshNow();
            }
            Rebuild();
        });
    }

    // --- Drop Site ---

    private enum DropPhase { Review, Running, Done, Failed }

    private sealed class DropState(string site, bool isDefault, IReadOnlyList<string> successors, string benchPath)
    {
        public string Site { get; } = site;
        public string BenchPath { get; } = benchPath;
        public bool IsDefault { get; } = isDefault;
        public IReadOnlyList<string> Successors { get; } = successors;
        public string? NewDefault { get; set; } = isDefault ? successors.FirstOrDefault() : null;
        public SiteDropPlan? Plan { get; set; }
        public string? PlanError { get; set; }
        public DropPhase Phase { get; set; }
        public string? Result { get; set; }
        public string? Failure { get; set; }
    }

    private DropState? _drop;

    /// <summary>The plan of the open drop panel; null when there is none yet.</summary>
    public SiteDropPlan? DropPlan => _drop?.Plan;

    private void StartDrop(string site)
    {
        if (SiteDropRules.Blocker(Rows, site) is { } blocker)
        {
            Say(blocker, true);
            Rebuild();
            return;
        }
        var row = Rows.First(r => r.Name == site);
        var state = new DropState(site, row.IsDefault, SiteDropRules.Successors(Rows, site), Bench.Path);
        _drop = state;
        Start(() => LoadDropPlanAsync(state));
    }

    private async Task LoadDropPlanAsync(DropState state)
    {
        _drop = state;
        var chosen = state.NewDefault;
        state.Plan = null;
        state.PlanError = null;
        RenderDrop(state);
        var r = await _services.Cli.RunJsonAsync(SiteCommands.DropPlan(state.Site, chosen, state.BenchPath), null, CliTimeouts.Plan, SiteJson.ParseDropPlan);
        PagePanels.OnUi(this, () =>
        {
            if (!ReferenceEquals(_drop, state) || state.NewDefault != chosen) return;
            if (r.Value is { } plan) state.Plan = plan;
            else state.PlanError = Why(r);
            RenderDrop(state);
        });
    }

    private void RenderDrop(DropState s)
    {
        var body = new List<UIElement>();
        var buttons = new List<Button>();
        string? explanation = "Backs the site up with its files, drops its database and moves its folder to archived/sites. Nothing is deleted from disk.";
        switch (s.Phase)
        {
            case DropPhase.Review:
                if (s.IsDefault)
                {
                    var picker = new ComboBox { ItemsSource = s.Successors, SelectedItem = s.NewDefault, Width = 300, HorizontalAlignment = HorizontalAlignment.Left };
                    Ui.Name(picker, "New default site");
                    picker.SelectionChanged += (_, _) =>
                    {
                        if (picker.SelectedItem is string chosen && chosen != s.NewDefault)
                        {
                            s.NewDefault = chosen;
                            Start(() => LoadDropPlanAsync(s));
                        }
                    };
                    body.Add(Ui.Labeled("New default site", picker, $"{s.Site} is the default site: the site you pick becomes the default first."));
                }
                if (s.Plan is { } plan)
                {
                    var n = 1;
                    foreach (var step in plan.Steps)
                    {
                        body.Add(PagePanels.Line($"{n++}. {step.Title}"));
                        if (step.Command is { Length: > 0 } command && !step.NeedsPassword) body.Add(Ui.Text(command, 12, opacity: 0.6, margin: new Thickness(18, 0, 0, 4)));
                    }
                }
                else if (s.PlanError is { } error) body.Add(PagePanels.Line(error, error: true));
                else body.Add(PagePanels.Line("Reading the plan..."));
                buttons.Add(Ui.Button("Cancel", ClosePanel));
                var drop = Ui.Button("Drop Site...", () => Start(() => ConfirmDropAsync(s)), $"Drop {s.Site}");
                drop.IsEnabled = s.Plan is not null && (!s.IsDefault || s.NewDefault is not null);
                buttons.Add(drop);
                break;
            case DropPhase.Running:
                explanation = null;
                body.Add(PagePanels.Line($"Backing up and dropping {s.Site}... A backup with files can take a few minutes on a big site."));
                break;
            case DropPhase.Done:
                explanation = null;
                body.Add(PagePanels.Line(s.Result ?? $"{s.Site} was dropped."));
                buttons.Add(Ui.Button("Done", ClosePanel, primary: true));
                break;
            default:
                explanation = null;
                body.Add(PagePanels.Line(s.Failure ?? "The site was not dropped.", error: true));
                buttons.Add(Ui.Button("Close", ClosePanel));
                break;
        }
        SetPanel(PagePanels.Panel($"Drop {s.Site}", explanation, body, buttons));
    }

    private async Task ConfirmDropAsync(DropState state)
    {
        if (!ReferenceEquals(_drop, state) || _context is null || state.BenchPath != Bench.Path) return; // the panel belongs to another bench
        var typed = _services.ConfirmTyped(new TypedConfirmRequest($"Drop {state.Site}",
            "This backs the site up, drops its database and user, and moves its folder to archived/sites.", state.Site, "Drop"));
        if (typed is null || !TypedConfirm.Matches(state.Site, typed)) return;
        state.Phase = DropPhase.Running;
        SetBusy(true);
        RenderDrop(state);
        Rebuild();
        var r = await _services.Cli.RunJsonAsync(SiteCommands.Drop(state.Site, typed.Trim(), state.NewDefault, state.BenchPath), null, CliTimeouts.Apply, SiteJson.ParseDropResult);
        PagePanels.OnUi(this, () =>
        {
            SetBusy(false);
            if (r.Value is { Dropped: true } result)
            {
                state.Phase = DropPhase.Done;
                state.Result = DropText(state.Site, result);
            }
            else
            {
                state.Phase = DropPhase.Failed;
                state.Failure = r.Value is null ? Why(r) : $"{state.Site} was not dropped.";
            }
            if (ReferenceEquals(_drop, state)) RenderDrop(state);
            if (!IsLoaded) _services.Notify(state.Result ?? state.Failure ?? "");
            Rebuild();
            if (state.Phase == DropPhase.Done) _services.RefreshNow();
        });
    }

    private static string DropText(string site, SiteDropResult result)
    {
        var text = $"{site} was dropped.";
        if (result.Backup is { } backup) text += $" Backup {backup.Stamp} ({ByteSize.Format(backup.SizeBytes)}) is in its archived folder.";
        else if (result.ArchivedPath is { Length: > 0 } archived) text += $" Its folder is {archived}.";
        if (result.NewDefault is { Length: > 0 } next) text += $" {next} is the default site now.";
        return text;
    }
}
