using System.ComponentModel;
using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

public class ShimSourceTests
{
    private const string Shim = @"C:\bin\benchbar.exe";

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static (ShimBenchSource Source, FakeProcessRunner Runner) Make(string? shim = Shim)
    {
        var runner = new FakeProcessRunner();
        return (new ShimBenchSource(runner, () => shim), runner);
    }

    [Fact]
    public async Task AMissingShimIsASetupProblemWithTheFixLineAndNothingIsStarted()
    {
        var (source, runner) = Make(shim: null);
        var ex = await Assert.ThrowsAsync<SetupProblemException>(() => source.ListAsync(Ct));
        Assert.Equal("benchbar.exe was not found. Put it next to BenchBarTray.exe or on PATH (benchbar.exe path install).", ex.Message);
        await Assert.ThrowsAsync<SetupProblemException>(() => source.RunAsync(["up"], Ct));
        await Assert.ThrowsAsync<SetupProblemException>(() => source.DoctorAsync("/b", Ct));
        Assert.False(source.StartDistro());
        Assert.Empty(runner.Calls);
        Assert.Empty(runner.Detached);
    }

    [Fact]
    public async Task ANonZeroExitWithNothingOnStdoutCarriesTheFirstLineOfStderr()
    {
        var (source, runner) = Make();
        runner.Answer = (_, _) => new ProcessResult(1, "", "\r\nno distro: run benchbar.exe adopt-distro NAME\nsecond line\n");
        var ex = await Assert.ThrowsAsync<CliProblemException>(() => source.ListAsync(Ct));
        Assert.Equal("no distro: run benchbar.exe adopt-distro NAME", ex.Message);

        runner.Answer = (_, _) => new ProcessResult(3, "", "");
        ex = await Assert.ThrowsAsync<CliProblemException>(() => source.StatusAsync(new BenchEntry("a", "/a", true, null), Ct));
        Assert.Equal("benchbar.exe exited with code 3.", ex.Message);
    }

    [Fact]
    public async Task ANonZeroExitWithJsonOnStdoutIsStillAnAnswer()
    {
        var (source, runner) = Make();
        runner.Answer = (_, _) => new ProcessResult(1, """{"bench":"/b","checks":[{"id":"x","level":"fail","message":"m","fix_command":"fix"}],"summary":{"ok":0,"warn":0,"fail":1}}""", "");
        var report = await source.DoctorAsync("/b", Ct);
        Assert.Equal(1, report.Fail);
        Assert.Equal("fix", Assert.Single(report.Checks).FixCommand);
    }

    [Fact]
    public async Task CommandsAreTheShimsOwnArguments()
    {
        var (source, runner) = Make();
        runner.Answer = (_, args) => args[0] switch
        {
            "list" => new ProcessResult(0, """{"benches":[{"path":"/b","name":"b"}]}""", ""),
            "status" => new ProcessResult(0, """{"bench":"/b","state":"running"}""", ""),
            "logs" => new ProcessResult(0, """{"file":"/b/logs/bench.log","lines":["x"]}""", ""),
            "report" => new ProcessResult(0, """{"zip":"/home/a/Desktop/r.zip"}""", ""),
            _ => new ProcessResult(0, "", ""),
        };
        var entry = Assert.Single(await source.ListAsync(Ct));
        Assert.Equal(BenchState.Running, (await source.StatusAsync(entry, Ct)).State);
        Assert.Equal(["x"], (await source.LogsAsync("/b", Ct)).Lines);
        Assert.Equal("/home/a/Desktop/r.zip", await source.ReportAsync("/b", Ct));
        Assert.True((await source.RunAsync(["restart", "--bench-dir", "/b"], Ct)).Ok);

        Assert.All(runner.Calls, c => Assert.Equal(Shim, c.File));
        Assert.Equal(
            [
                "list --json",
                "status --json --bench-dir /b",
                "logs --json -n300 --bench-dir /b",
                "report --json --bench-dir /b",
                "restart --bench-dir /b",
            ],
            runner.Calls.Select(c => string.Join(' ', c.Args)));
    }

    [Fact]
    public async Task LogsTakeALineCount()
    {
        var (source, runner) = Make();
        runner.Answer = (_, _) => new ProcessResult(0, """{"lines":[]}""", "");
        await source.LogsAsync("/b", Ct, 50);
        Assert.Equal("logs --json -n50 --bench-dir /b", string.Join(' ', runner.Calls[0].Args));
    }

    [Fact]
    public async Task AShimThatCannotStartIsACliProblem()
    {
        var (source, runner) = Make();
        runner.Throws = new Win32Exception("Access is denied");
        var ex = await Assert.ThrowsAsync<CliProblemException>(() => source.ListAsync(Ct));
        Assert.Contains("could not be started", ex.Message);
        Assert.False(source.StartDistro());
    }

