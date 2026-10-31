using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// The Apps tab of a bench page (macos BenchApps): the apps of the bench with their branch, sites and focus, Refresh and Check Remotes,
/// Add App with a plan, and per app Update, Install on a site and the focus pin. The list is read when the tab is first shown for a
/// bench and after a change, never on a timer. Add App uses the shared plan sheet; Update shows its changelog in a panel in the page,
/// because its plan has no token for the sheet.
/// </summary>
internal sealed class AppsView : UserControl, IBenchPageView
{
    private readonly PageServices _services;
    private readonly StackPanel _root = new() { MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly ContentControl _panelHost = new();
    private BenchContext? _context;
    private string _key = "";
    private string? _loadedFor;
    private BenchAppList? _list;
    private string? _listError;
    private bool _loading;
    private bool _checking;
    private bool _busy;
    private string? _message;
    private bool _messageIsError;

    // the Add App form is built once per opening, so a rebuild does not empty it
    private TextBox? _addSource;
    private TextBox? _addBranch;
    private TextBox? _addCommit;
    private List<CheckBox> _addSites = [];
    private TextBlock? _addProblem;

    public AppsView(PageServices services)
    {
        _services = services;
        Content = _root;
        Ui.Name(this, "Apps");
    }

    public PageServices Services => _services;

    public BenchContext? Context => _context;

    /// <summary>The last action started by a button or by showing the tab; tests wait on it.</summary>
    public Task Pending { get; private set; } = Task.CompletedTask;

    public BenchAppList? List => _list;

    public bool IsBusy => _busy;

    public bool IsLoading => _loading;

    public string? Message => _message;

    public bool MessageIsError => _messageIsError;

    public string? ListError => _listError;

    /// <summary>The panel in the page now (Add App, Update), or null.</summary>
    public UIElement? OpenPanel => _panelHost.Content as UIElement;

    private BenchStatus Bench => _context!.Bench;

    private IEnumerable<string> SiteList => Bench.Sites.Select(s => s.Name);

    public void Bind(BenchContext context)
    {
        var key = string.Join('|', context.Bench.Path, string.Join(',', context.Bench.Sites.Select(s => s.Name)));
        var benchChanged = _loadedFor != context.Bench.Path;
        _context = context;
        if (benchChanged)
        {
            // a different bench: nothing of the old one stays on screen
            _loadedFor = context.Bench.Path;
            _list = null;
            _listError = null;
            _message = null;
            ClosePanel();
            Pending = Guarded(() => ReloadAsync(live: false));
        }
        if (key == _key && !benchChanged) return;
        _key = key;
        Rebuild();
    }

    // --- drawing ---

    private void Rebuild()
    {
        if (_context is null) return;
        _root.Children.Clear();

        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        var refresh = Ui.Button("Refresh", () => Start(() => ReloadAsync(live: true)), "Refresh the site lists", minWidth: 72);
        refresh.IsEnabled = !_loading && !_busy;
        refresh.ToolTip = "Ask bench which sites have which app (needs MariaDB)";
        var remotes = Ui.Button("Check Remotes", () => Start(CheckRemotesAsync), minWidth: 72);
        remotes.IsEnabled = !_checking && !_busy;
        remotes.ToolTip = "git fetch the apps your focus apps need, to see how far behind they are (only .git changes)";
        var add = Ui.Button("Add App...", () => OpenAdd(), primary: true);
        add.IsEnabled = !_busy;
        add.Margin = new Thickness(0);
        buttons.Children.Add(refresh);
        buttons.Children.Add(remotes);
        if (_list is not { OnlyFrappe: true }) buttons.Children.Add(add); // with only Frappe the empty state below has the one action
        DockPanel.SetDock(buttons, Dock.Right);
        head.Children.Add(buttons);
        head.Children.Add(Ui.Title("Apps"));
        _root.Children.Add(head);
        _root.Children.Add(Ui.Text("Apps come from the app registry or any git repository, including private ones your SSH key can read. BenchBar never runs bench update.", 12, opacity: 0.7, margin: new Thickness(0, 0, 0, 12)));

        if (_message is not null) _root.Children.Add(PagePanels.Banner(_message, _messageIsError));
        if (_listError is not null) _root.Children.Add(PagePanels.Banner(_listError, true));
        if (_list is { SitesError: { Length: > 0 } siteError })
            _root.Children.Add(Ui.Text($"Site lists are from the last successful read: {siteError}", 12, margin: new Thickness(0, 0, 0, 8)));
        _panelHost.IsEnabled = !_busy;
        _root.Children.Add(_panelHost);

        if (_list is null)
        {
            if (_loading) _root.Children.Add(Ui.Text("Reading apps...", 14, opacity: 0.8));
            return;
        }
        if (_list.OnlyFrappe)
            _root.Children.Add(PagePanels.EmptyState("Only Frappe so far. Add ERPNext or any app from the registry or a git repository.", "Add App...", () => OpenAdd(), !_busy));
        foreach (var app in _list.Apps) _root.Children.Add(RowView(app, _list.SitesKnown));
    }

    private static Border Pill(string text, Brush? color = null)
    {
        var block = Ui.Text(text, 11, FontWeights.SemiBold, margin: new Thickness(0));
        if (color is not null) block.Foreground = color;
        var tag = new Border { Child = block, Background = Ui.Card, CornerRadius = new CornerRadius(8), Padding = new Thickness(7, 1, 7, 2), Margin = new Thickness(8, 1, 0, 0) };
        Ui.Name(tag, text);
        return tag;
    }

    private static readonly Brush Orange = FrozenBrush(Color.FromRgb(0xD9, 0x8E, 0x04));

    private static Brush FrozenBrush(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    private UIElement RowView(BenchApp app, bool sitesKnown)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var nameLine = new WrapPanel();
        nameLine.Children.Add(Ui.Text(app.Name, 15, FontWeights.SemiBold));
        if (app.Version is { } version) nameLine.Children.Add(Ui.Text(version, 12, opacity: 0.7, margin: new Thickness(8, 3, 0, 0)));
        if (app.Dirty) nameLine.Children.Add(Pill("local changes", Orange));
        if (!app.InAppsTxt) nameLine.Children.Add(Pill("not in apps.txt", Ui.CriticalBrush));
        if (app.Branch is { } branch && app.PolicyBranch is { } policy && branch != policy) nameLine.Children.Add(Pill($"expected {policy}", Orange));
        if (app.IsFocus) nameLine.Children.Add(Pill("focus", PagePanels.SelectedBrush));
        if (app.Pin == FocusPin.Ignore) nameLine.Children.Add(Pill("ignored"));
        if (app.IsStaleDependency) nameLine.Children.Add(Pill("behind", Orange));
        text.Children.Add(nameLine);
        if ((app.FocusSummary ?? app.DependencySummary) is { } words)
        {
            var line = Ui.Text(words, 12, opacity: app.IsStaleDependency ? 1 : 0.7);
            if (app.IsStaleDependency) line.Foreground = Orange;
            text.Children.Add(line);
        }
        text.Children.Add(Ui.Text(app.SourceLine, 12, opacity: 0.7));
        if (sitesKnown) text.Children.Add(Ui.Text(app.Sites.Count == 0 ? "on no site yet" : "on " + string.Join(", ", app.Sites), 12, opacity: 0.7));
        var blocker = app.UpdateBlocker;
        if (blocker is not null)
        {
            var why = Ui.Text("Update is off: " + blocker, 12, margin: new Thickness(0, 2, 0, 0));
            why.Foreground = Orange;
            why.TextWrapping = TextWrapping.Wrap;
            text.Children.Add(why);
        }
        grid.Children.Add(text);

        var update = Ui.Button("Update...", () => Start(() => UpdateAsync(app)), $"Update {app.Name}", minWidth: 84);
        update.Margin = new Thickness(8, 0, 6, 0);
        update.IsEnabled = !_busy && blocker is null;
        Grid.SetColumn(update, 1);
        grid.Children.Add(update);

        var more = PagePanels.MoreButton($"More actions for {app.Name}", MenuEntries(app, sitesKnown), !_busy);
        Grid.SetColumn(more, 2);
        grid.Children.Add(more);

        var card = Ui.CardOf(grid, new Thickness(0, 0, 0, 6));
        Ui.Name(card, $"App {app.Name}");
        return card;
    }

    private IEnumerable<PageMenuEntry> MenuEntries(BenchApp app, bool sitesKnown)
    {
        var missing = AppSites.Missing(app, SiteList, sitesKnown);
        foreach (var site in missing)
        {
            var target = site;
            yield return new PageMenuEntry($"Install on {target}", true, false, () => Start(() => InstallAsync(app.Name, target)));
        }
        if (missing.Count > 0) yield return PageMenuEntry.Divider;
        foreach (var pin in FocusPins.All)
        {
            var chosen = pin;
            yield return new PageMenuEntry($"Focus pin: {FocusPins.Title(pin)}", app.Focus is not null, false,
                () => Start(() => SetFocusAsync(app.Name, chosen)), Checked: app.Pin == pin);
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
            PagePanels.OnUi(this, () => { SetBusy(false); _loading = false; _checking = false; Say(ex.Message, true); Rebuild(); });
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

    /// <summary>The bench the open panel was opened for; its actions run against this path, never against whatever is bound now.</summary>
    private string? _panelBench;

    private string PanelBench => _panelBench ?? Bench.Path;

    private bool PanelIsStale => _panelBench is not null && _context is not null && _panelBench != Bench.Path;

    private void SetPanel(UIElement? panel)
    {
        _panelBench = panel is null ? null : (_panelBench ?? Bench.Path);
        _panelHost.Content = panel;
        _panelHost.IsEnabled = !_busy;
    }

    private void ClosePanel()
    {
        _addSource = null;
        _addBranch = null;
        _addCommit = null;
        _addSites = [];
        _addProblem = null;
        _update = null;
        SetPanel(null);
    }

    private static string Why(CliStreamResult r) => r.Problem ?? $"The command failed (exit {r.Exit}).";

    private static string Why<T>(CliResult<T> r) => r.Error ?? r.Done?.Problem ?? $"The command failed (exit {r.Exit}).";

    // --- the list ---

    /// <summary>Reads the apps. <paramref name="live"/> asks bench which sites have which app (Refresh); otherwise the cached site lists are used.</summary>
    internal async Task ReloadAsync(bool live)
    {
        var bench = Bench.Path;
        _loading = true;
        Rebuild();
        var r = await _services.Cli.RunJsonAsync(live ? AppCommands.ListLive(bench) : AppCommands.List(bench), null,
            live ? CliTimeouts.Plan : CliTimeouts.Read, AppJson.ParseList);
        PagePanels.OnUi(this, () =>
        {
            if (_context?.Bench.Path != bench) return; // another bench is on screen now
            _loading = false;
            if (r.Value is { } list)
            {
                _list = list;
                _listError = null;
            }
            else
            {
                _listError = Why(r);
            }
            Rebuild();
        });
    }

    internal async Task CheckRemotesAsync()
    {
        _checking = true;
        Say("Checking the remotes of the apps your focus apps need...", false);
        Rebuild();
        var r = await _services.Cli.RunJsonAsync(AppCommands.CheckRemotes(Bench.Path), null, CliTimeouts.Plan, AppJson.ParseFocusReport);
        PagePanels.OnUi(this, () =>
        {
            _checking = false;
            if (r.Value is { } report)
            {
                var behind = report.Apps.Count(a => a.IsStaleDependency);
                Say(behind == 0 ? "Checked the remotes. Nothing your focus apps need is behind." : $"Checked the remotes. {behind} app{(behind == 1 ? "" : "s")} your focus apps need {(behind == 1 ? "is" : "are")} behind.", false);
            }
            else
            {
                Say(Why(r), true);
            }
            Rebuild();
        });
        if (r.Value is not null) await ReloadAsync(live: false);
    }

    // --- Install, focus pin ---

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
        if (result.Ok) await ReloadAsync(live: false);
    }

    internal Task InstallAsync(string app, string site) => RunBusy($"Installing {app} on {site}... this migrates the site's database.", async () =>
    {
        var r = await _services.Cli.RunStreamAsync(AppCommands.Install(app, site, Bench.Path), null, CliTimeouts.Apply, _ => { });
        return r.Ok ? (true, $"{app} is installed on {site}.") : (false, Why(r));
    });

    internal Task SetFocusAsync(string app, FocusPin pin) => RunBusy($"Setting the focus pin of {app} to {FocusPins.Title(pin)}...", async () =>
    {
        var r = await _services.Cli.RunJsonAsync(AppCommands.SetFocus(app, pin, Bench.Path), null, CliTimeouts.Read);
        return r.Ok ? (true, $"The focus pin of {app} is {FocusPins.Title(pin)}.") : (false, Why(r));
    });

    // --- Add App ---

    private void OpenAdd()
    {
        _addSource = Ui.Field("App or repository", "", _ => HideAddProblem(), 420);
        _addBranch = Ui.Field("Branch", "", _ => HideAddProblem(), 220);
        _addCommit = Ui.Field("Commit", "", _ => HideAddProblem(), 220);
        _addProblem = PagePanels.Line("", error: true);
        _addProblem.Visibility = Visibility.Collapsed;
        _addSites = [];
        var sites = new StackPanel();
        foreach (var name in SiteList)
        {
            var box = new CheckBox { Content = name, Margin = new Thickness(0, 2, 0, 2) };
            Ui.Name(box, $"Install on {name}");
            _addSites.Add(box);
            sites.Children.Add(box);
        }
        var body = new List<UIElement>
        {
            Ui.Labeled("App or repository", _addSource, "erpnext, or a git URL such as https://github.com/org/app. Private repositories work when your SSH key can read them."),
            Ui.Labeled("Branch (optional)", _addBranch, "Empty: the profile's branch for a registry name, the repository's default for a URL."),
            Ui.Labeled("Commit (optional)", _addCommit, "Pins the app to this commit (7 to 40 hex characters)."),
        };
        if (_addSites.Count > 0) body.Add(Ui.Labeled("Install on", sites, "None ticked: the app is cloned and built, and installed on no site yet."));
        body.Add(_addProblem);
        SetPanel(PagePanels.Panel($"Add an app to {Bench.Name}",
            "Clones an app from the app registry or a git repository and installs it. You see the plan first.",
            body, [Ui.Button("Review Plan...", () => Start(AddAppAsync), primary: true), Ui.Button("Cancel", ClosePanel)]));
        _addSource.Focus();
    }

    private void HideAddProblem()
    {
        if (_addProblem is not null) _addProblem.Visibility = Visibility.Collapsed;
    }

    /// <summary>The fields of the open Add App form (for tests); null when it is not open.</summary>
    internal (TextBox Source, TextBox Branch, TextBox Commit, IReadOnlyList<CheckBox> Sites)? AddForm =>
        _addSource is not null && _addBranch is not null && _addCommit is not null ? (_addSource, _addBranch, _addCommit, _addSites) : null;

    internal string? AddProblemText => _addProblem is { Visibility: Visibility.Visible } p ? p.Text : null;

    internal async Task AddAppAsync()
    {
        if (_addSource is null || _addBranch is null || _addCommit is null) return;
        var input = new AppAddInput(_addSource.Text, _addBranch.Text, _addCommit.Text,
            _addSites.Where(b => b.IsChecked == true).Select(b => (string)b.Content).ToList());
        if (input.Problem is { } problem)
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
        var request = PlanReviewRequest.Tokened($"Add {input.DisplayName}", AppCommands.Add(input, benchPath)) with
        {
            ConfirmLabel = "Add App",
            CanStop = false,
            UsesSudoEnv = false,
            Summary = "Clones the app, installs its requirements and builds its assets, which can take several minutes. The bench keeps running.",
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
                return; // the person moved to another bench meanwhile
            }
            if (outcome.Applied)
            {
                ClosePanel();
                Say($"{input.DisplayName} was added.", false);
                _services.RefreshNow();
            }
            Rebuild();
        });
        if (outcome.Applied) await ReloadAsync(live: false);
    }

