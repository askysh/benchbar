using System.ComponentModel;
using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>Default timeouts of the calls the pages make.</summary>
public static class CliTimeouts
{
    /// <summary>A read only call (<c>site list</c>, <c>app list</c>, <c>doctor</c>).</summary>
    public static readonly TimeSpan Read = TimeSpan.FromSeconds(60);

    /// <summary>A <c>--dry-run --json</c> plan; an app add reads the remote, so it is not short.</summary>
    public static readonly TimeSpan Plan = TimeSpan.FromMinutes(3);

    /// <summary>
    /// A run that changes things (restore, drop, update, add, repair, a build): no hard timeout. Killing one part way can leave a half
    /// restored site or a half cloned app, so only the person can end it, and only where the run is safe to kill (<c>CanStop</c>).
    /// </summary>
    public static readonly TimeSpan Apply = Timeout.InfiniteTimeSpan;
}

/// <summary>
/// Calls the CLI through <c>benchbar.exe</c> and reads its JSON. A seam for the pages' view models: tests give it a
/// <see cref="ScriptedStreamRunner"/> and no process starts. Never throws for a failed call (a missing shim, a refusal, a
/// timeout): the result says so. Cancelling the token throws from <see cref="RunJsonAsync{T}"/>, and is reported by
/// <see cref="RunStreamAsync"/>.
/// </summary>
public interface ICliClient
{
    /// <summary>
    /// A command that prints one JSON document (<c>site list --json</c>, <c>X --dry-run --json</c>). <paramref name="parse"/> turns the
    /// document into the page's model; it may throw <see cref="FormatException"/> for a document it cannot use. Done fields found in
    /// the document come back in <see cref="CliResult{T}.Done"/>. <paramref name="env"/> is added to this one child's environment.
    /// </summary>
    Task<CliResult<T>> RunJsonAsync<T>(IReadOnlyList<string> args, SecretEnvironment? env, TimeSpan timeout, Func<JsonObject, T> parse, CancellationToken ct = default);

    /// <summary>The same call, keeping the document as it is.</summary>
    Task<CliResult<JsonObject>> RunJsonAsync(IReadOnlyList<string> args, SecretEnvironment? env, TimeSpan timeout, CancellationToken ct = default);

    /// <summary>
    /// A command that streams (<c>--json</c> or <c>--jsonl</c> ending in a <c>done</c> line). Each line is handed over as it arrives, on a
    /// pool thread. Cancelling kills the child and its tree and returns a result with <see cref="CliStreamResult.Cancelled"/>.
    /// </summary>
    Task<CliStreamResult> RunStreamAsync(IReadOnlyList<string> args, SecretEnvironment? env, TimeSpan timeout, Action<CliEvent> onEvent, CancellationToken ct = default);
}

public sealed class CliClient : ICliClient
{
    private readonly IStreamRunner _stream;
    private readonly Func<string?> _locate;

    public CliClient() : this(new SystemStreamRunner(), () => ShimLocator.Find()) { }

    public CliClient(IStreamRunner stream, Func<string?> locate)
    {
        _stream = stream;
        _locate = locate;
    }

    public Task<CliResult<JsonObject>> RunJsonAsync(IReadOnlyList<string> args, SecretEnvironment? env, TimeSpan timeout, CancellationToken ct = default) =>
        RunJsonAsync(args, env, timeout, o => o, ct);

