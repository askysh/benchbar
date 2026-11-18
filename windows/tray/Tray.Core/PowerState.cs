using System.Runtime.InteropServices;

namespace BenchBar.Tray.Core;

/// <summary>Whether the PC runs on its battery, and whether Windows battery saver is on. Read through <c>GetSystemPowerStatus</c>.</summary>
public readonly partial record struct PowerState(bool OnBattery, bool BatterySaver)
{
    public static PowerState Mains { get; } = new(false, false);

    [StructLayout(LayoutKind.Sequential)]
    private struct SystemPowerStatus
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public int BatteryLifeTime;
        public int BatteryFullLifeTime;
    }

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetSystemPowerStatus(out SystemPowerStatus status);

    /// <summary>The state now. A PC that cannot tell (a desktop, a failed call, unknown line status) counts as on mains.</summary>
    public static PowerState Read()
    {
        try
        {
            if (!GetSystemPowerStatus(out var s)) return Mains;
            return new PowerState(OnBattery: s.ACLineStatus == 0, BatterySaver: (s.SystemStatusFlag & 1) != 0);
        }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException)
        {
            return Mains;
        }
    }
}
