using System.ComponentModel;
using System.IO.Compression;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace BenchBar.Tray.Core;

/// <summary>The words of Report a Bug, shared by the app and the tests.</summary>
public static class BugReportText
{
    public const string Working = "Writing the report...";
    public const string StillWorking = "Still writing the report. A distro that does not answer can take up to a minute.";
    public const string ReadyMessage = "Your report is ready. 1. Click Open GitHub Issue. 2. Click Show Zip in Explorer and drag the zip into the issue. 3. Say what happened and submit.";
    public const string ReadyTitle = "Report a Bug";
    public const string IssueTemplate = "bug_report_windows.yml";
    public const string IssueBase = "https://github.com/askysh/benchbar/issues/new?template=" + IssueTemplate;

    /// <summary>The longest issue URL the tray makes. GitHub and the browser take more; the shim keeps below 4000 too.</summary>
    public const int UrlLimit = 3900;

    /// <summary>Only the issue form of this repository is opened; anything else falls back to it.</summary>
    public static string SafeIssueUrl(string? url) =>
        url is { Length: > 0 } u && (u == IssueBase || u.StartsWith(IssueBase + "&", StringComparison.Ordinal)) ? u : IssueBase;
}

/// <summary>
/// The sentence that tells the maintainers where the report was made: the entry point, the window or wizard page, and the problem when
/// the button sat next to one. One line, no names or paths (the shim and the fallback redact the rest).
/// </summary>
public static class ReportContext
{
    public const int MaxLength = 700;

    /// <summary>"Opened from: Tray menu. Where: Main window, Health tab. Problem: Step wsl_feature failed: ..."</summary>
    public static string Compose(string entry, string? where = null, string? problem = null)
    {
        var sb = new StringBuilder();
        sb.Append("Opened from: ").Append(Clean(entry)).Append('.');
        if (!string.IsNullOrWhiteSpace(where)) sb.Append(" Where: ").Append(Clean(where).TrimEnd('.')).Append('.');
        if (!string.IsNullOrWhiteSpace(problem)) sb.Append(" Problem: ").Append(Clean(problem).TrimEnd('.')).Append('.');
        var text = sb.ToString();
        return text.Length <= MaxLength ? text : text[..(MaxLength - 3)] + "...";
    }

    /// <summary>The wizard's page and flow, for "Where".</summary>
    public static string Wizard(WizardPage page, WizardFlow flow, string? step = null) =>
        $"Setup wizard, page {WizardModel.PageName(page)}, {(flow == WizardFlow.ExistingBench ? "existing bench" : "new bench")}" + (string.IsNullOrEmpty(step) ? "" : ", step " + step);

    /// <summary>A failed Check row as a problem sentence.</summary>
    public static string Step(SetupStepInfo step, string? message) =>
        $"Step {step.Id} ({step.Status.ToString().ToLowerInvariant()}): {(string.IsNullOrWhiteSpace(message) ? step.Detail : message)}";

    private static string Clean(string text) => Regex.Replace(text.Trim(), @"\s+", " ");
}

/// <summary>What Report a Bug sends to the shim.</summary>
public sealed record ReportRequest(string? Distro, string? BenchPath, string Context, string TrayVersion, IReadOnlyList<string> Includes);

/// <summary>A written report. <see cref="TrayOnly"/> is true when benchbar.exe could not make it and the tray wrote its own.</summary>
public sealed record ReportOutcome(string ZipPath, string IssueUrl, bool TrayOnly, IReadOnlyList<string> Skipped, string? Note);

public interface IBugReporter
{
    Task<ReportOutcome> CreateAsync(ReportRequest request, CancellationToken ct);
}

/// <summary>
/// <c>benchbar.exe report-windows --json</c>, and a zip of the tray's own when benchbar.exe cannot start (missing, blocked by SmartScreen
/// or an antivirus) or prints nothing usable. The shim works with no WSL, a stopped distro and no CLI, so there is no refusal here.
/// </summary>
public sealed class BugReporter(IProcessRunner runner, Func<string?> locate, TrayOnlyReport fallback) : IBugReporter
{
    /// <summary>The shim's own limits add up to about 2.5 minutes; this is the tray's.</summary>
    public static readonly TimeSpan Timeout = TimeSpan.FromMinutes(3);

