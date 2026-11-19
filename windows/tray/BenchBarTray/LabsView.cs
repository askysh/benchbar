using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// Labs, the experiments (macos Settings > Labs): one row per experiment of <c>benchbar.exe labs list --json</c> with a switch, its
/// warning, the version it came in and, for one that is not on Windows yet, why. The switch runs <c>labs on</c> or <c>labs off</c> through
/// the CLI, which keeps the flags. The rules are in <see cref="LabsModel"/>; this draws them. Rebuilt only when the model changes.
/// </summary>
internal sealed class LabsView : UserControl
{
    private readonly LabsModel _model;
    private readonly StackPanel _body = new();

    public LabsView(PageServices services) : this(new LabsModel(services.Cli)) { }

    internal LabsView(LabsModel model)
    {
        _model = model;
        var root = new StackPanel { MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Left };
        root.Children.Add(Ui.Title("Labs"));
        root.Children.Add(Ui.Text("Experiments are off until you turn one on. Each one has a warning, and the CLI keeps the switch, so benchbar.exe labs shows the same state.",
            14, opacity: 0.75, margin: new Thickness(0, 6, 0, 12)));
        root.Children.Add(_body);
        root.Children.Add(Ui.Text(LabsText.Footer, 12, opacity: 0.7, margin: new Thickness(0, 14, 0, 0)));
        Content = new ScrollViewer { Content = root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(0, 0, 12, 0) };
        Ui.Name(this, "Labs");
        _model.Changed += Render;
        Render();
    }

    internal LabsModel Model => _model;

    /// <summary>The texts shown, one per line, for tests.</summary>
    public IReadOnlyList<string> Lines { get; private set; } = [];

    /// <summary>The switches, by lab name (for tests and for the keyboard).</summary>
    public IReadOnlyDictionary<string, CheckBox> Switches => _switches;

    private readonly Dictionary<string, CheckBox> _switches = [];

    /// <summary>Called each time the pane is selected in the sidebar: one CLI call, and the model skips it when the last one was under 5 s ago.</summary>
    public void OnShown() => _model.RefreshAsync().Forget();

    private void Render()
    {
        var lines = new List<string>();
        _body.Children.Clear();
        _switches.Clear();

        void Line(string text, double size = 13, double opacity = 1, System.Windows.Media.Brush? brush = null, Thickness? margin = null)
        {
            var block = Ui.Text(text, size, null, opacity, margin ?? new Thickness(0, 2, 0, 0));
            if (brush is not null) block.Foreground = brush;
            _body.Children.Add(block);
            lines.Add(text);
        }

        if (_model.Availability == LabsAvailability.Unsupported)
        {
            Line(LabsText.Unsupported, 14, 0.8);
        }
        else if (_model.Availability == LabsAvailability.CliMissing)
        {
            Line(_model.RefreshError ?? "BenchBar cannot find benchbar.exe", 14, 0.8);
        }
        else
        {
            if (_model.RefreshError is { } problem) Line(problem, 13, brush: Ui.CriticalBrush);
            if (_model.Availability == LabsAvailability.Unknown && _model.IsLoading) Line("Reading the experiments...", 14, 0.8);
            foreach (var entry in _model.Entries) _body.Children.Add(Row(entry, lines));
            if (_model.Availability == LabsAvailability.Available && _model.Entries.Count == 0) Line("This version of BenchBar has no experiments.", 14, 0.8);
        }
        Lines = lines;
    }

    private UIElement Row(LabEntry entry, List<string> lines)
    {
        var card = new StackPanel { Margin = new Thickness(0, 0, 0, 12) };
        var busy = _model.IsBusy(entry.Name);
        var toggle = new CheckBox
        {
            IsChecked = entry.Enabled,
            IsEnabled = !busy && entry.CanToggle,
            Content = new TextBlock { Text = entry.Title, FontSize = 14, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap },
            Margin = new Thickness(0, 0, 0, 2),
        };
        Ui.Name(toggle, entry.Title, entry.Description);
        toggle.Click += (_, _) => _model.SetAsync(entry.Name, toggle.IsChecked == true).Forget();
        _switches[entry.Name] = toggle;
        card.Children.Add(toggle);
        lines.Add(entry.Title);

        void Add(string text, double size, double opacity = 1, System.Windows.Media.Brush? brush = null)
        {
            var block = Ui.Text(text, size, null, opacity, new Thickness(24, 2, 0, 0));
            if (brush is not null) block.Foreground = brush;
            card.Children.Add(block);
            lines.Add(text);
        }

        if (entry.Description.Length > 0) Add(entry.Description, 13, 0.85);
        if (entry.WhyNotHere is { } why) Add(why, 12, 0.8);
        if (entry.Warning.Length > 0)
        {
            // an experiment that is on keeps its warning in the caution color, as the Mac's Settings does
            if (entry.Enabled) Add("Warning: " + entry.Warning, 13, brush: Ui.CautionTextBrush);
            else Add(entry.Warning, 13, 0.75);
        }
        if (entry.Since.Length > 0) Add("since " + entry.Since, 12, 0.65);
        if (busy) Add(entry.Enabled ? "Turning it off..." : "Turning it on...", 12, 0.8);
        if (_model.ErrorOf(entry.Name) is { } error) Add(error, 13, brush: Ui.CriticalBrush);
        return card;
    }
}
