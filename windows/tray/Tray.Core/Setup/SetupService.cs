using System.ComponentModel;
using System.Globalization;
using System.Text;

namespace BenchBar.Tray.Core;

/// <summary>One action of <c>benchbar.exe setup run</c>. The password is only for <c>distro_user</c>.</summary>
public sealed record SetupRunRequest(string Action, string? Distro, string? User = null, Secret? Password = null);

/// <summary>How a setup action ended. <see cref="Error"/> is one line for the page, from the last failed step or stderr.</summary>
public sealed record SetupRunResult(int Exit, bool Changed, bool RebootRequired, bool Cancelled,
    IReadOnlyList<string> Warnings, IReadOnlyList<string> NextActions, string? Error, bool UserExisted = false)
{
    public bool Ok => Exit == 0 && !Cancelled;
}

/// <summary>The passwords of one install or adopt run. They go in that process's environment and nowhere else.</summary>
public sealed record InstallSecrets(Secret? Admin, Secret? LinuxPassword, Secret? RootPassword = null);

/// <summary>How an install or adopt stream ended: the process's exit code, the <c>done</c> line when there was one.</summary>
public sealed record InstallRunResult(int ExitCode, InstallDone? Done, string? Error)
{
    public bool Ok => ExitCode == 0 && (Done is null || Done.Exit == 0);
}

/// <summary>The dry run: the plan to review, or why there is none.</summary>
public sealed record PlanResult(InstallPlan? Plan, string? Error, string? Fix = null);

/// <summary>One line of <c>wsl.exe --list --verbose</c>.</summary>
public sealed record DistroInfo(string Name, bool IsDefault, string State, int Version);

/// <summary>Everything the first run wizard, Settings and About ask of the shim. A seam: tests and the fixture mode fake it.</summary>
public interface ISetupService
{
    /// <summary><c>setup check --json</c>. Read only. Without <paramref name="probe"/> it never boots a stopped distro (the steps inside it come back as "not checked"); with it the distro is started to look.</summary>
    Task<SetupReport> CheckAsync(string? distro, CancellationToken ct, bool probe = false);

    /// <summary><c>setup run ACTION --jsonl</c>, each event handed over as it arrives (on any thread).</summary>
    Task<SetupRunResult> RunActionAsync(SetupRunRequest request, Action<SetupEvent> onEvent, CancellationToken ct);

    /// <summary><c>install --dry-run --json</c>.</summary>
    Task<PlanResult> PlanInstallAsync(InstallRequest request, Secret admin, CancellationToken ct);

    /// <summary><c>install --yes --json</c> with <c>BENCHBAR_SUDO=env</c>.</summary>
    Task<InstallRunResult> InstallAsync(InstallRequest request, InstallSecrets secrets, Action<InstallEvent> onEvent, CancellationToken ct);

    /// <summary><c>adopt PATH --yes --json</c> with <c>BENCHBAR_SUDO=env</c>.</summary>
    Task<InstallRunResult> AdoptAsync(string benchPath, InstallSecrets secrets, Action<InstallEvent> onEvent, CancellationToken ct);

    /// <summary>The default Linux user's home folder in the distro (<c>~/frappe-bench</c> is resolved against it); null when unknown.</summary>
    Task<string?> HomeAsync(string? distro, CancellationToken ct);

    /// <summary><c>wsl.exe --list --verbose</c>. Never boots a distro.</summary>
    Task<IReadOnlyList<DistroInfo>> ListDistrosAsync(CancellationToken ct);

    /// <summary>Makes <paramref name="name"/> the distro BenchBar uses (<c>adopt-distro NAME --yes</c>).</summary>
    Task<ActionResult> UseDistroAsync(string name, CancellationToken ct);

    /// <summary><c>benchbar.exe --shim-version</c>, or null.</summary>
    Task<string?> ShimVersionAsync(CancellationToken ct);
}

