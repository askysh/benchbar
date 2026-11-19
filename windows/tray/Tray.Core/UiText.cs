using System.Globalization;
using System.Resources;

namespace BenchBar.Tray.Core;

/// <summary>
/// The resource layer for text the person reads: <see cref="Get"/> looks a string up in <c>Resources/Strings.resx</c> (and a
/// <c>Strings.&lt;culture&gt;.resx</c> next to it for the UI culture, when one exists). Text that is not moved there yet stays
/// where it is; new user text goes here. Dates and sizes for display follow the culture, never the machine readable invariant form.
/// </summary>
public static class UiText
{
    private static readonly ResourceManager Manager = new("BenchBar.Tray.Core.Resources.Strings", typeof(UiText).Assembly);

    /// <summary>The string named <paramref name="name"/> for the current UI culture; the name itself when it is missing, so a gap shows.</summary>
    public static string Get(string name, CultureInfo? culture = null) => Manager.GetString(name, culture) ?? name;

    /// <summary>The string named <paramref name="name"/> with its <c>{0}</c> placeholders filled, formatted for the current culture.</summary>
    public static string Format(string name, params object[] args) => string.Format(CultureInfo.CurrentCulture, Get(name), args);

    /// <summary>The culture's short date and short time, "3/5/2026 2:30 PM" in en-US, "05.03.2026 14:30" in de-DE (the invariant culture gives "03/05/2026 14:30").</summary>
    public static string Date(DateTimeOffset time, TimeZoneInfo? zone = null, CultureInfo? culture = null)
    {
        culture ??= CultureInfo.CurrentCulture;
        var local = TimeZoneInfo.ConvertTime(time, zone ?? TimeZoneInfo.Local);
        return local.ToString(culture.DateTimeFormat.ShortDatePattern, culture) + " " + local.ToString(culture.DateTimeFormat.ShortTimePattern, culture);
    }

    /// <summary>A number with one decimal, with the culture's decimal separator.</summary>
    public static string OneDecimal(double value, CultureInfo? culture = null) => value.ToString("0.0", culture ?? CultureInfo.CurrentCulture);
}
