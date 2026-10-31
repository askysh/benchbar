using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>The beta wording, Report a Bug and the 0.8.1 window fixes.</summary>
public class BetaViewTests
{
    private static BenchStatus OneBench() => Bench(BenchState.Running, "/home/a/frappe-bench", ("one.localhost", true));

    // --- the beta ---

    [Fact]
    public void TheWindowSaysBetaInTheTitleTheSidebarPillAndTheBanner() => Sta.Run(() =>
    {
        var dismissed = 0;
        var reports = new List<(string Entry, string? Problem)>();
        var visible = true;
        var window = new MainWindow(new MainActions
        {
            BetaBannerVisible = () => visible,
            DismissBetaBanner = () =>
            {
                dismissed++;
                visible = false;
            },
            ReportBug = (entry, problem) => reports.Add((entry, problem)),
        }, Theme);
        Assert.Equal("BenchBar (Beta)", window.Title);
        Assert.Equal("BenchBar (Beta)", AutomationProperties.GetName(window));
        Assert.Contains(Walk(window).OfType<Border>(), b => AutomationProperties.GetName(b) == "Beta: BenchBar for Windows is in beta");
        Assert.Contains("BenchBar for Windows is in beta. If something breaks or confuses you, tell us.", Texts(window));
        Assert.True(window.BetaBannerShown);
        Assert.Contains(Walk(window).OfType<Border>(), b => AutomationProperties.GetName(b).StartsWith("Beta notice", StringComparison.Ordinal));

        Click(ButtonNamed(window, "Report a bug"));
        Assert.Equal([("Beta banner", (string?)null)], reports);
        Assert.True(window.BetaBannerShown); // reporting does not dismiss it

        Click(ButtonNamed(window, "Dismiss the beta notice"));
        Assert.False(window.BetaBannerShown);
        Assert.Equal(1, dismissed);
        AssertEveryControlIsNamed(window);

        Assert.False(new MainWindow(new MainActions { BetaBannerVisible = () => visible }, Theme).BetaBannerShown); // it stays away once dismissed
    });

    [Fact]
    public void TheAboutWindowHasThePillAndTheBetaText() => Sta.Run(() =>
    {
        var about = new AboutWindow(new AboutActions(), Theme);
        Assert.Contains("BenchBar for Windows is in beta. It works, and you may find rough edges. Report a Bug writes a redacted report and opens a GitHub issue for it, in about a minute.", Texts(about));
        Assert.Contains(Walk(about).OfType<Border>(), b => AutomationProperties.GetName(b) == "Beta: BenchBar for Windows is in beta");
        AssertEveryControlIsNamed(about);
    });

