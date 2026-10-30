using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>Reads the files in fixtures/cli (recorded shapes of docs/json-schema.md). Add a file there for a new command and use it here.</summary>
internal static class CliFixture
{
    public static JsonObject Doc(string name) => (JsonObject)JsonNode.Parse(string.Join(Environment.NewLine, Lines(name)))!;

    public static string[] Lines(string name) =>
        BenchBar.Tray.TestSupport.FixtureFiles.CliLines(name);

    public static (CliClient Client, ScriptedStreamRunner Runner) Scripted()
    {
        var runner = new ScriptedStreamRunner();
        return (new CliClient(runner, () => @"C:\bb\benchbar.exe"), runner);
    }
}

public class CliClientTests
{
    private static readonly TimeSpan Short = TimeSpan.FromSeconds(5);

    [Fact]
    public async Task OneDocumentIsParsedByThePagesParser()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("site", "add").Print(CliFixture.Lines("site-add-plan.json"));
        var result = await client.RunJsonAsync(["site", "add", "qa1.localhost", "--dry-run", "--json"], null, Short, PlanDocument.FromJson, TestContext.Current.CancellationToken);
        Assert.True(result.Ok);
        Assert.Equal(["Create qa1.localhost", "Install erpnext"], result.Value!.Steps.Select(s => s.Name));
        Assert.StartsWith("3f9c0e", result.Value.Token);
        Assert.Equal(["site", "add", "qa1.localhost", "--dry-run", "--json"], runner.Runs.Single().Args);
    }

    [Fact]
    public async Task DoneFieldsOfADocumentComeBackWithIt()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("site", "backup").Print(CliFixture.Lines("doc-with-done.json"));
        var result = await client.RunJsonAsync(["site", "backup", "--json"], null, Short, TestContext.Current.CancellationToken);
        Assert.True(result.Ok);
        var done = result.Done!;
        Assert.Equal(0, done.Exit);
        Assert.Equal("backup", done.Changed.Single().Kind);
        Assert.Equal("/tmp/b.sql.gz", result.Value!["path"]!.GetValue<string>());
    }

    [Fact]
    public async Task AFailureWithNothingOnStdoutIsTheFirstStderrLine()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("site", "list").Fail(1, "No bench found. Run: benchbar adopt PATH");
        var result = await client.RunJsonAsync(["site", "list", "--json"], null, Short, TestContext.Current.CancellationToken);
        Assert.False(result.Ok);
        Assert.Equal(1, result.Exit);
        Assert.Null(result.Value);
        Assert.Equal("No bench found. Run: benchbar adopt PATH", result.Error);
    }

    [Fact]
    public async Task ARefusalOfTheNonInteractiveModeNamesWhatIsMissing()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("install").Print(CliFixture.Lines("refusal.jsonl")).Fail(1);
        var result = await client.RunJsonAsync(["install", "--json"], null, Short, TestContext.Current.CancellationToken);
        Assert.False(result.Ok);
        Assert.Equal(["ADMIN_PASSWORD", "--yes"], result.Done!.Missing);
        Assert.Equal("Missing inputs for the non interactive mode.", result.Error);
    }

    [Fact]
    public async Task AServicePlanStreamYieldsItsPlanLine()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("service").Print(CliFixture.Lines("service-plan.jsonl"));
        var result = await client.RunJsonAsync(["service", "--dry-run", "--json"], null, Short, PlanDocument.FromJson, TestContext.Current.CancellationToken);
        Assert.True(result.Ok);
        Assert.Equal(1, result.Value!.SudoSteps);
        Assert.Equal("bbbb2222", result.Value.Token);
    }

    [Fact]
    public async Task AParserThatRefusesTheDocumentIsAFailureNotAThrow()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("site").Print("{\"sites\":1}");
        var result = await client.RunJsonAsync<int>(["site", "list", "--json"], null, Short, _ => throw new FormatException("sites is not a list"), TestContext.Current.CancellationToken);
        Assert.False(result.Ok);
        Assert.Equal("sites is not a list", result.Error);
    }

    [Fact]
    public async Task ANewerSchemaIsRefusedWithTheUpdateLine()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("site").Print("{\"schema_version\":9}");
        var result = await client.RunJsonAsync(["site", "list", "--json"], null, Short, TestContext.Current.CancellationToken);
        Assert.False(result.Ok);
        Assert.Contains("Update BenchBar", result.Error);
    }

    [Fact]
    public async Task APasswordInTheEnvironmentReachesTheChildAndIsHiddenInWhatItPrintsBack()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("x").Print("{\"echo\":\"hunter2-pass\"}").Fail(1, "bad hunter2-pass");
        var env = new SecretEnvironment().Set("ADMIN_PASSWORD", Secret.From("hunter2-pass"));
        var result = await client.RunJsonAsync(["x", "--json"], env, Short, TestContext.Current.CancellationToken);
        Assert.Equal("hunter2-pass", runner.Runs.Single().Env["ADMIN_PASSWORD"]);
        Assert.DoesNotContain("hunter2-pass", result.Error);
        Assert.DoesNotContain("hunter2-pass", result.Value!.ToJsonString());
        Assert.DoesNotContain(runner.Runs.Single().Args, a => a.Contains("hunter2"));
    }

    [Fact]
    public async Task AMissingShimIsAFailureWithItsOwnMessage()
    {
        var client = new CliClient(new ScriptedStreamRunner(), () => null);
        var json = await client.RunJsonAsync(["status", "--json"], null, Short, TestContext.Current.CancellationToken);
        var stream = await client.RunStreamAsync(["up", "--json"], null, Short, _ => { }, TestContext.Current.CancellationToken);
        Assert.False(json.Ok);
        Assert.Equal(ShimBenchSource.NotFoundMessage, json.Error);
        Assert.Equal(1, stream.Exit);
        Assert.Equal(ShimBenchSource.NotFoundMessage, stream.Problem);
    }

    [Fact]
    public async Task AStreamHandsOverEveryLineAndEndsWithTheDoneFields()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("site", "add").Print(CliFixture.Lines("site-add-apply.jsonl"));
        var events = new List<CliEvent>();
        var result = await client.RunStreamAsync(["site", "add", "qa1.localhost", "--apply", "t", "--yes", "--jsonl"], null, Short, events.Add, TestContext.Current.CancellationToken);
        Assert.True(result.Ok);
        Assert.Equal(["Step", "Step", "Progress", "Step", "Done"], events.Select(e => e.GetType().Name));
        var done = result.Done!;
        Assert.Equal(["site", "app"], done.Changed.Select(c => c.Kind));
        Assert.Equal("Redis cache was slow to answer.", done.Warnings.Single());
        Assert.Equal("benchbar site default qa1.localhost", done.NextActions.Single().Command);
        Assert.Equal("running", done.StateAfter!["state"]!.GetValue<string>());
        Assert.Equal("qa1.localhost", done.Raw["site"]!.GetValue<string>());
    }

    [Fact]
    public async Task AStreamExitComesFromTheDoneLineAndErrorIdIsKept()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("up").Print(CliFixture.Lines("sudo-wrong.jsonl")).Fail(1);
        var result = await client.RunStreamAsync(["up", "--json"], null, Short, _ => { }, TestContext.Current.CancellationToken);
        Assert.False(result.Ok);
        Assert.True(result.Done!.WrongSudoPassword);
        Assert.Equal("sudo did not accept the password.", result.Problem);
    }

    [Fact]
    public async Task ALineThatIsNotJsonIsKeptAsText()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("ports", "apply").Print(CliFixture.Lines("ports-apply.txt"));
        var events = new List<CliEvent>();
        var result = await client.RunStreamAsync(["ports", "apply", "T", "--yes"], null, Short, events.Add, TestContext.Current.CancellationToken);
        Assert.True(result.Ok);
        Assert.Null(result.Done);
        Assert.Equal(["Applying /home/akash/b1", "Completed /home/akash/b1"], result.TextLines);
        Assert.All(events, e => Assert.IsType<CliEvent.Text>(e));
    }

    [Fact]
    public async Task CancellingAStreamKillsItAndReportsCancelled()
    {
        var (client, runner) = CliFixture.Scripted();
        var reply = runner.On("site", "add").Hold();
        using var cts = new CancellationTokenSource();
        var task = client.RunStreamAsync(["site", "add", "--jsonl"], null, TimeSpan.FromMinutes(1), _ => { }, cts.Token);
        await reply.Started.Task;
        await cts.CancelAsync();
        var result = await task;
        Assert.True(result.Cancelled);
        Assert.False(result.Ok);
    }

    [Fact]
    public void ADoneLineWithoutExitIsNotADone()
    {
        Assert.Null(CliJson.ParseDone((JsonObject)JsonNode.Parse("{\"event\":\"done\"}")!));
        var plain = CliJson.ParseDone((JsonObject)JsonNode.Parse("{\"exit_code\":0,\"next_actions\":[\"benchbar up\"]}")!)!;
        Assert.Equal("benchbar up", plain.NextActions.Single().Command);
    }
}
