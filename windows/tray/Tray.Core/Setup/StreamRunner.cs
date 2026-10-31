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
    /// Cancelling kills the child and its tree. A timeout throws <see cref="TimeoutException"/>.
    /// </summary>
    Task<StreamResult> RunAsync(string fileName, IReadOnlyList<string> args, IReadOnlyDictionary<string, string>? environment,
        Action<string> onLine, TimeSpan timeout, CancellationToken ct);
}

public sealed class SystemStreamRunner : IStreamRunner
{
    public async Task<StreamResult> RunAsync(string fileName, IReadOnlyList<string> args, IReadOnlyDictionary<string, string>? environment,
        Action<string> onLine, TimeSpan timeout, CancellationToken ct)
    {
        var info = new ProcessStartInfo(fileName)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in args) info.ArgumentList.Add(a);
        if (environment is not null)
        {
            foreach (var (name, value) in environment) info.Environment[name] = value;
        }

        using var process = new Process { StartInfo = info };
        process.Start();
        process.StandardInput.Close(); // the run never reads a terminal

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout);
        var errors = new List<string>();
        var pumpOut = Task.Run(async () =>
        {
            string? line;
            while ((line = await process.StandardOutput.ReadLineAsync(CancellationToken.None).ConfigureAwait(false)) is not null) onLine(line);
        }, CancellationToken.None);
        var pumpErr = Task.Run(async () =>
        {
            string? line;
            while ((line = await process.StandardError.ReadLineAsync(CancellationToken.None).ConfigureAwait(false)) is not null)
            {
                if (line.Trim().Length > 0 && errors.Count < 5) errors.Add(line.Trim());
            }
        }, CancellationToken.None);
        try
        {
            await process.WaitForExitAsync(cts.Token).ConfigureAwait(false);
            await Task.WhenAll(pumpOut, pumpErr).ConfigureAwait(false);
            return new StreamResult(process.ExitCode, errors.Count == 0 ? null : errors[0]);
        }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            if (ct.IsCancellationRequested) throw;
            throw new TimeoutException($"{Path.GetFileName(fileName)} did not finish in {(int)timeout.TotalMinutes} minutes.");
        }
    }
}
