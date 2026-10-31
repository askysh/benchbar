using Xunit;
using BenchBar.Tray.Core;

namespace Tray.Core.Tests;

public class WizardModelTests
{
    private static (WizardModel Model, SetupFixture Fixture, FakeWizardHost Host) Make(string check = "check-fresh.json", bool ready = false)
    {
        var fixture = new SetupFixture();
        fixture.Check(check, ready);
        var host = new FakeWizardHost();
        return (new WizardModel(fixture.Service, host), fixture, host);
    }

    private static Secret Pass(string text) => Secret.From(text);

    [Fact]
    public async Task ChoosingANewBenchChecksThePc()
    {
        var (model, fixture, _) = Make();
        await model.ChooseNewBench();
        Assert.Equal(WizardPage.Check, model.Page);
        Assert.Contains("check", fixture.Service.Calls);
        var rows = model.Rows;
        var enable = rows.Single(r => r.Step.Id == SetupIds.WslFeature);
        Assert.Equal("Turn On", enable.ButtonLabel);
        Assert.True(enable.ShowsShield);
        Assert.Equal(WizardModel.AdminNote, enable.AdminNote);
        Assert.True(rows.Single(r => r.Step.Id == SetupIds.Distro).Waiting);
        Assert.False(model.CanContinueFromCheck);
    }

    [Fact]
    public async Task OtherChoicesGoWhereTheyShould()
    {
        var (model, _, _) = Make();
        model.ChooseCommandLineOnly();
        Assert.Equal(WizardPage.CliOnly, model.Page);
        model.Back();
        Assert.Equal(WizardPage.Welcome, model.Page);
        await model.ChooseExistingBench();
        Assert.Equal(WizardFlow.ExistingBench, model.Flow);
        Assert.Equal(WizardPage.Check, model.Page);
    }

    [Fact]
    public void CancelOnTheFirstPageClosesTheWizard()
    {
        var (model, _, _) = Make();
        WizardClose? closed = null;
        model.CloseRequested += c => closed = c;
        model.Back();
        Assert.Equal(WizardClose.Cancelled, closed);
    }

    [Fact]
    public async Task TurningOnWslThatNeedsARestartRemembersToResume()
    {
        var (model, fixture, host) = Make();
        fixture.Run("wsl_enable", "run-wsl_enable.jsonl");
        await model.ChooseNewBench();
        fixture.Check("check-reboot.json");
        await model.RunStepAsync(SetupIds.WslFeature);

        Assert.True(model.RestartNeeded);
        Assert.True(host.ResumeFlag);
        Assert.Contains("run wsl_enable", fixture.Service.Calls);
        var reboot = model.Rows.Single(r => r.Step.Id == SetupIds.Reboot);
        Assert.Equal("Restart Now", reboot.ButtonLabel);
        Assert.False(reboot.ShowsShield);

        // the row never runs the "reboot" action through the shim: only the confirmed button restarts
        await model.RunStepAsync(SetupIds.Reboot);
        Assert.DoesNotContain("run reboot", fixture.Service.Calls);
        Assert.Equal(0, host.Restarts);
        Assert.True(model.RestartNow());
        Assert.Equal(1, host.Restarts);
        Assert.True(model.RestartRequested);
    }

    [Fact]
    public async Task ARefusedRestartKeepsTheFlagAndSaysSo()
    {
        var (model, _, host) = Make("check-reboot.json");
        host.RestartWorks = false;
        await model.ChooseNewBench();
        Assert.True(host.ResumeFlag);
        Assert.False(model.RestartNow());
        Assert.True(host.ResumeFlag); // still useful when the person restarts by hand
        Assert.False(model.RestartRequested);
        Assert.Equal("Windows did not allow the restart. Restart from the Start menu.", model.StepMessages[SetupIds.Reboot]);
        host.RestartWorks = true;
        Assert.True(model.RestartNow());
        Assert.False(model.StepMessages.ContainsKey(SetupIds.Reboot));
    }

    [Fact]
    public async Task ADeclinedWindowsPromptIsFriendlyNotAnError()
    {
        var (model, fixture, host) = Make();
        fixture.Run("wsl_enable", "run-wsl_enable-cancelled.jsonl");
        await model.ChooseNewBench();
        await model.RunStepAsync(SetupIds.WslFeature);
        Assert.Equal("You said no to the Windows prompt. Try again when ready.", model.StepMessages[SetupIds.WslFeature]);
        Assert.False(model.RestartNeeded);
        Assert.False(host.ResumeFlag);
    }

