using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;
using Microsoft.Extensions.Time.Testing;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>The log viewer window: its controls, the filter and search, Clear and Copy, Open in Terminal, and Follow stopping with the window.</summary>
public class LogWindowTests
{
    private const string BenchPath = "/home/akash/frappe-bench";

    private static (LogWindow Window, ScriptedStreamRunner Runner, List<string> Copied, List<TerminalLaunch> Terminals) Make(bool distro = true, FakeTimeProvider? time = null)
    {
        var (services, runner) = ScriptedServices();
        runner.On(a => a.Contains("--previous")).Print(Fixture("logs-previous.json"));
        runner.On(a => a.Contains("--since")).Print(Fixture("logs-since.json"));
        runner.On("logs").Print(Fixture("logs-first.json"));
        var copied = new List<string>();
        var terminals = new List<TerminalLaunch>();
        services.CopyText = copied.Add;
        services.Distro = () => distro ? "Ubuntu-24.04" : null;
        services.OpenTerminal = t =>
        {
            terminals.Add(t);
            return null;
        };
        SynchronizationContext.SetSynchronizationContext(null);
        var model = new LogViewModel(services.Cli, BenchPath, "frappe-bench", time: time) { PollEvery = time is null ? TimeSpan.FromHours(1) : TimeSpan.FromSeconds(2) };
        var window = new LogWindow(services, BenchWith(BenchState.Running), Theme, model);
        return (window, runner, copied, terminals);
    }

    private static void Open(LogWindow window)
    {
        window.StartAsync().GetAwaiter().GetResult();
        window.Sync();
    }

    /// <summary>Moves the fake clock until the Follow loop has polled <paramref name="count"/> times: a timer the loop has not made yet misses an early Advance.</summary>
    private static void PollsReach(LogWindow window, FakeTimeProvider time, int count) =>
        WaitFor(() =>
        {
            time.Advance(TimeSpan.FromMinutes(5));
            return window.Model.Polls >= count;
        });

    [Fact]
    public void EveryControlOfTheWindowIsNamedAndThereAreAllTheControlsTheMacHas() => Sta.Run(() =>
    {
        var (window, _, _, _) = Make();
        Open(window);
        AssertEveryControlIsNamed(window);
        Assert.Equal(["All processes", "web", "worker", "socketio", "schedule", "redis_queue", "redis_cache"], window.ProcessPicker.Items.OfType<string>());
        var names = Walk(window).OfType<DependencyObject>().Select(System.Windows.Automation.AutomationProperties.GetName).Where(n => n.Length > 0).ToList();
        foreach (var expected in new[] { "Process filter", "Search the log", "Previous match", "Next match", "Previous log", "Follow", "Clear view", "Copy the visible lines", "Open in Terminal", "Log lines" })
            Assert.Contains(expected, names);
        Assert.True(window.FollowToggle.IsChecked);
        Assert.False(window.PreviousToggle.IsChecked);
        Assert.Equal("frappe-bench log", window.Title);
        window.Close();
    });

    [Fact]
    public void TheWindowReadsTheLogThroughLogsJsonAndShowsErrorsAsRows() => Sta.Run(() =>
    {
        var (window, runner, _, _) = Make();
        Open(window);
        Assert.Equal(6, window.Rows.Count);
        Assert.Equal(["10:00:02 worker.1  | ERROR: job failed", "Traceback (most recent call last):", "  File \"x.py\", line 1"], window.Rows.Where(r => r.IsError).Select(r => r.Text));
        Assert.Equal("6 lines from /home/akash/frappe-bench/logs/bench.log, following", window.StatusText);
        Assert.Equal(LogArgs.First(BenchPath, false), runner.Runs[0].Args);
        Assert.All(runner.Runs, r => Assert.Equal("logs", r.Args[0])); // never a file read inside WSL
        window.Close();
    });

    [Fact]
    public void TheProcessFilterAndTheSearchNarrowTheRowsAndNextAndPreviousStepThroughMatches() => Sta.Run(() =>
    {
        var (window, _, _, _) = Make();
        Open(window);
        window.ProcessPicker.SelectedIndex = 1; // web
        window.Sync();
        Assert.Equal(["10:00:01 web.1     | * Running on http://127.0.0.1:8000", "10:00:03 web.1     | GET /app 200"], window.Rows.Select(r => r.Text));
        window.ProcessPicker.SelectedIndex = 0;
        window.Sync();
        Assert.Equal(6, window.Rows.Count);

        window.SearchBox.Text = "web";
        window.Sync();
        Assert.Equal("2 matches", window.Model.SearchSummary);
        Click(window.NextMatch);
        window.Sync();
        Assert.Equal("1 of 2", window.Model.SearchSummary);
        Click(window.NextMatch);
        Assert.Equal("2 of 2", window.Model.SearchSummary);
        Click(window.PreviousMatch);
        Assert.Equal("1 of 2", window.Model.SearchSummary);
        Click(window.PreviousMatch);
        Assert.Equal("2 of 2", window.Model.SearchSummary); // wraps
        window.Sync();
        Assert.False(window.FollowToggle.IsChecked); // stepping leaves the end of the log
        window.Close();
    });

