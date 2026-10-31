using BenchBar.Tray.Core;

namespace Tray.Core.Tests;

/// <summary>A scratch folder holding a copy of fixtures/setup, in the layout <see cref="FixtureSetupService"/> reads (DIR/setup).</summary>
internal sealed class SetupFixture
{
    public SetupFixture()
    {
        Root = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"));
        Setup = Path.Combine(Root, "setup");
        Directory.CreateDirectory(Setup);
        foreach (var file in Directory.GetFiles(Fixtures.Dir("setup")))
            File.Copy(file, Path.Combine(Setup, Path.GetFileName(file)));
        File.Copy(Path.Combine(Setup, "install.jsonl"), Path.Combine(Setup, "install-ok.jsonl"));
        Service = new FixtureSetupService(Root);
    }

    public string Root { get; }

    public string Setup { get; }

    public FixtureSetupService Service { get; }

    /// <summary>Makes <c>check.json</c> say what <paramref name="name"/> says (check-fresh.json, check-reboot.json, ...).</summary>
    public void Check(string name, bool ready = false)
    {
        var text = File.ReadAllText(Path.Combine(Setup, name));
        if (ready) text = text.Replace("\"ready\":false", "\"ready\":true");
        File.WriteAllText(Path.Combine(Setup, "check.json"), text);
    }

    /// <summary>The install stream replays this file next time.</summary>
    public void Install(string name) =>
        Replace(name, "install.jsonl");

    /// <summary>The next run of <paramref name="action"/> replays this file.</summary>
    public void Run(string action, string name) =>
        Replace(name, $"run-{action}.jsonl");

    private void Replace(string from, string to)
    {
        if (from != to) File.Copy(Path.Combine(Setup, from), Path.Combine(Setup, to), overwrite: true);
    }
}

internal sealed class FakeWizardHost : IWizardHost
{
    public bool ResumeFlag { get; private set; }
    public int Restarts { get; private set; }
    public bool RestartWorks { get; set; } = true;
    public string WindowsUserName { get; set; } = "Akash Mishra";
    public string? ConfiguredDistro { get; set; } = "Ubuntu-24.04";
    public bool Notifications { get; set; } = true;
    public bool OpenAtLogon { get; set; }
    public List<string> Opened { get; } = [];
    public List<string> Copied { get; } = [];

    public int ForegroundGrants { get; private set; }

    public void AllowForeground() => ForegroundGrants++;

    public void SetResumeAfterLogon(bool on) => ResumeFlag = on;

    public bool RestartWindows()
    {
        Restarts++;
        return RestartWorks;
    }

    public void OpenUrl(string url) => Opened.Add(url);

    public void CopyText(string text) => Copied.Add(text);
}

/// <summary>The fixture service, except that an install waits until it is cancelled (for the Stop button).</summary>
internal sealed class GatedSetup(FixtureSetupService inner) : ISetupService
{
    public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public Task<SetupReport> CheckAsync(string? distro, CancellationToken ct, bool probe = false) => inner.CheckAsync(distro, ct, probe);

    public Task<SetupRunResult> RunActionAsync(SetupRunRequest request, Action<SetupEvent> onEvent, CancellationToken ct) => inner.RunActionAsync(request, onEvent, ct);

    public Task<PlanResult> PlanInstallAsync(InstallRequest request, Secret admin, CancellationToken ct) => inner.PlanInstallAsync(request, admin, ct);

    public async Task<InstallRunResult> InstallAsync(InstallRequest request, InstallSecrets secrets, Action<InstallEvent> onEvent, CancellationToken ct)
    {
        onEvent(new InstallEvent.Step(new InstallStep(1, "system_deps", null, "System dependencies", InstallStepStatus.Running, null, null, null)));
        Started.TrySetResult();
        await Task.Delay(Timeout.Infinite, ct);
        return new InstallRunResult(1, null, null);
    }

    public Task<InstallRunResult> AdoptAsync(string benchPath, InstallSecrets secrets, Action<InstallEvent> onEvent, CancellationToken ct) => inner.AdoptAsync(benchPath, secrets, onEvent, ct);

    public Task<string?> HomeAsync(string? distro, CancellationToken ct) => inner.HomeAsync(distro, ct);

    public Task<IReadOnlyList<DistroInfo>> ListDistrosAsync(CancellationToken ct) => inner.ListDistrosAsync(ct);

    public Task<ActionResult> UseDistroAsync(string name, CancellationToken ct) => inner.UseDistroAsync(name, ct);

    public Task<string?> ShimVersionAsync(CancellationToken ct) => inner.ShimVersionAsync(ct);
}

/// <summary>Records what the shim service started: arguments and environment, and answers with prepared lines.</summary>
internal sealed class RecordingStream : IStreamRunner
{
    public List<(string File, string[] Args, Dictionary<string, string> Env)> Runs { get; } = [];
    public string[] Lines { get; set; } = [];
    public StreamResult Result { get; set; } = new(0, null);

    public Task<StreamResult> RunAsync(string fileName, IReadOnlyList<string> args, IReadOnlyDictionary<string, string>? environment,
        Action<string> onLine, TimeSpan timeout, CancellationToken ct)
    {
        Runs.Add((fileName, [.. args], environment is null ? [] : new Dictionary<string, string>(environment)));
        foreach (var line in Lines) onLine(line);
        return Task.FromResult(Result);
    }
}

internal sealed class CapturingProcessRunner : IProcessRunner
{
    public List<(string File, string[] Args)> Runs { get; } = [];
    public ProcessResult Next { get; set; } = new(0, "", "");

    public Task<ProcessResult> RunAsync(string fileName, IReadOnlyList<string> args, CancellationToken ct, TimeSpan? timeout = null, System.Text.Encoding? outputEncoding = null)
    {
        Runs.Add((fileName, [.. args]));
        return Task.FromResult(Next);
    }

    public void StartDetached(string fileName, IReadOnlyList<string> args) { }
}
