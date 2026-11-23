using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>Move to Another Bench (issue 183) in the windows: the site menu entry, the target dialog and the plan sheet's typed name, Stop Bench and Review Again.</summary>
public class SiteMoveViewTests
{
    private const string Other = "/home/akash/other-bench";

    private static (SitesView View, PageKit Kit) MakeSites(bool listed = true, bool another = true)
    {
        var kit = new PageKit();
        kit.Runner.On("commands").Print(listed ? Parity187cViewTests.CommandsWith("site move") : Parity187cViewTests.CommandsWith());
        kit.Runner.On(a => a is ["site", "move", ..] && a.Contains("--dry-run")).Print(Fixture("site-move-plan.json"));
        kit.Runner.On(a => a is ["site", "move", ..] && a.Contains("--apply")).Print(Fixture("site-move-apply.jsonl"));
        kit.Services.Benches = () => another ? [Bench(), Bench(path: Other)] : [Bench()];
        Wait(kit.Services.Commands.GetAsync());
        var view = new SitesView(kit.Services);
        view.Bind(new BenchContext(Bench(), null));
        return (view, kit);
    }

    [Fact]
    public void TheEntryIsInTheMenuOnlyWhenTheCliListsSiteMoveAndAnotherBenchExists() => Sta.Run(() =>
    {
        const string button = "More actions for two.localhost";
        var (with, _) = MakeSites();
        Assert.Contains(MenuOf(with, button), i => (string)i.Header == "Move to Another Bench...");
        var (unlisted, _) = MakeSites(listed: false);
        Assert.DoesNotContain(MenuOf(unlisted, button), i => (string)i.Header == "Move to Another Bench...");
        var (alone, _) = MakeSites(another: false);
        Assert.DoesNotContain(MenuOf(alone, button), i => (string)i.Header == "Move to Another Bench...");
        var unasked = new SitesView(new PageKit().Services); // the tab starts no call of its own
        unasked.Bind(new BenchContext(Bench(), null));
        Assert.DoesNotContain(MenuOf(unasked, button), i => (string)i.Header == "Move to Another Bench...");
    });

    [Fact]
    public void TheDefaultSitesEntryIsDisabled() => Sta.Run(() =>
    {
        var (view, _) = MakeSites();
        Assert.False(MenuOf(view, "More actions for one.localhost").Single(i => (string)i.Header == "Move to Another Bench...").IsEnabled);
        Assert.True(MenuOf(view, "More actions for two.localhost").Single(i => (string)i.Header == "Move to Another Bench...").IsEnabled);
    });

    [Fact]
    public void CancellingTheDialogRunsNothingAndAChoiceOpensThePlanOfThatBench() => Sta.Run(() =>
    {
        var (view, kit) = MakeSites();
        view.MoveAsync("two.localhost").GetAwaiter().GetResult();
        Assert.Empty(kit.Plans);
        kit.Services.AskMove = (site, bench, targets) =>
        {
            Assert.Equal([Other], targets.Select(t => t.Path));
            return new SiteMoveRequest(site, Other, true, bench);
        };
        view.MoveAsync("one.localhost").GetAwaiter().GetResult(); // the default site never moves
        Assert.Empty(kit.Plans);
        view.MoveAsync("two.localhost").GetAwaiter().GetResult();
        var plan = Assert.Single(kit.Plans);
        Assert.Equal(["site", "move", "two.localhost", "--to-bench", Other, "--no-migrate", "--bench-dir", PageKit.BenchPath, "--dry-run", "--json"], plan.PlanArgs);
    });

    [Fact]
    public void TheDialogOffersTheOtherBenchesAndSkipMigrate() => Sta.Run(() =>
    {
        var dialog = new SiteMoveDialog("two.localhost", PageKit.BenchPath, [Bench(path: Other), Bench(path: "/x/third")], Theme, null);
        dialog.Select(1);
        dialog.SkipMigrate = true;
        dialog.Choose();
        Assert.Equal(new SiteMoveRequest("two.localhost", "/x/third", true, PageKit.BenchPath), dialog.Chosen);
        AssertEveryControlIsNamed(dialog);
    });

    [Fact]
    public void MoveWaitsForTheTypedNameAndStopBenchAnswersARunningSource() => Sta.Run(() =>
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var runner = new ScriptedStreamRunner();
        runner.On(a => a.Contains("--dry-run")).Print(Fixture("site-move-plan-running.json"));
        var model = new PlanReviewModel(SiteMoveCommands.Review(new SiteMoveRequest("acme.localhost", "/t", false, "/s"), () => Task.FromResult(true)), new CliClient(runner, () => "benchbar.exe"));
        var sheet = new PlanReviewSheet(model, Theme, null, _ => { }, load: false);
        model.LoadAsync(CancellationToken.None).GetAwaiter().GetResult();
        Assert.Equal(["Stop Bench", "Move", "Cancel"], sheet.ButtonLabels);
        Assert.Contains(sheet.Lines, l => l.StartsWith("Stop the bench first"));
        Assert.Contains("Type acme.localhost to confirm", sheet.Lines);
        AssertEveryControlIsNamed(sheet);
    });

    [Fact]
    public void ThePlanSheetKeepsMoveOffUntilTheNameIsTypedAndAStalePlanSaysReviewAgain() => Sta.Run(() =>
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var runner = new ScriptedStreamRunner();
        runner.On(a => a.Contains("--dry-run")).Print(Fixture("site-move-plan.json"));
        runner.On(a => a.Contains("--apply")).Print(Fixture("site-move-apply-stale.jsonl")).Fail(1);
        var model = new PlanReviewModel(SiteMoveCommands.Review(new SiteMoveRequest("acme.localhost", "/t", false, "/s"), () => Task.FromResult(true)), new CliClient(runner, () => "benchbar.exe"));
        var sheet = new PlanReviewSheet(model, Theme, null, _ => { }, load: false);
        model.LoadAsync(CancellationToken.None).GetAwaiter().GetResult();
        var move = ButtonNamed(sheet, "Move");
        Assert.False(move.IsEnabled);
        Walk(sheet).OfType<TextBox>().Single(t => System.Windows.Automation.AutomationProperties.GetName(t) == "Type acme.localhost to confirm").Text = "acme.localhost";
        Assert.True(move.IsEnabled);
        model.ConfirmAsync().GetAwaiter().GetResult();
        Assert.Equal(["Review Again", "Close"], sheet.ButtonLabels);
        Assert.Contains("The plan is out of date", sheet.Lines);
    });
}
