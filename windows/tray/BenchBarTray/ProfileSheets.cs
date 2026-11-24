using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// The frame of a profile sheet (macos SheetScaffold): a title, one line of explanation, a part built once (fields that keep their
/// caret), a part drawn again on every change of the run, and a button bar. A sheet that has a run in flight cannot be closed.
/// Each sheet shows the CLI's plan before it writes anything, and none of them installs an app or touches a bench.
/// </summary>
internal abstract class SheetWindow : Window
{
    private readonly StackPanel _fixed = new();
    private readonly StackPanel _dynamic = new();
    private readonly StackPanel _bar = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
    private readonly List<string> _lines = [];
    private readonly List<string> _buttons = [];
    private Func<bool> _busy = () => false;

    protected SheetWindow(string title, string explanation, ResolvedTheme theme, Window? owner, double width = 600)
    {
        Title = title;
        Width = width;
        MaxHeight = 780;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = owner is null;
        Owner = owner;
        WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;
        Ui.ApplyTheme(this, theme);
        Ui.Name(this, title);

        var column = new StackPanel();
        column.Children.Add(Ui.Text(title, 18, FontWeights.SemiBold));
        column.Children.Add(Ui.Text(explanation, 13, opacity: 0.8, margin: new Thickness(0, 4, 0, 14)));
        column.Children.Add(_fixed);
        column.Children.Add(_dynamic);
        var grid = new Grid { Margin = new Thickness(24) };
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Auto) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var scroll = new ScrollViewer { Content = column, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = 620 };
        Grid.SetRow(_bar, 1);
        grid.Children.Add(scroll);
        grid.Children.Add(_bar);
        Content = grid;
        Closing += (_, e) =>
        {
            if (_busy()) e.Cancel = true;
        };
    }

    /// <summary>Every line of text, in order (for tests).</summary>
    internal IReadOnlyList<string> Lines => _lines.ToArray();

    /// <summary>The labels of the bar, left to right (for tests).</summary>
    internal IReadOnlyList<string> ButtonLabels => _buttons.ToArray();

    /// <summary>The button of the bar with this label (for tests).</summary>
    internal Button BarButton(string label) => _bar.Children.OfType<Button>().Single(b => b.Content as string == label);

    /// <summary>True when the person ended the sheet with its main button.</summary>
    internal bool Accepted { get; private set; }

    /// <summary>Ends a shown sheet with this answer; a sheet that was never shown (a test) just closes.</summary>
    protected void End(bool accepted)
    {
        Accepted = accepted;
        try { DialogResult = accepted; }
        catch (InvalidOperationException) { Close(); }
    }

    protected void BusyWhen(Func<bool> busy) => _busy = busy;

    /// <summary>The part that is built once and kept (fields, rows with text boxes).</summary>
    protected StackPanel Fixed => _fixed;

    /// <summary>Draws again: clears the dynamic part and the bar, then calls <paramref name="draw"/>.</summary>
    protected void Redraw(Action draw)
    {
        _dynamic.Children.Clear();
        _bar.Children.Clear();
        _lines.Clear();
        _buttons.Clear();
        draw();
    }

    protected void Add(UIElement element) => _dynamic.Children.Add(element);

    protected TextBlock Line(string text, double size = 13, double opacity = 1, Brush? brush = null, Thickness? margin = null)
    {
        var block = Ui.Text(text, size, null, opacity, margin ?? new Thickness(0, 0, 0, 6));
        if (brush is not null) block.Foreground = brush;
        _dynamic.Children.Add(block);
        _lines.Add(text);
        return block;
    }

    protected void Failure(string text) => Line(text, brush: Ui.CriticalBrush);

    protected void Note(string text) => Line(text, 12, 0.7, margin: new Thickness(0, 8, 0, 0));

    protected void Headline(string text, string? detail = null, bool warning = false)
    {
        var block = Line(text, 15, brush: warning ? Ui.StepBrush(InstallStepStatus.Warning) : Ui.StepBrush(InstallStepStatus.Done), margin: new Thickness(0, 0, 0, 4));
        block.FontWeight = FontWeights.SemiBold;
        if (detail is not null) Line(detail, opacity: 0.85);
    }

    protected void Busy(string text)
    {
        Line(text, 14, 0.85);
        _dynamic.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 4, Margin = new Thickness(0, 0, 0, 8) });
    }

    protected void Bar(string label, Action click, bool primary = false, bool enabled = true, bool cancel = false, bool left = false, string? name = null)
    {
        var button = Ui.Button(label, click, name ?? label, primary: primary, minWidth: 0);
        button.IsEnabled = enabled;
        if (primary && enabled) button.IsDefault = true;
        if (cancel) button.IsCancel = true;
        button.Margin = left ? new Thickness(0, 0, 24, 0) : new Thickness(8, 0, 0, 0);
        _bar.Children.Add(button);
        _buttons.Add(label);
    }

    /// <summary>The repository line of Import and Check Access: a mark, the app, its repository, and why it is not reachable.</summary>
    protected void RepoRow(string app, string repo, ProfileRepoCheck? check)
    {
        var brush = check?.Reachable switch
        {
            true => Ui.StepBrush(InstallStepStatus.Done),
            false => Ui.StepBrush(InstallStepStatus.Failed),
            _ => Ui.StepBrush(InstallStepStatus.Warning),
        };
        var row = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
        var mark = Ui.Text(check?.Mark ?? "?", 15, FontWeights.SemiBold, margin: new Thickness(0, 0, 10, 0));
        mark.Foreground = brush;
        Ui.Name(mark, UiText.Format("ProfileRepoName", app, check?.Accessibility ?? UiText.Get("ProfileNotChecked")));
        DockPanel.SetDock(mark, Dock.Left);
        row.Children.Add(mark);
        var text = new StackPanel();
        text.Children.Add(Ui.Text(app, 13, FontWeights.SemiBold));
        text.Children.Add(Ui.Caption(repo));
        _lines.Add(app);
        _lines.Add(repo);
        if (check?.Reason is { Length: > 0 } reason && check.Reachable != true)
        {
            var why = Ui.Caption(reason);
            why.Foreground = brush;
            text.Children.Add(why);
            _lines.Add(reason);
        }
        row.Children.Add(text);
        Add(row);
    }

    /// <summary>A unified diff, monospaced, with added lines green and removed lines red, in a short scroll view.</summary>
    protected void DiffView(string diff)
    {
        var block = new TextBlock { FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12 };
        var first = true;
        foreach (var line in diff.Split('\n'))
        {
            if (!first) block.Inlines.Add(new LineBreak());
            first = false;
            var run = new Run(line.Length == 0 ? " " : line.TrimEnd('\r'));
            if (line.StartsWith('+')) run.Foreground = Ui.StepBrush(InstallStepStatus.Done);
            else if (line.StartsWith('-')) run.Foreground = Ui.StepBrush(InstallStepStatus.Failed);
            block.Inlines.Add(run);
        }
        var scroll = new ScrollViewer
        {
            Content = block,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            MaxHeight = 180,
            Background = Ui.Card,
            Padding = new Thickness(8),
            Margin = new Thickness(0, 0, 0, 8),
        };
        Add(scroll);
        _lines.Add(diff);
    }
}

