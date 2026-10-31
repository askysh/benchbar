using System.Text.RegularExpressions;

namespace BenchBar.Tray.Core;

public enum WizardPage { Welcome, CliOnly, Check, LinuxUser, ExistingBench, NewBench, Review, Install, Done }

public enum WizardFlow { NewBench, ExistingBench }

/// <summary>Why the wizard window should close.</summary>
public enum WizardClose { Cancelled, Finished }

/// <summary>What the wizard needs from the app. The app implements it; tests fake it.</summary>
public interface IWizardHost
{
    /// <summary>Writes (or removes) the one shot flag that opens the wizard again after the next logon.</summary>
    void SetResumeAfterLogon(bool on);

    /// <summary>Restarts Windows. False when the request was not made.</summary>
    bool RestartWindows();

    /// <summary>Called just before an elevated action starts, so the Windows permission prompt may come to the front.</summary>
    void AllowForeground() { }

    /// <summary>The Windows user name, to suggest a Linux one.</summary>
    string WindowsUserName { get; }

    bool Notifications { get; set; }

    bool OpenAtLogon { get; set; }

    /// <summary>The <c>distro</c> key of the shim's config, null when it has none. The wizard makes the distro it checked the one the shim uses.</summary>
    string? ConfiguredDistro { get; }

    void OpenUrl(string url);

    void CopyText(string text);
}

/// <summary>The small dialog before an install that needs sudo: how many steps, and whether an earlier password was refused.</summary>
public sealed record LinuxPasswordRequest(int SudoSteps, bool WasWrong, bool UserExisted = false);

/// <summary>Why an install or adopt run ended without success.</summary>
public sealed record WizardFailure(string? Step, string Message, string? Fix, string? Log);

public enum InstallPhase { Idle, Running, Succeeded, Failed, NeedsRootPassword, NeedsLinuxPassword, Stopped }

/// <summary>One step on the Install page.</summary>
public sealed record InstallRow(string Id, string? Parent, string Name, InstallStepStatus Status, int? Secs, string? Message, string? Command);

/// <summary>A row of the Check Your PC page, as the page draws it.</summary>
public sealed record CheckRow(SetupStepInfo Step, bool Busy, string? Message, string? ButtonLabel, bool ShowsShield, string? AdminNote, bool Waiting = false);

/// <summary>
/// The first run wizard as a value you can drive: pages, the form fields, and the calls to the shim. No window code:
/// the views read these properties and call these methods. Every call is meant for the UI thread; events from a running
/// child arrive on any thread and are posted back through the captured <see cref="SynchronizationContext"/> (inline when
/// there is none, as in tests). Passwords are <see cref="Secret"/>s and live in this object only.
/// </summary>
public sealed partial class WizardModel : IDisposable
{
    public const string LinuxCliInstallLine = "curl -fsSL https://raw.githubusercontent.com/askysh/benchbar/main/install.sh | bash";
    public const string McpLine = "claude mcp add benchbar -- benchbar.exe mcp";
    public const string DefaultSite = "linuxdev.localhost";
    public const string DefaultProfile = "v15-lts";
    public const string RestartRefusedMessage = "Windows did not allow the restart. Restart from the Start menu.";
    public const string CancelledMessage = "You said no to the Windows prompt. Try again when ready.";
    public const string AdminNote = "Windows will ask for permission";
    public const string RestartBlurb = "Windows has to restart to finish turning on WSL. BenchBar opens again after you sign in and picks up here. Shut down does not count. Use Restart.";
    public const string RestartAgainHint = "If Windows did not restart, click Restart Now again.";
    public const string WaitingForPromptMessage = "Waiting for you to answer the Windows prompt. It may be behind other windows.";
    public const string HomeUnknownMessage = "BenchBar could not read your Linux home folder. Make sure Ubuntu starts, then check again.";
    public const string DistroRunningQuestion = "Ubuntu is running. Setting this up restarts it, which stops any benches and MariaDB inside it. Restart Ubuntu now?";
    public const string StoppedWaitingMessage = "Stopped waiting. If you already answered the Windows prompt, WSL keeps installing. Restart Windows when it finishes, then check again.";

    /// <summary>How long Restart Now stays off after a restart was requested. A shutdown that was aborted must not leave the button dead.</summary>
    public TimeSpan RestartRetryAfter { get; set; } = TimeSpan.FromSeconds(30);

    public static readonly IReadOnlyList<string> Bundles = ["minimal", "common", "extended"];

    private readonly ISetupService _setup;
    private readonly IWizardHost _host;
    private readonly SynchronizationContext? _context = SynchronizationContext.Current;
    private CancellationTokenSource? _checkCts;
    private CancellationTokenSource? _runCts;
    private Secret _linuxPassword = Secret.Empty();
    private Secret _confirmPassword = Secret.Empty();
    private Secret _adminPassword = Secret.Empty();
    private Secret _rootPassword = Secret.Empty();
    private bool _disposed;
    private bool _probe;
    private readonly CancellationTokenSource _lifetime = new();
    private bool _restartFromAction;
    private string? _alignedDistro;
    private string? _busyAction;

