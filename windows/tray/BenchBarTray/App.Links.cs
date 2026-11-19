using System.Diagnostics;
using System.Windows;
using BenchBar.Tray.Core;
using Microsoft.Win32;

namespace BenchBar.Tray;

/// <summary>
/// <c>HKCU\Software\Classes\benchbar</c>: the per user registration of the scheme (no admin rights). install.ps1 writes the same values
/// and removes them with <c>-Uninstall</c>.
/// </summary>
internal sealed class RegistrySchemeStore : ISchemeStore
{
    private const string KeyPath = @"Software\Classes\" + LinkRouter.Scheme;

    /// <summary>The merged view (this user's key, then the machine's), which is what a link click uses.</summary>
    public string? ReadCommand()
    {
        using var key = Registry.ClassesRoot.OpenSubKey(LinkRouter.Scheme + @"\shell\open\command");
        return key?.GetValue(null) as string;
    }

    public string? ReadUserCommand()
    {
        using var key = Registry.CurrentUser.OpenSubKey(KeyPath + @"\shell\open\command");
        return key?.GetValue(null) as string;
    }

    public void Write(string command, string iconPath)
    {
        using var root = Registry.CurrentUser.CreateSubKey(KeyPath);
        root.SetValue(null, "URL:BenchBar");
        root.SetValue("URL Protocol", "");
        using (var icon = root.CreateSubKey("DefaultIcon")) icon.SetValue(null, iconPath);
        using var open = root.CreateSubKey(@"shell\open\command");
        open.SetValue(null, command);
    }

    public void Remove() => Registry.CurrentUser.DeleteSubKeyTree(KeyPath, throwOnMissingSubKey: false);
}

/// <summary>benchbar:// links in the running tray: registered at start, handed over by a second copy, routed by <see cref="LinkRouter"/>.</summary>
public partial class App
{
    private IDisposable? _linkServer;
    private readonly List<string> _pendingLinks = [];
    private bool _linksReady;

    /// <summary>The pipe of this session (<see cref="LinkPipe.NameFor"/>).</summary>
    private static string LinkPipeName => LinkPipe.NameFor(Process.GetCurrentProcess().SessionId);

    /// <summary>
    /// A second copy started with a link: hand it to the running tray and quit. True when the running tray took it. False sends the caller to
    /// the old way (ask it to open its flyout), for a running tray that has no pipe.
    /// </summary>
    private static bool PassLinkOn(string link) =>
        LinkPipe.TrySendAsync(LinkPipeName, link, TimeSpan.FromSeconds(2)).GetAwaiter().GetResult();

    /// <summary>The first copy: wait for links from second copies. Costs no timer: the pipe waits for a connection.</summary>
    private void StartLinkServer()
    {
        _linkServer = LinkPipe.Serve(LinkPipeName, link => Dispatcher.BeginInvoke(() => QueueLink(link)));
    }

    /// <summary>Registers <c>benchbar://</c> for this tray when nothing owns it (first start, or the program it pointed at is gone).</summary>
    private void RegisterLinkScheme()
    {
        // a demo run on recorded data must not take over the person's links
        if (BenchSourceFactory.FixturesActive || Environment.ProcessPath is not { } exe) return;
        try
        {
            var result = UrlSchemeRegistration.Ensure(new RegistrySchemeStore(), exe, File.Exists);
            if (UrlSchemeRegistration.LogLine(result) is { } line) _log.Info("links", line);
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or System.Security.SecurityException or IOException)
        {
            _log.Write("links", ex); // a policy that locks the registry: links do not open, everything else works
        }
    }

    /// <summary>A link before the first poll waits for it: the bench list is what decides which bench it means.</summary>
    private void QueueLink(string link)
    {
        if (_quitting) return;
        if (!_linksReady)
        {
            if (_pendingLinks.Count < 16) _pendingLinks.Add(link);
            return;
        }
        HandleLink(link);
    }

    private void LinksReady()
    {
        if (_linksReady) return;
        _linksReady = true;
        var waiting = _pendingLinks.ToList();
        _pendingLinks.Clear();
        foreach (var link in waiting) HandleLink(link);
    }

    private void SayAboutLink(string text)
    {
        _notices.Set(new Notice("link", text, Critical: false));
        OpenMain();
    }

    /// <summary>One link: <see cref="LinkRouter"/> decides, this only carries it out. Every route is a launch or a start, stop or restart.</summary>
    private void HandleLink(string link)
    {
        if (_quitting || _controller is null) return;
        var benches = _controller.Snapshot.Benches
            .Select(b => new LinkBench(b.Path, b.Name, b.Sites.Count > 0 ? b.Sites.Select(s => s.Name).ToList() : b.Site is { } one ? [one] : []))
            .ToList();
        // a link can carry a room code or a profile token: only its scheme and action, or a short hash, reach the log
        var label = LinkRouter.LogLabel(link);
        var outcome = LinkRouter.Route(link, benches, _main?.SelectedBenchPath);
        if (LinkRouter.RejectionLogLine(label, outcome) is { } line) _log.Info("links", line);
        switch (outcome)
        {
            case LinkOutcome.Ignore:
                break;
            case LinkOutcome.Window:
                OpenMain();
                break;
            case LinkOutcome.Explain explain:
                SayAboutLink(explain.Message);
                break;
            case LinkOutcome.Profile profile:
                _log.Info("links", "profile link: Team Profiles, sheet filled in, waiting for a click");
                OpenMain();
                _main?.ShowTool(SidebarTool.TeamProfiles);
                if (_main is { Tool: SidebarTool.TeamProfiles } main)
                {
                    // after this call: the sheet is modal, and the pipe and the dispatcher must not wait behind it
                    Dispatcher.BeginInvoke(() => main.Profiles.OpenFromLink(profile.Kind, profile.Address));
                }
                else
                {
                    SayAboutLink("Finish or close the setup first, then open the link again.");
                }
                break;
            case LinkOutcome.Run run:
                RunLink(run);
                break;
        }
    }

