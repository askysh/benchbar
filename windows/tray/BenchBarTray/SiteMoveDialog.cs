using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// Move to Another Bench, the question before the plan: which registered bench the site goes to, and whether to skip <c>bench migrate</c>
/// there. It runs nothing. Review Plan closes it with a <see cref="SiteMoveRequest"/>, and the plan sheet reads the plan of exactly that.
/// </summary>
internal sealed class SiteMoveDialog : Window
{
    private readonly IReadOnlyList<BenchStatus> _targets;
    private readonly ComboBox _target = new() { MinWidth = 400, Padding = new Thickness(8, 6, 8, 6), HorizontalAlignment = HorizontalAlignment.Left };
    private readonly CheckBox _skip = new() { Content = "Skip migrate", Margin = new Thickness(0, 0, 0, 4) };
    private readonly string _site;
    private readonly string _source;

    public SiteMoveDialog(string site, string sourceBench, IReadOnlyList<BenchStatus> targets, ResolvedTheme theme, Window? owner)
    {
        _site = site;
        _source = sourceBench;
        _targets = targets;
        Title = $"Move {site}";
        Width = 500;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = owner is null;
        Owner = owner;
        WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;
        Ui.ApplyTheme(this, theme);
        Ui.Name(this, Title);

        var panel = new StackPanel { Margin = new Thickness(24) };
        panel.Children.Add(Ui.Text(Title, 18, FontWeights.SemiBold));
        panel.Children.Add(Ui.Text($"Moves {site} to another bench on this machine. Nothing changes yet: the next step shows the plan.", 13, opacity: 0.85, margin: new Thickness(0, 6, 0, 14)));
        foreach (var bench in targets) _target.Items.Add($"{bench.Name}  ({bench.Path})");
        _target.SelectedIndex = targets.Count > 0 ? 0 : -1;
        AutomationProperties.SetName(_target, "Target bench");
        panel.Children.Add(Ui.Labeled("Move to", _target));
        AutomationProperties.SetName(_skip, "Skip migrate");
        panel.Children.Add(_skip);
        panel.Children.Add(Ui.Text("The site arrives on the schema it had. Run bench migrate yourself afterwards.", 12, opacity: 0.7, margin: new Thickness(24, 0, 0, 0)));

        var bar = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        Review = Ui.Button("Review Plan", () => Choose(), "Review Plan", primary: true);
        var cancel = Ui.Button("Cancel", () => DialogResult = false, "Cancel");
        cancel.IsCancel = true;
        cancel.Margin = new Thickness(0);
        bar.Children.Add(Review);
        bar.Children.Add(cancel);
        panel.Children.Add(bar);
        Content = panel;
    }

    public Button Review { get; }

    /// <summary>What the person chose, set by Review Plan; null when cancelled.</summary>
    public SiteMoveRequest? Chosen { get; private set; }

    internal void Select(int index) => _target.SelectedIndex = index;

    internal bool SkipMigrate { get => _skip.IsChecked == true; set => _skip.IsChecked = value; }

    internal void Choose()
    {
        if (_target.SelectedIndex is var i and >= 0 && i < _targets.Count) Chosen = new SiteMoveRequest(_site, _targets[i].Path, SkipMigrate, _source);
        if (Chosen is null) return;
        try { DialogResult = true; }
        catch (InvalidOperationException) { } // not shown as a dialog (a test): the choice is in Chosen
    }

    public static SiteMoveRequest? Ask(string site, string sourceBench, IReadOnlyList<BenchStatus> targets, ResolvedTheme theme, Window? owner)
    {
        var dialog = new SiteMoveDialog(site, sourceBench, targets, theme, owner);
        return dialog.ShowDialog() == true ? dialog.Chosen : null;
    }
}
