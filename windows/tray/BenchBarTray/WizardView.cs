using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Threading;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>What the wizard's views do outside the model. Defaults are harmless so tests can build the view alone.</summary>
internal sealed class WizardActions
{
    /// <summary>"Restart Windows now?" The view only asks; the model restarts.</summary>
    public Func<bool> ConfirmRestart { get; set; } = () => false;

    /// <summary>Opens the install log (a Linux path inside the distro) in Notepad or Explorer.</summary>
    public Action<string> OpenLog { get; set; } = _ => { };

    /// <summary>Report a Bug from the wizard: the entry point ("Setup wizard footer", "Report This Problem") and the failure next to the button, if any.</summary>
    public Action<string, string?> ReportBug { get; set; } = (_, _) => { };
}

/// <summary>One page of the wizard: its content, what the buttons are, and how to bring it up to date with the model.</summary>
internal sealed class PageParts
{
    public string Title { get; init; } = "";
    public string Subtitle { get; init; } = "";
    public UIElement Content { get; init; } = new Grid();
    public Action Refresh { get; set; } = () => { };
    public List<Button> Left { get; } = [];
    public List<Button> Right { get; } = [];
    public Control? Focus { get; set; }

    /// <summary>Changes the heading while the page stays (the install page becomes "Install Failed"). Set by the view.</summary>
    public Action<string, string> SetHeading { get; set; } = (_, _) => { };
}

/// <summary>
/// The wizard's frame: a title, the page, and a button bar. It reads <see cref="WizardModel"/> and draws; the rules live in the
/// model. A page is built once when it is entered and then only refreshed, so a poll or a log line never takes the caret out of a field.
/// </summary>
internal sealed partial class WizardView : UserControl
{
    private readonly WizardModel _model;
    private readonly WizardActions _actions;
    private readonly TextBlock _title = Ui.Text("", 26, FontWeights.SemiBold);
    private readonly TextBlock _subtitle = Ui.Text("", 14, opacity: 0.75, margin: new Thickness(0, 4, 0, 0));
    private readonly ContentControl _body = new();
    private readonly StackPanel _left = new() { Orientation = Orientation.Horizontal };
    private readonly StackPanel _right = new() { Orientation = Orientation.Horizontal };
    private PageParts? _page;
    private WizardPage? _builtPage;
    private bool _refreshQueued;

    public WizardView(WizardModel model, WizardActions actions)
    {
        _model = model;
        _actions = actions;

        var header = new StackPanel { Margin = new Thickness(40, 32, 40, 16) };
        header.Children.Add(_title);
        header.Children.Add(_subtitle);
        Ui.Name(_title, "Page title");
        // no focus rectangle around the page or its parts: only the controls inside it take the focus
        FocusVisualStyle = null;
        Focusable = false;
        _body.FocusVisualStyle = null;
        _body.Focusable = false;
        _body.IsTabStop = false;

        var bar = new DockPanel { Margin = new Thickness(40, 12, 40, 8), LastChildFill = false };
        DockPanel.SetDock(_left, Dock.Left);
        DockPanel.SetDock(_right, Dock.Right);
        bar.Children.Add(_left);
        bar.Children.Add(_right);

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var scroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, // the page wraps to the window; it never measures wider
            Content = _body,
            Padding = new Thickness(40, 0, 40, 0),
            Focusable = false,
        };
        Grid.SetRow(header, 0);
        Grid.SetRow(scroll, 1);
        Grid.SetRow(bar, 2);
        // on every page: a way to tell us, before anything has gone wrong
        var footer = Ui.Link(BetaText.ReportABug, () => _actions.ReportBug("Setup wizard footer", null), "Report a Bug");
        footer.Margin = new Thickness(36, 0, 40, 16);
        Grid.SetRow(footer, 3);
        root.Children.Add(header);
        root.Children.Add(scroll);
        root.Children.Add(bar);
        root.Children.Add(footer);
        Content = root;

