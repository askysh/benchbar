using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

internal sealed partial class WizardView
{
    // --- 1 Welcome ---

    private PageParts WelcomePage()
    {
        var panel = new StackPanel();
        Button Choice(string title, string detail, Action click)
        {
            var text = new StackPanel();
            text.Children.Add(Ui.Text(title, 16, FontWeights.SemiBold));
            text.Children.Add(Ui.Text(detail, 13, opacity: 0.75, margin: new Thickness(0, 2, 0, 0)));
            var button = new Button
            {
                Content = text,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Padding = new Thickness(18, 14, 18, 14),
                Margin = new Thickness(0, 0, 0, 10),
            };
            button.Click += (_, _) => click();
            Ui.Name(button, title, detail);
            panel.Children.Add(button);
            return button;
        }
        panel.Children.Add(Ui.Text(BetaText.WizardLine, 13, opacity: 0.8, margin: new Thickness(0, 0, 0, 14)));
        var first = Choice("Set Up a New Bench", "Check this PC, turn on WSL and Ubuntu if they are missing, then install Frappe.", () => _model.ChooseNewBench().Forget());
        Choice("I Already Have a Bench", "Use a bench inside WSL that BenchBar did not create.", () => _model.ChooseExistingBench().Forget());
        Choice("Just the Command Line Tool", "Only use benchbar from a terminal.", _model.ChooseCommandLineOnly);

        var page = new PageParts
        {
            Title = "Welcome to BenchBar",
            Subtitle = "Frappe development on this PC, inside Windows Subsystem for Linux.",
            Content = panel,
            Focus = first,
        };
        page.Left.Add(BackButton("Cancel"));
        return page;
    }

    // --- Just the command line tool ---

    private PageParts CliOnlyPage()
    {
        var panel = new StackPanel();
        panel.Children.Add(Ui.Text("benchbar.exe is already on this PC. It calls the Linux command line tool inside Ubuntu. If that is missing, run this inside Ubuntu:", 14, margin: new Thickness(0, 0, 0, 10)));
        CopyRow("Linux install line", WizardModel.LinuxCliInstallLine, _model.Copy, panel);
        panel.Children.Add(Ui.Text("To let an AI assistant use it, run this in a terminal:", 14, margin: new Thickness(0, 10, 0, 10)));
        CopyRow("MCP line", WizardModel.McpLine, _model.Copy, panel);

        var done = Primary("Done", _model.Finish);
        var page = new PageParts { Title = "Just the Command Line Tool", Subtitle = "No setup wizard needed.", Content = panel, Focus = done };
        page.Left.Add(BackButton());
        page.Right.Add(done);
        return page;
    }

    // --- 2 Check Your PC ---

