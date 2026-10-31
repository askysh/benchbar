using Xunit;
using BenchBar.Tray.Core;

namespace Tray.Core.Tests;

public class SetupParsingTests
{
    private static string Read(string name) => File.ReadAllText(Path.Combine(Fixtures.Dir("setup"), name));

    [Fact]
    public void TheRealCheckOutputParses()
    {
        var report = SetupJson.ParseCheck(Read("check.json"));
        Assert.Equal("Ubuntu-24.04", report.Distro);
        Assert.True(report.Ready);
        Assert.Equal(13, report.Steps.Count);
        Assert.Equal(SetupStatus.Warn, report.Step(SetupIds.WslConfig)!.Status);
        Assert.Equal(SetupStatus.Warn, report.Step(SetupIds.ShimPath)!.Status);
        Assert.Null(report.Step(SetupIds.ShimPath)!.Action);
        Assert.True(report.Step(SetupIds.WslConfig)!.IsSatisfied);
        Assert.Null(report.NextActionable); // wslconfig and shim_path are only advice
        Assert.True(report.CanContinue);
    }

    [Fact]
    public void AdviceRowsAreNotBlockingAndNeverHoldContinueBack()
    {
        var report = SetupJson.ParseCheck(Read("check.json"));
        Assert.All(new[] { SetupIds.Linger, SetupIds.Keepalive, SetupIds.WslConfig, SetupIds.ShimPath }, id => Assert.False(report.Step(id)!.Blocking));
        Assert.True(report.Step(SetupIds.Cli)!.Blocking);
        var path = report.Step(SetupIds.ShimPath)!;
        Assert.True(path.HasAdviceCommand);
        Assert.Equal("benchbar.exe path install", path.CopyText);
        Assert.False(path.StopsTheWizard);
    }

    [Fact]
    public void AMissingBlockingFieldFallsBackToTheStepId()
    {
        var report = SetupJson.ParseCheck("{\"steps\":[{\"id\":\"linger\",\"status\":\"warn\"},{\"id\":\"cli\",\"status\":\"missing\"}]}");
        Assert.False(report.Step("linger")!.Blocking);
        Assert.True(report.Step("cli")!.Blocking);
        Assert.False(report.CanContinue);
        Assert.Equal("cli", report.FirstBlocking!.Id);
    }

    [Fact]
    public void ABlockingFailureWithNoActionNeedsAManualFix()
    {
        var report = SetupJson.ParseCheck("{\"steps\":[{\"id\":\"distro\",\"status\":\"fail\",\"detail\":\"Ubuntu runs as WSL 1, benches need WSL 2: wsl.exe --set-version Ubuntu 2\",\"action\":null,\"blocking\":true}]}");
        var step = report.Step("distro")!;
        Assert.True(step.NeedsManualFix);
        Assert.Equal("wsl.exe --set-version Ubuntu 2", step.CopyText);
        Assert.False(report.CanContinue);
    }

    [Fact]
    public void AWarningOnABlockingStepDoesNotBlockButNotCheckedDoes()
    {
        var warn = SetupJson.ParseCheck("{\"steps\":[{\"id\":\"virtualization\",\"status\":\"warn\",\"detail\":\"cannot tell\",\"blocking\":true}]}");
        Assert.True(warn.CanContinue);
        var unchecked1 = SetupJson.ParseCheck("{\"steps\":[{\"id\":\"systemd\",\"status\":\"warn\",\"detail\":\"not checked: the distro is stopped\",\"blocking\":true}]}");
        Assert.False(unchecked1.CanContinue);
    }

    [Fact]
    public void TheDoneLineCarriesTheErrorId()
    {
        var done = Assert.IsType<SetupEvent.Done>(SetupJson.ParseLine("{\"event\":\"done\",\"exit\":1,\"error_id\":\"distro_running\"}"));
        Assert.Equal(SetupIds.ErrorDistroRunning, done.ErrorId);
        var plain = Assert.IsType<SetupEvent.Done>(SetupJson.ParseLine("{\"event\":\"done\",\"exit\":0}"));
        Assert.Null(plain.ErrorId);
    }

