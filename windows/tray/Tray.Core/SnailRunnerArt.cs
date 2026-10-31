using System.Drawing;

namespace BenchBar.Tray.Core;

/// <summary>
/// The built in Snail runner, ported from macos/BenchBar/Runners/SnailRunnerArt.swift: a snail with a spiral shell
/// and eyes on stalks, heading right. It hurries while the bench runs and hides in its shell when it stops. Same
/// geometry, frame counts and marks as the Mac's. Drawn in black; only the alpha counts, the tray tints it.
/// </summary>
public static class SnailRunnerArt
{
    private static readonly PointF ShellCenter = new(8, 7.6f);
    private const float ShellRadius = 4.9f;

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
                case RunnerPose.Starting: Waking(c, frame); break;
                case RunnerPose.Running: Crawling(c, frame); break;
                case RunnerPose.Crashed: Rolling(c, frame); break;
                case RunnerPose.Alert: Alert(c); break;
                default: Question(c); break;
            }
        });
    }

    /// <summary>The shell around <paramref name="center"/>, its spiral cut out, turned <paramref name="turn"/> degrees.</summary>
    private static void Shell(RunnerCanvas c, PointF center, float turn = 0)
    {
        c.Dot(center, ShellRadius);
        c.Transformed(turn, center, PointF.Empty, () =>
        {
            c.CutArc(new PointF(center.X + 0.3f, center.Y), 2.9f, 0.5f * MathF.PI, 1.55f * MathF.PI, 0.8f);
            c.CutArc(new PointF(center.X + 0.6f, center.Y + 0.3f), 1.3f, 1.5f * MathF.PI, 1.4f * MathF.PI, 0.8f);
        });
    }

    /// <summary>
    /// The foot and the head. <paramref name="reach"/> moves the head forward (negative pulls it in),
    /// <paramref name="stalk"/> scales the stalks (0 hides them), <paramref name="sway"/> tips them back in degrees.
    /// </summary>
    private static void Body(RunnerCanvas c, float reach = 0, float stalk = 1, float sway = 0, float eyes = 0.85f, bool droop = false)
    {
        var front = 16.6f + reach;
        c.Fill(new RectangleF(2.2f, 0.6f, front - 2.2f, 2.4f), 1.2f);
        c.Fill(new RectangleF(front - 3.4f, 0.6f, 3.4f, 6.2f), 1.6f);
        if (stalk <= 0) return;
        PointF[] bases = [new(front - 2.6f, 6.2f), new(front - 1.0f, 6.2f)];
        for (var n = 0; n < bases.Length; n++)
        {
            var b = bases[n];
            var angle = ((n == 0 ? -6 : 22) - sway) * MathF.PI / 180;
            var length = 3.8f * stalk;
            var tip = new PointF(b.X + length * MathF.Sin(angle), b.Y + length * MathF.Cos(angle));
            if (droop && n == 1)
            {
                // one stalk bends over, puzzled
                var bend = new PointF(b.X + 0.6f, b.Y + 3.2f);
                tip = new PointF(bend.X + 1.6f, bend.Y - 0.6f);
                c.Line([b, bend, tip], 0.9f);
            }
            else
            {
                c.Line([b, tip], 0.9f);
            }
            c.Dot(tip, eyes);
        }
    }

    private static void Crawling(RunnerCanvas c, int i)
    {
        // the foot stretches and gathers, the shell rides along, the stalks stream back
        var s = (float)Math.Sin(2 * Math.PI * i / 6);
        Body(c, 1.0f + 1.0f * s, sway: 14 + 6 * s);
        Shell(c, new PointF(ShellCenter.X + 0.4f * s, ShellCenter.Y + 0.3f * Math.Abs(s)), 4 * s);
        // speed lines behind
        var drift = (i % 3) * 0.6f;
        c.Line([new PointF(0.2f + drift, 10.6f), new PointF(1.6f + drift, 10.6f)], 0.8f);
        c.Line([new PointF(0.4f + drift, 7.8f), new PointF(1.6f + drift, 7.8f)], 0.8f);
    }

    private static void Waking(RunnerCanvas c, int i)
    {
        // the head comes out, then the stalks unroll
        var t = i / 5f;
        Body(c, -4 + 4 * Math.Min(1, t * 1.6f), Math.Max(0, t * 1.4f - 0.4f));
        Shell(c, ShellCenter);
    }

    private static void Sleeping(RunnerCanvas c, int i)
    {
        // all in the shell, which rests on the ground and breathes
        var breath = i % 2 == 0 ? 0f : 0.3f;
        Shell(c, new PointF(ShellCenter.X, 5.2f + breath));
        c.Fill(new RectangleF(3.4f, 0.6f, 9.6f, 1.2f), 0.6f);
        BenchRunnerArt.SleepMarks(c, i, 15);
    }

    private static void Rolling(RunnerCanvas c, int i)
    {
        // it pulls in and the shell rolls over, a quarter turn a frame
        var center = new PointF(9 + i * 1.2f, 5.6f + (i % 2 == 0 ? 0.6f : 0));
        Shell(c, center, i * 90);
        c.Line([new PointF(center.X - 6.6f, 0.6f), new PointF(center.X - 5.2f, 0.6f)], 0.8f);
        if (i % 2 == 1)
        {
            c.Line([new PointF(center.X + 5.6f, 9.6f), new PointF(center.X + 6.8f, 10.8f)], 0.8f);
            c.Line([new PointF(center.X + 6, 7.4f), new PointF(center.X + 7.4f, 7.4f)], 0.8f);
        }
    }

    private static void Alert(RunnerCanvas c)
    {
        Body(c, -0.6f, 1.15f, 8, 1.05f);
        Shell(c, ShellCenter);
        c.Exclamation(20.6f);
    }

    private static void Question(RunnerCanvas c)
    {
        Body(c, -0.6f, droop: true);
        Shell(c, ShellCenter);
        c.Question(20.8f);
    }
}
