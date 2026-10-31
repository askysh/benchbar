using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using Xunit;
using static Tray.Core.Tests.CliFixture;

namespace Tray.Core.Tests;

/// <summary>Team Profiles: the parsers, the rules, the models and the exact calls of every action. Nothing here starts a process.</summary>
public class ProfileSharingTests
{
    private const string Digest = "5d41402abc4b2a76b9719d911017c5925d41402abc4b2a76b9719d911017c592";
    private const string WindowsToml = @"C:\Users\akash\Downloads\acme.toml";
    private const string LinuxToml = "/mnt/c/Users/akash/Downloads/acme.toml";


    private static FakeWsl Wsl()
    {
        var wsl = new FakeWsl();
        wsl.Paths[WindowsToml] = LinuxToml;
        wsl.Paths[@"C:\Users\akash\Desktop\acme.toml"] = "/mnt/c/Users/akash/Desktop/acme.toml";
        return wsl;
    }

    private static (CliClient Client, ScriptedStreamRunner Runner) Cli()
    {
        SynchronizationContext.SetSynchronizationContext(null);
        return CliFixture.Scripted();
    }

    // --- list ---

    [Fact]
    public void TheListGivesEachProfileItsOriginAndWhatItCanDo()
    {
        var profiles = ProfileListJson.Parse(Doc("profile-list.json"));
        Assert.Equal(["v15-lts", "acme", "acme-lite", "mine", "shared", "broken"], profiles.Select(p => p.Name));
        var builtin = profiles[0];
        Assert.False(builtin.IsTeam);
        Assert.Equal("built in", builtin.OriginText);
        Assert.False(builtin.CanExport || builtin.CanCheck || builtin.CanUpdate || builtin.CanRemove);

        var acme = profiles[1];
        Assert.Equal(ProfileOrigin.Subscribed, acme.Origin);
        Assert.Equal("subscribed · acme/bench-config", acme.OriginText);
        Assert.Equal("v15-lts", acme.Base);
        Assert.Equal("Outdated · 2 commits / 5 days", acme.Subscription!.OutdatedText);
        Assert.True(acme.CanExport && acme.CanCheck && acme.CanUpdate && acme.CanRemove);

        var mine = profiles[3];
        Assert.Equal("local", mine.OriginText);
        Assert.True(mine.CanExport && mine.CanCheck);
        Assert.False(mine.CanUpdate || mine.CanRemove);
        Assert.Null(mine.Subscription);

        var shared = profiles[4];
        Assert.Equal("imported", shared.OriginText);
        Assert.True(shared.CanUpdate && shared.CanRemove);
        Assert.Equal("https://example.com/shared.toml", shared.SourceUrl);

        var broken = profiles[5];
        Assert.False(broken.Valid);
        Assert.Equal("profile path", broken.OriginText);
        Assert.Contains("not supported", broken.Error);
        Assert.False(broken.CanExport || broken.CanCheck);
        Assert.NotNull(broken.ShadowedBy);
        Assert.NotEqual(acme.Id, profiles[2].Id);
    }

    [Fact]
    public void ASubscriptionNamesItsSiblingsAndShortensItsRepository()
    {
        var profiles = ProfileListJson.Parse(Doc("profile-list.json"));
        Assert.Equal(["acme", "acme-lite"], ProfileListJson.SiblingsOf(profiles, profiles[1]));
        Assert.Equal("acme/profiles", ProfileInfo.ShortRepo("https://github.com/acme/profiles.git"));
        Assert.Equal("acme/profiles", ProfileInfo.ShortRepo("git@github.com:acme/profiles.git/"));
        Assert.Equal("nothing", ProfileInfo.ShortRepo("nothing"));
        Assert.Null(new ProfileSubscription("r", "d", 0, null, null).OutdatedText);
        Assert.Equal("Outdated · 1 commit / 1 day", new ProfileSubscription("r", "d", 1, 1, null).OutdatedText);
        Assert.Equal("Outdated · 3 commits", new ProfileSubscription("r", "d", 3, null, null).OutdatedText);
        Assert.Throws<FormatException>(() => ProfileListJson.Parse(new JsonObject()));
    }