    public WizardModel(ISetupService setup, IWizardHost host, string? distro = null)
    {
        _setup = setup;
        _host = host;
        Distro = distro;
        UserName = SuggestUserName(host.WindowsUserName);
    }

    /// <summary>Raised after any change. May be raised from a worker thread only through <see cref="Post"/>: it is always on the UI thread.</summary>
    public event Action? Changed;

    /// <summary>Asks for the Linux password in a small dialog; null when cancelled. Set by the view.</summary>
    public Func<LinuxPasswordRequest, Task<Secret?>> AskLinuxPassword { get; set; } = _ => Task.FromResult<Secret?>(null);

    /// <summary>Asks "Ubuntu is running. Restart it now?" before an action is run again with --force. Set by the view; the default says no.</summary>
    public Func<string, Task<bool>> ConfirmRestartDistro { get; set; } = _ => Task.FromResult(false);

    public event Action<WizardClose>? CloseRequested;

    // --- state ---

    public WizardPage Page { get; private set; } = WizardPage.Welcome;

    public WizardFlow Flow { get; private set; } = WizardFlow.NewBench;

    public string? Distro { get; private set; }

    // --- check ---

    public SetupReport Report { get; private set; } = SetupReport.Empty;

    public bool Checking { get; private set; }

    public string? CheckError { get; private set; }

    /// <summary>The step whose action is running now; null when none.</summary>
    public string? BusyStepId { get; private set; }

    public bool FixingAll { get; private set; }

    /// <summary>The last line each step's action printed (a failure, a note), by step id.</summary>
    public IReadOnlyDictionary<string, string> StepMessages => _messages;

    private readonly Dictionary<string, string> _messages = [];

    /// <summary>The lines the running action printed, newest last; at most <see cref="LogLimit"/>.</summary>
    public IReadOnlyList<string> ActionLog => _actionLog;

    private readonly List<string> _actionLog = [];

    public const int LogLimit = 200;

    /// <summary>Windows must restart: the page offers Restart Now and the wizard resumes after logon.</summary>
    public bool RestartNeeded { get; private set; }

    public bool RestartRequested { get; private set; }

    /// <summary>Shown under Restart Now once the 30 seconds are over and Windows has not restarted.</summary>
    public string? RestartHint { get; private set; }

    /// <summary>Ends when the "Restart Now is off" wait is over (for tests).</summary>
    internal Task? RestartWatch { get; private set; }

    public IReadOnlyList<CheckRow> Rows => Report.Steps.Select(MakeRow).ToList();

    private CheckRow MakeRow(SetupStepInfo step)
    {
        _messages.TryGetValue(step.Id, out var message);
        var actionable = !step.IsSatisfied && step.Action is { Length: > 0 };
        var waiting = step.Waits;
        var label = !actionable ? null : step.Action switch
        {
            SetupIds.ActionReboot => "Restart Now",
            SetupIds.ActionDistroUser => "Create User",
            SetupIds.ActionWslEnable => "Turn On",
            _ => "Set Up",
        };
        return new CheckRow(step, BusyStepId == step.Id, message, label, actionable && !waiting && step.NeedsAdmin, actionable && !waiting && step.NeedsAdmin ? AdminNote : null, waiting);
    }

    /// <summary>Why the shim cannot use the distro the wizard checked (it could not be recorded), or null.</summary>
    public string? DistroAlignError { get; private set; }

    /// <summary>Continue is possible once every blocking step is done. Advice rows (linger, keep awake, .wslconfig, PATH) never hold it back.</summary>
    public bool CanContinueFromCheck => !Checking && BusyStepId is null && Report.CanContinue && DistroAlignError is null;

    // --- linux user ---

    public string UserName { get; private set; }

    public bool UserCreated { get; private set; }

    /// <summary>The shim found the user already there: the password typed here is not that user's, so it is not used for sudo.</summary>
    public bool UserExisted { get; private set; }

    public bool CreatingUser { get; private set; }

    public string? UserError { get; private set; }

    public Secret LinuxPassword => _linuxPassword;

    public static readonly Regex LinuxUserPattern = LinuxUserRegex();

    [GeneratedRegex(@"^[a-z_][a-z0-9_-]{0,30}$", RegexOptions.CultureInvariant)]
    private static partial Regex LinuxUserRegex();

    /// <summary>The Windows user name as the Linux layer would write it: lowercase, letters, digits, '_' and '-', starting with a letter.</summary>
    public static string SuggestUserName(string windowsName)
    {
        var chars = windowsName.ToLowerInvariant().Select(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '_' or '-' ? c : '-').ToArray();
        var text = new string(chars).Trim('-');
        if (text.Length == 0) return "user";
        if (!(text[0] is >= 'a' and <= 'z' or '_')) text = "u" + text;
        return text.Length > 31 ? text[..31] : text;
    }

    public string? UserNameProblem => LinuxUserPattern.IsMatch(UserName) && UserName != "root"
        ? null
        : "Use lowercase letters, digits, '-' and '_', starting with a letter. root is not allowed.";

    public string? PasswordProblem
    {
        get
        {
            if (_linuxPassword.IsEmpty) return "Choose a password. It is what sudo asks for later.";
            var text = _linuxPassword.Reveal();
            if (text.Any(c => c is '\n' or '\r' or '\0')) return "The password cannot contain a line break.";
            if (!_linuxPassword.SameAs(_confirmPassword)) return "The two passwords are not the same.";
            return null;
        }
    }

