using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Threading;
using BenchBar.Tray.Core;
using BenchBar.Tray.TestSupport;
using Xunit;

namespace BenchBar.Tray.Tests;

/// <summary>What the Sites and Apps view tests share: a bench, services over a scripted runner, a way to wait and to find controls.</summary>
internal sealed class PageKit
{
    public const string BenchPath = "/home/akash/frappe-bench";

    public ScriptedStreamRunner Runner { get; } = new();

    public PageServices Services { get; }

    public List<TypedConfirmRequest> Typed { get; } = [];

    public List<PlanReviewRequest> Plans { get; } = [];

    public List<string> Opened { get; } = [];

    public List<TerminalLaunch> Terminals { get; } = [];

    public int Refreshes { get; private set; }

    /// <summary>What <see cref="PageServices.ConfirmTyped"/> answers; null cancels.</summary>
    public Func<TypedConfirmRequest, string?> Answer { get; set; } = r => r.Expected;

    public string? Distro { get; set; } = "Ubuntu";

    public string? TerminalError { get; set; }

    /// <summary>When set, <see cref="PageServices.ReviewPlan"/> waits for it before it runs the plan.</summary>
    public TaskCompletionSource? PlanGate { get; set; }

    public PageKit()
    {
        SynchronizationContext.SetSynchronizationContext(null);
        Services = new PageServices
        {
            Cli = new CliClient(Runner, () => "benchbar.exe"),
            ConfirmTyped = request =>
            {
                Typed.Add(request);
                return Answer(request);
            },
            OpenUrl = Opened.Add,
            RefreshNow = () => Refreshes++,
            Distro = () => Distro,
            OpenTerminal = launch =>
            {
                Terminals.Add(launch);
                return TerminalError;
            },
        };
        // the real plan model behind the sheet, without the sheet: it reads the plan, confirms and applies
        Services.ReviewPlan = async request =>
        {
            Plans.Add(request);
            if (PlanGate is { } gate) await gate.Task;
            var model = new PlanReviewModel(request, Services.Cli);
            await model.LoadAsync();
            await model.ConfirmAsync();
            return model.Outcome;
        };
    }

    public static BenchStatus Bench(BenchState state = BenchState.Running, string path = BenchPath, params (string Name, bool Default)[] sites)
    {
        if (sites.Length == 0) sites = [("one.localhost", true), ("two.localhost", false)];
        return new BenchStatus("frappe-bench", path, state, null, "http://one.localhost:8000", "one.localhost")
        {
            Sites = sites.Select(s => new SiteInfo(s.Name, s.Default)).ToList(),
        };
    }

    public static string[] Fixture(string name)
    {
        return FixtureFiles.CliLines(name);
    }

    /// <summary>Waits for a task while the dispatcher runs, so a continuation posted to the UI thread can run.</summary>
    public static void Wait(Task task)
    {
        if (!task.IsCompleted)
        {
            var frame = new DispatcherFrame();
            task.ContinueWith(_ => frame.Continue = false, TaskScheduler.Default);
            Dispatcher.PushFrame(frame);
        }
        task.GetAwaiter().GetResult();
    }

    /// <summary>Runs the pending posts of the dispatcher (a held run that was just released posts its result).</summary>
    public static void Drain() => Dispatcher.CurrentDispatcher.Invoke(() => { }, DispatcherPriority.Background);

    public static IEnumerable<DependencyObject> Walk(DependencyObject root)
    {
        yield return root;
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
        {
            foreach (var d in Walk(child)) yield return d;
        }
    }

    public static void AssertEveryControlIsNamed(DependencyObject root)
    {
        foreach (var d in Walk(root))
        {
            switch (d)
            {
                case Button { Content: string text } when text.Length > 0:
                    break;
                case Button or TextBox or PasswordBox or ComboBox or CheckBox or RadioButton or ListBox or TabControl or TabItem or Expander:
                    Assert.False(string.IsNullOrWhiteSpace(AutomationProperties.GetName(d)), $"{d.GetType().Name} has no AutomationProperties.Name");
                    break;
                case MenuItem { Header: string header }:
                    Assert.False(string.IsNullOrWhiteSpace(header));
                    break;
            }
        }
    }

