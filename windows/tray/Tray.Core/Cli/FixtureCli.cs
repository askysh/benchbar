namespace BenchBar.Tray.Core;

/// <summary>
/// The demo mode's CLI: answers the read only calls of the pages from recorded files in <c>fixtures/cli</c> (next to, or inside, the
/// folder <c>BENCHBAR_TRAY_FIXTURES</c> names) and refuses everything else with a plain line. It never starts a process, so a demo can
/// not change a real bench.
/// </summary>
public sealed class FixtureCliRunner : IStreamRunner
{
    public const string Refusal = "The demo mode has no recorded answer for this. Unset BENCHBAR_TRAY_FIXTURES to use the real benchbar.exe.";

    private static readonly (string[] Prefix, string File)[] Answers =
    [
        (["ports", "check"], "ports-check-clean.json"),
        (["doctor"], "health-doctor.json"),
        (["lock", "check"], "health-lock-sync.json"),
        (["logs"], "logs-first.json"),
        (["app", "list"], "apps-list.json"),
        (["site", "backups"], "sites-backups.json"),
        (["profile", "list"], "profile-list.json"),
        (["list"], "scan-list.json"),
    ];

    private readonly string? _cliDir;

    public FixtureCliRunner(string fixturesDir)
    {
        foreach (var candidate in new[] { Path.Combine(fixturesDir, "cli"), Path.Combine(Path.GetDirectoryName(Path.GetFullPath(fixturesDir)) ?? fixturesDir, "cli") })
        {
            if (Directory.Exists(candidate))
            {
                _cliDir = candidate;
                break;
            }
        }
    }

    public async Task<StreamResult> RunAsync(string fileName, IReadOnlyList<string> args, IReadOnlyDictionary<string, string>? environment,
        Action<string> onLine, TimeSpan timeout, CancellationToken ct)
    {
        var mutating = args.Any(a => a is "--apply" or "--yes" or "--dry-run");
        var match = Answers.FirstOrDefault(a => a.Prefix.Length <= args.Count && a.Prefix.Select((p, i) => args[i] == p).All(x => x));
        if (_cliDir is null || mutating || match.File is null) return new StreamResult(1, Refusal);
        var path = Path.Combine(_cliDir, match.File);
        if (!File.Exists(path)) return new StreamResult(1, Refusal);
        foreach (var line in await File.ReadAllLinesAsync(path, ct).ConfigureAwait(false))
        {
            if (line.Trim().Length > 0) onLine(line);
        }
        return new StreamResult(0, null);
    }
}
