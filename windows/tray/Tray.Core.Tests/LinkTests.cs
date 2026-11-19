using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>benchbar:// links: the router (pure parsing), the log rules, the confirm, the registration and the hand over between two copies of the tray.</summary>
public class LinkTests
{
    private const string Home = "/home/akash";

    private static readonly LinkBench Main = new(Home + "/frappe-bench", "frappe-bench", ["one.localhost", "two.localhost"]);
    private static readonly LinkBench Other = new(Home + "/work/v16-bench", "v16-bench", ["v16.localhost"]);

    private static LinkOutcome Route(string link, params LinkBench[] benches) => LinkRouter.Route(link, benches, null);

    private static LinkOutcome.Run Run(string link, params LinkBench[] benches) => Assert.IsType<LinkOutcome.Run>(Route(link, benches));

    // --- routes ---

    [Theory]
    [InlineData("benchbar://up", LinkRoute.Up)]
    [InlineData("benchbar://down", LinkRoute.Down)]
    [InlineData("benchbar://restart", LinkRoute.Restart)]
    [InlineData("benchbar://open", LinkRoute.Open)]
    [InlineData("benchbar://logs", LinkRoute.Logs)]
    [InlineData("benchbar://window", LinkRoute.Window)]
    [InlineData("benchbar://doctor", LinkRoute.Doctor)]
    [InlineData("benchbar://console", LinkRoute.Console)]
    [InlineData("benchbar://db", LinkRoute.Db)]
    [InlineData("benchbar://editor", LinkRoute.Editor)]
    [InlineData("BENCHBAR://UP", LinkRoute.Up)]
    [InlineData("benchbar:restart", LinkRoute.Restart)]
    [InlineData("benchbar:///logs/", LinkRoute.Logs)]
    public void EveryRouteOfTheMacAppIsARouteHere(string link, LinkRoute route)
    {
        var run = Run(link, Main);
        Assert.Equal(route, run.Route);
        Assert.Equal(Main.Path, run.BenchPath);
    }

    [Fact]
    public void AnOnlyBenchNeedsNoBenchQueryAndASelectedOneWinsOverSeveral()
    {
        Assert.Equal(Main.Path, Run("benchbar://up", Main).BenchPath);
        Assert.Equal(Other.Path, Assert.IsType<LinkOutcome.Run>(LinkRouter.Route("benchbar://up", [Main, Other], Other.Path)).BenchPath);
        Assert.Equal(Other.Path, Assert.IsType<LinkOutcome.Run>(LinkRouter.Route("benchbar://up", [Main, Other], Other.Path + "/")).BenchPath);
    }

    [Fact]
    public void ABenchIsPickedByNameOrByLinuxPath()
    {
        Assert.Equal(Other.Path, Run("benchbar://restart?bench=V16-Bench", Main, Other).BenchPath);
        Assert.Equal(Other.Path, Run("benchbar://restart?bench=%2Fhome%2Fakash%2Fwork%2Fv16-bench", Main, Other).BenchPath);
        Assert.Equal(Main.Path, Run("benchbar://restart?bench=~/frappe-bench", Main, Other).BenchPath);
        Assert.Equal(Main.Path, Run("benchbar://restart?bench=/home//akash/frappe-bench/", Main, Other).BenchPath);
        // ~ is the person's home in the distro, so it never reaches into a folder deeper down or another root
        Assert.IsType<LinkOutcome.Explain>(Route("benchbar://restart?bench=~/v16-bench", Main, Other));
    }

    [Fact]
    public void ASiteIsMatchedWithoutCaseAndOnlyForTheRoutesThatTakeOne()
    {
        Assert.Equal("two.localhost", Run("benchbar://open?site=TWO.localhost", Main).Site);
        Assert.Equal("one.localhost", Run("benchbar://console?site=one.localhost", Main).Site);
        Assert.Equal("one.localhost", Run("benchbar://db?site=one.localhost", Main).Site);
        Assert.Null(Run("benchbar://up?site=nope.localhost", Main).Site); // site= does not apply to up: it is not checked
        var missing = Assert.IsType<LinkOutcome.Explain>(Route("benchbar://open?site=nope.localhost", Main));
        Assert.Equal(LinkWhy.SiteNotFound, missing.Why);
        Assert.Contains("nope.localhost", missing.Message);
    }

