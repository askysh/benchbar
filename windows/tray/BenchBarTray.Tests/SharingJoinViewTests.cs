using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>
/// "Join a room" on the Sharing tab: the look at the room comes before the code, the code goes to the CLI on stdin and the box is empty after,
/// a refusal is the CLI's sentence, Forget asks first, and an older CLI has none of it. The CLI documents are recorded (fixtures/cli/share-join*).
/// </summary>
public class SharingJoinViewTests
{
    private const string Code = "482913";
    private const string Room = "127.0.0.1:38999";
    private const string Pin = "7fdc34a6ba8c6ac7c1afd281d813b5d80957fdaa89d10c000cc72b44c816453d";

    private static (SharingView View, PageKit Kit, List<string> Asked) Make(bool supported = true, bool answer = true, string joined = "share-joined-none.json", string? join = "share-join-waiting.json",
        string look = "share-join-look.json", string? joinFails = null, string[]? joinedLines = null, string[]? lookLines = null, Action<PageKit>? prepare = null, Action<ScriptedStreamRunner>? script = null, bool pin = true)
    {
        var kit = new PageKit();
        prepare?.Invoke(kit);
        if (supported) kit.Runner.On("commands").Print(Commands(pin));
        kit.Runner.On(a => a.Length > 1 && a[1] == "join" && a.Contains("--dry-run")).Print(lookLines ?? Fixture(look));
        if (joinFails is not null) kit.Runner.On(a => a.Length > 1 && a[1] == "join").Fail(1, SystemStreamRunner.PickError([.. Fixture(joinFails).Select(l => l.Trim())]));
        else if (join is not null) kit.Runner.On(a => a.Length > 1 && a[1] == "join").Print(Fixture(join));
        script?.Invoke(kit.Runner); // before the catch all below: the first reply that matches wins
        kit.Runner.On("share", "joined").Print(joinedLines ?? Fixture(joined));
        kit.Runner.On("share", "leave").Print(Fixture("share-leave.json"));
        kit.Runner.On("share", "forget").Print(Fixture("share-forget.json"));
        kit.Runner.On("share", "status").Print(Fixture("share-status-unset.json")[0]);
        kit.Runner.On("share").Print(Fixture("share-done.jsonl"));
        var asked = new List<string>();
        var view = new SharingView(kit.Services, bench => new ShareModel(kit.Services.Cli, bench))
        {
            Confirm = (title, _, _) =>
            {
                asked.Add(title);
                return answer;
            },
        };
        view.Bind(new BenchContext(Bench(), null));
        Wait(view.Pending);
        return (view, kit, asked);
    }

    /// <summary>The catalogue of a CLI with the guest commands; <paramref name="pin"/>: <c>share join</c> has <c>--host-key</c>.</summary>
    private static string Commands(bool pin)
    {
        var doc = (JsonObject)JsonNode.Parse(Parity187cViewTests.CommandsWith("share join", "share joined", "share leave", "share forget"))!;
        doc["labs"] = new JsonArray("lan-rooms"); // the lab was on when the CLI printed it
        if (pin) ((JsonArray)doc["commands"]!.AsArray().Single(c => (string?)c!["name"] == "share join")!["flags"]!).Add(new JsonObject { ["name"] = "--host-key", ["value"] = "HEX", ["help"] = "Pin the key." });
        return doc.ToJsonString();
    }

    private static IEnumerable<(string[] Args, string? Stdin)> JoinRuns(PageKit kit) =>
        kit.Runner.Runs.Select((r, i) => (r.Args, kit.Runner.Stdins[i])).Where(r => r.Args.Length > 2 && r.Args[0] == "share" && r.Args[1] == "join");

    private static void Look(SharingView view, string address = Room)
    {
        Click(view.Buttons["Join a room..."]);
        view.AddressBox!.Text = address;
        Click(view.Buttons["Look at the room"]);
        Wait(view.Pending);
    }

    // --- an older CLI ---

