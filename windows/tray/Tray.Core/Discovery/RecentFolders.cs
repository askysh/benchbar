namespace BenchBar.Tray.Core;

/// <summary>
/// The folders Find Benches searched last, newest first (macos remembers one, <c>scanFolder</c>; there is no folder picker here, so
/// the pane offers a few). One folder per line in <c>%LOCALAPPDATA%\BenchBar\recent-scan-folders.txt</c>. A file that cannot be read
/// or written costs only the list, never the scan.
/// </summary>
public sealed class RecentFolders
{
    public const int Limit = 6;

    private readonly string? _path;
    private readonly List<string> _items = [];

    public RecentFolders(string? path = null)
    {
        _path = path;
        if (path is null) return;
        try
        {
            if (File.Exists(path))
                _items.AddRange(File.ReadAllLines(path).Select(l => l.Trim()).Where(l => l.StartsWith('/')).Distinct(StringComparer.Ordinal).Take(Limit));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            _items.Clear();
        }
    }

    public static string DefaultPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BenchBar", "recent-scan-folders.txt");

    public IReadOnlyList<string> Items => _items;

    public string? Latest => _items.FirstOrDefault();

    public void Add(string folder)
    {
        var f = folder.Trim().TrimEnd('/');
        if (f.Length == 0 || !f.StartsWith('/')) return;
        _items.RemoveAll(i => string.Equals(i, f, StringComparison.Ordinal));
        _items.Insert(0, f);
        if (_items.Count > Limit) _items.RemoveRange(Limit, _items.Count - Limit);
        Save();
    }

    private void Save()
    {
        if (_path is null) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllLines(_path, _items);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // the list stays in memory for this run
        }
    }
}
