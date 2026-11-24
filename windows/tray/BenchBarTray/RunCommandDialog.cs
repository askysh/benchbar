using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// Run Bench Command (macos has none; the CLI's <c>benchbar run</c>): one command of the allow list as <c>bench [--site S] COMMAND</c>, in the
/// right bench and site, under a deadline. A read (<c>doctor</c>, <c>list-apps</c>, <c>version</c>) runs at once and its output shows here. A
/// command that changes things is not run here: Review Plan closes the dialog with the choice, and the plan sheet shows
/// <c>run --dry-run --json</c> and applies it with <c>--apply TOKEN --yes</c> and that plan's own token. Offered only when the CLI lists
/// <c>run</c>. The flags are the ones the command's row of the allow list names, each value one plain word.
/// </summary>
internal sealed class RunCommandDialog : Window
{
    private readonly PageServices _services;
    private readonly BenchStatus _bench;
    private readonly ComboBox _command = new() { Width = 300, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly ComboBox _site = new() { Width = 300, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly TextBlock _help;
    private readonly TextBox _options;
    private readonly TextBlock _problem = Ui.CriticalText("");
    private readonly TextBox _output = Ui.Mono("");
    private readonly UIElement _siteRow;
    private readonly Button _go;
    private readonly CancellationTokenSource _cancel = new();

    public RunCommandDialog(PageServices services, BenchStatus bench, string? site, ResolvedTheme theme, Window? owner)
    {
        _services = services;
        _bench = bench;
        Title = UiText.Get("RunCmdTitle");
        Width = 520;
        SizeToContent = SizeToContent.Height;
        MaxHeight = 760;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = owner is null;
        Owner = owner;
        WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;
        Ui.ApplyTheme(this, theme);
        Ui.Name(this, UiText.Get("RunCmdTitle"));

        var panel = new StackPanel { Margin = new Thickness(24) };
        panel.Children.Add(Ui.Text(UiText.Get("RunCmdTitle"), 18, FontWeights.SemiBold));
        panel.Children.Add(Ui.Text(UiText.Format("RunCmdIntro", bench.Name), 13, opacity: 0.85, margin: new Thickness(0, 6, 0, 12)));

        _command.ItemsSource = RunAllowList.All.Select(c => c.Name).ToList();
        Ui.Name(_command, UiText.Get("RunCmdCommand"));
        _command.SelectionChanged += (_, _) => CommandChanged();
        panel.Children.Add(Ui.Labeled(UiText.Get("RunCmdCommand"), _command));

        _site.ItemsSource = bench.Sites.Select(s => s.Name).ToList();
        _site.SelectedItem = site ?? bench.Site ?? bench.Sites.FirstOrDefault()?.Name;
        Ui.Name(_site, UiText.Get("RunCmdSite"));
        _siteRow = Ui.Labeled(UiText.Get("RunCmdSite"), _site);
        panel.Children.Add(_siteRow);

        _options = Ui.Field(UiText.Get("RunCmdFlags"), "", _ => _problem.Visibility = Visibility.Collapsed, 400);
        panel.Children.Add(Ui.Labeled(UiText.Get("RunCmdFlagsOptional"), _options, UiText.Get("RunCmdFlagsHint")));
        _help = Ui.Text("", 12, opacity: 0.75, margin: new Thickness(0, 0, 0, 8));
        panel.Children.Add(_help);
        _problem.Visibility = Visibility.Collapsed;
        panel.Children.Add(_problem);
        _output.IsReadOnly = true;
        _output.Visibility = Visibility.Collapsed;
        _output.MaxHeight = 220;
        _output.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        Ui.Name(_output, UiText.Get("RunCmdOutput"));
        panel.Children.Add(_output);

        var bar = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        _go = Ui.Button(UiText.Get("RunCmdRun"), () => Go().Forget(), UiText.Get("RunCmdRun"), primary: true);
        var close = Ui.Button(UiText.Get("RunCmdClose"), () => DialogResult = false, UiText.Get("RunCmdClose"));
        close.IsCancel = true;
        close.Margin = new Thickness(0);
        bar.Children.Add(_go);
        bar.Children.Add(close);
        panel.Children.Add(bar);
        Content = panel;
        Closed += (_, _) => _cancel.Cancel(); // a read still running stops with the dialog, Close button or not
        _command.SelectedIndex = 0;
    }

    /// <summary>What the person chose to review, set when Review Plan closed the dialog; null otherwise.</summary>
    public RunInput? Chosen { get; private set; }

    /// <summary>The last Run of a read; tests wait on it.</summary>
    public Task Pending { get; private set; } = Task.CompletedTask;

    public string GoLabel => (string)_go.Content;

    public string? ProblemText => _problem.Visibility == Visibility.Visible ? _problem.Text : null;

    public string OutputText => _output.Visibility == Visibility.Visible ? _output.Text : "";

    public bool SiteShown => _siteRow.Visibility == Visibility.Visible;

    public string HelpText => _help.Text;

    internal void Choose(string command, string? site = null, string options = "")
    {
        _command.SelectedItem = command;
        if (site is not null) _site.SelectedItem = site;
        _options.Text = options;
    }

    internal void Press() => Go().Forget();

    private RunCommandInfo Current => RunAllowList.Find((string)_command.SelectedItem) ?? RunAllowList.All[0];

    private void CommandChanged()
    {
        var c = Current;
        _help.Text = c.Switches.Count + c.Valued.Count > 0 ? UiText.Format("RunCmdHelpFlags", c.Help, string.Join(", ", c.Switches.Concat(c.Valued))) : UiText.Format("RunCmdHelpNoFlags", c.Help);
        _siteRow.Visibility = c.NeedsSite ? Visibility.Visible : Visibility.Collapsed;
        _go.Content = c.Changes ? UiText.Get("RunCmdReviewPlan") : UiText.Get("RunCmdRun");
        _problem.Visibility = Visibility.Collapsed;
        _output.Visibility = Visibility.Collapsed;
    }

    private async Task Go()
    {
        var input = new RunInput(Current.Name, _site.SelectedItem as string, _options.Text);
        if (RunCommands.Problem(input, _bench.Sites.Select(s => s.Name)) is { } problem)
        {
            _problem.Text = problem;
            _problem.Visibility = Visibility.Visible;
            return;
        }
        if (Current.Changes)
        {
            Chosen = input;
            try { DialogResult = true; }
            catch (InvalidOperationException) { } // not shown as a dialog (a test): the choice is in Chosen
            return;
        }
        _go.IsEnabled = false;
        _problem.Visibility = Visibility.Collapsed;
        _output.Text = UiText.Format("RunCmdRunning", input.Command);
        _output.Visibility = Visibility.Visible;
        Pending = ReadAsync(input);
        await Pending;
    }

    private async Task ReadAsync(RunInput input)
    {
        try
        {
            var r = await _services.Cli.RunJsonAsync(RunCommands.Read(input, _bench.Path), null, TimeSpan.FromMinutes(3), RunCommands.ParseRead, _cancel.Token).ConfigureAwait(true);
            if (r.Value is { } read)
            {
                var text = read.Output.Length > 0 ? read.Output : UiText.Get("RunCmdNoOutput");
                _output.Text = (read.TimedOut ? UiText.Get("RunCmdDeadline") + "\n" : read.Ok ? "" : UiText.Format("RunCmdExit", read.CommandExit) + "\n") + text;
            }
            else
            {
                _output.Visibility = Visibility.Collapsed;
                _problem.Text = r.Error ?? UiText.Get("RunCmdDidNotRun");
                _problem.Visibility = Visibility.Visible;
            }
        }
        catch (OperationCanceledException)
        {
            // the dialog closed: nothing to show
        }
        finally
        {
            _go.IsEnabled = true;
        }
    }

    /// <summary>Shows the dialog; what the person chose to review (a change), or null (closed, or a read that ran).</summary>
    public static RunInput? Ask(PageServices services, BenchStatus bench, string? site, ResolvedTheme theme, Window? owner)
    {
        var dialog = new RunCommandDialog(services, bench, site, theme, owner);
        return dialog.ShowDialog() == true ? dialog.Chosen : null;
    }
}
