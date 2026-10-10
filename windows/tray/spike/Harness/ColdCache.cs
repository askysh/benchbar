using System.Diagnostics;
using System.Security.Principal;

namespace BenchBar.Tray.Harness;

/// <summary>Makes the next process start as cold as the session allows.</summary>
internal static class ColdCache
{
    private const int SystemMemoryListInformation = 80;
    private const int MemoryPurgeStandbyList = 4;

    public const string MethodWorkingSet = "empty-working-set";
    public const string MethodPurge = "empty-working-set+purge-standby";

    public static bool IsElevated()
    {
        using var id = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
    }

    /// <summary>Trims every process it can open, then purges the standby list when elevated. Returns the method used.</summary>
    public static string Prepare()
    {
        foreach (Process p in Process.GetProcesses())
        {
            using (p)
            {
                try
                {
                    IntPtr h = Native.OpenProcess(Native.ProcessSetQuota | Native.ProcessQueryLimitedInformation, false, (uint)p.Id);
                    if (h == IntPtr.Zero) continue;
                    Native.EmptyWorkingSet(h);
                    Native.CloseHandle(h);
                }
                catch (Exception)
                {
                    // Exited between listing and opening: nothing to trim.
                }
            }
        }

        if (IsElevated() && EnablePrivilege("SeProfileSingleProcessPrivilege"))
        {
            int command = MemoryPurgeStandbyList;
            int status = Native.NtSetSystemInformation(SystemMemoryListInformation, ref command, sizeof(int));
            if (status == 0) return MethodPurge;
        }
        return MethodWorkingSet;
    }

    private static bool EnablePrivilege(string name)
    {
        if (!Native.OpenProcessToken(Native.GetCurrentProcess(), Native.TokenAdjustPrivileges | Native.TokenQuery, out IntPtr token))
            return false;
        try
        {
            if (!Native.LookupPrivilegeValue(null, name, out long luid)) return false;
            var tp = new Native.TokenPrivileges { Count = 1, Luid = luid, Attributes = Native.SePrivilegeEnabled };
            if (!Native.AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return false;
            return System.Runtime.InteropServices.Marshal.GetLastWin32Error() != Native.ErrorNotAllAssigned;
        }
        finally
        {
            Native.CloseHandle(token);
        }
    }
}