    private void RunLink(LinkOutcome.Run run)
    {
        if (_controller?.Snapshot.Benches.FirstOrDefault(b => b.Path == run.BenchPath) is not { } bench) return;
        if (LinkConfirm.NeedsAsking(run.Route, _config.ConfirmLinkActions))
        {
            var question = LinkConfirm.Ask(run.Route, bench.Name);
            if (!ConfirmDialog.Ask(question.Title, question.Detail, question.Button, Theme, VisibleMain))
            {
                _log.Info("links", $"{run.Route.ToString().ToLowerInvariant()}: not confirmed");
                return;
            }
        }
        _log.Info("links", run.Route.ToString().ToLowerInvariant());
        var up = bench.State is BenchState.Running or BenchState.Starting;
        switch (run.Route)
        {
            case LinkRoute.Up:
                if (!up) RunBenchAction(_controller!.StartStopAsync(bench));
                break;
            case LinkRoute.Down:
                if (up) RunBenchAction(_controller!.StartStopAsync(bench));
                break;
            case LinkRoute.Restart:
                RunBenchAction(_controller!.RestartAsync(bench));
                break;
            case LinkRoute.Open:
                OpenLinkSite(bench, run.Site);
                break;
            case LinkRoute.Logs:
                ShowLogs(bench);
                break;
            case LinkRoute.Window:
                SelectInMain(bench);
                break;
            case LinkRoute.Doctor:
                OpenDoctorFromLink(bench);
                break;
            case LinkRoute.Console:
            case LinkRoute.Db:
                OpenShellFromLink(bench, run.Route, run.Site);
                break;
            case LinkRoute.Editor:
                if (OpenEditor(bench) != VsCodeOutcome.Launched) SayAboutLink(VsCode.InstallMessage);
                break;
        }
    }

    /// <summary>Start, stop and restart keep their port check; a refusal is said once, as a notice, and nothing is killed.</summary>
    private void RunBenchAction(Task<ActionResult> action) => ReportActionAsync(action).Forget();

    private async Task ReportActionAsync(Task<ActionResult> action)
    {
        var result = await action.ConfigureAwait(false);
        if (result.ExitCode != 0 && result.Message is { Length: > 0 } message) _ = Dispatcher.BeginInvoke(() => SayAboutLink(message));
    }

    private void OpenLinkSite(BenchStatus bench, string? site)
    {
        if (site is null)
        {
            _controller!.OpenSite(bench);
            return;
        }
        var row = SiteRows.From(bench).FirstOrDefault(r => string.Equals(r.Name, site, StringComparison.OrdinalIgnoreCase));
        if (row is { CanOpen: true, Url: { } url }) OpenUrl(url);
        else SayAboutLink(row is { NeedsSetUp: true }
            ? $"{site} is not a *.localhost name, so Windows cannot reach it yet. Open the Sites tab and choose Set Up."
            : $"{bench.Name} is not running, so {site} cannot open.");
    }

    private void SelectInMain(BenchStatus bench)
    {
        OpenMain();
        if (_main is null) return;
        var item = _main.Items.FirstOrDefault(i => i.Kind == SidebarKind.Bench && i.BenchPath == bench.Path);
        if (item is not null) _main.Select(item);
    }

    private void OpenDoctorFromLink(BenchStatus bench)
    {
        var already = _main?.SelectedBenchPath == bench.Path;
        SelectInMain(bench);
        if (_main is null) return;
        _main.ShowHealth();
        // a bench that was already selected keeps its Health view, so doctor runs again; a new one runs it when it is bound
        if (already) _main.Page.Health?.RunDoctorAsync().Forget();
    }

    private void OpenShellFromLink(BenchStatus bench, LinkRoute route, string? site)
    {
        var distro = DistroName.Resolve(_config.Distro) ?? _controller?.Snapshot.Distro;
        if (distro is null)
        {
            SayAboutLink(WslCommands.NoDistroMessage);
            return;
        }
        if (site is not null && !SiteNames.IsValid(site))
        {
            SayAboutLink($"{site} is not a name the terminal can take.");
            return;
        }
        var command = route == LinkRoute.Console ? WslCommands.Console(site) : WslCommands.Database(site);
        if (TerminalLauncher.Open(new TerminalLaunch(distro, bench.Path, command)) is { } problem) SayAboutLink(problem);
    }
}
