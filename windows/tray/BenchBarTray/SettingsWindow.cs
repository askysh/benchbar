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
        : base("BenchBar Settings", 620, 560, theme)
    {
        _model = model;
        _theme = theme;
        ConfirmSwitch = name => ConfirmDialog.Ask($"Use {name}?",
            $"BenchBar will use {name} for its benches from now on. Benches in the other distro stay where they are, and the list updates at once.", "Switch", _theme, this);
        _runners = runners;
        _copy = copy;
        _logonSettings = Ui.Button(LogonView.SettingsButton, () => _model.OpenStartupSettings(), "Open Windows startup settings", minWidth: 160);
        _logonSettings.HorizontalAlignment = HorizontalAlignment.Left;
        _logonSettings.Margin = new Thickness(0, 0, 0, 12);
        Ui.ApplyMica(this);
        Ui.Name(this, "BenchBar Settings");

        var tabs = new TabControl { Margin = new Thickness(16) };
        Ui.Name(tabs, "Settings sections");
        tabs.Items.Add(new TabItem { Header = "General", Content = General() });
        tabs.Items.Add(new TabItem { Header = "Tray", Content = TrayTab() });
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
        panel.Children.Add(Check("Show notifications when a bench stops or crashes", () => _model.Notifications, v => _model.Notifications = v));
        var updates = Check("Check for updates when the BenchBar window opens", () => _model.CheckForUpdates, v => _model.CheckForUpdates = v);
        if (!_model.ShowsUpdateCheck)
        {
            // packaged: the Store updates the programs, so the switch is gone and one line says where updates come from
            updates.Visibility = Visibility.Collapsed;
            panel.Children.Add(Ui.Text(UpdatePolicy.StoreLine, 13, opacity: 0.85, margin: new Thickness(0, 0, 0, 12)));
        }
        panel.Children.Add(updates);

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
        Ui.Name(_distro, "WSL distro");
        var distroBox = new StackPanel();
        distroBox.Children.Add(_distro);
        distroBox.Children.Add(_distroNote);
        panel.Children.Add(Ui.Labeled("WSL distro", distroBox, "The Linux distribution BenchBar runs benches in."));

        var editor = new ComboBox { Width = 220, HorizontalAlignment = HorizontalAlignment.Left, ItemsSource = EditorKind.Ids.Select(EditorKind.DisplayName).ToList() };
        editor.SelectedItem = EditorKind.DisplayName(_model.Editor);
        editor.SelectionChanged += (_, _) =>
        {
            if (editor.SelectedIndex >= 0) _model.Editor = EditorKind.Ids[editor.SelectedIndex];
        };
        Ui.Name(editor, "Editor for Open in editor");
        panel.Children.Add(Ui.Labeled("Editor", editor, "Used by Open in editor on a bench. It needs the editor's WSL extension."));

        var cli = new DockPanel();
        var copy = Ui.Button("Copy", () => _copy(_model.CliPathText), "Copy the CLI path", minWidth: 64);
        copy.Margin = new Thickness(8, 0, 0, 0);
        DockPanel.SetDock(copy, Dock.Right);
        var path = new TextBox { Text = _model.CliPathText, IsReadOnly = true, Padding = new Thickness(8, 6, 8, 6), Width = 420 };
        Ui.Name(path, "Command line tool path");
        cli.Children.Add(copy);
        cli.Children.Add(path);
        cli.HorizontalAlignment = HorizontalAlignment.Left;
        panel.Children.Add(Ui.Labeled("Command line tool", cli, "benchbar.exe, which calls the Linux command line tool inside the distro."));
        return new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    private UIElement TrayTab()
    {
        var panel = new StackPanel { Margin = new Thickness(16) };

        var appearance = new StackPanel();
        foreach (var (mode, label) in new[] { (AppearanceMode.System, "Follow Windows"), (AppearanceMode.Light, "Light"), (AppearanceMode.Dark, "Dark") })
        {
            var radio = new RadioButton { Content = label, GroupName = "appearance", IsChecked = _model.Appearance == mode, Margin = new Thickness(0, 0, 0, 4) };
            radio.Checked += (_, _) => { if (!_syncing) _model.Appearance = mode; };
            Ui.Name(radio, "Appearance: " + label);
            appearance.Children.Add(radio);
        }
        panel.Children.Add(Ui.Labeled("Appearance", appearance, "The runner follows the taskbar's theme; the windows follow this choice."));

        var set = _runners();
        var runner = new ComboBox { Width = 260, HorizontalAlignment = HorizontalAlignment.Left, DisplayMemberPath = nameof(RunnerInfo.DisplayName) };
        foreach (var info in set.Runners.Where(r => r.IsUsable)) runner.Items.Add(info);
        runner.SelectedItem = runner.Items.OfType<RunnerInfo>().FirstOrDefault(r => string.Equals(r.Id, _model.RunnerId, StringComparison.OrdinalIgnoreCase));
        runner.SelectionChanged += (_, _) => { if (runner.SelectedItem is RunnerInfo info) _model.RunnerId = info.Id; };
        Ui.Name(runner, "Runner in the notification area");
        panel.Children.Add(Ui.Labeled("Runner", runner, "The little figure in the notification area. The right click menu on the icon previews each one."));
        return new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    private readonly List<(CheckBox Box, Func<bool> Get)> _checks = [];
    private readonly CheckBox _logon = new() { Content = "Open BenchBar at logon", Margin = new Thickness(0, 0, 0, 12) };
    private readonly TextBlock _logonNote = Ui.Text("", 12, opacity: 0.85, margin: new Thickness(0, -6, 0, 6));
    private readonly Button _logonSettings;

    /// <summary>
    /// The logon switch and what goes with it. Packaged, it is the package's startup task: when Windows or a policy has it off, the app cannot
    /// turn it on, so the box is off and disabled, one line says where to turn it on, and a button opens Settings > Apps > Startup.
    /// </summary>
    private UIElement LogonRow()
    {
        var row = new StackPanel();
        _logon.Click += (_, _) => _model.OpenAtLogon = _logon.IsChecked == true;
        Ui.Name(_logon, "Open BenchBar at logon");
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

    private void SyncLogon()
    {
        var logon = _model.LogonView;
        _logon.IsChecked = logon.IsOn;
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
            _distroNote.Text = _model.LoadingDistros ? "Reading the list..." : _model.DistroMessage ?? "";
            _distroNote.Visibility = _distroNote.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
        finally
        {
            _syncing = false;
        }
    }
}