    public bool CanCreateUser => !CreatingUser && UserNameProblem is null && PasswordProblem is null;

    // --- new bench ---

    /// <summary>The Linux home folder, read from the distro. Empty until it is known; the wizard never guesses one.</summary>
    public string Home { get; private set; } = "";

    public string Folder { get; private set; } = "";

    public string Site { get; private set; } = DefaultSite;

    public string Bundle { get; private set; } = "minimal";

    public string ExistingPath { get; private set; } = "";

    public Secret AdminPassword => _adminPassword;

    private bool _folderEdited;
    private bool _homeLoaded;

    public static bool IsValidSite(string name) =>
        name.Length > 0 && (char.IsAsciiLetterLower(name[0]) || char.IsAsciiDigit(name[0]))
        && name.All(c => char.IsAsciiLetterLower(c) || char.IsAsciiDigit(c) || c is '-' or '.');

    public const string SiteRule = "Lowercase letters, digits, '-' and '.' only.";

    public static bool IsValidFolder(string folder) =>
        folder.Length > 1 && folder[0] == '/' && !folder.Contains("//") && !folder.Contains("..")
        && folder.All(c => char.IsAsciiLetterOrDigit(c) || c is '/' or '.' or '_' or '-' or '+' or '@');

    public const string FolderRule = "An absolute Linux path with letters, digits and . _ - + @ only.";

    public string? FormProblem
    {
        get
        {
            if (!IsValidFolder(Folder)) return FolderRule;
            if (!IsValidSite(Site)) return SiteRule;
            if (!Bundles.Contains(Bundle)) return "Choose a bundle.";
            if (_adminPassword.IsEmpty) return "Choose the Administrator password for the site.";
            return null;
        }
    }

    public string? ExistingProblem => IsValidFolder(ExistingPath) ? null : FolderRule;

    // --- review ---

    public InstallPlan? Plan { get; private set; }

    public bool Planning { get; private set; }

    public string? PlanError { get; private set; }

    public InstallRequest Request => new(Folder, DefaultProfile, Bundle, Site);

    // --- install ---

    public InstallPhase Phase { get; private set; } = InstallPhase.Idle;

    public WizardFailure? Failure { get; private set; }

    public IReadOnlyList<InstallRow> InstallRows => _rows;

    private readonly List<InstallRow> _rows = [];

    public string ProgressLabel { get; private set; } = "";

    public string? LogPath { get; private set; }

    public string? SiteUrl { get; private set; }

    public IReadOnlyList<string> SkippedCommands { get; private set; } = [];

    public bool StopRequested { get; private set; }

    public bool IsInstalling => Page == WizardPage.Install && Phase == InstallPhase.Running;

    public Secret RootPassword => _rootPassword;

    // --- bug report ---

    /// <summary>The page's plain name, for the window title of a report and the bug report context.</summary>
    public static string PageName(WizardPage page) => page switch
    {
        WizardPage.Welcome => "Welcome",
        WizardPage.CliOnly => "Command line tool only",
        WizardPage.Check => "Check Your PC",
        WizardPage.LinuxUser => "Linux user",
        WizardPage.ExistingBench => "Existing bench",
        WizardPage.NewBench => "New bench",
        WizardPage.Review => "Review",
        WizardPage.Install => "Install",
        _ => "Done",
    };

    /// <summary>Where the person is, as a sentence for a bug report.</summary>
    public string ReportWhere => ReportContext.Wizard(Page, Flow, BusyStepId);

    /// <summary>The problem the page shows now, if any (a check error, a failed step, a failed install, a plan error), for a bug report.</summary>
    public string? ReportProblem
    {
        get
        {
            if (Failure is { } f && Page == WizardPage.Install) return f.Step is null ? f.Message : $"{f.Step} failed: {f.Message}";
            if (PlanError is { Length: > 0 } plan && Page == WizardPage.Review) return plan;
            if (UserError is { Length: > 0 } user && Page == WizardPage.LinuxUser) return user;
            if (CheckError is { Length: > 0 } check) return check;
            var failed = Report.Steps.FirstOrDefault(s => s.StopsTheWizard && !s.Waits);
            return failed is null ? null : ReportContext.Step(failed, _messages.GetValueOrDefault(failed.Id));
        }
    }

    // --- helpers ---

    private void Raise() => Post(() => Changed?.Invoke());

    /// <summary>Runs on the UI thread: inline when already on it or when there is no context (tests).</summary>
    private void Post(Action action)
    {
        if (_context is null || SynchronizationContext.Current == _context) action();
        else _context.Post(_ => { if (!_disposed) action(); }, null);
    }

    private void Go(WizardPage page)
    {
        Page = page;
        Raise();
    }

    // --- welcome ---

    public Task ChooseNewBench()
    {
        if (Page != WizardPage.Welcome) return Task.CompletedTask;
        Flow = WizardFlow.NewBench;
        Go(WizardPage.Check);
        return CheckAsync();
    }

