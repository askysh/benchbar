namespace BenchBar.Tray.Core;

/// <summary>
/// The state behind Team Profiles (macos Workbench.profiles): the list from <c>profile list --json</c>, creating a profile from a
/// bench, and removing one. The sharing sheets have their own runs (<see cref="ProfileImportRun"/> and the others). Raises
/// <see cref="Changed"/> on the thread that awaited (the UI thread in the app).
/// </summary>
public sealed class ProfilesModel
{
    private readonly ICliClient _cli;

    public ProfilesModel(ICliClient cli) => _cli = cli;

    public event Action? Changed;

    public IReadOnlyList<ProfileInfo> Profiles { get; private set; } = [];

    /// <summary>The benches Create from Bench can read (<c>list --json</c>).</summary>
    public IReadOnlyList<FoundBench> Benches { get; private set; } = [];

    public bool HasLoaded { get; private set; }

    public bool IsLoading { get; private set; }

    /// <summary>Why the list could not be read.</summary>
    public string? Error { get; private set; }

    /// <summary>The result of the last create or remove, in a line.</summary>
    public string? Message { get; private set; }

    /// <summary>The last create or remove failed with this.</summary>
    public string? ActionError { get; private set; }

    public bool HasTeamProfile => Profiles.Any(p => p.IsTeam);

    // --- the exact calls ---

    public static string[] ListArgs() => ["profile", "list", "--json"];

    public static string[] CreateArgs(string name, string benchPath) => ["profile", "create", name, "--from-bench", benchPath, "--yes"];

    public static string[] RemoveArgs(string name) => ["profile", "remove", name, "--yes", "--json"];

    // --- load ---

    public async Task LoadAsync(CancellationToken ct = default)
    {
        IsLoading = true;
        Raise();
        try
        {
            var result = await _cli.RunJsonAsync(ListArgs(), null, CliTimeouts.Read, ProfileListJson.Parse, ct).ConfigureAwait(true);
            if (result.Value is { } profiles)
            {
                Profiles = profiles;
                Error = null;
            }
            else
            {
                Error = result.Error ?? "The profiles could not be read.";
            }
            var benches = await _cli.RunJsonAsync(DiscoveryModel.ListArgs(), null, CliTimeouts.Read, ScanJson.ParseList, ct).ConfigureAwait(true);
            if (benches.Value is { } list) Benches = list;
            HasLoaded = true;
        }
        finally
        {
            IsLoading = false;
            Raise();
        }
    }

    // --- create, remove ---

    /// <summary>Create from Bench: <c>profile create NAME --from-bench PATH --yes</c>. The bench is only read.</summary>
    public async Task<bool> CreateAsync(string name, string benchPath, CancellationToken ct = default)
    {
        if (!ProfileName.IsValid(name) || benchPath.Length == 0) return false;
        Message = null;
        ActionError = null;
        Raise();
        var result = await _cli.RunStreamAsync(CreateArgs(name, benchPath), null, CliTimeouts.Plan, _ => { }, ct).ConfigureAwait(true);
        if (!result.Ok)
        {
            ActionError = result.Problem ?? result.TextLines.LastOrDefault() ?? $"The profile was not created (exit {result.Exit}).";
            Raise();
            return false;
        }
        Message = $"Created {name}. Set up a bench from it with benchbar install --profile {name}.";
        await LoadAsync(ct).ConfigureAwait(true);
        return true;
    }

    /// <summary>A remove is running: a second one is refused and the menu item is off.</summary>
    public bool IsRemoving { get; private set; }

    /// <summary>Remove: <c>profile remove NAME --yes --json</c>. The file or subscription is moved aside, never deleted.</summary>
    public async Task<bool> RemoveAsync(ProfileInfo profile, CancellationToken ct = default)
    {
        if (IsRemoving) return false;
        IsRemoving = true;
        Message = null;
        ActionError = null;
        Raise();
        var result = await _cli.RunJsonAsync(RemoveArgs(profile.Name), null, CliTimeouts.Plan, ProfileRemoveResult.Parse, ct).ConfigureAwait(true);
        IsRemoving = false;
        if (result.Value is not { } removed || !result.Ok)
        {
            ActionError = result.Error ?? "The profile was not removed.";
            Raise();
            return false;
        }
        Message = removed.MovedTo.Length > 0 ? $"Removed {removed.Name}. It was moved to {removed.MovedTo}." : $"Removed {removed.Name}.";
        await LoadAsync(ct).ConfigureAwait(true);
        return true;
    }

    /// <summary>The sheet after a sharing run added or changed a profile.</summary>
    public Task ReloadAsync(CancellationToken ct = default) => LoadAsync(ct);

    // --- texts ---

    public static string RemoveTitle(ProfileInfo? profile) =>
        profile is null ? "Remove profile?" : profile.Origin == ProfileOrigin.Subscribed ? "Remove the subscription?" : $"Remove {profile.Name}?";

    public string RemoveMessage(ProfileInfo profile)
    {
        if (profile.Origin == ProfileOrigin.Subscribed)
        {
            var repo = profile.Subscription is { } s ? ProfileInfo.ShortRepo(s.Repo) : "its repository";
            var siblings = ProfileListJson.SiblingsOf(Profiles, profile);
            return $"This removes the subscription to {repo} with all its profiles ({string.Join(", ", siblings)}). The folder is moved to ~/.config/benchbar/removed, not deleted. Benches set up from them are not changed.";
        }
        return "The file is moved to ~/.config/benchbar/removed, not deleted. Benches set up from it are not changed.";
    }

    private void Raise() => Changed?.Invoke();
}

