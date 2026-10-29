using System.Text.Json;
using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

public class ParsingTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public void RecordedStatusParses()
    {
        var status = BenchJson.ParseStatus(File.ReadAllText(Path.Combine(Fixtures.Dir("recorded"), "status.json")));
        Assert.Equal("frappe-bench", status.Name);
        Assert.Equal("/home/akash/frappe-bench", status.Path);
        Assert.Equal(BenchState.Stopped, status.State);
        Assert.Equal("manual", status.StopReason);
        Assert.Equal("http://linuxdev.localhost:8000", status.WebUrl);
        Assert.Equal("linuxdev.localhost", status.Site);
    }

    [Fact]
    public void RecordedListParses()
    {
        var list = BenchJson.ParseList(File.ReadAllText(Path.Combine(Fixtures.Dir("recorded"), "list.json")));
        var bench = Assert.Single(list);
        Assert.Equal("frappe-bench", bench.Name);
        Assert.Equal("/home/akash/frappe-bench", bench.Path);
        Assert.True(bench.IsDefault);
        Assert.Equal("http://linuxdev.localhost:8000", bench.WebUrl);
    }

    [Theory]
    [InlineData("rest", "stopped", "stopped")]
    [InlineData("load", "running", "stopped")]
    [InlineData("crash", "paused", "stopped")]
    public async Task ScenarioFoldersReadThroughFixtureSource(string scenario, string first, string second)
    {
        var source = new FixtureBenchSource(Fixtures.Dir(scenario));
        var entries = await source.ListAsync(Ct);
        Assert.Equal(["frappe-bench", "v16-bench"], entries.Select(e => e.Name));
        Assert.True(entries[0].IsDefault);
        Assert.False(entries[1].IsDefault);

        var states = new List<BenchStatus>();
        foreach (var entry in entries) states.Add(await source.StatusAsync(entry, Ct));
        Assert.Equal(BenchJson.ParseState(first), states[0].State);
        Assert.Equal(BenchJson.ParseState(second), states[1].State);
        Assert.Equal("http://v16dev.localhost:8001", states[1].WebUrl);
    }

    [Fact]
    public async Task LoadFixtureReportsCpu()
    {
        Assert.Equal(250, new FixtureBenchSource(Fixtures.Dir("load")).CpuPercent);
        Assert.Null(new FixtureBenchSource(Fixtures.Dir("rest")).CpuPercent);
        await Task.CompletedTask;
    }

    [Fact]
    public async Task RecordedFolderServesItsSingleStatusForAnyBench()
    {
        var source = new FixtureBenchSource(Fixtures.Dir("recorded"));
        var entry = (await source.ListAsync(Ct)).Single();
        Assert.Equal(BenchState.Stopped, (await source.StatusAsync(entry, Ct)).State);
    }

    [Fact]
    public async Task FixtureSourceRereadsFilesOnEveryCall()
    {
        var dir = Fixtures.Copy("rest");
        var source = new FixtureBenchSource(dir);
        var entry = (await source.ListAsync(Ct))[0];
        Assert.Equal(BenchState.Stopped, (await source.StatusAsync(entry, Ct)).State);

        var path = Path.Combine(dir, "status-frappe-bench.json");
        File.WriteAllText(path, File.ReadAllText(path).Replace("\"state\":\"stopped\"", "\"state\":\"running\""));
        Assert.Equal(BenchState.Running, (await source.StatusAsync(entry, Ct)).State);
    }

    [Fact]
    public async Task FixtureUpAndDownRewriteNothingAndReturnZero()
    {
        var dir = Fixtures.Copy("rest");
        var before = File.ReadAllText(Path.Combine(dir, "status-frappe-bench.json"));
        var source = new FixtureBenchSource(dir);
        Assert.Equal(0, await source.RunAsync(["up", "--bench-dir", "/home/akash/frappe-bench"], Ct));
        Assert.Equal(before, File.ReadAllText(Path.Combine(dir, "status-frappe-bench.json")));
        Assert.Equal(["up --bench-dir /home/akash/frappe-bench"], source.Actions);
    }

    [Theory]
    [InlineData("stopped", BenchState.Stopped)]
    [InlineData("starting", BenchState.Starting)]
    [InlineData("running", BenchState.Running)]
    [InlineData("crashed", BenchState.Crashed)]
    [InlineData("paused", BenchState.Paused)]
    [InlineData("hibernating", BenchState.Unknown)]
    [InlineData("", BenchState.Unknown)]
    [InlineData(null, BenchState.Unknown)]
    public void StateStringsMapAndUnknownIsUnknown(string? text, BenchState expected) =>
        Assert.Equal(expected, BenchJson.ParseState(text));

    [Fact]
    public void MissingAndExtraFieldsAreTolerated()
    {
        var status = BenchJson.ParseStatus("""{"bench":"/x/y-bench","state":"running","brand_new":{"a":[1,2]}}""");
        Assert.Equal("y-bench", status.Name);
        Assert.Equal(BenchState.Running, status.State);
        Assert.Null(status.WebUrl);
        Assert.Null(status.StopReason);
        Assert.Null(status.Site);

        Assert.Equal(BenchState.Unknown, BenchJson.ParseStatus("{}").State);
        Assert.Empty(BenchJson.ParseList("""{"schema_version":2}"""));
    }

    [Fact]
    public void DefaultBenchFallsBackToTheDefaultPath()
    {
        var list = BenchJson.ParseList("""{"default_bench":"/a","benches":[{"path":"/a","name":"a"},{"path":"/b","name":"b"}]}""");
        Assert.True(list[0].IsDefault);
        Assert.False(list[1].IsDefault);
    }

    [Fact]
    public void MalformedJsonThrowsJsonException()
    {
        Assert.ThrowsAny<JsonException>(() => BenchJson.ParseStatus("not json"));
        Assert.ThrowsAny<JsonException>(() => BenchJson.ParseList("null"));
    }

    [Fact]
    public void FactoryUsesFixturesWhenTheVariableIsSet()
    {
        var old = Environment.GetEnvironmentVariable(BenchSourceFactory.FixturesVariable);
        try
        {
            Environment.SetEnvironmentVariable(BenchSourceFactory.FixturesVariable, Fixtures.Dir("rest"));
            Assert.IsType<FixtureBenchSource>(BenchSourceFactory.FromEnvironment());
            Environment.SetEnvironmentVariable(BenchSourceFactory.FixturesVariable, null);
            Assert.IsType<CliBenchSource>(BenchSourceFactory.FromEnvironment());
        }
        finally
        {
            Environment.SetEnvironmentVariable(BenchSourceFactory.FixturesVariable, old);
        }
    }

    [Fact]
    public void CliSourceBuildsTheShimAndTheWslCommand()
    {
        var shim = new CliBenchSource(@"C:\bin\benchbar.exe", null).Command(["status", "--json", "--bench-dir", "/home/a b/bench"]);
        Assert.Equal(@"C:\bin\benchbar.exe", shim.File);
        Assert.Equal(["status", "--json", "--bench-dir", "/home/a b/bench"], shim.Args);

        var wsl = new CliBenchSource(null, null).Command(["status", "--json", "--bench-dir", "/home/a b/it's"]);
        Assert.Equal("wsl.exe", wsl.File);
        Assert.Equal(["-d", "Ubuntu-24.04", "--", "bash", "-lc", "benchbar status --json --bench-dir '/home/a b/it'\\''s'"], wsl.Args);

        var custom = new CliBenchSource(null, "Debian").Command(["list", "--json"]);
        Assert.Equal("Debian", custom.Args[1]);
    }
}
