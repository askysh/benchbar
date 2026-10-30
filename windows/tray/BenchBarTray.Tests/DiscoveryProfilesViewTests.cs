using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>A WSL that starts nothing: a home folder and a table of Windows paths with their Linux paths.</summary>
internal sealed class ViewWsl : IWslHost
{
    public string? Home { get; set; } = "/home/akash";
    public Dictionary<string, string> Paths { get; } = new(StringComparer.OrdinalIgnoreCase);

    public Task<string?> HomeAsync(CancellationToken ct) => Task.FromResult(Home);

    public Task<PathConversion> ToLinuxPathAsync(string path, CancellationToken ct) =>
        Task.FromResult(!WslPaths.IsWindowsPath(path) ? new PathConversion(path.Trim(), null)
            : Paths.TryGetValue(path.Trim(), out var linux) ? new PathConversion(linux, null) : new PathConversion(null, "wslpath failed"));
}

/// <summary>Find Benches and Team Profiles: every control is named, every action makes the documented call, and an empty state is one line and one action.</summary>
public class DiscoveryProfilesViewTests
{
    private const string Projects = "/home/akash/projects";
    private const string Added = Projects + "/added-bench";
    private const string Loose = Projects + "/loose-bench";
    private const string WindowsToml = @"C:\Users\akash\Downloads\acme.toml";


