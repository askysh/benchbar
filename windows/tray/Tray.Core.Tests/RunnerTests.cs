using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

public sealed class RunnerFolder : IDisposable
{
    public string Root { get; } = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"));

    public RunnerFolder() => Directory.CreateDirectory(Root);

    public string Make(string name) => Directory.CreateDirectory(Path.Combine(Root, name)).FullName;

    /// <summary>A PNG of the given size, solid <paramref name="color"/>, with a transparent 2 px border when asked.</summary>
    public static void Png(string path, int width, int height, Color color)
    {
        using var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bitmap)) g.Clear(color);
        bitmap.Save(path, ImageFormat.Png);
    }

    public static void Manifest(string folder, string json) => File.WriteAllText(Path.Combine(folder, "manifest.json"), json);

    /// <summary>A valid runner: running (3 frames, ping pong), sleeping (2), alert (1). 36 by 36 black frames.</summary>
    public string Good(string name = "blob", int width = 36, bool template = true, string order = "ping_pong")
    {
        var dir = Make(name);
        foreach (var file in new[] { "run1.png", "run2.png", "run3.png", "sleep1.png", "sleep2.png", "alert.png" })
            Png(Path.Combine(dir, file), width, 36, Color.Black);
        Manifest(dir, $$"""
            {"name":"Blob","author":"Pat","template":{{(template ? "true" : "false")}},
             "states":{"running":["run1.png","run2.png","run3.png"],"sleeping":["sleep1.png","sleep2.png"],"alert":["alert.png"]},
             "frame_order":"{{order}}"}
            """);
        return dir;
    }

    public void Dispose()
    {
        try { Directory.Delete(Root, recursive: true); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }
}

public class RunnerLoaderTests : IDisposable
{
    private readonly RunnerFolder _runners = new();

    public void Dispose() => _runners.Dispose();

    private static string Message(Action action) => Assert.Throws<RunnerException>(action).Message;

    [Fact]
    public void AGoodFolderLoadsWithItsFramesInPlayOrder()
    {
        var runner = RunnerLoader.Load(_runners.Good(), "blob");
        Assert.Equal("blob", runner.Id);
        Assert.Equal("Blob", runner.Name);
        Assert.Equal("Pat", runner.Author);
        Assert.True(runner.IsTemplate);
        Assert.Equal(4, runner.FrameCount(RunnerPose.Running)); // 1 2 3 2
        Assert.Equal(2, runner.FrameCount(RunnerPose.Sleeping)); // two frames do not ping pong
        Assert.Equal(1, runner.FrameCount(RunnerPose.Alert));
    }

    [Fact]
    public void AStateThatIsLeftOutUsesTheRunningFrames()
    {
        var runner = RunnerLoader.Load(_runners.Good(), "blob");
        foreach (var pose in new[] { RunnerPose.Starting, RunnerPose.Crashed, RunnerPose.Unknown })
            Assert.Equal(runner.FrameCount(RunnerPose.Running), runner.FrameCount(pose));
    }

    [Fact]
    public void ForwardOrderKeepsTheListAndPingPongBouncesOffTheEnds()
    {
        Assert.Equal(["1", "2", "3"], RunnerLoader.Order(["1", "2", "3"], pingPong: false));
        Assert.Equal(["1", "2", "3", "2"], RunnerLoader.Order(["1", "2", "3"], pingPong: true));
        Assert.Equal(["1", "2", "3", "4", "3", "2"], RunnerLoader.Order(["1", "2", "3", "4"], pingPong: true));
        Assert.Equal(["1", "2"], RunnerLoader.Order(["1", "2"], pingPong: true));
    }

    [Fact]
    public void FrameOrderIsOptionalAndForwardByDefault()
    {
        var dir = _runners.Good(order: "forward");
        var manifest = JsonNode.Parse(File.ReadAllText(Path.Combine(dir, "manifest.json")))!.AsObject();
        manifest.Remove("frame_order");
        File.WriteAllText(Path.Combine(dir, "manifest.json"), manifest.ToJsonString());
        Assert.Equal(3, RunnerLoader.Load(dir, "blob").FrameCount(RunnerPose.Running));
    }

