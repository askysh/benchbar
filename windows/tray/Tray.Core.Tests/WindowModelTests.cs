using Xunit;
using System.Text.Json.Nodes;
using BenchBar.Tray.Core;

namespace Tray.Core.Tests;

public class LaunchPlannerTests
{
    private static BenchStatus Bench(string name = "a") => new(name, "/" + name, BenchState.Running, null, "http://a:8000", "a");

    private static SetupReport Report(bool ready) => new("Ubuntu-24.04", ready, false,
        [new SetupStepInfo(SetupIds.WslFeature, ready ? SetupStatus.Ok : SetupStatus.Missing, "WSL", "", ready ? null : SetupIds.ActionWslEnable, true)]);

    private static SetupReport CliOkButSystemdMissing() => new("Ubuntu-24.04", false, false,
    [
        new SetupStepInfo(SetupIds.Systemd, SetupStatus.Missing, "systemd", "not enabled", SetupIds.ActionSystemd, false),
        new SetupStepInfo(SetupIds.Cli, SetupStatus.Ok, "benchbar", "benchbar 0.8.0", null, false),
    ]);

    [Fact]
    public void AReturningUserWhoseFirstPollFailedIsLeftAlone()
    {
        var failedPoll = new TraySnapshot([], Problem: "benchbar.exe did not answer in 30 seconds.");
        Assert.Equal(LaunchAction.Nothing, LaunchPlanner.AtLaunch(failedPoll, CliOkButSystemdMissing(), false, false));
        // the same open step on a PC where the poll worked and found nothing still opens it
        Assert.Equal(LaunchAction.OpenWizard, LaunchPlanner.AtLaunch(new TraySnapshot([]), CliOkButSystemdMissing(), false, false));
    }

    [Fact]
    public void OnlyAdviceFailingNeverOpensTheWizard()
    {
        var advice = new SetupReport("Ubuntu-24.04", true, false,
        [
            new SetupStepInfo(SetupIds.Cli, SetupStatus.Ok, "benchbar", "benchbar 0.8.0", null, false),
            new SetupStepInfo(SetupIds.ShimPath, SetupStatus.Warn, "PATH", "another copy first", null, false, Blocking: false),
            new SetupStepInfo(SetupIds.WslConfig, SetupStatus.Missing, "wslconfig", "", "wslconfig", false, Blocking: false),
        ]);
        Assert.Equal(LaunchAction.Nothing, LaunchPlanner.AtLaunch(new TraySnapshot([]), advice, false, false));
    }

    [Fact]
    public void ANewPcWithoutWslOpensEvenThoughThePollFailed()
    {
        var wslMissing = new SetupReport(null, false, false,
        [
            new SetupStepInfo(SetupIds.WslFeature, SetupStatus.Missing, "WSL", "WSL is not installed", SetupIds.ActionWslEnable, true),
            new SetupStepInfo(SetupIds.Cli, SetupStatus.Missing, "benchbar", "waits for wsl_feature", null, false),
        ]);
        Assert.Equal(LaunchAction.OpenWizard, LaunchPlanner.AtLaunch(new TraySnapshot([], Problem: BenchPoller.WslMissingMessage), wslMissing, false, false));
    }

    [Fact]
    public void AboutSaysWhyThereIsNoCliVersion()
    {
        Assert.Equal("benchbar 0.8.0", AboutCli.From(SetupJson.ParseCheck(File.ReadAllText(Path.Combine(Fixtures.Dir("setup"), "check.json")))).Text);
        Assert.Equal("not installed yet", AboutCli.From(SetupJson.ParseCheck(File.ReadAllText(Path.Combine(Fixtures.Dir("setup"), "check-fresh.json")))).Text);
        Assert.Equal("unknown (the distro may be stopped)", AboutCli.From(SetupJson.ParseCheck(File.ReadAllText(Path.Combine(Fixtures.Dir("setup"), "check-stopped.json")))).Text);
        Assert.Equal("unknown", AboutCli.From(SetupReport.Empty).Text);
    }

    [Fact]
    public void ANewPcWithNothingSetUpOpensTheWizard()
    {
        var snapshot = new TraySnapshot([], Problem: "WSL is not installed: wsl.exe --install");
        Assert.True(LaunchPlanner.NeedsSetupCheck(snapshot, dismissed: false));
        Assert.Equal(LaunchAction.OpenWizard, LaunchPlanner.AtLaunch(snapshot, Report(false), false, false));
    }

