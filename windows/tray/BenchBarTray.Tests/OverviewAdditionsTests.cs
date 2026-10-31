using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>The Overview's guidance row, port check before Start and Restart, Scheduler, lockfile badge, More menu, uptime and port settings.</summary>
public class OverviewAdditionsTests
{
    private const string Path = "/home/akash/frappe-bench";

    private sealed class Rig
    {
        public OverviewView View = null!;
        public ScriptedStreamRunner Runner = null!;
        public PageServices Services = null!;
        public List<string> Calls = [];
        public List<(BenchTab Tab, bool Repair)> Navigated = [];
        public List<(bool Start, bool Settings)> PortSheets = [];
        public List<TerminalLaunch> Terminals = [];
        public int Refreshes;
    }

    private static Rig Make(string ports = "ports-check-clean.json", bool confirm = true)
    {
        var rig = new Rig();
        (rig.Services, rig.Runner) = ScriptedServices();
        rig.Runner.On("ports", "check").Print(Fixture(ports));
        rig.Runner.On("service");
        rig.Runner.On("lock").Print(Fixture("health-lock-drift.json")).Fail(1);
        rig.Services.Distro = () => "Ubuntu-24.04";
        rig.Services.OpenTerminal = t =>
        {
            rig.Terminals.Add(t);
            return null;
        };
        rig.Services.RefreshNow = () => rig.Refreshes++;
        var actions = new OverviewActions
        {
            StartStop = b => { rig.Calls.Add("startstop"); return Task.FromResult(ActionResult.Success); },
            Restart = b => { rig.Calls.Add("restart"); return Task.FromResult(ActionResult.Success); },
        };
        rig.View = new OverviewView(actions);
        rig.View.Attach(rig.Services, (tab, repair) => rig.Navigated.Add((tab, repair)));
        rig.View.Confirm = (_, _) => confirm;
        rig.View.ShowPortSetup = (_, start, settings) => rig.PortSheets.Add((start, settings));
        return rig;
    }

    private static Button Named(DependencyObject root, string name) =>
        Walk(root).OfType<Button>().Single(b => System.Windows.Automation.AutomationProperties.GetName(b).StartsWith(name, StringComparison.Ordinal));

    private static IEnumerable<string> PortCalls(Rig rig) => rig.Runner.Runs.Select(r => string.Join(' ', r.Args)).Where(a => a.StartsWith("ports", StringComparison.Ordinal));

    // --- start and restart: the ports first ---

    [Fact]
    public void AConflictRefusesStartShowsTheReasonAndOffersTheReviewWithoutKillingAnything() => Sta.Run(() =>
    {
        var rig = Make("ports-check-conflict.json");
        rig.View.Bind(BenchWith(BenchState.Stopped, "manual"), null);
        Pump(() => Click(rig.View.StartStopButton!), () => rig.View.Lines.Contains("9000 reserved by /home/akash/b2") || rig.View.Lines.Any(l => l.Contains("9000 reserved by /home/akash/b2")));
        Assert.Empty(rig.Calls); // Start never reached the controller
        Assert.Contains(rig.View.Lines, l => l.StartsWith(PortGuard.ConflictLead, StringComparison.Ordinal) && l.Contains("8000 has a listener: pid 4242"));
        Assert.Equal("Another program holds one of its ports.", rig.View.Guidance!.Text);
        Assert.Equal("Review Port Conflict...", rig.View.Guidance.ButtonLabel);
        // only the check ran: no up, down, restart, kill
        Assert.Equal(["ports check --json --bench-dir " + Path], PortCalls(rig));
        Assert.All(rig.Runner.Runs, r => Assert.Equal("ports", r.Args[0]));

        Click(rig.View.Guidance.Button!);
        Assert.Equal([(true, false)], rig.PortSheets); // Resolve and Start
        AssertEveryControlIsNamed(rig.View);
    });

    [Fact]
    public void ARestartIsRefusedOnAConflictToo() => Sta.Run(() =>
    {
        var rig = Make("ports-check-conflict.json");
        rig.View.Bind(BenchWith(BenchState.Running), null);
        Pump(() => Click(Named(rig.View, "Restart")), () => rig.View.Lines.Any(l => l.StartsWith(PortGuard.ConflictLead, StringComparison.Ordinal)));
        Assert.Empty(rig.Calls);
        Assert.Single(PortCalls(rig));
    });

