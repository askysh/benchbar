using System.Text.Json;
using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using Xunit;
using static Tray.Core.Tests.CliFixture;

namespace Tray.Core.Tests;

/// <summary>
/// The guest side of a room: the documents as <c>share join</c>, <c>joined</c>, <c>leave</c> and <c>forget</c> print them, the exact calls, the
/// refusals as the CLI words them, and the rule that the room code reaches the CLI on its standard input and nowhere else. Nothing here starts a
/// process. Every fixture is the output of the CLI of pull request #344 in the throwaway WSL distro (a real room gateway started on loopback),
/// recorded with a script that is not part of the repository; see the pull request for how.
/// </summary>
public class ShareGuestTests
{
    internal const string Code = "482913";
    private const string RoomKey = "7fdc34a6ba8c6ac7";
    private const string Pin = "7fdc34a6ba8c6ac7c1afd281d813b5d80957fdaa89d10c000cc72b44c816453d"; // host_pin of share-join-look.json
    private const string Room = "127.0.0.1:38999";

    internal static (ShareGuestModel Model, ScriptedStreamRunner Runner) Rig()
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var (client, runner) = Scripted();
        var commands = new CommandSupport(client);
        return (new ShareGuestModel(client, commands), runner);
    }

    internal static string Stderr(string name) => SystemStreamRunner.PickError([.. Lines(name).Select(l => l.Trim())])!; // the runner keeps trimmed lines

    internal static async Task<(ShareGuestModel Model, ScriptedStreamRunner Runner)> LookedAt(string look = "share-join-look.json")
    {
        var (model, runner) = Rig();
        runner.On(a => a.Contains("--dry-run")).Print(Lines(look));
        Assert.True(await model.LookAsync(Room, TestContext.Current.CancellationToken));
        return (model, runner);
    }

    // --- the documents ---

    [Fact]
    public void TheLookHoldsTheRoomItsAddressAndTheDigitsOfTheHostsKey()
    {
        var look = ShareGuestJson.Look(Doc("share-join-look.json"));
        Assert.Equal((RoomKey, "127.0.0.1", 38999, "Test Room", "Test Host"), (look.HostKey, look.Address, look.Port, look.Room, look.Host));
        Assert.Equal((false, false, false, false, 0, 6), (look.Locked, look.Full, look.Known, look.Paired, look.People, look.Seats));
        Assert.Equal("7fdc 34a6 ba8c 6ac7", look.SpacedKey);
        Assert.Equal(Pin, look.HostPin);
        Assert.Equal(Room, look.Target);
        Assert.True(ShareGuestJson.Look(Doc("share-join-look-paired.json")).Paired);
    }

    [Fact]
    public void ALookWithoutTheKeyIsNotALookSoNoCodeIsEverSentToItsRoom()
    {
        var doc = Doc("share-join-look.json");
        doc.Remove("host_key");
        Assert.Throws<FormatException>(() => ShareGuestJson.Look(doc));
        doc["host_key"] = "not sixteen hex digits";
        Assert.Throws<FormatException>(() => ShareGuestJson.Look(doc));
    }

    [Fact]
    public void ALookWithoutTheHostPinIsOfACliThatCannotPinTheJoinAndIsNotUsed()
    {
        // the whole hash is what --host-key takes: without it, or with one that is not the key shown, no join is offered
        var noPin = (JsonObject)Doc("share-join-look.json").DeepClone();
        noPin.Remove("host_pin");
        Assert.Throws<FormatException>(() => ShareGuestJson.Look(noPin));
        var short64 = (JsonObject)Doc("share-join-look.json").DeepClone();
        short64["host_pin"] = Pin[..63];
        Assert.Throws<FormatException>(() => ShareGuestJson.Look(short64));
        var other = (JsonObject)Doc("share-join-look.json").DeepClone();
        other["host_pin"] = new string('a', 64);
        Assert.Throws<FormatException>(() => ShareGuestJson.Look(other)); // the digits shown are not the start of the hash joined
    }

    [Fact]
    public void AJoinedRoomIsReadInEveryStateTheCliPrints()
    {
        var waiting = ShareGuestJson.Join(Doc("share-join-waiting.json"));
        Assert.True(waiting.Joined);
        Assert.Equal((GuestState.Waiting, true, 6, null), (waiting.Room.State, waiting.Room.HostAssigns, waiting.Room.Seats.Count, waiting.Room.Seat));
        var pick = ShareGuestJson.Join(Doc("share-join-pick.json")).Room;
        Assert.Equal((GuestState.Waiting, false), (pick.State, pick.HostAssigns));
        Assert.Equal(["seat1", "seat2", "seat3", "seat4", "seat5", "seat6"], pick.FreeSeats.Select(s => s.Id));
        Assert.Equal(["Sales User"], pick.Seats[0].Roles);
        var ready = ShareGuestJson.Join(Doc("share-join-ready.json"));
        Assert.False(ready.Joined);
        Assert.Equal((GuestState.Ready, "seat3@example.com", true), (ready.Room.State, ready.Room.Seat, ready.Room.CanOpen));

        var closed = Assert.Single(ShareGuestJson.Rooms(Doc("share-joined-closed.json")));
        Assert.Equal((GuestState.Closed, null, false, false), (closed.State, closed.Url, closed.Forwarding, closed.CanOpen));
        Assert.Empty(ShareGuestJson.Rooms(Doc("share-joined-none.json")));
        Assert.Equal(GuestState.Waiting, Assert.Single(ShareGuestJson.Rooms(Doc("share-joined-waiting.json"))).State);
    }

    [Theory]
    [InlineData("ready", GuestState.Ready)]
    [InlineData("waiting", GuestState.Waiting)]
    [InlineData("removed", GuestState.Removed)]
    [InlineData("new_room", GuestState.NewRoom)]
    [InlineData("ended", GuestState.Ended)]
    [InlineData("identity_changed", GuestState.IdentityChanged)]
    [InlineData("offline", GuestState.Offline)]
    [InlineData("closed", GuestState.Closed)]
    [InlineData("unknown", GuestState.Unknown)]
    [InlineData("a state of the future", GuestState.Unknown)]
    [InlineData(null, GuestState.Unknown)]
    public void EveryStateOfTheSchemaHasAReading(string? raw, GuestState expected) => Assert.Equal(expected, ShareGuestJson.State(raw));

    [Fact]
    public void TheAddressThatSignsABrowserInIsInNoTextTheRoomPrints()
    {
        var room = ShareGuestJson.Join(Doc("share-join-ready.json")).Room;
        Assert.False(string.IsNullOrEmpty(room.Url));
        Assert.DoesNotContain(room.Url!, room.ToString());
        Assert.DoesNotContain("signin", room.ToString());
        Assert.Contains("Test Room", room.ToString());
    }

    // --- what a person types ---

    [Theory]
    [InlineData("192.168.1.20", "192.168.1.20")]
    [InlineData("  10.0.0.7:9000 ", "10.0.0.7:9000")]
    [InlineData("100.64.1.2:8443", "100.64.1.2:8443")]
    public void AnAddressIsTheIpv4AddressOfARoomWithAnOptionalPort(string typed, string expected) => Assert.Equal(expected, ShareGuestText.Address(typed));

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("482913")]
    [InlineData("482 913")]
    [InlineData("room.example")]
    [InlineData("192.168.1")]
    [InlineData("192.168.1.256")]
    [InlineData("192.168.1.20:0")]
    [InlineData("192.168.1.20:70000")]
    [InlineData("192.168.1.20:80:90")]
    [InlineData("http://192.168.1.20")]
    [InlineData("benchbar://share/join?v=1&c=482913&a=192.168.1.20%3A8443")]
    [InlineData("192.168.1.20 --seat x")]
    [InlineData("-n")]
    public void AnythingElseIsNotAnAddressAndIsNeverAnArgument(string typed) => Assert.Null(ShareGuestText.Address(typed));

    [Theory]
    [InlineData("482913", "482913")]
    [InlineData(" 482 913 ", "482913")]
    [InlineData("48291", null)]
    [InlineData("4829135", null)]
    [InlineData("48x913", null)]
    [InlineData("", null)]
    public void ACodeIsSixDigitsWithOrWithoutTheSpace(string typed, string? expected) => Assert.Equal(expected, ShareGuestText.CodeDigits(typed));

    // --- the look ---

    [Fact]
    public async Task TheLookIsADryRunOfTheRoomAndSendsNoCode()
    {
        var (model, runner) = await LookedAt();
        Assert.Equal(["share", "join", Room, "--dry-run", "--json"], runner.Runs.Single().Args);
        Assert.Equal(("0", "gui"), (runner.Runs.Single().Env["BENCHBAR_NONINTERACTIVE"], runner.Runs.Single().Env["BENCHBAR_SUDO"]));
        Assert.Null(runner.Stdins.Single());
        Assert.Equal(RoomKey, model.Look!.HostKey);
        Assert.Null(model.LastError);
    }

    [Fact]
    public async Task AnAddressWithoutAPortIsLookedAtOnTheDefaultPort()
    {
        var (model, runner) = Rig();
        runner.On("share", "join").Print(Lines("share-join-look.json"));
        await model.LookAsync("192.168.1.20", TestContext.Current.CancellationToken);
        Assert.Equal("192.168.1.20:8443", runner.Runs.Single().Args[2]);
    }

    [Theory]
    [InlineData("482913")]
    [InlineData("482 913")]
    [InlineData("benchbar://share/join?v=1&c=482913&a=192.168.1.20%3A8443")]
    [InlineData("room.example")]
    public async Task ACodeOrALinkTypedAsTheAddressNeverReachesAProcess(string typed)
    {
        var (model, runner) = Rig();
        Assert.False(await model.LookAsync(typed, TestContext.Current.CancellationToken));
        Assert.Empty(runner.Runs);
        Assert.Equal(UiText.Get("GuestAddressInvalid"), model.LastError);
        Assert.Null(model.Look);
        Assert.DoesNotContain("482", model.LastError);
    }

    [Theory]
    [InlineData("share-join-not-local.stderr.txt", "8.8.8.8 is not an address of a local network, and a room is on the network this computer is on.")]
    [InlineData("share-join-unreachable.stderr.txt", "The room at 127.0.0.1:1 didn't answer.")]
    [InlineData("share-join-node-missing.stderr.txt", "Joining a room runs on Node 22 or later, and the one here cannot be used: there is no executable node at /nonexistent/node.")]
    public async Task ARefusedLookShowsTheSentenceOfTheCliNotAGenericOne(string stderrFixture, string sentence)
    {
        var (model, runner) = Rig();
        runner.On("share", "join").Fail(1, Stderr(stderrFixture));
        Assert.False(await model.LookAsync(Room, TestContext.Current.CancellationToken));
        Assert.Equal(sentence, model.LastError);
        Assert.Null(model.Look);
    }

    [Fact]
    public async Task TheLabBeingOffIsTheCliSentenceAndNotANeedForANewerCli()
    {
        var (model, runner) = Rig();
        runner.On("share", "join").Print(Lines("share-join-lab-off.json")).Fail(2);
        Assert.False(await model.LookAsync(Room, TestContext.Current.CancellationToken));
        Assert.Equal("benchbar share is an experiment and it is off.", model.LastError);
        Assert.DoesNotContain("newer", model.LastError!, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void TheSentenceOfARefusalIsTheFailLineEvenWhenTheRoomIsPrintedFirst()
    {
        // what the CLI wrote on stderr for a wrong code: the room, its address and key, then the sentence
        var lines = Lines("share-join-wrong-code.stderr.txt").Select(l => l.Trim()).ToArray();
        Assert.StartsWith("Room ", lines[0]);
        Assert.Equal("[FAIL] That code didn't work.", SystemStreamRunner.PickError(lines));
        Assert.Equal("That code didn't work.", ShareGuestText.Sentence(SystemStreamRunner.PickError(lines)));
        Assert.Equal("one", SystemStreamRunner.PickError(["one", "two"]));
        Assert.Null(SystemStreamRunner.PickError([]));
    }

    // --- the join ---

    [Fact]
    public async Task TheCodeIsTheFirstLineOfStdinAndInNoArgumentNoVariableAndNoText()
    {
        var (model, runner) = await LookedAt();
        runner.On(a => a.Contains("--no-open")).Print(Lines("share-join-waiting.json"));
        var code = Secret.From("482 913");
        Assert.True(await model.JoinAsync(code, ct: TestContext.Current.CancellationToken));

        var run = runner.Runs[1];
        Assert.Equal(["share", "join", Room, "--host-key", Pin, "--no-open", "--json"], run.Args);
        Assert.DoesNotContain(run.Args, a => a.Contains(Code)); // the pin is public; the code is not an argument
        Assert.Equal(Code, runner.Stdins[1]);
        Assert.Null(runner.Stdins[0]);
        Assert.DoesNotContain(run.Args, a => a.Contains(Code));
        Assert.DoesNotContain(run.Env, kv => kv.Value.Contains(Code) || kv.Key.Contains(Code));
        Assert.Equal(("0", "gui"), (run.Env["BENCHBAR_NONINTERACTIVE"], run.Env["BENCHBAR_SUDO"]));
        Assert.True(code.IsEmpty, "the code is disposed when the join ends");
        // nothing the model holds, prints or serialises has it
        var held = string.Join('|', JsonSerializer.Serialize(model.Rooms), JsonSerializer.Serialize(model.Look), model.Busy, model.LastError, model.Notice, model.ToString());
        Assert.DoesNotContain(Code, held);
        Assert.DoesNotContain("482 913", held);
    }

    [Fact]
    public async Task AJoinWhereTheHostGivesTheSeatsEndsWaitingAndSaysSo()
    {
        var (model, runner) = await LookedAt();
        runner.On(a => a.Contains("--no-open")).Print(Lines("share-join-waiting.json"));
        runner.On("share", "joined").Print(Lines("share-joined-waiting.json"));
        Assert.True(await model.JoinAsync(Secret.From(Code), ct: TestContext.Current.CancellationToken));
        Assert.Equal(UiText.Format("GuestJoinedWaiting", "Test Room", "Test Host"), model.Notice);
        Assert.Null(model.Look);
        Assert.Equal(GuestState.Waiting, Assert.Single(model.Rooms).State);
        Assert.Null(model.Busy);
        Assert.Equal(ShareGuestModel.JoinTimeout, TimeSpan.FromMinutes(12)); // the CLI's own wait is 10 minutes
    }

    [Fact]
    public async Task ARoomWithOpenSeatsEndsWithTheFreeSeatsToPickFrom()
    {
        var (model, runner) = await LookedAt();
        runner.On(a => a.Contains("--no-open")).Print(Lines("share-join-pick.json"));
        Assert.True(await model.JoinAsync(Secret.From(Code), ct: TestContext.Current.CancellationToken));
        Assert.Equal(UiText.Format("GuestJoinedPick", "Test Room"), model.Notice);
    }

    [Fact]
    public async Task TheSeatsOfAWaitingRoomSurviveTheListThatDoesNotCarryThem()
    {
        var (model, runner) = await LookedAt();
        var pick = ShareGuestJson.Join(Doc("share-join-pick.json")).Room;
        var listed = (JsonObject)Doc("share-joined-waiting.json").DeepClone(); // the same room as the list shows it: recorded in another run, so its id is set to the pick room's
        listed["rooms"]![0]!["id"] = pick.Id;
        runner.On(a => a.Contains("--no-open")).Print(Lines("share-join-pick.json"));
        runner.On("share", "joined").Print(listed.ToJsonString());
        await model.JoinAsync(Secret.From(Code), ct: TestContext.Current.CancellationToken);
        var room = Assert.Single(model.Rooms);
        Assert.Equal((false, 6), (room.HostAssigns, room.FreeSeats.Count)); // share joined has neither: they come from the join
        Assert.Equal(UiText.Get("GuestStatePick"), ShareGuestModel.StateText(room));
        await model.RefreshAsync(TestContext.Current.CancellationToken);
        Assert.Equal(6, Assert.Single(model.Rooms).FreeSeats.Count);
    }

    [Fact]
    public async Task ASeatIsTakenWithTheSeatFlagAndNoCode()
    {
        var (model, runner) = Rig();
        var room = ShareGuestJson.Join(Doc("share-join-pick.json")).Room;
        runner.On("share", "join").Print(Lines("share-join-ready.json"));
        runner.On("share", "joined").Print(Lines("share-joined-ready.json"));
        Assert.True(await model.TakeSeatAsync(room, "seat2", TestContext.Current.CancellationToken));
        Assert.Equal(["share", "join", room.Target, "--seat", "seat2", "--no-wait", "--no-open", "--json"], runner.Runs[0].Args);
        Assert.Null(runner.Stdins[0]);
        Assert.Equal(UiText.Format("GuestSeatTaken", "Test Room", "seat3@example.com"), model.Notice);
        Assert.False(await model.TakeSeatAsync(room, "seat 2; rm", TestContext.Current.CancellationToken));
        Assert.Equal(UiText.Get("GuestSeatInvalid"), model.LastError);
        Assert.Equal(2, runner.Runs.Count); // the refused id started nothing: the join and the list
    }

    [Fact]
    public async Task ARoomThatThisComputerIsInAlreadyNeedsNoCodeAndSendsNone()
    {
        var (model, runner) = await LookedAt("share-join-look-paired.json");
        runner.On(a => a.Contains("--no-open")).Print(Lines("share-join-ready.json"));
        Assert.True(await model.JoinAsync(null, ct: TestContext.Current.CancellationToken));
        Assert.Null(runner.Stdins[1]);
        Assert.Equal(UiText.Format("GuestJoinedReady", "Test Room", "seat3@example.com"), model.Notice);
    }

    [Fact]
    public async Task AWrongCodeShowsTheCliSentenceAndTheCodeIsGoneAnyway()
    {
        var (model, runner) = await LookedAt();
        runner.On(a => a.Contains("--no-open")).Fail(1, Stderr("share-join-wrong-code.stderr.txt"));
        runner.On("share", "joined").Print(Lines("share-joined-none.json"));
        var code = Secret.From("000000");
        Assert.False(await model.JoinAsync(code, ct: TestContext.Current.CancellationToken));
        Assert.Equal("That code didn't work.", model.LastError);
        Assert.True(code.IsEmpty);
        Assert.NotNull(model.Look); // the person types the code again without looking again
        Assert.Null(model.Busy);
    }

    [Fact]
    public async Task ALockedRoomIsRefusedBeforeAnythingIsSent()
    {
        var (model, runner) = Rig();
        var locked = (JsonObject)Doc("share-join-look.json").DeepClone();
        locked["locked"] = true;
        runner.On(a => a.Contains("--dry-run")).Print(locked.ToJsonString());
        Assert.True(await model.LookAsync(Room, TestContext.Current.CancellationToken));
        Assert.False(await model.JoinAsync(Secret.From(Code), ct: TestContext.Current.CancellationToken));
        Assert.Equal(UiText.Format("GuestLocked", "Test Host"), model.LastError);
        Assert.DoesNotContain(runner.Runs, r => r.Args.Contains("--no-open"));
        // the host's own refusal is worded the same way when the lock came after the look
        Assert.Equal("Test Host locked this room.", ShareGuestText.Sentence(Stderr("share-join-locked.stderr.txt")));
    }

    [Theory]
    [InlineData("")]
    [InlineData("12345")]
    [InlineData("12345a")]
    public async Task ACodeThatIsNotSixDigitsStartsNothing(string typed)
    {
        var (model, runner) = await LookedAt();
        Assert.False(await model.JoinAsync(Secret.From(typed), ct: TestContext.Current.CancellationToken));
        Assert.Equal(UiText.Get("GuestCodeInvalid"), model.LastError);
        Assert.Single(runner.Runs); // the look only
    }

    [Fact]
    public async Task NoJoinWithoutALook()
    {
        var (model, runner) = Rig();
        Assert.False(await model.JoinAsync(Secret.From(Code), ct: TestContext.Current.CancellationToken));
        Assert.Equal(UiText.Get("GuestLookFirst"), model.LastError);
        Assert.Empty(runner.Runs);
    }

    [Fact]
    public async Task AHostThatShowsAnotherKeyIsRefusedWithItsOwnSentenceAndTheCodeIsGone()
    {
        var (model, runner) = await LookedAt();
        runner.On(a => a.Contains("--no-open")).Fail(ShareGuestModel.HostKeyMismatchExit, Stderr("share-join-key-mismatch.stderr.txt"));
        runner.On("share", "joined").Print(Lines("share-joined-none.json"));
        var code = Secret.From(Code);
        Assert.False(await model.JoinAsync(code, ct: TestContext.Current.CancellationToken));
        Assert.Equal(UiText.Format("GuestKeyMismatch", "Test Host"), model.LastError);
        Assert.DoesNotContain("newer", model.LastError!, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("could not be joined", model.LastError!);
        Assert.Null(model.Look); // look again: the digits may be another host's
        Assert.True(code.IsEmpty);
        Assert.Equal(3, ShareGuestModel.HostKeyMismatchExit);
    }

    [Fact]
    public async Task AnExitOtherThanThreeIsNotTakenForAChangedKey()
    {
        var (model, runner) = await LookedAt();
        runner.On(a => a.Contains("--no-open")).Fail(1, Stderr("share-join-wrong-code.stderr.txt"));
        runner.On("share", "joined").Print(Lines("share-joined-none.json"));
        await model.JoinAsync(Secret.From("000000"), ct: TestContext.Current.CancellationToken);
        Assert.Equal("That code didn't work.", model.LastError);
        Assert.NotNull(model.Look);
    }

    [Fact]
    public async Task ACodeTheCliEchoesIsHiddenInWhatComesBack()
    {
        var (model, runner) = await LookedAt();
        runner.On(a => a.Contains("--no-open")).Fail(1, "[FAIL] the code " + Code + " was refused").Print("not json " + Code);
        runner.On("share", "joined").Print(Lines("share-joined-none.json"));
        Assert.False(await model.JoinAsync(Secret.From(Code), ct: TestContext.Current.CancellationToken));
        Assert.DoesNotContain(Code, model.LastError!);
        Assert.Contains("***", model.LastError!);
    }

    [Fact]
    public async Task CancellingTheWaitEndsTheCallAndKeepsThePlace()
    {
        var (model, runner) = await LookedAt();
        var wait = runner.On(a => a.Contains("--no-open")).Print().Hold();
        runner.On("share", "joined").Print(Lines("share-joined-waiting.json"));
        var code = Secret.From(Code);
        var join = model.JoinAsync(code, ct: TestContext.Current.CancellationToken);
        await wait.Started.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        Assert.True(model.CanCancel);
        Assert.NotNull(model.Busy);
        model.CancelJoin();
        Assert.False(await join);
        Assert.Equal(UiText.Get("GuestStopped"), model.LastError);
        Assert.False(model.CanCancel);
        Assert.Null(model.Busy);
        Assert.True(code.IsEmpty);
        Assert.Equal(GuestState.Waiting, Assert.Single(model.Rooms).State); // listed again, still waiting
    }

    [Fact]
    public async Task AnActionWaitsWhileAnotherRuns()
    {
        var (model, runner) = await LookedAt();
        var wait = runner.On(a => a.Contains("--no-open")).Print().Hold();
        runner.On("share", "joined").Print(Lines("share-joined-waiting.json"));
        var first = model.JoinAsync(Secret.From(Code), ct: TestContext.Current.CancellationToken);
        await wait.Started.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        var second = Secret.From(Code);
        Assert.False(await model.JoinAsync(second, ct: TestContext.Current.CancellationToken));
        Assert.Equal(2, runner.Runs.Count); // the look and the first join, not a second join
        Assert.True(second.IsEmpty);
        model.CancelJoin();
        await first;
    }

    // --- the rooms joined ---

    [Fact]
    public async Task TheRoomsAreListedWithJoinedAndNeedNoPersonOrBench()
    {
        var (model, runner) = Rig();
        runner.On("commands").Print(string.Join('\n', Lines("commands.json")).Replace("\"labs\": []", "\"labs\": [\"lan-rooms\"]").Replace("\"commands\": [", "\"commands\": [{\"name\":\"share join\",\"usage\":\"u\",\"summary\":\"s\",\"mutating\":true,\"flags\":[{\"name\":\"--host-key\",\"value\":\"HEX\",\"help\":\"h\"}]},"));
        runner.On("share", "joined").Print(Lines("share-joined-ready.json"));
        await model.CheckSupportAsync(TestContext.Current.CancellationToken);
        Assert.True(model.Supported);
        await model.RefreshAsync(TestContext.Current.CancellationToken);
        var room = Assert.Single(model.Rooms);
        Assert.Equal((RoomKey, GuestState.Ready, "seat3@example.com"), (room.Id, room.State, room.Seat));
        var run = runner.Runs.Single(r => r.Args[1] == "joined");
        Assert.Equal(["share", "joined", "--json"], run.Args);
        Assert.DoesNotContain("--bench-dir", run.Args);
        Assert.False(run.Env.ContainsKey("BENCHBAR_SUDO")); // a read, not a person's decision
    }

    [Fact]
    public async Task AShareJoinThatCannotPinTheKeyIsAnOlderCliAndHidesTheFeature()
    {
        // a CLI from before --host-key: the join is not offered, since the code would go to whatever answers at the address
        var (model, runner) = Rig();
        runner.On("commands").Print(string.Join(Environment.NewLine, Lines("commands.json")).Replace("\"labs\": []", "\"labs\": [\"lan-rooms\"]").Replace("\"commands\": [", "\"commands\": [{\"name\":\"share join\",\"usage\":\"u\",\"summary\":\"s\",\"mutating\":true,\"flags\":[{\"name\":\"--seat\",\"value\":\"ID\",\"help\":\"h\"}]},"));
        await model.CheckSupportAsync(TestContext.Current.CancellationToken);
        Assert.False(model.Supported);
    }

    [Fact]
    public async Task AnOlderCliWithoutShareJoinHidesTheFeatureAndAsksNothingElse()
    {
        var (model, runner) = Rig();
        runner.On("commands").Print(string.Join(Environment.NewLine, Lines("commands.json")).Replace("\"labs\": []", "\"labs\": [\"lan-rooms\"]")); // the lab is on and the recorded catalogue lists no share subcommand: an older CLI
        await model.CheckSupportAsync(TestContext.Current.CancellationToken);
        Assert.False(model.Supported);
        Assert.Equal(1, Asked(runner));

        var (silent, silentRunner) = Rig(); // no answer to commands at all
        await silent.CheckSupportAsync(TestContext.Current.CancellationToken);
        Assert.False(silent.Supported);
        Assert.Equal(1, Asked(silentRunner));
    }

    [Fact]
    public async Task LeaveAndForgetNameTheRoomByItsIdAndForgetSaysWhenTheHostWasNotTold()
    {
        var (model, runner) = Rig();
        var room = ShareGuestJson.Rooms(Doc("share-joined-ready.json")).Single();
        runner.On("share", "leave").Print(Lines("share-leave.json"));
        runner.On("share", "forget").Print(Lines("share-forget.json"));
        runner.On("share", "joined").Print(Lines("share-joined-none.json"));
        Assert.True(await model.LeaveAsync(room, TestContext.Current.CancellationToken));
        Assert.Equal(["share", "leave", RoomKey, "--json"], runner.Runs[0].Args);
        Assert.Equal(("0", "gui"), (runner.Runs[0].Env["BENCHBAR_NONINTERACTIVE"], runner.Runs[0].Env["BENCHBAR_SUDO"]));
        Assert.Equal(UiText.Format("GuestLeft", "Test Room"), model.Notice);
        Assert.True(await model.ForgetAsync(room, TestContext.Current.CancellationToken));
        Assert.Equal(["share", "forget", RoomKey, "--json"], runner.Runs.First(r => r.Args[1] == "forget").Args);
        Assert.StartsWith(UiText.Format("GuestForgot", "Test Room"), model.Notice);
        Assert.Contains(UiText.Format("GuestHostNotTold", "Test Host"), model.Notice); // share-forget.json: told_host false
        Assert.Empty(model.Rooms);
    }

    [Fact]
    public async Task ALeaveWhoseLocalAddressDidNotCloseSaysSo()
    {
        var (model, runner) = Rig();
        var room = ShareGuestJson.Rooms(Doc("share-joined-ready.json")).Single();
        Assert.True(Doc("share-leave.json")["forwarder_stopped"]!.GetValue<bool>()); // a fresh run: the field is there, and true
        var open = (JsonObject)Doc("share-leave.json").DeepClone();
        open["forwarder_stopped"] = false;
        runner.On("share", "leave").Print(open.ToJsonString());
        runner.On("share", "joined").Print(Lines("share-joined-none.json"));
        Assert.True(await model.LeaveAsync(room, TestContext.Current.CancellationToken));
        Assert.Equal(UiText.Format("GuestLeft", "Test Room") + " " + UiText.Format("GuestForwarderOpen", "Test Room"), model.Notice);
    }

    [Fact]
    public async Task ARoomIdThatIsNotSixteenHexDigitsIsNeverAnArgument()
    {
        var (model, runner) = Rig();
        var room = ShareGuestJson.Rooms(Doc("share-joined-ready.json")).Single() with { Id = "--yes" };
        Assert.False(await model.ForgetAsync(room, TestContext.Current.CancellationToken));
        Assert.Empty(runner.Runs);
    }

    [Fact]
    public async Task OpeningARoomGivesTheLocalAddressAndReopensAClosedOne()
    {
        var (model, runner) = Rig();
        var ready = ShareGuestJson.Rooms(Doc("share-joined-ready.json")).Single();
        Assert.Equal(ready.Url, await model.OpenUrlAsync(ready, TestContext.Current.CancellationToken));
        Assert.Empty(runner.Runs); // an open room needs no call

        var closed = ShareGuestJson.Rooms(Doc("share-joined-closed.json")).Single();
        runner.On("share", "join").Print(Lines("share-join-ready.json"));
        runner.On("share", "joined").Print(Lines("share-joined-ready.json"));
        var url = await model.OpenUrlAsync(closed, TestContext.Current.CancellationToken);
        Assert.Equal(ShareGuestJson.Join(Doc("share-join-ready.json")).Room.Url, url);
        Assert.Equal(["share", "join", closed.Target, "--no-wait", "--no-open", "--json"], runner.Runs[0].Args); // a listed room has no whole hash: the CLI uses the key it saved
        Assert.Null(runner.Stdins[0]);
    }

    [Fact]
    public async Task OnlyALocalhostAddressIsEverOpened()
    {
        var (model, _) = Rig();
        var room = ShareGuestJson.Rooms(Doc("share-joined-ready.json")).Single();
        foreach (var url in new[] { "https://evil.example/", "http://evil.example/", "http://192.168.1.20:8443/", "file:///c:/windows/system32/calc.exe", "http://test-room.localhost.evil.example/" })
            Assert.Null(await model.OpenUrlAsync(room with { Url = url }, TestContext.Current.CancellationToken));
        Assert.Equal(UiText.Get("GuestAddressNotLocal"), model.LastError);
        Assert.True(ShareGuestModel.IsLocalAddress("http://test-room-c85377aeab4f6a61.localhost:41732/_benchbar/signin?next=/app"));
    }

    [Fact]
    public void EveryStateHasASentenceWithTheHostNamedWhereItMatters()
    {
        var room = ShareGuestJson.Rooms(Doc("share-joined-ready.json")).Single();
        Assert.Equal("open, seat seat3@example.com", ShareGuestModel.StateText(room));
        Assert.Equal("Test Host removed this computer", ShareGuestModel.StateText(room with { State = GuestState.Removed }));
        Assert.Equal("no seat yet: Test Host has not given this computer one", ShareGuestModel.StateText(room with { State = GuestState.Waiting, HostAssigns = true }));
        Assert.Equal("no seat yet: pick one below", ShareGuestModel.StateText(room with { State = GuestState.Waiting, HostAssigns = false }));
        Assert.Equal(UiText.Get("GuestStateWaitingAny"), ShareGuestModel.StateText(room with { State = GuestState.Waiting, HostAssigns = null }));
        foreach (var state in Enum.GetValues<GuestState>())
            Assert.DoesNotMatch("^Guest[A-Z]", ShareGuestModel.StateText(room with { State = state })); // a missing entry would show as its own name
    }

    // --- what the CLI can do is asked once per CLI, not at every look at the tab ---

    internal static string Catalogue(string version, bool pin = true, bool lab = true)
    {
        var flags = pin ? "[{\"name\":\"--host-key\",\"value\":\"HEX\",\"help\":\"h\"}]" : "[]";
        return "{\"schema_version\":1,\"cli_version\":\"" + version + "\",\"labs\":" + (lab ? "[\"lan-rooms\"]" : "[]") + ",\"commands\":[{\"name\":\"share join\",\"usage\":\"u\",\"summary\":\"s\",\"mutating\":true,\"flags\":" + flags + "}]}";
    }

    internal static int Asked(ScriptedStreamRunner runner) => runner.Runs.Count(r => r.Args[0] == "commands");

    [Fact]
    public async Task TheCatalogueIsReadOnceForManyLooksAtTheTabAndManyModels()
    {
        var (client, runner) = Scripted();
        runner.On("commands").Print(Catalogue("0.9.0"));
        runner.On("share", "joined").Print(Lines("share-joined-none.json").Select(l => l.Replace("0.8.3", "0.9.0")).ToArray());
        var support = new CommandSupport(client);
        for (var look = 0; look < 3; look++)
        {
            var model = new ShareGuestModel(client, support); // a new view makes a new model each time the tab is shown
            await model.CheckSupportAsync(TestContext.Current.CancellationToken);
            Assert.True(model.Supported);
            await model.RefreshAsync(TestContext.Current.CancellationToken);
        }
        Assert.Equal(1, Asked(runner));
        Assert.Equal(3, runner.Runs.Count(r => r.Args[1] == "joined"));
    }

    [Fact]
    public async Task ACliWithoutThePinIsAskedOnceToo()
    {
        var (client, runner) = Scripted();
        runner.On("commands").Print(Catalogue("0.9.0", pin: false));
        var support = new CommandSupport(client);
        for (var look = 0; look < 3; look++)
        {
            var model = new ShareGuestModel(client, support);
            await model.CheckSupportAsync(TestContext.Current.CancellationToken);
            Assert.False(model.Supported);
        }
        Assert.Equal(1, Asked(runner));
    }

    [Fact]
    public async Task ACatalogueReadWhileTheLabWasOffIsReadAgainOnceAndThenKept()
    {
        var (client, runner) = Scripted();
        var first = 0;
        runner.On(a => a[0] == "commands" && first++ == 0).Print(Catalogue("0.9.0", lab: false)); // what the tray read at its start
        runner.On("commands").Print(Catalogue("0.9.0")); // the lab is on now
        var support = new CommandSupport(client);
        await support.GetAsync();
        var model = new ShareGuestModel(client, support);
        await model.CheckSupportAsync(TestContext.Current.CancellationToken);
        Assert.True(model.Supported);
        Assert.Equal(2, Asked(runner));
        await new ShareGuestModel(client, support).CheckSupportAsync(TestContext.Current.CancellationToken);
        Assert.Equal(2, Asked(runner)); // the catalogue with the lab on is kept
    }

    [Fact]
    public async Task ACliThatWasUpdatedIsAskedAgainAndTheFeatureFollowsIt()
    {
        var (client, runner) = Scripted();
        var first = 0;
        runner.On(a => a[0] == "commands" && first++ == 0).Print(Catalogue("0.9.0"));
        runner.On("commands").Print(Catalogue("0.9.1", pin: false)); // the CLI inside WSL was updated, and the new one has no --host-key
        runner.On("share", "joined").Print(Lines("share-joined-ready.json").Select(l => l.Replace("0.8.3", "0.9.1")).ToArray());
        var support = new CommandSupport(client);
        var model = new ShareGuestModel(client, support);
        await model.CheckSupportAsync(TestContext.Current.CancellationToken);
        Assert.True(model.Supported);
        Assert.Equal(1, Asked(runner));
        await model.RefreshAsync(TestContext.Current.CancellationToken); // the joined document says 0.9.1: the catalogue was read from 0.9.0
        Assert.Equal(2, Asked(runner));
        Assert.False(model.Supported);
        Assert.Empty(model.Rooms);
        await new ShareGuestModel(client, support).CheckSupportAsync(TestContext.Current.CancellationToken);
        Assert.Equal(2, Asked(runner)); // and 0.9.1 is remembered now
    }

    // --- the secret on stdin ---

    [Fact]
    public void AStdinSecretIsHiddenLikeAPasswordAndNamedNowhere()
    {
        using var line = Secret.From(Code);
        var env = new SecretEnvironment().Set("A", "b").Stdin(line);
        Assert.Equal(Code, env.MaterializeStdin());
        Assert.DoesNotContain(Code, env.ToString());
        Assert.Equal(["A"], env.Names);
        Assert.Equal(Code, Assert.Single(env.Secrets).Reveal());
        Assert.DoesNotContain(Code, string.Join('|', env.Materialize().Values));
        Assert.Equal("a ***", new Redactor(env.Secrets).Clean("a " + Code));
        Assert.Null(new SecretEnvironment().Stdin(Secret.Empty()).MaterializeStdin());
    }

    [Fact]
    public async Task TheClientHandsTheStdinLineToTheRunnerAndNothingElseSeesIt()
    {
        var (client, runner) = Scripted();
        runner.On("x").Print("{}");
        using var line = Secret.From(Code);
        await client.RunJsonAsync(["x"], new SecretEnvironment().Stdin(line), TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        await client.RunJsonAsync(["x"], null, TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        Assert.Equal([Code, null], runner.Stdins);
        Assert.DoesNotContain(Code, string.Join('|', runner.Runs.SelectMany(r => r.Args.Concat(r.Env.Values))));
    }
}
