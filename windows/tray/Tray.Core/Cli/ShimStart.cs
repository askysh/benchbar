using System.ComponentModel;

namespace BenchBar.Tray.Core;

/// <summary>What the tray says when <c>benchbar.exe</c> cannot be started, by the Windows error code, so each cause gets its own fix.</summary>
public static class ShimStart
{
    public const string ReinstallLine = "irm https://raw.githubusercontent.com/askysh/benchbar/main/install.ps1 | iex";

    public const string NotFoundMessage =
        "benchbar.exe was not found next to BenchBarTray.exe or on PATH. Run the installer again in PowerShell: " + ReinstallLine
        + " A security product may have removed it: check Windows Security, Protection history.";

    public const string BlockedMessage =
        "Windows blocked benchbar.exe. If SmartScreen or your antivirus asked, allow it, then try again. "
        + "Smart App Control blocks programs that are not signed: turn it off in Windows Security, App and browser control, Smart App Control settings. It cannot be turned on again without reinstalling Windows.";

    /// <summary>The code as a plain Win32 error: an HRESULT of the Win32 facility (0x8007xxxx) is cut to its low 16 bits.</summary>
    public static int Normalize(int code) => (code & unchecked((int)0xFFFF0000)) == unchecked((int)0x80070000) ? code & 0xFFFF : code;

    /// <summary>2 and 3: the file is not there (or its folder). 1260, 0x800704EC and 4551 (0x800711C7): a policy or Smart App Control blocked it. 5: access denied.</summary>
    public static ShimStartKind Classify(Win32Exception ex) => Normalize(ex.NativeErrorCode) switch
    {
        2 or 3 => ShimStartKind.Missing,
        1260 or 4551 => ShimStartKind.Blocked,
        5 => ShimStartKind.AccessDenied,
        _ => ShimStartKind.Other,
    };

    /// <summary>The line for a failed start. <paramref name="shimPath"/> is where benchbar.exe was expected, when known.</summary>
    public static string Describe(Win32Exception ex, string? shimPath = null)
    {
        switch (Classify(ex))
        {
            case ShimStartKind.Missing:
                return string.IsNullOrWhiteSpace(shimPath)
                    ? NotFoundMessage
                    : $"benchbar.exe was expected at {shimPath} and is not there. Run the installer again in PowerShell: {ReinstallLine} A security product may have removed it: check Windows Security, Protection history.";
            case ShimStartKind.Blocked:
                return BlockedMessage;
            case ShimStartKind.AccessDenied:
                return "Windows refused access to benchbar.exe (access denied). Check that your account can run files in its folder, and that no security product blocks it.";
            default:
                return $"benchbar.exe could not be started: {ex.Message}";
        }
    }
}

public enum ShimStartKind { Missing, Blocked, AccessDenied, Other }
