using System.Runtime.ExceptionServices;

namespace BenchBar.Tray.Tests;

/// <summary>
/// Runs WPF code on a dedicated STA thread (WPF controls need one and xUnit v3 has no STA attribute). The thread gets its
/// own dispatcher on first use. Nothing is ever shown, so no interactive desktop is needed.
/// </summary>
internal static class Sta
{
    public static T Run<T>(Func<T> work)
    {
        T result = default!;
        ExceptionDispatchInfo? failure = null;
        var thread = new Thread(() =>
        {
            try { result = work(); }
            catch (Exception ex) { failure = ExceptionDispatchInfo.Capture(ex); }
            finally { System.Windows.Threading.Dispatcher.CurrentDispatcher.InvokeShutdown(); }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
        if (!thread.Join(TimeSpan.FromSeconds(60))) throw new TimeoutException("the STA test did not finish");
        failure?.Throw();
        return result;
    }

    public static void Run(Action work) => Run(() =>
    {
        work();
        return 0;
    });
}
