using BenchBar.Tray.Core;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>Plans without a token, the ports plan as steps, the port check on every start path, and the demo mode's CLI.</summary>
public class IntegrationTests
{
    private static readonly TimeSpan Short = TimeSpan.FromSeconds(5);

    // --- plans with no token ---

    [Fact]
    public async Task APlanWithoutATokenConfirmsOnlyWhenTheRequestSaysSo()
    {
        foreach (var (requiresToken, expected) in new[] { (true, false), (false, true) })
        {
            var (client, runner) = CliFixture.Scripted();
            runner.On(a => a.Contains("--dry-run")).Print(CliFixture.Lines("service-plan.jsonl").Select(l => l.Replace("\"token\":\"bbbb2222\"", "\"token\":null")).ToArray());
            var request = new PlanReviewRequest("Set Up", ["adopt", "/b", "--dry-run", "--json"], _ => ["adopt", "/b", "--yes", "--json"]) { RequiresToken = requiresToken };
            var model = new PlanReviewModel(request, client);
            await model.LoadAsync(TestContext.Current.CancellationToken);
            Assert.Null(model.Plan!.Token);
            Assert.Equal(expected, model.CanConfirm);
        }
    }

    [Fact]
    public void TheAdoptRequestDoesNotNeedATokenAndStillAsksForSudo()
    {
        var request = DiscoveryModel.AdoptRequest("/home/a/b", "b");
        Assert.False(request.RequiresToken);
        Assert.True(request.UsesSudoEnv);
        Assert.True(PlanReviewRequest.Tokened("x", ["a"]).RequiresToken);
    }

    // --- ports plan as steps ---

    [Fact]
    public void ThePortsPlanEntriesBecomeStepsAndABlockedOneAnError()
    {
        var plan = PlanDocument.FromJson(CliFixture.Doc("scan-ports-plan.json"));
        Assert.Equal(["added-bench: set up the service files", "loose-bench: web port 8001 to 8002"], plan.Steps.Select(s => s.Name));
        Assert.All(plan.Steps, s => Assert.True(s.WillRun));
        Assert.Equal("8001 reserved by /home/akash/projects/added-bench", plan.Steps[1].Note);
        Assert.True(plan.HasChanges);
        Assert.Equal("aaaa1111", plan.Token);
        Assert.Empty(plan.Errors);

        var blocked = PlanDocument.FromJson(CliFixture.Doc("scan-ports-plan-blocked.json"));
        Assert.NotEmpty(blocked.Errors);
        Assert.False(blocked.CanApply);
    }

    // --- the port check on every start path ---

    private static (TrayController Controller, ScriptedSource Source, ScriptedStreamRunner Cli) Make(BenchState state)
    {
        var source = new ScriptedSource();
        source.States["a"] = state;
        var (client, runner) = CliFixture.Scripted();
        var options = new TrayOptions { ListenToSystemEvents = false, PortCheck = client };
        var controller = new TrayController(source, new FakeFrameClock(), new FakeHost(), new FakeTimeProvider(), options);
        return (controller, source, runner);
    }

    private static BenchStatus Bench(BenchState state) => new("a", "/a", state, null, "http://a.localhost:8000", "a.localhost");

    [Fact]
    public async Task AStartWithAPortConflictIsRefusedWithTheFixAndNothingRuns()
    {
        var (controller, source, cli) = Make(BenchState.Stopped);
        cli.On("ports", "check").Print(CliFixture.Lines("ports-check-conflict.json"));
        using var _ = controller;
        var result = await controller.StartStopAsync(Bench(BenchState.Stopped));
        Assert.False(result.Ok);
        Assert.StartsWith(PortGuard.ConflictLead, result.Message);
        Assert.DoesNotContain('\n', result.Message!);
        Assert.Contains("Open BenchBar, then Health", result.Message);
        Assert.Empty(source.Actions);
        Assert.Equal(["ports", "check", "--json", "--bench-dir", "/a"], cli.Runs.Single().Args);
    }

    [Fact]
    public async Task ARestartIsCheckedToo()
    {
        var (controller, source, cli) = Make(BenchState.Running);
        cli.On("ports", "check").Print(CliFixture.Lines("ports-check-conflict.json"));
        using var _ = controller;
        var result = await controller.RestartAsync(Bench(BenchState.Running));
        Assert.False(result.Ok);
        Assert.Empty(source.Actions);
    }

    [Fact]
    public async Task ACleanCheckStartsAndAStopIsNeverChecked()
    {
        var (controller, source, cli) = Make(BenchState.Stopped);
        cli.On("ports", "check").Print(CliFixture.Lines("ports-check-clean.json"));
        using var _ = controller;
        Assert.True((await controller.StartStopAsync(Bench(BenchState.Stopped))).Ok);
        Assert.True((await controller.StartStopAsync(Bench(BenchState.Running))).Ok);
        Assert.Equal(["up --bench-dir /a", "down --bench-dir /a"], source.Actions);
        Assert.Single(cli.Runs); // only the start asked
    }

    [Fact]
    public async Task ACheckThatCannotRunRefusesAndACallerThatCheckedItselfSkipsIt()
    {
        var (controller, source, cli) = Make(BenchState.Stopped);
        using var _ = controller; // no scripted reply: the check fails
        var refused = await controller.StartStopAsync(Bench(BenchState.Stopped));
        Assert.False(refused.Ok);
        Assert.Contains("could not be checked", refused.Message);
        Assert.Empty(source.Actions);

        var again = await controller.StartStopAsync(Bench(BenchState.Stopped), checkPorts: false);
        Assert.True(again.Ok);
        Assert.Single(cli.Runs);
    }

    // --- the demo mode's CLI ---

    [Fact]
    public async Task TheDemoCliAnswersReadOnlyCallsFromRecordedFilesAndRefusesTheRest()
    {
        var client = new CliClient(new FixtureCliRunner(FixtureDir("rest")), () => "benchbar.exe");
        var check = await client.RunJsonAsync(PortArgs.Check("/b"), null, Short, PortsJson.ParseCheck, TestContext.Current.CancellationToken);
        Assert.True(check.Ok);
        var apply = await client.RunStreamAsync(["site", "add", "x", "--apply", "t", "--yes"], null, Short, _ => { }, TestContext.Current.CancellationToken);
        Assert.False(apply.Ok);
        Assert.Equal(FixtureCliRunner.Refusal, apply.Problem);
        var unknown = await client.RunJsonAsync(["nothing", "--json"], null, Short, TestContext.Current.CancellationToken);
        Assert.Equal(FixtureCliRunner.Refusal, unknown.Error);
    }

    private static string FixtureDir(string name) => BenchBar.Tray.TestSupport.FixtureFiles.Dir(name);
}
