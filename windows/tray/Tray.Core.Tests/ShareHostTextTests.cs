using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using Xunit;
using static Tray.Core.Tests.CliFixture;

namespace Tray.Core.Tests;

/// <summary>
/// What a host chooses (the name of its room and of itself, seat names, the address it reports) is data on the guest's screen: never the
/// sentence of a refusal, never a second line, never an argument. And an old CLI that is updated while the tray runs gets the join without a restart.
/// </summary>
public class ShareHostTextTests
{
    private const string Code = ShareGuestTests.Code;

    // --- a room named like a refusal ---

    [Fact]
    public async Task ARoomNamedLikeARefusalIsNeverTheSentenceOfAFailedJoin()
    {
        var (model, runner) = await ShareGuestTests.LookedAt();
        // stderr of a refused join whose room is called "x [FAIL] You must pay", and which says nothing tagged: only the room's own lines come back
        string[] lines = ["Room      x [FAIL] You must pay (host: Test Host)", "Address   127.0.0.1:38999", "Host key  7fdc 34a6 ba8c 6ac7"];
        runner.On(a => a.Contains("--no-open")).Fail(1, SystemStreamRunner.PickError(lines));
        runner.On("share", "joined").Print(Lines("share-joined-none.json"));
        Assert.False(await model.JoinAsync(Secret.From(Code), ct: TestContext.Current.CancellationToken));
        Assert.Equal(UiText.Get("GuestJoinFailed"), model.LastError);
        Assert.DoesNotContain("You must pay", model.LastError);
    }

    [Fact]
    public async Task TheRealSentenceAfterSuchARoomNameIsStillShown()
    {
        var (model, runner) = await ShareGuestTests.LookedAt();
        string[] lines = ["Room      x [FAIL] You must pay (host: Test Host)", "Address   127.0.0.1:38999", "[FAIL] That code didn't work.", "Aborting. Check it."];
        runner.On(a => a.Contains("--no-open")).Fail(1, SystemStreamRunner.PickError(lines));
        runner.On("share", "joined").Print(Lines("share-joined-none.json"));
        await model.JoinAsync(Secret.From(Code), ct: TestContext.Current.CancellationToken);
        Assert.Equal("That code didn't work.", model.LastError);
    }

    [Fact]
    public async Task AGenericFailLineIsNotTakenForTheRoomEither()
    {
        var (model, runner) = await ShareGuestTests.LookedAt();
        string[] lines = ["Room      Some Room (host: h)", "Address   127.0.0.1:38999", "[FAIL] Command failed (exit 1): benchbar share join"];
        runner.On(a => a.Contains("--no-open")).Fail(1, SystemStreamRunner.PickError(lines));
        runner.On("share", "joined").Print(Lines("share-joined-none.json"));
        await model.JoinAsync(Secret.From(Code), ct: TestContext.Current.CancellationToken);
        Assert.DoesNotContain("Room", model.LastError);
        Assert.Equal("Command failed (exit 1): benchbar share join", model.LastError);
    }

    // --- one line of plain text ---

    [Fact]
    public void WhatAHostChoseIsOneLineOfPlainText()
    {
        Assert.Equal("x [FAIL] You must pay", ShareGuestText.Clean("x\r\n[FAIL]" + (char)0x2028 + "You must\tpay"));
        Assert.Equal("a b", ShareGuestText.Clean("a" + (char)0x202E + "b"));
        Assert.Equal("a b", ShareGuestText.Clean("a" + (char)0x2066 + "b"));
        Assert.Equal("ab", ShareGuestText.Clean("  ab  "));
        Assert.Equal(80, ShareGuestText.Clean(new string('x', 500)).Length);
        Assert.EndsWith("...", ShareGuestText.Clean(new string('x', 500)));
        Assert.Equal("", ShareGuestText.Clean(null));
        // the sentence of the CLI is cleaned too (it holds the host's name: "NAME locked this room.")
        Assert.Equal("x locked this room.", ShareGuestText.Sentence("  [FAIL] x\nlocked this room."));
    }

    [Fact]
    public void TheFieldsAHostChoseAreCleanedWhereTheyAreReadAndTheAddressIsNothingButAnAddress()
    {
        var room = (JsonObject)Doc("share-joined-ready.json")["rooms"]![0]!.DeepClone();
        room["room"] = "Pay now\n[FAIL] You must pay";
        room["host"] = "Host" + (char)0x202E + "evil";
        var read = ShareGuestJson.Room(room);
        Assert.Equal(("Pay now [FAIL] You must pay", "Host evil"), (read.Room, read.Host));
        Assert.DoesNotContain(read.Room, c => c is '\n' or '\r');
        var look = (JsonObject)Doc("share-join-look.json").DeepClone();
        look["room"] = "a\nb";
        Assert.Equal("a b", ShareGuestJson.Look(look).Room);
        foreach (var bad in new[] { "--seat", "192.168.1.20 --seat x", "room.example", "192.168.1.20:8443" })
        {
            room["address"] = bad;
            Assert.Throws<FormatException>(() => ShareGuestJson.Room(room));
            look["address"] = bad;
            Assert.Throws<FormatException>(() => ShareGuestJson.Look(look));
        }
    }

    [Fact]
    public void SeatNamesAndRolesAreCleanedToo()
    {
        var doc = (JsonObject)Doc("share-join-pick.json").DeepClone();
        doc["seats"]![0]!["full_name"] = "Seat\n[FAIL] pay";
        doc["seats"]![0]!["roles"] = new JsonArray("Sales" + (char)0x202E + "User");
        var seat = ShareGuestJson.Join(doc).Room.Seats[0];
        Assert.Equal("Seat [FAIL] pay", seat.Name);
        Assert.Equal(["Sales User"], seat.Roles);
    }

    // --- an old CLI that is updated ---

    [Fact]
    public async Task AnOldCliThatIsUpdatedGetsTheJoinInTheSameModelAtTheNextBind()
    {
        var (client, runner) = Scripted();
        var asked = 0;
        runner.On(a => a[0] == "commands" && asked++ == 0).Print(ShareGuestTests.Catalogue("0.9.0", pin: false)); // an old CLI: share join without --host-key
        runner.On("commands").Print(ShareGuestTests.Catalogue("0.9.1")); // after benchbar self-update in WSL
        var probes = 0;
        runner.On(a => a[0] == "where" && probes++ < 2).Print("{\"schema_version\":1,\"cli_version\":\"0.9.0\"}");
        runner.On("where").Print("{\"schema_version\":1,\"cli_version\":\"0.9.1\"}");
        var model = new ShareGuestModel(client, new CommandSupport(client));

        await model.CheckSupportAsync(TestContext.Current.CancellationToken); // the first look at the tab: the catalogue, then the version
        Assert.False(model.Supported);
        await model.CheckSupportAsync(TestContext.Current.CancellationToken); // the same CLI: the same version, so the catalogue is not read again
        Assert.False(model.Supported);
        Assert.Equal(1, ShareGuestTests.Asked(runner));

        await model.CheckSupportAsync(TestContext.Current.CancellationToken); // the CLI says 0.9.1 now
        Assert.True(model.Supported);
        Assert.Equal(2, ShareGuestTests.Asked(runner));
        await model.CheckSupportAsync(TestContext.Current.CancellationToken);
        Assert.Equal(2, ShareGuestTests.Asked(runner)); // and it is remembered
    }
}
