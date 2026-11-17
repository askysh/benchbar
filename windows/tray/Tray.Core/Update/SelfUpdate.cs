using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace BenchBar.Tray.Core;

/// <summary>How this copy of BenchBar was installed, as <c>benchbar.exe self-update --check --json</c> says it.</summary>
public enum InstallKind
{
    /// <summary>The one line installer (<c>install.ps1</c>): Update Now can run it.</summary>
    Installer,

    /// <summary>A packaged (Microsoft Store) copy: the Store updates it.</summary>
    Store,

    /// <summary>A development build or a loose copy: only the update line is offered.</summary>
    Other,
}

/// <summary>The links and lines every update surface shares.</summary>
public static class UpdateLinks
{
    /// <summary>The one line installer from the documentation (docs/windows.md); the same line as <see cref="ShimStart.ReinstallLine"/>.</summary>
    public const string InstallCommand = ShimStart.ReinstallLine;

    /// <summary>What to tell the person to do with <see cref="InstallCommand"/>.</summary>
    public const string InstallExplanation = "Run this line in PowerShell. It closes BenchBar and starts it again.";

    /// <summary>What Update Now does, said before the click.</summary>
    public const string UpdateNowExplanation = "Update Now closes BenchBar, installs the new version and starts it again. A window shows the progress.";

    /// <summary>What is going on while the update window runs.</summary>
    public const string UpdatingExplanation = "The update runs in its own window. BenchBar closes and starts again when it is done.";

    /// <summary>The answer of Check for Updates for a packaged copy.</summary>
    public const string StoreLine = "This copy of BenchBar is updated by the Microsoft Store.";

    /// <summary>The release page of a version, the same page the update banner's Release Page opens.</summary>
    public static string ReleasePage(string version) => "https://github.com/askysh/benchbar/releases/tag/v" + version.TrimStart('v');
}

/// <summary>
/// What <c>benchbar.exe self-update --check --json</c> printed: <c>current</c>, <c>latest</c>, <c>update_available</c>, <c>install</c>
/// <c>error</c> and the optional <c>release_url</c>. Unknown fields (the CLI's own part, notes) are ignored. The shim offers a release only
/// when it has the Windows zip for this PC's CPU and its checksums file, as install.ps1 picks it.
/// </summary>
public sealed record SelfUpdateStatus(string Current, string? Latest, bool UpdateAvailable, InstallKind Install, string? Error, string? ReleaseUrl = null)
{
    /// <summary>
    /// The document in the output, or null when there is none or it is not the shim's answer: without <c>install</c> and <c>current</c> it
    /// came from somewhere else (an older shim forwards an unknown command to the Linux CLI, whose answer has no <c>install</c>).
    /// </summary>
    public static SelfUpdateStatus? Parse(string output)
    {
        var lines = output.Replace("\r", "").Split('\n');
        if (CliJson.PickDocument(lines) is not { } o) return null;
        var current = JsonRead.Str(o, "current");
        var install = JsonRead.Str(o, "install");
        if (string.IsNullOrWhiteSpace(current) || string.IsNullOrWhiteSpace(install)) return null;
        var kind = install.Trim().ToLowerInvariant() switch
        {
            "installer" => InstallKind.Installer,
            "store" => InstallKind.Store,
            _ => InstallKind.Other, // a kind this tray does not know is offered the copy line only, never a run
        };
        var latest = JsonRead.Str(o, "latest");
        var error = JsonRead.Str(o, "error");
        var url = JsonRead.Str(o, "release_url");
        return new SelfUpdateStatus(current.Trim(), string.IsNullOrWhiteSpace(latest) ? null : latest.Trim().TrimStart('v'),
            JsonRead.Bool(o, "update_available"), kind, string.IsNullOrWhiteSpace(error) ? null : error.Trim(),
            url is not null && url.StartsWith("https://", StringComparison.Ordinal) ? url : null);
    }
}

/// <summary>A newer release the app offers: its version, its page, and whether Update Now can install it.</summary>
public sealed record UpdateOffer(string Version, string Url, bool CanUpdateNow = false)
{
    /// <summary>The line to run by hand; always offered, as the second way.</summary>
    public string Command => UpdateLinks.InstallCommand;
}

/// <summary>The update decisions, apart from any process or window.</summary>
public static class UpdatePlanner
{
    /// <summary>How often opening the BenchBar window may ask: once in six hours, as before.</summary>
    public static readonly TimeSpan CheckEvery = TimeSpan.FromHours(6);

