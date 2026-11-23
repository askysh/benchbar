using BenchBar.Tray.Core;
using Xunit;

namespace BenchBar.Tray.Tests;

/// <summary>The Quick Switch shortcut row of Settings: the switch, the recorder, Reset and the line under them.</summary>
public class HotKeyRowTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (IOException) { }
    }

    private sealed class Registrar : IHotKeyRegistrar
    {
        public HashSet<string> Taken { get; } = [];
        public HotKeyChord? Held { get; private set; }

        public bool Register(int id, HotKeyChord chord)
        {
            if (Taken.Contains(chord.Text)) return false;
            Held = chord;
            return true;
        }

        public void Unregister(int id) => Held = null;
    }

    private (HotKeyRow Row, QuickSwitchHotKey HotKey, Registrar Registrar) Make()
    {
        var config = TrayConfig.Load(Path.Combine(_dir, "config.json"));
        var registrar = new Registrar();
        var hotKey = new QuickSwitchHotKey(config, registrar, config.Save);
        return (new HotKeyRow(hotKey), hotKey, registrar);
    }

    [Fact]
    public void OffByDefaultWithTheShortcutHiddenAndNothingHeld() => Sta.Run(() =>
    {
        var (row, hotKey, registrar) = Make();
        Assert.False(row.Switch.IsChecked);
        Assert.False(hotKey.Enabled);
        Assert.Null(registrar.Held);
    });

    [Fact]
    public void TheSwitchTurnsTheShortcutOnShowingTheDefault() => Sta.Run(() =>
    {
        var (row, hotKey, registrar) = Make();
        row.Switch.IsChecked = true;
        row.Switch.RaiseEvent(new System.Windows.RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
        Assert.True(hotKey.Enabled);
        Assert.Equal("Ctrl+Alt+U", row.RecordButton.Content);
        Assert.Equal(HotKeyChord.Default, registrar.Held);
        Assert.False(row.ResetButton.IsEnabled); // already the default
    });

    [Fact]
    public void RecordingPausesTheKeyAndANewChordReplacesIt() => Sta.Run(() =>
    {
        var (row, hotKey, registrar) = Make();
        hotKey.SetEnabled(true);
        row.RecordButton.RaiseEvent(new System.Windows.RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
        Assert.True(row.Recording);
        Assert.Null(registrar.Held); // the current key is free to be recorded again
        Assert.Equal("Press the new shortcut...", row.RecordButton.Content);

        row.Record(new HotKeyChord(HotKeyModifiers.Ctrl | HotKeyModifiers.Alt, 'K'));
        Assert.False(row.Recording);
        Assert.Equal("Ctrl+Alt+K", row.RecordButton.Content);
        Assert.Equal(new HotKeyChord(HotKeyModifiers.Ctrl | HotKeyModifiers.Alt, 'K'), registrar.Held);
        Assert.True(row.ResetButton.IsEnabled);
    });

    [Fact]
    public void ARefusedChordShowsTheReasonAndKeepsTheOldKey() => Sta.Run(() =>
    {
        var (row, hotKey, registrar) = Make();
        hotKey.SetEnabled(true);
        row.RecordButton.RaiseEvent(new System.Windows.RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
        row.Record(new HotKeyChord(HotKeyModifiers.Ctrl, 'C'));
        Assert.Contains("Add Alt", row.Note);
        Assert.Equal("Ctrl+Alt+U", row.RecordButton.Content);
        Assert.Equal(HotKeyChord.Default, registrar.Held);
    });

    [Fact]
    public void ATakenChordShowsThatAndKeepsTheOldKey() => Sta.Run(() =>
    {
        var (row, hotKey, registrar) = Make();
        hotKey.SetEnabled(true);
        registrar.Taken.Add("Ctrl+Alt+K");
        row.RecordButton.RaiseEvent(new System.Windows.RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
        row.Record(new HotKeyChord(HotKeyModifiers.Ctrl | HotKeyModifiers.Alt, 'K'));
        Assert.Contains("taken by another app", row.Note);
        Assert.Equal("Ctrl+Alt+U", row.RecordButton.Content);
        Assert.Equal(HotKeyChord.Default, registrar.Held);
    });

    [Fact]
    public void LeavingTheRecorderGivesTheKeyBack() => Sta.Run(() =>
    {
        var (row, hotKey, registrar) = Make();
        hotKey.SetEnabled(true);
        row.RecordButton.RaiseEvent(new System.Windows.RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
        Assert.Null(registrar.Held);
        row.EndRecording();
        Assert.Equal(HotKeyChord.Default, registrar.Held);
        Assert.Equal("Ctrl+Alt+U", row.RecordButton.Content);
    });

    [Fact]
    public void ResetPutsTheDefaultBack() => Sta.Run(() =>
    {
        var (row, hotKey, registrar) = Make();
        hotKey.SetEnabled(true);
        hotKey.TryChange(new HotKeyChord(HotKeyModifiers.Ctrl | HotKeyModifiers.Alt, 'K'));
        Assert.True(row.ResetButton.IsEnabled);
        row.ResetButton.RaiseEvent(new System.Windows.RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
        Assert.Equal("Ctrl+Alt+U", row.RecordButton.Content);
        Assert.Equal(HotKeyChord.Default, registrar.Held);
    });
}
