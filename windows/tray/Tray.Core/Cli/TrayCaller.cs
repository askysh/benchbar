using System.Diagnostics;

namespace BenchBar.Tray.Core;

/// <summary>
/// Says who started a run: <c>BENCHBAR_CALLER=tray</c> in the environment of every process the tray starts. The shim
/// passes it on into the distro, and the CLI keeps it in the run's log header and in <c>benchbar history</c>. It is a
/// label the tray sets, not a proof (any process of the user can set it); the CLI ignores a value outside its short list.
/// </summary>
public static class TrayCaller
{
    public const string Variable = "BENCHBAR_CALLER";
    public const string Name = "tray";

    /// <summary>Sets the variable on a process about to start. An environment the caller passes afterwards can still override it.</summary>
    public static void Apply(ProcessStartInfo info) => info.Environment[Variable] = Name;
}
