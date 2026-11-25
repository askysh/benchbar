using System.Globalization;

namespace BenchBar.Tray.Core;

/// <summary>The modifier bits RegisterHotKey takes.</summary>
[Flags]
public enum HotKeyModifiers : uint
{
    None = 0,
    Alt = 0x1,
    Ctrl = 0x2,
    Shift = 0x4,
    Win = 0x8,
}

/// <summary>A shortcut: modifiers and a Windows virtual key code. Stored as text, <c>Ctrl+Alt+U</c>.</summary>
public readonly record struct HotKeyChord(HotKeyModifiers Modifiers, uint VirtualKey)
{
    /// <summary>Ctrl+Alt+U, the Mac's default (control, option, U) on the keys Windows has.</summary>
    public static HotKeyChord Default { get; } = new(HotKeyModifiers.Ctrl | HotKeyModifiers.Alt, 0x55);

    /// <summary>The shortcut as the person reads it: modifiers in the order Ctrl, Alt, Shift, Win, then the key.</summary>
    public string Text
    {
        get
        {
            var parts = new List<string>();
            if (Modifiers.HasFlag(HotKeyModifiers.Ctrl)) parts.Add("Ctrl");
            if (Modifiers.HasFlag(HotKeyModifiers.Alt)) parts.Add("Alt");
            if (Modifiers.HasFlag(HotKeyModifiers.Shift)) parts.Add("Shift");
            if (Modifiers.HasFlag(HotKeyModifiers.Win)) parts.Add("Win");
            parts.Add(HotKeyKeys.NameOf(VirtualKey) ?? "?");
            return string.Join('+', parts);
        }
    }

    /// <summary>Reads <see cref="Text"/> back; null for anything else (a stored value that was edited by hand).</summary>
    public static HotKeyChord? Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var mods = HotKeyModifiers.None;
        uint? key = null;
        foreach (var raw in text.Split('+', StringSplitOptions.TrimEntries))
        {
            switch (raw.ToLowerInvariant())
            {
                case "ctrl": mods |= HotKeyModifiers.Ctrl; break;
                case "alt": mods |= HotKeyModifiers.Alt; break;
                case "shift": mods |= HotKeyModifiers.Shift; break;
                case "win": mods |= HotKeyModifiers.Win; break;
                default:
                    if (key is not null || HotKeyKeys.FromName(raw) is not { } vk) return null;
                    key = vk;
                    break;
            }
        }
        return key is { } k ? new HotKeyChord(mods, k) : null;
    }
}

/// <summary>The keys a shortcut may end in, by virtual key code.</summary>
public static class HotKeyKeys
{
    private static readonly (string Name, uint Vk)[] Named =
    [
        ("Space", 0x20), ("PageUp", 0x21), ("PageDown", 0x22), ("End", 0x23), ("Home", 0x24),
        ("Left", 0x25), ("Up", 0x26), ("Right", 0x27), ("Down", 0x28), ("Insert", 0x2D), ("Delete", 0x2E),
    ];

    public static string? NameOf(uint vk)
    {
        if (vk is >= 0x30 and <= 0x39 or >= 0x41 and <= 0x5A) return ((char)vk).ToString();
        if (vk is >= 0x70 and <= 0x87) return "F" + (vk - 0x6F).ToString(CultureInfo.InvariantCulture);
        foreach (var (name, code) in Named)
        {
            if (code == vk) return name;
        }
        return null;
    }

    public static uint? FromName(string name)
    {
        if (name.Length == 1 && char.ToUpperInvariant(name[0]) is var c && (c is >= '0' and <= '9' or >= 'A' and <= 'Z')) return c;
        if (name.Length is 2 or 3 && name[0] is 'F' or 'f' && int.TryParse(name.AsSpan(1), NumberStyles.None, CultureInfo.InvariantCulture, out var n) && n is >= 1 and <= 24)
            return (uint)(0x6F + n);
        foreach (var (known, code) in Named)
        {
            if (string.Equals(known, name, StringComparison.OrdinalIgnoreCase)) return code;
        }
        return null;
    }

    public static bool IsLetterOrDigit(uint vk) => vk is >= 0x30 and <= 0x39 or >= 0x41 and <= 0x5A;
}

/// <summary>
/// What a shortcut may be (the Mac's recorder rule, "it must contain Control or Option", and a little more for Windows): Ctrl or Alt must be
/// in it, so Shift or Win alone never qualify; Ctrl with a letter or a digit needs Alt too, or it would take Ctrl+C, Ctrl+V, Ctrl+Z and the
/// other shortcuts of every app; Alt+F4 and Alt+Space are the system's. A null answer means allowed.
/// </summary>
public static class HotKeyRules
{
    public static string? Refusal(HotKeyChord chord)
    {
        if (HotKeyKeys.NameOf(chord.VirtualKey) is null) return UiText.Get("HotKeyBadKey");
        var ctrl = chord.Modifiers.HasFlag(HotKeyModifiers.Ctrl);
        var alt = chord.Modifiers.HasFlag(HotKeyModifiers.Alt);
        if (!ctrl && !alt) return UiText.Get("HotKeyNeedsModifier");
        if (ctrl && !alt && HotKeyKeys.IsLetterOrDigit(chord.VirtualKey)) return UiText.Get("HotKeyCtrlLetter");
        if (alt && !ctrl && chord.VirtualKey is 0x73 or 0x20) return UiText.Format("HotKeyReserved", chord.Text);
        return null;
    }
}

