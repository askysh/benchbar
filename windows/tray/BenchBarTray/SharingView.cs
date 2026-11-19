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
    private bool _revealed;

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

    public BenchContext? Context { get; private set; }

    /// <summary>The texts shown, one per line, with buttons as <c>[Label]</c>, for tests.</summary>
    public IReadOnlyList<string> Lines { get; private set; } = [];

    /// <summary>The buttons by their label (for tests and the keyboard).</summary>
    public IReadOnlyDictionary<string, Button> Buttons => _buttons;

    /// <summary>The last action started by a button; tests wait on it.</summary>
    public Task Pending { get; private set; } = Task.CompletedTask;

    public void Bind(BenchContext context)
    {
        if (_model is null || _model.BenchPath != context.Bench.Path)
        {
            if (_model is not null) _model.Changed -= Render;
            _model = _newModel(context.Bench.Path);
            _model.Changed += Render;
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
        if (settingUp) Line(ShareText.SetUpElsewhere);
        else DrawPrimary(status, primary);
        if (status.IsLive) DrawRoom(status);
        DrawNotices(status);
        if (!settingUp) DrawChecks(status);
        if (status.Copy is { } copy) DrawCopy(copy);
        if (status.IsLive) DrawPeople(status);
    }

    private void DrawPrimary(ShareStatus status, SharePrimary primary)
    {
        var buttons = new List<(string, Action, bool)>();
        if (status.IsOn)
            foreach (var (label, minutes) in ShareText.ExtendOptions(status.CanExtendSeconds))
                buttons.Add((label, () => Run(() => _model!.ExtendAsync(minutes)), true));
        if (primary is SharePrimary.Start or SharePrimary.Stop or SharePrimary.UpdateCli)
            buttons.Add((ShareText.Title(primary), () => Run(() => OnPrimary(primary, status)), primary != SharePrimary.Start || ShareText.CanStart(status)));
        else Line(ShareText.ProtectionText(status.LanGuard) + " Turn it on in PowerShell: benchbar.exe lan-guard install");
        Row([.. buttons]);
        if (primary != SharePrimary.Start) return;
        var box = new ComboBox { Width = 90, Margin = new Thickness(0, 0, 0, 6), HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var h in ShareText.Hours) box.Items.Add($"{h} h");
        box.SelectedIndex = Math.Max(0, ShareText.Hours.ToList().IndexOf(_hours));
        box.SelectionChanged += (_, _) => _hours = ShareText.Hours[Math.Max(0, box.SelectedIndex)];
        Ui.Name(box, "Hours to share");
        _root.Children.Add(box);
    }

    private async Task OnPrimary(SharePrimary primary, ShareStatus status)
    {
        var model = _model!;
        switch (primary)
        {
            case SharePrimary.Start:
                if (!Confirm(ShareText.StartConfirm(Site), "", "Start sharing")) break;
                if (await model.StartAsync(_hours) && await model.LoadCodeAsync()) _revealed = true;
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
        var code = _model!.Code;
        var shown = _revealed && code is not null ? code.Spaced : "••• •••";
        _lines.Add("Room code: " + (_revealed && code is not null ? "shown" : "hidden")); // the code itself is never in Lines
        var text = Ui.Text(shown, 36, System.Windows.FontWeights.SemiBold, margin: new Thickness(0, 0, 0, 4));
        text.FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas");
        Ui.Name(text, _revealed && code is not null ? "Room code" : "Room code, hidden");
        _root.Children.Add(text);
        Row((_revealed ? "Hide" : "Show", () => { _revealed = !_revealed; Render(); }, code is not null),
            ("Copy", () => { if (_model.Code is { } c) _services.CopySecret(c.Code); }, code is not null),
            ("Copy invite", () => Run(CopyInviteAsync), true),
            ("New code", () => Run(async () => { if (await _model.LoadCodeAsync(true)) _revealed = true; Render(); }), true),
            (status.Locked == true ? "Unlock" : "Lock room", () => Run(() => _model.SetLockedAsync(status.Locked != true)), true));
        if (_model.InviteCopied) Line(ShareText.InviteCopied, 0.8);
        if (_model.RemovedName is { } name) Line(ShareText.RemovedNotice(name), 0.8);
        Line(ShareText.CodeNote, 0.8);
        Line(ShareText.CodeProves, 0.65);
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
        foreach (var check in status.Checks)
        {
            if (ShareText.WaitsForStart(check, status)) { Line($"{ShareText.CheckTitle(check)}: {ShareText.CheckedAtStart}", 0.7); continue; }
            Line($"{ShareText.CheckStatus(check.Status)}: {ShareText.CheckTitle(check)}", error: check.Status == ShareCheckStatus.Fail);
            if (check.Status != ShareCheckStatus.Ok && check.Message.Length > 0 && ShareText.CheckTitle(check) != check.Message) Line(check.Message, 0.65);
            if (check.Status != ShareCheckStatus.Ok && ShareText.FixLabel(check.Fix) is { } label && check.Fix != ShareFixAction.InstallNetworkProtection)
                Row((label, () => Run(() => Fix(check.Fix, status)), true));
        }
    }

    private async Task Fix(ShareFixAction action, ShareStatus status)
    {
        switch (action)
        {
            case ShareFixAction.UpdateCli:
                _services.OpenUrl(AboutWindow.DocsUrl);
                break;
            case ShareFixAction.RestartSharing:
                if (!Confirm("Restart sharing?", "Everyone in the room is disconnected and needs the new room code to join again.", "Restart")) break;
                if (await _model!.StopAsync()) await _model.StartAsync(_hours);
                break;
        }
    }

    private void DrawCopy(ShareCopy copy)
    {
        _root.Children.Add(Ui.Heading("The copy"));
        Line(ShareText.CopyLine(copy));
        if (copy.Drifted) Line(ShareText.DriftWarning, caution: true);
    }

    private void DrawPeople(ShareStatus status)
    {
        _root.Children.Add(Ui.Heading(ShareText.PeopleTitle));
        if (_model!.People.Count == 0) Line("Nobody has joined yet.", 0.7);
        foreach (var person in ShareText.Sorted(_model.People))
        {
            Line($"{(person.Online ? "Online" : "Offline")}: {ShareText.PersonLine(person)} · {person.SeatName ?? "No seat yet"}");
            Row(("Remove " + person.Name, () => Run(() => RemoveAsync(person)), true));
        }
    }

    private async Task RemoveAsync(SharePerson person)
    {
        if (Confirm(ShareText.RemoveConfirm(person, Site), ShareText.RemoveDetail, "Remove")) await _model!.RemoveAsync(person);
    }
}
