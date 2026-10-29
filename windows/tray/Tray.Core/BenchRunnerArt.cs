using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace BenchBar.Tray.Core;

/// <summary>
/// The shared drawing helpers of macos/BenchBar/Runners/BuiltInRunners.swift
/// (RunnerCanvas), on GDI+. Coordinates are the Mac's: points on a 24 by 18
/// canvas, y up. The Graphics transform maps them to pixels, so the geometry
/// is the same numbers as the Swift source.
/// </summary>
internal sealed class RunnerCanvas
{
    public enum EyeStyle { Open, Wide, Closed, Crossed }

    private readonly Graphics _g;
    private readonly Brush _ink = Brushes.Black;
    private readonly Color _inkColor = Color.Black;

    public RunnerCanvas(Graphics g) => _g = g;

    private Pen NewPen(float width, Color color) => new(color, width)
    {
        StartCap = LineCap.Round,
        EndCap = LineCap.Round,
        LineJoin = LineJoin.Round,
    };

    /// <summary>Runs <paramref name="body"/> leaned <paramref name="lean"/> degrees clockwise around <paramref name="pivot"/>, then moved by <paramref name="offset"/>.</summary>
    public void Transformed(float lean, PointF pivot, PointF offset, Action body)
    {
        var state = _g.Save();
        _g.TranslateTransform(pivot.X + offset.X, pivot.Y + offset.Y);
        _g.RotateTransform(-lean); // y is up here, so a negative angle turns clockwise
        _g.TranslateTransform(-pivot.X, -pivot.Y);
        body();
        _g.Restore(state);
    }

    /// <summary>Draws with the clear blend mode: whatever is drawn becomes a hole (real alpha).</summary>
    private void Cutting(Action body)
    {
        _g.CompositingMode = CompositingMode.SourceCopy;
        try { body(); }
        finally { _g.CompositingMode = CompositingMode.SourceOver; }
    }

    public void Fill(RectangleF rect, float radius)
    {
        var r = Math.Min(radius, Math.Min(rect.Width, rect.Height) / 2);
        var d = r * 2;
        using var path = new GraphicsPath();
        path.AddArc(rect.X, rect.Y, d, d, 180, 90);
        path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
        path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
        path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        _g.FillPath(_ink, path);
    }

    public void Dot(PointF center, float radius) => Dot(_ink, center, radius);

    private void Dot(Brush brush, PointF center, float radius) =>
        _g.FillEllipse(brush, center.X - radius, center.Y - radius, radius * 2, radius * 2);

    public void Line(PointF[] points, float width) => Line(_inkColor, points, width);

    private void Line(Color color, PointF[] points, float width)
    {
        if (points.Length < 2) return;
        using var pen = NewPen(width, color);
        _g.DrawLines(pen, points);
    }

    /// <summary>
    /// A two part leg from <paramref name="hip"/>. Angles are degrees from
    /// straight down, positive swings forward (to the right). <paramref name="knee"/> bends the shin back.
    /// </summary>
    public void Leg(PointF hip, float thigh, float shin, float swing, float knee, float width)
    {
        var a = swing * MathF.PI / 180;
        var kneePoint = new PointF(hip.X + thigh * MathF.Sin(a), hip.Y - thigh * MathF.Cos(a));
        var b = (swing - knee) * MathF.PI / 180;
        var foot = new PointF(kneePoint.X + shin * MathF.Sin(b), kneePoint.Y - shin * MathF.Cos(b));
        Line([hip, kneePoint, foot], width);
    }

    /// <summary>Eyes in one of the face styles, cut out of whatever is under them.</summary>
    public void Eyes(PointF[] centers, EyeStyle style)
    {
        Cutting(() =>
        {
            foreach (var c in centers)
            {
                switch (style)
                {
                    case EyeStyle.Open: Dot(Brushes.Transparent, c, 0.8f); break;
                    case EyeStyle.Wide: Dot(Brushes.Transparent, c, 1.05f); break;
                    case EyeStyle.Closed:
                        Line(Color.Transparent, [new PointF(c.X - 0.6f, c.Y), new PointF(c.X + 0.6f, c.Y)], 0.7f);
                        break;
                    case EyeStyle.Crossed:
                        Line(Color.Transparent, [new PointF(c.X - 0.75f, c.Y - 0.75f), new PointF(c.X + 0.75f, c.Y + 0.75f)], 0.6f);
                        Line(Color.Transparent, [new PointF(c.X - 0.75f, c.Y + 0.75f), new PointF(c.X + 0.75f, c.Y - 0.75f)], 0.6f);
                        break;
                }
            }
        });
    }

