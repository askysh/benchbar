using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace BenchBar.Tray.Core;

/// <summary>
/// Runner frames as HICONs for the tray slot. A frame is drawn on first use
/// for the current (side, tint) and cached; an animation tick only swaps a
/// cached handle. Changing the slot (DPI of the taskbar monitor) or the
/// taskbar theme drops the cache and destroys every handle.
/// Not thread safe: use it from one thread (the UI thread).
/// </summary>
public sealed class RunnerIcons : IDisposable
{
    /// <summary>White on a dark taskbar.</summary>
    public static readonly Color DarkTaskbarTint = Color.FromArgb(255, 255, 255);

    /// <summary>Near black on a light taskbar.</summary>
    public static readonly Color LightTaskbarTint = Color.FromArgb(0x1B, 0x1B, 0x1B);

    private readonly Dictionary<(RunnerPose Pose, int Frame), IntPtr> _cache = [];
    private int _side;
    private bool _light;
    private bool _disposed;

    public RunnerIcons(int side = 16, bool lightTaskbar = false)
    {
        _side = side;
        _light = lightTaskbar;
    }

    public int Side => _side;

    public bool LightTaskbar => _light;

    /// <summary>The number of icons currently cached.</summary>
    public int CachedCount => _cache.Count;

    public int FrameCount(RunnerPose pose) => BenchRunnerArt.FrameCount(pose);

    /// <summary>The cached HICON for a frame; it stays valid until the slot changes or this is disposed.</summary>
    public IntPtr Get(RunnerPose pose, int frame)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var count = FrameCount(pose);
        frame = ((frame % count) + count) % count;
        if (_cache.TryGetValue((pose, frame), out var handle)) return handle;

        using var bitmap = RenderTinted(pose, frame, _side, _light);
        handle = CreateHIcon(bitmap);
        _cache[(pose, frame)] = handle;
        return handle;
    }

    /// <summary>Drops the cache (and destroys every handle) when the side or the tint changed.</summary>
    public void SetSlot(int side, bool lightTaskbar)
    {
        if (side == _side && lightTaskbar == _light) return;
        _side = side;
        _light = lightTaskbar;
        DestroyAll();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        DestroyAll();
    }

    private void DestroyAll()
    {
        foreach (var handle in _cache.Values) Native.DestroyIcon(handle);
        _cache.Clear();
    }

    /// <summary>The frame drawn in black, then every pixel's colour set to the taskbar's foreground (alpha kept).</summary>
    internal static Bitmap RenderTinted(RunnerPose pose, int frame, int side, bool lightTaskbar)
    {
        var bitmap = BenchRunnerArt.Render(pose, frame, side);
        var tint = lightTaskbar ? LightTaskbarTint : DarkTaskbarTint;
        var data = bitmap.LockBits(new Rectangle(0, 0, side, side), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        try
        {
            var row = new byte[side * 4];
            for (var y = 0; y < side; y++)
            {
                var line = data.Scan0 + y * data.Stride;
                Marshal.Copy(line, row, 0, row.Length);
                for (var x = 0; x < side; x++)
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
        return bitmap;
    }

    /// <summary>
    /// An HICON from a 32 bpp top down DIB section with straight alpha plus a
    /// mask bitmap, through CreateIconIndirect: no Icon.FromHandle round trip.
    /// </summary>
    internal static IntPtr CreateHIcon(Bitmap bitmap)
    {
        var width = bitmap.Width;
        var height = bitmap.Height;
        var header = new Native.BITMAPINFOHEADER
        {
            biSize = (uint)Marshal.SizeOf<Native.BITMAPINFOHEADER>(),
            biWidth = width,
            biHeight = -height, // top down
            biPlanes = 1,
            biBitCount = 32,
            biCompression = 0, // BI_RGB
        };

        var color = Native.CreateDIBSection(IntPtr.Zero, in header, 0, out var bits, IntPtr.Zero, 0);
        if (color == IntPtr.Zero || bits == IntPtr.Zero) throw new InvalidOperationException("CreateDIBSection failed");
        var mask = IntPtr.Zero;
        try
        {
            var data = bitmap.LockBits(new Rectangle(0, 0, width, height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                var row = new byte[width * 4];
                for (var y = 0; y < height; y++)
                {
                    Marshal.Copy(data.Scan0 + y * data.Stride, row, 0, row.Length);
                    Marshal.Copy(row, 0, bits + y * width * 4, row.Length);
                }
            }
            finally
            {
                bitmap.UnlockBits(data);
            }

            mask = Native.CreateBitmap(width, height, 1, 1, IntPtr.Zero);
            if (mask == IntPtr.Zero) throw new InvalidOperationException("CreateBitmap failed");
            var info = new Native.ICONINFO { fIcon = 1, hbmMask = mask, hbmColor = color };
            var icon = Native.CreateIconIndirect(in info);
            if (icon == IntPtr.Zero) throw new InvalidOperationException("CreateIconIndirect failed");
            return icon;
        }
        finally
        {
            // the icon keeps its own copies
            Native.DeleteObject(color);
            if (mask != IntPtr.Zero) Native.DeleteObject(mask);
        }
    }

    /// <summary>
    /// Writes every frame as <c>POSE-N.png</c> (N from 1) for the given side and
    /// taskbar tint, so the port can be compared to the Mac art by eye.
    /// Returns the paths written.
    /// </summary>
    public static IReadOnlyList<string> ExportPng(string dir, int side, bool light)
    {
        Directory.CreateDirectory(dir);
        var written = new List<string>();
        foreach (var pose in Enum.GetValues<RunnerPose>())
        {
            for (var f = 0; f < BenchRunnerArt.FrameCount(pose); f++)
            {
                using var bitmap = RenderTinted(pose, f, side, light);
                var path = Path.Combine(dir, $"{pose.ToString().ToLowerInvariant()}-{f + 1}.png");
                bitmap.Save(path, ImageFormat.Png);
                written.Add(path);
            }
        }
        return written;
    }

    /// <summary>
    /// One contact sheet per pose, <paramref name="height"/> px tall, the frames side by side on the
    /// taskbar's colour. <paramref name="vector"/> draws each frame at full size from the
    /// geometry (to compare with the Mac art); otherwise the <paramref name="side"/> px frame is
    /// enlarged without smoothing (to see the pixels the tray really gets).
    /// </summary>
    public static IReadOnlyList<string> ExportContactSheets(string dir, int side, bool light, int height = 96, bool vector = true)
    {
        Directory.CreateDirectory(dir);
        var written = new List<string>();
        var background = light ? Color.FromArgb(0xF3, 0xF3, 0xF3) : Color.FromArgb(0x20, 0x20, 0x20);
        foreach (var pose in Enum.GetValues<RunnerPose>())
        {
            var count = BenchRunnerArt.FrameCount(pose);
            using var sheet = new Bitmap(height * count, height, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(sheet))
            {
                g.Clear(background);
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.NearestNeighbor;
                g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.Half;
                for (var f = 0; f < count; f++)
                {
                    using var frame = RenderTinted(pose, f, vector ? height : side, light);
                    g.DrawImage(frame, new Rectangle(f * height, 0, height, height));
                }
            }
            var name = vector ? $"sheet-{pose.ToString().ToLowerInvariant()}.png" : $"sheet-px{side}-{pose.ToString().ToLowerInvariant()}.png";
            var path = Path.Combine(dir, name);
            sheet.Save(path, ImageFormat.Png);
            written.Add(path);
        }
        return written;
    }
}