    [Fact]
    public void AnUnclearBenchIsExplainedAndNeverGuessed()
    {
        Assert.Equal(LinkWhy.NoBench, Assert.IsType<LinkOutcome.Explain>(Route("benchbar://up")).Why);
        Assert.Equal(LinkWhy.NeedsBench, Assert.IsType<LinkOutcome.Explain>(Route("benchbar://up", Main, Other)).Why);
        Assert.Equal(LinkWhy.BenchNotFound, Assert.IsType<LinkOutcome.Explain>(Route("benchbar://up?bench=nope", Main, Other)).Why);
        var twins = Assert.IsType<LinkOutcome.Explain>(Route("benchbar://up?bench=frappe-bench", Main, Main with { Path = Home + "/b/frappe-bench" }));
        Assert.Equal(LinkWhy.BenchAmbiguous, twins.Why);
        // the window route is the one that does not need a bench
        Assert.IsType<LinkOutcome.Window>(Route("benchbar://window", Main, Other));
        Assert.IsType<LinkOutcome.Window>(Route("benchbar://window"));
    }

    // --- profile and share links ---

    [Fact]
    public void ProfileLinksOnlyFillInASheet()
    {
        var import = Assert.IsType<LinkOutcome.Profile>(Route("benchbar://profile/import?url=https%3A%2F%2Fexample.com%2Facme.toml"));
        Assert.Equal((ProfileLinkKind.Import, "https://example.com/acme.toml"), (import.Kind, import.Address));
        var subscribe = Assert.IsType<LinkOutcome.Profile>(Route("benchbar://profile/subscribe?url=git%40github.com%3Aacme%2Fprofiles.git"));
        Assert.Equal((ProfileLinkKind.Subscribe, "git@github.com:acme/profiles.git"), (subscribe.Kind, subscribe.Address));
        // no bench is needed or looked at
        Assert.IsType<LinkOutcome.Profile>(Route("benchbar://profile/import?url=https://example.com/a.toml&bench=nope", Main, Other));
    }

    [Theory]
    [InlineData("benchbar://profile/import?url=http%3A%2F%2Fexample.com%2Fa.toml", LinkWhy.ProfileNeedsHttps)]
    [InlineData("benchbar://profile/import?url=C%3A%5Cx%5Ca.toml", LinkWhy.ProfileNeedsHttps)]
    [InlineData("benchbar://profile/import", LinkWhy.ProfileNeedsHttps)]
    [InlineData("benchbar://profile/subscribe?url=file%3A%2F%2F%2Ftmp%2Frepo", LinkWhy.SubscribeNeedsGit)]
    [InlineData("benchbar://profile/subscribe?url=ext%3A%3Ash", LinkWhy.SubscribeNeedsGit)]
    [InlineData("benchbar://profile/subscribe", LinkWhy.SubscribeNeedsGit)]
    public void AProfileLinkWithoutAGoodAddressIsExplainedAndOpensNothing(string link, LinkWhy why) =>
        Assert.Equal(why, Assert.IsType<LinkOutcome.Explain>(Route(link, Main)).Why);

    [Theory]
    [InlineData("benchbar://profile")]
    [InlineData("benchbar://profile/export?url=https://example.com/a.toml")]
    [InlineData("benchbar://profile/import/extra?url=https://example.com/a.toml")]
    public void OtherProfileRoutesAreIgnored(string link) =>
        Assert.Equal(LinkIgnore.UnknownRoute, Assert.IsType<LinkOutcome.Ignore>(Route(link, Main)).Reason);

