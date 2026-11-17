using System.Text;
using Microsoft.Win32;

namespace BenchBar.Tray.Core;

/// <summary>Whether a WSL distro is running now. It must never start one.</summary>
public interface IDistroProbe
{
    Task<bool> IsRunningAsync(string distro, CancellationToken ct);

    /// <summary>Whether WSL has this distro at all (running or not). Asked only after <see cref="IsRunningAsync"/> said no; it must not start one. A probe that cannot tell says yes.</summary>
    Task<bool> IsInstalledAsync(string distro, CancellationToken ct) => Task.FromResult(true);
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

    public async Task<bool> IsInstalledAsync(string distro, CancellationToken ct)
    {
        var result = await _runner.RunAsync("wsl.exe", ["--list", "--quiet"], ct, TimeSpan.FromSeconds(10), Encoding.Unicode).ConfigureAwait(false);
        // a failing list (no distro at all makes wsl.exe exit non zero with a sentence) lists nothing: the distro is not there
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

    /// <summary>
    /// Distros that belong to another tool (Docker Desktop, Rancher Desktop, Podman) and are never a place for a bench, default or not.
    /// The shim (windows/shim/distro.go) applies the same rule, so the tray and <c>benchbar.exe</c> watch the same distro.
    /// </summary>
    public static readonly IReadOnlyList<string> ToolPrefixes = ["docker-desktop", "rancher-desktop", "podman-machine"];

    public static bool IsToolDistro(string name) =>
        ToolPrefixes.Any(p => name.StartsWith(p, StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// The distro to watch among the registered ones: the default when it is usable, else the only usable one, else none (several
    /// candidates and no usable default is a choice for Settings or <c>adopt-distro</c>, not a guess).
    /// </summary>
    public static string? Pick(IReadOnlyList<(string Name, bool IsDefault)> distros)
    {
        var usable = distros.Where(d => d.Name.Length > 0 && !IsToolDistro(d.Name)).ToList();
        if (usable.FirstOrDefault(d => d.IsDefault) is { Name: { Length: > 0 } preferred }) return preferred;
        return usable.Count == 1 ? usable[0].Name : null;
    }

    /// <summary>HKCU Lxss: every subkey with a <c>DistributionName</c>, and <c>DefaultDistribution</c> (a GUID) names the default.</summary>
    public static string? FromRegistry()
    {
        try
        {
            using var lxss = Registry.CurrentUser.OpenSubKey(LxssKey);
            if (lxss is null) return null;
            var defaultGuid = lxss.GetValue("DefaultDistribution") as string;
            var distros = new List<(string Name, bool IsDefault)>();
            foreach (var guid in lxss.GetSubKeyNames())
            {
                using var key = lxss.OpenSubKey(guid);
                if (key?.GetValue("DistributionName") is string name)
                    distros.Add((name, string.Equals(guid, defaultGuid, StringComparison.OrdinalIgnoreCase)));
            }
            return Pick(distros);
        }
        catch (Exception)
        {
            return null;
        }
    }
}