// --- create ---

/// <summary>A team profile from one of the benches: the apps, their repositories and branches, and the Frappe version.</summary>
internal sealed class CreateProfileSheet : SheetWindow
{
    private readonly TextBox _name;
    private readonly ComboBox _bench;
    private readonly IReadOnlyList<FoundBench> _benches;

    public CreateProfileSheet(IReadOnlyList<FoundBench> benches, ResolvedTheme theme, Window? owner)
        : base(UiText.Get("ProfileCreateTitle"), UiText.Get("ProfileCreateLine"), theme, owner)
    {
        _benches = benches;
        _name = Ui.Field(UiText.Get("ProfileNameField"), "", _ => Draw(), 360);
        _bench = new ComboBox { Width = 360, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var b in benches) _bench.Items.Add(b.Name + "  (" + b.Path + ")");
        if (benches.Count > 0) _bench.SelectedIndex = 0;
        Ui.Name(_bench, UiText.Get("ProfileFromBench"));
        _bench.SelectionChanged += (_, _) => Draw();
        Fixed.Children.Add(Ui.Labeled(UiText.Get("ProfileNameField"), _name, UiText.Get("ProfileNameHint")));
        Fixed.Children.Add(Ui.Labeled(UiText.Get("ProfileFromBench"), _bench));
        Draw();
    }