    /// <summary>
    /// What to offer: nothing for no answer, a check error, nothing newer, a packaged copy (the Store updates it) or a version the person
    /// dismissed with Not Now; otherwise the version, with Update Now only for the one line installer's install.
    /// </summary>
    public static UpdateOffer? Offer(SelfUpdateStatus? status, string? dismissedVersion = null)
    {
        if (status is null || status.Error is not null || !status.UpdateAvailable || status.Latest is not { Length: > 0 } latest) return null;
        if (status.Install == InstallKind.Store) return null;
        if (dismissedVersion is not null && string.Equals(dismissedVersion.TrimStart('v'), latest, StringComparison.OrdinalIgnoreCase)) return null;
        return new UpdateOffer(latest, status.ReleaseUrl ?? UpdateLinks.ReleasePage(latest), CanUpdateNow: status.Install == InstallKind.Installer);
    }

    /// <summary>
    /// Whether opening the BenchBar window should check now: only with the Settings switch on, and at most once per <see cref="CheckEvery"/>.
    /// <paramref name="lastCheckedTick"/> 0 means never (or the last try failed).
    /// </summary>
    public static bool CheckDue(bool enabled, long lastCheckedTick, long nowTick) =>
        enabled && (lastCheckedTick == 0 || nowTick - lastCheckedTick >= CheckEvery.TotalMilliseconds);

    /// <summary>The line Check for Updates (the menu item and About) shows for an answer, or for a check that could not run.</summary>
    public static string CheckText(SelfUpdateCheck check)
    {
        if (check.Problem is { } problem) return "Could not check for updates: " + problem;
        var status = check.Status!;
        if (status.Error is { } error) return "Could not check for updates: " + error;
        if (status.Install == InstallKind.Store) return UpdateLinks.StoreLine;
        if (status.UpdateAvailable && status.Latest is { Length: > 0 } latest) return $"BenchBar {latest} is out.";
        return "You have the latest version.";
    }
}

/// <summary>The answer of one check: the shim's status, or the reason there is none.</summary>
public sealed record SelfUpdateCheck(SelfUpdateStatus? Status, string? Problem)
{
    public static SelfUpdateCheck Failed(string problem) => new(null, problem);
}

/// <summary>
/// Asks <c>benchbar.exe self-update --check --json</c>, the one source of truth for updates. It first asks <c>--shim-version</c>: only a shim
/// of this tray's own version knows the Windows <c>self-update</c>, and an older one would forward the command to the Linux CLI and boot the
/// distro. Never throws for a missing or failing shim; the answer says why.
/// </summary>
public sealed class SelfUpdateClient(IProcessRunner runner, Func<string?> locateShim, string trayVersion)
{
    public static readonly TimeSpan VersionTimeout = TimeSpan.FromSeconds(10);

    /// <summary>The shim asks GitHub; its own HTTP timeout is shorter.</summary>
    public static readonly TimeSpan CheckTimeout = TimeSpan.FromSeconds(45);

    public static IReadOnlyList<string> CheckArgs { get; } = ["self-update", "--check", "--json"];

    public async Task<SelfUpdateCheck> CheckAsync(CancellationToken ct)
    {
        var shim = locateShim();
        if (shim is null) return SelfUpdateCheck.Failed("benchbar.exe was not found next to BenchBar.");
        try
        {
            var version = await runner.RunAsync(shim, ["--shim-version"], ct, VersionTimeout).ConfigureAwait(false);
            var shimVersion = version.ExitCode == 0 ? VersionMismatch.Parse(ShimBenchSource.FirstLine(version.Output)) : "unknown";
            if (shimVersion != VersionMismatch.Parse(trayVersion))
                return SelfUpdateCheck.Failed("benchbar.exe is not the same version as BenchBar. Run the installer again.");

            var result = await runner.RunAsync(shim, CheckArgs, ct, CheckTimeout).ConfigureAwait(false);
            if (SelfUpdateStatus.Parse(result.Output) is { } status) return new SelfUpdateCheck(status, null);
            return SelfUpdateCheck.Failed(ShimBenchSource.FirstLine(result.Error) ?? $"benchbar.exe gave no update answer (exit code {result.ExitCode}).");
        }
        catch (Win32Exception ex)
        {
            return SelfUpdateCheck.Failed(ShimStart.Describe(ex, shim));
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            return SelfUpdateCheck.Failed("benchbar.exe did not answer in time.");
        }
    }
}