/// <summary>The names of the variables that carry a password or a mode into a run. The shim's forwarder passes exactly these into WSL.</summary>
public static class SetupEnv
{
    public const string SetupPassword = "BENCHBAR_SETUP_PASSWORD";
    public const string AdminPassword = "ADMIN_PASSWORD";
    public const string MariadbRootPassword = "MARIADB_ROOT_PASSWORD";
    public const string Sudo = "BENCHBAR_SUDO";
    public const string SudoPassword = "BENCHBAR_SUDO_PASSWORD";
    public const string NonInteractive = "BENCHBAR_NONINTERACTIVE";

    /// <summary>For an install or adopt run: sudo steps fed from the environment, nothing ever asks on a terminal.</summary>
    public static SecretEnvironment ForInstall(InstallSecrets secrets)
    {
        var env = new SecretEnvironment().Set(Sudo, "env").Set(NonInteractive, "1");
        env.Set(AdminPassword, secrets.Admin).Set(SudoPassword, secrets.LinuxPassword).Set(MariadbRootPassword, secrets.RootPassword);
        return env;
    }
}

/// <summary>The real service: <c>benchbar.exe</c> and, for the lists that must not boot a distro, <c>wsl.exe</c>.</summary>
public sealed class ShimSetupService : ISetupService
{
    public static readonly TimeSpan CheckTimeout = TimeSpan.FromSeconds(60);
    public static readonly TimeSpan ActionTimeout = TimeSpan.FromMinutes(45);
    public static readonly TimeSpan PlanTimeout = TimeSpan.FromMinutes(3);
    public static readonly TimeSpan InstallTimeout = TimeSpan.FromMinutes(90);

    private readonly IProcessRunner _runner;
    private readonly IStreamRunner _stream;
    private readonly Func<string?> _locate;

    public ShimSetupService() : this(new SystemProcessRunner(), new SystemStreamRunner(), () => ShimLocator.Find()) { }

    public ShimSetupService(IProcessRunner runner, IStreamRunner stream, Func<string?> locate)
    {
        _runner = runner;
        _stream = stream;
        _locate = locate;
    }

    private string Shim => _locate() ?? throw new SetupProblemException(ShimBenchSource.NotFoundMessage);

    public async Task<SetupReport> CheckAsync(string? distro, CancellationToken ct, bool probe = false)
    {
        List<string> args = ["setup", "check", "--json"];
        if (probe) args.Add("--probe");
        if (!string.IsNullOrWhiteSpace(distro)) args.AddRange(["--distro", distro]);
        ProcessResult result;
        try
        {
            result = await _runner.RunAsync(Shim, args, ct, CheckTimeout).ConfigureAwait(false);
        }
        catch (Win32Exception ex)
        {
            throw new CliProblemException($"benchbar.exe could not be started: {ex.Message}");
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new CliProblemException("benchbar.exe setup check did not answer in 1 minute.");
        }
        if (string.IsNullOrWhiteSpace(result.Output))
            throw new CliProblemException(ShimBenchSource.FirstLine(result.Error) ?? $"benchbar.exe setup check exited with code {result.ExitCode}. Update BenchBar.");
        return SetupJson.ParseCheck(result.Output);
    }