    [Theory]
    [InlineData("bench")]
    [InlineData("cup")]
    [InlineData("Bench")]
    public void TheBuiltInIdsAreReserved(string id) =>
        Assert.Contains("built in runner", Message(() => RunnerLoader.Load(_runners.Good(), id)));

    [Fact]
    public void ThereMustBeAManifest()
    {
        var dir = _runners.Good();
        File.Delete(Path.Combine(dir, "manifest.json"));
        Assert.Contains("no manifest.json", Message(() => RunnerLoader.Load(dir, "blob")));
    }

    [Theory]
    [InlineData("{ nope", "not valid JSON")]
    [InlineData("[]", "not a JSON object")]
    [InlineData("""{"template":true,"states":{"running":["run1.png"]}}""", "\"name\" is missing")]
    [InlineData("""{"name":"","template":true,"states":{"running":["run1.png"]}}""", "1 to 40")]
    [InlineData("""{"name":"0123456789012345678901234567890123456789X","template":true,"states":{"running":["run1.png"]}}""", "1 to 40")]
    [InlineData("""{"name":"B","states":{"running":["run1.png"]}}""", "\"template\" is missing")]
    [InlineData("""{"name":"B","template":"yes","states":{"running":["run1.png"]}}""", "\"template\" has the wrong type")]
    [InlineData("""{"name":"B","template":true}""", "\"states\" is missing")]
    [InlineData("""{"name":"B","template":true,"states":{"running":"run1.png"}}""", "wrong type")]
    [InlineData("""{"name":"B","template":true,"states":{"running":["run1.png"]},"frame_order":"backwards"}""", "frame_order")]
    public void ABadManifestSaysWhatIsWrong(string manifest, string expected)
    {
        var dir = _runners.Good();
        RunnerFolder.Manifest(dir, manifest);
        Assert.Contains(expected, Message(() => RunnerLoader.Load(dir, "blob")));
    }

    [Fact]
    public void TheManifestIsAtMostSixtyFourKilobytes()
    {
        var dir = _runners.Good();
        RunnerFolder.Manifest(dir, new string(' ', 70 * 1024));
        Assert.Contains("64 KB", Message(() => RunnerLoader.Load(dir, "blob")));
    }

    [Fact]
    public void AnUnknownStateIsRejected()
    {
        var dir = _runners.Good();
        RunnerFolder.Manifest(dir, """{"name":"B","template":true,"states":{"running":["run1.png"],"dancing":["run1.png"]}}""");
        Assert.Contains("\"dancing\" is not a state", Message(() => RunnerLoader.Load(dir, "blob")));
    }

    [Fact]
    public void RunningIsRequired()
    {
        var dir = _runners.Good();
        RunnerFolder.Manifest(dir, """{"name":"B","template":true,"states":{"sleeping":["sleep1.png"]}}""");
        Assert.Contains("running state is required", Message(() => RunnerLoader.Load(dir, "blob")));
        RunnerFolder.Manifest(dir, """{"name":"B","template":true,"states":{"running":[]}}""");
        Assert.Contains("running state is required", Message(() => RunnerLoader.Load(dir, "blob")));
    }

    [Fact]
    public void AnEmptyStateIsRejected()
    {
        var dir = _runners.Good();
        RunnerFolder.Manifest(dir, """{"name":"B","template":true,"states":{"running":["run1.png"],"alert":[]}}""");
        Assert.Contains("alert state lists no frames", Message(() => RunnerLoader.Load(dir, "blob")));
    }

    [Fact]
    public void AtMostThirtyFramesPerState()
    {
        var dir = _runners.Good();
        var names = string.Join(",", Enumerable.Range(0, 31).Select(_ => "\"run1.png\""));
        RunnerFolder.Manifest(dir, "{\"name\":\"B\",\"template\":true,\"states\":{\"running\":[" + names + "]}}");
        Assert.Contains("31 frames; the limit is 30", Message(() => RunnerLoader.Load(dir, "blob")));

        names = string.Join(",", Enumerable.Range(0, 30).Select(_ => "\"run1.png\""));
        RunnerFolder.Manifest(dir, "{\"name\":\"B\",\"template\":true,\"states\":{\"running\":[" + names + "]}}");
        Assert.Equal(30, RunnerLoader.Load(dir, "blob").FrameCount(RunnerPose.Running));
    }

