using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>Tray parity, part 1 (issue 187), in the windows: what the Overview and Health offer once the CLI says it has the command.</summary>
public class Parity187ViewTests
{
    private const string Path = "/home/akash/frappe-bench";

    private sealed class Rig
    {
        public OverviewView View = null!;
        public ScriptedStreamRunner Runner = null!;
        public PageServices Services = null!;
        public List<PlanReviewRequest> Plans = [];
        public List<TerminalLaunch> Terminals = [];
        public List<string> Calls = [];
    }

    private static Rig Make(string autostart = "autostart-off.txt", bool catalogue = true, bool planApplied = true)
    {
        var rig = new Rig();
        (rig.Services, rig.Runner) = ScriptedServices();
        if (catalogue) rig.Runner.On("commands").Print(Fixture("commands.json"));
        rig.Runner.On("autostart").Print(Fixture(autostart));
        rig.Runner.On("up").Print(Fixture("up-services-only.jsonl"));
        rig.Runner.On("down").Print(Fixture("up-services-only.jsonl"));
        rig.Runner.On("autostart", "on").Print("  [OK] autostart on");
        rig.Runner.On("ports", "check").Print(Fixture("ports-check-clean.json"));
        rig.Runner.On("lock", "check").Print(Fixture("health-lock-sync.json"));
        rig.Services.Distro = () => "Ubuntu-24.04";
        rig.Services.OpenTerminal = t => { rig.Terminals.Add(t); return null; };
        rig.Services.ReviewPlan = request =>
        {
            rig.Plans.Add(request);
            return Task.FromResult(new PlanOutcome(planApplied, false, null));
        };
        rig.View = new OverviewView(new OverviewActions
        {
            Restart = _ => { rig.Calls.Add("restart"); return Task.FromResult(ActionResult.Success); },
        });
        rig.View.Attach(rig.Services, (_, _) => { });
        return rig;
    }

    private static void Learn(Rig rig, BenchStatus bench)
    {
        rig.View.Bind(bench, null);
        Pump(() => rig.View.EnsureCliFactsAsync().Forget(), () => rig.View.MoreItems.Contains("Watch Assets in Terminal"));
    }