    public static IReadOnlyList<string> Arguments(ReportRequest request)
    {
        List<string> args = ["report-windows", "--json"];
        if (!string.IsNullOrWhiteSpace(request.Distro)) args.AddRange(["--distro", request.Distro]);
        if (!string.IsNullOrWhiteSpace(request.BenchPath)) args.AddRange(["--bench", request.BenchPath]);
        if (!string.IsNullOrWhiteSpace(request.Context)) args.AddRange(["--context", request.Context]);
        if (!string.IsNullOrWhiteSpace(request.TrayVersion)) args.AddRange(["--tray-version", request.TrayVersion]);
        foreach (var file in request.Includes) args.AddRange(["--include", file]);
        return args;
    }

    public async Task<ReportOutcome> CreateAsync(ReportRequest request, CancellationToken ct)
    {
        var shim = locate();
        if (shim is null) return fallback.Write(request, ShimBenchSource.NotFoundMessage);
        ProcessResult result;
        try
        {
            result = await runner.RunAsync(shim, Arguments(request), ct, Timeout).ConfigureAwait(false);
        }
        catch (Win32Exception)
        {
            return fallback.Write(request, ShimBenchSource.BlockedMessage);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            return fallback.Write(request, "benchbar.exe report-windows did not finish in 3 minutes.");
        }
        if (result.ExitCode == 0 && Parse(result.Output) is { } outcome) return outcome;
        var why = ShimBenchSource.FirstLine(result.Error) ?? (result.ExitCode == 0 ? "benchbar.exe report-windows printed no report." : $"benchbar.exe report-windows exited with code {result.ExitCode}.");
        return fallback.Write(request, why);
    }

    /// <summary>The one JSON line of <c>report-windows --json</c>; null when it holds no zip.</summary>
    public static ReportOutcome? Parse(string output)
    {
        foreach (var raw in output.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line[0] != '{') continue;
            JsonObject? root;
            try { root = JsonNode.Parse(line) as JsonObject; }
            catch (System.Text.Json.JsonException) { continue; }
            if (root is null) continue;
            var zip = JsonRead.Str(root, "zip");
            if (string.IsNullOrWhiteSpace(zip)) continue;
            var skipped = new List<string>();
            if (root["skipped"] is JsonArray array)
            {
                foreach (var item in array.OfType<JsonObject>())
                    skipped.Add($"{JsonRead.Str(item, "part")}: {JsonRead.Str(item, "reason")}");
            }
            var url = JsonRead.Str(root, "issue_url");
            return new ReportOutcome(zip, BugReportText.SafeIssueUrl(url), false, skipped, null);
        }
        return null;
    }
}

/// <summary>
/// The report the tray writes alone: tray and Windows versions, the context, the error text and the tray's error log. Names are
/// replaced with <c>&lt;user&gt;</c> the way the shim does it; the issue URL carries versions and a sentence, never a path.
/// </summary>
public sealed class TrayOnlyReport(string folder, Func<DateTime> now, string windowsVersion, string userName, string profileDir)
{
    public const int Keep = 10;
    private const string Prefix = "benchbar-tray-report-";

    public static string DefaultFolder { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BenchBar", "reports");

    public static TrayOnlyReport ForThisPc() => new(DefaultFolder, () => DateTime.Now,
        System.Runtime.InteropServices.RuntimeInformation.OSDescription, Environment.UserName,
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));

