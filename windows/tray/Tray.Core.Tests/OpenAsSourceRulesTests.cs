using System.Runtime.CompilerServices;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>
/// Open as is a person's decision and its sign in link is a credential. This scans the tray's code (not the tests) so a new path to
/// <c>site open-as on</c>, to the person's environment or to <c>--print-url</c> fails here until someone decides.
/// </summary>
public class OpenAsSourceRulesTests
{
    private static string TrayRoot([CallerFilePath] string here = "") => Path.GetFullPath(Path.Combine(Path.GetDirectoryName(here)!, ".."));

    /// <summary>Every code line (comments dropped) of the tray's sources as "File.cs: code", or null when the sources are not on this machine.</summary>
    private static List<string>? CodeLines()
    {
        var root = TrayRoot();
        if (!Directory.Exists(Path.Combine(root, "Tray.Core"))) return null;
        var lines = new List<string>();
        foreach (var dir in new[] { "Tray.Core", "BenchBarTray" })
        {
            foreach (var file in Directory.EnumerateFiles(Path.Combine(root, dir), "*.cs", SearchOption.AllDirectories))
            {
                if (file.Contains(Path.DirectorySeparatorChar + "obj" + Path.DirectorySeparatorChar)) continue;
                foreach (var line in File.ReadLines(file))
                {
                    var code = line.TrimStart();
                    if (code.StartsWith("//", StringComparison.Ordinal)) continue;
                    lines.Add(Path.GetFileName(file) + ": " + code);
                }
            }
        }
        return lines;
    }

    [Fact]
    public void SiteOpenAsOnIsBuiltOnlyByOpenAsCommandsSetAndCalledOnlyBehindTheQuestion()
    {
        if (CodeLines() is not { } code) return;
        Assert.StartsWith("OpenAsModels.cs:", Assert.Single(code, l => l.Contains("\"open-as\"")));
        // the one place that runs it, and the line that turns it on is the line of the question
        Assert.StartsWith("SitesView.OpenAs.cs:", Assert.Single(code, l => l.Contains("OpenAsCommands.Set(")));
        Assert.Contains("_services.Confirm(", Assert.Single(code, l => l.Contains("SetOpenAsAsync(") && l.Contains("true")));
    }

    [Fact]
    public void ThePersonsEnvironmentGoesOnlyToTurningOpenAsOnAndToOpeningAsAUser()
    {
        if (CodeLines() is not { } code) return;
        // the Sharing tab has its own PersonEnvironment for its click-only actions (ShareModel.cs, its own rules
        // and tests): this rule is about Open as
        var uses = code.Where(l => l.Contains("PersonEnvironment()") && !l.Contains("public static") && !l.StartsWith("ShareModel.cs:"))
            .Select(l => l.Split(':')[0]).Order().ToList();
        Assert.Equal(["OpenAsModels.cs", "SitesView.OpenAs.cs"], uses);
        // the search is a read: a typed letter must not claim that a person clicked
        Assert.DoesNotContain(code, l => l.Contains("OpenAsCommands.Users(") && l.Contains("PersonEnvironment"));
    }

    [Fact]
    public void NothingInTheTrayAsksForTheSignInLink()
    {
        if (CodeLines() is not { } code) return;
        Assert.DoesNotContain(code, l => l.Contains("print-url", StringComparison.OrdinalIgnoreCase));
    }
}
