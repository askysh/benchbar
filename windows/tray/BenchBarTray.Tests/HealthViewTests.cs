using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>The Health tab and the repair sheet.</summary>
public class HealthViewTests
{
    private static (HealthView View, ScriptedStreamRunner Runner, List<string> Copied) Make(string doctor = "health-doctor.json")
    {
        var (services, runner) = ScriptedServices();
        runner.On("doctor").Print(Fixture(doctor));
        runner.On("setup", "check").Print(Fixture("health-setup-check.json"));
        var copied = new List<string>();
        services.CopyText = copied.Add;
        SynchronizationContext.SetSynchronizationContext(null);
        return (new HealthView(services, autoRun: false), runner, copied);
    }

    private static void Show(HealthView view)
    {
        view.Bind(new BenchContext(BenchWith(BenchState.Running), null));
        view.Model!.RunAsync().GetAwaiter().GetResult();
        view.Refresh();
    }

    [Fact]
    public void BeforeDoctorHasRunTheTabSaysSoAndOffersRunDoctorOnly() => Sta.Run(() =>
    {
        var (view, runner, _) = Make();
        view.Bind(new BenchContext(BenchWith(BenchState.Running), null));
        Assert.Equal(["Run Doctor", "Repair..."], view.ButtonLabels);
        Assert.Contains("Doctor has not run yet.", view.Lines);
        Assert.True(view.RunDoctorButton!.IsEnabled);
        Assert.False(view.RepairButton!.IsEnabled);
        Assert.Empty(runner.Runs); // nothing ran by itself
        AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void RunDoctorShowsTheChecksFirstFailuresWithTheirFixAndTheWindowsRows() => Sta.Run(() =>
    {
        var (view, runner, _) = Make();
        Show(view);
        Assert.Contains("2 passing, 1 failure, 1 warning", view.Lines);
        Assert.Contains("Built assets", view.Lines);
        Assert.Contains("2 of 2 dist files referenced by assets.json are missing (site loads unstyled)", view.Lines);
        Assert.Contains("cd /home/akash/frappe-bench && bench build", view.Lines);
        Assert.Contains("Hosts entry", view.Lines);
        Assert.Contains("acknowledged", view.Lines);
        Assert.True(view.Lines.ToList().IndexOf("Built assets") < view.Lines.ToList().IndexOf("Hosts entry")); // FAIL before WARN
        Assert.Contains("Show 2 passing", view.Lines); // the passing group is folded
        Assert.Contains("Profile v15-lts is only the default: no profile matches this bench's Frappe, so the env checks warn instead of offering a rebuild.", view.Lines);
        // the shim's own rows
        Assert.Contains("Windows", view.Lines);
        Assert.Contains("Windows build", view.Lines);
        Assert.Contains("not checked: the distro is stopped (run setup check --probe to start it and check)", view.Lines);
        var args = runner.Runs.Select(r => string.Join(' ', r.Args)).ToList();
        Assert.Contains("doctor --json --bench-dir /home/akash/frappe-bench", args);
        Assert.Contains("setup check --json", args);
        Assert.DoesNotContain(args, a => a.Contains("--probe") && !a.StartsWith("setup check --json", StringComparison.Ordinal));
        AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void EachFixHasACopyButtonThatCopiesTheCommand() => Sta.Run(() =>
    {
        var (view, _, copied) = Make();
        Show(view);
        var copy = Walk(view).OfType<Button>().Single(b => System.Windows.Automation.AutomationProperties.GetName(b) == "Copy fix for Built assets");
        Click(copy);
        Assert.Equal(["cd /home/akash/frappe-bench && bench build"], copied);
        // the warning has a fix too
        Assert.Contains(Walk(view).OfType<Button>(), b => System.Windows.Automation.AutomationProperties.GetName(b) == "Copy fix for Hosts entry");
    });

    [Fact]
    public void RepairIsTheMainActionOnlyWhenDoctorFoundSomethingItCanFix() => Sta.Run(() =>
    {
        var (view, _, _) = Make();
        Show(view);
        Assert.True(view.RepairButton!.IsEnabled);

        var (calm, _, _) = Make("health-doctor-legacy.json");
        calm.Bind(new BenchContext(BenchWith(BenchState.Running), null));
        calm.Model!.RunAsync().GetAwaiter().GetResult();
        calm.Refresh();
        // the legacy fixture has no repair action on its failure
        Assert.False(calm.RepairButton!.IsEnabled);
        Assert.Contains("1 passing, 1 failure", calm.Lines);
    });

    [Fact]
    public void TheTabKeepsItsAnswerForTheSameBenchAndAsksAgainForAnother() => Sta.Run(() =>
    {
        var (view, _, _) = Make();
        view.Bind(new BenchContext(BenchWith(BenchState.Running), null));
        var first = view.Model;
        view.Bind(new BenchContext(BenchWith(BenchState.Stopped), "one.localhost")); // a poll
        Assert.Same(first, view.Model);
        view.Bind(new BenchContext(BenchWith() with { Path = "/home/akash/other", Name = "other" }, null));
        Assert.NotSame(first, view.Model);
        Assert.Contains("other", view.Lines);
    });

    // --- the repair sheet ---

    private static (RepairSheet Sheet, ScriptedStreamRunner Runner, List<LinuxPasswordRequest> Asked) Sheet(string plan = "health-repair-plan.json", string run = "health-repair-run.jsonl", bool password = true)
    {
        var (services, runner) = ScriptedServices();
        runner.On("repair", "--dry-run").Print(Fixture(plan));
        runner.On("repair", "--yes").Print(Fixture(run));
        var asked = new List<LinuxPasswordRequest>();
        services.AskLinuxPassword = r =>
        {
            asked.Add(r);
            return Task.FromResult<Secret?>(password ? Secret.From("hunter2") : null);
        };
        SynchronizationContext.SetSynchronizationContext(null);
        var view = new HealthView(services, autoRun: false);
        view.Bind(new BenchContext(BenchWith(BenchState.Running), null));
        return (view.CreateRepairSheet(load: false), runner, asked);
    }

    [Fact]
    public void TheRepairSheetShowsThePlanAndRepairsOnlyAfterTheYes() => Sta.Run(() =>
    {
        var (sheet, runner, asked) = Sheet();
        Assert.Equal(["Cancel"], sheet.ButtonLabels);
        sheet.Model.LoadPlanAsync(CancellationToken.None).GetAwaiter().GetResult();
        sheet.Refresh();
        Assert.Equal(["Repair", "Cancel"], sheet.ButtonLabels);
        Assert.Contains("bench build", sheet.Lines);
        Assert.Contains("write the systemd unit (sudo)  (asks for your Linux password)", sheet.Lines);
        Assert.Contains(sheet.Lines, l => l.StartsWith("1 step uses sudo.", StringComparison.Ordinal));
        Assert.DoesNotContain(runner.Runs, r => r.Args.Contains("--yes")); // nothing runs before the yes
        AssertEveryControlIsNamed(sheet);

        sheet.Model.RunAsync().GetAwaiter().GetResult();
        sheet.Refresh();
        Assert.Equal([new LinuxPasswordRequest(1, false)], asked);
        Assert.Equal(["Close"], sheet.ButtonLabels);
        Assert.Contains("Repair finished; every check passes.", sheet.Lines);
        Assert.Contains(sheet.Lines, l => l.EndsWith("20261030-101500-4242.log", StringComparison.Ordinal));
        Assert.Equal("done", RepairSheet.StepWord(InstallStepStatus.Done));
        Assert.Equal("skipped", RepairSheet.StepWord(InstallStepStatus.Skipped));
        AssertEveryControlIsNamed(sheet);
    });

    [Fact]
    public void ARepairWithNothingToDoSaysSoAndOffersNoRepair() => Sta.Run(() =>
    {
        var (sheet, _, _) = Sheet("health-repair-empty.json");
        sheet.Model.LoadPlanAsync(CancellationToken.None).GetAwaiter().GetResult();
        sheet.Refresh();
        Assert.Contains("Nothing to repair.", sheet.Lines);
        Assert.Equal(["Repair", "Cancel"], sheet.ButtonLabels);
        Assert.False(PageKit.Walk(sheet).OfType<Button>().First(b => b.Content as string == "Repair").IsEnabled);
    });

    [Fact]
    public void ARunningRepairCannotBeClosedAndAFailedPlanCanBeReadAgain() => Sta.Run(() =>
    {
        var (services, runner) = ScriptedServices();
        runner.On("repair", "--dry-run").Print(Fixture("health-repair-plan-plain.json"));
        var held = runner.On("repair", "--yes").Print(Fixture("health-repair-run-plain.jsonl")).Hold();
        SynchronizationContext.SetSynchronizationContext(null);
        var model = new RepairModel(services.Cli, "/home/akash/frappe-bench", "frappe-bench");
        var sheet = new RepairSheet(model, Theme, null, _ => { }, load: false);
        var closed = false;
        sheet.Closed += (_, _) => closed = true;
        model.LoadPlanAsync(CancellationToken.None).GetAwaiter().GetResult();
        var run = model.RunAsync();
        held.Started.Task.Wait();
        sheet.Refresh();
        Assert.Equal(RepairPhase.Running, model.Phase);
        Assert.Empty(sheet.ButtonLabels); // no close, no stop
        Assert.Contains("Repairing...", sheet.Lines);
        sheet.Close();
        Assert.False(closed);
        held.Release();
        run.GetAwaiter().GetResult();
        sheet.Refresh();
        Assert.Contains("Repair finished with problems left", sheet.Lines);
        Assert.Equal(["Close"], sheet.ButtonLabels);
        sheet.Close();
        Assert.True(closed);

        var failing = new RepairModel(new CliClient(new ScriptedStreamRunner(), () => "benchbar.exe"), "/b", "b");
        var failedSheet = new RepairSheet(failing, Theme, null, _ => { }, load: false);
        failing.LoadPlanAsync(CancellationToken.None).GetAwaiter().GetResult();
        failedSheet.Refresh();
        Assert.Equal(["Read Plan Again", "Close"], failedSheet.ButtonLabels);
        Assert.Contains("No repair plan", failedSheet.Lines);
        AssertEveryControlIsNamed(failedSheet);
    });

    [Fact]
    public void AWrongPasswordBringsTheSheetBackToReviewWithTheReason() => Sta.Run(() =>
    {
        var (sheet, _, asked) = Sheet(run: "sudo-wrong.jsonl");
        sheet.Model.LoadPlanAsync(CancellationToken.None).GetAwaiter().GetResult();
        sheet.Model.RunAsync().GetAwaiter().GetResult();
        sheet.Refresh();
        Assert.Equal(["Repair", "Cancel"], sheet.ButtonLabels);
        Assert.Contains("Linux did not accept that password. Nothing was changed.", sheet.Lines);
        Assert.Single(asked);
    });
}
