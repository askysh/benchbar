using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>Tray parity, part 2 (issue 187), in the windows: the notices banner, readiness in the Overview, the Pull form and the MCP entry.</summary>
public class Parity187bViewTests
{
    private static BenchStatus Status(string fixture) => BenchJson.ParseStatus(string.Join('\n', Fixture(fixture)));

    // --- row 1: notices ---

    private static (NoticesBanner Banner, PageKit Kit, List<string> Copied) MakeBanner()
    {
        var kit = new PageKit();
        var copied = new List<string>();
        kit.Services.CopyText = copied.Add;
        var banner = new NoticesBanner(kit.Services);
        banner.Bind(Status("status-notices.json"));
        return (banner, kit, copied);
    }

    [Fact]
    public void EachNoticeShowsItsTitleTextSwitchBackAndLink() => Sta.Run(() =>
    {
        var (banner, kit, copied) = MakeBanner();
        Assert.Equal(Visibility.Visible, banner.Visibility);
        Assert.Equal(["listen-local", "unknown-flags", "pull-neutralise"], banner.Shown.Select(n => n.Id));
        Assert.Contains("The bench now listens on this computer only", banner.Lines);
        Assert.Contains(banner.Lines, l => l.Contains("127.0.0.1"));
        Assert.Contains("benchbar listen all", banner.Lines);
        Assert.Equal(3, Walk(banner).OfType<Button>().Count(b => (b.Content as string) == "Dismiss"));

        Click(ButtonNamed(banner, "Copy the command to go back: An option a command does not take is now an error"));
        Assert.Equal(["BENCHBAR_LENIENT_FLAGS=1"], copied);
        Click(ButtonNamed(banner, "Read more: The bench now listens on this computer only"));
        Assert.Equal(["https://benchbar.akashmishra.com/whats-new/#the-bench-listens-on-this-computer-only"], kit.Opened);
        Assert.Empty(kit.Runner.Runs); // showing a notice runs nothing
        AssertEveryControlIsNamed(banner);
    });

    [Fact]
    public void DismissRunsNoticesDismissWithTheIdAndTheNoticeGoes() => Sta.Run(() =>
    {
        var (banner, kit, _) = MakeBanner();
        kit.Runner.On("notices").Print("""{"schema_version":1,"notices":[]}""");
        Pump(() => Click(ButtonNamed(banner, "Dismiss: An option a command does not take is now an error")), () => banner.Pending.IsCompleted);
        Assert.Equal(["notices", "--dismiss", "unknown-flags"], kit.Runner.Runs.Single().Args);
        Assert.Equal(["listen-local", "pull-neutralise"], banner.Shown.Select(n => n.Id));
        Assert.Equal(1, kit.Refreshes);
        // a poll that still lists it (it was asked before the dismissal) does not bring it back
        banner.Bind(Status("status-notices.json") with { Path = "/other" });
        Assert.Equal(["listen-local", "pull-neutralise"], banner.Shown.Select(n => n.Id));
    });

    [Fact]
    public void ARefusedDismissKeepsTheNoticeAndSaysWhy() => Sta.Run(() =>
    {
        var (banner, kit, _) = MakeBanner();
        kit.Runner.On("notices").Fail(1, "The state file is not writable.");
        Pump(() => Click(ButtonNamed(banner, "Dismiss: The bench now listens on this computer only")), () => banner.Pending.IsCompleted);
        Assert.Equal(3, banner.Shown.Count);
        Assert.Equal("The state file is not writable.", banner.Message);
        Assert.Contains("The state file is not writable.", banner.Lines);
    });

    [Fact]
    public void NoNoticesMeansNoBannerAndAnOlderCliIsTheSame() => Sta.Run(() =>
    {
        var banner = new NoticesBanner(new PageKit().Services);
        banner.Bind(Status("status-pending-add.json")); // a 0.8 CLI sends no notices
        Assert.Equal(Visibility.Collapsed, banner.Visibility);
        Assert.Empty(banner.Shown);
        banner.Bind(Status("status-ready.json")); // notices: [] on a 0.9 CLI
        Assert.Equal(Visibility.Collapsed, banner.Visibility);
    });

    [Fact]
    public void TheBenchPageShowsTheBannerAboveTheTabs() => Sta.Run(() =>
    {
        var kit = new PageKit();
        var page = new BenchPage(kit.Services, new OverviewView(new OverviewActions()));
        page.Bind(Status("status-notices.json"), null, navigate: true);
        Assert.Equal(3, page.Notices.Shown.Count);
        Assert.Equal(Visibility.Visible, page.Notices.Visibility);
        page.Bind(Status("status-ready.json"), null, navigate: false);
        Assert.Empty(page.Notices.Shown);
    });

