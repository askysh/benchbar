using System.ComponentModel;
using System.IO.Compression;
using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

public class ReportContextTests
{
    [Fact]
    public void TheContextNamesTheEntryPointThePlaceAndTheProblem()
    {
        Assert.Equal("Opened from: About.", ReportContext.Compose("About"));
        Assert.Equal("Opened from: Tray menu. Where: Main window, Health tab.", ReportContext.Compose("Tray menu", "Main window, Health tab"));
        Assert.Equal("Opened from: Beta banner. Where: Main window, Overview tab. Problem: Start failed.",
            ReportContext.Compose("Beta banner", "Main window, Overview tab", "Start failed."));
    }

    [Fact]
    public void TheContextIsOneShortLine()
    {
        var text = ReportContext.Compose("Report This Problem", "Setup wizard", "line one\r\nline two\n   " + new string('x', 2000));
        Assert.DoesNotContain('\n', text);
        Assert.DoesNotContain('\r', text);
        Assert.True(text.Length <= ReportContext.MaxLength);
        Assert.EndsWith("...", text);
    }

    [Fact]
    public void TheWizardPlaceNamesThePageTheFlowAndTheStep()
    {
        Assert.Equal("Setup wizard, page Install, new bench", ReportContext.Wizard(WizardPage.Install, WizardFlow.NewBench));
        Assert.Equal("Setup wizard, page Check Your PC, existing bench, step wsl_feature", ReportContext.Wizard(WizardPage.Check, WizardFlow.ExistingBench, "wsl_feature"));
    }

    [Fact]
    public void AFailedRowBecomesAProblemSentence()
    {
        var step = new SetupStepInfo(SetupIds.WslFeature, SetupStatus.Missing, "WSL", "WSL is not installed", SetupIds.ActionWslEnable, true);
        Assert.Equal("Step wsl_feature (missing): WSL is not installed", ReportContext.Step(step, null));
        Assert.Equal("Step wsl_feature (missing): the prompt was declined", ReportContext.Step(step, "the prompt was declined"));
    }
}

