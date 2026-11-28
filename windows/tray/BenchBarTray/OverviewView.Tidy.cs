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
            item(UiText.Get("TidyMenuTidyUp"), UiText.Get("TidyMenuTidyUpTip"), true, () => TidyAsync().Forget());
        if (cli.Has("uninstall-service") && !needsService)
            item(UiText.Get("TidyMenuRemoveService"), UiText.Get("TidyMenuRemoveServiceTip"), true, () => RemoveServiceAsync().Forget());
        if (cli.Has("bench forget"))
            item(UiText.Get("TidyMenuForget"), UiText.Get("TidyMenuForgetTip"), true, () => ForgetBenchAsync().Forget());
        if (cli.Has("bench remove"))
            item(UiText.Get("TidyMenuRemoveBench"), UiText.Get("TidyMenuRemoveBenchTip"), true, () => RemoveBenchAsync().Forget());
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
        var typed = _services.ConfirmTyped(new TypedConfirmRequest(UiText.Format("TidyRemoveTitle", name),
            UiText.Format("TidyRemoveBody", name, bench.Path),
            name, UiText.Get("TidyRemoveBenchConfirm")));
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
