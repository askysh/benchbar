using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// The Team Profiles pane (macos ProfilesPane). A team profile is a file in the distro (or in a team's config repository), never part
/// of BenchBar: one is created from an existing bench, read only, imported from a file or link, or comes from a subscribed repository.
/// Nothing on this page installs an app. It is not about one bench, so it gets no bench context.
/// </summary>
internal sealed class ProfilesView : UserControl
{
    private readonly PageServices _services;
    private readonly IWslHost _wsl;
    private readonly ProfilesModel _model;
    private readonly StackPanel _body = new();
    private readonly Button _addButton;
    private string? _notice;

    public ProfilesView(PageServices services)
        : this(services, new WslHost(new SystemProcessRunner(), () => DistroName.Resolve(TrayConfig.Load().Distro)))
    {
    }

    /// <summary>For tests: a fake WSL.</summary>
    internal ProfilesView(PageServices services, IWslHost wsl)
    {
        _services = services;
        _wsl = wsl;
        _model = new ProfilesModel(services.Cli);
        Confirm = (title, message) => MessageBox.Show(services.Owner(), message, title, MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) == MessageBoxResult.Yes;
        var root = new StackPanel { MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Left };
        root.Children.Add(Ui.Title("Team Profiles"));
        root.Children.Add(Ui.Text("Pin a base profile and your team's apps, then set up a bench from it.", 14, opacity: 0.75, margin: new Thickness(0, 6, 0, 12)));
        _addButton = Ui.Button("Add Profile", ShowAddMenu, "Add Profile", primary: false, minWidth: 0);
        _addButton.HorizontalAlignment = HorizontalAlignment.Left;
        _addButton.Margin = new Thickness(0, 0, 0, 12);
        root.Children.Add(_addButton);
        root.Children.Add(_body);
        Content = root;
        Ui.Name(this, "Team Profiles");

        AllowDrop = true;
        Drop += (_, e) =>
        {
            if (e.Data.GetData(DataFormats.FileDrop) is string[] files && files.FirstOrDefault(f => f.EndsWith(".toml", StringComparison.OrdinalIgnoreCase)) is { } file)
                Import(file, autoReview: true);
        };

        _model.Changed += Render;
        Render();
    }

    public PageServices Services => _services;

    internal ProfilesModel Model => _model;

    // --- seams; the defaults are the real dialogs ---

    /// <summary>Shows a sheet and returns when it closes. A test records it and does not show it.</summary>
    internal Action<SheetWindow> ShowSheet { get; set; } = sheet => sheet.ShowDialog();

