using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// Settings: General (open at logon, notifications, update check, distro, editor, CLI path) and Tray (appearance, runner).
/// The rules are in <see cref="SettingsModel"/>; this draws them.
/// </summary>
internal sealed class SettingsWindow : ToolWindow
{
    private readonly SettingsModel _model;
    private readonly Func<RunnerSet> _runners;
    private readonly Action<string> _copy;
    private readonly ComboBox _distro = new() { Width = 320, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly TextBlock _distroNote = Ui.Text("", 12, opacity: 0.8, margin: new Thickness(0, 4, 0, 0));
    private readonly ResolvedTheme _theme;
    private bool _syncing;

    /// <summary>Asks before the distro changes; tests replace it.</summary>
    public Func<string, bool> ConfirmSwitch { get; set; }

    public SettingsWindow(SettingsModel model, Func<RunnerSet> runners, Action<string> copy, ResolvedTheme theme)
        : base(UiText.Get("SettingsTitle"), 620, 560, theme)
    {
        _model = model;
        _theme = theme;
        ConfirmSwitch = name => ConfirmDialog.Ask(UiText.Format("SettingsUseDistro", name),
            UiText.Format("SettingsUseDistroBody", name), UiText.Get("SettingsSwitch"), _theme, this);
        _runners = runners;
        _copy = copy;
        _logonSettings = Ui.Button(LogonView.SettingsButton, () => _model.OpenStartupSettings(), UiText.Get("SettingsOpenStartup"), minWidth: 160);
        _logonSettings.HorizontalAlignment = HorizontalAlignment.Left;
        _logonSettings.Margin = new Thickness(0, 0, 0, 12);
        Ui.ApplyMica(this);
        Ui.Name(this, UiText.Get("SettingsTitle"));

        var tabs = new TabControl { Margin = new Thickness(16) };
        Ui.Name(tabs, UiText.Get("SettingsSections"));
        tabs.Items.Add(new TabItem { Header = UiText.Get("SettingsGeneral"), Content = General() });
        tabs.Items.Add(new TabItem { Header = UiText.Get("SettingsTray"), Content = TrayTab() });
        Content = tabs;

        _model.Changed += Sync;
        Closed += (_, _) =>
        {
            _model.Changed -= Sync;
            _model.Detach();
        };
        Loaded += (_, _) =>
        {
            _model.LoadDistrosAsync().Forget();
            _model.LoadLogonAsync().Forget();
        };
        SyncLogon();
    }

    private UIElement General()
    {
        var panel = new StackPanel { Margin = new Thickness(16) };

        panel.Children.Add(LogonRow());
        panel.Children.Add(Check(UiText.Get("SettingsNotifications"), () => _model.Notifications, v => _model.Notifications = v));
        var updates = Check(UiText.Get("SettingsCheckUpdates"), () => _model.CheckForUpdates, v => _model.CheckForUpdates = v);
        if (!_model.ShowsUpdateCheck)
        {
            // packaged: the Store updates the programs, so the switch is gone and one line says where updates come from
            updates.Visibility = Visibility.Collapsed;
            panel.Children.Add(Ui.Text(UpdatePolicy.StoreLine, 13, opacity: 0.85, margin: new Thickness(0, 0, 0, 12)));
        }
        panel.Children.Add(updates);

        var askBox = Check(UiText.Get("SettingsAskLink"), () => _model.ConfirmLinkActions, v => _model.ConfirmLinkActions = v);
        askBox.Margin = new Thickness(0, 0, 0, 2);
        panel.Children.Add(askBox);
        panel.Children.Add(Ui.Text(UiText.Get("SettingsAskLinkHint"),
            12, opacity: 0.7, margin: new Thickness(24, 0, 0, 12)));

        if (_model.HotKey is { } hotKey) panel.Children.Add(new HotKeyRow(hotKey));

        _distro.SelectionChanged += (_, _) =>
        {
            if (_syncing || _distro.SelectedItem is not string chosen) return;
            var name = chosen.Replace(" (default)", "");
            if (string.Equals(name, _model.CurrentDistro, StringComparison.OrdinalIgnoreCase)) return;
            if (!ConfirmSwitch(name))
            {
                Dispatcher.BeginInvoke(Sync); // put the picker back on the distro in use
                return;
            }
            _model.UseDistroAsync(name).Forget();
        };
        Ui.Name(_distro, UiText.Get("SettingsDistro"));
        var distroBox = new StackPanel();
        distroBox.Children.Add(_distro);
        distroBox.Children.Add(_distroNote);
        panel.Children.Add(Ui.Labeled(UiText.Get("SettingsDistro"), distroBox, UiText.Get("SettingsDistroHint")));

        var editor = new ComboBox { Width = 220, HorizontalAlignment = HorizontalAlignment.Left, ItemsSource = EditorKind.Ids.Select(EditorKind.DisplayName).ToList() };
        editor.SelectedItem = EditorKind.DisplayName(_model.Editor);
        editor.SelectionChanged += (_, _) =>
        {
            if (editor.SelectedIndex >= 0) _model.Editor = EditorKind.Ids[editor.SelectedIndex];
        };
        Ui.Name(editor, UiText.Get("SettingsEditorName"));
        panel.Children.Add(Ui.Labeled(UiText.Get("SettingsEditor"), editor, UiText.Get("SettingsEditorHint")));

        var cli = new DockPanel();
        var copy = Ui.Button(UiText.Get("Copy"), () => _copy(_model.CliPathText), UiText.Get("SettingsCopyCliPath"), minWidth: 64);
        copy.Margin = new Thickness(8, 0, 0, 0);
        DockPanel.SetDock(copy, Dock.Right);
        var path = new TextBox { Text = _model.CliPathText, IsReadOnly = true, Padding = new Thickness(8, 6, 8, 6), Width = 420 };
        Ui.Name(path, UiText.Get("SettingsCliPathName"));
        cli.Children.Add(copy);
        cli.Children.Add(path);
        cli.HorizontalAlignment = HorizontalAlignment.Left;
        panel.Children.Add(Ui.Labeled(UiText.Get("SettingsCli"), cli, UiText.Get("SettingsCliHint")));
        return new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    private UIElement TrayTab()
    {
        var panel = new StackPanel { Margin = new Thickness(16) };

        var appearance = new StackPanel();
        foreach (var (mode, label) in new[] { (AppearanceMode.System, UiText.Get("SettingsAppearanceSystem")), (AppearanceMode.Light, UiText.Get("SettingsAppearanceLight")), (AppearanceMode.Dark, UiText.Get("SettingsAppearanceDark")) })
        {
            var radio = new RadioButton { Content = label, GroupName = "appearance", IsChecked = _model.Appearance == mode, Margin = new Thickness(0, 0, 0, 4) };
            radio.Checked += (_, _) => { if (!_syncing) _model.Appearance = mode; };
            Ui.Name(radio, UiText.Format("SettingsAppearanceNamed", label));
            appearance.Children.Add(radio);
        }
        panel.Children.Add(Ui.Labeled(UiText.Get("SettingsAppearance"), appearance, UiText.Get("SettingsAppearanceHint")));

        var set = _runners();
        var runner = new ComboBox { Width = 260, HorizontalAlignment = HorizontalAlignment.Left, DisplayMemberPath = nameof(RunnerInfo.DisplayName) };
        foreach (var info in set.Runners.Where(r => r.IsUsable)) runner.Items.Add(info);
        runner.SelectedItem = runner.Items.OfType<RunnerInfo>().FirstOrDefault(r => string.Equals(r.Id, _model.RunnerId, StringComparison.OrdinalIgnoreCase));
        runner.SelectionChanged += (_, _) => { if (runner.SelectedItem is RunnerInfo info) _model.RunnerId = info.Id; };
        Ui.Name(runner, UiText.Get("SettingsRunnerName"));
        panel.Children.Add(Ui.Labeled(UiText.Get("SettingsRunner"), runner, UiText.Get("SettingsRunnerHint")));
        return new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    private readonly List<(CheckBox Box, Func<bool> Get)> _checks = [];
    private readonly CheckBox _logon = new() { Content = UiText.Get("MenuLogon"), Margin = new Thickness(0, 0, 0, 12) };
    private readonly TextBlock _logonNote = Ui.Text("", 12, opacity: 0.85, margin: new Thickness(0, -6, 0, 6));
    private readonly Button _logonSettings;

    /// <summary>
    /// The logon switch and what goes with it. Packaged, it is the package's startup task: when Windows or a policy has it off, the app cannot
    /// turn it on, so the box is off and disabled, one line says where to turn it on, and a button opens Settings > Apps > Startup.
    /// </summary>
    private UIElement LogonRow()
    {
        var row = new StackPanel();
        // Checked/Unchecked, not Click: UI Automation's Toggle pattern flips the box without a Click. Whatever the box was flipped to, it is put back
        // to what the model says at once; the answer of Windows publishes the real state and Sync shows it.
        _logon.Checked += (_, _) => OnLogonToggled();
        _logon.Unchecked += (_, _) => OnLogonToggled();
        Ui.Name(_logon, UiText.Get("MenuLogon"));
        row.Children.Add(_logon);
        _logonNote.TextWrapping = TextWrapping.Wrap;
        row.Children.Add(_logonNote);
        row.Children.Add(_logonSettings);
        return row;
    }

    private CheckBox Check(string label, Func<bool> get, Action<bool> set)
    {
        var box = new CheckBox { Content = label, IsChecked = get(), Margin = new Thickness(0, 0, 0, 12) };
        box.Click += (_, _) => set(box.IsChecked == true);
        Ui.Name(box, label);
        _checks.Add((box, get));
        return box;
    }

    private void OnLogonToggled()
    {
        if (_syncing) return;
        var wanted = _logon.IsChecked == true;
        SyncLogon();
        _model.OpenAtLogon = wanted;
    }

    private void SyncLogon()
    {
        var logon = _model.LogonView;
        var was = _syncing;
        _syncing = true;
        try { _logon.IsChecked = logon.IsOn; }
        finally { _syncing = was; }
        _logon.IsEnabled = logon.CanChange;
        _logonNote.Text = logon.Note ?? "";
        _logonNote.Visibility = logon.Note is null ? Visibility.Collapsed : Visibility.Visible;
        _logonSettings.Visibility = logon.ShowSettingsButton ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>The distro list and the note under it.</summary>
    private void Sync()
    {
        _syncing = true;
        try
        {
            foreach (var (box, get) in _checks) box.IsChecked = get();
            SyncLogon();
            var names = _model.Distros.Select(d => d.IsDefault ? d.Name + " (default)" : d.Name).ToList();
            if (!names.SequenceEqual(_distro.Items.OfType<string>())) _distro.ItemsSource = names;
            var current = _model.CurrentDistro;
            _distro.SelectedItem = names.FirstOrDefault(n => n.Replace(" (default)", "").Equals(current, StringComparison.OrdinalIgnoreCase));
            _distro.IsEnabled = !_model.LoadingDistros && !_model.SwitchingDistro && names.Count > 0;
            _distroNote.Text = _model.LoadingDistros ? UiText.Get("SettingsReadingList") : _model.DistroMessage ?? "";
            _distroNote.Visibility = _distroNote.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
        finally
        {
            _syncing = false;
        }
    }
}