    [Fact]
    public void AFreshPcShowsTheWaitingRowsAsWaiting()
    {
        var report = SetupJson.ParseCheck(Read("check-fresh.json"));
        var enable = report.Step(SetupIds.WslFeature)!;
        Assert.True(enable.NeedsAdmin);
        Assert.Equal(SetupIds.ActionWslEnable, report.NextActionable!.Action);
        Assert.True(report.Step(SetupIds.Distro)!.Waits);
        Assert.False(enable.Waits);
    }

    [Fact]
    public void ARebootPendingReportOffersTheRestart()
    {
        var report = SetupJson.ParseCheck(Read("check-reboot.json"));
        Assert.True(report.RebootPending);
        Assert.Equal(SetupIds.ActionReboot, report.NextActionable!.Action);
    }

    [Fact]
    public void AStoppedDistroIsNotChecked()
    {
        var report = SetupJson.ParseCheck(Read("check-stopped.json"));
        Assert.True(report.Step(SetupIds.DistroUser)!.NotChecked);
    }

    [Fact]
    public void ANewerSchemaIsRefused() =>
        Assert.Throws<UnsupportedSchemaException>(() => SetupJson.ParseCheck("{\"schema_version\":2,\"steps\":[]}"));

    [Fact]
    public void UnknownStatusAndFieldsAreTolerated()
    {
        var report = SetupJson.ParseCheck("{\"steps\":[{\"id\":\"x\",\"status\":\"odd\",\"extra\":1}],\"future\":true}");
        Assert.Equal(SetupStatus.Unknown, report.Steps[0].Status);
        Assert.False(report.Steps[0].IsSatisfied);
    }

    [Fact]
    public void RunLinesParse()
    {
        Assert.Equal(new SetupEvent.Step("wsl_enable", "running", "m"), SetupJson.ParseLine("{\"event\":\"step\",\"id\":\"wsl_enable\",\"status\":\"running\",\"message\":\"m\"}"));
        Assert.Equal(new SetupEvent.Log("hello"), SetupJson.ParseLine("{\"event\":\"log\",\"line\":\"hello\"}"));
        var done = Assert.IsType<SetupEvent.Done>(SetupJson.ParseLine("{\"event\":\"done\",\"exit\":1,\"changed\":false,\"reboot_required\":true,\"cancelled\":true,\"warnings\":[\"w\"],\"next_actions\":[\"a\"]}"));
        Assert.Equal(1, done.Exit);
        Assert.True(done.Cancelled);
        Assert.True(done.RebootRequired);
        Assert.Equal(["w"], done.Warnings);
        Assert.False(done.UserExisted);
        var existing = Assert.IsType<SetupEvent.Done>(SetupJson.ParseLine(File.ReadAllLines(Path.Combine(Fixtures.Dir("setup"), "run-distro_user-existing.jsonl"))[1]));
        Assert.True(existing.UserExisted);
        Assert.Null(SetupJson.ParseLine("plain text"));
        Assert.Null(SetupJson.ParseLine("{\"event\":\"future\"}"));
        Assert.Null(SetupJson.ParseLine("{broken"));
    }

    [Fact]
    public void ThePlanCountsOnlyTheStepsThatAskForSudoAndWillRun()
    {
        var plan = Assert.IsType<InstallEvent.Plan>(InstallJson.ParseLine(File.ReadAllLines(Path.Combine(Fixtures.Dir("setup"), "plan.jsonl"))[0])).Value;
        Assert.Equal("/home/akash/frappe-bench", plan.Bench);
        Assert.Equal(5, plan.Steps.Count);
        Assert.Equal(["wkhtmltopdf_install", "system_deps"], plan.PrivilegedSteps.Select(s => s.Id));
    }