    [Fact]
    public void AboutSaysNotInstalledYetNotTheDistroMayBeStopped() => Sta.Run(() =>
    {
        var about = new AboutWindow(new AboutActions { CliVersion = () => Task.FromResult(AboutCli.NotInstalled) }, Theme);
        Pump(() => about.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent)), () => Texts(about).Contains("not installed yet"));
    });

    // --- the wizard ---

    private sealed class Host : IWizardHost
    {
        public void SetResumeAfterLogon(bool on) { }
        public bool RestartWindows() => true;
        public string WindowsUserName => "Akash";
        public string? ConfiguredDistro => "Ubuntu-24.04";
        public bool Notifications { get; set; } = true;
        public bool OpenAtLogon { get; set; }
        public void OpenUrl(string url) { }
        public void CopyText(string text) { }
    }

    private static FixtureSetupService Setup(string check = "check.json", string? edit = null, string? to = null)
    {
        var root = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"));
        var target = Path.Combine(root, "setup");
        Directory.CreateDirectory(target);
        var source = Path.Combine(BenchBar.Tray.TestSupport.FixtureFiles.Root, "setup");
        foreach (var file in Directory.GetFiles(source)) File.Copy(file, Path.Combine(target, Path.GetFileName(file)));
        var text = File.ReadAllText(Path.Combine(source, check));
        if (edit is not null) text = text.Replace(edit, to);
        File.WriteAllText(Path.Combine(target, "check.json"), text);
        return new FixtureSetupService(root);
    }

    [Fact]
    public void TheWelcomePageHasTheBetaLineAndEveryPageHasAReportABugLink() => Sta.Run(() =>
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var reports = new List<(string, string?)>();
        var model = new WizardModel(Setup(), new Host());
        var view = new WizardView(model, new WizardActions { ReportBug = (entry, problem) => reports.Add((entry, problem)) });
        view.Update();
        Assert.Contains("This is a beta. If a step fails, Report This Problem sends us what we need.", Texts(view));
        Click(ButtonNamed(view, "Report a Bug"));
        Assert.Equal([("Setup wizard footer", (string?)null)], reports);

        model.ChooseCommandLineOnly();
        view.Update();
        Assert.NotNull(FindButton(view, "Report a Bug"));
    });

    [Fact]
    public void PagesWithPasswordBoxesDoNotMakeBackTheEscapeButton() => Sta.Run(() =>
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var model = new WizardModel(Setup(), new Host());
        model.ChooseNewBench().GetAwaiter().GetResult();
        model.ContinueFromCheckAsync().GetAwaiter().GetResult();
        Assert.Equal(WizardPage.NewBench, model.Page);
        var view = new WizardView(model, new WizardActions());
        view.Update();
        Assert.False(ButtonNamed(view, "Back to the previous page").IsCancel);

        var stuck = new WizardModel(Setup(), new Host());
        stuck.ChooseCommandLineOnly();
        var cli = new WizardView(stuck, new WizardActions());
        cli.Update();
        Assert.True(ButtonNamed(cli, "Back to the previous page").IsCancel); // a page with nothing typed keeps Esc
    });

    private const string VirtOk = "{\"id\":\"virtualization\",\"status\":\"ok\",\"title\":\"Virtualization\",\"detail\":\"enabled in firmware\",\"action\":null";
    private const string VirtFail = "{\"id\":\"virtualization\",\"status\":\"fail\",\"title\":\"Virtualization\",\"detail\":\"virtualization is off: turn it on in the BIOS\",\"action\":null";

    [Fact]
    public void ABlockingStepWithNoButtonShowsCopyHowToFixAndReportThisProblem() => Sta.Run(() =>
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var copied = new List<string>();
        var opened = new List<string>();
        var reports = new List<(string, string?)>();
        var host = new CapturingHost(copied, opened);
        var model = new WizardModel(Setup(edit: VirtOk, to: VirtFail), host);
        model.ChooseNewBench().GetAwaiter().GetResult();
        var view = new WizardView(model, new WizardActions { ReportBug = (entry, problem) => reports.Add((entry, problem)) });
        view.Update();

        Assert.False(ButtonNamed(view, "Continue").IsEnabled);
        Click(ButtonNamed(view, "Copy the fix: Virtualization"));
        Assert.Equal(["virtualization is off: turn it on in the BIOS"], copied);
        Click(ButtonNamed(view, "How to fix: Virtualization"));
        Assert.Equal(["https://askysh.github.io/benchbar/windows/#first-run"], opened);
        Click(ButtonNamed(view, "Report this problem: Virtualization"));
        Assert.Equal([("Report This Problem", (string?)"Step virtualization (fail): virtualization is off: turn it on in the BIOS")], reports);
        AssertEveryControlIsNamed(view);
    });

    [Fact]
    public void AdviceWithACommandOffersCopyAndStillLetsYouContinue() => Sta.Run(() =>
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var copied = new List<string>();
        var model = new WizardModel(Setup(), new CapturingHost(copied, []));
        model.ChooseNewBench().GetAwaiter().GetResult();
        var view = new WizardView(model, new WizardActions());
        view.Update();
        Assert.True(ButtonNamed(view, "Continue").IsEnabled);
        Click(ButtonNamed(view, "Copy the fix: benchbar.exe on PATH"));
        Assert.Equal(["benchbar.exe path install"], copied);
    });

    private sealed class CapturingHost(List<string> copied, List<string> opened) : IWizardHost
    {
        public void SetResumeAfterLogon(bool on) { }
        public bool RestartWindows() => true;
        public string WindowsUserName => "Akash";
        public string? ConfiguredDistro => "Ubuntu-24.04";
        public bool Notifications { get; set; } = true;
        public bool OpenAtLogon { get; set; }
        public void OpenUrl(string url) => opened.Add(url);
        public void CopyText(string text) => copied.Add(text);
    }

    // --- the main window ---

    [Fact]
    public void FindBenchesAndTeamProfilesAreOffWithAReasonWhileTheWizardIsOpen() => Sta.Run(() =>
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var window = new MainWindow(new MainActions(), Theme);
        window.SetSnapshot(new TraySnapshot([OneBench()]), "1 of 1 up");
        Assert.True(ButtonNamed(window, "Find Benches").IsEnabled);

        var model = new WizardModel(Setup(), new Host());
        window.ShowWizard(new WizardView(model, new WizardActions()));
        var find = ButtonNamed(window, "Find Benches");
        Assert.False(find.IsEnabled);
        Assert.Equal("Finish or close the setup first.", find.ToolTip);
        Assert.False(ButtonNamed(window, "Team Profiles").IsEnabled);
        window.ShowTool(SidebarTool.FindBenches); // a shortcut does nothing either
        Assert.Equal(SidebarTool.None, window.Tool);

        window.CloseWizard();
        Assert.True(ButtonNamed(window, "Find Benches").IsEnabled);
        Assert.Null(ButtonNamed(window, "Find Benches").ToolTip);
    });

    [Fact]
    public void TheProblemCardOffersSetUpBenchBarNextToCopy() => Sta.Run(() =>
    {
        var opened = 0;
        var copied = new List<string>();
        var window = new MainWindow(new MainActions { NewBench = () => opened++, CopyText = copied.Add }, Theme);
        window.SetSnapshot(new TraySnapshot([], Problem: "WSL is not installed: wsl.exe --install"), "needs attention");
        Click(ButtonNamed(window, "Set Up BenchBar"));
        Assert.Equal(1, opened);
        Click(ButtonNamed(window, "Copy"));
        Assert.Equal(["WSL is not installed: wsl.exe --install"], copied);
        AssertEveryControlIsNamed(window);
    });

    [Fact]
    public void TheWindowNamesItsPlaceAndTheSelectedBenchForABugReport() => Sta.Run(() =>
    {
        var window = new MainWindow(new MainActions(), Theme);
        Assert.Equal("Main window, no benches yet", window.ReportWhere);
        Assert.Null(window.SelectedBenchPath);
        var two = new TraySnapshot([OneBench(), Bench(BenchState.Stopped, "/home/a/other", ("two.localhost", true))]);
        window.SetSnapshot(two, "1 of 2 up");
        Assert.Equal("Main window, Overview tab", window.ReportWhere);
        Assert.Equal("/home/a/frappe-bench", window.SelectedBenchPath);
        window.Select(window.Items.Last(i => i.Kind == SidebarKind.Bench));
        Assert.Equal("/home/a/other", window.SelectedBenchPath); // the selected bench, not the first
        window.ShowHealth();
        Assert.Equal("Main window, Health tab", window.ReportWhere);
        window.ShowTool(SidebarTool.TeamProfiles);
        Assert.Equal("Main window, Team Profiles", window.ReportWhere);
        Assert.Null(window.SelectedBenchPath);
    });

    // --- the plan sheet ---

    [Fact]
    public void StopWaitingClosesTheSheetAndTheRunFinishesInTheBackground() => Sta.Run(() =>
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var runner = new ScriptedStreamRunner();
        runner.On(a => a.Contains("--dry-run")).Print(Fixture("site-add-plan.json"));
        var held = runner.On(a => a.Contains("--apply")).Print(Fixture("site-add-apply.jsonl")).Hold();
        var model = new PlanReviewModel(PlanReviewRequest.Tokened("Add", ["site", "add", "x"]), new CliClient(runner, () => "benchbar.exe"));
        var told = new List<string>();
        var sheet = new PlanReviewSheet(model, Theme, null, _ => { }, load: false, onDetachedFinish: told.Add);
        var closed = false;
        sheet.Closed += (_, _) => closed = true;
        model.LoadAsync(CancellationToken.None).GetAwaiter().GetResult();
        var run = model.ConfirmAsync();
        held.Started.Task.Wait();
        Assert.Equal(["Stop Waiting"], sheet.ButtonLabels);

        Click(ButtonNamed(sheet, "Stop Waiting"));
        Assert.True(closed);
        Assert.Equal(PlanPhase.Running, model.Phase); // the run was not cancelled by the sheet closing

        held.Release();
        run.GetAwaiter().GetResult();
        Assert.Equal(PlanPhase.Finished, model.Phase);
        Assert.Single(told);
        Assert.StartsWith("Add: done", told[0]);
    });

    [Fact]
    public void AFailedPlanOffersReportThisProblemWithTheFailureAsContext() => Sta.Run(() =>
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var failing = new PlanReviewModel(PlanReviewRequest.Tokened("Add", ["site", "add", "x"]), new CliClient(new ScriptedStreamRunner(), () => "benchbar.exe"));
        var reports = new List<(string, string?)>();
        var sheet = new PlanReviewSheet(failing, Theme, null, _ => { }, load: false, report: (entry, problem) => reports.Add((entry, problem)));
        failing.LoadAsync(CancellationToken.None).GetAwaiter().GetResult();
        Click(ButtonNamed(sheet, "Report this problem"));
        Assert.Single(reports);
        Assert.Equal("Report This Problem", reports[0].Item1);
        Assert.Contains("No scripted reply", reports[0].Item2);
        AssertEveryControlIsNamed(sheet);
    });

    // --- focus ---

    [Fact]
    public void ARebuildFindsTheControlThatHadTheFocusByItsName() => Sta.Run(() =>
    {
        var panel = new StackPanel();
        var first = Ui.Button("One", () => { }, "Turn On: WSL");
        panel.Children.Add(first);
        Assert.Same(first, Ui.FindByName(panel, "Turn On: WSL"));
        Assert.Null(Ui.FindByName(panel, "Nothing"));
        panel.Children.Clear();
        var second = Ui.Button("One", () => { }, "Turn On: WSL");
        panel.Children.Add(second);
        Assert.Same(second, Ui.FindByName(panel, "Turn On: WSL"));
        Assert.Null(Ui.FocusedName(panel)); // nothing has the keyboard focus in a test
    });

    [Fact]
    public void StatusAndProgressTextIsAPoliteLiveRegion() => Sta.Run(() =>
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var model = new WizardModel(Setup("check-fresh.json"), new Host());
        model.ChooseNewBench().GetAwaiter().GetResult();
        var view = new WizardView(model, new WizardActions());
        view.Update();
        Assert.Contains(Walk(view).OfType<TextBlock>(), t => AutomationProperties.GetLiveSetting(t) == AutomationLiveSetting.Polite);
    });
}

