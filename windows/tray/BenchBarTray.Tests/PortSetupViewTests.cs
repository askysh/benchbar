using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>The Port Settings and Setup sheet, and Resolve and Start.</summary>
public class PortSetupViewTests
{
    private const string B1 = "/home/akash/b1";

    private static (PortSetupSheet Sheet, ScriptedStreamRunner Runner) Make(string plan = "ports-plan.json", bool start = false, bool settings = false)
    {
        var (services, runner) = ScriptedServices();
        runner.On("ports", "plan").Print(Fixture(plan));
        runner.On("ports", "mode");
        runner.On("ports", "apply").Print("Applying " + B1, "Completed " + B1);
        runner.On("ports", "check").Print(Fixture("ports-check-clean.json"));
        runner.On("up");
        SynchronizationContext.SetSynchronizationContext(null);
        var model = new PortSetupModel(services.Cli, [new PortBench(B1, "b1")], start, settings);
        return (new PortSetupSheet(model, Theme, null, _ => { }, load: false), runner);
    }

    private static void Load(PortSetupSheet sheet)
    {
        sheet.Model.LoadPlanAsync(CancellationToken.None).GetAwaiter().GetResult();
        sheet.Refresh();
    }

    [Fact]
    public void WhileThePlanLoadsOnlyCancelIsOffered() => Sta.Run(() =>
    {
        var (sheet, _) = Make();
        Assert.Equal(["Cancel"], sheet.ButtonLabels);
        Assert.Contains("Checking ports and preparing the selection...", sheet.Lines);
    });

    [Fact]
    public void ASetupShowsTheOldAndNewAddressTheServiceChangesAndTheModePicker() => Sta.Run(() =>
    {
        var (sheet, _) = Make();
        Load(sheet);
        Assert.Equal(["Refresh Preview", "Cancel", "Set Up Bench"], sheet.ButtonLabels);
        Assert.Contains("Set Up b1", sheet.Lines);
        Assert.Contains("Current address", sheet.Lines);
        Assert.Contains("http://b1.localhost:8000", sheet.Lines);
        Assert.Contains("New address", sheet.Lines);
        Assert.Contains("http://b1.localhost:8001", sheet.Lines);
        Assert.Contains("Web 8001 | Socket.IO 9001 | Redis 11001/13001", sheet.Lines);
        Assert.Contains("Port conflict resolved by the proposed allocation", sheet.Lines);
        Assert.Contains("Service changes", sheet.Lines);
        Assert.Contains(sheet.Lines, l => l.StartsWith("Rewrite the systemd unit for b1", StringComparison.Ordinal));
        var picker = sheet.ModePickers[B1];
        Assert.Equal("Port mode b1", System.Windows.Automation.AutomationProperties.GetName(picker));
        Assert.Equal(0, picker.SelectedIndex);
        Assert.Equal(["Automatic", "Fixed"], picker.Items.OfType<ComboBoxItem>().Select(i => (string)i.Content));
        AssertEveryControlIsNamed(sheet);
    });

    [Fact]
    public void PortSettingsWithNothingToSetUpIsCalm() => Sta.Run(() =>
    {
        var (sheet, _) = Make("ports-plan-calm.json", settings: true);
        Load(sheet);
        Assert.Equal(["Check Again", "Done"], sheet.ButtonLabels);
        Assert.Contains("Port Settings", sheet.Lines);
        Assert.Contains("The ports this bench uses, and whether BenchBar may move them. Nothing needs setting up.", sheet.Lines);
        Assert.Contains("Address", sheet.Lines);
        Assert.DoesNotContain("Service changes", sheet.Lines);
        Assert.Equal(1, sheet.ModePickers[B1].SelectedIndex); // Fixed
        AssertEveryControlIsNamed(sheet);
    });

    [Fact]
    public void ResolveAndStartIsTheLabelOfTheReviewedConflict() => Sta.Run(() =>
    {
        var (sheet, _) = Make(start: true);
        Load(sheet);
        Assert.Equal(["Refresh Preview", "Cancel", "Resolve and Start"], sheet.ButtonLabels);
        Assert.Contains("Resolve Port Conflict", sheet.Lines);
    });