    [Theory]
    [InlineData("../run1.png")]
    [InlineData("sub/run1.png")]
    [InlineData("sub\\run1.png")]
    [InlineData("..")]
    [InlineData(".hidden.png")]
    [InlineData("run1.jpg")]
    [InlineData("run1")]
    [InlineData("CON.png")]
    [InlineData("nul.png")]
    [InlineData("lpt1.png")]
    [InlineData("C:run1.png")]
    [InlineData("a|b.png")]
    [InlineData("")]
    public void OnlyPlainPngNamesAreAllowed(string name)
    {
        var dir = _runners.Good();
        RunnerFolder.Manifest(dir, "{\"name\":\"B\",\"template\":true,\"states\":{\"running\":[" + JsonValue.Create(name)!.ToJsonString() + "]}}");
        Assert.Contains("not an allowed frame name", Message(() => RunnerLoader.Load(dir, "blob")));
    }

    [Fact]
    public void AListedFileMustBeInTheFolder()
    {
        var dir = _runners.Good();
        File.Delete(Path.Combine(dir, "run2.png"));
        Assert.Contains("run2.png is listed in manifest.json but is not in the folder", Message(() => RunnerLoader.Load(dir, "blob")));
    }

    [Fact]
    public void AFrameMustReallyBeAPng()
    {
        var dir = _runners.Good();
        File.WriteAllText(Path.Combine(dir, "run2.png"), "this is text");
        Assert.Contains("run2.png is not a PNG image", Message(() => RunnerLoader.Load(dir, "blob")));

        using (var bitmap = new Bitmap(36, 36)) bitmap.Save(Path.Combine(dir, "run2.png"), ImageFormat.Gif); // a GIF called .png
        Assert.Contains("run2.png is not a PNG image", Message(() => RunnerLoader.Load(dir, "blob")));
    }

    [Theory]
    [InlineData(36, 35)]
    [InlineData(36, 37)]
    [InlineData(9, 36)]
    [InlineData(101, 36)]
    public void FramesAreThirtySixTallAndTenToAHundredWide(int width, int height)
    {
        var dir = _runners.Good();
        RunnerFolder.Png(Path.Combine(dir, "run1.png"), width, height, Color.Black);
        RunnerFolder.Manifest(dir, """{"name":"B","template":true,"states":{"running":["run1.png"]}}""");
        Assert.Contains($"{width} x {height} px", Message(() => RunnerLoader.Load(dir, "blob")));
    }

    [Theory]
    [InlineData(10)]
    [InlineData(100)]
    public void TheWidthLimitsThemselvesAreAllowed(int width)
    {
        var dir = _runners.Good(width: width);
        Assert.Equal("Blob", RunnerLoader.Load(dir, "blob").Name);
    }

    [Fact]
    public void EveryFrameIsTheSameSize()
    {
        var dir = _runners.Good();
        RunnerFolder.Png(Path.Combine(dir, "sleep2.png"), 40, 36, Color.Black);
        Assert.Contains("sleep2.png is not the same size", Message(() => RunnerLoader.Load(dir, "blob")));
    }

    [Fact]
    public void TheWholeFolderIsAtMostTwoMegabytes()
    {
        var dir = _runners.Good();
        File.WriteAllBytes(Path.Combine(dir, "extra.bin"), new byte[2 * 1024 * 1024 + 1]);
        Assert.Contains("limit is 2 MB", Message(() => RunnerLoader.Load(dir, "blob")));
    }

    [Fact]
    public void ALinkInsideTheFolderIsRejected()
    {
        var dir = _runners.Good();
        var target = _runners.Make("elsewhere");
        var link = Path.Combine(dir, "link");
        // a junction needs no privilege, unlike a symbolic link
        using (var process = Process.Start(new ProcessStartInfo("cmd.exe", $"/c mklink /J \"{link}\" \"{target}\"") { CreateNoWindow = true, UseShellExecute = false, RedirectStandardOutput = true })!)
        {
            process.StandardOutput.ReadToEnd();
            process.WaitForExit();
        }
        Assert.True(new DirectoryInfo(link).Attributes.HasFlag(FileAttributes.ReparsePoint), "the junction was not created");
        Assert.Contains("is a link", Message(() => RunnerLoader.Load(dir, "blob")));
    }