    // marks beside the character

    /// <summary>A small "z" with its bottom left corner at <paramref name="origin"/>.</summary>
    public void SleepZ(PointF origin, float size) =>
        Line(
        [
            new PointF(origin.X, origin.Y + size),
            new PointF(origin.X + size, origin.Y + size),
            new PointF(origin.X, origin.Y),
            new PointF(origin.X + size, origin.Y),
        ], 0.9f);

    public void Exclamation(float x)
    {
        Line([new PointF(x, 15.8f), new PointF(x, 9.6f)], 2);
        Dot(new PointF(x, 6.6f), 1.1f);
    }

    public void Question(float x)
    {
        // the hook: an arc from the upper left round to the right, then down. In y up
        // terms the Mac sweeps clockwise from 0.95 pi to -0.4 pi, which is 171 degrees
        // with a sweep of -243 here.
        const float cy = 13.4f, r = 2.1f;
        using var path = new GraphicsPath();
        path.AddArc(x - r, cy - r, r * 2, r * 2, 171, -243);
        var end = new PointF(x + r * MathF.Cos(-0.4f * MathF.PI), cy + r * MathF.Sin(-0.4f * MathF.PI));
        path.AddLine(end, new PointF(x, 9.4f));
        using var pen = NewPen(1.6f, _inkColor);
        _g.DrawPath(pen, path);
        Dot(new PointF(x, 6.6f), 1);
    }
}

/// <summary>Leg positions for the gaits, as (swing, knee) pairs in degrees.</summary>
internal static class Gait
{
    public static (float Swing, float Knee) Run(int i, int count, double offset)
    {
        var phase = 2 * Math.PI * ((double)i / count + offset);
        return ((float)(38 * Math.Sin(phase)), (float)(55 * Math.Max(0, Math.Cos(phase))));
    }

    public static (float Swing, float Knee) Walk(int i, int count, double offset)
    {
        var phase = 2 * Math.PI * ((double)i / count + offset);
        return ((float)(20 * Math.Sin(phase)), (float)(18 * Math.Max(0, Math.Cos(phase))));
    }

    /// <summary>Vertical bounce of the body: highest between steps.</summary>
    public static float Bob(int i, int count, float amount) =>
        amount * (float)Math.Abs(Math.Sin(2 * Math.PI * i / count));
}

/// <summary>
/// The built in Bench runner, ported from <c>BenchRunnerArt</c> in the Mac app: a
/// park bench with two legs and a face, running to the right. Same geometry,
/// same frame counts, same marks (z, !, ?). Drawn in black; only the alpha
/// counts, the tray tints it.
/// </summary>
public static class BenchRunnerArt
{
    public const float Width = 24;
    public const float Height = 18;

    private const float HipY = 6.6f;
    private static readonly PointF Pivot = new(9, 6.6f);
    private static readonly PointF[] EyePoints = [new(10.9f, 12.6f), new(13.6f, 12.6f)];

    /// <summary>Frames per pose, the same as the Mac's.</summary>
    public static int FrameCount(RunnerPose pose) => pose switch
    {
        RunnerPose.Sleeping => 4,
        RunnerPose.Starting => 6,
        RunnerPose.Running => 6,
        RunnerPose.Crashed => 4,
        RunnerPose.Alert => 1,
        _ => 1,
    };

