namespace BenchBar.Tray.Core;

/// <summary>
/// After a package update Windows stops the running <c>benchbar.exe keepalive run</c> and starts the tray again with <c>--restarted</c>.
/// The tray then asks the shim to start the keepalive again: <c>keepalive start</c> does nothing (exit 0) when there is no keepalive task or
/// it already runs, and never creates a task, so the call is safe for everyone.
/// </summary>
public static class KeepaliveRestart
{
    public static readonly IReadOnlyList<string> Arguments = ["keepalive", "start"];

    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(30);

    /// <summary>
    /// One hidden shim call when <paramref name="restarted"/>, else nothing. Off the calling thread; a failure goes to <paramref name="fault"/> and never
    /// further. The returned task ends when the call has (a test awaits it; the app does not).
    /// </summary>
    public static Task RunAsync(bool restarted, IProcessRunner runner, Func<string?> locate, Action<Exception> fault)
    {
        if (!restarted) return Task.CompletedTask;
        return Task.Run(async () =>
        {
            try
            {
                var shim = locate();
                if (shim is null) return; // the setup check says so; nothing to log here
                var result = await runner.RunAsync(shim, Arguments, CancellationToken.None, Timeout).ConfigureAwait(false);
                if (result.ExitCode != 0)
                    fault(new InvalidOperationException($"benchbar.exe keepalive start exited with code {result.ExitCode}: {ShimBenchSource.FirstLine(result.Error) ?? ShimBenchSource.FirstLine(result.Output) ?? "no output"}"));
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                try { fault(ex); } catch (Exception) { /* logging must not fault the task */ }
            }
        });
    }
}
