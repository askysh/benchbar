using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace BenchBar.Tray.Core;

/// <summary>
/// A runner: the frames for each pose. <see cref="Render"/> gives a square, transparent bitmap of the tray slot's
/// size; a template runner is black ink on transparent (only alpha counts, the tray tints it), any other keeps its colours.
/// </summary>
public interface IRunnerArt
{
    string Id { get; }

    string Name { get; }

    string? Author { get; }

    /// <summary>True: only the alpha of the frames counts and the tray paints them in the taskbar's text colour.</summary>
    bool IsTemplate { get; }

    /// <summary>The frames of a pose, at least 1. A pose a custom runner left out has its running frames.</summary>
    int FrameCount(RunnerPose pose);

    /// <summary>One frame as a <paramref name="side"/> by <paramref name="side"/> bitmap, 32 bpp straight alpha, not tinted. The caller disposes it.</summary>
    Bitmap Render(RunnerPose pose, int frame, int side);
}

/// <summary>A runner drawn in code.</summary>
public sealed class BuiltInRunner(
    string id, string name, Func<RunnerPose, int> frameCount, Func<RunnerPose, int, int, Bitmap> render) : IRunnerArt
{
    public string Id { get; } = id;
    public string Name { get; } = name;
    public string? Author => "BenchBar";
    public bool IsTemplate => true;
    public int FrameCount(RunnerPose pose) => frameCount(pose);
    public Bitmap Render(RunnerPose pose, int frame, int side) => render(pose, frame, side);
}

/// <summary>The two runners that ship with BenchBar. Their ids are reserved.</summary>
public static class BuiltInRunners
{
    public const string BenchId = "bench";
    public const string CupId = "cup";

    public static IRunnerArt Bench { get; } = new BuiltInRunner(BenchId, "Bench", BenchRunnerArt.FrameCount, BenchRunnerArt.Render);

    public static IRunnerArt Cup { get; } = new BuiltInRunner(CupId, "Coffee cup", CupRunnerArt.FrameCount, CupRunnerArt.Render);

    public static IReadOnlyList<IRunnerArt> All { get; } = [Bench, Cup];

    public static bool IsReserved(string id) =>
        id.Equals(BenchId, StringComparison.OrdinalIgnoreCase) || id.Equals(CupId, StringComparison.OrdinalIgnoreCase);
}

/// <summary>Painting a template frame in one colour.</summary>
public static class RunnerTint
{
    /// <summary>White on a dark taskbar.</summary>
    public static readonly Color Dark = Color.FromArgb(255, 255, 255);

    /// <summary>Near black on a light taskbar.</summary>
    public static readonly Color Light = Color.FromArgb(0x1B, 0x1B, 0x1B);

    public static Color For(bool lightBackground) => lightBackground ? Light : Dark;

    /// <summary>Sets the colour of every pixel to <paramref name="tint"/>, alpha kept (in place).</summary>
    public static void Apply(Bitmap bitmap, Color tint)
    {
        var width = bitmap.Width;
        var height = bitmap.Height;
        var data = bitmap.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        try
        {
            var row = new byte[width * 4];
            for (var y = 0; y < height; y++)
            {
                var line = data.Scan0 + y * data.Stride;
                Marshal.Copy(line, row, 0, row.Length);
                for (var x = 0; x < width; x++)
                {
                    row[x * 4] = tint.B;
                    row[x * 4 + 1] = tint.G;
                    row[x * 4 + 2] = tint.R;
                }
                Marshal.Copy(row, 0, line, row.Length);
            }
        }
        finally
        {
            bitmap.UnlockBits(data);
        }
    }

    /// <summary>The frame as the tray shows it: tinted for a template runner, as drawn otherwise.</summary>
    public static Bitmap Frame(IRunnerArt art, RunnerPose pose, int frame, int side, bool lightBackground)
    {
        var bitmap = art.Render(pose, frame, side);
        if (art.IsTemplate) Apply(bitmap, For(lightBackground));
        return bitmap;
    }
}
