using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// The Quick Switch shortcut row of Settings (the Mac's switch and recorder): a switch, the shortcut as a button that records the next
/// chord, Reset, and the line that says why a key was refused or is taken. The rules are in <see cref="HotKeyRules"/> and
/// <see cref="QuickSwitchHotKey"/>; this draws them. The shortcut is paused while it records, so the current key can be recorded again.
/// </summary>
internal sealed class HotKeyRow : StackPanel
{
    private readonly IQuickSwitchHotKey _hotKey;
    private readonly CheckBox _switch = new() { Content = UiText.Get("HotKeySwitch"), Margin = new Thickness(0, 0, 0, 2) };
    private readonly StackPanel _detail = new() { Margin = new Thickness(24, 0, 0, 0) };
    private readonly Button _record;
    private readonly Button _reset;
    private readonly TextBlock _note = Ui.Text("", 12, opacity: 0.85, margin: new Thickness(0, 4, 0, 0));
    private bool _recording;

    public HotKeyRow(IQuickSwitchHotKey hotKey)
    {
        _hotKey = hotKey;
        Margin = new Thickness(0, 0, 0, 12);
        Ui.Name(_switch, UiText.Get("HotKeySwitch"));
        _switch.Click += (_, _) => _hotKey.SetEnabled(_switch.IsChecked == true);
        Children.Add(_switch);

        _record = Ui.Button("", StartRecording, UiText.Get("HotKeyRecord"), minWidth: 140);
        _reset = Ui.Button(UiText.Get("HotKeyReset"), () => { EndRecording(); _hotKey.Reset(); }, UiText.Get("HotKeyResetName"), minWidth: 64);
        _reset.Margin = new Thickness(8, 0, 0, 0);
        var line = new StackPanel { Orientation = Orientation.Horizontal };
        line.Children.Add(_record);
        line.Children.Add(_reset);
        _detail.Children.Add(line);
        _note.TextWrapping = TextWrapping.Wrap;
        _detail.Children.Add(_note);
        Children.Add(_detail);

        _record.PreviewKeyDown += OnKeyDown;
        _record.LostKeyboardFocus += (_, _) => EndRecording();
        _hotKey.Changed += Sync;
        Unloaded += (_, _) =>
        {
            _hotKey.Changed -= Sync;
            EndRecording();
        };
        Sync();
    }

    /// <summary>The switch, the shortcut button and the Reset button, for tests.</summary>
    internal CheckBox Switch => _switch;

    internal Button RecordButton => _record;

    internal Button ResetButton => _reset;

    internal bool Recording => _recording;

    internal string Note => _note.Text;

    private void StartRecording()
    {
        if (_recording) return;
        _recording = true;
        _hotKey.Pause();
        Sync();
        _record.Focus();
    }

    /// <summary>The recording ends without a new key (focus left, Esc, Reset): the old key is registered again.</summary>
    internal void EndRecording()
    {
        if (!_recording) return;
        _recording = false;
        _hotKey.Resume();
        Sync();
    }

    /// <summary>A chord was pressed while recording: the old key comes back first, then the new one replaces it, or is refused with the reason.</summary>
    internal void Record(HotKeyChord chord)
    {
        if (!_recording) return;
        _recording = false;
        _hotKey.Resume();
        _hotKey.TryChange(chord);
        Sync();
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (!_recording) return;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        e.Handled = true;
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin or Key.None or Key.DeadCharProcessed) return;
        var mods = HotKeyModifiers.None;
        var held = Keyboard.Modifiers;
        if (held.HasFlag(ModifierKeys.Control)) mods |= HotKeyModifiers.Ctrl;
        if (held.HasFlag(ModifierKeys.Alt)) mods |= HotKeyModifiers.Alt;
        if (held.HasFlag(ModifierKeys.Shift)) mods |= HotKeyModifiers.Shift;
        if (held.HasFlag(ModifierKeys.Windows)) mods |= HotKeyModifiers.Win;
        if (key == Key.Escape && mods == HotKeyModifiers.None)
        {
            EndRecording();
            return;
        }
        Record(new HotKeyChord(mods, (uint)KeyInterop.VirtualKeyFromKey(key)));
    }

    private void Sync()
    {
        _switch.IsChecked = _hotKey.Enabled;
        _detail.Visibility = _hotKey.Enabled ? Visibility.Visible : Visibility.Collapsed;
        _record.Content = _recording ? UiText.Get("HotKeyPressNew") : _hotKey.Chord.Text;
        _reset.IsEnabled = _recording || _hotKey.Chord != HotKeyChord.Default;
        var note = _recording ? UiText.Get("HotKeyRecordingNote") : _hotKey.Message;
        _note.Text = note ?? "";
        _note.Visibility = note is null ? Visibility.Collapsed : Visibility.Visible;
    }
}
