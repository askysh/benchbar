using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>The result envelope (docs/json-schema.md): one decoder for the done line of a stream, the document of a command that changed things and the document of a read.</summary>
public class ResultEnvelopeTests
{
    private static readonly TimeSpan Short = TimeSpan.FromSeconds(5);

    [Fact]
    public void ADoneLineReadsEveryField()
    {
        var e = ResultEnvelope.Last(CliFixture.Lines("envelope-site-backup.jsonl"))!;
        Assert.True(e.Succeeded);
        Assert.Equal(1, e.SchemaVersion);
        Assert.Equal("0.9.0", e.CliVersion);
        Assert.Equal("op-20261119-101500-4242", e.OpId);
        Assert.Null(e.Error);
        Assert.Equal([new CliChange("backup", "acme.localhost", "3 files"), new CliChange("site", "acme.localhost", null)], e.Changed);
        Assert.Equal(["Disk is 91% full"], e.Warnings);
        Assert.Equal([new CliNextAction("benchbar site restore acme.localhost --dry-run --json", "Try the backup in a copy", true),
            new CliNextAction("benchbar site backups acme.localhost", null)], e.NextActions);
        Assert.EndsWith("1.log", e.Log);
    }

    [Fact]
    public async Task AStreamResultCarriesTheEnvelopeFields()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("site", "backup").Print(CliFixture.Lines("envelope-site-backup.jsonl"));
        var result = await client.RunStreamAsync(["site", "backup", "--jsonl"], null, Short, _ => { }, TestContext.Current.CancellationToken);
        Assert.True(result.Ok);
        Assert.Equal("op-20261119-101500-4242", result.Done!.OpId);
        Assert.Equal("0.9.0", result.Done.CliVersion);
        Assert.True(result.Done.NextActions[0].Quoted);
        Assert.False(result.Done.NextActions[1].Quoted);
    }

    [Fact]
    public void AUsageErrorShowsTheErrorAndTheHint()
    {
        var done = CliJson.FindDone(CliFixture.Lines("envelope-usage-error.jsonl"))!;
        Assert.Equal(64, done.Exit);
        Assert.Equal("unknown_flag", done.ErrorId);
        Assert.Equal("Unknown option for install: --bogus", done.Problem);
        Assert.Equal("Unknown option for install: --bogus. Usage: benchbar install [--yes] [--json]. Every flag: benchbar install --help", done.Explained);
    }

    [Fact]
    public void AHintThatTheErrorAlreadySaysIsNotRepeated()
    {
        Assert.Equal("Run it on a Mac.", ResultEnvelope.Explain("Run it on a Mac.", "Run it on a Mac."));
        Assert.Equal("Only a fix.", ResultEnvelope.Explain(null, "Only a fix."));
        Assert.Null(ResultEnvelope.Explain("", " "));
    }

    [Fact]
    public async Task ARefusalOfTheRunAllowListKeepsItsErrorAndItsOwnFields()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("run").Print(CliFixture.Lines("envelope-run-refused.jsonl")).Fail(64);
        var result = await client.RunStreamAsync(["run", "bogus", "--jsonl"], null, Short, _ => { }, TestContext.Current.CancellationToken);
        Assert.False(result.Ok);
        Assert.Equal(64, result.Exit);
        Assert.Equal("benchbar run does not run 'bogus': it is not on the allow list.", result.Problem);
        Assert.True(result.Done!.Raw["refused"]!.GetValue<bool>());
    }

    [Fact]
    public async Task AReadThatFailedPrintsAnEnvelopeWithNextActions()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("site", "list").Print(CliFixture.Lines("envelope-read-failure-next.json")).Fail(1);
        var result = await client.RunJsonAsync(["site", "list", "--for-agent"], null, Short, TestContext.Current.CancellationToken);
        Assert.False(result.Ok);
        Assert.Equal(1, result.Exit);
        Assert.Equal("No bench at /home/me/missing.", result.Done!.Error);
        Assert.Equal("Run benchbar adopt PATH to register one.", result.Done.Fix);
        var next = Assert.Single(result.Done.NextActions);
        Assert.Equal("benchbar adopt /home/me/frappe-bench", next.Command);
        Assert.True(next.Quoted);
    }

    [Fact]
    public void AnUnknownExtraFieldAndAFieldOfAnotherTypeCostOnlyThatField()
    {
        var e = ResultEnvelope.Last(CliFixture.Lines("envelope-newer-extras.jsonl"))!;
        Assert.Equal(1, e.Exit);
        Assert.Equal("Something broke.", e.Error);
        Assert.Null(e.OpId);
        Assert.Empty(e.Warnings);
        Assert.Empty(e.Changed);
        Assert.Equal(["--yes"], e.Missing);
        Assert.Equal([new CliNextAction("benchbar doctor", null), new CliNextAction("benchbar repair --dry-run", "See the plan")], e.NextActions);
    }

    [Fact]
    public void AMissingOptionalFieldIsEmptyNotAnError()
    {
        var e = ResultEnvelope.From((JsonObject)JsonNode.Parse("""{"exit":0}""")!)!;
        Assert.Null(e.SchemaVersion);
        Assert.Null(e.CliVersion);
        Assert.Null(e.OpId);
        Assert.Null(e.Error);
        Assert.Null(e.Problem);
        Assert.Empty(e.Changed);
        Assert.Empty(e.Warnings);
        Assert.Empty(e.NextActions);
        Assert.Empty(e.Missing);
        Assert.Null(e.StateAfter);
    }

    [Fact]
    public void NoLineWithAnExitIsNoEnvelopeAndTextAfterTheDocumentDoesNotHideIt()
    {
        Assert.Null(ResultEnvelope.Last([]));
        Assert.Null(ResultEnvelope.Last(["[OK] fine", "not json", """{"event":"step","id":"a"}"""]));
        Assert.Equal(0, ResultEnvelope.Last(["""{"exit":0}""", "[OK] later"])!.Exit);
        Assert.Equal(3, ResultEnvelope.From((JsonObject)JsonNode.Parse("""{"exit_code":3}""")!)!.Exit);
    }

    [Fact]
    public void ADocumentOfAReadWithExitIsAnEnvelopeToo()
    {
        var e = ResultEnvelope.Last(["""{"schema_version":1,"cli_version":"0.9.0","labs":[],"exit":0}"""])!;
        Assert.True(e.Succeeded);
        Assert.Empty(e.NextActions);
    }

    [Fact]
    public void AStreamedPullKeepsItsChangedList()
    {
        var e = ResultEnvelope.Last(CliFixture.Lines("envelope-pull-done.jsonl"))!;
        Assert.Equal(0, e.Exit);
        Assert.Equal(new CliChange("site", "erpdl", "restored from a backup set"), Assert.Single(e.Changed));
        Assert.NotNull(e.StateAfter);
    }

    [Fact]
    public void ARefusalShowsTheHintBesideTheErrorInTheResultModel()
    {
        var done = CliJson.FindDone(CliFixture.Lines("envelope-usage-error.jsonl"));
        var model = PlanResultModel.From(new CliStreamResult(64, done, null, false, []));
        Assert.Equal("Unknown option for install: --bogus", model.Error);
        Assert.StartsWith("Usage: benchbar install", model.Hint);
        var plain = PlanResultModel.From(new CliStreamResult(1, CliJson.FindDone(CliFixture.Lines("sudo-wrong.jsonl")), null, false, []));
        Assert.Null(plain.Hint);
    }
}