    [Fact]
    public async Task OnlyTheElevatedActionAsksWindowsToLetThePromptThrough()
    {
        var (model, fixture, host) = Make();
        fixture.Run("wsl_enable", "run-wsl_enable.jsonl");
        await model.ChooseNewBench();
        await model.RunStepAsync(SetupIds.WslFeature);
        Assert.Equal(1, host.ForegroundGrants);
        await model.RunStepAsync(SetupIds.Distro); // not admin
        Assert.Equal(1, host.ForegroundGrants);
    }

    [Fact]
    public async Task AStoppedDistroIsProbedOnceWhenItExists()
    {
        var (model, fixture, _) = Make("check-stopped.json");
        await model.ChooseNewBench();
        Assert.Equal(["check", "check --probe"], fixture.Service.Calls);
        await model.CheckAsync();
        Assert.Equal("check --probe", fixture.Service.Calls[^1]);
    }

    [Fact]
    public async Task ACheckWithoutADistroNeverProbes()
    {
        var (model, fixture, _) = Make();
        await model.ChooseNewBench();
        Assert.Equal(["check"], fixture.Service.Calls);
    }

    [Fact]
    public async Task ACheckThatFailsShowsTheLine()
    {
        var (model, fixture, _) = Make();
        File.Delete(Path.Combine(fixture.Setup, "check.json"));
        File.WriteAllText(Path.Combine(fixture.Setup, "check.json"), "not json");
        await model.CheckAsync();
        Assert.NotNull(model.CheckError);
        Assert.False(model.Checking);
    }

    // --- the Linux user ---

    [Fact]
    public void TheLinuxUserSuggestionFollowsTheWindowsName()
    {
        Assert.Equal("akash-mishra", WizardModel.SuggestUserName("Akash Mishra"));
        Assert.Equal("u1abc", WizardModel.SuggestUserName("1abc"));
        Assert.Equal("user", WizardModel.SuggestUserName("..."));
        Assert.Equal(31, WizardModel.SuggestUserName(new string('a', 50)).Length);
    }

    [Fact]
    public async Task TheUserRowOpensTheUserPageAndCreatesTheUser()
    {
        var (model, fixture, host) = Make("check.json");
        // a PC whose Ubuntu has no user yet
        File.WriteAllText(Path.Combine(fixture.Setup, "check.json"), File.ReadAllText(Path.Combine(fixture.Setup, "check.json"))
            .Replace("{\"id\":\"distro_user\",\"status\":\"ok\",\"title\":\"Linux user\",\"detail\":\"akash\",\"action\":null", "{\"id\":\"distro_user\",\"status\":\"missing\",\"title\":\"Linux user\",\"detail\":\"no user\",\"action\":\"distro_user\""));
        await model.ChooseNewBench();
        Assert.Equal("Create User", model.Rows.Single(r => r.Step.Id == SetupIds.DistroUser).ButtonLabel);
        await model.RunStepAsync(SetupIds.DistroUser);
        Assert.Equal(WizardPage.LinuxUser, model.Page);
        Assert.Equal("akash-mishra", model.UserName);

        Assert.False(model.CanCreateUser);
        model.SetPassword(Pass("one"));
        model.SetConfirm(Pass("two"));
        Assert.Equal("The two passwords are not the same.", model.PasswordProblem);
        model.SetConfirm(Pass("one"));
        model.SetUserName("Bad Name");
        Assert.NotNull(model.UserNameProblem);
        model.SetUserName("root");
        Assert.NotNull(model.UserNameProblem);
        model.SetUserName("akash");
        Assert.True(model.CanCreateUser);

        fixture.Check("check.json"); // after the user exists the shim says so
        await model.CreateUserAsync();
        Assert.Contains("run distro_user --user akash (password)", fixture.Service.Calls);
        Assert.True(model.UserCreated);
        Assert.Equal(WizardPage.Check, model.Page);
        Assert.False(host.ResumeFlag);
    }