    internal Func<string?> PickImportFile { get; set; } = () =>
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Title = "Choose a BenchBar profile", Filter = "BenchBar profile (*.toml)|*.toml|All files (*.*)|*.*" };
        return dialog.ShowDialog() == true ? dialog.FileName : null;
    };

    internal Func<string, string?> PickExportFile { get; set; } = suggested =>
    {
        var dialog = new Microsoft.Win32.SaveFileDialog { Title = "Save the profile to share", FileName = suggested, DefaultExt = ".toml", Filter = "BenchBar profile (*.toml)|*.toml" };
        return dialog.ShowDialog() == true ? dialog.FileName : null;
    };

    /// <summary>Asks title and message; true when the person confirmed.</summary>
    internal Func<string, string, bool> Confirm { get; set; } = null!; // set in the constructor: the box needs the owner window

    /// <summary>Opens Explorer on a Windows path (<c>explorer.exe /select,PATH</c>).</summary>
    internal Action<string> RevealWindowsPath { get; set; } = path =>
    {
        try
        {
            var info = new ProcessStartInfo("explorer.exe") { UseShellExecute = false };
            info.ArgumentList.Add("/select," + path);
            Process.Start(info)?.Dispose();
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            // Explorer is always there; nothing to say if it is not
        }
    };

    internal Func<string?> Distro { get; set; } = () => DistroName.Resolve(TrayConfig.Load().Distro);

    /// <summary>Called each time the pane is selected in the sidebar (reads the profiles here, not in the constructor).</summary>
    public void OnShown() => _ = _model.LoadAsync();

    // --- the Add Profile menu ---

    /// <summary>The three ways to add a profile; Create from Bench needs a bench to read.</summary>
    internal ContextMenu BuildAddMenu()
    {
        var menu = new ContextMenu { PlacementTarget = _addButton, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
        Ui.Name(menu, "Add Profile");
        var create = new MenuItem { Header = "Create from Bench...", IsEnabled = _model.Benches.Count > 0 };
        create.Click += (_, _) => CreateFromBench();
        var import = new MenuItem { Header = "Import..." };
        import.Click += (_, _) => Import();
        var subscribe = new MenuItem { Header = "Subscribe to a Repository..." };
        subscribe.Click += (_, _) => Subscribe();
        menu.Items.Add(create);
        menu.Items.Add(import);
        menu.Items.Add(subscribe);
        return menu;
    }

    private void ShowAddMenu() => BuildAddMenu().IsOpen = true;

    internal void CreateFromBench()
    {
        if (_model.Benches.Count == 0) return;
        var sheet = new CreateProfileSheet(_model.Benches, _services.Theme(), _services.Owner());
        ShowSheet(sheet);
        if (sheet.Accepted && sheet.SelectedBenchPath is { } bench && ProfileName.IsValid(sheet.ProfileNameText.Trim()))
            _ = _model.CreateAsync(sheet.ProfileNameText.Trim(), bench);
    }

    internal ImportProfileSheet Import(string source = "", bool autoReview = false)
    {
        var run = new ProfileImportRun(_services.Cli, _wsl, source);
        var sheet = new ImportProfileSheet(run, _services.Theme(), _services.Owner(), PickImportFile, RevealLinuxPath, autoReview);
        ShowSheet(sheet);
        _ = _model.ReloadAsync();
        return sheet;
    }

    internal SubscribeProfilesSheet Subscribe()
    {
        var run = new ProfileSubscribeRun(_services.Cli, _wsl);
        var sheet = new SubscribeProfilesSheet(run, _services.Theme(), _services.Owner(), RevealLinuxPath);
        ShowSheet(sheet);
        _ = _model.ReloadAsync();
        return sheet;
    }

    // --- per profile ---

    internal ExportProfileSheet Export(ProfileInfo profile)
    {
        var run = new ProfileExportRun(_services.Cli, _wsl, profile.Name);
        var sheet = new ExportProfileSheet(run, _services.Theme(), _services.Owner(), PickExportFile, RevealWindowsOrLinux, _services.CopyText);
        _ = run.LoadAsync();
        ShowSheet(sheet);
        return sheet;
    }

    internal UpdateProfileSheet Update(ProfileInfo profile)
    {
        var run = new ProfileUpdateRun(_services.Cli, _wsl, profile.Name);
        var sheet = new UpdateProfileSheet(run, _services.Theme(), _services.Owner());
        _ = run.LoadAsync();
        ShowSheet(sheet);
        _ = _model.ReloadAsync();
        return sheet;
    }

    internal CheckAccessSheet CheckAccess(ProfileInfo profile)
    {
        var run = new ProfileCheckRun(_services.Cli, _wsl, profile.Name);
        var sheet = new CheckAccessSheet(run, _services.Theme(), _services.Owner());
        _ = run.LoadAsync();
        ShowSheet(sheet);
        return sheet;
    }

    /// <summary>Show in Explorer: the profile's file inside the distro, as <c>\\wsl.localhost\DISTRO\...</c>.</summary>
    internal void ShowInExplorer(ProfileInfo profile) => RevealLinuxPath(profile.File);

    private void RevealLinuxPath(string linuxPath)
    {
        if (Distro() is not { Length: > 0 } distro)
        {
            _notice = "BenchBar could not tell which Linux distro to open. Set one in Settings, then try again.";
            Render();
            return;
        }
        RevealWindowsPath(WslPaths.ToWindows(distro, linuxPath));
    }

    /// <summary>The export result is the Windows path the person chose; an import or subscription result is a Linux path.</summary>
    private void RevealWindowsOrLinux(string path)
    {
        if (WslPaths.IsWindowsPath(path)) RevealWindowsPath(path);
        else RevealLinuxPath(path);
    }

    /// <summary>Remove: asks first, then <c>profile remove NAME --yes --json</c>. The file is moved aside, never deleted.</summary>
    internal async Task RemoveAsync(ProfileInfo profile)
    {
        if (_model.IsRemoving || !Confirm(ProfilesModel.RemoveTitle(profile), _model.RemoveMessage(profile))) return;
        await _model.RemoveAsync(profile);
        _services.RefreshNow();
    }

    // --- drawing ---

    /// <summary>Every line of text in the body, in order (for tests).</summary>
    internal IReadOnlyList<string> Lines { get; private set; } = [];

    /// <summary>The labels of the buttons in the body, in order (for tests).</summary>
    internal IReadOnlyList<string> ButtonLabels { get; private set; } = [];

    private void Render()
    {
        var lines = new List<string>();
        var buttons = new List<string>();
        _body.Children.Clear();

        void Line(string text, double size = 14, double opacity = 1, Brush? brush = null, Thickness? margin = null)
        {
            var block = Ui.Text(text, size, null, opacity, margin ?? new Thickness(0, 0, 0, 6));
            if (brush is not null) block.Foreground = brush;
            _body.Children.Add(block);
            lines.Add(text);
        }

        if (_notice is { } notice) Line(notice, 13, brush: Ui.CriticalBrush);
        if (_model.ActionError is { } actionError) Line(actionError, 13, brush: Ui.CriticalBrush);
        if (_model.Message is { } message) Line(message, 13, 0.85);

        if (!_model.HasLoaded && _model.IsLoading)
        {
            Line("Reading profiles...", 14, 0.8);
        }
        else if (_model.Profiles.Count == 0 && _model.Error is { } error)
        {
            AddEmpty("The profiles could not be read", error, "Try Again", () => _ = _model.LoadAsync(), lines, buttons);
        }
        else
        {
            _body.Children.Add(Ui.Text("Profiles", 16, FontWeights.SemiBold, margin: new Thickness(0, 4, 0, 6)));
            lines.Add("Profiles");
            foreach (var profile in _model.Profiles) _body.Children.Add(Row(profile, lines, buttons));
            if (_model.HasLoaded && _model.Profiles.Count > 0 && !_model.HasTeamProfile)
            {
                AddEmpty("Only the built in profiles",
                    "A team profile pins your team's apps and branches, so everyone sets up the same bench.",
                    "Import...", () => Import(), lines, buttons);
            }
            if (_model.Error is { } listError) Line(listError, 12, brush: Ui.CriticalBrush);
        }

        Line("Set up a bench from one with benchbar install --profile NAME. Team profiles are files in ~/.config/benchbar/profiles inside Linux, a subscribed repository or a folder in BENCHBAR_PROFILE_PATH, never inside BenchBar. Drop a .toml file here to import it.",
            12, 0.7, margin: new Thickness(0, 14, 0, 0));
        Lines = lines;
        ButtonLabels = buttons;
    }

    private void AddEmpty(string title, string line, string actionLabel, Action action, List<string> lines, List<string> buttons)
    {
        var panel = new StackPanel { Margin = new Thickness(0, 20, 0, 8) };
        panel.Children.Add(Ui.Text(title, 18, FontWeights.SemiBold));
        panel.Children.Add(Ui.Text(line, 14, opacity: 0.75, margin: new Thickness(0, 6, 0, 12)));
        var button = Ui.Button(actionLabel, action, actionLabel, primary: true, minWidth: 0);
        button.HorizontalAlignment = HorizontalAlignment.Left;
        panel.Children.Add(button);
        _body.Children.Add(panel);
        lines.Add(title);
        lines.Add(line);
        buttons.Add(actionLabel);
    }

    private UIElement Row(ProfileInfo profile, List<string> lines, List<string> buttons)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var icon = Ui.Text(profile.IsTeam ? "◆" : "▢", 14, margin: new Thickness(2, 2, 12, 0));
        icon.Foreground = profile.Valid ? Ui.StepBrush(InstallStepStatus.Running) : Ui.StepBrush(InstallStepStatus.Failed);
        Ui.Name(icon, profile.IsTeam ? "Team profile" : "Built in profile");
        grid.Children.Add(icon);

        var text = new StackPanel();
        Grid.SetColumn(text, 1);
        var head = new WrapPanel();
        head.Children.Add(Ui.Text(profile.Name, 15, FontWeights.SemiBold, margin: new Thickness(0, 0, 8, 0)));
        lines.Add(profile.Name);
        void Tag(string tag, bool warn = false)
        {
            var block = Ui.Caption(tag);
            block.Margin = new Thickness(0, 3, 8, 0);
            if (warn) block.Foreground = Ui.StepBrush(InstallStepStatus.Warning);
            head.Children.Add(block);
            lines.Add(tag);
        }
        Tag(profile.OriginText);
        if (profile.Base is { } b) Tag("based on " + b);
        if (profile.Subscription?.OutdatedText is { } outdated) Tag(outdated, warn: true);
        text.Children.Add(head);
        void Sub(string value, Brush? brush = null)
        {
            var block = Ui.Caption(value);
            if (brush is not null) block.Foreground = brush;
            text.Children.Add(block);
            lines.Add(value);
        }
        if (profile.Label is { Length: > 0 } label) Sub(label);
        if (profile.Error is { Length: > 0 } error) Sub(error, Ui.StepBrush(InstallStepStatus.Failed));
        if (profile.ShadowedBy is { Length: > 0 } winner)
            Sub($"Not used: {winner} has the same name and comes first", Ui.StepBrush(InstallStepStatus.Warning));
        if (profile.IsTeam) Sub(profile.SourceUrl ?? profile.File);
        grid.Children.Add(text);

        if (profile.IsTeam)
        {
            var more = Ui.Button("Actions", () => { }, $"Actions for {profile.Name}", minWidth: 0);
            more.Margin = new Thickness(12, 0, 0, 0);
            more.VerticalAlignment = VerticalAlignment.Top;
            more.Click += (_, _) =>
            {
                var menu = BuildProfileMenu(profile);
                menu.PlacementTarget = more;
                menu.IsOpen = true;
            };
            Grid.SetColumn(more, 2);
            grid.Children.Add(more);
            buttons.Add("Actions");
        }
        return Ui.CardOf(grid, new Thickness(0, 0, 0, 6));
    }

    /// <summary>Export, Update, Check Access, Show in Explorer, Remove: the ones that apply to this profile.</summary>
    internal ContextMenu BuildProfileMenu(ProfileInfo profile)
    {
        var menu = new ContextMenu { Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
        Ui.Name(menu, $"Actions for {profile.Name}");
        MenuItem Item(string header, Action click, bool enabled = true)
        {
            var item = new MenuItem { Header = header, IsEnabled = enabled };
            item.Click += (_, _) => click();
            menu.Items.Add(item);
            return item;
        }
        Item("Export...", () => Export(profile), profile.CanExport);
        if (profile.CanUpdate) Item("Update...", () => Update(profile));
        Item("Check Access", () => CheckAccess(profile), profile.CanCheck);
        Item("Show in Explorer", () => ShowInExplorer(profile));
        if (profile.CanRemove)
        {
            menu.Items.Add(new Separator());
            Item(profile.Origin == ProfileOrigin.Subscribed ? "Remove Subscription..." : "Remove...", () => _ = RemoveAsync(profile), !_model.IsRemoving);
        }
        return menu;
    }
}
