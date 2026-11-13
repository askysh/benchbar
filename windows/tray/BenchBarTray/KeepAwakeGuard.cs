namespace BenchBar.Tray;

/// <summary>
/// Keeps Windows from sleeping while an install runs (<c>ES_CONTINUOUS | ES_SYSTEM_REQUIRED</c>), and lets it sleep again. The execution state
/// belongs to the thread that set it, so both calls come from the UI thread (the wizard model guarantees that), and the state ends with the
/// thread if the app is killed. The display may still turn off: only the system is held.
/// </summary>
internal sealed class KeepAwakeGuard(Func<uint, uint>? setState = null)
{
    private readonly Func<uint, uint> _set = setState ?? NativeMethods.SetThreadExecutionState;

    public bool IsOn { get; private set; }

    /// <summary>False when Windows refused (the call returns 0); the install goes on either way.</summary>
    public bool Set(bool on)
    {
        var ok = _set(on ? NativeMethods.EsContinuous | NativeMethods.EsSystemRequired : NativeMethods.EsContinuous) != 0;
        if (ok) IsOn = on;
        return ok;
    }
}
