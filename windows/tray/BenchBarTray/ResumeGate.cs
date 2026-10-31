namespace BenchBar.Tray;

/// <summary>
/// The one shot resume flag lives until the wizard has opened because of it. Both ways in (the tray started with
/// <c>--resume-setup</c>, or a second instance signalled the running one) go through here, so the flag cannot outlive its one use
/// and reopen the wizard at every sign in.
/// </summary>
internal sealed class ResumeGate(Action consumeFlag)
{
    /// <summary>Called whenever the wizard is about to open; removes the flag when the open is a resume.</summary>
    public void Opening(bool resume)
    {
        if (resume) consumeFlag();
    }
}
