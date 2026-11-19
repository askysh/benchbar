using System.IO.Pipes;
using System.Text;

namespace BenchBar.Tray.Core;

/// <summary>
/// How a second copy of the tray hands a <c>benchbar://</c> link to the running one: a named pipe that only this user can open
/// (<see cref="PipeOptions.CurrentUserOnly"/>), one link per connection, UTF-8, at most <see cref="LinkRouter.MaxLength"/> characters. The
/// link stays in memory: it is not written to a file, because a link can carry a token. The server waits for a connection, so it costs
/// no timer and no polling at rest.
/// </summary>
public static class LinkPipe
{
    /// <summary>The pipe of this user's session: another user, or another session of the same user, has its own tray.</summary>
    public static string NameFor(int sessionId) => $"BenchBarTray.Link.{sessionId}";

    /// <summary>The most bytes read from one connection: four bytes per character is the most UTF-8 needs.</summary>
    private const int MaxBytes = (LinkRouter.MaxLength + 1) * 4;

    /// <summary>
    /// Sends one link. False when nobody listens (no tray, or an older one without the pipe) or the send timed out; the caller then falls back
    /// to asking the running tray to open its flyout.
    /// </summary>
    public static async Task<bool> TrySendAsync(string pipeName, string link, TimeSpan timeout, CancellationToken ct = default)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", pipeName, PipeDirection.Out, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(timeout);
            await client.ConnectAsync(cts.Token).ConfigureAwait(false);
            var bytes = Encoding.UTF8.GetBytes(link + "\n");
            await client.WriteAsync(bytes, cts.Token).ConfigureAwait(false);
            await client.FlushAsync(cts.Token).ConfigureAwait(false);
            return true;
        }
        catch (Exception ex) when (ex is OperationCanceledException or IOException or UnauthorizedAccessException or TimeoutException)
        {
            return false;
        }
    }

    /// <summary>
    /// Starts the server: each link that arrives is handed to <paramref name="onLink"/> (on a pool thread). One that is too long, or that
    /// does not end, is dropped. A connection that sends nothing is closed after <paramref name="readTimeout"/>. Dispose stops it.
    /// </summary>
    public static IDisposable Serve(string pipeName, Action<string> onLink, TimeSpan? readTimeout = null)
    {
        var cts = new CancellationTokenSource();
        var wait = readTimeout ?? TimeSpan.FromSeconds(2);
        _ = Task.Run(() => RunAsync(pipeName, onLink, wait, cts.Token));
        return new Stopper(cts);
    }

    private sealed class Stopper(CancellationTokenSource cts) : IDisposable
    {
        public void Dispose()
        {
            cts.Cancel();
            cts.Dispose();
        }
    }

    private static NamedPipeServerStream Listen(string pipeName) =>
        new(pipeName, PipeDirection.In, NamedPipeServerStream.MaxAllowedServerInstances, PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);

    private static async Task RunAsync(string pipeName, Action<string> onLink, TimeSpan readTimeout, CancellationToken ct)
    {
        NamedPipeServerStream? server = null;
        while (!ct.IsCancellationRequested)
        {
            try
            {
                server ??= Listen(pipeName);
                await server.WaitForConnectionAsync(ct).ConfigureAwait(false);
                var connected = server;
                // the next listener exists before this client is read, so a second copy never finds the pipe missing
                server = Listen(pipeName);
                _ = ReadOneAsync(connected, onLink, readTimeout, ct);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ObjectDisposedException)
            {
                // a pipe name another program holds, or a client that left before it was accepted: wait a moment, never spin
                server?.Dispose();
                server = null;
                try { await Task.Delay(500, ct).ConfigureAwait(false); }
                catch (OperationCanceledException) { break; }
            }
        }
        server?.Dispose();
    }

    private static async Task ReadOneAsync(NamedPipeServerStream connected, Action<string> onLink, TimeSpan readTimeout, CancellationToken ct)
    {
        try
        {
            using var read = CancellationTokenSource.CreateLinkedTokenSource(ct);
            read.CancelAfter(readTimeout);
            if (await ReadLinkAsync(connected, read.Token).ConfigureAwait(false) is { } link) onLink(link);
        }
        catch (Exception ex) when (ex is OperationCanceledException or IOException or ObjectDisposedException)
        {
            // a client that sent nothing, or left half way: dropped
        }
        finally
        {
            await connected.DisposeAsync().ConfigureAwait(false);
        }
    }

    /// <summary>The first line of the connection, or null when it is empty, too long or not finished within the time.</summary>
    internal static async Task<string?> ReadLinkAsync(Stream stream, CancellationToken ct)
    {
        var buffer = new byte[MaxBytes];
        var used = 0;
        while (used < buffer.Length)
        {
            var n = await stream.ReadAsync(buffer.AsMemory(used), ct).ConfigureAwait(false);
            if (n == 0) break;
            used += n;
            if (Array.IndexOf(buffer, (byte)'\n', 0, used) >= 0) break;
        }
        if (used >= buffer.Length) return null;
        var end = Array.IndexOf(buffer, (byte)'\n', 0, used);
        var text = Encoding.UTF8.GetString(buffer, 0, end >= 0 ? end : used).Trim();
        return text.Length == 0 || text.Length > LinkRouter.MaxLength ? null : text;
    }
}
