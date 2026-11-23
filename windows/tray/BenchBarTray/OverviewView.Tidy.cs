using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// The end of a bench's life in the More menu of the Overview (issue 183): Tidy Up (scratch benches, expired ones, orphan databases),
/// Forget Bench, Remove Bench and Remove Service. Each is offered only when the CLI lists its command. A change goes through the plan sheet
/// and runs the plan's own token; Remove asks first for the folder name. Hosts lines are not pruned here: <c>site hosts --prune</c> is macOS only
/// and the Windows hosts file is never edited (a <c>*.localhost</c> name needs no line).
/// </summary>
internal sealed partial class OverviewView
{
    /// <summary>What the Tidy Up dialog returns: true when Remove Expired was chosen. The default opens the dialog; tests replace it.</summary>
    internal Func<BenchStatus, CommandCatalogue, bool>? AskTidy { get; set; }

    private void AddTidyItems(BenchStatus bench, CommandCatalogue cli, bool needsService, Func<string, string, bool, Action, MenuItem> item)
    {
        if (cli.Has("bench scratch") || cli.Has("bench gc") || cli.Has("db orphans"))
            item("Tidy Up...", "Scratch benches, the ones that expired and the databases no site refers to", true, () => TidyAsync().Forget());
        if (cli.Has("uninstall-service") && !needsService)
            item("Remove Service...", "uninstall-service for this bench: stops it and removes its background service; shows its plan first", true, () => RemoveServiceAsync().Forget());
        if (cli.Has("bench forget"))
            item("Forget Bench...", "bench forget: takes the bench out of benchbar's list; the folder, sites and databases stay", true, () => ForgetBenchAsync().Forget());
        if (cli.Has("bench remove"))
            item("Remove Bench...", "bench remove: backs up and drops its sites, then moves the folder aside; asks for the folder name", true, () => RemoveBenchAsync().Forget());
    }

    /// <summary>Tidy Up: the dialog reads and lists; Remove Expired comes back here and goes through the plan sheet of <c>bench gc</c>.</summary>
    internal async Task TidyAsync()
    {
        if (_services is null || _bench is not { } bench || _catalogue is not { } cli) return;
        var remove = AskTidy is { } ask ? ask(bench, cli) : TidyDialog.Ask(_services, bench, cli, _services.Theme(), _services.Owner());
        if (!remove) return;
        await ReviewAsync(TidyCommands.GcReview()).ConfigureAwait(true);
    }

    internal Task ForgetBenchAsync() => _bench is { } bench ? ReviewAsync(TidyCommands.ForgetReview(bench.Path)) : Task.CompletedTask;

    internal Task RemoveServiceAsync() => _bench is { } bench ? ReviewAsync(TidyCommands.UninstallServiceReview(bench.Path, bench.Name)) : Task.CompletedTask;

    /// <summary>Remove asks for the folder name first, as the CLI wants it again, then shows the plan and runs it with its token as the person.</summary>
    internal async Task RemoveBenchAsync()
    {
        if (_services is null || _bench is not { } bench) return;
        var name = TidyCommands.FolderName(bench.Path);
        var typed = _services.ConfirmTyped(new TypedConfirmRequest($"Remove {name}",
            $"This backs up each site of {name}, drops its database and moves the folder {bench.Path} to a trash folder next to it. Nothing is deleted, and the plan comes next.",
            name, "Remove Bench"));
        if (typed is null || !TypedConfirm.Matches(name, typed)) return;
        await ReviewAsync(TidyCommands.RemoveReview(bench.Path)).ConfigureAwait(true);
    }

    private async Task ReviewAsync(PlanReviewRequest request)
    {
        if (_services is null) return;
        var outcome = await _services.ReviewPlan(request).ConfigureAwait(true);
        if (outcome.Applied) _services.RefreshNow();
    }
}
