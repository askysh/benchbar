using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>The done lines of the setup and install streams, and the site move plan's next_actions, read through the one envelope decoder (and without it when the line has no usable exit).</summary>
public class DoneParsersTests
{
    private static SetupEvent.Done SetupDone(string line) => Assert.IsType<SetupEvent.Done>(SetupJson.ParseLine(line));

    private static InstallDone InstallDoneOf(string line) => Assert.IsType<InstallEvent.Done>(InstallJson.ParseLine(line)).Value;

    [Fact]
    public void ASetupDoneLineReadsTheEnvelope()
    {
        var d = SetupDone("""{"schema_version":1,"event":"done","exit":0,"changed":true,"warnings":["w"],"next_actions":[{"command":"benchbar doctor","why":"x"},"benchbar up"],"error_id":"e1"}""");
        Assert.Equal(0, d.Exit);
        Assert.Equal(["w"], d.Warnings);
        Assert.Equal(["benchbar doctor", "benchbar up"], d.NextActions);
        Assert.Equal("e1", d.ErrorId);
    }

    [Theory]
    [InlineData("""{"event":"done","warnings":["w"],"next_actions":["benchbar doctor"],"error_id":"e1"}""")]
    [InlineData("""{"event":"done","exit":"1","warnings":["w"],"next_actions":["benchbar doctor"],"error_id":"e1"}""")]
    public void ASetupDoneLineWithoutAUsableExitKeepsWarningsNextActionsAndErrorId(string line)
    {
        var d = SetupDone(line);
        Assert.Equal(1, d.Exit);
        Assert.Equal(["w"], d.Warnings);
        Assert.Equal(["benchbar doctor"], d.NextActions);
        Assert.Equal("e1", d.ErrorId);
    }

    [Fact]
    public void AnInstallDoneLineReadsTheEnvelopeAndFallsBackWithoutAnExit()
    {
        var d = InstallDoneOf("""{"event":"done","exit":1,"error":"apt failed","fix":"sudo apt update","error_id":"sudo_password_wrong","log":"/l"}""");
        Assert.Equal((1, "apt failed", "sudo apt update", "sudo_password_wrong", "/l"), (d.Exit, d.Error, d.Fix, d.ErrorId, d.Log));
        var bare = InstallDoneOf("""{"event":"done","error":"apt failed","fix":"f","code":"c","log":"/l"}""");
        Assert.Equal((1, "apt failed", "f", "c", "/l"), (bare.Exit, bare.Error, bare.Fix, bare.ErrorId, bare.Log));
    }

    [Fact]
    public void ASiteMovePlanReadsBareStringAndObjectNextActions()
    {
        var plan = PlanDocument.FromJson((JsonObject)JsonNode.Parse("""{"steps":[],"next_actions":["benchbar down --bench-dir /x",{"command":"benchbar doctor","why":"look","quoted":true},{"why":"no command"}]}""")!);
        var next = SiteMoveJson.Read(plan).NextActions;
        Assert.Equal([new CliNextAction("benchbar down --bench-dir /x", null), new CliNextAction("benchbar doctor", "look", true)], next);
        Assert.True(SiteMoveRules.NeedsStop(plan));
    }

    [Fact]
    public void TheShownErrorAndHintAreOneCleanLine()
    {
        var evil = "pull failed\r\n[OK] all fine" + (char)0x202E + " from host\u0007";
        var done = CliJson.ParseDone((JsonObject)JsonNode.Parse("{\"exit\":1,\"error\":" + System.Text.Json.JsonSerializer.Serialize(evil) + ",\"fix\":" + System.Text.Json.JsonSerializer.Serialize("ssh said:\nrun this" + new string('x', 600)) + "}")!)!;
        Assert.DoesNotContain('\n', done.Explained!);
        Assert.DoesNotContain((char)0x202E, done.Explained!);
        Assert.DoesNotContain('\u0007', done.Explained!);
        Assert.StartsWith("pull failed [OK] all fine from host.", done.Explained);
        Assert.True(done.Explained!.Length <= 810);
        var model = PlanResultModel.From(new CliStreamResult(1, done, null, false, []));
        Assert.DoesNotContain('\n', model.Error!);
        Assert.DoesNotContain('\n', model.Hint!);
        Assert.DoesNotContain((char)0x202E, model.Error!);
        Assert.True(model.Hint!.Length <= 400);
    }
}
