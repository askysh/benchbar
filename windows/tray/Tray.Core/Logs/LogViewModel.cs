namespace BenchBar.Tray.Core;

/// <summary>
/// One bench's log in the viewer (macos LogViewModel): the lines read through <c>logs --json</c> (never through <c>\\wsl$</c>), a capped
/// buffer, the filter and search, and Follow. Follow polls <c>logs --json --since</c> every <see cref="PollEvery"/> and only while the
/// viewer is open (<see cref="Start"/> to <see cref="Dispose"/>), Follow is on and the current log is shown (not the previous one).
/// Nothing runs otherwise. Raises <see cref="Changed"/> on the context captured at construction.
/// </summary>
public sealed class LogViewModel : IDisposable
{
    public const int RawTailKept = 400;

    private readonly ICliClient _cli;
    private readonly object _gate = new();
    private readonly SynchronizationContext? _context = SynchronizationContext.Current;
    private readonly LogBuffer _buffer;
    private readonly List<string> _rawTail = [];
    private CancellationTokenSource? _loop;
    private CancellationTokenSource? _load;
    private LogQuery _query = new();
    private string? _lastTime;
    private int? _currentMatch;
    private bool _follow = true;
    private bool _showPrevious;
    private bool _open;
    private bool _disposed;
    private int _polls;

    public LogViewModel(ICliClient cli, string benchPath, string benchName, int capacity = 5000)
    {
        _cli = cli;
        BenchPath = benchPath;
        BenchName = benchName;
        _buffer = new LogBuffer(capacity);
    }

    public string BenchPath { get; }

    public string BenchName { get; }

    /// <summary>How often Follow asks for newer lines. Tests make it short.</summary>
    public TimeSpan PollEvery { get; set; } = TimeSpan.FromSeconds(2);

    /// <summary>Asked before each Follow poll whether the distro runs, so a poll never boots a stopped one. Null skips the check.</summary>
    public IDistroProbe? DistroProbe { get; set; }

    /// <summary>The distro to ask about.</summary>
    public Func<string?> Distro { get; set; } = () => null;

    /// <summary>Follow stopped because the distro stopped. It resumes only when the person turns Follow on again.</summary>
    public bool DistroPaused { get; private set; }

    public const string DistroStoppedLine = "The distro stopped. Follow is paused.";

    public event Action? Changed;

    /// <summary>Bumped on every change the view must redraw whole for (not per line): new lines are not a change, the view appends what follows the last line it drew.</summary>
    public int Changes { get; private set; }

    public string? File { get; private set; }

    /// <summary>Why the log could not be read, or null.</summary>
    public string? Error { get; private set; }

    public bool IsLoading { get; private set; }

    /// <summary>How many polls have run (for tests).</summary>
    public int Polls => Volatile.Read(ref _polls);

    /// <summary>True while a Follow loop is running.</summary>
    public bool IsPolling
    {
        get
        {
            lock (_gate) return _loop is not null;
        }
    }

    public LogQuery Query
    {
        get
        {
            lock (_gate) return _query;
        }
    }

    public bool Follow
    {
        get => _follow;
        set
        {
            if (_follow == value) return;
            _follow = value;
            if (value) DistroPaused = false;
            Reschedule();
            Raise();
        }
    }

    public bool ShowPrevious
    {
        get => _showPrevious;
        set
        {
            if (_showPrevious == value) return;
            _showPrevious = value;
            Reschedule();
            _ = LoadAsync();
        }
    }

    public int? CurrentMatch
    {
        get
        {
            lock (_gate) return _currentMatch;
        }
    }

    // --- what the view shows ---

    public IReadOnlyList<LogLine> Visible()
    {
        lock (_gate) return _query.Visible(_buffer.Lines);
    }

    /// <summary>The visible lines that came after line <paramref name="id"/>, oldest first.</summary>
    public IReadOnlyList<LogLine> VisibleAfter(int id)
    {
        lock (_gate) return _query.Visible(_buffer.Lines.Where(l => l.Id > id));
    }

    public int FirstId
    {
        get
        {
            lock (_gate) return _buffer.Lines.Count == 0 ? int.MaxValue : _buffer.Lines[0].Id;
        }
    }

    public int LastId
    {
        get
        {
            lock (_gate) return _buffer.LastId;
        }
    }

    public int LineCount
    {
        get
        {
            lock (_gate) return _buffer.Lines.Count;
        }
    }

    public IReadOnlyList<int> Matches()
    {
        lock (_gate) return _query.Matches(_query.Visible(_buffer.Lines));
    }

    public string SearchSummary
    {
        get
        {
            lock (_gate) return SearchText.Describe(_currentMatch, _query.Matches(_query.Visible(_buffer.Lines)).Count, _query.Search.Trim().Length > 0);
        }
    }

    /// <summary>The line id of the current match, for the view to scroll to.</summary>
    public int? CurrentMatchId
    {
        get
        {
            lock (_gate)
            {
                var matches = _query.Matches(_query.Visible(_buffer.Lines));
                return _currentMatch is { } c && c < matches.Count ? matches[c] : null;
            }
        }
    }

    /// <summary>Every visible line, one per row, for Copy.</summary>
    public string VisibleText() => string.Join(Environment.NewLine, Visible().Select(l => l.Text));

    // --- changes the person makes ---

    public void SetProcess(string? process)
    {
        lock (_gate)
        {
            if (_query.Process == process) return;
            _query = _query with { Process = process };
            _currentMatch = null;
            Changes++;
        }
        Raise();
    }

    public void SetSearch(string search)
    {
        lock (_gate)
        {
            if (_query.Search == search) return;
            _query = _query with { Search = search };
            _currentMatch = null;
            Changes++;
        }
        Raise();
    }

