using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// A file that exists while the tray runs: written at start, deleted on a clean exit (Quit, a Windows shutdown or sign out). Found at the next
/// start, it means the tray ended some other way (a crash, a kill). The file holds the version that wrote it: a tray that starts as another
/// version (the installer replaced it, closing the old one) does not count that as a crash.
/// </summary>
internal sealed class RunMarker(string? path = null)
{
    private readonly string _path = path ?? DataFolder.In("running");

    public string Path => _path;

    /// <summary>
    /// Writes the marker and says whether the previous run ended without removing it. Never throws. <paramref name="restartedByWindows"/>
    /// is a start by <c>RegisterApplicationRestart</c> (after a package update): Windows ended the earlier run on purpose, so a marker left
    /// behind is not a crash (a crash or a hang is never restarted: the registration says so).
    /// </summary>
    public bool Begin(string version, bool restartedByWindows = false)
    {
        var crashed = false;
        try
        {
            if (File.Exists(_path))
            {
                var earlier = File.ReadAllText(_path).Trim();
                crashed = !restartedByWindows && (earlier.Length == 0 || string.Equals(earlier, version, StringComparison.Ordinal));
            }
            var dir = System.IO.Path.GetDirectoryName(_path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            File.WriteAllText(_path, version);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // no marker: no notice next time, and nothing else is lost
        }
        return crashed;
    }

    /// <summary>A clean exit. Never throws.</summary>
    public void End()
    {
        try
        {
            if (File.Exists(_path)) File.Delete(_path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }
}
