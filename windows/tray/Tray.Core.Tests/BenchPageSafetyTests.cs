using BenchBar.Tray.Core;
using Xunit;
using static Tray.Core.Tests.CliFixture;

namespace Tray.Core.Tests;

/// <summary>The Phase 2 review fixes in the models: timeouts, the log follow guard, terminal arguments, remove, stale tokens, app input.</summary>
public class BenchPageSafetyTests
{
    // --- no hard timeout for a run that changes things ---

    [Fact]
    public async Task AnApplyHasNoHardTimeoutAndReadsAndPlansKeepTheirs()
    {
        Assert.Equal(Timeout.InfiniteTimeSpan, CliTimeouts.Apply);
        Assert.Equal(Timeout.InfiniteTimeSpan, PlanReviewRequest.Tokened("x", ["a"]).ApplyTimeout);
        Assert.True(CliTimeouts.Read < TimeSpan.FromMinutes(5));
        Assert.True(CliTimeouts.Plan < TimeSpan.FromMinutes(5));

        var lines = new List<string>();
        var result = await new SystemStreamRunner().RunAsync("cmd.exe", ["/c", "echo", "hi"], null, lines.Add, Timeout.InfiniteTimeSpan, TestContext.Current.CancellationToken);
        Assert.Equal(0, result.ExitCode);
        Assert.Contains("hi", lines);
    }

    [Fact]
    public async Task ARunningApplyReportsHowLongItHasRun()
    {
        var (client, runner) = Scripted();
        runner.On(a => a.Contains("--dry-run")).Print(Lines("site-add-plan.json"));
        var held = runner.On(a => a.Contains("--apply")).Print(Lines("site-add-apply.jsonl")).Hold();
        var model = new PlanReviewModel(PlanReviewRequest.Tokened("Add", ["site", "add", "x"]), client);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(TimeSpan.Zero, model.Elapsed);
        var run = model.ConfirmAsync();
        await held.Started.Task;
        await Task.Delay(30, TestContext.Current.CancellationToken);
        Assert.True(model.Elapsed > TimeSpan.Zero);
        Assert.False(model.CanStop); // nothing offers to kill it
        held.Release();
        await run;
    }

    // --- Follow never boots a stopped distro ---

    private sealed class Probe(bool running) : IDistroProbe
    {
        public bool Running { get; set; } = running;
        public int Asked { get; private set; }

        public Task<bool> IsRunningAsync(string distro, CancellationToken ct)
        {
            Asked++;
            return Task.FromResult(Running);
        }
    }

