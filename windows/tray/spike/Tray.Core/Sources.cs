using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace BenchBar.Tray.Core;

/// <summary>Where the tray reads bench state from and sends actions to.</summary>
public interface IBenchSource
{
    Task<IReadOnlyList<BenchEntry>> ListAsync(CancellationToken ct);
    Task<BenchStatus> StatusAsync(BenchEntry bench, CancellationToken ct);
    Task<int> RunAsync(string[] args, CancellationToken ct);
}

/// <summary>
/// A source that can also tell how busy the benches are. The spike has no real
/// CPU source (a Windows process cannot sample processes inside WSL; the real
/// source is an open question for the CLI), so only the fixture source offers one.
/// </summary>
public interface ILoadSource
{
    double? CpuPercent { get; }
}

/// <summary>Result of one child process.</summary>
internal readonly record struct ProcessResult(int ExitCode, string Output, string Error);

internal static class ProcessRunner
{
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(30);

    public static async Task<ProcessResult> RunAsync(
        string fileName, IReadOnlyList<string> args, CancellationToken ct, TimeSpan? timeout = null)
    {
        var info = new ProcessStartInfo(fileName)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in args) info.ArgumentList.Add(a);

        using var process = new Process { StartInfo = info };
        process.Start();
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout ?? Timeout);
        var output = process.StandardOutput.ReadToEndAsync(cts.Token);
        var error = process.StandardError.ReadToEndAsync(cts.Token);
        try
        {
            await process.WaitForExitAsync(cts.Token).ConfigureAwait(false);
            return new ProcessResult(process.ExitCode, await output.ConfigureAwait(false), await error.ConfigureAwait(false));
        }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            throw;
        }
    }
}

/// <summary>
/// Runs <c>benchbar.exe</c> (the shim) when it is on PATH, else
/// <c>wsl.exe -d DISTRO -- bash -lc 'benchbar ...'</c>. A login shell is needed:
/// benchbar is on PATH only there (windows/tray/DECISIONS.md).
/// </summary>
public sealed class CliBenchSource : IBenchSource
{
    public const string DistroVariable = "BENCHBAR_TRAY_DISTRO";
    public const string DefaultDistro = "Ubuntu-24.04";

    private readonly string? _shim;
    private readonly string _distro;

    public CliBenchSource() : this(FindOnPath("benchbar.exe"), Environment.GetEnvironmentVariable(DistroVariable)) { }

    public CliBenchSource(string? shimPath, string? distro)
    {
        _shim = shimPath;
        _distro = string.IsNullOrWhiteSpace(distro) ? DefaultDistro : distro;
    }

    public async Task<IReadOnlyList<BenchEntry>> ListAsync(CancellationToken ct)
    {
        var result = await RunCliAsync(["list", "--json"], ct).ConfigureAwait(false);
        return BenchJson.ParseList(result.Output);
    }

    public async Task<BenchStatus> StatusAsync(BenchEntry bench, CancellationToken ct)
    {
        var result = await RunCliAsync(["status", "--json", "--bench-dir", bench.Path], ct).ConfigureAwait(false);
        var status = BenchJson.ParseStatus(result.Output);
        return status with
        {
            Name = string.IsNullOrEmpty(status.Name) ? bench.Name : status.Name,
            Path = string.IsNullOrEmpty(status.Path) ? bench.Path : status.Path,
            WebUrl = status.WebUrl ?? bench.WebUrl,
        };
    }

    public async Task<int> RunAsync(string[] args, CancellationToken ct) =>
        (await RunCliAsync(args, ct).ConfigureAwait(false)).ExitCode;

    private Task<ProcessResult> RunCliAsync(IReadOnlyList<string> args, CancellationToken ct)
    {
        var (file, list) = Command(args);
        return ProcessRunner.RunAsync(file, list, ct);
    }

    /// <summary>The executable and arguments that run the CLI with <paramref name="args"/>.</summary>
    internal (string File, List<string> Args) Command(IReadOnlyList<string> args)
    {
        if (_shim is not null) return (_shim, [.. args]);
        var line = "benchbar " + string.Join(' ', args.Select(PosixQuote));
        return ("wsl.exe", ["-d", _distro, "--", "bash", "-lc", line]);
    }

    /// <summary>A process start info that opens a visible console running <c>benchbar doctor</c>.</summary>
    public ProcessStartInfo DoctorStartInfo()
    {
        var info = new ProcessStartInfo { UseShellExecute = false, CreateNoWindow = false };
        if (_shim is not null)
        {
            info.FileName = "cmd.exe";
            info.ArgumentList.Add("/k");
            info.ArgumentList.Add($"\"{_shim}\" doctor");
        }
        else
        {
            info.FileName = "wsl.exe";
            foreach (var a in new[] { "-d", _distro, "--", "bash", "-lc", "benchbar doctor; echo; read -n1 -r -p 'Press any key to close'" })
                info.ArgumentList.Add(a);
        }
        return info;
    }

    internal static string PosixQuote(string value) =>
        value.Length > 0 && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.' or '/' or ':' or '=' or '@' or '+')
            ? value
            : "'" + value.Replace("'", "'\\''") + "'";

    internal static string? FindOnPath(string fileName)
    {
        var path = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrEmpty(path)) return null;
        foreach (var dir in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var candidate = Path.Combine(dir.Trim('"'), fileName);
                if (File.Exists(candidate)) return candidate;
            }
            catch (ArgumentException) { }
        }
        return null;
    }
}

/// <summary>
/// Reads a folder of recorded output: <c>list.json</c>, <c>status-NAME.json</c>
/// (or <c>status.json</c> for any bench without its own file) and an optional
/// <c>cpu-percent</c>. Every call re-reads the files, so a test can swap one.
/// </summary>
public sealed class FixtureBenchSource(string directory) : IBenchSource, ILoadSource
{
    private readonly List<string> _log = [];

    public string Directory { get; } = directory;

    /// <summary>The actions requested through <see cref="RunAsync"/>, newest last.</summary>
    public IReadOnlyList<string> Actions
    {
        get { lock (_log) return [.. _log]; }
    }

    public double? CpuPercent
    {
        get
        {
            var file = Path.Combine(Directory, "cpu-percent");
            if (!File.Exists(file)) return null;
            return double.TryParse(File.ReadAllText(file).Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : null;
        }
    }

    public async Task<IReadOnlyList<BenchEntry>> ListAsync(CancellationToken ct) =>
        BenchJson.ParseList(await File.ReadAllTextAsync(Path.Combine(Directory, "list.json"), ct).ConfigureAwait(false));

    public async Task<BenchStatus> StatusAsync(BenchEntry bench, CancellationToken ct)
    {
        var file = Path.Combine(Directory, $"status-{bench.Name}.json");
        if (!File.Exists(file)) file = Path.Combine(Directory, "status.json");
        var status = BenchJson.ParseStatus(await File.ReadAllTextAsync(file, ct).ConfigureAwait(false));
        return status with { WebUrl = status.WebUrl ?? bench.WebUrl };
    }

    public Task<int> RunAsync(string[] args, CancellationToken ct)
    {
        // up and down rewrite nothing: a scenario stays what the folder says
        lock (_log) _log.Add(string.Join(' ', args));
        return Task.FromResult(0);
    }
}

public static class BenchSourceFactory
{
    public const string FixturesVariable = "BENCHBAR_TRAY_FIXTURES";

    public static IBenchSource FromEnvironment()
    {
        var fixtures = Environment.GetEnvironmentVariable(FixturesVariable);
        return string.IsNullOrWhiteSpace(fixtures) ? new CliBenchSource() : new FixtureBenchSource(fixtures);
    }
}