    private PageParts CheckPage()
    {
        var error = Note(error: true);
        var reportCheck = Ui.Link(BetaText.ReportThisProblem, () => _actions.ReportBug(BetaText.ReportThisProblem, _model.CheckError), "Report this problem");
        reportCheck.Visibility = Visibility.Collapsed;
        reportCheck.Margin = new Thickness(0, 0, 0, 10);
        var status = Ui.Live(Ui.Text("", 13, opacity: 0.75, margin: new Thickness(0, 0, 0, 10)));
        var rows = new StackPanel();
        var restart = new StackPanel { Visibility = Visibility.Collapsed };
        var logBox = new TextBox
        {
            IsReadOnly = true,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            FontSize = 12,
            MaxHeight = 140,
            TextWrapping = TextWrapping.NoWrap,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            Visibility = Visibility.Collapsed,
            Margin = new Thickness(0, 8, 0, 0),
        };
        Ui.Name(logBox, "Output of the running step");

        var panel = new StackPanel();
        panel.Children.Add(error);
        panel.Children.Add(reportCheck);
        panel.Children.Add(status);
        panel.Children.Add(rows);
        panel.Children.Add(restart);
        panel.Children.Add(logBox);

        var back = BackButton();
        var again = Ui.Button("Check Again", () => _model.CheckAsync().Forget(), "Check this PC again");
        var cancel = Ui.Button("Cancel", () => _model.CancelRun(), "Cancel the running step");
        var all = Ui.Button("Set Up Everything", () => _model.FixAllAsync().Forget(), "Set up everything that is missing");
        var next = Primary("Continue", () => _model.ContinueFromCheckAsync().Forget());

        string lastKey = "";
        var parts = new PageParts
        {
            Title = "Check Your PC",
            Subtitle = "BenchBar needs WSL and Ubuntu 24.04. Each row says what is missing and how to fix it.",
            Content = panel,
        };
        parts.Left.Add(back);
        parts.Left.Add(again);
        parts.Right.Add(cancel);
        parts.Right.Add(all);
        parts.Right.Add(next);
        parts.Refresh = () =>
        {
            cancel.Visibility = _model.BusyStepId is not null ? Visibility.Visible : Visibility.Collapsed;
            Show(error, _model.CheckError);
            reportCheck.Visibility = _model.CheckError is { Length: > 0 } ? Visibility.Visible : Visibility.Collapsed;
            status.Text = _model.Checking ? "Checking this PC..." : _model.FixingAll ? "Setting things up..." : "";
            status.Visibility = status.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            var busy = _model.Checking || _model.BusyStepId is not null || _model.FixingAll;
            again.IsEnabled = !busy;
            back.IsEnabled = _model.BusyStepId is null;
            all.IsEnabled = !busy && _model.Report.Steps.Count > 0 && _model.Report.NextActionable is not null;
            next.IsEnabled = _model.CanContinueFromCheck;

            var key = string.Join('\n', _model.Rows.Select(r =>
                $"{r.Step.Id}|{r.Step.Status}|{r.Detail}|{r.Busy}|{r.Message}|{r.ButtonLabel}|{busy}"))
                + "|" + _model.RestartNeeded + "|" + _model.RestartRequested + "|" + _model.RestartHint;
            if (key != lastKey)
            {
                lastKey = key;
                // a rebuild destroys the control that had the focus: remember it by name and put it back
                var focused = Ui.FocusedName(panel);
                rows.Children.Clear();
                foreach (var row in _model.Rows) rows.Children.Add(CheckRowView(row, busy));
                restart.Children.Clear();
                if (_model.RestartNeeded && _model.Report.Step(SetupIds.Reboot) is null or { IsSatisfied: true })
                    restart.Children.Add(RestartCard());
                restart.Visibility = restart.Children.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
                Ui.RestoreFocus(panel, focused);
            }
            var log = string.Join(Environment.NewLine, _model.ActionLog);
            if (logBox.Text != log)
            {
                logBox.Text = log;
                logBox.ScrollToEnd();
            }
            logBox.Visibility = log.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        };
        return parts;
    }

    private UIElement CheckRowView(CheckRow row, bool anythingBusy)
    {
        var grid = new Grid { Margin = new Thickness(0, 0, 0, 2) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(32) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var glyph = Ui.StatusGlyph(row.Step.Status);
        glyph.VerticalAlignment = VerticalAlignment.Top;
        glyph.Margin = new Thickness(2, 3, 0, 0);
        Grid.SetColumn(glyph, 0);

        var text = new StackPanel();
        text.Children.Add(Ui.Text(row.Step.Title, 14, FontWeights.SemiBold));
        if (row.Detail.Length > 0) text.Children.Add(Ui.Text(row.Detail, 13, opacity: 0.8, margin: new Thickness(0, 2, 0, 0)));
        if (!row.Step.Blocking && row.Step.Status == SetupStatus.Warn && !row.Step.Waits)
            text.Children.Add(Ui.Text("Advice only. You can continue without it.", 12, opacity: 0.7, margin: new Thickness(0, 2, 0, 0)));
        if (row.Busy)
            text.Children.Add(Ui.Text(row.Message is { Length: > 0 } running ? running : "Working...", 13, opacity: 0.8, margin: new Thickness(0, 2, 0, 0)));
        else if (row.Message is { Length: > 0 } message)
        {
            var line = Ui.Text(message, 13, margin: new Thickness(0, 2, 0, 0));
            if (row.Step.Status != SetupStatus.Ok) line.Foreground = Ui.CriticalBrush;
            text.Children.Add(line);
        }
        if (!row.Busy && !row.Waiting) AddHelp(text, row);
        if (row.AdminNote is { } note)
        {
            var shield = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 0) };
            shield.Children.Add(Ui.ShieldIcon());
            shield.Children.Add(Ui.Text(note, 12, opacity: 0.8));
            text.Children.Add(shield);
        }
        Grid.SetColumn(text, 1);