    [Theory]
    [InlineData("benchbar://share/0123456789abcdef/app")]
    [InlineData("benchbar://share/join?code=SECRET-CODE-1234")]
    [InlineData("benchbar://share")]
    public void ShareLinksSayRoomsAreNotOnWindowsYetAndNeverEchoTheLink(string link)
    {
        var note = Assert.IsType<LinkOutcome.Explain>(Route(link, Main));
        Assert.Equal(LinkWhy.ShareNotOnWindows, note.Why);
        Assert.Contains("not on Windows yet", note.Message);
        Assert.DoesNotContain("SECRET", note.Message);
        Assert.DoesNotContain("0123456789", note.Message);
    }

    // --- what is ignored ---

    [Theory]
    [InlineData("https://example.com/up", LinkIgnore.NotOurScheme)]
    [InlineData("benchbarx://up", LinkIgnore.NotOurScheme)]
    [InlineData("up", LinkIgnore.NotOurScheme)]
    [InlineData("", LinkIgnore.NotOurScheme)]
    [InlineData("benchbar://", LinkIgnore.NoRoute)]
    [InlineData("benchbar:", LinkIgnore.NoRoute)]
    [InlineData("benchbar://repair", LinkIgnore.UnknownRoute)]
    [InlineData("benchbar://drop?site=a.localhost", LinkIgnore.UnknownRoute)]
    [InlineData("benchbar://update", LinkIgnore.UnknownRoute)]
    [InlineData("benchbar://up.evil.example", LinkIgnore.UnknownRoute)]
    [InlineData("benchbar://user@up", LinkIgnore.UnknownRoute)]
    [InlineData("benchbar://up\"%20--x", LinkIgnore.UnknownRoute)]
    public void WhatIsNotARouteIsIgnoredWithAFixedSentence(string link, string reason) =>
        Assert.Equal(reason, Assert.IsType<LinkOutcome.Ignore>(Route(link, Main)).Reason);

    [Fact]
    public void ALinkWithAControlCharacterOrASpaceOrPastTheLimitIsIgnored()
    {
        foreach (var link in new[] { "benchbar://up\n", "benchbar://up?bench=a b", "benchbar://up\t?x=1", "benchbar://up\0", "benchbar://up?x=" + new string('a', LinkRouter.MaxLength) })
        {
            // a trailing newline is trimmed, as a shell may add one: only what is inside the link counts
            var outcome = Route(link, Main);
            if (link == "benchbar://up\n") Assert.IsType<LinkOutcome.Run>(outcome);
            else Assert.Equal(LinkIgnore.NotOurScheme, Assert.IsType<LinkOutcome.Ignore>(outcome).Reason);
        }
    }

    [Fact]
    public void TheStartArgumentsGiveTheFirstLinkAndNothingElse()
    {
        Assert.Equal("benchbar://up?bench=x", LinkRouter.FromArguments(["--restarted", "benchbar://up?bench=x", "benchbar://down"]));
        Assert.Equal("BENCHBAR:down", LinkRouter.FromArguments(["BENCHBAR:down"]));
        Assert.Null(LinkRouter.FromArguments(["--resume-setup", "--installed"]));
        Assert.Null(LinkRouter.FromArguments(["benchbar://up?x=" + new string('a', LinkRouter.MaxLength)]));
        Assert.Null(LinkRouter.FromArguments([]));
    }

    // --- the log ---

    [Theory]
    [InlineData("benchbar://up?bench=secret-bench", "benchbar://up")]
    [InlineData("benchbar://open?site=client-x.localhost", "benchbar://open")]
    [InlineData("benchbar://share/0123456789abcdef/app", "benchbar://share")]
    [InlineData("benchbar://share/join?code=SECRET", "benchbar://share")]
    [InlineData("benchbar://profile/import?url=https://user:token@example.com/a.toml", "benchbar://profile/import")]
    [InlineData("benchbar://profile/subscribe?url=git@github.com:acme/p.git", "benchbar://profile/subscribe")]
    public void ALinkIsLoggedByItsActionOnly(string link, string label)
    {
        Assert.Equal(label, LinkRouter.LogLabel(link));
    }