    public Task ChooseExistingBench()
    {
        if (Page != WizardPage.Welcome) return Task.CompletedTask;
        Flow = WizardFlow.ExistingBench;
        Go(WizardPage.Check);
        return CheckAsync();
    }

    public void ChooseCommandLineOnly()
    {
        if (Page != WizardPage.Welcome) return;
        Go(WizardPage.CliOnly);
    }

    /// <summary>Opens straight on the Check page (the wizard resumed after a restart).</summary>
    public Task ResumeAtCheck()
    {
        Flow = WizardFlow.NewBench;
        Page = WizardPage.Check;
        return CheckAsync();
    }

    /// <summary>Back or Cancel: one page back, or the window closes from the first page.</summary>
    public void Back()
    {
        switch (Page)
        {
            case WizardPage.Welcome:
                CloseRequested?.Invoke(WizardClose.Cancelled);
                break;
            case WizardPage.CliOnly:
            case WizardPage.Check:
                if (BusyStepId is not null) return;
                Go(WizardPage.Welcome);
                break;
            case WizardPage.LinuxUser:
                if (CreatingUser) return;
                if (!UserCreated)
                {
                    // a half typed password must not become the sudo password of a user that was never created here
                    _linuxPassword.Dispose();
                    _linuxPassword = Secret.Empty();
                    _confirmPassword.Dispose();
                    _confirmPassword = Secret.Empty();
                }
                Go(WizardPage.Check);
                break;
            case WizardPage.ExistingBench:
            case WizardPage.NewBench:
                Go(WizardPage.Check);
                break;
            case WizardPage.Review:
                CancelRun();
                Go(WizardPage.NewBench);
                break;
            case WizardPage.Install:
                if (IsInstalling) return;
                Go(Flow == WizardFlow.ExistingBench ? WizardPage.ExistingBench : WizardPage.Review);
                break;
            case WizardPage.Done:
                Finish();
                break;
        }
    }

    /// <summary>A step, a check or the install runs now: the wizard cannot change flow, and its window should not close without asking.</summary>
    public bool IsRunning => BusyStepId is not null || CreatingUser || FixingAll || Planning || IsInstalling;

    /// <summary>
    /// "New Bench" or "I Already Have a Bench" asked for while the wizard is already open: go to the Check page of that flow, unless
    /// something runs (then nothing changes and false comes back). Typed values stay; a finished or failed install is left behind.
    /// </summary>
    public Task<bool> SwitchFlowAsync(WizardFlow flow)
    {
        if (_disposed || IsRunning) return Task.FromResult(false);
        if (Flow == flow && Page == WizardPage.Check) return Task.FromResult(true);
        CancelRun();
        Flow = flow;
        if (Page is WizardPage.Install or WizardPage.Done)
        {
            Phase = InstallPhase.Idle;
            Failure = null;
            _rows.Clear();
        }
        Go(WizardPage.Check);
        return SwitchChecked();
    }

    private async Task<bool> SwitchChecked()
    {
        await CheckAsync().ConfigureAwait(true);
        return true;
    }

    // --- check ---

    public async Task CheckAsync()
    {
        if (_disposed) return;
        _checkCts?.Cancel();
        var cts = _checkCts = new CancellationTokenSource();
        Checking = true;
        CheckError = null;
        Raise();
        try
        {
            var report = await _setup.CheckAsync(Distro, cts.Token, probe: _probe).ConfigureAwait(true);
            if (cts.IsCancellationRequested) return;
            // Without --probe a stopped distro is not looked into. Once the distro exists on this PC the wizard looks once, which starts it.
            if (!_probe && report.Step(SetupIds.Distro) is { IsOk: true } && report.Steps.Any(s => s.NotChecked))
            {
                _probe = true;
                report = await _setup.CheckAsync(Distro, cts.Token, probe: true).ConfigureAwait(true);
                if (cts.IsCancellationRequested) return;
            }
            Report = report;
            if (report.Distro is { Length: > 0 } d) Distro = d;
            if (report.RebootPending) NoteRestartNeeded();
            // a restart an action asked for stays until Windows restarts (the wizard then starts again): the check may not know of it yet
            else if (RestartNeeded && !_restartFromAction && report.Step(SetupIds.Reboot) is { IsSatisfied: true }) ClearRestart();
            await AlignDistroAsync(report, cts.Token).ConfigureAwait(true);
        }
        catch (OperationCanceledException) when (cts.IsCancellationRequested)
        {
            return;
        }
        catch (Exception ex) when (ex is SourceProblemException or System.Text.Json.JsonException or TimeoutException or System.ComponentModel.Win32Exception or IOException)
        {
            CheckError = ex.Message;
        }
        finally
        {
            if (ReferenceEquals(_checkCts, cts)) Checking = false;
            Raise();
        }
    }

