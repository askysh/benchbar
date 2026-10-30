namespace BenchBar.Tray.TestSupport;

/// <summary>
/// Where the recorded CLI output lives for the tests. The csproj files copy <c>fixtures</c> next to the test binaries, so the lookup
/// finds them wherever the build output goes (also with <c>--artifacts-path</c> outside the repository); walking up is the fallback.
/// Compiled into both test projects.
/// </summary>
internal static class FixtureFiles
{
    public static string Root { get; } = Find();

    public static string Dir(string name) => Path.Combine(Root, name);

    /// <summary>The non empty lines of <c>fixtures/cli/NAME</c>.</summary>
    public static string[] CliLines(string name) =>
        File.ReadAllLines(Path.Combine(Dir("cli"), name)).Where(l => l.Trim().Length > 0).ToArray();

    private static string Find()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "fixtures");
            if (Directory.Exists(Path.Combine(candidate, "recorded")) && Directory.Exists(Path.Combine(candidate, "cli"))) return candidate;
        }
        throw new DirectoryNotFoundException("fixtures folder not found at or above " + AppContext.BaseDirectory);
    }
}