    [Fact]
    public void AnythingElseIsLoggedAsAShortHashAndNothingToReadBack()
    {
        var secret = "benchbar://repair?token=SECRET-TOKEN&bench=secret-bench";
        var label = LinkRouter.LogLabel(secret);
        Assert.Matches("^other link, hash [0-9a-f]{12}$", label);
        Assert.Equal(label, LinkRouter.LogLabel(secret));
        Assert.NotEqual(label, LinkRouter.LogLabel(secret + "x"));
        Assert.DoesNotContain("SECRET", label);
        Assert.StartsWith("other link, hash ", LinkRouter.LogLabel("https://example.com/up"));
        Assert.StartsWith("other link, hash ", LinkRouter.LogLabel("benchbar://profile/export?url=x"));
    }

    [Fact]
    public void TheMacAndTheTrayHashALinkTheSameWay()
    {
        // SHA-256 of the link as written, first six bytes in hex (macos URLRouter.logLabel)
        Assert.Equal(Hash("benchbar://nope"), LinkRouter.LogLabel("benchbar://nope")["other link, hash ".Length..]);
    }

    private static string Hash(string text) =>
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(text)), 0, 6).ToLowerInvariant();

    [Fact]
    public void TheLogLineOfAnIgnoredOrExplainedLinkNeverHoldsTheLink()
    {
        var link = "benchbar://up?bench=client-secret-bench&token=SECRET";
        var outcome = Route(link, Main, Other);
        var line = LinkRouter.RejectionLogLine(LinkRouter.LogLabel(link), outcome)!;
        Assert.Equal("benchbar://up: link refused: no such bench", line);
        Assert.DoesNotContain("client-secret-bench", line);
        Assert.DoesNotContain("SECRET", line);

        var ignored = LinkRouter.RejectionLogLine(LinkRouter.LogLabel("benchbar://repair?x=SECRET"), Route("benchbar://repair?x=SECRET"))!;
        Assert.StartsWith("Ignored other link, hash ", ignored);
        Assert.EndsWith(": unknown route", ignored);
        Assert.DoesNotContain("SECRET", ignored);

        var share = LinkRouter.RejectionLogLine(LinkRouter.LogLabel("benchbar://share/join?code=SECRET"), Route("benchbar://share/join?code=SECRET"))!;
        Assert.Equal("benchbar://share: share link: rooms are not on Windows yet", share);

        // an outcome that acts is not a rejection
        Assert.Null(LinkRouter.RejectionLogLine("benchbar://up", Route("benchbar://up", Main)));
        foreach (var why in Enum.GetValues<LinkWhy>()) Assert.DoesNotContain("SECRET", LinkRouter.LogText(why));
    }

    // --- ask before a link acts ---

    [Theory]
    [InlineData(LinkRoute.Up, true)]
    [InlineData(LinkRoute.Down, true)]
    [InlineData(LinkRoute.Restart, true)]
    [InlineData(LinkRoute.Console, true)]
    [InlineData(LinkRoute.Db, true)]
    [InlineData(LinkRoute.Open, false)]
    [InlineData(LinkRoute.Logs, false)]
    [InlineData(LinkRoute.Window, false)]
    [InlineData(LinkRoute.Doctor, false)]
    [InlineData(LinkRoute.Editor, false)]
    public void OnlyTheRoutesThatActAskAndOnlyWhenTheSettingIsOn(LinkRoute route, bool asks)
    {
        Assert.Equal(asks, LinkConfirm.NeedsAsking(route, setting: true));
        Assert.False(LinkConfirm.NeedsAsking(route, setting: false));
    }

    [Fact]
    public void TheQuestionNamesTheBenchTheActionAndWhyItIsAsked()
    {
        var stop = LinkConfirm.Ask(LinkRoute.Down, "frappe-bench");
        Assert.Equal(("Stop frappe-bench?", "Stop"), (stop.Title, stop.Button));
        Assert.Contains("A web page or another app can open such a link", stop.Detail);
        Assert.Equal("Open Terminal", LinkConfirm.Ask(LinkRoute.Console, "b").Button);
        Assert.Equal("Open a database session for b?", LinkConfirm.Ask(LinkRoute.Db, "b").Title);
    }

    [Fact]
    public void AskingIsOffByDefaultAndTheSettingIsSavedInTheTrayObject()
    {
        var path = Path.Combine(Path.GetTempPath(), "bb-links-" + Guid.NewGuid().ToString("N"), "config.json");
        try
        {
            var config = TrayConfig.Load(path);
            Assert.False(config.ConfirmLinkActions);
            config.ConfirmLinkActions = true;
            config.Save();
            Assert.True(TrayConfig.Load(path).ConfirmLinkActions);
            Assert.Contains("\"confirm_link_actions\": true", File.ReadAllText(path));
        }
        finally
        {
            if (Directory.Exists(Path.GetDirectoryName(path)!)) Directory.Delete(Path.GetDirectoryName(path)!, recursive: true);
        }
    }

    // --- the registration ---

    private sealed class FakeStore : ISchemeStore
    {
        public string? Command { get; set; }
        public string? Icon { get; private set; }
        public int Writes { get; private set; }

        public string? ReadCommand() => Command;

        public void Write(string command, string iconPath)
        {
            Command = command;
            Icon = iconPath;
            Writes++;
        }

        public void Remove() => Command = null;
    }

    private const string Exe = @"C:\Users\akash\AppData\Local\Programs\BenchBar\BenchBarTray.exe";

    [Fact]
    public void TheFirstStartRegistersTheSchemeWithTheLinkAsOneQuotedArgument()
    {
        var store = new FakeStore();
        Assert.Equal(SchemeResult.Registered, UrlSchemeRegistration.Ensure(store, Exe, _ => true));
        Assert.Equal("\"" + Exe + "\" \"%1\"", store.Command);
        Assert.Equal(Exe + ",0", store.Icon);
        Assert.Equal(Exe, UrlSchemeRegistration.ExeOf(store.Command));
        // the second start finds it current and writes nothing
        Assert.Equal(SchemeResult.Current, UrlSchemeRegistration.Ensure(store, Exe, _ => true));
        Assert.Equal(1, store.Writes);
    }

    [Fact]
    public void ARegistrationOfAGoneTrayIsRepairedButAnotherCopyOrProgramIsLeftAlone()
    {
        var gone = new FakeStore { Command = "\"D:\\old\\BenchBarTray.exe\" \"%1\"" };
        Assert.Equal(SchemeResult.Repaired, UrlSchemeRegistration.Ensure(gone, Exe, _ => false));
        Assert.Equal(UrlSchemeRegistration.CommandFor(Exe), gone.Command);

        var copy = new FakeStore { Command = "\"D:\\build\\BenchBarTray.exe\" \"%1\"" };
        Assert.Equal(SchemeResult.OtherCopy, UrlSchemeRegistration.Ensure(copy, Exe, _ => true));
        Assert.Equal(0, copy.Writes);

        var other = new FakeStore { Command = "\"C:\\Tools\\launcher.exe\" \"%1\"" };
        Assert.Equal(SchemeResult.OtherProgram, UrlSchemeRegistration.Ensure(other, Exe, _ => false));
        Assert.Equal(0, other.Writes);
        Assert.Equal("benchbar:// is registered to another program: left alone", UrlSchemeRegistration.LogLine(SchemeResult.OtherProgram));
        Assert.Null(UrlSchemeRegistration.LogLine(SchemeResult.Current));
    }

    [Fact]
    public void RemovingTakesOnlyTheRegistrationOfThisTray()
    {
        var ours = new FakeStore { Command = UrlSchemeRegistration.CommandFor(Exe) };
        Assert.True(UrlSchemeRegistration.Remove(ours, Exe.ToLowerInvariant()));
        Assert.Null(ours.Command);
        var other = new FakeStore { Command = UrlSchemeRegistration.CommandFor(@"D:\build\BenchBarTray.exe") };
        Assert.False(UrlSchemeRegistration.Remove(other, Exe));
        Assert.NotNull(other.Command);
        Assert.False(UrlSchemeRegistration.Remove(new FakeStore(), Exe));
    }

    [Theory]
    [InlineData("\"C:\\a b\\BenchBarTray.exe\" \"%1\"", "C:\\a b\\BenchBarTray.exe")]
    [InlineData("C:\\a\\BenchBarTray.exe %1", "C:\\a\\BenchBarTray.exe")]
    [InlineData("\"\" \"%1\"", null)]
    [InlineData("", null)]
    [InlineData(null, null)]
    public void TheProgramOfARegistryCommandIsItsFirstWord(string? command, string? exe) =>
        Assert.Equal(exe, UrlSchemeRegistration.ExeOf(command));

    // --- the hand over between two copies ---

    [Fact]
    public async Task ASecondCopyHandsTheLinkToTheRunningOneAndNothingIsWrittenToDisk()
    {
        var name = "bb.link." + Guid.NewGuid().ToString("N")[..8];
        var seen = new System.Collections.Concurrent.BlockingCollection<string>();
        using var server = LinkPipe.Serve(name, seen.Add);
        var first = await LinkPipe.TrySendAsync(name, "benchbar://up?bench=a%20b&x=é", TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        var second = await LinkPipe.TrySendAsync(name, "benchbar://down", TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        Assert.True(first && second);
        Assert.True(seen.TryTake(out var one, TimeSpan.FromSeconds(10)));
        Assert.True(seen.TryTake(out var two, TimeSpan.FromSeconds(10)));
        Assert.Equal(["benchbar://down", "benchbar://up?bench=a%20b&x=é"], new[] { one, two }.Order(StringComparer.Ordinal));
    }

    [Fact]
    public async Task WithNobodyListeningTheSendFailsQuicklyAndTheCallerFallsBack()
    {
        var sent = await LinkPipe.TrySendAsync("bb.none." + Guid.NewGuid().ToString("N")[..8], "benchbar://up", TimeSpan.FromMilliseconds(300), TestContext.Current.CancellationToken);
        Assert.False(sent);
    }

    [Fact]
    public async Task ALinkThatIsTooLongOrEmptyIsDroppedByTheReader()
    {
        static MemoryStream Bytes(string text) => new(System.Text.Encoding.UTF8.GetBytes(text));
        Assert.Equal("benchbar://up", await LinkPipe.ReadLinkAsync(Bytes("benchbar://up\nrest"), TestContext.Current.CancellationToken));
        Assert.Equal("benchbar://up", await LinkPipe.ReadLinkAsync(Bytes("benchbar://up"), TestContext.Current.CancellationToken));
        Assert.Null(await LinkPipe.ReadLinkAsync(Bytes("\n"), TestContext.Current.CancellationToken));
        Assert.Null(await LinkPipe.ReadLinkAsync(Bytes(""), TestContext.Current.CancellationToken));
        Assert.Null(await LinkPipe.ReadLinkAsync(Bytes("benchbar://up?x=" + new string('a', LinkRouter.MaxLength + 10) + "\n"), TestContext.Current.CancellationToken));
        Assert.Null(await LinkPipe.ReadLinkAsync(Bytes(new string('a', 100_000)), TestContext.Current.CancellationToken));
    }

    [Fact]
    public void ThePipeIsPerSession()
    {
        Assert.NotEqual(LinkPipe.NameFor(1), LinkPipe.NameFor(2));
    }
}
