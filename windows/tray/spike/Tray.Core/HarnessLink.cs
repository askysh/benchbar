using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Threading.Channels;

namespace BenchBar.Tray.Core;

/// <summary>
/// The shell's side of the measurement pipe. The harness owns a named pipe
/// server; with <c>BENCHBAR_TRAY_HARNESS_PIPE</c> set, the shell connects as a
/// client on a background task. Without the variable nothing exists: no
/// pipe, no thread. One UTF-8 text line per message.
/// </summary>
public sealed class HarnessLink : IDisposable
{
    public const string PipeVariable = "BENCHBAR_TRAY_HARNESS_PIPE";
    public const string ThemeVariable = "BENCHBAR_TRAY_THEME";

    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(30);

    private readonly Channel<string> _outbox = Channel.CreateBounded<string>(
        new BoundedChannelOptions(1024) { FullMode = BoundedChannelFullMode.DropWrite, SingleReader = true });
    private readonly CancellationTokenSource _cts = new();
    private readonly NamedPipeClientStream _pipe;
    private readonly Task _run;
    private int _disposed;

    /// <summary>The link for this process, or null when the harness variable is not set.</summary>
    public static HarnessLink? FromEnvironment(string shellName)
    {
        var name = Environment.GetEnvironmentVariable(PipeVariable);
        return string.IsNullOrWhiteSpace(name) ? null : new HarnessLink(name, shellName);
    }

    /// <summary>"light", "dark" or null (follow the system), from <c>BENCHBAR_TRAY_THEME</c>.</summary>
    public static string? ForcedTheme()
    {
        var value = Environment.GetEnvironmentVariable(ThemeVariable)?.Trim().ToLowerInvariant();
        return value is "light" or "dark" ? value : null;
    }

    private HarnessLink(string pipeName, string shellName)
    {
        _pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        // queued until the connection is up, so `icon-added` sent before it is not lost
        Send($"hello pid={Environment.ProcessId} shell={shellName}");
        _run = Task.Run(RunAsync);
    }

    /// <summary>A command line from the harness (<c>open-flyout</c>, <c>hide-flyout</c>, <c>quit</c>), on a thread pool thread.</summary>
    public event Action<string>? Command;

    /// <summary>Queues a line. Thread safe, never throws, dropped when the link is closed or full.</summary>
    public void Send(string line)
    {
        try { _outbox.Writer.TryWrite(line); }
        catch (Exception) { /* never throws */ }
    }

    /// <summary>The current time in the units of <c>qpc=</c> fields.</summary>
    public static long Qpc() => Stopwatch.GetTimestamp();

    private async Task RunAsync()
    {
        try
        {
            using var connectCts = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
            connectCts.CancelAfter(ConnectTimeout);
            await _pipe.ConnectAsync(connectCts.Token).ConfigureAwait(false);
        }
        catch (Exception)
        {
            _outbox.Writer.TryComplete();
            return;
        }

        _ = Task.Run(ReadLoopAsync);
        try
        {
            var writer = new StreamWriter(_pipe, new UTF8Encoding(false), 1024, leaveOpen: true) { NewLine = "\n", AutoFlush = true };
            await foreach (var line in _outbox.Reader.ReadAllAsync(_cts.Token).ConfigureAwait(false))
                await writer.WriteLineAsync(line.AsMemory(), _cts.Token).ConfigureAwait(false);
        }
        catch (Exception) { /* closed: nothing more to send */ }
    }

    private async Task ReadLoopAsync()
    {
        try
        {
            using var reader = new StreamReader(_pipe, new UTF8Encoding(false), false, 1024, leaveOpen: true);
            while (await reader.ReadLineAsync(_cts.Token).ConfigureAwait(false) is { } line)
            {
                try { Command?.Invoke(line.Trim()); }
                catch (Exception) { /* a handler must not end the link */ }
            }
        }
        catch (Exception) { /* closed */ }
    }

    /// <summary>Sends <c>bye</c>, flushes for a moment and closes the pipe.</summary>
    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        Send("bye");
        _outbox.Writer.TryComplete();
        try { _run.Wait(TimeSpan.FromSeconds(1)); } catch (Exception) { }
        _cts.Cancel();
        try { _pipe.Dispose(); } catch (Exception) { }
        _cts.Dispose();
    }
}
