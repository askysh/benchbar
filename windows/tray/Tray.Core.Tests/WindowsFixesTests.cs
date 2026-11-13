using System.ComponentModel;
using System.Diagnostics;
using BenchBar.Tray.Core;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>The Windows onboarding fixes: awake during setup, a missing distro, readable poll errors, unknown steps, viewers, the lock, passwords.</summary>
public class WindowsFixesTests
{
    private static TimeSpan S(double seconds) => TimeSpan.FromSeconds(seconds);

    private static Secret Pass(string text) => Secret.From(text);

    private static async Task UntilAsync(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "condition not met in time");
            await Task.Delay(10, TestContext.Current.CancellationToken);
        }
    }

    private static async Task<WizardModel> ReviewedAsync(ISetupService service, FakeWizardHost host)
    {
        var model = new WizardModel(service, host);
        await model.ChooseNewBench();
        await model.ContinueFromCheckAsync();
        model.SetAdminPassword(Pass("admin-pass"));
        await model.ReviewAsync();
        model.SetPassword(Pass("linux-pass"));
        return model;
    }

    private static SetupFixture ReadyFixture()
    {
        var fixture = new SetupFixture();
        fixture.Check("check.json", ready: true);
        return fixture;
    }

    // --- 1: the PC stays awake while a setup runs ---

    [Fact]
    public async Task AnInstallHoldsThePcAwakeToItsEnd()
    {
        var fixture = ReadyFixture();
        var host = new FakeWizardHost();
        var model = await ReviewedAsync(fixture.Service, host);
        Assert.Empty(host.AwakeCalls);

        await model.StartInstallAsync();

        Assert.Equal(InstallPhase.Succeeded, model.Phase);
        Assert.Equal([true, false], host.AwakeCalls);
        Assert.False(model.HoldingAwake);
    }

    [Fact]
    public async Task StopLetsThePcSleepAgain()
    {
        var fixture = ReadyFixture();
        var gate = new GatedSetup(fixture.Service);
        var host = new FakeWizardHost();
        var model = await ReviewedAsync(gate, host);

        var run = model.StartInstallAsync();
        await gate.Started.Task;
        Assert.True(host.Awake);
        model.Stop();
        await run;

        Assert.Equal(InstallPhase.Stopped, model.Phase);
        Assert.Equal([true, false], host.AwakeCalls);
    }

    private sealed class ThrowingInstall(FixtureSetupService inner) : DelegatingSetup(inner)
    {
        public override Task<InstallRunResult> InstallAsync(InstallRequest request, InstallSecrets secrets, Action<InstallEvent> onEvent, CancellationToken ct) =>
            throw new NotSupportedException("not an expected failure");
    }

    [Fact]
    public async Task AnExceptionThatEscapesTheRunStillLetsThePcSleepAgain()
    {
        var fixture = ReadyFixture();
        var host = new FakeWizardHost();
        var model = await ReviewedAsync(new ThrowingInstall(fixture.Service), host);

        await Assert.ThrowsAsync<NotSupportedException>(() => model.StartInstallAsync());

        Assert.Equal([true, false], host.AwakeCalls);
        Assert.False(model.HoldingAwake);
    }

    [Fact]
    public async Task ClosingTheWindowLetsThePcSleepAgainAtOnce()
    {
        var fixture = ReadyFixture();
        var gate = new GatedSetup(fixture.Service);
        var host = new FakeWizardHost();
        var model = await ReviewedAsync(gate, host);

        var run = model.StartInstallAsync();
        await gate.Started.Task;
        Assert.True(host.Awake);
        model.Dispose(); // the window closed

        Assert.False(host.Awake);
        await run;
        Assert.Equal([true, false], host.AwakeCalls); // released once, not twice
    }

    [Fact]
    public async Task ASetupActionHoldsThePcAwakeToo()
    {
        var fixture = new SetupFixture();
        fixture.Check("check-fresh.json");
        var holding = new HoldingSetup(fixture.Service);
        var host = new FakeWizardHost();
        var model = new WizardModel(holding, host);
        await model.ChooseNewBench();

        var run = model.RunStepAsync(SetupIds.WslFeature);
        await holding.Started.Task;
        Assert.True(host.Awake);
        model.CancelRun();
        await run;

        Assert.Equal([true, false], host.AwakeCalls);
    }

    [Fact]
    public void TheInstallPageNamesWhatThePersonCanDo() =>
        Assert.Equal("Keep this PC plugged in and awake until it finishes.", WizardModel.KeepAwakeNote);

    [Theory]
    [InlineData(0.4, "1 second")]
    [InlineData(45, "45 seconds")]
    [InlineData(59.2, "60 seconds")]
    [InlineData(60, "1 minute")]
    [InlineData(120, "2 minutes")]
    [InlineData(5400, "90 minutes")]
    public void ATimeoutIsSaidInSecondsBelowAMinute(double seconds, string words) =>
        Assert.Equal(words, SystemStreamRunner.TimeoutText(S(seconds)));

    [Fact]
    public async Task AGrandchildThatHoldsThePipeDoesNotHangTheCall()
    {
        if (!OperatingSystem.IsWindows()) return;
        // cmd ends at once, and the ping it started in the background keeps the output pipe (it writes to it) for about 14 seconds
        var lines = new List<string>();
        var watch = Stopwatch.StartNew();
        var result = await new SystemStreamRunner().RunAsync("cmd.exe", ["/c", "echo first & start /b ping -n 15 127.0.0.1 & exit /b 0"], null,
            line => { lock (lines) lines.Add(line); }, TimeSpan.FromMinutes(1), TestContext.Current.CancellationToken);
        watch.Stop();

        Assert.Equal(0, result.ExitCode);
        Assert.Contains(lines, l => l.Contains("first"));
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(11), $"took {watch.Elapsed}");
    }

    // --- 2: a PC with WSL and no usable distro ---

    private static SetupReport Blocking() => new("Ubuntu-24.04", false, false,
        [new SetupStepInfo(SetupIds.Distro, SetupStatus.Missing, "Ubuntu 24.04", "not installed", "distro_install", false)]);

    [Fact]
    public void AMissingDistroOpensTheWizardButAStoppedOneDoesNot()
    {
        var missing = new TraySnapshot([], DistroStopped: true, Distro: "Ubuntu-24.04", DistroMissing: true);
        var stopped = new TraySnapshot([], DistroStopped: true, Distro: "Ubuntu-24.04");

        Assert.True(LaunchPlanner.NeedsSetupCheck(missing, dismissed: false));
        Assert.Equal(LaunchAction.OpenWizard, LaunchPlanner.AtLaunch(missing, Blocking(), dismissed: false, resumeFlag: false));

        Assert.False(LaunchPlanner.NeedsSetupCheck(stopped, dismissed: false));
        Assert.Equal(LaunchAction.Nothing, LaunchPlanner.AtLaunch(stopped, Blocking(), dismissed: false, resumeFlag: false));
    }

    [Fact]
    public void AMissingDistroStillRespectsTheOtherReasonsNotToOpen()
    {
        var missing = new TraySnapshot([], DistroStopped: true, Distro: "Ubuntu-24.04", DistroMissing: true);
        Assert.Equal(LaunchAction.Nothing, LaunchPlanner.AtLaunch(missing, Blocking(), dismissed: true, resumeFlag: false));
        Assert.Equal(LaunchAction.Nothing, LaunchPlanner.AtLaunch(missing, null, dismissed: false, resumeFlag: false));
        Assert.Equal(LaunchAction.Nothing, LaunchPlanner.AtLaunch(missing, SetupReport.Empty, dismissed: false, resumeFlag: false));
        Assert.False(LaunchPlanner.NeedsSetupCheck(missing, dismissed: true));
    }

    [Theory]
    [InlineData("docker-desktop", true)]
    [InlineData("Docker-Desktop-Data", true)]
    [InlineData("rancher-desktop", true)]
    [InlineData("rancher-desktop-data", true)]
    [InlineData("podman-machine-default", true)]
    [InlineData("Ubuntu-24.04", false)]
    [InlineData("Debian", false)]
    public void ToolDistrosAreRecognisedByPrefix(string name, bool tool) => Assert.Equal(tool, DistroName.IsToolDistro(name));

    [Fact]
    public void ADockerDefaultIsNeverTheWatchedDistro()
    {
        // the default wins when it is usable ...
        Assert.Equal("Ubuntu-24.04", DistroName.Pick([("docker-desktop", false), ("Ubuntu-24.04", true)]));
        // ... a tool distro never does, default or not: the only usable one is picked
        Assert.Equal("Ubuntu-24.04", DistroName.Pick([("docker-desktop", true), ("Ubuntu-24.04", false)]));
        Assert.Equal("Debian", DistroName.Pick([("rancher-desktop", true), ("podman-machine-default", false), ("Debian", false)]));
        // several candidates and no usable default is a choice for the person, not a guess
        Assert.Null(DistroName.Pick([("docker-desktop", true), ("Ubuntu-24.04", false), ("Debian", false)]));
        Assert.Null(DistroName.Pick([("docker-desktop", true), ("docker-desktop-data", false)]));
        Assert.Null(DistroName.Pick([]));
    }

    // --- 3: the poll reads the document out of the output ---

    private const string ListDocument = """{"schema_version":1,"benches":[{"name":"a","path":"/home/x/a"}]}""";

    private static (ShimBenchSource Source, FakeProcessRunner Runner) Shim()
    {
        var runner = new FakeProcessRunner();
        return (new ShimBenchSource(runner, () => @"C:\bin\benchbar.exe"), runner);
    }

    [Fact]
    public async Task APollPicksTheDocumentOutOfTheLines()
    {
        var (source, runner) = Shim();
        runner.Answer = (_, _) => new ProcessResult(0, "note: using the cached distro\r\n" + ListDocument + "\r\n", "");
        var entry = Assert.Single(await source.ListAsync(TestContext.Current.CancellationToken));
        Assert.Equal("/home/x/a", entry.Path);

        runner.Answer = (_, _) => new ProcessResult(0, ListDocument, ""); // one document, as before
        Assert.Single(await source.ListAsync(TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task ANewerSchemaIsRefusedWithItsOwnMessage()
    {
        var (source, runner) = Shim();
        runner.Answer = (_, _) => new ProcessResult(0, """{"schema_version":2,"benches":[]}""", "");
        var ex = await Assert.ThrowsAsync<UnsupportedSchemaException>(() => source.ListAsync(TestContext.Current.CancellationToken));
        Assert.Contains("schema 2", ex.Message);

        runner.Answer = (_, _) => new ProcessResult(0, "banner\n" + """{"schema_version":3,"bench":"/b","state":"running"}""", "");
        await Assert.ThrowsAsync<UnsupportedSchemaException>(() => source.StatusAsync(new BenchEntry("b", "/b", true, null), TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task AnAnswerThatIsNotJsonNamesAVersionMismatchAndQuotesTheFirstLine()
    {
        var (source, runner) = Shim();
        runner.Answer = (_, _) => new ProcessResult(0, "\r\nbenchbar: unknown option --json\nUsage: benchbar list\n", "");
        var ex = await Assert.ThrowsAsync<CliProblemException>(() => source.ListAsync(TestContext.Current.CancellationToken));
        Assert.Contains("version", ex.Message);
        Assert.Contains("benchbar: unknown option --json", ex.Message);
        Assert.DoesNotContain("Usage:", ex.Message);
        Assert.DoesNotContain("JsonReaderException", ex.Message);
        Assert.DoesNotContain("is an invalid start", ex.Message);

        runner.Answer = (_, _) => new ProcessResult(0, "   \n", "");
        ex = await Assert.ThrowsAsync<CliProblemException>(() => source.ListAsync(TestContext.Current.CancellationToken));
        Assert.Contains("printed nothing", ex.Message);
    }

    [Fact]
    public async Task ADocumentOfTheWrongShapeIsTheSameReadableProblem()
    {
        var (source, runner) = Shim();
        runner.Answer = (_, _) => new ProcessResult(0, """{"schema_version":1,"benches":"none"}""", "");
        var ex = await Assert.ThrowsAsync<CliProblemException>(() => source.ListAsync(TestContext.Current.CancellationToken));
        Assert.Contains("version", ex.Message);
    }

    [Fact]
    public async Task TheSetupCheckReadsTheSameWayAndNeverShowsAParserMessage()
    {
        var checkText = File.ReadAllText(Path.Combine(Fixtures.Dir("setup"), "check.json"));
        var runner = new CapturingProcessRunner { Next = new ProcessResult(0, "WARN: stale cache\n" + checkText.ReplaceLineEndings("\n"), "") };
        var service = new ShimSetupService(runner, new RecordingStream(), () => @"C:\x\benchbar.exe");
        var report = await service.CheckAsync("Ubuntu-24.04", TestContext.Current.CancellationToken);
        Assert.NotEmpty(report.Steps);

        runner.Next = new ProcessResult(0, "Segmentation fault\n", "");
        var ex = await Assert.ThrowsAsync<CliProblemException>(() => service.CheckAsync("Ubuntu-24.04", TestContext.Current.CancellationToken));
        Assert.Contains("Segmentation fault", ex.Message);
        Assert.Contains("version", ex.Message);

        runner.Next = new ProcessResult(0, """{"schema_version":9,"steps":[]}""", "");
        await Assert.ThrowsAsync<UnsupportedSchemaException>(() => service.CheckAsync("Ubuntu-24.04", TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task ThePollerShowsTheReadableLine()
    {
        var (poller, source, _, probe) = PollerTests.Make();
        source.ListFails = CliOutput.Unreadable("oops\n", "list");
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();
            Assert.Contains("version", poller.Last.Problem);
            Assert.Contains("oops", poller.Last.Problem);
        }
    }

    [Theory]
    [InlineData("benchbar.exe 0.8.2", "0.8.2", null)]
    [InlineData("benchbar.exe 0.8.2", "0.8.2+abc123", null)]
    [InlineData("benchbar.exe 0.8.1", "0.8.2", "differ")]
    [InlineData("benchbar.exe dev", "0.8.2", null)]
    [InlineData("benchbar.exe 0.8.2", "0.0.0-dev", null)]
    [InlineData(null, "0.8.2", null)]
    [InlineData("benchbar.exe 0.8.2-rc1", "0.8.2", null)]
    public void TheShimVersionIsComparedWithTheTrays(string? shim, string tray, string? expected)
    {
        var notice = VersionMismatch.Notice(shim, tray);
        if (expected is null) Assert.Null(notice);
        else
        {
            Assert.NotNull(notice);
            Assert.Contains("0.8.1", notice);
            Assert.Contains("0.8.2", notice);
            Assert.Contains("installer", notice);
        }
    }

    [Fact]
    public void TheMismatchNoticeSaysWhichFileRan() =>
        Assert.Contains(@"C:\old\benchbar.exe", VersionMismatch.Notice("benchbar.exe 0.7.0", "0.8.2", @"C:\old\benchbar.exe"));

    // --- 4: a step or an action this tray does not know ---

    private static async Task<(WizardModel Model, SetupFixture Fixture)> UnknownAsync()
    {
        var fixture = new SetupFixture();
        fixture.Check("check-unknown.json");
        var model = new WizardModel(fixture.Service, new FakeWizardHost());
        await model.ChooseNewBench();
        return (model, fixture);
    }

    [Fact]
    public async Task AnUnknownBlockingStepShowsItsOwnWordsAndHoldsContinueBack()
    {
        var (model, _) = await UnknownAsync();

        var os = model.Rows.Single(r => r.Step.Id == SetupIds.DistroOs);
        Assert.Equal("Ubuntu version", os.Step.Title);
        Assert.Contains("Debian 12 is not Ubuntu 24.04", os.Detail);
        Assert.Contains("wsl.exe --install -d Ubuntu-24.04", os.Detail); // the step's own fix text
        Assert.Null(os.ButtonLabel);                                      // no action: the person has to act
        Assert.True(os.Step.NeedsManualFix);
        Assert.Equal("wsl.exe --install -d Ubuntu-24.04", os.Step.CopyText);

        Assert.False(model.CanContinueFromCheck);
        Assert.True(model.Report.HasBlockingFailure);
        Assert.Contains(model.Report.Steps, s => s.Id == SetupIds.DistroOs && s.StopsTheWizard);
        Assert.Null(model.CheckError);
    }

    [Fact]
    public async Task AnUnknownActionGetsTheGenericButtonAndTheGenericRun()
    {
        var (model, fixture) = await UnknownAsync();

        var row = model.Rows.Single(r => r.Step.Id == "future_step");
        Assert.Equal("A step from a newer shim", row.Step.Title);
        Assert.Equal("Set Up", row.ButtonLabel);
        Assert.Equal("future_step", model.Report.NextActionable!.Id);

        await model.RunStepAsync("future_step");

        Assert.Contains("run future_action", fixture.Service.Calls);
        Assert.Null(model.CheckError);
    }

    [Fact]
    public async Task AnOlderCliGetsTheUpdateLabelAndRunsTheCliInstallAction()
    {
        var (model, fixture) = await UnknownAsync();

        var cli = model.Rows.Single(r => r.Step.Id == SetupIds.Cli);
        Assert.Equal("0.8.0", cli.Step.CliVersion);
        Assert.Equal("Update", cli.ButtonLabel);
        Assert.Contains("does not match benchbar.exe 0.8.2", cli.Detail);

        await model.RunStepAsync(SetupIds.Cli);
        Assert.Contains("run cli_install", fixture.Service.Calls);
    }

    [Theory]
    [InlineData("\"cli_version\":\"0.8.0\"", "benchbar is not on the PATH inside Ubuntu", "Update")] // the field alone
    [InlineData("\"x\":1", "benchbar 0.8.0 in Ubuntu does not match benchbar.exe 0.8.2", "Update")] // an older shim: the detail alone
    [InlineData("\"x\":1", "benchbar is not on the PATH inside Ubuntu", "Set Up")] // a plain install
    public async Task TheCliRowSaysUpdateOnlyWhenACliIsThere(string extra, string detail, string label)
    {
        var fixture = new SetupFixture();
        var text = File.ReadAllText(Path.Combine(fixture.Setup, "check-unknown.json"));
        text = text.Replace(",\"cli_version\":\"0.8.0\"", "," + extra);
        text = text.Replace("benchbar 0.8.0 in Ubuntu does not match benchbar.exe 0.8.2: update it with benchbar.exe setup run cli_install", detail);
        File.WriteAllText(Path.Combine(fixture.Setup, "check.json"), text);
        var model = new WizardModel(fixture.Service, new FakeWizardHost());
        await model.ChooseNewBench();
        Assert.Equal(label, model.Rows.Single(r => r.Step.Id == SetupIds.Cli).ButtonLabel);
    }

    [Fact]
    public async Task UnknownAdviceStaysAdviceAndAnUnknownAdviceActionNeverRunsInSetUpEverything()
    {
        var (model, fixture) = await UnknownAsync();

        var keep = model.Rows.Single(r => r.Step.Id == SetupIds.Keepalive);
        Assert.False(keep.Step.Blocking);
        var mystery = model.Rows.Single(r => r.Step.Id == "mystery_advice");
        Assert.False(mystery.Step.Blocking);
        Assert.True(mystery.Step.HasAdviceCommand);
        Assert.Equal("benchbar.exe mystery", mystery.Step.CopyText);

        await model.FixAllAsync();
        // blocking actions only, in order, and never the keepalive
        Assert.DoesNotContain(fixture.Service.Calls, c => c.Contains("keepalive_install"));
        Assert.Contains("run future_action", fixture.Service.Calls);
    }

    [Fact]
    public void AReportWithUnknownThingsParsesWithoutThrowing()
    {
        var report = SetupJson.ParseCheck("""
            {"schema_version":1,"distro":"U","ready":false,"future_field":{"a":1},"steps":[
              {"id":"brand_new","status":"strange","title":"Brand new","detail":"d","action":"brand_new_action","needs_admin":true,"extra":[1,2]},
              {"status":"ok","title":"no id"},
              {"id":"distro_os","status":"fail","title":"Ubuntu version","detail":"Debian","fix_command":"wsl.exe --install -d Ubuntu-24.04"}]}
            """);
        Assert.Equal(2, report.Steps.Count);
        var unknown = report.Step("brand_new")!;
        Assert.Equal(SetupStatus.Unknown, unknown.Status);
        Assert.True(unknown.Blocking);        // an id nobody knows blocks until the shim says otherwise
        Assert.True(unknown.StopsTheWizard);
        Assert.Equal("brand_new_action", unknown.Action);
        Assert.Equal("wsl.exe --install -d Ubuntu-24.04", report.Step(SetupIds.DistroOs)!.Fix);
        Assert.False(report.CanContinue);
    }

    // --- 5: windows are counted ---

    [Theory]
    [InlineData(new[] { BenchState.Stopped }, 30)]
    [InlineData(new[] { BenchState.Running }, 30)]
    [InlineData(new[] { BenchState.Starting }, 2)]
    public void AnIdleViewerDoesNotHoldTheFiveSecondRate(BenchState[] states, double seconds) =>
        Assert.Equal(S(seconds), BenchPoller.NextDelay(states, flyoutOpen: true, idleStep: 0, viewerIdle: true));

    [Fact]
    public void AnActiveViewerKeepsTheFiveSecondRate() =>
        Assert.Equal(BenchPoller.FlyoutOpenDelay, BenchPoller.NextDelay([BenchState.Stopped], flyoutOpen: true, idleStep: 0, viewerIdle: false));

    [Fact]
    public async Task AWindowThatIsNotInUseBacksOffToThirtySecondsAndComingBackSpeedsUp()
    {
        var (poller, _, time, probe) = PollerTests.Make();
        using (poller)
        using (probe)
        {
            poller.Start();
            await probe.NextAsync();
            poller.SetFlyoutOpen(true);
            time.Advance(S(5));
            await probe.NextAsync();

            poller.SetViewerIdle(true);
            time.Advance(S(29.9));
            await probe.NoneForAsync(100);
            time.Advance(S(0.1));
            await probe.NextAsync();

            poller.SetViewerIdle(false);
            time.Advance(S(5));
            await probe.NextAsync();
        }
    }

    [Fact]
    public async Task ClosingOneOfTwoWindowsKeepsTheFastRateUntilTheLastCloses()
    {
        var source = new ScriptedSource();
        source.States["a"] = BenchState.Stopped;
        var host = new FakeHost();
        var time = new FakeTimeProvider();
        var controller = new TrayController(source, new FakeFrameClock(), host, time, new TrayOptions { ListenToSystemEvents = false });
        using (host.Owning(controller))
        {
            host.Ui(controller.Start);
            await UntilAsync(() => host.Changes.Count > 0);

            var changes = host.Changes.Count;
            host.Ui(controller.FlyoutOpened); // the flyout
            await UntilAsync(() => host.Changes.Count > changes);
            changes = host.Changes.Count;
            host.Ui(controller.FlyoutOpened); // the BenchBar window
            await UntilAsync(() => host.Changes.Count > changes);
            Assert.Equal(2, controller.Viewers);

            host.Ui(controller.FlyoutClosed); // the flyout hides: the window is still open
            Assert.Equal(1, controller.Viewers);
            var lists = source.Lists;
            time.Advance(S(5));
            await UntilAsync(() => source.Lists > lists); // still the window rate, not the 30 s one

            host.Ui(controller.FlyoutClosed);
            host.Ui(controller.FlyoutClosed); // an extra close does nothing
            Assert.Equal(0, controller.Viewers);
        }
    }

    [Fact]
    public async Task AViewerThatLeavesAndComesBackNeedsNoWindowsToBeSafe()
    {
        var source = new ScriptedSource();
        var host = new FakeHost();
        var controller = new TrayController(source, new FakeFrameClock(), host, new FakeTimeProvider(), new TrayOptions { ListenToSystemEvents = false });
        using (host.Owning(controller))
        {
            host.Ui(controller.Start);
            await UntilAsync(() => host.Changes.Count > 0);
            host.Ui(() => controller.ViewersActive(false)); // nobody has a window open: nothing to back off
            host.Ui(controller.FlyoutOpened);
            host.Ui(() => controller.ViewersActive(false));
            host.Ui(() => controller.ViewersActive(true));
            host.Ui(controller.FlyoutClosed);
            Assert.Equal(0, controller.Viewers);
        }
    }

    // --- 6: the old WSL share ---

    [Fact]
    public void TheOldShareIsUsedOnlyWhenTheNewOneIsNotThere()
    {
        const string modern = @"\\wsl.localhost\Ubuntu\home\a\x.log";
        const string legacy = @"\\wsl$\Ubuntu\home\a\x.log";
        Assert.Equal(modern, WslPaths.ToWindows("Ubuntu", "/home/a/x.log", p => p == modern || p == legacy));
        Assert.Equal(legacy, WslPaths.ToWindows("Ubuntu", "/home/a/x.log", p => p == legacy));
        Assert.Equal(modern, WslPaths.ToWindows("Ubuntu", "/home/a/x.log", _ => false)); // neither: the error names the modern one
        Assert.Equal(modern, WslPaths.ToWindows("Ubuntu", "/home/a/x.log"));
    }

    // --- 7: the CLI's lock ---

    [Theory]
    [InlineData("Another benchbar run is active (pid 4242).", true)]
    [InlineData("another benchbar run is starting (lock /x is 5 seconds old at most).", true)]
    [InlineData("Could not take the lock /x after 5 tries.", true)]
    [InlineData("[FAIL] bench init failed", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void TheLockLineOfTheCliIsRecognised(string? text, bool held) => Assert.Equal(held, LockText.IsHeld(text));

    [Fact]
    public void AnyOfSeveralTextsCanBeTheLockLine() => Assert.True(LockText.IsHeld(null, "x", "Another benchbar run is active (pid 7)."));

    private sealed class LockedInstall(FixtureSetupService inner, int locked) : DelegatingSetup(inner)
    {
        public int Attempts { get; private set; }

        public override Task<InstallRunResult> InstallAsync(InstallRequest request, InstallSecrets secrets, Action<InstallEvent> onEvent, CancellationToken ct)
        {
            Attempts++;
            if (Attempts > locked) return base.InstallAsync(request, secrets, onEvent, ct);
            var done = new InstallDone(1, null, null, null, [], null, null, "Another benchbar run is active (pid 4242).", null);
            onEvent(new InstallEvent.Done(done));
            return Task.FromResult(new InstallRunResult(1, done, null));
        }
    }

    [Fact]
    public async Task ARunThatMeetsTheLockWaitsAndTriesAgain()
    {
        var fixture = ReadyFixture();
        var service = new LockedInstall(fixture.Service, locked: 2);
        var host = new FakeWizardHost();
        var model = await ReviewedAsync(service, host);
        model.LockWaitEvery = TimeSpan.FromMilliseconds(10);
        model.LockWaitLimit = TimeSpan.FromSeconds(30);
        var phases = new List<InstallPhase>();
        model.Changed += () =>
        {
            if (phases.Count == 0 || phases[^1] != model.Phase) phases.Add(model.Phase);
        };

        await model.StartInstallAsync();

        Assert.Equal(InstallPhase.Succeeded, model.Phase);
        Assert.Equal(3, service.Attempts);
        Assert.Contains(InstallPhase.WaitingForPreviousRun, phases);
        Assert.Equal([true, false], host.AwakeCalls); // awake through the waits, released once
    }

    [Fact]
    public async Task TheWaitForTheLockIsBounded()
    {
        var fixture = ReadyFixture();
        var service = new LockedInstall(fixture.Service, locked: int.MaxValue);
        var model = await ReviewedAsync(service, new FakeWizardHost());
        model.LockWaitEvery = TimeSpan.FromMilliseconds(10);
        model.LockWaitLimit = TimeSpan.FromMilliseconds(35);

        await model.StartInstallAsync();

        Assert.Equal(InstallPhase.Failed, model.Phase);
        Assert.StartsWith(WizardModel.PreviousRunStillGoingMessage, model.Failure!.Message);
        Assert.Contains("pid 4242", model.Failure.Message);
        Assert.InRange(service.Attempts, 3, 8);
        Assert.False(model.IsInstalling);
    }

    [Fact]
    public async Task StopEndsTheWaitForThePreviousRun()
    {
        var fixture = ReadyFixture();
        var service = new LockedInstall(fixture.Service, locked: int.MaxValue);
        var host = new FakeWizardHost();
        var model = await ReviewedAsync(service, host);
        model.LockWaitEvery = TimeSpan.FromMinutes(5);

        var run = model.StartInstallAsync();
        await UntilAsync(() => model.Phase == InstallPhase.WaitingForPreviousRun);
        Assert.True(model.IsInstalling);
        model.Stop();
        await run.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);

        Assert.Equal(InstallPhase.Stopped, model.Phase);
        Assert.False(model.IsInstalling);
        Assert.Equal([true, false], host.AwakeCalls);
    }

    private sealed class HoldFirstInstall(FixtureSetupService inner) : DelegatingSetup(inner)
    {
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public bool Released { get; set; }

        public bool TimeOutInstead { get; set; }

        public override async Task<InstallRunResult> InstallAsync(InstallRequest request, InstallSecrets secrets, Action<InstallEvent> onEvent, CancellationToken ct)
        {
            if (Released) return await base.InstallAsync(request, secrets, onEvent, ct);
            if (TimeOutInstead) throw new TimeoutException("benchbar.exe did not finish in 90 minutes.");
            Started.TrySetResult();
            await Task.Delay(Timeout.Infinite, ct);
            return new InstallRunResult(1, null, null);
        }
    }

    [Fact]
    public async Task RetryAfterAStopChecksFirstAndOrdinaryRetryDoesNot()
    {
        var fixture = ReadyFixture();
        var service = new HoldFirstInstall(fixture.Service);
        var model = await ReviewedAsync(service, new FakeWizardHost());

        var run = model.StartInstallAsync();
        await service.Started.Task;
        model.Stop();
        await run;
        Assert.Equal(InstallPhase.Stopped, model.Phase);

        service.Released = true;
        await model.RetryAsync();

        Assert.Equal(InstallPhase.Succeeded, model.Phase);
        var calls = fixture.Service.Calls.ToList();
        Assert.Equal(2, calls.Count(c => c == "check")); // one from the page, one before the retry
        Assert.True(calls.FindLastIndex(c => c == "check") < calls.FindLastIndex(c => c.StartsWith("install ", StringComparison.Ordinal)));
    }

    [Fact]
    public async Task ATimeoutAlsoChecksBeforeTheRetry()
    {
        var fixture = ReadyFixture();
        var service = new HoldFirstInstall(fixture.Service) { TimeOutInstead = true };
        var model = await ReviewedAsync(service, new FakeWizardHost());

        await model.StartInstallAsync();
        Assert.Equal(InstallPhase.Failed, model.Phase);
        Assert.Contains("did not finish in 90 minutes", model.Failure!.Message);

        service.Released = true;
        await model.RetryAsync();

        Assert.Equal(InstallPhase.Succeeded, model.Phase);
        Assert.Equal(2, fixture.Service.Calls.Count(c => c == "check"));
    }

    [Fact]
    public async Task AnOrdinaryFailureIsRetriedWithoutTheCheck()
    {
        var fixture = ReadyFixture();
        var model = await ReviewedAsync(fixture.Service, new FakeWizardHost());
        fixture.Install("install-failed.jsonl");
        await model.StartInstallAsync();
        Assert.Equal(InstallPhase.Failed, model.Phase);

        fixture.Install("install-ok.jsonl");
        await model.RetryAsync();

        Assert.Equal(InstallPhase.Succeeded, model.Phase);
        Assert.Equal(1, fixture.Service.Calls.Count(c => c == "check"));
    }

    // --- 11: passwords ---

    [Fact]
    public void ARedactorHidesEvenAShortPassword()
    {
        using var two = Secret.From("ab");
        Assert.Equal("x***x", new Redactor([two]).Clean("xabx"));
        using var one = Secret.From("z");
        Assert.Equal("***", new Redactor([one]).Clean("z"));
    }

    [Fact]
    public void ARedactorHidesThePasswordAsAJsonStringHoldsIt()
    {
        using var secret = Secret.From("p\"ss\\wörd<&>");
        var redactor = new Redactor([secret]);

        // as the CLI writes it: only quote and backslash escaped, the letter raw
        Assert.Equal("""{"error":"bad ***"}""", redactor.Clean("""{"error":"bad p\"ss\\wörd<&>"}"""));
        // as System.Text.Json writes it by default
        var escaped = System.Text.Json.JsonEncodedText.Encode(secret.Reveal()).ToString();
        Assert.Equal("""{"error":"bad ***"}""", redactor.Clean("{\"error\":\"bad " + escaped + "\"}"));
        // and plain
        Assert.Equal("echo ***", redactor.Clean("echo p\"ss\\wörd<&>"));
        Assert.DoesNotContain("ss", redactor.Clean("""{"error":"p\"ss\\wörd<&>"}"""));
    }

    [Fact]
    public void OnTheCreateUserPageEightCharactersIsAdviceAndAnEmptyPasswordOrLineBreakBlocks()
    {
        var model = new WizardModel(new SetupFixture().Service, new FakeWizardHost());
        Assert.NotNull(model.PasswordProblem); // empty
        Assert.Null(model.PasswordAdvice);

        // a user that exists with a short password must not be blocked
        model.SetPassword(Pass("short"));
        model.SetConfirm(Pass("short"));
        Assert.Null(model.PasswordProblem);
        Assert.Equal("Use at least 8 characters for a new user.", model.PasswordAdvice);

        model.SetPassword(Pass("eight-ch"));
        model.SetConfirm(Pass("eight-ch"));
        Assert.Null(model.PasswordProblem);
        Assert.Null(model.PasswordAdvice);

        model.SetPassword(Pass("long enough\nsecond line"));
        model.SetConfirm(Pass("long enough\nsecond line"));
        Assert.Equal(WizardModel.PasswordLineBreakMessage, model.PasswordProblem);

        model.SetPassword(Pass("long enough\rsecond"));
        model.SetConfirm(Pass("long enough\rsecond"));
        Assert.Equal(WizardModel.PasswordLineBreakMessage, model.PasswordProblem);
    }

    [Fact]
    public async Task TheAdministratorPasswordFollowsTheSameRules()
    {
        var fixture = ReadyFixture();
        var model = new WizardModel(fixture.Service, new FakeWizardHost());
        await model.ChooseNewBench();
        await model.ContinueFromCheckAsync();

        model.SetAdminPassword(Pass("x"));
        Assert.Contains("at least 8 characters", model.FormProblem);
        model.SetAdminPassword(Pass("long enough\nsecond"));
        Assert.Contains("line break", model.FormProblem);
        model.SetAdminPassword(Pass("long enough"));
        Assert.Null(model.FormProblem);
    }

    // --- 12: why benchbar.exe did not start ---

    [Theory]
    [InlineData(2, ShimStartKind.Missing)]
    [InlineData(3, ShimStartKind.Missing)]
    [InlineData(1260, ShimStartKind.Blocked)]
    [InlineData(4551, ShimStartKind.Blocked)]
    [InlineData(unchecked((int)0x800704EC), ShimStartKind.Blocked)]
    [InlineData(unchecked((int)0x800711C7), ShimStartKind.Blocked)]
    [InlineData(5, ShimStartKind.AccessDenied)]
    [InlineData(22, ShimStartKind.Other)]
    public void TheWindowsErrorCodePicksTheCause(int code, ShimStartKind kind) =>
        Assert.Equal(kind, ShimStart.Classify(new Win32Exception(code, "x")));

    [Fact]
    public void EachCauseHasItsOwnWordsAndFix()
    {
        var missing = ShimStart.Describe(new Win32Exception(2, "x"), @"C:\Programs\BenchBar\benchbar.exe");
        Assert.Contains(@"C:\Programs\BenchBar\benchbar.exe", missing);
        Assert.Contains("install.ps1", missing);
        Assert.Contains("Protection history", missing);
        Assert.Contains("Protection history", ShimStart.Describe(new Win32Exception(3, "x")));

        var blocked = ShimStart.Describe(new Win32Exception(1260, "x"));
        Assert.Contains("Windows blocked benchbar.exe", blocked);
        Assert.Contains("Smart App Control", blocked);

        Assert.Contains("access denied", ShimStart.Describe(new Win32Exception(5, "x")));
        Assert.Equal("benchbar.exe could not be started: odd", ShimStart.Describe(new Win32Exception(22, "odd")));
    }

    [Theory]
    [InlineData(2, "was expected at")]
    [InlineData(1260, "Smart App Control")]
    [InlineData(5, "access denied")]
    [InlineData(22, "could not be started")]
    public async Task TheShimSourceUsesTheCause(int code, string expected)
    {
        var (source, runner) = Shim();
        runner.Throws = new Win32Exception(code, "x");
        var ex = await Assert.ThrowsAsync<CliProblemException>(() => source.ListAsync(TestContext.Current.CancellationToken));
        Assert.Contains(expected, ex.Message);
        var action = await Assert.ThrowsAsync<CliProblemException>(() => source.RunAsync(["up"], TestContext.Current.CancellationToken));
        Assert.Contains(expected, action.Message);
    }

    [Fact]
    public async Task TheSetupServiceAndTheCliClientUseTheCauseToo()
    {
        var setup = new ShimSetupService(new FakeProcessRunner { Throws = new Win32Exception(2, "x") }, new RecordingStream(), () => @"C:\x\benchbar.exe");
        var ex = await Assert.ThrowsAsync<CliProblemException>(() => setup.CheckAsync(null, TestContext.Current.CancellationToken));
        Assert.Contains("was expected at C:", ex.Message);

        var cli = new CliClient(new BlockedStream(), () => @"C:\x\benchbar.exe");
        var result = await cli.RunJsonAsync(["site", "list"], null, TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        Assert.Contains("Smart App Control", result.Error);
    }

    // --- 13: flow and user name ---

    [Fact]
    public async Task ARestartInTheExistingBenchFlowResumesInThatFlow()
    {
        var fixture = new SetupFixture();
        fixture.Check("check-reboot.json");
        var host = new FakeWizardHost();
        var model = new WizardModel(fixture.Service, host);
        await model.ChooseExistingBench();
        Assert.True(model.RestartNeeded);
        Assert.Equal(WizardFlow.ExistingBench, host.SavedFlow);

        var resumed = new WizardModel(fixture.Service, host);
        await resumed.ResumeAtCheck();
        Assert.Equal(WizardFlow.ExistingBench, resumed.Flow);
        Assert.Equal(WizardPage.Check, resumed.Page);
    }

    [Fact]
    public async Task ANewBenchResumesAsANewBenchWhenNothingWasSaved()
    {
        var fixture = new SetupFixture();
        fixture.Check("check-reboot.json");
        var host = new FakeWizardHost();
        var model = new WizardModel(fixture.Service, host);
        await model.ResumeAtCheck();
        Assert.Equal(WizardFlow.NewBench, model.Flow);
    }

    [Fact]
    public void TheResumeFlowIsKeptInTheConfig()
    {
        var path = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"), "config.json");
        var config = TrayConfig.Load(path);
        Assert.Equal("new", config.ResumeFlow);
        config.ResumeFlow = "existing";
        config.Save();
        Assert.Equal("existing", TrayConfig.Load(path).ResumeFlow);
        config.ResumeFlow = "anything else";
        config.Save();
        Assert.Equal("new", TrayConfig.Load(path).ResumeFlow);
    }

    [Fact]
    public async Task TheUserTheStepWillCreateIsNamedBeforeItRuns()
    {
        var fixture = new SetupFixture();
        fixture.Check("check.json");
        File.WriteAllText(Path.Combine(fixture.Setup, "check.json"), File.ReadAllText(Path.Combine(fixture.Setup, "check.json"))
            .Replace("{\"id\":\"distro_user\",\"status\":\"ok\",\"title\":\"Linux user\",\"detail\":\"akash\",\"action\":null", "{\"id\":\"distro_user\",\"status\":\"missing\",\"title\":\"Linux user\",\"detail\":\"no user\",\"action\":\"distro_user\""));
        var model = new WizardModel(fixture.Service, new FakeWizardHost { WindowsUserName = "Akash Mishra" });
        await model.ChooseNewBench();

        var row = model.Rows.Single(r => r.Step.Id == SetupIds.DistroUser);
        Assert.Contains("Create User makes the Linux user akash-mishra", row.Detail);
        model.SetUserName("deploy");
        Assert.Contains("makes the Linux user deploy", model.Rows.Single(r => r.Step.Id == SetupIds.DistroUser).Detail);
    }

    // --- 17: the keep awake row ---

    [Fact]
    public async Task MovingTheKeepAwakeTaskStatesTheConsequenceBeforeTheClickAndIsNeverPartOfSetUpEverything()
    {
        var fixture = ReadyFixture();
        File.WriteAllText(Path.Combine(fixture.Setup, "check.json"), File.ReadAllText(Path.Combine(fixture.Setup, "check.json"))
            .Replace("{\"id\":\"keepalive\",\"status\":\"ok\",\"title\":\"Keep Ubuntu awake\",\"detail\":\"task installed\",\"action\":null",
                "{\"id\":\"keepalive\",\"status\":\"warn\",\"title\":\"Keep Ubuntu awake\",\"detail\":\"keepalive keeps Ubuntu-24.04 alive, but BenchBar uses BenchBarQA2\",\"action\":\"keepalive_install\""));
        var model = new WizardModel(fixture.Service, new FakeWizardHost());
        await model.ChooseNewBench();

        var row = model.Rows.Single(r => r.Step.Id == SetupIds.Keepalive);
        Assert.Equal("Move Keep Awake", row.ButtonLabel);
        Assert.Contains("Ubuntu-24.04 is then no longer kept awake", row.Detail);
        Assert.Contains("BenchBarQA2", row.Detail);
        Assert.Contains("can go idle and stop", row.Detail);
        Assert.True(model.CanContinueFromCheck);
        Assert.Null(model.Report.NextActionable);

        await model.FixAllAsync();
        Assert.DoesNotContain(fixture.Service.Calls, c => c.StartsWith("run ", StringComparison.Ordinal));

        await model.RunStepAsync(SetupIds.Keepalive); // only the click runs it
        Assert.Contains("run keepalive_install", fixture.Service.Calls);
    }
}
