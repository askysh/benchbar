using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// Snapshots in the Sites tab (macos SnapshotsSheet): a site's ... menu has Snapshots..., which takes one (a label if you like; nothing in the
/// site changes), lists them with age, size and whether the bench's apps are still the same, and has Roll Back... and Remove... on each.
/// Roll Back asks for the site name first, then shows the plan of <c>site rollback --dry-run --json</c> in the plan sheet and runs exactly that
/// plan by its token; Remove asks first and is never offered for the undo point of the last rollback. Offered only when the CLI lists
/// <c>site snapshots</c> and <c>site rollback</c>; an older CLI shows nothing new.
/// </summary>
internal sealed partial class SitesView
{
    private TextBox? _snapLabel;
    private TextBlock? _snapProblem;

    /// <summary>The CLI lists the snapshot commands. Null until the catalogue was read (the bench page asks for it; this tab starts no call of its own).</summary>
    internal bool? SnapshotsAvailable => _services.Commands.Current is { } c ? c.Has("site snapshots") && c.Has("site rollback") : null;

    /// <summary>Now, for the age of a snapshot. Tests set it.</summary>
    internal Func<DateTimeOffset> Clock { get; set; } = () => DateTimeOffset.UtcNow;

    /// <summary>The label box of the open Snapshots panel (for tests); null when it is not open.</summary>
    internal TextBox? SnapshotLabelBox => _snapLabel;

    internal async Task ShowSnapshotsAsync(string site, string? note = null)
    {
        _snapLabel = null;
        SetPanel(PagePanels.Panel(UiText.Format("SnapshotTitle", site), null, [PagePanels.Line(UiText.Get("SnapshotReading"))], [Ui.Button(UiText.Get("TidyClose"), ClosePanel)]));
        var generation = _panelGeneration;
        var bench = PanelBench;
        var r = await _services.Cli.RunJsonAsync(SnapshotCommands.List(site, bench), null, CliTimeouts.Read, SnapshotJson.ParseList);
        PagePanels.OnUi(this, () =>
        {
            if (generation != _panelGeneration) return; // the person opened something else meanwhile
            SetPanel(r.Value is { } list ? SnapshotsPanel(site, list, note)
                : PagePanels.Panel(UiText.Format("SnapshotTitle", site), null, [PagePanels.Line(Why(r), error: true)], [Ui.Button(UiText.Get("TidyClose"), ClosePanel)]));
        });
    }

    private UIElement SnapshotsPanel(string site, SiteSnapshotList list, string? note)
    {
        var body = new List<UIElement>();
        _snapLabel = Ui.Field(UiText.Get("SnapshotLabelField"), "", _ => HideSnapProblem(), 300);
        _snapProblem = PagePanels.Line("", error: true);
        _snapProblem.Visibility = Visibility.Collapsed;
        var take = Ui.Button(UiText.Get("SnapshotTake"), () => Start(() => TakeSnapshotAsync(site)), UiText.Format("SnapshotTakeName", site), primary: true);
        take.IsEnabled = !_busy;
        var takeRow = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
        DockPanel.SetDock(take, Dock.Right);
        take.Margin = new Thickness(8, 0, 0, 0);
        takeRow.Children.Add(take);
        takeRow.Children.Add(Ui.Labeled(UiText.Get("SnapshotLabelField"), _snapLabel));
        body.Add(takeRow);
        body.Add(_snapProblem);
        if (note is { Length: > 0 }) body.Add(PagePanels.Line(note));
        if (list.Snapshots.Count == 0)
        {
            body.Add(PagePanels.Line(UiText.Format("SnapshotNone", site)));
        }
        else
        {
            foreach (var snapshot in list.Snapshots) body.Add(SnapshotRow(site, snapshot));
            body.Add(Ui.Text(SnapshotText.Summary(list), 12, opacity: 0.7, margin: new Thickness(0, 6, 0, 0)));
        }
        return PagePanels.Panel(UiText.Format("SnapshotTitle", site),
            UiText.Get("SnapshotExplain"),
            body, [Ui.Button(UiText.Get("TidyClose"), ClosePanel)]);
    }