    public ReportOutcome Write(ReportRequest request, string error)
    {
        Directory.CreateDirectory(folder);
        var stamp = now().ToString("yyyyMMdd-HHmmss", System.Globalization.CultureInfo.InvariantCulture);
        var path = Path.Combine(folder, $"{Prefix}{stamp}.zip");
        for (var n = 2; File.Exists(path); n++) path = Path.Combine(folder, $"{Prefix}{stamp}-{n}.zip");

        var summary = new StringBuilder();
        summary.AppendLine("BenchBar tray report (benchbar.exe could not make the full report)");
        summary.AppendLine("Tray version: " + request.TrayVersion);
        summary.AppendLine("Windows: " + windowsVersion);
        summary.AppendLine("Configured distro: " + (string.IsNullOrWhiteSpace(request.Distro) ? "none" : request.Distro));
        summary.AppendLine("Context: " + request.Context);
        summary.AppendLine("Why: " + error);

        using (var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write))
        using (var zip = new ZipArchive(stream, ZipArchiveMode.Create))
        {
            AddText(zip, "summary.txt", Redact(summary.ToString()));
            foreach (var file in request.Includes)
            {
                var text = ReadTail(file);
                if (text is null) continue;
                var entry = "included/" + Path.GetFileName(file);
                AddText(zip, entry, Redact(text));
            }
        }
        Prune();
        return new ReportOutcome(path, IssueUrl(request, error), true, [], error);
    }

    /// <summary>The issue form prefilled with <c>versions</c>, <c>windows</c> and <c>what</c>, under <see cref="BugReportText.UrlLimit"/> characters.</summary>
    public string IssueUrl(ReportRequest request, string error)
    {
        var versions = $"BenchBar tray {request.TrayVersion.Split('+')[0]}, benchbar.exe not available";
        var what = $"While: {request.Context}\n\nbenchbar.exe could not make the report: {error}\n\n";
        string Build(string whatText) => BugReportText.IssueBase
            + "&title=" + Uri.EscapeDataString("Windows beta: tray report")
            + "&versions=" + Uri.EscapeDataString(ForUrl(versions))
            + "&windows=" + Uri.EscapeDataString(ForUrl(windowsVersion))
            + "&what=" + Uri.EscapeDataString(ForUrl(whatText));
        var url = Build(what);
        while (url.Length > BugReportText.UrlLimit && what.Length > 40)
        {
            what = what[..(what.Length * 3 / 4)];
            url = Build(what);
        }
        return url;
    }

    private string Redact(string text)
    {
        if (!string.IsNullOrEmpty(profileDir)) text = text.Replace(profileDir.TrimEnd('\\', '/'), @"C:\Users\<user>", StringComparison.OrdinalIgnoreCase);
        text = Regex.Replace(text, @"([A-Za-z]:[\\/]+Users[\\/]+)[^\\/\s""'<>|:*?]+", "${1}<user>", RegexOptions.IgnoreCase);
        text = Regex.Replace(text, @"(/home/)[^/\s""'<>:]+", "${1}<user>");
        text = Regex.Replace(text, @"(\\home\\)[^\\\s""'<>:]+", "${1}<user>", RegexOptions.IgnoreCase);
        text = Regex.Replace(text, @"(/mnt/[a-z]/Users/)[^/\s""'<>:]+", "${1}<user>", RegexOptions.IgnoreCase);
        if (userName.Length >= 3) text = Regex.Replace(text, @"\b" + Regex.Escape(userName) + @"\b", "<user>", RegexOptions.IgnoreCase);
        return Regex.Replace(text, @"(?i)\b([A-Za-z0-9_.-]*(?:password|passwd|secret|token|api[_-]?key)[A-Za-z0-9_.-]*)(\s*[=:]\s*)(""[^""\r\n]*""|'[^'\r\n]*'|[^\s,;]+)", "${1}${2}<redacted>");
    }

    private string ForUrl(string text) =>
        Regex.Replace(Redact(text), @"(?i)[A-Za-z]:[\\/][^\s""']*|\\\\[^\s""']+|(?<![\w.])/(?:home|mnt|tmp|var|opt|srv|root|usr|etc)/[^\s""']*", "<path>");

    private static void AddText(ZipArchive zip, string name, string text)
    {
        var entry = zip.CreateEntry(name);
        using var writer = new StreamWriter(entry.Open(), new UTF8Encoding(false));
        writer.Write(text);
    }

    /// <summary>The last megabyte of a file another process may hold open; null when it cannot be read.</summary>
    private static string? ReadTail(string file)
    {
        try
        {
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            const int max = 1 << 20;
            if (stream.Length > max) stream.Seek(-max, SeekOrigin.End);
            using var reader = new StreamReader(stream, Encoding.UTF8);
            return reader.ReadToEnd();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private void Prune()
    {
        try
        {
            var old = new DirectoryInfo(folder).GetFiles(Prefix + "*.zip").OrderByDescending(f => f.Name, StringComparer.Ordinal).Skip(Keep);
            foreach (var file in old) file.Delete();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // an old report that stays is not a failure
        }
    }
}
