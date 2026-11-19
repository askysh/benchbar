using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>What the Quick Switch panel needs from the app. Harmless defaults, so tests build the window without an app.</summary>
internal sealed class QuickSwitchHost
{
    public ICliClient Cli { get; set; } = new CliClient(new ScriptedStreamRunner(), () => "benchbar.exe");

    /// <summary>The benches as the last poll saw them; read once when the panel opens.</summary>
    public Func<IReadOnlyList<BenchStatus>> Benches { get; set; } = () => [];

    public OpenAsPins Pins { get; set; } = new();

    /// <summary>The user and the site key of the last user the panel opened, kept for the session only: it names the row marked "last opened".</summary>
    public Func<string?> LastTarget { get; set; } = () => null;

    public Func<string, string?> LastUser { get; set; } = _ => null;

    public Action<QuickSwitchTarget, string> Opened { get; set; } = (_, _) => { };

    public TimeSpan Debounce { get; set; } = TimeSpan.FromMilliseconds(250);
}

/// <summary>
/// Quick Switch (macos QuickSwitchPanel): a small panel that opens a site signed in as Administrator, a pinned user or a user found by
/// typing, from the keyboard: Up and Down, Enter, Esc, and 0 to 9 while the field is empty. It runs <c>open --as USER --json</c>, so the
/// CLI opens the browser and no sign in link reaches the panel. Open as being on for the site is the person's earlier decision: a site
/// without it is not a target, and the panel says how to turn it on instead of doing it.
/// </summary>
internal sealed class QuickSwitchWindow : Window
{
    private readonly QuickSwitchHost _host;
    private readonly IReadOnlyList<BenchStatus> _benches;
    private readonly IReadOnlyList<QuickSwitchTarget> _targets;
    private readonly TextBox _search = new() { Margin = new Thickness(0, 8, 0, 8), Padding = new Thickness(6) };
    private readonly ListBox _list = new() { BorderThickness = new Thickness(0), Background = System.Windows.Media.Brushes.Transparent, MinHeight = 120 };
    private readonly TextBlock _status = Ui.Text("", 12, opacity: 0.85, margin: new Thickness(0, 8, 0, 0));
    private readonly DispatcherTimer _debounce = new();
    private CancellationTokenSource? _searching;
    private QuickSwitchModel? _model;
    private bool _opening;

    public QuickSwitchWindow(QuickSwitchHost host, ResolvedTheme theme)
    {
        _host = host;
        _benches = host.Benches();
        _targets = QuickSwitchTargets.From(_benches);
        Title = "Quick Switch";
        Width = 460;
        SizeToContent = SizeToContent.Height;
        MaxHeight = 560;
        Topmost = true;
        ShowInTaskbar = false;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Ui.ApplyTheme(this, theme);
        Ui.Name(this, "Quick Switch");

        var root = new StackPanel { Margin = new Thickness(16) };
        root.Children.Add(Ui.Text("Open as", 16, FontWeights.SemiBold));
        if (QuickSwitchTargets.Blocker(_benches, _targets) is { } blocker)
        {
            root.Children.Add(PagePanels.Line(blocker));
            SetStatus(blocker);
            Content = root;
            Blocker = blocker;
            PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
            return;
        }

        var last = host.LastTarget();
        var start = _targets.FirstOrDefault(t => t.Key == last) ?? _targets[0];
        if (_targets.Count > 1)
        {
            var combo = new ComboBox { Margin = new Thickness(0, 6, 0, 0) };
            foreach (var t in _targets) combo.Items.Add(t.Title);
            combo.SelectedIndex = _targets.ToList().IndexOf(start);
            combo.SelectionChanged += (_, _) => { if (combo.SelectedIndex >= 0) Select(_targets[combo.SelectedIndex]); };
            Ui.Name(combo, "Site to open");
            root.Children.Add(combo);
        }
        else
        {
            root.Children.Add(Ui.Text(start.Title, 13, opacity: 0.75, margin: new Thickness(0, 4, 0, 0)));
        }
        Ui.Name(_search, "Search users");
        Ui.Name(_list, "Users");
        _search.TextChanged += (_, _) => OnTyped();
        root.Children.Add(_search);
        root.Children.Add(_list);
        root.Children.Add(_status);
        Content = root;
        PreviewKeyDown += OnKey;
        _debounce.Tick += (_, _) => { _debounce.Stop(); SearchAsync().Forget(); };
        Closed += (_, _) => { _debounce.Stop(); _searching?.Cancel(); };
        ContentRendered += (_, _) => _search.Focus();
        Select(start);
    }

    /// <summary>Why there is nothing to open (the panel then shows only that line), or null.</summary>
    public string? Blocker { get; }

    internal QuickSwitchModel? Model => _model;

    /// <summary>The status line under the list: searching, an error, or what was opened.</summary>
    public string StatusText => _status.Text;

    /// <summary>True while the status line has the error colour (for tests).</summary>
    internal bool StatusIsError => _status.ReadLocalValue(TextBlock.ForegroundProperty) != DependencyProperty.UnsetValue;

    public IReadOnlyList<string> RowTexts => [.. _list.Items.OfType<ListBoxItem>().Select(i => (string)i.Content)];