/// <summary>A process Update Now started, as far as the app needs to know it.</summary>
public interface IStartedProcess
{
    bool HasExited { get; }

    /// <summary>Raised once, on a pool thread, when the process ends.</summary>
    event Action? Exited;
}

public enum UpdateStartKind { Started, AlreadyRunning, ShimMissing, Failed }

/// <summary>The outcome of Update Now. <see cref="Message"/> says why it did not start.</summary>
public sealed record UpdateStart(UpdateStartKind Kind, string? Message = null)
{
    public bool Started => Kind == UpdateStartKind.Started;
}

/// <summary>
/// Update Now: starts <c>benchbar.exe self-update --yes</c> in a new, visible Windows PowerShell window that is not tied to the tray (the
/// installer closes the tray part way and starts it again), and keeps that window open at the end with "Press Enter to close" so the
/// result can be read. The script goes as <c>-EncodedCommand</c>, so no shell parses the profile path: spaces, quotes, <c>&amp;</c>,
/// <c>%</c> and <c>$</c> in it stay as they are. A second Update Now while the window runs starts nothing.
/// </summary>
public sealed class SelfUpdateLauncher(Func<string?> locateShim, Func<ProcessStartInfo, IStartedProcess?> start, string systemDirectory, string workingDirectory)
{
    public const string WindowTitle = "BenchBar update";

    public static IReadOnlyList<string> UpdateArgs { get; } = ["self-update", "--yes"];

    private readonly object _gate = new();
    private IStartedProcess? _running;

    /// <summary>Raised when the update window closes while this tray still runs (the update failed, or the window was closed early).</summary>
    public event Action? Ended;

    public bool IsRunning
    {
        get
        {
            lock (_gate) return _running is { HasExited: false };
        }
    }

    public UpdateStart Start()
    {
        IStartedProcess? process;
        lock (_gate)
        {
            if (_running is { HasExited: false }) return new UpdateStart(UpdateStartKind.AlreadyRunning, AlreadyRunningText);
            var shim = locateShim();
            if (shim is null) return new UpdateStart(UpdateStartKind.ShimMissing, ShimStart.NotFoundMessage);
            try
            {
                process = start(StartInfo(shim, systemDirectory, workingDirectory));
            }
            catch (Exception ex) when (ex is Win32Exception or InvalidOperationException or IOException)
            {
                return new UpdateStart(UpdateStartKind.Failed, "Windows PowerShell could not be started: " + ex.Message);
            }
            if (process is null) return new UpdateStart(UpdateStartKind.Failed, "Windows did not start the update window.");
            _running = process;
            process.Exited += () => Ended?.Invoke();
        }
        if (process.HasExited) Ended?.Invoke(); // it ended before Exited had a handler
        return new UpdateStart(UpdateStartKind.Started);
    }

    public const string AlreadyRunningText = "An update is already running in its own window.";

    /// <summary>Windows PowerShell 5.1, which every Windows 10 and 11 has: <c>%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe</c>.</summary>
    public static string PowerShellPath(string systemDirectory) =>
        systemDirectory.TrimEnd('\\') + @"\WindowsPowerShell\v1.0\powershell.exe";

    /// <summary>The arguments before the encoded script.</summary>
    public const string ArgumentPrefix = "-NoProfile -NoLogo -EncodedCommand ";

    /// <summary>
    /// A new console window through ShellExecute (a window of its own, not a hidden child), started in the profile folder rather than the
    /// install folder the installer replaces files in.
    /// </summary>
    public static ProcessStartInfo StartInfo(string shimPath, string systemDirectory, string workingDirectory) => new(PowerShellPath(systemDirectory))
    {
        UseShellExecute = true,
        WindowStyle = ProcessWindowStyle.Normal,
        WorkingDirectory = workingDirectory,
        Arguments = ArgumentPrefix + Encode(Script(shimPath)),
    };

    /// <summary>PowerShell's <c>-EncodedCommand</c>: the script as UTF-16LE in base64.</summary>
    public static string Encode(string script) => Convert.ToBase64String(Encoding.Unicode.GetBytes(script));

