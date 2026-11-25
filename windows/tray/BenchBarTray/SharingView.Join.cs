using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// "Join a room" on the Sharing tab (macos: the join sheet and the rooms joined): this computer as a guest of somebody else's room, through
/// <c>benchbar.exe share join</c>. The person types the address of the room and looks at it first: the room's name, the address and the 16
/// digits of the host's key, which the host reads out. Only after that does the sheet ask for the room code, and the code goes to the CLI on
/// its standard input and nowhere else. The tab is drawn only when the CLI lists <c>share join</c>. The words and rules are in
/// <see cref="ShareGuestModel"/>; this draws them.
/// </summary>
internal sealed partial class SharingView
{
    private readonly Func<ShareGuestModel> _newGuest;
    private ShareGuestModel? _guest;
    private bool _joinOpen;
    private string _address = "";
    private TextBox? _addressBox;
    private PasswordBox? _codeBox;
    private readonly Dictionary<string, string> _guestSeatPick = []; // room id -> the seat picked in its box

    internal ShareGuestModel? Guest => _guest;

    /// <summary>The address box of the join sheet, for tests; null while the sheet is closed.</summary>
    internal TextBox? AddressBox => _addressBox;

    /// <summary>The room code box of the join sheet; null while the sheet is closed or before the look.</summary>
    internal PasswordBox? CodeBox => _codeBox;

    private Task StartGuest()
    {
        if (_guest is null)
        {
            _guest = _newGuest();
            _guest.Changed += Render;
        }
        return LoadGuestAsync(_guest);
    }

    private static async Task LoadGuestAsync(ShareGuestModel guest)
    {
        await guest.CheckSupportAsync().ConfigureAwait(true);
        if (guest.Supported) await guest.RefreshAsync().ConfigureAwait(true);
    }

    private bool Idle => _guest?.Busy is null && _model?.Busy is null;

