using System.ComponentModel;

namespace BenchBar.Tray.Core;

/// <summary>A Windows path turned into a path inside the distro, or why that failed.</summary>
public sealed record PathConversion(string? Path, string? Error)
{
    public bool Ok => Path is not null;
}

/// <summary>What the Find Benches and Team Profiles panes ask of WSL: the home folder, and Windows paths as Linux paths.</summary>
public interface IWslHost
{
    /// <summary><c>wsl.exe --exec printenv HOME</c>, the way the wizard resolves it; null when WSL did not answer.</summary>
    Task<string?> HomeAsync(CancellationToken ct);

    /// <summary>The path as the CLI inside the distro can open it: a Linux path is returned as it is, a Windows path goes through <c>wslpath</c>.</summary>
    Task<PathConversion> ToLinuxPathAsync(string path, CancellationToken ct);
}

public static class WslPaths
{
    /// <summary><c>C:\x\y</c>, <c>C:/x/y</c> or a UNC path (<c>\\wsl.localhost\Ubuntu\home\a</c>).</summary>
    public static bool IsWindowsPath(string path)
    {
        var p = path.Trim();
        if (p.StartsWith(@"\\", StringComparison.Ordinal)) return true;
        return p.Length >= 3 && char.IsAsciiLetter(p[0]) && p[1] == ':' && (p[2] == '\\' || p[2] == '/');
    }

    /// <summary>A path inside the distro as Windows opens it: <c>\\wsl.localhost\DISTRO\home\a\x.toml</c>.</summary>
    public static string ToWindows(string distro, string linuxPath) =>
        @"\\wsl.localhost\" + distro + linuxPath.Replace('/', '\\');

    /// <summary><c>~</c> and <c>~/x</c> become paths under <paramref name="home"/>; anything else stays.</summary>
    public static string ExpandHome(string path, string? home)
    {
        var p = path.Trim();
        if (home is null || home.Length == 0) return p;
        if (p == "~") return home.TrimEnd('/');
        return p.StartsWith("~/", StringComparison.Ordinal) ? home.TrimEnd('/') + p[1..] : p;
    }
}

/// <summary>The real thing: <c>wsl.exe</c> in the distro the tray watches (<paramref name="distro"/>, null for the default).</summary>
public sealed class WslHost(IProcessRunner runner, Func<string?> distro) : IWslHost
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(30);

    public async Task<string?> HomeAsync(CancellationToken ct)
    {
        try
        {
            var result = await runner.RunAsync("wsl.exe", Args("printenv", "HOME"), ct, Timeout).ConfigureAwait(false);
            var line = result.ExitCode == 0 ? ShimBenchSource.FirstLine(result.Output) : null;
            return line is { Length: > 0 } && line.StartsWith('/') ? line.Trim() : null;
        }
        catch (Exception ex) when (ex is Win32Exception or OperationCanceledException or TimeoutException)
        {
            return null;
        }
    }

    public async Task<PathConversion> ToLinuxPathAsync(string path, CancellationToken ct)
    {
        var text = path.Trim();
        if (!WslPaths.IsWindowsPath(text)) return new PathConversion(text, null);
        try
        {
            var result = await runner.RunAsync("wsl.exe", Args("wslpath", "-a", "-u", text), ct, Timeout).ConfigureAwait(false);
            var line = result.ExitCode == 0 ? ShimBenchSource.FirstLine(result.Output) : null;
            if (line is { Length: > 0 } && line.StartsWith('/')) return new PathConversion(line.Trim(), null);
            return new PathConversion(null, ShimBenchSource.FirstLine(result.Error) ?? $"WSL could not convert {text} to a Linux path.");
        }
        catch (Exception ex) when (ex is Win32Exception or OperationCanceledException or TimeoutException)
        {
            return new PathConversion(null, "WSL could not be started to convert " + text + ".");
        }
    }

    private List<string> Args(params string[] command)
    {
        var args = new List<string>();
        if (distro() is { Length: > 0 } name) args.AddRange(["-d", name]);
        args.Add("--exec");
        args.AddRange(command);
        return args;
    }
}
