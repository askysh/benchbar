using System.Windows.Interop;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// RegisterHotKey on a message only window of the tray's own (no taskbar button, no focus). The window exists only while a key is
/// registered: it is made by the first successful register and disposed when the last key is unregistered (or the first register fails), so
/// a tray whose option is off holds no extra window. WM_HOTKEY goes to <see cref="Message"/>.
/// </summary>
internal sealed class HotKeyHost : IHotKeyRegistrar, IDisposable
{
    private const int WmHotKey = 0x0312;
    private const uint ModNoRepeat = 0x4000;
    private static readonly IntPtr HwndMessage = new(-3);

    private readonly HashSet<int> _ids = [];
    private HwndSource? _source;

    /// <summary>A hot key message arrived; the argument is its id. Returns true when it was handled.</summary>
    public Func<int, bool> Message { get; set; } = _ => false;

    /// <summary>True while the message window exists (tests).</summary>
    internal bool HasWindow => _source is not null;

    public bool Register(int id, HotKeyChord chord)
    {
        var made = false;
        if (_source is null)
        {
            try
            {
                _source = new HwndSource(new HwndSourceParameters("BenchBarHotKeys") { ParentWindow = HwndMessage, Width = 0, Height = 0, WindowStyle = 0 });
            }
            catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception)
            {
                return false;
            }
            made = true;
            if (_source.Handle == IntPtr.Zero)
            {
                Release(); // no half made source is kept
                return false;
            }
            _source.AddHook(Hook);
        }
        if (!NativeMethods.RegisterHotKey(_source.Handle, id, (uint)chord.Modifiers | ModNoRepeat, chord.VirtualKey))
        {
            if (made || _ids.Count == 0) Release();
            return false;
        }
        _ids.Add(id);
        return true;
    }

    public void Unregister(int id)
    {
        if (_source is { Handle: var handle } && handle != IntPtr.Zero && _ids.Remove(id)) NativeMethods.UnregisterHotKey(handle, id);
        if (_ids.Count == 0) Release();
    }

    private void Release()
    {
        _source?.RemoveHook(Hook);
        _source?.Dispose();
        _source = null;
    }

    private IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WmHotKey && Message((int)wParam)) handled = true;
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        foreach (var id in _ids.ToList()) Unregister(id);
        Release();
    }
}