    // --- rules ---

    [Theory]
    [InlineData("acme", true)]
    [InlineData("a.b_c-d", true)]
    [InlineData("0day", true)]
    [InlineData("", false)]
    [InlineData("Acme", false)]
    [InlineData("-acme", false)]
    [InlineData("_acme", false)]
    [InlineData("a b", false)]
    public void ProfileNamesFollowTheCliRule(string name, bool valid) => Assert.Equal(valid, ProfileName.IsValid(name));

    [Theory]
    [InlineData("https://github.com/acme/profiles/blob/main/acme.toml", true)]
    [InlineData("http://example.com/acme.toml", false)]
    [InlineData("-https://x", false)]
    [InlineData("https://", false)]
    [InlineData("https://a b/c", false)]
    [InlineData("ftp://example.com/a.toml", false)]
    public void OnlyHttpsLinksAreImportUrls(string text, bool valid) => Assert.Equal(valid, ProfileSourceRule.IsImportUrl(text));

    [Theory]
    [InlineData(@"C:\Users\akash\acme.toml", true)]
    [InlineData("c:/Users/akash/acme.TOML", true)]
    [InlineData(@"\\wsl.localhost\Ubuntu\home\a\acme.toml", true)]
    [InlineData("/home/akash/acme.toml", true)]
    [InlineData("/home/akash/acme.txt", false)]
    [InlineData("acme.toml", false)]
    [InlineData("~/acme.toml", false)]
    public void AFileMayBeAWindowsOrALinuxTomlPath(string text, bool valid) => Assert.Equal(valid, ProfileSourceRule.IsLocalFile(text));

    [Theory]
    [InlineData("git@github.com:acme/benchbar-profiles.git", true)]
    [InlineData("https://github.com/acme/profiles.git", true)]
    [InlineData("ssh://git@host/acme/profiles", true)]
    [InlineData("file:///etc/passwd", false)]
    [InlineData("ext::sh -c id", false)]
    [InlineData("/home/a/repo", false)]
    [InlineData("--upload-pack=x", false)]
    [InlineData("git@github.com:/abs", false)]
    [InlineData("https://github.com", false)]
    [InlineData("", false)]
    public void OnlyRemoteGitUrlsCanBeSubscribed(string text, bool valid) => Assert.Equal(valid, ProfileSourceRule.IsGitUrl(text));

    [Fact]
    public void TheExpectFlagIsPassedOnlyForARealDigest()
    {
        Assert.Equal(["--expect", Digest], ProfileRun.ExpectArgs(Digest));
        Assert.Empty(ProfileRun.ExpectArgs(null));
        Assert.Empty(ProfileRun.ExpectArgs("abc"));
        Assert.Empty(ProfileRun.ExpectArgs(new string('z', 64)));
    }

    // --- documents ---

    [Fact]
    public void TheExportPlanGivesAppsBranchesAccessAndADigest()
    {
        var plan = ProfileExportPlan.Parse(Doc("profile-export-plan.json"));
        Assert.Equal("acme", plan.Name);
        Assert.Equal(Digest, plan.Digest);
        Assert.Equal(2, plan.Apps.Count);
        var ecr = plan.Apps[1];
        Assert.Equal("git@github.com:acme/acme_ecr.git", ecr.ExportedRepo);
        Assert.Equal("wip", ecr.CurrentBranch);
        Assert.Equal("develop", ecr.ExportedBranch);
        Assert.True(ecr.BranchVerified);
        Assert.Equal(["acme_base"], ecr.Requires);
        Assert.Equal("private", RepoAccess.Label(ecr.Access));
        Assert.Equal("personal account", RepoAccess.Label("personal"));
        Assert.Equal("unknown", RepoAccess.Label(null));
        Assert.Single(plan.Warnings);
        Assert.Throws<FormatException>(() => ProfileExportPlan.Parse(new JsonObject()));
    }

