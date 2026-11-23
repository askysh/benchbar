namespace BenchBar.Tray.Core;

/// <summary>
/// What the Overview shows besides the bench's state: who holds a lease (<c>lease list</c>), the resource charts (<c>stats</c>) and the
/// bench's running background operations (<c>op list</c>). Each is asked only when the CLI's catalogue lists the command, so an older CLI
/// gets no call it would refuse. It starts no timer: the page that shows it polls while it is visible (<see cref="PollAsync"/>), so nothing
/// here costs anything at rest. A failed read keeps what was known and says nothing; a bench change starts the picture over.
/// </summary>
public sealed class ActivityModel(ICliClient cli, Func<DateTimeOffset>? clock = null)
{
    private readonly Func<DateTimeOffset> _clock = clock ?? (() => DateTimeOffset.UtcNow);
    private string? _bench;

    public IReadOnlyList<LeaseInfo> Leases { get; private set; } = [];

    public IReadOnlyList<OpRecord> Ops { get; private set; } = [];

    public ResourceHistory Resources { get; } = new();

    public event Action? Changed;

    /// <summary>Whether anything is worth drawing.</summary>
    public bool HasContent => Leases.Count > 0 || Ops.Count > 0 || Resources.Latest is not null;

    public bool WantsStats(CommandCatalogue? catalogue) => catalogue?.Has("stats") == true;

    /// <summary>
    /// One round of reads for <paramref name="bench"/>. <paramref name="leases"/> says whether the leases are due this round (they are asked
    /// less often than the charts). A bench that is not <paramref name="running"/> has no resources and no chart.
    /// </summary>
    public async Task PollAsync(string bench, bool running, CommandCatalogue? catalogue, bool leases = true, CancellationToken ct = default)
    {
        if (catalogue is null) return;
        var changed = false;
        if (_bench != bench)
        {
            changed = Leases.Count > 0 || Ops.Count > 0 || Resources.Latest is not null;
            _bench = bench;
            Leases = [];
            Ops = [];
            Resources.Clear();
        }
        var now = _clock();
        if (leases && catalogue.Has("lease list"))
        {
            var r = await cli.RunJsonAsync(LeaseCommands.List(bench), null, CliTimeouts.Read, o => LeaseJson.ParseList(o, now), ct).ConfigureAwait(true);
            if (_bench == bench && r.Value is { } list && !list.SequenceEqual(Leases))
            {
                Leases = list;
                changed = true;
            }
        }
        if (WantsStats(catalogue))
        {
            if (!running)
            {
                if (Resources.Latest is not null)
                {
                    Resources.Clear();
                    changed = true;
                }
            }
            else
            {
                var r = await cli.RunJsonAsync(StatsJson.Args(bench), null, CliTimeouts.Read, o => StatsJson.Parse(o, now), ct).ConfigureAwait(true);
                if (_bench == bench && r.Exit == 0 && r.Error is null) // a null sample is an answer (nothing serves the site), a failed call is not
                {
                    if (r.Value is { } sample) Resources.Add(sample);
                    else if (Resources.Latest is not null) Resources.Clear(); // nothing serves the site now
                    changed = true;
                }
            }
        }
        if (catalogue.Has("op list"))
        {
            var r = await cli.RunJsonAsync(OpJson.List(catalogue.HasFlag("op list", "--running")), null, CliTimeouts.Read, OpJson.ParseList, ct).ConfigureAwait(true);
            if (_bench == bench && r.Value is { } all)
            {
                var mine = OpJson.RunningFor(all, bench);
                if (!mine.SequenceEqual(Ops))
                {
                    Ops = mine;
                    changed = true;
                }
            }
        }
        if (changed) Changed?.Invoke();
    }
}
