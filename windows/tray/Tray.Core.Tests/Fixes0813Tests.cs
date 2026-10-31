using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>The 0.8.1 live recheck: stopped messages, distro changes behind the wizard, advice buttons, plan fixes and blockers.</summary>
public class Fixes0813Tests
{
    private static SetupFixture Fixture(string check = "check.json")
    {
        var fixture = new SetupFixture();
        fixture.Check(check);
        return fixture;
    }

    private sealed class RecordingCheck(FixtureSetupService inner) : DelegatingSetup(inner)
    {
        public List<string?> Distros { get; } = [];

        public override Task<SetupReport> CheckAsync(string? distro, CancellationToken ct, bool probe = false)
        {
            Distros.Add(distro);
            return base.CheckAsync(distro, ct, probe);
        }
    }

    [Fact]
    public async Task AStoppedElevationStepKeepsTheWindowsPromptWordsAndAStoppedOtherStepDoesNot()
    {
        var fixture = Fixture("check-fresh.json");
        var holding = new HoldingSetup(fixture.Service);
        var model = new WizardModel(holding, new FakeWizardHost());
        await model.ChooseNewBench();
        var run = model.RunStepAsync(SetupIds.Cli);
        await holding.Started.Task;
        model.CancelRun();
        await run;
        Assert.Equal("Stopped. Click the button to try again.", model.StepMessages[SetupIds.Cli]);
        Assert.DoesNotContain("Windows prompt", model.StepMessages[SetupIds.Cli]);
    }

    [Fact]
    public async Task ADeclinedWindowsPromptKeepsItsWordsUntilCheckAgain()
    {
        var fixture = Fixture("check-fresh.json");
        fixture.Run("wsl_enable", "run-wsl_enable-cancelled.jsonl");
        var model = new WizardModel(fixture.Service, new FakeWizardHost());
        await model.ChooseNewBench();
        await model.RunStepAsync(SetupIds.WslFeature);
        Assert.Equal(WizardModel.CancelledMessage, model.StepMessages[SetupIds.WslFeature]); // the check after the run keeps it
        await model.CheckAsync();
        Assert.False(model.StepMessages.ContainsKey(SetupIds.WslFeature));
    }

    [Fact]
    public async Task TheCheckUsesTheDistroThatConfigJsonNamesNow()
    {
        var fixture = Fixture();
        var setup = new RecordingCheck(fixture.Service);
        var host = new FakeWizardHost { ConfiguredDistro = "Ubuntu-24.04" };
        var model = new WizardModel(setup, host, "Ubuntu-24.04");
        await model.ChooseNewBench();
        Assert.Equal("Ubuntu-24.04", setup.Distros[^1]);

        host.ConfiguredDistro = "BenchBarQA"; // changed outside the wizard (Settings, adopt-distro by hand)
        await model.CheckAsync();
        Assert.Equal("BenchBarQA", setup.Distros[^1]);
    }

    [Fact]
    public async Task AWslconfigAdviceRowHasItsSetUpButtonAndSetUpEverythingLeavesItAlone()
    {
        var fixture = Fixture();
        var model = new WizardModel(fixture.Service, new FakeWizardHost());
        await model.ChooseNewBench();
        var row = model.Rows.Single(r => r.Step.Id == SetupIds.WslConfig);
        Assert.Equal(SetupStatus.Warn, row.Step.Status);
        Assert.Equal("Set Up", row.ButtonLabel);
        Assert.False(row.Step.Blocking);
        Assert.Null(model.Report.NextActionable); // no blocking action is pending: Set Up Everything has nothing to do
        Assert.True(model.CanContinueFromCheck);
    }

    [Fact]
    public void SetUpEverythingPicksBlockingActionsOnly()
    {
        var steps = new[]
        {
            new SetupStepInfo(SetupIds.WslConfig, SetupStatus.Missing, "WSL idle", "no file", "wslconfig", false, Blocking: false),
            new SetupStepInfo(SetupIds.Systemd, SetupStatus.Missing, "systemd", "off", SetupIds.ActionSystemd, false),
        };
        Assert.Equal(SetupIds.Systemd, new SetupReport("U", false, false, steps).NextActionable!.Id);
        Assert.Null(new SetupReport("U", true, false, steps[..1]).NextActionable);
        Assert.True(steps[0].OffersAction);
    }