    [Fact]
    public void AFrameThatIsALinkIsRejected()
    {
        var dir = _runners.Good();
        var real = Path.Combine(_runners.Make("elsewhere"), "real.png");
        RunnerFolder.Png(real, 36, 36, Color.Black);
        File.Delete(Path.Combine(dir, "alert.png"));
        try
        {
            File.CreateSymbolicLink(Path.Combine(dir, "alert.png"), real);
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or IOException)
        {
            return; // symbolic links need developer mode or elevation; the junction test covers the rule
        }
        Assert.Contains("is a link", Message(() => RunnerLoader.Load(dir, "blob")));
    }

    [Theory]
    [InlineData("Blob", "blob")]
    [InlineData("My Runner!", "my-runner-")]
    [InlineData("a.b_c-d", "a.b_c-d")]
    public void TheIdIsTheFolderNameLowerCasedAndCleaned(string folder, string id) =>
        Assert.Equal(id, RunnerLoader.IdFor(folder));
}

public class RunnerSetTests : IDisposable
{
    private readonly RunnerFolder _runners = new();

    public void Dispose() => _runners.Dispose();

    [Fact]
    public void AMissingFolderIsJustTheBuiltIns()
    {
        var set = RunnerSet.Load(Path.Combine(_runners.Root, "nope"));
        Assert.Equal(["bench", "cup"], set.Runners.Select(r => r.Id));
        Assert.All(set.Runners, r => Assert.True(r.IsBuiltIn && r.IsUsable));
    }

    [Fact]
    public void GoodAndBrokenFoldersAreBothListedAndOnlyTheGoodOneIsSelectable()
    {
        _runners.Good("Blob");
        var bad = _runners.Make("broken");
        RunnerFolder.Manifest(bad, "{}");
        _runners.Good("cup"); // reserved id

        var set = RunnerSet.Load(_runners.Root);

        Assert.Equal(["bench", "cup", "blob", "broken", "cup"], set.Runners.Select(r => r.Id));
        var blob = set.Runners[2];
        Assert.True(blob.IsUsable);
        Assert.Equal("Blob (by Pat)", blob.DisplayName);
        Assert.Null(blob.Error);

        var broken = set.Runners[3];
        Assert.False(broken.IsUsable);
        Assert.Contains("\"name\" is missing", broken.Error);
        Assert.Equal("broken", broken.Name);

        Assert.Contains("built in runner", set.Runners[4].Error);

        Assert.Same(blob.Art, set.Resolve("blob"));
        Assert.Same(BuiltInRunners.Bench, set.Resolve("broken")); // never selected
        Assert.Same(BuiltInRunners.Bench, set.Resolve("missing"));
        Assert.Same(BuiltInRunners.Bench, set.Resolve(null));
        Assert.Same(BuiltInRunners.Cup, set.Resolve("cup")); // the built in, not the folder named cup
        Assert.Null(set.Find("broken"));
    }

    [Fact]
    public void TwoFoldersWithTheSameIdKeepTheFirst()
    {
        _runners.Good("my runner");
        _runners.Good("my-runner"); // both are the id my-runner
        var set = RunnerSet.Load(_runners.Root);
        var mine = set.Runners.Where(r => r.Id == "my-runner").ToList();
        Assert.Equal(2, mine.Count);
        Assert.True(mine[0].IsUsable);
        Assert.Contains("already has the id", mine[1].Error);
    }
}

public class RunnerRenderingTests : IDisposable
{
    private readonly RunnerFolder _runners = new();

    public void Dispose() => _runners.Dispose();