    [Fact]
    public void ExportChoicesPassEveryKeptBranchAndEveryDroppedApp()
    {
        var plan = ProfileExportPlan.Parse(Doc("profile-export-plan.json"));
        var choices = new ProfileExportChoices(plan);
        Assert.Null(choices.Problem(plan));
        Assert.Equal(["--branch", "acme_base=main", "--branch", "acme_ecr=develop"], choices.Arguments(plan));

        choices.SetBranch("acme_ecr", " release ");
        Assert.Equal(["--branch", "acme_base=main", "--branch", "acme_ecr=release"], choices.Arguments(plan));

        choices.SetKeep("acme_ecr", false);
        Assert.Equal(["--branch", "acme_base=main", "--drop", "acme_ecr"], choices.Arguments(plan));
        Assert.Null(choices.Problem(plan));
    }

    [Fact]
    public void ExportChoicesRefuseWhatTheCliWouldRefuse()
    {
        var plan = ProfileExportPlan.Parse(Doc("profile-export-plan.json"));
        var choices = new ProfileExportChoices(plan);
        choices.SetKeep("acme_base", false);
        Assert.Equal("acme_base is required by acme_ecr: keep it, or drop those too.", choices.Problem(plan));
        choices.SetKeep("acme_ecr", false);
        Assert.Equal("Keep at least one app.", choices.Problem(plan));
        choices.SetKeep("acme_base", true);
        choices.SetBranch("acme_base", "bad branch");
        Assert.Equal("acme_base needs a branch name.", choices.Problem(plan));
        Assert.False(ProfileExportChoices.IsBranch("-x"));
        Assert.False(ProfileExportChoices.IsBranch("a..b"));
        Assert.False(ProfileExportChoices.IsBranch("a=b"));
        Assert.True(ProfileExportChoices.IsBranch("feature/x"));
    }

    [Fact]
    public void TheImportPlanGivesTheChecksTheSkippedAppsAndADigest()
    {
        var plan = ProfileImportPlan.Parse(Doc("profile-import-plan.json"));
        Assert.Equal("acme", plan.Name);
        Assert.True(plan.Exists);
        Assert.Contains("+description", plan.Diff);
        Assert.Equal("v15-lts", plan.Base);
        Assert.Equal(["acme_ecr"], plan.SkippedApps);
        var check = plan.CheckFor("acme_ecr")!;
        Assert.False(check.Reachable);
        Assert.Equal("✗", check.Mark);
        Assert.Equal("not reachable", check.Accessibility);
        Assert.Null(plan.CheckFor("nope"));
        Assert.Equal("c2a1f0c2a1f0c2a1f0c2a1f0c2a1f0c2a1f0c2a1f0c2a1f0c2a1f0c2a1f0c2a1", plan.Digest);
        Assert.Equal("?", new ProfileRepoCheck("a", "r", null, null).Mark);
        Assert.Equal("✓", new ProfileRepoCheck("a", "r", true, null).Mark);
    }

    [Fact]
    public void TheCheckSaysEveryRepositoryIsReachableOrHowManyAreNot()
    {
        var ok = ProfileCheck.Parse(Doc("profile-check-ok.json")).Verdict();
        Assert.False(ok.Warning);
        Assert.Equal("This machine can reach every repository", ok.Title);

        var check = ProfileCheck.Parse(Doc("profile-check.json"));
        Assert.Equal(3, check.Repos.Count);
        Assert.Null(check.Repos[2].Reachable);
        var verdict = check.Verdict();
        Assert.True(verdict.Warning);
        Assert.Equal("2 repositories are not reachable", verdict.Title);
        Assert.Contains("would skip: acme_ecr", verdict.Detail);
        Assert.Equal("1 repository is not reachable", new ProfileCheck("x", [new("a", "r", false, null)], []).Verdict().Title);
        Assert.Equal("Some apps would be left out", new ProfileCheck("x", [new("a", "r", true, null)], ["b"]).Verdict().Title);
        Assert.Throws<FormatException>(() => ProfileCheck.Parse(new JsonObject()));
    }

