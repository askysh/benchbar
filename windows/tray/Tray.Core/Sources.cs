using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace BenchBar.Tray.Core;

/// <summary>Where the tray reads bench state from and sends actions to.</summary>
public interface IBenchSource
{
    Task<IReadOnlyList<BenchEntry>> ListAsync(CancellationToken ct);
    Task<BenchStatus> StatusAsync(BenchEntry bench, CancellationToken ct);

    /// <summary>Runs an action (<c>up</c>, <c>down</c>, <c>restart</c> with <c>--bench-dir</c>) and returns its exit code and, on failure, the first useful line it printed.</summary>
    Task<ActionResult> RunAsync(string[] args, CancellationToken ct);

    /// <summary><c>doctor --json --bench-dir PATH</c>. Read only.</summary>
    Task<DoctorReport> DoctorAsync(string benchPath, CancellationToken ct);

    /// <summary><c>logs --json -nN --bench-dir PATH</c>. Read only.</summary>
    Task<LogTail> LogsAsync(string benchPath, CancellationToken ct, int lines = 300);

    /// <summary><c>report --json</c>: writes the redacted zip and returns its path, a Linux path inside the distro.</summary>
    Task<string> ReportAsync(string? benchPath, CancellationToken ct);

    /// <summary>Starts <c>keepalive run</c> detached and hidden, which boots the distro and keeps it up. False when it could not start.</summary>
    bool StartDistro();
}

/// <summary>
/// A source that can also tell how busy the benches are. There is no real
/// CPU source yet (the CLI has no such field and a Windows process cannot sample
/// processes inside WSL), so only the fixture source offers one and the real one has speed 1.
/// </summary>
public interface ILoadSource
{
    double? CpuPercent { get; }
}

/// <summary>The outcome of an action: <see cref="Message"/> is the first useful stderr line when it failed, else null.</summary>
public readonly record struct ActionResult(int ExitCode, string? Message)
{
    public bool Ok => ExitCode == 0;

    public static ActionResult Success { get; } = new(0, null);

    public static ActionResult Failure(string message) => new(1, message);
}

/// <summary>Result of one child process.</summary>
public readonly record struct ProcessResult(int ExitCode, string Output, string Error);

/// <summary>Runs child processes. A seam so tests do not start any.</summary>
public interface IProcessRunner
{
    /// <summary>Runs to the end (or <paramref name="timeout"/>, which cancels and kills the tree). Output is decoded as <paramref name="outputEncoding"/> (UTF-8 by default).</summary>
    Task<ProcessResult> RunAsync(
        string fileName, IReadOnlyList<string> args, CancellationToken ct, TimeSpan? timeout = null, Encoding? outputEncoding = null);

    /// <summary>Starts a process with no window and does not wait for it; it is not killed when this process exits.</summary>
    void StartDetached(string fileName, IReadOnlyList<string> args);
}

public sealed class SystemProcessRunner : IProcessRunner
{
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(30);

    public async Task<ProcessResult> RunAsync(
        string fileName, IReadOnlyList<string> args, CancellationToken ct, TimeSpan? timeout = null, Encoding? outputEncoding = null)
    {
        var info = new ProcessStartInfo(fileName)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = outputEncoding ?? Encoding.UTF8,
            StandardErrorEncoding = outputEncoding ?? Encoding.UTF8,
        };
        foreach (var a in args) info.ArgumentList.Add(a);

        using var process = new Process { StartInfo = info };
        process.Start();
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout ?? DefaultTimeout);
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

    public void StartDetached(string fileName, IReadOnlyList<string> args)
    {
        var info = new ProcessStartInfo(fileName) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var a in args) info.ArgumentList.Add(a);
        Process.Start(info)?.Dispose(); // disposing the handle does not end the process
    }
}

/// <summary>
/// A failure the user can fix, with the one line that says how. The poller shows <see cref="Exception.Message"/> as it is.
/// </summary>
public abstract class SourceProblemException(string message) : Exception(message);

/// <summary>The tray cannot find or start <c>benchbar.exe</c>.</summary>
public sealed class SetupProblemException(string message) : SourceProblemException(message);

/// <summary>The shim ran and failed with nothing on stdout; the message is the first line of its stderr (it prints a one line fix).</summary>
public sealed class CliProblemException(string message) : SourceProblemException(message);

/// <summary>Finds <c>benchbar.exe</c>: next to the running exe first, then on PATH.</summary>
public static class ShimLocator
{
    public const string FileName = "benchbar.exe";