    private UIElement SnapshotRow(string site, SiteSnapshot snapshot)
    {
        var grid = new Grid { Margin = new Thickness(0, 3, 0, 3) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var text = new StackPanel();
        text.Children.Add(Ui.Text(snapshot.Title, 14, FontWeights.SemiBold));
        text.Children.Add(Ui.Text(SnapshotText.Line(snapshot, Clock()), 12, opacity: 0.75));
        if (SnapshotText.Apps(snapshot) is { } apps) text.Children.Add(Ui.Text(apps, 12, opacity: snapshot.AppsMatch == false ? 1 : 0.75));
        if (snapshot.BeforeRollback) text.Children.Add(Ui.Text(UiText.Get("SnapshotUndoPoint"), 12, opacity: 0.75));
        if (!snapshot.Complete) text.Children.Add(Ui.Text(UiText.Get("SnapshotIncomplete"), 12));
        grid.Children.Add(text);
        var roll = Ui.Button(UiText.Get("SnapshotRollBack"), () => Start(() => RollBackAsync(site, snapshot)), UiText.Format("SnapshotRollName", site, snapshot.Title), minWidth: 84);
        roll.IsEnabled = !_busy && snapshot.Complete;
        roll.Margin = new Thickness(8, 0, 0, 0);
        Grid.SetColumn(roll, 1);
        grid.Children.Add(roll);
        var remove = Ui.Button(UiText.Get("ProfileRemove"), () => Start(() => RemoveSnapshotAsync(site, snapshot)), UiText.Format("SnapshotRemoveName", snapshot.Title), minWidth: 84);
        remove.IsEnabled = !_busy && SnapshotText.CanRemove(snapshot);
        if (!SnapshotText.CanRemove(snapshot)) remove.ToolTip = UiText.Get("SnapshotUndoTip");
        remove.Margin = new Thickness(6, 0, 0, 0);
        Grid.SetColumn(remove, 2);
        grid.Children.Add(remove);
        return grid;
    }

    private void HideSnapProblem()
    {
        if (_snapProblem is not null) _snapProblem.Visibility = Visibility.Collapsed;
    }

    /// <summary><c>site snapshot NAME --label TEXT --json</c>. It changes nothing in the site, so it has no plan.</summary>
    internal async Task TakeSnapshotAsync(string site)
    {
        var label = _snapLabel?.Text ?? "";
        if (SnapshotCommands.LabelProblem(label) is { } problem)
        {
            if (_snapProblem is not null)
            {
                _snapProblem.Text = problem;
                _snapProblem.Visibility = Visibility.Visible;
            }
            return;
        }
        var bench = PanelBench;
        SetBusy(true);
        Rebuild();
        var r = await _services.Cli.RunJsonAsync(SnapshotCommands.Take(site, label, bench), null, CliTimeouts.Apply, SnapshotJson.ParseTaken);
        string text;
        if (r.Ok) text = r.Value is { } taken ? UiText.Format("SnapshotTaken", taken.Title, ByteSize.Format(taken.SizeBytes)) : UiText.Format("SnapshotTakenPlain", site);
        else text = Why(r);
        var ok = r.Ok;
        PagePanels.OnUi(this, () =>
        {
            SetBusy(false);
            Rebuild();
            if (_context is null || Bench.Path != bench) return;
            if (!ok) Say(text, true);
            ShowSnapshotsAsync(site, ok ? text : null).Forget();
        });
    }

    /// <summary>
    /// Roll Back: the person types the site name, then the plan sheet shows <c>site rollback --dry-run --json</c> and runs
    /// <c>--apply TOKEN --yes</c> with that plan's token. A snapshot of the site as it is now is taken first. The default site is rolled back as
    /// the person and the sheet says so.
    /// </summary>
    internal async Task RollBackAsync(string site, SiteSnapshot snapshot)
    {
        var isDefault = Rows.FirstOrDefault(r => r.Name == site)?.IsDefault == true;
        var typed = _services.ConfirmTyped(new TypedConfirmRequest(UiText.Format("SnapshotRollTitle", site),
            UiText.Format("SnapshotRollConfirm", site, snapshot.Title)
            + (isDefault ? " " + SnapshotCommands.DefaultSiteNote : ""), site, UiText.Get("SnapshotRollButton")));
        if (typed is null || !TypedConfirm.Matches(site, typed)) return;
        if (PanelIsStale) return;
        var bench = PanelBench;
        SetBusy(true);
        Rebuild();
        PlanOutcome outcome;
        try
        {
            outcome = await _services.ReviewPlan(SnapshotCommands.Review(site, snapshot, bench));
        }
        catch (Exception ex)
        {
            outcome = PlanOutcome.None;
            Say(ex.Message, true);
        }
        PagePanels.OnUi(this, () =>
        {
            SetBusy(false);
            if (_context is null || Bench.Path != bench)
            {
                if (outcome.Applied) _services.RefreshNow();
                return; // the person moved to another bench meanwhile: say nothing about this one there
            }
            if (outcome.Applied)
            {
                Say(UiText.Format("SnapshotRolledBack", site, snapshot.Title), false);
                _services.RefreshNow();
                Rebuild();
                ShowSnapshotsAsync(site).Forget();
                return;
            }
            Rebuild();
        });
    }

    /// <summary>Remove asks first and runs <c>site snapshot drop --yes</c> as the person (the CLI allows it to a person only), never with <c>--force-undo-point</c>.</summary>
    internal async Task RemoveSnapshotAsync(string site, SiteSnapshot snapshot)
    {
        if (!SnapshotText.CanRemove(snapshot)) return;
        if (!_services.Confirm(UiText.Format("SnapshotRemoveTitle", snapshot.Title), UiText.Format("SnapshotRemoveMessage", site), UiText.Get("SnapshotRemoveButton"))) return;
        var bench = PanelBench;
        SetBusy(true);
        Rebuild();
        var r = await _services.Cli.RunJsonAsync(SnapshotCommands.Remove(site, snapshot.Id, bench), ActivityText.ClickEnvironment(), CliTimeouts.Apply, o => o);
        var ok = r.Ok;
        var text = ok ? UiText.Format("SnapshotRemoved", snapshot.Title) : Why(r);
        PagePanels.OnUi(this, () =>
        {
            SetBusy(false);
            Rebuild();
            if (_context is null || Bench.Path != bench) return;
            if (!ok) Say(text, true);
            ShowSnapshotsAsync(site, ok ? text : null).Forget();
        });
    }
}