    [Fact]
    public void ClearEmptiesTheViewAndCopyTakesTheVisibleLines() => Sta.Run(() =>
    {
        var (window, runner, copied, _) = Make();
        Open(window);
        window.ProcessPicker.SelectedIndex = 1;
        Click(window.CopyButton);
        Assert.Equal(["10:00:01 web.1     | * Running on http://127.0.0.1:8000" + Environment.NewLine + "10:00:03 web.1     | GET /app 200"], copied);
        Click(window.ClearButton);
        window.Sync();
        Assert.Empty(window.Rows);
        Assert.Single(runner.Runs, r => !r.Args.Contains("--since")); // the file was not read again
        window.Close();
    });

    [Fact]
    public void ThePreviousLogToggleReadsThePreviousFile() => Sta.Run(() =>
    {
        var (window, runner, _, _) = Make();
        Open(window);
        window.PreviousToggle.IsChecked = true;
        WaitFor(() => window.Model.File?.EndsWith("bench.previous.log", StringComparison.Ordinal) == true);
        window.Sync();
        Assert.Contains(runner.Runs, r => r.Args.SequenceEqual(LogArgs.First(BenchPath, true)));
        Assert.Equal(["09:00:00 web.1     | old run"], window.Rows.Select(r => r.Text));
        Assert.False(window.Model.IsPolling); // the previous log does not change
        window.Close();
    });

    [Fact]
    public void OpenInTerminalTailsTheLogInsideTheDistro() => Sta.Run(() =>
    {
        var (window, _, _, terminals) = Make();
        Open(window);
        Click(window.TerminalButton);
        var launch = Assert.Single(terminals);
        Assert.Equal(["wsl.exe", "-d", "Ubuntu-24.04", "--cd", BenchPath, "--exec", "tail", "-f", "-n", "200", "logs/bench.log"], launch.WindowsTerminalArguments);
        window.PreviousToggle.IsChecked = true;
        WaitFor(() => window.Model.ShowPrevious);
        Click(window.TerminalButton);
        Assert.EndsWith("logs/bench.previous.log", terminals[1].Command[^1]);
        window.Close();
    });

    [Fact]
    public void WithoutADistroOpenInTerminalSaysSo() => Sta.Run(() =>
    {
        var (window, _, _, terminals) = Make(distro: false);
        Open(window);
        Click(window.TerminalButton);
        Assert.Empty(terminals);
        Assert.Equal(WslCommands.NoDistroMessage, window.StatusText);
        window.Close();
    });

    [Fact]
    public void FollowPollsOnlyWhileTheWindowIsOpenAndStopsWhenItCloses() => Sta.Run(() =>
    {
        var time = new FakeTimeProvider();
        var (window, runner, _, _) = Make(time: time);
        Assert.Equal(0, window.Model.Polls); // built, not opened: nothing polls
        Open(window);
        PollsReach(window, time, 2);
        WaitFor(() => runner.Runs.Count(r => r.Args.Contains("--since")) >= window.Model.Polls); // the second poll's call has been made
        Assert.True(window.Model.IsPolling);

        window.Close();
        Assert.False(window.Model.IsPolling);
        var polls = window.Model.Polls; // every poll runs on the fake clock, so none is under way now
        var runs = runner.Runs.Count;
        time.Advance(TimeSpan.FromHours(1));
        Assert.Equal(polls, window.Model.Polls);
        Assert.Equal(runs, runner.Runs.Count);
        Assert.Contains(runner.Runs, r => r.Args.Contains("--since") && r.Args.Contains("2026-10-30T10:00:04Z")); // each poll asks for what came after the last line shown
    });

    [Fact]
    public void TurningFollowOffStopsThePollsAndTheCheckboxShowsIt() => Sta.Run(() =>
    {
        var time = new FakeTimeProvider();
        var (window, _, _, _) = Make(time: time);
        Open(window);
        PollsReach(window, time, 1);
        window.FollowToggle.IsChecked = false;
        Assert.False(window.Model.Follow);
        Assert.False(window.Model.IsPolling);
        window.FollowToggle.IsChecked = true;
        WaitFor(() => window.Model.IsPolling);
        window.Close();
    });
}