    [Fact]
    public void TheUpdateSubscribeAndRemoveDocumentsParse()
    {
        var plan = ProfileUpdatePlan.Parse(Doc("profile-update-plan.json"));
        Assert.True(plan.HasChanges);
        Assert.Equal(2, plan.Updates[0].Behind);
        Assert.Null(plan.Applied);
        Assert.False(ProfileUpdatePlan.Parse(Doc("profile-update-none.json")).HasChanges);
        Assert.True(ProfileUpdatePlan.Parse(Doc("profile-update-applied.json")).Applied);
        var subscribed = ProfileSubscribeResult.Parse(Doc("profile-subscribe.json"));
        Assert.Equal(["acme", "acme-lite"], subscribed.Profiles);
        var removed = ProfileRemoveResult.Parse(Doc("profile-remove.json"));
        Assert.Equal("mine", removed.Name);
        Assert.EndsWith("mine.toml", removed.MovedTo);
        Assert.Equal("/home/akash/.config/benchbar/profiles/acme.toml", ProfileImportResult.Parse(Doc("profile-import-result.json")).Path);
        var export = ProfileExportResult.Parse(Doc("profile-export-result.json"));
        Assert.Equal(2, export.Apps);
        Assert.Empty(export.Dropped);
    }

    // --- the page model ---

    [Fact]
    public async Task ThePageReadsTheProfilesAndTheBenchesForCreate()
    {
        var (client, runner) = Cli();
        runner.On("profile", "list").Print(CliFixture.Lines("profile-list.json"));
        runner.On("list").Print(CliFixture.Lines("scan-list.json"));
        var model = new ProfilesModel(client);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(["profile", "list", "--json"], runner.Runs[0].Args);
        Assert.Equal(["list", "--json"], runner.Runs[1].Args);
        Assert.Equal(6, model.Profiles.Count);
        Assert.Equal(2, model.Benches.Count);
        Assert.True(model.HasLoaded);
        Assert.True(model.HasTeamProfile);
        Assert.Null(model.Error);
    }

    [Fact]
    public async Task OnlyBuiltInProfilesIsAnEmptyStateNotAnError()
    {
        var (client, runner) = Cli();
        runner.On("profile", "list").Print(CliFixture.Lines("profile-list-builtin-only.json"));
        var model = new ProfilesModel(client);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Single(model.Profiles);
        Assert.False(model.HasTeamProfile);
        Assert.Empty(model.Benches); // list failed: Create from Bench stays off
        Assert.Null(model.Error);
    }

    [Fact]
    public async Task AListThatFailsIsSaidInTheCliWords()
    {
        var (client, runner) = Cli();
        runner.On("profile", "list").Fail(1, "profile: broken config");
        var model = new ProfilesModel(client);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Contains("broken config", model.Error);
        Assert.Empty(model.Profiles);
        Assert.False(model.IsLoading);
    }

    [Fact]
    public async Task CreateFromBenchRunsProfileCreateWithYesThenReadsTheListAgain()
    {
        var (client, runner) = Cli();
        runner.On("profile", "create").Print("wrote /home/akash/.config/benchbar/profiles/acme.toml");
        runner.On("profile", "list").Print(CliFixture.Lines("profile-list.json"));
        runner.On("list").Print(CliFixture.Lines("scan-list.json"));
        var model = new ProfilesModel(client);
        Assert.True(await model.CreateAsync("acme", "/home/akash/projects/managed-bench", TestContext.Current.CancellationToken));
        Assert.Equal(["profile", "create", "acme", "--from-bench", "/home/akash/projects/managed-bench", "--yes"], runner.Runs[0].Args);
        Assert.Equal(["profile", "list", "--json"], runner.Runs[1].Args);
        Assert.Contains("Created acme", model.Message);
        Assert.Equal(6, model.Profiles.Count);
        Assert.Equal(["profile", "create", "acme", "--from-bench", "/b", "--yes"], ProfilesModel.CreateArgs("acme", "/b"));
    }