public class ReportFlowTests
{
    private sealed class FakeReporter : IBugReporter
    {
        public TaskCompletionSource<ReportOutcome> Gate { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public List<ReportRequest> Requests { get; } = [];
        public Exception? Throws { get; set; }

        public Task<ReportOutcome> CreateAsync(ReportRequest request, CancellationToken ct)
        {
            Requests.Add(request);
            if (Throws is not null) return Task.FromException<ReportOutcome>(Throws);
            return Gate.Task;
        }
    }

    private static ReportRequest Request() => new("Ubuntu-24.04", null, "Opened from: About.", "0.8.1", []);

    private static ReportOutcome Outcome() => new(@"C:\r\x.zip", "https://github.com/askysh/benchbar/issues/new?template=bug_report_windows.yml", false, [], null);

    [Fact]
    public async Task ARepeatClickWhileOneRunsIsIgnored()
    {
        var reporter = new FakeReporter();
        var busy = 0;
        var ready = new List<ReportOutcome>();
        var refocused = 0;
        var flow = new ReportFlow(reporter, new ReportSeams
        {
            ShowBusy = () =>
            {
                busy++;
                return new Done(() => busy--);
            },
            Refocus = () => refocused++,
            ShowReady = outcome =>
            {
                ready.Add(outcome);
                return null;
            },
        });

        var first = flow.RunAsync(Request());
        Assert.True(flow.IsRunning);
        Assert.Equal(1, busy);
        Assert.False(await flow.RunAsync(Request())); // the second click starts nothing, it brings the busy window forward
        Assert.Equal(1, refocused);
        Assert.Single(reporter.Requests);

        reporter.Gate.SetResult(Outcome());
        Assert.True(await first);
        Assert.False(flow.IsRunning);
        Assert.Equal(0, busy);
        Assert.Single(ready);
        Assert.True(await flow.RunAsync(Request())); // a new report may start once the first ended
    }

