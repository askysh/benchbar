using System.Drawing;

namespace BenchBar.Tray.Core;

/// <summary>
/// The built in Coffee cup runner, ported from <c>CupRunnerArt</c> in macos/BenchBar/Runners/BuiltInRunners.swift:
/// a cup with a handle, a face and steam, two legs, running to the right. Same geometry, frame counts and marks.
/// Drawn in black; only the alpha counts, the tray tints it.
/// </summary>
public static class CupRunnerArt
{
    private const float HipY = 5.8f;
    private static readonly PointF Pivot = new(8.6f, 5.8f);
    private static readonly PointF[] EyePoints = [new(9.8f, 10.6f), new(12.2f, 10.6f)];

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
                case RunnerPose.Starting: Walking(c, frame, 6); break;
                case RunnerPose.Running: Running(c, frame, 6); break;
                case RunnerPose.Crashed: Stumbling(c, frame); break;
                case RunnerPose.Alert: Alert(c); break;
                default: Question(c); break;
            }
        });
    }

    /// <summary>The cup, its rim and its handle (on the left, the trailing side).</summary>
    private static void Body(RunnerCanvas c, RunnerCanvas.EyeStyle eyes)
    {
        c.FillShape(path =>
        {
            path.AddLine(new PointF(4.2f, 13.6f), new PointF(13.8f, 13.6f));
            path.AddLine(new PointF(13.8f, 13.6f), new PointF(12.6f, 6.6f));
            RunnerCanvas.QuadTo(path, new PointF(12.6f, 6.6f), new PointF(12.4f, 5.4f), new PointF(11.4f, 5.4f));
            path.AddLine(new PointF(11.4f, 5.4f), new PointF(6.6f, 5.4f));
            RunnerCanvas.QuadTo(path, new PointF(6.6f, 5.4f), new PointF(5.6f, 5.4f), new PointF(5.4f, 6.6f));
            path.CloseFigure();
        });
        c.Fill(new RectangleF(3.4f, 12.8f, 11.2f, 1.9f), 0.8f);
        // the handle: from 0.45 pi round the left side to 1.55 pi
        c.Arc(new PointF(4.4f, 9.6f), 2.3f, 0.45f * MathF.PI, 1.1f * MathF.PI, 1.4f);
        c.Eyes(EyePoints, eyes);
    }

    /// <summary>Two wisps of steam; <paramref name="lean"/> bends them back when running.</summary>
    private static void Steam(RunnerCanvas c, int phase, float lean)
    {
        float[] xs = [7.2f, 10.4f];
        for (var n = 0; n < xs.Length; n++)
        {
            var x = xs[n];
            var sway = (phase + n) % 2 == 0 ? 0.5f : -0.5f;
            c.Line(
            [
                new PointF(x, 15.4f),
                new PointF(x + sway - lean * 0.4f, 16.4f),
                new PointF(x - sway - lean, 17.5f),
            ], 0.9f);
        }
    }

    private static void Legs(RunnerCanvas c, (float, float) back, (float, float) front)
    {
        c.Leg(new PointF(7.4f, HipY), 2.8f, 3.0f, back.Item1, back.Item2, 1.4f);
        c.Leg(new PointF(10.6f, HipY), 2.8f, 3.0f, front.Item1, front.Item2, 1.4f);
    }

    private static void Running(RunnerCanvas c, int i, int n) =>
        c.Transformed(10, Pivot, new PointF(1.2f, Gait.Bob(i, n, 0.9f)), () =>
        {
            Legs(c, Gait.Run(i, n, 0.5), Gait.Run(i, n, 0));
            Body(c, RunnerCanvas.EyeStyle.Open);
            Steam(c, i, 1.6f);
        });

    private static void Walking(RunnerCanvas c, int i, int n) =>
        c.Transformed(3, Pivot, new PointF(0.6f, Gait.Bob(i, n, 0.4f)), () =>
        {
            Legs(c, Gait.Walk(i, n, 0.5), Gait.Walk(i, n, 0));
            Body(c, RunnerCanvas.EyeStyle.Open);
            Steam(c, i / 2, 0.4f);
        });

    private static void Sleeping(RunnerCanvas c, int i)
    {
        // sitting on the ground, legs folded out of sight, no steam: a cold cup
        var breath = i % 2 == 0 ? 0f : 0.3f;
        c.Transformed(0, Pivot, new PointF(0, -4.6f + breath), () => Body(c, RunnerCanvas.EyeStyle.Closed));
        BenchRunnerArt.SleepMarks(c, i, 16.6f);
    }

    private static readonly (float Lean, float Drop, (float, float) Back, (float, float) Front, RunnerCanvas.EyeStyle Eyes)[] StumblePoses =
    [
        (14, 0, (-30, 10), (25, 0), RunnerCanvas.EyeStyle.Open),
        (32, -0.8f, (-45, 30), (40, 5), RunnerCanvas.EyeStyle.Crossed),
        (46, -1.8f, (-55, 50), (55, 10), RunnerCanvas.EyeStyle.Crossed),
        (24, -0.6f, (-20, 20), (30, 0), RunnerCanvas.EyeStyle.Crossed),
    ];

    private static void Stumbling(RunnerCanvas c, int i)
    {
        var p = StumblePoses[i];
        c.Transformed(p.Lean, Pivot, new PointF(1.2f, p.Drop), () =>
        {
            Legs(c, p.Back, p.Front);
            Body(c, p.Eyes);
        });
        // a splash of coffee flies out on the big pitch
        if (i == 2)
        {
            c.Dot(new PointF(19.4f, 10.8f), 0.8f);
            c.Dot(new PointF(21.2f, 8.6f), 0.6f);
        }
    }

    private static void Alert(RunnerCanvas c)
    {
        Legs(c, (-8, 0), (8, 0));
        Body(c, RunnerCanvas.EyeStyle.Wide);
        c.Exclamation(20.4f);
    }

    private static void Question(RunnerCanvas c)
    {
        c.Transformed(-6, Pivot, PointF.Empty, () =>
        {
            Legs(c, (-8, 0), (8, 0));
            Body(c, RunnerCanvas.EyeStyle.Open);
        });
        c.Question(20.2f);
    }
}