    public static Button ButtonNamed(DependencyObject root, string name) =>
        Walk(root).OfType<Button>().Single(b => AutomationProperties.GetName(b) == name);

    public static Button? FindButton(DependencyObject root, string name) =>
        Walk(root).OfType<Button>().SingleOrDefault(b => AutomationProperties.GetName(b) == name);

    public static void Click(Button button)
    {
        Assert.True(button.IsEnabled, $"{AutomationProperties.GetName(button)} is disabled");
        button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    }

    /// <summary>The menu of a "more" button, as (header, enabled) pairs without the separators.</summary>
    public static IReadOnlyList<MenuItem> MenuOf(DependencyObject root, string buttonName) =>
        ButtonNamed(root, buttonName).ContextMenu!.Items.OfType<MenuItem>().ToList();

    public static void ClickMenu(DependencyObject root, string buttonName, string header)
    {
        var item = MenuOf(root, buttonName).Single(i => (string)i.Header == header);
        Assert.True(item.IsEnabled, $"{header} is disabled");
        item.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
    }

    /// <summary>All the text the controls under <paramref name="root"/> show.</summary>
    public static IReadOnlyList<string> Texts(DependencyObject root) =>
        Walk(root).OfType<TextBlock>().Select(t => t.Text).Where(t => t.Length > 0).ToList();

    public static IReadOnlyList<string> ButtonLabels(DependencyObject root) =>
        Walk(root).OfType<Button>().Select(b => AutomationProperties.GetName(b)).ToList();

    public string[][] RunsOf(params string[] prefix) =>
        Runner.Runs.Select(r => r.Args).Where(a => a.Take(prefix.Length).SequenceEqual(prefix)).ToArray();

    // --- shared by every view test ---

    public static readonly ResolvedTheme Theme = new(true, true);

    /// <summary>A person's click on a check box: it toggles, then raises Click (RaiseEvent alone does not toggle).</summary>
    public static void ClickToggle(CheckBox box)
    {
        box.IsChecked = !box.IsChecked;
        box.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
    }

    /// <summary>A bench with a stop reason (the Health and Overview tests); <see cref="Bench"/> is the one with sites.</summary>
    public static BenchStatus BenchWith(BenchState state = BenchState.Stopped, string? stopReason = null) =>
        new("frappe-bench", BenchPath, state, stopReason, "http://one.localhost:8000", "one.localhost");

    /// <summary>A services object whose client answers from the returned runner. Nothing starts a process.</summary>
    public static (PageServices Services, ScriptedStreamRunner Runner) ScriptedServices()
    {
        var runner = new ScriptedStreamRunner();
        return (new PageServices { Cli = new CliClient(runner, () => "benchbar.exe") }, runner);
    }

    /// <summary>
    /// Runs <paramref name="start"/> inside a dispatcher frame (so the awaits it begins come back to this thread), and pumps until
    /// <paramref name="done"/> is true. Fails after ten seconds.
    /// </summary>
    public static void Pump(Action start, Func<bool> done)
    {
        var frame = new DispatcherFrame();
        var started = DateTime.UtcNow;
        var timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(5) };
        var timedOut = false;
        timer.Tick += (_, _) =>
        {
            if (done()) frame.Continue = false;
            else if (DateTime.UtcNow - started > TimeSpan.FromSeconds(10))
            {
                timedOut = true;
                frame.Continue = false;
            }
        };
        Dispatcher.CurrentDispatcher.BeginInvoke(start);
        timer.Start();
        Dispatcher.PushFrame(frame);
        timer.Stop();
        Assert.False(timedOut, "the condition was not met in time");
    }

    public static void WaitFor(Func<bool> condition)
    {
        Assert.True(SpinWait.SpinUntil(condition, TimeSpan.FromSeconds(10)), "the condition was not met in time");
    }
}
