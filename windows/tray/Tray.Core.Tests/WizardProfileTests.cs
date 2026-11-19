using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using BenchBar.Tray.TestSupport;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>The profile picker of the New Bench page (issue 175, PAR-5): the list, the gate's refusals, and the flags the install gets.</summary>
public class WizardProfileTests
{
    private const string FutureRefusal = "Profile v17-future is not supported on Linux yet: it needs MariaDB 12.0, apt on this release gives 10.11, and the profile accepts 11.4 to 12.0 only.";

    private static IReadOnlyList<ProfileInfo> Listed() =>
        ProfileListJson.Parse(JsonNode.Parse(File.ReadAllText(Path.Combine(FixtureFiles.Dir("cli"), "profile-list-linux.json")))!.AsObject());

    /// <summary>The same list from a CLI older than 0.9: its entries have no <c>linux_supported</c>, so the gate is asked with a dry run per profile.</summary>
    private static IReadOnlyList<ProfileInfo> ListedByOlderCli() =>
        Listed().Select(p => p with { LinuxSupported = null, UnsupportedReason = null }).ToList();

    /// <summary>Answers the list from the fixture and the gate from a table; every gate call is recorded.</summary>
    private sealed class ProfileSetup(FixtureSetupService inner, IReadOnlyList<ProfileInfo> profiles, string? listError = null) : DelegatingSetup(inner)
    {
        public Dictionary<string, string?> Refusals { get; } = [];
        public List<string> Gated { get; } = [];
        public List<string> GatedBench { get; } = [];
        public int Lists { get; private set; }

        /// <summary>The first read of the list waits for this, and ends when its token is cancelled.</summary>
        public TaskCompletionSource? FirstListHold { get; init; }

        public List<CancellationToken> ListTokens { get; } = [];

        /// <summary>The gate call of this profile waits for <see cref="GateRelease"/>; <see cref="GateEntered"/> says it has begun.</summary>
        public string? HoldGateFor { get; init; }

        public TaskCompletionSource GateEntered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource GateRelease { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public override async Task<ProfileListResult> ListProfilesAsync(CancellationToken ct)
        {
            Lists++;
            ListTokens.Add(ct);
            if (Lists == 1 && FirstListHold is { } hold) await hold.Task.WaitAsync(ct);
            return listError is null ? new ProfileListResult(profiles, null) : new ProfileListResult([], listError);
        }

        public override async Task<ProfileGate> CheckProfileAsync(string profile, string benchDir, CancellationToken ct)
        {
            Gated.Add(profile);
            GatedBench.Add(benchDir);
            if (profile == HoldGateFor)
            {
                GateEntered.TrySetResult();
                await GateRelease.Task.WaitAsync(ct);
            }
            return new ProfileGate(profile, Refusals.GetValueOrDefault(profile));
        }
    }

    private static async Task<(WizardModel Model, ProfileSetup Setup)> OnNewBenchPage(IReadOnlyList<ProfileInfo>? profiles = null, string? listError = null)
    {
        var fixture = new SetupFixture();
        fixture.Check("check.json", ready: true);
        return await Go(new ProfileSetup(fixture.Service, profiles ?? Listed(), listError));
    }

    private static async Task<(WizardModel, ProfileSetup)> Go(ProfileSetup setup)
    {
        var model = new WizardModel(setup, new FakeWizardHost());
        await model.ChooseNewBench();
        await model.ContinueFromCheckAsync();
        await model.ProfilesTask;
        return (model, setup);
    }

    [Fact]
    public void ThePickerOffersBuiltInAndValidTeamProfilesOnly()
    {
        var choices = ProfileChoices.From(Listed());
        Assert.Equal(["v15-lts", "v16-lts", "acme", "acme-next"], choices.Select(c => c.Name));
        Assert.Equal([false, false, true, true], choices.Select(c => c.IsTeam));
        Assert.Equal("Python 3.14, Node 24, MariaDB 11.8", choices.Single(c => c.Name == "v16-lts").Versions);
        Assert.Equal("v16-lts  Frappe/ERPNext v16 LTS", choices.Single(c => c.Name == "v16-lts").Text);
        Assert.Equal("acme  Acme ERP (team)", choices.Single(c => c.Name == "acme").Text);
    }

