using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// The small dialog before an install for a distro whose user was not created here: "BenchBar needs your Linux password for N
/// steps that use sudo". The answer is a <see cref="Secret"/> held by the wizard for the one run; nothing is stored.
/// </summary>
internal sealed class LinuxPasswordDialog : Window
{
    private readonly PasswordBox _box;
    private readonly Button _ok;

    public LinuxPasswordDialog(LinuxPasswordRequest request, ResolvedTheme theme, Window? owner)
    {
        Title = UiText.Get("LinuxPasswordTitle");
        Width = 440;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = owner is null;
        Owner = owner;
        WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;
        Ui.ApplyTheme(this, theme);
        Ui.Name(this, UiText.Get("LinuxPasswordTitle"));

        var count = Math.Max(request.SudoSteps, 1);
        var panel = new StackPanel { Margin = new Thickness(24) };
        panel.Children.Add(Ui.Text(UiText.Format("LinuxPasswordNeeds", count, count == 1 ? UiText.Get("LinuxPasswordStep") : UiText.Get("LinuxPasswordSteps")), 15, FontWeights.SemiBold));
        panel.Children.Add(Ui.Text(UiText.Get("LinuxPasswordHint"), 13, opacity: 0.8, margin: new Thickness(0, 6, 0, 12)));
        if (request.UserExisted)
            panel.Children.Add(Ui.Text(UiText.Get("LinuxPasswordExisting"), 13, margin: new Thickness(0, 0, 0, 10)));
        if (request.WasWrong)
        {
            var wrong = Ui.Text(UiText.Get("LinuxPasswordWrong"), 13, margin: new Thickness(0, 0, 0, 10));
            wrong.Foreground = Ui.CriticalBrush;
            panel.Children.Add(wrong);
        }
        _box = Ui.Password(UiText.Get("LinuxPasswordTitle"), _ => _ok!.IsEnabled = _box!.SecurePassword.Length > 0, 380);
        panel.Children.Add(_box);

        var bar = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0) };
        _ok = Ui.Button(UiText.Get("LinuxPasswordContinue"), () => DialogResult = true, UiText.Get("LinuxPasswordContinueName"), primary: true);
        _ok.IsDefault = true;
        _ok.IsEnabled = false;
        var cancel = Ui.Button(UiText.Get("Cancel"), () => DialogResult = false, UiText.Get("Cancel"));
        cancel.IsCancel = true;
        cancel.Margin = new Thickness(0);
        bar.Children.Add(_ok);
        bar.Children.Add(cancel);
        panel.Children.Add(bar);
        Content = panel;
        Loaded += (_, _) => _box.Focus();
    }

    /// <summary>The password as a <see cref="Secret"/> (a copy; the box is cleared when the dialog closes).</summary>
    public Secret? Answer => DialogResult == true && _box.SecurePassword.Length > 0 ? Secret.From(_box.SecurePassword) : null;

    /// <summary>Shows the dialog and returns the password, or null when cancelled.</summary>
    public static Secret? Ask(LinuxPasswordRequest request, ResolvedTheme theme, Window? owner)
    {
        var dialog = new LinuxPasswordDialog(request, theme, owner);
        dialog.ShowDialog();
        var answer = dialog.Answer;
        dialog._box.Clear();
        return answer;
    }
}