    public string ProfileNameText { get => _name.Text; set => _name.Text = value; }

    public string? SelectedBenchPath => _bench.SelectedIndex >= 0 && _bench.SelectedIndex < _benches.Count ? _benches[_bench.SelectedIndex].Path : null;

    internal bool CanCreate => ProfileName.IsValid(_name.Text.Trim()) && SelectedBenchPath is not null;

    private void Draw() => Redraw(() =>
    {
        var name = _name.Text.Trim();
        if (name.Length > 0 && !ProfileName.IsValid(name))
            Failure(UiText.Get("ProfileNameRule"));
        Note(UiText.Get("ProfileCreateNote"));
        Bar(UiText.Get("ProfileCreate"), () => End(true), primary: true, enabled: CanCreate);
        Bar(UiText.Get("Cancel"), () => End(false), cancel: true);
    });
}

// --- import ---

/// <summary>Import: a .toml file (a Windows path is fine) or an https link, reviewed before it is added.</summary>
internal sealed class ImportProfileSheet : SheetWindow
{
    private readonly ProfileImportRun _run;
    private readonly Func<string?> _pickFile;
    private readonly Action<string> _reveal;
    private readonly TextBox _source;
    private readonly TextBox _saveAs;

    public ImportProfileSheet(ProfileImportRun run, ResolvedTheme theme, Window? owner, Func<string?> pickFile, Action<string> reveal, bool autoReview = false)
        : base(UiText.Get("ProfileImportTitle"), UiText.Get("ProfileImportLine"), theme, owner, 640)
    {
        _run = run;
        _pickFile = pickFile;
        _reveal = reveal;
        BusyWhen(() => run.IsBusy);
        _source = Ui.Field(UiText.Get("ProfileSourceField"), run.Source, text => { run.Source = text; Draw(); }, 420);
        var choose = Ui.Button(UiText.Get("ProfileChooseFile"), Choose, UiText.Get("ProfileChooseFileName"), minWidth: 0);
        choose.Margin = new Thickness(8, 0, 0, 0);
        var sourceRow = new StackPanel { Orientation = Orientation.Horizontal };
        sourceRow.Children.Add(_source);
        sourceRow.Children.Add(choose);
        _saveAs = Ui.Field(UiText.Get("ProfileSaveAs"), run.SaveAs, text => { run.SaveAs = text; Draw(); }, 420);
        Fixed.Children.Add(Ui.Labeled(UiText.Get("ProfileSourceField"), sourceRow, UiText.Get("ProfileSourceHint")));
        Fixed.Children.Add(Ui.Labeled(UiText.Get("ProfileSaveAs"), _saveAs, UiText.Get("ProfileSaveAsHint")));
        run.Changed += Draw;
        Draw();
        if (autoReview) Loaded += (_, _) => run.ReviewAsync().Forget();
    }

    internal ProfileImportRun Run => _run;

    private void Choose()
    {
        if (_pickFile() is not { Length: > 0 } file) return;
        _source.Text = file;
        _run.Source = file;
        _run.ReviewAsync().Forget();
    }

    private void Draw()
    {
        Fixed.Visibility = _run.Phase == ProfileRunPhase.Done ? Visibility.Collapsed : Visibility.Visible;
        Redraw(() =>
        {
            if (_run.Phase == ProfileRunPhase.Done && _run.Result is { } done)
            {
                Headline(UiText.Format("ProfileAddedTitle", done.Name), UiText.Format("ProfileAddedLine", done.Name));
                Bar(UiText.Get("ProfileShowInExplorer"), () => _reveal(done.Path), left: true);
                Bar(UiText.Get("ProfileDone"), () => End(true), primary: true);
                return;
            }
            if (_run.TrimmedSource.Length > 0 && !_run.SourceValid) Failure(UiText.Get("ProfileBadSource"));
            if (!_run.NameValid) Failure(UiText.Get("ProfileNameRule"));
            if (_run.Phase == ProfileRunPhase.Loading) Busy(UiText.Get("ProfileReadingBusy"));
            if (_run.Phase == ProfileRunPhase.Running) Busy(UiText.Get("ProfileAdding"));
            if (_run.Phase == ProfileRunPhase.Failed && _run.Error is { } error) Failure(UiText.Format("ProfileImportFailed", error));
            if (_run.Plan is { } plan) Review(plan);
            Note(UiText.Get("ProfileImportNote"));
            Bar(UiText.Get("ProfileReview"), () => _run.ReviewAsync().Forget(), enabled: _run.CanReview, left: true);
            Bar(UiText.Get("Cancel"), () => End(false), cancel: true, enabled: _run.Phase != ProfileRunPhase.Running);
            Bar(_run.Plan?.Exists == true ? UiText.Get("ProfileReplace") : UiText.Get("ProfileAdd"), () => _run.AddAsync().Forget(), primary: true, enabled: _run.CanAdd);
        });
    }

