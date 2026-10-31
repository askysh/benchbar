using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>The wizard fixes of the 0.8.1 review: blocking steps, cancel, force restart, disposal, home folder, adopt sudo steps, restart, distro alignment.</summary>
public class WizardReviewFixTests
{
    private const string SystemdOk = "{\"id\":\"systemd\",\"status\":\"ok\",\"title\":\"systemd\",\"detail\":\"PID 1 is systemd\",\"action\":null";
    private const string SystemdMissing = "{\"id\":\"systemd\",\"status\":\"missing\",\"title\":\"systemd\",\"detail\":\"not enabled\",\"action\":\"systemd\"";
    private const string VirtOk = "{\"id\":\"virtualization\",\"status\":\"ok\",\"title\":\"Virtualization\",\"detail\":\"enabled in firmware\",\"action\":null";
    private const string VirtFail = "{\"id\":\"virtualization\",\"status\":\"fail\",\"title\":\"Virtualization\",\"detail\":\"virtualization is off: turn it on in the BIOS\",\"action\":null";

    private static string CheckFile(SetupFixture f) => Path.Combine(f.Setup, "check.json");

    private static void Edit(SetupFixture f, string from, string to)
    {
        var text = File.ReadAllText(CheckFile(f));
        Assert.Contains(from, text);
        File.WriteAllText(CheckFile(f), text.Replace(from, to));
    }

    private static SetupFixture Fixture(string check = "check.json")
    {
        var fixture = new SetupFixture();
        fixture.Check(check);
        return fixture;
    }

    private static Secret Pass(string text) => Secret.From(text);

    // --- 1: a blocked benchbar.exe ---

    private sealed class BlockedInstall(FixtureSetupService inner, ShimSetupService blocked) : DelegatingSetup(inner)
    {
        public override Task<InstallRunResult> InstallAsync(InstallRequest request, InstallSecrets secrets, Action<InstallEvent> onEvent, CancellationToken ct) =>
            blocked.InstallAsync(request, secrets, onEvent, ct);
    }

    [Fact]
    public async Task ABlockedBenchbarExeEndsTheInstallWithALineAndNotWithRunningForever()
    {
        var fixture = Fixture();
        var blocked = new ShimSetupService(new CapturingProcessRunner(), new BlockedStream(), () => @"C:\x\benchbar.exe");
        var model = new WizardModel(new BlockedInstall(fixture.Service, blocked), new FakeWizardHost());
        await model.ChooseNewBench();
        await model.ContinueFromCheckAsync();
        model.SetAdminPassword(Pass("admin-pass"));
        await model.ReviewAsync();
        model.SetPassword(Pass("linux-pass"));

        await model.StartInstallAsync();

        Assert.Equal(InstallPhase.Failed, model.Phase);
        Assert.Equal(ShimBenchSource.BlockedMessage, model.Failure!.Message);
        Assert.Equal("Windows blocked benchbar.exe. If SmartScreen or your antivirus asked, allow it, then try again.", model.Failure.Message);
    }

