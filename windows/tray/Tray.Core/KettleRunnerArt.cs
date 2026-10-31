using System.Drawing;

namespace BenchBar.Tray.Core;

/// <summary>
/// The built in Kettle runner, ported from macos/BenchBar/Runners/KettleRunnerArt.swift: a round kettle with a face,
/// its spout to the right. It boils instead of running. Same geometry, frame counts and marks as the Mac's.
/// Drawn in black; only the alpha counts, the tray tints it.
/// </summary>
public static class KettleRunnerArt
{
    private static readonly PointF Pivot = new(8, 1.2f);
    private static readonly PointF[] EyePoints = [new(6.4f, 6.4f), new(9.6f, 6.4f)];
    private static readonly PointF SpoutTip = new(16.8f, 10);

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
                case RunnerPose.Starting: Warming(c, frame); break;
                case RunnerPose.Running: Boiling(c, frame); break;
                case RunnerPose.Crashed: BoilingOver(c, frame); break;
                case RunnerPose.Alert: Alert(c); break;
                default: Question(c); break;
            }
        });
    }

    /// <summary>The pot, the spout and the handle; the lid sits <paramref name="lid"/> points up.</summary>
    private static void Body(RunnerCanvas c, RunnerCanvas.EyeStyle eyes, float lid = 0, float lidTilt = 0)
    {
        // the pot, wider at the bottom
        c.Shape(
        [
            new PointF(2.6f, 1.2f), new PointF(13.4f, 1.2f), new PointF(13.8f, 2.2f),
            new PointF(12.6f, 9.4f), new PointF(3.4f, 9.4f), new PointF(2.2f, 2.2f),
        ]);
        c.Fill(new RectangleF(2.2f, 1.2f, 11.6f, 4), 1.6f);
        c.Fill(new RectangleF(3.2f, 6.2f, 9.6f, 3.6f), 1.8f);
        // the spout, rising to the right
        c.Shape(
        [
            new PointF(12.4f, 2.2f), new PointF(15.4f, 7.2f), new PointF(17.4f, 9.4f),
            new PointF(16.2f, 10.6f), new PointF(13.8f, 8.8f), new PointF(12.4f, 7.6f),
        ]);
        // the handle, an arch over the lid
        c.Arc(new PointF(8, 9.6f), 4.4f, 0.12f * MathF.PI, 0.76f * MathF.PI, 1.3f);
        // the lid and its knob
        c.Transformed(lidTilt, new PointF(8, 10), new PointF(0, lid), () =>
        {
            c.Fill(new RectangleF(5.2f, 9.4f, 5.6f, 1.4f), 0.7f);
            c.Dot(new PointF(8, 11.4f), 0.8f);
        });
        c.Eyes(EyePoints, eyes);
    }

    /// <summary>A curl of steam rising from the spout; <paramref name="t"/> from 0 (at the spout) to 1 (gone).</summary>
    private static void Wisp(RunnerCanvas c, float t, float x, float length = 3.2f, bool flip = false)
    {
        var y = SpoutTip.Y + 1.4f + 4 * t;
        var sway = flip ? -0.7f : 0.7f;
        c.Line(
        [
            new PointF(x, y),
            new PointF(x + sway, y + length * 0.35f),
            new PointF(x - sway, y + length * 0.7f),
            new PointF(x, y + length),
        ], 0.9f);
    }

    private static void Boiling(RunnerCanvas c, int i)
    {
        // the lid rattles on every other frame, the pot jiggles
        var lid = i % 2 == 0 ? 0f : 0.9f;
        var tilt = i % 4 == 1 ? 8f : (i % 4 == 3 ? -8f : 0f);
        var jiggle = i % 2 == 0 ? -0.25f : 0.25f;
        c.Transformed(0, Pivot, new PointF(jiggle, 0), () => Body(c, RunnerCanvas.EyeStyle.Open, lid, tilt));
        // two curls half a cycle apart, so one leaves as the other arrives
        for (var k = 0; k < 2; k++)
        {
            var t = (i / 6f + k / 2f) % 1;
            Wisp(c, t, 18.6f + k * 2.2f, flip: (i + k) % 2 == 0);
        }
    }

    private static void Warming(RunnerCanvas c, int i)
    {
        Body(c, RunnerCanvas.EyeStyle.Open);
        // one small wisp at a time, and a little heat under the pot
        Wisp(c, i / 10f, 18.8f, 2, i % 2 == 0);
        var shimmer = i % 2 == 0 ? 0f : 0.6f;
        foreach (var x in new[] { 5f, 8f, 11f })
            c.Line([new PointF(x - 0.6f + shimmer, 0.2f), new PointF(x + 0.6f + shimmer, 0.2f)], 0.6f);
    }

    private static void Sleeping(RunnerCanvas c, int i)
    {
        // a cold kettle: no steam, the lid shut, breathing a little
        var breath = i % 2 == 0 ? 0f : 0.25f;
        c.Transformed(0, Pivot, new PointF(0, breath), () => Body(c, RunnerCanvas.EyeStyle.Closed));
        BenchRunnerArt.SleepMarks(c, i, 18.2f);
    }

    private static readonly (float Tilt, float Lid, float LidTilt, RunnerCanvas.EyeStyle Eyes)[] OverPoses =
    [
        (-6, 1.0f, 10, RunnerCanvas.EyeStyle.Wide),
        (7, 3.4f, -24, RunnerCanvas.EyeStyle.Crossed),
        (-7, 5.0f, 30, RunnerCanvas.EyeStyle.Crossed),
        (4, 2.0f, -12, RunnerCanvas.EyeStyle.Crossed),
    ];

    private static readonly PointF[][] Spray =
    [
        [new(18.4f, 11)],
        [new(18.6f, 12), new(20.4f, 10.4f)],
        [new(19.4f, 13), new(21.6f, 11), new(20.4f, 8.4f)],
        [new(20.6f, 9.2f), new(22.4f, 7)],
    ];

    private static void BoilingOver(RunnerCanvas c, int i)
    {
        // it shakes, the lid pops off and water spits out of the spout
        var p = OverPoses[i];
        c.Transformed(p.Tilt, Pivot, PointF.Empty, () => Body(c, p.Eyes, p.Lid, p.LidTilt));
        for (var n = 0; n < Spray[i].Length; n++)
            c.Dot(Spray[i][n], n == 0 ? 0.8f : 0.6f);
    }

    private static void Alert(RunnerCanvas c)
    {
        Body(c, RunnerCanvas.EyeStyle.Wide, 0.6f);
        c.Exclamation(20.6f);
    }

    private static void Question(RunnerCanvas c)
    {
        c.Transformed(-5, Pivot, PointF.Empty, () => Body(c, RunnerCanvas.EyeStyle.Open));
        c.Question(20.6f);
    }
}
