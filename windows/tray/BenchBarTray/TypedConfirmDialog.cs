using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// A destructive step that asks the person to type a name first (dropping a site). The confirm button stays off until the text is
/// exactly the expected name; it is never the default button. The CLI checks the name again (<c>--confirm-site</c>).
/// </summary>
internal sealed class TypedConfirmDialog : Window
{
    private readonly TypedConfirmRequest _request;

    public TypedConfirmDialog(TypedConfirmRequest request, ResolvedTheme theme, Window? owner)
    {
        _request = request;
        Title = request.Title;
        Width = 460;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = owner is null;
        Owner = owner;
        WindowStartupLocation = owner is null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner;
        Ui.ApplyTheme(this, theme);
        Ui.Name(this, request.Title);

        var panel = new StackPanel { Margin = new Thickness(24) };
        panel.Children.Add(Ui.Text(request.Title, 16, FontWeights.SemiBold));
        panel.Children.Add(Ui.Text(request.Message, 13, opacity: 0.85, margin: new Thickness(0, 6, 0, 12)));
        Box = Ui.Field($"Type {request.Expected} to confirm", "", _ => Sync(), 400);
        panel.Children.Add(Ui.Labeled($"Type {request.Expected} to confirm", Box));

        var bar = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0) };
        Confirm = Ui.Button(request.ConfirmLabel, () => DialogResult = true, request.ConfirmLabel);
        Confirm.IsEnabled = false;
        var cancel = Ui.Button("Cancel", () => DialogResult = false, "Cancel");
        cancel.IsDefault = true;
        cancel.IsCancel = true;
        cancel.Margin = new Thickness(0);
        bar.Children.Add(Confirm);
        bar.Children.Add(cancel);
        panel.Children.Add(bar);
        Content = panel;
        Loaded += (_, _) => Box.Focus();
    }

    public TextBox Box { get; }

    public Button Confirm { get; }

    public string Typed => Box.Text.Trim();

    private void Sync() => Confirm.IsEnabled = TypedConfirm.Matches(_request.Expected, Box.Text);

    /// <summary>Shows the dialog; the typed name when it matched and the person confirmed, else null.</summary>
    public static string? Ask(TypedConfirmRequest request, ResolvedTheme theme, Window? owner)
    {
        var dialog = new TypedConfirmDialog(request, theme, owner);
        return dialog.ShowDialog() == true && TypedConfirm.Matches(request.Expected, dialog.Box.Text) ? dialog.Typed : null;
    }
}
