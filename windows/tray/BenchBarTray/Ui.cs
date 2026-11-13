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

    // Text colors. The status colors above are for dots and glyphs (3:1 is enough there); text needs 4.5:1 on the card, which in the
    // light theme is a light gray: E5484D is 3.5:1 and D98E04 2.4:1 on it, so the light theme has darker ones. The dark theme's red is
    // lightened for the same reason (4.2:1 on the dark card). High contrast replaces all of them with the system's colors.
    public static readonly Color CriticalTextLight = Color.FromRgb(0xC4, 0x2B, 0x31);
    public static readonly Color CriticalTextDark = Color.FromRgb(0xFF, 0x70, 0x75);
    public static readonly Color CautionTextLight = Color.FromRgb(0x8A, 0x58, 0x00);
    public static readonly Color CautionTextDark = Color.FromRgb(0xD9, 0x8E, 0x04);

    private static readonly Brush CriticalLightBrush = Frozen(CriticalTextLight);
    private static readonly Brush CriticalDarkBrush = Frozen(CriticalTextDark);
    private static readonly Brush CautionLightBrush = Frozen(CautionTextLight);
    private static readonly Brush CautionDarkBrush = Frozen(CautionTextDark);

    /// <summary>Whether windows are in the light theme now (set when a window takes its theme). Text colors follow it.</summary>
    public static bool LightTheme { get; set; } = true;

    public static bool HighContrast => SystemParameters.HighContrast;

    /// <summary>The color of a problem line.</summary>
    public static Brush CriticalBrush => HighContrast ? SystemColors.HotTrackBrush : LightTheme ? CriticalLightBrush : CriticalDarkBrush;

    /// <summary>The color of a warning line (a pill, a note on an app).</summary>
    public static Brush CautionTextBrush => HighContrast ? SystemColors.HotTrackBrush : LightTheme ? CautionLightBrush : CautionDarkBrush;

    /// <summary>The WCAG contrast ratio of two opaque colors.</summary>
    public static double ContrastRatio(Color a, Color b)
    {
        static double Channel(byte v)
        {
            var c = v / 255.0;
            return c <= 0.03928 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4);
        }
        static double Luminance(Color c) => 0.2126 * Channel(c.R) + 0.7152 * Channel(c.G) + 0.0722 * Channel(c.B);
        var (hi, lo) = (Luminance(a), Luminance(b));
        if (hi < lo) (hi, lo) = (lo, hi);
        return (hi + 0.05) / (lo + 0.05);
    }

    public static void Name(DependencyObject element, string name, string? help = null)
    {
        AutomationProperties.SetName(element, name);
        if (help is not null) AutomationProperties.SetHelpText(element, help);
    }

    /// <summary>Screen readers read this text when it changes, without taking the focus.</summary>
    public static TextBlock Live(TextBlock block)
    {
        AutomationProperties.SetLiveSetting(block, AutomationLiveSetting.Polite);
        return block;
    }

    /// <summary>The small rounded "Beta" label next to the app name.</summary>
    public static Border Pill(string text = BetaText.Pill)
    {
        var pill = new Border
        {
            Child = new TextBlock { Text = text, FontSize = 11, FontWeight = FontWeights.SemiBold, Margin = new Thickness(7, 1, 7, 1) },
            BorderBrush = Accent,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(9),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(8, 0, 0, 0),
        };
        Name(pill, "Beta: BenchBar for Windows is in beta");
        return pill;
    }

    /// <summary>The automation name of the control that has the keyboard focus inside <paramref name="root"/>, or null.</summary>
    public static string? FocusedName(DependencyObject root)
    {
        if (Keyboard.FocusedElement is not DependencyObject focused) return null;
        for (DependencyObject? node = focused; node is not null; node = node is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(node) : LogicalTreeHelper.GetParent(node))
        {
            if (ReferenceEquals(node, root))
            {
                var name = AutomationProperties.GetName(focused);
                return string.IsNullOrEmpty(name) ? null : name;
            }
        }
        return null;
    }

    /// <summary>Rebuilding a list destroys the control that had the focus. Call this with the name taken before the rebuild to put the focus on its replacement.</summary>
    public static void RestoreFocus(FrameworkElement root, string? name)
    {
        if (name is null) return;
        if (FindByName(root, name) is not { } target) return;
        root.Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Loaded, () => { if (target.IsEnabled) target.Focus(); });
    }

    public static IInputElement? FindByName(DependencyObject node, string name)
    {
        foreach (var child in LogicalTreeHelper.GetChildren(node).OfType<DependencyObject>())
        {
            if (child is IInputElement { Focusable: true } input && AutomationProperties.GetName(child) == name) return input;
            if (FindByName(child, name) is { } found) return found;
        }
        return null;
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

    /// <summary>
    /// Puts <paramref name="content"/> at the left in a column that is as wide as the space allows, up to <paramref name="maxWidth"/>. A
    /// left aligned panel with a MaxWidth shrinks to its widest child, so rows changed width from one state to the next; this one does not.
    /// </summary>
    public static Grid Constrain(UIElement content, double maxWidth)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MaxWidth = maxWidth });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(content, 0);
        grid.Children.Add(content);
        return grid;
    }

    /// <summary>
    /// Takes the focus rectangle off the containers of a page (panels, borders, scroll viewers, plain content hosts): after a key press
    /// the theme drew one big rounded rectangle around the whole page. Buttons, boxes and the other controls keep theirs.
    /// </summary>
    public static void QuietFocus(DependencyObject root)
    {
        if (root is FrameworkElement element && IsContainer(element))
        {
            element.FocusVisualStyle = null;
            if (element is ScrollViewer or UserControl || element.GetType() == typeof(ContentControl)) element.Focusable = false;
        }
        foreach (var child in LogicalTreeHelper.GetChildren(root))
        {
            if (child is DependencyObject d) QuietFocus(d);
        }
    }

    private static bool IsContainer(FrameworkElement element) =>
        element is Panel or Border or ScrollViewer or UserControl or ContentPresenter || element.GetType() == typeof(ContentControl);

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
        };
        // never assign null: a local null Foreground beats the inherited one and the glyph is drawn in no color at all
        if (brush is not null) block.Foreground = brush;
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

    public static void ApplyTheme(Window window, ResolvedTheme theme)
    {
        LightTheme = theme.FlyoutLight;
        window.ThemeMode = theme.FlyoutLight ? ThemeMode.Light : ThemeMode.Dark;
    }
}
