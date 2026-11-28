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
    private sealed record AddRow(TextBox Source, TextBox Branch, TextBox Commit, List<CheckBox> Sites, UIElement View);

    private List<AddRow> _addRows = [];
    private StackPanel? _addRowsHost;
    private Button? _addAnother;
    private TextBlock? _addProblem;

    public AppsView(PageServices services)
    {
        _services = services;
        Content = _root;
        Ui.Name(this, UiText.Get("BenchTabApps"));
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
        var refresh = Ui.Button(UiText.Get("HistoryRefresh"), () => Start(() => ReloadAsync(live: true)), UiText.Get("AppsRefreshName"), minWidth: 72);
        refresh.IsEnabled = !_loading && !_busy;
        refresh.ToolTip = UiText.Get("AppsRefreshTip");
        var remotes = Ui.Button(UiText.Get("AppsCheckRemotes"), () => Start(CheckRemotesAsync), minWidth: 72);
        remotes.IsEnabled = !_checking && !_busy;
        remotes.ToolTip = UiText.Get("AppsCheckTip");
        var add = Ui.Button(UiText.Get("AppsAdd"), () => OpenAdd(), primary: true);
        add.IsEnabled = !_busy;
        add.Margin = new Thickness(0);
        buttons.Children.Add(refresh);
        buttons.Children.Add(remotes);
        if (_list is not { OnlyFrappe: true }) buttons.Children.Add(add); // with only Frappe the empty state below has the one action
        DockPanel.SetDock(buttons, Dock.Right);
        head.Children.Add(buttons);
        head.Children.Add(Ui.Title(UiText.Get("BenchTabApps")));
        _root.Children.Add(head);
        _root.Children.Add(Ui.Text(UiText.Get("AppsNote"), 12, opacity: 0.7, margin: new Thickness(0, 0, 0, 12)));

        if (_message is not null) _root.Children.Add(PagePanels.Banner(_message, _messageIsError));
        if (_listError is not null) _root.Children.Add(PagePanels.Banner(_listError, true));
        if (_list is { SitesError: { Length: > 0 } siteError })
            _root.Children.Add(Ui.Text(UiText.Format("AppsSiteListStale", siteError), 12, margin: new Thickness(0, 0, 0, 8)));
        _panelHost.IsEnabled = !_busy;
        _root.Children.Add(_panelHost);

        if (_list is null)
        {
            if (_loading) _root.Children.Add(Ui.Text(UiText.Get("AppsReading"), 14, opacity: 0.8));
            return;
        }
        if (_list.OnlyFrappe)
            _root.Children.Add(PagePanels.EmptyState(UiText.Get("AppsOnlyFrappe"), UiText.Get("AppsAdd"), () => OpenAdd(), !_busy));
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

    private static Brush Orange => Ui.CautionTextBrush;


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
        if (app.Dirty) nameLine.Children.Add(Pill(UiText.Get("AppsLocalChanges"), Orange));
        if (!app.InAppsTxt) nameLine.Children.Add(Pill(UiText.Get("AppsNotInAppsTxt"), Ui.CriticalBrush));
        if (app.Branch is { } branch && app.PolicyBranch is { } policy && branch != policy) nameLine.Children.Add(Pill(UiText.Format("AppsExpected", policy), Orange));
        if (app.IsFocus) nameLine.Children.Add(Pill(UiText.Get("AppsFocus"), PagePanels.SelectedBrush));
        if (app.Pin == FocusPin.Ignore) nameLine.Children.Add(Pill(UiText.Get("AppsIgnored")));
        if (app.IsStaleDependency) nameLine.Children.Add(Pill(UiText.Get("AppsBehind"), Orange));
        text.Children.Add(nameLine);
        if ((app.FocusSummary ?? app.DependencySummary) is { } words)
        {
            var line = Ui.Text(words, 12, opacity: app.IsStaleDependency ? 1 : 0.7);
            if (app.IsStaleDependency) line.Foreground = Orange;
            text.Children.Add(line);
        }
        text.Children.Add(Ui.Text(app.SourceLine, 12, opacity: 0.7));
        if (sitesKnown) text.Children.Add(Ui.Text(app.Sites.Count == 0 ? UiText.Get("AppsOnNoSite") : UiText.Format("OverviewDriftOnSite", string.Join(", ", app.Sites)), 12, opacity: 0.7));
        var blocker = app.UpdateBlocker;
        if (blocker is not null)
        {
            var why = Ui.Text(UiText.Format("AppsUpdateOff", blocker), 12, margin: new Thickness(0, 2, 0, 0));
            why.Foreground = Orange;
            why.TextWrapping = TextWrapping.Wrap;
            text.Children.Add(why);
        }
        grid.Children.Add(text);

        var update = Ui.Button(UiText.Get("ProfileUpdateMenu"), () => Start(() => UpdateAsync(app)), UiText.Format("ProfileUpdateTitle", app.Name), minWidth: 84);
        update.Margin = new Thickness(8, 0, 6, 0);
        update.IsEnabled = !_busy && blocker is null;
        Grid.SetColumn(update, 1);
        grid.Children.Add(update);

        var more = PagePanels.MoreButton(UiText.Format("SitesMoreActions", app.Name), MenuEntries(app, sitesKnown), !_busy);
        Grid.SetColumn(more, 2);
        grid.Children.Add(more);

        var card = Ui.CardOf(grid, new Thickness(0, 0, 0, 6));
        Ui.Name(card, UiText.Format("AppsCardName", app.Name));
        return card;
    }

    private IEnumerable<PageMenuEntry> MenuEntries(BenchApp app, bool sitesKnown)
    {
        var missing = AppSites.Missing(app, SiteList, sitesKnown);
        foreach (var site in missing)
        {
            var target = site;
            yield return new PageMenuEntry(UiText.Format("AppsInstallOn", target), true, false, () => Start(() => InstallAsync(app.Name, target)));
        }
        if (missing.Count > 0) yield return PageMenuEntry.Divider;
        foreach (var pin in FocusPins.All)
        {
            var chosen = pin;
            yield return new PageMenuEntry(UiText.Format("AppsFocusPin", FocusPins.Title(pin)), app.Focus is not null, false,
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
        _addRows = [];
        _addRowsHost = null;
        _addAnother = null;
        _addProblem = null;
        _update = null;
        SetPanel(null);
    }

    private static string Why(CliStreamResult r) => r.Done?.Explained ?? r.Problem ?? UiText.Format("PendingFailed", r.Exit);

    private static string Why<T>(CliResult<T> r) => r.Done?.Explained ?? r.Error ?? r.Done?.Problem ?? UiText.Format("PendingFailed", r.Exit);

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
        Say(UiText.Get("AppsChecking"), false);
        Rebuild();
        var r = await _services.Cli.RunJsonAsync(AppCommands.CheckRemotes(Bench.Path), null, CliTimeouts.Plan, AppJson.ParseFocusReport);
        PagePanels.OnUi(this, () =>
        {
            _checking = false;
            if (r.Value is { } report)
            {
                var behind = report.Apps.Count(a => a.IsStaleDependency);
                Say(behind == 0 ? UiText.Get("AppsChecked") : behind == 1 ? UiText.Format("AppsBehindOne", behind) : UiText.Format("AppsBehindMany", behind), false);
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

    internal Task InstallAsync(string app, string site) => RunBusy(UiText.Format("AppsInstalling", app, site), async () =>
    {
        var r = await _services.Cli.RunStreamAsync(AppCommands.Install(app, site, Bench.Path), null, CliTimeouts.Apply, _ => { });
        return r.Ok ? (true, UiText.Format("AppsInstalled", app, site)) : (false, Why(r));
    });

    internal Task SetFocusAsync(string app, FocusPin pin) => RunBusy(UiText.Format("AppsSettingPin", app, FocusPins.Title(pin)), async () =>
    {
        var r = await _services.Cli.RunJsonAsync(AppCommands.SetFocus(app, pin, Bench.Path), null, CliTimeouts.Read);
        return r.Ok ? (true, UiText.Format("AppsPinSet", app, FocusPins.Title(pin))) : (false, Why(r));
    });

    // --- Add App ---

    private void OpenAdd()
    {
        _addProblem = PagePanels.Line("", error: true);
        _addProblem.Visibility = Visibility.Collapsed;
        _addRows = [];
        _addRowsHost = new StackPanel();
        AddAnotherRow();
        _addAnother = Ui.Button(UiText.Get("AppsAddAnother"), () => { AddAnotherRow(); _addRows[^1].Source.Focus(); }, UiText.Get("AppsAddAnotherName"));
        UpdateAddAnother();
        var body = new List<UIElement> { _addRowsHost, _addAnother, _addProblem };
        SetPanel(PagePanels.Panel(UiText.Format("AppsAddTitle", Bench.Name),
            UiText.Get("AppsAddExplain"),
            body, [Ui.Button(UiText.Get("RunCmdReviewPlan"), () => Start(AddAppAsync), primary: true), Ui.Button(UiText.Get("Cancel"), ClosePanel)]));
        _addRows[0].Source.Focus();
    }

    /// <summary>A form for one more app. The first keeps the labels of the single app form; the others say which app they are.</summary>
    private void AddAnotherRow()
    {
        if (_addRowsHost is null || _addRows.Count >= AppAddBatch.MaxApps) return;
        var n = _addRows.Count + 1;
        var source = Ui.Field(n == 1 ? UiText.Get("AppsFieldSource") : UiText.Format("AppsFieldSourceN", n), "", _ => HideAddProblem(), 420);
        var branch = Ui.Field(n == 1 ? UiText.Get("AppsFieldBranch") : UiText.Format("AppsFieldBranchN", n), "", _ => HideAddProblem(), 220);
        var commit = Ui.Field(n == 1 ? UiText.Get("AppsFieldCommit") : UiText.Format("AppsFieldCommitN", n), "", _ => HideAddProblem(), 220);
        var sites = new List<CheckBox>();
        var sitePanel = new StackPanel();
        foreach (var name in SiteList)
        {
            var box = new CheckBox { Content = name, Margin = new Thickness(0, 2, 0, 2) };
            Ui.Name(box, n == 1 ? UiText.Format("AppsInstallOn", name) : UiText.Format("AppsInstallOnApp", n, name));
            sites.Add(box);
            sitePanel.Children.Add(box);
        }
        var view = new StackPanel { Margin = new Thickness(0, n == 1 ? 0 : 14, 0, 0) };
        if (n > 1) view.Children.Add(Ui.Text(UiText.Format("AppsCardName", n), 14, FontWeights.SemiBold, margin: new Thickness(0, 0, 0, 4)));
        view.Children.Add(Ui.Labeled(UiText.Get("AppsFieldSource"), source, UiText.Get("AppsSourceHelp")));
        view.Children.Add(Ui.Labeled(UiText.Get("AppsBranchLabel"), branch, UiText.Get("AppsBranchHelp")));
        view.Children.Add(Ui.Labeled(UiText.Get("AppsCommitLabel"), commit, UiText.Get("AppsCommitHelp")));
        if (sites.Count > 0) view.Children.Add(Ui.Labeled(UiText.Get("AppsInstallOnLabel"), sitePanel, UiText.Get("AppsInstallOnHelp")));
        var row = new AddRow(source, branch, commit, sites, view);
        if (n > 1)
        {
            var remove = Ui.Button(UiText.Get("AppsRemove"), () => RemoveRow(row), UiText.Format("AppsRemoveName", n));
            view.Children.Add(remove);
        }
        _addRows.Add(row);
        _addRowsHost.Children.Add(view);
        UpdateAddAnother();
        HideAddProblem();
    }

    private void RemoveRow(AddRow row)
    {
        if (_addRowsHost is null || !_addRows.Remove(row)) return;
        _addRowsHost.Children.Remove(row.View);
        UpdateAddAnother();
        HideAddProblem();
    }

    private void UpdateAddAnother()
    {
        if (_addAnother is not null) _addAnother.IsEnabled = _addRows.Count < AppAddBatch.MaxApps;
    }

    private void HideAddProblem()
    {
        if (_addProblem is not null) _addProblem.Visibility = Visibility.Collapsed;
    }

    /// <summary>The fields of the first app of the open Add App form (for tests); null when it is not open.</summary>
    internal (TextBox Source, TextBox Branch, TextBox Commit, IReadOnlyList<CheckBox> Sites)? AddForm =>
        _addRows.Count > 0 ? (_addRows[0].Source, _addRows[0].Branch, _addRows[0].Commit, _addRows[0].Sites) : null;

    /// <summary>The fields of every app of the open form, in order (for tests).</summary>
    internal IReadOnlyList<(TextBox Source, TextBox Branch, TextBox Commit, IReadOnlyList<CheckBox> Sites)> AddFormRows =>
        _addRows.Select(r => (r.Source, r.Branch, r.Commit, (IReadOnlyList<CheckBox>)r.Sites)).ToList();

    internal void AddAnotherAppForTest() => AddAnotherRow();

    internal string? AddProblemText => _addProblem is { Visibility: Visibility.Visible } p ? p.Text : null;

    internal async Task AddAppAsync()
    {
        if (_addRows.Count == 0) return;
        var inputs = _addRows.Select(r => new AppAddInput(r.Source.Text, r.Branch.Text, r.Commit.Text,
            r.Sites.Where(b => b.IsChecked == true).Select(b => (string)b.Content).ToList())).ToList();
        if (AppAddBatch.Problem(inputs) is { } problem)
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
        var title = AppAddBatch.Title(inputs);
        var request = PlanReviewRequest.Tokened(title, AppCommands.AddMany(inputs, benchPath)) with
        {
            ConfirmLabel = inputs.Count == 1 ? UiText.Get("AppsConfirmAdd") : UiText.Get("AppsConfirmAddMany"),
            Describe = AppAddBatch.PlanLines,
            CanStop = false,
            UsesSudoEnv = false,
            Summary = UiText.Get("AppsAddSummary"),
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
                Say(inputs.Count == 1 ? UiText.Format("SitesAdded", inputs[0].DisplayName) : UiText.Format("AppsAddedMany", string.Join(", ", inputs.Select(i => i.DisplayName))), false);
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
                state.Text = UiText.Format("AppsNoChangelog", app.Name, Why(r));
            }
            RenderUpdate(state);
        });
    }

    private void RenderUpdate(UpdateState s)
    {
        var body = new List<UIElement>();
        var buttons = new List<Button>();
        string? explanation = UiText.Get("AppsUpdateExplain");
        switch (s.Phase)
        {
            case UpdatePhase.Loading:
                body.Add(PagePanels.Line(UiText.Get("AppsFetching")));
                buttons.Add(Ui.Button(UiText.Get("Cancel"), ClosePanel));
                break;
            case UpdatePhase.UpToDate:
                explanation = null;
                body.Add(PagePanels.Line(UiText.Format("AppsUpToDate", s.App, s.Plan?.Branch ?? UiText.Get("AppsItsBranch"))));
                buttons.Add(Ui.Button(UiText.Get("ProfileDone"), ClosePanel, primary: true));
                break;
            case UpdatePhase.Review when s.Plan is { } plan:
                if (plan.HasPending) body.Add(PagePanels.Line(UiText.Get("AppsPendingEarlier")));
                body.Add(PagePanels.Line(plan.CommitsTotal == 1 ? UiText.Format("AppsCommitsOne", plan.CommitsTotal, plan.Branch ?? UiText.Get("AppsTheBranch")) : UiText.Format("AppsCommitsMany", plan.CommitsTotal, plan.Branch ?? UiText.Get("AppsTheBranch"))));
                foreach (var commit in plan.Commits)
                {
                    var row = new StackPanel { Orientation = Orientation.Horizontal };
                    row.Children.Add(Ui.Text(commit.Sha, 12, opacity: 0.6, margin: new Thickness(0, 0, 8, 0)));
                    row.Children.Add(Ui.Text(commit.Subject, 12));
                    body.Add(row);
                }
                if (plan.CommitsTotal > plan.Commits.Count) body.Add(Ui.Text(UiText.Format("AppsAndMore", plan.CommitsTotal - plan.Commits.Count), 12, opacity: 0.6));
                body.Add(Ui.Text(UiText.Get("AppsThenInOrder"), 13, margin: new Thickness(0, 8, 0, 2)));
                var n = 1;
                foreach (var step in plan.Steps) body.Add(PagePanels.Line(UiText.Format("SitesStepLine", n++, step.Name)));
                if (plan.Sites.Count > 0)
                    body.Add(Ui.Text(plan.SkipBackup ? UiText.Format("AppsSitesMigrated", string.Join(", ", plan.Sites)) : UiText.Format("AppsSitesBackedUp", string.Join(", ", plan.Sites)), 12, opacity: 0.7, margin: new Thickness(0, 6, 0, 0)));
                buttons.Add(Ui.Button(UiText.Get("Cancel"), ClosePanel));
                buttons.Add(Ui.Button(UiText.Get("ProfileUpdate"), () => Start(() => RunUpdateAsync(s)), UiText.Format("AppsRunUpdate", s.App), primary: true));
                break;
            case UpdatePhase.Running:
                explanation = null;
                body.Add(PagePanels.Line(UiText.Format("AppsUpdating", s.App)));
                foreach (var (name, status) in s.Steps) body.Add(PagePanels.Line(UiText.Format("OverviewDriftLine", name, status)));
                break;
            case UpdatePhase.Done:
                explanation = null;
                body.Add(PagePanels.Line(s.Text ?? UiText.Format("AppsUpdated", s.App)));
                buttons.Add(Ui.Button(UiText.Get("ProfileDone"), ClosePanel, primary: true));
                break;
            default:
                explanation = null;
                body.Add(PagePanels.Line(s.Text ?? UiText.Format("AppsNotUpdated", s.App), error: true));
                buttons.Add(Ui.Button(UiText.Get("TidyClose"), ClosePanel));
                break;
        }
        SetPanel(PagePanels.Panel(UiText.Format("ProfileUpdateTitle", s.App), explanation, body, buttons));
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
                state.Text = r.Done is { Changed.Count: > 0 } done ? UiText.Format("AppsUpdatedChanged", state.App, string.Join(", ", done.Changed.Select(c => c.Name))) : UiText.Format("AppsUpdated", state.App);
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
