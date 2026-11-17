namespace BenchBar.Tray;

/// <summary>One notice on the board: what to say, an optional button, and whether it can be dismissed.</summary>
internal sealed record Notice(string Key, string Text, string? ActionLabel = null, Action? Action = null, bool Dismissible = true);

/// <summary>
/// The notices the tray keeps on screen until they are dealt with: the tray closed unexpectedly last time, benchbar.exe and BenchBar are of
/// different versions, an error was caught and the tray kept running. Windows draw them (the flyout and the BenchBar window); one key is one notice.
/// </summary>
internal sealed class NoticeBoard
{
    private readonly List<Notice> _notices = [];

    public IReadOnlyList<Notice> All => _notices;

    public event Action? Changed;

    /// <summary>Adds the notice, or replaces the one with its key.</summary>
    public void Set(Notice notice)
    {
        var index = _notices.FindIndex(n => n.Key == notice.Key);
        if (index >= 0)
        {
            if (_notices[index] == notice) return;
            _notices[index] = notice;
        }
        else _notices.Add(notice);
        Changed?.Invoke();
    }

    public void Remove(string key)
    {
        if (_notices.RemoveAll(n => n.Key == key) > 0) Changed?.Invoke();
    }

    public bool Has(string key) => _notices.Any(n => n.Key == key);
}
