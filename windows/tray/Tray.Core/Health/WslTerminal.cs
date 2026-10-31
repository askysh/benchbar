namespace BenchBar.Tray.Core;

/// <summary>A command to run in a terminal inside the distro, in the bench folder (Console, Database, tail -f of a log).</summary>
public sealed record TerminalLaunch(string Distro, string BenchPath, IReadOnlyList<string> Command)
{
    /// <summary><c>wsl.exe -d DISTRO --cd BENCH --exec COMMAND...</c> (the arguments after <c>wsl.exe</c>). <c>--exec</c> runs the program itself, so no shell parses the words.</summary>
    public string[] WslArguments => ["-d", Distro, "--cd", BenchPath, "--exec", .. Command];

    /// <summary>Windows Terminal: <c>wt.exe wsl.exe -d DISTRO --cd BENCH --exec COMMAND...</c> (the arguments after <c>wt.exe</c>). wt treats <c>;</c> as its own separator, so each one is written with a backslash in front.</summary>
    public string[] WindowsTerminalArguments => new[] { "wsl.exe" }.Concat(WslArguments).Select(a => a.Replace(";", "\\;")).ToArray();
}

/// <summary>The commands the tray opens in a terminal. Pure: the arguments only; <c>TerminalLauncher</c> starts the process.</summary>
public static class WslCommands
{
    /// <summary><c>bench console</c>; with a site selected in the sidebar, <c>bench --site SITE console</c>.</summary>
    public static string[] Console(string? site) => Bench(site, "console");

    /// <summary><c>bench mariadb</c>; with a site selected in the sidebar, <c>bench --site SITE mariadb</c>.</summary>
    public static string[] Database(string? site) => Bench(site, "mariadb");

    /// <summary><c>tail -f -n 200 logs/bench.log</c> (or the previous log), relative to the bench folder.</summary>
    public static string[] TailLog(bool previous) => ["tail", "-f", "-n", "200", previous ? "logs/bench.previous.log" : "logs/bench.log"];

    /// <summary>A site name that is not a plain site name (<see cref="SiteNames.IsValid"/>) never reaches a terminal command.</summary>
    private static string[] Bench(string? site, string verb)
    {
        if (string.IsNullOrWhiteSpace(site)) return ["bench", verb];
        if (!SiteNames.IsValid(site)) throw new ArgumentException($"{site} is not a name the terminal can take.", nameof(site));
        return ["bench", "--site", site, verb];
    }

    /// <summary>The line to show when no terminal can open because the distro is not known.</summary>
    public const string NoDistroMessage = "BenchBar does not know which WSL distro to open. Choose one in Settings.";
}