    [Fact]
    public void AProfileAnEarlierFileHidesIsNotOffered()
    {
        var shadowed = Listed().Select(p => p.Name == "acme" ? p with { ShadowedBy = "/home/akash/.config/benchbar/profiles/acme.toml" } : p).ToList();
        Assert.DoesNotContain(ProfileChoices.From(shadowed), c => c.Name == "acme");
    }

    [Fact]
    public void AListFromACliWithoutVersionsStillWorks()
    {
        var json = JsonNode.Parse(File.ReadAllText(Path.Combine(FixtureFiles.Dir("cli"), "profile-list-builtin-only.json")))!.AsObject();
        var choice = Assert.Single(ProfileChoices.From(ProfileListJson.Parse(json)));
        Assert.Null(choice.Versions);
        Assert.Equal("", choice.Detail);
    }

    [Fact]
    public async Task OpeningNewBenchReadsTheListOnceAndAsksNoGateWhenTheListHasTheAnswers()
    {
        var (model, setup) = await OnNewBenchPage();
        Assert.Equal(1, setup.Lists);
        Assert.Empty(setup.Gated);
        Assert.Equal(["v15-lts", "v16-lts", "acme", "acme-next"], model.ProfileChoiceList.Select(c => c.Name));
        Assert.All(model.ProfileChoiceList, c => Assert.True(c.Enabled && c.Answered));
        Assert.False(model.ProfilesChecking);
    }

    [Fact]
    public async Task AProfileTheListSaysLinuxCannotInstallIsOffWithTheListsReasonAndNoDryRunIsMade()
    {
        var reason = "it needs MariaDB 12.0, apt on this release gives 10.11, and the profile accepts 11.4 to 12.0 only";
        var listed = Listed().Select(p => p.Name == "v16-lts" ? p with { LinuxSupported = false, UnsupportedReason = reason } : p).ToList();
        var (model, setup) = await OnNewBenchPage(listed);
        Assert.Empty(setup.Gated);
        var v16 = model.ProfileChoiceList.Single(c => c.Name == "v16-lts");
        Assert.False(v16.Enabled);
        Assert.Equal("Not supported on Linux yet: " + reason + ".", v16.Refusal);
        Assert.EndsWith("(not available here)", v16.Text);
        Assert.True(model.ProfileChoiceList.Single(c => c.Name == "acme").Enabled);
        model.SetProfile("v16-lts");
        Assert.Equal("v15-lts", model.Profile);
    }

    [Fact]
    public void TheListsReasonIsWordedWithOneFullStop()
    {
        Assert.Equal("Not supported on Linux yet: it needs Node 16.", ProfileChoices.Unsupported("it needs Node 16"));
        Assert.Equal("Not supported on Linux yet: it needs Node 16.", ProfileChoices.Unsupported("it needs Node 16. "));
        Assert.Equal("Not supported on Linux yet.", ProfileChoices.Unsupported(null));
    }

    [Fact]
    public async Task OpeningNewBenchWithAnOlderCliAsksTheGateAboutEachProfile()
    {
        var (model, setup) = await OnNewBenchPage(ListedByOlderCli());
        Assert.Equal(WizardPage.NewBench, model.Page);
        Assert.Equal(1, setup.Lists);
        Assert.Equal(["v15-lts", "v16-lts", "acme", "acme-next"], setup.Gated);
        Assert.All(setup.GatedBench, b => Assert.Equal(model.Folder, b));
        Assert.Equal(["v15-lts", "v16-lts", "acme", "acme-next"], model.ProfileChoiceList.Select(c => c.Name));
        Assert.False(model.ProfilesLoading);
        Assert.False(model.ProfilesChecking);
        Assert.Null(model.ProfilesError);
        Assert.Equal("v15-lts", model.Profile);
    }

