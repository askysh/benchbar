using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

public class QuickSwitchHotKeyTests
{
    private sealed class FakeRegistrar : IHotKeyRegistrar
    {
        private readonly Dictionary<int, HotKeyChord> _held = [];

        public HashSet<string> Taken { get; } = [];
        public List<string> Log { get; } = [];

        /// <summary>The one key held now (null when none); two held at once is only ever the instant of a change.</summary>
        public HotKeyChord? Held => _held.Count == 0 ? null : _held.Values.Single();

        public int HeldCount => _held.Count;

        public bool Register(int id, HotKeyChord chord)
        {
            Log.Add($"register {id} {chord.Text}");
            Assert.False(_held.ContainsKey(id)); // an id is never registered twice
            if (Taken.Contains(chord.Text)) return false;
            _held[id] = chord;
            return true;
        }

        public void Unregister(int id)
        {
            Log.Add($"unregister {id}");
            _held.Remove(id);
        }
    }

    private static (QuickSwitchHotKey HotKey, FakeRegistrar Registrar, TrayConfig Config, int[] Saves) Make()
    {
        var path = Path.Combine(Path.GetTempPath(), "benchbar-tray-tests", Guid.NewGuid().ToString("N"), "config.json");
        var config = TrayConfig.Load(path);
        var registrar = new FakeRegistrar();
        var saves = new int[1];
        return (new QuickSwitchHotKey(config, registrar, () => { saves[0]++; config.Save(); }), registrar, config, saves);
    }

    private static HotKeyChord Chord(HotKeyModifiers mods, char key) => new(mods, key);

    private const HotKeyModifiers Ctrl = HotKeyModifiers.Ctrl, Alt = HotKeyModifiers.Alt, Shift = HotKeyModifiers.Shift, Win = HotKeyModifiers.Win;

    [Fact]
    public void TheDefaultIsCtrlAltUAndItIsAllowed()
    {
        Assert.Equal("Ctrl+Alt+U", HotKeyChord.Default.Text);
        Assert.Null(HotKeyRules.Refusal(HotKeyChord.Default));
    }

    [Theory]
    [InlineData("Ctrl+Alt+U")]
    [InlineData("Alt+F9")]
    [InlineData("Ctrl+Alt+Shift+Space")]
    [InlineData("Ctrl+F5")]
    [InlineData("Ctrl+Win+Left")]
    [InlineData("Alt+7")]
    public void AShortcutWithCtrlOrAltIsAllowedAndReadsBack(string text)
    {
        var chord = HotKeyChord.Parse(text);
        Assert.NotNull(chord);
        Assert.Equal(text, chord.Value.Text);
        if (text != "Ctrl+Alt+Shift+Space") Assert.Null(HotKeyRules.Refusal(chord.Value));
    }

    [Theory]
    [InlineData(Shift, 'U')]
    [InlineData(Win, 'U')]
    [InlineData(Shift | Win, 'U')]
    [InlineData(HotKeyModifiers.None, 'U')]
    public void WithoutCtrlOrAltItIsRefused(HotKeyModifiers mods, char key)
    {
        Assert.Contains("Ctrl or Alt", HotKeyRules.Refusal(Chord(mods, key)));
    }

    [Theory]
    [InlineData('C')]
    [InlineData('V')]
    [InlineData('X')]
    [InlineData('Z')]
    [InlineData('A')]
    [InlineData('5')]
    public void CtrlWithALetterOrDigitAndNoAltIsRefusedSoNoAppShortcutIsTaken(char key)
    {
        Assert.Contains("Add Alt", HotKeyRules.Refusal(Chord(Ctrl, key)));
        Assert.Contains("Add Alt", HotKeyRules.Refusal(Chord(Ctrl | Shift, key)));
        Assert.Null(HotKeyRules.Refusal(Chord(Ctrl | Alt, key)));
    }

    [Fact]
    public void AltF4AndAltSpaceAreRefusedWithOrWithoutShift()
    {
        foreach (var vk in new uint[] { 0x73, 0x20 })
        {
            Assert.NotNull(HotKeyRules.Refusal(new HotKeyChord(Alt, vk)));
            Assert.NotNull(HotKeyRules.Refusal(new HotKeyChord(Alt | Shift, vk)));
            Assert.Null(HotKeyRules.Refusal(new HotKeyChord(Ctrl | Alt, vk))); // with Ctrl it is not the system's
        }
    }