    private static void Click(Button button) => button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));

    private static Button ButtonNamed(DependencyObject root, string name) =>
        Walk(root).OfType<Button>().First(b => AutomationProperties.GetName(b) == name);

    private static TextBox BoxNamed(DependencyObject root, string name) =>
        Walk(root).OfType<TextBox>().First(b => AutomationProperties.GetName(b) == name);

    private sealed class Rig
    {
        public ScriptedStreamRunner Runner { get; } = new();
        public List<PlanReviewRequest> Reviews { get; } = [];
        public int Refreshes { get; set; }
        public List<string> Copied { get; } = [];
        public PageServices Services { get; }

        public Rig()
        {
            SynchronizationContext.SetSynchronizationContext(null);
            Services = new PageServices
            {
                Cli = new CliClient(Runner, () => "benchbar.exe"),
                ReviewPlan = request =>
                {
                    Reviews.Add(request);
                    return Task.FromResult(PlanOutcome.None);
                },
                RefreshNow = () => Refreshes++,
                CopyText = Copied.Add,
            };
        }
    }

    private static (DiscoveryView View, Rig Rig, ViewWsl Wsl) Discovery()
    {
        var rig = new Rig();
        rig.Runner.On("scan").Print(Fixture("scan-result.json"));
        rig.Runner.On("list").Print(Fixture("scan-list.json"));
        var wsl = new ViewWsl();
        return (new DiscoveryView(rig.Services, wsl, new RecentFolders()), rig, wsl);
    }

    // --- Find Benches ---

    [Fact]
    public void BeforeAScanThePaneIsOneLineAndOneAction() => Sta.Run(() =>
    {
        var (view, _, _) = Discovery();
        Assert.Contains("Your benches, in one place", view.Lines);
        Assert.Equal(["Scan Folder"], view.ButtonLabels);
        Assert.Single(view.Lines, l => l.StartsWith("Scan a folder such as your home"));
        AssertEveryControlIsNamed(view);
        Assert.NotNull(ButtonNamed(view, "Choose Folder"));
        Assert.NotNull(ButtonNamed(view, "Scan this folder"));
        Assert.NotNull(BoxNamed(view, "Folder to search in Linux"));
    });

    [Fact]
    public void ShowingThePaneFillsTheFolderWithTheHomeFromWsl() => Sta.Run(() =>
    {
        var (view, rig, _) = Discovery();
        view.EnterAsync().GetAwaiter().GetResult();
        Assert.Equal("/home/akash", view.FolderText);
        Assert.Empty(rig.Runner.Runs); // showing the pane never scans
    });

    [Fact]
    public void ChooseFolderOffersTheHomeAndTheRecentFolders() => Sta.Run(() =>
    {
        var rig = new Rig();
        var recent = new RecentFolders();
        recent.Add("/home/akash/work");
        var view = new DiscoveryView(rig.Services, new ViewWsl(), recent);
        Assert.Equal(["Home folder (~)", "/home/akash/work"], view.ChooseFolderItems());
    });

    [Fact]
    public void TypingAFolderAndPressingScanRunsScanWithThatFolder() => Sta.Run(() =>
    {
        var (view, rig, _) = Discovery();
        BoxNamed(view, "Folder to search in Linux").Text = Projects;
        Click(ButtonNamed(view, "Scan this folder"));
        Assert.Equal(["scan", Projects, "--json"], rig.Runner.Runs[0].Args);
        Assert.Equal(["list", "--json"], rig.Runner.Runs[1].Args);
    });

    [Fact]
    public void TheResultsShowEachBenchWithItsStateAndEveryControlIsNamed() => Sta.Run(() =>
    {
        var (view, _, _) = Discovery();
        view.Model.Folder = Projects;
        view.Model.ScanAsync().GetAwaiter().GetResult();
        Assert.Contains("3 benches found", view.Lines);
        Assert.Contains("Managed by BenchBar", view.Lines);
        Assert.Contains("Added · Management needs setup", view.Lines);
        Assert.Contains("Not adopted", view.Lines);
        Assert.Contains("Port conflict · Review during setup", view.Lines);
        Assert.Contains("managed.localhost · Port 8000", view.Lines);
        Assert.Equal(["Select All", "Set Up Management...", "Set Up Management...", "Add Selected", "Set Up Selected..."], view.ButtonLabels);
        Assert.Contains("2 scan warnings", view.Lines);
        Assert.Single(Walk(view).OfType<Expander>());
        AssertEveryControlIsNamed(view);

        var boxes = Walk(view).OfType<CheckBox>().ToList();
        Assert.Equal(2, boxes.Count); // the managed bench has a mark, not a box
        Assert.Equal([$"Select added-bench at {Added}", $"Select loose-bench at {Loose}"], boxes.Select(AutomationProperties.GetName));
        Assert.Equal([false, true], boxes.Select(b => b.IsChecked == true));
        Assert.Contains(Walk(view).OfType<TextBlock>(), t => AutomationProperties.GetName(t) == "managed-bench is managed by BenchBar");
    });

    [Fact]
    public void ClickingABoxChangesTheSelectionAndTheCount() => Sta.Run(() =>
    {
        var (view, _, _) = Discovery();
        view.Model.Folder = Projects;
        view.Model.ScanAsync().GetAwaiter().GetResult();
        Assert.Contains("1 selected", view.Lines);
        var box = Walk(view).OfType<CheckBox>().First(b => AutomationProperties.GetName(b).Contains("added-bench"));
        box.IsChecked = true;
        box.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Assert.Contains("2 selected", view.Lines);
        Assert.Contains("Deselect All", view.ButtonLabels);
        Click(ButtonNamed(view, "Deselect All"));
        Assert.Contains("0 selected", view.Lines);
        Assert.False(ButtonNamed(view, "Set Up Selected").IsEnabled);
        Assert.False(ButtonNamed(view, "Add Selected").IsEnabled);
    });

    [Fact]
    public void AFolderWithNoBenchesIsOneLineAndOneAction() => Sta.Run(() =>
    {
        var rig = new Rig();
        rig.Runner.On("scan").Print(Fixture("scan-empty.json"));
        rig.Runner.On("list").Print(Fixture("scan-list.json"));
        var view = new DiscoveryView(rig.Services, new ViewWsl(), new RecentFolders());
        view.Model.Folder = "/home/akash/empty";
        view.Model.ScanAsync().GetAwaiter().GetResult();
        Assert.Contains("No benches found", view.Lines);
        Assert.Equal(["Choose Another Folder..."], view.ButtonLabels);
        Assert.Single(view.Lines, l => l.StartsWith("Choose a folder containing a bench"));
        AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void AFailedScanShowsTheErrorAndKeepsTheEmptyState() => Sta.Run(() =>
    {
        var rig = new Rig();
        rig.Runner.On("scan").Fail(1, "scan: /nope is not a folder");
        var view = new DiscoveryView(rig.Services, new ViewWsl(), new RecentFolders());
        view.Model.Folder = "/nope";
        view.Model.ScanAsync().GetAwaiter().GetResult();
        Assert.Contains(view.Lines, l => l.Contains("is not a folder"));
        Assert.Equal(["Scan Folder"], view.ButtonLabels);
    });

    [Fact]
    public void CancelScanIsOfferedWhileScanningAndStopsIt() => Sta.Run(() =>
    {
        var rig = new Rig();
        var held = rig.Runner.On("scan").Hold();
        var view = new DiscoveryView(rig.Services, new ViewWsl(), new RecentFolders());
        view.Model.Folder = Projects;
        var scan = view.Model.ScanAsync();
        held.Started.Task.Wait(TimeSpan.FromSeconds(10));
        Assert.Contains("Searching folders...", view.Lines);
        Assert.Contains("Cancel Scan", view.ButtonLabels);
        Assert.False(ButtonNamed(view, "Scan this folder").IsEnabled);
        AssertEveryControlIsNamed(view);
        Click(ButtonNamed(view, "Cancel Scan"));
        scan.GetAwaiter().GetResult();
        Assert.Contains("Scan cancelled.", view.Lines);
        Assert.DoesNotContain("Cancel Scan", view.ButtonLabels);
        Assert.True(ButtonNamed(view, "Scan this folder").IsEnabled);
    });

    [Fact]
    public void AddSelectedRegistersTheSelectedBenchesAndPollsAgain() => Sta.Run(() =>
    {
        var (view, rig, _) = Discovery();
        rig.Runner.On("register").Print(Fixture("scan-register.json"));
        view.Model.Folder = Projects;
        view.Model.ScanAsync().GetAwaiter().GetResult();
        view.AddSelectedAsync().GetAwaiter().GetResult();
        Assert.Equal(["register", "--json", "--", Loose], rig.Runner.Runs.Last().Args);
        Assert.Equal(1, rig.Refreshes);
        Assert.Contains("Added 1 bench to BenchBar.", view.Lines);
    });

    [Fact]
    public void SetUpSelectedOpensThePlanSheetWithThePortPlan() => Sta.Run(() =>
    {
        var (view, rig, _) = Discovery();
        rig.Runner.On("ports", "plan").Print(Fixture("scan-ports-plan.json"));
        view.Model.Folder = Projects;
        view.Model.ScanAsync().GetAwaiter().GetResult();
        view.SetUpSelectedAsync().GetAwaiter().GetResult();
        var request = Assert.Single(rig.Reviews);
        Assert.Equal(["ports", "plan", "--json", "--", Loose], request.PlanArgs);
        Assert.Equal("Set Up Management", request.Title);
        Assert.Contains("Set Up Selected...", view.ButtonLabels); // drawn again after the sheet
    });

    [Fact]
    public void ABlockedPlanOpensNoSheetAndTheReasonIsOnTheScreen() => Sta.Run(() =>
    {
        var (view, rig, _) = Discovery();
        rig.Runner.On("ports", "plan").Print(Fixture("scan-ports-plan-blocked.json"));
        view.Model.Folder = Projects;
        view.Model.ScanAsync().GetAwaiter().GetResult();
        view.SetUpSelectedAsync().GetAwaiter().GetResult();
        Assert.Empty(rig.Reviews);
        Assert.Contains("Setup is blocked. loose-bench: it is running; stop it first", view.Lines);
    });

    [Fact]
    public void SetUpManagementOnARowReadsTheAdoptPlan() => Sta.Run(() =>
    {
        var (view, rig, _) = Discovery();
        view.Model.Folder = Projects;
        view.Model.ScanAsync().GetAwaiter().GetResult();
        var bench = view.Model.Results.Single(b => b.Path == Added);
        Click(ButtonNamed(view, "Set Up Management for added-bench"));
        var request = Assert.Single(rig.Reviews);
        Assert.Equal(["adopt", Added, "--dry-run", "--json"], request.PlanArgs);
        Assert.True(request.UsesSudoEnv);
        Assert.Equal("Set Up Management for added-bench", request.Title);
        _ = bench;
    });

    // --- Team Profiles ---

    private static (ProfilesView View, Rig Rig, List<Window> Sheets) Profiles(string list = "profile-list.json", bool benches = true)
    {
        var rig = new Rig();
        rig.Runner.On("profile", "list").Print(Fixture(list));
        if (benches) rig.Runner.On("list").Print(Fixture("scan-list.json"));
        var wsl = new ViewWsl();
        wsl.Paths[WindowsToml] = "/mnt/c/Users/akash/Downloads/acme.toml";
        wsl.Paths[@"C:\Users\akash\Desktop\acme.toml"] = "/mnt/c/Users/akash/Desktop/acme.toml";
        var sheets = new List<Window>();
        var view = new ProfilesView(rig.Services, wsl) { ShowSheet = sheets.Add, Distro = () => "Ubuntu" };
        view.Model.LoadAsync().GetAwaiter().GetResult();
        return (view, rig, sheets);
    }

    private static ProfileInfo Profile(ProfilesView view, string name) => view.Model.Profiles.Single(p => p.Name == name);

    [Fact]
    public void TheListShowsEveryProfileWithItsTagsAndATeamProfileHasActions() => Sta.Run(() =>
    {
        var (view, _, _) = Profiles();
        Assert.Contains("v15-lts", view.Lines);
        Assert.Contains("built in", view.Lines);
        Assert.Contains("subscribed · acme/bench-config", view.Lines);
        Assert.Contains("based on v15-lts", view.Lines);
        Assert.Contains("Outdated · 2 commits / 5 days", view.Lines);
        Assert.Contains("Not used: /home/akash/.config/benchbar/profiles/broken.toml has the same name and comes first", view.Lines);
        Assert.Contains(view.Lines, l => l.Contains("not supported"));
        Assert.Equal(Enumerable.Repeat("Actions", 5), view.ButtonLabels); // five team profiles, the built in one has none
        AssertEveryControlIsNamed(view);
        Assert.Equal(5, Walk(view).OfType<Button>().Count(b => AutomationProperties.GetName(b).StartsWith("Actions for ")));
        Assert.NotNull(ButtonNamed(view, "Add Profile"));
    });

    [Fact]
    public void OnlyTheBuiltInProfilesIsOneLineAndOneAction() => Sta.Run(() =>
    {
        var (view, _, sheets) = Profiles("profile-list-builtin-only.json");
        Assert.Contains("Only the built in profiles", view.Lines);
        Assert.Equal(["Import..."], view.ButtonLabels);
        Assert.Single(view.Lines, l => l.StartsWith("A team profile pins your team's apps"));
        AssertEveryControlIsNamed(view);
        Click(ButtonNamed(view, "Import..."));
        Assert.IsType<ImportProfileSheet>(Assert.Single(sheets));
    });


    [Fact]
    public void AProfileListThatFailsIsOneLineAndOneAction() => Sta.Run(() =>
    {
        var rig = new Rig();
        rig.Runner.On("profile", "list").Fail(1, "profile: broken config");
        var view = new ProfilesView(rig.Services, new ViewWsl());
        view.Model.LoadAsync().GetAwaiter().GetResult();
        Assert.Contains("The profiles could not be read", view.Lines);
        Assert.Equal(["Try Again"], view.ButtonLabels);
        Assert.Contains(view.Lines, l => l.Contains("broken config"));
        AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void TheAddProfileMenuHasThreeEntriesAndCreateNeedsABench() => Sta.Run(() =>
    {
        var (view, _, _) = Profiles();
        var menu = view.BuildAddMenu();
        var items = menu.Items.OfType<MenuItem>().ToList();
        Assert.Equal(["Create from Bench...", "Import...", "Subscribe to a Repository..."], items.Select(i => (string)i.Header));
        Assert.True(items[0].IsEnabled);

        var (noBench, _, _) = Profiles(benches: false);
        Assert.False(noBench.BuildAddMenu().Items.OfType<MenuItem>().First().IsEnabled);
    });

    [Fact]
    public void TheProfileMenuOffersOnlyWhatApplies() => Sta.Run(() =>
    {
        var (view, _, _) = Profiles();
        string[] Headers(string name) => view.BuildProfileMenu(Profile(view, name)).Items.OfType<MenuItem>().Select(i => (string)i.Header).ToArray();
        Assert.Equal(["Export...", "Update...", "Check Access", "Show in Explorer", "Remove Subscription..."], Headers("acme"));
        Assert.Equal(["Export...", "Update...", "Check Access", "Show in Explorer", "Remove..."], Headers("shared"));
        Assert.Equal(["Export...", "Check Access", "Show in Explorer"], Headers("mine"));
        var broken = view.BuildProfileMenu(Profile(view, "broken")).Items.OfType<MenuItem>().ToList();
        Assert.False(broken[0].IsEnabled); // an invalid profile cannot be exported
        Assert.False(broken[1].IsEnabled); // or checked
    });

    [Fact]
    public void CreateFromBenchAsksForANameAndABenchThenRunsProfileCreate() => Sta.Run(() =>
    {
        var (view, rig, sheets) = Profiles();
        rig.Runner.On("profile", "create").Print("wrote it");
        view.ShowSheet = sheet =>
        {
            sheets.Add(sheet);
            var create = (CreateProfileSheet)sheet;
            Assert.Equal(["Create", "Cancel"], create.ButtonLabels);
            Assert.False(create.CanCreate);
            AssertEveryControlIsNamed(create);
            create.ProfileNameText = "Bad Name";
            Assert.Contains("Lower case letters, digits, '.', '_' or '-', starting with a letter or digit.", create.Lines);
            Assert.False(create.CanCreate);
            create.ProfileNameText = "team-x";
            Assert.True(create.CanCreate);
            Assert.Equal("/home/akash/projects/managed-bench", create.SelectedBenchPath);
            Click(create.BarButton("Create"));
        };
        view.CreateFromBench();
        var run = rig.Runner.Runs.First(r => r.Args[1] == "create").Args;
        Assert.Equal(["profile", "create", "team-x", "--from-bench", "/home/akash/projects/managed-bench", "--yes"], run);
    });

    [Fact]
    public void ImportSheetReviewsAWindowsFileThenOffersToReplace() => Sta.Run(() =>
    {
        var (view, rig, sheets) = Profiles();
        rig.Runner.On("profile", "import").Print(Fixture("profile-import-plan.json"));
        var sheet = view.Import();
        Assert.Same(sheet, sheets.Single());
        Assert.Equal(["Review", "Cancel", "Add Profile"], sheet.ButtonLabels);
        Assert.False(sheet.BarButton("Review").IsEnabled);
        AssertEveryControlIsNamed(sheet);

        BoxNamed(sheet, "File or https URL").Text = "acme.toml";
        Assert.Contains("Use a .toml file on this PC or in Linux, or an https URL.", sheet.Lines);
        BoxNamed(sheet, "File or https URL").Text = WindowsToml;
        Assert.True(sheet.BarButton("Review").IsEnabled);
        Click(sheet.BarButton("Review"));
        Assert.Equal(["profile", "import", "/mnt/c/Users/akash/Downloads/acme.toml", "--plan", "--json"], rig.Runner.Runs.First(r => r.Args[1] == "import").Args);
        Assert.Equal(["Review", "Cancel", "Replace Profile"], sheet.ButtonLabels);
        Assert.True(sheet.BarButton("Replace Profile").IsEnabled);
        Assert.Contains("Profile: acme", sheet.Lines);
        Assert.Contains("acme_ecr @ develop", sheet.Lines);
        Assert.Contains("Permission denied (publickey).", sheet.Lines);
        Assert.Contains("A profile named acme exists. Adding this one replaces it:", sheet.Lines);
        AssertEveryControlIsNamed(sheet);

        BoxNamed(sheet, "Save as").Text = "other"; // changed after the review: add is off
        Assert.False(sheet.BarButton("Replace Profile").IsEnabled);
    });

    [Fact]
    public void ImportSheetShowsTheResultAfterAdding() => Sta.Run(() =>
    {
        var (view, rig, _) = Profiles();
        rig.Runner.On("profile", "import", "/mnt/c/Users/akash/Downloads/acme.toml", "--plan").Print(Fixture("profile-import-plan.json"));
        rig.Runner.On("profile", "import", "/mnt/c/Users/akash/Downloads/acme.toml", "--expect").Print(Fixture("profile-import-result.json"));
        var revealed = new List<string>();
        view.RevealWindowsPath = revealed.Add;
        var sheet = view.Import(WindowsToml);
        sheet.Run.ReviewAsync().GetAwaiter().GetResult();
        sheet.Run.AddAsync().GetAwaiter().GetResult();
        Assert.Contains("Added acme", sheet.Lines);
        Assert.Equal(["Show in Explorer", "Done"], sheet.ButtonLabels);
        Click(sheet.BarButton("Show in Explorer"));
        Assert.Equal([@"\\wsl.localhost\Ubuntu\home\akash\.config\benchbar\profiles\acme.toml"], revealed);
        AssertEveryControlIsNamed(sheet);
    });

    [Fact]
    public void SubscribeSheetChecksTheAddressAndRunsProfileSubscribe() => Sta.Run(() =>
    {
        var (view, rig, _) = Profiles();
        rig.Runner.On("profile", "subscribe").Print(Fixture("profile-subscribe.json"));
        var sheet = view.Subscribe();
        Assert.Equal(["Cancel", "Subscribe"], sheet.ButtonLabels);
        Assert.False(sheet.BarButton("Subscribe").IsEnabled);
        AssertEveryControlIsNamed(sheet);
        BoxNamed(sheet, "Git repository").Text = "file:///etc";
        Assert.Contains("Use an https, ssh or git@host:owner/repo URL.", sheet.Lines);
        BoxNamed(sheet, "Git repository").Text = "git@github.com:acme/bench-config.git";
        Assert.True(sheet.BarButton("Subscribe").IsEnabled);
        Click(sheet.BarButton("Subscribe"));
        Assert.Equal(["profile", "subscribe", "git@github.com:acme/bench-config.git", "--yes", "--json"], rig.Runner.Runs.First(r => r.Args[1] == "subscribe").Args);
        Assert.Contains("Subscribed to acme/bench-config", sheet.Lines);
        Assert.Contains("Profiles: acme, acme-lite.", sheet.Lines);
        Assert.Equal(["Show in Explorer", "Done"], sheet.ButtonLabels);
    });

    [Fact]
    public void ExportSheetListsTheAppsBlocksARequiredDropAndWritesToAWindowsPath() => Sta.Run(() =>
    {
        var (view, rig, _) = Profiles();
        rig.Runner.On("profile", "export", "acme", "--plan").Print(Fixture("profile-export-plan.json"));
        rig.Runner.On("profile", "export", "acme", "--out").Print(Fixture("profile-export-result.json"));
        view.PickExportFile = suggested =>
        {
            Assert.Equal("acme.toml", suggested);
            return @"C:\Users\akash\Desktop\acme.toml";
        };
        var revealed = new List<string>();
        view.RevealWindowsPath = revealed.Add;
        var sheet = view.Export(Profile(view, "acme"));
        Assert.Equal(["Cancel", "Export..."], sheet.ButtonLabels);
        Assert.Equal(2, sheet.KeepBoxes.Count);
        Assert.Equal(["main", "develop"], sheet.BranchBoxes.Select(b => b.Text));
        Assert.True(sheet.BarButton("Export...").IsEnabled);
        AssertEveryControlIsNamed(sheet);

        sheet.KeepBoxes[0].IsChecked = false; // acme_base, which acme_ecr requires
        sheet.KeepBoxes[0].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Assert.Contains("acme_base is required by acme_ecr: keep it, or drop those too.", sheet.Lines);
        Assert.False(sheet.BarButton("Export...").IsEnabled);
        sheet.KeepBoxes[0].IsChecked = true;
        sheet.KeepBoxes[0].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Assert.True(sheet.BarButton("Export...").IsEnabled);

        Click(sheet.BarButton("Export..."));
        Assert.Equal("--out", rig.Runner.Runs.First(r => r.Args[1] == "export" && r.Args.Contains("--out")).Args[3]);
        Assert.Contains("Exported 2 apps", sheet.Lines);
        Assert.Equal(["Show in Explorer", "Done"], sheet.ButtonLabels);
        Click(sheet.BarButton("Show in Explorer"));
        Assert.Equal([@"C:\Users\akash\Desktop\acme.toml"], revealed);

        // the import link: only for an https address
        Assert.False(sheet.CopyButton.IsEnabled);
        sheet.HostedBox.Text = "https://github.com/acme/profiles/blob/main/acme.toml";
        Assert.True(sheet.CopyButton.IsEnabled);
        Click(sheet.CopyButton);
        Assert.Equal(["benchbar://profile/import?url=https%3A%2F%2Fgithub.com%2Facme%2Fprofiles%2Fblob%2Fmain%2Facme.toml"], rig.Copied);
        AssertEveryControlIsNamed(sheet);
    });

    [Fact]
    public void UpdateSheetShowsTheDiffThenAppliesAndAnUpToDateProfileOnlyCloses() => Sta.Run(() =>
    {
        var (view, rig, _) = Profiles();
        rig.Runner.On("profile", "update", "acme", "--plan").Print(Fixture("profile-update-plan.json"));
        rig.Runner.On("profile", "update", "acme", "--expect").Print(Fixture("profile-update-applied.json"));
        var sheet = view.Update(Profile(view, "acme"));
        Assert.Equal(["Cancel", "Update"], sheet.ButtonLabels);
        Assert.Contains("acme  ·  subscribed  ·  2 commits behind", sheet.Lines);
        Assert.Contains(sheet.Lines, l => l.Contains("+new"));
        AssertEveryControlIsNamed(sheet);
        Click(sheet.BarButton("Update"));
        Assert.Contains("Updated acme", sheet.Lines);
        Assert.Equal(["Done"], sheet.ButtonLabels);

        var (second, secondRig, _) = Profiles();
        secondRig.Runner.On("profile", "update").Print(Fixture("profile-update-none.json"));
        var upToDate = second.Update(Profile(second, "shared"));
        Assert.Contains("shared is up to date", upToDate.Lines);
        Assert.Equal(["Close"], upToDate.ButtonLabels);
    });

    [Fact]
    public void CheckAccessSheetMarksEachRepositoryAndCanCheckAgain() => Sta.Run(() =>
    {
        var (view, rig, _) = Profiles();
        rig.Runner.On("profile", "check").Print(Fixture("profile-check.json"));
        var sheet = view.CheckAccess(Profile(view, "mine"));
        Assert.Equal(["Check Again", "Done"], sheet.ButtonLabels);
        Assert.Contains("2 repositories are not reachable", sheet.Lines);
        Assert.Contains("Permission denied (publickey).", sheet.Lines);
        Assert.Contains("timed out", sheet.Lines);
        Assert.Equal(["profile", "check", "mine", "--json"], rig.Runner.Runs.First(r => r.Args[1] == "check").Args);
        AssertEveryControlIsNamed(sheet);
        Click(sheet.BarButton("Check Again"));
        Assert.Equal(2, rig.Runner.Runs.Count(r => r.Args[1] == "check"));
    });

    [Fact]
    public void ShowInExplorerOpensTheProfileFileThroughWslLocalhost() => Sta.Run(() =>
    {
        var (view, _, _) = Profiles();
        var revealed = new List<string>();
        view.RevealWindowsPath = revealed.Add;
        view.ShowInExplorer(Profile(view, "mine"));
        Assert.Equal([@"\\wsl.localhost\Ubuntu\home\akash\.config\benchbar\profiles\mine.toml"], revealed);

        view.Distro = () => null;
        view.ShowInExplorer(Profile(view, "mine"));
        Assert.Single(revealed);
        Assert.Contains(view.Lines, l => l.Contains("could not tell which Linux distro"));
    });

    [Fact]
    public void RemoveAsksFirstAndRunsProfileRemoveOnlyWhenConfirmed() => Sta.Run(() =>
    {
        var (view, rig, _) = Profiles();
        rig.Runner.On("profile", "remove").Print(Fixture("profile-remove.json"));
        var asked = new List<(string Title, string Message)>();
        var answer = false;
        view.Confirm = (title, message) =>
        {
            asked.Add((title, message));
            return answer;
        };
        view.RemoveAsync(Profile(view, "mine")).GetAwaiter().GetResult();
        Assert.DoesNotContain(rig.Runner.Runs, r => r.Args[1] == "remove");
        Assert.Equal("Remove mine?", asked.Single().Title);

        answer = true;
        view.RemoveAsync(Profile(view, "mine")).GetAwaiter().GetResult();
        Assert.Equal(["profile", "remove", "mine", "--yes", "--json"], rig.Runner.Runs.First(r => r.Args[1] == "remove").Args);
        Assert.Equal(1, rig.Refreshes);
        Assert.Contains(view.Lines, l => l.StartsWith("Removed mine."));
    });
}
