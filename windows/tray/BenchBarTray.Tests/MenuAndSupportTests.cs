using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;
using Xunit;

namespace BenchBar.Tray.Tests;

public class TrayMenuTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (IOException) { }
    }

    [Fact]
    public void TheItemsAreInTheAgreedOrder() => Sta.Run(() =>
    {
        var menu = new TrayMenu(new TrayMenuModel());
        Assert.Equal(
            [
                "Open BenchBar at logon", "Appearance", "Runner", "Notifications", "-",
                "Check for Updates", "Help", "Report a Bug", "-", "Quit",
            ],
            menu.Headers);
    });

    [Fact]
    public void TheChecksComeFromTheModelWhenTheMenuOpens() => Sta.Run(() =>
    {
        var model = new TrayMenuModel
        {
            LogonEnabled = () => true,
            Notifications = () => false,
            Appearance = () => AppearanceMode.Dark,
        };
        var menu = new TrayMenu(model);
        var items = menu.Menu.Items.OfType<MenuItem>().ToList();
        Assert.False(items[0].IsChecked); // nothing is read before the menu opens

        menu.RefreshChecks();
        Assert.True(items[0].IsChecked);
        Assert.False(items[3].IsChecked);
        var appearance = items[1].Items.OfType<MenuItem>().ToList();
        Assert.Equal(["System", "Light", "Dark"], appearance.Select(i => i.Header));
        Assert.Equal([false, false, true], appearance.Select(i => i.IsChecked));
    });

    [Fact]
    public void ClicksReachTheModel() => Sta.Run(() =>
    {
        var seen = new List<string>();
        var model = new TrayMenuModel
        {
            SetLogon = on => seen.Add("logon " + on),
            SetNotifications = on => seen.Add("notifications " + on),
            SetAppearance = m => seen.Add("appearance " + m),
            CheckForUpdates = () => seen.Add("update"),
            Help = () => seen.Add("help"),
            ReportBug = () => seen.Add("report"),
            Quit = () => seen.Add("quit"),
        };
        var menu = new TrayMenu(model);
        void Click(MenuItem item) => item.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        var items = menu.Menu.Items.OfType<MenuItem>().ToList();

        items[0].IsChecked = true; // a checkable item toggles itself before Click
        Click(items[0]);
        Click(items[1].Items.OfType<MenuItem>().Single(i => (string)i.Header == "Light"));
        items[3].IsChecked = false;
        Click(items[3]);
        foreach (var header in new[] { "Check for Updates", "Help", "Report a Bug", "Quit" })
            Click(items.Single(i => (string)i.Header == header));

        Assert.Equal(["logon True", "appearance Light", "notifications False", "update", "help", "report", "quit"], seen);
        var appearance = items[1].Items.OfType<MenuItem>().ToList();
        Assert.Equal([false, true, false], appearance.Select(i => i.IsChecked)); // radio behaviour
    });

    [Fact]
    public void TheRunnerSubmenuListsEveryRunnerAndDisablesTheBrokenOneWithItsError() => Sta.Run(() =>
    {
        using var folder = new RunnerFolder(_dir);
        folder.Good("blob");
        var bad = folder.Make("broken");
        File.WriteAllText(Path.Combine(bad, "manifest.json"), "{}");

        string? selected = null;
        var model = new TrayMenuModel
        {
            LoadRunners = () => RunnerSet.Load(_dir),
            RunnerId = () => "cup",
            SelectRunner = id => selected = id,
        };
        var menu = new TrayMenu(model);
        Assert.False(menu.IsAnimating); // no timer unless the submenu is open

        menu.BuildRunnerItems();
        var runner = menu.Menu.Items.OfType<MenuItem>().Single(i => (string)i.Header == "Runner");
        var runners = runner.Items.OfType<MenuItem>().Where(i => i.Tag is RunnerInfo).ToList();
        Assert.Equal(["Bench", "Coffee cup", "Blob (by Pat)", "broken"], runners.Select(i => i.Header));
        Assert.Equal([false, true, false, false], runners.Select(i => i.IsChecked));
        Assert.Equal([true, true, true, false], runners.Select(i => i.IsEnabled));
        Assert.Contains("\"name\" is missing", (string)runners[3].ToolTip);
        Assert.All(runners.Take(3), i => Assert.IsType<Image>(i.Icon));
        Assert.IsType<StackPanel>(runner.Items[0]); // the live preview sits above the list
        Assert.Equal("Coffee cup", menu.PreviewName);
        Assert.Equal("Open runners folder", ((MenuItem)runner.Items[^1]).Header);

        runners[2].RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        Assert.Equal("blob", selected);
        Assert.Equal([false, false, true, false], runners.Select(i => i.IsChecked));
        Assert.False(menu.IsAnimating);
    });
}

internal sealed class RunnerFolder(string root) : IDisposable
{
    public string Make(string name) => Directory.CreateDirectory(Path.Combine(root, name)).FullName;