    private void Review(ProfileImportPlan plan)
    {
        Line(UiText.Format("ProfileLineName", plan.Name), 14);
        if (plan.Base is { } b) Line(UiText.Format("ProfileLineBase", b));
        Line(UiText.Format("ProfileLineFrom", plan.Source), 12, 0.8);
        foreach (var app in plan.Apps) RepoRow(app.Branch is { } br ? UiText.Format("ProfileAppAtBranch", app.Name, br) : app.Name, app.Repo, plan.CheckFor(app.Name));
        if (plan.SkippedApps.Count > 0)
        {
            Line(UiText.Format("ProfileLeftOut", string.Join(", ", plan.SkippedApps)),
                12, brush: Ui.StepBrush(InstallStepStatus.Warning));
        }
        if (plan.Exists)
        {
            Line(UiText.Format("ProfileExists", plan.Name), 13);
            DiffView(plan.Diff ?? UiText.Get("ProfileNoDiff"));
        }
    }
}

// --- subscribe ---

/// <summary>Subscribe: adds the profiles in a team's git repository to this machine.</summary>
internal sealed class SubscribeProfilesSheet : SheetWindow
{
    private readonly ProfileSubscribeRun _run;
    private readonly Action<string> _reveal;
    private readonly TextBox _repo;

    public SubscribeProfilesSheet(ProfileSubscribeRun run, ResolvedTheme theme, Window? owner, Action<string> reveal)
        : base(UiText.Get("ProfileSubscribeTitle"), UiText.Get("ProfileSubscribeLine"), theme, owner)
    {
        _run = run;
        _reveal = reveal;
        BusyWhen(() => run.IsBusy);
        _repo = Ui.Field(UiText.Get("ProfileGitField"), run.Repo, text => { run.Repo = text; Draw(); }, 480);
        Fixed.Children.Add(Ui.Labeled(UiText.Get("ProfileGitField"), _repo, UiText.Get("ProfileGitHint")));
        run.Changed += Draw;
        Draw();
    }

    internal ProfileSubscribeRun Run => _run;

    private void Draw()
    {
        Fixed.Visibility = _run.Phase == ProfileRunPhase.Done ? Visibility.Collapsed : Visibility.Visible;
        Redraw(() =>
        {
            if (_run.Phase == ProfileRunPhase.Done && _run.Result is { } done)
            {
                Headline(UiText.Format("ProfileSubscribedTitle", ProfileInfo.ShortRepo(done.Repo)),
                    done.Profiles.Count == 0 ? UiText.Get("ProfileNoProfilesYet") : UiText.Format("ProfileProfilesList", string.Join(", ", done.Profiles)));
                Bar(UiText.Get("ProfileShowInExplorer"), () => _reveal(done.Dir), left: true);
                Bar(UiText.Get("ProfileDone"), () => End(true), primary: true);
                return;
            }
            if (_run.TrimmedRepo.Length > 0 && !ProfileSourceRule.IsGitUrl(_run.TrimmedRepo)) Failure(UiText.Get("ProfileBadGit"));
            if (_run.Phase == ProfileRunPhase.Running) Busy(UiText.Get("ProfileCloning"));
            if (_run.Phase == ProfileRunPhase.Failed && _run.Error is { } error) Failure(UiText.Format("ProfileSubscribeFailed", error));
            Note(UiText.Get("ProfileSubscribeNote"));
            Bar(UiText.Get("Cancel"), () => End(false), cancel: true, enabled: _run.Phase != ProfileRunPhase.Running);
            Bar(UiText.Get("ProfileSubscribe"), () => _run.SubscribeAsync().Forget(), primary: true, enabled: _run.CanSubscribe);
        });
    }
}

