using System.Diagnostics;
using System.Text;

namespace BenchBar.Tray.Core;

/// <summary>How a streamed child ended: its exit code, and the first lines it wrote on stderr.</summary>
public readonly record struct StreamResult(int ExitCode, string? Error);

/// <summary>Runs a child process and hands over its stdout line by line. A seam so tests do not start any.</summary>
public interface IStreamRunner
{
    /// <summary>
    /// Runs to the end. <paramref name="environment"/> is added to the child's environment for this one process only.
    /// Cancelling kills the child and its tree. A timeout throws <see cref="TimeoutException"/>. <paramref name="stdin"/> is one line
    /// for the child's standard input (a secret that must not be an argument); null sends nothing and closes the input at once.
    /// </summary>
    Task<StreamResult> RunAsync(string fileName, IReadOnlyList<string> args, IReadOnlyDictionary<string, string>? environment,
        Action<string> onLine, TimeSpan timeout, CancellationToken ct, string? stdin = null);
}

public sealed class SystemStreamRunner : IStreamRunner
{
    /// <summary>How long to wait for the output pipes after the child has exited: a grandchild that keeps a pipe open must not hang the call.</summary>
    public static readonly TimeSpan PipeGrace = TimeSpan.FromSeconds(5);

    /// <summary>A timeout in words: seconds below one minute ("60 seconds"), else minutes ("90 minutes", "1 minute").</summary>
    public static string TimeoutText(TimeSpan timeout)
    {
        if (timeout.TotalSeconds < 60)
        {
            var seconds = Math.Max(1, (int)Math.Ceiling(timeout.TotalSeconds));
            return seconds == 1 ? UiText.Get("SetupSecondOne") : UiText.Format("SetupSecondsMany", seconds);
        }
        var minutes = (int)timeout.TotalMinutes;
        return minutes == 1 ? UiText.Get("SetupMinuteOne") : UiText.Format("SetupMinutesMany", minutes);
    }

    /// <summary>How many stderr lines are kept: a refusal of <c>share join</c> prints the room first, so its sentence is not the first line.</summary>
    private const int ErrorLinesKept = 12;

    /// <summary>
    /// The sentence of what a child wrote on stderr: the first <c>[FAIL]</c> line when there is one (the CLI's own refusal, which can come after
    /// lines that only describe the room), else the first line. The generic <c>[FAIL] Command failed (exit N)</c> that <c>benchbar run</c> prints
    /// after a command is not the reason: it counts only when nothing else is there to say, so a first line that was the meaning stays the meaning.
    /// </summary>
    public static string? PickError(IReadOnlyList<string> lines) =>
        lines.FirstOrDefault(l => l.Contains("[FAIL]", StringComparison.Ordinal) && !l.Contains("[FAIL] Command failed (exit", StringComparison.Ordinal)) ?? lines.FirstOrDefault();

    /// <summary>
    /// Sends <paramref name="stdin"/> and a line feed (LF, never the platform's line end: the CLI reads the line with <c>read -r</c> and a
    /// carriage return would stay in it) as UTF-8 bytes without a byte order mark, then closes the input; the run never reads a terminal. A child that
    /// ended before it read gives <see cref="IOException"/>: that is not an error of ours, its exit code and what it wrote on stderr say why.
    /// </summary>
    private static async Task SendStdinAsync(Process process, string? stdin, CancellationToken ct)
    {
        try
        {
            if (stdin is not null)
            {
                var bytes = new UTF8Encoding(false).GetBytes(stdin + "\n");
                var input = process.StandardInput.BaseStream;
                await input.WriteAsync(bytes, ct).ConfigureAwait(false);
                await input.FlushAsync(ct).ConfigureAwait(false);
            }
        }
        catch (IOException)
        {
            // the child is gone: nothing to read it
        }
        finally
        {
            try
            {
                process.StandardInput.Close();
            }
            catch (IOException)
            {
                // see above
            }
        }
    }

    public async Task<StreamResult> RunAsync(string fileName, IReadOnlyList<string> args, IReadOnlyDictionary<string, string>? environment,
        Action<string> onLine, TimeSpan timeout, CancellationToken ct, string? stdin = null)
    {
        var info = new ProcessStartInfo(fileName)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            StandardInputEncoding = new UTF8Encoding(false), // no byte order mark in front of the first line
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in args) info.ArgumentList.Add(a);
        TrayCaller.Apply(info);
        if (environment is not null)
        {
            foreach (var (name, value) in environment) info.Environment[name] = value;
        }

        using var process = new Process { StartInfo = info };
        process.Start();

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout);
        var errors = new List<string>();
        var pumpOut = Task.Run(async () =>
        {
            try
            {
                string? line;
                while ((line = await process.StandardOutput.ReadLineAsync(CancellationToken.None).ConfigureAwait(false)) is not null) onLine(line);
            }
            catch (Exception ex) when (ex is ObjectDisposedException or IOException or InvalidOperationException)
            {
                // the process was disposed while a grandchild still held the pipe
            }
        }, CancellationToken.None);
        var pumpErr = Task.Run(async () =>
        {
            try
            {
                string? line;
                while ((line = await process.StandardError.ReadLineAsync(CancellationToken.None).ConfigureAwait(false)) is not null)
                {
                    if (line.Trim().Length > 0 && errors.Count < ErrorLinesKept) errors.Add(line.Trim());
                }
            }
            catch (Exception ex) when (ex is ObjectDisposedException or IOException or InvalidOperationException)
            {
                // see above
            }
        }, CancellationToken.None);
        try
        {
            await SendStdinAsync(process, stdin, cts.Token).ConfigureAwait(false); // under the timeout and the cancel token, with the pumps already reading
            await process.WaitForExitAsync(cts.Token).ConfigureAwait(false);
            try
            {
                await Task.WhenAll(pumpOut, pumpErr).WaitAsync(PipeGrace, ct).ConfigureAwait(false);
            }
            catch (TimeoutException)
            {
                // a grandchild holds a pipe: the child is done, so the result is what it printed so far
            }
            return new StreamResult(process.ExitCode, PickError(errors));
        }
        catch (OperationCanceledException)
        {
            ProcessKill.Tree(process);
            if (ct.IsCancellationRequested) throw;
            throw new TimeoutException(UiText.Format("SetupDidNotFinish", Path.GetFileName(fileName), TimeoutText(timeout)));
        }
    }
}
