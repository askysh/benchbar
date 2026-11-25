using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// Open as in the Sites tab (macos BenchPage and FindUserSheet): the opt in per site, which is the person's decision and never made by
/// the tray, and Find User, which lists the users of a site and opens it in the browser signed in as one of them. The tray runs
/// <c>open --as USER --json</c> and the CLI opens the browser itself, so the sign in link (it holds a session id) never reaches the tray,
/// a log or the screen.
/// </summary>
internal sealed partial class SitesView
{
    private FindUserModel? _find;
    private TextBox? _findQuery;
    private StackPanel? _findList;
    private TextBlock? _findNote;

    /// <summary>The Find User panel in the page now, or null.</summary>
    internal FindUserModel? Find => _find;

    /// <summary>The users shown in the open Find User panel, by user id (for tests).</summary>
    internal IReadOnlyDictionary<string, Button> FindButtons => _findButtons;

    private readonly Dictionary<string, Button> _findButtons = [];

    private (OpenAsRules.Availability State, string? Why) OpenAsFor(SiteRowInfo row) => OpenAsRules.For(row, Bench.State == BenchState.Running, Bench.Name);

    /// <summary>The line under the site's address while Open as is on: ready, or why it is not usable.</summary>
    private UIElement? OpenAsLine(SiteRowInfo row)
    {
        if (OpenAsRules.StatusLine(row) is not { } line) return null;
        var block = Ui.Text(line.Text, 12, opacity: line.Warning ? 1 : 0.7, margin: new Thickness(0, 2, 0, 0));
        if (line.Warning) block.Foreground = Ui.CautionTextBrush;
        return block;
    }

    private void OpenAsAction(SiteRowInfo row, SiteAction action)
    {
        switch (action)
        {
            case SiteAction.OpenAs: OpenFindUser(row); break;
            case SiteAction.AllowOpenAs:
                // the question is the person's decision, as the Mac's alert is; the CLI's --yes only skips its own copy of it
                if (_services.Confirm(OpenAsRules.AllowTitle(row.Name), OpenAsRules.AllowMessage, UiText.Get("OpenAsAllowButton"))) Start(() => SetOpenAsAsync(row.Name, true));
                break;
            case SiteAction.TurnOffOpenAs: Start(() => SetOpenAsAsync(row.Name, false)); break;
        }
    }

    internal Task SetOpenAsAsync(string site, bool on) => RunBusy(on ? UiText.Format("OpenAsTurningOn", site) : UiText.Format("OpenAsTurningOff", site), async () =>
    {
        var r = await _services.Cli.RunJsonAsync(OpenAsCommands.Set(site, on, Bench.Path), OpenAsCommands.PersonEnvironment(), CliTimeouts.Plan, o => o);
        return r.Ok ? (true, on ? OpenAsRules.TurnedOn(site) : OpenAsRules.TurnedOff(site)) : (false, Why(r));
    });

    // --- Find User ---