    public string Good(string name)
    {
        var dir = Make(name);
        foreach (var file in new[] { "run1.png", "run2.png", "run3.png" })
        {
            using var bitmap = new System.Drawing.Bitmap(36, 36);
            using (var g = System.Drawing.Graphics.FromImage(bitmap)) g.Clear(System.Drawing.Color.Black);
            bitmap.Save(Path.Combine(dir, file), System.Drawing.Imaging.ImageFormat.Png);
        }
        File.WriteAllText(Path.Combine(dir, "manifest.json"),
            """{"name":"Blob","author":"Pat","template":true,"states":{"running":["run1.png","run2.png","run3.png"]}}""");
        return dir;
    }

    public void Dispose() { }
}

public class SupportTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (IOException) { }
    }

    [Fact]
    public void TheStartupShortcutIsOnlyOnWhenItPointsAtThisExe() => Sta.Run(() =>
    {
        var exe = Path.Combine(_dir, "app", "BenchBarTray.exe");
        var startup = new StartupShortcut(Path.Combine(_dir, "Startup"), exe);
        Assert.Equal("BenchBar Tray.lnk", Path.GetFileName(startup.LinkPath));
        Assert.False(startup.IsEnabled());

        startup.Enable(); // creates the missing folder
        Assert.True(File.Exists(startup.LinkPath));
        Assert.True(startup.IsEnabled());

        var other = new StartupShortcut(Path.Combine(_dir, "Startup"), Path.Combine(_dir, "elsewhere", "BenchBarTray.exe"));
        Assert.False(other.IsEnabled()); // a link to another copy does not count

        startup.Disable();
        Assert.False(File.Exists(startup.LinkPath));
        Assert.False(startup.IsEnabled());
        startup.Disable(); // twice is fine
    });

    [Fact]
    public void VsCodeIsFoundOnPathThenInTheUserInstall()
    {
        var present = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            Path.Combine(@"C:\tools", "code.cmd"),
            Path.Combine(@"C:\Users\a\AppData\Local", "Programs", "Microsoft VS Code", "bin", "code.cmd"),
        };
        Assert.Equal(Path.Combine(@"C:\tools", "code.cmd"), VsCode.Find(@"C:\x;C:\tools", @"C:\Users\a\AppData\Local", present.Contains));
        Assert.Equal(Path.Combine(@"C:\Users\a\AppData\Local", "Programs", "Microsoft VS Code", "bin", "code.cmd"),
            VsCode.Find(@"C:\x", @"C:\Users\a\AppData\Local", present.Contains));
        Assert.Null(VsCode.Find(@"C:\x", @"C:\nowhere", present.Contains));
    }

    [Fact]
    public void VsCodeGetsItsArgumentsAsAListNotAShellString()
    {
        var info = VsCode.StartInfo(@"C:\tools\code.cmd", "Ubuntu-24.04", "/home/a/my bench");
        Assert.Equal(@"C:\tools\code.cmd", info.FileName);
        Assert.Equal(["--remote", "wsl+Ubuntu-24.04", "/home/a/my bench"], info.ArgumentList);
        Assert.True(info.CreateNoWindow);
        Assert.False(info.UseShellExecute);
        Assert.Equal("", info.Arguments);
    }

    [Theory]
    [InlineData("v0.8.1", "0.8.0", true)]
    [InlineData("0.8.0", "0.8.0", false)]
    [InlineData("v0.7.9", "0.8.0", false)]
    [InlineData("v1.0.0", "0.9.9", true)]
    [InlineData("v0.8.0", "0.8.0-dev", true)]
    [InlineData("v0.0.1", "0.0.0-dev", true)]
    [InlineData("v0.8", "0.8.0", false)]
    [InlineData("nightly", "0.8.0", false)]
    [InlineData("v0.8.0", "weird", true)]
    public void VersionsCompareByNumber(string tag, string current, bool newer) =>
        Assert.Equal(newer, UpdateCheck.IsNewer(tag, current));

    [Fact]
    public void TheReleaseJsonGivesTheTagAndThePage()
    {
        var release = UpdateCheck.ParseRelease("""{"tag_name":"v0.9.0","html_url":"https://github.com/askysh/benchbar/releases/tag/v0.9.0","assets":[]}""");
        Assert.Equal(("v0.9.0", "https://github.com/askysh/benchbar/releases/tag/v0.9.0"), release);
        Assert.Null(UpdateCheck.ParseRelease("""{"message":"Not Found"}"""));
        Assert.Null(UpdateCheck.ParseRelease("[]"));
        Assert.False(string.IsNullOrEmpty(UpdateCheck.CurrentVersion()));
    }

    [Fact]
    public void DoctorTextUsesTheCliLayoutWithFixLines()
    {
        var report = BenchJson.ParseDoctor("""
            {"checks":[
              {"id":"a","label":"Agent","level":"ok","message":"running"},
              {"id":"b","label":"Built assets","level":"fail","message":"2 missing","fix_command":"cd /b && bench build"},
              {"id":"c","label":"PATH","level":"warn","message":"not set","fix_command":"benchbar.exe path install"}],
             "summary":{"ok":1,"warn":1,"fail":1}}
            """);
        Assert.Equal("1 OK, 1 WARN, 1 FAIL", TextFormats.Summary(report));
        Assert.Equal(["Built assets", "PATH", "Agent"], TextFormats.ByLevel(report).Select(c => c.Label));
        var text = TextFormats.Doctor(report).ReplaceLineEndings("\n");
        Assert.Equal(
            "[OK] Agent: running\n[FAIL] Built assets: 2 missing\n   fix: cd /b && bench build\n[WARN] PATH: not set\n   fix: benchbar.exe path install\n\n1 OK, 1 WARN, 1 FAIL",
            text);
    }

    [Fact]
    public void ALinuxPathBecomesAWslShare()
    {
        Assert.Equal(@"\\wsl.localhost\Ubuntu-24.04\home\a\Desktop\benchbar-report.zip",
            TextFormats.WslToWindows("Ubuntu-24.04", "/home/a/Desktop/benchbar-report.zip"));
        Assert.Equal("my-bench-", TextFormats.SafeFileName("my bench!"));
        Assert.Equal("bench", TextFormats.SafeFileName("..."));
    }

    [Fact]
    public void TheErrorLogWritesOneLinePerExceptionAndRotatesAtTheCap()
    {
        var path = Path.Combine(_dir, "BenchBar", "tray.log");
        var log = new ErrorLog(path, maxBytes: 300);
        log.Write("ui", new InvalidOperationException("first\nsecond line"));
        var lines = File.ReadAllLines(path);
        Assert.Single(lines); // a multi line exception is still one line
        Assert.Contains("ui: System.InvalidOperationException: first", lines[0]);

        for (var i = 0; i < 6; i++) log.Write("ui", new InvalidOperationException("again " + i));
        Assert.True(File.Exists(path + ".1"));
        Assert.True(new FileInfo(path).Length <= 300);
        Assert.True(new FileInfo(path + ".1").Length <= 300);
    }

    [Fact]
    public void TheErrorLogNeverThrows()
    {
        var log = new ErrorLog(Path.Combine(_dir, "a\0b", "tray.log"));
        log.Write("ui", new InvalidOperationException("x"));
    }
}

