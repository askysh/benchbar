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
        Ui.Name(mark, $"{app}: {check?.Accessibility ?? "not checked"}");
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
        : base("Create a Team Profile", "Writes a profile from one bench's apps, branches and Frappe version.", theme, owner)
    {
        _benches = benches;
        _name = Ui.Field("Profile name", "", _ => Draw(), 360);
        _bench = new ComboBox { Width = 360, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var b in benches) _bench.Items.Add(b.Name + "  (" + b.Path + ")");
        if (benches.Count > 0) _bench.SelectedIndex = 0;
        Ui.Name(_bench, "From bench");
        _bench.SelectionChanged += (_, _) => Draw();
        Fixed.Children.Add(Ui.Labeled("Profile name", _name, "For example acme"));
        Fixed.Children.Add(Ui.Labeled("From bench", _bench));
        Draw();
    }

    public string ProfileNameText { get => _name.Text; set => _name.Text = value; }

    public string? SelectedBenchPath => _bench.SelectedIndex >= 0 && _bench.SelectedIndex < _benches.Count ? _benches[_bench.SelectedIndex].Path : null;

    internal bool CanCreate => ProfileName.IsValid(_name.Text.Trim()) && SelectedBenchPath is not null;

    private void Draw() => Redraw(() =>
    {
        var name = _name.Text.Trim();
        if (name.Length > 0 && !ProfileName.IsValid(name))
            Failure("Lower case letters, digits, '.', '_' or '-', starting with a letter or digit.");
        Note("BenchBar reads the bench (its apps, their repositories and branches, and its Frappe version) and writes ~/.config/benchbar/profiles/NAME.toml. The bench is not changed; no site data or password goes into the file.");
        Bar("Create", () => End(true), primary: true, enabled: CanCreate);
        Bar("Cancel", () => End(false), cancel: true);
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
        : base("Import a Profile", "Adds a profile from a .toml file or an https link, after you review it.", theme, owner, 640)
    {
        _run = run;
        _pickFile = pickFile;
        _reveal = reveal;
        BusyWhen(() => run.IsBusy);
        _source = Ui.Field("File or https URL", run.Source, text => { run.Source = text; Draw(); }, 420);
        var choose = Ui.Button("Choose File...", Choose, "Choose File", minWidth: 0);
        choose.Margin = new Thickness(8, 0, 0, 0);
        var sourceRow = new StackPanel { Orientation = Orientation.Horizontal };
        sourceRow.Children.Add(_source);
        sourceRow.Children.Add(choose);
        _saveAs = Ui.Field("Save as", run.SaveAs, text => { run.SaveAs = text; Draw(); }, 420);
        Fixed.Children.Add(Ui.Labeled("File or https URL", sourceRow, @"A .toml file on this PC (C:\Users\you\acme.toml) or in Linux (/home/you/acme.toml), or an https link."));
        Fixed.Children.Add(Ui.Labeled("Save as", _saveAs, "Optional: the name in the file."));
        run.Changed += Draw;
        Draw();
        if (autoReview) Loaded += (_, _) => _ = run.ReviewAsync();
    }

    internal ProfileImportRun Run => _run;

    private void Choose()
    {
        if (_pickFile() is not { Length: > 0 } file) return;
        _source.Text = file;
        _run.Source = file;
        _ = _run.ReviewAsync();
    }

    private void Draw()
    {
        Fixed.Visibility = _run.Phase == ProfileRunPhase.Done ? Visibility.Collapsed : Visibility.Visible;
        Redraw(() =>
        {
            if (_run.Phase == ProfileRunPhase.Done && _run.Result is { } done)
            {
                Headline($"Added {done.Name}", $"Set up a bench from it with benchbar install --profile {done.Name}.");
                Bar("Show in Explorer", () => _reveal(done.Path), left: true);
                Bar("Done", () => End(true), primary: true);
                return;
            }
            if (_run.TrimmedSource.Length > 0 && !_run.SourceValid) Failure("Use a .toml file on this PC or in Linux, or an https URL.");
            if (!_run.NameValid) Failure("Lower case letters, digits, '.', '_' or '-', starting with a letter or digit.");
            if (_run.Phase == ProfileRunPhase.Loading) Busy("Reading the profile and checking its repositories...");
            if (_run.Phase == ProfileRunPhase.Running) Busy("Adding the profile...");
            if (_run.Phase == ProfileRunPhase.Failed && _run.Error is { } error) Failure("The profile was not imported. " + error);
            if (_run.Plan is { } plan) Review(plan);
            Note("BenchBar reads the file, checks that it parses and whether this machine can reach each repository, and shows it before anything is saved. Nothing is installed from here.");
            Bar("Review", () => _ = _run.ReviewAsync(), enabled: _run.CanReview, left: true);
            Bar("Cancel", () => End(false), cancel: true, enabled: _run.Phase != ProfileRunPhase.Running);
            Bar(_run.Plan?.Exists == true ? "Replace Profile" : "Add Profile", () => _ = _run.AddAsync(), primary: true, enabled: _run.CanAdd);
        });
    }

    private void Review(ProfileImportPlan plan)
    {
        Line($"Profile: {plan.Name}", 14);
        if (plan.Base is { } b) Line($"Based on: {b}");
        Line($"From: {plan.Source}", 12, 0.8);
        foreach (var app in plan.Apps) RepoRow(app.Name + (app.Branch is { } br ? " @ " + br : ""), app.Repo, plan.CheckFor(app.Name));
        if (plan.SkippedApps.Count > 0)
        {
            Line("Left out when a bench is set up from it, because this machine cannot read their repository or they require an app that is left out: " + string.Join(", ", plan.SkippedApps) + ".",
                12, brush: Ui.StepBrush(InstallStepStatus.Warning));
        }
        if (plan.Exists)
        {
            Line($"A profile named {plan.Name} exists. Adding this one replaces it:", 13);
            DiffView(plan.Diff ?? "(no difference)");
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
        : base("Subscribe to a Team's Profiles", "Adds the profiles in a team's git repository to this machine.", theme, owner)
    {
        _run = run;
        _reveal = reveal;
        BusyWhen(() => run.IsBusy);
        _repo = Ui.Field("Git repository", run.Repo, text => { run.Repo = text; Draw(); }, 480);
        Fixed.Children.Add(Ui.Labeled("Git repository", _repo, "For example git@github.com:acme/benchbar-profiles.git"));
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
                Headline($"Subscribed to {ProfileInfo.ShortRepo(done.Repo)}",
                    done.Profiles.Count == 0 ? "The repository has no profile yet." : "Profiles: " + string.Join(", ", done.Profiles) + ".");
                Bar("Show in Explorer", () => _reveal(done.Dir), left: true);
                Bar("Done", () => End(true), primary: true);
                return;
            }
            if (_run.TrimmedRepo.Length > 0 && !ProfileSourceRule.IsGitUrl(_run.TrimmedRepo)) Failure("Use an https, ssh or git@host:owner/repo URL.");
            if (_run.Phase == ProfileRunPhase.Running) Busy("Cloning...");
            if (_run.Phase == ProfileRunPhase.Failed && _run.Error is { } error) Failure("The repository was not added. " + error);
            Note("BenchBar clones the repository into ~/.config/benchbar/sources with your own git credentials and reads only its .toml files; no code from it runs. It never updates on its own: the list shows when it is behind, and Update shows the changes first.");
            Bar("Cancel", () => End(false), cancel: true, enabled: _run.Phase != ProfileRunPhase.Running);
            Bar("Subscribe", () => _ = _run.SubscribeAsync(), primary: true, enabled: _run.CanSubscribe);
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
        : base($"Export {run.Name}", "Writes a profile file your team can import, with the branch each app is shared on.", theme, owner, 680)
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
        if (_pickSave($"{_run.Name}.toml") is { Length: > 0 } file) _ = _run.ExportAsync(file);
    }

    private void BuildRows(ProfileExportPlan plan, ProfileExportChoices choices)
    {
        _rowsBuilt = true;
        _rows.Children.Add(Ui.Text("Pick the branch each teammate gets, and which apps go into the file.", 13, opacity: 0.85, margin: new Thickness(0, 0, 0, 8)));
        foreach (var app in plan.Apps)
        {
            var row = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
            var keep = new CheckBox { IsChecked = choices.Keeps(app.Name), Margin = new Thickness(0, 4, 10, 0), VerticalAlignment = VerticalAlignment.Top };
            Ui.Name(keep, $"Keep {app.Name}", $"Put {app.Name} in the file");
            DockPanel.SetDock(keep, Dock.Left);
            var branch = Ui.Field($"Branch for {app.Name}", choices.Branch(app), text => { choices.SetBranch(app.Name, text); _run.Touched(); }, 140);
            branch.FontFamily = new FontFamily("Cascadia Mono, Consolas");
            branch.IsEnabled = choices.Keeps(app.Name);
            keep.Click += (_, _) =>
            {
                choices.SetKeep(app.Name, keep.IsChecked == true);
                branch.IsEnabled = keep.IsChecked == true;
                _run.Touched();
            };
            DockPanel.SetDock(branch, Dock.Right);
            var current = Ui.Text(app.CurrentBranch ?? "detached", 12, opacity: 0.7, margin: new Thickness(8, 6, 8, 0));
            DockPanel.SetDock(current, Dock.Right);
            var text = new StackPanel();
            text.Children.Add(Ui.Text($"{app.Name}  ·  {RepoAccess.Label(app.Access)}", 13, FontWeights.SemiBold));
            text.Children.Add(Ui.Caption(app.ExportedRepo));
            if (app.Requires.Count > 0) text.Children.Add(Ui.Caption("requires " + string.Join(", ", app.Requires)));
            if (!app.BranchVerified) text.Children.Add(Ui.Caption("Not verified on the remote"));
            row.Children.Add(keep);
            row.Children.Add(branch);
            row.Children.Add(current);
            row.Children.Add(text);
            _rows.Children.Add(row);
        }
        foreach (var w in plan.Warnings)
            _rows.Children.Add(Ui.Text(w, 12, margin: new Thickness(0, 0, 0, 4)));
        _rows.Children.Add(Ui.Text("Repository addresses are written without your SSH host aliases or any login.", 12, opacity: 0.7, margin: new Thickness(0, 8, 0, 0)));
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
                    Busy("Asking each repository for its default branch and access...");
                    Bar("Cancel", () => End(false), cancel: true);
                    return;
                case ProfileRunPhase.Failed:
                    Failure($"{_run.Name} was not exported. {_run.Error}");
                    Bar("Close", () => End(false), primary: true);
                    return;
                case ProfileRunPhase.Done when _run.Result is { } result:
                    Headline($"Exported {result.Apps} app{(result.Apps == 1 ? "" : "s")}", _run.ChosenFile ?? result.Path);
                    if (result.Dropped.Count > 0) Line("Left out: " + string.Join(", ", result.Dropped));
                    Bar("Show in Explorer", () => _reveal(_run.ChosenFile ?? result.Path), left: true);
                    Bar("Done", () => End(true), primary: true);
                    return;
            }
            if (_run.Phase == ProfileRunPhase.Running) Busy("Exporting...");
            if (_run.Problem is { } problem) Failure(problem);
            else if (_run.Error is { } error) Failure(error);
            Bar("Cancel", () => End(false), cancel: true, enabled: _run.Phase != ProfileRunPhase.Running);
            Bar("Export...", Save, primary: true, enabled: _run.CanExport);
        });
    }

    private void BuildShare()
    {
        _share.Children.Add(Ui.Text("Share an import link", 14, FontWeights.SemiBold, margin: new Thickness(0, 12, 0, 2)));
        _share.Children.Add(Ui.Text("Put the file where your team can read it over https (a repository, a gist), then paste its address here. Teammates click the link and review the profile before BenchBar adds it.", 12, opacity: 0.75, margin: new Thickness(0, 0, 0, 6)));
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
        _hostedBox = Ui.Field("Hosted file", "", text => { _copied = false; SyncShare(); }, 400);
        _copyButton = Ui.Button("Copy Import Link", CopyLink, "Copy Import Link", minWidth: 0);
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
        _copyButton.Content = _copied ? "Copied" : "Copy Import Link";
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
        : base($"Update {run.Name}", "Shows what changed in the profile's source, then applies it.", theme, owner, 680)
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
                Busy("Fetching the source...");
                Bar("Cancel", () => End(false), cancel: true);
                return;
            case ProfileRunPhase.Failed:
                Failure($"{_run.Name} was not updated. {_run.Error}");
                Bar("Close", () => End(false), primary: true);
                return;
            case ProfileRunPhase.Done:
                Headline($"Updated {_run.Name}");
                Bar("Done", () => End(true), primary: true);
                return;
        }
        if (_run.Plan is { HasChanges: false })
        {
            Headline($"{_run.Name} is up to date", "Nothing to change.");
            Bar("Close", () => End(false), primary: true);
            return;
        }
        if (_run.Phase == ProfileRunPhase.Running) Busy("Updating...");
        foreach (var update in _run.Plan?.Updates ?? [])
        {
            var title = $"{update.Name}  ·  {update.Kind}" + (update.Behind is > 0 ? $"  ·  {update.Behind} commit{(update.Behind == 1 ? "" : "s")} behind" : "");
            Line(title, 14, margin: new Thickness(0, 0, 0, 4)).FontWeight = FontWeights.SemiBold;
            if (update.Diff is { Length: > 0 } diff) DiffView(diff);
        }
        Bar("Cancel", () => End(false), cancel: true, enabled: _run.Phase != ProfileRunPhase.Running);
        Bar("Update", () => _ = _run.ApplyAsync(), primary: true, enabled: _run.CanApply);
    });
}

// --- check access ---

/// <summary>Check Access: tries each repository of the profile with your git credentials.</summary>
internal sealed class CheckAccessSheet : SheetWindow
{
    private readonly ProfileCheckRun _run;

    public CheckAccessSheet(ProfileCheckRun run, ResolvedTheme theme, Window? owner)
        : base($"Check Access to {run.Name}", "Tries each repository of the profile with your git credentials.", theme, owner)
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
                Busy("Trying each repository with your git credentials...");
                break;
            case ProfileRunPhase.Failed:
                Failure("Access was not checked. " + _run.Error);
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
        Bar("Check Again", () => _ = _run.LoadAsync(), enabled: !_run.IsBusy, left: true);
        Bar("Done", () => End(true), primary: true);
    });
}