    [Fact]
    public void ABenchOrAStoppedDistroOrADismissalKeepsItQuiet()
    {
        var withBench = new TraySnapshot([Bench()]);
        var stopped = new TraySnapshot([], DistroStopped: true, Distro: "Ubuntu-24.04");
        var empty = new TraySnapshot([]);
        Assert.False(LaunchPlanner.NeedsSetupCheck(withBench, false));
        Assert.False(LaunchPlanner.NeedsSetupCheck(stopped, false));
        Assert.False(LaunchPlanner.NeedsSetupCheck(empty, dismissed: true));
        Assert.Equal(LaunchAction.Nothing, LaunchPlanner.AtLaunch(withBench, Report(false), false, false));
        Assert.Equal(LaunchAction.Nothing, LaunchPlanner.AtLaunch(stopped, Report(false), false, false));
        Assert.Equal(LaunchAction.Nothing, LaunchPlanner.AtLaunch(empty, Report(false), true, false));
    }

    [Fact]
    public void AReadyPcWithoutABenchOrAnUnansweredCheckStaysQuiet()
    {
        var empty = new TraySnapshot([]);
        Assert.Equal(LaunchAction.Nothing, LaunchPlanner.AtLaunch(empty, Report(true), false, false));
        Assert.Equal(LaunchAction.Nothing, LaunchPlanner.AtLaunch(empty, null, false, false));
    }

    [Fact]
    public void TheResumeFlagAlwaysOpensTheWizard() =>
        Assert.Equal(LaunchAction.OpenWizard, LaunchPlanner.AtLaunch(new TraySnapshot([Bench()]), null, true, resumeFlag: true));
}

public class SidebarTests
{
    [Fact]
    public void SitesAreChildRowsOfTheirBench()
    {
        var bench = new BenchStatus("frappe-bench", "/b", BenchState.Running, null, "http://one.localhost:8000", "one.localhost")
        {
            Sites = [new SiteInfo("one.localhost", true), new SiteInfo("two.localhost", false)],
        };
        var items = SidebarModel.Build(new TraySnapshot([bench]));
        Assert.Equal([SidebarKind.Bench, SidebarKind.Site, SidebarKind.Site], items.Select(i => i.Kind));
        Assert.Equal("running", items[0].Detail);
        Assert.Equal("default site", items[1].Detail);
        Assert.Equal("http://one.localhost:8000", items[1].Url);
        Assert.Null(items[2].Url);
        Assert.All(items, i => Assert.Equal("/b", i.BenchPath));
    }

    [Fact]
    public void ANotAdoptedBenchHasNoChildren()
    {
        var bench = new BenchStatus("x", "/x", BenchState.Unknown, null, null, null) { RawState = "not_adopted" };
        var items = SidebarModel.Build(new TraySnapshot([bench]));
        Assert.Single(items);
        Assert.Equal("unknown (not_adopted)", items[0].Detail);
    }

    [Fact]
    public void OverviewButtonsFollowTheFlyoutRules()
    {
        var running = new BenchStatus("a", "/a", BenchState.Running, null, "http://a", "a");
        var stopped = running with { State = BenchState.Stopped, WebUrl = null };
        var unknown = running with { State = BenchState.Unknown };
        Assert.Equal(new OverviewButtons("Stop", true, true, true), OverviewButtons.For(running, false));
        Assert.Equal(new OverviewButtons("Start", true, false, false), OverviewButtons.For(stopped, false));
        Assert.False(OverviewButtons.For(unknown, false).CanStartStop);
        Assert.False(OverviewButtons.For(running, busy: true).CanStartStop);
    }
}

public class EditorTests
{
    [Fact]
    public void EditorsNormalizeAndHaveTheirLaunchers()
    {
        Assert.Equal("code", EditorKind.Normalize(null));
        Assert.Equal("code", EditorKind.Normalize("emacs"));
        Assert.Equal("cursor", EditorKind.Normalize(" Cursor "));
        Assert.Equal("code-insiders.cmd", EditorKind.CommandFile("insiders"));
        Assert.Equal("Cursor", EditorKind.DisplayName("cursor"));
        Assert.EndsWith(Path.Combine("cursor", "resources", "app", "bin"), EditorKind.UserBinFolder("cursor", @"C:\u\AppData\Local"));
    }
}

