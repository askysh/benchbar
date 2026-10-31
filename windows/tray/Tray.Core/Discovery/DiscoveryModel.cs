namespace BenchBar.Tray.Core;

/// <summary>The answer of <see cref="DiscoveryModel.PrepareSetupAsync"/>: the sheet to open, or why not.</summary>
public sealed record PortSetupPrep(PlanReviewRequest? Request, string? Error);

/// <summary>
/// The state behind Find Benches (macos BenchDiscovery): scan a folder inside the distro, show what was found and in which state,
/// register the selection, and prepare the port plan and the per bench adopt for the plan review sheet. The pane only draws this.
/// Raises <see cref="Changed"/> on the thread that awaited (the UI thread in the app).
/// </summary>
public sealed class DiscoveryModel
{
    public static readonly TimeSpan ScanTimeout = TimeSpan.FromMinutes(5);

    private readonly ICliClient _cli;
    private readonly IWslHost _wsl;
    private readonly RecentFolders _recent;
    private CancellationTokenSource? _scan;
    private int _generation;
    private string? _home;
    private bool _homeLoaded;
    private IReadOnlyList<FoundBench> _known = [];
    private readonly HashSet<string> _selected = new(StringComparer.Ordinal);

    public DiscoveryModel(ICliClient cli, IWslHost wsl, RecentFolders recent)
    {
        _cli = cli;
        _wsl = wsl;
        _recent = recent;
    }

    public event Action? Changed;

    /// <summary>What the folder box says. Default <c>~</c>, the home from <c>wsl.exe --exec printenv HOME</c>.</summary>
    public string Folder { get; set; } = "";

    /// <summary>The folder of the last scan, as the CLI got it.</summary>
    public string? ScannedFolder { get; private set; }

    public IReadOnlyList<FoundBench> Results { get; private set; } = [];

    public IReadOnlyList<string> Warnings { get; private set; } = [];

    public IReadOnlySet<string> Selected => _selected;

    public bool IsScanning { get; private set; }

    public bool IsAdding { get; private set; }

    public bool HasScanned { get; private set; }

    public string? Error { get; private set; }

    public string? Message { get; private set; }

    public IReadOnlyList<string> RecentList => _recent.Items;

    public IReadOnlyList<string> WarningLines => ScanJson.WarningLines(Warnings);

    public bool IsBusy => IsScanning || IsAdding;

    // --- argument lists (the exact calls; tests pin them) ---

    public static string[] ScanArgs(string folder) => ["scan", folder, "--json"];

    public static string[] ListArgs() => ["list", "--json"];

    /// <summary><c>register --json -- PATHS</c>: remember the benches, change no service.</summary>
    public static string[] RegisterArgs(IEnumerable<string> paths) => ["register", "--json", "--", .. paths];

    public static string[] PortsPlanArgs(IEnumerable<string> paths) => ["ports", "plan", "--json", "--", .. paths];

    public static string[] PortsApplyArgs(string token, IEnumerable<string> paths) => ["ports", "apply", token, "--yes", "--", .. paths];

    public static string[] AdoptPlanArgs(string path) => ["adopt", path, "--dry-run", "--json"];

    public static string[] AdoptApplyArgs(string path) => ["adopt", path, "--yes", "--json"];

    /// <summary>
    /// Set Up Management for one bench: <c>adopt PATH --dry-run --json</c> to read the plan, <c>adopt PATH --yes --json</c> to apply, with
    /// the Linux password in the environment when a step uses sudo. The adopt plan has no token, so the sheet has to confirm a plan without one.
    /// </summary>
    public static PlanReviewRequest AdoptRequest(string path, string name) =>
        new($"Set Up Management for {name}", AdoptPlanArgs(path), _ => AdoptApplyArgs(path))
        {
            ConfirmLabel = "Set Up",
            UsesSudoEnv = true,
            RequiresToken = false,
            Summary = "Writes the bench's service files and helpers. It never runs migrate, build or update.",
        };

    // --- states ---

    public FoundState StateOf(FoundBench bench)
    {
        var known = _known.FirstOrDefault(k => k.Path == bench.Path);
        if (bench.ServiceInstalled || known?.ServiceInstalled == true) return FoundState.Managed;
        return known is not null ? FoundState.AddedNeedsSetup : FoundState.NotAdopted;
    }

    /// <summary>Benches with no checkbox: nothing to add or set up.</summary>
    public IReadOnlySet<string> ManagedPaths => Results.Where(r => StateOf(r) == FoundState.Managed).Select(r => r.Path).ToHashSet(StringComparer.Ordinal);

