using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>Tray parity, part 3 (issue 187), in the windows: snapshots and rollback, leases, History, the charts, operations and Run Bench Command.</summary>
public class Parity187cViewTests
{
    private const string Lease = "The bench /home/akash/frappe-bench is leased by claude-qa until 2027-01-15T08:20:00Z (running the QA suite). Nothing was changed.";

    /// <summary>The recorded <c>commands --json</c> with the 0.9 commands this part reads added, so a catalogue lists exactly what a test needs.</summary>
    private static string CommandsWith(params string[] names)
    {
        var doc = (JsonObject)JsonNode.Parse(string.Join('\n', Fixture("commands.json")))!;
        foreach (var name in names)
        {
            var flags = new JsonArray();
            if (name == "op list") flags.Add(new JsonObject { ["name"] = "--running", ["help"] = "Only the runs that go on." });
            ((JsonArray)doc["commands"]!).Add(new JsonObject { ["name"] = name, ["usage"] = "benchbar " + name, ["summary"] = name, ["mutating"] = false, ["flags"] = flags });
        }
        return doc.ToJsonString();
    }

    private static string Snapshots(bool undoPoint = false)
    {
        var doc = (JsonObject)JsonNode.Parse(string.Join('\n', Fixture("snapshots-list.json")))!;
        if (undoPoint) ((JsonObject)((JsonArray)doc["snapshots"]!)[0]!)["before_rollback"] = true;
        return doc.ToJsonString();
    }

    private static (SitesView View, PageKit Kit) MakeSites(bool snapshots = true, bool undoPoint = false)
    {
        var kit = new PageKit();
        kit.Runner.On("commands").Print(snapshots ? CommandsWith("site snapshots", "site rollback") : CommandsWith());
        kit.Runner.On("site", "snapshots").Print(Snapshots(undoPoint));
        kit.Runner.On("site", "snapshot", "drop").Print(Fixture("snapshot-drop.json"));
        kit.Runner.On("site", "snapshot").Print(Fixture("snapshot-take.json"));
        kit.Runner.On(a => a is ["site", "rollback", ..] && a.Contains("--dry-run")).Print(Fixture("snapshot-rollback-plan.json"));
        kit.Runner.On(a => a is ["site", "rollback", ..] && a.Contains("--apply")).Print(Fixture("snapshot-rollback.json"));
        Wait(kit.Services.Commands.GetAsync());
        var view = new SitesView(kit.Services) { Clock = () => DateTimeOffset.Parse("2026-11-21T21:07:50Z") };
        view.Bind(new BenchContext(Bench(), null));
        return (view, kit);
    }

    private static void OpenSnapshots(SitesView view, PageKit kit, string site = "one.localhost")
    {
        Pump(() => ClickMenu(view, "More actions for " + site, "Snapshots..."), () => view.Pending.IsCompleted && view.OpenPanel is not null && Texts(view.OpenPanel).Contains("Before upgrade"));
    }

    // --- row 1: snapshots ---

    [Fact]
    public void SnapshotsIsInTheSiteMenuOnlyWhenTheCliHasBothCommands() => Sta.Run(() =>
    {
        var (with, _) = MakeSites();
        Assert.Contains(MenuOf(with, "More actions for one.localhost"), i => (string)i.Header == "Snapshots...");
        var (without, _) = MakeSites(snapshots: false);
        Assert.DoesNotContain(MenuOf(without, "More actions for one.localhost"), i => (string)i.Header == "Snapshots...");
        var unasked = new SitesView(new PageKit().Services); // the tab starts no call of its own
        unasked.Bind(new BenchContext(Bench(), null));
        Assert.Null(unasked.SnapshotsAvailable);
        Assert.DoesNotContain(MenuOf(unasked, "More actions for one.localhost"), i => (string)i.Header == "Snapshots...");
    });

