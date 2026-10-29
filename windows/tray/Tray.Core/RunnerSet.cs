using System.Drawing;

namespace BenchBar.Tray.Core;

/// <summary>
/// One entry of the Runner menu: a built in or custom runner, or a folder that broke a rule
/// (<see cref="Art"/> is null and <see cref="Error"/> says which, so the menu can list it and never select it).
/// </summary>
public sealed record RunnerInfo(string Id, string Name, string? Author, bool IsBuiltIn, IRunnerArt? Art, string? Error, string? Folder)
{
    public bool IsUsable => Art is not null;

    /// <summary>"Name (by author)", as the Mac's Settings shows it.</summary>
    public string DisplayName => string.IsNullOrWhiteSpace(Author) || IsBuiltIn ? Name : $"{Name} (by {Author})";
}

/// <summary>
/// The runners available: the built in <c>bench</c> and <c>cup</c>, then every valid or broken folder under
/// <c>%LOCALAPPDATA%\BenchBar\runners\&lt;id&gt;\</c>. A broken one is listed with its error and never selected:
/// <see cref="Resolve"/> falls back to the Bench.
/// </summary>
public sealed class RunnerSet
{
    private RunnerSet(IReadOnlyList<RunnerInfo> runners) => Runners = runners;

    public static string DefaultFolder { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BenchBar", "runners");

    public IReadOnlyList<RunnerInfo> Runners { get; }

    /// <summary>Only the built ins: Bench and Coffee cup.</summary>
    public static RunnerSet BuiltIn { get; } = new(Describe(BuiltInRunners.All));

    /// <summary>Reads the runners folder now. A missing folder is just the built ins; call again to pick up changes.</summary>
    public static RunnerSet Load(string? folder = null)
    {
        folder ??= DefaultFolder;
        var list = new List<RunnerInfo>(Describe(BuiltInRunners.All));
        var seen = new HashSet<string>(BuiltInRunners.All.Select(r => r.Id), StringComparer.OrdinalIgnoreCase);
        IEnumerable<string> dirs;
        try
        {
            dirs = Directory.Exists(folder) ? Directory.EnumerateDirectories(folder).OrderBy(Path.GetFileName, StringComparer.OrdinalIgnoreCase).ToList() : [];
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            dirs = [];
        }

        foreach (var dir in dirs)
        {
            var name = Path.GetFileName(dir);
            var id = RunnerLoader.IdFor(name);
            try
            {
                var runner = RunnerLoader.Load(dir, id);
                if (!seen.Add(id)) throw new RunnerException($"Another runner already has the id \"{id}\".");
                list.Add(new RunnerInfo(id, runner.Name, runner.Author, false, runner, null, dir));
            }
            catch (Exception ex) when (ex is RunnerException or IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
            {
                list.Add(new RunnerInfo(id, name, null, false, null, ex.Message, dir));
            }
        }
        return new RunnerSet(list);
    }

    public RunnerInfo? Find(string? id) =>
        id is null ? null : Runners.FirstOrDefault(r => r.Id.Equals(id, StringComparison.OrdinalIgnoreCase) && (r.IsBuiltIn || r.IsUsable));

    /// <summary>The runner for an id; the Bench when it is unknown, missing or broken.</summary>
    public IRunnerArt Resolve(string? id) => Find(id)?.Art ?? BuiltInRunners.Bench;

    /// <summary>
    /// One frame for the Runner menu, <paramref name="side"/> px square, as the tray would show it on a taskbar
    /// of the given brightness (a template runner tinted, any other as drawn). The caller disposes it.
    /// </summary>
    public static Bitmap RenderPreview(IRunnerArt art, int side, bool lightBackground, RunnerPose pose = RunnerPose.Running, int frame = 0) =>
        RunnerTint.Frame(art, pose, frame, side, lightBackground);

    private static List<RunnerInfo> Describe(IEnumerable<IRunnerArt> arts) =>
        arts.Select(a => new RunnerInfo(a.Id, a.Name, a.Author, true, a, null, null)).ToList();
}