// --- export ---

/// <summary>Export: pick the branch each teammate gets and which apps go into the file, then choose where to save it.</summary>
internal sealed class ExportProfileSheet : SheetWindow
{
    private readonly ProfileExportRun _run;
    private readonly Func<string, string?> _pickSave;
    private readonly Action<string> _reveal;
    private readonly Action<string> _copy;
    private readonly StackPanel _rows = new();
    private bool _rowsBuilt;
    private readonly StackPanel _share = new();
    private TextBox _hostedBox = null!;
    private Button _copyButton = null!;
    private bool _copied;

    public ExportProfileSheet(ProfileExportRun run, ResolvedTheme theme, Window? owner, Func<string, string?> pickSave, Action<string> reveal, Action<string> copy)
        : base(UiText.Format("ProfileExportTitle", run.Name), UiText.Get("ProfileExportLine"), theme, owner, 680)
    {
        _run = run;
        _pickSave = pickSave;
        _reveal = reveal;
        _copy = copy;
        BusyWhen(() => run.IsBusy);
        Fixed.Children.Add(_rows);
        BuildShare();
        Fixed.Children.Add(_share);
        run.Changed += Draw;
        Draw();
    }

    internal ProfileExportRun Run => _run;

    internal IReadOnlyList<CheckBox> KeepBoxes => _rows.Children.OfType<Panel>().SelectMany(p => p.Children.OfType<CheckBox>()).ToList();

    internal IReadOnlyList<TextBox> BranchBoxes => _rows.Children.OfType<Panel>().SelectMany(p => p.Children.OfType<TextBox>()).ToList();

    private void Save()
    {
        if (_pickSave($"{_run.Name}.toml") is { Length: > 0 } file) _run.ExportAsync(file).Forget();
    }

    private void BuildRows(ProfileExportPlan plan, ProfileExportChoices choices)
    {
        _rowsBuilt = true;
        _rows.Children.Add(Ui.Text(UiText.Get("ProfileExportPick"), 13, opacity: 0.85, margin: new Thickness(0, 0, 0, 8)));
        foreach (var app in plan.Apps)
        {
            var row = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
            var keep = new CheckBox { IsChecked = choices.Keeps(app.Name), Margin = new Thickness(0, 4, 10, 0), VerticalAlignment = VerticalAlignment.Top };
            Ui.Name(keep, UiText.Format("ProfileKeepName", app.Name), UiText.Format("ProfileKeepHelp", app.Name));
            DockPanel.SetDock(keep, Dock.Left);
            var branch = Ui.Field(UiText.Format("ProfileBranchFor", app.Name), choices.Branch(app), text => { choices.SetBranch(app.Name, text); _run.Touched(); }, 140);
            branch.FontFamily = new FontFamily("Cascadia Mono, Consolas");
            branch.IsEnabled = choices.Keeps(app.Name);
            keep.Click += (_, _) =>
            {
                choices.SetKeep(app.Name, keep.IsChecked == true);
                branch.IsEnabled = keep.IsChecked == true;
                _run.Touched();
            };
            DockPanel.SetDock(branch, Dock.Right);
            var current = Ui.Text(app.CurrentBranch ?? UiText.Get("ProfileDetached"), 12, opacity: 0.7, margin: new Thickness(8, 6, 8, 0));
            DockPanel.SetDock(current, Dock.Right);
            var text = new StackPanel();
            text.Children.Add(Ui.Text(UiText.Format("ProfileAppAccess", app.Name, RepoAccess.Label(app.Access)), 13, FontWeights.SemiBold));
            text.Children.Add(Ui.Caption(app.ExportedRepo));
            if (app.Requires.Count > 0) text.Children.Add(Ui.Caption(UiText.Format("ProfileRequires", string.Join(", ", app.Requires))));
            if (!app.BranchVerified) text.Children.Add(Ui.Caption(UiText.Get("ProfileNotVerified")));
            row.Children.Add(keep);
            row.Children.Add(branch);
            row.Children.Add(current);
            row.Children.Add(text);
            _rows.Children.Add(row);
        }
        foreach (var w in plan.Warnings)
            _rows.Children.Add(Ui.Text(w, 12, margin: new Thickness(0, 0, 0, 4)));
        _rows.Children.Add(Ui.Text(UiText.Get("ProfileAddressNote"), 12, opacity: 0.7, margin: new Thickness(0, 8, 0, 0)));
    }