    /// <summary>The script the window runs. The exit code of <c>benchbar.exe</c> decides the last line.</summary>
    public static string Script(string shimPath) => string.Join("\r\n",
        "$Host.UI.RawUI.WindowTitle = '" + WindowTitle + "'",
        "Write-Host 'Updating BenchBar. BenchBar closes now and starts again when the update is done.'",
        "Write-Host ''",
        "& " + PowerShellQuote(shimPath) + " " + string.Join(' ', UpdateArgs),
        "$code = $LASTEXITCODE",
        "Write-Host ''",
        "if ($code -eq 0) { Write-Host 'The update finished.' }",
        "else { Write-Host ('The update did not finish (exit code ' + $code + '). Read the lines above. To update by hand, run this line in PowerShell:'); Write-Host '" + UpdateLinks.InstallCommand + "' }",
        "Write-Host ''",
        "$null = Read-Host 'Press Enter to close this window'",
        "exit $code");

    /// <summary>
    /// A single quoted PowerShell string. Inside one, nothing expands; a quote is written twice. PowerShell also takes the typographic
    /// single quotes (U+2018, U+2019, U+201A, U+201B) as quotes, so they are doubled too.
    /// </summary>
    public static string PowerShellQuote(string text)
    {
        var sb = new StringBuilder("'");
        foreach (var c in text)
        {
            if (c is '\'' or '‘' or '’' or '‚' or '‛') sb.Append(c);
            sb.Append(c);
        }
        return sb.Append('\'').ToString();
    }
}

/// <summary>Wraps a started <see cref="Process"/>; the handle is kept so <see cref="HasExited"/> and <see cref="Exited"/> work.</summary>
public sealed class StartedProcess : IStartedProcess
{
    private readonly Process _process;

    private StartedProcess(Process process)
    {
        _process = process;
        _process.EnableRaisingEvents = true;
        _process.Exited += (_, _) => Exited?.Invoke();
    }

    public event Action? Exited;

    public bool HasExited
    {
        get
        {
            try { return _process.HasExited; }
            catch (Exception ex) when (ex is InvalidOperationException or Win32Exception) { return true; }
        }
    }

    public static IStartedProcess? Start(ProcessStartInfo info) => Process.Start(info) is { } process ? new StartedProcess(process) : null;
}

/// <summary>What the tray does at start about the version it last recorded in its config.</summary>
public enum UpdatedNoticeKind { None, Updated }

/// <summary>The decision, and the version to record (null: leave the config as it is).</summary>
public sealed record UpdatedNoticeDecision(UpdatedNoticeKind Kind, string? Record, string? Version = null)
{
    public bool Show => Kind == UpdatedNoticeKind.Updated;
}

/// <summary>
/// "BenchBar was updated to X": once, at the first start of a newer version. A first install records the version and says nothing; so does
/// an older version (a downgrade). A development build (0.0.0) neither shows nor records. A config with a <c>tray</c> section but no
/// version is an install from before the version was recorded (0.8.3 and older): that start is an update too.
/// </summary>
public static class UpdatedNotice
{
    public static string Text(string version) => $"BenchBar was updated to {version}.";

    public const string ActionLabel = "What's New";

    public static UpdatedNoticeDecision Decide(string? recorded, string currentVersion, bool hadTraySection)
    {
        var current = VersionMismatch.Parse(currentVersion);
        if (current is null) return new UpdatedNoticeDecision(UpdatedNoticeKind.None, null);
        var earlier = VersionMismatch.Parse(recorded);
        if (earlier is null)
            return hadTraySection && string.IsNullOrWhiteSpace(recorded)
                ? new UpdatedNoticeDecision(UpdatedNoticeKind.Updated, current, current)
                : new UpdatedNoticeDecision(UpdatedNoticeKind.None, current);
        if (earlier == current) return new UpdatedNoticeDecision(UpdatedNoticeKind.None, null);
        return IsNewer(current, earlier)
            ? new UpdatedNoticeDecision(UpdatedNoticeKind.Updated, current, current)
            : new UpdatedNoticeDecision(UpdatedNoticeKind.None, current);
    }

    private static bool IsNewer(string a, string b)
    {
        var x = a.Split('.').Select(p => int.Parse(p, System.Globalization.CultureInfo.InvariantCulture)).ToArray();
        var y = b.Split('.').Select(p => int.Parse(p, System.Globalization.CultureInfo.InvariantCulture)).ToArray();
        for (var i = 0; i < 3; i++)
        {
            if (x[i] != y[i]) return x[i] > y[i];
        }
        return false;
    }
}
