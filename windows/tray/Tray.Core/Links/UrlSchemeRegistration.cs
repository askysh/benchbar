namespace BenchBar.Tray.Core;

/// <summary>Where the <c>benchbar:</c> scheme is kept: <c>HKCU\Software\Classes\benchbar</c>, per user, no admin rights. A seam for tests.</summary>
public interface ISchemeStore
{
    /// <summary>
    /// The default value of <c>shell\open\command</c> as Windows resolves it (the merged view of <c>HKEY_CLASSES_ROOT</c>: this user's
    /// key first, then the machine's), or null when the scheme is not registered anywhere. A machine wide registration of another
    /// program counts.
    /// </summary>
    string? ReadCommand();

    /// <summary>The same value from this user's key only: what <see cref="Write"/> and <see cref="Remove"/> change.</summary>
    string? ReadUserCommand();

    /// <summary>Writes the scheme: its name, <c>URL Protocol</c>, the icon and the open command.</summary>
    void Write(string command, string iconPath);

    /// <summary>Removes the whole <c>benchbar</c> key.</summary>
    void Remove();
}

public enum SchemeResult
{
    /// <summary>It was not registered: now it is.</summary>
    Registered,

    /// <summary>It already points at this tray.</summary>
    Current,

    /// <summary>It pointed at a BenchBarTray.exe that is gone: now it points at this one.</summary>
    Repaired,

    /// <summary>It points at another BenchBarTray.exe that is still there (an installed copy and a build): left alone.</summary>
    OtherCopy,

    /// <summary>Another program owns <c>benchbar:</c>: left alone, and said once in the log.</summary>
    OtherProgram,

    /// <summary>This process is not <c>BenchBarTray.exe</c> (a <c>dotnet run</c> start, a test host): nothing is registered.</summary>
    NotTray,
}

/// <summary>
/// Registers <c>benchbar://</c> for this tray. The command is <c>"BenchBarTray.exe" "%1"</c>: the link comes as one quoted argument, and
/// the tray reads it as data (<see cref="LinkRouter.FromArguments"/>). The tray writes it at its first start and checks it at each start;
/// install.ps1 writes the same values and removes them with <c>-Uninstall</c>. A registration of another program is never replaced.
/// </summary>
public static class UrlSchemeRegistration
{
    public const string TrayExeName = "BenchBarTray.exe";

    public static string CommandFor(string exePath) => "\"" + exePath + "\" \"%1\"";

    /// <summary>The program in a registry command: the quoted part, else the text up to the first space.</summary>
    public static string? ExeOf(string? command)
    {
        var text = command?.Trim();
        if (string.IsNullOrEmpty(text)) return null;
        if (text[0] == '"')
        {
            var end = text.IndexOf('"', 1);
            return end > 1 ? text[1..end] : null;
        }
        var space = text.IndexOf(' ');
        return space > 0 ? text[..space] : text;
    }

    /// <summary>The file name after the last slash of either kind, so the answer does not depend on the machine's path rules.</summary>
    private static bool IsTray(string exe) =>
        string.Equals(exe[(exe.LastIndexOfAny(['\\', '/']) + 1)..], TrayExeName, StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Registers the scheme when nothing owns it, and repairs a registration whose program is gone. <paramref name="exists"/> says whether a
    /// file is there. Only a process that is <c>BenchBarTray.exe</c> registers: a <c>dotnet run</c> start would register dotnet.exe.
    /// The rule for an existing entry (install.ps1 follows the same one): the same program with another argument form is put right; a
    /// BenchBarTray.exe that is gone is replaced; a BenchBarTray.exe that is still there (another copy) and any other program are left alone.
    /// </summary>
    public static SchemeResult Ensure(ISchemeStore store, string exePath, Func<string, bool> exists)
    {
        if (!IsTray(exePath)) return SchemeResult.NotTray;
        var wanted = CommandFor(exePath);
        var current = store.ReadCommand();
        if (current is null)
        {
            store.Write(wanted, exePath + ",0");
            return SchemeResult.Registered;
        }
        var existing = ExeOf(current);
        if (existing is not null && string.Equals(existing, exePath, StringComparison.OrdinalIgnoreCase))
        {
            if (string.Equals(current.Trim(), wanted, StringComparison.Ordinal)) return SchemeResult.Current;
            store.Write(wanted, exePath + ",0"); // the same program with another argument form: put ours back
            return SchemeResult.Repaired;
        }
        if (existing is null || !IsTray(existing)) return SchemeResult.OtherProgram;
        if (exists(existing)) return SchemeResult.OtherCopy;
        store.Write(wanted, exePath + ",0");
        return SchemeResult.Repaired;
    }

    /// <summary>Removes the registration when it points at <paramref name="exePath"/> (an uninstall must not remove another copy's).</summary>
    public static bool Remove(ISchemeStore store, string exePath)
    {
        var existing = ExeOf(store.ReadUserCommand());
        if (existing is null || !string.Equals(existing, exePath, StringComparison.OrdinalIgnoreCase)) return false;
        store.Remove();
        return true;
    }

    /// <summary>The fixed log line for a result that needs one, else null.</summary>
    public static string? LogLine(SchemeResult result) => result switch
    {
        SchemeResult.Registered => "benchbar:// links registered for this tray",
        SchemeResult.Repaired => "benchbar:// links pointed at this tray again",
        SchemeResult.OtherProgram => "benchbar:// is registered to another program: left alone",
        _ => null,
    };
}