    public TextBox SearchBox => _search;

    private void Select(QuickSwitchTarget target)
    {
        _model = new QuickSwitchModel(target, _host.Pins.Of(target.Bench, target.Site), _host.LastUser(target.Key));
        SetStatus("");
        Draw();
    }

    /// <summary>The one place the status line is set: a plain line takes the normal colour back, so an error never colours the next message.</summary>
    private void SetStatus(string text, bool error = false)
    {
        _status.Text = text;
        if (error) _status.Foreground = Ui.CriticalBrush;
        else _status.ClearValue(TextBlock.ForegroundProperty);
    }

    private void OnTyped()
    {
        if (_model is null) return;
        _model.SetQuery(_search.Text);
        if (!_opening) SetStatus(""); // the line belongs to the last text: "No users match" and an old error go with it
        Draw();
        // two characters or more ask the CLI: until it answers, an empty list is not yet "no match"
        if (_model.WantsSearch && !_opening) SetStatus("");
        _debounce.Stop();
        _searching?.Cancel();
        if (!_model.WantsSearch) return;
        _debounce.Interval = _host.Debounce;
        _debounce.Start();
    }

    private void Draw()
    {
        if (_model is null) return;
        _list.Items.Clear();
        foreach (var row in _model.Rows)
        {
            var text = string.Join("   ", new[] { row.Digit is { } d ? d.ToString() : "", row.Title, row.Detail ?? "", row.Hint }.Where(s => s.Length > 0));
            var item = new ListBoxItem { Content = text };
            AutomationProperties.SetName(item, row.Spoken);
            _list.Items.Add(item);
        }
        if (_list.Items.Count > 0) _list.SelectedIndex = Math.Clamp(_model.Selection, 0, _list.Items.Count - 1);
        else SetStatus("No users match");
    }

    internal async Task SearchAsync()
    {
        if (_model is not { WantsSearch: true } model) return;
        _searching?.Cancel();
        var cts = _searching = new CancellationTokenSource();
        SetStatus("Searching...");
        var args = OpenAsCommands.Users(model.Target.Site, model.Query, model.Target.Bench, QuickSwitchModel.SearchLimit);
        CliResult<SiteUserList> result;
        try
        {
            result = await _host.Cli.RunJsonAsync(args, null, CliTimeouts.Read, OpenAsJson.ParseUsers, cts.Token);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        if (cts.IsCancellationRequested || !ReferenceEquals(_model, model)) return;
        if (result.Value is { } list)
        {
            model.SetRemote(list.Users);
            SetStatus("");
            Draw();
        }
        else
        {
            SetStatus("Could not search users: " + (OpenAsRules.CliSentence(result.Error) ?? "no answer"), error: true);
        }
    }

    private void OnKey(object sender, KeyEventArgs e)
    {
        if (HandleKey(e.Key, Keyboard.Modifiers)) e.Handled = true;
    }

    /// <summary>
    /// The panel's keys: Esc closes, Up and Down move, Enter opens the selected row, 0 to 9 open a row at once while the field is empty and
    /// no modifier is down (Shift+1 is "!", not pin 1, and Ctrl, Alt and Win digits belong to Windows and to the person). True when the key was used.
    /// </summary>
    internal bool HandleKey(Key key, ModifierKeys modifiers = ModifierKeys.None)
    {
        if (_model is null) return false;
        switch (key)
        {
            case Key.Escape: Close(); return true;
            case Key.Down: _model.Move(1); Draw(); return true;
            case Key.Up: _model.Move(-1); Draw(); return true;
            case Key.Enter: OpenTask = OpenAsync(_model.Confirm()); OpenTask.Forget(); return true;
        }
        var digit = key is >= Key.D0 and <= Key.D9 ? key - Key.D0 : key is >= Key.NumPad0 and <= Key.NumPad9 ? key - Key.NumPad0 : -1;
        if (digit < 0 || modifiers != ModifierKeys.None || _model.ByDigit(digit) is not { } row) return false;
        OpenTask = OpenAsync(row);
        OpenTask.Forget();
        return true;
    }

    /// <summary>The last open the keys started; tests wait on it.</summary>
    internal Task OpenTask { get; private set; } = Task.CompletedTask;

    /// <summary>Opens the site signed in as the row's user. One at a time: a second Return while it runs does nothing. The window closes on success.</summary>
    internal async Task OpenAsync(QuickSwitchRow? row)
    {
        if (row is null || _model is not { } model) return;
        if (_opening)
        {
            SetStatus("Already opening...");
            return;
        }
        _opening = true;
        SetStatus($"Opening as {row.Title}...");
        try
        {
            var target = model.Target;
            var result = await _host.Cli.RunJsonAsync(OpenAsCommands.OpenAs(target.Site, row.User, target.Bench), OpenAsCommands.PersonEnvironment(),
                CliTimeouts.Plan, OpenAsJson.Opened);
            if (result.Ok && result.Value)
            {
                _host.Opened(target, row.User);
                Close();
                return;
            }
            SetStatus(OpenAsRules.CliSentence(result.Error) ?? $"{target.Site} could not be opened as {row.Title}.", error: true);
        }
        finally
        {
            _opening = false;
        }
    }
}
