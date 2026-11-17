using System.Diagnostics;
using System.Globalization;
using System.Text;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// One line per exception in <c>%LOCALAPPDATA%\BenchBar\tray.log</c>. The file is capped at 256 KB: past that it
/// is moved to <c>tray.log.1</c> (replacing the old one). Never throws.
/// </summary>
internal sealed class ErrorLog(string? path = null, long maxBytes = 256 * 1024, Func<DateTime>? utcNow = null)
{
    /// <summary>The same exception from the same place inside this window is counted, not written again (a render loop can throw 35 times a second).</summary>
    public static readonly TimeSpan RepeatWindow = TimeSpan.FromSeconds(60);

    private readonly Func<DateTime> _now = utcNow ?? (() => DateTime.UtcNow);
    private readonly Dictionary<string, (DateTime Written, int Suppressed)> _seen = [];
    private readonly string _path = path ?? System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BenchBar", "tray.log");
    private readonly object _gate = new();

    public string Path => _path;

    public void Write(string where, Exception ex)
    {
        try
        {
            var text = ex.ToString().ReplaceLineEndings(" | ");
            var now = _now();
            var key = where + "|" + ex.GetType().FullName + "|" + ex.Message;
            lock (_gate)
            {
                var suppressed = 0;
                if (_seen.TryGetValue(key, out var earlier))
                {
                    if (now - earlier.Written < RepeatWindow)
                    {
                        _seen[key] = (earlier.Written, earlier.Suppressed + 1);
                        return;
                    }
                    suppressed = earlier.Suppressed;
                }
                if (_seen.Count >= 64) _seen.Clear(); // bounded: a flood of different messages is capped by the file size
                _seen[key] = (now, 0);
                var note = suppressed > 0 ? $" (repeated {suppressed} more times since the last line)" : "";
                var line = string.Create(CultureInfo.InvariantCulture, $"{now:yyyy-MM-ddTHH:mm:ssZ} {where}: {text}{note}{Environment.NewLine}");
                var dir = System.IO.Path.GetDirectoryName(_path);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                if (File.Exists(_path) && new FileInfo(_path).Length + line.Length > maxBytes)
                    File.Move(_path, _path + ".1", overwrite: true);
                File.AppendAllText(_path, line, Encoding.UTF8);
            }
        }
        catch (Exception)
        {
            // the log must never be the thing that fails
        }
    }
}

/// <summary>The result of the VS Code button.</summary>
internal enum VsCodeOutcome { Launched, NotFound, BadPath }

/// <summary>Finding VS Code and building the command that opens a bench inside the distro.</summary>
internal static class VsCode
{
    public const string InstallMessage = "Install VS Code and its WSL extension (ms-vscode-remote.remote-wsl), then try again.";
    public const string HelpUrl = "https://code.visualstudio.com/docs/remote/wsl";

    /// <summary><c>code.cmd</c> on PATH, else the per user install; null when neither exists.</summary>
    public static string? Find(string? pathVariable = null, string? localAppData = null, Func<string, bool>? exists = null) =>
        FindEditor(EditorKind.DefaultId, pathVariable, localAppData, exists);

