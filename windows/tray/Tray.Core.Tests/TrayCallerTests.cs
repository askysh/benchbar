using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>Every process the tray starts says who started it (BENCHBAR_CALLER=tray), for benchbar history.</summary>
public class TrayCallerTests
{
    [Fact]
    public async Task AStreamRunsCarryTheCallerLabel()
    {
        var lines = new List<string>();
        var result = await new SystemStreamRunner().RunAsync("cmd.exe", ["/c", "echo", "[%BENCHBAR_CALLER%]"], null, lines.Add, Timeout.InfiniteTimeSpan, TestContext.Current.CancellationToken);
        Assert.Equal(0, result.ExitCode);
        Assert.Contains("[tray]", lines);
    }

    [Fact]
    public async Task APlainRunCarriesItToo()
    {
        var result = await new SystemProcessRunner().RunAsync("cmd.exe", ["/c", "echo", "[%BENCHBAR_CALLER%]"], TestContext.Current.CancellationToken);
        Assert.Equal(0, result.ExitCode);
        Assert.Contains("[tray]", result.Output);
    }

    [Fact]
    public async Task AnEnvironmentTheCallerPassesWins()
    {
        var lines = new List<string>();
        var env = new Dictionary<string, string> { ["BENCHBAR_CALLER"] = "script" };
        await new SystemStreamRunner().RunAsync("cmd.exe", ["/c", "echo", "[%BENCHBAR_CALLER%]"], env, lines.Add, Timeout.InfiniteTimeSpan, TestContext.Current.CancellationToken);
        Assert.Contains("[script]", lines);
    }
}