    /// <summary>Benches a selection can hold.</summary>
    public IReadOnlySet<string> SelectablePaths => Results.Where(r => StateOf(r) != FoundState.Managed).Select(r => r.Path).ToHashSet(StringComparer.Ordinal);

    /// <summary>Benches Add Selected can still remember.</summary>
    public IReadOnlySet<string> AvailablePaths => Results.Where(r => StateOf(r) == FoundState.NotAdopted).Select(r => r.Path).ToHashSet(StringComparer.Ordinal);

    public bool AllSelected => SelectablePaths.Count > 0 && SelectablePaths.IsSubsetOf(_selected);

    public bool CanAdd => !IsBusy && _selected.Overlaps(AvailablePaths);

    public bool CanSetUp => !IsBusy && _selected.Count > 0;

    /// <summary>True when another bench (found or known) uses one of this bench's four ports.</summary>
    public bool HasPortConflict(FoundBench bench)
    {
        var own = bench.Ports.All.Where(p => p > 0).ToHashSet();
        return Results.Concat(_known).Any(other => other.Path != bench.Path && other.Ports.All.Any(own.Contains));
    }

    // --- selection ---

    public void SetSelected(string path, bool selected)
    {
        if (selected && SelectablePaths.Contains(path)) _selected.Add(path);
        else if (!selected) _selected.Remove(path);
        Raise();
    }

    public void SelectAll()
    {
        _selected.UnionWith(SelectablePaths);
        Raise();
    }

    public void DeselectAll()
    {
        _selected.Clear();
        Raise();
    }

    // --- the pane is shown, a scan ---

    /// <summary>Fills the folder box the first time: the last folder, else the home folder (or <c>~</c> when WSL did not answer).</summary>
    public async Task EnterAsync(CancellationToken ct = default)
    {
        if (Folder.Trim().Length > 0) return;
        await EnsureHomeAsync(ct).ConfigureAwait(true);
        if (Folder.Trim().Length > 0) return;
        Folder = _recent.Latest ?? _home ?? "~";
        Raise();
    }

    private async Task EnsureHomeAsync(CancellationToken ct)
    {
        if (_homeLoaded) return;
        _home = await _wsl.HomeAsync(ct).ConfigureAwait(true);
        _homeLoaded = _home is not null;
    }

    /// <summary>Turns what was typed into the Linux folder the CLI scans; null (and <see cref="Error"/>) when it cannot.</summary>
    public async Task<string?> ResolveFolderAsync(string typed, CancellationToken ct = default)
    {
        var text = typed.Trim();
        if (text.Length == 0)
        {
            Error = "Type the Linux folder to search, for example /home/you/projects.";
            return null;
        }
        if (text.StartsWith('~'))
        {
            await EnsureHomeAsync(ct).ConfigureAwait(true);
            if (_home is null)
            {
                Error = "WSL did not say where your home folder is. Type the full path, for example /home/you/projects.";
                return null;
            }
            text = WslPaths.ExpandHome(text, _home);
        }
        if (WslPaths.IsWindowsPath(text))
        {
            var converted = await _wsl.ToLinuxPathAsync(text, ct).ConfigureAwait(true);
            if (!converted.Ok)
            {
                Error = converted.Error;
                return null;
            }
            text = converted.Path!;
        }
        if (!text.StartsWith('/'))
        {
            Error = "Use a folder inside Linux, starting with /, for example /home/you/projects.";
            return null;
        }
        return text.Length > 1 ? text.TrimEnd('/') : text;
    }

    public async Task ScanAsync(CancellationToken ct = default)
    {
        if (IsBusy) return;
        Error = null;
        Message = null;
        var folder = await ResolveFolderAsync(Folder, ct).ConfigureAwait(true);
        if (folder is null)
        {
            Raise();
            return;
        }
        _scan?.Cancel();
        var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        _scan = cts;
        var generation = ++_generation;
        ScannedFolder = folder;
        Results = [];
        Warnings = [];
        _selected.Clear();
        HasScanned = false;
        IsScanning = true;
        Raise();
        ScanResult? found = null;
        string? problem = null;
        try
        {
            var result = await _cli.RunJsonAsync(ScanArgs(folder), null, ScanTimeout, ScanJson.ParseScan, cts.Token).ConfigureAwait(true);
            if (result.Value is { } value) found = value;
            else problem = result.Error ?? "The scan did not finish.";
            if (found is not null && cts.IsCancellationRequested == false) await RefreshKnownAsync(cts.Token).ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            return; // CancelScan or a newer scan already told the pane
        }
        if (cts.IsCancellationRequested || generation != _generation) return;
        IsScanning = false;
        if (found is null)
        {
            Error = problem;
        }
        else
        {
            Results = found.Benches;
            Warnings = found.Warnings;
            HasScanned = true;
            _selected.UnionWith(AvailablePaths);
            _recent.Add(folder);
        }
        Raise();
    }

