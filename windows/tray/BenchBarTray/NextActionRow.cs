using System.Windows;
using System.Windows.Controls;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// One line of guidance and at most one button (macos GuidanceLine): "You stopped it.  [Start]". Build it from a
/// <see cref="BenchGuidance"/> with <see cref="For"/>, or from any text and an optional action.
/// </summary>
internal sealed class NextActionRow : UserControl
{
    public NextActionRow(string text, string? buttonLabel = null, Action? click = null, bool enabled = true)
    {
        Text = text;
        ButtonLabel = click is null ? null : buttonLabel;
        var row = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        if (ButtonLabel is not null)
        {
            var button = Ui.Button(ButtonLabel, click!, ButtonLabel, minWidth: 0);
            button.Margin = new Thickness(12, 0, 0, 0);
            button.IsEnabled = enabled;
            Button = button;
            DockPanel.SetDock(button, Dock.Right);
            row.Children.Add(button);
        }
        row.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center, Opacity = 0.85 });
        Content = row;
        Ui.Name(this, text);
    }

    public string Text { get; }

    /// <summary>The button's label, null when the row is only a line.</summary>
    public string? ButtonLabel { get; }

    public Button? Button { get; }

    /// <summary>
    /// The row for a bench's guidance, or null when there is nothing to say. <paramref name="perform"/> maps the action to what the page
    /// does; <paramref name="shown"/> is an action a button next to the row already offers (it is left off here).
    /// </summary>
    public static NextActionRow? For(BenchGuidance? guidance, Func<GuidanceAction, Action> perform, GuidanceAction? shown = null, bool enabled = true)
    {
        if (guidance is null) return null;
        if (shown is { } s) guidance = guidance.Without(s);
        return guidance.Action is { } action
            ? new NextActionRow(guidance.Reason, BenchGuidance.Title(action), perform(action), enabled)
            : new NextActionRow(guidance.Reason);
    }
}