    [Fact]
    public void AStartWithFreePortsGoesToTheController() => Sta.Run(() =>
    {
        var rig = Make();
        rig.View.Bind(BenchWith(BenchState.Stopped, "manual"), null);
        Pump(() => Click(rig.View.StartStopButton!), () => rig.Calls.Count == 1);
        Assert.Equal(["startstop"], rig.Calls);
        Assert.Equal(["ports check --json --bench-dir " + Path], PortCalls(rig));
    });

    [Fact]
    public void StopIsNotHeldUpByAPortCheck() => Sta.Run(() =>
    {
        var rig = Make("ports-check-conflict.json");
        rig.View.Bind(BenchWith(BenchState.Running), null);
        Pump(() => Click(rig.View.StartStopButton!), () => rig.Calls.Count == 1);
        Assert.Empty(rig.Runner.Runs);
    });

    [Fact]
    public void ThePortCheckIsSkippedWithoutServicesSoTheViewWorksAlone() => Sta.Run(() =>
    {
        var calls = 0;
        var view = new OverviewView(new OverviewActions { StartStop = _ => { calls++; return Task.FromResult(ActionResult.Success); } });
        view.Bind(BenchWith(), null);
        Click(view.StartStopButton!);
        Assert.Equal(1, calls); // synchronous: nothing awaited a check
    });

    // --- guidance ---

    [Fact]
    public void TheGuidanceRowSaysWhyAndOffersTheNextStep() => Sta.Run(() =>
    {
        var rig = Make();
        rig.View.Bind(BenchWith(BenchState.Stopped, "manual"), null);
        Assert.Equal("You stopped it.", rig.View.Guidance!.Text);
        Assert.Null(rig.View.Guidance.ButtonLabel); // Start is the button beside it already

        rig.View.Bind(BenchWith(BenchState.Crashed), null);
        Assert.Equal("View Health...", rig.View.Guidance!.ButtonLabel);
        Click(rig.View.Guidance.Button!);
        Assert.Equal([(BenchTab.Health, false)], rig.Navigated);

        rig.View.Bind(BenchWith(BenchState.Stopped, "broken"), null);
        Assert.Equal("Repair...", rig.View.Guidance!.ButtonLabel);
        Click(rig.View.Guidance.Button!);
        Assert.Equal((BenchTab.Health, true), rig.Navigated[^1]);

        rig.View.Bind(BenchWith(BenchState.Running), null);
        Assert.Null(rig.View.Guidance); // nothing to say about a bench that runs
    });

    [Fact]
    public void ABenchWithoutManagementOffersSetUpManagementAndCannotStart() => Sta.Run(() =>
    {
        var rig = Make();
        rig.View.Bind(BenchWith(BenchState.Unknown) with { RawState = "not_adopted" }, null);
        Assert.Equal("BenchBar does not manage this bench yet, so it cannot start it.", rig.View.Guidance!.Text);
        Assert.Equal("Set Up Management...", rig.View.Guidance.ButtonLabel);
        Assert.False(rig.View.StartStopButton!.IsEnabled);
        Assert.False(rig.View.MoreButton!.IsEnabled);
        Click(rig.View.Guidance.Button!);
        Assert.Equal([(false, false)], rig.PortSheets);
    });

    [Fact]
    public void PortSettingsAndSetupOpensTheSheetOnTheSettings() => Sta.Run(() =>
    {
        var rig = Make();
        rig.View.Bind(BenchWith(BenchState.Running), null);
        Click(rig.View.PortSettingsButton!);
        Assert.Equal([(false, true)], rig.PortSheets);
        Assert.Equal("Port Settings and Setup frappe-bench", System.Windows.Automation.AutomationProperties.GetName(rig.View.PortSettingsButton!));
    });

    // --- uptime and state ---

    [Fact]
    public void TheStateLineGivesTheUptimeWorkedOutFromTheStatusAlreadyRead() => Sta.Run(() =>
    {
        var rig = Make();
        var now = new DateTimeOffset(2026, 10, 30, 12, 5, 0, TimeSpan.Zero);
        rig.View.Now = () => now;
        var bench = BenchWith(BenchState.Running) with { StartedAt = now - TimeSpan.FromMinutes(125) };
        rig.View.Bind(bench, null);
        Assert.Equal("Up for 2 h 5 min", rig.View.UptimeText);
        Assert.Contains("running, up for 2 h 5 min", rig.View.Lines);
        now += TimeSpan.FromSeconds(20);
        var key = rig.View.Lines;
        rig.View.Bind(bench, null); // a poll in the same minute rebuilds nothing
        Assert.Same(key, rig.View.Lines);
        rig.View.Bind(bench with { State = BenchState.Stopped }, null);
        Assert.Null(rig.View.UptimeText);
        Assert.Contains("stopped", rig.View.Lines);
        Assert.Empty(rig.Runner.Runs); // none of this asked the CLI
    });

