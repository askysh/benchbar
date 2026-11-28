using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// The banner of the bench page for an app update or app add that stopped part way (<c>status --json</c> <c>pending_operations</c>,
/// the Mac app's unfinished operations). It says what stopped and why, shows the CLI's fix line, and offers the CLI's two ways out:
/// run the same command again (the plan lists only the steps left) or <c>app update NAME --discard-pending</c>, which drops the record
/// and runs nothing, after a question. Rebuilt only when the records change, so a poll does not touch a button under the pointer.
/// </summary>
internal sealed class PendingBanner : UserControl
{
    private readonly PageServices _services;
    private readonly StackPanel _root = new();
    private string _key = "";
    private string? _bench;
    private IReadOnlyList<PendingOperation> _operations = [];
    private string? _message;
    private bool _messageIsError;
    private bool _busy;

    public PendingBanner(PageServices services)
    {
        _services = services;
        Content = _root;
        Visibility = Visibility.Collapsed;
        Ui.Name(this, UiText.Get("PendingName"));
    }

    /// <summary>The run behind the last click, for tests.</summary>
    internal Task Pending { get; private set; } = Task.CompletedTask;

    internal IReadOnlyList<PendingOperation> Operations => _operations;

    internal string? Message => _message;

    public void Bind(BenchStatus bench)
    {
        var key = bench.Path + "|" + string.Join('|', bench.PendingOperations.Select(o => $"{o.Key}\t{o.FailedStep}\t{o.Reason}\t{o.Steps.Count}\t{o.UpdatedAt}"));
        if (key == _key) return;
        if (_bench != bench.Path) _message = null; // a result belongs to the bench it came from
        _bench = bench.Path;
        _key = key;
        _operations = bench.PendingOperations;
        Rebuild();
    }

    private void Rebuild()
    {
        _root.Children.Clear();
        if (_operations.Count == 0 && _message is null)
        {
            Visibility = Visibility.Collapsed;
            return;
        }
        Visibility = Visibility.Visible;
        var bench = _bench ?? "";
        foreach (var op in _operations)
        {
            var card = new StackPanel();
            card.Children.Add(Ui.Text(UiText.Format("PendingUnfinished", op.Command), 14, FontWeights.SemiBold, margin: new Thickness(0, 0, 0, 2)));
            card.Children.Add(Ui.Text(op.Message, 13, opacity: 0.9));
            if (op.Steps.Count > 0)
                card.Children.Add(Ui.Text(UiText.Format("PendingLeft", string.Join(", ", op.Steps.Select(s => s.Target.Length > 0 ? UiText.Format("PendingStepTarget", s.Name, s.Target) : s.Name))), 12, opacity: 0.75, margin: new Thickness(0, 2, 0, 0)));
            var fix = Ui.Mono(op.FixLine(bench));
            fix.Margin = new Thickness(0, 6, 0, 0);
            card.Children.Add(fix);
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
            var captured = op;
            if (op.CanResume)
            {
                var resume = Ui.Button(op.ResumeLabel, () => Pending = ResumeAsync(captured, bench), UiText.Format("PendingResumeName", op.ResumeLabel, op.App), primary: true);
                resume.IsEnabled = !_busy;
                buttons.Children.Add(resume);
            }
            var discard = Ui.Button(UiText.Get("PendingDiscard"), () => Pending = DiscardAsync(captured, bench), UiText.Format("PendingDiscardName", op.Command, op.App));
            discard.IsEnabled = !_busy;
            buttons.Children.Add(discard);
            card.Children.Add(buttons);
            _root.Children.Add(Ui.CardOf(card, new Thickness(0, 0, 0, 8)));
        }
        if (_message is { Length: > 0 } text) _root.Children.Add(Ui.Text(text, 13, opacity: _messageIsError ? 1 : 0.85, margin: new Thickness(0, 0, 0, 8)));
    }

    /// <summary>The plan of the same command, shown in the plan sheet: the CLI lists only the steps that are left.</summary>
    internal async Task ResumeAsync(PendingOperation op, string bench)
    {
        var request = op.IsAdd
            ? PlanReviewRequest.Tokened(UiText.Format("PendingFinishAddTitle", op.App), AppCommands.ResumeAdd(op.App, bench)) with
            {
                ConfirmLabel = UiText.Get("PendingFinishAdd"),
                Summary = UiText.Get("PendingFinishAddSummary"),
                Describe = AppAddBatch.PlanLines,
            }
            : new PlanReviewRequest(UiText.Format("PendingFinishUpdateTitle", op.App), AppCommands.ResumeUpdatePlan(op.App, bench), _ => AppCommands.Update(op.App, bench))
            {
                ConfirmLabel = UiText.Get("PendingFinishUpdate"),
                RequiresToken = false,
                Summary = UiText.Get("PendingFinishUpdateSummary"),
            };
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
        if (outcome.Applied) _services.RefreshNow();
    }

    /// <summary>Asks first, then runs <c>app update NAME --discard-pending</c>. The record goes; the app stays as it is and no step runs.</summary>
    internal async Task DiscardAsync(PendingOperation op, string bench)
    {
        var left = op.Steps.Count == 1 ? UiText.Get("PendingStepOne") : UiText.Format("PendingStepMany", op.Steps.Count);
        var question = UiText.Format("PendingDiscardQuestion", op.Command, op.App, left);
        if (!_services.Confirm(UiText.Format("PendingDiscardTitle", op.Command), question, UiText.Get("PendingDiscardConfirm"))) return;
        _busy = true;
        Rebuild();
        var r = await _services.Cli.RunStreamAsync(AppCommands.DiscardPending(op.App, bench), null, CliTimeouts.Read, _ => { });
        _busy = false;
        PagePanels.OnUi(this, () =>
        {
            Say(r.Ok ? UiText.Format("PendingDiscarded", op.Command, op.App) : r.Problem ?? UiText.Format("PendingFailed", r.Exit), !r.Ok);
            if (r.Ok) _operations = _operations.Where(o => o.Key != op.Key).ToList();
            Rebuild();
            if (r.Ok) _services.RefreshNow();
        });
    }

    private void Say(string? text, bool error)
    {
        _message = text;
        _messageIsError = error;
    }
}