    private void GuestRow(params (string Label, Action Click, bool Enabled)[] buttons)
    {
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 4) };
        foreach (var (label, click, enabled) in buttons)
        {
            var button = Ui.Button(label, click);
            button.IsEnabled = enabled;
            _buttons[label] = button;
            bar.Children.Add(button);
            _lines.Add("[" + label + "]");
        }
        _root.Children.Add(bar);
    }

    private void DrawJoin()
    {
        if (_guest is not { Supported: true } guest) return;
        _root.Children.Add(Ui.Heading(UiText.Get("GuestHeading")));
        Line(UiText.Get("GuestIntro"), 0.7);
        if (guest.LastError is { } problem) Line(problem, error: true);
        if (guest.Notice is { } notice) Line(notice, 0.8);
        if (guest.Busy is { } busy)
        {
            Line(busy);
            if (guest.CanCancel) GuestRow((UiText.Get("GuestCancelJoin"), guest.CancelJoin, true));
        }
        foreach (var room in guest.Rooms) DrawGuestRoom(guest, room);
        if (_joinOpen) DrawJoinSheet(guest);
        else GuestRow((UiText.Get("GuestJoinButton"), OpenJoinSheet, Idle));
    }

    private void DrawGuestRoom(ShareGuestModel guest, GuestRoom room)
    {
        Line($"{room.Room} · {UiText.Format("GuestHostOf", room.Host)} · {room.Target} · {ShareGuestModel.StateText(room)}", 1);
        Line(UiText.Format("GuestHostKey", room.SpacedKey), 0.6);
        var buttons = new List<(string, Action, bool)>();
        var pick = room.State == GuestState.Waiting && room.HostAssigns == false && room.FreeSeats.Count > 0;
        if (pick)
        {
            var free = room.FreeSeats;
            var box = new ComboBox { MinWidth = 260, Margin = new Thickness(0, 0, 0, 2), HorizontalAlignment = HorizontalAlignment.Left };
            foreach (var seat in free) box.Items.Add(seat.Roles.Count == 0 ? seat.Name : $"{seat.Name}: {string.Join(", ", seat.Roles)}");
            box.SelectedIndex = Math.Max(0, free.ToList().FindIndex(s => _guestSeatPick.TryGetValue(room.Id, out var picked) && picked == s.Id));
            box.SelectionChanged += (_, _) => _guestSeatPick[room.Id] = free[Math.Max(0, box.SelectedIndex)].Id;
            Ui.Name(box, UiText.Format("GuestSeatFor", room.Room));
            _root.Children.Add(box);
            buttons.Add((UiText.Format("GuestTakeSeat", room.Room), () => Run(() => guest.TakeSeatAsync(room, free[Math.Max(0, box.SelectedIndex)].Id)), Idle));
        }
        var canOpen = room.State is GuestState.Ready or GuestState.Closed or GuestState.Waiting or GuestState.Offline;
        buttons.Add((UiText.Format("GuestOpen", room.Room), () => Run(() => OpenRoomAsync(guest, room)), canOpen && !pick && Idle));
        buttons.Add((UiText.Format("GuestLeave", room.Room), () => Run(() => guest.LeaveAsync(room)), Idle));
        buttons.Add((UiText.Format("GuestForget", room.Room), () => Run(() => ForgetAsync(guest, room)), Idle));
        GuestRow([.. buttons]);
    }

    private async Task OpenRoomAsync(ShareGuestModel guest, GuestRoom room)
    {
        if (await guest.OpenUrlAsync(room) is { } url) _services.OpenUrl(url);
    }

    private async Task ForgetAsync(ShareGuestModel guest, GuestRoom room)
    {
        if (Confirm(UiText.Format("GuestForgetTitle", room.Room), UiText.Format("GuestForgetDetail", room.Host), UiText.Get("GuestForgetConfirm"))) await guest.ForgetAsync(room);
    }

    // --- the sheet ---

    private void OpenJoinSheet()
    {
        _joinOpen = true;
        _address = "";
        _addressBox = Ui.Field(UiText.Get("GuestAddressName"), "", OnAddressTyped);
        _codeBox = null;
        _guest?.ClearLook();
        Render();
    }

    private void CloseJoinSheet()
    {
        _codeBox?.Clear();
        _joinOpen = false;
        _addressBox = null;
        _codeBox = null;
        _guest?.ClearLook();
        Render();
    }

    private void OnAddressTyped(string text)
    {
        _address = text;
        // the button is drawn with the sheet, and typing does not draw again: it follows the box
        if (_buttons.TryGetValue(UiText.Get("GuestLookButton"), out var look)) look.IsEnabled = Idle && text.Trim().Length > 0;
        if (_guest is not { Look: not null } guest) return;
        // the room that was looked at is not the room that is typed any more: the code is asked again only after a new look
        var focus = _addressBox?.IsKeyboardFocused == true;
        _codeBox?.Clear();
        guest.ClearLook();
        if (focus && _addressBox is { } box)
        {
            box.Focus();
            box.CaretIndex = box.Text.Length;
        }
    }

    private void DrawJoinSheet(ShareGuestModel guest)
    {
        _root.Children.Add(Ui.Heading(UiText.Get("GuestSheetTitle")));
        Line(UiText.Get("GuestAddressHelp"), 0.7);
        _root.Children.Add(_addressBox!);
        _lines.Add(UiText.Get("GuestAddressName"));
        GuestRow((UiText.Get("GuestLookButton"), () => Run(LookAsync), Idle && _address.Trim().Length > 0), (UiText.Get("GuestSheetCancel"), CloseJoinSheet, guest.Busy is null));
        var look = guest.Look;
        if (look is null || look.Paired || ShareGuestModel.NotJoinable(look) is not null) _codeBox = null; // only a room that takes a code has a box
        if (look is null) return;
        Line(UiText.Format("GuestLookRoom", look.Room, look.Host), 1);
        Line(UiText.Format("GuestLookAddress", look.Target));
        Line(UiText.Format("GuestLookKey", look.SpacedKey), 1);
        Line(UiText.Format("GuestLookKeyHelp", look.Host), 0.7);
        if (look.Paired)
        {
            Line(UiText.Get("GuestPaired"), 0.85);
            GuestRow((UiText.Get("GuestOpenPaired"), () => Run(() => JoinAsync(guest, null)), Idle));
            return;
        }
        if (ShareGuestModel.NotJoinable(look) is { } closed)
        {
            Line(closed, caution: true);
            return;
        }
        Line(UiText.Get("GuestCodeLabel"), 1);
        _codeBox ??= Ui.Password(UiText.Get("GuestCodeName"), _ => { }, 160);
        _codeBox.MaxLength = 8; // six digits and the space of "482 913"
        _root.Children.Add(_codeBox);
        _lines.Add(UiText.Get("GuestCodeName"));
        Line(UiText.Get("GuestWaitHelp"), 0.7);
        GuestRow((UiText.Get("GuestJoinRoom"), () => Run(() => JoinTypedAsync(guest)), Idle));
    }

    private async Task LookAsync()
    {
        _codeBox?.Clear();
        await _guest!.LookAsync(_address);
        Render();
    }

    /// <summary>
    /// The code leaves the box for the model as a <see cref="Secret"/> that the model disposes when the join ends, and the box is emptied whatever
    /// the result: a wrong code is typed again, and a right one is not left on the screen.
    /// </summary>
    private async Task JoinTypedAsync(ShareGuestModel guest)
    {
        var typed = _codeBox is null ? null : Secret.From(_codeBox.SecurePassword);
        _codeBox?.Clear(); // the box is empty from the moment the code is taken, not only when the call ends
        await JoinAsync(guest, typed);
    }

    private async Task JoinAsync(ShareGuestModel guest, Secret? code)
    {
        var ok = await guest.JoinAsync(code);
        _codeBox?.Clear();
        if (ok) CloseJoinSheet();
        else Render();
    }
}