    [Fact]
    public async Task CreateWithABadNameOrAFailureSaysSo()
    {
        var (client, runner) = Cli();
        runner.On("profile", "create").Fail(1, "acme is a built in profile; a team profile may not shadow it.");
        var model = new ProfilesModel(client);
        Assert.False(await model.CreateAsync("Bad Name", "/b", TestContext.Current.CancellationToken));
        Assert.Empty(runner.Runs);
        Assert.False(await model.CreateAsync("acme", "/b", TestContext.Current.CancellationToken));
        Assert.Contains("may not shadow it", model.ActionError);
        Assert.Null(model.Message);
    }

    [Fact]
    public async Task RemoveRunsProfileRemoveWithYesAndSaysWhereTheFileWent()
    {
        var (client, runner) = Cli();
        runner.On("profile", "remove").Print(CliFixture.Lines("profile-remove.json"));
        runner.On("profile", "list").Print(CliFixture.Lines("profile-list.json"));
        var model = new ProfilesModel(client);
        var mine = ProfileListJson.Parse(Doc("profile-list.json"))[3];
        Assert.True(await model.RemoveAsync(mine, TestContext.Current.CancellationToken));
        Assert.Equal(["profile", "remove", "mine", "--yes", "--json"], runner.Runs[0].Args);
        Assert.Contains("moved to /home/akash/.config/benchbar/removed", model.Message);

        var (failing, failRunner) = Cli();
        failRunner.On("profile", "remove").Fail(1, "profile remove: acme is not an import or a subscription");
        var other = new ProfilesModel(failing);
        Assert.False(await other.RemoveAsync(mine, TestContext.Current.CancellationToken));
        Assert.Contains("not an import", other.ActionError);
    }

    [Fact]
    public async Task TheRemoveQuestionNamesTheWholeSubscription()
    {
        var (client, runner) = Cli();
        runner.On("profile", "list").Print(CliFixture.Lines("profile-list.json"));
        var model = new ProfilesModel(client);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        var acme = model.Profiles[1];
        Assert.Equal("Remove the subscription?", ProfilesModel.RemoveTitle(acme));
        Assert.Contains("subscription to acme/bench-config with all its profiles (acme, acme-lite)", model.RemoveMessage(acme));
        var mine = model.Profiles[3];
        Assert.Equal("Remove mine?", ProfilesModel.RemoveTitle(mine));
        Assert.StartsWith("The file is moved to ~/.config/benchbar/removed, not deleted.", model.RemoveMessage(mine));
        Assert.Equal("Remove profile?", ProfilesModel.RemoveTitle(null));
    }

    // --- import ---

    [Fact]
    public async Task ImportConvertsAWindowsFileThenPlansThenAddsWithTheDigest()
    {
        var (client, runner) = Cli();
        runner.On("profile", "import", LinuxToml, "--plan").Print(CliFixture.Lines("profile-import-plan.json"));
        runner.On("profile", "import", LinuxToml, "--expect").Print(CliFixture.Lines("profile-import-result.json"));
        var wsl = Wsl();
        var run = new ProfileImportRun(client, wsl, "  " + WindowsToml + " ");
        Assert.True(run.CanReview);
        Assert.False(run.CanAdd);
        await run.ReviewAsync(TestContext.Current.CancellationToken);
        Assert.Equal([WindowsToml], wsl.Converted);
        Assert.Equal(["profile", "import", LinuxToml, "--plan", "--json"], runner.Runs[0].Args);
        Assert.Equal(ProfileRunPhase.Ready, run.Phase);
        Assert.True(run.CanAdd);

        await run.AddAsync(TestContext.Current.CancellationToken);
        Assert.Equal(["profile", "import", LinuxToml, "--expect", "c2a1f0c2a1f0c2a1f0c2a1f0c2a1f0c2a1f0c2a1f0c2a1f0c2a1f0c2a1f0c2a1", "--yes", "--json"], runner.Runs[1].Args);
        Assert.Equal(ProfileRunPhase.Done, run.Phase);
        Assert.Equal("acme", run.Result!.Name);
    }