    [Fact]
    public async Task AnExistingUserKeepsItsOwnPasswordAndTheInstallAsksForIt()
    {
        var (model, fixture, _) = Make("check.json", ready: true);
        // the shim reports that the user was already there
        fixture.Run("distro_user", "run-distro_user-existing.jsonl");
        File.WriteAllText(Path.Combine(fixture.Setup, "check.json"), File.ReadAllText(Path.Combine(fixture.Setup, "check.json"))
            .Replace("\"ready\":true", "\"ready\":false")
            .Replace("{\"id\":\"distro_user\",\"status\":\"ok\",\"title\":\"Linux user\",\"detail\":\"akash\",\"action\":null", "{\"id\":\"distro_user\",\"status\":\"missing\",\"title\":\"Linux user\",\"detail\":\"no user\",\"action\":\"distro_user\""));
        await model.ChooseNewBench();
        await model.RunStepAsync(SetupIds.DistroUser);
        model.SetUserName("akash");
        model.SetPassword(Pass("typed-here"));
        model.SetConfirm(Pass("typed-here"));
        fixture.Check("check.json", ready: true);
        await model.CreateUserAsync();

        Assert.True(model.UserExisted);
        Assert.True(model.LinuxPassword.IsEmpty); // not that user's password: never used for sudo
        await model.ContinueFromCheckAsync();
        model.SetAdminPassword(Pass("admin-pass"));
        await model.ReviewAsync();
        LinuxPasswordRequest? asked = null;
        model.AskLinuxPassword = r =>
        {
            asked = r;
            return Task.FromResult<Secret?>(Pass("real-linux-pass"));
        };
        await model.StartInstallAsync();
        Assert.Equal(new LinuxPasswordRequest(2, false, UserExisted: true), asked);
        Assert.Equal(InstallPhase.Succeeded, model.Phase);
    }

    [Fact]
    public void ALineBreakInThePasswordIsRefused()
    {
        var (model, _, _) = Make();
        model.SetPassword(Pass("a\nb"));
        model.SetConfirm(Pass("a\nb"));
        Assert.Equal("The password cannot contain a line break.", model.PasswordProblem);
    }

    [Fact]
    public async Task LeavingTheUserPageForgetsAHalfTypedPassword()
    {
        var (model, fixture, _) = Make("check.json");
        File.WriteAllText(Path.Combine(fixture.Setup, "check.json"), File.ReadAllText(Path.Combine(fixture.Setup, "check.json"))
            .Replace("{\"id\":\"distro_user\",\"status\":\"ok\",\"title\":\"Linux user\",\"detail\":\"akash\",\"action\":null", "{\"id\":\"distro_user\",\"status\":\"missing\",\"title\":\"Linux user\",\"detail\":\"no user\",\"action\":\"distro_user\""));
        await model.ChooseNewBench();
        await model.RunStepAsync(SetupIds.DistroUser);
        Assert.Equal(WizardPage.LinuxUser, model.Page);
        model.SetPassword(Pass("typed"));
        model.Back();
        Assert.Equal(WizardPage.Check, model.Page);
        Assert.True(model.LinuxPassword.IsEmpty);
    }

    // --- the form ---

    [Fact]
    public void TheFormRules()
    {
        Assert.True(WizardModel.IsValidSite("linuxdev.localhost"));
        Assert.False(WizardModel.IsValidSite("Bad"));
        Assert.False(WizardModel.IsValidSite(""));
        Assert.True(WizardModel.IsValidFolder("/home/a/frappe-bench"));
        Assert.False(WizardModel.IsValidFolder("~/frappe-bench"));
        Assert.False(WizardModel.IsValidFolder("/home/a/x y"));
        Assert.False(WizardModel.IsValidFolder("/home/../etc"));
        Assert.False(WizardModel.IsValidFolder("/a;rm"));
    }

    // --- the whole run ---

    private static async Task<(WizardModel Model, SetupFixture Fixture, FakeWizardHost Host)> ReadyForReview()
    {
        var (model, fixture, host) = Make("check.json", ready: true);
        await model.ChooseNewBench();
        Assert.True(model.CanContinueFromCheck);
        await model.ContinueFromCheckAsync();
        Assert.Equal(WizardPage.NewBench, model.Page);
        Assert.Equal("/home/fixture/frappe-bench", model.Folder);
        Assert.Equal("linuxdev.localhost", model.Site);
        Assert.NotNull(model.FormProblem); // no Administrator password yet
        model.SetAdminPassword(Pass("admin-pass"));
        Assert.Null(model.FormProblem);
        await model.ReviewAsync();
        Assert.Equal(WizardPage.Review, model.Page);
        Assert.NotNull(model.Plan);
        Assert.True(model.CanInstall);
        return (model, fixture, host);
    }

