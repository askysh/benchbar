using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>The Check page words, install failure advice, a missing distro and the settings switch (0.8.1 QA).</summary>
public class Fixes081Tests
{
    private static (WizardModel Model, SetupFixture Fixture) Make(string check = "check-fresh.json")
    {
        var fixture = new SetupFixture();
        fixture.Check(check);
        return (new WizardModel(fixture.Service, new FakeWizardHost()), fixture);
    }

    [Fact]
    public async Task AWaitingRowNamesTheStepItWaitsForNotItsId()
    {
        var (model, _) = Make();
        await model.ChooseNewBench();
        var rows = model.Rows;
        Assert.Equal("waits for Windows Subsystem for Linux", rows.Single(r => r.Step.Id == SetupIds.Reboot).Detail);
        Assert.Equal("waits for Windows Subsystem for Linux", rows.Single(r => r.Step.Id == SetupIds.Distro).Detail);
        Assert.True(rows.Single(r => r.Step.Id == SetupIds.Distro).Waiting); // the raw detail still says it waits
    }

    [Fact]
    public async Task ARowForWaitingOnTheRestartNamesTheRestartStep()
    {
        var (model, _) = Make("check-reboot.json");
        await model.ChooseNewBench();
        Assert.Equal("waits for Restart", model.Rows.Single(r => r.Step.Id == SetupIds.WslVersion).Detail);
    }

    [Fact]
    public async Task AFinishedStepDropsItsRunningText()
    {
        var (model, fixture) = Make();
        await model.ChooseNewBench();
        await model.RunStepAsync(SetupIds.WslFeature);
        Assert.Equal("WSL is on", model.StepMessages[SetupIds.WslFeature]); // the shim's last word for the step
        Assert.NotNull(model.Rows.Single(r => r.Step.Id == SetupIds.WslFeature).Message); // still missing, so the text stays

        var text = File.ReadAllText(Path.Combine(fixture.Setup, "check.json"))
            .Replace("\"status\":\"missing\",\"title\":\"Windows Subsystem for Linux\"", "\"status\":\"ok\",\"title\":\"Windows Subsystem for Linux\"");
        File.WriteAllText(Path.Combine(fixture.Setup, "check.json"), text);
        await model.CheckAsync();
        Assert.Null(model.Rows.Single(r => r.Step.Id == SetupIds.WslFeature).Message);
    }

    [Fact]
    public void TheKeepaliveLineForAnotherDistroReadsAsAdvice()
    {
        var step = new SetupStepInfo(SetupIds.Keepalive, SetupStatus.Warn, "Keep the distro awake",
            "keepalive keeps Ubuntu-24.04 alive, but BenchBar uses BenchBarQA", "keepalive", false, Blocking: false);
        var text = StepText.Detail(step, [step]);
        Assert.Equal("The keep awake task keeps Ubuntu-24.04 running, but BenchBar uses BenchBarQA. Set Up points the task at BenchBarQA.", text);
    }

    [Fact]
    public void AdviceNeverHoldsContinueBack()
    {
        var steps = new[]
        {
            new SetupStepInfo(SetupIds.WslFeature, SetupStatus.Ok, "WSL", "on", null, false),
            new SetupStepInfo(SetupIds.Keepalive, SetupStatus.Warn, "Keep awake", "keepalive keeps A alive, but BenchBar uses B", "keepalive", false, Blocking: false),
            new SetupStepInfo(SetupIds.WslConfig, SetupStatus.Missing, ".wslconfig", "no file", "wslconfig", false, Blocking: false),
        };
        var report = new SetupReport("B", true, false, steps);
        Assert.True(report.CanContinue);
        Assert.False(report.HasBlockingFailure);
    }

    [Theory]
    [InlineData("Pass MARIADB_ROOT_PASSWORD.", false)]
    [InlineData("should run it again", false)]
    [InlineData("Enter the password and retry.", false)]
    [InlineData("benchbar.exe keepalive install", true)]
    [InlineData("wsl.exe --install -d Ubuntu-24.04", true)]
    [InlineData("MARIADB_ROOT_PASSWORD=secret benchbar install", true)]
    public void OnlyACommandGetsACopyButton(string fix, bool command)
    {
        Assert.Equal(command, new WizardFailure(null, "x", fix, null).FixIsCommand);
        Assert.False(new WizardFailure(null, "x", null, null).FixIsCommand);
    }

    [Fact]
    public async Task AMissingDistroIsNotJustStopped()
    {
        var probe = new FakeProbe { Running = false, Installed = false };
        var (poller, _, _, snapshots) = PollerTests.Make(BenchState.Stopped, probe);
        using (poller)
        using (snapshots)
        {
            poller.Start();
            await snapshots.NextAsync();
            Assert.True(poller.Last.DistroStopped);
            Assert.True(poller.Last.DistroMissing);
            Assert.Equal("distro not installed", TrayController.UpText(poller.Last, []));
            Assert.Contains("is not installed", TrayController.Tooltip(poller.Last, "x"));
        }
    }

    [Fact]
    public async Task AStoppedDistroThatExistsStaysStopped()
    {
        var probe = new FakeProbe { Running = false, Installed = true };
        var (poller, _, _, snapshots) = PollerTests.Make(BenchState.Stopped, probe);
        using (poller)
        using (snapshots)
        {
            poller.Start();
            await snapshots.NextAsync();
            Assert.False(poller.Last.DistroMissing);
            Assert.Equal("distro stopped", TrayController.UpText(poller.Last, []));
        }
    }

    [Fact]
    public async Task SwitchingTheDistroTellsTheHostSoTheListRefreshesAtOnce()
    {
        var path = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"), "config.json");
        var config = TrayConfig.Load(path);
        var host = new SwitchHost();
        var model = new SettingsModel(config, host, new SetupFixture().Service, () => { });
        await model.UseDistroAsync("Debian", TestContext.Current.CancellationToken);
        Assert.Equal(1, host.Switches);
    }

    private sealed class SwitchHost : ISettingsHost
    {
        public bool OpenAtLogon { get; set; }
        public string? ShimPath => null;
        public int Switches { get; private set; }
        public void ApplyAppearance(AppearanceMode mode) { }
        public void ApplyRunner(string id) { }
        public void ApplyNotifications(bool on) { }
        public void DistroSwitched() => Switches++;
    }

    [Theory]
    [InlineData("0.8.1", "https://raw.githubusercontent.com/askysh/benchbar/v0.8.1/install.sh | bash -s -- --version v0.8.1")]
    [InlineData("0.0.0-dev", "https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash")]
    [InlineData("0.8.1-rc1", "https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash")]
    [InlineData(null, "https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash")]
    public void TheLinuxInstallLineFollowsTheTrayRelease(string? version, string tail)
    {
        Assert.Equal("curl -fsSL " + tail, WizardModel.LinuxCliInstallLineFor(version));
    }
}