    public async Task<CliResult<T>> RunJsonAsync<T>(IReadOnlyList<string> args, SecretEnvironment? env, TimeSpan timeout, Func<JsonObject, T> parse, CancellationToken ct = default)
    {
        var redact = new Redactor(env?.Secrets ?? []);
        var lines = new List<string>();
        StreamResult result;
        try
        {
            result = await StartAsync(args, env, line => { lock (lines) lines.Add(redact.Clean(line)); }, timeout, ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is SourceProblemException or TimeoutException)
        {
            return CliResult<T>.Failure(ex.Message);
        }
        string[] copy;
        lock (lines) copy = [.. lines];
        var error = result.Error is null ? null : redact.Clean(result.Error);
        JsonObject? document;
        try
        {
            document = CliJson.PickDocument(copy);
            if (document is not null) JsonRead.RefuseNewerSchema(document);
        }
        catch (UnsupportedSchemaException ex)
        {
            return new CliResult<T>(1, default, null, ex.Message);
        }
        var done = CliJson.FindDone(copy) ?? (document is null ? null : CliJson.ParseDone(document));
        var exit = done?.Exit ?? result.ExitCode;
        if (document is null || (done is { Exit: not 0 } && JsonRead.Str(document, "event") == "done"))
            return new CliResult<T>(exit == 0 ? 1 : exit, default, done, done?.Problem ?? error ?? $"benchbar.exe {args.FirstOrDefault()} printed no JSON (exit {result.ExitCode}).");
        try
        {
            return new CliResult<T>(exit, parse(document), done, exit == 0 ? null : done?.Problem ?? error);
        }
        catch (Exception ex) when (ex is FormatException or InvalidOperationException or KeyNotFoundException)
        {
            return new CliResult<T>(exit == 0 ? 1 : exit, default, done, ex.Message);
        }
    }

    public async Task<CliStreamResult> RunStreamAsync(IReadOnlyList<string> args, SecretEnvironment? env, TimeSpan timeout, Action<CliEvent> onEvent, CancellationToken ct = default)
    {
        var redact = new Redactor(env?.Secrets ?? []);
        CliDone? done = null;
        string? issue = null;
        var text = new List<string>();
        void OnLine(string raw)
        {
            var line = redact.Clean(raw);
            CliEvent e;
            try { e = CliJson.ParseLine(line); }
            catch (UnsupportedSchemaException ex) { issue ??= ex.Message; return; }
            switch (e)
            {
                case CliEvent.Done d: done = d.Value; break;
                case CliEvent.Text t: lock (text) text.Add(t.Line); break;
            }
            onEvent(e);
        }

        StreamResult result;
        try
        {
            result = await StartAsync(args, env, OnLine, timeout, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            string[] seen;
            lock (text) seen = [.. text];
            return new CliStreamResult(130, done, null, true, seen);
        }
        catch (Exception ex) when (ex is SourceProblemException or TimeoutException)
        {
            return CliStreamResult.Failure(ex.Message);
        }
        var error = issue ?? (result.Error is null ? null : redact.Clean(result.Error));
        var exit = done?.Exit ?? result.ExitCode;
        if (done is null && result.ExitCode == 0 && issue is not null) exit = 1;
        string[] textCopy;
        lock (text) textCopy = [.. text];
        return new CliStreamResult(exit, done, error, false, textCopy);
    }

    private Task<StreamResult> StartAsync(IReadOnlyList<string> args, SecretEnvironment? env, Action<string> onLine, TimeSpan timeout, CancellationToken ct)
    {
        var shim = _locate() ?? throw new SetupProblemException(ShimBenchSource.NotFoundMessage);
        try
        {
            // The secrets are placed in the child's environment here, at the last moment, and the dictionary is not kept.
            return _stream.RunAsync(shim, args, env?.Materialize(), onLine, timeout, ct);
        }
        catch (Win32Exception ex)
        {
            throw new CliProblemException($"benchbar.exe could not be started: {ex.Message}");
        }
    }
}

/// <summary>
/// A stream runner that answers from a script instead of starting a process (tests, and the pages' inert default).
/// The first reply whose matcher accepts the arguments wins; a call nothing matches fails with exit 1 and a stderr line.
/// </summary>
public sealed class ScriptedStreamRunner : IStreamRunner
{
    private readonly List<(Func<string[], bool> Match, ScriptedReply Reply)> _script = [];

    /// <summary>Every call so far: the arguments and a copy of the environment given to the child.</summary>
    public List<(string[] Args, Dictionary<string, string> Env)> Runs { get; } = [];

    /// <summary>Replies to calls whose arguments start with <paramref name="prefix"/> (for example <c>["site", "list"]</c>).</summary>
    public ScriptedReply On(params string[] prefix) =>
        On(args => args.Length >= prefix.Length && args.Take(prefix.Length).SequenceEqual(prefix));

    public ScriptedReply On(Func<string[], bool> match)
    {
        var reply = new ScriptedReply();
        _script.Add((match, reply));
        return reply;
    }

    public async Task<StreamResult> RunAsync(string fileName, IReadOnlyList<string> args, IReadOnlyDictionary<string, string>? environment,
        Action<string> onLine, TimeSpan timeout, CancellationToken ct)
    {
        var copy = args.ToArray();
        Runs.Add((copy, environment is null ? [] : new Dictionary<string, string>(environment)));
        var reply = _script.FirstOrDefault(s => s.Match(copy)).Reply;
        if (reply is null) return new StreamResult(1, "No scripted reply for: " + string.Join(' ', copy));
        foreach (var line in reply.Lines) onLine(line);
        if (reply.Gate is { } gate)
        {
            reply.Started.TrySetResult();
            await gate.Task.WaitAsync(ct).ConfigureAwait(false);
        }
        foreach (var line in reply.After) onLine(line);
        return new StreamResult(reply.Exit, reply.Error);
    }
}

/// <summary>What <see cref="ScriptedStreamRunner"/> answers: stdout lines, an exit code, a stderr line.</summary>
public sealed class ScriptedReply
{
    public List<string> Lines { get; } = [];

    /// <summary>Lines written after the gate opens.</summary>
    public List<string> After { get; } = [];

    public int Exit { get; private set; }

    public string? Error { get; private set; }

    /// <summary>When set, the run waits here (after <see cref="Lines"/>) until released or cancelled: a run for the Stop button.</summary>
    public TaskCompletionSource? Gate { get; private set; }

    /// <summary>Completes when a held run has reached its gate.</summary>
    public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public ScriptedReply Print(params string[] lines)
    {
        Lines.AddRange(lines);
        return this;
    }

    public ScriptedReply Fail(int exit, string? stderr = null)
    {
        Exit = exit;
        Error = stderr;
        return this;
    }

    public ScriptedReply Hold()
    {
        Gate = new(TaskCreationOptions.RunContinuationsAsynchronously);
        return this;
    }

    public ScriptedReply Release(params string[] after)
    {
        After.AddRange(after);
        Gate?.TrySetResult();
        return this;
    }
}