    // --- Update ---

    private enum UpdatePhase { Loading, Review, UpToDate, Running, Done, Failed }

    private sealed class UpdateState(string app, string benchPath)
    {
        public string App { get; } = app;
        public string BenchPath { get; } = benchPath;
        public UpdatePhase Phase { get; set; }
        public AppUpdatePlan? Plan { get; set; }
        public string? Text { get; set; }
        public List<(string Name, string Status)> Steps { get; } = [];
    }

    private UpdateState? _update;

    /// <summary>The plan of the open Update panel; null when there is none yet.</summary>
    public AppUpdatePlan? UpdatePlan => _update?.Plan;

    internal async Task UpdateAsync(BenchApp app)
    {
        if (app.UpdateBlocker is { } blocker)
        {
            Say(blocker, true);
            Rebuild();
            return;
        }
        var state = new UpdateState(app.Name, Bench.Path) { Phase = UpdatePhase.Loading };
        _update = state;
        RenderUpdate(state);
        var r = await _services.Cli.RunJsonAsync(AppCommands.UpdatePlan(app.Name, state.BenchPath), null, CliTimeouts.Plan, AppJson.ParseUpdatePlan);
        PagePanels.OnUi(this, () =>
        {
            if (!ReferenceEquals(_update, state)) return;
            if (r.Value is { } plan)
            {
                state.Plan = plan;
                state.Phase = plan.IsUpToDate ? UpdatePhase.UpToDate : UpdatePhase.Review;
            }
            else
            {
                state.Phase = UpdatePhase.Failed;
                state.Text = $"No changelog for {app.Name}: {Why(r)}";
            }
            RenderUpdate(state);
        });
    }