    [Fact]
    public async Task AProfileTheGateRefusesIsShownOffWithTheClisReason()
    {
        var fixture = new SetupFixture();
        fixture.Check("check.json", ready: true);
        var setup = new ProfileSetup(fixture.Service, ListedByOlderCli());
        // the real refusal line, recorded from the CLI: its done event
        var done = (InstallEvent.Done)InstallJson.ParseLine(File.ReadAllLines(Path.Combine(fixture.Setup, "profile-gate-refused.jsonl"))[0])!;
        setup.Refusals["v16-lts"] = ProfileChoices.Read("v16-lts", null, done.Value).Refusal;
        var (model, _) = await Go(setup);

        var v16 = model.ProfileChoiceList.Single(c => c.Name == "v16-lts");
        Assert.False(v16.Enabled);
        Assert.Equal(FutureRefusal, v16.Refusal);
        Assert.Equal(FutureRefusal, v16.Detail);
        Assert.EndsWith("(not available here)", v16.Text);
        Assert.True(model.ProfileChoiceList.Single(c => c.Name == "v15-lts").Enabled);

        model.SetProfile("v16-lts"); // a refused profile cannot be chosen
        Assert.Equal("v15-lts", model.Profile);
        model.SetProfile("nothing-like-it");
        Assert.Equal("v15-lts", model.Profile);
    }

    [Fact]
    public async Task ChoosingATeamProfilePassesItToInstall()
    {
        var (model, setup) = await OnNewBenchPage();
        model.SetProfile("acme-next");
        Assert.Equal("acme-next", model.Profile);
        Assert.Equal(["--bench-dir", model.Folder, "--profile", "acme-next", "--bundle", "minimal", "--site", WizardModel.DefaultSite], model.Request.Flags);

        model.SetAdminPassword(Secret.From("admin-pass"));
        await model.ReviewAsync();
        Assert.Contains(setup.Inner.Calls, c => c.StartsWith("plan ") && c.Contains("--profile acme-next"));
        Assert.True(model.CanInstall);
        model.SetPassword(Secret.From("linux-pass"));
        await model.StartInstallAsync();
        Assert.Contains(setup.Inner.Calls, c => c.StartsWith("install ") && c.Contains("--profile acme-next"));
    }

    [Fact]
    public async Task TheDefaultProfileStaysV15Lts()
    {
        var (model, setup) = await OnNewBenchPage();
        Assert.Equal("v15-lts", model.Request.Profile);
        model.SetAdminPassword(Secret.From("admin-pass"));
        await model.ReviewAsync();
        Assert.Contains(setup.Inner.Calls, c => c.StartsWith("plan ") && c.Contains("--profile v15-lts"));
    }

    [Fact]
    public async Task WhenTheChosenProfileIsRefusedTheFirstOneThatIsTakenIsChosen()
    {
        var fixture = new SetupFixture();
        fixture.Check("check.json", ready: true);
        var setup = new ProfileSetup(fixture.Service, ListedByOlderCli());
        setup.Refusals["v15-lts"] = "Profile v15-lts is not supported on Linux yet: (a made up reason for this test)";
        var (model, _) = await Go(setup);
        Assert.Equal("v16-lts", model.Profile);
        Assert.True(model.SelectedProfile!.Enabled);
    }

    [Fact]
    public async Task WhenNothingIsTakenTheFormSaysWhy()
    {
        var fixture = new SetupFixture();
        fixture.Check("check.json", ready: true);
        var setup = new ProfileSetup(fixture.Service, ListedByOlderCli().Where(p => p.Name == "v15-lts").ToList());
        setup.Refusals["v15-lts"] = "Profile v15-lts is not supported on Linux yet: (a made up reason for this test)";
        var (model, _) = await Go(setup);
        model.SetAdminPassword(Secret.From("admin-pass"));
        Assert.Equal("v15-lts cannot be used here. Profile v15-lts is not supported on Linux yet: (a made up reason for this test)", model.FormProblem);
        await model.ReviewAsync();
        Assert.Equal(WizardPage.NewBench, model.Page); // Review stays off
    }

