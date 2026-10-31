using System.Drawing;

namespace BenchBar.Tray.Core;

/// <summary>
/// The built in Server rack runner, ported from macos/BenchBar/Runners/ServerRunnerArt.swift: three units with a face
/// on the top one, whose lights and outgoing data carry the state. Same geometry, frame counts and marks as the Mac's.
/// Drawn in black; only the alpha counts, the tray tints it.
/// </summary>
public static class ServerRunnerArt
{
    private static readonly PointF Pivot = new(8.8f, 0.6f);
    private static readonly PointF[] EyePoints = [new(6.9f, 14), new(9.7f, 14)];

    /// <summary>Bottom and height of each unit, from the bottom up.</summary>
    private static readonly (float Y, float Height)[] Units = [(1.6f, 4.4f), (6.7f, 4.4f), (11.8f, 4.6f)];

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
                case RunnerPose.Starting: Booting(c, frame); break;
                case RunnerPose.Running: Serving(c, frame); break;
                case RunnerPose.Crashed: Failing(c, frame); break;
                case RunnerPose.Alert: Alert(c); break;
                default: Question(c); break;
            }
        });
    }

    /// <summary>
    /// The rack: feet, three units, a light per unit (<paramref name="lit"/>, bottom up), a drive slot on the two
    /// lower units and the face on the top one. The middle unit can stick out by <paramref name="drawer"/> points.
    /// </summary>
    private static void Body(RunnerCanvas c, RunnerCanvas.EyeStyle eyes, bool[] lit, float drawer = 0)
    {
        c.Fill(new RectangleF(4.8f, 0.6f, 1.4f, 1.4f), 0.3f);
        c.Fill(new RectangleF(11.4f, 0.6f, 1.4f, 1.4f), 0.3f);
        for (var n = 0; n < Units.Length; n++)
        {
            var unit = Units[n];
            var x = n == 1 ? 4 + drawer : 4;
            c.Fill(new RectangleF(x, unit.Y, 9.6f, unit.Height), 1);
            var mid = unit.Y + unit.Height / 2;
            if (n < 2) c.CutLine([new PointF(x + 1.5f, mid), new PointF(x + 5.2f, mid)], 0.8f);
            if (lit[n]) c.CutDot(new PointF(x + 7.7f, n == 2 ? mid - 0.9f : mid), 0.85f);
        }
        c.Eyes(EyePoints, eyes);
    }

    /// <summary>Dashes of data leaving to the right, <paramref name="i"/> of 6.</summary>
    private static void Data(RunnerCanvas c, int i)
    {
        float[] lanes = [3.8f, 8.9f];
        for (var lane = 0; lane < lanes.Length; lane++)
        {
            for (var k = 0; k < 2; k++)
            {
                var x = 15 + (i * 1.4f + k * 4.2f + lane * 2.1f) % 8.4f;
                c.Line([new PointF(x, lanes[lane]), new PointF(Math.Min(x + 1.6f, 23.4f), lanes[lane])], 1);
            }
        }
    }

    private static void Serving(RunnerCanvas c, int i)
    {
        // the lights blink out of step, the data streams out
        var lit = Enumerable.Range(0, 3).Select(n => (i + n * 2) % 3 != 0).ToArray();
        Body(c, RunnerCanvas.EyeStyle.Open, lit);
        Data(c, i);
    }

    private static void Booting(RunnerCanvas c, int i)
    {
        // the units light up one by one, bottom first
        var on = i % 4;
        Body(c, on == 3 ? RunnerCanvas.EyeStyle.Open : RunnerCanvas.EyeStyle.Closed,
            Enumerable.Range(0, 3).Select(n => n < on).ToArray());
    }

    private static void Sleeping(RunnerCanvas c, int i)
    {
        // every light out; the bottom one breathes slowly
        Body(c, RunnerCanvas.EyeStyle.Closed, [i == 1, false, false]);
        BenchRunnerArt.SleepMarks(c, i, 16.4f);
    }

    private static readonly (float Lean, float Drawer, RunnerCanvas.EyeStyle Eyes)[] FailPoses =
    [
        (-3, 0.8f, RunnerCanvas.EyeStyle.Wide),
        (4, 2.4f, RunnerCanvas.EyeStyle.Crossed),
        (-4, 3.2f, RunnerCanvas.EyeStyle.Crossed),
        (2, 1.8f, RunnerCanvas.EyeStyle.Crossed),
    ];

    private static void Failing(RunnerCanvas c, int i)
    {
        // it shakes, the middle drive jams out and sparks fly
        var p = FailPoses[i];
        c.Transformed(p.Lean, Pivot, PointF.Empty, () => Body(c, p.Eyes, [i % 2 == 0, true, i % 2 == 1], p.Drawer));
        if (i == 1 || i == 2)
        {
            var x = 14.6f + p.Drawer;
            c.Line([new PointF(x, 10.6f), new PointF(x + 1.6f, 12)], 0.8f);
            c.Line([new PointF(x + 0.4f, 8.8f), new PointF(x + 2.2f, 8.8f)], 0.8f);
            c.Line([new PointF(x, 7.2f), new PointF(x + 1.6f, 5.8f)], 0.8f);
        }
    }

    private static void Alert(RunnerCanvas c)
    {
        Body(c, RunnerCanvas.EyeStyle.Wide, [true, true, true]);
        c.Exclamation(19.4f);
    }

    private static void Question(RunnerCanvas c)
    {
        c.Transformed(-5, Pivot, PointF.Empty, () => Body(c, RunnerCanvas.EyeStyle.Open, [false, true, false]));
        c.Question(19.4f);
    }
}
