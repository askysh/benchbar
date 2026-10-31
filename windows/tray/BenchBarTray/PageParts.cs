using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>One line of a "more" menu: a label and what it does, a check mark, or a separator.</summary>
internal sealed record PageMenuEntry(string Label, bool Enabled, bool Danger, Action? Click, bool Checked = false, bool Separator = false)
{
    public static PageMenuEntry Divider { get; } = new("", true, false, null, Separator: true);
}

/// <summary>Small pieces the Sites and Apps tabs share: a panel that sits in the page (not a dialog), a banner, a "more" menu button.</summary>
internal static class PagePanels
{
    private static readonly Brush Accent = Frozen(Color.FromRgb(0x3B, 0x82, 0xF6));

    private static Brush Frozen(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    public static Brush SelectedBrush => Accent;

    /// <summary>Runs <paramref name="action"/> on the thread that owns <paramref name="owner"/>.</summary>
    public static void OnUi(DispatcherObject owner, Action action)
    {
        if (owner.Dispatcher.CheckAccess()) action();
        else owner.Dispatcher.BeginInvoke(action);
    }

    public static Border Banner(string text, bool error)
    {
        var block = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap };
        if (error) block.Foreground = Ui.CriticalBrush;
        var border = Ui.CardOf(block, new Thickness(0, 0, 0, 10));
        Ui.Name(border, (error ? "Problem: " : "Result: ") + text);
        return border;
    }

    /// <summary>A card with a title, an optional line, the body and a row of buttons.</summary>
    public static Border Panel(string title, string? explanation, IEnumerable<UIElement> body, IEnumerable<Button> buttons)
    {
        var stack = new StackPanel();
        stack.Children.Add(Ui.Text(title, 16, FontWeights.SemiBold));
        if (explanation is not null)
        {
            var line = Ui.Text(explanation, 13, opacity: 0.8, margin: new Thickness(0, 4, 0, 0));
            line.TextWrapping = TextWrapping.Wrap;
            stack.Children.Add(line);
        }
        var content = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
        foreach (var element in body) content.Children.Add(element);
        stack.Children.Add(content);
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 12, 0, 0) };
        foreach (var button in buttons) bar.Children.Add(button);
        if (bar.Children.Count > 0) stack.Children.Add(bar);
        var card = Ui.CardOf(stack, new Thickness(0, 0, 0, 10));
        card.BorderBrush = Accent;
        card.BorderThickness = new Thickness(1);
        Ui.Name(card, title);
        return card;
    }

    public static TextBlock Line(string text, bool error = false, double opacity = 0.85)
    {
        var block = Ui.Text(text, 13, opacity: error ? 1 : opacity, margin: new Thickness(0, 2, 0, 2));
        block.TextWrapping = TextWrapping.Wrap;
        if (error) block.Foreground = Ui.CriticalBrush;
        return block;
    }

    /// <summary>The empty state: one line and one action.</summary>
    public static UIElement EmptyState(string line, string actionLabel, Action click, bool enabled)
    {
        var row = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        row.Children.Add(Ui.Text(line, 14, opacity: 0.8, margin: new Thickness(0, 0, 0, 8)));
        var button = Ui.Button(actionLabel, click, actionLabel, primary: true);
        button.IsEnabled = enabled;
        button.HorizontalAlignment = HorizontalAlignment.Left;
        row.Children.Add(button);
        return row;
    }

    /// <summary>A "..." button that opens a menu of the given entries under it.</summary>
    public static Button MoreButton(string automationName, IEnumerable<PageMenuEntry> entries, bool enabled)
    {
        var menu = new ContextMenu();
        foreach (var entry in entries)
        {
            if (entry.Separator)
            {
                menu.Items.Add(new Separator());
                continue;
            }
            var click = entry.Click;
            var item = new MenuItem { Header = entry.Label, IsEnabled = entry.Enabled, IsChecked = entry.Checked };
            if (entry.Danger) item.Foreground = Ui.CriticalBrush;
            item.Click += (_, _) => click?.Invoke();
            menu.Items.Add(item);
        }
        var button = new Button { Content = Ui.Glyph("", 14), MinWidth = 36, Padding = new Thickness(8, 6, 8, 6), IsEnabled = enabled, ContextMenu = menu };
        button.Click += (_, _) =>
        {
            menu.PlacementTarget = button;
            menu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom;
            menu.IsOpen = true;
        };
        Ui.Name(button, automationName);
        button.ToolTip = "More actions";
        return button;
    }
}
