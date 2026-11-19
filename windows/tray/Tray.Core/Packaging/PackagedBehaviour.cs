namespace BenchBar.Tray.Core;

/// <summary>What changes about the update UI when the Windows programs come from the Microsoft Store.</summary>
public static class UpdatePolicy
{
    public const string StoreLine = "Updates come from the Microsoft Store";

    /// <summary>Only the one line installer's copy checks for an update (through benchbar.exe self-update) and offers Update Now; the Store updates a package.</summary>
    public static bool ChecksForUpdates(IPackageInfo package) => !package.IsPackaged;
}

/// <summary>The path of <c>benchbar.exe</c> to show: packaged, the alias, because the file next to the tray sits in a versioned folder that changes on every update.</summary>
public static class ShimPathDisplay
{
    public static string? For(IPackageInfo package, string? shimPath, string localAppData) =>
        package.IsPackaged ? PackageInfo.AliasPath(localAppData) : shimPath;
}

/// <summary>
/// Both installs on one PC: the Store package and the one line installer's copy. The second tray of either kind exits and raises the first one's flyout, and the old
/// logon shortcut still starts the unpackaged tray, so the person is told once to remove the older one.
/// </summary>
public static class TwoInstalls
{
    public const string Key = "two-installs";

    public const string Text = "Two BenchBar installs are on this PC. Remove the older one with the installer's uninstall line.";

    public const string CopyLabel = "Copy Uninstall Line";

    /// <summary>The one line installer with its own uninstall switch (docs/windows.md, Uninstall): it asks once, then removes the two programs and keeps WSL, the distro and the benches.</summary>
    public const string UninstallLine = "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/askysh/benchbar/main/install.ps1))) -Uninstall";

    /// <summary>Where the one line installer puts the tray.</summary>
    public static string UnpackagedTrayPath(string localAppData) => Path.Combine(localAppData, "Programs", "BenchBar", "BenchBarTray.exe");

    /// <summary>True when this is the Store package and the other install's tray exe is there.</summary>
    public static bool Applies(IPackageInfo package, string localAppData, Func<string, bool>? exists = null) =>
        package.IsPackaged && (exists ?? File.Exists)(UnpackagedTrayPath(localAppData));

    /// <summary>
    /// Whether to show the notice, given whether both installs are there and whether the person dismissed it. <paramref name="newDismissed"/> is
    /// the value to keep: it goes back to false when the second install is gone, so a later one is told once more.
    /// </summary>
    public static bool ShouldShow(bool applies, bool dismissed, out bool newDismissed)
    {
        newDismissed = applies && dismissed;
        return applies && !dismissed;
    }
}