    public static string? Find(string? baseDirectory = null, string? pathVariable = null, Func<string, bool>? exists = null)
    {
        exists ??= File.Exists;
        baseDirectory ??= AppContext.BaseDirectory;
        pathVariable ??= Environment.GetEnvironmentVariable("PATH");

        var candidates = new List<string> { baseDirectory };
        if (!string.IsNullOrEmpty(pathVariable))
            candidates.AddRange(pathVariable.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries));
        foreach (var dir in candidates)
        {
            try
            {
                var candidate = Path.Combine(dir.Trim().Trim('"'), FileName);
                if (exists(candidate)) return candidate;
            }
            catch (ArgumentException) { /* a bad PATH entry */ }
        }
        return null;
    }
}

/// <summary>
/// Runs <c>benchbar.exe</c> (the shim) and nothing else: no <c>wsl.exe bash</c> fallback. A missing shim is a
/// <see cref="SetupProblemException"/>; a non zero exit with nothing on stdout is a <see cref="CliProblemException"/>.
/// </summary>
public sealed class ShimBenchSource : IBenchSource
{
    public const string NotFoundMessage =
        "benchbar.exe was not found. Put it next to BenchBarTray.exe or on PATH (benchbar.exe path install).";

    /// <summary>up, down and restart wait for the bench: 3 minutes.</summary>
    public static readonly TimeSpan ActionTimeout = TimeSpan.FromSeconds(180);

    /// <summary>doctor and report run many checks: 2 minutes.</summary>
    public static readonly TimeSpan SlowReadTimeout = TimeSpan.FromSeconds(120);

    /// <summary>list, status and logs: 30 seconds.</summary>
    public static readonly TimeSpan ReadTimeout = TimeSpan.FromSeconds(30);

    /// <summary>The time a command may take: by its first argument.</summary>
    public static TimeSpan TimeoutFor(IReadOnlyList<string> args) => args.Count > 0 ? args[0] switch
    {
        "up" or "down" or "restart" => ActionTimeout,
        "report" or "doctor" => SlowReadTimeout,
        _ => ReadTimeout,
    } : ReadTimeout;

    private static string Words(TimeSpan t) =>
        t.TotalSeconds >= 120 ? $"{(int)t.TotalMinutes} minutes" : t.TotalSeconds >= 60 ? "1 minute" : $"{(int)t.TotalSeconds} seconds";

    private readonly IProcessRunner _runner;
    private readonly Func<string?> _locate;

    public ShimBenchSource() : this(new SystemProcessRunner(), () => ShimLocator.Find()) { }

    public ShimBenchSource(IProcessRunner runner, Func<string?> locate)
    {
        _runner = runner;
        _locate = locate;
    }

    /// <summary>The shim's path, or null when there is none (looked up on each call, so a shim put in place later is found).</summary>
    public string? ShimPath => _locate();

    public async Task<IReadOnlyList<BenchEntry>> ListAsync(CancellationToken ct) =>
        BenchJson.ParseList((await RunCliAsync(["list", "--json"], ct).ConfigureAwait(false)).Output);

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

    public async Task<ActionResult> RunAsync(string[] args, CancellationToken ct)
    {
        var shim = _locate() ?? throw new SetupProblemException(NotFoundMessage);
        try
        {
            var result = await _runner.RunAsync(shim, args, ct, TimeoutFor(args)).ConfigureAwait(false);
            if (result.ExitCode == 0) return ActionResult.Success;
            var line = FirstLine(result.Error) ?? FirstLine(result.Output) ?? $"benchbar.exe exited with code {result.ExitCode}.";
            return new ActionResult(result.ExitCode, line);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            // the runner's own timeout, not a caller cancel: never "A task was canceled."
            var verb = args.Length > 0 ? args[0] : "command";
            var state = verb == "down" ? "stopping" : "starting";
            return ActionResult.Failure($"benchbar.exe {verb} did not finish in {Words(TimeoutFor(args))}; the bench may still be {state}. Run benchbar.exe status.");
        }
        catch (Win32Exception ex)
        {
            throw new CliProblemException($"benchbar.exe could not be started: {ex.Message}");
        }
    }

    public async Task<DoctorReport> DoctorAsync(string benchPath, CancellationToken ct) =>
        BenchJson.ParseDoctor((await RunCliAsync(["doctor", "--json", "--bench-dir", benchPath], ct).ConfigureAwait(false)).Output);

