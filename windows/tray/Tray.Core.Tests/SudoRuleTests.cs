using System.Runtime.CompilerServices;
using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>
/// The sudo password goes only to install, adopt (when the plan has sudo steps) and repair (when an action needs sudo). This lists every
/// place the code can put <c>BENCHBAR_SUDO_PASSWORD</c> in a child's environment, so a new one fails here until someone decides.
/// </summary>
public class SudoRuleTests
{
    private static string TrayRoot([CallerFilePath] string here = "") => Path.GetFullPath(Path.Combine(Path.GetDirectoryName(here)!, ".."));

    [Fact]
    public void OnlyTheKnownPlacesBuildASudoEnvironment()
    {
        var root = TrayRoot();
        if (!Directory.Exists(Path.Combine(root, "Tray.Core"))) return; // the sources are not on this machine
        var hits = new List<string>();
        foreach (var dir in new[] { "Tray.Core", "BenchBarTray" })
        {
            foreach (var file in Directory.EnumerateFiles(Path.Combine(root, dir), "*.cs", SearchOption.AllDirectories))
            {
                if (file.Contains(Path.DirectorySeparatorChar + "obj" + Path.DirectorySeparatorChar)) continue;
                foreach (var line in File.ReadLines(file))
                {
                    var code = line.TrimStart();
                    if (code.StartsWith("///", StringComparison.Ordinal) || code.StartsWith("//", StringComparison.Ordinal)) continue;
                    if (code.Contains("CliSudo.Apply(") || code.Contains("SetupEnv.SudoPassword") || code.Contains("Set(SudoPassword") || code.Contains("UsesSudoEnv = true"))
                        hits.Add(Path.GetFileName(file) + ": " + code.Split("//")[0].Trim());
                }
            }
        }
        string[] expected =
        [
            // the wizard's install and adopt run (SetupEnv.ForInstall)
            "SetupService.cs: env.Set(AdminPassword, secrets.Admin).Set(SudoPassword, secrets.LinuxPassword).Set(MariadbRootPassword, secrets.RootPassword);",
            // Set Up Management (adopt): asks when the plan has sudo steps
            "DiscoveryModel.cs: UsesSudoEnv = true,",
            // the plan sheet: only for a request that says so, and a plan with sudo steps
            "PlanReviewModel.cs: if (password is not null) CliSudo.Apply(env, password);",
            "PlanReviewModel.cs: return env.Set(SetupEnv.Sudo, \"env\").Set(SetupEnv.NonInteractive, \"1\").Set(SetupEnv.SudoPassword, password);",
            // repair: only when an action of its plan needs sudo
            "RepairModel.cs: var env = password is null ? null : CliSudo.Apply(null, password);",
        ];
        Assert.Equal(expected.Order(StringComparer.Ordinal), hits.Order(StringComparer.Ordinal));
    }
}