    // --- row 2: readiness ---

    private static (OverviewView View, List<string> Copied) MakeOverview()
    {
        var kit = new PageKit();
        var copied = new List<string>();
        kit.Services.CopyText = copied.Add;
        var view = new OverviewView(new OverviewActions());
        view.Attach(kit.Services, (_, _) => { });
        return (view, copied);
    }

    [Fact]
    public void TheOverviewSaysReadyForABenchThatCanServe() => Sta.Run(() =>
    {
        var (view, _) = MakeOverview();
        view.Bind(Status("status-ready.json"), null);
        Assert.Equal("Ready", view.ReadinessWord);
        Assert.Contains("Ready", view.Lines);
        Assert.Null(FindButton(view, "Copy the command that gets the bench ready"));
    });

    [Fact]
    public void TheOverviewSaysWhatANotReadyBenchWaitsOnAndOffersTheFixToCopy() => Sta.Run(() =>
    {
        var (view, copied) = MakeOverview();
        view.Bind(Status("status-not-ready.json"), null);
        Assert.Equal("Running, not ready", view.ReadinessWord);
        Assert.Contains("Waiting on the realtime server (socketio).", view.Lines);
        Assert.Contains("benchbar logs --bench-dir /home/akash/frappe-bench", view.Lines);
        Click(ButtonNamed(view, "Copy the command that gets the bench ready"));
        Assert.Equal(["benchbar logs --bench-dir /home/akash/frappe-bench"], copied);
        AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void StaleCodeSaysNeedsRestartAndNamesTheFileTheBenchRunsNothingByItself() => Sta.Run(() =>
    {
        var (view, copied) = MakeOverview();
        view.Bind(Status("status-ready-stale.json"), null);
        Assert.Equal("Needs restart (code changed)", view.ReadinessWord);
        Assert.Contains("apps/erpnext/erpnext/hooks.py changed after the bench started.", view.Lines);
        Assert.Empty(copied); // the fix is shown; Restart is the person's click
    });

    [Fact]
    public void ThereIsNoReadinessLineForAStoppedBenchOrAnOlderCli() => Sta.Run(() =>
    {
        var (view, _) = MakeOverview();
        view.Bind(Status("status-pending-add.json"), null);
        Assert.Null(view.ReadinessWord);
        view.Bind(Status("status-not-ready.json") with { State = BenchState.Stopped }, null);
        Assert.Null(view.ReadinessWord);
    });

    [Fact]
    public void ThePageRebuildsWhenReadinessChangesAndNotOtherwise() => Sta.Run(() =>
    {
        var (view, _) = MakeOverview();
        view.Bind(Status("status-not-ready.json"), null);
        var first = view.Content;
        view.Bind(Status("status-not-ready.json"), null); // a poll that changed nothing
        Assert.Same(first, view.Content);
        view.Bind(Status("status-ready.json"), null);
        Assert.NotSame(first, view.Content);
        Assert.Equal("Ready", view.ReadinessWord);
    });

    // --- row 3: pull ---

    private static string CommandsWith(bool pull, bool apply = true)
    {
        var doc = (JsonObject)JsonNode.Parse(string.Join('\n', Fixture("commands.json")))!;
        if (pull)
        {
            var flags = new JsonArray(new JsonObject { ["name"] = "--as", ["value"] = "NAME", ["help"] = "Local site name." });
            if (apply) flags.Add(new JsonObject { ["name"] = "--apply", ["value"] = "TOKEN", ["help"] = "Run exactly that plan." });
            ((JsonArray)doc["commands"]!).Add(new JsonObject { ["name"] = "pull", ["usage"] = "benchbar pull HOST:SITE", ["summary"] = "Copy a site.", ["mutating"] = true, ["flags"] = flags });
        }
        return doc.ToJsonString();
    }

    private static (SitesView View, PageKit Kit) MakeSites(bool pull = true, bool apply = true)
    {
        var kit = new PageKit();
        kit.Runner.On("commands").Print(CommandsWith(pull, apply));
        Wait(kit.Services.Commands.GetAsync());
        var view = new SitesView(kit.Services);
        view.Bind(new BenchContext(PageKit.Bench(), null));
        return (view, kit);
    }

    [Fact]
    public void PullIsOfferedOnlyWhenTheCliHasItWithAnApplyToken() => Sta.Run(() =>
    {
        var (with, _) = MakeSites();
        Assert.True(with.PullAvailable);
        Assert.NotNull(FindButton(with, "Pull a site into frappe-bench"));
        var (noApply, _) = MakeSites(apply: false);
        Assert.False(noApply.PullAvailable);
        Assert.Null(FindButton(noApply, "Pull a site into frappe-bench"));
        var (none, _) = MakeSites(pull: false);
        Assert.Null(FindButton(none, "Pull a site into frappe-bench"));
        var unasked = new SitesView(new PageKit().Services);
        unasked.Bind(new BenchContext(PageKit.Bench(), null));
        Assert.Null(unasked.PullAvailable); // the tab starts no call of its own
        Assert.Null(FindButton(unasked, "Pull a site into frappe-bench"));
    });

    [Fact]
    public void TheFormStartsWithKeepSecretsOffAndWarnsWhenItIsTicked() => Sta.Run(() =>
    {
        var (view, kit) = MakeSites();
        Click(ButtonNamed(view, "Pull a site into frappe-bench"));
        var form = view.PullForm!.Value;
        Assert.False(form.KeepSecrets.IsChecked);
        Assert.False(form.FromFolder.IsChecked);
        Assert.Equal(PullCommands.NeutralisedText, view.PullKeepNoteText);
        ClickToggle(form.KeepSecrets);
        Assert.StartsWith("Warning: Production's passwords, webhooks and integrations stay on the copy", view.PullKeepNoteText);
        Assert.Contains("Do not start its scheduler", view.PullKeepNoteText);
        ClickToggle(form.KeepSecrets);
        Assert.Equal(PullCommands.NeutralisedText, view.PullKeepNoteText);
        AssertEveryControlIsNamed(view);
        Assert.DoesNotContain(kit.Runner.Runs, r => r.Args[0] == "pull");
    });

    [Fact]
    public void TheNameFollowsTheServerUntilItIsTypedOver() => Sta.Run(() =>
    {
        var (view, _) = MakeSites();
        Click(ButtonNamed(view, "Pull a site into frappe-bench"));
        var form = view.PullForm!.Value;
        form.Source.Text = "prod:ERP.example.com";
        Assert.Equal("erp.example.com.local", form.Name.Text);
        form.Name.Text = "mine.localhost";
        form.Source.Text = "prod:other.example.com";
        Assert.Equal("mine.localhost", form.Name.Text);
    });

    [Fact]
    public void AFormProblemIsSaidBeforeAnyCommandRuns() => Sta.Run(() =>
    {
        var (view, kit) = MakeSites();
        var before = kit.Runner.Runs.Count;
        Click(ButtonNamed(view, "Pull a site into frappe-bench"));
        var form = view.PullForm!.Value;
        foreach (var (source, name, problem) in new[]
        {
            ("prod", "a.localhost", "Enter the server as HOST:SITE, for example prod:erp.example.com. HOST is a Host of ~/.ssh/config in Ubuntu."),
            ("prod:erp", "", "Enter a name for the new site."),
            ("prod:erp", "Bad Name", SiteNames.Rule),
            ("prod:erp", "two.localhost", "two.localhost is already a site of this bench. Pull never overwrites one here."),
        })
        {
            form.Source.Text = source;
            form.Name.Text = name;
            Click(ButtonNamed(view, "Review Plan..."));
            Wait(view.Pending);
            Assert.Equal(problem, view.PullProblemText);
        }
        Assert.Empty(kit.Plans);
        Assert.Equal(before, kit.Runner.Runs.Count);
    });

    [Fact]
    public void PullReadsThePlanThenAppliesItByItsOwnToken() => Sta.Run(() =>
    {
        var (view, kit) = MakeSites();
        kit.Runner.On(a => a.Contains("--dry-run")).Print(Fixture("pull-plan.jsonl"));
        kit.Runner.On(a => a.Contains("--apply")).Print(Fixture("pull-apply.jsonl"));
        Click(ButtonNamed(view, "Pull a site into frappe-bench"));
        var form = view.PullForm!.Value;
        form.Source.Text = "prod:erp.example.com";
        form.Name.Text = "erpcopy.localhost";
        Click(ButtonNamed(view, "Review Plan..."));
        Wait(view.Pending);

        var request = Assert.Single(kit.Plans);
        Assert.Equal("Pull", request.ConfirmLabel);
        Assert.False(request.CanStop);
        Assert.Equal("Pull erpcopy.localhost", request.Title);
        var pulls = kit.Runner.Runs.Where(r => r.Args[0] == "pull").ToList();
        Assert.Equal(["pull", "prod:erp.example.com", "--as", "erpcopy.localhost", "--bench-dir", P, "--dry-run", "--json"], pulls[0].Args);
        Assert.Equal(["pull", "prod:erp.example.com", "--as", "erpcopy.localhost", "--bench-dir", P, "--apply", "0ae11fd8a7dd70b49af83085424cbdf431c4237d2da52d31abdd9ea35b2eeceb", "--yes", "--jsonl"], pulls[1].Args);
        Assert.DoesNotContain(pulls.SelectMany(r => r.Args), a => a == "--keep-secrets");
        Assert.Equal("erpcopy.localhost was pulled.", view.Message);
        Assert.Equal(1, kit.Refreshes);
        Assert.Null(view.OpenPanel);
    });

    [Fact]
    public void KeepSecretsGoesToBothCallsOnlyWhenTicked() => Sta.Run(() =>
    {
        var (view, kit) = MakeSites();
        kit.Runner.On(a => a.Contains("--dry-run")).Print(Fixture("pull-plan-keep.jsonl"));
        kit.Runner.On(a => a.Contains("--apply")).Print(Fixture("pull-apply.jsonl"));
        Click(ButtonNamed(view, "Pull a site into frappe-bench"));
        var form = view.PullForm!.Value;
        form.Source.Text = "prod:erp.example.com";
        form.Name.Text = "erpcopy.localhost";
        ClickToggle(form.KeepSecrets);
        Click(ButtonNamed(view, "Review Plan..."));
        Wait(view.Pending);
        var pulls = kit.Runner.Runs.Where(r => r.Args[0] == "pull").ToList();
        Assert.All(pulls, r => Assert.Contains("--keep-secrets", r.Args));
        Assert.Equal("9c36a3b81ade9add42016679ef9a88612cd441084483b90ed8e066c2e0c33e0f", pulls[1].Args[pulls[1].Args.ToList().IndexOf("--apply") + 1]);
    });

    [Fact]
    public void ABackupFolderPullsWithFromDirAndNeedsAPathInsideUbuntu() => Sta.Run(() =>
    {
        var (view, kit) = MakeSites();
        kit.Runner.On(a => a.Contains("--dry-run")).Print(Fixture("pull-plan.jsonl"));
        kit.Runner.On(a => a.Contains("--apply")).Print(Fixture("pull-apply.jsonl"));
        Click(ButtonNamed(view, "Pull a site into frappe-bench"));
        var form = view.PullForm!.Value;
        ClickToggle(form.FromFolder);
        form.Source.Text = @"C:\Users\me\backup";
        form.Name.Text = "erpcopy.localhost";
        Click(ButtonNamed(view, "Review Plan..."));
        Wait(view.Pending);
        Assert.Contains("inside Ubuntu", view.PullProblemText);
        Assert.Empty(kit.Plans);
        form.Source.Text = "/home/akash/backup";
        Click(ButtonNamed(view, "Review Plan..."));
        Wait(view.Pending);
        Assert.Equal(["pull", "--from-dir", "/home/akash/backup", "--as", "erpcopy.localhost", "--bench-dir", P, "--dry-run", "--json"],
            kit.Runner.Runs.First(r => r.Args[0] == "pull").Args);
    });

    [Fact]
    public void TheBenchPageAsksWhatTheCliCanDoWhenTheSitesTabOpensSoPullAppears() => Sta.Run(() =>
    {
        var kit = new PageKit();
        kit.Runner.On("commands").Print(CommandsWith(pull: true));
        var page = new BenchPage(kit.Services, new OverviewView(new OverviewActions()));
        // inside the dispatcher frame, so the awaits of the page come back to this thread as they do in the app
        Pump(() =>
        {
            page.Bind(PageKit.Bench(), null, navigate: false);
            page.Select(BenchTab.Sites);
        }, () => FindButton(page.Sites!, "Pull a site into frappe-bench") is not null);
        Assert.Single(kit.Runner.Runs, r => r.Args[0] == "commands"); // one catalogue for the Overview and the Sites tab
    });

    // --- row 5: the MCP entry ---

    [Fact]
    public void AboutShowsAndCopiesTheMcpCommandAndTheJsonEntry() => Sta.Run(() =>
    {
        var copied = new List<string>();
        var about = new AboutWindow(new AboutActions { CopyText = copied.Add }, Theme);
        var boxes = Walk(about).OfType<TextBox>().Select(t => t.Text).ToList();
        Assert.Contains(WizardModel.McpLine, boxes);
        Assert.Contains(WizardModel.McpJson, boxes);
        Click(ButtonNamed(about, "Copy the command that adds benchbar mcp"));
        Click(ButtonNamed(about, "Copy the JSON entry for the benchbar mcp server"));
        Assert.Equal([WizardModel.McpLine, WizardModel.McpJson], copied);
        AssertEveryControlIsNamed(about);
    });

    private const string P = PageKit.BenchPath;
}
