using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using Xunit;
using static Tray.Core.Tests.CliFixture;

namespace Tray.Core.Tests;

/// <summary>
/// The follow-ups of the reviews of the join work (#353), Windows tray half: where text is cut, what a seat's roles and a full name are
/// read through, what a person sees when a join ends with a line that is not the room's, and what is asked once and not at every look.
/// </summary>
public class ShareGuestFollowUpTests
{
    private const string Code = ShareGuestTests.Code;

    private static bool HasLoneSurrogate(string text)
    {
        for (var i = 0; i < text.Length; i++)
        {
            if (char.IsHighSurrogate(text[i]) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1])) i++;
            else if (char.IsSurrogate(text[i])) return true;
        }
        return false;
    }

    // --- 1. the cut is on a text element ---

    [Fact]
    public void AnEmojiThatStraddlesTheCutIsDroppedWholeNotSplit()
    {
        // 76 letters, then a smiley (two UTF-16 units at 76 and 77): the cut at 77 would keep half of it
        var text = new string('a', 76) + "\U0001F600" + new string('b', 20);
        var clean = ShareGuestText.Clean(text);
        Assert.False(HasLoneSurrogate(clean));
        Assert.Equal(new string('a', 76) + "...", clean);
        Assert.True(clean.Length <= 80);
    }

    [Fact]
    public void AFamilyEmojiJoinedWithZeroWidthJoinersIsOneCharacterAtTheCut()
    {
        var family = "\U0001F468\u200D\U0001F469\u200D\U0001F467"; // eight units, one character
        var text = new string('a', 74) + family + new string('b', 20);
        var clean = ShareGuestText.Clean(text);
        Assert.False(HasLoneSurrogate(clean));
        Assert.DoesNotContain('\u200D', clean);
        Assert.Equal(new string('a', 74) + "...", clean);
    }

    [Fact]
    public void ALetterIsNotCutFromItsCombiningMark()
    {
        // "e" at 76 and U+0301 (acute) at 77: keeping the "e" and not the mark would show another letter
        var text = new string('a', 76) + "e\u0301" + new string('b', 20);
        var clean = ShareGuestText.Clean(text);
        Assert.Equal(new string('a', 76) + "...", clean);
        Assert.True(clean.Length <= 80);
    }

    [Fact]
    public void ATextExactlyAsLongAsTheLimitIsNotChanged()
    {
        var emojiAtTheEnd = new string('a', 78) + "\U0001F600"; // 80 units, ends in a pair
        Assert.Equal(emojiAtTheEnd, ShareGuestText.Clean(emojiAtTheEnd));
        var markAtTheEnd = new string('a', 78) + "e\u0301";
        Assert.Equal(markAtTheEnd, ShareGuestText.Clean(markAtTheEnd));
        var plain = new string('a', 80);
        Assert.Equal(plain, ShareGuestText.Clean(plain));
        Assert.Equal(new string('a', 77) + "...", ShareGuestText.Clean(new string('a', 81)));
    }

    // --- 2. seat roles, and a name that is longer than 80 ---

    private static JsonObject HostSeatDoc(string roleText, string fullName) => (JsonObject)JsonNode.Parse(
        new JsonObject { ["seats"] = new JsonArray(new JsonObject { ["seat_id"] = "seat1", ["full_name"] = fullName, ["roles"] = new JsonArray(roleText, "Plain Role") }) }.ToJsonString())!;

    [Fact]
    public void TheRolesOfASeatOnTheHostTabAreOneLineOfPlainTextLikeOnTheGuestSide()
    {
        var seat = ShareJson.Seats(HostSeatDoc("Sales\r\n[FAIL] You must pay\u202E", "Seat One")).Single();
        Assert.Equal(["Sales [FAIL] You must pay", "Plain Role"], seat.Roles);
    }

    [Fact]
    public void AFullNameOfAHundredAndTwentyCharactersIsShownWholeOnBothTabs()
    {
        var name = string.Join(' ', Enumerable.Repeat("Alexandrina", 10)); // 119 characters
        Assert.Equal(name, ShareJson.Seats(HostSeatDoc("Sales", name)).Single().Name);
        var doc = (JsonObject)Doc("share-join-pick.json").DeepClone();
        doc["seats"]![0]!["full_name"] = name;
        Assert.Equal(name, ShareGuestJson.Join(doc).Room.Seats[0].Name);
        var people = (JsonObject)Doc("share-people.json").DeepClone();
        people["people"]![0]!["seat_full_name"] = name;
        Assert.Equal(name, ShareJson.People(people)[0].SeatName);
    }

    [Fact]
    public void AFullNameLongerThanTheFieldOfAUserIsStillCut()
    {
        var shown = ShareJson.Seats(HostSeatDoc("Sales", new string('n', 300))).Single().Name;
        Assert.Equal(140, shown.Length);
        Assert.EndsWith("...", shown);
    }

    // --- 3. a join that ends with a line that is not the room's ---

    private static async Task<ShareGuestModel> JoinFailing(int exit, string stderr)
    {
        var (model, runner) = await ShareGuestTests.LookedAt();
        runner.On(a => a.Contains("--no-open")).Fail(exit, stderr);
        runner.On("share", "joined").Print(Lines("share-joined-none.json"));
        Assert.False(await model.JoinAsync(Secret.From(Code), ct: TestContext.Current.CancellationToken));
        return model;
    }

    [Theory]
    [InlineData("WSL is not installed")]
    [InlineData("benchbar: command not found")]
    public async Task ALineOfTheShimOrWslIsShownWithTheExitCodeAndNotHiddenBehindAGenericSentence(string line)
    {
        var model = await JoinFailing(127, line);
        Assert.Contains(line, model.LastError);
        Assert.Contains("127", model.LastError);
        Assert.StartsWith(UiText.Get("GuestJoinFailed"), model.LastError);
    }

    [Fact]
    public async Task ThatLineIsOneCleanLineEvenWhenItCarriesColourCodesAndTurnedText()
    {
        var model = await JoinFailing(1, "\u001b[31mnot found\u001b[0m\u202E [FAIL] You must pay\u2028next");
        Assert.Contains("not found", model.LastError);
        Assert.DoesNotContain('\u001b', model.LastError!);
        Assert.DoesNotContain('\u202E', model.LastError!);
        Assert.DoesNotContain('\u2028', model.LastError!);
        Assert.DoesNotContain("\n", model.LastError!);
    }

    [Theory]
    [InlineData("Room      Test Room (host: Test Host)")]
    [InlineData("Address   127.0.0.1:38999")]
    [InlineData("Host key  7fdc 34a6 ba8c 6ac7")]
    [InlineData("If you are not sure this is the right computer, ask Test Host to read out the host key: benchbar share status shows it there.")]
    public async Task ALineOfTheRoomsOwnBlockIsStillNeverShown(string line)
    {
        var model = await JoinFailing(1, line);
        Assert.Equal(UiText.Get("GuestJoinFailed"), model.LastError);
    }

    [Fact]
    public async Task ALookThatEndsWithALineOfTheShimIsShownToo()
    {
        var (model, runner) = ShareGuestTests.Rig();
        runner.On("share", "join").Fail(1, "WSL is not installed");
        Assert.False(await model.LookAsync("127.0.0.1:38999", TestContext.Current.CancellationToken));
        Assert.Contains("WSL is not installed", model.LastError);
        Assert.StartsWith(UiText.Get("GuestLookFailed"), model.LastError);
    }

    [Fact]
    public async Task TheLocalAddressThatDidNotEndIsTheSentenceThePersonSees()
    {
        // pull request #420: the CLI refuses a join of a room this computer is in while the old local address is still open
        var model = await JoinFailing(1, ShareGuestTests.Stderr("share-join-forwarder-open.stderr.txt"));
        Assert.Equal("This computer is in the room, but the local address of the room Test Host had before is still open: its process (guest-forward.js) did not end, and it shows that room's pages.", model.LastError);
    }

    // --- 4. what the CLI cannot do is asked once, not at every look ---

    private static string Where(string version) => "{\"schema_version\":1,\"cli_version\":\"" + version + "\"}";

    private static int Asked(ScriptedStreamRunner runner, string command) => runner.Runs.Count(r => r.Args[0] == command);

    [Fact]
    public async Task ACliThatCannotPinPaysTheVersionProbeOnceAcrossTwoBinds()
    {
        var (client, runner) = Scripted();
        runner.On("commands").Print(ShareGuestTests.Catalogue("0.9.0", pin: false));
        runner.On("where").Print(Where("0.9.0"));
        var model = new ShareGuestModel(client, new CommandSupport(client));
        for (var bind = 0; bind < 2; bind++)
        {
            await model.CheckSupportAsync(TestContext.Current.CancellationToken);
            Assert.False(model.Supported);
        }
        Assert.Equal(1, Asked(runner, "where"));
        Assert.Equal(1, Asked(runner, "commands"));
    }

    [Fact]
    public async Task TheAnswerIsAskedAgainOnceTheRecheckTimeHasPassed()
    {
        var (client, runner) = Scripted();
        runner.On("commands").Print(ShareGuestTests.Catalogue("0.9.0", pin: false));
        runner.On("where").Print(Where("0.9.0"));
        var clock = new Microsoft.Extensions.Time.Testing.FakeTimeProvider();
        var model = new ShareGuestModel(client, new CommandSupport(client), clock);
        await model.CheckSupportAsync(TestContext.Current.CancellationToken);
        clock.Advance(ShareGuestModel.Recheck - TimeSpan.FromSeconds(1));
        await model.CheckSupportAsync(TestContext.Current.CancellationToken);
        Assert.Equal(1, Asked(runner, "where"));
        clock.Advance(TimeSpan.FromSeconds(2));
        await model.CheckSupportAsync(TestContext.Current.CancellationToken);
        Assert.Equal(2, Asked(runner, "where"));
        Assert.Equal(1, Asked(runner, "commands")); // the version did not change, so the catalogue stays
    }

    [Fact]
    public async Task AProbeThatCannotAnswerIsRememberedToo()
    {
        var (client, runner) = Scripted();
        runner.On("commands").Print(ShareGuestTests.Catalogue("0.9.0", pin: false));
        runner.On("where").Fail(1, "WSL is not installed");
        var model = new ShareGuestModel(client, new CommandSupport(client));
        await model.CheckSupportAsync(TestContext.Current.CancellationToken);
        await model.CheckSupportAsync(TestContext.Current.CancellationToken);
        Assert.Equal(1, Asked(runner, "where"));
    }

    [Fact]
    public async Task ACliThatMovedOnIsStillSeenByTheFirstProbeAndFollowed()
    {
        var (client, runner) = Scripted();
        var first = 0;
        runner.On(a => a[0] == "commands" && first++ == 0).Print(ShareGuestTests.Catalogue("0.9.0", pin: false));
        runner.On("commands").Print(ShareGuestTests.Catalogue("0.9.1"));
        runner.On("where").Print(Where("0.9.1"));
        var model = new ShareGuestModel(client, new CommandSupport(client));
        await model.CheckSupportAsync(TestContext.Current.CancellationToken);
        Assert.True(model.Supported);
        await model.CheckSupportAsync(TestContext.Current.CancellationToken);
        Assert.Equal(1, Asked(runner, "where"));
        Assert.Equal(2, Asked(runner, "commands"));
    }

    [Fact]
    public async Task ACliThatPrintsNoLabsFieldIsReadOnceAcrossTwoLooks()
    {
        var (client, runner) = Scripted();
        runner.On("commands").Print(ShareGuestTests.Catalogue("0.9.0", pin: false).Replace("\"labs\":[\"lan-rooms\"],", ""));
        runner.On("where").Print(Where("0.9.0"));
        var support = new CommandSupport(client);
        await new ShareGuestModel(client, support).CheckSupportAsync(TestContext.Current.CancellationToken);
        await new ShareGuestModel(client, support).CheckSupportAsync(TestContext.Current.CancellationToken);
        Assert.Equal(1, Asked(runner, "commands"));
    }

    [Fact]
    public async Task ALabThatStaysOffIsAskedAboutOnceAcrossTwoLooks()
    {
        var (client, runner) = Scripted();
        runner.On("commands").Print(ShareGuestTests.Catalogue("0.9.0", lab: false));
        runner.On("where").Print(Where("0.9.0"));
        var support = new CommandSupport(client);
        var model = new ShareGuestModel(client, support);
        await model.CheckSupportAsync(TestContext.Current.CancellationToken);
        await model.CheckSupportAsync(TestContext.Current.CancellationToken);
        Assert.Equal(2, Asked(runner, "commands")); // the first read, and the one read again because the lab may have been off then
    }
}
