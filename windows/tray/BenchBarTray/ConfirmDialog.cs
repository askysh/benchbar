using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>A themed yes or no question (the classic MessageBox ignores light and dark). The safe answer is the default button.</summary>
internal sealed class ConfirmDialog : Window
{
    public ConfirmDialog(string title, string message, string confirmLabel, ResolvedTheme theme, Window? owner)
    {
        Title = title;
        Width = 440;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = owner is null;
        Owner = owner;
        WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;
        Ui.ApplyTheme(this, theme);
        Ui.Name(this, title);

        var panel = new StackPanel { Margin = new Thickness(24) };
        panel.Children.Add(Ui.Text(title, 16, FontWeights.SemiBold));
        panel.Children.Add(Ui.Text(message, 14, opacity: 0.9, margin: new Thickness(0, 8, 0, 16)));
        var bar = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        Confirm = Ui.Button(confirmLabel, () => DialogResult = true, confirmLabel);
        var cancel = Ui.Button("Cancel", () => DialogResult = false, "Cancel");
        cancel.IsDefault = cancel.IsCancel = true;
        cancel.Margin = new Thickness(0);
        bar.Children.Add(Confirm);
        bar.Children.Add(cancel);
        panel.Children.Add(bar);
        Content = panel;
        Loaded += (_, _) => cancel.Focus();
    }

    public Button Confirm { get; }

    public static bool Ask(string title, string message, string confirmLabel, ResolvedTheme theme, Window? owner) =>
        new ConfirmDialog(title, message, confirmLabel, theme, owner).ShowDialog() == true;
}