    /// <summary>The launcher of the chosen editor (<c>code.cmd</c>, <c>cursor.cmd</c>, <c>code-insiders.cmd</c>) on PATH, else its per user install; null when neither exists.</summary>
    public static string? FindEditor(string editorId, string? pathVariable = null, string? localAppData = null, Func<string, bool>? exists = null)
    {
        exists ??= File.Exists;
        pathVariable ??= Environment.GetEnvironmentVariable("PATH");
        localAppData ??= Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var candidates = new List<string>();
        foreach (var dir in (pathVariable ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            candidates.Add(dir.Trim().Trim('"'));
        candidates.Add(EditorKind.UserBinFolder(editorId, localAppData));
        foreach (var dir in candidates)
        {
            try
            {
                var file = Path.Combine(dir, EditorKind.CommandFile(editorId));
                if (exists(file)) return file;
            }
            catch (ArgumentException) { }
        }
        return null;
    }

    /// <summary>False for the characters cmd.exe acts on (<c>&amp; | ^ &lt; &gt; % ! ( )</c>), for quotes, and for control characters.</summary>
    private static bool IsCmdSafe(string text) =>
        text.Length > 0 && !text.Any(c => c is '&' or '|' or '^' or '<' or '>' or '%' or '!' or '(' or ')' or '"' or '\'' || char.IsControl(c));

    /// <summary>
    /// True when both values can go through <c>code.cmd</c>. It runs inside cmd.exe, and an argument list only quotes for
    /// CreateProcess: cmd still acts on the characters above even inside quotes (<c>%VAR%</c> expands, <c>^</c> and <c>"</c> break out),
    /// so such a distro name or bench path is refused rather than escaped.
    /// </summary>
    public static bool CanLaunch(string distro, string benchPath) => IsCmdSafe(distro) && IsCmdSafe(benchPath);

    /// <summary>What to tell the user for a path that cannot be launched.</summary>
    public static string BadPathMessage(string benchPath) =>
        "This bench path has characters VS Code's launcher cannot take; open it from a WSL terminal: code " + benchPath;

    /// <summary>Hidden: <c>code.cmd --remote wsl+DISTRO PATH</c>. Check <see cref="CanLaunch"/> first.</summary>
    public static ProcessStartInfo StartInfo(string codeCmd, string distro, string benchPath)
    {
        var info = new ProcessStartInfo(codeCmd)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        info.ArgumentList.Add("--remote");
        info.ArgumentList.Add("wsl+" + distro);
        info.ArgumentList.Add(benchPath);
        return info;
    }
}

/// <summary>The running tray's version. Updates themselves are checked and run through benchbar.exe (<see cref="SelfUpdateClient"/>).</summary>
internal static class UpdateCheck
{
    public static string CurrentVersion()
    {
        var info = (System.Reflection.Assembly.GetEntryAssembly() ?? typeof(UpdateCheck).Assembly)
            .GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
            .OfType<System.Reflection.AssemblyInformationalVersionAttribute>().FirstOrDefault()?.InformationalVersion;
        return string.IsNullOrWhiteSpace(info) ? "0.0.0-dev" : info;
    }

    /// <summary>The version without build metadata: <c>0.8.4</c> of <c>0.8.4+abc</c>.</summary>
    public static string ShortVersion() => CurrentVersion().Split('+')[0];
}

/// <summary>Text forms of what the windows show, so tests and Copy buttons share them.</summary>
internal static class TextFormats
{
    /// <summary>The CLI's own layout: <c>[OK] label: message</c>, and <c>   fix: command</c> under a check that has one.</summary>
    public static string Doctor(DoctorReport report)
    {
        var sb = new StringBuilder();
        foreach (var check in report.Checks) sb.AppendLine(DoctorCheckText(check));
        sb.AppendLine().Append(Summary(report));
        return sb.ToString();
    }

    public static string DoctorCheckText(DoctorCheck check)
    {
        var tag = check.Level switch { CheckLevel.Ok => "[OK]", CheckLevel.Warn => "[WARN]", CheckLevel.Fail => "[FAIL]", _ => "[?]" };
        var text = $"{tag} {check.Label}: {check.Message}";
        return check.FixCommand is { Length: > 0 } fix ? text + Environment.NewLine + "   fix: " + fix : text;
    }

    public static string Summary(DoctorReport report) => $"{report.Ok} OK, {report.Warn} WARN, {report.Fail} FAIL";

    /// <summary>FAIL first, then WARN, OK, anything else; the CLI's order inside a level.</summary>
    public static IReadOnlyList<DoctorCheck> ByLevel(DoctorReport report) =>
        report.Checks.OrderBy(c => c.Level switch { CheckLevel.Fail => 0, CheckLevel.Warn => 1, CheckLevel.Ok => 2, _ => 3 }).ToList();

    /// <summary>A path inside the distro as Windows can open it: <c>\\wsl.localhost\DISTRO\home\a\x.zip</c>.</summary>
    public static string WslToWindows(string distro, string linuxPath) => WslPaths.ToWindows(distro, linuxPath);

    /// <summary>The same, with <c>\\wsl$\</c> when only that share exists (older Windows 10 builds).</summary>
    public static string WslToWindowsExisting(string distro, string linuxPath) =>
        WslPaths.ToWindows(distro, linuxPath, WslPaths.PathExists);

    /// <summary>A file name for the bench's log copy: letters, digits, dot, dash and underscore only.</summary>
    public static string SafeFileName(string name)
    {
        var cleaned = new string(name.Select(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-' or '_' ? c : '-').ToArray()).Trim('.');
        return cleaned.Length == 0 ? "bench" : cleaned;
    }
}