    [Fact]
    public async Task TheStreamHelpersTurnAStartFailureIntoTheProblemException()
    {
        var setup = new ShimSetupService(new CapturingProcessRunner(), new BlockedStream(), () => @"C:\x\benchbar.exe");
        var ex = await Assert.ThrowsAsync<CliProblemException>(() => setup.RunActionAsync(new SetupRunRequest("systemd", null), _ => { }, TestContext.Current.CancellationToken));
        Assert.Equal(ShimBenchSource.BlockedMessage, ex.Message);
        await Assert.ThrowsAsync<CliProblemException>(() => setup.InstallAsync(new InstallRequest("/a", "v15-lts", "minimal", "a.localhost"), new InstallSecrets(null, null), _ => { }, TestContext.Current.CancellationToken));

        var client = new CliClient(new BlockedStream(), () => @"C:\x\benchbar.exe");
        var stream = await client.RunStreamAsync(["site", "list"], null, TimeSpan.FromSeconds(5), _ => { }, TestContext.Current.CancellationToken);
        Assert.False(stream.Ok);
        Assert.Equal(ShimBenchSource.BlockedMessage, stream.Problem);
        var json = await client.RunJsonAsync(["site", "list", "--json"], null, TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        Assert.False(json.Ok);
        Assert.Equal(ShimBenchSource.BlockedMessage, json.Error);
    }

    [Fact]
    public async Task ABlockedBenchbarExeEndsASetupActionWithALine()
    {
        var fixture = Fixture("check-fresh.json");
        var blocked = new ShimSetupService(new CapturingProcessRunner { Next = new ProcessResult(0, File.ReadAllText(Path.Combine(fixture.Setup, "check-fresh.json")), "") }, new BlockedStream(), () => @"C:\x\benchbar.exe");
        var model = new WizardModel(blocked, new FakeWizardHost());
        await model.ChooseNewBench();
        await model.RunStepAsync(SetupIds.WslFeature);
        Assert.Null(model.BusyStepId);
        Assert.Equal(ShimBenchSource.BlockedMessage, model.StepMessages[SetupIds.WslFeature]);
    }

    // --- 2: blocking ---

    [Fact]
    public async Task AdviceNeverHoldsContinueBackAndABlockingFailureDoes()
    {
        var advice = Fixture();
        var model = new WizardModel(advice.Service, new FakeWizardHost());
        await model.ChooseNewBench();
        Assert.True(model.CanContinueFromCheck);

        var blocked = Fixture();
        Edit(blocked, VirtOk, VirtFail);
        var stuck = new WizardModel(blocked.Service, new FakeWizardHost());
        await stuck.ChooseNewBench();
        Assert.False(stuck.CanContinueFromCheck);
        var row = stuck.Rows.Single(r => r.Step.Id == SetupIds.Virtualization);
        Assert.True(row.Step.NeedsManualFix);
        Assert.Null(row.ButtonLabel);
        Assert.Equal("virtualization is off: turn it on in the BIOS", row.Step.CopyText);
    }

    // --- 3: cancel a running step ---

    [Fact]
    public async Task ARunningStepCanBeCancelledAndTheWindowsPromptWaitSaysSo()
    {
        var fixture = Fixture("check-fresh.json");
        var holding = new HoldingSetup(fixture.Service);
        var model = new WizardModel(holding, new FakeWizardHost());
        await model.ChooseNewBench();

        var run = model.RunStepAsync(SetupIds.WslFeature);
        await holding.Started.Task;
        Assert.Equal(SetupIds.WslFeature, model.BusyStepId);
        Assert.Equal(WizardModel.WaitingForPromptMessage, model.StepMessages[SetupIds.WslFeature]);
        Assert.Equal("Waiting for you to answer the Windows prompt. It may be behind other windows.", model.Rows.Single(r => r.Step.Id == SetupIds.WslFeature).Message);

        model.CancelRun();
        await run;
        Assert.Null(model.BusyStepId);
        Assert.Equal(WizardModel.StoppedWaitingMessage, model.StepMessages[SetupIds.WslFeature]);
        Assert.False(model.RestartNeeded); // the next check says what Windows finished
    }

    [Fact]
    public async Task CancellingAnotherStepSaysItWasCancelled()
    {
        var fixture = Fixture("check-fresh.json");
        var holding = new HoldingSetup(fixture.Service);
        var model = new WizardModel(holding, new FakeWizardHost());
        await model.ChooseNewBench();
        var run = model.RunStepAsync(SetupIds.Distro);
        await holding.Started.Task;
        model.CancelRun();
        await run;
        // not the Windows prompt: the words are about the step, not about a prompt that never came up
        Assert.Equal("Stopped. Click the button to try again.", model.StepMessages[SetupIds.Distro]);
        Assert.Equal(WizardModel.StoppedMessage, model.Rows.Single(r => r.Step.Id == SetupIds.Distro).Message);
        await model.CheckAsync(); // Check Again clears it
        Assert.False(model.StepMessages.ContainsKey(SetupIds.Distro));
    }

    [Fact]
    public async Task TurningOnWslWaitsAtMostTenMinutes()
    {
        var stream = new RecordingStream { Lines = ["{\"event\":\"done\",\"exit\":0}"] };
        var setup = new ShimSetupService(new CapturingProcessRunner(), stream, () => @"C:\x\benchbar.exe");
        await setup.RunActionAsync(new SetupRunRequest("wsl_enable", null), _ => { }, TestContext.Current.CancellationToken);
        await setup.RunActionAsync(new SetupRunRequest("systemd", null), _ => { }, TestContext.Current.CancellationToken);
        Assert.Equal(TimeSpan.FromMinutes(10), stream.Timeouts[0]);
        Assert.Equal(TimeSpan.FromMinutes(45), stream.Timeouts[1]);
    }

    [Fact]
    public async Task TheShimsStoppedButContinuingResultShowsItsMessageAndKeepsRestartNow()
    {
        var fixture = Fixture("check-fresh.json");
        File.WriteAllLines(Path.Combine(fixture.Setup, "run-wsl_enable.jsonl"),
        [
            "{\"event\":\"step\",\"id\":\"wsl_enable\",\"status\":\"done\",\"message\":\"stopped waiting: the WSL install keeps running in Windows. Restart Windows when it finishes\"}",
            "{\"event\":\"done\",\"exit\":0,\"changed\":true,\"reboot_required\":true,\"cancelled\":false,\"warnings\":[],\"next_actions\":[\"reboot\"]}",
        ]);
        var host = new FakeWizardHost();
        var model = new WizardModel(fixture.Service, host);
        await model.ChooseNewBench();
        await model.RunStepAsync(SetupIds.WslFeature);
        Assert.Equal("stopped waiting: the WSL install keeps running in Windows. Restart Windows when it finishes", model.StepMessages[SetupIds.WslFeature]);
        Assert.True(model.RestartNeeded);
        Assert.True(host.ResumeFlag);
    }

    // --- 6: done messages, restart stays ---

    [Fact]
    public async Task ADoneMessageShowsOnTheRowAndARestartFromDistroInstallStaysAfterTheNextCheck()
    {
        var fixture = Fixture("check-fresh.json");
        File.WriteAllLines(Path.Combine(fixture.Setup, "run-distro_install.jsonl"),
        [
            "{\"event\":\"step\",\"id\":\"distro_install\",\"status\":\"done\",\"message\":\"Ubuntu installed. Restart Windows to finish.\"}",
            "{\"event\":\"done\",\"exit\":0,\"changed\":true,\"reboot_required\":true,\"cancelled\":false,\"warnings\":[],\"next_actions\":[\"reboot\"]}",
        ]);
        var host = new FakeWizardHost();
        var model = new WizardModel(fixture.Service, host);
        await model.ChooseNewBench();
        await model.RunStepAsync(SetupIds.Distro); // the check that follows knows of no pending restart: the marker is not read yet

        Assert.Equal("Ubuntu installed. Restart Windows to finish.", model.StepMessages[SetupIds.Distro]);
        Assert.True(model.RestartNeeded);
        Assert.True(host.ResumeFlag);
        await model.CheckAsync();
        Assert.True(model.RestartNeeded);
    }

    // --- 7: the distro is running ---

    [Fact]
    public async Task ARunningDistroAsksThenRunsAgainWithForce()
    {
        var fixture = Fixture();
        Edit(fixture, SystemdOk, SystemdMissing);
        var setup = new RunningDistroSetup(fixture.Service);
        var model = new WizardModel(setup, new FakeWizardHost());
        string? asked = null;
        model.ConfirmRestartDistro = question =>
        {
            asked = question;
            return Task.FromResult(true);
        };
        await model.ChooseNewBench();
        await model.RunStepAsync(SetupIds.Systemd);

        Assert.Equal("Ubuntu is running. Setting this up restarts it, which stops any benches and MariaDB inside it. Restart Ubuntu now?", asked);
        Assert.Equal([false, true], setup.Requests.Select(r => r.Force));
        Assert.Null(model.BusyStepId);
    }

    [Fact]
    public async Task SayingNoLeavesTheRowAsItIs()
    {
        var fixture = Fixture();
        Edit(fixture, SystemdOk, SystemdMissing);
        var setup = new RunningDistroSetup(fixture.Service);
        var model = new WizardModel(setup, new FakeWizardHost()); // the default answer is no
        await model.ChooseNewBench();
        await model.RunStepAsync(SetupIds.Systemd);
        Assert.Single(setup.Requests);
        Assert.Contains("is running", model.StepMessages[SetupIds.Systemd]);
    }

    [Fact]
    public async Task TheForceFlagAndTheErrorIdTravelThroughTheShimService()
    {
        var stream = new RecordingStream { Lines = ["{\"event\":\"done\",\"exit\":1,\"error_id\":\"distro_running\"}"], Result = new StreamResult(1, null) };
        var setup = new ShimSetupService(new CapturingProcessRunner(), stream, () => @"C:\x\benchbar.exe");
        var first = await setup.RunActionAsync(new SetupRunRequest("systemd", "Ubuntu-24.04"), _ => { }, TestContext.Current.CancellationToken);
        Assert.Equal(SetupIds.ErrorDistroRunning, first.ErrorId);
        await setup.RunActionAsync(new SetupRunRequest("systemd", "Ubuntu-24.04", Force: true), _ => { }, TestContext.Current.CancellationToken);
        Assert.DoesNotContain("--force", stream.Runs[0].Args);
        Assert.Equal(["setup", "run", "systemd", "--distro", "Ubuntu-24.04", "--force", "--jsonl"], stream.Runs[1].Args);
    }

    // --- 9: disposed ---

    [Fact]
    public async Task ADisposedWizardRunsNoMoreChecks()
    {
        var fixture = Fixture("check-fresh.json");
        var holding = new HoldingSetup(fixture.Service);
        var model = new WizardModel(holding, new FakeWizardHost());
        await model.ChooseNewBench();
        var before = fixture.Service.Calls.Count;

        var run = model.RunStepAsync(SetupIds.WslFeature);
        await holding.Started.Task;
        model.Dispose();
        await run;
        Assert.Equal(before, fixture.Service.Calls.Count);

        var again = new WizardModel(new HoldingSetup(fixture.Service), new FakeWizardHost());
        again.Dispose();
        await again.FixAllAsync();
        await again.CheckAsync();
        Assert.Equal(before, fixture.Service.Calls.Count);
    }

    [Fact]
    public async Task FixAllStopsWhenTheWindowClosedMeanwhile()
    {
        var fixture = Fixture("check-fresh.json");
        var holding = new HoldingSetup(fixture.Service);
        var model = new WizardModel(holding, new FakeWizardHost());
        await model.ChooseNewBench();
        var before = fixture.Service.Calls.Count;
        var fix = model.FixAllAsync();
        await holding.Started.Task;
        model.Dispose();
        await fix;
        Assert.Equal(before, fixture.Service.Calls.Count);
    }

    // --- 10: the home folder ---

    private sealed class Home(FixtureSetupService inner) : DelegatingSetup(inner)
    {
        public string? Path { get; set; }

        public override Task<string?> HomeAsync(string? distro, CancellationToken ct) => Task.FromResult(Path);
    }

    [Fact]
    public async Task AnUnreadableHomeFolderBlocksContinueInsteadOfGuessing()
    {
        var fixture = Fixture();
        var setup = new Home(fixture.Service);
        var model = new WizardModel(setup, new FakeWizardHost());
        await model.ChooseNewBench();
        await model.ContinueFromCheckAsync();
        Assert.Equal(WizardPage.Check, model.Page);
        Assert.Equal(WizardModel.HomeUnknownMessage, model.CheckError);
        Assert.Equal("", model.Home);
        Assert.NotNull(model.FormProblem);

        setup.Path = "/home/akash";
        await model.ContinueFromCheckAsync();
        Assert.Equal(WizardPage.NewBench, model.Page);
        Assert.Equal("/home/akash/frappe-bench", model.Folder);
    }

    // --- 17: the adopt plan's sudo steps ---

    private sealed class AdoptPlan(FixtureSetupService inner) : DelegatingSetup(inner)
    {
        public int? Steps { get; set; }

        public override Task<int?> AdoptSudoStepsAsync(string benchPath, CancellationToken ct) => Task.FromResult(Steps);
    }

    private static async Task<(WizardModel Model, AdoptPlan Setup, SetupFixture Fixture)> AtExistingBench(int? steps)
    {
        var fixture = Fixture();
        File.Copy(Path.Combine(fixture.Setup, "install.jsonl"), Path.Combine(fixture.Setup, "adopt.jsonl"));
        var setup = new AdoptPlan(fixture.Service) { Steps = steps };
        var model = new WizardModel(setup, new FakeWizardHost());
        await model.ChooseExistingBench();
        await model.ContinueFromCheckAsync();
        return (model, setup, fixture);
    }

    [Fact]
    public async Task AnAdoptPlanWithoutSudoStepsNeverAsksForThePassword()
    {
        var (model, _, fixture) = await AtExistingBench(0);
        var asked = false;
        model.AskLinuxPassword = _ =>
        {
            asked = true;
            return Task.FromResult<Secret?>(null);
        };
        await model.StartAdoptAsync();
        Assert.False(asked);
        Assert.Equal(WizardPage.Done, model.Page);
        Assert.Contains("adopt /home/fixture/frappe-bench", fixture.Service.Calls);
    }

    [Fact]
    public async Task AnAdoptPlanWithSudoStepsAsksWithTheirCount()
    {
        var (model, _, _) = await AtExistingBench(2);
        LinuxPasswordRequest? asked = null;
        model.AskLinuxPassword = r =>
        {
            asked = r;
            return Task.FromResult<Secret?>(Pass("linux-pass"));
        };
        await model.StartAdoptAsync();
        Assert.Equal(2, asked!.SudoSteps);
        Assert.Equal(WizardPage.Done, model.Page);
    }

    // --- 16: secrets ---

    [Fact]
    public async Task ThePasswordsAreForgottenOnceTheInstallSucceeded()
    {
        var fixture = Fixture();
        var model = new WizardModel(fixture.Service, new FakeWizardHost());
        await model.ChooseNewBench();
        await model.ContinueFromCheckAsync();
        model.SetAdminPassword(Pass("admin-pass"));
        model.SetRootPassword(Pass("root-pass"));
        await model.ReviewAsync();
        model.AskLinuxPassword = _ => Task.FromResult<Secret?>(Pass("linux-pass"));
        await model.StartInstallAsync();
        Assert.Equal(InstallPhase.Succeeded, model.Phase);
        Assert.True(model.AdminPassword.IsEmpty);
        Assert.True(model.LinuxPassword.IsEmpty);
        Assert.True(model.RootPassword.IsEmpty);
    }

    // --- 5: the distro the shim uses ---

    [Fact]
    public async Task TheCheckedDistroBecomesTheShimsDistroOnce()
    {
        var fixture = Fixture();
        var host = new FakeWizardHost { ConfiguredDistro = "Debian" };
        var model = new WizardModel(fixture.Service, host);
        await model.ChooseNewBench();
        await model.CheckAsync();
        Assert.Equal(1, fixture.Service.Calls.Count(c => c == "use-distro Ubuntu-24.04"));
        Assert.True(model.CanContinueFromCheck);
    }

    [Fact]
    public async Task TheDistroIsNotHandedOverBeforeSystemdAndTheCliAreSetUp()
    {
        var fixture = Fixture();
        File.WriteAllText(Path.Combine(fixture.Setup, "check.json"), File.ReadAllText(Path.Combine(fixture.Setup, "check.json"))
            .Replace("\"id\":\"systemd\",\"status\":\"ok\"", "\"id\":\"systemd\",\"status\":\"missing\"")
            .Replace("\"id\":\"cli\",\"status\":\"ok\"", "\"id\":\"cli\",\"status\":\"missing\"")
            .Replace("\"ready\":true", "\"ready\":false"));
        var model = new WizardModel(fixture.Service, new FakeWizardHost { ConfiguredDistro = "Debian" });
        await model.ChooseNewBench();
        await model.CheckAsync();
        Assert.DoesNotContain(fixture.Service.Calls, c => c.StartsWith("use-distro"));
        Assert.Null(model.CheckError);
    }

    [Fact]
    public async Task ADistroTheShimAlreadyUsesIsLeftAlone()
    {
        var fixture = Fixture();
        var model = new WizardModel(fixture.Service, new FakeWizardHost { ConfiguredDistro = "ubuntu-24.04" });
        await model.ChooseNewBench();
        Assert.DoesNotContain(fixture.Service.Calls, c => c.StartsWith("use-distro"));
    }

    private sealed class RefusesDistro(FixtureSetupService inner) : DelegatingSetup(inner)
    {
        public override Task<ActionResult> UseDistroAsync(string name, CancellationToken ct) => Task.FromResult(ActionResult.Failure("Ubuntu-24.04 runs as WSL 1"));
    }

    [Fact]
    public async Task AFailedHandOverBlocksContinueAndSaysWhy()
    {
        var fixture = Fixture();
        var model = new WizardModel(new RefusesDistro(fixture.Service), new FakeWizardHost { ConfiguredDistro = "Debian" });
        await model.ChooseNewBench();
        Assert.False(model.CanContinueFromCheck);
        Assert.Contains("Ubuntu-24.04", model.CheckError);
        Assert.Contains("runs as WSL 1", model.CheckError);
    }

    [Fact]
    public async Task UseDistroAsksForJsonAndNotForTheLingerChange()
    {
        var runner = new CapturingProcessRunner { Next = new ProcessResult(1, "{\"checks\":[{\"id\":\"wsl2\",\"status\":\"fail\",\"message\":\"runs as WSL 1, systemd needs WSL 2\"}]}", "") };
        var setup = new ShimSetupService(runner, new RecordingStream(), () => @"C:\x\benchbar.exe");
        var result = await setup.UseDistroAsync("Ubuntu-24.04", TestContext.Current.CancellationToken);
        Assert.Equal(["adopt-distro", "Ubuntu-24.04", "--json"], runner.Runs[0].Args);
        Assert.Equal("runs as WSL 1, systemd needs WSL 2", result.Message);
    }

    [Fact]
    public async Task TheAdoptPlanIsReadForItsSudoSteps()
    {
        var stream = new RecordingStream
        {
            Lines = ["{\"steps\":[{\"id\":\"runner\",\"name\":\"write the runner\",\"sudo\":false},{\"id\":\"unit\",\"name\":\"write the unit\",\"sudo\":true}],\"can_apply\":true}"],
        };
        var setup = new ShimSetupService(new CapturingProcessRunner(), stream, () => @"C:\x\benchbar.exe");
        Assert.Equal(1, await setup.AdoptSudoStepsAsync("/home/a/bench", TestContext.Current.CancellationToken));
        Assert.Equal(["adopt", "/home/a/bench", "--dry-run", "--json"], stream.Runs[0].Args);

        var broken = new ShimSetupService(new CapturingProcessRunner(), new BlockedStream(), () => @"C:\x\benchbar.exe");
        Assert.Null(await broken.AdoptSudoStepsAsync("/home/a/bench", TestContext.Current.CancellationToken)); // unknown: the page asks
    }

    // --- 12: Restart Now ---

    [Fact]
    public async Task RestartNowComesBackAfterTheWaitWhenWindowsDidNotRestart()
    {
        var fixture = Fixture("check-reboot.json");
        var host = new FakeWizardHost();
        var model = new WizardModel(fixture.Service, host) { RestartRetryAfter = TimeSpan.FromMilliseconds(20) };
        await model.ChooseNewBench();
        Assert.True(model.RestartNow());
        Assert.True(model.RestartRequested);
        await model.RestartWatch!;
        Assert.False(model.RestartRequested);
        Assert.Equal("If Windows did not restart, click Restart Now again.", model.RestartHint);
        Assert.True(model.RestartNow());
        Assert.Null(model.RestartHint);
        model.Dispose();
    }

    [Fact]
    public void TheRestartCopySaysShutDownDoesNotCount() =>
        Assert.Contains("Shut down does not count. Use Restart.", WizardModel.RestartBlurb);

    // --- 19: the wizard is already open ---

    [Fact]
    public async Task AnOpenWizardSwitchesFlowUnlessSomethingRuns()
    {
        var fixture = Fixture();
        var model = new WizardModel(fixture.Service, new FakeWizardHost());
        await model.ChooseNewBench();
        Assert.True(await model.SwitchFlowAsync(WizardFlow.ExistingBench));
        Assert.Equal(WizardFlow.ExistingBench, model.Flow);
        Assert.Equal(WizardPage.Check, model.Page);

        var fresh = Fixture("check-fresh.json");
        var holding = new HoldingSetup(fresh.Service);
        var busy = new WizardModel(holding, new FakeWizardHost());
        await busy.ChooseNewBench();
        var run = busy.RunStepAsync(SetupIds.WslFeature);
        await holding.Started.Task;
        Assert.False(await busy.SwitchFlowAsync(WizardFlow.ExistingBench));
        Assert.Equal(WizardFlow.NewBench, busy.Flow);
        busy.CancelRun();
        await run;
    }

    // --- 4 of the report: the wizard's own words ---

    [Fact]
    public async Task TheWizardNamesItsPlaceAndItsProblemForABugReport()
    {
        var fixture = Fixture();
        Edit(fixture, VirtOk, VirtFail);
        var model = new WizardModel(fixture.Service, new FakeWizardHost());
        await model.ChooseNewBench();
        Assert.Equal("Setup wizard, page Check Your PC, new bench", model.ReportWhere);
        Assert.Equal("Step virtualization (fail): virtualization is off: turn it on in the BIOS", model.ReportProblem);
        Assert.Equal("Opened from: Report This Problem. Where: Setup wizard, page Check Your PC, new bench. Problem: Step virtualization (fail): virtualization is off: turn it on in the BIOS.",
            ReportContext.Compose("Report This Problem", model.ReportWhere, model.ReportProblem));
    }
}