    public async Task<SetupRunResult> RunActionAsync(SetupRunRequest request, Action<SetupEvent> onEvent, CancellationToken ct)
    {
        List<string> args = ["setup", "run", request.Action];
        if (!string.IsNullOrWhiteSpace(request.Distro)) args.AddRange(["--distro", request.Distro]);
        if (!string.IsNullOrWhiteSpace(request.User)) args.AddRange(["--user", request.User]);
        args.Add("--jsonl");

        var env = new SecretEnvironment().Set(SetupEnv.SetupPassword, request.Password);
        var redact = new Redactor(env.Secrets);
        SetupEvent.Done? done = null;
        string? failure = null;
        void OnLine(string raw)
        {
            var line = redact.Clean(raw);
            SetupEvent? e;
            try { e = SetupJson.ParseLine(line); }
            catch (UnsupportedSchemaException ex) { failure ??= ex.Message; return; }
            switch (e)
            {
                case SetupEvent.Done d: done = d; break;
                case SetupEvent.Step { Status: "failed" or "skipped" } s when s.Message.Length > 0: failure = s.Message; break;
            }
            if (e is not null) onEvent(e);
        }

        var result = await RunStreamAsync(args, env, OnLine, ActionTimeout, ct).ConfigureAwait(false);
        if (done is { } d2)
            return new SetupRunResult(d2.Exit, d2.Changed, d2.RebootRequired, d2.Cancelled, d2.Warnings, d2.NextActions, d2.Exit == 0 ? null : failure ?? redact.Clean(result.Error ?? ""), d2.UserExisted);
        return new SetupRunResult(result.ExitCode == 0 ? 1 : result.ExitCode, false, false, false, [], [],
            failure ?? (result.Error is null ? "benchbar.exe ended without saying how it went." : redact.Clean(result.Error)));
    }

    public async Task<PlanResult> PlanInstallAsync(InstallRequest request, Secret admin, CancellationToken ct)
    {
        // The admin password is in the environment too: a CLI that checks its inputs before the dry run refuses the plan without it.
        var env = new SecretEnvironment().Set(SetupEnv.AdminPassword, admin).Set(SetupEnv.NonInteractive, "1");
        var redact = new Redactor(env.Secrets);
        InstallPlan? plan = null;
        InstallDone? done = null;
        void OnLine(string raw)
        {
            try
            {
                switch (InstallJson.ParseLine(redact.Clean(raw)))
                {
                    case InstallEvent.Plan p: plan = p.Value; break;
                    case InstallEvent.Done d: done = d.Value; break;
                }
            }
            catch (UnsupportedSchemaException) { }
        }
        var result = await RunStreamAsync(["install", "--dry-run", "--json", .. request.Flags], env, OnLine, PlanTimeout, ct).ConfigureAwait(false);
        if (done is { Exit: not 0 } failed) return new PlanResult(null, failed.Error ?? failed.Fix ?? "The plan could not be made.", failed.Fix);
        if (plan is null) return new PlanResult(null, redact.Clean(result.Error ?? "The plan could not be made."));
        return new PlanResult(plan, null);
    }

    public Task<InstallRunResult> InstallAsync(InstallRequest request, InstallSecrets secrets, Action<InstallEvent> onEvent, CancellationToken ct) =>
        StreamInstallAsync(["install", "--yes", "--json", .. request.Flags], secrets, onEvent, ct);

    public Task<InstallRunResult> AdoptAsync(string benchPath, InstallSecrets secrets, Action<InstallEvent> onEvent, CancellationToken ct) =>
        StreamInstallAsync(["adopt", benchPath, "--yes", "--json"], secrets, onEvent, ct);

    private async Task<InstallRunResult> StreamInstallAsync(IReadOnlyList<string> args, InstallSecrets secrets, Action<InstallEvent> onEvent, CancellationToken ct)
    {
        var env = SetupEnv.ForInstall(secrets);
        var redact = new Redactor(env.Secrets);
        InstallDone? done = null;
        string? issue = null;
        void OnLine(string raw)
        {
            InstallEvent? e;
            try { e = InstallJson.ParseLine(redact.Clean(raw)); }
            catch (UnsupportedSchemaException ex) { issue ??= ex.Message; return; }
            if (e is InstallEvent.Done d) done = d.Value;
            if (e is not null) onEvent(e);
        }
        var result = await RunStreamAsync(args, env, OnLine, InstallTimeout, ct).ConfigureAwait(false);
        return new InstallRunResult(result.ExitCode, done, issue ?? (result.Error is null ? null : redact.Clean(result.Error)));
    }