public class SettingsModelTests
{
    private sealed class Host : ISettingsHost
    {
        public bool OpenAtLogon { get; set; }
        public List<string> Applied { get; } = [];
        public string? ShimPath { get; set; } = @"C:\x\benchbar.exe";
        public void ApplyAppearance(AppearanceMode mode) => Applied.Add("appearance " + mode);
        public void ApplyRunner(string id) => Applied.Add("runner " + id);
        public void ApplyNotifications(bool on) => Applied.Add("notifications " + on);
    }

    private static (SettingsModel Model, TrayConfig Config, Host Host, int[] Saves, SetupFixture Fixture) Make()
    {
        var path = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"), "config.json");
        var config = TrayConfig.Load(path);
        var host = new Host();
        var saves = new int[1];
        var fixture = new SetupFixture();
        return (new SettingsModel(config, host, fixture.Service, () => { saves[0]++; config.Save(); }), config, host, saves, fixture);
    }

    [Fact]
    public void EverySettingSavesAndTellsTheHost()
    {
        var (model, config, host, saves, _) = Make();
        model.Notifications = false;
        model.Appearance = AppearanceMode.Dark;
        model.RunnerId = "cup";
        model.Editor = "cursor";
        model.CheckForUpdates = false;
        model.OpenAtLogon = true;
        Assert.Equal(5, saves[0]);
        Assert.Equal(["notifications False", "appearance Dark", "runner cup"], host.Applied);
        Assert.True(host.OpenAtLogon);

        var back = TrayConfig.Load(config.Path);
        Assert.False(back.Notifications);
        Assert.Equal(AppearanceMode.Dark, back.Appearance);
        Assert.Equal("cup", back.RunnerId);
        Assert.Equal("cursor", back.Editor);
        Assert.False(back.CheckForUpdates);
    }

    [Fact]
    public void AnUnknownEditorFallsBackToVsCode()
    {
        var (model, _, _, _, _) = Make();
        model.Editor = "notepad";
        Assert.Equal("code", model.Editor);
    }

    [Fact]
    public async Task TheDistroListComesFromWslAndSwitchingGoesThroughTheShim()
    {
        var (model, _, _, _, fixture) = Make();
        await model.LoadDistrosAsync(TestContext.Current.CancellationToken);
        Assert.Equal(["Ubuntu-24.04", "Debian"], model.Distros.Select(d => d.Name));
        Assert.Equal("Ubuntu-24.04", model.CurrentDistro); // the WSL default, nothing configured yet
        await model.UseDistroAsync("Debian", TestContext.Current.CancellationToken);
        Assert.Contains("use-distro Debian", fixture.Service.Calls);
        Assert.Null(model.DistroMessage);
        await model.UseDistroAsync("Ubuntu-24.04", TestContext.Current.CancellationToken); // already the current one: nothing to do
        Assert.Equal(1, fixture.Service.Calls.Count(c => c.StartsWith("use-distro")));
    }

    [Fact]
    public void TheCliPathIsTheShimsKeyElseTheShimItself()
    {
        var (model, config, host, _, _) = Make();
        Assert.Equal(@"C:\x\benchbar.exe", model.CliPathText);
        Directory.CreateDirectory(Path.GetDirectoryName(config.Path)!);
        File.WriteAllText(config.Path, "{\"cli_path\":\"/home/a/.local/bin/benchbar\",\"distro\":\"Debian\"}");
        Assert.Equal("/home/a/.local/bin/benchbar", model.CliPathText);
        Assert.Equal("Debian", model.CurrentDistro);
        host.ShimPath = null;
        Assert.Equal("/home/a/.local/bin/benchbar", model.CliPathText);
    }

    [Fact]
    public void TheNewKeysKeepTheShimsKeysAndUnknownTrayKeys()
    {
        var path = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"), "config.json");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, "{\"distro\":\"Debian\",\"cli_path\":\"/x\",\"tray\":{\"future\":7}}");
        var config = TrayConfig.Load(path);
        Assert.True(config.CheckForUpdates);
        Assert.Equal("code", config.Editor);
        Assert.False(config.WizardDismissed);
        config.WizardDismissed = true;
        config.Save();
        var root = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
        Assert.Equal("Debian", (string?)root["distro"]);
        Assert.Equal("/x", (string?)root["cli_path"]);
        Assert.Equal(7, (int?)root["tray"]!["future"]);
        Assert.True((bool?)root["tray"]!["wizard_dismissed"]);
        Assert.True(TrayConfig.Load(path).WizardDismissed);
    }
}
