using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// The Sharing tab of a bench page (macos SharingTab, the host side): one primary button per state, the room code, the checks, the
/// copy and the people in the room. It is on the bench page only while the lan-rooms experiment is on. Every action that changes
/// something asks first, as the Mac's alerts do, and nothing runs from a poll: <see cref="Bind"/> only reads. The rules and the
/// words are in <see cref="ShareModel"/> and <see cref="ShareText"/>; this draws them.
/// </summary>
internal sealed class SharingView : UserControl, IBenchPageView
{
    private readonly PageServices _services;
    private readonly Func<string, ShareModel> _newModel;
    private readonly StackPanel _root = new() { MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly Dictionary<string, Button> _buttons = [];
    private readonly List<string> _lines = [];
    private ShareModel? _model;
    private int _hours = 4;
    private readonly Dictionary<string, string> _seatPick = []; // person id -> the seat picked in their box
    private bool _revealed;
    private ShareSetupForm? _form;
    private ShareSetupPlan? _formPlan;
    private bool _formRefresh;

    public SharingView(PageServices services) : this(services, bench => new ShareModel(services.Cli, bench))
    {
        Confirm = (title, detail, button) => ConfirmDialog.Ask(title, detail, button, services.Theme(), services.Owner());
    }

    internal SharingView(PageServices services, Func<string, ShareModel> newModel)
    {
        _services = services;
        _newModel = newModel;
        Content = _root;
        Ui.Name(this, "Sharing");
    }

    /// <summary>The questions the tab asks before it acts: title, detail, button label. Tests answer them; the app shows a dialog.</summary>
    public Func<string, string, string, bool> Confirm { get; set; } = (_, _, _) => false;

    internal ShareModel? Model => _model;

    /// <summary>The Start form's switch: the host gives out the seats of the room that starts. On until the host unticks it.</summary>
    internal bool AssignSeats { get; set; } = true;

    public BenchContext? Context { get; private set; }

    /// <summary>The texts shown, one per line, with buttons as <c>[Label]</c>, for tests.</summary>
    public IReadOnlyList<string> Lines { get; private set; } = [];

    /// <summary>The buttons by their label (for tests and the keyboard).</summary>
    public IReadOnlyDictionary<string, Button> Buttons => _buttons;

    public ShareSetupForm? Form => _form;

    /// <summary>The last action started by a button; tests wait on it.</summary>
    public Task Pending { get; private set; } = Task.CompletedTask;

    public void Bind(BenchContext context)
    {
        if (_model is null || _model.BenchPath != context.Bench.Path)
        {
            if (_model is not null) _model.Changed -= Render;
            _model = _newModel(context.Bench.Path);
            _model.Changed += Render;
            _form = null;
            _revealed = false;
        }
        Context = context;
        Pending = _model.RefreshAsync();
        Render();
    }

    private string Site => Context?.Site ?? Context?.Bench.Sites.FirstOrDefault(s => s.IsDefault)?.Name ?? Context?.Bench.Sites.FirstOrDefault()?.Name ?? "";

    private void Run(Func<Task> action) => Pending = action();

    // --- drawing ---

    private void Line(string text, double opacity = 0.85, bool error = false, bool caution = false)
    {
        _lines.Add(text);
        var block = PagePanels.Line(text, error, opacity);
        if (caution) block.Foreground = Ui.CautionTextBrush;
        _root.Children.Add(block);
    }

    private void Row(params (string Label, Action Click, bool Enabled)[] buttons)
    {
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 4) };
        foreach (var (label, click, enabled) in buttons)
        {
            var button = Ui.Button(label, click);
            button.IsEnabled = enabled && _model!.Busy is null;
            _buttons[label] = button;
            bar.Children.Add(button);
            _lines.Add("[" + label + "]");
        }
        _root.Children.Add(bar);
    }

    private void Render()
    {
        if (_model is null) return;
        _lines.Clear();
        _buttons.Clear();
        _root.Children.Clear();
        _root.Children.Add(Ui.Title("Sharing"));
        Draw(_model.Status);
        Lines = [.. _lines];
    }

    private void Draw(ShareStatus? status)
    {
        if (_model!.LastError is { } problem) Line(problem, error: true);
        if (_model.Busy is { } busy) Line(busy);
        if (status is null)
        {
            if (_model.LastError is null) Line("Reading sharing...");
            return;
        }
        if (status.NeedsNewerCli)
        {
            Line(ShareText.NewerCli);
            Row(("Update", () => _services.OpenUrl(AboutWindow.DocsUrl), true));
            return;
        }
        var primary = ShareText.Primary(status);
        var settingUp = primary is SharePrimary.SetUp or SharePrimary.FinishSetup;
        Line(settingUp ? ShareText.SetUpIntro : ShareText.LiveUpdates, 0.7);
        if (status.IsOn) Line(ShareText.Indicator(status), 1);
        if (_form is not null) DrawForm();
        else DrawPrimary(status, primary);
        if (status.IsLive) DrawRoom(status);
        DrawNotices(status);
        if (!settingUp) DrawChecks(status);
        if (status.Copy is { } copy) DrawCopy(status, copy);
        if (status.IsLive) DrawPeople(status);
    }

    private void DrawPrimary(ShareStatus status, SharePrimary primary)
    {
        var buttons = new List<(string, Action, bool)>();
        if (status.IsOn)
            foreach (var (label, minutes) in ShareText.ExtendOptions(status.CanExtendSeconds))
                buttons.Add((label, () => Run(() => _model!.ExtendAsync(minutes)), true));
        if (primary == SharePrimary.TurnOnProtection && !_model!.LanGuardSupported) Line(ShareText.LanGuardUnavailable, 0.85, caution: true); // no button: nothing here can run it
        else buttons.Add((ShareText.Title(primary), () => Run(() => OnPrimary(primary, status)), primary != SharePrimary.Start || ShareText.CanStart(status)));
        Row([.. buttons]);
        if (primary != SharePrimary.Start) return;
        var box = new ComboBox { Width = 90, Margin = new Thickness(0, 0, 0, 6), HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var h in ShareText.Hours) box.Items.Add($"{h} h");
        box.SelectedIndex = Math.Max(0, ShareText.Hours.ToList().IndexOf(_hours));
        box.SelectionChanged += (_, _) => _hours = ShareText.Hours[Math.Max(0, box.SelectedIndex)];
        Ui.Name(box, "Hours to share");
        _root.Children.Add(box);
        var seats = new CheckBox { IsChecked = AssignSeats, Content = ShareText.AssignSeatsToggle, Margin = new Thickness(0, 0, 0, 2) };
        seats.Click += (_, _) => { AssignSeats = seats.IsChecked == true; Render(); };
        Ui.Name(seats, ShareText.AssignSeatsToggle);
        _root.Children.Add(seats);
        Line(ShareText.SeatModeLine(AssignSeats), 0.7);
    }

    private async Task OnPrimary(SharePrimary primary, ShareStatus status)
    {
        var model = _model!;
        switch (primary)
        {
            case SharePrimary.SetUp or SharePrimary.FinishSetup:
                await OpenFormAsync(status.Copy is not null || status.SetupInterrupted);
                break;
            case SharePrimary.TurnOnProtection:
                if (Confirm("Turn on network protection?", ShareText.LanGuardAsk, "Continue")) await model.RunLanGuardAsync(false);
                break;
            case SharePrimary.Start:
                if (!Confirm(ShareText.StartConfirm(Site, AssignSeats), "", "Start sharing")) break;
                if (await model.StartAsync(_hours, AssignSeats) && await model.LoadCodeAsync()) _revealed = true;
                Render();
                break;
            case SharePrimary.Stop:
                if (Confirm(ShareText.StopConfirm(status.DevicesOnline), "", "Stop")) await model.StopAsync();
                _revealed = false;
                break;
            default:
                _services.OpenUrl(AboutWindow.DocsUrl);
                break;
        }
    }

    // --- the room code and the invite ---

    private void DrawRoom(ShareStatus status)
    {
        _root.Children.Add(Ui.Heading("Room code"));
        if (_model!.Status is { } keyed && ShareText.HostKeyLine(keyed) is { } hostKey)
        {
            Line(hostKey, 0.7);
            Line(ShareText.HostKeyHelp, 0.6);
        }
        var code = _model!.Code;
        var shown = _revealed && code is not null ? code.Spaced : "••• •••";
        _lines.Add("Room code: " + (_revealed && code is not null ? "shown" : "hidden")); // the code itself is never in Lines
        var text = Ui.Text(shown, 36, System.Windows.FontWeights.SemiBold, margin: new Thickness(0, 0, 0, 4));
        text.FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas");
        Ui.Name(text, _revealed && code is not null ? "Room code" : "Room code, hidden");
        _root.Children.Add(text);
        Row((_revealed ? "Hide" : "Show", () => Run(ToggleCodeAsync), true),
            ("Copy", () => Run(CopyCodeAsync), true),
            ("Copy invite", () => Run(CopyInviteAsync), true),
            ("New code", () => Run(async () => { if (await _model.LoadCodeAsync(true)) _revealed = true; Render(); }), true),
            (status.Locked == true ? "Unlock" : "Lock room", () => Run(() => _model.SetLockedAsync(status.Locked != true)), true));
        if (_model.InviteCopied) Line(ShareText.InviteCopied, 0.8);
        if (_model.RemovedName is { } name) Line(ShareText.RemovedNotice(name), 0.8);
        Line(ShareText.CodeNote, 0.8);
        Line(ShareText.CodeProves, 0.65);
    }

    /// <summary>
    /// The code is read on a click, never when the tab shows. A tab opened after a tray restart has no code in memory, so Show and Copy read
    /// the current one (<c>share code</c>, no <c>--new</c>: a new code would end the invites already sent) and then do their job.
    /// </summary>
    private async Task<bool> HaveCodeAsync() => _model!.Code is not null || await _model.LoadCodeAsync();

    private async Task ToggleCodeAsync()
    {
        if (_revealed) _revealed = false;
        else if (await HaveCodeAsync()) _revealed = true;
        Render();
    }

    private async Task CopyCodeAsync()
    {
        if (await HaveCodeAsync() && _model!.Code is { } code) _services.CopySecret(code.Code);
        Render();
    }

    private async Task CopyInviteAsync()
    {
        if (await _model!.ReadInviteAsync() is { } invite) _services.CopySecret(invite.Text);
        Render();
    }

    private void DrawNotices(ShareStatus status)
    {
        if (status.SetupInterrupted) Line(ShareText.SetupInterrupted, caution: true);
        if (ShareText.LockLine(status) is { } lockLine) Line(lockLine, caution: status.LockReason == "budget");
        if (status.JoinTrouble) Line(ShareText.JoinTrouble, caution: true);
        if (status.WipeFailed > 0) Line(ShareText.WipeOwed, caution: true);
        if (status.Degraded is { Length: > 0 } degraded) Line(degraded, caution: true);
        if (status.Error is { Length: > 0 } error) Line(error, error: true);
    }

    // --- checks, copy, people ---

    private void DrawChecks(ShareStatus status)
    {
        _root.Children.Add(Ui.Heading("Checks"));
        Line(ShareText.ProtectionText(status.LanGuard));
        if (status.LanGuard != LanGuardState.Installed && _model!.LanGuardSupported)
            Row(("Turn on network protection", () => Run(() => OnPrimary(SharePrimary.TurnOnProtection, status)), !status.IsLive));
        foreach (var check in status.Checks)
        {
            if (ShareText.WaitsForStart(check, status)) { Line($"{ShareText.CheckTitle(check)}: {ShareText.CheckedAtStart}", 0.7); continue; }
            Line($"{ShareText.CheckStatus(check.Status)}: {ShareText.CheckTitle(check)}", error: check.Status == ShareCheckStatus.Fail);
            if (check.Status != ShareCheckStatus.Ok && check.Message.Length > 0 && ShareText.CheckTitle(check) != check.Message) Line(check.Message, 0.65);
            if (check.Status != ShareCheckStatus.Ok && ShareText.FixLabel(check.Fix) is { } label && check.Fix != ShareFixAction.InstallNetworkProtection
                && (_model!.LanGuardSupported || check.Fix != ShareFixAction.AllowNodeFirewall))
                Row((label, () => Run(() => Fix(check.Fix, status)), true));
        }
    }

    private async Task Fix(ShareFixAction action, ShareStatus status)
    {
        switch (action)
        {
            case ShareFixAction.AllowNodeFirewall:
                if (Confirm("Allow sharing through the firewall?", ShareText.LanGuardAllowAsk, "Allow")) await _model!.RunLanGuardAsync(true);
                break;
            case ShareFixAction.UpdateCli:
                _services.OpenUrl(AboutWindow.DocsUrl);
                break;
            case ShareFixAction.RerunSetup or ShareFixAction.RefreshCopy:
                await OpenFormAsync(true);
                break;
            case ShareFixAction.RestartSharing:
                if (!Confirm("Restart sharing?", "Everyone in the room is disconnected and needs the new room code to join again.", "Restart")) break;
                var assign = _model!.HostGivesSeats; // the room that starts again gives out its seats the way the one that ran did
                if (await _model.StopAsync()) await _model.StartAsync(_hours, assign);
                break;
        }
    }

    private void DrawCopy(ShareStatus status, ShareCopy copy)
    {
        _root.Children.Add(Ui.Heading("The copy"));
        Line(ShareText.CopyLine(copy));
        if (copy.Drifted) Line(ShareText.DriftWarning, caution: true);
        Row(("Refresh copy", () => { if (Confirm("Refresh the copy?", ShareText.RefreshConfirm, "Refresh")) Run(() => OpenFormAsync(true)); }, !status.IsLive));
    }

    private void DrawPeople(ShareStatus status)
    {
        _root.Children.Add(Ui.Heading(ShareText.PeopleTitle));
        Line(ShareText.SeatModeLine(_model!.HostGivesSeats), 0.7);
        if (_model.People.Count == 0) Line("Nobody has joined yet.", 0.7);
        if (ShareText.WaitingNotice(_model.People, _model.HostGivesSeats) is { } waiting) Line(waiting, caution: true);
        var free = ShareText.FreeSeats(_model.Seats, _model.People);
        foreach (var person in ShareText.Sorted(_model.People))
        {
            Line($"{(person.Online ? "Online" : "Offline")}: {ShareText.PersonLine(person)} · {ShareText.SeatCaption(person, _model.HostGivesSeats)}");
            if (free.Count == 0)
            {
                Row(("Remove " + person.Name, () => Run(() => RemoveAsync(person)), true));
                continue;
            }
            // the seat to give: a box of the free seats with their roles, then the button that gives the one picked
            var box = new ComboBox { MinWidth = 260, Margin = new Thickness(0, 0, 0, 2), HorizontalAlignment = HorizontalAlignment.Left };
            foreach (var seat in free) box.Items.Add(ShareText.SeatTitle(seat));
            box.SelectedIndex = Math.Max(0, free.ToList().FindIndex(s => _seatPick.TryGetValue(person.Id, out var picked) && picked == s.Id));
            box.SelectionChanged += (_, _) => _seatPick[person.Id] = free[Math.Max(0, box.SelectedIndex)].Id;
            Ui.Name(box, "Seat for " + person.Name);
            _root.Children.Add(box);
            Row((ShareText.AssignButton(person), () => Run(() => AssignAsync(person, free[Math.Max(0, box.SelectedIndex)])), true),
                ("Remove " + person.Name, () => Run(() => RemoveAsync(person)), true));
        }
    }

    private async Task AssignAsync(SharePerson person, ShareSeat seat)
    {
        if (await _model!.AssignAsync(person, seat)) _seatPick.Remove(person.Id);
    }

    private async Task RemoveAsync(SharePerson person)
    {
        if (Confirm(ShareText.RemoveConfirm(person, Site), ShareText.RemoveDetail, "Remove")) await _model!.RemoveAsync(person);
    }

    // --- set up ---

    private async Task OpenFormAsync(bool refresh)
    {
        _formRefresh = refresh;
        _form = new ShareSetupForm(Site);
        _formPlan = null;
        await _model!.LoadUsersAsync(Site);
        Render();
    }

    private void DrawForm()
    {
        var form = _form!;
        _root.Children.Add(Ui.Heading(_formRefresh ? "Refresh the shared copy" : "Set up sharing"));
        Line($"Site: {form.Site}", 0.7);
        var source = new StackPanel { Margin = new Thickness(0, 2, 0, 6) };
        foreach (var now in new[] { true, false })
        {
            var radio = new RadioButton { IsChecked = form.BackupNow == now, GroupName = "share-source", Content = ShareSetupForm.SourceLabel(now, _formPlan?.EstMinutes, _formPlan?.SourceAgeSeconds) };
            radio.Checked += (_, _) => form.BackupNow = now;
            Ui.Name(radio, (string)radio.Content);
            source.Children.Add(radio);
        }
        _root.Children.Add(source);
        Line("People (one seat each)", 1);
        foreach (var user in _model!.Users.Where(u => u.Selectable))
        {
            var roles = string.Join(", ", user.Roles.Take(4).Select(r => user.CodeCapableRoles.Contains(r) ? $"{r} (removed in the copy)" : r));
            var box = new CheckBox { IsChecked = form.Picked.Contains(user.Name), Content = roles.Length > 0 ? $"{user.FullName}: {roles}" : user.FullName, Margin = new Thickness(0, 2, 0, 2) };
            box.Click += (_, _) => { if (box.IsChecked == true) form.Picked.Add(user.Name); else form.Picked.Remove(user.Name); Render(); };
            Ui.Name(box, user.FullName);
            _root.Children.Add(box);
            _lines.Add(box.Content.ToString()!);
        }
        var ack = new CheckBox { IsChecked = form.Acknowledged, Content = new TextBlock { Text = ShareText.Acknowledgement, TextWrapping = TextWrapping.Wrap }, Margin = new Thickness(0, 8, 0, 4) };
        ack.Click += (_, _) => { form.Acknowledged = ack.IsChecked == true; Render(); };
        Ui.Name(ack, "Acknowledge the copy holds real data");
        _root.Children.Add(ack);
        _lines.Add(ShareText.Acknowledgement);
        Row((_formRefresh ? "Refresh copy" : "Set up sharing", () => Run(ReviewSetupAsync), form.CanRun), ("Cancel", () => { _form = null; Render(); }, true));
    }

    /// <summary>Reads the plan (nothing changes), then the plan sheet shows it and makes the copy only on its confirm.</summary>
    private async Task ReviewSetupAsync()
    {
        var form = _form!;
        var request = form.Request(_formRefresh);
        var plan = await _model!.PlanSetupAsync(request);
        if (plan is null) return;
        _formPlan = plan;
        var outcome = await _services.ReviewPlan(_model.SetupReview(request, plan));
        if (outcome.Applied) _form = null;
        _services.RefreshNow();
        await _model.RefreshAsync(true);
        Render();
    }
}
