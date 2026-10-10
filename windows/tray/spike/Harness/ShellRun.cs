using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Threading.Channels;

namespace BenchBar.Tray.Harness;

/// <summary>One line from the shell: a name and key=value pairs.</summary>
internal sealed record Msg(string Line)
{
    public string Name => Line.Split(' ', 2)[0];

    public string? Get(string key)
    {
        foreach (string token in Line.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            if (token.StartsWith(key + "=", StringComparison.Ordinal))
                return token[(key.Length + 1)..];
        }
        return null;
    }

    public long? GetLong(string key) => long.TryParse(Get(key), out long v) ? v : null;
}

/// <summary>
/// One shell process plus the named pipe server the harness owns for it. Every live
/// process is tracked so Ctrl+C and process exit never leave a shell behind.
/// </summary>
internal sealed class ShellRun : IDisposable
{
    private static readonly object LiveLock = new();
    private static readonly HashSet<Process> Live = [];

    private readonly NamedPipeServerStream _pipe;
    private readonly Channel<Msg> _inbox = Channel.CreateUnbounded<Msg>();
    private readonly CancellationTokenSource _dead = new();
    private readonly object _writeLock = new();
    private StreamWriter? _writer;
    private bool _disposed;

    public Process Process { get; }
    public string Shell { get; }

    public ShellRun(string shell, string exe, string fixturesDir, string? theme)
    {
        Shell = shell;
        string pipeName = "benchbar-tray-harness-" + Guid.NewGuid().ToString("N");
        _pipe = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);

        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            WorkingDirectory = Path.GetDirectoryName(Path.GetFullPath(exe))!,
        };
        psi.Environment["BENCHBAR_TRAY_HARNESS_PIPE"] = pipeName;
        psi.Environment["BENCHBAR_TRAY_FIXTURES"] = fixturesDir;
        if (theme is not null) psi.Environment["BENCHBAR_TRAY_THEME"] = theme;
        Process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        Process.Exited += (_, _) =>
        {
            // Let lines that were already written drain before waiters give up.
            try { _dead.CancelAfter(300); } catch (ObjectDisposedException) { }
        };
    }

    /// <summary>Takes QPC t0 right before Process.Start and starts the shell. Returns t0.</summary>
    public long Start()
    {
        _ = Task.Run(ReadLoopAsync);
        long t0 = Stopwatch.GetTimestamp();
        Process.Start();
        lock (LiveLock) Live.Add(Process);
        return t0;
    }

    private async Task ReadLoopAsync()
    {
        try
        {
            await _pipe.WaitForConnectionAsync().ConfigureAwait(false);
            lock (_writeLock) _writer = new StreamWriter(_pipe, new UTF8Encoding(false), 1024, leaveOpen: true) { AutoFlush = true, NewLine = "\n" };
            using var reader = new StreamReader(_pipe, Encoding.UTF8, false, 1024, leaveOpen: true);
            while (await reader.ReadLineAsync().ConfigureAwait(false) is { } line)
            {
                if (line.Length > 0) _inbox.Writer.TryWrite(new Msg(line.Trim()));
            }
        }
        catch (Exception)
        {
            // Pipe closed or disposed: waiters see a timeout or the process exit.
        }
        finally
        {
            _inbox.Writer.TryComplete();
        }
    }

    public bool HasExited
    {
        get
        {
            try { return Process.HasExited; } catch (InvalidOperationException) { return true; }
        }
    }

    public void Send(string line)
    {
        try
        {
            lock (_writeLock) _writer?.WriteLine(line);
        }
        catch (Exception)
        {
            // The shell went away; the next wait reports it.
        }
    }

    /// <summary>
    /// Waits for a line starting with <paramref name="name"/>; other lines are skipped.
    /// Returns null on timeout, on shell exit or on cancellation.
    /// </summary>
    public async Task<Msg?> WaitForAsync(string name, TimeSpan timeout, CancellationToken ct)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct, _dead.Token);
        cts.CancelAfter(timeout);
        try
        {
            while (true)
            {
                while (_inbox.Reader.TryRead(out Msg? m))
                {
                    if (m.Name == name) return m;
                }
                if (!await _inbox.Reader.WaitToReadAsync(cts.Token).ConfigureAwait(false)) return null;
            }
        }
        catch (OperationCanceledException)
        {
            return null;
        }
    }

    /// <summary>Why a wait failed, for the failure list.</summary>
    public string WhyNot(string waitingFor, CancellationToken ct) =>
        ct.IsCancellationRequested ? "interrupted"
        : HasExited ? $"shell exited (code {SafeExitCode()}) before {waitingFor}"
        : $"timeout waiting for {waitingFor}";

    private int SafeExitCode()
    {
        try { return Process.ExitCode; } catch (InvalidOperationException) { return -1; }
    }

    /// <summary>Asks the shell to quit, waits 5 s, then kills it.</summary>
    public void Quit()
    {
        Send("quit");
        try
        {
            if (!Process.WaitForExit(5000)) Kill();
        }
        catch (InvalidOperationException)
        {
            // Never started.
        }
    }

    public void Kill()
    {
        try
        {
            if (!Process.HasExited) Process.Kill(entireProcessTree: true);
            Process.WaitForExit(2000);
        }
        catch (Exception)
        {
            // Already gone.
        }
    }

    public static void KillAll()
    {
        Process[] all;
        lock (LiveLock) all = [.. Live];
        foreach (Process p in all)
        {
            try
            {
                if (!p.HasExited) p.Kill(entireProcessTree: true);
            }
            catch (Exception)
            {
                // Already gone.
            }
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Kill();
        lock (LiveLock) Live.Remove(Process);
        try { _dead.Cancel(); } catch (ObjectDisposedException) { }
        _pipe.Dispose();
        Process.Dispose();
    }
}