    [Fact]
    public void ThePanelListsTheSnapshotsWithAgeSizeAndWhetherTheAppsMatch() => Sta.Run(() =>
    {
        var (view, kit) = MakeSites();
        OpenSnapshots(view, kit);
        var texts = Texts(view.OpenPanel!);
        Assert.Contains("Snapshots of one.localhost", texts);
        Assert.Contains("20261121_090000", texts); // no label: the stamp
        Assert.Contains(texts, t => t.StartsWith("3 hours ago, ", StringComparison.Ordinal) && t.EndsWith(" KB, with files", StringComparison.Ordinal));
        Assert.Contains("Apps changed since: erpnext", texts);
        Assert.Contains(texts, t => t.StartsWith("The snapshots hold ", StringComparison.Ordinal));
        Assert.Equal(["site", "snapshots", "one.localhost", "--json", "--bench-dir", PageKit.BenchPath], kit.Runner.Runs.Last(r => r.Args[0] == "site").Args);
        AssertEveryControlIsNamed(view.OpenPanel!);
    });

    [Fact]
    public void TakeSnapshotSendsTheLabelAndListsAgain() => Sta.Run(() =>
    {
        var (view, kit) = MakeSites();
        OpenSnapshots(view, kit);
        view.SnapshotLabelBox!.Text = "  before the upgrade ";
        Pump(() => Click(ButtonNamed(view, "Take a snapshot of one.localhost")), () => view.Pending.IsCompleted && kit.RunsOf("site", "snapshots").Length == 2
            && view.OpenPanel is not null && Texts(view.OpenPanel).Any(t => t.StartsWith("Snapshot taken: Before upgrade", StringComparison.Ordinal)));
        var take = kit.RunsOf("site", "snapshot").Single(a => a.Contains("--label"));
        Assert.Equal(["site", "snapshot", "one.localhost", "--label", "before the upgrade", "--json", "--bench-dir", PageKit.BenchPath], take);
    });

    [Fact]
    public void ALabelTheCliWouldRefuseIsRefusedBeforeAnyCall() => Sta.Run(() =>
    {
        var (view, kit) = MakeSites();
        OpenSnapshots(view, kit);
        view.SnapshotLabelBox!.Text = "say \"hi\"";
        Pump(() => Click(ButtonNamed(view, "Take a snapshot of one.localhost")), () => view.Pending.IsCompleted);
        Assert.DoesNotContain(kit.RunsOf("site", "snapshot"), a => a.Contains("--label"));
        Assert.Contains("No quotes, backslashes or line breaks.", Texts(view.OpenPanel!));
    });

    [Fact]
    public void RollBackAsksForTheSiteNameThenRunsThePlanByItsTokenAsThePerson() => Sta.Run(() =>
    {
        var (view, kit) = MakeSites();
        OpenSnapshots(view, kit);
        Pump(() => Click(ButtonNamed(view, "Roll one.localhost back to Before upgrade")), () => view.Pending.IsCompleted && kit.RunsOf("site", "rollback").Length == 2);
        var typed = Assert.Single(kit.Typed);
        Assert.Equal("one.localhost", typed.Expected);
        Assert.Contains("default site", typed.Message); // one.localhost is the default site of the bench: labelled
        var request = Assert.Single(kit.Plans);
        Assert.Equal("Roll one.localhost back", request.Title);
        var runs = kit.RunsOf("site", "rollback");
        Assert.Equal(["--dry-run", "--json"], runs[0][^2..]);
        Assert.Equal("--apply", runs[1][^4]);
        Assert.Equal("92c48b5c022f153a4672ee88277c0895050ab6df2b24a1ee434790cbda1c4b5a", runs[1][^3]);
        Assert.All(kit.Runner.Runs.Where(r => r.Args.Length > 1 && r.Args[1] == "rollback"), r => Assert.Equal("0", r.Env["BENCHBAR_NONINTERACTIVE"]));
        Assert.True(kit.Refreshes >= 1);
    });

