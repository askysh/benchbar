using Microsoft.Extensions.Time.Testing;
using BenchBar.Tray.Core;
using Xunit;
using static Tray.Core.Tests.CliFixture;

namespace Tray.Core.Tests;

/// <summary>Labs: the list as the CLI prints it, the switch calls, the refusals and the texts. Nothing here starts a process.</summary>
public class LabsTests
{
    /// <summary>The first reply that matches wins, so a test that changes an answer changes the reply it got here (<c>List</c>).</summary>
    private static (LabsModel Model, ScriptedStreamRunner Runner, FakeTimeProvider Time, ScriptedReply List) Rig()
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var runner = new ScriptedStreamRunner();
        var time = new FakeTimeProvider();
        var list = runner.On("labs", "list").Print(Lines("labs-list.json"));
        return (new LabsModel(new CliClient(runner, () => @"C:\bb\benchbar.exe"), time), runner, time, list);
    }

    // --- the list ---

    [Fact]
    public void TheListGivesEachLabItsStateAndWhetherItRunsOnThisPlatform()
    {
        var labs = LabsJson.Parse(Doc("labs-list.json"), out var skipped);
        Assert.Equal(0, skipped);
        Assert.Equal(["lan-rooms", "quick-switch", "example-linux"], labs.Select(l => l.Name));
        var rooms = labs[0];
        Assert.Equal("Share with people on the same Wi-Fi", rooms.Title);
        Assert.Equal("0.8.2", rooms.Since);
        Assert.Equal(["share", "lan-guard"], rooms.Commands);
        Assert.True(rooms.NotHere);
        Assert.False(rooms.CanToggle); // off and not here: it cannot be turned on
        Assert.Equal("Not on Windows yet. It works on macOS only.", rooms.WhyNotHere);
        Assert.Contains("firewall rule", rooms.Warning);
        var linux = labs[2];
        Assert.True(linux.Enabled && linux.CanToggle && !linux.NotHere);
        Assert.Null(linux.WhyNotHere);
    }

    [Fact]
    public void ALabThatIsOnButNotHereCanStillBeTurnedOff()
    {
        var lab = new LabEntry("x", "X", "", "", "0.9.0", true, [], ["macos"], false);
        Assert.True(lab.CanToggle);
        Assert.False((lab with { Enabled = false }).CanToggle);
    }

    [Fact]
    public void AnOlderCliWithoutPlatformsOffersEveryLabEverywhere()
    {
        var doc = Doc("labs-list.json");
        foreach (var node in doc["labs"]!.AsArray())
        {
            node!.AsObject().Remove("platforms");
            node.AsObject().Remove("available");
        }
        var labs = LabsJson.Parse(doc, out _);
        Assert.All(labs, l => Assert.True(!l.NotHere && l.CanToggle && l.Platforms is null && l.Available is null));
    }

    [Fact]
    public void AnEntryWithoutANameIsSkippedAndAMissingFieldHasADefault()
    {
        var doc = (System.Text.Json.Nodes.JsonObject)System.Text.Json.Nodes.JsonNode.Parse("""{"schema_version":1,"labs":[{"title":"No name"},{"name":"future-thing"},7]}""")!;
        var labs = LabsJson.Parse(doc, out var skipped);
        Assert.Equal(2, skipped);
        var future = Assert.Single(labs);
        Assert.Equal(("future-thing", "future-thing", "", false), (future.Name, future.Title, future.Since, future.Enabled));
        Assert.Throws<FormatException>(() => LabsJson.Parse([], out _));
    }

    [Theory]
    [InlineData("macos", "Not on Windows yet. It works on macOS only.")]
    [InlineData("macos,linux", "Not on Windows yet. It works on macOS and Linux.")]
    [InlineData("macos,linux,other", "Not on Windows yet. It works on macOS, Linux and other.")]
    [InlineData("", "Not on Windows yet.")]
    public void WhyALabIsNotHereNamesThePlatformsItDoesList(string platforms, string text) =>
        Assert.Equal(text, LabsText.NotHere(platforms.Split(',', StringSplitOptions.RemoveEmptyEntries)));

    // --- refresh ---

    [Fact]
    public async Task RefreshReadsTheListWithTheMacAppsCallAndKeepsEveryNameTheCliSends()
    {
        var (model, runner, _, _) = Rig();
        await model.RefreshAsync(ct: TestContext.Current.CancellationToken);
        Assert.Equal(["labs", "list", "--json"], runner.Runs.Single().Args);
        Assert.Equal(LabsAvailability.Available, model.Availability);
        Assert.Equal(3, model.Entries.Count);
        Assert.True(model.IsOn("example-linux"));
        Assert.False(model.IsOn("lan-rooms"));
        Assert.False(model.IsOn("never-heard-of-it"));
    }

    [Fact]
    public async Task CallsCloserThanFiveSecondsReuseTheLastAnswerAndForceAsksAgain()
    {
        var (model, runner, time, _) = Rig();
        await model.RefreshAsync(ct: TestContext.Current.CancellationToken);
        time.Advance(TimeSpan.FromSeconds(4));
        await model.RefreshAsync(ct: TestContext.Current.CancellationToken);
        Assert.Single(runner.Runs);
        time.Advance(TimeSpan.FromSeconds(2));
        await model.RefreshAsync(ct: TestContext.Current.CancellationToken);
        Assert.Equal(2, runner.Runs.Count);
        await model.RefreshAsync(force: true, TestContext.Current.CancellationToken);
        Assert.Equal(3, runner.Runs.Count);
    }

    [Fact]
    public async Task ACliWithoutLabsIsAnUnsupportedVerdictAndAMissingShimIsNotOne()
    {
        var old = new ScriptedStreamRunner();
        old.On("labs").Fail(2, "[FAIL] Unknown command: labs");
        var unsupported = new LabsModel(new CliClient(old, () => "benchbar.exe"));
        await unsupported.RefreshAsync(ct: TestContext.Current.CancellationToken);
        Assert.Equal(LabsAvailability.Unsupported, unsupported.Availability);
        Assert.Empty(unsupported.Entries);
        Assert.Null(unsupported.RefreshError);
        Assert.Equal("Update BenchBar to use Labs", LabsText.Unsupported);

        var missing = new LabsModel(new CliClient(new ScriptedStreamRunner(), () => null));
        await missing.RefreshAsync(ct: TestContext.Current.CancellationToken);
        Assert.Equal(LabsAvailability.CliMissing, missing.Availability);
        Assert.Equal(ShimBenchSource.NotFoundMessage, missing.RefreshError);
    }

    [Fact]
    public async Task ATransientFailureKeepsWhatTheLastListSaid()
    {
        var (model, _, time, list) = Rig();
        await model.RefreshAsync(ct: TestContext.Current.CancellationToken);
        // a later call fails: the list stays, with the reason above it, and it is no verdict about the CLI
        list.Lines.Clear();
        list.Fail(1, "timed out");
        time.Advance(TimeSpan.FromMinutes(1));
        await model.RefreshAsync(ct: TestContext.Current.CancellationToken);
        Assert.Equal(3, model.Entries.Count);
        Assert.Equal(LabsAvailability.Available, model.Availability);
        Assert.Contains("timed out", model.RefreshError);

        // a first call that fails leaves nothing to show and no verdict
        var failing = new ScriptedStreamRunner();
        failing.On("labs").Fail(1, "wsl.exe: the distro is not running");
        var again = new LabsModel(new CliClient(failing, () => "benchbar.exe"), time);
        await again.RefreshAsync(ct: TestContext.Current.CancellationToken);
        Assert.Equal(LabsAvailability.Unknown, again.Availability);
        Assert.Empty(again.Entries);
        Assert.Contains("the distro is not running", again.RefreshError);
    }

    [Fact]
    public async Task ANewerSchemaOfTheListIsStillReadBecauseItOnlyReads()
    {
        var (model, _, _, list) = Rig();
        var newer = Lines("labs-list.json").Select(l => l.Replace("\"schema_version\":1", "\"schema_version\":2")).ToArray();
        list.Lines.Clear();
        list.Print(newer);
        await model.RefreshAsync(ct: TestContext.Current.CancellationToken);
        Assert.Equal(3, model.Entries.Count);
        Assert.Null(model.RefreshError);
    }

    // --- turn on and off ---

    [Fact]
    public void TheCallsAreTheMacAppsCalls()
    {
        Assert.Equal(["labs", "on", "lan-rooms", "--yes", "--json"], LabsModel.SetArgs("lan-rooms", true));
        Assert.Equal(["labs", "off", "lan-rooms", "--yes", "--json"], LabsModel.SetArgs("lan-rooms", false));
    }

    [Fact]
    public async Task TurningOneOffRunsLabsOffSaysTheRunIsInteractiveAndFlipsTheEntry()
    {
        var (model, runner, _, _) = Rig();
        runner.On("labs", "off").Print("""{"schema_version":1,"cli_version":"0.9.0","exit":0,"changed":[{"kind":"lab","name":"example-linux","detail":"turned off"}],"lab":"example-linux","enabled":false}""");
        await model.RefreshAsync(ct: TestContext.Current.CancellationToken);
        Assert.True(await model.SetAsync("example-linux", false, TestContext.Current.CancellationToken));
        var call = runner.Runs.Last();
        Assert.Equal(["labs", "off", "example-linux", "--yes", "--json"], call.Args);
        // the CLI refuses `labs on` while BENCHBAR_NONINTERACTIVE is 1: the click is the person's decision, so it says 0
        Assert.Equal("0", call.Env["BENCHBAR_NONINTERACTIVE"]);
        Assert.False(model.IsOn("example-linux"));
        Assert.Null(model.ErrorOf("example-linux"));
        Assert.False(model.IsBusy("example-linux"));
    }

    [Fact]
    public async Task TheCliRefusalIsShownUnderTheRowInItsOwnWordsAndTheEntryStaysOff()
    {
        var (model, runner, _, _) = Rig();
        var on = runner.On("labs", "on").Print("""{"schema_version":1,"cli_version":"0.9.0","exit":1,"error":"lan-rooms is not available on windows yet","fix":"It lists these platforms: macos"}""").Fail(1);
        await model.RefreshAsync(ct: TestContext.Current.CancellationToken);
        Assert.False(await model.SetAsync("lan-rooms", true, TestContext.Current.CancellationToken));
        Assert.Equal("lan-rooms is not available on windows yet", model.ErrorOf("lan-rooms"));
        Assert.False(model.IsOn("lan-rooms"));
        Assert.Null(model.ErrorOf("quick-switch"));
        // the next flip of that lab clears the line
        on.Lines.Clear();
        on.Print("""{"schema_version":1,"exit":0,"lab":"lan-rooms","enabled":true}""").Fail(0);
        Assert.True(await model.SetAsync("lan-rooms", true, TestContext.Current.CancellationToken));
        Assert.Null(model.ErrorOf("lan-rooms"));
        Assert.True(model.IsOn("lan-rooms"));
    }

    [Fact]
    public async Task ARunThatPrintsNoDocumentShowsTheCliError()
    {
        var (model, runner, _, _) = Rig();
        runner.On("labs", "on").Fail(2, "turning on an experiment is a person's decision");
        await model.RefreshAsync(ct: TestContext.Current.CancellationToken);
        Assert.False(await model.SetAsync("example-linux", true, TestContext.Current.CancellationToken));
        Assert.Contains("a person's decision", model.ErrorOf("example-linux"));
    }

    [Fact]
    public async Task ASecondFlipOfTheSameLabWhileOneRunsIsIgnored()
    {
        var (model, runner, _, _) = Rig();
        var held = runner.On("labs", "off").Print().Hold();
        await model.RefreshAsync(ct: TestContext.Current.CancellationToken);
        var first = model.SetAsync("example-linux", false, TestContext.Current.CancellationToken);
        await held.Started.Task;
        Assert.True(model.IsBusy("example-linux"));
        Assert.False(await model.SetAsync("example-linux", false, TestContext.Current.CancellationToken));
        held.Release("""{"schema_version":1,"exit":0,"lab":"example-linux","enabled":false}""");
        Assert.True(await first);
        Assert.Single(runner.Runs, r => r.Args[1] == "off");
    }

    [Fact]
    public void TheListAndTheFlipsAreNotMistakenForOtherCommandsByTheSchemaRule()
    {
        // labs list is a read (a newer schema is shown); on and off change things (a newer schema is refused)
        Assert.True(CliSchema.IsReadOnly(LabsModel.ListArgs()));
        Assert.False(CliSchema.IsReadOnly(LabsModel.SetArgs("x", true)));
        Assert.False(CliSchema.IsReadOnly(LabsModel.SetArgs("x", false)));
    }

    [Fact]
    public async Task TheDemoModeAnswersTheListAndRefusesAFlip()
    {
        Assert.True(File.Exists(Path.Combine(BenchBar.Tray.TestSupport.FixtureFiles.Dir("cli"), "labs-list.json")));
        var demo = new FixtureCliRunner(BenchBar.Tray.TestSupport.FixtureFiles.Dir("recorded"));
        var lines = new List<string>();
        var list = await demo.RunAsync("benchbar.exe", LabsModel.ListArgs(), null, lines.Add, TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        Assert.Equal(0, list.ExitCode);
        Assert.NotEmpty(lines);
        var flip = await demo.RunAsync("benchbar.exe", LabsModel.SetArgs("example-linux", false), null, lines.Add, TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        Assert.Equal(1, flip.ExitCode);
        Assert.Equal(FixtureCliRunner.Refusal, flip.Error);
    }
}