    /// <summary>
    /// Once the distro step passes, the distro the wizard checked becomes the one the shim uses (<c>adopt-distro NAME --json</c>), so the
    /// install, adopt and report that follow all go to the same distro. Asked once per name; a failure blocks Continue and says why.
    /// </summary>
    private async Task AlignDistroAsync(SetupReport report, CancellationToken ct)
    {
        DistroAlignError = null;
        if (report.Step(SetupIds.Distro) is not { IsOk: true } || report.Distro is not { Length: > 0 } name) return;
        if (_alignedDistro == name) return;
        if (string.Equals(_host.ConfiguredDistro, name, StringComparison.OrdinalIgnoreCase))
        {
            _alignedDistro = name;
            return;
        }
        var result = await _setup.UseDistroAsync(name, ct).ConfigureAwait(true);
        if (ct.IsCancellationRequested || _disposed) return;
        if (result.Ok) _alignedDistro = name;
        else DistroAlignError = $"BenchBar could not make {name} its distro: {result.Message ?? "adopt-distro failed"}";
        if (DistroAlignError is not null) CheckError = DistroAlignError;
    }

    private void NoteRestartNeeded()
    {
        RestartNeeded = true;
        _host.SetResumeAfterLogon(true);
    }

    private void ClearRestart()
    {
        RestartNeeded = false;
        RestartRequested = false;
        RestartHint = null;
        _restartFromAction = false;
        _host.SetResumeAfterLogon(false);
    }

    /// <summary>The Restart Now button, after the view asked "Restart Windows now?" and got a yes.</summary>
    public bool RestartNow()
    {
        _host.SetResumeAfterLogon(true);
        RestartRequested = _host.RestartWindows();
        RestartHint = null;
        // a refused restart keeps the flag: it is still useful when the person restarts by hand
        if (RestartRequested)
        {
            _messages.Remove(SetupIds.Reboot);
            RestartWatch = WatchRestartAsync();
        }
        else _messages[SetupIds.Reboot] = RestartRefusedMessage;
        Raise();
        return RestartRequested;
    }

