using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

namespace BenchBar.Tray;

/// <summary>
/// Windows keeps its own on/off switch for each entry of the Startup folder (Settings, Apps, Startup, and Task Manager's Startup tab):
/// <c>HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder</c>, one binary value per file name. A value
/// that is absent, or whose first byte is even (02), means enabled; an odd first byte (03) means disabled, and the shortcut is then ignored
/// at sign in. This is the registry part, apart so a test can stand in for it.
/// </summary>
internal interface IStartupApproval
{
    /// <summary>The value for a shortcut's file name; null when there is none.</summary>
    byte[]? Get(string fileName);

    /// <summary>Removes the value: absent means enabled.</summary>
    void Clear(string fileName);
}

internal sealed class RegistryStartupApproval : IStartupApproval
{
    private const string KeyPath = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder";

    public byte[]? Get(string fileName)
    {
        using var key = Registry.CurrentUser.OpenSubKey(KeyPath);
        return key?.GetValue(fileName) as byte[];
    }

    public void Clear(string fileName)
    {
        using var key = Registry.CurrentUser.OpenSubKey(KeyPath, writable: true);
        key?.DeleteValue(fileName, throwOnMissingValue: false);
    }
}

/// <summary>
/// "Open BenchBar at logon": a shortcut named <c>BenchBar Tray.lnk</c> in the Startup folder that points at this exe.
/// The name is fixed: the shim's doctor looks for exactly this file. On means the file exists, points at this exe, and Windows
/// has not switched the entry off (<see cref="IStartupApproval"/>). Turning it on clears Windows' off switch for the entry.
/// </summary>
internal sealed class StartupShortcut(string? folder = null, string? exePath = null, string? fileName = null, string arguments = "", IStartupApproval? approval = null)
{
    private readonly IStartupApproval _approval = approval ?? new RegistryStartupApproval();

    public const string FileName = "BenchBar Tray.lnk";

    /// <summary>The one shot flag that opens the setup wizard again after the next sign in: the same exe, <c>--resume-setup</c>, removed by the tray when it starts with it.</summary>
    public const string ResumeFileName = "BenchBar Setup Resume.lnk";
    public const string ResumeArgument = "--resume-setup";

    private readonly string _folder = folder ?? Environment.GetFolderPath(Environment.SpecialFolder.Startup);
    private readonly string _exe = exePath ?? Environment.ProcessPath ?? "";

    public string LinkPath => Path.Combine(_folder, fileName ?? FileName);

    /// <summary>Whether Windows has the entry switched off: the first byte of its StartupApproved value is odd.</summary>
    public static bool IsDisabledValue(byte[]? value) => value is { Length: > 0 } && (value[0] & 1) == 1;

    /// <summary>Windows switched the entry off in Settings or Task Manager (the shortcut is there and is ignored at sign in).</summary>
    public bool IsApprovedOff()
    {
        try
        {
            return IsDisabledValue(_approval.Get(Path.GetFileName(LinkPath)));
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return false; // cannot tell: the file decides
        }
    }

    public bool IsEnabled()
    {
        try
        {
            if (!File.Exists(LinkPath)) return false;
            if (IsApprovedOff()) return false;
            var target = ShellLink.ReadTarget(LinkPath);
            return string.Equals(Path.GetFullPath(target), Path.GetFullPath(_exe), StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception ex) when (ex is IOException or COMException or ArgumentException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    public void Enable()
    {
        Directory.CreateDirectory(_folder);
        ShellLink.Write(LinkPath, _exe, Path.GetDirectoryName(_exe) ?? "", "BenchBar", arguments);
        ClearApproval();
    }

    public void Disable()
    {
        if (File.Exists(LinkPath)) File.Delete(LinkPath);
        ClearApproval();
    }

    /// <summary>Takes Windows' off switch for this entry away (a value that is absent means enabled). A registry that cannot be written changes nothing else.</summary>
    private void ClearApproval()
    {
        try
        {
            _approval.Clear(Path.GetFileName(LinkPath));
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
        }
    }
}

/// <summary>Just enough of IShellLinkW and IPersistFile to write and read one shortcut.</summary>
internal static class ShellLink
{
    public static void Write(string linkPath, string target, string workingDirectory, string description, string arguments = "")
    {
        var link = (IShellLinkW)new ShellLinkObject();
        try
        {
            link.SetPath(target);
            link.SetWorkingDirectory(workingDirectory);
            link.SetDescription(description);
            if (arguments.Length > 0) link.SetArguments(arguments);
            link.SetIconLocation(target, 0);
            ((IPersistFile)link).Save(linkPath, true);
        }
        finally
        {
            Marshal.FinalReleaseComObject(link);
        }
    }

    public static string ReadTarget(string linkPath)
    {
        var link = (IShellLinkW)new ShellLinkObject();
        try
        {
            ((IPersistFile)link).Load(linkPath, 0);
            var sb = new StringBuilder(1024);
            link.GetPath(sb, sb.Capacity, IntPtr.Zero, 0);
            return sb.ToString();
        }
        finally
        {
            Marshal.FinalReleaseComObject(link);
        }
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    private class ShellLinkObject;

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
    private interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int maxPath, IntPtr findData, uint flags);
        void GetIDList(out IntPtr idList);
        void SetIDList(IntPtr idList);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, int maxName);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder dir, int maxPath);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder args, int maxPath);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int showCmd);
        void SetShowCmd(int showCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder iconPath, int maxPath, out int icon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string iconPath, int icon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string relPath, uint reserved);
        void Resolve(IntPtr hwnd, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("0000010b-0000-0000-C000-000000000046")]
    private interface IPersistFile
    {
        void GetClassID(out Guid classId);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string fileName, uint mode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string fileName, [MarshalAs(UnmanagedType.Bool)] bool remember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string fileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string fileName);
    }
}
