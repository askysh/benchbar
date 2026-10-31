using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using BenchBar.Tray.Core;

namespace BenchBar.Tray;

/// <summary>
/// Small builders for the main window, the wizard, Settings and About. Everything is code, as in the flyout. Colors come from the
/// Fluent theme's resources when it provides them (they follow light and dark), else from a neutral fallback; every control
/// that is not plain text gets an AutomationProperties.Name.
/// </summary>
internal static class Ui
{
    public static Brush ThemeBrush(FrameworkElement owner, string key, Brush fallback) =>
        owner.TryFindResource(key) as Brush ?? fallback;

    private static readonly Brush Success = Frozen(Color.FromRgb(0x2E, 0xA0, 0x43));
    private static readonly Brush Caution = Frozen(Color.FromRgb(0xD9, 0x8E, 0x04));
    private static readonly Brush Critical = Frozen(Color.FromRgb(0xE5, 0x48, 0x4D));
    private static readonly Brush Neutral = Frozen(Color.FromArgb(0x99, 0x80, 0x80, 0x80));
    private static readonly Brush Accent = Frozen(Color.FromRgb(0x3B, 0x82, 0xF6));

    private static Brush Frozen(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    public static Brush Card { get; } = Frozen(Color.FromArgb(0x1A, 0x80, 0x80, 0x80));

    public static Brush CriticalBrush => Critical;

    public static void Name(DependencyObject element, string name, string? help = null)
    {
        AutomationProperties.SetName(element, name);
        if (help is not null) AutomationProperties.SetHelpText(element, help);
    }

    public static TextBlock Text(string text, double size = 14, FontWeight? weight = null, double opacity = 1, Thickness? margin = null) => new()
    {
        Text = text,
        FontSize = size,
        FontWeight = weight ?? FontWeights.Normal,
        Opacity = opacity,
        TextWrapping = TextWrapping.Wrap,
        Margin = margin ?? new Thickness(0),
    };

    public static TextBlock Title(string text) => Text(text, 24, FontWeights.SemiBold);

    public static TextBlock Heading(string text) => Text(text, 16, FontWeights.SemiBold, margin: new Thickness(0, 0, 0, 4));

    public static TextBlock Caption(string text) => Text(text, 12, opacity: 0.7);

    /// <summary>A problem line in the critical color.</summary>
    public static TextBlock CriticalText(string text)
    {
        var block = Text(text, 14, margin: new Thickness(0, 8, 0, 0));
        block.Foreground = CriticalBrush;
        block.TextWrapping = TextWrapping.Wrap;
        return block;
    }

    /// <summary>Selectable monospace text (a command to copy, tool output).</summary>
    public static TextBox Mono(string text)
    {
        var box = new TextBox
        {
            Text = text,
            IsReadOnly = true,
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            Padding = new Thickness(0),
        };
        Name(box, text.Length > 40 ? text[..40] : text);
        return box;
    }

    public static Button Button(string label, Action click, string? automationName = null, bool primary = false, double minWidth = 88)
    {
        var button = new Button { Content = label, MinWidth = minWidth, Padding = new Thickness(14, 6, 14, 6), Margin = new Thickness(0, 0, 8, 0) };
        if (primary && Application.Current?.TryFindResource("AccentButtonStyle") is Style accent) button.Style = accent;
        button.Click += (_, _) => click();
        Name(button, automationName ?? label);
        return button;
    }

    /// <summary>A link looking button: the text only, with a keyboard focus ring.</summary>
    public static Button Link(string label, Action click, string? automationName = null)
    {
        var button = new Button
        {
            Content = new TextBlock { Text = label, TextDecorations = TextDecorations.Underline },
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(4, 2, 4, 2),
            Cursor = Cursors.Hand,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        button.Click += (_, _) => click();
        Name(button, automationName ?? label);
        return button;
    }

    public static TextBox Field(string name, string text, Action<string> changed, double width = 360)
    {
        var box = new TextBox { Text = text, Width = width, HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(8, 6, 8, 6) };
        box.TextChanged += (_, _) => changed(box.Text);
        Name(box, name);
        return box;
    }

    public static PasswordBox Password(string name, Action<System.Security.SecureString> changed, double width = 360)
    {
        var box = new PasswordBox { Width = width, HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(8, 6, 8, 6) };
        box.PasswordChanged += (_, _) => changed(box.SecurePassword);
        Name(box, name);
        return box;
    }

    public static StackPanel Labeled(string label, UIElement field, string? hint = null)
    {
        var panel = new StackPanel { Margin = new Thickness(0, 0, 0, 14) };
        panel.Children.Add(Text(label, 13, FontWeights.SemiBold, margin: new Thickness(0, 0, 0, 4)));
        panel.Children.Add(field);
        if (hint is not null) panel.Children.Add(Text(hint, 12, opacity: 0.7, margin: new Thickness(0, 4, 0, 0)));
        return panel;
    }

    public static Border CardOf(UIElement content, Thickness? margin = null) => new()
    {
        Background = Card,
        CornerRadius = new CornerRadius(8),
        Padding = new Thickness(16),
        Margin = margin ?? new Thickness(0, 0, 0, 8),
        Child = content,
    };

    public static Brush StateBrush(BenchState state) => state switch
    {
        BenchState.Running => Success,
        BenchState.Starting => Caution,
        BenchState.Crashed => Critical,
        BenchState.Paused => Caution,
        _ => Neutral,
    };

    public static Ellipse Dot(BenchState state, double size = 10) => new()
    {
        Width = size,
        Height = size,
        Fill = StateBrush(state),
        VerticalAlignment = VerticalAlignment.Center,
    };

    public static Brush StatusBrush(SetupStatus status) => status switch
    {
        SetupStatus.Ok => Success,
        SetupStatus.Warn => Caution,
        SetupStatus.Fail => Critical,
        _ => Neutral,
    };

    public static Brush StepBrush(InstallStepStatus status) => status switch
    {
        InstallStepStatus.Done or InstallStepStatus.Unchanged => Success,
        InstallStepStatus.Running => Accent,
        InstallStepStatus.Warning or InstallStepStatus.Skipped or InstallStepStatus.Stopped => Caution,
        InstallStepStatus.Failed => Critical,
        _ => Neutral,
    };

    /// <summary>A Segoe Fluent Icons glyph (the font ships with Windows 11; on Windows 10 Segoe MDL2 Assets has the same code points).</summary>
    public static TextBlock Glyph(string glyph, double size = 16, Brush? brush = null, string? name = null)
    {
        var block = new TextBlock
        {
            Text = glyph,
            FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
            FontSize = size,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = brush,
        };
        if (name is not null) Name(block, name);
        return block;
    }

    public const string CheckGlyph = "";
    public const string WarningGlyph = "";
    public const string ErrorGlyph = "";
    public const string PendingGlyph = "";

    private static System.Windows.Media.ImageSource? _shield;

    /// <summary>Windows' own UAC shield (SHGetStockIconInfo), so the row looks like the button Windows draws for an admin action.</summary>
    public static Image ShieldIcon()
    {
        var image = new Image { Width = 16, Height = 16, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0) };
        try
        {
            if (_shield is null)
            {
                var info = new NativeMethods.StockIconInfo { Size = (uint)System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.StockIconInfo>() };
                if (NativeMethods.SHGetStockIconInfo(NativeMethods.SiidShield, NativeMethods.ShgsiIcon | NativeMethods.ShgsiSmallIcon, ref info) == 0 && info.Icon != IntPtr.Zero)
                {
                    var source = System.Windows.Interop.Imaging.CreateBitmapSourceFromHIcon(info.Icon, Int32Rect.Empty, System.Windows.Media.Imaging.BitmapSizeOptions.FromEmptyOptions());
                    source.Freeze();
                    NativeMethods.DestroyIcon(info.Icon);
                    _shield = source;
                }
            }
            image.Source = _shield;
        }
        catch (Exception)
        {
            // no shield picture: the words beside it still say Windows will ask
        }
        return image;
    }

    /// <summary>The status icon of a check row.</summary>
    public static TextBlock StatusGlyph(SetupStatus status) => status switch
    {
        SetupStatus.Ok => Glyph(CheckGlyph, 16, Success, "Done"),
        SetupStatus.Warn => Glyph(WarningGlyph, 16, Caution, "Advice"),
        SetupStatus.Fail => Glyph(ErrorGlyph, 16, Critical, "Blocked"),
        _ => Glyph(PendingGlyph, 16, Neutral, "To do"),
    };

    /// <summary>The Mica backdrop of the .NET 10 Fluent theme, by reflection (the property is not public). A failure keeps the plain background.</summary>
    public static void ApplyMica(Window window, string kind = "MainWindow")
    {
        try
        {
            var property = typeof(Window).GetProperty("WindowBackdropType",
                System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public);
            property?.SetValue(window, Enum.Parse(property.PropertyType, kind));
        }
        catch (Exception)
        {
            // keep the theme default
        }
    }

    public static void ApplyTheme(Window window, ResolvedTheme theme) =>
        window.ThemeMode = theme.FlyoutLight ? ThemeMode.Light : ThemeMode.Dark;
}
