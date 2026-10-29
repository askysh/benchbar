using System.Text;
using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

public class ConfigTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"));

    private string ConfigPath => Path.Combine(_dir, "BenchBar", "config.json");

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (IOException) { }
    }

    private void Write(string text, bool bom = false)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(ConfigPath)!);
        File.WriteAllBytes(ConfigPath, new UTF8Encoding(bom).GetPreamble().Concat(Encoding.UTF8.GetBytes(text)).ToArray());
    }

    private JsonObject Read() => (JsonObject)JsonNode.Parse(File.ReadAllText(ConfigPath))!;

    [Fact]
    public void AMissingFileAndFolderGiveTheDefaults()
    {
        var config = TrayConfig.Load(ConfigPath);
        Assert.Equal(AppearanceMode.System, config.Appearance);
        Assert.Equal("bench", config.RunnerId);
        Assert.True(config.Notifications);
        Assert.Null(config.Distro);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   \r\n")]
    public void AnEmptyFileGivesTheDefaults(string text)
    {
        Write(text);
        var config = TrayConfig.Load(ConfigPath);
        Assert.False(config.WasCorrupt);
        Assert.Equal("bench", config.RunnerId);
    }

    [Fact]
    public void ABomIsTolerated()
    {
        Write("""{"distro":"Debian","tray":{"appearance":"dark","runner":"cup","notifications":false}}""", bom: true);
        var config = TrayConfig.Load(ConfigPath);
        Assert.Equal("Debian", config.Distro);
        Assert.Equal(AppearanceMode.Dark, config.Appearance);
        Assert.Equal("cup", config.RunnerId);
        Assert.False(config.Notifications);
    }

    [Fact]
    public void SaveKeepsEveryUnknownKeyAtTheTopAndInsideTray()
    {
        Write("""
            {"distro":"Ubuntu-24.04","cli_path":"/opt/bb","future":{"a":[1,2]},
             "tray":{"appearance":"light","runner":"blob","notifications":true,"window":{"x":3},"later":"yes"}}
            """);
        var config = TrayConfig.Load(ConfigPath);
        config.Appearance = AppearanceMode.Dark;
        config.RunnerId = "cup";
        config.Notifications = false;
        config.Save();

        var root = Read();
        Assert.Equal("Ubuntu-24.04", (string?)root["distro"]);
        Assert.Equal("/opt/bb", (string?)root["cli_path"]);
        Assert.Equal(2, root["future"]!["a"]!.AsArray()[1]!.GetValue<int>());
        var tray = root["tray"]!.AsObject();
        Assert.Equal("dark", (string?)tray["appearance"]);
        Assert.Equal("cup", (string?)tray["runner"]);
        Assert.False(tray["notifications"]!.GetValue<bool>());
        Assert.Equal(3, tray["window"]!["x"]!.GetValue<int>());
        Assert.Equal("yes", (string?)tray["later"]);
    }

    [Fact]
    public void ARoundTripGivesTheSameSettings()
    {
        var config = TrayConfig.Load(ConfigPath);
        config.Appearance = AppearanceMode.Light;
        config.RunnerId = "my-runner";
        config.Notifications = false;
        config.Save(); // creates the missing folder

        var again = TrayConfig.Load(ConfigPath);
        Assert.Equal(AppearanceMode.Light, again.Appearance);
        Assert.Equal("my-runner", again.RunnerId);
        Assert.False(again.Notifications);
    }

    [Fact]
    public void SaveIsAtomicAndLeavesNoTempFile()
    {
        var config = TrayConfig.Load(ConfigPath);
        config.Save();
        config.Notifications = false;
        config.Save();
        Assert.Equal([ConfigPath], Directory.GetFiles(Path.GetDirectoryName(ConfigPath)!));
    }

    [Fact]
    public void AFileThatIsNotJsonIsKeptAsBadBeforeItIsReplaced()
    {
        Write("{ not json");
        var config = TrayConfig.Load(ConfigPath);
        Assert.True(config.WasCorrupt);
        Assert.Equal("bench", config.RunnerId);

        config.Save();
        Assert.Equal("{ not json", File.ReadAllText(ConfigPath + ".bad"));
        Assert.Equal("bench", (string?)Read()["tray"]!["runner"]);
        Assert.False(config.WasCorrupt);
    }

    [Fact]
    public void ATrayKeyOfTheWrongTypeIsReplacedAndOtherKeysSurvive()
    {
        Write("""{"distro":"D","tray":"oops"}""");
        var config = TrayConfig.Load(ConfigPath);
        config.Save();
        var root = Read();
        Assert.Equal("D", (string?)root["distro"]);
        Assert.Equal("system", (string?)root["tray"]!["appearance"]);
    }

    [Theory]
    [InlineData("light", AppearanceMode.Light)]
    [InlineData("LIGHT", AppearanceMode.Light)]
    [InlineData("dark", AppearanceMode.Dark)]
    [InlineData("system", AppearanceMode.System)]
    [InlineData("neon", AppearanceMode.System)]
    [InlineData(null, AppearanceMode.System)]
    public void AppearanceTextParses(string? text, AppearanceMode expected) =>
        Assert.Equal(expected, TrayConfig.ParseAppearance(text));
}

public class ThemeTests
{
    [Theory]
    [InlineData(AppearanceMode.System, true, false, true, false)]
    [InlineData(AppearanceMode.System, false, true, false, true)]
    [InlineData(AppearanceMode.Light, false, false, true, true)]
    [InlineData(AppearanceMode.Dark, true, true, false, false)]
    public void SystemFollowsEachRegistryValueAndTheOthersForceBoth(
        AppearanceMode mode, bool apps, bool taskbar, bool flyoutLight, bool taskbarLight)
    {
        var theme = ThemeResolver.Resolve(mode, () => apps, () => taskbar, forced: "");
        Assert.Equal(new ResolvedTheme(flyoutLight, taskbarLight), theme);
    }

    [Theory]
    [InlineData("light", AppearanceMode.Dark, true)]
    [InlineData("dark", AppearanceMode.Light, false)]
    public void TheEnvironmentOverrideBeatsTheSetting(string forced, AppearanceMode mode, bool light) =>
        Assert.Equal(new ResolvedTheme(light, light), ThemeResolver.Resolve(mode, () => !light, () => !light, forced));
}
