using BenchBar.Tray.Core;
using Xunit;
using static Tray.Core.Tests.CliFixture;

namespace Tray.Core.Tests;

/// <summary>Open as: what status says per site, when the controls show and why they do not, the exact calls, and that no link or session id is ever asked for.</summary>
public class OpenAsTests
{
    private const string Bench = "/home/akash/frappe-bench";

    private static SiteRowInfo Row(string name = "one.localhost", bool isDefault = true, SiteOpenAs? openAs = null, bool needsSetUp = false) =>
        new(name, isDefault, "http://" + name + ":8000", !needsSetUp, needsSetUp, openAs);

    private static readonly SiteOpenAs Ready = new(true, true, true);

    // --- what status says ---

    [Fact]
    public void StatusCarriesTheOptInTheDeveloperModeAndTheVerdictPerSiteAndAnOlderCliCarriesNone()
    {
        var status = BenchJson.ParseStatus("""{"bench":"/b","name":"b","state":"running","sites":[{"name":"a.localhost","default":true,"open_as_enabled":true,"developer_mode":true,"open_as":false},{"name":"b.localhost","default":false}]}""");
        Assert.Equal(new SiteOpenAs(true, true, false), status.Sites[0].OpenAs);
        Assert.Null(status.Sites[1].OpenAs);
        Assert.Equal(new SiteOpenAs(false, false, false), BenchJson.ParseStatus(File.ReadAllText(Path.Combine(Fixtures.Dir("recorded"), "status.json"))).Sites.Single().OpenAs);
    }

    // --- when the controls show ---

    [Fact]
    public void OpenAsIsHiddenUntilThePersonTurnedItOnAndForANameWindowsCannotFind()
    {
        Assert.Equal(OpenAsRules.Availability.Hidden, OpenAsRules.For(Row(openAs: new(false, true, false)), true, "b").State);
        Assert.Equal(OpenAsRules.Availability.Hidden, OpenAsRules.For(Row(openAs: null), true, "b").State); // an older CLI
        Assert.Equal(OpenAsRules.Availability.Hidden, OpenAsRules.For(Row("mysite", openAs: Ready, needsSetUp: true), true, "b").State);
        Assert.Equal(OpenAsRules.Availability.Available, OpenAsRules.For(Row(openAs: Ready), true, "b").State);
    }

    [Fact]
    public void ABenchThatIsStoppedShowsItDisabledWithTheReason()
    {
        var (state, why) = OpenAsRules.For(Row(openAs: Ready), false, "frappe-bench");
        Assert.Equal((OpenAsRules.Availability.Disabled, "Start frappe-bench first"), (state, why));
    }

    [Fact]
    public void AnOptedInSiteThatCannotBeUsedSaysWhyOnlyOnTheDefaultSite()
    {
        var noDev = Row(openAs: new(true, false, false));
        Assert.Equal(["one.localhost is not in developer mode. Run: bench --site one.localhost set-config developer_mode 1"], OpenAsRules.Reasons(noDev));
        Assert.Equal(OpenAsRules.Availability.Disabled, OpenAsRules.For(noDev, true, "b").State);
        var other = Row("two.localhost", false, new(true, true, false));
        Assert.Equal(["Only the default site can be used: port 8000 serves only it"], OpenAsRules.Reasons(other));
        Assert.Equal(OpenAsRules.Availability.Hidden, OpenAsRules.For(other, true, "b").State); // only the default site can be explained
        var served = Row(openAs: new(true, true, false));
        Assert.Equal(["The web process answers as another site. Run: benchbar site default one.localhost, then benchrestart"], OpenAsRules.Reasons(served));
        Assert.Equal(["Update the benchbar command line tool to use Open as"], OpenAsRules.Reasons(Row(openAs: new(true, null, false))));
    }

    [Fact]
    public void TheLineUnderASiteSaysReadyWhenOnAndWhyNotWhenItCannotBeUsed()
    {
        Assert.Null(OpenAsRules.StatusLine(Row(openAs: new(false, true, false))));
        Assert.Equal(("Open as is on", false), OpenAsRules.StatusLine(Row(openAs: Ready)));
        var broken = OpenAsRules.StatusLine(Row(openAs: new(true, false, false))).GetValueOrDefault();
        Assert.True(broken.Warning);
        Assert.StartsWith("Open as is on, but not usable. one.localhost is not in developer mode.", broken.Text);
    }

    [Fact]
    public void TheSiteMenuOffersTheOptInWhereTheCliReportsItAndOpenAsOnlyWhenItIsOn()
    {
        string[] Labels(SiteRowInfo row) => [.. SiteMenu.For(row, false, OpenAsRules.For(row, true, "b").State).Select(i => i.Label)];
        Assert.DoesNotContain("Open as...", Labels(Row(openAs: new(false, true, false))));
        Assert.Contains("Allow Open as...", Labels(Row(openAs: new(false, true, false))));
        Assert.Equal(["Open as...", "Turn Off Open as"], Labels(Row(openAs: Ready)).Where(l => l.Contains("Open as")));
        Assert.DoesNotContain(Labels(Row(openAs: null)), l => l.Contains("Open as")); // an older CLI
        Assert.DoesNotContain(Labels(Row("mysite", openAs: Ready, needsSetUp: true)), l => l.Contains("Open as")); // Windows cannot find the name
        var disabled = SiteMenu.For(Row(openAs: new(true, false, false)), false, OpenAsRules.Availability.Disabled).Single(i => i.Action == SiteAction.OpenAs);
        Assert.False(disabled.Enabled);
    }

