using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>The tidy surfaces (issue 183) in the windows: Tidy Up, Forget Bench, Remove Bench and Remove Service in the More menu of the Overview.</summary>
public class TidyViewTests
{
    private static readonly string[] All = ["bench scratch", "bench gc", "bench forget", "bench remove", "db orphans", "uninstall-service"];

    private static (OverviewView View, PageKit Kit) MakeOverview(params string[] commands)
    {
        var kit = new PageKit();
        kit.Runner.On("commands").Print(Parity187cViewTests.CommandsWith(commands));
        kit.Runner.On("ports", "check").Print(Fixture("ports-check-clean.json"));
        kit.Runner.On(a => a is ["bench", "gc", ..] && a.Contains("--dry-run")).Print(Fixture("bench-gc-plan.json"));
        kit.Runner.On(a => a is ["bench", "gc", ..] && a.Contains("--apply")).Print(Fixture("bench-gc-apply.jsonl"));
        kit.Runner.On(a => a is ["bench", "forget", ..] && a.Contains("--dry-run")).Print(Fixture("bench-forget-plan.json"));
        kit.Runner.On(a => a is ["bench", "remove", ..] && a.Contains("--dry-run")).Print(Fixture("bench-remove-plan.json"));
        kit.Runner.On(a => a is ["bench", ..] && a.Contains("--apply")).Print(Fixture("bench-retire-result.jsonl"));
        kit.Runner.On("uninstall-service").Print("[OK] service uninstalled");
        kit.Runner.On("db", "orphans").Print(Fixture("db-orphans.json"));
        var view = new OverviewView(new OverviewActions());
        view.Attach(kit.Services, (_, _) => { });
        Pump(() =>
        {
            view.Bind(BenchWith(BenchState.Running), null);
            view.EnsureCliFactsAsync().Forget();
        }, () => view.MoreItems.Contains("Write Lockfile...")); // the catalogue was read and the page rebuilt with it
        return (view, kit);
    }

    [Fact]
    public void TheTidyEntriesAreInTheMenuOnlyWhenTheCliListsTheirCommands() => Sta.Run(() =>
    {
        var (with, _) = MakeOverview(All);
        Assert.Contains("Tidy Up...", with.MoreItems);
        Assert.Contains("Remove Service...", with.MoreItems);
        Assert.Contains("Forget Bench...", with.MoreItems);
        Assert.Contains("Remove Bench...", with.MoreItems);
        var (without, _) = MakeOverview();
        Assert.DoesNotContain(without.MoreItems, t => t is "Tidy Up..." or "Remove Service..." or "Forget Bench..." or "Remove Bench...");
        var (some, _) = MakeOverview("bench forget");
        Assert.Contains("Forget Bench...", some.MoreItems);
        Assert.DoesNotContain("Remove Bench...", some.MoreItems);
    });

    [Fact]
    public void ForgetShowsItsPlanThenRunsThatToken() => Sta.Run(() =>
    {
        var (view, kit) = MakeOverview(All);
        Wait(view.ForgetBenchAsync());
        Assert.Equal("Forget frappe-bench", Assert.Single(kit.Plans).Title);
        var runs = kit.RunsOf("bench", "forget");
        Assert.Equal(["bench", "forget", PageKit.BenchPath, "--dry-run", "--json"], runs[0]);
        Assert.Equal(["bench", "forget", PageKit.BenchPath, "--apply", "5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d", "--yes", "--jsonl"], runs[1]);
        Assert.True(kit.Refreshes >= 1);
    });

    [Fact]
    public void RemoveAsksForTheFolderNameThenRunsThePlanAsThePerson() => Sta.Run(() =>
    {
        var (view, kit) = MakeOverview(All);
        kit.Answer = _ => "wrong";
        Wait(view.RemoveBenchAsync());
        Assert.Empty(kit.Plans); // a name that does not match plans nothing
        kit.Answer = r => r.Expected;
        Wait(view.RemoveBenchAsync());
        Assert.Equal("frappe-bench", kit.Typed.Last().Expected);
        var runs = kit.RunsOf("bench", "remove");
        Assert.Equal(["--dry-run", "--json"], runs[0][^2..]);
        Assert.Equal(["--confirm-bench", "frappe-bench", "--apply", "3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8091a2b", "--yes", "--jsonl"], runs[1][^6..]);
        Assert.All(kit.Runner.Runs.Where(r => r.Args[0] == "bench"), r => Assert.Equal("0", r.Env["BENCHBAR_NONINTERACTIVE"]));
        Assert.True(kit.Refreshes >= 1);
    });

    [Fact]
    public void RemoveServiceIsForThisBenchOnlyAndNeverPassesAll() => Sta.Run(() =>
    {
        var (view, kit) = MakeOverview(All);
        Wait(view.RemoveServiceAsync());
        var request = Assert.Single(kit.Plans);
        Assert.True(request.PlanIsText);
        var runs = kit.RunsOf("uninstall-service");
        Assert.Equal(["uninstall-service", "--bench-dir", PageKit.BenchPath, "--dry-run", "--yes"], runs[0]);
        Assert.Equal(["uninstall-service", "--bench-dir", PageKit.BenchPath, "--yes"], runs[1]);
        Assert.DoesNotContain(runs, a => a.Contains("--all"));
    });

