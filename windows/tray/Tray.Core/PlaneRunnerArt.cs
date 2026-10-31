using System.Drawing;

namespace BenchBar.Tray.Core;

/// <summary>
/// The built in Paper plane runner, ported from macos/BenchBar/Runners/PlaneRunnerArt.swift: a folded paper plane
/// seen from the side, nose to the right. It flies, rests on the ground and nose dives. Same geometry, frame counts
/// and marks as the Mac's. Drawn in black; only the alpha counts, the tray tints it.
/// </summary>
public static class PlaneRunnerArt
{
    /// <summary>The plane turns around its middle.</summary>
    private static readonly PointF Pivot = new(13, 9);

    public static int FrameCount(RunnerPose pose) => BenchRunnerArt.FrameCount(pose);

    public static Bitmap Render(RunnerPose pose, int frame, int side)
    {
        var count = FrameCount(pose);
        frame = ((frame % count) + count) % count;

        return RunnerCanvas.Render(side, c =>
        {
            switch (pose)
            {
                case RunnerPose.Sleeping: Sleeping(c, frame); break;
                case RunnerPose.Starting: TakingOff(c, frame); break;
                case RunnerPose.Running: Flying(c, frame); break;
                case RunnerPose.Crashed: Nosediving(c, frame); break;
                case RunnerPose.Alert: Alert(c); break;
                default: Question(c); break;
            }
        });
    }

    /// <summary>The upper wing and the keel, with the fold between them cut out.</summary>
    private static void Body(RunnerCanvas c)
    {
        c.Shape([new PointF(5.6f, 13.2f), new PointF(20.4f, 9.2f), new PointF(8.6f, 8.9f)]);
        c.Shape([new PointF(8.6f, 8.9f), new PointF(20.4f, 9.2f), new PointF(10, 5.6f)]);
        c.CutLine([new PointF(8.2f, 8.9f), new PointF(18.2f, 9.13f)], 0.6f);
    }

    /// <summary>The plane leaned <paramref name="pitch"/> degrees nose down and moved by <paramref name="offset"/>.</summary>
    private static void Plane(RunnerCanvas c, float pitch, PointF offset) =>
        c.Transformed(pitch, Pivot, offset, () => Body(c));

    private static float Height(int i) => 1.6f * (float)Math.Sin(2 * Math.PI * i / 6);

    private static void Flying(RunnerCanvas c, int i)
    {
        // up and down on a gentle wave, nose up while it climbs
        var pitch = -7 * (float)Math.Cos(2 * Math.PI * i / 6);
        Plane(c, pitch, new PointF(0, Height(i)));
        // the trail: where it was a moment ago
        for (var k = 1; k <= 3; k++)
        {
            var y = 9.6f + Height(i - k);
            var x = 6.2f - k * 1.9f;
            c.Line([new PointF(x, y), new PointF(x + 1.1f, y)], 0.9f);
        }
    }

    private static readonly float[] Hops = [0, 0.3f, 1.2f, 2.0f, 1.2f, 0.3f];

    private static void TakingOff(RunnerCanvas c, int i)
    {
        // a run along the ground with little hops, not quite airborne
        Plane(c, -4 - Hops[i] * 3, new PointF(-1, -5.4f + Hops[i]));
        var drift = (i % 3) * 0.8f;
        foreach (var x in new[] { 1.0f, 5.2f })
            c.Line([new PointF(x - drift, 0.6f), new PointF(x + 1.6f - drift, 0.6f)], 0.8f);
    }

    private static void Sleeping(RunnerCanvas c, int i)
    {
        // grounded, nose down a little, rocking now and then
        var rock = i % 2 == 0 ? 0f : 1.5f;
        Plane(c, 4 + rock, new PointF(-5, -5.6f));
        BenchRunnerArt.SleepMarks(c, i, 17);
    }

    private static readonly (float Pitch, PointF Offset)[] DivePoses =
    [
        (-14, new PointF(-1.6f, 1.4f)),
        (30, new PointF(-1.4f, -0.4f)),
        (62, new PointF(-3.6f, -2.0f)),
        (48, new PointF(-3.6f, -1.4f)),
    ];

    private static void Nosediving(RunnerCanvas c, int i)
    {
        // a stall, a dive, the nose hits the ground, a bounce back
        var p = DivePoses[i];
        Plane(c, p.Pitch, p.Offset);
        if (i == 2)
        {
            // the bump where the nose hit
            c.Line([new PointF(13.6f, 2.6f), new PointF(12.4f, 4.2f)], 0.8f);
            c.Line([new PointF(18.6f, 2.6f), new PointF(19.8f, 4.2f)], 0.8f);
            c.Line([new PointF(16.2f, 3.6f), new PointF(16.2f, 5.4f)], 0.8f);
        }
    }

    private static void Alert(RunnerCanvas c)
    {
        // stuck nose first in the ground
        Plane(c, 62, new PointF(-5.4f, -2.0f));
        c.Exclamation(19.6f);
    }

    private static void Question(RunnerCanvas c)
    {
        Plane(c, -4, new PointF(-5, 0));
        c.Question(19.6f);
    }
}