    public async Task<LogTail> LogsAsync(string benchPath, CancellationToken ct, int lines = 300) =>
        BenchJson.ParseLogs((await RunCliAsync(
            ["logs", "--json", "-n" + lines.ToString(CultureInfo.InvariantCulture), "--bench-dir", benchPath], ct).ConfigureAwait(false)).Output);

    public async Task<string> ReportAsync(string? benchPath, CancellationToken ct)
    {
        List<string> args = ["report", "--json"];
        if (!string.IsNullOrEmpty(benchPath)) args.AddRange(["--bench-dir", benchPath]);
        return BenchJson.ParseReport((await RunCliAsync(args, ct).ConfigureAwait(false)).Output);
    }

    public bool StartDistro()
    {
        var shim = _locate();
        if (shim is null) return false;
        try
        {
            _runner.StartDetached(shim, ["keepalive", "run"]);
            return true;
        }
        catch (Win32Exception)
        {
            return false;
        }
    }

    private async Task<ProcessResult> RunCliAsync(IReadOnlyList<string> args, CancellationToken ct)
    {
        var shim = _locate() ?? throw new SetupProblemException(NotFoundMessage);
        ProcessResult result;
        try
        {
            result = await _runner.RunAsync(shim, args, ct, TimeoutFor(args)).ConfigureAwait(false);
        }
        catch (Win32Exception ex)
        {
            throw new CliProblemException($"benchbar.exe could not be started: {ex.Message}");
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new CliProblemException($"benchbar.exe {(args.Count > 0 ? args[0] : "command")} did not answer in {Words(TimeoutFor(args))}.");
        }

        if (result.ExitCode != 0 && string.IsNullOrWhiteSpace(result.Output))
            throw new CliProblemException(FirstLine(result.Error) ?? $"benchbar.exe exited with code {result.ExitCode}.");
        return result;
    }

    internal static string? FirstLine(string text)
    {
        foreach (var line in text.Split('\n'))
        {
            var trimmed = line.Trim();
            if (trimmed.Length > 0) return trimmed;
        }
        return null;
    }
}

/// <summary>
/// Reads a folder of recorded output: <c>list.json</c>, <c>status-NAME.json</c>
/// (or <c>status.json</c> for any bench without its own file), and optional
/// <c>doctor.json</c>, <c>logs.json</c> and <c>cpu-percent</c>. Every call re-reads the files, so a test can swap one.
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

    public Task<ActionResult> RunAsync(string[] args, CancellationToken ct)
    {
        // up and down rewrite nothing: a scenario stays what the folder says
        lock (_log) _log.Add(string.Join(' ', args));
        return Task.FromResult(ActionResult.Success);
    }

    public async Task<DoctorReport> DoctorAsync(string benchPath, CancellationToken ct)
    {
        var file = Path.Combine(Directory, "doctor.json");
        return File.Exists(file)
            ? BenchJson.ParseDoctor(await File.ReadAllTextAsync(file, ct).ConfigureAwait(false))
            : new DoctorReport(benchPath, null, [], 0, 0, 0);
    }

    public async Task<LogTail> LogsAsync(string benchPath, CancellationToken ct, int lines = 300)
    {
        var file = Path.Combine(Directory, "logs.json");
        return File.Exists(file)
            ? BenchJson.ParseLogs(await File.ReadAllTextAsync(file, ct).ConfigureAwait(false))
            : new LogTail(null, []);
    }

    public Task<string> ReportAsync(string? benchPath, CancellationToken ct)
    {
        lock (_log) _log.Add("report");
        return Task.FromResult("/tmp/benchbar-report-fixture.zip");
    }

    public bool StartDistro()
    {
        lock (_log) _log.Add("keepalive run");
        return true;
    }
}

public static class BenchSourceFactory
{
    public const string FixturesVariable = "BENCHBAR_TRAY_FIXTURES";

    private static string? Fixtures => Environment.GetEnvironmentVariable(FixturesVariable) is { } f && !string.IsNullOrWhiteSpace(f) ? f : null;

    public static IBenchSource FromEnvironment() =>
        Fixtures is { } fixtures ? new FixtureBenchSource(fixtures) : new ShimBenchSource();

    /// <summary>The distro probe for the real source; null with fixtures, which have no distro.</summary>
    public static IDistroProbe? DistroProbeFromEnvironment() => Fixtures is null ? new WslDistroProbe() : null;
}