    private void Draw()
    {
        if (!_rowsBuilt && _run.Plan is { } plan && _run.Choices is { } choices) BuildRows(plan, choices);
        _rows.Visibility = _run.Phase is ProfileRunPhase.Ready or ProfileRunPhase.Running ? Visibility.Visible : Visibility.Collapsed;
        _share.Visibility = _run.Phase == ProfileRunPhase.Done ? Visibility.Visible : Visibility.Collapsed;
        Redraw(() =>
        {
            switch (_run.Phase)
            {
                case ProfileRunPhase.Idle:
                case ProfileRunPhase.Loading:
                    Busy(UiText.Get("ProfileExportBusy"));
                    Bar(UiText.Get("Cancel"), () => End(false), cancel: true);
                    return;
                case ProfileRunPhase.Failed:
                    Failure(UiText.Format("ProfileExportFailed", _run.Name, _run.Error ?? ""));
                    Bar(UiText.Get("ProfileClose"), () => End(false), primary: true);
                    return;
                case ProfileRunPhase.Done when _run.Result is { } result:
                    Headline(result.Apps == 1 ? UiText.Get("ProfileExportedOne") : UiText.Format("ProfileExportedMany", result.Apps), _run.ChosenFile ?? result.Path);
                    if (result.Dropped.Count > 0) Line(UiText.Format("ProfileLeftOutList", string.Join(", ", result.Dropped)));
                    Bar(UiText.Get("ProfileShowInExplorer"), () => _reveal(_run.ChosenFile ?? result.Path), left: true);
                    Bar(UiText.Get("ProfileDone"), () => End(true), primary: true);
                    return;
            }
            if (_run.Phase == ProfileRunPhase.Running) Busy(UiText.Get("ProfileExporting"));
            if (_run.Problem is { } problem) Failure(problem);
            else if (_run.Error is { } error) Failure(error);
            Bar(UiText.Get("Cancel"), () => End(false), cancel: true, enabled: _run.Phase != ProfileRunPhase.Running);
            Bar(UiText.Get("ProfileExport"), Save, primary: true, enabled: _run.CanExport);
        });
    }

    private void BuildShare()
    {
        _share.Children.Add(Ui.Text(UiText.Get("ProfileShareTitle"), 14, FontWeights.SemiBold, margin: new Thickness(0, 12, 0, 2)));
        _share.Children.Add(Ui.Text(UiText.Get("ProfileShareLine"), 12, opacity: 0.75, margin: new Thickness(0, 0, 0, 6)));
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
        _hostedBox = Ui.Field(UiText.Get("ProfileHosted"), "", text => { _copied = false; SyncShare(); }, 400);
        _copyButton = Ui.Button(UiText.Get("ProfileCopyLink"), CopyLink, UiText.Get("ProfileCopyLink"), minWidth: 0);
        _copyButton.Margin = new Thickness(8, 0, 0, 0);
        _copyButton.IsEnabled = false;
        row.Children.Add(_hostedBox);
        row.Children.Add(_copyButton);
        _share.Children.Add(row);
        _share.Visibility = Visibility.Collapsed;
    }

    private string? CurrentLink => ProfileSourceRule.IsImportUrl(_hostedBox.Text) ? ImportLink(_hostedBox.Text) : null;

    private void SyncShare()
    {
        _copyButton.Content = (_copied ? UiText.Get("ProfileCopied") : UiText.Get("ProfileCopyLink"));
        _copyButton.IsEnabled = CurrentLink is not null;
    }

    private void CopyLink()
    {
        if (CurrentLink is not { } link) return;
        _copy(link);
        _copied = true;
        SyncShare();
    }

    internal TextBox HostedBox => _hostedBox;

    internal Button CopyButton => _copyButton;

    /// <summary><c>benchbar://profile/import?url=ENC</c>, to paste into a team chat.</summary>
    internal static string ImportLink(string hostedUrl) => "benchbar://profile/import?url=" + Uri.EscapeDataString(hostedUrl.Trim());
}