    [Fact]
    public async Task AProfileThePersonPickedThatTheGateRefusesLaterStaysPickedAndTheFormSaysWhy()
    {
        var fixture = new SetupFixture();
        fixture.Check("check.json", ready: true);
        var setup = new ProfileSetup(fixture.Service, ListedByOlderCli()) { HoldGateFor = "acme-next" };
        var model = new WizardModel(setup, new FakeWizardHost());
        await model.ChooseNewBench();
        await model.ContinueFromCheckAsync();
        await setup.GateEntered.Task; // the gate is at the last profile; every one is still on offer
        Assert.True(model.ProfilesChecking);
        model.SetProfile("acme-next");
        Assert.Equal("acme-next", model.Profile);
        setup.Refusals["acme-next"] = "Profile acme-next is not supported on Linux yet: (a made up reason for this test)";
        setup.GateRelease.SetResult();
        await model.ProfilesTask;

        Assert.Equal("acme-next", model.Profile); // not moved to another profile behind the person's back
        Assert.False(model.SelectedProfile!.Enabled);
        model.SetAdminPassword(Secret.From("admin-pass"));
        Assert.Equal("acme-next cannot be used here. Profile acme-next is not supported on Linux yet: (a made up reason for this test)", model.FormProblem);
        await model.ReviewAsync();
        Assert.Equal(WizardPage.NewBench, model.Page);
    }