    [Fact]
    public async Task ImportKeepsAUrlAsItIsAndPassesSaveAs()
    {
        var (client, runner) = Cli();
        runner.On("profile", "import").Print(CliFixture.Lines("profile-import-plan.json"));
        var wsl = Wsl();
        var run = new ProfileImportRun(client, wsl, "https://github.com/acme/profiles/blob/main/acme.toml") { SaveAs = " team-acme " };
        await run.ReviewAsync(TestContext.Current.CancellationToken);
        Assert.Empty(wsl.Converted);
        Assert.Equal(["profile", "import", "https://github.com/acme/profiles/blob/main/acme.toml", "--as", "team-acme", "--plan", "--json"], runner.Runs[0].Args);
        Assert.Equal(["profile", "import", "/home/a/x.toml", "--yes", "--json"], ProfileImportRun.AddArgs("/home/a/x.toml", null, null));
    }

    [Fact]
    public async Task ChangingTheFieldsAfterTheReviewTurnsAddOffUntilItIsReviewedAgain()
    {
        var (client, runner) = Cli();
        runner.On("profile", "import").Print(CliFixture.Lines("profile-import-plan.json"));
        var run = new ProfileImportRun(client, Wsl(), WindowsToml);
        await run.ReviewAsync(TestContext.Current.CancellationToken);
        Assert.True(run.CanAdd);
        run.SaveAs = "other";
        Assert.False(run.CanAdd);
        run.SaveAs = "";
        Assert.True(run.CanAdd);
        run.Source = "https://example.com/x.toml";
        Assert.False(run.CanAdd);
    }

    [Fact]
    public async Task ImportRefusesWhatIsNotAFileOrAnHttpsLinkAndAnUnconvertedPath()
    {
        var (client, runner) = Cli();
        var run = new ProfileImportRun(client, Wsl(), "acme.toml");
        Assert.False(run.SourceValid);
        Assert.False(run.CanReview);
        await run.ReviewAsync(TestContext.Current.CancellationToken);
        Assert.Empty(runner.Runs);

        var bad = new ProfileImportRun(client, Wsl(), @"D:\unknown.toml");
        await bad.ReviewAsync(TestContext.Current.CancellationToken);
        Assert.Equal(ProfileRunPhase.Failed, bad.Phase);
        Assert.Equal("wslpath failed", bad.Error);
        Assert.Empty(runner.Runs);
        Assert.False(new ProfileImportRun(client, Wsl(), "https://x.example/a.toml") { SaveAs = "Bad Name" }.CanReview);
    }

    [Fact]
    public async Task ImportShowsTheCliSentenceWhenTheReviewFails()
    {
        var (client, runner) = Cli();
        runner.On("profile", "import").Fail(1, "profile import: the file is larger than 64 KB");
        var run = new ProfileImportRun(client, Wsl(), WindowsToml);
        await run.ReviewAsync(TestContext.Current.CancellationToken);
        Assert.Equal(ProfileRunPhase.Failed, run.Phase);
        Assert.Contains("larger than 64 KB", run.Error);
        Assert.False(run.CanAdd);
    }

    // --- export ---

