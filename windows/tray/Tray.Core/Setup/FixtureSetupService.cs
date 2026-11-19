namespace BenchBar.Tray.Core;

/// <summary>
/// Replays recorded shim output from <c>DIR/setup</c> (BENCHBAR_TRAY_FIXTURES): <c>check.json</c>, <c>run-ACTION.jsonl</c>,
/// <c>plan.jsonl</c>, <c>install.jsonl</c>, <c>adopt.jsonl</c>, <c>distros.txt</c>. Every call re-reads its file, so a test can swap one,
/// and the calls (never a password) are recorded. A missing run file ends the action with a plain success.
/// </summary>
public sealed class FixtureSetupService(string directory) : ISetupService
{
    private readonly string _dir = Path.Combine(directory, "setup");

    /// <summary>The folder the fixtures are read from (it holds <c>setup</c>, and <c>cli/profile-list.json</c> for the profile picker).</summary>
    public string Root => directory;
    private readonly List<string> _calls = [];

    public IReadOnlyList<string> Calls
    {
        get { lock (_calls) return [.. _calls]; }
    }

    private void Record(string call)
    {
        lock (_calls) _calls.Add(call);
    }

    public async Task<SetupReport> CheckAsync(string? distro, CancellationToken ct, bool probe = false)
    {
        Record(probe ? "check --probe" : "check");
        return SetupJson.ParseCheck(await File.ReadAllTextAsync(Path.Combine(_dir, "check.json"), ct).ConfigureAwait(false));
    }

    public async Task<SetupRunResult> RunActionAsync(SetupRunRequest request, Action<SetupEvent> onEvent, CancellationToken ct)
    {
        Record("run " + request.Action + (request.User is null ? "" : " --user " + request.User) + (request.Password is null ? "" : " (password)") + (request.Force ? " --force" : ""));
        var file = Path.Combine(_dir, $"run-{request.Action}.jsonl");
        SetupEvent.Done? done = null;
        if (File.Exists(file))
        {
            foreach (var line in await File.ReadAllLinesAsync(file, ct).ConfigureAwait(false))
            {
                var e = SetupJson.ParseLine(line);
                if (e is null) continue;
                if (e is SetupEvent.Done d) done = d;
                onEvent(e);
            }
        }
        done ??= new SetupEvent.Done(0, true, false, false, [], []);
        return new SetupRunResult(done.Exit, done.Changed, done.RebootRequired, done.Cancelled, done.Warnings, done.NextActions, done.Exit == 0 ? null : "The fixture action failed.", done.UserExisted, done.ErrorId);
    }

    public async Task<PlanResult> PlanInstallAsync(InstallRequest request, Secret admin, CancellationToken ct)
    {
        Record("plan " + string.Join(' ', request.Flags));
        InstallPlan? plan = null;
        InstallDone? done = null;
        foreach (var e in await ReadInstallAsync("plan.jsonl", ct).ConfigureAwait(false))
        {
            if (e is InstallEvent.Plan p) plan = p.Value;
            if (e is InstallEvent.Done d) done = d.Value;
        }
        if (done is { Exit: not 0 }) return new PlanResult(null, done.Error ?? done.Fix ?? "The plan could not be made.", done.Fix, plan?.Blockers);
        return plan is null ? new PlanResult(null, "The fixture has no plan.") : new PlanResult(plan, null);
    }

    public Task<InstallRunResult> InstallAsync(InstallRequest request, InstallSecrets secrets, Action<InstallEvent> onEvent, CancellationToken ct)
    {
        Record("install " + string.Join(' ', request.Flags) + Flags(secrets));
        return ReplayAsync("install.jsonl", onEvent, ct);
    }

    public Task<InstallRunResult> AdoptAsync(string benchPath, InstallSecrets secrets, Action<InstallEvent> onEvent, CancellationToken ct)
    {
        Record("adopt " + benchPath + Flags(secrets));
        return ReplayAsync("adopt.jsonl", onEvent, ct);
    }

