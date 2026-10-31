using System.Drawing;

namespace BenchBar.Tray.Core;

/// <summary>
/// The built in Rocket runner, ported from macos/BenchBar/Runners/RocketRunnerArt.swift: a small rocket with fins and
/// a round window for an eye. It flies up to the right, smokes on the pad while it starts and tumbles when it crashes.
/// Same geometry, frame counts and marks as the Mac's. Drawn in black; only the alpha counts, the tray tints it.
/// </summary>
public static class RocketRunnerArt
{
    private enum Window { Open, Wide, Closed, Crossed }

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
                case RunnerPose.Starting: Countdown(c, frame); break;
                case RunnerPose.Running: Flying(c, frame); break;
                case RunnerPose.Crashed: Tumbling(c, frame); break;
                case RunnerPose.Alert: Alert(c); break;
                default: Question(c); break;
            }
        });
    }

    /// <summary>
    /// The rocket standing up with its middle at <paramref name="center"/>, turned <paramref name="lean"/> degrees
    /// clockwise; a flame <paramref name="flame"/> points long under it.
    /// </summary>
    private static void Rocket(RunnerCanvas c, PointF center, float lean = 0, float flame = 0, Window window = Window.Open)
    {
        c.Transformed(lean, PointF.Empty, center, () =>
        {
            if (flame > 0) c.Shape([new PointF(-1.5f, -5.4f), new PointF(1.5f, -5.4f), new PointF(0, -5.6f - flame)]);
            c.Fill(new RectangleF(-2.6f, -4.4f, 5.2f, 8.8f), 1.6f);
            c.Shape(
            [
                new PointF(-2.6f, 3.0f), new PointF(2.6f, 3.0f), new PointF(1.7f, 5.6f),
                new PointF(0, 7.4f), new PointF(-1.7f, 5.6f),
            ]);
            c.Shape([new PointF(-2.4f, -0.8f), new PointF(-5.0f, -5.4f), new PointF(-2.4f, -4.0f)]);
            c.Shape([new PointF(2.4f, -0.8f), new PointF(5.0f, -5.4f), new PointF(2.4f, -4.0f)]);
            c.Fill(new RectangleF(-1.5f, -5.6f, 3.0f, 1.6f), 0.3f);
            var eye = new PointF(0, 1.4f);
            switch (window)
            {
                case Window.Open: c.CutDot(eye, 1.3f); break;
                case Window.Wide: c.CutDot(eye, 1.6f); break;
                case Window.Closed: c.CutLine([new PointF(-0.9f, 1.2f), new PointF(0.9f, 1.2f)], 0.7f); break;
                case Window.Crossed:
                    c.CutLine([new PointF(-0.9f, 0.5f), new PointF(0.9f, 2.3f)], 0.6f);
                    c.CutLine([new PointF(-0.9f, 2.3f), new PointF(0.9f, 0.5f)], 0.6f);
                    break;
            }
        });
    }

    private static readonly float[] Flames = [3.2f, 4.4f, 3.6f, 4.8f, 3.0f, 4.2f];

    private static void Flying(RunnerCanvas c, int i)
    {
        var shake = i % 2 == 0 ? 0.25f : -0.25f;
        Rocket(c, new PointF(13 + shake, 9.6f - shake), 45, Flames[i]);
        // puffs of exhaust drifting away down to the left
        for (var k = 0; k < 3; k++)
        {
            var t = (i / 6f + k / 3f) % 1;
            var d = 9.8f + 4.4f * t;
            c.Dot(new PointF(13 - d * 0.707f, 9.6f - d * 0.707f), 0.6f + 0.8f * t);
        }
    }

    private static void Countdown(RunnerCanvas c, int i)
    {
        // on the pad, rumbling, the smoke spreading out at its feet
        var shake = i % 2 == 0 ? 0.2f : -0.2f;
        Rocket(c, new PointF(10 + shake, 7.4f), flame: i % 2 == 0 ? 0.8f : 1.4f);
        float spread = i % 3;
        foreach (var side in new[] { -1f, 1f })
        {
            c.Dot(new PointF(10 + side * (3.6f + spread * 0.9f), 1.4f), 0.8f + spread * 0.25f);
            c.Dot(new PointF(10 + side * (5.8f + spread * 1.1f), 1.2f), 0.6f + spread * 0.2f);
        }
    }

    private static void Sleeping(RunnerCanvas c, int i)
    {
        // parked on its fins, engine cold
        var breath = i % 2 == 0 ? 0f : 0.25f;
        Rocket(c, new PointF(9, 6.0f + breath), window: Window.Closed);
        BenchRunnerArt.SleepMarks(c, i, 15.6f);
    }

    private static readonly (PointF Center, float Lean, float Flame, Window Eye)[] TumblePoses =
    [
        (new PointF(12, 10), 40, 1.6f, Window.Wide),
        (new PointF(13, 9), 110, 0, Window.Crossed),
        (new PointF(13.6f, 7.6f), 190, 0.8f, Window.Crossed),
        (new PointF(13, 8.6f), 270, 0, Window.Crossed),
    ];

    private static void Tumbling(RunnerCanvas c, int i)
    {
        // the engine coughs, it flips over and falls, smoke behind it
        var p = TumblePoses[i];
        Rocket(c, p.Center, p.Lean, p.Flame, p.Eye);
        c.Dot(new PointF(4.4f, 11 - i * 0.6f), 1.2f);
        c.Dot(new PointF(2.2f, 13 - i * 0.4f), 0.8f);
    }

    private static void Alert(RunnerCanvas c)
    {
        Rocket(c, new PointF(9, 6.0f), window: Window.Wide);
        c.Exclamation(18.6f);
    }

    private static void Question(RunnerCanvas c)
    {
        Rocket(c, new PointF(9, 6.0f), -8);
        c.Question(18.6f);
    }
}