    private void RenderUpdate(UpdateState s)
    {
        var body = new List<UIElement>();
        var buttons = new List<Button>();
        string? explanation = "Shows the new commits and the steps before anything changes.";
        switch (s.Phase)
        {
            case UpdatePhase.Loading:
                body.Add(PagePanels.Line("Fetching the changes..."));
                buttons.Add(Ui.Button("Cancel", ClosePanel));
                break;
            case UpdatePhase.UpToDate:
                explanation = null;
                body.Add(PagePanels.Line($"{s.App} is up to date on {s.Plan?.Branch ?? "its branch"}."));
                buttons.Add(Ui.Button("Done", ClosePanel, primary: true));
                break;
            case UpdatePhase.Review when s.Plan is { } plan:
                if (plan.HasPending) body.Add(PagePanels.Line("An earlier update of this app stopped part way. This run finishes it."));
                body.Add(PagePanels.Line($"{plan.CommitsTotal} new commit{(plan.CommitsTotal == 1 ? "" : "s")} on {plan.Branch ?? "the branch"}:"));
                foreach (var commit in plan.Commits)
                {
                    var row = new StackPanel { Orientation = Orientation.Horizontal };
                    row.Children.Add(Ui.Text(commit.Sha, 12, opacity: 0.6, margin: new Thickness(0, 0, 8, 0)));
                    row.Children.Add(Ui.Text(commit.Subject, 12));
                    body.Add(row);
                }
                if (plan.CommitsTotal > plan.Commits.Count) body.Add(Ui.Text($"and {plan.CommitsTotal - plan.Commits.Count} more", 12, opacity: 0.6));
                body.Add(Ui.Text("Then, in order:", 13, margin: new Thickness(0, 8, 0, 2)));
                var n = 1;
                foreach (var step in plan.Steps) body.Add(PagePanels.Line($"{n++}. {step.Name}"));
                if (plan.Sites.Count > 0)
                    body.Add(Ui.Text(plan.SkipBackup ? $"Sites that are migrated: {string.Join(", ", plan.Sites)}." : $"Each site is backed up before it is migrated: {string.Join(", ", plan.Sites)}.", 12, opacity: 0.7, margin: new Thickness(0, 6, 0, 0)));
                buttons.Add(Ui.Button("Cancel", ClosePanel));
                buttons.Add(Ui.Button("Update", () => Start(() => RunUpdateAsync(s)), $"Run the update of {s.App}", primary: true));
                break;
            case UpdatePhase.Running:
                explanation = null;
                body.Add(PagePanels.Line($"Updating {s.App}... Do not close BenchBar until it finishes."));
                foreach (var (name, status) in s.Steps) body.Add(PagePanels.Line($"{name}: {status}"));
                break;
            case UpdatePhase.Done:
                explanation = null;
                body.Add(PagePanels.Line(s.Text ?? $"{s.App} was updated."));
                buttons.Add(Ui.Button("Done", ClosePanel, primary: true));
                break;
            default:
                explanation = null;
                body.Add(PagePanels.Line(s.Text ?? $"{s.App} was not updated.", error: true));
                buttons.Add(Ui.Button("Close", ClosePanel));
                break;
        }
        SetPanel(PagePanels.Panel($"Update {s.App}", explanation, body, buttons));
    }