    private sealed class Done(Action done) : IDisposable
    {
        public void Dispose() => done();
    }

    [Fact]
    public async Task WhenItIsDoneOnlyTheDialogIsShownAndItOpensExplorerAndTheBrowser()
    {
        var reporter = new FakeReporter();
        reporter.Gate.SetResult(Outcome());
        var steps = new List<string>();
        var flow = new ReportFlow(reporter, new ReportSeams
        {
            ShowBusy = () =>
            {
                steps.Add("busy on");
                return new Done(() => steps.Add("busy off"));
            },
            ShowReady = outcome =>
            {
                steps.Add("ready " + outcome.ZipPath);
                return null;
            },
        });
        await flow.RunAsync(Request());
        // the flow opens nothing itself: Explorer and the browser opened first used to cover the dialog
        Assert.Equal(["busy on", "busy off", @"ready C:\r\x.zip"], steps);
    }

    [Fact]
    public async Task AClickWhileTheDialogIsOpenBringsItForwardAndStartsNoSecondReport()
    {
        var reporter = new FakeReporter();
        reporter.Gate.SetResult(Outcome());
        var open = true;
        var fronted = 0;
        var flow = new ReportFlow(reporter, new ReportSeams { ShowReady = _ => new ReadyHandle(() => open, () => fronted++) });
        Assert.True(await flow.RunAsync(Request()));
        Assert.False(flow.IsRunning); // the dialog does not block the flow
        Assert.False(await flow.RunAsync(Request()));
        Assert.Equal(1, fronted);
        Assert.Single(reporter.Requests);
        open = false; // the dialog was closed: the next click writes a new report
        Assert.True(await flow.RunAsync(Request()));
        Assert.Equal(2, reporter.Requests.Count);
        Assert.Equal(1, fronted);
    }

