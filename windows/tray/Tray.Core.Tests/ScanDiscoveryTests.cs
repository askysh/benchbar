using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using Xunit;
using static Tray.Core.Tests.CliFixture;

namespace Tray.Core.Tests;

/// <summary>A WSL that starts nothing: a home folder, and a table of Windows paths with their Linux paths.</summary>
internal sealed class FakeWsl : IWslHost
{
    public string? Home { get; set; } = "/home/akash";
    public Dictionary<string, string> Paths { get; } = new(StringComparer.OrdinalIgnoreCase);
    public List<string> Converted { get; } = [];
    public string ConvertError { get; set; } = "wslpath failed";

    public Task<string?> HomeAsync(CancellationToken ct) => Task.FromResult(Home);

    public Task<PathConversion> ToLinuxPathAsync(string path, CancellationToken ct)
    {
        var text = path.Trim();
        if (!WslPaths.IsWindowsPath(text)) return Task.FromResult(new PathConversion(text, null));
        Converted.Add(text);
        return Task.FromResult(Paths.TryGetValue(text, out var linux) ? new PathConversion(linux, null) : new PathConversion(null, ConvertError));
    }
}

/// <summary>Find Benches: the parsers, the models and the exact calls. Nothing here starts a process.</summary>
public class ScanDiscoveryTests
{
    private const string Projects = "/home/akash/projects";
    private const string Managed = Projects + "/managed-bench";
    private const string Added = Projects + "/added-bench";
    private const string Loose = Projects + "/loose-bench";