/// <summary>Registers a system wide shortcut; the app's is RegisterHotKey on a window of its own, a test's is a fake.</summary>
public interface IHotKeyRegistrar
{
    /// <summary>True when the system took the key; false when another app holds it.</summary>
    bool Register(int id, HotKeyChord chord);

    void Unregister(int id);
}

/// <summary>
/// The Quick Switch shortcut (the Mac's global hot key, opt in, default Ctrl+Alt+U). A key another app holds does not turn the option off:
/// the old key stays, <see cref="Message"/> says so, and turning the option off and on tries again. While the person records a new key the
/// shortcut is paused, so the current one can be recorded again.
/// </summary>
public interface IQuickSwitchHotKey
{
    event Action? Changed;

    bool Enabled { get; }

    HotKeyChord Chord { get; }

    /// <summary>The line to show under the shortcut (a refusal, a taken key), or null.</summary>
    string? Message { get; }

    /// <summary>True while the system holds the key for the tray.</summary>
    bool Active { get; }

    void SetEnabled(bool on);

    /// <summary>Takes the new shortcut when the rules allow it and the system gives it; false (with <see cref="Message"/>) keeps the old one.</summary>
    bool TryChange(HotKeyChord chord);

    void Reset();

    /// <summary>Recording starts: the key is given back to the system so it can be recorded again.</summary>
    void Pause();

    /// <summary>Recording ended (a key taken or Esc): the key is registered again.</summary>
    void Resume();
}

public sealed class QuickSwitchHotKey(TrayConfig config, IHotKeyRegistrar registrar, Action save) : IQuickSwitchHotKey, IDisposable
{
    internal const int HotKeyId = 0x4251;

    /// <summary>The second id: a change registers the new key under the id not in use, so the old key is never given up before the new one is held.</summary>
    internal const int HotKeyIdAlt = HotKeyId + 1;

    private int _id = HotKeyId;

    private bool _paused;
    private bool _registered;

    public event Action? Changed;

    /// <summary>The system sent the key.</summary>
    public event Action? Pressed;

    public bool Enabled => config.QuickSwitchHotKeyEnabled;

    public HotKeyChord Chord => HotKeyChord.Parse(config.QuickSwitchHotKey) is { } c && HotKeyRules.Refusal(c) is null ? c : HotKeyChord.Default;

    public string? Message { get; private set; }

    public bool Active => _registered;

    /// <summary>The window procedure calls this for WM_HOTKEY; true when it was ours.</summary>
    public bool Handle(int id)
    {
        if (id != HotKeyId && id != HotKeyIdAlt) return false;
        Pressed?.Invoke();
        return true;
    }

    /// <summary>Registers the saved shortcut at start when the option is on.</summary>
    public void Start() => Sync();

    public void SetEnabled(bool on)
    {
        if (config.QuickSwitchHotKeyEnabled == on) return;
        config.QuickSwitchHotKeyEnabled = on;
        save();
        Message = null;
        Sync();
    }

    public bool TryChange(HotKeyChord chord)
    {
        if (HotKeyRules.Refusal(chord) is { } refusal)
        {
            Message = refusal;
            Changed?.Invoke();
            return false;
        }
        var old = Chord;
        if (Enabled && !_paused && chord != old)
        {
            var next = _id == HotKeyId ? HotKeyIdAlt : HotKeyId;
            if (!registrar.Register(next, chord))
            {
                // the old key was never released, so it is still held (when it was)
                Message = UiText.Format("HotKeyTaken", chord.Text, old.Text);
                Changed?.Invoke();
                return false;
            }
            Unregister();
            _id = next;
            _registered = true;
        }
        config.QuickSwitchHotKey = chord.Text;
        save();
        Message = null;
        Changed?.Invoke();
        return true;
    }

    public void Reset() => TryChange(HotKeyChord.Default);

    public void Pause()
    {
        _paused = true;
        Unregister();
        Changed?.Invoke();
    }

    public void Resume()
    {
        _paused = false;
        Sync();
    }

    private void Sync()
    {
        Unregister();
        if (Enabled && !_paused)
        {
            _registered = registrar.Register(_id, Chord);
            Message = _registered ? null : UiText.Format("HotKeyTakenAtStart", Chord.Text);
        }
        Changed?.Invoke();
    }

    private void Unregister()
    {
        if (!_registered) return;
        registrar.Unregister(_id);
        _registered = false;
    }

    public void Dispose() => Unregister();
}