    [Fact]
    public void TheSystemsOwnAltKeysAndUnknownKeysAreRefused()
    {
        Assert.NotNull(HotKeyRules.Refusal(new HotKeyChord(Alt, 0x73))); // Alt+F4
        Assert.NotNull(HotKeyRules.Refusal(new HotKeyChord(Alt, 0x20))); // Alt+Space
        Assert.NotNull(HotKeyRules.Refusal(new HotKeyChord(Ctrl | Alt, 0xBA))); // a punctuation key is not offered
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("Ctrl+Alt")]
    [InlineData("Ctrl+Alt+U+V")]
    [InlineData("Hyper+U")]
    public void AStoredValueThatCannotBeReadIsNotAChord(string? text)
    {
        Assert.Null(HotKeyChord.Parse(text));
    }

    [Fact]
    public void ItIsOffByDefaultAndHoldsNoKey()
    {
        var (hotKey, registrar, config, _) = Make();
        hotKey.Start();
        Assert.False(hotKey.Enabled);
        Assert.False(hotKey.Active);
        Assert.Empty(registrar.Log);
        Assert.False(config.QuickSwitchHotKeyEnabled);
    }

    [Fact]
    public void TurningItOnRegistersTheDefaultAndOffGivesItBack()
    {
        var (hotKey, registrar, _, saves) = Make();
        hotKey.SetEnabled(true);
        Assert.True(hotKey.Active);
        Assert.Equal(HotKeyChord.Default, registrar.Held);
        Assert.Equal(1, saves[0]);

        hotKey.SetEnabled(false);
        Assert.False(hotKey.Active);
        Assert.Null(registrar.Held);
        Assert.Equal(2, saves[0]);
    }

    [Fact]
    public void TheChoiceIsStoredInTheConfigAndRegisteredAtTheNextStart()
    {
        var (hotKey, _, config, _) = Make();
        hotKey.SetEnabled(true);
        Assert.True(hotKey.TryChange(Chord(Ctrl | Alt, 'K')));

        var back = TrayConfig.Load(config.Path);
        Assert.True(back.QuickSwitchHotKeyEnabled);
        Assert.Equal("Ctrl+Alt+K", back.QuickSwitchHotKey);

        var registrar = new FakeRegistrar();
        var next = new QuickSwitchHotKey(back, registrar, () => { });
        next.Start();
        Assert.Equal(Chord(Ctrl | Alt, 'K'), registrar.Held);
    }

    [Fact]
    public void ARefusedKeyChangesNothingAndSaysWhy()
    {
        var (hotKey, registrar, config, saves) = Make();
        hotKey.SetEnabled(true);
        var before = saves[0];
        Assert.False(hotKey.TryChange(Chord(Ctrl, 'C')));
        Assert.Contains("Add Alt", hotKey.Message);
        Assert.Equal(HotKeyChord.Default, hotKey.Chord);
        Assert.Equal(HotKeyChord.Default, registrar.Held);
        Assert.Equal(before, saves[0]);
        Assert.Null(config.QuickSwitchHotKey);
    }

    [Fact]
    public void ATakenKeyKeepsTheOldOneAndSaysSo()
    {
        var (hotKey, registrar, config, _) = Make();
        hotKey.SetEnabled(true);
        registrar.Taken.Add("Ctrl+Alt+K");
        Assert.False(hotKey.TryChange(Chord(Ctrl | Alt, 'K')));
        Assert.Equal("Ctrl+Alt+K is taken by another app. Ctrl+Alt+U stays.", hotKey.Message);
        Assert.Equal(HotKeyChord.Default, hotKey.Chord);
        Assert.Equal(HotKeyChord.Default, registrar.Held); // the old key is registered again
        Assert.True(hotKey.Active);
        Assert.Null(config.QuickSwitchHotKey);

        Assert.True(hotKey.TryChange(Chord(Ctrl | Alt, 'J')));
        Assert.Null(hotKey.Message);
    }

    [Fact]
    public void ANewKeyIsHeldBeforeTheOldOneIsGivenUpSoNoOtherAppCanTakeItInBetween()
    {
        var (hotKey, registrar, _, _) = Make();
        hotKey.SetEnabled(true);
        registrar.Log.Clear();
        Assert.True(hotKey.TryChange(Chord(Ctrl | Alt, 'K')));
        Assert.Equal([$"register {QuickSwitchHotKey.HotKeyIdAlt} Ctrl+Alt+K", $"unregister {QuickSwitchHotKey.HotKeyId}"], registrar.Log);
        Assert.Equal(1, registrar.HeldCount);

        registrar.Log.Clear();
        Assert.True(hotKey.TryChange(Chord(Ctrl | Alt, 'J'))); // the ids alternate
        Assert.Equal([$"register {QuickSwitchHotKey.HotKeyId} Ctrl+Alt+J", $"unregister {QuickSwitchHotKey.HotKeyIdAlt}"], registrar.Log);
        Assert.True(hotKey.Handle(QuickSwitchHotKey.HotKeyId));

        // and a refused new key never lets go of the old one
        registrar.Taken.Add("Ctrl+Alt+H");
        registrar.Log.Clear();
        Assert.False(hotKey.TryChange(Chord(Ctrl | Alt, 'H')));
        Assert.Equal([$"register {QuickSwitchHotKey.HotKeyIdAlt} Ctrl+Alt+H"], registrar.Log);
        Assert.Equal(Chord(Ctrl | Alt, 'J'), registrar.Held);
        Assert.True(hotKey.Active);
        Assert.Contains("Ctrl+Alt+J stays", hotKey.Message);
    }

