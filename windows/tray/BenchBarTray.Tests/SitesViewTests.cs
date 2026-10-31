using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Threading;
using BenchBar.Tray.Core;
using Xunit;

namespace BenchBar.Tray.Tests;


public class SitesViewTests
{
    private const string P = PageKit.BenchPath;

    private static (SitesView View, PageKit Kit) Make(BenchStatus? bench = null, string? site = null)
    {
        var kit = new PageKit();
        var view = new SitesView(kit.Services);
        view.Bind(new BenchContext(bench ?? PageKit.Bench(), site));
        return (view, kit);
    }

    // --- rows ---

    [Fact]
    public void ARowShowsTheNameTheDefaultBadgeAndOpenOrSetUp() => Sta.Run(() =>
    {
        var (view, kit) = Make(PageKit.Bench(sites: [("one.localhost", true), ("two.localhost", false), ("mysite", false)]));
        Assert.Equal(["one.localhost", "two.localhost", "mysite"], view.Rows.Select(r => r.Name));
        Assert.Single(PageKit.Walk(view).OfType<Border>(), b => AutomationProperties.GetName(b) == "default site");
        Assert.Contains("one.localhost", PageKit.Texts(view));
        Assert.NotNull(PageKit.FindButton(view, "Open one.localhost"));
        Assert.NotNull(PageKit.FindButton(view, "Open two.localhost"));
        Assert.NotNull(PageKit.FindButton(view, "Set Up... mysite"));
        PageKit.Click(PageKit.ButtonNamed(view, "Open two.localhost"));
        Assert.Equal(["http://two.localhost:8000"], kit.Opened);
        PageKit.AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void ASiteDoesNotOpenWhileTheBenchIsStopped() => Sta.Run(() =>
    {
        var (view, _) = Make(PageKit.Bench(BenchState.Stopped));
        Assert.False(PageKit.ButtonNamed(view, "Open one.localhost").IsEnabled);
    });

    [Fact]
    public void ThePageRebuildsOnlyWhenSomethingItShowsChanged() => Sta.Run(() =>
    {
        var (view, _) = Make();
        var first = PageKit.ButtonNamed(view, "Open one.localhost");
        view.Bind(new BenchContext(PageKit.Bench(), null)); // a poll
        Assert.Same(first, PageKit.ButtonNamed(view, "Open one.localhost"));
        view.Bind(new BenchContext(PageKit.Bench(BenchState.Stopped), null));
        Assert.NotSame(first, PageKit.ButtonNamed(view, "Open one.localhost"));
    });

    [Fact]
    public void TheSelectedSiteIsMarked() => Sta.Run(() =>
    {
        var (view, _) = Make(site: "two.localhost");
        Assert.Equal("two.localhost", view.SelectedSite);
        var cards = PageKit.Walk(view).OfType<Border>().Where(b => AutomationProperties.GetName(b).StartsWith("Site ", StringComparison.Ordinal)).ToDictionary(b => AutomationProperties.GetName(b), b => b.BorderThickness.Left, StringComparer.Ordinal);
        Assert.Equal(1, cards["Site two.localhost"]);
        Assert.Equal(0, cards["Site one.localhost"]);
    });

    [Fact]
    public void ANoSiteBenchHasOneLineAndOneAction() => Sta.Run(() =>
    {
        var (view, kit) = Make(PageKit.Bench(sites: [("x", false)]) with { Sites = [] });
        Assert.Contains("frappe-bench has no site yet.", PageKit.Texts(view));
        Assert.Equal(["Add Site..."], PageKit.ButtonLabels(view));
        PageKit.Click(PageKit.ButtonNamed(view, "Add Site..."));
        Assert.NotNull(view.OpenPanel);
        Assert.Empty(kit.Runner.Runs);
    });

    // --- the per site menu ---

    [Fact]
    public void TheMenuNamesEveryAction() => Sta.Run(() =>
    {
        var (view, _) = Make();
        Assert.Equal(["Make Default", "Back Up", "Back Up with Files", "Backups...", "Restore...", "Open Console", "Open Database", "Drop Site..."],
            PageKit.MenuOf(view, "More actions for two.localhost").Select(i => (string)i.Header));
        Assert.Equal(["Back Up", "Back Up with Files", "Backups...", "Restore...", "Open Console", "Open Database", "Drop Site..."],
            PageKit.MenuOf(view, "More actions for one.localhost").Select(i => (string)i.Header));
        PageKit.AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void NoControlOffersAHostsAction() => Sta.Run(() =>
    {
        var (view, _) = Make(PageKit.Bench(sites: [("one.localhost", true), ("mysite", false)]));
        var labels = PageKit.ButtonLabels(view).Concat(PageKit.MenuOf(view, "More actions for mysite").Select(i => (string)i.Header));
        Assert.DoesNotContain(labels, l => l.Contains("hosts", StringComparison.OrdinalIgnoreCase));
    });

    [Fact]
    public void TheOnlySiteCannotBeDropped() => Sta.Run(() =>
    {
        var (view, _) = Make(PageKit.Bench(sites: [("one.localhost", true)]));
        Assert.False(PageKit.MenuOf(view, "More actions for one.localhost").Single(i => (string)i.Header == "Drop Site...").IsEnabled);
    });

    // --- Make Default, Back Up ---

    [Fact]
    public void MakeDefaultRunsSiteDefaultAndPollsAgain() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On("site", "default").Print(PageKit.Fixture("sites-default.jsonl"));
        PageKit.ClickMenu(view, "More actions for two.localhost", "Make Default");
        PageKit.Wait(view.Pending);
        Assert.Equal([["site", "default", "two.localhost", "--jsonl", "--bench-dir", P]], kit.Runner.Runs.Select(r => r.Args));
        Assert.Equal("two.localhost is now the default site.", view.Message);
        Assert.False(view.MessageIsError);
        Assert.False(view.IsBusy);
        Assert.Equal(1, kit.Refreshes);
    });

    [Fact]
    public void AFailedMakeDefaultShowsTheCliErrorAndDoesNotPoll() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On("site", "default").Print(PageKit.Fixture("sites-default-fail.jsonl")).Fail(1);
        PageKit.ClickMenu(view, "More actions for two.localhost", "Make Default");
        PageKit.Wait(view.Pending);
        Assert.Equal("two.localhost is not a site of this bench.", view.Message);
        Assert.True(view.MessageIsError);
        Assert.Equal(0, kit.Refreshes);
    });

