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
    private bool _syncing;

    public SettingsWindow(SettingsModel model, Func<RunnerSet> runners, Action<string> copy, ResolvedTheme theme)
        : base("BenchBar Settings", 620, 560, theme)
    {
        _model = model;
        _runners = runners;
        _copy = copy;
        Ui.ApplyMica(this);
        Ui.Name(this, "BenchBar Settings");

        var tabs = new TabControl { Margin = new Thickness(16) };
        Ui.Name(tabs, "Settings sections");
        tabs.Items.Add(new TabItem { Header = "General", Content = General() });
        tabs.Items.Add(new TabItem { Header = "Tray", Content = TrayTab() });
        Content = tabs;

        _model.Changed += Sync;
        Closed += (_, _) => _model.Changed -= Sync;
        Loaded += (_, _) => _model.LoadDistrosAsync().Forget();
    }

    private UIElement General()
    {
        var panel = new StackPanel { Margin = new Thickness(16) };

        panel.Children.Add(Check("Open BenchBar at logon", () => _model.OpenAtLogon, v => _model.OpenAtLogon = v));
        panel.Children.Add(Check("Show notifications when a bench stops or crashes", () => _model.Notifications, v => _model.Notifications = v));
        panel.Children.Add(Check("Check for updates when the BenchBar window opens", () => _model.CheckForUpdates, v => _model.CheckForUpdates = v));

        _distro.SelectionChanged += (_, _) =>
        {
            if (_syncing || _distro.SelectedItem is not string name) return;
            _model.UseDistroAsync(name.Replace(" (default)", "")).Forget();
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

    private CheckBox Check(string label, Func<bool> get, Action<bool> set)
    {
        var box = new CheckBox { Content = label, IsChecked = get(), Margin = new Thickness(0, 0, 0, 12) };
        box.Click += (_, _) => set(box.IsChecked == true);
        Ui.Name(box, label);
        _checks.Add((box, get));
        return box;
    }

    /// <summary>The distro list and the note under it.</summary>
    private void Sync()
    {
        _syncing = true;
        try
        {
            foreach (var (box, get) in _checks) box.IsChecked = get();
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