    [Fact]
    public void TidyUpRunsTheGcPlanByItsTokenOnlyWhenRemoveExpiredWasChosen() => Sta.Run(() =>
    {
        var (view, kit) = MakeOverview(All);
        view.AskTidy = (_, _) => false;
        Wait(view.TidyAsync());
        Assert.Empty(kit.Plans);
        view.AskTidy = (_, _) => true;
        Wait(view.TidyAsync());
        Assert.Equal("Remove expired scratch benches", Assert.Single(kit.Plans).Title);
        var runs = kit.RunsOf("bench", "gc");
        Assert.Equal(["bench", "gc", "--apply", "1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f809", "--yes", "--jsonl"], runs[^1]);
        Assert.All(kit.Runner.Runs.Where(r => r.Args[0] == "bench"), r => Assert.Equal("0", r.Env["BENCHBAR_NONINTERACTIVE"]));
    });

    // --- the dialog ---

    private static TidyDialog MakeDialog(PageKit kit, params string[] commands)
    {
        kit.Runner.On("bench", "gc").Print(Fixture("bench-gc-plan.json"));
        kit.Runner.On("db", "orphans").Print(Fixture("db-orphans.json"));
        kit.Runner.On("bench", "scratch").Print(Fixture("bench-scratch.json"));
        var catalogue = CommandCatalogue.Parse((System.Text.Json.Nodes.JsonObject)System.Text.Json.Nodes.JsonNode.Parse(Parity187cViewTests.CommandsWith(commands))!);
        return new TidyDialog(kit.Services, Bench(), catalogue, Theme, null, () => DateTimeOffset.Parse("2026-11-23T10:00:00Z"));
    }

    [Fact]
    public void TheDialogListsTheExpiredBenchesAndTheOrphansWithoutAnyPlanOrChange() => Sta.Run(() =>
    {
        var kit = new PageKit();
        kit.Services.Confirm = (_, _, _) => true;
        var dialog = MakeDialog(kit, All);
        Wait(dialog.Pending);
        Assert.Contains(dialog.GcLines, l => l.StartsWith("/home/akash/scratch-qa: 2 sites, expired ", StringComparison.Ordinal) && l.EndsWith(", marked by person", StringComparison.Ordinal));
        Assert.Contains("/home/akash/scratch-next: expires 2026-11-30", dialog.GcLines);
        Assert.Contains("/home/akash/frappe-bench: kept, it is the default bench", dialog.GcLines);
        Assert.True(dialog.RemoveExpiredEnabled);
        Assert.Equal("2 databases of 3 have no site in any bench benchbar knows.", dialog.OrphanLines[0]);
        Assert.Contains("_7f3a9c1e5b2d4a60, named by the archived site old.localhost", dialog.OrphanLines);
        Assert.Contains(dialog.OrphanLines, l => l.Contains("benchbar does not drop them"));
        Assert.Equal(["bench gc --dry-run --json", "db orphans --json"], kit.Runner.Runs.Select(r => string.Join(' ', r.Args)).Order());
        Assert.Empty(kit.Plans);
        AssertEveryControlIsNamed(dialog);
    });

    [Fact]
    public void MarkScratchRefusesBadDaysBeforeAnyCallAndAsksBeforeMarking() => Sta.Run(() =>
    {
        var kit = new PageKit();
        var asked = new List<string>();
        kit.Services.Confirm = (title, _, button) =>
        {
            asked.Add(title + "|" + button);
            return true;
        };
        var dialog = MakeDialog(kit, All);
        Wait(dialog.Pending);
        dialog.SetDays("91");
        dialog.Mark(true);
        Wait(dialog.Pending);
        Assert.Equal("Whole days from 1 to 90.", dialog.ScratchText);
        Assert.Empty(kit.RunsOf("bench", "scratch"));
        dialog.SetDays("3");
        dialog.Mark(true);
        Wait(dialog.Pending);
        Assert.Equal(["Mark frappe-bench scratch for 3 day(s)?|Mark Scratch"], asked);
        Assert.Equal(["bench", "scratch", PageKit.BenchPath, "--ttl", "3", "--yes", "--json"], Assert.Single(kit.RunsOf("bench", "scratch")));
        Assert.Equal("frappe-bench is a scratch bench for 3 day(s).", dialog.ScratchText);
        dialog.Mark(false);
        Wait(dialog.Pending);
        Assert.Equal(["bench", "scratch", PageKit.BenchPath, "--clear", "--yes", "--json"], kit.RunsOf("bench", "scratch")[1]);
    });

    [Fact]
    public void ADialogShowsOnlyTheSectionsOfTheCommandsTheCliLists() => Sta.Run(() =>
    {
        var kit = new PageKit();
        var dialog = MakeDialog(kit, "db orphans");
        Wait(dialog.Pending);
        Assert.Empty(dialog.GcLines);
        Assert.Equal(["db", "orphans", "--json"], Assert.Single(kit.Runner.Runs).Args);
        Assert.Null(FindButton(dialog, "Mark frappe-bench scratch"));
    });
}