    private void OpenFindUser(SiteRowInfo row)
    {
        _find = new FindUserModel(_services.Cli, Bench.Path, row.Name);
        _findButtons.Clear();
        _findQuery = Ui.Field(UiText.Get("OpenAsSearchField"), "", _ => { }, 360);
        _findQuery.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter) Start(SearchUsersAsync);
        };
        _findList = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        _findNote = PagePanels.Line("");
        _findNote.Visibility = Visibility.Collapsed;
        var panel = PagePanels.Panel(UiText.Get("OpenAsFindTitle"),
            UiText.Format("OpenAsFindExplain", row.Name),
            [_findQuery, _findList, _findNote],
            [Ui.Button(UiText.Get("OpenAsSearch"), () => Start(SearchUsersAsync), primary: true), Ui.Button(UiText.Get("TidyClose"), CloseFind)]);
        SetPanel(panel);
        _findQuery.Focus();
        Start(SearchUsersAsync);
    }

    private void CloseFind()
    {
        _find = null;
        _findQuery = null;
        _findList = null;
        _findNote = null;
        _findButtons.Clear();
        _pinButtons.Clear();
        ClosePanel();
    }

    internal async Task SearchUsersAsync()
    {
        if (_find is not { } find) return;
        await find.SearchAsync(_findQuery?.Text);
        PagePanels.OnUi(this, () => { if (ReferenceEquals(_find, find)) DrawUsers(find); });
    }

    private void DrawUsers(FindUserModel find)
    {
        if (_findList is null) return;
        _findList.Children.Clear();
        _findButtons.Clear();
        _pinButtons.Clear();
        if (find.Error is { } error)
        {
            _findList.Children.Add(PagePanels.Line(error, error: true));
            return;
        }
        if (find.List is not { } list) return;
        if (list.Users.Count == 0) _findList.Children.Add(PagePanels.Line(UiText.Get("QuickSwitchNoMatch")));
        foreach (var user in list.Users) _findList.Children.Add(UserRow(find, user));
        if (list.Truncated) _findList.Children.Add(PagePanels.Line(UiText.Format("OpenAsShowingFirst", OpenAsRules.Limit)));
    }

    private UIElement UserRow(FindUserModel find, SiteUser user)
    {
        var grid = new Grid { Margin = new Thickness(0, 4, 0, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var text = new StackPanel();
        // a list of mostly System Users saying so on every row is noise
        text.Children.Add(Ui.Text(user.UserType == "System User" ? user.Title : UiText.Format("ActivityOpProgress", user.Title, user.UserType), 14, FontWeights.SemiBold, margin: new Thickness(0)));
        text.Children.Add(Ui.Text(user.Name, 12, opacity: 0.7, margin: new Thickness(0)));
        if (user.RolesLine.Length > 0) text.Children.Add(Ui.Text(user.RolesLine, 12, opacity: 0.7, margin: new Thickness(0)));
        if (_services.Pins.Of(Bench.Path, find.Site).FirstOrDefault(p => p.User == user.Name) is { } kept)
        {
            // the label Quick Switch shows for this user, as the Mac's Find User row has; saved when the person is done (Enter or leaving
            // the field), not on every key, because every save writes config.json
            var label = Ui.Field(UiText.Format("OpenAsLabelFor", user.Name), kept.Label ?? "", _ => { }, 220);
            label.LostFocus += (_, _) => CommitLabel(label, user.Name, find.Site);
            label.KeyDown += (_, e) =>
            {
                if (e.Key != Key.Enter) return;
                CommitLabel(label, user.Name, find.Site);
                e.Handled = true;
            };
            label.ToolTip = UiText.Get("OpenAsLabelTip");
            label.HorizontalAlignment = HorizontalAlignment.Left;
            label.Margin = new Thickness(0, 4, 0, 0);
            text.Children.Add(label);
        }
        grid.Children.Add(text);
        var open = Ui.Button(UiText.Get("SitesOpen"), () => Start(() => OpenUserAsync(find, user)), UiText.Format("OpenAsOpenName", user.Name), minWidth: 72);
        open.IsEnabled = !_busy;
        _findButtons[user.Name] = open;
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        if (user.Name != OpenAsPins.Administrator) // Administrator is always in Quick Switch
        {
            var pinned = _services.Pins.IsPinned(user.Name, Bench.Path, find.Site);
            var pin = Ui.Button(pinned ? UiText.Get("OpenAsUnpin") : UiText.Get("OpenAsPin"), () => TogglePin(find, user), pinned ? UiText.Format("OpenAsUnpinName", user.Name) : UiText.Format("OpenAsPinName", user.Name), minWidth: 64);
            pin.ToolTip = pinned ? UiText.Get("OpenAsUnpinTip") : UiText.Format("OpenAsPinTip", OpenAsPins.Max);
            buttons.Children.Add(pin);
            _pinButtons[user.Name] = pin;
        }
        buttons.Children.Add(open);
        Grid.SetColumn(buttons, 1);
        grid.Children.Add(buttons);
        return grid;
    }

    private readonly Dictionary<string, Button> _pinButtons = [];

    /// <summary>The Pin and Unpin buttons of the open Find User panel, by user id (for tests).</summary>
    internal IReadOnlyDictionary<string, Button> PinButtons => _pinButtons;

    private void TogglePin(FindUserModel find, SiteUser user)
    {
        var pins = _services.Pins;
        if (pins.IsPinned(user.Name, Bench.Path, find.Site)) pins.Unpin(user.Name, Bench.Path, find.Site);
        else if (!pins.Pin(user.Name, user.FullName, Bench.Path, find.Site))
        {
            ShowFindNote(UiText.Format("OpenAsPinLimit", OpenAsPins.Max), true);
            return;
        }
        DrawUsers(find);
    }

    private void ShowFindNote(string text, bool error)
    {
        if (_findNote is null) return;
        _findNote.Text = text;
        _findNote.Visibility = Visibility.Visible;
        if (error) _findNote.Foreground = Ui.CriticalBrush;
        else _findNote.ClearValue(TextBlock.ForegroundProperty);
    }

    /// <summary>Saves the label typed for a pinned user, once, when it differs from the one kept.</summary>
    internal void CommitLabel(TextBox box, string user, string site)
    {
        var typed = string.IsNullOrWhiteSpace(box.Text) ? null : box.Text.Trim();
        if (_services.Pins.Of(Bench.Path, site).FirstOrDefault(p => p.User == user) is not { } pin || pin.Label == typed) return;
        _services.Pins.SetLabel(user, box.Text, Bench.Path, site);
    }

    internal async Task OpenUserAsync(FindUserModel find, SiteUser user)
    {
        await find.OpenAsync(user);
        PagePanels.OnUi(this, () =>
        {
            if (!ReferenceEquals(_find, find) || _findNote is null) return;
            if (find.Note is { } note) ShowFindNote(note, find.NoteIsError);
        });
    }
}