    // --- lockfile ---

    [Fact]
    public void LockCheckRunsWhenTheTabIsShownOnceAndOnCheckAgain() => Sta.Run(() =>
    {
        var rig = Make();
        rig.View.Bind(BenchWith(BenchState.Running), null);
        rig.View.Bind(BenchWith(BenchState.Running), null); // polls
        rig.View.Bind(BenchWith(BenchState.Stopped), null);
        Assert.Empty(rig.Runner.Runs); // a poll never runs lock check

        Pump(() => _ = rig.View.EnsureLockChecked(), () => rig.View.LockBadge is not null);
        Assert.Equal("2 differences", rig.View.LockBadge);
        Assert.Equal(["lock check --json --bench-dir " + Path], rig.Runner.Runs.Select(r => string.Join(' ', r.Args)));
        Assert.Contains("Lockfile", rig.View.Lines);
        Assert.Contains("Show differences", rig.View.Lines);

        var before = rig.Runner.Runs.Count;
        _ = rig.View.EnsureLockChecked(); // shown again: the answer is kept
        Assert.Equal(before, rig.Runner.Runs.Count);

        rig.Runner.Runs.Clear();
        Pump(() => Click(Named(rig.View, "Check the lockfile again")), () => rig.Runner.Runs.Count == 1 && !rig.View.Lines.Contains("Comparing with the lockfile..."));
        Assert.Equal(["lock check --json --bench-dir " + Path], rig.Runner.Runs.Select(r => string.Join(' ', r.Args)));
        AssertEveryControlIsNamed(rig.View);
    });

    [Fact]
    public void ABenchWithoutALockfileShowsNoLockSection() => Sta.Run(() =>
    {
        var (services, runner) = ScriptedServices();
        runner.On("lock").Fail(1, "No lockfile for /home/akash/frappe-bench (looked for benchbar.toml).");
        var view = new OverviewView(new OverviewActions());
        view.Attach(services, (_, _) => { });
        view.Bind(BenchWith(BenchState.Running), null);
        Pump(() => _ = view.EnsureLockChecked(), () => runner.Runs.Count == 1 && !view.Lines.Contains("Comparing with the lockfile..."));
        Pump(() => { }, () => true);
        Assert.Null(view.LockBadge);
        Assert.DoesNotContain("Lockfile", view.Lines);
    });

    [Fact]
    public void LockCheckNeverRunsWithoutServices() => Sta.Run(() =>
    {
        var view = new OverviewView(new OverviewActions());
        view.Bind(BenchWith(BenchState.Running), null);
        Assert.True(view.EnsureLockChecked().IsCompletedSuccessfully);
    });

    // --- scheduler ---

    [Fact]
    public void TheSchedulerToggleAsksThenRunsServiceAndRestartsARunningBench() => Sta.Run(() =>
    {
        var rig = Make();
        var bench = BenchWith(BenchState.Running) with { Scheduler = false };
        rig.View.Bind(bench, null);
        var toggle = rig.View.SchedulerToggle!;
        Assert.True(toggle.IsEnabled);
        Assert.False(toggle.IsChecked);
        Pump(() => ClickToggle(toggle), () => rig.Calls.Contains("restart"));
        var lines = rig.Runner.Runs.Select(r => string.Join(' ', r.Args)).ToList();
        Assert.Equal(["service --yes --with-schedule --bench-dir " + Path, "ports check --json --bench-dir " + Path], lines);
        Assert.Equal(1, rig.Refreshes);
        Assert.False(toggle.IsChecked); // the status says what it is: the poll shows the new value
    });

    [Fact]
    public void TurningTheSchedulerOffUsesWithoutScheduleAndASteppedBenchIsNotRestarted() => Sta.Run(() =>
    {
        var rig = Make();
        rig.View.Bind(BenchWith(BenchState.Stopped, "manual") with { Scheduler = true }, null);
        Assert.True(rig.View.SchedulerToggle!.IsChecked);
        Pump(() => ClickToggle(rig.View.SchedulerToggle!), () => rig.Refreshes == 1);
        Assert.Equal(["service --yes --without-schedule --bench-dir " + Path], rig.Runner.Runs.Select(r => string.Join(' ', r.Args)));
        Assert.Empty(rig.Calls);
    });

