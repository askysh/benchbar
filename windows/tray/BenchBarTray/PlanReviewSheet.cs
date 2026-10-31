using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// The plan review sheet (macos PlanReviewFlow): a modal window that shows a plan from a <c>--dry-run --json</c> call, runs the apply
/// when confirmed, and shows the result. It only draws <see cref="PlanReviewModel"/>. While the apply runs the frame cannot be closed;
/// Stop Waiting is always there and closes the sheet while the run goes on (a notification says how it ended), and Stop is added only
/// when the request says the run is safe to kill. Open it with <see cref="PageServices.ReviewPlan"/>.
/// </summary>
internal sealed class PlanReviewSheet : Window
{
    private readonly PlanReviewModel _model;
    private readonly Action<string> _copy;
    private readonly Action<string, string?> _report;
    private readonly Action<string>? _onDetachedFinish;
    private readonly TextBlock _live = Ui.Live(Ui.Text("", 12, opacity: 0.7, margin: new Thickness(0, 8, 0, 0)));
    private TextBlock? _elapsedText;
    private bool _leaving;
    private readonly ContentControl _body = new() { IsTabStop = false };
    private readonly System.Windows.Threading.DispatcherTimer _clock = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly StackPanel _bar = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };

    public PlanReviewSheet(PlanReviewModel model, ResolvedTheme theme, Window? owner, Action<string> copy, bool load = true,
        Action<string, string?>? report = null, Action<string>? onDetachedFinish = null)
    {
        _model = model;
        _copy = copy;
        _report = report ?? ((_, _) => { });
        _onDetachedFinish = onDetachedFinish;
        Title = model.Request.Title;
        Width = 600;
        MaxHeight = 760;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = owner is null;
        Owner = owner;
        WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;
        Ui.ApplyTheme(this, theme);
        Ui.Name(this, model.Request.Title);

        var grid = new Grid { Margin = new Thickness(24) };
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Auto) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var scroll = new ScrollViewer { Content = _body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = 600 };
        _live.Visibility = Visibility.Collapsed;
        Grid.SetRow(scroll, 0);
        Grid.SetRow(_live, 1);
        Grid.SetRow(_bar, 2);
        grid.Children.Add(scroll);
        grid.Children.Add(_live);
        grid.Children.Add(_bar);
        Content = grid;

        model.Changed += OnChanged;
        // the clock only moves the elapsed time: rebuilding the sheet every second took the focus off its button
        _clock.Tick += (_, _) => { if (_elapsedText is not null) _elapsedText.Text = ElapsedLine(); };
        Closing += (_, e) =>
        {
            if (!_model.IsDismissible && !_leaving) e.Cancel = true;
        };
        Closed += (_, _) =>
        {
            model.Changed -= OnChanged;
            _clock.Stop();
            model.Dispose();
        };
        Rebuild();
        if (load) Loaded += (_, _) => model.LoadAsync().Forget();
    }

    public PlanReviewModel Model => _model;

    /// <summary>The labels of the buttons in the bar, left to right (for tests).</summary>
    public IReadOnlyList<string> ButtonLabels { get; private set; } = [];

    /// <summary>Every line of text in the body, in order (for tests).</summary>
    public IReadOnlyList<string> Lines { get; private set; } = [];

    /// <summary>Opens the sheet over the owner window and returns what it ended with.</summary>
    public static Task<PlanOutcome> ReviewAsync(PlanReviewRequest request, PageServices services)
    {
        var model = new PlanReviewModel(request, services.Cli) { AskLinuxPassword = services.AskLinuxPassword };
        var sheet = new PlanReviewSheet(model, services.Theme(), services.Owner(), services.CopyText, report: services.ReportBug, onDetachedFinish: line =>
        {
            services.RunEnded();
            services.Notify(line);
            services.RefreshNow();
        });
        sheet.Closing += (_, _) => { if (sheet._leaving) services.RunStarted(); }; // the window asks before it closes while this goes on
        sheet.ShowDialog();
        var outcome = model.Outcome;
        if (outcome.Applied || outcome.Done is not null) services.RefreshNow();
        return Task.FromResult(outcome);
    }

    /// <summary>The model may raise from the thread of a running command; the sheet draws on its own thread.</summary>
    private void OnChanged()
    {
        if (Dispatcher.CheckAccess()) Rebuild();
        else Dispatcher.BeginInvoke(Rebuild);
    }

    /// <summary>Stop Waiting: the sheet goes, the run does not. How it ends comes as a notification.</summary>
    private void StopWaiting()
    {
        if (!_model.CanStopWaiting) return;
        _model.Detach(line => _onDetachedFinish?.Invoke(line));
        _leaving = true;
        Close();
    }

    private string ElapsedLine()
    {
        var elapsed = _model.Elapsed;
        return $"Running for {(int)elapsed.TotalMinutes}:{elapsed.Seconds:00}";
    }

    private void Rebuild()
    {
        var focused = Ui.FocusedName(this);
        _elapsedText = null;
        var panel = new StackPanel { Width = 550 };
        var buttons = new List<(string Label, Action Click, bool Primary, bool Enabled)>();
        var plan = _model.Plan;
        switch (_model.Phase)
        {
            case PlanPhase.Loading:
                panel.Children.Add(Ui.Text(_model.Request.Title, 18, FontWeights.SemiBold));
                panel.Children.Add(Ui.Text("Reading the plan...", 14, opacity: 0.75, margin: new Thickness(0, 8, 0, 0)));
                buttons.Add(("Cancel", Close, false, true));
                break;
            case PlanPhase.PlanFailed:
                panel.Children.Add(Ui.Text("There is no plan", 18, FontWeights.SemiBold));
                panel.Children.Add(Ui.CriticalText(_model.Message ?? "The plan could not be made."));
                panel.Children.Add(ReportLink(_model.Message ?? "The plan could not be made."));
                buttons.Add(("Refresh Plan", () => _model.RefreshPlanAsync().Forget(), true, true));
                buttons.Add(("Close", Close, false, true));
                break;
            case PlanPhase.Stale:
                panel.Children.Add(Ui.Text("The plan is out of date", 18, FontWeights.SemiBold));
                panel.Children.Add(Ui.Text("Something changed since you reviewed it. Nothing was changed. Read the plan again before you apply it.", 14, opacity: 0.85, margin: new Thickness(0, 8, 0, 0)));
                buttons.Add(("Refresh Plan", () => _model.RefreshPlanAsync().Forget(), true, true));
                buttons.Add(("Close", Close, false, true));
                break;
            case PlanPhase.Review when plan is not null:
                BuildReview(panel, plan);
                buttons.Add((_model.Request.ConfirmLabel, () => _model.ConfirmAsync().Forget(), true, _model.CanConfirm));
                buttons.Add(("Cancel", Close, false, true));
                break;
            case PlanPhase.Running:
                BuildRunning(panel);
                // always a way out: the run is not cancelled, the sheet just stops waiting for it
                buttons.Add(("Stop Waiting", StopWaiting, false, true));
                if (_model.CanStop) buttons.Add(("Stop", _model.Stop, false, true));
                break;
            case PlanPhase.Finished when _model.Result is { } result:
                BuildResult(panel, result);
                if (!result.Ok && !result.Cancelled) panel.Children.Add(ReportLink($"{_model.Request.Title}: {result.Error ?? result.Headline}"));
                buttons.Add(("Close", Close, true, true));
                break;
        }
        var lines = new List<string>();
        Collect(panel, lines);
        Lines = lines;
        _body.Content = panel;
        var live = _model.Phase == PlanPhase.Running ? _model.ProgressLabel : "";
        _live.Text = live;
        _live.Visibility = live.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (_model.Phase == PlanPhase.Running && !_clock.IsEnabled) _clock.Start();
        else if (_model.Phase != PlanPhase.Running) _clock.Stop();

        _bar.Children.Clear();
        foreach (var (label, click, primary, enabled) in buttons)
        {
            var button = Ui.Button(label, click, label, primary);
            button.IsEnabled = enabled;
            if (label is "Cancel" or "Close") button.IsCancel = _model.IsDismissible;
            _bar.Children.Add(button);
        }
        ButtonLabels = buttons.Select(b => b.Label).ToList();
        Ui.RestoreFocus(this, focused);
    }

    private Button ReportLink(string problem)
    {
        var link = Ui.Link(BetaText.ReportThisProblem, () => _report(BetaText.ReportThisProblem, problem), "Report this problem");
        link.Margin = new Thickness(0, 8, 0, 0);
        return link;
    }

    private void BuildReview(StackPanel panel, PlanDocument plan)
    {
        panel.Children.Add(Ui.Text(_model.Request.Title, 18, FontWeights.SemiBold));
        if (_model.Request.Summary is { Length: > 0 } summary) panel.Children.Add(Ui.Text(summary, 14, opacity: 0.85, margin: new Thickness(0, 6, 0, 0)));
        if (_model.Message is { Length: > 0 } message) panel.Children.Add(Ui.CriticalText(message));
        if (!plan.HasChanges && plan.Errors.Count == 0) panel.Children.Add(Ui.Text("There is nothing to change.", 14, opacity: 0.85, margin: new Thickness(0, 8, 0, 0)));
        if (plan.Steps.Count > 0)
        {
            panel.Children.Add(Ui.Text("Steps", 13, FontWeights.SemiBold, margin: new Thickness(0, 14, 0, 4)));
            var n = 1;
            foreach (var step in plan.Steps.Where(s => s.WillRun))
            {
                var line = new StackPanel { Margin = new Thickness(0, 0, 0, 6) };
                line.Children.Add(Ui.Text($"{n++}. {step.Name}{(step.Sudo ? "  (needs sudo)" : "")}", 14));
                if (step.Command is { Length: > 0 } cmd) line.Children.Add(Ui.Mono(cmd));
                if (step.Note is { Length: > 0 } note) line.Children.Add(Ui.Text(note, 12, opacity: 0.7));
                panel.Children.Add(line);
            }
        }
        if (plan.Touches.Count > 0) panel.Children.Add(Ui.Text("Changes: " + string.Join(", ", plan.Touches), 13, opacity: 0.8, margin: new Thickness(0, 8, 0, 0)));
        if (_model.AsksPassword)
            panel.Children.Add(Ui.Text($"{plan.SudoSteps} {(plan.SudoSteps == 1 ? "step uses" : "steps use")} sudo. BenchBar asks for your Linux password when you confirm; it is used for this run only.", 13, margin: new Thickness(0, 10, 0, 0)));
        foreach (var warning in plan.Warnings) panel.Children.Add(Ui.Text("Warning: " + warning, 13, margin: new Thickness(0, 6, 0, 0)));
        foreach (var need in plan.Needs) panel.Children.Add(Ui.Text("Needs: " + need, 13, margin: new Thickness(0, 6, 0, 0)));
    }

    private void BuildRunning(StackPanel panel)
    {
        panel.Children.Add(Ui.Text("Working...", 18, FontWeights.SemiBold));
        panel.Children.Add(Ui.Text(_model.CanStop
            ? "You can stop this run, or stop waiting and let it finish in the background."
            : "This cannot be stopped part way. You can stop waiting: it keeps running and BenchBar tells you when it ends.", 13, opacity: 0.75, margin: new Thickness(0, 4, 0, 10)));
        _elapsedText = Ui.Text(ElapsedLine(), 12, opacity: 0.7, margin: new Thickness(0, 0, 0, 8));
        panel.Children.Add(_elapsedText);
        foreach (var step in _model.Steps)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 4) };
            var glyph = Ui.Glyph(StepGlyph(step.Status), 14, Ui.StepBrush(step.Status));
            glyph.Margin = new Thickness(0, 0, 8, 0);
            row.Children.Add(glyph);
            row.Children.Add(Ui.Text(step.Name + (step.Message is { Length: > 0 } m && step.Status is InstallStepStatus.Failed or InstallStepStatus.Skipped or InstallStepStatus.Warning ? ": " + m : ""), 14));
            panel.Children.Add(row);
        }
    }

    private void BuildResult(StackPanel panel, PlanResultModel result)
    {
        panel.Children.Add(Ui.Text(result.Headline, 18, FontWeights.SemiBold));
        if (result.Error is { Length: > 0 } error) panel.Children.Add(Ui.CriticalText(error));
        if (result.Missing.Count > 0) panel.Children.Add(Ui.Text("It needs: " + string.Join(", ", result.Missing), 13, margin: new Thickness(0, 6, 0, 0)));
        if (result.Changed.Count > 0)
        {
            panel.Children.Add(Ui.Text("Changed", 13, FontWeights.SemiBold, margin: new Thickness(0, 12, 0, 4)));
            foreach (var change in result.Changed)
                panel.Children.Add(Ui.Text($"{change.Kind}: {change.Name}{(change.Detail is { Length: > 0 } d ? ", " + d : "")}", 14));
        }
        foreach (var warning in result.Warnings) panel.Children.Add(Ui.Text("Warning: " + warning, 13, margin: new Thickness(0, 6, 0, 0)));
        if (result.NextActions.Count > 0)
        {
            panel.Children.Add(Ui.Text("Next", 13, FontWeights.SemiBold, margin: new Thickness(0, 12, 0, 4)));
            foreach (var next in result.NextActions)
            {
                var row = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
                var copy = Ui.Button("Copy", () => _copy(next.Command), "Copy " + next.Command, minWidth: 0);
                copy.Margin = new Thickness(8, 0, 0, 0);
                DockPanel.SetDock(copy, Dock.Right);
                row.Children.Add(copy);
                var text = new StackPanel();
                text.Children.Add(Ui.Mono(next.Command));
                if (next.Why is { Length: > 0 } why) text.Children.Add(Ui.Text(why, 12, opacity: 0.7));
                row.Children.Add(text);
                panel.Children.Add(row);
            }
        }
    }

    private static string StepGlyph(InstallStepStatus status) => status switch
    {
        InstallStepStatus.Done or InstallStepStatus.Unchanged => Ui.CheckGlyph,
        InstallStepStatus.Failed => Ui.ErrorGlyph,
        InstallStepStatus.Warning or InstallStepStatus.Skipped or InstallStepStatus.Stopped => Ui.WarningGlyph,
        _ => Ui.PendingGlyph,
    };

    private static void Collect(DependencyObject node, List<string> lines)
    {
        switch (node)
        {
            case TextBlock { Text.Length: > 0 } block:
                lines.Add(block.Text);
                return;
            case TextBox { Text.Length: > 0 } box:
                lines.Add(box.Text);
                return;
        }
        foreach (var child in LogicalTreeHelper.GetChildren(node).OfType<DependencyObject>()) Collect(child, lines);
    }
}