    /// <summary>
    /// One frame as a <paramref name="side"/> by <paramref name="side"/> bitmap
    /// (32 bpp, straight alpha). The 24 by 18 pt runner is scaled to the full
    /// width and centred vertically. Black ink, transparent holes.
    /// </summary>
    public static Bitmap Render(RunnerPose pose, int frame, int side)
    {
        var count = FrameCount(pose);
        frame = ((frame % count) + count) % count;

        var bitmap = new Bitmap(side, side, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bitmap);
        g.Clear(Color.Transparent);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.CompositingQuality = CompositingQuality.HighQuality;

        var scale = side / Width;
        var top = (side - Height * scale) / 2f;
        g.TranslateTransform(0, top + Height * scale);
        g.ScaleTransform(scale, -scale); // points, y up

        var c = new RunnerCanvas(g);
        switch (pose)
        {
            case RunnerPose.Sleeping: Sleeping(c, frame); break;
            case RunnerPose.Starting: Walking(c, frame, 6); break;
            case RunnerPose.Running: Running(c, frame, 6); break;
            case RunnerPose.Crashed: Stumbling(c, frame); break;
            case RunnerPose.Alert: Alert(c); break;
            default: Question(c); break;
        }
        return bitmap;
    }

    /// <summary>The seat, the posts and the backrest, above the hips.</summary>
    private static void Body(RunnerCanvas c, RunnerCanvas.EyeStyle eyes)
    {
        c.Fill(new RectangleF(2.2f, 6.4f, 13.6f, 2.2f), 0.8f);
        c.Fill(new RectangleF(3.4f, 8.4f, 1.5f, 1.8f), 0.3f);
        c.Fill(new RectangleF(13.1f, 8.4f, 1.5f, 1.8f), 0.3f);
        c.Fill(new RectangleF(2.6f, 9.9f, 12.8f, 5.4f), 1.6f);
        c.Eyes(EyePoints, eyes);
    }

    private static void Legs(RunnerCanvas c, (float, float) back, (float, float) front)
    {
        c.Leg(new PointF(7.2f, HipY), 3.1f, 3.4f, back.Item1, back.Item2, 1.5f);
        c.Leg(new PointF(10.8f, HipY), 3.1f, 3.4f, front.Item1, front.Item2, 1.5f);
    }

    private static void Running(RunnerCanvas c, int i, int n)
    {
        c.Transformed(10, Pivot, new PointF(1, Gait.Bob(i, n, 0.9f)), () =>
        {
            Legs(c, Gait.Run(i, n, 0.5), Gait.Run(i, n, 0));
            Body(c, RunnerCanvas.EyeStyle.Open);
        });
        // speed lines behind the bench
        var drift = (i % 3) * 0.6f;
        c.Line([new PointF(0.4f + drift, 13), new PointF(1.6f + drift, 13)], 0.8f);
        c.Line([new PointF(0.2f + drift, 10.4f), new PointF(1.2f + drift, 10.4f)], 0.8f);
    }

    private static void Walking(RunnerCanvas c, int i, int n)
    {
        c.Transformed(3, Pivot, new PointF(0.5f, Gait.Bob(i, n, 0.4f)), () =>
        {
            Legs(c, Gait.Walk(i, n, 0.5), Gait.Walk(i, n, 0));
            Body(c, RunnerCanvas.EyeStyle.Open);
        });
    }

    private static void Sleeping(RunnerCanvas c, int i)
    {
        // standing still like any bench, breathing a little
        var breath = i % 2 == 0 ? 0f : 0.3f;
        c.Transformed(0, Pivot, new PointF(0, -0.6f + breath), () =>
        {
            c.Line([new PointF(4.2f, HipY), new PointF(4.2f, 0.6f - breath)], 1.5f);
            c.Line([new PointF(13.8f, HipY), new PointF(13.8f, 0.6f - breath)], 1.5f);
            Body(c, RunnerCanvas.EyeStyle.Closed);
        });
        SleepMarks(c, i, 17.6f);
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
        // trip, pitch forward, nearly fall, catch itself
        var p = StumblePoses[i];
        c.Transformed(p.Lean, Pivot, new PointF(1, p.Drop), () =>
        {
            Legs(c, p.Back, p.Front);
            Body(c, p.Eyes);
        });
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

    /// <summary>Two z's floating up and away, frame <paramref name="i"/> of 4.</summary>
    private static void SleepMarks(RunnerCanvas c, int i, float x)
    {
        var rise = i * 0.7f;
        c.SleepZ(new PointF(x, 7.2f + rise), 2.2f);
        if (i >= 1) c.SleepZ(new PointF(x + 2.6f, 11 + rise * 0.8f), 2.8f);
    }
}