    [Fact]
    public void ACliWithoutShareJoinHasNoJoinASheetOrACall() => Sta.Run(() =>
    {
        var (view, kit, _) = Make(supported: false);
        Assert.DoesNotContain(view.Lines, l => l.Contains("Join a room"));
        Assert.DoesNotContain("Join a room...", view.Buttons.Keys);
        Assert.False(view.Guest!.Supported);
        Assert.DoesNotContain(kit.Runner.Runs, r => r.Args.Length > 1 && r.Args[0] == "share" && r.Args[1] is "join" or "joined");
        AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void ACatalogueFromBeforeTheLabWasOnIsReadAgainSoTheJoinShowsUpWithoutARestart() => Sta.Run(() =>
    {
        var (view, _, _) = Make(prepare: kit =>
        {
            // the tray read its catalogue while the lab was off: it lists no share subcommand
            var old = new ScriptedStreamRunner();
            var first = 0;
            old.On(a => a[0] == "commands" && first++ == 0).Print(Fixture("commands.json"));
            old.On("commands").Print(Commands(pin: true)); // what the CLI prints now, with the lab on
            kit.Services.Commands = new CommandSupport(new CliClient(old, () => "benchbar.exe"));
            Wait(kit.Services.Commands.GetAsync());
            Assert.False(kit.Services.Commands.Current!.Has("share join"));
        });
        Assert.Contains("Join a room...", view.Buttons.Keys);
    });

    [Fact]
    public void ACliThatHasShareJoinButNoHostKeyFlagGetsNoJoin() => Sta.Run(() =>
    {
        var (view, kit, _) = Make(pin: false);
        Assert.DoesNotContain("Join a room...", view.Buttons.Keys);
        Assert.False(view.Guest!.Supported);
        Assert.Empty(JoinRuns(kit));
    });

    // --- the look comes first ---

    [Fact]
    public void TheSheetShowsTheRoomItsAddressAndTheHostKeyBeforeAskingForTheCode() => Sta.Run(() =>
    {
        var (view, kit, _) = Make();
        Assert.Contains("Join a room...", view.Buttons.Keys);
        Click(view.Buttons["Join a room..."]);
        Assert.False(view.Buttons["Look at the room"].IsEnabled); // nothing typed yet
        Assert.Null(view.CodeBox);
        view.AddressBox!.Text = Room;
        Assert.True(view.Buttons["Look at the room"].IsEnabled);
        Assert.Empty(JoinRuns(kit)); // typing sends nothing
        Click(view.Buttons["Look at the room"]);
        Wait(view.Pending);

        Assert.Contains("Room: Test Room (host: Test Host)", view.Lines);
        Assert.Contains("Address: 127.0.0.1:38999", view.Lines);
        Assert.Contains("Host key: 7fdc 34a6 ba8c 6ac7", view.Lines);
        Assert.NotNull(view.CodeBox);
        Assert.Contains("Join room", view.Buttons.Keys);
        var run = Assert.Single(JoinRuns(kit));
        Assert.Equal(["share", "join", Room, "--dry-run", "--json"], run.Args);
        Assert.Null(run.Stdin);
        AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void ACodeTypedInTheAddressBoxIsNeverRunAndIsNotShownBack() => Sta.Run(() =>
    {
        var (view, kit, _) = Make();
        Look(view, Code);
        Assert.Empty(JoinRuns(kit));
        Assert.Contains(UiText.Get("GuestAddressInvalid"), view.Lines);
        Assert.DoesNotContain(view.Lines, l => l.Contains(Code));
        Assert.Null(view.CodeBox);
    });

    [Fact]
    public void ChangingTheAddressAfterTheLookDropsTheLookAndTheCodeBox() => Sta.Run(() =>
    {
        var (view, _, _) = Make();
        Look(view);
        Assert.NotNull(view.CodeBox);
        view.AddressBox!.Text = "127.0.0.1:39000";
        Assert.Null(view.Guest!.Look);
        Assert.DoesNotContain(view.Lines, l => l.StartsWith("Host key:"));
        Assert.Null(view.CodeBox);
    });

    [Theory]
    [InlineData("locked", "GuestLocked")]
    [InlineData("full", "GuestFull")]
    public void ALockedOrFullRoomOffersNoCodeBox(string field, string sentence) => Sta.Run(() =>
    {
        var look = (JsonObject)JsonNode.Parse(Fixture("share-join-look.json")[0])!;
        look[field] = true;
        var (view, _, _) = Make(lookLines: [look.ToJsonString()]);
        Look(view);
        Assert.Contains(UiText.Format(field == "locked" ? "GuestLocked" : "GuestFull", "Test Host"), view.Lines);
        Assert.Null(view.CodeBox);
        Assert.DoesNotContain("Join room", view.Buttons.Keys);
        Assert.NotEmpty(sentence);
    });

    // --- the join ---

    [Fact]
    public void TheCodeGoesOnStdinTheBoxIsEmptyAndTheSheetClosesWhenTheJoinEnds() => Sta.Run(() =>
    {
        var (view, kit, _) = Make();
        Look(view);
        var box = view.CodeBox!;
        box.Password = "482 913";
        Click(view.Buttons["Join room"]);
        Assert.Equal("", box.Password); // empty from the moment the code was taken
        Wait(view.Pending);

        var join = JoinRuns(kit).Single(r => !r.Args.Contains("--dry-run"));
        Assert.Equal(["share", "join", Room, "--host-key", Pin, "--no-open", "--json"], join.Args); // pinned to the key that was looked at
        Assert.Equal(Code, join.Stdin);
        Assert.All(kit.Runner.Runs, r => Assert.DoesNotContain(r.Args.Concat(r.Env.Values), a => a.Contains(Code)));
        Assert.Null(view.AddressBox); // the sheet closed
        Assert.Null(view.CodeBox);
        Assert.DoesNotContain(view.Lines, l => l.Contains(Code) || l.Contains("482 913"));
        Assert.Contains(UiText.Format("GuestJoinedWaiting", "Test Room", "Test Host"), view.Lines);
        Assert.Contains("Join a room...", view.Buttons.Keys);
        AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void AWrongCodeShowsTheCliSentenceKeepsTheLookAndEmptiesTheBox() => Sta.Run(() =>
    {
        var (view, _, _) = Make(joinFails: "share-join-wrong-code.stderr.txt");
        Look(view);
        var box = view.CodeBox!;
        box.Password = "000000";
        Click(view.Buttons["Join room"]);
        Wait(view.Pending);
        Assert.Contains("That code didn't work.", view.Lines);
        Assert.Equal("", box.Password);
        Assert.NotNull(view.AddressBox);
        Assert.Contains("Host key: 7fdc 34a6 ba8c 6ac7", view.Lines); // type the code again, no new look
        Assert.DoesNotContain(view.Lines, l => l.Contains("newer"));
    });

    [Fact]
    public void AHostThatShowsAnotherKeyIsTheSentenceOfItsOwnAndTheSheetAsksForANewLook() => Sta.Run(() =>
    {
        var (view, kit, _) = Make(join: null, script: runner => runner.On(a => a.Length > 1 && a[1] == "join" && a.Contains("--no-open"))
            .Fail(ShareGuestModel.HostKeyMismatchExit, SystemStreamRunner.PickError([.. Fixture("share-join-key-mismatch.stderr.txt").Select(l => l.Trim())])));
        Look(view);
        view.CodeBox!.Password = Code;
        Click(view.Buttons["Join room"]);
        Wait(view.Pending);
        Assert.Contains(UiText.Format("GuestKeyMismatch", "Test Host"), view.Lines);
        Assert.DoesNotContain(view.Lines, l => l.Contains("newer") || l.Contains("could not be joined"));
        Assert.Null(view.Guest!.Look);
        Assert.Null(view.CodeBox);
        Assert.NotNull(view.AddressBox); // the sheet stays: look again
    });

    [Fact]
    public void ARoomOfThisComputerOffersOpenInPlaceOfACodeBox() => Sta.Run(() =>
    {
        var (view, kit, _) = Make(look: "share-join-look-paired.json", join: "share-join-ready.json");
        Look(view);
        Assert.Null(view.CodeBox);
        Assert.Contains(UiText.Get("GuestPaired"), view.Lines);
        Click(view.Buttons["Open the room"]);
        Wait(view.Pending);
        var join = JoinRuns(kit).Single(r => !r.Args.Contains("--dry-run"));
        Assert.Null(join.Stdin);
        Assert.Contains(UiText.Format("GuestJoinedReady", "Test Room", "seat3@example.com"), view.Lines);
    });

    [Fact]
    public void CancelJoinEndsTheWaitForASeatAndEmptiesTheCode() => Sta.Run(() =>
    {
        ScriptedReply? hold = null;
        var (view, _, _) = Make(join: null, script: runner => hold = runner.On(a => a.Length > 1 && a[1] == "join" && a.Contains("--no-open")).Print().Hold());
        Look(view);
        view.CodeBox!.Password = Code;
        Click(view.Buttons["Join room"]);
        Wait(hold!.Started.Task);
        Assert.Contains("Cancel join", view.Buttons.Keys);
        Click(view.Buttons["Cancel join"]);
        Wait(view.Pending);
        Assert.Contains(UiText.Get("GuestStopped"), view.Lines);
        Assert.Null(view.Guest!.Busy);
        Assert.Equal("", view.CodeBox?.Password ?? "");
    });

    // --- the rooms joined ---

    [Fact]
    public void ARoomThatIsOpenCanBeOpenedLeftAndForgottenAndForgetAsksFirst() => Sta.Run(() =>
    {
        var (view, kit, asked) = Make(joined: "share-joined-ready.json", answer: false);
        Assert.Contains("Test Room · host: Test Host · 127.0.0.1:38999 · open, seat seat3@example.com", view.Lines);
        Assert.Contains("Host key: 7fdc 34a6 ba8c 6ac7", view.Lines);
        AssertEveryControlIsNamed(view);

        Click(view.Buttons["Open Test Room"]);
        Wait(view.Pending);
        Assert.Equal("http://test-room-c85377aeab4f6a61.localhost:41732/_benchbar/signin?next=/app", Assert.Single(kit.Opened));
        Assert.Empty(JoinRuns(kit)); // an open room needs no call

        Click(view.Buttons["Forget Test Room"]);
        Wait(view.Pending);
        Assert.Equal(["Forget Test Room?"], asked);
        Assert.DoesNotContain(kit.Runner.Runs, r => r.Args.Length > 1 && r.Args[1] == "forget"); // declined: nothing ran

        Click(view.Buttons["Leave Test Room"]);
        Wait(view.Pending);
        var leave = kit.Runner.Runs.Single(r => r.Args.Length > 1 && r.Args[1] == "leave");
        Assert.Equal(["share", "leave", "7fdc34a6ba8c6ac7", "--json"], leave.Args);
        Assert.Equal(("0", "gui"), (leave.Env["BENCHBAR_NONINTERACTIVE"], leave.Env["BENCHBAR_SUDO"]));
        Assert.Contains(UiText.Format("GuestLeft", "Test Room"), view.Lines);
    });

    [Fact]
    public void ForgetRunsOnlyAfterTheConfirmation() => Sta.Run(() =>
    {
        var (view, kit, asked) = Make(joined: "share-joined-ready.json", answer: true);
        Click(view.Buttons["Forget Test Room"]);
        Wait(view.Pending);
        Assert.Single(asked);
        Assert.Equal(["share", "forget", "7fdc34a6ba8c6ac7", "--json"], kit.Runner.Runs.Single(r => r.Args.Length > 1 && r.Args[1] == "forget").Args);
        Assert.Contains(view.Lines, l => l.StartsWith(UiText.Format("GuestForgot", "Test Room")));
    });

    [Fact]
    public void AClosedRoomIsOpenedAgainWithNoCodeAndThenOpenedInTheBrowser() => Sta.Run(() =>
    {
        var (view, kit, _) = Make(joined: "share-joined-closed.json", join: "share-join-ready.json");
        Assert.Contains("closed here: Open opens it again", string.Join('\n', view.Lines));
        Click(view.Buttons["Open Test Room"]);
        Wait(view.Pending);
        var join = Assert.Single(JoinRuns(kit));
        Assert.Equal(["share", "join", Room, "--no-wait", "--no-open", "--json"], join.Args);
        Assert.Null(join.Stdin);
        Assert.Equal("http://test-room-c85377aeab4f6a61.localhost:41732/_benchbar/signin?next=/app", Assert.Single(kit.Opened));
    });

    [Fact]
    public void ARoomWhereGuestsPickSeatsShowsTheFreeSeatsAndTakesTheOnePicked() => Sta.Run(() =>
    {
        // share joined lists the room as waiting and nothing more; the recording is of another run than share-join-pick.json, so its id and port are set to the pick room's
        var listed = (JsonObject)JsonNode.Parse(Fixture("share-joined-waiting.json")[0])!;
        listed["rooms"]![0]!["id"] = "69258557ffccf587";
        listed["rooms"]![0]!["port"] = 39629;
        var (view, kit, _) = Make(joinedLines: [listed.ToJsonString()], join: "share-join-pick.json");
        Assert.Contains(view.Lines, l => l.Contains(UiText.Get("GuestStateWaitingAny")));
        Assert.Empty(Walk(view).OfType<System.Windows.Controls.ComboBox>());

        Click(view.Buttons["Open Test Room"]); // asks the room, which says seats are for picking
        Wait(view.Pending);
        var box = Walk(view).OfType<System.Windows.Controls.ComboBox>().Single();
        Assert.Equal(6, box.Items.Count);
        Assert.Equal("Seat 1: Sales User", box.Items[0]);
        Assert.Contains(UiText.Format("GuestNotOpen", "Test Room", UiText.Get("GuestStatePick")), view.Lines);

        box.SelectedIndex = 1;
        Click(view.Buttons["Take a seat in Test Room"]);
        Wait(view.Pending);
        var take = JoinRuns(kit).Last();
        Assert.Equal(["share", "join", "127.0.0.1:39629", "--seat", "seat2", "--no-wait", "--no-open", "--json"], take.Args);
        Assert.Null(take.Stdin);
    });

    [Fact]
    public void TheJoinedRoomsAreAskedWithJoinedAndNeverRunAJoin() => Sta.Run(() =>
    {
        var (_, kit, _) = Make(joined: "share-joined-ready.json");
        Assert.Contains(kit.Runner.Runs, r => r.Args.SequenceEqual(["share", "joined", "--json"]));
        Assert.Empty(JoinRuns(kit));
        Assert.DoesNotContain(kit.Runner.Runs, r => r.Args.Contains("--bench-dir") && r.Args.Length > 1 && r.Args[1] is "join" or "joined" or "leave" or "forget");
    });
}
