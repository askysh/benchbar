using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

public class ActionResultTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static (ShimBenchSource Source, FakeProcessRunner Runner) Make()
    {
        var runner = new FakeProcessRunner();
        return (new ShimBenchSource(runner, () => @"C:\bin\benchbar.exe"), runner);
    }

    [Fact]
    public async Task ASuccessHasNoMessage()
    {
        var (source, runner) = Make();
        runner.Answer = (_, _) => new ProcessResult(0, "started", "noise on stderr");
        var result = await source.RunAsync(["up", "--bench-dir", "/b"], Ct);
        Assert.True(result.Ok);
        Assert.Null(result.Message);
    }

    [Fact]
    public async Task AFailureCarriesTheFirstNonBlankLineOfStderr()
    {
        var (source, runner) = Make();
        runner.Answer = (_, _) => new ProcessResult(1, "", "\r\nPort 8000 is held by another bench. Run: benchbar ports setup\nsecond line");
        var result = await source.RunAsync(["up", "--bench-dir", "/b"], Ct);
        Assert.False(result.Ok);
        Assert.Equal(1, result.ExitCode);
        Assert.Equal("Port 8000 is held by another bench. Run: benchbar ports setup", result.Message);
    }

    [Fact]
    public async Task AFailureWithOnlyStdoutUsesThatAndWithNothingUsesTheExitCode()
    {
        var (source, runner) = Make();
        runner.Answer = (_, _) => new ProcessResult(2, "refused: x", "");
        Assert.Equal("refused: x", (await source.RunAsync(["up"], Ct)).Message);
        runner.Answer = (_, _) => new ProcessResult(2, "", "");
        Assert.Equal("benchbar.exe exited with code 2.", (await source.RunAsync(["up"], Ct)).Message);
    }

    [Fact]
    public async Task TheControllerReturnsTheResultOfStartAndStopAndRestart()
    {
        var source = new ScriptedSource { Result = new ActionResult(1, "Port 8000 is held by another bench.") };
        using var controller = new TrayController(source, new FakeFrameClock(), new FakeHost(), TimeProvider.System,
            new TrayOptions { ListenToSystemEvents = false });
        var bench = new BenchStatus("a", "/a", BenchState.Stopped, null, null, null);

        var up = await controller.StartStopAsync(bench);
        Assert.False(up.Ok);
        Assert.Equal("Port 8000 is held by another bench.", up.Message);
        Assert.Equal("Port 8000 is held by another bench.", (await controller.RestartAsync(bench)).Message);

        source.Result = ActionResult.Success;
        Assert.True((await controller.StartStopAsync(bench)).Ok);
    }

    [Fact]
    public async Task ASetupProblemBecomesAFailedResult()
    {
        var source = new ShimBenchSource(new FakeProcessRunner(), () => null);
        using var controller = new TrayController(source, new FakeFrameClock(), new FakeHost(), TimeProvider.System,
            new TrayOptions { ListenToSystemEvents = false });
        var result = await controller.StartStopAsync(new BenchStatus("a", "/a", BenchState.Stopped, null, null, null));
        Assert.False(result.Ok);
        Assert.Equal(ShimBenchSource.NotFoundMessage, result.Message);
    }
}