    [Theory]
    [InlineData("Back Up", false)]
    [InlineData("Back Up with Files", true)]
    public void BackUpRunsSiteBackupJson(string item, bool withFiles) => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On("site", "backup").Print(PageKit.Fixture("sites-backup.json"));
        PageKit.ClickMenu(view, "More actions for one.localhost", item);
        PageKit.Wait(view.Pending);
        var expected = withFiles
            ? new[] { "site", "backup", "one.localhost", "--with-files", "--json", "--bench-dir", P }
            : ["site", "backup", "one.localhost", "--json", "--bench-dir", P];
        Assert.Equal(expected, kit.Runner.Runs.Single().Args);
        Assert.Contains("20261030_120000", view.Message);
        Assert.Contains("2.0 MB", view.Message);
    });

    [Fact]
    public void WhileABackupRunsNothingElseCanStart() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        var held = kit.Runner.On("site", "backup").Hold();
        PageKit.ClickMenu(view, "More actions for one.localhost", "Back Up");
        Assert.True(view.IsBusy);
        Assert.False(PageKit.ButtonNamed(view, "More actions for two.localhost").IsEnabled);
        Assert.False(PageKit.ButtonNamed(view, "Add Site...").IsEnabled);
        held.Release(PageKit.Fixture("sites-backup.json"));
        PageKit.Wait(view.Pending);
        PageKit.Drain();
        Assert.False(view.IsBusy);
        Assert.True(PageKit.ButtonNamed(view, "Add Site...").IsEnabled);
    });

    // --- Backups, Restore ---

    [Fact]
    public void BackupsListsTheSetsAndOpensTheFolderThroughWsl() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On("site", "backups").Print(PageKit.Fixture("sites-backups.json"));
        var folders = new List<string>();
        view.FolderOpener = folders.Add;
        PageKit.ClickMenu(view, "More actions for one.localhost", "Backups...");
        PageKit.Wait(view.Pending);
        Assert.Equal(["site", "backups", "one.localhost", "--json", "--bench-dir", P], kit.Runner.Runs.Single().Args);
        var panel = view.OpenPanel!;
        Assert.Contains("Backups of one.localhost", PageKit.Texts(panel));
        Assert.Contains("20260929_101500", PageKit.Texts(panel));
        Assert.Contains("20260920_080000", PageKit.Texts(panel));
        PageKit.Click(PageKit.ButtonNamed(panel, "Open the backup folder of one.localhost"));
        Assert.Equal([@"\\wsl.localhost\Ubuntu\home\akash\frappe-bench\sites\one.localhost\private\backups"], folders);
        PageKit.AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void AnEncryptedBackupCannotBeRestored() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On("site", "backups").Print(PageKit.Fixture("sites-backups.json"));
        PageKit.ClickMenu(view, "More actions for one.localhost", "Restore...");
        PageKit.Wait(view.Pending);
        var panel = view.OpenPanel!;
        Assert.True(PageKit.ButtonNamed(panel, "Restore one.localhost from 20260929_101500").IsEnabled);
        var encrypted = PageKit.ButtonNamed(panel, "Restore one.localhost from 20260920_080000");
        Assert.False(encrypted.IsEnabled);
        Assert.Contains("encrypted", (string)encrypted.ToolTip);
    });

    [Fact]
    public void NoBackupsIsOneLineAndOneAction() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On("site", "backups").Print(PageKit.Fixture("sites-backups-empty.json"));
        kit.Runner.On("site", "backup").Print(PageKit.Fixture("sites-backup.json"));
        PageKit.ClickMenu(view, "More actions for one.localhost", "Backups...");
        PageKit.Wait(view.Pending);
        Assert.Contains("one.localhost has no backup yet.", PageKit.Texts(view.OpenPanel!));
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Back Up one.localhost"));
        PageKit.Wait(view.Pending);
        Assert.Equal(["site", "backup", "one.localhost", "--json", "--bench-dir", P], kit.Runner.Runs.Last().Args);
        Assert.Null(view.OpenPanel);
    });

    [Fact]
    public void AFailedBackupListShowsTheErrorInThePanel() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On("site", "backups").Fail(1, "no such site");
        PageKit.ClickMenu(view, "More actions for one.localhost", "Backups...");
        PageKit.Wait(view.Pending);
        Assert.Contains(PageKit.Texts(view.OpenPanel!), t => t.Contains("no such site"));
    });

    [Fact]
    public void RestoreAsksTheNameFirstThenReviewsThePlanAndRunsItsToken() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On("site", "backups").Print(PageKit.Fixture("sites-backups.json"));
        kit.Runner.On(a => a.Contains("--dry-run")).Print(PageKit.Fixture("sites-restore-plan.json"));
        kit.Runner.On(a => a.Contains("--apply")).Print(PageKit.Fixture("sites-restore-apply.jsonl"));
        PageKit.ClickMenu(view, "More actions for one.localhost", "Restore...");
        PageKit.Wait(view.Pending);
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Restore one.localhost from 20260929_101500"));
        PageKit.Wait(view.Pending);

        var typed = Assert.Single(kit.Typed);
        Assert.Equal("one.localhost", typed.Expected);
        Assert.Equal("Restore", typed.ConfirmLabel);
        var request = Assert.Single(kit.Plans);
        Assert.Equal("Restore", request.ConfirmLabel);
        Assert.False(request.CanStop);
        string[] plan = ["site", "restore", "one.localhost", "--from", "20260929_101500", "--with-files", "--bench-dir", P, "--dry-run", "--json"];
        string[] apply = ["site", "restore", "one.localhost", "--from", "20260929_101500", "--with-files", "--bench-dir", P, "--apply", "8f1c000000000000000000000000000000000000000000000000000000000000", "--yes", "--jsonl"];
        Assert.Equal([plan, apply], kit.RunsOf("site", "restore"));
        Assert.Equal("one.localhost was restored from 20260929_101500.", view.Message);
        Assert.Equal(1, kit.Refreshes);
        Assert.Null(view.OpenPanel);
    });

    [Fact]
    public void ACancelledRestoreConfirmationRunsNothing() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Answer = _ => null;
        var backup = SiteJson.ParseList(System.Text.Json.Nodes.JsonNode.Parse(string.Join('\n', PageKit.Fixture("sites-backups.json")))!.AsObject()).Backups[0];
        PageKit.Wait(view.RestoreAsync("one.localhost", backup));
        Assert.Empty(kit.Plans);
        Assert.Empty(kit.Runner.Runs);
        Assert.False(view.IsBusy);
    });

    // --- Add Site ---

    private static void FillAdd(SitesView view, string name, string password, string confirm)
    {
        var form = view.AddForm!.Value;
        form.Name.Text = name;
        form.Password.Password = password;
        form.Confirm.Password = confirm;
    }

    [Fact]
    public void AddSiteChecksTheFormBeforeAnyCommandRuns() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        PageKit.Click(PageKit.ButtonNamed(view, "Add Site..."));
        PageKit.AssertEveryControlIsNamed(view);
        foreach (var (name, password, confirm, problem) in new[]
        {
            ("", "pw", "pw", "Enter a site name."),
            ("Bad Name", "pw", "pw", SiteNames.Rule),
            ("two.localhost", "pw", "pw", "two.localhost is already a site of this bench."),
            ("qa1.localhost", "", "", "Enter an Administrator password."),
            ("qa1.localhost", "one", "two", "The two passwords are not the same."),
        })
        {
            FillAdd(view, name, password, confirm);
            PageKit.Click(PageKit.ButtonNamed(view, "Review Plan..."));
            PageKit.Wait(view.Pending);
            Assert.Equal(problem, view.AddProblemText);
        }
        Assert.Empty(kit.Plans);
        Assert.Empty(kit.Runner.Runs);
    });

    [Fact]
    public void AddSiteRunsThePlanThenItsTokenAndTheSecretIsOnlyInTheEnvironment() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Runner.On(a => a.Contains("--dry-run")).Print(PageKit.Fixture("site-add-plan.json"));
        kit.Runner.On(a => a.Contains("--apply")).Print(PageKit.Fixture("site-add-apply.jsonl"));
        PageKit.Click(PageKit.ButtonNamed(view, "Add Site..."));
        FillAdd(view, "qa1.localhost", "S3cret-Pass", "S3cret-Pass");
        PageKit.Click(PageKit.ButtonNamed(view, "Review Plan..."));
        PageKit.Wait(view.Pending);

        var request = Assert.Single(kit.Plans);
        Assert.Equal("Add Site", request.ConfirmLabel);
        Assert.False(request.UsesSudoEnv);
        Assert.Equal(2, kit.Runner.Runs.Count);
        Assert.Equal(["site", "add", "qa1.localhost", "--bench-dir", P, "--dry-run", "--json"], kit.Runner.Runs[0].Args);
        Assert.Equal(["site", "add", "qa1.localhost", "--bench-dir", P, "--apply", "3f9c0e1111111111111111111111111111111111111111111111111111111111", "--yes", "--jsonl"], kit.Runner.Runs[1].Args);
        foreach (var run in kit.Runner.Runs)
        {
            Assert.DoesNotContain(run.Args, a => a.Contains("S3cret", StringComparison.Ordinal));
            Assert.Equal("S3cret-Pass", run.Env["ADMIN_PASSWORD"]);
        }
        Assert.Equal("qa1.localhost was added.", view.Message);
        Assert.Equal(1, kit.Refreshes);
        Assert.Null(view.OpenPanel);
        Assert.DoesNotContain("S3cret", string.Join('|', PageKit.Texts(view)));
    });

    [Fact]
    public void WhileThePlanSheetIsOpenTheTabIsBusy() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.PlanGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        kit.Runner.On(a => a.Contains("--dry-run")).Print(PageKit.Fixture("site-add-plan.json"));
        kit.Runner.On(a => a.Contains("--apply")).Print(PageKit.Fixture("site-add-apply.jsonl"));
        PageKit.Click(PageKit.ButtonNamed(view, "Add Site..."));
        FillAdd(view, "qa1.localhost", "pw", "pw");
        PageKit.Click(PageKit.ButtonNamed(view, "Review Plan..."));
        Assert.True(view.IsBusy);
        Assert.False(PageKit.ButtonNamed(view, "Add Site...").IsEnabled);
        kit.PlanGate.SetResult();
        PageKit.Wait(view.Pending);
        PageKit.Drain();
        Assert.False(view.IsBusy);
    });

    [Fact]
    public void ASetUpSiteOffersTheLocalhostNameInsteadOfAHostsLine() => Sta.Run(() =>
    {
        var (view, _) = Make(PageKit.Bench(sites: [("one.localhost", true), ("mysite", false)]));
        PageKit.Click(PageKit.ButtonNamed(view, "Set Up... mysite"));
        var panel = view.OpenPanel!;
        Assert.Contains(PageKit.Texts(panel), t => t.Contains("never edits it"));
        PageKit.Click(PageKit.ButtonNamed(panel, "Add mysite.localhost..."));
        Assert.Equal("mysite.localhost", view.AddForm!.Value.Name.Text);
    });

    // --- Console, Database ---

    [Theory]
    [InlineData("Open Console", "console")]
    [InlineData("Open Database", "mariadb")]
    public void TheShellsOpenInTheDistroInTheBenchFolder(string item, string verb) => Sta.Run(() =>
    {
        var (view, kit) = Make();
        PageKit.ClickMenu(view, "More actions for two.localhost", item);
        var launch = Assert.Single(kit.Terminals);
        Assert.Equal("Ubuntu", launch.Distro);
        Assert.Equal(P, launch.BenchPath);
        Assert.Equal(["bench", "--site", "two.localhost", verb], launch.Command);
        Assert.Equal(["-d", "Ubuntu", "--cd", P, "--exec", "bench", "--site", "two.localhost", verb], launch.WslArguments);
        Assert.Null(view.Message);
        Assert.Empty(kit.Runner.Runs);
    });

    [Fact]
    public void AShellThatCannotOpenSaysWhy() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        kit.Distro = null;
        PageKit.ClickMenu(view, "More actions for two.localhost", "Open Console");
        Assert.Empty(kit.Terminals);
        Assert.Equal(WslCommands.NoDistroMessage, view.Message!.Replace("The console did not open: ", ""));
        kit.Distro = "Ubuntu";
        kit.TerminalError = "wt.exe is blocked";
        PageKit.ClickMenu(view, "More actions for two.localhost", "Open Database");
        Assert.Equal("The database shell did not open: wt.exe is blocked", view.Message);
        Assert.True(view.MessageIsError);
    });

    // --- Drop ---

    private static void ScriptDrop(PageKit kit, string plan = "sites-drop-plan.json")
    {
        kit.Runner.On(a => a.Length > 1 && a[0] == "site" && a[1] == "drop" && a.Contains("--dry-run")).Print(PageKit.Fixture(plan));
    }

    [Fact]
    public void DropShowsThePlanThenAsksTheNameThenRunsConfirmSite() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        ScriptDrop(kit);
        kit.Runner.On(a => a.Length > 1 && a[0] == "site" && a[1] == "drop" && !a.Contains("--dry-run")).Print(PageKit.Fixture("sites-drop-result.json"));
        PageKit.ClickMenu(view, "More actions for two.localhost", "Drop Site...");
        PageKit.Wait(view.Pending);
        Assert.Equal(["site", "drop", "two.localhost", "--confirm-site", "two.localhost", "--dry-run", "--json", "--bench-dir", P], kit.Runner.Runs.Single().Args);
        Assert.NotNull(view.DropPlan);
        Assert.Contains(PageKit.Texts(view.OpenPanel!), t => t.StartsWith("1. Back up two.localhost"));
        Assert.Empty(kit.Typed);

        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Drop two.localhost"));
        PageKit.Wait(view.Pending);
        var typed = Assert.Single(kit.Typed);
        Assert.Equal("two.localhost", typed.Expected);
        Assert.Equal(["site", "drop", "two.localhost", "--confirm-site", "two.localhost", "--json", "--bench-dir", P], kit.Runner.Runs.Last().Args);
        Assert.Contains(PageKit.Texts(view.OpenPanel!), t => t.StartsWith("two.localhost was dropped."));
        Assert.Contains(PageKit.Texts(view.OpenPanel!), t => t.Contains("20261030_121500"));
        Assert.Equal(1, kit.Refreshes);
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Done"));
        Assert.Null(view.OpenPanel);
    });

    [Fact]
    public void ACancelledTypedConfirmationDropsNothing() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        ScriptDrop(kit);
        kit.Answer = _ => null;
        PageKit.ClickMenu(view, "More actions for two.localhost", "Drop Site...");
        PageKit.Wait(view.Pending);
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Drop two.localhost"));
        PageKit.Wait(view.Pending);
        Assert.Single(kit.Runner.Runs); // only the plan
        Assert.False(view.IsBusy);
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Cancel"));
        Assert.Null(view.OpenPanel);
    });

    [Fact]
    public void DroppingTheDefaultSiteNamesTheNewDefault() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        ScriptDrop(kit, "sites-drop-plan-default.json");
        kit.Runner.On(a => a.Length > 1 && a[0] == "site" && a[1] == "drop" && !a.Contains("--dry-run")).Print(PageKit.Fixture("sites-drop-result.json"));
        PageKit.ClickMenu(view, "More actions for one.localhost", "Drop Site...");
        PageKit.Wait(view.Pending);
        Assert.Equal(["site", "drop", "one.localhost", "--confirm-site", "one.localhost", "--new-default", "two.localhost", "--dry-run", "--json", "--bench-dir", P],
            kit.Runner.Runs.Single().Args);
        var picker = PageKit.Walk(view.OpenPanel!).OfType<ComboBox>().Single();
        Assert.Equal(["two.localhost"], picker.Items.Cast<string>());
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Drop one.localhost"));
        PageKit.Wait(view.Pending);
        Assert.Equal(["site", "drop", "one.localhost", "--confirm-site", "one.localhost", "--new-default", "two.localhost", "--json", "--bench-dir", P],
            kit.Runner.Runs.Last().Args);
        PageKit.AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void ADropThatIsRunningCannotBeDismissed() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        ScriptDrop(kit);
        var held = kit.Runner.On(a => a.Length > 1 && a[0] == "site" && a[1] == "drop" && !a.Contains("--dry-run")).Hold();
        PageKit.ClickMenu(view, "More actions for two.localhost", "Drop Site...");
        PageKit.Wait(view.Pending);
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Drop two.localhost"));
        Assert.True(view.IsBusy);
        Assert.Empty(PageKit.Walk(view.OpenPanel!).OfType<Button>()); // no Cancel, no Close, nothing
        Assert.False(PageKit.ButtonNamed(view, "More actions for one.localhost").IsEnabled);
        Assert.Contains(PageKit.Texts(view.OpenPanel!), t => t.StartsWith("Backing up and dropping two.localhost"));
        held.Release(PageKit.Fixture("sites-drop-result.json"));
        PageKit.Wait(view.Pending);
        PageKit.Drain();
        Assert.False(view.IsBusy);
        Assert.NotNull(PageKit.FindButton(view.OpenPanel!, "Done"));
    });

    [Fact]
    public void AFailedDropShowsTheErrorAndKeepsTheSite() => Sta.Run(() =>
    {
        var (view, kit) = Make();
        ScriptDrop(kit);
        kit.Runner.On(a => a.Length > 1 && a[0] == "site" && a[1] == "drop" && !a.Contains("--dry-run")).Fail(1, "MariaDB refused the drop");
        PageKit.ClickMenu(view, "More actions for two.localhost", "Drop Site...");
        PageKit.Wait(view.Pending);
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Drop two.localhost"));
        PageKit.Wait(view.Pending);
        Assert.Contains(PageKit.Texts(view.OpenPanel!), t => t.Contains("MariaDB refused the drop"));
        Assert.Equal(0, kit.Refreshes);
        Assert.False(view.IsBusy);
        PageKit.Click(PageKit.ButtonNamed(view.OpenPanel!, "Close"));
    });
}
