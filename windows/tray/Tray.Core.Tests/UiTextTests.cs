using System.Text.RegularExpressions;
using System.Xml.Linq;
using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

public class UiTextTests
{
    private static string TrayFolder()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "BenchBarTray.sln"))) return dir.FullName;
        throw new DirectoryNotFoundException("windows/tray was not found above " + AppContext.BaseDirectory);
    }

    [Fact]
    public void EveryNameTheCodeAsksForIsInTheResourceFileAndEveryEntryIsUsed()
    {
        var folder = TrayFolder();
        var names = XDocument.Load(Path.Combine(folder, "Tray.Core", "Resources", "Strings.resx"))
            .Root!.Elements("data").Select(d => (string)d.Attribute("name")!).ToHashSet();
        var used = new[] { "Tray.Core", "BenchBarTray" }.SelectMany(d => Directory.EnumerateFiles(Path.Combine(folder, d), "*.cs", SearchOption.AllDirectories))
            .Where(f => !f.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}") && !f.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}"))
            .SelectMany(f => Regex.Matches(File.ReadAllText(f), @"UiText\.(?:Get|Format)\(""(\w+)""").Select(m => m.Groups[1].Value))
            .ToHashSet();
        used.UnionWith(Regex.Matches(File.ReadAllText(Path.Combine(folder, "Tray.Core", "TrayController.cs")), @"""(Tooltip\w+)""").Select(m => m.Groups[1].Value));

        Assert.Empty(used.Except(names)); // a missing name would show as the name itself
        Assert.Empty(names.Except(used)); // an entry nobody reads is dead text
    }

    [Fact]
    public void AFormatStringTakesTheArgumentsTheCodePasses()
    {
        Assert.Equal("Update to 0.9.1", UiText.Format("MenuUpdateTo", "0.9.1"));
        Assert.Equal("a crashed", UiText.Format("ToastCrashedTitle", "a"));
        Assert.Equal("Use Debian?", UiText.Format("SettingsUseDistro", "Debian"));
        Assert.Equal("Type my-site to confirm", UiText.Format("TypeToConfirm", "my-site"));
        Assert.Equal("Opening as Administrator...", UiText.Format("QuickSwitchOpeningAs", "Administrator"));
        Assert.Equal("BenchBar needs your Linux password for 2 steps that use sudo.", UiText.Format("LinuxPasswordNeeds", 2, UiText.Get("LinuxPasswordSteps")));
        Assert.Equal("Warning: x", UiText.Format("LabsWarning", "x"));
    }
}
