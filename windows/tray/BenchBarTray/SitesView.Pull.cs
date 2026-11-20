using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// Pull in the Sites tab (macos PullSheet): copy a production site over SSH, or a backup folder, into a new site. The form takes the source
/// and the new name; Review Plan runs <c>pull ... --dry-run --json</c> in the plan sheet, which shows the backup, the apps that differ and
/// what the copy loses, and Pull runs <c>--apply TOKEN --yes --jsonl</c> with the token of that plan. The copy is neutralised unless the box
/// is ticked, and ticking it says what that means. Offered only when the CLI lists <c>pull</c> with <c>--apply</c> (an older one has no token).
/// </summary>
internal sealed partial class SitesView
{
    private CheckBox? _pullFolder;
    private TextBox? _pullSource;
    private TextBox? _pullName;
    private CheckBox? _pullKeep;
    private TextBlock? _pullProblem;
    private TextBlock? _pullKeepNote;
    private string _pullAutoName = "";

    /// <summary>
    /// Whether the Pull button is offered: the CLI lists <c>pull</c> with <c>--apply</c> (an older one has no plan token). Null until the
    /// catalogue was read; the bench page asks for it, this tab only reads what is there, so it starts no call of its own.
    /// </summary>
    internal bool? PullAvailable => _services.Commands.Current?.HasFlag("pull", "--apply");

    /// <summary>The boxes of the open Pull form (for tests); null when it is not open.</summary>
    internal (CheckBox FromFolder, TextBox Source, TextBox Name, CheckBox KeepSecrets)? PullForm =>
        _pullFolder is not null && _pullSource is not null && _pullName is not null && _pullKeep is not null ? (_pullFolder, _pullSource, _pullName, _pullKeep) : null;

    internal string? PullProblemText => _pullProblem is { Visibility: Visibility.Visible } p ? p.Text : null;

    /// <summary>The note under the keep secrets box: what the copy loses, or the warning when the box is ticked (for tests).</summary>
    internal string? PullKeepNoteText => _pullKeepNote?.Text;

    internal void OpenPull()
    {
        _pullFolder = new CheckBox { Content = "Copy from a backup folder inside Ubuntu instead of a server", Margin = new Thickness(0, 0, 0, 10) };
        Ui.Name(_pullFolder, "From a backup folder");
        _pullSource = Ui.Field("Host and site", "", _ => PullSourceChanged(), 420);
        _pullName = Ui.Field("New local site", "", _ => HidePullProblem(), 360);
        _pullKeep = new CheckBox { Content = "Keep production's passwords and integrations", Margin = new Thickness(0, 0, 0, 4) };
        Ui.Name(_pullKeep, "Keep production's passwords and integrations");
        _pullProblem = PagePanels.Line("", error: true);
        _pullProblem.Visibility = Visibility.Collapsed;
        _pullKeepNote = Ui.Text(PullCommands.NeutralisedText, 12, opacity: 0.8, margin: new Thickness(0, 0, 0, 10));
        _pullFolder.Click += (_, _) => PullSourceKindChanged();
        _pullKeep.Click += (_, _) => PullKeepChanged();
        _pullAutoName = "";
        var panel = PagePanels.Panel($"Pull a site into {Bench.Name}",
            "Copies a production site, or a backup you downloaded, into a new site of this bench. Production is only read. You see the plan first.",
            [_pullFolder, Ui.Labeled("Host and site", _pullSource, "HOST is a Host of ~/.ssh/config inside Ubuntu, and its key must work without a prompt. The latest backup on the server is used and nothing is written there."),
             Ui.Labeled("New local site", _pullName, "Names that end in .localhost open in your browser without any setup."), _pullKeep, _pullKeepNote, _pullProblem],
            [Ui.Button("Review Plan...", () => Start(PullAsync), primary: true), Ui.Button("Cancel", ClosePanel)]);
        SetPanel(panel);
        _pullSource.Focus();
    }

    private void PullSourceChanged()
    {
        HidePullProblem();
        if (_pullName is null || _pullSource is null || _pullFolder?.IsChecked == true) return;
        // the name follows the host until it is typed over
        if (_pullName.Text.Length == 0 || _pullName.Text == _pullAutoName)
        {
            _pullAutoName = PullCommands.DefaultName(_pullSource.Text);
            _pullName.Text = _pullAutoName;
        }
    }

    private void PullSourceKindChanged()
    {
        if (_pullSource is null) return;
        _pullSource.Text = "";
        if (_pullName is not null && _pullName.Text == _pullAutoName) _pullName.Text = "";
        _pullAutoName = "";
        HidePullProblem();
        Ui.Name(_pullSource, _pullFolder?.IsChecked == true ? "Backup folder" : "Host and site");
    }

    private void PullKeepChanged()
    {
        if (_pullKeepNote is null || _pullKeep is null) return;
        var keep = _pullKeep.IsChecked == true;
        _pullKeepNote.Text = keep
            ? "Warning: " + PullCommands.KeptText + " Do not start its scheduler or workers unless you mean to reach the same services as production."
            : PullCommands.NeutralisedText;
        _pullKeepNote.Opacity = 1;
        if (keep) _pullKeepNote.Foreground = Ui.CautionTextBrush;
        else _pullKeepNote.ClearValue(TextBlock.ForegroundProperty);
    }

    private void HidePullProblem()
    {
        if (_pullProblem is not null) _pullProblem.Visibility = Visibility.Collapsed;
    }

    internal async Task PullAsync()
    {
        if (_pullSource is null || _pullName is null || _pullKeep is null || _pullFolder is null) return;
        var input = new PullInput(_pullSource.Text.Trim(), _pullFolder.IsChecked == true, _pullName.Text.Trim(), _pullKeep.IsChecked == true);
        if (PullCommands.Problem(input, Rows.Select(r => r.Name)) is { } problem)
        {
            if (_pullProblem is not null)
            {
                _pullProblem.Text = problem;
                _pullProblem.Visibility = Visibility.Visible;
            }
            return;
        }
        if (PanelIsStale) return;
        var benchPath = PanelBench;
        var request = PullCommands.Review(input, benchPath);
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
                Say($"{input.Name} was pulled.", false);
                _services.RefreshNow();
            }
            Rebuild();
        });
    }
}
