using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// Tidy Up (macos has none; the CLI's <c>bench scratch</c>, <c>bench gc</c> and <c>db orphans</c>): marks this bench scratch for a number of days or
/// not, lists the scratch benches that expired, and lists the databases no site refers to. The two lists are read when the dialog opens
/// (<c>bench gc --dry-run --json</c> and <c>db orphans --json</c> change nothing). Removing the expired benches is not done here: Remove Expired
/// closes the dialog with that choice, and the plan sheet shows the plan and applies it with the plan's own token. BenchBar never drops a
/// database: the orphans are a list, and the CLI says why. Each part is offered only when the CLI lists its command.
/// </summary>
internal sealed class TidyDialog : Window
{
    private readonly PageServices _services;
    private readonly BenchStatus _bench;
    private readonly CommandCatalogue _commands;
    private readonly TextBox _days;
    private readonly TextBlock _scratchLine = Ui.Text("", 12, opacity: 0.85);
    private readonly StackPanel _gc = new();
    private readonly StackPanel _orphans = new();
    private readonly Button _removeExpired;
    private readonly CancellationTokenSource _cancel = new();
    private readonly Func<DateTimeOffset> _now;

    public TidyDialog(PageServices services, BenchStatus bench, CommandCatalogue commands, ResolvedTheme theme, Window? owner, Func<DateTimeOffset>? now = null)
    {
        _services = services;
        _bench = bench;
        _commands = commands;
        _now = now ?? (() => DateTimeOffset.UtcNow);
        Title = "Tidy up";
        Width = 560;
        SizeToContent = SizeToContent.Height;
        MaxHeight = 760;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = owner is null;
        Owner = owner;
        WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;
        Ui.ApplyTheme(this, theme);
        Ui.Name(this, "Tidy up");

        var panel = new StackPanel { Margin = new Thickness(24) };
        panel.Children.Add(Ui.Text("Tidy up", 18, FontWeights.SemiBold));
        _days = Ui.Field("Days until it expires", "7", _ => { }, 80);
        _removeExpired = Ui.Button("Remove Expired...", () => Choose(), "Remove the expired scratch benches", primary: true);
        _removeExpired.IsEnabled = false;
        if (commands.Has("bench scratch"))
        {
            panel.Children.Add(Ui.Text($"{bench.Name}", 14, FontWeights.SemiBold, margin: new Thickness(0, 12, 0, 2)));
            panel.Children.Add(Ui.Text("A scratch bench expires after the days you give. Then Remove Expired backs up its sites, drops their databases and moves its folder aside. The default bench is never removed.", 12, opacity: 0.8));
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 4) };
            row.Children.Add(_days);
            row.Children.Add(Ui.Button("Mark Scratch", () => MarkAsync(true).Forget(), $"Mark {bench.Name} scratch", minWidth: 100));
            row.Children.Add(Ui.Button("Not Scratch", () => MarkAsync(false).Forget(), $"Keep {bench.Name}, not scratch", minWidth: 100));
            _days.Margin = new Thickness(0, 0, 8, 0);
            panel.Children.Add(row);
            panel.Children.Add(_scratchLine);
        }
        if (commands.Has("bench gc"))
        {
            panel.Children.Add(Ui.Text("Scratch benches", 14, FontWeights.SemiBold, margin: new Thickness(0, 14, 0, 4)));
            panel.Children.Add(_gc);
            panel.Children.Add(_removeExpired);
        }
        if (commands.Has("db orphans"))
        {
            panel.Children.Add(Ui.Text("Databases no site refers to", 14, FontWeights.SemiBold, margin: new Thickness(0, 14, 0, 4)));
            panel.Children.Add(_orphans);
        }
        var close = Ui.Button("Close", () => DialogResult = false, "Close");
        close.IsCancel = true;
        close.HorizontalAlignment = HorizontalAlignment.Right;
        close.Margin = new Thickness(0, 12, 0, 0);
        panel.Children.Add(close);
        Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Closed += (_, _) => _cancel.Cancel();
        Pending = LoadAsync();
    }

    /// <summary>Set when Remove Expired closed the dialog: the plan sheet takes it from here.</summary>
    public bool RemoveChosen { get; private set; }

    /// <summary>The last read or mark; tests wait on it.</summary>
    public Task Pending { get; private set; }

    public string ScratchText => _scratchLine.Text;

    public IReadOnlyList<string> GcLines => Lines(_gc);

    public IReadOnlyList<string> OrphanLines => Lines(_orphans);

    public bool RemoveExpiredEnabled => _removeExpired.IsEnabled;

    internal void SetDays(string text) => _days.Text = text;

    internal void Mark(bool scratch) => (Pending = MarkAsync(scratch)).Forget();

    internal void Choose()
    {
        RemoveChosen = true;
        try { DialogResult = true; }
        catch (InvalidOperationException) { } // not shown as a dialog (a test): the choice is in RemoveChosen
    }

    private static IReadOnlyList<string> Lines(Panel p) => p.Children.OfType<TextBlock>().Select(t => t.Text).ToList();

    private static void Fill(Panel p, IEnumerable<(string Text, bool Error)> lines)
    {
        p.Children.Clear();
        foreach (var (text, error) in lines) p.Children.Add(PagePanels.Line(text, error));
    }

    private async Task LoadAsync()
    {
        var gc = _commands.Has("bench gc") ? _services.Cli.RunJsonAsync(TidyCommands.GcRead, null, CliTimeouts.Plan, TidyJson.ParseGc, _cancel.Token) : null;
        var orphans = _commands.Has("db orphans") ? _services.Cli.RunJsonAsync(TidyCommands.OrphansRead, null, CliTimeouts.Read, TidyJson.ParseOrphans, _cancel.Token) : null;
        try
        {
            if (gc is not null) ShowGc(await gc.ConfigureAwait(true));
            if (orphans is not null) ShowOrphans(await orphans.ConfigureAwait(true));
        }
        catch (OperationCanceledException)
        {
            // the dialog closed: nothing to show
        }
    }

    private void ShowGc(CliResult<GcPlan> r)
    {
        if (r.Value is not { } gc)
        {
            Fill(_gc, [(r.Error ?? "The scratch benches could not be read.", true)]);
            return;
        }
        var now = _now();
        var lines = gc.Expired.Select(b => ($"{b.Bench}: {TidyText.Sites(b.Sites)}, {TidyText.Expiry(b, now)}, marked by {b.MarkedBy}", false))
            .Concat(gc.Pending.Select(b => ($"{b.Bench}: {TidyText.Expiry(b, now)}", false)))
            .Concat(gc.Skipped.Select(b => ($"{b.Bench}: kept, {b.Why}", false))).ToList();
        if (gc.Expired.Count == 0) lines.Insert(0, ("No scratch bench has expired.", false));
        Fill(_gc, lines);
        _removeExpired.IsEnabled = gc.Expired.Count > 0;
    }

    private void ShowOrphans(CliResult<OrphanList> r)
    {
        if (r.Value is not { } list)
        {
            Fill(_orphans, [(r.Error ?? "The databases could not be read.", true)]);
            return;
        }
        var lines = new List<(string, bool)> { (TidyText.OrphanSummary(list), false) };
        lines.AddRange(list.Orphans.Select(o => (TidyText.Orphan(o), false)));
        if (list.Orphans.Count > 0 && list.Note.Length > 0) lines.Add((list.Note, false));
        Fill(_orphans, lines);
    }

    private async Task MarkAsync(bool scratch)
    {
        if (scratch && TidyCommands.Days(_days.Text) is null)
        {
            _scratchLine.Text = TidyCommands.TtlProblem(_days.Text) ?? "";
            return;
        }
        var count = TidyCommands.Days(_days.Text) ?? 7;
        if (scratch && !_services.Confirm($"Mark {_bench.Name} scratch for {count} day(s)?",
                "Once the time is up, Remove Expired backs up its sites, drops their databases and moves its folder aside. The default bench is never removed.", "Mark Scratch")) return;
        var r = await _services.Cli.RunJsonAsync(scratch ? TidyCommands.Scratch(_bench.Path, count) : TidyCommands.ClearScratch(_bench.Path), null, CliTimeouts.Read, o => o, _cancel.Token).ConfigureAwait(true);
        _scratchLine.Text = !r.Ok ? r.Error ?? "It did not work." : scratch ? $"{_bench.Name} is a scratch bench for {count} day(s)." : $"{_bench.Name} is not a scratch bench.";
        if (r.Ok && _commands.Has("bench gc")) ShowGc(await _services.Cli.RunJsonAsync(TidyCommands.GcRead, null, CliTimeouts.Plan, TidyJson.ParseGc, _cancel.Token).ConfigureAwait(true));
    }

    /// <summary>Shows the dialog; true when the person chose Remove Expired.</summary>
    public static bool Ask(PageServices services, BenchStatus bench, CommandCatalogue commands, ResolvedTheme theme, Window? owner) =>
        Show(new TidyDialog(services, bench, commands, theme, owner));

    private static bool Show(TidyDialog dialog) => dialog.ShowDialog() == true && dialog.RemoveChosen;
}