    [Fact]
    public async Task ExportPlansThenWritesToAConvertedWindowsPathWithEveryBranchAndTheDigest()
    {
        var (client, runner) = Cli();
        runner.On("profile", "export", "acme", "--plan").Print(CliFixture.Lines("profile-export-plan.json"));
        runner.On("profile", "export", "acme", "--out").Print(CliFixture.Lines("profile-export-result.json"));
        var run = new ProfileExportRun(client, Wsl(), "acme");
        await run.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(["profile", "export", "acme", "--plan", "--json"], runner.Runs[0].Args);
        Assert.True(run.CanExport);

        run.Choices!.SetBranch("acme_ecr", "release");
        await run.ExportAsync(@"C:\Users\akash\Desktop\acme.toml", TestContext.Current.CancellationToken);
        Assert.Equal(["profile", "export", "acme", "--out", "/mnt/c/Users/akash/Desktop/acme.toml", "--branch", "acme_base=main", "--branch", "acme_ecr=release",
            "--expect", Digest, "--yes", "--json"], runner.Runs[1].Args);
        Assert.Equal(ProfileRunPhase.Done, run.Phase);
        Assert.Equal(2, run.Result!.Apps);
        Assert.Equal(@"C:\Users\akash\Desktop\acme.toml", run.ChosenFile);
    }

    [Fact]
    public async Task ARefusedExportGoesBackToTheChoicesWithTheCliSentence()
    {
        var (client, runner) = Cli();
        runner.On("profile", "export", "acme", "--plan").Print(CliFixture.Lines("profile-export-plan.json"));
        runner.On("profile", "export", "acme", "--out").Print(CliFixture.Lines("profile-export-refusal.json")).Fail(1);
        var run = new ProfileExportRun(client, Wsl(), "acme");
        await run.LoadAsync(TestContext.Current.CancellationToken);
        await run.ExportAsync(@"C:\Users\akash\Desktop\acme.toml", TestContext.Current.CancellationToken);
        Assert.Equal(ProfileRunPhase.Ready, run.Phase);
        Assert.Equal("acme_base is required by acme_ecr: keep it, or drop acme_ecr too.", run.Error);
        Assert.Null(run.Result);
    }

    [Fact]
    public async Task AnExportWithAnApplessChoiceOrAFailedPlanCannotRun()
    {
        var (client, runner) = Cli();
        runner.On("profile", "export", "acme", "--plan").Print(CliFixture.Lines("profile-export-plan.json"));
        var run = new ProfileExportRun(client, Wsl(), "acme");
        await run.LoadAsync(TestContext.Current.CancellationToken);
        run.Choices!.SetKeep("acme_base", false);
        run.Choices.SetKeep("acme_ecr", false);
        Assert.False(run.CanExport);
        Assert.Equal("Keep at least one app.", run.Problem);
        await run.ExportAsync("/home/akash/x.toml", TestContext.Current.CancellationToken);
        Assert.Single(runner.Runs);

        var (failing, failRunner) = Cli();
        failRunner.On("profile", "export").Fail(1, "profile export: acme is not a team profile");
        var broken = new ProfileExportRun(failing, Wsl(), "acme");
        await broken.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(ProfileRunPhase.Failed, broken.Phase);
        Assert.Contains("not a team profile", broken.Error);
    }

    [Fact]
    public void ExportArgumentsHaveTheCliOrder() =>
        Assert.Equal(["profile", "export", "n", "--out", "/f.toml", "--drop", "x", "--yes", "--json"], ProfileExportRun.ExportArgs("n", "/f.toml", ["--drop", "x"], null));

    // --- update, check, subscribe ---

    [Fact]
    public async Task UpdatePlansThenAppliesTheReviewedDigest()
    {
        var (client, runner) = Cli();
        runner.On("profile", "update", "acme", "--plan").Print(CliFixture.Lines("profile-update-plan.json"));
        runner.On("profile", "update", "acme", "--expect").Print(CliFixture.Lines("profile-update-applied.json"));
        var run = new ProfileUpdateRun(client, Wsl(), "acme");
        await run.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(["profile", "update", "acme", "--plan", "--json"], runner.Runs[0].Args);
        Assert.True(run.CanApply);
        await run.ApplyAsync(TestContext.Current.CancellationToken);
        Assert.Equal(["profile", "update", "acme", "--expect", "77e3b977e3b977e3b977e3b977e3b977e3b977e3b977e3b977e3b977e3b977e3", "--yes", "--json"], runner.Runs[1].Args);
        Assert.Equal(ProfileRunPhase.Done, run.Phase);
    }