    private async Task RunUpdateAsync(UpdateState state)
    {
        if (_context is null || state.BenchPath != Bench.Path || !ReferenceEquals(_update, state)) return; // the panel belongs to another bench
        state.Phase = UpdatePhase.Running;
        SetBusy(true);
        RenderUpdate(state);
        Rebuild();
        var r = await _services.Cli.RunStreamAsync(AppCommands.Update(state.App, state.BenchPath), null, CliTimeouts.Apply, e =>
        {
            if (e is not CliEvent.Step { Value: var step }) return;
            PagePanels.OnUi(this, () =>
            {
                var i = state.Steps.FindIndex(x => x.Name == step.Name);
                var entry = (step.Name, step.Status.ToString().ToLowerInvariant());
                if (i >= 0) state.Steps[i] = entry;
                else state.Steps.Add(entry);
                if (ReferenceEquals(_update, state) && state.Phase == UpdatePhase.Running) RenderUpdate(state);
            });
        });
        PagePanels.OnUi(this, () =>
        {
            SetBusy(false);
            if (r.Ok)
            {
                state.Phase = UpdatePhase.Done;
                state.Text = r.Done is { Changed.Count: > 0 } done ? $"{state.App} was updated. Changed: {string.Join(", ", done.Changed.Select(c => c.Name))}." : $"{state.App} was updated.";
            }
            else
            {
                state.Phase = UpdatePhase.Failed;
                state.Text = Why(r);
            }
            if (ReferenceEquals(_update, state)) RenderUpdate(state);
            if (!IsLoaded) _services.Notify(state.Text ?? "");
            Rebuild();
            if (r.Ok) _services.RefreshNow();
        });
        await ReloadAsync(live: false);
    }
}