    [Fact]
    public void ANameThatIsNotTheSitesRunsNothing() => Sta.Run(() =>
    {
        var (view, kit) = MakeSites();
        kit.Answer = _ => "two.localhost";
        OpenSnapshots(view, kit);
        Pump(() => Click(ButtonNamed(view, "Roll one.localhost back to Before upgrade")), () => view.Pending.IsCompleted);
        Assert.Empty(kit.Plans);
        Assert.Empty(kit.RunsOf("site", "rollback"));
        kit.Answer = _ => null; // cancelled
        Pump(() => Click(ButtonNamed(view, "Roll one.localhost back to Before upgrade")), () => view.Pending.IsCompleted);
        Assert.Empty(kit.RunsOf("site", "rollback"));
    });

    [Fact]
    public void RemoveAsksFirstAndNeverPassesForceUndoPoint() => Sta.Run(() =>
    {
        var (view, kit) = MakeSites();
        OpenSnapshots(view, kit);
        var asked = new List<string>();
        kit.Services.Confirm = (title, _, _) =>
        {
            asked.Add(title);
            return false;
        };
        Pump(() => Click(ButtonNamed(view, "Remove the snapshot Before upgrade")), () => view.Pending.IsCompleted);
        Assert.Equal(["Remove the snapshot Before upgrade?"], asked);
        Assert.Empty(kit.RunsOf("site", "snapshot", "drop")); // a no changes nothing
        kit.Services.Confirm = (_, _, _) => true;
        Pump(() => Click(ButtonNamed(view, "Remove the snapshot Before upgrade")), () => view.Pending.IsCompleted && kit.RunsOf("site", "snapshots").Length == 2);
        var drop = Assert.Single(kit.RunsOf("site", "snapshot", "drop"));
        Assert.Equal(["site", "snapshot", "drop", "one.localhost", "20261120_160102-before-upgrade", "--yes", "--json", "--bench-dir", PageKit.BenchPath], drop);
        Assert.Equal("0", kit.Runner.Runs.Single(r => r.Args.Contains("drop")).Env["BENCHBAR_NONINTERACTIVE"]);
    });

    [Fact]
    public void TheUndoPointOfTheLastRollbackCannotBeRemovedFromHere() => Sta.Run(() =>
    {
        var (view, kit) = MakeSites(undoPoint: true);
        OpenSnapshots(view, kit);
        Assert.False(ButtonNamed(view, "Remove the snapshot 20261121_090000").IsEnabled);
        Assert.True(ButtonNamed(view, "Remove the snapshot Before upgrade").IsEnabled);
        Assert.Contains("The undo point of the last rollback", Texts(view.OpenPanel!));
    });

    // --- row 2: leases ---

    private static (OverviewView View, PageKit Kit, List<string> Calls, List<string> Asked) MakeOverview(bool lease = true, string commands = "")
    {
        var kit = new PageKit();
        var calls = new List<string>();
        var asked = new List<string>();
        kit.Runner.On("commands").Print(commands.Length > 0 ? commands : CommandsWith(lease ? new[] { "lease list", "stats", "op list", "run" } : []));
        kit.Runner.On("ports", "check").Print(Fixture("ports-check-clean.json"));
        kit.Runner.On("lease", "list").Print(Fixture("lease-list.json"));
        kit.Runner.On("stats").Print(Fixture("stats.json"));
        kit.Runner.On("op", "list").Print(Fixture("op-list.json"));
        kit.Runner.On("restart");
        var actions = new OverviewActions
        {
            Restart = _ =>
            {
                calls.Add("restart");
                return Task.FromResult(ActionResult.Failure(Lease));
            },
        };
        var view = new OverviewView(actions);
        view.Attach(kit.Services, (_, _) => { });
        kit.Services.Confirm = (title, detail, button) =>
        {
            asked.Add(title + "|" + detail + "|" + button);
            return true;
        };
        return (view, kit, calls, asked);
    }

    private static BenchStatus Running() => BenchWith(BenchState.Running);

    /// <summary>Binds the Overview and waits until the CLI's catalogue was read and the page rebuilt with it (the lockfile entry is one of its markers).</summary>
    private static void BindWithCatalogue(OverviewView view, Func<bool>? done = null) =>
        Pump(() =>
        {
            view.Bind(Running(), null);
            view.EnsureCliFactsAsync().Forget();
        }, () => view.MoreItems.Contains("Write Lockfile...") && (done?.Invoke() ?? true));