// --- update ---

/// <summary>Update: shows what changed in the profile's source, then applies it.</summary>
internal sealed class UpdateProfileSheet : SheetWindow
{
    private readonly ProfileUpdateRun _run;

    public UpdateProfileSheet(ProfileUpdateRun run, ResolvedTheme theme, Window? owner)
        : base(UiText.Format("ProfileUpdateTitle", run.Name), UiText.Get("ProfileUpdateLine"), theme, owner, 680)
    {
        _run = run;
        BusyWhen(() => run.IsBusy);
        run.Changed += Draw;
        Draw();
    }

    internal ProfileUpdateRun Run => _run;

    private void Draw() => Redraw(() =>
    {
        switch (_run.Phase)
        {
            case ProfileRunPhase.Idle:
            case ProfileRunPhase.Loading:
                Busy(UiText.Get("ProfileFetching"));
                Bar(UiText.Get("Cancel"), () => End(false), cancel: true);
                return;
            case ProfileRunPhase.Failed:
                Failure(UiText.Format("ProfileUpdateFailed", _run.Name, _run.Error ?? ""));
                Bar(UiText.Get("ProfileClose"), () => End(false), primary: true);
                return;
            case ProfileRunPhase.Done:
                Headline(UiText.Format("ProfileUpdatedTitle", _run.Name));
                Bar(UiText.Get("ProfileDone"), () => End(true), primary: true);
                return;
        }
        if (_run.Plan is { HasChanges: false })
        {
            Headline(UiText.Format("ProfileUpToDate", _run.Name), UiText.Get("ProfileNothingToChange"));
            Bar(UiText.Get("ProfileClose"), () => End(false), primary: true);
            return;
        }
        if (_run.Phase == ProfileRunPhase.Running) Busy(UiText.Get("ProfileUpdating"));
        foreach (var update in _run.Plan?.Updates ?? [])
        {
            var title = update.Behind is > 0
                ? update.Behind == 1 ? UiText.Format("ProfileUpdateBehindOne", update.Name, update.Kind) : UiText.Format("ProfileUpdateBehindMany", update.Name, update.Kind, update.Behind)
                : UiText.Format("ProfileUpdateKind", update.Name, update.Kind);
            Line(title, 14, margin: new Thickness(0, 0, 0, 4)).FontWeight = FontWeights.SemiBold;
            if (update.Diff is { Length: > 0 } diff) DiffView(diff);
        }
        Bar(UiText.Get("Cancel"), () => End(false), cancel: true, enabled: _run.Phase != ProfileRunPhase.Running);
        Bar(UiText.Get("ProfileUpdate"), () => _run.ApplyAsync().Forget(), primary: true, enabled: _run.CanApply);
    });
}

// --- check access ---

/// <summary>Check Access: tries each repository of the profile with your git credentials.</summary>
internal sealed class CheckAccessSheet : SheetWindow
{
    private readonly ProfileCheckRun _run;

    public CheckAccessSheet(ProfileCheckRun run, ResolvedTheme theme, Window? owner)
        : base(UiText.Format("ProfileCheckTitle", run.Name), UiText.Get("ProfileCheckLine"), theme, owner)
    {
        _run = run;
        BusyWhen(() => run.IsBusy);
        run.Changed += Draw;
        Draw();
    }

    internal ProfileCheckRun Run => _run;

    private void Draw() => Redraw(() =>
    {
        switch (_run.Phase)
        {
            case ProfileRunPhase.Idle:
            case ProfileRunPhase.Loading:
                Busy(UiText.Get("ProfileCheckBusy"));
                break;
            case ProfileRunPhase.Failed:
                Failure(UiText.Format("ProfileCheckFailed", _run.Error ?? ""));
                break;
            default:
                if (_run.Check is { } check)
                {
                    var (warning, title, detail) = check.Verdict();
                    Headline(title, detail, warning);
                    foreach (var repo in check.Repos) RepoRow(repo.App, repo.Repo, repo);
                }
                break;
        }
        Bar(UiText.Get("ProfileCheckAgain"), () => _run.LoadAsync().Forget(), enabled: !_run.IsBusy, left: true);
        Bar(UiText.Get("ProfileDone"), () => End(true), primary: true);
    });
}