    [Fact]
    public async Task ATimeoutIsACliProblemButACallerCancelIsNot()
    {
        var (source, runner) = Make();
        runner.Throws = new OperationCanceledException();
        await Assert.ThrowsAsync<CliProblemException>(() => source.ListAsync(Ct));

        using var cts = new CancellationTokenSource();
        await cts.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => source.ListAsync(cts.Token));
    }

    [Fact]
    public void StartDistroRunsKeepaliveRunDetached()
    {
        var (source, runner) = Make();
        Assert.True(source.StartDistro());
        var call = Assert.Single(runner.Detached);
        Assert.Equal(Shim, call.File);
        Assert.Equal(["keepalive", "run"], call.Args);
        Assert.Empty(runner.Calls);
    }

    [Fact]
    public void TheShimIsFoundNextToTheExeBeforeOnPath()
    {
        var present = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            Path.Combine(@"C:\app", "benchbar.exe"),
            Path.Combine(@"C:\tools", "benchbar.exe"),
        };
        bool Exists(string p) => present.Contains(p);

        Assert.Equal(Path.Combine(@"C:\app", "benchbar.exe"), ShimLocator.Find(@"C:\app", @"C:\x;C:\tools", Exists));
        Assert.Equal(Path.Combine(@"C:\tools", "benchbar.exe"), ShimLocator.Find(@"C:\other", @"C:\x;""C:\tools""", Exists));
        Assert.Null(ShimLocator.Find(@"C:\other", @"C:\x;C:\y", Exists));
        Assert.Null(ShimLocator.Find(@"C:\other", null, Exists));
        Assert.Null(ShimLocator.Find(@"C:\other", "a|b;;", Exists)); // a bad PATH entry does not throw
    }
}

public class RealShimTests
{
    [Fact]
    public async Task TheRealShimAnswersTheReadOnlyCommands()
    {
        // BENCHBAR_TEST_SHIM=<path to benchbar.exe> runs list, status, doctor and logs against a real distro
        var shim = Environment.GetEnvironmentVariable("BENCHBAR_TEST_SHIM");
        if (string.IsNullOrEmpty(shim)) return;
        var ct = TestContext.Current.CancellationToken;
        var source = new ShimBenchSource(new SystemProcessRunner(), () => shim);
        var entry = (await source.ListAsync(ct)).First();
        var status = await source.StatusAsync(entry, ct);
        Assert.NotEqual("", status.RawState);
        Assert.NotEmpty((await source.DoctorAsync(entry.Path, ct)).Checks);
        Assert.NotNull((await source.LogsAsync(entry.Path, ct, 20)).Lines);
        Assert.True(await new WslDistroProbe().IsRunningAsync(DistroName.Resolve(null) ?? "", ct));
    }
}

public class DistroProbeTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public void TheListIsDecodedFromUtf16WithBomNulsAndCarriageReturns()
    {
        // wsl.exe writes UTF-16LE; Encoding.Unicode decodes it, but a stray BOM or a UTF-8 read of it leaves these
        var names = WslDistroProbe.ParseRunning("\uFEFFUbuntu-24.04\r\nDebian\r\n\r\n");
        Assert.Equal(["Ubuntu-24.04", "Debian"], names);
        Assert.Equal(["Ubuntu"], WslDistroProbe.ParseRunning("U\0b\0u\0n\0t\0u\0\r\0\n\0"));
        Assert.Empty(WslDistroProbe.ParseRunning(""));
    }

    [Fact]
    public void ARealUtf16LeOutputDecodesToTheNames()
    {
        var bytes = System.Text.Encoding.Unicode.GetPreamble().Concat(System.Text.Encoding.Unicode.GetBytes("Ubuntu-24.04\r\ndocker-desktop\r\n")).ToArray();
        var text = System.Text.Encoding.Unicode.GetString(bytes);
        Assert.Equal(["Ubuntu-24.04", "docker-desktop"], WslDistroProbe.ParseRunning(text));
    }

    [Theory]
    [InlineData("Ubuntu-24.04\r\n", "ubuntu-24.04", true)]
    [InlineData("Ubuntu-24.04\r\n", "Ubuntu-24.04", true)]
    [InlineData("Debian\r\nUbuntu-24.04\r\n", "Ubuntu-24.04", true)]
    [InlineData("Debian\r\n", "Ubuntu-24.04", false)]
    [InlineData("", "Ubuntu-24.04", false)]
    [InlineData("Ubuntu-24.04-extra\r\n", "Ubuntu-24.04", false)]
    public async Task TheNameIsComparedWithoutCase(string output, string distro, bool expected)
    {
        var runner = new FakeProcessRunner { Answer = (_, _) => new ProcessResult(0, output, "") };
        var probe = new WslDistroProbe(runner);
        Assert.Equal(expected, await probe.IsRunningAsync(distro, Ct));

        var call = Assert.Single(runner.Calls);
        Assert.Equal("wsl.exe", call.File);
        Assert.Equal(["--list", "--running", "--quiet"], call.Args); // never `-d`, which would boot the distro
        Assert.Equal(System.Text.Encoding.Unicode, runner.LastEncoding);
    }

    [Fact]
    public void TheNameComesFromTheConfigThenTheWslDefault()
    {
        Assert.Equal("Debian", DistroName.Resolve("Debian", () => "Ubuntu-24.04"));
        Assert.Equal("Debian", DistroName.Resolve("  Debian ", () => "Ubuntu-24.04"));
        Assert.Equal("Ubuntu-24.04", DistroName.Resolve(null, () => "Ubuntu-24.04"));
        Assert.Equal("Ubuntu-24.04", DistroName.Resolve("", () => "Ubuntu-24.04"));
        Assert.Null(DistroName.Resolve(null, () => null));
    }

    [Fact]
    public void TheRegistryReadDoesNotThrow() => _ = DistroName.FromRegistry();
}
