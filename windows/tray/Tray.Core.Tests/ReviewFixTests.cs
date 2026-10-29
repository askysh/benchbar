using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace Tray.Core.Tests;

public class TimeoutTests
{
    private const string Shim = @"C:\bin\benchbar.exe";

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Theory]
    [InlineData("up", 180)]
    [InlineData("down", 180)]
    [InlineData("restart", 180)]
    [InlineData("report", 120)]
    [InlineData("doctor", 120)]
    [InlineData("logs", 30)]
    [InlineData("list", 30)]
    [InlineData("status", 30)]
    public void EachCommandHasItsOwnTimeout(string verb, int seconds) =>
        Assert.Equal(TimeSpan.FromSeconds(seconds), ShimBenchSource.TimeoutFor([verb, "--json"]));

    [Fact]
    public async Task TheTimeoutIsPassedToTheRunnerPerCommand()
    {
        var runner = new FakeProcessRunner { Answer = (_, args) => new ProcessResult(0, args[0] == "list" ? """{"benches":[]}""" : "{}", "") };
        var source = new ShimBenchSource(runner, () => Shim);
        await source.RunAsync(["up", "--bench-dir", "/b"], Ct);
        Assert.Equal(TimeSpan.FromSeconds(180), runner.LastTimeout);
        await source.ListAsync(Ct);
        Assert.Equal(TimeSpan.FromSeconds(30), runner.LastTimeout);
        runner.Answer = (_, _) => new ProcessResult(0, "{}", "");
        await source.DoctorAsync("/b", Ct);
        Assert.Equal(TimeSpan.FromSeconds(120), runner.LastTimeout);
    }

    [Fact]
    public async Task AnActionThatTimesOutIsAFailureLineNeverATaskCanceled()
    {
        var runner = new FakeProcessRunner { Throws = new OperationCanceledException() };
        var source = new ShimBenchSource(runner, () => Shim);

        var up = await source.RunAsync(["up", "--bench-dir", "/b"], Ct);
        Assert.False(up.Ok);
        Assert.Equal("benchbar.exe up did not finish in 3 minutes; the bench may still be starting. Run benchbar.exe status.", up.Message);
        var down = await source.RunAsync(["down", "--bench-dir", "/b"], Ct);
        Assert.Equal("benchbar.exe down did not finish in 3 minutes; the bench may still be stopping. Run benchbar.exe status.", down.Message);
    }

    [Fact]
    public async Task AReadThatTimesOutNamesTheCommandAndItsLimit()
    {
        var runner = new FakeProcessRunner { Throws = new OperationCanceledException() };
        var source = new ShimBenchSource(runner, () => Shim);
        var doctor = await Assert.ThrowsAsync<CliProblemException>(() => source.DoctorAsync("/b", Ct));
        Assert.Equal("benchbar.exe doctor did not answer in 2 minutes.", doctor.Message);
        var logs = await Assert.ThrowsAsync<CliProblemException>(() => source.LogsAsync("/b", Ct));
        Assert.Equal("benchbar.exe logs did not answer in 30 seconds.", logs.Message);
    }

    [Fact]
    public async Task ACallerCancelIsStillACancel()
    {
        var source = new ShimBenchSource(new FakeProcessRunner { Throws = new OperationCanceledException() }, () => Shim);
        using var cts = new CancellationTokenSource();
        await cts.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => source.RunAsync(["up"], cts.Token));
    }

    [Fact]
    public async Task AFailedActionKeepsTheFastPollWindowRunning()
    {
        var runner = new FakeProcessRunner { Throws = new OperationCanceledException() };
        var source = new ShimBenchSource(runner, () => Shim);
        var time = new FakeTimeProvider();
        var host = new FakeHost();
        using var controller = new TrayController(source, new FakeFrameClock(), host, time, new TrayOptions { ListenToSystemEvents = false });
        controller.Start();
        await Wait(() => host.Changes.Count >= 1);

        var result = await controller.StartStopAsync(new BenchStatus("a", "/a", BenchState.Stopped, null, null, null));
        Assert.Contains("did not finish in 3 minutes", result.Message);
        await Wait(() => host.Changes.Count >= 2); // the boost's immediate poll, finished and re-armed

        var calls = runner.Calls.Count;
        time.Advance(TimeSpan.FromSeconds(2)); // 30 s would be the idle wait
        await Wait(() => runner.Calls.Count > calls);
    }

    private static async Task Wait(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "condition not met in time");
            await Task.Delay(10, TestContext.Current.CancellationToken);
        }
    }
}