    [Fact]
    public async Task AReportThatCannotBeWrittenSaysSoAndShowsNoDialog()
    {
        var reporter = new FakeReporter { Throws = new IOException("The disk is full.") };
        var shown = new List<string>();
        var ready = new List<ReportOutcome>();
        var flow = new ReportFlow(reporter, new ReportSeams
        {
            ShowFailure = shown.Add,
            ShowReady = o =>
            {
                ready.Add(o);
                return null;
            },
        });
        await flow.RunAsync(Request());
        Assert.Equal(["The report could not be written: The disk is full."], shown);
        Assert.Empty(ready);
        Assert.False(flow.IsRunning);
    }

    [Fact]
    public void TheDialogTextAndTheExplorerCommandAreTheAgreedOnes()
    {
        Assert.Equal("Your report is ready. Drag the selected zip into the GitHub issue that just opened, describe what happened, and submit.", BugReportText.ReadyMessage);
        Assert.Equal("Writing the report...", BugReportText.Working);
        var info = ReportFlow.RevealInfo(@"C:\r\x.zip");
        Assert.Equal("explorer.exe", info.FileName);
        // the path is quoted after the comma, so a profile folder with a space still selects the file
        Assert.Equal("/select,\"C:\\Users\\First Last\\x.zip\"", ReportFlow.RevealInfo(@"C:\Users\First Last\x.zip").Arguments);
        Assert.Equal("/select,\"C:\\r\\x.zip\"", info.Arguments);
        Assert.Empty(info.ArgumentList);
    }

    [Fact]
    public void TheReadyDialogHasOpenIssueShowZipAndCopyPathAndOpensBothOnlyOnce() => Sta.Run(() =>
    {
        var copied = new List<string>();
        var revealed = new List<string>();
        var opened = new List<string>();
        var dialog = new ReportReadyDialog(Outcome(), PageKit.Theme, null, copied.Add, revealed.Add, opened.Add);
        Assert.Contains(BugReportText.ReadyMessage, PageKit.Texts(dialog));
        Assert.True(dialog.Topmost); // in front of the browser and Explorer until they have settled
        PageKit.Click(PageKit.ButtonNamed(dialog, "Copy the path of the report zip"));
        Assert.Equal([@"C:\r\x.zip"], copied);
        Assert.Empty(revealed); // nothing opens until the dialog is on screen
        Assert.Empty(opened);

        dialog.LaunchOnce();
        dialog.LaunchOnce();
        Assert.Equal([@"C:\r\x.zip"], revealed);
        Assert.Equal(["https://github.com/askysh/benchbar/issues/new?template=bug_report_windows.yml"], opened);

        PageKit.Click(PageKit.ButtonNamed(dialog, "Show the report zip in Explorer"));
        PageKit.Click(PageKit.ButtonNamed(dialog, "Open the GitHub issue"));
        Assert.Equal(2, revealed.Count);
        Assert.Equal(2, opened.Count);
        PageKit.AssertEveryControlIsNamed(dialog);
    });
}
