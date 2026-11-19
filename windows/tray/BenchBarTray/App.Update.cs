using System.Windows;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// Updates: one check through benchbar.exe (<c>self-update --check --json</c>), one offer shown in the BenchBar window, the flyout, the tray
/// menu and About, Update Now (the update window), and the "BenchBar was updated" notice at the first start of a newer version.
/// </summary>
public partial class App
{
    private SelfUpdateClient? _updateClient;
    private SelfUpdateLauncher? _updateLauncher;

    private SelfUpdateClient UpdateClient => _updateClient ??= new SelfUpdateClient(new SystemProcessRunner(), () => ShimLocator.Find(), UpdateCheck.CurrentVersion());

    private SelfUpdateLauncher UpdateLauncher
    {
        get
        {
            if (_updateLauncher is null)
            {
                _updateLauncher = new SelfUpdateLauncher(() => ShimLocator.Find(), StartedProcess.Start, Environment.SystemDirectory,
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
                // the window closed while this tray still runs (a failure, or closed early): Update Now comes back
                _updateLauncher.Ended += () => Dispatcher.BeginInvoke(ShowUpdateEverywhere);
            }
            return _updateLauncher;
        }
    }

    private bool UpdateRunning => _updateLauncher?.IsRunning == true;

    /// <summary>The offer as each surface draws it: the window's banner (unless dismissed), the flyout line and, on open, the menu and About.</summary>
    private void ShowUpdateEverywhere()
    {
        _main?.SetUpdate(_updateOffer, DismissUpdate, UpdateRunning);
        _flyout?.View.SetUpdate(_updateOffer, UpdateRunning);
        _menu?.RefreshUpdate();
        _aboutWindow?.ShowOffer(_updateKnown);
    }

    /// <summary>The last offer a check found, whether or not the banner was dismissed: the menu and About still offer it.</summary>
    private UpdateOffer? _updateKnown;

    /// <summary>
    /// Runs one check and keeps its offer. A failure (no shim, another version of it, the shim's own <c>error</c>) is written to the log and
    /// shows nothing, as before; the menu item and About say it in words.
    /// </summary>
    private async Task<SelfUpdateCheck> RunUpdateCheckAsync()
    {
        var check = await UpdateClient.CheckAsync(CancellationToken.None);
        var problem = check.Problem ?? check.Status?.Error;
        if (problem is not null)
        {
            _log.Write("update-check", new InvalidOperationException(problem));
            return check;
        }
        _updateKnown = UpdatePlanner.Offer(check.Status);
        _updateOffer = UpdatePlanner.Offer(check.Status, _updateDismissed);
        ShowUpdateEverywhere();
        return check;
    }

    /// <summary>Asks when the BenchBar window opens, with the Settings switch on, at most once in six hours; a failure tries again next time.</summary>
    private async Task CheckBannerAsync()
    {
        var now = Math.Max(1, Environment.TickCount64);
        if (!UpdatePlanner.CheckDue(_config.CheckForUpdates, _updateCheckedAt, now))
        {
            ShowUpdateEverywhere();
            return;
        }
        _updateCheckedAt = now;
        var check = await RunUpdateCheckAsync();
        if (check.Problem is not null || check.Status?.Error is not null) _updateCheckedAt = 0;
    }

    private void DismissUpdate()
    {
        _updateDismissed = _updateOffer?.Version;
        _updateOffer = null;
        _flyout?.View.SetUpdate(null, false);
    }

    /// <summary>
    /// Update Now from any surface. The tray does not close itself: the installer the update window runs closes it (the Quit event, see
    /// <see cref="QuitEventName"/>) and starts it again. A second click while the window runs starts nothing and says so.
    /// </summary>
    private void UpdateNow()
    {
        if (_quitting) return;
        var start = UpdateLauncher.Start();
        switch (start.Kind)
        {
            case UpdateStartKind.Started:
                _notices.Remove("update-failed");
                break;
            case UpdateStartKind.AlreadyRunning:
                ShowInfo(start.Message!);
                break;
            default:
                _notices.Set(new Notice("update-failed", $"The update could not start. {start.Message} You can run the update line in PowerShell instead.",
                    "Copy Update Line", () => CopyText(UpdateLinks.InstallCommand)));
                break;
        }
        ShowUpdateEverywhere();
    }

    /// <summary>Check for Updates in the tray menu: says the answer in a dialog, with Update Now when it can.</summary>
    private async Task CheckForUpdatesAsync()
    {
        if (!UpdatePolicy.ChecksForUpdates(_package)) return; // the Store updates the package
        var check = await RunUpdateCheckAsync();
        var text = UpdatePlanner.CheckText(check);
        var offer = UpdatePlanner.Offer(check.Status);
        if (offer is null)
        {
            MessageBox.Show(text, "BenchBar", MessageBoxButton.OK, check.Problem is null && check.Status?.Error is null ? MessageBoxImage.Information : MessageBoxImage.Warning);
            return;
        }
        if (offer.CanUpdateNow)
        {
            var answer = MessageBox.Show($"{text} You have {UpdateCheck.ShortVersion()}.\n\n{UpdateLinks.UpdateNowExplanation}\n\nUpdate now?",
                "BenchBar", MessageBoxButton.YesNo, MessageBoxImage.Information);
            if (answer == MessageBoxResult.Yes) UpdateNow();
            return;
        }
        CopyText(UpdateLinks.InstallCommand);
        var open = MessageBox.Show($"{text} You have {UpdateCheck.ShortVersion()}.\n\n{UpdateLinks.InstallExplanation} The line is copied to the clipboard:\n\n{UpdateLinks.InstallCommand}\n\nOpen the release page too?",
            "BenchBar", MessageBoxButton.YesNo, MessageBoxImage.Information);
        if (open == MessageBoxResult.Yes) OpenUrl(offer.Url);
    }

    /// <summary>
    /// At start: a newer version than the config recorded says "BenchBar was updated to X" once, with What's New (the release page of that
    /// version), and records it. A first install and a normal start say nothing. True when this start is the first of a newer version.
    /// </summary>
    private bool NoteVersion()
    {
        var decision = UpdatedNotice.Decide(_config.LastVersion, UpdateCheck.ShortVersion(), _config.HadTraySection);
        if (decision.Record is null) return false;
        _config.LastVersion = decision.Record;
        if (decision.Show)
        {
            // someone who updates already knows where BenchBar lives: no "still running" hint for them
            _config.RunningHintShown = true;
            var version = decision.Version!;
            var text = UpdatedNotice.Text(version);
            _notices.Set(new Notice("updated", text, UpdatedNotice.ActionLabel, () => OpenUrl(UpdateLinks.ReleasePage(version)), Critical: false));
            ShowInfo(text + " Click for what's new.");
        }
        SaveConfig();
        return decision.Show;
    }

    /// <summary>
    /// The first time a BenchBar window closes (the wizard's window on a first run included), one balloon says BenchBar keeps running in
    /// the notification area. Never again after that, and not while quitting.
    /// </summary>
    private void MaybeShowRunningHint()
    {
        if (_quitting || _config.RunningHintShown) return;
        _config.RunningHintShown = true;
        SaveConfig();
        ShowInfo(RunningHint.Text);
    }

    private void ShowInfo(string text)
    {
        try
        {
            _icon?.TrayIcon.ShowNotification("BenchBar", text, H.NotifyIcon.Core.NotificationIcon.Info);
        }
        catch (Exception ex)
        {
            _log.Write("notice", ex);
        }
    }
}

/// <summary>The one time hint after the first window closes.</summary>
internal static class RunningHint
{
    public const string Text = "BenchBar is still running. Find it in the notification area near the clock (it may be under the ^ arrow), or open BenchBar from the Start menu.";
}
