using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>Update Now: the check through benchbar.exe, the offer in each state, the update window's exact start, and the "updated" notice.</summary>
public class SelfUpdateTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (IOException) { }
    }

    private static string Json(string install, bool available = true, string? latest = "0.9.0", string? error = null) =>
        "{\"current\":\"0.8.4\",\"latest\":" + (latest is null ? "null" : "\"" + latest + "\"")
        + ",\"update_available\":" + (available ? "true" : "false")
        + ",\"install\":\"" + install + "\",\"error\":" + (error is null ? "null" : "\"" + error + "\"")
        + ",\"extra\":{\"ignored\":1}}";

    private static SelfUpdateStatus Status(string install, bool available = true, string? latest = "0.9.0", string? error = null) =>
        SelfUpdateStatus.Parse(Json(install, available, latest, error))!;

    // --- parsing ---

    [Fact]
    public void TheShimsAnswerIsReadAndUnknownFieldsAreIgnored()
    {
        var status = Status("installer");
        Assert.Equal("0.8.4", status.Current);
        Assert.Equal("0.9.0", status.Latest);
        Assert.True(status.UpdateAvailable);
        Assert.Equal(InstallKind.Installer, status.Install);
        Assert.Null(status.Error);

        Assert.Equal(InstallKind.Store, Status("store").Install);
        Assert.Equal(InstallKind.Other, Status("other").Install);
        Assert.Equal(InstallKind.Other, Status("winget").Install); // a kind this tray does not know never gets Update Now
        Assert.Equal("0.9.0", Status("installer", latest: "v0.9.0").Latest);
        Assert.Null(Status("installer", latest: null).Latest);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("""{"current":"0.8.4","latest":"0.9.0","update_available":true}""")] // the Linux CLI's answer has no install
    [InlineData("""{"install":"installer"}""")]
    public void AnAnswerThatIsNotTheShimsIsNoAnswer(string output) => Assert.Null(SelfUpdateStatus.Parse(output));

    [Fact]
    public void TheShimsReleasePageIsUsedWhenItGivesOne()
    {
        var status = SelfUpdateStatus.Parse("""{"schema_version":1,"current":"0.8.4","latest":"0.9.0","update_available":true,"install":"installer","release_url":"https://github.com/askysh/benchbar/releases/tag/v0.9.0-win","error":null,"cli":{"current":"0.9.0"}}""");
        Assert.Equal("https://github.com/askysh/benchbar/releases/tag/v0.9.0-win", UpdatePlanner.Offer(status)!.Url);
        var odd = SelfUpdateStatus.Parse("""{"current":"0.8.4","latest":"0.9.0","update_available":true,"install":"installer","release_url":"file:///c:/x"}""");
        Assert.Equal("https://github.com/askysh/benchbar/releases/tag/v0.9.0", UpdatePlanner.Offer(odd)!.Url); // only an https page is opened
    }

    [Fact]
    public void TheDocumentIsFoundAmongOtherLines() =>
        Assert.Equal(InstallKind.Installer, SelfUpdateStatus.Parse("checking...\r\n" + Json("installer") + "\r\n")!.Install);

    // --- the offer in each state ---

    [Fact]
    public void TheInstallersInstallGetsUpdateNow()
    {
        var offer = UpdatePlanner.Offer(Status("installer"))!;
        Assert.True(offer.CanUpdateNow);
        Assert.Equal("0.9.0", offer.Version);
        Assert.Equal("https://github.com/askysh/benchbar/releases/tag/v0.9.0", offer.Url);
        Assert.Equal(UpdateLinks.InstallCommand, offer.Command);
        Assert.Equal("BenchBar 0.9.0 is out.", UpdatePlanner.CheckText(new SelfUpdateCheck(Status("installer"), null)));
    }

    [Fact]
    public void AStoreCopyGetsNoBannerAndTheStoreLine()
    {
        Assert.Null(UpdatePlanner.Offer(Status("store")));
        Assert.Equal(UpdateLinks.StoreLine, UpdatePlanner.CheckText(new SelfUpdateCheck(Status("store"), null)));
    }

    [Fact]
    public void ALooseCopyOrDevBuildGetsTheCopyLineOnly()
    {
        var offer = UpdatePlanner.Offer(Status("other"))!;
        Assert.False(offer.CanUpdateNow);
        Assert.Equal(UpdateLinks.InstallCommand, offer.Command);
    }

    [Fact]
    public void ACheckErrorOffersNothingAndSaysWhyOnlyWhenAsked()
    {
        var status = Status("installer", error: "GitHub did not answer");
        Assert.Null(UpdatePlanner.Offer(status));
        Assert.Equal("Could not check for updates: GitHub did not answer", UpdatePlanner.CheckText(new SelfUpdateCheck(status, null)));
        Assert.Equal("Could not check for updates: benchbar.exe was not found next to BenchBar.",
            UpdatePlanner.CheckText(SelfUpdateCheck.Failed("benchbar.exe was not found next to BenchBar.")));
    }

    [Fact]
    public void NothingNewerOrADismissedVersionOffersNothing()
    {
        Assert.Null(UpdatePlanner.Offer(Status("installer", available: false)));
        Assert.Equal("You have the latest version.", UpdatePlanner.CheckText(new SelfUpdateCheck(Status("installer", available: false), null)));
        Assert.Null(UpdatePlanner.Offer(Status("installer"), dismissedVersion: "0.9.0"));
        Assert.NotNull(UpdatePlanner.Offer(Status("installer"), dismissedVersion: "0.8.9")); // a newer one than the dismissed comes back
        Assert.Null(UpdatePlanner.Offer(null));
    }

    [Fact]
    public void TheSwitchOffMeansNoCheckWhenTheWindowOpens()
    {
        var hours = (long)TimeSpan.FromHours(1).TotalMilliseconds;
        Assert.False(UpdatePlanner.CheckDue(enabled: false, 0, 100));
        Assert.True(UpdatePlanner.CheckDue(enabled: true, 0, 100));                    // never checked
        Assert.False(UpdatePlanner.CheckDue(enabled: true, 1, 1 + 5 * hours));         // within six hours
        Assert.True(UpdatePlanner.CheckDue(enabled: true, 1, 1 + 6 * hours));
    }

    // --- the check through benchbar.exe ---

    private const string Shim = @"C:\Users\Pat Doe\AppData\Local\Programs\BenchBar\benchbar.exe";

    [Fact]
    public async Task TheCheckAsksTheShimOfThisVersionWithTheExactArguments()
    {
        var runner = new FakeProcessRunner
        {
            Answer = (_, args) => args[0] == "--shim-version" ? new ProcessResult(0, "benchbar.exe 0.8.4\n", "") : new ProcessResult(0, Json("installer"), ""),
        };
        var check = await new SelfUpdateClient(runner, () => Shim, "0.8.4+abc").CheckAsync(CancellationToken.None);
        Assert.Null(check.Problem);
        Assert.Equal(InstallKind.Installer, check.Status!.Install);
        Assert.Equal([(Shim, new[] { "--shim-version" }), (Shim, new[] { "self-update", "--check", "--json" })],
            runner.Calls.Select(c => (c.File, c.Args)));
    }

    [Fact]
    public async Task AShimOfAnotherVersionIsNeverAskedToUpdate()
    {
        // an older shim forwards an unknown command to the Linux CLI, which would boot the distro
        var runner = new FakeProcessRunner { Answer = (_, _) => new ProcessResult(0, "benchbar.exe 0.8.2", "") };
        var check = await new SelfUpdateClient(runner, () => Shim, "0.8.4").CheckAsync(CancellationToken.None);
        Assert.Null(check.Status);
        Assert.Contains("not the same version", check.Problem);
        Assert.Single(runner.Calls);
    }

    [Theory]
    [InlineData("benchbar.exe 0.8.5")] // a newer patch knows the command: asking it is how a tray with a locked DLL is fixed
    [InlineData("benchbar.exe 0.9.0")]
    public async Task ANewerShimIsAskedForTheCheck(string shimLine)
    {
        var runner = new FakeProcessRunner
        {
            Answer = (_, args) => args[0] == "--shim-version" ? new ProcessResult(0, shimLine + "\n", "") : new ProcessResult(0, Json("installer"), ""),
        };
        var check = await new SelfUpdateClient(runner, () => Shim, "0.8.4").CheckAsync(CancellationToken.None);
        Assert.Null(check.Problem);
        Assert.Equal(2, runner.Calls.Count);
    }

    [Fact]
    public async Task NoShimOrAShimThatCannotStartIsAProblemNotAThrow()
    {
        var missing = await new SelfUpdateClient(new FakeProcessRunner(), () => null, "0.8.4").CheckAsync(CancellationToken.None);
        Assert.Contains("not found", missing.Problem);

        var blocked = new FakeProcessRunner { Throws = new Win32Exception(4551) };
        var check = await new SelfUpdateClient(blocked, () => Shim, "0.8.4").CheckAsync(CancellationToken.None);
        Assert.Equal(ShimStart.BlockedMessage, check.Problem);
    }

    [Fact]
    public async Task AnAnswerThatIsNotJsonIsAProblem()
    {
        var runner = new FakeProcessRunner
        {
            Answer = (_, args) => args[0] == "--shim-version" ? new ProcessResult(0, "benchbar.exe 0.8.4", "") : new ProcessResult(1, "", "unknown command self-update\n"),
        };
        var check = await new SelfUpdateClient(runner, () => Shim, "0.8.4").CheckAsync(CancellationToken.None);
        Assert.Equal("unknown command self-update", check.Problem);
    }

    // --- Update Now: the exact start ---

    private sealed class FakeStarted : IStartedProcess
    {
        public bool HasExited { get; set; }

        public event Action? Exited;

        public void Exit()
        {
            HasExited = true;
            Exited?.Invoke();
        }
    }

    [Fact]
    public void UpdateNowStartsAVisiblePowerShellWindowWithTheEncodedScript()
    {
        var info = SelfUpdateLauncher.StartInfo(Shim, @"C:\Windows\system32", @"C:\Users\Pat Doe");
        Assert.Equal(@"C:\Windows\system32\WindowsPowerShell\v1.0\powershell.exe", info.FileName);
        Assert.True(info.UseShellExecute);                   // a window of its own, not a hidden child of the tray
        Assert.False(info.CreateNoWindow);
        Assert.Equal(ProcessWindowStyle.Normal, info.WindowStyle);
        Assert.Equal(@"C:\Users\Pat Doe", info.WorkingDirectory); // not the install folder the installer replaces files in
        Assert.Empty(info.ArgumentList);
        Assert.StartsWith("-NoProfile -NoLogo -EncodedCommand ", info.Arguments);
        var encoded = info.Arguments["-NoProfile -NoLogo -EncodedCommand ".Length..];
        Assert.DoesNotContain(' ', encoded);

        var script = Encoding.Unicode.GetString(Convert.FromBase64String(encoded));
        Assert.Equal(string.Join("\r\n",
            "$Host.UI.RawUI.WindowTitle = 'BenchBar update'",
            "Write-Host 'Updating BenchBar. BenchBar closes now and starts again when the update is done.'",
            "Write-Host ''",
            @"& 'C:\Users\Pat Doe\AppData\Local\Programs\BenchBar\benchbar.exe' self-update --yes",
            "$code = $LASTEXITCODE",
            "Write-Host ''",
            "if ($code -eq 0) { Write-Host 'The update finished.' }",
            "else { Write-Host ('The update did not finish (exit code ' + $code + '). Read the lines above. To update by hand, run this line in PowerShell:'); Write-Host 'irm https://raw.githubusercontent.com/askysh/benchbar/main/install.ps1 | iex' }",
            "Write-Host ''",
            "$null = Read-Host 'Press Enter to close this window'",
            "exit $code"), script);
    }

    [Theory]
    [InlineData(@"C:\Users\Pat Doe\b.exe", @"'C:\Users\Pat Doe\b.exe'")]
    [InlineData(@"C:\Users\O'Brien\b.exe", @"'C:\Users\O''Brien\b.exe'")]
    [InlineData("C:\\Users\\O\u2019Brien\\b.exe", "'C:\\Users\\O\u2019\u2019Brien\\b.exe'")]
    [InlineData(@"C:\Users\A&B %USERNAME% $env:x\b.exe", @"'C:\Users\A&B %USERNAME% $env:x\b.exe'")]
    public void TheShimPathIsOneSingleQuotedStringWhateverTheProfileHolds(string path, string quoted)
    {
        Assert.Equal(quoted, SelfUpdateLauncher.PowerShellQuote(path));
        Assert.Contains("& " + quoted + " self-update --yes", SelfUpdateLauncher.Script(path));
    }

    [Fact]
    public void ASecondUpdateNowWhileTheWindowRunsStartsNothing()
    {
        var started = new List<ProcessStartInfo>();
        var process = new FakeStarted();
        var launcher = new SelfUpdateLauncher(() => Shim, info => { started.Add(info); return process; }, @"C:\Windows\system32", @"C:\Users\Pat Doe");
        var ended = 0;
        launcher.Ended += () => ended++;

        Assert.Equal(UpdateStartKind.Started, launcher.Start().Kind);
        Assert.True(launcher.IsRunning);
        var again = launcher.Start();
        Assert.Equal(UpdateStartKind.AlreadyRunning, again.Kind);
        Assert.Equal(SelfUpdateLauncher.AlreadyRunningText, again.Message);
        Assert.Single(started);

        process.Exit(); // the update failed and the window was closed while the tray still runs
        Assert.Equal(1, ended);
        Assert.False(launcher.IsRunning);
        process.HasExited = false;
        Assert.Equal(UpdateStartKind.Started, launcher.Start().Kind); // Update Now works again
        Assert.Equal(2, started.Count);
    }

    [Fact]
    public void NoShimOrAFailedStartIsSaidAndNothingRuns()
    {
        var missing = new SelfUpdateLauncher(() => null, _ => throw new InvalidOperationException("must not start"), @"C:\Windows\system32", @"C:\");
        var none = missing.Start();
        Assert.Equal(UpdateStartKind.ShimMissing, none.Kind);
        Assert.Equal(ShimStart.NotFoundMessage, none.Message);

        var refused = new SelfUpdateLauncher(() => Shim, _ => throw new Win32Exception(5, "Access is denied"), @"C:\Windows\system32", @"C:\");
        var failed = refused.Start();
        Assert.Equal(UpdateStartKind.Failed, failed.Kind);
        Assert.Contains("Access is denied", failed.Message);
        Assert.False(refused.IsRunning);

        var nothing = new SelfUpdateLauncher(() => Shim, _ => null, @"C:\Windows\system32", @"C:\");
        Assert.Equal(UpdateStartKind.Failed, nothing.Start().Kind);
    }

    // --- "BenchBar was updated to X" ---

    [Fact]
    public void AFirstInstallRecordsTheVersionAndSaysNothing()
    {
        var d = UpdatedNotice.Decide(null, "0.8.4", hadTraySection: false);
        Assert.False(d.Show);
        Assert.Equal("0.8.4", d.Record);
    }

    [Fact]
    public void ANormalStartChangesNothing()
    {
        var d = UpdatedNotice.Decide("0.8.4", "0.8.4+abc", hadTraySection: true);
        Assert.False(d.Show);
        Assert.Null(d.Record);
    }

    [Fact]
    public void ANewerVersionSaysItOnceAndRecordsIt()
    {
        var d = UpdatedNotice.Decide("0.8.4", "0.9.0", hadTraySection: true);
        Assert.True(d.Show);
        Assert.Equal("0.9.0", d.Record);
        Assert.Equal("BenchBar was updated to 0.9.0.", UpdatedNotice.Text(d.Version!));
        Assert.Equal("What's New", UpdatedNotice.ActionLabel);
        Assert.Equal("https://github.com/askysh/benchbar/releases/tag/v0.9.0", UpdateLinks.ReleasePage(d.Version!));
        Assert.False(UpdatedNotice.Decide(d.Record, "0.9.0", hadTraySection: true).Show); // the next start is a normal one
        Assert.True(UpdatedNotice.Decide("0.9.9", "0.10.0", hadTraySection: true).Show); // by number, not by text
    }

    [Fact]
    public void AnOlderVersionRecordsItselfQuietly()
    {
        var d = UpdatedNotice.Decide("0.9.0", "0.8.4", hadTraySection: true);
        Assert.False(d.Show);
        Assert.Equal("0.8.4", d.Record);
    }

    [Fact]
    public void AnUpdateFromATrayThatRecordedNoVersionIsStillAnUpdate()
    {
        var d = UpdatedNotice.Decide(null, "0.8.4", hadTraySection: true);
        Assert.True(d.Show);
        Assert.Equal("0.8.4", d.Record);
    }

    [Fact]
    public void ADevelopmentBuildNeitherShowsNorRecords()
    {
        var d = UpdatedNotice.Decide("0.8.4", "0.0.0-dev", hadTraySection: true);
        Assert.False(d.Show);
        Assert.Null(d.Record);
    }

    [Fact]
    public void TheConfigKeepsTheVersionAndTheHint()
    {
        Directory.CreateDirectory(_dir);
        var path = Path.Combine(_dir, "config.json");
        var fresh = TrayConfig.Load(path);
        Assert.False(fresh.HadTraySection);
        Assert.Null(fresh.LastVersion);
        Assert.False(fresh.RunningHintShown);

        fresh.LastVersion = "0.8.4";
        fresh.RunningHintShown = true;
        fresh.Save();
        var again = TrayConfig.Load(path);
        Assert.True(again.HadTraySection);
        Assert.Equal("0.8.4", again.LastVersion);
        Assert.True(again.RunningHintShown);
    }
}
