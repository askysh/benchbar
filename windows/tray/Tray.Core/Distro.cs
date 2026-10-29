using System.Text;
using Microsoft.Win32;

namespace BenchBar.Tray.Core;

/// <summary>Whether a WSL distro is running now. It must never start one.</summary>
public interface IDistroProbe
{
    Task<bool> IsRunningAsync(string distro, CancellationToken ct);
}

/// <summary>
/// <c>wsl.exe --list --running --quiet</c>: lists the running distros without booting any.
/// Its output is UTF-16LE; names are compared without regard to case.
/// </summary>
public sealed class WslDistroProbe(IProcessRunner? runner = null) : IDistroProbe
{
    private readonly IProcessRunner _runner = runner ?? new SystemProcessRunner();

    public async Task<bool> IsRunningAsync(string distro, CancellationToken ct)
    {
        // a missing wsl.exe throws; the poller then asks the shim, which says so with its own fix line
        var result = await _runner.RunAsync("wsl.exe", ["--list", "--running", "--quiet"], ct, TimeSpan.FromSeconds(10), Encoding.Unicode)
            .ConfigureAwait(false);
        return ParseRunning(result.Output).Contains(distro.Trim(), StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>The names in the output, with the BOM, NULs and carriage returns removed and blank lines dropped.</summary>
    public static IReadOnlyList<string> ParseRunning(string output)
    {
        var text = output.Replace("\0", "").Replace("﻿", "").Replace("\r", "");
        return text.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).ToList();
    }
}

/// <summary>
/// The distro the tray watches: <c>distro</c> in config.json (the shim's key), else the WSL default distro.
/// </summary>
public static class DistroName
{
    private const string LxssKey = @"Software\Microsoft\Windows\CurrentVersion\Lxss";

    public static string? Resolve(string? configured, Func<string?>? defaultDistro = null)
    {
        if (!string.IsNullOrWhiteSpace(configured)) return configured.Trim();
        return (defaultDistro ?? FromRegistry)();
    }

    /// <summary>HKCU Lxss: <c>DefaultDistribution</c> is a GUID; its subkey holds <c>DistributionName</c>.</summary>
    public static string? FromRegistry()
    {
        try
        {
            using var lxss = Registry.CurrentUser.OpenSubKey(LxssKey);
            if (lxss?.GetValue("DefaultDistribution") is not string guid || guid.Length == 0) return null;
            using var distro = lxss.OpenSubKey(guid);
            return distro?.GetValue("DistributionName") as string;
        }
        catch (Exception)
        {
            return null;
        }
    }
}