    private static byte[] Pixels(Bitmap bitmap)
    {
        var data = bitmap.LockBits(new Rectangle(0, 0, bitmap.Width, bitmap.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            var bytes = new byte[bitmap.Width * bitmap.Height * 4];
            for (var y = 0; y < bitmap.Height; y++)
                Marshal.Copy(data.Scan0 + y * data.Stride, bytes, y * bitmap.Width * 4, bitmap.Width * 4);
            return bytes;
        }
        finally { bitmap.UnlockBits(data); }
    }

    private static int Alpha(byte[] p, int side, int x, int y) => p[(y * side + x) * 4 + 3];

    [Theory]
    [InlineData(16)]
    [InlineData(20)]
    [InlineData(24)]
    [InlineData(32)]
    public void ASquareFrameFillsTheSlot(int side)
    {
        var runner = RunnerLoader.Load(_runners.Good(), "blob");
        using var bitmap = runner.Render(RunnerPose.Running, 0, side);
        Assert.Equal((side, side), (bitmap.Width, bitmap.Height));
        var pixels = Pixels(bitmap);
        Assert.Equal(255, Alpha(pixels, side, side / 2, side / 2));
        Assert.True(Alpha(pixels, side, 1, 1) >= 250 && Alpha(pixels, side, side - 2, side - 2) >= 250);
    }

    [Theory]
    [InlineData(16)]
    [InlineData(20)]
    [InlineData(24)]
    [InlineData(32)]
    public void AWideFrameKeepsItsAspectAndIsCentred(int side)
    {
        var runner = RunnerLoader.Load(_runners.Good(width: 72), "wide");
        using var bitmap = runner.Render(RunnerPose.Running, 0, side);
        var pixels = Pixels(bitmap);

        // 72 by 36 in a square slot: full width, half the height, centred
        var rows = Enumerable.Range(0, side).Where(y => Enumerable.Range(0, side).Any(x => Alpha(pixels, side, x, y) > 128)).ToList();
        var columns = Enumerable.Range(0, side).Where(x => Enumerable.Range(0, side).Any(y => Alpha(pixels, side, x, y) > 128)).ToList();
        Assert.Equal(0, columns.Min());
        Assert.Equal(side - 1, columns.Max());
        Assert.InRange(rows.Count, side / 2 - 1, side / 2 + 1);
        Assert.InRange(rows.Min() - (side - 1 - rows.Max()), -1, 1); // equal margins above and below
        Assert.Equal(0, Alpha(pixels, side, side / 2, 0));
        Assert.Equal(0, Alpha(pixels, side, side / 2, side - 1));
    }

    [Fact]
    public void ATemplateRunnerIsTintedAndAnyOtherKeepsItsColours()
    {
        var template = RunnerLoader.Load(_runners.Good("t", template: true), "t");
        var colour = RunnerLoader.Load(_runners.Good("c", template: false), "c");
        var dir = Path.Combine(_runners.Root, "red");
        Directory.CreateDirectory(dir);
        RunnerFolder.Png(Path.Combine(dir, "r.png"), 36, 36, Color.FromArgb(255, 200, 30, 20));
        RunnerFolder.Manifest(dir, """{"name":"Red","template":false,"states":{"running":["r.png"]}}""");
        var red = RunnerLoader.Load(dir, "red");

        using (var tinted = RunnerTint.Frame(template, RunnerPose.Running, 0, 20, lightBackground: false))
        {
            var p = Pixels(tinted);
            var i = (10 * 20 + 10) * 4;
            Assert.Equal((255, 255, 255, 255), (p[i + 2], p[i + 1], p[i], p[i + 3]));
        }
        using (var tinted = RunnerTint.Frame(template, RunnerPose.Running, 0, 20, lightBackground: true))
        {
            var p = Pixels(tinted);
            var i = (10 * 20 + 10) * 4;
            Assert.Equal((0x1B, 0x1B, 0x1B), (p[i + 2], p[i + 1], p[i]));
        }
        using (var plain = RunnerTint.Frame(red, RunnerPose.Running, 0, 20, lightBackground: false))
        {
            var p = Pixels(plain);
            var i = (10 * 20 + 10) * 4;
            Assert.Equal((200, 30, 20, 255), (p[i + 2], p[i + 1], p[i], p[i + 3]));
        }
        Assert.False(colour.IsTemplate);
    }

    [Fact]
    public void ACustomRunnerBecomesTrayIcons()
    {
        var runner = RunnerLoader.Load(_runners.Good(), "blob");
        using var icons = new RunnerIcons(20, false, runner);
        Assert.NotEqual(IntPtr.Zero, icons.Get(RunnerPose.Running, 0));
        Assert.NotEqual(IntPtr.Zero, icons.Get(RunnerPose.Crashed, 3)); // a missing state plays the running frames
        Assert.Equal(4, icons.FrameCount(RunnerPose.Crashed));
        Assert.Equal(2, icons.CachedCount);

        icons.SetRunner(BuiltInRunners.Cup);
        Assert.Equal(0, icons.CachedCount);
        Assert.Equal(6, icons.FrameCount(RunnerPose.Running));
    }

    [Fact]
    public void AFrameThatVanishedAfterTheCheckRendersBlankInsteadOfThrowing()
    {
        var dir = _runners.Good();
        var runner = RunnerLoader.Load(dir, "blob");
        File.Delete(Path.Combine(dir, "run1.png"));
        using var bitmap = runner.Render(RunnerPose.Running, 0, 20);
        Assert.Equal(0, Alpha(Pixels(bitmap), 20, 10, 10));
    }

    [Fact]
    public void ThePreviewIsATintedSquareForTheRunnerMenu()
    {
        using var preview = RunnerSet.RenderPreview(BuiltInRunners.Bench, 32, lightBackground: true);
        Assert.Equal((32, 32), (preview.Width, preview.Height));
        var p = Pixels(preview);
        var inked = Enumerable.Range(0, 32 * 32).Where(i => p[i * 4 + 3] > 128).ToList();
        Assert.NotEmpty(inked);
        Assert.All(inked, i => Assert.Equal(0x1B, p[i * 4]));
    }
}

public class CupRunnerTests
{
    private static readonly Dictionary<RunnerPose, int> Counts = new()
    {
        [RunnerPose.Sleeping] = 4,
        [RunnerPose.Starting] = 6,
        [RunnerPose.Running] = 6,
        [RunnerPose.Crashed] = 4,
        [RunnerPose.Alert] = 1,
        [RunnerPose.Unknown] = 1,
    };

