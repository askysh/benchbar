namespace BenchBar.Tray.Core;

/// <summary>Whether this process has package identity (it runs from the Microsoft Store package) and what follows from it.</summary>
public interface IPackageInfo
{
    bool IsPackaged { get; }

    /// <summary>The package family name, for example <c>Askysh.BenchBar_0f196q1bwh8q6</c>; null when not packaged. Read at run time, never written in code.</summary>
    string? FamilyName { get; }
}

/// <summary>
/// Package identity from <c>kernel32!GetCurrentPackageFamilyName</c>. An unpackaged process (the one line installer's copy) gets
/// <c>APPMODEL_ERROR_NO_PACKAGE</c> (15700) and everything stays as it was.
/// </summary>
public sealed class PackageInfo : IPackageInfo
{
    private const int NoPackage = 15700;
    private const int BufferTooSmall = 122;
    private const int FamilyNameMax = 64; // PACKAGE_FAMILY_NAME_MAX_LENGTH, without the terminator

    private static readonly Lazy<PackageInfo> Detected = new(Detect);

    private PackageInfo(string? familyName) => FamilyName = string.IsNullOrWhiteSpace(familyName) ? null : familyName;

    /// <summary>This process, asked once.</summary>
    public static IPackageInfo Current => Detected.Value;

    public static IPackageInfo Unpackaged { get; } = new PackageInfo(null);

    /// <summary>A packaged process with this family name (tests, and anything that needs the other state).</summary>
    public static IPackageInfo Packaged(string familyName) => new PackageInfo(familyName);

    public bool IsPackaged => FamilyName is not null;

    public string? FamilyName { get; }

    /// <summary>The alias <c>benchbar.exe</c> that a package registers: <c>%LOCALAPPDATA%\Microsoft\WindowsApps\benchbar.exe</c>.</summary>
    public static string AliasPath(string localAppData) => Path.Combine(localAppData, "Microsoft", "WindowsApps", ShimLocator.FileName);

    public static string LocalAppData() => Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    private static unsafe PackageInfo Detect()
    {
        try
        {
            var buffer = new char[FamilyNameMax + 1];
            uint length = (uint)buffer.Length;
            int result;
            fixed (char* name = buffer) result = Native.GetCurrentPackageFamilyName(ref length, name);
            if (result == 0 && length > 1) return new PackageInfo(new string(buffer, 0, (int)length - 1));
            return new PackageInfo(null); // 15700 (no package) or anything else: behave as an unpackaged install
        }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException)
        {
            return new PackageInfo(null); // no such export: not packaged
        }
    }
}

/// <summary>
/// The one folder the tray keeps its files in (<c>config.json</c>, <c>tray.log</c>, the <c>running</c> marker, <c>runners</c>, <c>reports</c>,
/// <c>recent-scan-folders.txt</c>). Packaged, writes under <c>%LOCALAPPDATA%\BenchBar</c> are redirected to a private store whose
/// content depends on what existed before, so the tray and the shim both use the physical path inside the package's own data folder, which
/// is never redirected, and every path shown to the person is then true. The shim applies the same rule: keep the expression as it is.
/// </summary>
public static class DataFolder
{
    public const string Name = "BenchBar";

    /// <summary>Not packaged: <c>%LOCALAPPDATA%\BenchBar</c>. Packaged: <c>%LOCALAPPDATA%\Packages\&lt;PackageFamilyName&gt;\LocalCache\Local\BenchBar</c>.</summary>
    public static string For(IPackageInfo package, string localAppData) =>
        package.IsPackaged && package.FamilyName is { } family
            ? Path.Combine(localAppData, "Packages", family, "LocalCache", "Local", Name)
            : Path.Combine(localAppData, Name);

    /// <summary>The folder of this process.</summary>
    public static string Current { get; } = For(PackageInfo.Current, PackageInfo.LocalAppData());

    /// <summary>A file or folder inside <see cref="Current"/>.</summary>
    public static string In(string name) => Path.Combine(Current, name);
}