    private Task<StreamResult> RunStreamAsync(IReadOnlyList<string> args, SecretEnvironment env, Action<string> onLine, TimeSpan timeout, CancellationToken ct)
    {
        // The values are placed in the child's environment here, at the last moment, and the dictionary is not kept.
        try
        {
            return _stream.RunAsync(Shim, args, env.Materialize(), onLine, timeout, ct);
        }
        catch (Win32Exception ex)
        {
            throw new CliProblemException($"benchbar.exe could not be started: {ex.Message}");
        }
    }

    public async Task<string?> HomeAsync(string? distro, CancellationToken ct)
    {
        List<string> args = [];
        if (!string.IsNullOrWhiteSpace(distro)) args.AddRange(["-d", distro]);
        args.AddRange(["--exec", "printenv", "HOME"]);
        try
        {
            var result = await _runner.RunAsync("wsl.exe", args, ct, TimeSpan.FromSeconds(60)).ConfigureAwait(false);
            var line = result.ExitCode == 0 ? ShimBenchSource.FirstLine(result.Output) : null;
            return line is { Length: > 0 } && line.StartsWith('/') ? line : null;
        }
        catch (Exception ex) when (ex is Win32Exception or OperationCanceledException)
        {
            return null;
        }
    }

    public async Task<IReadOnlyList<DistroInfo>> ListDistrosAsync(CancellationToken ct)
    {
        try
        {
            var result = await _runner.RunAsync("wsl.exe", ["--list", "--verbose"], ct, TimeSpan.FromSeconds(15), Encoding.Unicode).ConfigureAwait(false);
            return WslList.Parse(result.Output);
        }
        catch (Exception ex) when (ex is Win32Exception or OperationCanceledException)
        {
            return [];
        }
    }

    public async Task<ActionResult> UseDistroAsync(string name, CancellationToken ct)
    {
        try
        {
            var result = await _runner.RunAsync(Shim, ["adopt-distro", name, "--yes"], ct, ShimBenchSource.ActionTimeout).ConfigureAwait(false);
            if (result.ExitCode == 0) return ActionResult.Success;
            return new ActionResult(result.ExitCode, ShimBenchSource.FirstLine(result.Error) ?? ShimBenchSource.FirstLine(result.Output) ?? $"benchbar.exe exited with code {result.ExitCode}.");
        }
        catch (Win32Exception ex)
        {
            return ActionResult.Failure($"benchbar.exe could not be started: {ex.Message}");
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            return ActionResult.Failure("benchbar.exe adopt-distro did not finish in 3 minutes.");
        }
    }

    public async Task<string?> ShimVersionAsync(CancellationToken ct)
    {
        try
        {
            var result = await _runner.RunAsync(Shim, ["--shim-version"], ct, TimeSpan.FromSeconds(10)).ConfigureAwait(false);
            return result.ExitCode == 0 ? ShimBenchSource.FirstLine(result.Output) : null;
        }
        catch (Exception ex) when (ex is Win32Exception or SourceProblemException or OperationCanceledException)
        {
            return null;
        }
    }
}

/// <summary>Parsing of <c>wsl.exe --list --verbose</c>: a header line, then <c>* NAME  State  Version</c> per distro.</summary>
public static class WslList
{
    public static IReadOnlyList<DistroInfo> Parse(string output)
    {
        var lines = output.Replace("\0", "").Replace("﻿", "").Replace("\r", "").Split('\n')
            .Select(l => l.TrimEnd()).Where(l => l.Trim().Length > 0).ToList();
        var result = new List<DistroInfo>();
        foreach (var line in lines.Skip(1)) // the header is localised: skip it by position
        {
            var isDefault = line.TrimStart().StartsWith('*');
            var parts = line.Replace("*", " ").Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 3) continue;
            if (!int.TryParse(parts[^1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var version)) continue;
            result.Add(new DistroInfo(parts[0], isDefault, parts[^2], version));
        }
        return result;
    }
}
