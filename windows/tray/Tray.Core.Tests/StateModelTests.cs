using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

public class StateModelTests
{
    private static string Recorded(string file) => File.ReadAllText(Path.Combine(Fixtures.Dir("recorded-v1"), file));

    private static string Status(string state, string? stopReason = null, string site = "\"x.localhost\"", string extra = "") =>
        $$"""{"schema_version":1,"bench":"/home/a/x-bench","name":"x-bench","site":{{site}},"state":"{{state}}","stop_reason":{{(stopReason is null ? "null" : "\"" + stopReason + "\"")}},"web_url":"http://x.localhost:8000"{{extra}}}""";

    [Fact]
    public void TheCapturedStatusKeepsRawStateLogAndSites()
    {
        var status = BenchJson.ParseStatus(Recorded("status.json"));
        Assert.Equal("frappe-bench", status.Name);
        Assert.Equal(BenchState.Running, status.State);
        Assert.Equal("running", status.RawState);
        Assert.Null(status.StopReason);
        Assert.Equal("linuxdev.localhost", status.Site);
        Assert.Equal("/home/akash/frappe-bench/logs/bench.log", status.LogPath);
        Assert.Equal([new SiteInfo("linuxdev.localhost", true), new SiteInfo("second.localhost", false)], status.Sites);
        Assert.Equal("running", BenchPresentation.StateWord(status));
    }

    [Fact]
    public void TheCapturedListParses()
    {
        var list = BenchJson.ParseList(Recorded("list.json"));
        var bench = Assert.Single(list);
        Assert.Equal("frappe-bench", bench.Name);
        Assert.Equal("/home/akash/frappe-bench", bench.Path);
        Assert.True(bench.IsDefault);
        Assert.Equal("http://linuxdev.localhost:8000", bench.WebUrl);
    }

    [Theory]
    [InlineData("running", null, BenchState.Running, "running")]
    [InlineData("starting", null, BenchState.Starting, "starting")]
    [InlineData("stopped", "manual", BenchState.Stopped, "stopped")]
    [InlineData("stopped", null, BenchState.Stopped, "stopped")]
    [InlineData("crashed", "crash", BenchState.Crashed, "crashed")]
    [InlineData("paused", "crash", BenchState.Paused, "paused")]
    [InlineData("paused", "port_conflict", BenchState.Paused, "port conflict")]
    [InlineData("paused", "broken", BenchState.Paused, "paused, needs repair")]
    [InlineData("paused", null, BenchState.Paused, "paused")]
    [InlineData("paused", "something_new", BenchState.Paused, "paused")]
    public void EveryStateHasItsWord(string state, string? reason, BenchState expected, string word)
    {
        var status = BenchJson.ParseStatus(Status(state, reason));
        Assert.Equal(expected, status.State);
        Assert.Equal(state, status.RawState);
        Assert.Equal(reason, status.StopReason);
        Assert.Equal(word, BenchPresentation.StateWord(status));
    }

    [Fact]
    public void NotAdoptedHasNoSiteAndIsUnknownWithItsRawNameKept()
    {
        var status = BenchJson.ParseStatus(Status("not_adopted", site: "null"));
        Assert.Null(status.Site);
        Assert.Equal(BenchState.Unknown, status.State);
        Assert.Equal("not_adopted", status.RawState);
        Assert.Equal("unknown (not_adopted)", BenchPresentation.StateWord(status));
    }

    [Fact]
    public void AnUnknownStateIsUnknownNeverAnError()
    {
        var status = BenchJson.ParseStatus(Status("hibernating"));
        Assert.Equal(BenchState.Unknown, status.State);
        Assert.Equal("unknown (hibernating)", BenchPresentation.StateWord(status));
        Assert.Equal("unknown", BenchPresentation.StateWord(BenchJson.ParseStatus("{}")));
    }