    [Fact]
    public void ABlockedPlanOffersNoWayToApplyAndSaysWhy() => Sta.Run(() =>
    {
        var (sheet, _) = Make("ports-plan-blocked.json");
        Load(sheet);
        var apply = Walk(sheet).OfType<Button>().Single(b => b.Content as string == "Set Up Bench");
        Assert.False(apply.IsEnabled);
        Assert.Contains("It is running; stop it first.", sheet.Lines);
        Assert.Contains(sheet.Lines, l => l.StartsWith("Resolve the blocked benches before applying.", StringComparison.Ordinal));
        Assert.Contains("Conflict details", Walk(sheet).OfType<Expander>().Select(e => (string)e.Header));
        AssertEveryControlIsNamed(sheet);
    });

    [Fact]
    public void ChoosingAnotherModeSavesItAtOnce() => Sta.Run(() =>
    {
        var (sheet, runner) = Make();
        Load(sheet);
        sheet.ModePickers[B1].SelectedIndex = 1;
        WaitFor(() => runner.Runs.Count(r => r.Args[1] == "plan") == 2);
        Assert.Contains(runner.Runs, r => r.Args.SequenceEqual(PortArgs.Mode(PortMode.Fixed, B1)));
    });

    [Fact]
    public void RefreshPreviewReadsThePlanAgain() => Sta.Run(() =>
    {
        var (sheet, runner) = Make();
        Load(sheet);
        Click(ButtonNamed(sheet, "Refresh Preview"));
        WaitFor(() => runner.Runs.Count(r => r.Args[1] == "plan") == 2);
    });

    [Fact]
    public void ApplyingKeepsTheSheetOpenUntilItEndsThenShowsTheResult() => Sta.Run(() =>
    {
        var (services, runner) = ScriptedServices();
        runner.On("ports", "plan").Print(Fixture("ports-plan.json"));
        var held = runner.On("ports", "apply").Print("Applying " + B1).Hold();
        SynchronizationContext.SetSynchronizationContext(null);
        var model = new PortSetupModel(services.Cli, [new PortBench(B1, "b1")]);
        var sheet = new PortSetupSheet(model, Theme, null, _ => { }, load: false);
        var closed = false;
        sheet.Closed += (_, _) => closed = true;
        Load(sheet);
        var run = model.ApplyAsync();
        held.Started.Task.Wait();
        sheet.Refresh();
        Assert.Equal(PortSetupPhase.Running, model.Phase);
        Assert.Empty(sheet.ButtonLabels); // nothing to press, nothing to close with
        Assert.Contains("Applying changes...", sheet.Lines);
        sheet.Close();
        Assert.False(closed);
        held.Release("Completed " + B1);
        run.GetAwaiter().GetResult();
        sheet.Refresh();
        Assert.Equal(["Done"], sheet.ButtonLabels);
        Assert.Contains("Management is set up. Start the benches when you are ready.", sheet.Lines);
        Assert.Contains("Setup output", Walk(sheet).OfType<Expander>().Select(e => (string)e.Header));
        sheet.Close();
        Assert.True(closed);
    });

    [Fact]
    public void AFailedApplyShowsTheReasonAndOnlyDone() => Sta.Run(() =>
    {
        var (services, runner) = ScriptedServices();
        runner.On("ports", "plan").Print(Fixture("ports-plan.json"));
        runner.On("ports", "apply").Print("[FAIL] the plan changed since it was shown").Fail(1);
        SynchronizationContext.SetSynchronizationContext(null);
        var model = new PortSetupModel(services.Cli, [new PortBench(B1, "b1")]);
        var sheet = new PortSetupSheet(model, Theme, null, _ => { }, load: false);
        Load(sheet);
        model.ApplyAsync().GetAwaiter().GetResult();
        sheet.Refresh();
        Assert.Equal(["Refresh Preview", "Done"], sheet.ButtonLabels);
        Assert.Contains("Setup did not finish", sheet.Lines);
        Assert.Contains("[FAIL] the plan changed since it was shown", sheet.Lines);
        AssertEveryControlIsNamed(sheet);
    });
}