    public void Step(bool forward)
    {
        lock (_gate)
        {
            var total = _query.Matches(_query.Visible(_buffer.Lines)).Count;
            _currentMatch = SearchText.Step(_currentMatch, total, forward);
            Changes++;
        }
        // moving to a match leaves the end of the log, so Follow ends (the checkbox shows it)
        if (_follow) Follow = false;
        else Raise();
    }

    /// <summary>Empties the view. The file is not touched, and what was shown is not read again by Follow.</summary>
    public void Clear()
    {
        lock (_gate)
        {
            _buffer.Clear();
            _currentMatch = null;
            Changes++;
        }
        Raise();
    }

    // --- reading ---

    /// <summary>Marks the viewer open: from now on Follow may poll.</summary>
    public void Start()
    {
        _open = true;
        Reschedule();
    }

    /// <summary>Reads the newest lines of the current (or the previous) log, replacing what is shown.</summary>
    public async Task LoadAsync(CancellationToken ct = default)
    {
        CancellationTokenSource? previous;
        var source = CancellationTokenSource.CreateLinkedTokenSource(ct);
        lock (_gate)
        {
            previous = _load;
            _load = source;
        }
        try { previous?.Cancel(); } catch (ObjectDisposedException) { }
        IsLoading = true;
        Error = null;
        Raise();
        var previousLog = _showPrevious;
        var result = await _cli.RunJsonAsync(LogArgs.First(BenchPath, previousLog), null, CliTimeouts.Read, LogsJson.Parse, source.Token).ConfigureAwait(false);
        if (_disposed || source.IsCancellationRequested) return;
        lock (_gate)
        {
            _buffer.Clear();
            _rawTail.Clear();
            _currentMatch = null;
            _lastTime = null;
            if (result.Value is { } chunk)
            {
                File = chunk.File;
                Remember(chunk.Lines, chunk.Times);
                _buffer.Append(chunk.Lines);
                Error = null;
            }
            else
            {
                Error = result.Error ?? "The log could not be read.";
            }
            Changes++;
        }
        IsLoading = false;
        Raise();
    }

    /// <summary>One Follow poll: the lines newer than the last one shown. Public so a test can run it once.</summary>
    public async Task PollOnceAsync(CancellationToken ct = default)
    {
        string? since;
        lock (_gate) since = _lastTime;
        Interlocked.Increment(ref _polls);
        var result = await _cli.RunJsonAsync(LogArgs.Newer(BenchPath, since), null, CliTimeouts.Read, LogsJson.Parse, ct).ConfigureAwait(false);
        if (_disposed || ct.IsCancellationRequested || result.Value is not { } chunk) return;
        var changed = false;
        lock (_gate)
        {
            if (_showPrevious) return;
            var (fresh, restarted) = LogOverlap.NewLines(_rawTail, chunk.Lines);
            if (fresh.Count == 0 && !restarted) return;
            if (restarted) _buffer.Append(["--- log restarted ---"]);
            // the times of the fresh lines are the last ones of the response
            var offset = chunk.Lines.Count - fresh.Count;
            Remember(fresh, chunk.Times.Skip(offset).ToList());
            _buffer.Append(fresh);
            changed = true;
        }
        if (changed) Raise();
    }

    private void Remember(IReadOnlyList<string> lines, IReadOnlyList<string?> times)
    {
        _rawTail.AddRange(lines);
        if (_rawTail.Count > RawTailKept) _rawTail.RemoveRange(0, _rawTail.Count - RawTailKept);
        for (var i = times.Count - 1; i >= 0; i--)
        {
            if (times[i] is not { } time) continue;
            _lastTime = time;
            break;
        }
    }

    // --- the Follow loop ---

    private void Reschedule()
    {
        lock (_gate)
        {
            var want = _open && _follow && !_showPrevious && !_disposed;
            if (!want)
            {
                try { _loop?.Cancel(); } catch (ObjectDisposedException) { }
                _loop = null;
                return;
            }
            if (_loop is not null) return;
            _loop = new CancellationTokenSource();
            var token = _loop.Token;
            _ = Task.Run(() => LoopAsync(token));
        }
    }

    private async Task LoopAsync(CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                await Task.Delay(PollEvery, ct).ConfigureAwait(false);
                if (!await DistroIsUpAsync(ct).ConfigureAwait(false))
                {
                    PauseForDistro();
                    return;
                }
                await PollOnceAsync(ct).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    private async Task<bool> DistroIsUpAsync(CancellationToken ct)
    {
        if (DistroProbe is null || Distro() is not { Length: > 0 } distro) return true;
        try
        {
            return await DistroProbe.IsRunningAsync(distro, ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return true; // wsl.exe could not be asked: the poll reports its own problem
        }
    }

    private void PauseForDistro()
    {
        lock (_gate)
        {
            _follow = false;
            DistroPaused = true;
            _loop = null;
            _buffer.Append([DistroStoppedLine]);
            Changes++;
        }
        Raise();
    }

    private void Raise()
    {
        if (_context is null || SynchronizationContext.Current == _context) Changed?.Invoke();
        else _context.Post(_ => { if (!_disposed) Changed?.Invoke(); }, null);
    }

    /// <summary>The viewer closed: Follow stops, a read still going is dropped.</summary>
    public void Dispose()
    {
        _disposed = true;
        _open = false;
        lock (_gate)
        {
            try { _loop?.Cancel(); } catch (ObjectDisposedException) { }
            _loop = null;
            try { _load?.Cancel(); } catch (ObjectDisposedException) { }
        }
    }
}