        _model.Changed += OnChanged;
        Unloaded += (_, _) => _model.Changed -= OnChanged;
        Rebuild();
    }

    public WizardModel Model => _model;

    /// <summary>The page on screen, for tests and the window title.</summary>
    public PageParts? Current => _page;

    public string TitleText => _title.Text;

    /// <summary>A step, a check or the install runs now: the window should not close without asking.</summary>
    public bool IsBusy => _model.IsInstalling || _model.BusyStepId is not null || _model.CreatingUser;

    private void OnChanged()
    {
        if (_refreshQueued) return;
        _refreshQueued = true;
        // one refresh per burst of events, after the UI has handled input
        Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
        {
            _refreshQueued = false;
            Update();
        });
    }

    /// <summary>Brings the view up to date now (the dispatcher does it for a burst of changes).</summary>
    public void Update()
    {
        if (_builtPage != _model.Page) Rebuild();
        else _page?.Refresh();
    }

    private void Rebuild()
    {
        _builtPage = _model.Page;
        var page = Build(_model.Page);
        _page = page;
        page.SetHeading = SetHeading;
        SetHeading(page.Title, page.Subtitle);
        _body.Content = Ui.Constrain(page.Content, MaxWidthOf(_model.Page));
        _left.Children.Clear();
        _right.Children.Clear();
        foreach (var b in page.Left) _left.Children.Add(b);
        foreach (var b in page.Right) _right.Children.Add(b);
        page.Refresh();
        var focus = page.Focus is { Visibility: Visibility.Visible, IsEnabled: true } wanted
            ? wanted
            : page.Right.FirstOrDefault(b => b.IsEnabled && b.Visibility == Visibility.Visible) as Control;
        if (focus is not null) Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () => focus.Focus());
    }

    private void SetHeading(string title, string subtitle)
    {
        _title.Text = title;
        // the heading is announced by what it says, not by "Page title"
        AutomationProperties.SetName(_title, title);
        _subtitle.Text = subtitle;
        _subtitle.Visibility = subtitle.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>How wide a page's column gets at most; the same on every state of the page, so rows do not change width.</summary>
    internal static double MaxWidthOf(WizardPage page) => page switch
    {
        WizardPage.Welcome or WizardPage.LinuxUser => 560,
        WizardPage.Check or WizardPage.Install => 720,
        _ => 640,
    };

    private PageParts Build(WizardPage page) => page switch
    {
        WizardPage.Welcome => WelcomePage(),
        WizardPage.CliOnly => CliOnlyPage(),
        WizardPage.Check => CheckPage(),
        WizardPage.LinuxUser => LinuxUserPage(),
        WizardPage.ExistingBench => ExistingBenchPage(),
        WizardPage.NewBench => NewBenchPage(),
        WizardPage.Review => ReviewPage(),
        WizardPage.Install => InstallPage(),
        _ => DonePage(),
    };

    // --- shared bits ---

    /// <summary>
    /// Back is the Esc button on pages that hold nothing typed. A page with a password box passes <c>escapes: false</c>: Esc must not
    /// walk away from a half typed password (Back on the Linux user page forgets it).
    /// </summary>
    private Button BackButton(string label = "Back", bool escapes = true)
    {
        var back = Ui.Button(label, _model.Back, label + " to the previous page");
        back.IsCancel = escapes;
        return back;
    }

    /// <summary>A link that sends a bug report with this failure as its context.</summary>
    private Button ReportProblemLink(string problem)
    {
        var link = Ui.Link(BetaText.ReportThisProblem, () => _actions.ReportBug(BetaText.ReportThisProblem, problem), "Report this problem");
        link.Margin = new Thickness(0, 4, 0, 0);
        return link;
    }

    private static Button Primary(string label, Action click, string? name = null)
    {
        var button = Ui.Button(label, click, name, primary: true);
        button.IsDefault = true;
        button.Margin = new Thickness(0);
        return button;
    }

    /// <summary>A text line that appears only when it has text, in the error color when asked.</summary>
    private static TextBlock Note(bool error = false)
    {
        var text = Ui.Text("", 13, margin: new Thickness(0, 0, 0, 10));
        if (error) text.Foreground = Ui.CriticalBrush;
        text.Visibility = Visibility.Collapsed;
        return text;
    }

    private static void Show(TextBlock block, string? text)
    {
        block.Text = text ?? "";
        block.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
    }

    private static Button CopyRow(string label, string text, Action<string> copy, StackPanel into)
    {
        var line = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        var button = Ui.Button("Copy", () => copy(text), "Copy " + label, minWidth: 64);
        button.Margin = new Thickness(8, 0, 0, 0);
        DockPanel.SetDock(button, Dock.Right);
        var box = new TextBox { Text = text, IsReadOnly = true, FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"), FontSize = 12, Padding = new Thickness(8, 6, 8, 6), TextWrapping = TextWrapping.Wrap };
        Ui.Name(box, label);
        line.Children.Add(button);
        line.Children.Add(box);
        into.Children.Add(line);
        return button;
    }

    private static void SetSecret(Action<Secret> set, System.Security.SecureString value) => set(Secret.From(value));
}