    private static (DiscoveryModel Model, ScriptedStreamRunner Runner, FakeWsl Wsl, RecentFolders Recent) Make()
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var (client, runner) = CliFixture.Scripted();
        var wsl = new FakeWsl();
        var recent = new RecentFolders();
        runner.On("scan").Print(CliFixture.Lines("scan-result.json"));
        runner.On("list").Print(CliFixture.Lines("scan-list.json"));
        return (new DiscoveryModel(client, wsl, recent), runner, wsl, recent);
    }

    // --- parsers ---

    [Fact]
    public void TheScanDocumentGivesBenchesPortsAndWarnings()
    {
        var scan = ScanJson.ParseScan(Doc("scan-result.json"));
        Assert.Equal(Projects, scan.Root);
        Assert.Equal([Managed, Added, Loose], scan.Benches.Select(b => b.Path));
        var managed = scan.Benches[0];
        Assert.Equal("managed-bench", managed.Name);
        Assert.Equal("managed.localhost", managed.Site);
        Assert.Equal("http://managed.localhost:8000", managed.WebUrl);
        Assert.Equal(new FoundPorts(8000, 9000, 11000, 13000), managed.Ports);
        Assert.True(managed.ServiceInstalled);
        Assert.True(managed.IsDefault);
        Assert.False(scan.Benches[1].ServiceInstalled);
        Assert.Equal(3, scan.Warnings.Count);
    }

    [Fact]
    public void AnEmptyScanIsAnEmptyListAndAMissingArrayIsRefused()
    {
        Assert.Empty(ScanJson.ParseScan(Doc("scan-empty.json")).Benches);
        Assert.Throws<FormatException>(() => ScanJson.ParseScan(new JsonObject { ["root"] = "/x" }));
        Assert.Throws<FormatException>(() => ScanJson.ParseList(new JsonObject()));
    }

    [Fact]
    public void ADocumentWithoutPortsStillParses()
    {
        var doc = (JsonObject)JsonNode.Parse("""{"benches":[{"path":"/home/a/x"}]}""")!;
        var bench = ScanJson.ParseList(doc).Single();
        Assert.Equal("x", bench.Name);
        Assert.Equal(new FoundPorts(0, 0, 0, 0), bench.Ports);
    }

    [Fact]
    public void ManyStoppedAtWarningsBecomeOneLine()
    {
        var lines = ScanJson.WarningLines(ScanJson.ParseScan(Doc("scan-result.json")).Warnings);
        Assert.Equal(2, lines.Count);
        Assert.Equal("Stopped at 6 folders deep in 2 folders: a bench deeper than that is not found. Choose a folder closer to it.", lines[0]);
        Assert.Equal("Cannot read /home/akash/projects/locked", lines[1]);
        Assert.Equal(["Stopped at 4 folders deep: /x"], ScanJson.WarningLines(["Stopped at 4 folders deep: /x"]));
        Assert.Equal("1 scan warning", ScanJson.WarningsTitle(1));
        Assert.Equal("2 scan warnings", ScanJson.WarningsTitle(2));
    }

    [Fact]
    public void ThePortPlanGivesEntriesATokenAndASummary()
    {
        var plan = SetupPlan.Parse(Doc("scan-ports-plan.json"));
        Assert.Equal("aaaa1111", plan.Token);
        Assert.True(plan.CanApply);
        Assert.Equal(2, plan.Entries.Count);
        Assert.False(plan.Entries[0].Moves);
        Assert.True(plan.Entries[1].Moves);
        var summary = plan.Summary();
        Assert.Contains("added-bench: web port 8001 stays.", summary);
        Assert.Contains("loose-bench: web port 8001 moves to 8002 (mode automatic).", summary);
        Assert.Contains("Conflict: 8001 reserved by /home/akash/projects/added-bench", summary);
        var blocked = SetupPlan.Parse(Doc("scan-ports-plan-blocked.json"));
        Assert.False(blocked.CanApply);
        Assert.Equal("loose-bench: it is running; stop it first", blocked.FirstBlock);
        Assert.Throws<FormatException>(() => SetupPlan.Parse(new JsonObject()));
    }

    // --- the exact calls ---

    [Fact]
    public void EveryCallHasTheArgumentsTheCliDocuments()
    {
        Assert.Equal(["scan", "/home/a/p", "--json"], DiscoveryModel.ScanArgs("/home/a/p"));
        Assert.Equal(["list", "--json"], DiscoveryModel.ListArgs());
        Assert.Equal(["register", "--json", "--", "/a", "/b"], DiscoveryModel.RegisterArgs(["/a", "/b"]));
        Assert.Equal(["ports", "plan", "--json", "--", "/a", "/b"], DiscoveryModel.PortsPlanArgs(["/a", "/b"]));
        Assert.Equal(["ports", "apply", "TOKEN", "--yes", "--", "/a", "/b"], DiscoveryModel.PortsApplyArgs("TOKEN", ["/a", "/b"]));
        Assert.Equal(["adopt", "/a", "--dry-run", "--json"], DiscoveryModel.AdoptPlanArgs("/a"));
        Assert.Equal(["adopt", "/a", "--yes", "--json"], DiscoveryModel.AdoptApplyArgs("/a"));
    }

    [Fact]
    public async Task SetUpManagementReadsTheAdoptPlanAndAppliesWithSudoThroughTheEnv()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("adopt", Added, "--dry-run").Print(CliFixture.Lines("scan-adopt-plan.jsonl"));
        var request = DiscoveryModel.AdoptRequest(Added, "added-bench");
        Assert.Equal("Set Up Management for added-bench", request.Title);
        Assert.True(request.UsesSudoEnv);
        Assert.Equal(["adopt", Added, "--dry-run", "--json"], request.PlanArgs);
        Assert.Equal(["adopt", Added, "--yes", "--json"], request.ApplyArgs(new PlanDocument([], [], [], [], [], null, true, true, new JsonObject())));
        SynchronizationContext.SetSynchronizationContext(null);
        using var model = new PlanReviewModel(request, client);
        await model.LoadAsync(TestContext.Current.CancellationToken);
        Assert.Equal(PlanPhase.Review, model.Phase);
        Assert.Equal("Write the systemd unit", model.Plan!.Steps.Single().Name);
    }

    // --- states and the scan ---

    [Fact]
    public async Task ThePaneStartsAtTheHomeFolderFromWsl()
    {
        var (model, _, wsl, recent) = Make();
        await model.EnterAsync(TestContext.Current.CancellationToken);
        Assert.Equal("/home/akash", model.Folder);
        model.Folder = "/srv/x";
        await model.EnterAsync(TestContext.Current.CancellationToken);
        Assert.Equal("/srv/x", model.Folder); // typed text is kept

        var (second, _, wsl2, recent2) = Make();
        recent2.Add("/home/akash/work");
        await second.EnterAsync(TestContext.Current.CancellationToken);
        Assert.Equal("/home/akash/work", second.Folder); // the last folder comes first

        var (third, _, wsl3, _) = Make();
        wsl3.Home = null;
        await third.EnterAsync(TestContext.Current.CancellationToken);
        Assert.Equal("~", third.Folder);
        _ = (wsl, recent);
    }

    [Fact]
    public async Task AScanListsEachBenchWithItsStateAndSelectsTheOnesNotAdopted()
    {
        var (model, runner, _, recent) = Make();
        model.Folder = Projects;
        await model.ScanAsync(TestContext.Current.CancellationToken);
        Assert.Equal(["scan", Projects, "--json"], runner.Runs[0].Args);
        Assert.Equal(["list", "--json"], runner.Runs[1].Args);
        Assert.False(model.IsScanning);
        Assert.True(model.HasScanned);
        Assert.Equal(3, model.Results.Count);
        Assert.Equal(FoundState.Managed, model.StateOf(model.Results[0]));
        Assert.Equal(FoundState.AddedNeedsSetup, model.StateOf(model.Results[1]));
        Assert.Equal(FoundState.NotAdopted, model.StateOf(model.Results[2]));
        Assert.Equal([Added, Loose], model.SelectablePaths.Order());
        Assert.Equal([Loose], model.AvailablePaths);
        Assert.Equal([Loose], model.Selected);
        Assert.False(model.HasPortConflict(model.Results[0]));
        Assert.True(model.HasPortConflict(model.Results[1]));
        Assert.True(model.HasPortConflict(model.Results[2]));
        Assert.Equal([Projects], recent.Items);
        Assert.Equal(2, model.WarningLines.Count);
    }

    [Fact]
    public async Task SelectAllDeselectAllAndASingleBox()
    {
        var (model, _, _, _) = Make();
        model.Folder = Projects;
        await model.ScanAsync(TestContext.Current.CancellationToken);
        model.DeselectAll();
        Assert.Empty(model.Selected);
        Assert.False(model.CanSetUp);
        model.SelectAll();
        Assert.Equal([Added, Loose], model.Selected.Order());
        Assert.True(model.AllSelected);
        model.SetSelected(Managed, true); // a managed bench has no box
        Assert.DoesNotContain(Managed, model.Selected);
        model.SetSelected(Added, false);
        Assert.Equal([Loose], model.Selected);
        Assert.Equal([Loose], model.SelectedInOrder());
    }

    [Fact]
    public async Task AFolderWithNoBenchesSaysSo()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("scan").Print(CliFixture.Lines("scan-empty.json"));
        runner.On("list").Print(CliFixture.Lines("scan-list.json"));
        SynchronizationContext.SetSynchronizationContext(null);
        var model = new DiscoveryModel(client, new FakeWsl(), new RecentFolders()) { Folder = "/home/akash/empty" };
        await model.ScanAsync(TestContext.Current.CancellationToken);
        Assert.True(model.HasScanned);
        Assert.Empty(model.Results);
        Assert.Null(model.Error);
    }

    [Fact]
    public async Task AFailedScanShowsTheCliSentenceAndKeepsNoResults()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("scan").Fail(1, "scan: /nope is not a folder");
        SynchronizationContext.SetSynchronizationContext(null);
        var model = new DiscoveryModel(client, new FakeWsl(), new RecentFolders()) { Folder = "/nope" };
        await model.ScanAsync(TestContext.Current.CancellationToken);
        Assert.Contains("/nope is not a folder", model.Error);
        Assert.False(model.HasScanned);
        Assert.False(model.IsScanning);
    }

    [Fact]
    public async Task CancelScanStopsTheCallAndSaysSo()
    {
        var (client, runner) = CliFixture.Scripted();
        var held = runner.On("scan").Hold();
        SynchronizationContext.SetSynchronizationContext(null);
        var model = new DiscoveryModel(client, new FakeWsl(), new RecentFolders()) { Folder = Projects };
        var scan = model.ScanAsync(TestContext.Current.CancellationToken);
        await held.Started.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        Assert.True(model.IsScanning);
        model.CancelScan();
        await scan;
        Assert.False(model.IsScanning);
        Assert.Equal("Scan cancelled.", model.Message);
        Assert.Empty(model.Results);
        Assert.False(model.HasScanned);
    }

    [Fact]
    public async Task TheFolderIsResolvedInsideLinux()
    {
        var (model, runner, wsl, _) = Make();
        wsl.Paths[@"C:\dev\benches"] = "/mnt/c/dev/benches";

        Assert.Equal("/home/akash/projects", await model.ResolveFolderAsync("~/projects/", TestContext.Current.CancellationToken));
        Assert.Equal("/home/akash", await model.ResolveFolderAsync("~", TestContext.Current.CancellationToken));
        Assert.Equal("/srv/x", await model.ResolveFolderAsync("  /srv/x  ", TestContext.Current.CancellationToken));
        Assert.Equal("/", await model.ResolveFolderAsync("/", TestContext.Current.CancellationToken));
        Assert.Equal("/mnt/c/dev/benches", await model.ResolveFolderAsync(@"C:\dev\benches", TestContext.Current.CancellationToken));
        Assert.Equal([@"C:\dev\benches"], wsl.Converted);
        Assert.Null(model.Error);

        Assert.Null(await model.ResolveFolderAsync("projects", TestContext.Current.CancellationToken));
        Assert.Contains("starting with /", model.Error);
        Assert.Null(await model.ResolveFolderAsync("   ", TestContext.Current.CancellationToken));
        Assert.Contains("Type the Linux folder", model.Error);
        Assert.Null(await model.ResolveFolderAsync(@"D:\missing", TestContext.Current.CancellationToken));
        Assert.Equal("wslpath failed", model.Error);
        var (offline, _, offlineWsl, _) = Make();
        offlineWsl.Home = null;
        Assert.Null(await offline.ResolveFolderAsync("~/x", TestContext.Current.CancellationToken));
        Assert.Contains("home folder", offline.Error);
        Assert.Empty(runner.Runs); // a bad folder never reaches the CLI
    }

    [Fact]
    public async Task AWindowsFolderIsScannedAsItsLinuxPath()
    {
        var (model, runner, wsl, _) = Make();
        wsl.Paths[@"C:\dev"] = "/mnt/c/dev";
        model.Folder = @"C:\dev";
        await model.ScanAsync(TestContext.Current.CancellationToken);
        Assert.Equal(["scan", "/mnt/c/dev", "--json"], runner.Runs[0].Args);
    }

    // --- add, set up ---

    [Fact]
    public async Task AddSelectedRegistersTheBenchesNotKnownYet()
    {
        var (model, runner, _, _) = Make();
        runner.On("register").Print(CliFixture.Lines("scan-register.json"));
        model.Folder = Projects;
        await model.ScanAsync(TestContext.Current.CancellationToken);
        Assert.True(model.CanAdd);
        await model.AddSelectedAsync(TestContext.Current.CancellationToken);
        Assert.Equal(["register", "--json", "--", Loose], runner.Runs.Last().Args);
        Assert.Equal("Added 1 bench to BenchBar.", model.Message);
        Assert.Null(model.Error);
        Assert.Equal(FoundState.AddedNeedsSetup, model.StateOf(model.Results[2]));
        Assert.Empty(model.Selected);
        Assert.False(model.CanAdd);
        Assert.False(model.IsAdding);
    }

    [Fact]
    public async Task AFailedAddShowsTheCliSentenceAndKeepsTheSelection()
    {
        var (model, runner, _, _) = Make();
        runner.On("register").Fail(1, "register: /x is not a bench");
        model.Folder = Projects;
        await model.ScanAsync(TestContext.Current.CancellationToken);
        await model.AddSelectedAsync(TestContext.Current.CancellationToken);
        Assert.Contains("is not a bench", model.Error);
        Assert.Equal([Loose], model.Selected);
        Assert.Equal(FoundState.NotAdopted, model.StateOf(model.Results[2]));
    }

    [Fact]
    public async Task SetUpSelectedReadsThePortPlanThenAppliesItsTokenToTheSamePaths()
    {
        var (model, runner, _, _) = Make();
        runner.On("ports", "plan").Print(CliFixture.Lines("scan-ports-plan.json"));
        model.Folder = Projects;
        await model.ScanAsync(TestContext.Current.CancellationToken);
        model.SelectAll();
        var prep = await model.PrepareSetupAsync(model.SelectedInOrder(), TestContext.Current.CancellationToken);
        Assert.Null(prep.Error);
        var request = prep.Request!;
        Assert.Equal(["ports", "plan", "--json", "--", Added, Loose], runner.Runs.Last().Args);
        Assert.Equal(["ports", "plan", "--json", "--", Added, Loose], request.PlanArgs);
        Assert.Equal("Set Up 2 Benches", request.Title);
        Assert.False(request.UsesSudoEnv); // ports apply runs nothing as root, so it never gets the password
        Assert.Contains("loose-bench: web port 8001 moves to 8002", request.Summary);
        var plan = PlanDocument.FromJson(Doc("scan-ports-plan.json"));
        Assert.Equal("aaaa1111", plan.Token);
        Assert.Equal(["ports", "apply", "aaaa1111", "--yes", "--", Added, Loose], request.ApplyArgs(plan));
    }

    [Fact]
    public async Task ABlockedPortPlanOpensNoSheetAndSaysWhy()
    {
        var (model, runner, _, _) = Make();
        runner.On("ports", "plan").Print(CliFixture.Lines("scan-ports-plan-blocked.json"));
        var prep = await model.PrepareSetupAsync([Loose], TestContext.Current.CancellationToken);
        Assert.Null(prep.Request);
        Assert.Equal("Setup is blocked. loose-bench: it is running; stop it first", prep.Error);
        Assert.Equal(prep.Error, model.Error);
    }

    [Fact]
    public async Task APortPlanThatCannotBeReadSaysSo()
    {
        var (model, runner, _, _) = Make();
        runner.On("ports", "plan").Fail(1, "ports: lock held");
        var prep = await model.PrepareSetupAsync([Loose], TestContext.Current.CancellationToken);
        Assert.Null(prep.Request);
        Assert.Contains("lock held", prep.Error);
    }

    [Fact]
    public async Task AfterASetupTheListIsReadAgainAndManagedBenchesLeaveTheSelection()
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var (client, runner) = CliFixture.Scripted();
        runner.On("scan").Print(CliFixture.Lines("scan-result.json"));
        var lists = 0;
        runner.On(a => a[0] == "list" && lists++ == 0).Print(CliFixture.Lines("scan-list.json"));
        runner.On("list").Print(CliFixture.Lines("scan-list-after.json")); // the bench is managed by the second read
        var model = new DiscoveryModel(client, new FakeWsl(), new RecentFolders()) { Folder = Projects };
        await model.ScanAsync(TestContext.Current.CancellationToken);
        model.SetSelected(Added, true);
        Assert.Equal(FoundState.AddedNeedsSetup, model.StateOf(model.Results[1]));
        await model.SetupFinishedAsync(new PlanOutcome(true, false, null), TestContext.Current.CancellationToken);
        Assert.Equal(FoundState.Managed, model.StateOf(model.Results[1]));
        Assert.Contains("Management is set up", model.Message);
        Assert.DoesNotContain(Added, model.Selected);
    }

    // --- recent folders and the WSL host ---

    [Fact]
    public void RecentFoldersAreNewestFirstWithoutDuplicatesAndKeepOnlyLinuxPaths()
    {
        var recent = new RecentFolders();
        recent.Add("/a");
        recent.Add("/b/");
        recent.Add("/a");
        recent.Add(@"C:\x");
        recent.Add("  ");
        Assert.Equal(["/a", "/b"], recent.Items);
        Assert.Equal("/a", recent.Latest);
        for (var i = 0; i < 10; i++) recent.Add("/n" + i);
        Assert.Equal(RecentFolders.Limit, recent.Items.Count);
        Assert.Equal("/n9", recent.Items[0]);
    }

    [Fact]
    public void RecentFoldersSurviveARestart()
    {
        var dir = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"));
        var file = Path.Combine(dir, "recent.txt");
        new RecentFolders(file).Add("/home/akash/projects");
        Assert.Equal(["/home/akash/projects"], new RecentFolders(file).Items);
        File.WriteAllLines(file, ["/ok", "not a path", ""]);
        Assert.Equal(["/ok"], new RecentFolders(file).Items);
    }

    [Fact]
    public async Task TheHomeFolderComesFromPrintenvInTheWatchedDistro()
    {
        var runner = new FakeProcessRunner { Answer = (_, _) => new ProcessResult(0, "/home/akash\n", "") };
        var host = new WslHost(runner, () => "Ubuntu-24.04");
        Assert.Equal("/home/akash", await host.HomeAsync(TestContext.Current.CancellationToken));
        Assert.Equal("wsl.exe", runner.Calls[0].File);
        Assert.Equal(["-d", "Ubuntu-24.04", "--exec", "printenv", "HOME"], runner.Calls[0].Args);

        var defaultDistro = new FakeProcessRunner { Answer = (_, _) => new ProcessResult(0, "/home/akash\n", "") };
        await new WslHost(defaultDistro, () => null).HomeAsync(TestContext.Current.CancellationToken);
        Assert.Equal(["--exec", "printenv", "HOME"], defaultDistro.Calls[0].Args);

        var failing = new FakeProcessRunner { Answer = (_, _) => new ProcessResult(1, "", "no distro") };
        Assert.Null(await new WslHost(failing, () => null).HomeAsync(TestContext.Current.CancellationToken));
        var relative = new FakeProcessRunner { Answer = (_, _) => new ProcessResult(0, "home\n", "") };
        Assert.Null(await new WslHost(relative, () => null).HomeAsync(TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task AWindowsPathIsConvertedWithWslpathAndALinuxPathIsLeftAlone()
    {
        var runner = new FakeProcessRunner { Answer = (_, _) => new ProcessResult(0, "/mnt/c/Users/akash/Downloads/acme.toml\n", "") };
        var host = new WslHost(runner, () => "Ubuntu-24.04");
        var converted = await host.ToLinuxPathAsync(@"  C:\Users\akash\Downloads\acme.toml ", TestContext.Current.CancellationToken);
        Assert.Equal("/mnt/c/Users/akash/Downloads/acme.toml", converted.Path);
        Assert.Equal(["-d", "Ubuntu-24.04", "--exec", "wslpath", "-a", "-u", @"C:\Users\akash\Downloads\acme.toml"], runner.Calls.Single().Args);

        var same = await host.ToLinuxPathAsync("/home/akash/a.toml", TestContext.Current.CancellationToken);
        Assert.Equal("/home/akash/a.toml", same.Path);
        Assert.Single(runner.Calls); // nothing ran for a Linux path

        var failing = new FakeProcessRunner { Answer = (_, _) => new ProcessResult(1, "", "wslpath: bad path\n") };
        var bad = await new WslHost(failing, () => null).ToLinuxPathAsync(@"Z:\nope.toml", TestContext.Current.CancellationToken);
        Assert.False(bad.Ok);
        Assert.Equal("wslpath: bad path", bad.Error);

        var missing = new FakeProcessRunner { Throws = new System.ComponentModel.Win32Exception("no wsl") };
        var none = await new WslHost(missing, () => null).ToLinuxPathAsync(@"C:\x.toml", TestContext.Current.CancellationToken);
        Assert.False(none.Ok);
    }

    [Theory]
    [InlineData(@"C:\Users\a\x.toml", true)]
    [InlineData("c:/Users/a/x.toml", true)]
    [InlineData(@"\\wsl.localhost\Ubuntu\home\a\x.toml", true)]
    [InlineData("/home/a/x.toml", false)]
    [InlineData("~/x.toml", false)]
    [InlineData("C:", false)]
    [InlineData("https://example.com/x.toml", false)]
    public void WindowsPathsAreTold(string path, bool windows) => Assert.Equal(windows, WslPaths.IsWindowsPath(path));

    [Fact]
    public void LinuxPathsOpenInExplorerThroughWslLocalhost()
    {
        Assert.Equal(@"\\wsl.localhost\Ubuntu\home\a\.config\benchbar\profiles\x.toml", WslPaths.ToWindows("Ubuntu", "/home/a/.config/benchbar/profiles/x.toml"));
        Assert.Equal("/home/a/x", WslPaths.ExpandHome("~/x", "/home/a/"));
        Assert.Equal("/home/a", WslPaths.ExpandHome("~", "/home/a"));
        Assert.Equal("~x", WslPaths.ExpandHome("~x", "/home/a"));
        Assert.Equal("~/x", WslPaths.ExpandHome("~/x", null));
    }
}