public class BugReporterTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (IOException) { }
    }

    private static ReportRequest Request(params string[] includes) =>
        new("Ubuntu-24.04", "/home/a/bench", "Opened from: About. Where: Main window, Overview tab.", "0.8.1+abc", includes);

    private TrayOnlyReport Fallback(DateTime? at = null) =>
        new(Path.Combine(_dir, "reports"), () => at ?? new DateTime(2026, 10, 31, 12, 0, 0), "Microsoft Windows 10.0.26300", "akash", @"C:\Users\akash");

    private BugReporter Reporter(FakeProcessRunner runner, string? shim = @"C:\bb\benchbar.exe", DateTime? at = null) => new(runner, () => shim, Fallback(at));

    private static IReadOnlyList<string> Entries(string zip)
    {
        using var archive = ZipFile.OpenRead(zip);
        return archive.Entries.Select(e => e.FullName).ToList();
    }

    private static string ReadEntry(string zip, string name)
    {
        using var archive = ZipFile.OpenRead(zip);
        using var reader = new StreamReader(archive.GetEntry(name)!.Open());
        return reader.ReadToEnd();
    }

    [Fact]
    public void TheShimGetsTheDistroTheSelectedBenchTheContextTheVersionAndTheTrayLog()
    {
        Assert.Equal(
            ["report-windows", "--json", "--distro", "Ubuntu-24.04", "--bench", "/home/a/bench", "--context", "Opened from: About. Where: Main window, Overview tab.", "--tray-version", "0.8.1+abc", "--include", @"C:\x\tray.log"],
            BugReporter.Arguments(Request(@"C:\x\tray.log")));
        Assert.Equal(["report-windows", "--json", "--context", "c", "--tray-version", "v"], BugReporter.Arguments(new ReportRequest(null, null, "c", "v", [])));
    }

    [Fact]
    public async Task AReportTheShimWroteIsUsedAsItIsEvenWithPartsLeftOut()
    {
        var runner = new FakeProcessRunner
        {
            Answer = (_, _) => new ProcessResult(0,
                "{\"schema_version\":1,\"zip\":\"C:\\\\r\\\\benchbar-windows-report-20261031-120000.zip\",\"included\":[\"summary.txt\"],\"skipped\":[{\"part\":\"cli_report\",\"reason\":\"the distro is stopped\"}],\"issue_url\":\"https://github.com/askysh/benchbar/issues/new?template=bug_report_windows.yml&title=x\"}\n", ""),
        };
        var outcome = await Reporter(runner).CreateAsync(Request(), TestContext.Current.CancellationToken);
        Assert.False(outcome.TrayOnly);
        Assert.Equal(@"C:\r\benchbar-windows-report-20261031-120000.zip", outcome.ZipPath);
        Assert.StartsWith("https://github.com/askysh/benchbar/issues/new?template=bug_report_windows.yml", outcome.IssueUrl);
        Assert.Equal(["cli_report: the distro is stopped"], outcome.Skipped);
        Assert.Equal(@"C:\bb\benchbar.exe", runner.Calls[0].File);
        Assert.Equal("report-windows", runner.Calls[0].Args[0]);
        Assert.Equal(BugReporter.Timeout, runner.LastTimeout);
    }

    [Fact]
    public async Task ABlockedBenchbarExeGivesATrayOnlyZipAndAnIssueUrl()
    {
        Directory.CreateDirectory(_dir);
        var log = Path.Combine(_dir, "tray.log");
        File.WriteAllText(log, @"2026-10-31 ui: boom in C:\Users\akash\AppData\x password=hunter2 for akash");
        var runner = new FakeProcessRunner { Throws = new Win32Exception(1260, "blocked") };

        var outcome = await Reporter(runner).CreateAsync(Request(log), TestContext.Current.CancellationToken);

        Assert.True(outcome.TrayOnly);
        Assert.Equal(Path.Combine(_dir, "reports", "benchbar-tray-report-20261031-120000.zip"), outcome.ZipPath);
        Assert.Equal(["summary.txt", "included/tray.log"], Entries(outcome.ZipPath));
        var summary = ReadEntry(outcome.ZipPath, "summary.txt");
        Assert.Contains("Tray version: 0.8.1+abc", summary);
        Assert.Contains("Windows: Microsoft Windows 10.0.26300", summary);
        Assert.Contains(ShimBenchSource.BlockedMessage, summary);
        Assert.Contains("Opened from: About.", summary);
        var copied = ReadEntry(outcome.ZipPath, "included/tray.log");
        Assert.Contains("boom in C:\\Users\\<user>", copied);
        Assert.DoesNotContain("hunter2", copied);
        Assert.DoesNotContain("akash", copied + summary);

        var url = outcome.IssueUrl;
        Assert.StartsWith("https://github.com/askysh/benchbar/issues/new?template=bug_report_windows.yml", url);
        Assert.Contains("&versions=", url);
        Assert.Contains("&windows=", url);
        Assert.Contains("&what=", url);
        Assert.InRange(url.Length, 1, BugReportText.UrlLimit);
        Assert.DoesNotContain("akash", Uri.UnescapeDataString(url));
        Assert.Contains("Windows%20blocked%20benchbar.exe", url);
    }

    [Fact]
    public async Task AMissingShimAlsoGivesTheTrayOnlyReport()
    {
        var outcome = await Reporter(new FakeProcessRunner(), shim: null).CreateAsync(Request(), TestContext.Current.CancellationToken);
        Assert.True(outcome.TrayOnly);
        Assert.Contains(ShimBenchSource.NotFoundMessage, ReadEntry(outcome.ZipPath, "summary.txt"));
    }

    [Fact]
    public async Task AShimThatFailsWithNoReportGivesTheTrayOnlyReportWithItsLine()
    {
        var runner = new FakeProcessRunner { Answer = (_, _) => new ProcessResult(1, "", "\nreport-windows: cannot write the zip\nsecond\n") };
        var outcome = await Reporter(runner).CreateAsync(Request(), TestContext.Current.CancellationToken);
        Assert.True(outcome.TrayOnly);
        Assert.Equal("report-windows: cannot write the zip", outcome.Note);
        var empty = new FakeProcessRunner { Answer = (_, _) => new ProcessResult(0, "not json\n", "") };
        Assert.True((await Reporter(empty, at: new DateTime(2026, 10, 31, 12, 0, 1)).CreateAsync(Request(), TestContext.Current.CancellationToken)).TrayOnly);
    }

    [Fact]
    public async Task ACancelledReportIsNotTurnedIntoAFallback()
    {
        using var cts = new CancellationTokenSource();
        await cts.CancelAsync();
        var runner = new FakeProcessRunner { Throws = new OperationCanceledException() };
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Reporter(runner).CreateAsync(Request(), cts.Token));
    }

    [Fact]
    public async Task ALongContextKeepsTheIssueUrlUnderTheLimit()
    {
        var long1 = new ReportRequest(null, null, ReportContext.Compose("Report This Problem", "Setup wizard", new string('é', 900) + @" C:\Users\akash\x"), "0.8.1", []);
        var runner = new FakeProcessRunner { Throws = new Win32Exception(5, "denied") };
        var outcome = await Reporter(runner).CreateAsync(long1, TestContext.Current.CancellationToken);
        Assert.InRange(outcome.IssueUrl.Length, 1, BugReportText.UrlLimit);
        Assert.StartsWith("https://github.com/askysh/benchbar/issues/new?template=bug_report_windows.yml", outcome.IssueUrl);
    }

    [Fact]
    public async Task OnlyTheNewestTenTrayReportsStay()
    {
        var runner = new FakeProcessRunner { Throws = new Win32Exception(5, "denied") };
        for (var i = 0; i < 12; i++)
            await Reporter(runner, at: new DateTime(2026, 10, 31, 12, 0, i)).CreateAsync(Request(), TestContext.Current.CancellationToken);
        var files = Directory.GetFiles(Path.Combine(_dir, "reports"), "benchbar-tray-report-*.zip").Select(Path.GetFileName).Order().ToList();
        Assert.Equal(TrayOnlyReport.Keep, files.Count);
        Assert.Equal("benchbar-tray-report-20261031-120002.zip", files[0]);
    }

    [Fact]
    public async Task TwoReportsInTheSameSecondDoNotOverwriteEachOther()
    {
        var runner = new FakeProcessRunner { Throws = new Win32Exception(5, "denied") };
        var a = await Reporter(runner).CreateAsync(Request(), TestContext.Current.CancellationToken);
        var b = await Reporter(runner).CreateAsync(Request(), TestContext.Current.CancellationToken);
        Assert.NotEqual(a.ZipPath, b.ZipPath);
        Assert.True(File.Exists(a.ZipPath));
        Assert.True(File.Exists(b.ZipPath));
    }
}