    [Fact]
    public async Task ReviewAsksForTheLinuxPasswordForTheSudoStepsThenInstalls()
    {
        var (model, fixture, host) = await ReadyForReview();
        LinuxPasswordRequest? asked = null;
        model.AskLinuxPassword = request =>
        {
            asked = request;
            return Task.FromResult<Secret?>(Pass("linux-pass"));
        };
        await model.StartInstallAsync();

        Assert.Equal(new LinuxPasswordRequest(2, false), asked);
        Assert.Equal(WizardPage.Done, model.Page);
        Assert.Equal(InstallPhase.Succeeded, model.Phase);
        Assert.Equal("http://linuxdev.localhost:8000", model.SiteUrl);
        Assert.Contains(fixture.Service.Calls, c => c.StartsWith("install ") && c.EndsWith("+admin +sudo"));
        Assert.All(model.InstallRows.Where(r => r.Parent is null), r => Assert.Equal(InstallStepStatus.Done, r.Status));
        model.OpenSite();
        Assert.Equal(["http://linuxdev.localhost:8000"], host.Opened);
        model.CopyMcp();
        Assert.Equal(WizardModel.McpLine, host.Copied[0]);
        Assert.Equal("claude mcp add benchbar -- benchbar.exe mcp", WizardModel.McpLine);
    }

    [Fact]
    public async Task ACreatedUserNeverTriggersTheDialog()
    {
        var (model, _, _) = await ReadyForReview();
        model.SetPassword(Pass("linux-pass"));
        var asked = false;
        model.AskLinuxPassword = _ =>
        {
            asked = true;
            return Task.FromResult<Secret?>(null);
        };
        await model.StartInstallAsync();
        Assert.False(asked);
        Assert.Equal(InstallPhase.Succeeded, model.Phase);
    }

    [Fact]
    public async Task CancellingTheDialogStaysOnReview()
    {
        var (model, fixture, _) = await ReadyForReview();
        model.AskLinuxPassword = _ => Task.FromResult<Secret?>(null);
        await model.StartInstallAsync();
        Assert.Equal(WizardPage.Review, model.Page);
        Assert.DoesNotContain(fixture.Service.Calls, c => c.StartsWith("install "));
    }

    [Fact]
    public async Task AWrongSudoPasswordAsksAgainAndSaysSo()
    {
        var (model, fixture, _) = await ReadyForReview();
        var asks = new List<LinuxPasswordRequest>();
        model.AskLinuxPassword = request =>
        {
            asks.Add(request);
            return Task.FromResult<Secret?>(Pass("linux-pass"));
        };
        fixture.Install("install-wrong-password.jsonl");
        await model.StartInstallAsync();
        Assert.Equal(InstallPhase.NeedsLinuxPassword, model.Phase);
        Assert.Equal(WizardPage.Install, model.Page);

        fixture.Install("install-ok.jsonl");
        await model.RetryAsync();
        Assert.Equal([new LinuxPasswordRequest(2, false), new LinuxPasswordRequest(2, true)], asks);
        Assert.Equal(InstallPhase.Succeeded, model.Phase);
    }

    [Fact]
    public async Task AFailedStepShowsItsLineAndTheFix()
    {
        var (model, fixture, _) = await ReadyForReview();
        model.AskLinuxPassword = _ => Task.FromResult<Secret?>(Pass("linux-pass"));
        File.WriteAllText(Path.Combine(fixture.Setup, "install.jsonl"), File.ReadAllText(Path.Combine(fixture.Setup, "install-failed.jsonl")));
        await model.StartInstallAsync();
        Assert.Equal(InstallPhase.Failed, model.Phase);
        Assert.Equal("Bench and site", model.Failure!.Step);
        Assert.Equal("[FAIL] bench init failed", model.Failure.Message);
        Assert.Equal("benchbar doctor --fix-hints", model.Failure.Fix);
        Assert.EndsWith("x.log", model.Failure.Log);
    }