public class VsCodeValidationTests
{
    [Theory]
    [InlineData("/home/a/frappe-bench")]
    [InlineData("/home/a/my bench")]
    [InlineData("/home/a/bench-v15.1_x+y@z")]
    public void PlainPathsAreAllowed(string path) => Assert.True(VsCode.CanLaunch("Ubuntu-24.04", path));

    [Theory]
    [InlineData("/home/a/b&c")]
    [InlineData("/home/a/b|c")]
    [InlineData("/home/a/b^c")]
    [InlineData("/home/a/b<c")]
    [InlineData("/home/a/b>c")]
    [InlineData("/home/a/%PATH%")]
    [InlineData("/home/a/b!c")]
    [InlineData("/home/a/(b)")]
    [InlineData("/home/a/\"b")]
    [InlineData("/home/a/it's")]
    [InlineData("/home/a/b\nc")]
    [InlineData("")]
    public void ACmdMetacharacterOrAQuoteInThePathIsRefused(string path) => Assert.False(VsCode.CanLaunch("Ubuntu-24.04", path));

    [Theory]
    [InlineData("Ubuntu&calc")]
    [InlineData("Ub%x%")]
    [InlineData("a\"b")]
    [InlineData("")]
    public void TheSameGoesForTheDistroName(string distro) => Assert.False(VsCode.CanLaunch(distro, "/home/a/bench"));

    [Fact]
    public void TheFlyoutExplainsARefusedPathWithoutALink() => Sta.Run(() =>
    {
        var view = new FlyoutView(new FlyoutActions { OpenVsCode = _ => VsCodeOutcome.BadPath });
        var bench = BenchJson.ParseStatus("""{"bench":"/home/a/b&c","name":"b&c","site":"x.localhost","state":"running"}""");
        view.SetSnapshot(new TraySnapshot([bench]), "1 of 1 up");
        view.Rows[0].Buttons.Single(b => b.Content as string == "VS Code").RaiseEvent(new System.Windows.RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
        Assert.Equal("This bench path has characters VS Code's launcher cannot take; open it from a WSL terminal: code /home/a/b&c", view.MessageText);
    });

    [Fact]
    public void ABenchThatCouldNotBeReadShowsItsOwnLineUnderItsRow() => Sta.Run(() =>
    {
        var view = new FlyoutView(new FlyoutActions());
        var bad = new BenchStatus("b", "/b", BenchState.Unknown, null, null, null) { Problem = "bench dir is gone" };
        var ok = BenchJson.ParseStatus("""{"bench":"/a","name":"a","site":"x.localhost","state":"running"}""");
        view.SetSnapshot(new TraySnapshot([ok, bad]), "1 of 2 up");
        Assert.Null(view.Rows[0].FailureText);
        Assert.Equal("bench dir is gone", view.Rows[1].FailureText);
    });
}
