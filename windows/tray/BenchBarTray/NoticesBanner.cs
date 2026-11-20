using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// The banner of the bench page for the defaults an update changed (<c>status --json</c> <c>notices[]</c>, the Mac app's notices): the title, what
/// changed, the command that switches back, a link to the page that explains it, and Dismiss, which runs <c>benchbar notices --dismiss ID</c>.
/// The notices belong to the person, not to a bench, so every bench's status carries the same ones. Dismiss is the person's click and the only
/// way a notice goes; a poll never dismisses. Rebuilt only when the list changes, so a poll does not touch a button under the pointer.
/// </summary>
internal sealed class NoticesBanner : UserControl
{
    private readonly PageServices _services;
    private readonly StackPanel _root = new();
    private readonly HashSet<string> _dismissed = [];
    private IReadOnlyList<BenchNotice> _all = [];
    private string _key = "";
    private string? _message;
    private bool _busy;

    public NoticesBanner(PageServices services)
    {
        _services = services;
        // three notices are tall: the tabs below must stay in reach
        Content = new ScrollViewer { Content = _root, MaxHeight = 260, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Visibility = Visibility.Collapsed;
        Ui.Name(this, "Notices");
    }

    /// <summary>The run behind the last click, for tests.</summary>
    internal Task Pending { get; private set; } = Task.CompletedTask;

    /// <summary>The notices on screen now, in order.</summary>
    internal IReadOnlyList<BenchNotice> Shown => [.. _all.Where(n => !_dismissed.Contains(n.Id))];

    internal string? Message => _message;

    /// <summary>Every line of text on screen, in order (for tests).</summary>
    internal IReadOnlyList<string> Lines { get; private set; } = [];

    public void Bind(BenchStatus bench)
    {
        var key = string.Join('|', bench.Notices.Select(n => $"{n.Id}\t{n.Title}\t{n.Text}\t{n.SwitchBack}\t{n.Doc}"));
        if (key == _key) return;
        _key = key;
        _all = bench.Notices;
        // a notice the CLI no longer lists is dismissed for good: forget it, so a later one with the same id shows again
        _dismissed.IntersectWith(_all.Select(n => n.Id));
        Rebuild();
    }

    private void Rebuild()
    {
        _root.Children.Clear();
        var shown = Shown;
        if (shown.Count == 0 && _message is null)
        {
            Visibility = Visibility.Collapsed;
            Lines = [];
            return;
        }
        Visibility = Visibility.Visible;
        foreach (var notice in shown)
        {
            var card = new StackPanel();
            card.Children.Add(Ui.Text(notice.Title, 14, FontWeights.SemiBold, margin: new Thickness(0, 0, 0, 2)));
            card.Children.Add(Ui.Text(notice.Text, 13, opacity: 0.9));
            if (notice.SwitchBack is { } back)
            {
                card.Children.Add(Ui.Text("To go back:", 12, opacity: 0.75, margin: new Thickness(0, 6, 0, 0)));
                card.Children.Add(Ui.Mono(back));
            }
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
            var captured = notice;
            var dismiss = Ui.Button("Dismiss", () => Pending = DismissAsync(captured), $"Dismiss: {notice.Title}", primary: true);
            dismiss.IsEnabled = !_busy;
            buttons.Children.Add(dismiss);
            if (notice.SwitchBack is { } command)
                buttons.Children.Add(Ui.Button("Copy Command", () => _services.CopyText(command), $"Copy the command to go back: {notice.Title}"));
            if (notice.SafeDoc is { } doc)
                buttons.Children.Add(Ui.Button("Read More", () => _services.OpenUrl(doc), $"Read more: {notice.Title}"));
            card.Children.Add(buttons);
            _root.Children.Add(Ui.CardOf(card, new Thickness(0, 0, 0, 8)));
        }
        if (_message is { Length: > 0 } text) _root.Children.Add(Ui.Text(text, 13, margin: new Thickness(0, 0, 0, 8)));
        Lines = TextProbe.Lines(_root);
    }

    /// <summary>Runs <c>notices --dismiss ID</c>. The notice stays on screen when the CLI refuses, with its reason.</summary>
    internal async Task DismissAsync(BenchNotice notice)
    {
        _busy = true;
        _message = null;
        Rebuild();
        var r = await _services.Cli.RunStreamAsync(NoticeCommands.Dismiss(notice.Id), null, CliTimeouts.Read, _ => { }).ConfigureAwait(true);
        _busy = false;
        if (r.Ok)
        {
            _dismissed.Add(notice.Id);
            _services.RefreshNow();
        }
        else _message = r.Problem ?? $"The notice was not dismissed (exit {r.Exit}).";
        Rebuild();
    }
}
