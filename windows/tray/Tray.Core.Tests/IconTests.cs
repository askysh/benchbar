using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

public class IconTests
{
    private static readonly Dictionary<RunnerPose, int> MacFrameCounts = new()
    {
        [RunnerPose.Sleeping] = 4,
        [RunnerPose.Starting] = 6,
        [RunnerPose.Running] = 6,
        [RunnerPose.Crashed] = 4,
        [RunnerPose.Alert] = 1,
        [RunnerPose.Unknown] = 1,
    };

    private static string TempDir() =>
        Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"));

    /// <summary>The bitmap's pixels as BGRA bytes, row after row.</summary>
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

    private static int Alpha(byte[] pixels, int width, int x, int y) => pixels[(y * width + x) * 4 + 3];

    [Fact]
    public void FrameCountsMatchTheMac()
    {
        using var icons = new RunnerIcons();
        foreach (var (pose, count) in MacFrameCounts)
        {
            Assert.Equal(count, icons.FrameCount(pose));
            Assert.Equal(count, BenchRunnerArt.FrameCount(pose));
        }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void ExportAtTwentyPixelsWritesEveryFrameAndNoneIsEmpty(bool light)
    {
        var dir = TempDir();
        var files = RunnerIcons.ExportPng(dir, 20, light);

        Assert.Equal(MacFrameCounts.Values.Sum(), files.Count);
        foreach (var (pose, count) in MacFrameCounts)
            for (var f = 1; f <= count; f++)
                Assert.True(File.Exists(Path.Combine(dir, $"{pose.ToString().ToLowerInvariant()}-{f}.png")));

        var tint = light ? RunnerIcons.LightTaskbarTint : RunnerIcons.DarkTaskbarTint;
        foreach (var file in files)
        {
            using var bitmap = new Bitmap(file);
            Assert.Equal(20, bitmap.Width);
            Assert.Equal(20, bitmap.Height);
            var pixels = Pixels(bitmap);
            var inked = 0;
            for (var i = 0; i < pixels.Length; i += 4)
            {
                if (pixels[i + 3] < 128) continue;
                inked++;
                // straight alpha: the colour of every visible pixel is the taskbar foreground
                Assert.Equal(tint.B, pixels[i]);
                Assert.Equal(tint.G, pixels[i + 1]);
                Assert.Equal(tint.R, pixels[i + 2]);
            }
            Assert.True(inked >= 25, $"{Path.GetFileName(file)} has only {inked} inked pixels");
            Assert.True(inked < 20 * 20 * 0.7, $"{Path.GetFileName(file)} is mostly filled");
        }
    }

    [Fact]
    public void TheRunnerIsCentredVerticallyAndFillsTheWidth()
    {
        using var bitmap = BenchRunnerArt.Render(RunnerPose.Alert, 0, 24);
        var pixels = Pixels(bitmap);
        // 24 by 18 pt at scale 1 in a 24 px slot: 3 empty rows above and below
        for (var x = 0; x < 24; x++)
        {
            Assert.Equal(0, Alpha(pixels, 24, x, 0));
            Assert.Equal(0, Alpha(pixels, 24, x, 23));
        }
        var rows = Enumerable.Range(0, 24).Where(y => Enumerable.Range(0, 24).Any(x => Alpha(pixels, 24, x, y) > 0)).ToList();
        Assert.InRange(rows.Min(), 2, 4);
        Assert.InRange(rows.Max(), 19, 21);
    }

    [Fact]
    public void HolesAreTransparentNotWhite()
    {
        // wide eyes of the alert pose, in a big frame so a pixel sits fully inside a hole
        const int side = 240; // 10 px per point
        using var bitmap = BenchRunnerArt.Render(RunnerPose.Alert, 0, side);
        var pixels = Pixels(bitmap);
        var top = (side - 180) / 2;
        int PixelX(double pt) => (int)(pt * 10);
        int PixelY(double pt) => top + (int)((18 - pt) * 10);

        Assert.Equal(0, Alpha(pixels, side, PixelX(10.9), PixelY(12.6))); // inside the eye
        Assert.Equal(0, Alpha(pixels, side, PixelX(13.6), PixelY(12.6)));
        Assert.Equal(255, Alpha(pixels, side, PixelX(12.2), PixelY(12.6))); // the backrest between the eyes
        Assert.Equal(255, Alpha(pixels, side, PixelX(6), PixelY(14.4))); // the backrest above the eyes
    }

    [Fact]
    public void HolesStayPartlyTransparentAtTrayScale()
    {
        using var bitmap = BenchRunnerArt.Render(RunnerPose.Alert, 0, 32);
        var pixels = Pixels(bitmap);
        const double scale = 32 / 24.0;
        var top = (32 - 18 * scale) / 2;
        var x = (int)(10.9 * scale);
        var y = (int)(top + (18 - 12.6) * scale);
        var min = Enumerable.Range(x - 1, 3).SelectMany(px => Enumerable.Range(y - 1, 3).Select(py => Alpha(pixels, 32, px, py))).Min();
        Assert.True(min < 128, $"the eye left alpha {min} everywhere around its centre");
    }

    [Fact]
    public void IconsAreLazyCachedAndDestroyedWhenTheSlotChanges()
    {
        using var icons = new RunnerIcons(20, lightTaskbar: false);
        Assert.Equal(0, icons.CachedCount);

        var first = icons.Get(RunnerPose.Running, 0);
        Assert.NotEqual(IntPtr.Zero, first);
        Assert.Equal(1, icons.CachedCount);
        Assert.Equal(first, icons.Get(RunnerPose.Running, 0));
        Assert.NotEqual(first, icons.Get(RunnerPose.Running, 1));
        Assert.Equal(first, icons.Get(RunnerPose.Running, 6)); // frames wrap
        Assert.Equal(2, icons.CachedCount);

        icons.SetSlot(20, false); // nothing changed
        Assert.Equal(2, icons.CachedCount);

        icons.SetSlot(24, false);
        Assert.Equal(0, icons.CachedCount);
        Assert.Equal(24, icons.Side);
        icons.Get(RunnerPose.Alert, 0);
        icons.SetSlot(24, true);
        Assert.Equal(0, icons.CachedCount);
        Assert.True(icons.LightTaskbar);
    }

    [Fact]
    public void TheHiconIsTheRenderedFrameAndNotUpsideDown()
    {
        using var icons = new RunnerIcons(32, lightTaskbar: false);
        var handle = icons.Get(RunnerPose.Alert, 0);

        using var icon = Icon.FromHandle(handle);
        using var roundTrip = icon.ToBitmap();
        using var expected = RunnerIcons.RenderTinted(RunnerPose.Alert, 0, 32, false);
        Assert.Equal(32, roundTrip.Width);

        var got = Pixels(roundTrip);
        var want = Pixels(expected);
        var wantFlipped = new byte[want.Length];
        for (var y = 0; y < 32; y++)
            Array.Copy(want, y * 32 * 4, wantFlipped, (31 - y) * 32 * 4, 32 * 4);

        int Difference(byte[] a, byte[] b)
        {
            var total = 0;
            for (var i = 3; i < a.Length; i += 4) total += Math.Abs(a[i] - b[i]);
            return total;
        }

        Assert.True(Difference(got, want) < Difference(got, wantFlipped) / 10, "the icon does not match the frame");
    }

    [Fact]
    public void ContactSheetsAreNinetySixPixelsTall()
    {
        var dir = TempDir();
        var files = RunnerIcons.ExportContactSheets(dir, 20, light: false);
        Assert.Equal(6, files.Count);
        foreach (var file in files)
        {
            using var sheet = new Bitmap(file);
            Assert.Equal(96, sheet.Height);
        }
        using var running = new Bitmap(Path.Combine(dir, "sheet-running.png"));
        Assert.Equal(96 * 6, running.Width);
    }

    [Fact]
    public void ExportForTheLead()
    {
        // BENCHBAR_TRAY_EXPORT_DIR=<dir> writes the frames and sheets for both taskbar themes.
        var root = Environment.GetEnvironmentVariable("BENCHBAR_TRAY_EXPORT_DIR");
        if (string.IsNullOrEmpty(root)) return;
        foreach (var (name, light) in new[] { ("dark", false), ("light", true) })
        {
            var dir = Path.Combine(root, name);
            RunnerIcons.ExportPng(dir, 20, light);
            RunnerIcons.ExportContactSheets(Path.Combine(dir, "sheets"), 20, light);
            RunnerIcons.ExportContactSheets(Path.Combine(dir, "sheets"), 20, light, vector: false);
        }
    }

    [Theory]
    [InlineData(96u, 16)]
    [InlineData(120u, 20)]
    [InlineData(144u, 24)]
    [InlineData(192u, 32)]
    public void IconSideFollowsTheSystemMetric(uint dpi, int side) =>
        Assert.Equal(side, TrayMetrics.IconSide(dpi));

    [Fact]
    public void TheTaskbarProbesReturnSomething()
    {
        Assert.True(TrayMetrics.TaskbarDpi() >= 96);
        _ = TaskbarTheme.IsLight();
        _ = TrayMetrics.ReduceMotion();
    }
}