    [Fact]
    public async Task ExitTwoWantsTheMariaDbRootPassword()
    {
        var (model, fixture, _) = await ReadyForReview();
        model.AskLinuxPassword = _ => Task.FromResult<Secret?>(Pass("linux-pass"));
        fixture.Install("install-root-password.jsonl");
        await model.StartInstallAsync();
        Assert.Equal(InstallPhase.NeedsRootPassword, model.Phase);

        await model.RetryAsync(); // no root password yet: nothing runs
        Assert.Equal(1, fixture.Service.Calls.Count(c => c.StartsWith("install ")));

        fixture.Install("install-ok.jsonl");
        model.SetRootPassword(Pass("root-pass"));
        await model.RetryAsync();
        Assert.Equal(InstallPhase.Succeeded, model.Phase);
        Assert.EndsWith("+admin +sudo +root", fixture.Service.Calls[^1]);
    }

    [Fact]
    public async Task StopEndsTheRunAndRunAgainContinues()
    {
        var fixture = new SetupFixture();
        fixture.Check("check.json", ready: true);
        var gate = new GatedSetup(fixture.Service);
        var model = new WizardModel(gate, new FakeWizardHost());
        await model.ChooseNewBench();
        await model.ContinueFromCheckAsync();
        model.SetAdminPassword(Pass("admin-pass"));
        await model.ReviewAsync();
        model.SetPassword(Pass("linux-pass"));

        var run = model.StartInstallAsync();
        await gate.Started.Task;
        Assert.True(model.IsInstalling);
        model.Stop();
        await run;
        Assert.Equal(InstallPhase.Stopped, model.Phase);
        Assert.All(model.InstallRows.Where(r => r.Id == "system_deps"), r => Assert.Equal(InstallStepStatus.Stopped, r.Status));
        Assert.False(model.IsInstalling);
    }

    [Fact]
    public async Task AdoptingAnExistingBenchRunsTheAdoptStream()
    {
        var (model, fixture, _) = Make("check.json", ready: true);
        await model.ChooseExistingBench();
        await model.ContinueFromCheckAsync();
        Assert.Equal(WizardPage.ExistingBench, model.Page);
        Assert.Equal("/home/fixture/frappe-bench", model.ExistingPath);
        model.AskLinuxPassword = request =>
        {
            Assert.Equal(1, request.SudoSteps);
            return Task.FromResult<Secret?>(Pass("linux-pass"));
        };
        fixture.Install("install-ok.jsonl");
        File.Copy(Path.Combine(fixture.Setup, "install.jsonl"), Path.Combine(fixture.Setup, "adopt.jsonl"));
        await model.StartAdoptAsync();
        Assert.Contains("adopt /home/fixture/frappe-bench +sudo", fixture.Service.Calls);
        Assert.Equal(WizardPage.Done, model.Page);
    }

    [Fact]
    public async Task FixAllStopsAtTheRestart()
    {
        var (model, fixture, host) = Make();
        fixture.Run("wsl_enable", "run-wsl_enable.jsonl");
        await model.ChooseNewBench();
        fixture.Check("check-reboot.json");
        await model.FixAllAsync();
        Assert.Contains("run wsl_enable", fixture.Service.Calls);
        Assert.DoesNotContain("run reboot", fixture.Service.Calls);
        Assert.True(host.ResumeFlag);
        Assert.False(model.FixingAll);
    }

    [Fact]
    public async Task PasswordsAreNeverInThePrintedState()
    {
        var (model, _, _) = Make();
        model.SetPassword(Pass("super-secret-pw"));
        model.SetAdminPassword(Pass("admin-secret-pw"));
        model.SetRootPassword(Pass("root-secret-pw"));
        var text = model.LinuxPassword + "|" + model.AdminPassword + "|" + model.RootPassword + "|" + model.Request + "|" + model.FormProblem;
        Assert.DoesNotContain("secret", text);
        await Task.CompletedTask;
    }

    [Fact]
    public async Task FinishingClearsTheResumeFlag()
    {
        var (model, _, host) = Make("check-reboot.json");
        await model.ChooseNewBench();
        Assert.True(host.ResumeFlag);
        WizardClose? closed = null;
        model.CloseRequested += c => closed = c;
        model.Finish();
        Assert.Equal(WizardClose.Finished, closed);
        Assert.False(host.ResumeFlag);
    }
}
