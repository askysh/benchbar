using System.Runtime.InteropServices;
using System.Text;

namespace BenchBar.Tray;

/// <summary>
/// "Open BenchBar at logon": a shortcut named <c>BenchBar Tray.lnk</c> in the Startup folder that points at this exe.
/// The name is fixed: the shim's doctor looks for exactly this file. On means the file exists and points at this exe.
/// </summary>
internal sealed class StartupShortcut(string? folder = null, string? exePath = null)
{
    public const string FileName = "BenchBar Tray.lnk";

    private readonly string _folder = folder ?? Environment.GetFolderPath(Environment.SpecialFolder.Startup);
    private readonly string _exe = exePath ?? Environment.ProcessPath ?? "";

    public string LinkPath => Path.Combine(_folder, FileName);

    public bool IsEnabled()
    {
        try
        {
            if (!File.Exists(LinkPath)) return false;
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
        ShellLink.Write(LinkPath, _exe, Path.GetDirectoryName(_exe) ?? "", "BenchBar");
    }

    public void Disable()
    {
        if (File.Exists(LinkPath)) File.Delete(LinkPath);
    }
}

/// <summary>Just enough of IShellLinkW and IPersistFile to write and read one shortcut.</summary>
internal static class ShellLink
{
    public static void Write(string linkPath, string target, string workingDirectory, string description)
    {
        var link = (IShellLinkW)new ShellLinkObject();
        try
        {
            link.SetPath(target);
            link.SetWorkingDirectory(workingDirectory);
            link.SetDescription(description);
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
