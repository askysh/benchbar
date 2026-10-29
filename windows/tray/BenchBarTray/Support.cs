using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// One line per exception in <c>%LOCALAPPDATA%\BenchBar\tray.log</c>. The file is capped at 256 KB: past that it
/// is moved to <c>tray.log.1</c> (replacing the old one). Never throws.
/// </summary>
internal sealed class ErrorLog(string? path = null, long maxBytes = 256 * 1024)
{
    private readonly string _path = path ?? System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BenchBar", "tray.log");
    private readonly object _gate = new();

    public string Path => _path;

    public void Write(string where, Exception ex)
    {
        try
        {
            var text = ex.ToString().ReplaceLineEndings(" | ");
            var line = string.Create(CultureInfo.InvariantCulture, $"{DateTime.UtcNow:yyyy-MM-ddTHH:mm:ssZ} {where}: {text}{Environment.NewLine}");
            lock (_gate)
            {
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
    public static string? Find(string? pathVariable = null, string? localAppData = null, Func<string, bool>? exists = null)
    {
        exists ??= File.Exists;
        pathVariable ??= Environment.GetEnvironmentVariable("PATH");
        localAppData ??= Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var candidates = new List<string>();
        foreach (var dir in (pathVariable ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            candidates.Add(dir.Trim().Trim('"'));
        candidates.Add(Path.Combine(localAppData, "Programs", "Microsoft VS Code", "bin"));
        foreach (var dir in candidates)
        {
            try
            {
                var file = Path.Combine(dir, "code.cmd");
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

/// <summary>The Check for Updates logic, apart from the HTTP call.</summary>
internal static class UpdateCheck
{
    public const string LatestUrl = "https://api.github.com/repos/askysh/benchbar/releases/latest";

    private static readonly Regex Number = new(@"^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(.*)$", RegexOptions.CultureInvariant);

    public static string CurrentVersion()
    {
        var info = (System.Reflection.Assembly.GetEntryAssembly() ?? typeof(UpdateCheck).Assembly)
            .GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
            .OfType<System.Reflection.AssemblyInformationalVersionAttribute>().FirstOrDefault()?.InformationalVersion;
        return string.IsNullOrWhiteSpace(info) ? "0.0.0-dev" : info;
    }

    /// <summary>True when <paramref name="tag"/> is a later version than <paramref name="current"/>. A pre release (-dev) is before its release.</summary>
    public static bool IsNewer(string tag, string current)
    {
        var (a, aPre) = Parse(tag);
        var (b, bPre) = Parse(current);
        if (a is null) return false;
        if (b is null) return true;
        for (var i = 0; i < 3; i++)
        {
            if (a[i] != b[i]) return a[i] > b[i];
        }
        return bPre && !aPre;
    }

    private static (int[]? Parts, bool Pre) Parse(string text)
    {
        var m = Number.Match(text.Trim());
        if (!m.Success) return (null, false);
        int P(int g) => m.Groups[g].Success ? int.Parse(m.Groups[g].Value, CultureInfo.InvariantCulture) : 0;
        var rest = m.Groups[4].Value;
        return ([P(1), P(2), P(3)], rest.StartsWith('-'));
    }

    /// <summary>The tag and the release page from the GitHub API's JSON.</summary>
    public static (string Tag, string Url)? ParseRelease(string json)
    {
        using var doc = JsonDocument.Parse(json);
        if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;
        var tag = doc.RootElement.TryGetProperty("tag_name", out var t) && t.ValueKind == JsonValueKind.String ? t.GetString() : null;
        var url = doc.RootElement.TryGetProperty("html_url", out var u) && u.ValueKind == JsonValueKind.String ? u.GetString() : null;
        return string.IsNullOrEmpty(tag) || string.IsNullOrEmpty(url) ? null : (tag, url);
    }

    /// <summary>One GET with a User-Agent. The client lives only for this call.</summary>
    public static async Task<(string Tag, string Url)?> FetchLatestAsync(CancellationToken ct)
    {
        using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("BenchBarTray/" + CurrentVersion().Split('+')[0]);
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        var json = await client.GetStringAsync(LatestUrl, ct).ConfigureAwait(false);
        return ParseRelease(json);
    }
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
    public static string WslToWindows(string distro, string linuxPath) =>
        @"\\wsl.localhost\" + distro + linuxPath.Replace('/', '\\');

    /// <summary>A file name for the bench's log copy: letters, digits, dot, dash and underscore only.</summary>
    public static string SafeFileName(string name)
    {
        var cleaned = new string(name.Select(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-' or '_' ? c : '-').ToArray()).Trim('.');
        return cleaned.Length == 0 ? "bench" : cleaned;
    }
}