    [Fact]
    public void ARefusedRestartShowsTheHolderAndBreakLeaseAsksThenRunsTheSameCommandWithTheFlag() => Sta.Run(() =>
    {
        var (view, kit, calls, asked) = MakeOverview();
        view.Bind(Running(), null);
        Pump(() => Click(ButtonNamed(view, "Restart frappe-bench")), () => view.BreakLeaseButton is not null);
        Assert.Equal(["restart"], calls);
        Assert.Contains(view.Lines, l => l.StartsWith("Held by claude-qa until ", StringComparison.Ordinal) && l.EndsWith("(running the QA suite).", StringComparison.Ordinal));
        Assert.Empty(asked); // showing the holder asks nothing and breaks nothing
        Assert.DoesNotContain(kit.Runner.Runs, r => r.Args.Contains("--break-lease"));

        Pump(() => Click(view.BreakLeaseButton!), () => kit.RunsOf("restart").Length == 1);
        var question = Assert.Single(asked);
        Assert.StartsWith("Break the lease of claude-qa?|", question);
        Assert.EndsWith("|Break Lease and Run", question);
        Assert.Contains("Restart frappe-bench", question);
        var run = kit.Runner.Runs.Single(r => r.Args[0] == "restart");
        Assert.Equal(["restart", "--break-lease", "--bench-dir", PageKit.BenchPath], run.Args);
        Assert.Equal("0", run.Env["BENCHBAR_NONINTERACTIVE"]);
    });

    [Fact]
    public void ANoToBreakLeaseRunsNothing() => Sta.Run(() =>
    {
        var (view, kit, _, asked) = MakeOverview();
        view.Bind(Running(), null);
        Pump(() => Click(ButtonNamed(view, "Restart frappe-bench")), () => view.BreakLeaseButton is not null);
        kit.Services.Confirm = (title, _, _) =>
        {
            asked.Add(title);
            return false;
        };
        Pump(() => Click(view.BreakLeaseButton!), () => asked.Count == 1);
        Assert.Empty(kit.RunsOf("restart"));
    });

    [Fact]
    public void AFailureThatIsNotALeaseHasNoBreakLeaseButton() => Sta.Run(() =>
    {
        var (view, _, _, _) = MakeOverview();
        view.Bind(Running(), null);
        view.Bind(Running() with { Problem = "Something else is wrong." }, null);
        Assert.Null(view.BreakLeaseButton);
        Assert.DoesNotContain(ButtonLabels(view), l => l == "Break the lease of claude-qa");
    });

    [Fact]
    public void TheCardShowsLeasesChartsAndRunningOperationsWhenTheCliHasThem() => Sta.Run(() =>
    {
        var (view, kit, _, _) = MakeOverview();
        var card = () => view.Activity!;
        view.Activity!.Clock = () => DateTimeOffset.Parse("2027-01-15T08:05:00Z");
        BindWithCatalogue(view, () => card().Lines.Any(l => l.Contains("site backup")));
        Assert.Contains("Leases", card().Lines);
        Assert.Contains(card().Lines, l => l.StartsWith("Site acme.localhost is held by claude-qa until ", StringComparison.Ordinal));
        Assert.Contains("Resources", card().Lines);
        Assert.Contains(card().Lines, l => l.StartsWith("CPU 112.8", StringComparison.Ordinal) || l.StartsWith("CPU 112,8", StringComparison.Ordinal));
        Assert.Equal((1, 1), card().ChartPoints);
        Assert.Contains("Running now", card().Lines);
        AssertEveryControlIsNamed(card());
        // a bench the card is bound to is asked for what it shows only: no lease is taken, renewed or released
        Assert.DoesNotContain(kit.Runner.Runs, r => r.Args is ["lease", "take" or "renew" or "release", ..]);
    });