public class ObserveTests
{
    [Fact]
    public async Task AForgottenTaskThatFailsIsReported()
    {
        var seen = new TaskCompletionSource<Exception>();
        Observe.OnFault = seen.SetResult;
        try
        {
            static async Task Fail()
            {
                await Task.Yield();
                throw new InvalidOperationException("boom");
            }
            Fail().Forget();
            var ex = await seen.Task.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
            Assert.Equal("boom", ex.Message);
        }
        finally
        {
            Observe.OnFault = null;
        }
    }

    [Fact]
    public void ACompletedFailureIsReportedAtOnceAndASuccessIsSilent()
    {
        var seen = new List<Exception>();
        Observe.OnFault = seen.Add;
        try
        {
            Task.CompletedTask.Forget();
            Task.FromException(new IOException("gone")).Forget();
            Assert.Equal(["gone"], seen.Select(e => e.Message));
        }
        finally
        {
            Observe.OnFault = null;
        }
    }
}

public class PlanReviewDetachTests
{
    [Fact]
    public async Task StopWaitingKeepsTheRunGoingAndSaysHowItEnded()
    {
        var runner = new ScriptedStreamRunner();
        runner.On(a => a.Contains("--dry-run")).Print(CliFixture.Lines("site-add-plan.json"));
        var held = runner.On(a => a.Contains("--apply")).Print(CliFixture.Lines("site-add-apply.jsonl")).Hold();
        var model = new PlanReviewModel(PlanReviewRequest.Tokened("Add Site", ["site", "add", "x"]), new CliClient(runner, () => "benchbar.exe"));
        await model.LoadAsync(TestContext.Current.CancellationToken);
        var run = model.ConfirmAsync();
        await held.Started.Task;
        Assert.True(model.CanStopWaiting);
        Assert.False(model.CanStop); // a restore is not safe to kill, but the sheet can still be left

        string? said = null;
        model.Detach(line => said = line);
        model.Dispose(); // the sheet closed
        Assert.Equal(PlanPhase.Running, model.Phase);
        Assert.Null(said);

        held.Release();
        await run;
        Assert.Equal(PlanPhase.Finished, model.Phase);
        Assert.StartsWith("Add Site: done", said);
    }

    [Fact]
    public async Task ClosingASheetThatWasNotDetachedStillStopsTheRun()
    {
        var runner = new ScriptedStreamRunner();
        runner.On(a => a.Contains("--dry-run")).Print(CliFixture.Lines("site-add-plan.json"));
        var held = runner.On(a => a.Contains("--apply")).Print(CliFixture.Lines("site-add-apply.jsonl")).Hold();
        var model = new PlanReviewModel(PlanReviewRequest.Tokened("Add Site", ["site", "add", "x"]), new CliClient(runner, () => "benchbar.exe"));
        await model.LoadAsync(TestContext.Current.CancellationToken);
        var run = model.ConfirmAsync();
        await held.Started.Task;
        model.Dispose();
        await run;
        Assert.NotEqual(PlanPhase.Finished, model.Phase);
    }

    [Fact]
    public void DetachingOnlyWorksWhileTheRunGoes()
    {
        var model = new PlanReviewModel(PlanReviewRequest.Tokened("Add Site", ["site", "add", "x"]), new CliClient(new ScriptedStreamRunner(), () => "benchbar.exe"));
        model.Detach(_ => { });
        Assert.False(model.IsDetached);
    }
    [Theory]
    [InlineData("https://github.com/askysh/benchbar/issues/new?template=bug_report_windows.yml&title=x", true)]
    [InlineData("https://github.com/askysh/benchbar/issues/new?template=bug_report_windows.yml", true)]
    [InlineData("https://evil.example/issues/new?template=bug_report_windows.yml", false)]
    [InlineData("file:///C:/Windows/System32/calc.exe", false)]
    [InlineData("https://github.com/askysh/benchbar/issues/new?template=bug_report_windows.ymlx", false)]
    [InlineData(null, false)]
    public void OnlyThisRepositorysIssueFormIsOpened(string? url, bool kept)
    {
        Assert.Equal(kept ? url : BugReportText.IssueBase, BugReportText.SafeIssueUrl(url));
    }
}