public class ConfigReviewTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"));

    private string ConfigPath => Path.Combine(_dir, "config.json");

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (IOException) { }
    }

    private void Write(string text)
    {
        Directory.CreateDirectory(_dir);
        File.WriteAllText(ConfigPath, text);
    }

    [Fact]
    public void SaveKeepsWhatTheShimWroteAfterTheTrayStarted()
    {
        Write("""{"distro":"Ubuntu-24.04","tray":{"runner":"cup"}}""");
        var config = TrayConfig.Load(ConfigPath);

        // `benchbar.exe adopt-distro` runs while the tray is up
        Write("""{"distro":"Debian","cli_path":"/opt/bb","tray":{"runner":"cup","extra":1}}""");
        config.Notifications = false;
        config.Save();

        var root = (JsonObject)JsonNode.Parse(File.ReadAllText(ConfigPath))!;
        Assert.Equal("Debian", (string?)root["distro"]);
        Assert.Equal("/opt/bb", (string?)root["cli_path"]);
        Assert.Equal(1, root["tray"]!["extra"]!.GetValue<int>());
        Assert.False(root["tray"]!["notifications"]!.GetValue<bool>());
    }

    [Fact]
    public void TheDistroIsReadAgainOnlyWhenTheFileChanged()
    {
        Write("""{"distro":"Ubuntu-24.04"}""");
        var config = TrayConfig.Load(ConfigPath);
        Assert.Equal("Ubuntu-24.04", config.Distro);

        // a change with the same write time and length is not seen: no I/O beyond the stat
        var stamp = File.GetLastWriteTimeUtc(ConfigPath);
        File.WriteAllText(ConfigPath, """{"distro":"Debian-12-xx"}""".Replace("Debian-12-xx", "Ubuntu-22.04"));
        File.SetLastWriteTimeUtc(ConfigPath, stamp);
        Assert.Equal("Ubuntu-24.04", config.Distro);

        File.WriteAllText(ConfigPath, """{"distro":"Debian"}""");
        File.SetLastWriteTimeUtc(ConfigPath, stamp.AddSeconds(5));
        Assert.Equal("Debian", config.Distro);

        File.Delete(ConfigPath);
        Assert.Null(config.Distro);
    }

    [Fact]
    public void AConfigThatCannotBeReadIsNeverOverwritten()
    {
        Write("""{"distro":"Ubuntu-24.04"}""");
        TrayConfig config;
        using (new FileStream(ConfigPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            config = TrayConfig.Load(ConfigPath);
        Assert.True(config.Unreadable);

        config.RunnerId = "cup";
        var ex = Assert.Throws<IOException>(config.Save);
        Assert.Contains("not overwritten", ex.Message);
        Assert.Equal("""{"distro":"Ubuntu-24.04"}""", File.ReadAllText(ConfigPath));
    }

    [Fact]
    public void ADuplicateKeyIsInvalidJsonAndGoesThroughTheBadCopy()
    {
        const string text = """{"distro":"A","distro":"B"}""";
        Write(text);
        var config = TrayConfig.Load(ConfigPath);
        Assert.True(config.WasCorrupt);
        Assert.Equal("bench", config.RunnerId);
        Assert.Null(config.Distro);

        config.Save();
        Assert.Equal(text, File.ReadAllText(ConfigPath + ".bad"));
        Assert.Equal("bench", (string?)JsonNode.Parse(File.ReadAllText(ConfigPath))!["tray"]!["runner"]);
    }

    [Fact]
    public void AFileThatBecameInvalidAfterLoadIsKeptAsBadAtSave()
    {
        Write("""{"distro":"A"}""");
        var config = TrayConfig.Load(ConfigPath);
        Write("{ half written");
        config.Save();
        Assert.Equal("{ half written", File.ReadAllText(ConfigPath + ".bad"));
    }
}

public class ToastReviewTests
{
    private static BenchStatus Bench(string path, BenchState state, string? reason = null) =>
        new(path.TrimStart('/'), path, state, reason, null, null);

    [Fact]
    public void AnAllUnknownFirstSnapshotDoesNotSeedSoACrashAfterItIsOnlyTheSeed()
    {
        var policy = new ToastPolicy();
        Assert.Empty(policy.Observe(new TraySnapshot([Bench("/a", BenchState.Unknown)])));
        Assert.Empty(policy.Observe(new TraySnapshot([Bench("/a", BenchState.Crashed)]))); // found at launch, not news
        Assert.Single(policy.Observe(new TraySnapshot([Bench("/a", BenchState.Paused, "crash")])));
    }

    [Fact]
    public void OneBrokenBenchDoesNotSilenceAnother()
    {
        var policy = new ToastPolicy();
        Assert.Empty(policy.Observe(new TraySnapshot([Bench("/a", BenchState.Running), Bench("/b", BenchState.Running)])));

        var broken = Bench("/b", BenchState.Unknown) with { Problem = "benchbar.exe status gave no usable answer." };
        var toast = Assert.Single(policy.Observe(new TraySnapshot([Bench("/a", BenchState.Crashed), broken])));
        Assert.Equal("a crashed", toast.Title);
    }
}

public class ControllerReviewTests
{
    [Fact]
    public async Task TheIconFollowsTheKnownBenchesWhenAnotherCannotBeRead()
    {
        var source = new ScriptedSource();
        source.States["a"] = BenchState.Crashed;
        source.Entries.Add(new BenchEntry("b", "/b", false, null)); // b has no state: its status call fails
        var host = new FakeHost();
        using var controller = new TrayController(source, new FakeFrameClock(), host, new FakeTimeProvider(),
            new TrayOptions { ListenToSystemEvents = false });
        controller.Start();
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (host.Changes.Count == 0 && DateTime.UtcNow < deadline) await Task.Delay(10, TestContext.Current.CancellationToken);

        Assert.Null(controller.Snapshot.Problem);
        Assert.Contains(controller.Sequencer.Plan, new RunnerPlan?[] { new RunnerPlan.Stumble(3, RunnerPose.Alert), new RunnerPlan.Still(RunnerPose.Alert) });
        Assert.NotEmpty(controller.Snapshot.Benches[1].Problem ?? "");
    }
}

public class RunnerReviewTests : IDisposable
{
    private readonly RunnerFolder _runners = new();

    public void Dispose() => _runners.Dispose();

    [Fact]
    public void ADuplicateKeyManifestIsABrokenRunner()
    {
        var dir = _runners.Good();
        RunnerFolder.Manifest(dir, """{"name":"A","name":"B","template":true,"states":{"running":["run1.png"]}}""");
        Assert.Contains("not valid JSON", Assert.Throws<RunnerException>(() => RunnerLoader.Load(dir, "blob")).Message);

        var set = RunnerSet.Load(_runners.Root);
        var info = set.Runners.Single(r => r.Id == "blob");
        Assert.False(info.IsUsable);
        Assert.Contains("not valid JSON", info.Error);
    }

    [Fact]
    public void ALinkIsCaughtBeforeAnythingIsRead()
    {
        var dir = _runners.Good();
        File.WriteAllText(Path.Combine(dir, "manifest.json"), "{ this would be a JSON error");
        var target = _runners.Make("elsewhere");
        var link = Path.Combine(dir, "link");
        using (var process = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("cmd.exe", $"/c mklink /J \"{link}\" \"{target}\"") { CreateNoWindow = true, UseShellExecute = false, RedirectStandardOutput = true })!)
        {
            process.StandardOutput.ReadToEnd();
            process.WaitForExit();
        }
        // the manifest is invalid too, but the link is reported: the folder rules run first
        Assert.Contains("is a link", Assert.Throws<RunnerException>(() => RunnerLoader.Load(dir, "blob")).Message);
    }

    [Fact]
    public void AnOversizedManifestIsRefusedBySizeNotRead()
    {
        var dir = _runners.Good();
        using (var stream = File.Create(Path.Combine(dir, "manifest.json"))) stream.SetLength(65 * 1024);
        Assert.Contains("64 KB", Assert.Throws<RunnerException>(() => RunnerLoader.Load(dir, "blob")).Message);
    }
}