    private static void ClickItem(Rig rig, string title) => rig.View.MoreMenuItems[title].RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));

    [Fact]
    public void TheMoreMenuOffersTheNewCommandsOnlyAfterTheCliListsThem() => Sta.Run(() =>
    {
        var rig = Make();
        rig.View.Bind(BenchWith(BenchState.Stopped, "manual"), null);
        Assert.Equal(["Open Console", "Open Database"], rig.View.MoreItems); // nothing is offered before the CLI has said what it knows
        Learn(rig, BenchWith(BenchState.Stopped, "manual"));
        Assert.Equal(["Open Console", "Open Database", "Start Services Only", "Stop Services", "Refresh Service...", "Write Lockfile...", "Apply Lockfile...",
            "Watch Assets in Terminal", "Run in Foreground in Terminal"], rig.View.MoreItems);
        Assert.True(rig.View.MoreMenuItems["Start Services Only"].IsEnabled);
        AssertEveryControlIsNamed(rig.View);
    });

    [Fact]
    public void AnOldCliWithoutTheCatalogueGetsTheMenuItAlwaysHad() => Sta.Run(() =>
    {
        var rig = Make(catalogue: false);
        rig.View.Bind(BenchWith(BenchState.Stopped, "manual"), null);
        rig.View.EnsureCliFactsAsync().GetAwaiter().GetResult();
        Assert.Equal(["Open Console", "Open Database"], rig.View.MoreItems);
        Assert.Null(rig.View.AutostartToggle);
    });

    [Fact]
    public void StartServicesOnlyRunsUpWithItsFlagOnAStoppedBenchOnly() => Sta.Run(() =>
    {
        var rig = Make();
        Learn(rig, BenchWith(BenchState.Running));
        Assert.False(rig.View.MoreMenuItems["Start Services Only"].IsEnabled); // a running bench has its Redis
        rig.View.Bind(BenchWith(BenchState.Stopped, "manual"), null);
        rig.View.EnsureCliFactsAsync().GetAwaiter().GetResult();
        Assert.True(rig.View.MoreMenuItems["Start Services Only"].IsEnabled);
        Pump(() => ClickItem(rig, "Start Services Only"), () => rig.View.Lines.Any(l => l.StartsWith("The Redis of this bench is up", StringComparison.Ordinal)));
        Assert.Contains(rig.Runner.Runs, r => r.Args.SequenceEqual(["up", "--services-only", "--json", "--bench-dir", Path]));
        Assert.DoesNotContain(rig.Runner.Runs, r => r.Args[0] == "down");
    });

    [Fact]
    public void AutostartIsReadOnceAndChangedWithOnOrOff() => Sta.Run(() =>
    {
        var rig = Make();
        Learn(rig, BenchWith(BenchState.Stopped, "manual"));
        Pump(() => { }, () => rig.View.AutostartToggle is { IsEnabled: true });
        Assert.False(rig.View.AutostartToggle!.IsChecked);
        Assert.Single(rig.Runner.Runs, r => r.Args[0] == "autostart");
        Pump(() => ClickToggle(rig.View.AutostartToggle!), () => rig.View.AutostartToggle is { IsChecked: true });
        Assert.Contains(rig.Runner.Runs, r => r.Args.SequenceEqual(["autostart", "on", "--bench-dir", Path]));
        rig.View.EnsureCliFactsAsync().GetAwaiter().GetResult();
        Assert.Single(rig.Runner.Runs, r => r.Args is ["autostart", "--bench-dir", _]); // not read again
    });

    [Fact]
    public void WriteLockfileShowsTheSheetWithTheDryRunFirstAndComparesAgain() => Sta.Run(() =>
    {
        var rig = Make();
        Learn(rig, BenchWith(BenchState.Stopped, "manual"));
        Pump(() => ClickItem(rig, "Write Lockfile..."), () => rig.Runner.Runs.Count(r => r.Args is ["lock", "check", ..]) >= 1);
        var request = rig.Plans.Single();
        Assert.Equal(["lock", "write", "--dry-run", "--bench-dir", Path], request.PlanArgs);
        Assert.True(request.PlanIsText);
        Assert.False(request.RequiresToken);
        Assert.DoesNotContain(rig.Runner.Runs, r => r.Args.Contains("--yes")); // nothing was written by opening the sheet
    });

    [Fact]
    public void WatchAndForegroundOpenInATerminalTheCloseOfWhichEndsThem() => Sta.Run(() =>
    {
        var rig = Make();
        Learn(rig, BenchWith(BenchState.Stopped, "manual"));
        ClickItem(rig, "Watch Assets in Terminal");
        ClickItem(rig, "Run in Foreground in Terminal");
        Assert.Equal(["watch", "fg"], rig.Terminals.Select(t => t.Command[4]));
        Assert.All(rig.Terminals, t => Assert.Equal(Path, t.Command[6]));
        Assert.DoesNotContain(rig.Runner.Runs, r => r.Args[0] is "watch" or "fg"); // the tray never runs them itself
    });

    [Fact]
    public void TheSchedulerGoesThroughTheServicePlanWhenTheCliHasApply() => Sta.Run(() =>
    {
        var rig = Make();
        Learn(rig, BenchWith(BenchState.Running) with { Scheduler = false });
        Pump(() => ClickToggle(rig.View.SchedulerToggle!), () => rig.Calls.Contains("restart"));
        var request = rig.Plans.Single();
        Assert.Equal(["service", "--with-schedule", "--bench-dir", Path, "--dry-run", "--json"], request.PlanArgs);
        Assert.True(request.UsesSudoEnv);
        Assert.DoesNotContain(rig.Runner.Runs, r => r.Args.Contains("--yes")); // no direct service --yes any more
    });

    [Fact]
    public void ADeclinedServicePlanChangesNothingAndDoesNotRestart() => Sta.Run(() =>
    {
        var rig = Make(planApplied: false);
        Learn(rig, BenchWith(BenchState.Running) with { Scheduler = false });
        Pump(() => ClickToggle(rig.View.SchedulerToggle!), () => rig.Plans.Count == 1);
        Pump(() => { }, () => true);
        Assert.Empty(rig.Calls);
    });

    // --- Health: acknowledge ---

    private static (HealthView View, ScriptedStreamRunner Runner) Health(bool catalogue, bool acked)
    {
        var (services, runner) = ScriptedServices();
        var doc = (JsonObject)JsonNode.Parse(string.Join('\n', Fixture("health-doctor.json")))!;
        foreach (var c in doc["checks"]!.AsArray().OfType<JsonObject>().Where(c => (string?)c["id"] == "hosts")) c["acked"] = acked;
        runner.On("doctor", "--json").Print(doc.ToJsonString());
        runner.On("doctor", "--ack").Print(Fixture("doctor-ack.json"));
        runner.On("doctor", "--unack").Print(Fixture("doctor-ack.json"));
        if (catalogue) runner.On("commands").Print(Fixture("commands.json"));
        runner.On("setup", "check").Print(Fixture("health-setup-check.json"));
        SynchronizationContext.SetSynchronizationContext(null);
        var view = new HealthView(services, autoRun: false);
        view.Bind(new BenchContext(BenchWith(BenchState.Running), null));
        view.Model!.RunAsync().GetAwaiter().GetResult();
        Wait(view.LoadCommandsAsync());
        Drain();
        view.Refresh();
        return (view, runner);
    }

    [Fact]
    public void OnlyAWarningGetsAnAcknowledgeButtonAndOnlyWhenTheCliHasIt() => Sta.Run(() =>
    {
        var (view, _) = Health(catalogue: true, acked: false);
        Assert.Equal(["Acknowledge Hosts entry"], ButtonLabels(view).Where(l => l.Contains("cknowledge", StringComparison.Ordinal))); // not the failure, not the unknown level
        var (old, _) = Health(catalogue: false, acked: false);
        Assert.DoesNotContain(ButtonLabels(old), l => l.Contains("cknowledge", StringComparison.Ordinal));
    });

    [Fact]
    public void AClickAcknowledgesAndAnAcknowledgedWarningCanBeTakenBack() => Sta.Run(() =>
    {
        var (view, runner) = Health(catalogue: true, acked: false);
        Pump(() => Click(ButtonNamed(view, "Acknowledge Hosts entry")), () => runner.Runs.Count(r => r.Args[0] == "doctor" && r.Args.Contains("--json") && !r.Args.Contains("--ack")) >= 2);
        Assert.Contains(runner.Runs, r => r.Args.SequenceEqual(["doctor", "--ack", "hosts", "--json", "--bench-dir", Path]));

        var (again, second) = Health(catalogue: true, acked: true);
        Assert.Contains("acknowledged", again.Lines);
        Pump(() => Click(ButtonNamed(again, "Undo acknowledging Hosts entry")), () => second.Runs.Any(r => r.Args.Contains("--unack")));
        Assert.Contains(second.Runs, r => r.Args.SequenceEqual(["doctor", "--unack", "hosts", "--json", "--bench-dir", Path]));
    });

    [Fact]
    public void NothingAcknowledgesByItself() => Sta.Run(() =>
    {
        var (_, runner) = Health(catalogue: true, acked: false);
        Assert.DoesNotContain(runner.Runs, r => r.Args.Contains("--ack") || r.Args.Contains("--unack"));
    });
}
