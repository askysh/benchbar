using System.Drawing;
using System.Drawing.Imaging;
using PixelFormat = System.Drawing.Imaging.PixelFormat;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>Runner frames as WPF images, for the Runner menu.</summary>
internal static class RunnerImages
{
    /// <summary>One frame, tinted like the tray would on that background, as a frozen image.</summary>
    public static BitmapSource Frame(IRunnerArt art, RunnerPose pose, int frame, int side, bool lightBackground)
    {
        using var bitmap = RunnerSet.RenderPreview(art, side, lightBackground, pose, frame);
        var data = bitmap.LockBits(new Rectangle(0, 0, side, side), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            var bytes = new byte[side * 4 * side];
            for (var y = 0; y < side; y++)
                Marshal.Copy(data.Scan0 + y * data.Stride, bytes, y * side * 4, side * 4);
            var image = BitmapSource.Create(side, side, 96, 96, System.Windows.Media.PixelFormats.Bgra32, null, bytes, side * 4);
            image.Freeze();
            return image;
        }
        finally
        {
            bitmap.UnlockBits(data);
        }
    }

    /// <summary>All running frames of a runner, in play order.</summary>
    public static IReadOnlyList<BitmapSource> RunningFrames(IRunnerArt art, int side, bool lightBackground) =>
        Enumerable.Range(0, art.FrameCount(RunnerPose.Running)).Select(f => Frame(art, RunnerPose.Running, f, side, lightBackground)).ToList();
}