    /// <summary>Cancel Scan: the call is killed and the pane says so.</summary>
    public void CancelScan()
    {
        if (!IsScanning) return;
        _generation++;
        try { _scan?.Cancel(); } catch (ObjectDisposedException) { }
        _scan = null;
        IsScanning = false;
        Message = "Scan cancelled.";
        Raise();
    }

    /// <summary>The benches BenchBar knows (<c>list --json</c>): what makes a found bench "added". Best effort: a failure leaves the last answer.</summary>
    public async Task RefreshKnownAsync(CancellationToken ct = default)
    {
        var result = await _cli.RunJsonAsync(ListArgs(), null, CliTimeouts.Read, ScanJson.ParseList, ct).ConfigureAwait(true);
        if (result.Value is { } list) _known = list;
    }

    // --- add, set up ---

    /// <summary>Add Selected: <c>register --json -- PATHS</c> for the selected benches BenchBar does not know yet.</summary>
    public async Task AddSelectedAsync(CancellationToken ct = default)
    {
        if (!CanAdd) return;
        var paths = _selected.Intersect(AvailablePaths).Order(StringComparer.Ordinal).ToList();
        IsAdding = true;
        Error = null;
        Message = null;
        Raise();
        try
        {
            var result = await _cli.RunJsonAsync(RegisterArgs(paths), null, CliTimeouts.Read, ScanJson.ParseList, ct).ConfigureAwait(true);
            if (result.Ok)
            {
                _known = result.Value!;
                _selected.ExceptWith(paths);
                Message = $"Added {paths.Count} {(paths.Count == 1 ? "bench" : "benches")} to BenchBar.";
            }
            else
            {
                Error = result.Error ?? "The benches could not be added.";
            }
        }
        finally
        {
            IsAdding = false;
            Raise();
        }
    }

    /// <summary>
    /// Set Up Selected: reads <c>ports plan --json -- PATHS</c> first, so a blocked plan is said in the pane and the sheet opens only for
    /// a plan that can be applied. The sheet reads the same plan again and applies it with <c>ports apply TOKEN --yes -- PATHS</c>.
    /// </summary>
    public async Task<PortSetupPrep> PrepareSetupAsync(IReadOnlyList<string> paths, CancellationToken ct = default)
    {
        Error = null;
        Message = null;
        var result = await _cli.RunJsonAsync(PortsPlanArgs(paths), null, CliTimeouts.Plan, SetupPlan.Parse, ct).ConfigureAwait(true);
        if (result.Value is not { } plan)
        {
            Error = result.Error ?? "The port plan could not be read.";
            Raise();
            return new PortSetupPrep(null, Error);
        }
        if (!plan.CanApply)
        {
            Error = plan.FirstBlock is { } block ? "Setup is blocked. " + block : "Setup is blocked, so nothing can be applied.";
            Raise();
            return new PortSetupPrep(null, Error);
        }
        var request = new PlanReviewRequest(paths.Count == 1 ? "Set Up Management" : $"Set Up {paths.Count} Benches", PortsPlanArgs(paths), p => PortsApplyArgs(p.Token ?? "", paths))
        {
            ConfirmLabel = "Set Up",
            Summary = plan.Summary(),
        };
        return new PortSetupPrep(request, null);
    }

    /// <summary>The selected benches in the order the scan listed them.</summary>
    public IReadOnlyList<string> SelectedInOrder() => Results.Where(r => _selected.Contains(r.Path)).Select(r => r.Path).ToList();

    /// <summary>After a sheet closed: what it did changes which benches are managed, so read the list again.</summary>
    public async Task SetupFinishedAsync(PlanOutcome outcome, CancellationToken ct = default)
    {
        if (outcome.Applied || outcome.Done is not null)
        {
            await RefreshKnownAsync(ct).ConfigureAwait(true);
            _selected.ExceptWith(ManagedPaths);
            if (outcome.Applied) Message = "Management is set up. Start the benches from the sidebar.";
        }
        Raise();
    }

    private void Raise() => Changed?.Invoke();
}