    [Fact]
    public void ANoToTheQuestionChangesNothingAndAnOldCliCannotChangeTheScheduler() => Sta.Run(() =>
    {
        var rig = Make(confirm: false);
        rig.View.Bind(BenchWith(BenchState.Running) with { Scheduler = false }, null);
        ClickToggle(rig.View.SchedulerToggle!);
        Pump(() => { }, () => true);
        Assert.Empty(rig.Runner.Runs);
        Assert.Empty(rig.Calls);

        rig.View.Bind(BenchWith(BenchState.Running), null);
        Assert.False(rig.View.SchedulerToggle!.IsEnabled);
        Assert.Contains("Needs benchbar 0.4 or later", rig.View.Lines);
    });

    [Fact]
    public void AFailedSchedulerChangeIsShown() => Sta.Run(() =>
    {
        var (services, runner) = ScriptedServices();
        runner.On("service").Fail(1, "could not write Procfile.lean");
        var view = new OverviewView(new OverviewActions());
        view.Attach(services, (_, _) => { });
        view.Confirm = (_, _) => true;
        view.Bind(BenchWith(BenchState.Stopped, "manual") with { Scheduler = false }, null);
        Pump(() => ClickToggle(view.SchedulerToggle!), () => view.Lines.Contains("could not write Procfile.lean"));
    });

    // --- the More menu ---

    [Fact]
    public void ConsoleAndDatabaseOpenInWindowsTerminalInsideTheDistro() => Sta.Run(() =>
    {
        var rig = Make();
        rig.View.Bind(BenchWith(BenchState.Running), null);
        Assert.Equal(["Open Console", "Open Database"], rig.View.MoreItems);
        Assert.Equal(["Open Console", "Open Database"], new[] { rig.View.ConsoleItem!, rig.View.DatabaseItem! }.Select(i => System.Windows.Automation.AutomationProperties.GetName(i)));
        rig.View.ConsoleItem!.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        rig.View.DatabaseItem!.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        Assert.Equal(["wsl.exe", "-d", "Ubuntu-24.04", "--cd", Path, "--exec", "bench", "console"], rig.Terminals[0].WindowsTerminalArguments);
        Assert.Equal(["wsl.exe", "-d", "Ubuntu-24.04", "--cd", Path, "--exec", "bench", "mariadb"], rig.Terminals[1].WindowsTerminalArguments);
        Assert.Equal(["-d", "Ubuntu-24.04", "--cd", Path, "--exec", "bench", "mariadb"], rig.Terminals[1].WslArguments);
    });

    [Fact]
    public void WithoutADistroTheMoreMenuSaysSoAndTheButtonLabelsStayTheSame() => Sta.Run(() =>
    {
        var rig = Make();
        rig.Services.Distro = () => null;
        rig.View.Bind(BenchWith(BenchState.Running), null);
        rig.View.ConsoleItem!.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        Assert.Empty(rig.Terminals);
        Assert.Contains(WslCommands.NoDistroMessage, rig.View.Lines);
        Assert.Equal(["Stop", "Restart", "Open Site", "Logs", "Health", "Open in VS Code"], rig.View.ButtonLabels);
        Assert.Equal("More actions frappe-bench", System.Windows.Automation.AutomationProperties.GetName(rig.View.MoreButton!));
    });

    // --- the bench page ---

    [Fact]
    public void TheBenchPageRunsLockCheckOnlyWhileTheOverviewIsShownAndGuidanceMovesToHealth() => Sta.Run(() =>
    {
        var (services, runner) = ScriptedServices();
        runner.On("lock").Print(Fixture("health-lock-sync.json"));
        runner.On("doctor").Print(Fixture("health-doctor.json"));
        runner.On("setup", "check").Print(Fixture("health-setup-check.json"));
        var page = new BenchPage(services, new OverviewView(new OverviewActions()));
        Pump(() => page.Bind(BenchWith(BenchState.Crashed), null, navigate: true), () => page.Overview.LockBadge is not null);
        Assert.Equal("In sync", page.Overview.LockBadge);
        Assert.Single(runner.Runs.ToArray(), r => r.Args[0] == "lock");

        // the guidance row moves to Health
        Click(page.Overview.Guidance!.Button!);
        Assert.Equal(BenchTab.Health, page.Tab);
        Assert.NotNull(page.Health);
        // polls while Health is shown never run lock check again
        page.Bind(BenchWith(BenchState.Crashed), null, navigate: false);
        Assert.Single(runner.Runs.ToArray(), r => r.Args[0] == "lock");
        AssertEveryControlIsNamed(page);
    });
}