    [Fact]
    public async Task ANewerReadOfTheListStopsTheOlderOneThatIsStillAsking()
    {
        var fixture = new SetupFixture();
        fixture.Check("check.json", ready: true);
        var setup = new ProfileSetup(fixture.Service, Listed()) { FirstListHold = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        var model = new WizardModel(setup, new FakeWizardHost());
        await model.ChooseNewBench();
        await model.ContinueFromCheckAsync();
        var first = model.ProfilesTask;
        Assert.True(model.ProfilesLoading);

        await model.LoadProfilesAsync(force: true); // Try Again, or another distro: a second read while the first waits
        Assert.True(setup.ListTokens[0].IsCancellationRequested);
        Assert.False(setup.ListTokens[1].IsCancellationRequested);
        Assert.Equal(["v15-lts", "v16-lts", "acme", "acme-next"], model.ProfileChoiceList.Select(c => c.Name));

        await first; // the older read ends without touching what the newer one set
        Assert.Equal(2, setup.Lists);
        Assert.False(model.ProfilesLoading);
        Assert.Null(model.ProfilesError);
        Assert.Equal(4, model.ProfileChoiceList.Count);
        await model.LoadProfilesAsync();
        Assert.Equal(2, setup.Lists); // the newer read is the one that counts for the distro
    }

    [Fact]
    public async Task AListThatCannotBeReadLeavesV15LtsAndSaysWhy()
    {
        var (model, setup) = await OnNewBenchPage(listError: "benchbar.exe profile list exited with code 1.");
        Assert.Equal("benchbar.exe profile list exited with code 1.", model.ProfilesError);
        Assert.Equal(["v15-lts"], model.ProfileChoiceList.Select(c => c.Name));
        Assert.Empty(setup.Gated);
        model.SetAdminPassword(Secret.From("admin-pass"));
        Assert.Null(model.FormProblem);
        await model.ReviewAsync();
        Assert.Equal(WizardPage.Review, model.Page);
    }

    [Fact]
    public async Task TryAgainReadsTheListAgainAndOpeningTheSamePageDoesNot()
    {
        var (model, setup) = await OnNewBenchPage();
        await model.LoadProfilesAsync();
        Assert.Equal(1, setup.Lists);
        await model.LoadProfilesAsync(force: true);
        Assert.Equal(2, setup.Lists);
    }

    [Fact]
    public async Task ABenchWithoutAnyServiceListGetsTheFallbackNotACrash()
    {
        var fixture = new SetupFixture();
        fixture.Check("check.json", ready: true);
        var model = new WizardModel(fixture.Service, new FakeWizardHost()); // the fixture service has no cli folder
        await model.ChooseNewBench();
        await model.ContinueFromCheckAsync();
        await model.ProfilesTask;
        Assert.Equal(["v15-lts"], model.ProfileChoiceList.Select(c => c.Name));
        Assert.NotNull(model.ProfilesError);
    }

    // --- the gate's answer, read from the stream of install --dry-run --json --offline --profile NAME ---

    [Fact]
    public void ThePlanLineMeansTheProfileIsTaken()
    {
        var plan = (InstallEvent.Plan)InstallJson.ParseLine(File.ReadAllLines(Path.Combine(FixtureFiles.Dir("setup"), "plan.jsonl"))[0])!;
        Assert.Null(ProfileChoices.Read("v16-lts", plan.Value, null).Refusal);
    }

    [Fact]
    public void ADoneThatFailedBeforeAnyPlanCarriesTheRefusal()
    {
        var done = (InstallEvent.Done)InstallJson.ParseLine(File.ReadAllLines(Path.Combine(FixtureFiles.Dir("setup"), "profile-gate-refused.jsonl"))[0])!;
        Assert.Equal(FutureRefusal, ProfileChoices.Read("v17-future", null, done.Value).Refusal);
    }

    [Fact]
    public void NoAnswerLeavesTheProfileOnOffer()
    {
        Assert.Null(ProfileChoices.Read("v16-lts", null, null).Refusal);
        Assert.Null(ProfileChoices.Read("v16-lts", null, new InstallDone(1, null, null, null, [], null, null, null, null)).Refusal);
    }

    [Fact]
    public async Task TheRealServiceAsksTheGateWithADryRunOffline()
    {
        var stream = new RecordingStream { Lines = File.ReadAllLines(Path.Combine(FixtureFiles.Dir("setup"), "profile-gate-refused.jsonl")) };
        var service = new ShimSetupService(new CapturingProcessRunner(), stream, () => @"C:\x\benchbar.exe");
        var gate = await service.CheckProfileAsync("v17-future", "/home/akash/frappe-bench", CancellationToken.None);
        Assert.Equal(FutureRefusal, gate.Refusal);
        Assert.Equal(["install", "--dry-run", "--json", "--offline", "--bench-dir", "/home/akash/frappe-bench", "--profile", "v17-future"], stream.Runs.Single().Args);
        Assert.False(stream.Runs.Single().Env.ContainsKey(SetupEnv.AdminPassword)); // the gate needs no password
    }

    [Fact]
    public async Task TheRealServiceReadsTheProfileList()
    {
        var runner = new CapturingProcessRunner { Next = new ProcessResult(0, File.ReadAllText(Path.Combine(FixtureFiles.Dir("cli"), "profile-list-linux.json")), "") };
        var service = new ShimSetupService(runner, new RecordingStream(), () => @"C:\x\benchbar.exe");
        var result = await service.ListProfilesAsync(CancellationToken.None);
        Assert.Null(result.Error);
        Assert.Equal(["profile", "list", "--json"], runner.Runs.Single().Args);
        Assert.Contains(result.Profiles, p => p.Name == "v16-lts" && p.Mariadb == "11.8");
    }

    [Fact]
    public async Task AMissingShimOrAnEmptyAnswerIsAProblemLineNotAThrow()
    {
        var none = new ShimSetupService(new CapturingProcessRunner(), new RecordingStream(), () => null);
        Assert.NotNull((await none.ListProfilesAsync(CancellationToken.None)).Error);
        Assert.Null((await none.CheckProfileAsync("v16-lts", "/x", CancellationToken.None)).Refusal);

        var silent = new ShimSetupService(new CapturingProcessRunner { Next = new ProcessResult(1, "", "benchbar: command not found") }, new RecordingStream(), () => @"C:\x\benchbar.exe");
        Assert.Equal("benchbar: command not found", (await silent.ListProfilesAsync(CancellationToken.None)).Error);
    }
}
