using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// Move to Another Bench (the CLI's <c>site move</c>, issue 183): the dialog picks the bench, then the plan sheet shows the plan, answers a running
/// source with Stop Bench, asks for the site's name and runs that plan by its own token. The entry is in the menu only when the CLI lists the command
/// and another bench is registered, and it is off for the default site.
/// </summary>
internal sealed partial class SitesView
{
    private IReadOnlyList<BenchStatus> MoveTargets => SiteMoveRules.Targets(_services.Benches(), Bench.Path);

    /// <summary>The menu entry shows. False until the catalogue was read (the bench page asks for it; this tab starts no call of its own).</summary>
    internal bool MoveOffered => _context is not null && MoveOfferedFor(Bench.Path);

    private bool MoveOfferedFor(string benchPath) => SiteMoveRules.Offered(_services.Commands.Current, SiteMoveRules.Targets(_services.Benches(), benchPath).Count);

    internal async Task MoveAsync(string site)
    {
        if (Rows.FirstOrDefault(r => r.Name == site) is not { IsDefault: false }) return;
        var bench = Bench.Path;
        if (_services.AskMove(site, bench, MoveTargets) is not { } request) return;
        SetBusy(true);
        Rebuild();
        PlanOutcome outcome;
        try
        {
            outcome = await _services.ReviewPlan(SiteMoveCommands.Review(request, () => SiteMoveCommands.StopBench(_services.Cli, bench)));
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
                Say($"{site} moved to {TidyCommands.FolderName(request.Target)}. Its address there is in the result you just read.", false);
                _services.RefreshNow();
            }
            Rebuild();
        });
    }
}
