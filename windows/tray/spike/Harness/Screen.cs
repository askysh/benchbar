using System.Runtime.InteropServices;

namespace BenchBar.Tray.Harness;

internal static class Screen
{
    public static void MakeDpiAware()
    {
        // PER_MONITOR_AWARE_V2 = -4: the rect a shell reports is in physical pixels.
        Native.SetProcessDpiAwarenessContext(new IntPtr(-4));
    }

    /// <summary>Copies a physical pixel rectangle of the desktop to a top down BGRA buffer.</summary>
    public static byte[]? Capture(int left, int top, int width, int height)
    {
        IntPtr screen = Native.GetDC(IntPtr.Zero);
        IntPtr mem = Native.CreateCompatibleDC(screen);
        IntPtr bmp = Native.CreateCompatibleBitmap(screen, width, height);
        IntPtr old = Native.SelectObject(mem, bmp);
        try
        {
            if (!Native.BitBlt(mem, 0, 0, width, height, screen, left, top, Native.SrcCopy | Native.CaptureBlt))
                return null;
            var info = new Native.BitmapInfoHeader
            {
                Size = (uint)Marshal.SizeOf<Native.BitmapInfoHeader>(),
                Width = width,
                Height = -height,
                Planes = 1,
                BitCount = 32,
            };
            var pixels = new byte[width * height * 4];
            int lines = Native.GetDIBits(mem, bmp, 0, (uint)height, pixels, ref info, 0);
            return lines == height ? pixels : null;
        }
        finally
        {
            Native.SelectObject(mem, old);
            Native.DeleteObject(bmp);
            Native.DeleteDC(mem);
            Native.ReleaseDC(IntPtr.Zero, screen);
        }
    }
}