    [Fact]
    public void FieldsSessionFiveAddsDoNotBreakParsing()
    {
        var extra = """
            ,"pending_operations":[{"id":"op1","kind":"app_add","started_at":"2026-10-29T11:00:25Z","progress":{"done":1,"of":4}}],
             "redis":{"queue":{"running":true,"port":11000},"cache":"up"},
             "sites":[{"name":"a.localhost","default":true,"served":true,"hosts_entry":true,"ping_code":200},{"name":"b.localhost","default":false,"served":false}],
             "brand_new":{"a":[1,2,{"b":null}]}
            """;
        var status = BenchJson.ParseStatus(Status("running", extra: extra));
        Assert.Equal(BenchState.Running, status.State);
        Assert.Equal(["a.localhost", "b.localhost"], status.Sites.Select(s => s.Name));
        Assert.True(status.Sites[0].IsDefault);

        var list = BenchJson.ParseList(
            """{"schema_version":1,"benches":[{"path":"/p","name":"p","pending_operations":[],"redis":null,"sites":[{"name":"s","served":true}]}]}""");
        Assert.Equal("p", Assert.Single(list).Name);
    }

    [Fact]
    public void ADoctorDocumentParsesChecksFixesAndSummary()
    {
        const string json = """
            {"schema_version":1,"bench":"/b","name":"b","profile":"v15-lts","checks":[
              {"id":"assets","group":"bench","label":"Built assets","level":"fail","message":"2 missing","fix_command":"cd /b && bench build","action":"build","status":"fail","fix":"cd /b && bench build"},
              {"id":"agent","group":"service","label":"Agent","level":"ok","message":"running","fix_command":null,"action":null,"status":"ok","fix":""},
              {"id":"old","label":"Old names","status":"warn","fix":"run it","message":"m"},
              {"id":"odd","label":"New level","level":"degraded","message":"?"}],
             "summary":{"ok":1,"warn":1,"fail":1}}
            """;
        var report = BenchJson.ParseDoctor(json);
        Assert.Equal("v15-lts", report.Profile);
        Assert.Equal((1, 1, 1), (report.Ok, report.Warn, report.Fail));
        Assert.Equal(["assets", "agent", "old", "odd"], report.Checks.Select(c => c.Id));
        Assert.Equal(CheckLevel.Fail, report.Checks[0].Level);
        Assert.Equal("cd /b && bench build", report.Checks[0].FixCommand);
        Assert.Null(report.Checks[1].FixCommand);
        Assert.Equal(CheckLevel.Warn, report.Checks[2].Level);
        Assert.Equal("run it", report.Checks[2].FixCommand);
        Assert.Equal(CheckLevel.Unknown, report.Checks[3].Level);
    }

    [Fact]
    public void LogsAndReportParse()
    {
        var tail = BenchJson.ParseLogs("""{"schema_version":1,"file":"/b/logs/bench.log","process":null,"lines":["a","b",null],"truncated":true}""");
        Assert.Equal("/b/logs/bench.log", tail.File);
        Assert.Equal(["a", "b", ""], tail.Lines);
        Assert.Equal("/home/a/Desktop/r.zip", BenchJson.ParseReport("""{"schema_version":1,"zip":"/home/a/Desktop/r.zip","redactions":3}"""));
        Assert.ThrowsAny<System.Text.Json.JsonException>(() => BenchJson.ParseReport("""{"zip":""}"""));
    }

    [Fact]
    public async Task TheRecordedFolderReadsThroughTheFixtureSource()
    {
        var source = new FixtureBenchSource(Fixtures.Dir("recorded-v1"));
        var entry = Assert.Single(await source.ListAsync(TestContext.Current.CancellationToken));
        var status = await source.StatusAsync(entry, TestContext.Current.CancellationToken);
        Assert.Equal(BenchState.Running, status.State);
        Assert.Empty((await source.DoctorAsync(entry.Path, TestContext.Current.CancellationToken)).Checks);
        Assert.Empty((await source.LogsAsync(entry.Path, TestContext.Current.CancellationToken)).Lines);
    }
}