    // --- the calls ---

    [Fact]
    public void TheCallsAreExactAndNoneAsksForTheSignInLink()
    {
        Assert.Equal(["site", "open-as", "on", "one.localhost", "--yes", "--json", "--bench-dir", Bench], OpenAsCommands.Set("one.localhost", true, Bench));
        Assert.Equal(["site", "open-as", "off", "one.localhost", "--yes", "--json", "--bench-dir", Bench], OpenAsCommands.Set("one.localhost", false, Bench));
        Assert.Equal(["users", "--site", "one.localhost", "--limit", "50", "--json", "--bench-dir", Bench], OpenAsCommands.Users("one.localhost", " ", Bench));
        Assert.Equal(["users", "--site", "one.localhost", "--search", "priya", "--limit", "50", "--json", "--bench-dir", Bench], OpenAsCommands.Users("one.localhost", " priya ", Bench));
        var open = OpenAsCommands.OpenAs("one.localhost", "priya@example.com", Bench);
        Assert.Equal(["open", "--site", "one.localhost", "--as", "priya@example.com", "--json", "--bench-dir", Bench], open);
        Assert.DoesNotContain("--print-url", open);
        var env = OpenAsCommands.PersonEnvironment().Materialize();
        Assert.Equal("0", env["BENCHBAR_NONINTERACTIVE"]);
    }

    // --- Find User ---

    [Fact]
    public void TheUsersAreReadWithTheirRolesAndTheTruncationFlag()
    {
        var list = OpenAsJson.ParseUsers(Doc("users.json"));
        Assert.Equal(["Administrator", "priya@example.com", "web@example.com"], list.Users.Select(u => u.Name));
        Assert.True(list.Truncated);
        Assert.Equal("Network Executive, Sales User, Accounts User, Stock User, Item Manager +2 more", list.Users[1].RolesLine);
        Assert.Equal("", list.Users[2].RolesLine);
        Assert.Throws<FormatException>(() => OpenAsJson.ParseUsers([]));
    }

    [Fact]
    public async Task SearchReadsTheUsersAsAPersonAndAFailureShowsTheCliSentence()
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var (client, runner) = Scripted();
        runner.On("users").Print(Lines("users.json"));
        var find = new FindUserModel(client, Bench, "one.localhost");
        await find.SearchAsync("pri", TestContext.Current.CancellationToken);
        Assert.Equal(3, find.List!.Users.Count);
        var run = runner.Runs.Single();
        Assert.Equal(["users", "--site", "one.localhost", "--search", "pri", "--limit", "50", "--json", "--bench-dir", Bench], run.Args);
        Assert.Equal("0", run.Env["BENCHBAR_NONINTERACTIVE"]);

        var (client2, runner2) = Scripted();
        runner2.On("users").Print(Lines("open-as-refused.jsonl")).Fail(1);
        var failed = new FindUserModel(client2, Bench, "one.localhost");
        await failed.SearchAsync(null, TestContext.Current.CancellationToken);
        Assert.Null(failed.List);
        Assert.Equal("one.localhost is not in developer mode, so benchbar will not sign in as another user.", failed.Error);
    }

    [Fact]
    public async Task OpeningAsAUserIsOneCallThatTheCliAnswersWithoutALink()
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var (client, runner) = Scripted();
        runner.On("open").Print(Lines("open-as-opened.json"));
        var find = new FindUserModel(client, Bench, "one.localhost");
        var user = OpenAsJson.ParseUsers(Doc("users.json")).Users[1];
        Assert.True(await find.OpenAsync(user, TestContext.Current.CancellationToken));
        Assert.Equal("one.localhost opened in your browser as Priya N.", find.Note);
        Assert.False(find.NoteIsError);
        Assert.DoesNotContain("--print-url", runner.Runs.Single().Args);
    }

    [Fact]
    public async Task ARefusedOpenShowsTheCliSentenceAndIsNotSuccess()
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var (client, runner) = Scripted();
        runner.On("open").Print(Lines("open-as-refused.jsonl")).Fail(1);
        var find = new FindUserModel(client, Bench, "one.localhost");
        Assert.False(await find.OpenAsync(OpenAsJson.ParseUsers(Doc("users.json")).Users[0], TestContext.Current.CancellationToken));
        Assert.True(find.NoteIsError);
        Assert.Contains("not in developer mode", find.Note);
    }

    [Fact]
    public async Task AnAnswerWithoutOpenedTrueIsNotSuccess()
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var (client, runner) = Scripted();
        runner.On("open").Print("""{"schema_version":1,"site":"one.localhost","opened":false}""");
        var find = new FindUserModel(client, Bench, "one.localhost");
        Assert.False(await find.OpenAsync(OpenAsJson.ParseUsers(Doc("users.json")).Users[0], TestContext.Current.CancellationToken));
        Assert.True(find.NoteIsError);
    }
}