    [Fact]
    public void AnOlderCliGetsNoCallForWhatItDoesNotList() => Sta.Run(() =>
    {
        var (view, kit, _, _) = MakeOverview(lease: false);
        BindWithCatalogue(view);
        Assert.DoesNotContain(kit.Runner.Runs, r => r.Args[0] is "lease" or "stats" or "op");
        Assert.Empty(view.Activity!.Lines);
    });

    [Fact]
    public void ThePollingTimerRunsOnlyWhileTheCardIsOnScreen() => Sta.Run(() =>
    {
        var (view, kit, _, _) = MakeOverview();
        var card = view.Activity!;
        Assert.False(card.Polling); // not bound, not shown: no timer, no call
        Assert.Equal(TimeSpan.FromSeconds(5), card.Interval);
        view.Bind(Running(), null);
        Assert.False(card.Polling); // bound, but not on screen (no window): still no timer
        Assert.DoesNotContain(kit.Runner.Runs, r => r.Args[0] is "lease" or "stats" or "op"); // and the CLI was asked nothing about them
    });

    // --- row 3: history ---

    [Fact]
    public void HistoryListsWhatRanWhoStartedItAndHowItEnded() => Sta.Run(() =>
    {
        var kit = new PageKit();
        kit.Runner.On("commands").Print(CommandsWith("history"));
        kit.Runner.On("history").Print(Fixture("history.json"));
        var view = new HistoryView(kit.Services) { Clock = () => DateTimeOffset.Parse("2026-11-21T19:00:00Z") };
        Pump(() => view.OnShown(), () => view.Entries.Count > 0 && !view.IsLoading);
        Assert.Contains("site rollback acme.localhost", view.Lines);
        Assert.Contains("A script, Done", view.Lines);
        Assert.Contains("snapshot acme.localhost, site acme.localhost", view.Lines);
        Assert.Contains("frappe-bench", view.Lines);
        Assert.Equal(["history", "--json", "--limit", "100"], kit.Runner.Runs.Single(r => r.Args[0] == "history").Args);
        Assert.NotNull(FindButton(view, "Refresh the history"));
        AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void HistoryOnACliWithoutItSaysSoAndAFailedReadSaysWhy() => Sta.Run(() =>
    {
        var kit = new PageKit();
        kit.Runner.On("commands").Print(CommandsWith());
        var view = new HistoryView(kit.Services);
        Pump(() => view.OnShown(), () => !view.IsLoading && view.Lines.Count > 0);
        Assert.Contains(view.Lines, l => l.StartsWith("This version of benchbar has no history.", StringComparison.Ordinal));
        Assert.DoesNotContain(kit.Runner.Runs, r => r.Args[0] == "history");

        var failing = new PageKit();
        failing.Runner.On("commands").Print(CommandsWith("history"));
        failing.Runner.On("history").Fail(1, "The state folder is not readable.");
        var second = new HistoryView(failing.Services);
        Pump(() => second.OnShown(), () => !second.IsLoading && second.Lines.Count > 0);
        Assert.Contains("The history could not be read: The state folder is not readable.", second.Lines);
    });

    [Fact]
    public void HistoryIsReadWhenShownAndNeverOnATimer() => Sta.Run(() =>
    {
        var kit = new PageKit();
        kit.Runner.On("commands").Print(CommandsWith("history"));
        kit.Runner.On("history").Print(Fixture("history.json"));
        var view = new HistoryView(kit.Services);
        Assert.Empty(kit.Runner.Runs); // building the pane asks nothing
        Pump(() => view.OnShown(), () => view.Entries.Count > 0 && !view.IsLoading);
        Pump(() => Click(ButtonNamed(view, "Refresh the history")), () => kit.RunsOf("history").Length == 2 && !view.IsLoading);
    });

    [Fact]
    public void TheSidebarHasAHistoryRowBelowTheBenches() => Sta.Run(() =>
    {
        Assert.Contains(SidebarTool.History, SidebarTools.All);
        Assert.Equal("History", SidebarTools.Title(SidebarTool.History));
    });

    // --- row 6: run ---

    private static RunCommandDialog MakeDialog(PageKit kit, string site = "one.localhost") =>
        new(kit.Services, Bench(), site, Theme, null);

    [Fact]
    public void TheDialogOffersTheAllowListAndTheButtonSaysWhetherItIsAReadOrAChange() => Sta.Run(() =>
    {
        var dialog = MakeDialog(new PageKit());
        Assert.Equal("Review Plan...", dialog.GoLabel); // migrate is first
        dialog.Choose("doctor");
        Assert.Equal("Run", dialog.GoLabel);
        Assert.True(dialog.SiteShown);
        dialog.Choose("build");
        Assert.False(dialog.SiteShown);
        Assert.Contains("--app", dialog.HelpText);
        dialog.Choose("clear-cache");
        Assert.Contains("takes no flags", dialog.HelpText);
        AssertEveryControlIsNamed(dialog);
    });

    [Fact]
    public void AReadRunsAtOnceAndShowsItsOutput() => Sta.Run(() =>
    {
        var kit = new PageKit();
        kit.Runner.On("run").Print(Fixture("run-read.json"));
        var dialog = MakeDialog(kit);
        dialog.Choose("list-apps", "two.localhost", "--format json");
        Pump(() => dialog.Press(), () => dialog.OutputText.Contains("erpnext 15.38.1"));
        Assert.Equal(["run", "--site", "two.localhost", "--bench-dir", PageKit.BenchPath, "--json", "--", "list-apps", "--format", "json"], kit.Runner.Runs.Single().Args);
        Assert.Empty(kit.Plans); // a read has no plan
    });

    [Fact]
    public void AChangeIsNotRunByTheDialogItHandsTheChoiceToThePlanSheet() => Sta.Run(() =>
    {
        var kit = new PageKit();
        var dialog = MakeDialog(kit);
        dialog.Choose("migrate", "one.localhost", "--skip-failing");
        dialog.Press();
        Assert.Equal(new RunInput("migrate", "one.localhost", "--skip-failing"), dialog.Chosen);
        Assert.Empty(kit.Runner.Runs);
    });

    [Fact]
    public void AFlagTheCommandDoesNotTakeIsRefusedInTheDialogBeforeAnyCall() => Sta.Run(() =>
    {
        var kit = new PageKit();
        var dialog = MakeDialog(kit);
        dialog.Choose("clear-cache", "one.localhost", "--all");
        dialog.Press();
        Assert.Equal("clear-cache takes no flags.", dialog.ProblemText);
        Assert.Null(dialog.Chosen);
        Assert.Empty(kit.Runner.Runs);
    });

    [Fact]
    public void RunBenchCommandIsInTheMoreMenuOnlyWhenTheCliHasRunAndTheChangeGoesThroughThePlanSheet() => Sta.Run(() =>
    {
        var (without, _, _, _) = MakeOverview(lease: false);
        BindWithCatalogue(without);
        Assert.DoesNotContain("Run Bench Command...", without.MoreItems);
        var (view, kit, _, _) = MakeOverview();
        kit.Runner.On(a => a[0] == "run" && a.Contains("--dry-run")).Print(Fixture("run-plan.json"));
        kit.Runner.On(a => a[0] == "run" && a.Contains("--apply")).Print("""{"schema_version":1,"event":"done","exit":0,"changed":[],"warnings":[],"next_actions":[]}""");
        BindWithCatalogue(view);
        Assert.Contains("Run Bench Command...", view.MoreItems);
        view.AskRunCommand = (_, site) => new RunInput("migrate", site ?? "one.localhost", "--skip-failing");
        Pump(() => view.RunBenchCommandAsync().Forget(), () => kit.RunsOf("run").Length == 2);
        var request = Assert.Single(kit.Plans);
        Assert.Equal("Run migrate", request.Title);
        var apply = kit.RunsOf("run")[1];
        Assert.Equal("8f1c5d0e2a7b4c9d1e3f6a8b0c2d4e6f8a0b1c3d5e7f9a1b2c4d6e8f0a1b3c5d", apply[apply.ToList().IndexOf("--apply") + 1]);
        Assert.Equal("--", apply[^3]);
    });
}