    [Fact]
    public void TheCupHasTheBenchesPoseNamesAndFrameCounts()
    {
        Assert.Equal("cup", BuiltInRunners.Cup.Id);
        Assert.Equal("Coffee cup", BuiltInRunners.Cup.Name);
        Assert.True(BuiltInRunners.Cup.IsTemplate);
        foreach (var (pose, count) in Counts)
        {
            Assert.Equal(count, BuiltInRunners.Cup.FrameCount(pose));
            Assert.Equal(count, BuiltInRunners.Bench.FrameCount(pose));
        }
    }

    [Theory]
    [InlineData(16)]
    [InlineData(20)]
    [InlineData(24)]
    [InlineData(32)]
    public void EveryCupFrameHasInkAndIsNotMostlyFilled(int side)
    {
        foreach (var (pose, count) in Counts)
        {
            for (var f = 0; f < count; f++)
            {
                using var bitmap = BuiltInRunners.Cup.Render(pose, f, side);
                var data = bitmap.LockBits(new Rectangle(0, 0, side, side), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                var inked = 0;
                try
                {
                    var bytes = new byte[side * side * 4];
                    Marshal.Copy(data.Scan0, bytes, 0, bytes.Length); // stride is side * 4 for a 32 bpp bitmap
                    for (var i = 3; i < bytes.Length; i += 4) if (bytes[i] >= 128) inked++;
                }
                finally { bitmap.UnlockBits(data); }
                Assert.True(inked >= side, $"{pose} {f} at {side} has only {inked} inked pixels");
                Assert.True(inked < side * side * 0.7, $"{pose} {f} at {side} is mostly filled");
            }
        }
    }

    [Fact]
    public void TheCupDiffersFromTheBench()
    {
        using var bench = BuiltInRunners.Bench.Render(RunnerPose.Alert, 0, 32);
        using var cup = BuiltInRunners.Cup.Render(RunnerPose.Alert, 0, 32);
        Assert.NotEqual(Raw(bench), Raw(cup));
    }

    private static string Raw(Bitmap bitmap)
    {
        var data = bitmap.LockBits(new Rectangle(0, 0, bitmap.Width, bitmap.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            var bytes = new byte[bitmap.Width * bitmap.Height * 4];
            Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
            return Convert.ToBase64String(bytes);
        }
        finally { bitmap.UnlockBits(data); }
    }
}
