namespace BenchBar.Tray.Core;

/// <summary>Why a bench needs attention.</summary>
public enum AlertKind { None, Crashed, PausedAfterCrashes, PortConflict, NeedsRepair }

/// <summary>One notification to show: a title and one line of body, the fix.</summary>
public sealed record Toast(string Title, string Body, string BenchPath, AlertKind Kind);

/// <summary>
/// When to notify. Fed every snapshot, it returns the toasts to show now. The Linux CLI sends none, so the
/// tray owns this. Rules: the first snapshot with real data only seeds (a state found at launch is not news,
/// as on the Mac); one toast when a bench enters crashed, paused after crashes, a port conflict or broken;
/// nothing for a poll that changed nothing; a bench the CLI did not answer for (unknown, missing, distro stopped)
/// keeps its memory, so crashed, unknown, crashed gives one toast; crashed to paused is a change and toasts once.
/// </summary>
public sealed class ToastPolicy
{
    private readonly Dictionary<string, AlertKind> _seen = new(StringComparer.Ordinal);
    private bool _seeded;

    /// <summary>When false the policy still tracks states, so turning it on later does not announce old news.</summary>
    public bool Enabled { get; set; } = true;

    public IReadOnlyList<Toast> Observe(TraySnapshot snapshot)
    {
        // An unknown bench (it did not answer) is skipped on its own: nothing is learned, nothing is forgotten.
        // A snapshot with no known bench at all (distro stopped, shim missing, every bench silent) teaches nothing,
        // so it does not seed either.
        if (snapshot.DistroStopped || snapshot.Benches.All(b => b.State == BenchState.Unknown)) return [];

        var toasts = new List<Toast>();
        foreach (var bench in snapshot.Benches)
        {
            if (bench.State == BenchState.Unknown) continue;
            var kind = KindOf(bench);
            _seen.TryGetValue(bench.Path, out var before);
            _seen[bench.Path] = kind;
            if (_seeded && Enabled && kind != AlertKind.None && kind != before)
                toasts.Add(Make(bench, kind));
        }
        _seeded = true;
        return toasts;
    }

    public static AlertKind KindOf(BenchStatus bench) => bench.State switch
    {
        BenchState.Crashed => AlertKind.Crashed,
        BenchState.Paused => bench.StopReason?.Trim().ToLowerInvariant() switch
        {
            "crash" => AlertKind.PausedAfterCrashes,
            "port_conflict" => AlertKind.PortConflict,
            "broken" => AlertKind.NeedsRepair,
            _ => AlertKind.None,
        },
        _ => AlertKind.None,
    };

    private static Toast Make(BenchStatus bench, AlertKind kind)
    {
        var path = PosixQuote(bench.Path);
        var (title, body) = kind switch
        {
            AlertKind.Crashed => ($"{bench.Name} crashed", "It restarts on its own in about 20 seconds."),
            AlertKind.PausedAfterCrashes => ($"{bench.Name} paused after repeated crashes", $"benchbar up --bench-dir {path}"),
            AlertKind.PortConflict => ($"{bench.Name} has a port conflict", $"benchbar doctor --bench-dir {path}"),
            _ => ($"{bench.Name} needs repair", $"benchbar doctor --bench-dir {path}"),
        };
        return new Toast(title, body, bench.Path, kind);
    }

    /// <summary>The path as a shell would need it; a plain path stays as it is.</summary>
    internal static string PosixQuote(string value) =>
        value.Length > 0 && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.' or '/' or ':' or '=' or '@' or '+')
            ? value
            : "'" + value.Replace("'", "'\\''") + "'";
}