    private static async Task<WizardModel> ReviewWith(SetupFixture fixture)
    {
        var model = new WizardModel(fixture.Service, new FakeWizardHost());
        await model.ChooseNewBench();
        await model.ContinueFromCheckAsync();
        model.SetAdminPassword(Secret.From("admin-pass"));
        await model.ReviewAsync();
        return model;
    }

    [Fact]
    public async Task AFailedPlanShowsItsFixLine()
    {
        var fixture = Fixture();
        File.WriteAllText(Path.Combine(fixture.Setup, "plan.jsonl"),
            "{\"schema_version\":1,\"event\":\"done\",\"exit\":1,\"error_id\":\"port_3306_in_use\",\"error\":\"Port 3306 is in use by another distro.\",\"fix\":\"In the other distro run: sudo systemctl stop mariadb\"}\n");
        var model = await ReviewWith(fixture);
        Assert.Null(model.Plan);
        Assert.Equal("Port 3306 is in use by another distro.", model.PlanError);
        Assert.Equal("In the other distro run: sudo systemctl stop mariadb", model.PlanFix);
        Assert.False(model.PlanFixIsCommand); // a sentence that leads to a command: read, not copied
    }

    [Fact]
    public async Task AFixThatIsACommandCanBeCopied()
    {
        var fixture = Fixture();
        File.WriteAllText(Path.Combine(fixture.Setup, "plan.jsonl"),
            "{\"schema_version\":1,\"event\":\"done\",\"exit\":1,\"error\":\"MariaDB is stopped.\",\"fix\":\"sudo systemctl start mariadb\"}\n");
        var model = await ReviewWith(fixture);
        Assert.Equal("sudo systemctl start mariadb", model.PlanFix);
        Assert.True(model.PlanFixIsCommand);
    }

    [Fact]
    public async Task APlanWithBlockersListsEachWithItsFix()
    {
        var fixture = Fixture();
        File.WriteAllText(Path.Combine(fixture.Setup, "plan.jsonl"),
            "{\"schema_version\":1,\"event\":\"plan\",\"bench\":\"/b\",\"site\":\"s\",\"steps\":[],\"blockers\":[{\"id\":\"port_3306_in_use\",\"message\":\"Port 3306 is in use.\",\"fix\":\"sudo systemctl stop mariadb\"},{\"id\":\"disk\",\"message\":\"Low disk space.\"}]}\n"
            + "{\"schema_version\":1,\"event\":\"done\",\"exit\":1,\"error\":\"The plan has blockers.\"}\n");
        var model = await ReviewWith(fixture);
        Assert.Equal("The plan has blockers.", model.PlanError);
        Assert.Collection(model.PlanBlockers,
            b =>
            {
                Assert.Equal("port_3306_in_use", b.Id);
                Assert.Equal("Port 3306 is in use.", b.Message);
                Assert.Equal("sudo systemctl stop mariadb", b.Fix);
                Assert.True(b.FixIsCommand);
            },
            b =>
            {
                Assert.Equal("Low disk space.", b.Message);
                Assert.Null(b.Fix);
            });
    }

    [Fact]
    public void BlockersParseFromThePlanLineAndAPlanWithoutThemHasNone()
    {
        var plain = (InstallEvent.Plan)InstallJson.ParseLine("{\"event\":\"plan\",\"bench\":\"/b\",\"site\":\"s\",\"steps\":[]}")!;
        Assert.Empty(plain.Value.Blockers);
        var with = (InstallEvent.Plan)InstallJson.ParseLine("{\"event\":\"plan\",\"bench\":\"/b\",\"site\":\"s\",\"steps\":[],\"blockers\":[\"Port in use\"]}")!;
        Assert.Equal("Port in use", with.Value.Blockers.Single().Message);
    }
}