    [Fact]
    public async Task AnUpToDateProfileHasNothingToApplyAndAnUnappliedUpdateFails()
    {
        var (client, runner) = Cli();
        runner.On("profile", "update").Print(CliFixture.Lines("profile-update-none.json"));
        var run = new ProfileUpdateRun(client, Wsl(), "acme");
        await run.LoadAsync(TestContext.Current.CancellationToken);
        Assert.False(run.CanApply);
        await run.ApplyAsync(TestContext.Current.CancellationToken);
        Assert.Single(runner.Runs);

        var (second, secondRunner) = Cli();
        var reply = secondRunner.On("profile", "update");
        reply.Print(CliFixture.Lines("profile-update-plan.json"));
        var again = new ProfileUpdateRun(second, Wsl(), "acme");
        await again.LoadAsync(TestContext.Current.CancellationToken);
        reply.Lines.Clear();
        reply.Print(string.Join("", CliFixture.Lines("profile-update-applied.json")).Replace("\"applied\":true", "\"applied\":false"));
        await again.ApplyAsync(TestContext.Current.CancellationToken);
        Assert.Equal(ProfileRunPhase.Failed, again.Phase);
        Assert.Contains("could not be updated", again.Error);
    }

    [Fact]
    public async Task CheckAccessRunsProfileCheckAndCanRunAgain()
    {
        var (client, runner) = Cli();
        runner.On("profile", "check").Print(CliFixture.Lines("profile-check.json"));
        var run = new ProfileCheckRun(client, Wsl(), "acme");
        await run.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(["profile", "check", "acme", "--json"], runner.Runs[0].Args);
        Assert.Equal(ProfileRunPhase.Done, run.Phase);
        Assert.Equal(3, run.Check!.Repos.Count);
        await run.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(2, runner.Runs.Count);
    }

    [Fact]
    public async Task SubscribeRunsProfileSubscribeWithYesOnlyForARemoteGitUrl()
    {
        var (client, runner) = Cli();
        runner.On("profile", "subscribe").Print(CliFixture.Lines("profile-subscribe.json"));
        var bad = new ProfileSubscribeRun(client, Wsl(), "file:///etc");
        Assert.False(bad.CanSubscribe);
        await bad.SubscribeAsync(TestContext.Current.CancellationToken);
        Assert.Empty(runner.Runs);

        var run = new ProfileSubscribeRun(client, Wsl(), "  git@github.com:acme/bench-config.git ");
        Assert.True(run.CanSubscribe);
        await run.SubscribeAsync(TestContext.Current.CancellationToken);
        Assert.Equal(["profile", "subscribe", "git@github.com:acme/bench-config.git", "--yes", "--json"], runner.Runs[0].Args);
        Assert.Equal(ProfileRunPhase.Done, run.Phase);
        Assert.Equal(["acme", "acme-lite"], run.Result!.Profiles);
        Assert.False(run.CanSubscribe);
    }

    [Fact]
    public async Task AFailedSubscribeKeepsTheFormAndTheCliSentence()
    {
        var (client, runner) = Cli();
        runner.On("profile", "subscribe").Fail(1, "profile subscribe: git clone failed (Permission denied)");
        var run = new ProfileSubscribeRun(client, Wsl(), "git@github.com:acme/private.git");
        await run.SubscribeAsync(TestContext.Current.CancellationToken);
        Assert.Equal(ProfileRunPhase.Failed, run.Phase);
        Assert.Contains("Permission denied", run.Error);
        Assert.True(run.CanSubscribe); // the address can be fixed and tried again
    }
}