    /// <summary>Which secrets a run carried, as words: a test can check that one was supplied without seeing it.</summary>
    private static string Flags(InstallSecrets s) =>
        (s.Admin is { IsEmpty: false } ? " +admin" : "") + (s.LinuxPassword is { IsEmpty: false } ? " +sudo" : "") + (s.RootPassword is { IsEmpty: false } ? " +root" : "");

    private async Task<IReadOnlyList<InstallEvent>> ReadInstallAsync(string name, CancellationToken ct)
    {
        var file = Path.Combine(_dir, name);
        var events = new List<InstallEvent>();
        if (!File.Exists(file)) return events;
        foreach (var line in await File.ReadAllLinesAsync(file, ct).ConfigureAwait(false))
        {
            if (InstallJson.ParseLine(line) is { } e) events.Add(e);
        }
        return events;
    }

    private async Task<InstallRunResult> ReplayAsync(string name, Action<InstallEvent> onEvent, CancellationToken ct)
    {
        InstallDone? done = null;
        foreach (var e in await ReadInstallAsync(name, ct).ConfigureAwait(false))
        {
            ct.ThrowIfCancellationRequested();
            if (e is InstallEvent.Done d) done = d.Value;
            onEvent(e);
        }
        return new InstallRunResult(done?.Exit ?? 0, done, null);
    }

    public Task<string?> HomeAsync(string? distro, CancellationToken ct) => Task.FromResult<string?>("/home/fixture");

    /// <summary>The profiles come from <c>cli/profile-list.json</c> of the fixtures folder (the CLI fixtures the Profiles page uses), the built in ones when it is missing.</summary>
    public async Task<ProfileListResult> ListProfilesAsync(CancellationToken ct)
    {
        Record("profile list");
        var file = Path.Combine(directory, "cli", "profile-list.json");
        if (!File.Exists(file)) return new ProfileListResult([], "The fixtures have no profile list.");
        var text = await File.ReadAllTextAsync(file, ct).ConfigureAwait(false);
        return new ProfileListResult(ProfileListJson.Parse(System.Text.Json.Nodes.JsonNode.Parse(text)!.AsObject()), null);
    }

    public async Task<PrerequisiteResult> PrerequisitesAsync(string benchDir, CancellationToken ct)
    {
        Record("prerequisites");
        var file = Path.Combine(directory, "cli", "prerequisites.json");
        if (!File.Exists(file)) return new PrerequisiteResult(null, "The fixtures have no prerequisites.");
        var text = await File.ReadAllTextAsync(file, ct).ConfigureAwait(false);
        return new PrerequisiteResult(PrerequisiteReport.Parse(System.Text.Json.Nodes.JsonNode.Parse(text)!.AsObject()), null);
    }

    /// <summary>The gate takes every profile, unless <c>setup/profile-gate-NAME.jsonl</c> holds the stream the CLI printed when it refused it.</summary>
    public async Task<ProfileGate> CheckProfileAsync(string profile, string benchDir, CancellationToken ct)
    {
        Record("gate " + profile);
        InstallPlan? plan = null;
        InstallDone? done = null;
        foreach (var e in await ReadInstallAsync($"profile-gate-{profile}.jsonl", ct).ConfigureAwait(false))
        {
            if (e is InstallEvent.Plan p) plan = p.Value;
            if (e is InstallEvent.Done d) done = d.Value;
        }
        return ProfileChoices.Read(profile, plan, done);
    }

    public Task<IReadOnlyList<DistroInfo>> ListDistrosAsync(CancellationToken ct)
    {
        var file = Path.Combine(_dir, "distros.txt");
        IReadOnlyList<DistroInfo> list = File.Exists(file) ? WslList.Parse(File.ReadAllText(file)) : [new DistroInfo("Ubuntu-24.04", true, "Running", 2)];
        return Task.FromResult(list);
    }

    public Task<ActionResult> UseDistroAsync(string name, CancellationToken ct)
    {
        Record("use-distro " + name);
        return Task.FromResult(ActionResult.Success);
    }

    public Task<string?> ShimVersionAsync(CancellationToken ct) => Task.FromResult<string?>("benchbar.exe fixture");
}