    [Fact]
    public void ATakenKeyAtStartKeepsTheOptionOnAndTurningItOffAndOnTriesAgain()
    {
        var (hotKey, registrar, config, _) = Make();
        config.QuickSwitchHotKeyEnabled = true;
        registrar.Taken.Add("Ctrl+Alt+U");
        hotKey.Start();
        Assert.True(hotKey.Enabled);
        Assert.False(hotKey.Active);
        Assert.Contains("taken by another app", hotKey.Message);

        registrar.Taken.Clear();
        hotKey.SetEnabled(false);
        hotKey.SetEnabled(true);
        Assert.True(hotKey.Active);
        Assert.Null(hotKey.Message);
    }

    [Fact]
    public void RecordingPausesTheKeySoTheCurrentOneCanBeRecordedAgain()
    {
        var (hotKey, registrar, _, _) = Make();
        hotKey.SetEnabled(true);
        registrar.Taken.Clear();

        hotKey.Pause();
        Assert.Null(registrar.Held);
        Assert.False(hotKey.Active);

        hotKey.Resume();
        Assert.Equal(HotKeyChord.Default, registrar.Held);
        Assert.True(hotKey.TryChange(HotKeyChord.Default)); // the same key again is fine
        Assert.Equal(HotKeyChord.Default, registrar.Held);
    }

    [Fact]
    public void PausingWhileOffHoldsNothingAndResumingDoesNotTurnItOn()
    {
        var (hotKey, registrar, _, _) = Make();
        hotKey.Pause();
        hotKey.Resume();
        Assert.Null(registrar.Held);
        Assert.False(hotKey.Active);
    }

    [Fact]
    public void ResetRestoresTheDefault()
    {
        var (hotKey, registrar, config, _) = Make();
        hotKey.SetEnabled(true);
        hotKey.TryChange(Chord(Ctrl | Alt, 'K'));
        hotKey.Reset();
        Assert.Equal(HotKeyChord.Default, hotKey.Chord);
        Assert.Equal(HotKeyChord.Default, registrar.Held);
        Assert.Equal("Ctrl+Alt+U", config.QuickSwitchHotKey);
    }

    [Fact]
    public void AnEditedConfigWithAnUnsafeKeyFallsBackToTheDefault()
    {
        var (hotKey, _, config, _) = Make();
        config.QuickSwitchHotKey = "Ctrl+C";
        Assert.Equal(HotKeyChord.Default, hotKey.Chord);
        config.QuickSwitchHotKey = "nonsense";
        Assert.Equal(HotKeyChord.Default, hotKey.Chord);
    }

    [Fact]
    public void DisposeGivesTheKeyBackAndOnlyItsOwnIdIsHandled()
    {
        var (hotKey, registrar, _, _) = Make();
        var pressed = 0;
        hotKey.Pressed += () => pressed++;
        hotKey.SetEnabled(true);
        Assert.False(hotKey.Handle(1));
        Assert.True(hotKey.Handle(QuickSwitchHotKey.HotKeyId));
        Assert.Equal(1, pressed);

        hotKey.Dispose();
        Assert.Null(registrar.Held);
    }

    [Fact]
    public void TheHotKeyKeyDoesNotDisturbTheShimsKeysOrTheOtherTraySettings()
    {
        var (hotKey, _, config, _) = Make();
        Directory.CreateDirectory(Path.GetDirectoryName(config.Path)!);
        File.WriteAllText(config.Path, """{"distro":"Ubuntu-24.04","tray":{"runner":"cup"}}""");
        var loaded = TrayConfig.Load(config.Path);
        new QuickSwitchHotKey(loaded, new FakeRegistrar(), loaded.Save).SetEnabled(true);
        var text = File.ReadAllText(config.Path);
        Assert.Contains("\"distro\": \"Ubuntu-24.04\"", text);
        Assert.Equal("cup", TrayConfig.Load(config.Path).RunnerId);
        Assert.True(TrayConfig.Load(config.Path).QuickSwitchHotKeyEnabled);
        _ = hotKey;
    }
}