    [Fact]
    public void TheDoneLineCarriesTheStableErrorId()
    {
        var done = Assert.IsType<InstallEvent.Done>(InstallJson.ParseLine(Read("install-wrong-password.jsonl"))).Value;
        Assert.True(done.WrongSudoPassword);
        var other = Assert.IsType<InstallEvent.Done>(InstallJson.ParseLine("{\"event\":\"done\",\"exit\":1,\"error\":\"nope\"}")).Value;
        Assert.False(other.WrongSudoPassword);
        var viaText = Assert.IsType<InstallEvent.Done>(InstallJson.ParseLine("{\"event\":\"done\",\"exit\":1,\"error\":\"sudo_password_wrong: try again\"}")).Value;
        Assert.True(viaText.WrongSudoPassword);
    }

    [Fact]
    public void WslListParsesNamesStatesAndTheDefault()
    {
        var list = WslList.Parse("  NAME            STATE           VERSION\r\n* Ubuntu-24.04    Running         2\r\n  Debian          Stopped         2\r\n");
        Assert.Equal([new DistroInfo("Ubuntu-24.04", true, "Running", 2), new DistroInfo("Debian", false, "Stopped", 2)], list);
        Assert.Empty(WslList.Parse(""));
    }
}

public class SecretTests
{
    [Fact]
    public void ASecretNeverPrintsItself()
    {
        using var secret = Secret.From("hunter2-pass");
        Assert.Equal("hidden", secret.ToString());
        Assert.DoesNotContain("hunter2", $"{secret}");
        Assert.Equal("empty", Secret.Empty().ToString());
        Assert.Equal("hunter2-pass", secret.Reveal());
        Assert.True(secret.SameAs(Secret.From("hunter2-pass")));
    }

    [Fact]
    public void TheEnvironmentListsNamesOnly()
    {
        using var secret = Secret.From("hunter2-pass");
        var env = new SecretEnvironment().Set("A", "plain").Set("B", secret).Set("EMPTY", Secret.Empty());
        Assert.DoesNotContain("hunter2", env.ToString());
        Assert.Equal(["A", "B"], env.Names.Order());
        Assert.Equal("hunter2-pass", env.Materialize()["B"]);
    }

    [Fact]
    public void TheRedactorHidesAnEchoedPassword()
    {
        using var secret = Secret.From("hunter2-pass");
        Assert.Equal("user:*** done", new Redactor([secret]).Clean("user:hunter2-pass done"));
        Assert.Equal("nothing here", Redactor.None.Clean("nothing here"));
    }
}

public class ShimSetupServiceTests
{
    private static ShimSetupService Service(RecordingStream stream, CapturingProcessRunner? runner = null) =>
        new(runner ?? new CapturingProcessRunner(), stream, () => @"C:\x\benchbar.exe");

    [Fact]
    public async Task CheckAsksForAProbeOnlyWhenTold()
    {
        var runner = new CapturingProcessRunner { Next = new ProcessResult(0, File.ReadAllText(Path.Combine(Fixtures.Dir("setup"), "check.json")), "") };
        var service = Service(new RecordingStream(), runner);
        await service.CheckAsync("Ubuntu-24.04", CancellationToken.None);
        await service.CheckAsync(null, CancellationToken.None, probe: true);
        Assert.Equal(["setup", "check", "--json", "--distro", "Ubuntu-24.04"], runner.Runs[0].Args);
        Assert.Equal(["setup", "check", "--json", "--probe"], runner.Runs[1].Args);
    }

    [Fact]
    public async Task OnlyTheUserActionCarriesThePasswordAndOnlyInTheEnvironment()
    {
        var stream = new RecordingStream
        {
            Lines = ["{\"event\":\"log\",\"line\":\"set pass hunter2-pass for akash\"}", "{\"event\":\"done\",\"exit\":0,\"changed\":true}"],
        };
        var events = new List<SetupEvent>();
        using var password = Secret.From("hunter2-pass");
        var result = await Service(stream).RunActionAsync(new SetupRunRequest("distro_user", "Ubuntu-24.04", "akash", password), events.Add, CancellationToken.None);
        Assert.True(result.Ok);
        var run = stream.Runs[0];
        Assert.Equal(["setup", "run", "distro_user", "--distro", "Ubuntu-24.04", "--user", "akash", "--jsonl"], run.Args);
        Assert.DoesNotContain(run.Args, a => a.Contains("hunter2"));
        Assert.Equal("hunter2-pass", run.Env[SetupEnv.SetupPassword]);
        Assert.Equal(new SetupEvent.Log("set pass *** for akash"), events[0]);

        await Service(stream).RunActionAsync(new SetupRunRequest("systemd", "Ubuntu-24.04"), _ => { }, CancellationToken.None);
        Assert.Empty(stream.Runs[1].Env);
    }