        grid.Children.Add(glyph);
        grid.Children.Add(text);
        if (row.ButtonLabel is { } label)
        {
            var button = Ui.Button(label, () => OnRowClicked(row), $"{label}: {row.Step.Title}", minWidth: 96);
            button.Margin = new Thickness(12, 0, 0, 0);
            button.VerticalAlignment = VerticalAlignment.Top;
            button.IsEnabled = !anythingBusy && !row.Waiting;
            if (row.ShowsShield)
            {
                var content = new StackPanel { Orientation = Orientation.Horizontal };
                content.Children.Add(Ui.ShieldIcon());
                content.Children.Add(new TextBlock { Text = label });
                button.Content = content;
            }
            Grid.SetColumn(button, 2);
            grid.Children.Add(button);
        }
        return Ui.CardOf(grid, new Thickness(0, 0, 0, 6));
    }

    /// <summary>
    /// What a row with no button offers. A blocking step the person must fix by hand: the detail, Copy, a How to fix link and Report This
    /// Problem. Advice with a command: Copy. A step that failed when it ran: Report This Problem.
    /// </summary>
    private void AddHelp(StackPanel text, CheckRow row)
    {
        var step = row.Step;
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
        if (step.NeedsManualFix || step.HasAdviceCommand)
        {
            var copy = Ui.Button("Copy", () => _model.Copy(step.CopyText), "Copy the fix: " + step.Title, minWidth: 64);
            buttons.Children.Add(copy);
        }
        if (step.NeedsManualFix)
        {
            var how = Ui.Link("How to fix", () => _model.OpenUrl(BetaText.HowToFixUrl), "How to fix: " + step.Title);
            how.VerticalAlignment = VerticalAlignment.Center;
            buttons.Children.Add(how);
        }
        // the person's own Stop is not a problem to report
        var userStop = row.Message is WizardModel.StoppedMessage or WizardModel.CancelledMessage or WizardModel.StoppedWaitingMessage;
        if (step.NeedsManualFix || (row.Message is { Length: > 0 } && step.Status != SetupStatus.Ok && !userStop))
        {
            var report = Ui.Link(BetaText.ReportThisProblem, () => _actions.ReportBug(BetaText.ReportThisProblem, ReportContext.Step(step, row.Message)), "Report this problem: " + step.Title);
            report.VerticalAlignment = VerticalAlignment.Center;
            buttons.Children.Add(report);
        }
        if (buttons.Children.Count > 0) text.Children.Add(buttons);
    }

    private void OnRowClicked(CheckRow row)
    {
        if (row.Step.Action == SetupIds.ActionReboot)
        {
            if (_actions.ConfirmRestart()) _model.RestartNow();
            return;
        }
        _model.RunStepAsync(row.Step.Id).Forget();
    }

    private UIElement RestartCard()
    {
        var panel = new StackPanel();
        panel.Children.Add(Ui.Text("Windows needs to restart", 14, FontWeights.SemiBold));
        panel.Children.Add(Ui.Text(_model.RestartRequested ? "Restarting..." : WizardModel.RestartBlurb, 13, opacity: 0.8, margin: new Thickness(0, 2, 0, 8)));
        if (_model.StepMessages.TryGetValue(SetupIds.Reboot, out var refused))
        {
            var warn = Ui.Text(refused, 13, margin: new Thickness(0, 0, 0, 8));
            warn.Foreground = Ui.CriticalBrush;
            panel.Children.Add(warn);
        }
        if (_model.RestartHint is { Length: > 0 } hint) panel.Children.Add(Ui.Live(Ui.Text(hint, 13, margin: new Thickness(0, 0, 0, 8))));
        var button = Ui.Button("Restart Now", () => { if (_actions.ConfirmRestart()) _model.RestartNow(); }, "Restart Windows now", primary: true);
        button.IsEnabled = !_model.RestartRequested;
        panel.Children.Add(button);
        return Ui.CardOf(panel);
    }

    // --- 3 Linux user ---

    private PageParts LinuxUserPage()
    {
        var name = Ui.Field("Linux user name", _model.UserName, _model.SetUserName, 280);
        var pass = Ui.Password("Linux password", s => SetSecret(_model.SetPassword, s), 280);
        var confirm = Ui.Password("Confirm Linux password", s => SetSecret(_model.SetConfirm, s), 280);
        var nameProblem = Note(error: true);
        var passProblem = Note(error: true);
        var error = Note(error: true);
        var working = Ui.Text("", 13, opacity: 0.75, margin: new Thickness(0, 6, 0, 0));
        var userHint = Note(); // says what Create User is waiting for

        var panel = new StackPanel();
        panel.Children.Add(Ui.Labeled("User name", name, "Lowercase letters, digits, '-' and '_'."));
        panel.Children.Add(nameProblem);
        panel.Children.Add(Ui.Labeled("Password", pass, "This is what sudo asks for later. BenchBar keeps it in memory while this window is open and never saves it."));
        panel.Children.Add(Ui.Labeled("Confirm password", confirm));
        panel.Children.Add(passProblem);
        panel.Children.Add(error);
        panel.Children.Add(userHint);
        panel.Children.Add(working);

        var back = BackButton(escapes: false); // two password boxes: Esc must not throw them away
        var create = Primary("Create User", () => _model.CreateUserAsync().Forget());
        var reportUser = Ui.Link(BetaText.ReportThisProblem, () => _actions.ReportBug(BetaText.ReportThisProblem, _model.UserError), "Report this problem");
        reportUser.Visibility = Visibility.Collapsed;
        panel.Children.Add(reportUser);
        var page = new PageParts
        {
            Title = "Create Your Linux User",
            Subtitle = "Ubuntu has no user yet. BenchBar creates one and adds it to the sudo group.",
            Content = panel,
            Focus = name,
        };
        page.Left.Add(back);
        page.Right.Add(create);
        page.Refresh = () =>
        {
            // problems show once the person has typed something, not on an empty form
            Show(nameProblem, _model.UserNameProblem);
            Show(passProblem, _model.LinuxPassword.IsEmpty ? null : _model.PasswordProblem);
            Show(error, _model.UserError);
            reportUser.Visibility = _model.UserError is { Length: > 0 } ? Visibility.Visible : Visibility.Collapsed;
            working.Text = _model.CreatingUser ? "Creating the user..." : "";
            create.IsEnabled = _model.CanCreateUser;
            Show(userHint, _model.CanCreateUser || _model.CreatingUser ? null : "Create User is off. " + (_model.UserNameProblem ?? _model.PasswordProblem));
            back.IsEnabled = !_model.CreatingUser;
            name.IsEnabled = pass.IsEnabled = confirm.IsEnabled = !_model.CreatingUser;
        };
        return page;
    }

    // --- Existing bench ---

    private PageParts ExistingBenchPage()
    {
        var path = Ui.Field("Bench folder", _model.ExistingPath, _model.SetExistingPath, 480);
        var problem = Note(error: true);
        var panel = new StackPanel();
        panel.Children.Add(Ui.Labeled("Bench folder in Ubuntu", path, "BenchBar adds its service files and does not change your sites, apps or database."));
        panel.Children.Add(problem);

        var back = BackButton();
        var adopt = Primary("Use This Bench", () => _model.StartAdoptAsync().Forget());
        var page = new PageParts { Title = "Use an Existing Bench", Subtitle = "Point BenchBar at a bench that already exists in WSL.", Content = panel, Focus = path };
        page.Left.Add(back);
        page.Right.Add(adopt);
        page.Refresh = () =>
        {
            Show(problem, _model.ExistingPath.Length == 0 ? null : _model.ExistingProblem);
            adopt.IsEnabled = _model.ExistingProblem is null;
        };
        return page;
    }

    // --- 4 New bench ---

    private PageParts NewBenchPage()
    {
        var folder = Ui.Field("Bench folder", _model.Folder, _model.SetFolder, 480);
        var site = Ui.Field("Site name", _model.Site, _model.SetSite, 320);
        var bundle = new ComboBox { Width = 200, HorizontalAlignment = HorizontalAlignment.Left, ItemsSource = WizardModel.Bundles, SelectedItem = _model.Bundle };
        bundle.SelectionChanged += (_, _) => { if (bundle.SelectedItem is string b) _model.SetBundle(b); };
        Ui.Name(bundle, "App bundle");
        var admin = Ui.Password("Administrator password", s => SetSecret(_model.SetAdminPassword, s), 320);
        var problem = Note(error: true);
        var formHint = Note(); // says what Review is waiting for

        var panel = new StackPanel();
        panel.Children.Add(Ui.Labeled("Bench folder", folder, "Inside Ubuntu. The default is in your Linux home folder."));
        panel.Children.Add(Ui.Labeled("Site name", site, "Open it later at http://" + WizardModel.DefaultSite + ":8000. Windows resolves .localhost names by itself."));
        panel.Children.Add(Ui.Labeled("Apps", bundle, "minimal is Frappe only; common and extended add more apps."));
        panel.Children.Add(Ui.Labeled("Administrator password", admin, "The login of the new site. It is used for this install only and never saved."));
        panel.Children.Add(problem);
        panel.Children.Add(formHint);

        var back = BackButton(escapes: false); // the Administrator password is typed here
        var review = Primary("Review", () => _model.ReviewAsync().Forget());
        var page = new PageParts { Title = "New Bench", Subtitle = "Where the bench goes and how its first site is named.", Content = panel, Focus = folder };
        page.Left.Add(back);
        page.Right.Add(review);
        page.Refresh = () =>
        {
            // a typed form shows its problem in red; an empty password only says what Review is waiting for
            var typed = !_model.AdminPassword.IsEmpty;
            Show(problem, _model.FormProblem is { } p && typed ? p : null);
            Show(formHint, _model.FormProblem is { } waiting && !typed ? "Review is off. " + waiting : null);
            review.IsEnabled = _model.FormProblem is null;
            if (!folder.IsKeyboardFocusWithin && folder.Text != _model.Folder) folder.Text = _model.Folder;
        };
        return page;
    }

    // --- 5 Review ---

    private PageParts ReviewPage()
    {
        var working = Ui.Text("Reading the plan...", 14, opacity: 0.75);
        var error = Note(error: true);
        var reportPlan = Ui.Link(BetaText.ReportThisProblem, () => _actions.ReportBug(BetaText.ReportThisProblem, _model.PlanError), "Report this problem");
        reportPlan.Visibility = Visibility.Collapsed;
        reportPlan.Margin = new Thickness(0, 0, 0, 10);
        var plan = new StackPanel();
        var problems = new StackPanel(); // the fix of a failed plan and what the plan found in the way
        var panel = new StackPanel();
        panel.Children.Add(working);
        panel.Children.Add(error);
        panel.Children.Add(problems);
        panel.Children.Add(reportPlan);
        panel.Children.Add(plan);

        var back = BackButton();
        var install = Primary("Install", () => _model.StartInstallAsync().Forget());
        var page = new PageParts { Title = "Review", Subtitle = "Nothing has changed yet. This is what Install will do.", Content = panel, Focus = install };
        page.Left.Add(back);
        page.Right.Add(install);
        string lastKey = "";
        string lastProblems = "";
        page.Refresh = () =>
        {
            working.Visibility = _model.Planning ? Visibility.Visible : Visibility.Collapsed;
            // blockers say it better than the red line: with them the page shows their cards only
            var hasBlockers = _model.PlanBlockers.Count > 0;
            Show(error, hasBlockers ? null : _model.PlanError);
            var problemKey = _model.PlanFix + "|" + string.Join('|', _model.PlanBlockers.Select(b => b.Id + b.Message + b.Fix));
            if (problemKey != lastProblems)
            {
                lastProblems = problemKey;
                problems.Children.Clear();
                FillPlanProblems(problems);
            }
            reportPlan.Visibility = _model.PlanError is { Length: > 0 } ? Visibility.Visible : Visibility.Collapsed;
            install.IsEnabled = _model.CanInstall;
            var key = _model.Plan is null ? "-" : string.Join('|', _model.Plan.Steps.Select(s => s.Id + s.WillRun)) + _model.Plan.Site;
            if (key == lastKey) return;
            lastKey = key;
            plan.Children.Clear();
            if (_model.Plan is not { } p) return;
            var summary = new StackPanel();
            summary.Children.Add(Summary("Bench folder", p.Bench));
            summary.Children.Add(Summary("Site", p.Site));
            if (p.WebUrl is not null) summary.Children.Add(Summary("Address", p.WebUrl));
            summary.Children.Add(Summary("Apps", p.Bundle ?? _model.Bundle));
            plan.Children.Add(Ui.CardOf(summary));
            plan.Children.Add(Ui.Text("The install takes about 15 to 30 minutes, most of it downloads.", 13, opacity: 0.8, margin: new Thickness(0, 0, 0, 8)));

            var steps = new StackPanel();
            foreach (var step in p.Steps)
            {
                var line = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 0, 2) };
                line.Children.Add(Ui.Text(step.Name, 14, opacity: step.WillRun ? 1 : 0.5));
                if (step.Sudo && step.WillRun) line.Children.Add(Ui.Text("  asks for your Linux password", 12, opacity: 0.7));
                if (!step.WillRun) line.Children.Add(Ui.Text("  already done", 12, opacity: 0.7));
                steps.Children.Add(line);
            }
            plan.Children.Add(Ui.CardOf(steps));
            var sudo = p.PrivilegedSteps.Count;
            if (sudo > 0 && _model.LinuxPassword.IsEmpty)
                plan.Children.Add(Ui.Text($"BenchBar will ask for your Linux password for {sudo} {(sudo == 1 ? "step" : "steps")} that use sudo.", 13, opacity: 0.8));
        };
        return page;
    }

    private static UIElement Summary(string label, string value)
    {
        var line = new Grid { Margin = new Thickness(0, 2, 0, 2) };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(140) });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var l = Ui.Text(label, 13, opacity: 0.7);
        var v = Ui.Text(value, 14);
        Grid.SetColumn(v, 1);
        line.Children.Add(l);
        line.Children.Add(v);
        return line;
    }

    /// <summary>
    /// Under the plan's error: what the plan found in the way, each with its fix, then the fix of the failure itself. A fix that is a
    /// command gets Copy; a sentence is only read.
    /// </summary>
    private void FillPlanProblems(StackPanel into)
    {
        var n = 0;
        foreach (var blocker in _model.PlanBlockers)
        {
            n++;
            var card = new StackPanel();
            card.Children.Add(Ui.Text(blocker.Message, 14, FontWeights.SemiBold));
            AddFix(card, blocker.Fix, blocker.FixIsCommand, "the fix for problem " + n);
            into.Children.Add(Ui.CardOf(card, new Thickness(0, 0, 0, 8)));
        }
        if (_model.PlanBlockers.Count == 0 && _model.PlanFix is { Length: > 0 } fix)
        {
            var card = new StackPanel();
            AddFix(card, fix, _model.PlanFixIsCommand, "the fix");
            into.Children.Add(Ui.CardOf(card, new Thickness(0, 0, 0, 8)));
        }
    }

    private void AddFix(StackPanel into, string? fix, bool isCommand, string copyLabel)
    {
        if (fix is not { Length: > 0 }) return;
        if (isCommand) CopyRow(copyLabel, fix, _model.Copy, into);
        else into.Children.Add(Ui.Text(fix, 13, margin: new Thickness(0, 4, 0, 0)));
    }

    // --- 6 Install ---

    private PageParts InstallPage()
    {
        var rows = new StackPanel();
        var progress = Ui.Live(Ui.Text("", 13, opacity: 0.75, margin: new Thickness(0, 8, 0, 0)));
        var failure = new StackPanel { Visibility = Visibility.Collapsed };
        var root = Ui.Password("MariaDB root password", s => SetSecret(_model.SetRootPassword, s), 320);
        var rootPanel = Ui.Labeled("MariaDB root password", root, "MariaDB in Ubuntu already has a root password that BenchBar does not know. Enter it and retry.");
        rootPanel.Visibility = Visibility.Collapsed;

        var panel = new StackPanel();
        panel.Children.Add(rows);
        panel.Children.Add(progress);
        panel.Children.Add(failure);
        panel.Children.Add(rootPanel);

        var back = BackButton(escapes: false); // the MariaDB root password box can be on this page
        var log = Ui.Button("Open Log", () => { if (_model.LogPath is { } path) _actions.OpenLog(path); }, "Open the install log");
        var stop = Ui.Button("Stop", _model.Stop, "Stop the install");
        var retry = Primary("Retry", () => _model.RetryAsync().Forget());
        string lastKey = "";
        var parts = new PageParts
        {
            Title = "Installing",
            Subtitle = "This takes a while the first time. You can leave this window open and do something else.",
            Content = panel,
            Focus = stop,
        };
        parts.Left.Add(back);
        parts.Left.Add(log);
        parts.Right.Add(stop);
        parts.Right.Add(retry);
        parts.Refresh = () =>
        {
            var running = _model.Phase == InstallPhase.Running;
            var (heading, line) = InstallHeading(_model.Phase);
            parts.SetHeading(heading, line);
            back.IsEnabled = !running;
            stop.IsEnabled = running && !_model.StopRequested;
            stop.Visibility = running ? Visibility.Visible : Visibility.Collapsed;
            retry.Visibility = _model.Phase is InstallPhase.Failed or InstallPhase.Stopped or InstallPhase.NeedsRootPassword or InstallPhase.NeedsLinuxPassword ? Visibility.Visible : Visibility.Collapsed;
            retry.Content = _model.Phase == InstallPhase.Stopped ? "Run Again" : "Retry";
            retry.IsEnabled = _model.Phase != InstallPhase.NeedsRootPassword || !_model.RootPassword.IsEmpty;
            log.IsEnabled = _model.LogPath is not null;
            progress.Text = _model.StopRequested && running ? "Stopping..." : _model.ProgressLabel;
            progress.Visibility = progress.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            rootPanel.Visibility = _model.Phase == InstallPhase.NeedsRootPassword ? Visibility.Visible : Visibility.Collapsed;

            var key = string.Join('\n', _model.InstallRows.Select(r => $"{r.Id}|{r.Status}|{r.Secs}|{r.Message}|{r.Parent}"))
                + "|" + _model.Phase + "|" + _model.Failure?.Message;
            if (key == lastKey) return;
            lastKey = key;
            var focusedRow = Ui.FocusedName(panel);
            rows.Children.Clear();
            var runningTop = _model.InstallRows.FirstOrDefault(r => r.Parent is null && r.Status == InstallStepStatus.Running)?.Id;
            foreach (var row in _model.InstallRows)
            {
                // sub steps show only under the step that is running now
                if (row.Parent is not null && row.Parent != runningTop) continue;
                rows.Children.Add(InstallRowView(row));
            }
            failure.Children.Clear();
            failure.Visibility = Visibility.Collapsed;
            if (_model.Failure is { } f && _model.Phase != InstallPhase.Running)
            {
                failure.Children.Add(FailureCard(f));
                failure.Visibility = Visibility.Visible;
            }
            else if (_model.Phase == InstallPhase.Stopped)
            {
                failure.Children.Add(Ui.CardOf(Ui.Text("The install was stopped. Run Again continues where it can; finished steps are not repeated.", 14)));
                failure.Visibility = Visibility.Visible;
            }
            Ui.RestoreFocus(panel, focusedRow);
        };
        return parts;
    }

    private static (string Title, string Subtitle) InstallHeading(InstallPhase phase) => phase switch
    {
        InstallPhase.Failed => ("Install Failed", "A step did not finish. Retry it, tell us with Report This Problem, or open the log."),
        InstallPhase.Stopped => ("Install Stopped", "Run Again continues where it can. Finished steps are not repeated."),
        InstallPhase.NeedsLinuxPassword => ("Wrong Linux Password", "Linux did not accept the password. Type it again and press Retry."),
        InstallPhase.NeedsRootPassword => ("MariaDB Needs Its Password", "MariaDB in Ubuntu already has a root password. Enter it and press Retry."),
        _ => ("Installing", "This takes a while the first time. You can leave this window open and do something else."),
    };

    private UIElement InstallRowView(InstallRow row)
    {
        var grid = new Grid { Margin = new Thickness(row.Parent is null ? 0 : 28, 3, 0, 3) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var dot = Ui.Glyph(row.Status switch
        {
            InstallStepStatus.Done or InstallStepStatus.Unchanged => Ui.CheckGlyph,
            InstallStepStatus.Failed => Ui.ErrorGlyph,
            InstallStepStatus.Warning or InstallStepStatus.Skipped or InstallStepStatus.Stopped => Ui.WarningGlyph,
            _ => Ui.PendingGlyph,
        }, 14, Ui.StepBrush(row.Status), StatusWord(row.Status));
        var name = Ui.Text(row.Name, 14, row.Parent is null ? FontWeights.Normal : FontWeights.Normal, row.Status == InstallStepStatus.Unknown ? 0.6 : 1);
        Grid.SetColumn(name, 1);
        grid.Children.Add(dot);
        grid.Children.Add(name);
        if (row.Status == InstallStepStatus.Running)
        {
            var spin = Ui.Text("working", 12, opacity: 0.7);
            Grid.SetColumn(spin, 2);
            grid.Children.Add(spin);
        }
        else if (row.Secs is { } secs && row.Status != InstallStepStatus.Unknown)
        {
            var time = Ui.Text(secs + " s", 12, opacity: 0.7);
            Grid.SetColumn(time, 2);
            grid.Children.Add(time);
        }
        if (row.Message is { Length: > 0 } message && row.Status is InstallStepStatus.Failed or InstallStepStatus.Skipped or InstallStepStatus.Warning)
        {
            var stack = new StackPanel();
            stack.Children.Add(grid);
            stack.Children.Add(Ui.Text(message, 12, opacity: 0.85, margin: new Thickness(row.Parent is null ? 28 : 56, 0, 0, 2)));
            return stack;
        }
        return grid;
    }

    private static string StatusWord(InstallStepStatus status) => status switch
    {
        InstallStepStatus.Done => "Done",
        InstallStepStatus.Unchanged => "Already done",
        InstallStepStatus.Running => "Running",
        InstallStepStatus.Failed => "Failed",
        InstallStepStatus.Skipped => "Skipped",
        InstallStepStatus.Warning => "Warning",
        InstallStepStatus.Stopped => "Stopped",
        _ => "Waiting",
    };

    private UIElement FailureCard(WizardFailure f)
    {
        var panel = new StackPanel();
        panel.Children.Add(Ui.Text(f.Step is null ? "The install did not finish" : $"{f.Step} failed", 14, FontWeights.SemiBold));
        panel.Children.Add(Ui.Text(f.Message, 13, margin: new Thickness(0, 4, 0, 0)));
        panel.Children.Add(ReportProblemLink(f.Step is null ? f.Message : $"{f.Step} failed: {f.Message}"));
        var todo = Ui.Text("What to do:", 13, FontWeights.SemiBold, margin: new Thickness(0, 8, 0, 2));
        if (_model.Phase == InstallPhase.NeedsLinuxPassword)
        {
            panel.Children.Add(todo);
            panel.Children.Add(Ui.Text("The Linux password is the one you chose for your Linux user. Type it again.", 13));
        }
        else if (f.Fix is { Length: > 0 } fix)
        {
            panel.Children.Add(todo);
            // a command can be copied; a sentence ("Pass MARIADB_ROOT_PASSWORD.") is only read
            if (f.FixIsCommand) CopyRow("Fix", fix, _model.Copy, panel);
            else panel.Children.Add(Ui.Text(fix, 13));
        }
        else if (_model.Phase == InstallPhase.Failed)
        {
            panel.Children.Add(todo);
            panel.Children.Add(Ui.Text("Press Retry to run the install again; finished steps are not repeated. If it fails again, press Report This Problem or Open Log.", 13));
        }
        return Ui.CardOf(panel);
    }

    // --- 7 Done ---

    private PageParts DonePage()
    {
        var panel = new StackPanel();
        var address = new StackPanel();
        address.Children.Add(Ui.Text("Your bench is running at", 13, opacity: 0.75));
        address.Children.Add(Ui.Text(_model.SiteUrl ?? _model.Site, 18, FontWeights.SemiBold, margin: new Thickness(0, 2, 0, 0)));
        panel.Children.Add(Ui.CardOf(address));

        var notify = new CheckBox { Content = "Show a notification when a bench stops or crashes", IsChecked = _model.Notifications, Margin = new Thickness(0, 8, 0, 6) };
        notify.Click += (_, _) => _model.Notifications = notify.IsChecked == true;
        Ui.Name(notify, "Show notifications");
        var logon = new CheckBox { Content = "Open BenchBar when I sign in to Windows", IsChecked = _model.OpenAtLogon, Margin = new Thickness(0, 0, 0, 12) };
        logon.Click += (_, _) => _model.OpenAtLogon = logon.IsChecked == true;
        Ui.Name(logon, "Open BenchBar at logon");
        panel.Children.Add(notify);
        panel.Children.Add(logon);

        if (_model.SkippedCommands.Count > 0)
        {
            panel.Children.Add(Ui.Text("Some steps were skipped. Run these when you are ready:", 13, margin: new Thickness(0, 0, 0, 6)));
            foreach (var command in _model.SkippedCommands) CopyRow("Skipped step", command, _model.Copy, panel);
        }
        panel.Children.Add(Ui.Text("To let an AI assistant use this bench, run this in a terminal:", 13, margin: new Thickness(0, 6, 0, 6)));
        CopyRow("MCP line", WizardModel.McpLine, _model.Copy, panel);
        panel.Children.Add(Ui.Text("Cannot see the BenchBar icon? Windows may hide it under the ^ arrow in the taskbar. To keep it in view, open Settings, Personalization, Taskbar, Other system tray icons, and turn BenchBar on.", 13, opacity: 0.85, margin: new Thickness(0, 10, 0, 0)));

        var open = Primary("Open Site", _model.OpenSite);
        var done = Ui.Button("Done", _model.Finish, "Close the wizard");
        done.IsCancel = true;
        var page = new PageParts { Title = "Your Bench Is Ready", Subtitle = "BenchBar keeps it running in the notification area.", Content = panel, Focus = open };
        page.Right.Add(done);
        page.Right.Add(open);
        open.IsEnabled = !string.IsNullOrWhiteSpace(_model.SiteUrl);
        return page;
    }
}