    private static async Task Until(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline) throw new TimeoutException("the condition was not met");
            await Task.Delay(5, TestContext.Current.CancellationToken);
        }
    }

    [Fact]
    public async Task FollowPausesWhenTheDistroStoppedAndResumesOnlyWhenTheUserTurnsItOn()
    {
        var (client, runner) = Scripted();
        runner.On("logs").Print(Lines("logs-first.json"));
        var probe = new Probe(false);
        var model = new LogViewModel(client, "/b", "b") { PollEvery = TimeSpan.FromMilliseconds(15), DistroProbe = probe, Distro = () => "Ubuntu-24.04" };
        await model.LoadAsync(TestContext.Current.CancellationToken);
        var loads = runner.Runs.Count;
        model.Start();
        await Until(() => model.DistroPaused);

        Assert.False(model.Follow);
        Assert.Contains(model.Visible(), l => l.Text == LogViewModel.DistroStoppedLine);
        Assert.Equal(loads, runner.Runs.Count); // no poll reached the CLI, so the distro was not booted
        var asked = probe.Asked;
        await Task.Delay(80, TestContext.Current.CancellationToken);
        Assert.Equal(asked, probe.Asked); // and it does not ask again by itself

        probe.Running = true;
        runner.On(a => a.Contains("--since")).Print(Lines("logs-since.json"));
        model.Follow = true;
        await Until(() => model.Polls > 0);
        Assert.False(model.DistroPaused);
        model.Dispose();
    }

    [Fact]
    public async Task ARunningDistroIsPolledAsBefore()
    {
        var (client, runner) = Scripted();
        runner.On("logs").Print(Lines("logs-first.json"));
        var model = new LogViewModel(client, "/b", "b") { PollEvery = TimeSpan.FromMilliseconds(15), DistroProbe = new Probe(true), Distro = () => "Ubuntu-24.04" };
        await model.LoadAsync(TestContext.Current.CancellationToken);
        model.Start();
        await Until(() => model.Polls > 1);
        Assert.False(model.DistroPaused);
        Assert.True(model.Follow);
        model.Dispose();
    }

    // --- terminal commands ---

    [Fact]
    public void ATerminalCommandRunsTheProgramItselfAndEscapesTheSemicolonForWindowsTerminal()
    {
        var launch = new TerminalLaunch("Ubuntu;x", "/home/a/b;c", WslCommands.Console("one.localhost"));
        Assert.Equal(["-d", "Ubuntu;x", "--cd", "/home/a/b;c", "--exec", "bench", "--site", "one.localhost", "console"], launch.WslArguments);
        Assert.Equal(["wsl.exe", "-d", "Ubuntu\\;x", "--cd", "/home/a/b\\;c", "--exec", "bench", "--site", "one.localhost", "console"], launch.WindowsTerminalArguments);
        Assert.DoesNotContain("--", launch.WslArguments);
    }

    [Theory]
    [InlineData("a;b")]
    [InlineData("a b")]
    [InlineData("$(id).localhost")]
    [InlineData("-x")]
    [InlineData("a`b")]
    [InlineData("A.localhost")]
    public void AHostileSiteNameNeverReachesATerminalCommand(string site)
    {
        Assert.Throws<ArgumentException>(() => WslCommands.Console(site));
        Assert.Throws<ArgumentException>(() => WslCommands.Database(site));
    }

    // --- remove runs once ---

    [Fact]
    public async Task ASecondRemoveWhileOneRunsIsRefused()
    {
        var (client, runner) = Scripted();
        var held = runner.On("profile", "remove").Print(Lines("profile-remove.json")).Hold();
        runner.On("profile", "list").Print(Lines("profile-list.json"));
        var model = new ProfilesModel(client);
        var mine = ProfileListJson.Parse(Doc("profile-list.json"))[3];
        var first = model.RemoveAsync(mine, TestContext.Current.CancellationToken);
        await held.Started.Task;
        Assert.True(model.IsRemoving);
        Assert.False(await model.RemoveAsync(mine, TestContext.Current.CancellationToken));
        held.Release();
        Assert.True(await first);
        Assert.False(model.IsRemoving);
        Assert.Single(runner.Runs, r => r.Args.Contains("remove"));
    }

    // --- the stale token refusal is matched by its wording ---

    [Theory]
    [InlineData("The site add plan changed since it was shown (the sites, apps.txt or the default site). Nothing was changed.", true)]
    [InlineData("The site restore plan changed since it was shown (the backup set). Nothing was changed.", true)]
    [InlineData("The app add plan changed since it was shown (apps.txt, apps/, the sites or the remote). Nothing was changed.", true)]
    [InlineData("The port plan changed. Review a fresh preview before applying.", true)]
    [InlineData("The update changed since it was reviewed (newer content at the source). Nothing was changed.", true)]
    [InlineData("The export plan changed since it was reviewed (the file). Nothing was written.", true)]
    [InlineData("Reclaiming stale lock left by pid 4242", false)]
    [InlineData("The stale cache was cleared", false)]
    [InlineData("config changed", false)]
    [InlineData(null, false)]
    public void OnlyTheCliRefusalIsStale(string? text, bool stale) => Assert.Equal(stale, PlanStale.Looks(text));

    [Fact]
    public async Task AStaleLockInStderrIsAFailureNotAStalePlan()
    {
        var (client, runner) = Scripted();
        runner.On(a => a.Contains("--dry-run")).Print(Lines("site-add-plan.json"));
        runner.On(a => a.Contains("--apply")).Fail(1, "Reclaiming stale lock, then the build failed");
        var model = new PlanReviewModel(PlanReviewRequest.Tokened("Add", ["site", "add", "x"]), client);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        await model.ConfirmAsync();
        Assert.Equal(PlanPhase.Finished, model.Phase);
        Assert.Contains("stale lock", model.Result!.Error);
    }

    // --- app input ---

    [Theory]
    [InlineData("-oProxyCommand=x", "", "cannot start with a dash")]
    [InlineData("erpnext", "-b", "branch cannot start with a dash")]
    public void AnAppSourceOrBranchStartingWithADashIsRefused(string source, string branch, string expected)
    {
        var input = new AppAddInput(source, branch);
        Assert.False(input.CanReview);
        Assert.Contains(expected, input.Problem);
        Assert.True(new AppAddInput("erpnext", "version-15").CanReview);
    }
}
