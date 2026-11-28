using System.Text.RegularExpressions;

namespace BenchBar.Tray.Core;

/// <summary>
/// Compares the version <c>benchbar.exe --shim-version</c> prints ("benchbar.exe 0.8.2") with the tray's own. They ship in one zip: a PC was
/// found whose keepalive ran an older shim from another folder. An older shim warns; a newer patch of the same minor does not (a tray whose
/// files could not all be replaced is still compatible with it); another minor or major warns. A development build (0.0.0, "dev") has no
/// version to compare, so it never warns.
/// </summary>
public static partial class VersionMismatch
{
    [GeneratedRegex(@"(?<![\d.])(\d+)\.(\d+)\.(\d+)", RegexOptions.CultureInvariant)]
    private static partial Regex Number();

    /// <summary>The X.Y.Z in <paramref name="text"/>, or null when there is none or it is 0.0.0.</summary>
    public static string? Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var m = Number().Match(text);
        if (!m.Success) return null;
        var version = $"{int.Parse(m.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture)}.{int.Parse(m.Groups[2].Value, System.Globalization.CultureInfo.InvariantCulture)}.{int.Parse(m.Groups[3].Value, System.Globalization.CultureInfo.InvariantCulture)}";
        return version == "0.0.0" ? null : version;
    }

    /// <summary>The notice to show when the two differ; null when they match or either is unknown. <paramref name="shimPath"/> says which file ran.</summary>
    public static string? Notice(string? shimLine, string? trayVersion, string? shimPath = null)
    {
        var shim = Parse(shimLine);
        var tray = Parse(trayVersion);
        if (shim is null || tray is null || shim == tray) return null;
        if (SameMinor(shim, tray) && IsNewer(shim, tray)) return null;
        var where = string.IsNullOrWhiteSpace(shimPath) ? "benchbar.exe" : UiText.Format("CommonShimAt", shimPath);
        return UiText.Format("CommonVersionMismatch", where, shim, tray);
    }

    /// <summary>True when <paramref name="a"/> is a later X.Y.Z than <paramref name="b"/> (both as <see cref="Parse"/> returns them).</summary>
    public static bool IsNewer(string a, string b)
    {
        var x = Parts(a);
        var y = Parts(b);
        for (var i = 0; i < 3; i++)
        {
            if (x[i] != y[i]) return x[i] > y[i];
        }
        return false;
    }

    private static bool SameMinor(string a, string b) => Parts(a).Take(2).SequenceEqual(Parts(b).Take(2));

    private static int[] Parts(string version) =>
        [.. version.Split('.').Select(p => int.Parse(p, System.Globalization.CultureInfo.InvariantCulture))];
}