    /// <summary>The restart was asked for. If Windows is still here after the wait (the shutdown was aborted), Restart Now comes back.</summary>
    private async Task WatchRestartAsync()
    {
        try
        {
            await Task.Delay(RestartRetryAfter, _lifetime.Token).ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        if (_disposed || !RestartRequested) return;
        RestartRequested = false;
        RestartHint = RestartAgainHint;
        Raise();
    }

    /// <summary>Runs the action of one row. <c>reboot</c> is not run here (the view confirms, then calls <see cref="RestartNow"/>); <c>distro_user</c> without a user opens the Linux User page.</summary>
    public async Task RunStepAsync(string stepId)
    {
        if (BusyStepId is not null || Checking) return;
        var step = Report.Step(stepId);
        if (step is null || step.Action is not { Length: > 0 } action) return;
        if (action == SetupIds.ActionReboot) return;
        if (action == SetupIds.ActionDistroUser && !UserCreated)
        {
            Go(WizardPage.LinuxUser);
            return;
        }
        await RunActionAsync(step, action).ConfigureAwait(true);
        if (_disposed) return;
        await CheckAsync().ConfigureAwait(true);
    }

    private async Task<SetupRunResult> RunActionAsync(SetupStepInfo step, string action, bool force = false)
    {
        var cts = _runCts = new CancellationTokenSource();
        BusyStepId = step.Id;
        _busyAction = action;
        if (step.NeedsAdmin || action == SetupIds.ActionWslEnable) _host.AllowForeground();
        _messages.Remove(step.Id);
        if (action == SetupIds.ActionWslEnable) _messages[step.Id] = WaitingForPromptMessage;
        _actionLog.Clear();
        Raise();
        SetupRunResult result;
        var stoppedWaiting = false;
        try
        {
            var request = new SetupRunRequest(action, Distro, action == SetupIds.ActionDistroUser ? UserName : null,
                action == SetupIds.ActionDistroUser ? _linuxPassword : null, force);
            result = await _setup.RunActionAsync(request, OnSetupEvent, cts.Token).ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            stoppedWaiting = action == SetupIds.ActionWslEnable;
            result = new SetupRunResult(1, false, false, true, [], [], "Cancelled.");
        }
        catch (TimeoutException ex)
        {
            stoppedWaiting = action == SetupIds.ActionWslEnable;
            result = new SetupRunResult(1, false, false, false, [], [], ex.Message);
        }
        catch (Exception ex) when (ex is SourceProblemException or System.ComponentModel.Win32Exception or IOException or InvalidOperationException)
        {
            // a blocked or missing benchbar.exe ends the step with a line; it never leaves the row on Working forever
            result = new SetupRunResult(1, false, false, false, [], [], ex.Message);
        }
        finally
        {
            BusyStepId = null;
            _busyAction = null;
        }

        if (stoppedWaiting)
        {
            // the elevated wsl.exe belongs to Windows, not to us: it may still run. The next check says what it finished.
            _messages[step.Id] = StoppedWaitingMessage;
        }
        else if (result.Cancelled && !result.RebootRequired) _messages[step.Id] = CancelledMessage;
        else if (!result.Ok && !result.RebootRequired) _messages[step.Id] = result.Error ?? "It did not work. Open the log for details.";
        else if (result.Warnings.Count > 0) _messages[step.Id] = result.Warnings[0];
        if (result.RebootRequired)
        {
            // also for a run the shim reports as stopped but still going: Restart Now stays until Windows has restarted
            _restartFromAction = true;
            NoteRestartNeeded();
        }
        Raise();

        if (!_disposed && result.ErrorId == SetupIds.ErrorDistroRunning && !force && action is SetupIds.ActionSystemd or SetupIds.ActionDistroUser)
        {
            if (await ConfirmRestartDistro(DistroRunningQuestion).ConfigureAwait(true) && !_disposed)
                return await RunActionAsync(step, action, force: true).ConfigureAwait(true);
        }
        return result;
    }

    private void OnSetupEvent(SetupEvent e) => Post(() =>
    {
        switch (e)
        {
            case SetupEvent.Log log:
                _actionLog.Add(log.Line);
                if (_actionLog.Count > LogLimit) _actionLog.RemoveRange(0, _actionLog.Count - LogLimit);
                break;
            // the Windows prompt wait keeps its own words; every other step shows what the shim says it is doing, and how it ended
            case SetupEvent.Step { Status: "running" } when _busyAction == SetupIds.ActionWslEnable:
                break;
            case SetupEvent.Step { Status: "running" or "done" or "skipped" } step when BusyStepId is not null && step.Message.Length > 0:
                _messages[BusyStepId] = step.Message;
                break;
        }
        Changed?.Invoke();
    });

    /// <summary>Runs every step that needs only a click, in order, until one needs the person (a user name, a restart) or fails.</summary>
    public async Task FixAllAsync()
    {
        if (_disposed || FixingAll || BusyStepId is not null) return;
        FixingAll = true;
        Raise();
        try
        {
            for (var guard = 0; guard < 16; guard++)
            {
                if (Report.Steps.Count == 0) await CheckAsync().ConfigureAwait(true);
                var next = Report.NextActionable;
                if (next is null || next.Action == SetupIds.ActionReboot) break;
                if (next.Action == SetupIds.ActionDistroUser && !UserCreated)
                {
                    Go(WizardPage.LinuxUser);
                    break;
                }
                var result = await RunActionAsync(next, next.Action!).ConfigureAwait(true);
                if (_disposed) break;
                await CheckAsync().ConfigureAwait(true);
                if (!result.Ok || RestartNeeded || _disposed) break;
            }
        }
        finally
        {
            FixingAll = false;
            Raise();
        }
    }

    public void CancelRun() => _runCts?.Cancel();

    /// <summary>Continue on the Check page.</summary>
    public async Task ContinueFromCheckAsync()
    {
        if (!CanContinueFromCheck) return;
        // the home folder is read, never guessed: a wrong guess would put the bench in a folder that does not exist
        if (!await EnsureHomeAsync().ConfigureAwait(true)) return;
        if (Flow == WizardFlow.ExistingBench)
        {
            if (ExistingPath.Length == 0) ExistingPath = Home + "/frappe-bench";
            Go(WizardPage.ExistingBench);
            return;
        }
        Go(WizardPage.NewBench);
    }

    private async Task<bool> EnsureHomeAsync()
    {
        if (_homeLoaded) return true;
        string? home;
        try
        {
            home = await _setup.HomeAsync(Distro, CancellationToken.None).ConfigureAwait(true);
        }
        catch (Exception ex) when (ex is SourceProblemException or System.ComponentModel.Win32Exception or IOException)
        {
            home = null;
        }
        if (_disposed) return false;
        if (home is not null) Home = home.TrimEnd('/');
        else if (UserCreated) Home = "/home/" + UserName; // the user this wizard just made: its home is known
        else
        {
            CheckError = HomeUnknownMessage;
            Raise();
            return false;
        }
        _homeLoaded = true;
        if (!_folderEdited) Folder = Home + "/frappe-bench";
        return true;
    }

    // --- linux user ---

    public void SetUserName(string name)
    {
        UserName = name.Trim();
        Raise();
    }

    public void SetPassword(Secret secret)
    {
        _linuxPassword.Dispose();
        _linuxPassword = secret;
        Raise();
    }

    public void SetConfirm(Secret secret)
    {
        _confirmPassword.Dispose();
        _confirmPassword = secret;
        Raise();
    }

    /// <summary>Creates the Linux user (<c>distro_user</c>), then goes back to the Check page, which checks again.</summary>
    public async Task CreateUserAsync()
    {
        if (!CanCreateUser) return;
        CreatingUser = true;
        UserError = null;
        Raise();
        var step = Report.Step(SetupIds.DistroUser) ?? new SetupStepInfo(SetupIds.DistroUser, SetupStatus.Missing, "Linux user", "", SetupIds.ActionDistroUser, false);
        SetupRunResult result;
        try
        {
            result = await RunActionAsync(step, SetupIds.ActionDistroUser).ConfigureAwait(true);
        }
        finally
        {
            CreatingUser = false;
        }
        if (result.Ok)
        {
            UserCreated = true;
            if (result.UserExisted)
            {
                UserExisted = true;
                _linuxPassword.Dispose();
                _linuxPassword = Secret.Empty();
                _confirmPassword.Dispose();
                _confirmPassword = Secret.Empty();
            }
            _homeLoaded = false;
            Go(WizardPage.Check);
            await CheckAsync().ConfigureAwait(true);
        }
        else
        {
            UserError = _messages.GetValueOrDefault(SetupIds.DistroUser) ?? "The user could not be created.";
            Raise();
        }
    }

    // --- new bench ---

    public void SetFolder(string folder)
    {
        Folder = folder.Trim();
        _folderEdited = true;
        Raise();
    }

    public void SetSite(string site)
    {
        Site = site.Trim();
        Raise();
    }

    public void SetBundle(string bundle)
    {
        Bundle = bundle;
        Raise();
    }

    public void SetExistingPath(string path)
    {
        ExistingPath = path.Trim();
        Raise();
    }

    public void SetAdminPassword(Secret secret)
    {
        _adminPassword.Dispose();
        _adminPassword = secret;
        Raise();
    }

    public void SetRootPassword(Secret secret)
    {
        _rootPassword.Dispose();
        _rootPassword = secret;
        Raise();
    }

    // --- review ---

    public async Task ReviewAsync()
    {
        if (Page != WizardPage.NewBench || FormProblem is not null) return;
        Page = WizardPage.Review;
        Plan = null;
        PlanError = null;
        Planning = true;
        Raise();
        var cts = _runCts = new CancellationTokenSource();
        try
        {
            var result = await _setup.PlanInstallAsync(Request, _adminPassword, cts.Token).ConfigureAwait(true);
            if (Page != WizardPage.Review) return;
            Plan = result.Plan;
            PlanError = result.Error;
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (Exception ex) when (ex is SourceProblemException or TimeoutException or System.ComponentModel.Win32Exception or IOException)
        {
            PlanError = ex.Message;
        }
        finally
        {
            Planning = false;
            Raise();
        }
    }

    public bool CanInstall => Page == WizardPage.Review && Plan is not null && !Planning;

    // --- install ---

    /// <summary>The Install button of the Review page.</summary>
    public async Task StartInstallAsync()
    {
        if (!CanInstall) return;
        await RunInstallAsync(adopt: false).ConfigureAwait(true);
    }

    /// <summary>The Adopt button of the existing bench page.</summary>
    public async Task StartAdoptAsync()
    {
        if (Page != WizardPage.ExistingBench || ExistingProblem is not null) return;
        await RunInstallAsync(adopt: true).ConfigureAwait(true);
    }

    /// <summary>Retry or Run Again on the Install page.</summary>
    public async Task RetryAsync()
    {
        if (Page != WizardPage.Install || Phase is InstallPhase.Running or InstallPhase.Succeeded or InstallPhase.Idle) return;
        if (Phase == InstallPhase.NeedsRootPassword && _rootPassword.IsEmpty) return;
        await RunInstallAsync(adopt: Flow == WizardFlow.ExistingBench, retrying: true).ConfigureAwait(true);
    }

    private int SudoSteps => Flow == WizardFlow.ExistingBench ? _adoptSudoSteps ?? 1 : Plan?.PrivilegedSteps.Count ?? 0;

    /// <summary>The adopt dry run's sudo steps; null when not read (then the password is asked for, as one step).</summary>
    private int? _adoptSudoSteps;

    private async Task RunInstallAsync(bool adopt, bool retrying = false)
    {
        if (adopt)
        {
            try
            {
                _adoptSudoSteps = await _setup.AdoptSudoStepsAsync(ExistingPath, CancellationToken.None).ConfigureAwait(true);
            }
            catch (Exception ex) when (ex is SourceProblemException or System.ComponentModel.Win32Exception or IOException)
            {
                _adoptSudoSteps = null;
            }
            if (_disposed) return;
        }
        // The Linux password: asked here only when the plan has sudo steps and the wizard did not create the user (or the last one was refused).
        var wrong = Phase == InstallPhase.NeedsLinuxPassword;
        var needsPassword = !adopt || _adoptSudoSteps is null or > 0 || wrong;
        if (needsPassword && (_linuxPassword.IsEmpty || wrong))
        {
            var asked = await AskLinuxPassword(new LinuxPasswordRequest(Math.Max(SudoSteps, 1), wrong, UserExisted)).ConfigureAwait(true);
            if (asked is null || asked.IsEmpty) return;
            _linuxPassword.Dispose();
            _linuxPassword = asked;
        }

        Page = WizardPage.Install;
        Phase = InstallPhase.Running;
        Failure = null;
        StopRequested = false;
        ProgressLabel = "";
        _rows.Clear();
        SeedRows();
        Raise();

        var cts = _runCts = new CancellationTokenSource();
        var secrets = new InstallSecrets(adopt ? null : _adminPassword, _linuxPassword, _rootPassword.IsEmpty ? null : _rootPassword);
        InstallRunResult? result = null;
        string? problem = null;
        try
        {
            result = adopt
                ? await _setup.AdoptAsync(ExistingPath, secrets, OnInstallEvent, cts.Token).ConfigureAwait(true)
                : await _setup.InstallAsync(Request, secrets, OnInstallEvent, cts.Token).ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            // Stop was pressed
        }
        catch (Exception ex) when (ex is SourceProblemException or TimeoutException or System.ComponentModel.Win32Exception or IOException or InvalidOperationException)
        {
            // a blocked benchbar.exe ends the run with a line; the page never stays on Running
            problem = ex.Message;
        }
        if (_disposed) return;
        Conclude(result, problem, cts.IsCancellationRequested);
    }

    private void SeedRows()
    {
        if (Plan is null || Flow == WizardFlow.ExistingBench) return;
        foreach (var s in Plan.Steps.Where(s => s.WillRun))
            _rows.Add(new InstallRow(s.Id, null, s.Name, InstallStepStatus.Unknown, null, null, null));
        LogPath = Plan.Log;
    }

    private void OnInstallEvent(InstallEvent e) => Post(() =>
    {
        switch (e)
        {
            case InstallEvent.Plan p:
                Plan = p.Value;
                LogPath = p.Value.Log ?? LogPath;
                if (_rows.Count == 0 || Flow == WizardFlow.ExistingBench) SeedFromPlan(p.Value);
                break;
            case InstallEvent.Step s:
                ApplyStep(s.Value);
                break;
            case InstallEvent.Progress g:
                ProgressLabel = g.Value.Label;
                break;
            case InstallEvent.Done d:
                LogPath = d.Value.Log ?? LogPath;
                break;
        }
        Changed?.Invoke();
    });

    private void SeedFromPlan(InstallPlan plan)
    {
        _rows.Clear();
        foreach (var s in plan.Steps.Where(s => s.WillRun))
            _rows.Add(new InstallRow(s.Id, null, s.Name, InstallStepStatus.Unknown, null, null, null));
    }

    private void ApplyStep(InstallStep step)
    {
        var row = new InstallRow(step.Id, step.Parent, step.Name, step.Status, step.Secs, step.Message, step.Command);
        var index = _rows.FindIndex(r => r.Id == step.Id);
        if (index >= 0) _rows[index] = row;
        else _rows.Add(row);
    }

    private void Conclude(InstallRunResult? result, string? problem, bool cancelled)
    {
        var done = result?.Done;
        // a step that was running when the process ended gets no end line
        for (var i = 0; i < _rows.Count; i++)
        {
            if (_rows[i].Status == InstallStepStatus.Running) _rows[i] = _rows[i] with { Status = InstallStepStatus.Stopped };
        }
        ProgressLabel = "";

        if (cancelled || StopRequested)
        {
            Phase = InstallPhase.Stopped;
        }
        else if (done is { WrongSudoPassword: true })
        {
            Phase = InstallPhase.NeedsLinuxPassword;
            Failure = new WizardFailure(null, "Linux did not accept that password.", null, done.Log ?? LogPath);
        }
        else if (result is { Ok: true } && done is not null)
        {
            Phase = InstallPhase.Succeeded;
            SiteUrl = done.Url ?? Plan?.WebUrl;
            SkippedCommands = done.Skipped;
            Page = WizardPage.Done;
            ClearRestart();
            ForgetPasswords(); // the bench is installed: nothing needs them again
        }
        else if ((done?.Exit ?? result?.ExitCode) == 2)
        {
            Phase = InstallPhase.NeedsRootPassword;
            Failure = new WizardFailure(null, "MariaDB already has a root password that BenchBar does not know.", done?.Fix, done?.Log ?? LogPath);
        }
        else
        {
            Phase = InstallPhase.Failed;
            var failedStep = _rows.LastOrDefault(r => r.Status == InstallStepStatus.Failed);
            var message = problem ?? done?.Error ?? failedStep?.Message ?? result?.Error ?? "The install did not finish.";
            Failure = new WizardFailure(failedStep?.Name, message, done?.Fix, done?.Log ?? LogPath);
        }
        Raise();
    }

    private void ForgetPasswords()
    {
        _adminPassword.Dispose();
        _adminPassword = Secret.Empty();
        _linuxPassword.Dispose();
        _linuxPassword = Secret.Empty();
        _confirmPassword.Dispose();
        _confirmPassword = Secret.Empty();
        _rootPassword.Dispose();
        _rootPassword = Secret.Empty();
    }

    /// <summary>Stop: ends the run. The Linux CLI is told to stop when its process tree is killed; run Retry to continue where it can.</summary>
    public void Stop()
    {
        if (!IsInstalling || StopRequested) return;
        StopRequested = true;
        _runCts?.Cancel();
        Raise();
    }

    // --- done ---

    public bool Notifications
    {
        get => _host.Notifications;
        set
        {
            _host.Notifications = value;
            Raise();
        }
    }

    public bool OpenAtLogon
    {
        get => _host.OpenAtLogon;
        set
        {
            _host.OpenAtLogon = value;
            Raise();
        }
    }

    public void OpenSite()
    {
        if (!string.IsNullOrWhiteSpace(SiteUrl)) _host.OpenUrl(SiteUrl);
    }

    public void Copy(string text) => _host.CopyText(text);

    public void OpenUrl(string url) => _host.OpenUrl(url);

    public void CopyMcp() => _host.CopyText(McpLine);

    public void CopyCliInstallLine() => _host.CopyText(LinuxCliInstallLine);

    public void Finish()
    {
        _host.SetResumeAfterLogon(false);
        CloseRequested?.Invoke(WizardClose.Finished);
    }

    /// <summary>The window was closed from its frame: stop whatever runs and forget the passwords.</summary>
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _lifetime.Cancel();
        _checkCts?.Cancel();
        _runCts?.Cancel();
        _linuxPassword.Dispose();
        _confirmPassword.Dispose();
        _adminPassword.Dispose();
        _rootPassword.Dispose();
    }
}