    [Fact]
    public async Task ADeclinedPromptIsCancelledNotAnError()
    {
        var stream = new RecordingStream { Lines = File.ReadAllLines(Path.Combine(Fixtures.Dir("setup"), "run-wsl_enable-cancelled.jsonl")), Result = new StreamResult(1, null) };
        var result = await Service(stream).RunActionAsync(new SetupRunRequest("wsl_enable", null), _ => { }, CancellationToken.None);
        Assert.True(result.Cancelled);
        Assert.False(result.Ok);
    }

    [Fact]
    public async Task AnInstallRunPutsSudoAndPasswordsInTheEnvironmentOnly()
    {
        var stream = new RecordingStream { Lines = File.ReadAllLines(Path.Combine(Fixtures.Dir("setup"), "install.jsonl")) };
        using var admin = Secret.From("admin-secret");
        using var linux = Secret.From("linux-secret");
        var events = new List<InstallEvent>();
        var result = await Service(stream).InstallAsync(new InstallRequest("/home/a/b", "v15-lts", "minimal", "linuxdev.localhost"), new InstallSecrets(admin, linux), events.Add, CancellationToken.None);
        Assert.True(result.Ok);
        var run = stream.Runs[0];
        Assert.Equal(["install", "--yes", "--json", "--bench-dir", "/home/a/b", "--profile", "v15-lts", "--bundle", "minimal", "--site", "linuxdev.localhost"], run.Args);
        Assert.Equal("env", run.Env[SetupEnv.Sudo]);
        Assert.Equal("1", run.Env[SetupEnv.NonInteractive]);
        Assert.Equal("admin-secret", run.Env[SetupEnv.AdminPassword]);
        Assert.Equal("linux-secret", run.Env[SetupEnv.SudoPassword]);
        Assert.False(run.Env.ContainsKey(SetupEnv.MariadbRootPassword));
        Assert.DoesNotContain(run.Args, a => a.Contains("secret"));
        Assert.Contains(events, e => e is InstallEvent.Done { Value.Exit: 0 });
    }

    [Fact]
    public async Task ADryRunSendsNoSudoMode()
    {
        var stream = new RecordingStream { Lines = File.ReadAllLines(Path.Combine(Fixtures.Dir("setup"), "plan.jsonl")) };
        using var admin = Secret.From("admin-secret");
        var plan = await Service(stream).PlanInstallAsync(new InstallRequest("/home/a/b", "v15-lts", "minimal", "s.localhost"), admin, CancellationToken.None);
        Assert.NotNull(plan.Plan);
        Assert.Equal("--dry-run", stream.Runs[0].Args[1]);
        Assert.False(stream.Runs[0].Env.ContainsKey(SetupEnv.Sudo));
        Assert.Equal("admin-secret", stream.Runs[0].Env[SetupEnv.AdminPassword]);
    }

    [Fact]
    public async Task AdoptUsesTheSameStream()
    {
        var stream = new RecordingStream { Lines = File.ReadAllLines(Path.Combine(Fixtures.Dir("setup"), "install.jsonl")) };
        using var linux = Secret.From("linux-secret");
        await Service(stream).AdoptAsync("/home/a/b", new InstallSecrets(null, linux), _ => { }, CancellationToken.None);
        Assert.Equal(["adopt", "/home/a/b", "--yes", "--json"], stream.Runs[0].Args);
        Assert.False(stream.Runs[0].Env.ContainsKey(SetupEnv.AdminPassword));
    }

    [Fact]
    public async Task AMissingShimIsASetupProblem()
    {
        var service = new ShimSetupService(new CapturingProcessRunner(), new RecordingStream(), () => null);
        await Assert.ThrowsAsync<SetupProblemException>(() => service.CheckAsync(null, CancellationToken.None));
    }
}
