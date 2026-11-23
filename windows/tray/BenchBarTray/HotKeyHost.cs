using System.Windows.Interop;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// RegisterHotKey on a message only window of the tray's own (no taskbar button, no focus). The window exists only while a shortcut is
/// registered, so a tray whose option is off holds no extra window. WM_HOTKEY goes to <see cref="Message"/>.
/// </summary>
internal sealed class HotKeyHost : IHotKeyRegistrar, IDisposable
{
    private const int WmHotKey = 0x0312;
    private const uint ModNoRepeat = 0x4000;
    private static readonly IntPtr HwndMessage = new(-3);

    private HwndSource? _source;

    /// <summary>A hot key message arrived; the argument is its id. Returns true when it was handled.</summary>
    public Func<int, bool> Message { get; set; } = _ => false;

    public bool Register(int id, HotKeyChord chord)
    {
        _source ??= new HwndSource(new HwndSourceParameters("BenchBarHotKeys") { ParentWindow = HwndMessage, Width = 0, Height = 0, WindowStyle = 0 });
        if (_source.Handle == IntPtr.Zero) return false;
        _source.RemoveHook(Hook); // one hook, however many times it registers
        _source.AddHook(Hook);
        return NativeMethods.RegisterHotKey(_source.Handle, id, (uint)chord.Modifiers | ModNoRepeat, chord.VirtualKey);
    }

    public void Unregister(int id)
    {
        if (_source is { Handle: var handle } && handle != IntPtr.Zero) NativeMethods.UnregisterHotKey(handle, id);
    }

    private IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WmHotKey && Message((int)wParam)) handled = true;
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        _source?.Dispose();
        _source = null;
    }
}
