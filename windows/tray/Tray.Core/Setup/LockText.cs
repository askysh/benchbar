namespace BenchBar.Tray.Core;

/// <summary>
/// Recognises the CLI's refusal at its lock. The CLI has no stable id for it: <c>lib/frappe-local/lock.sh</c> dies with a sentence
/// ("Another benchbar run is active (pid N).", "Another benchbar run is starting ...", "Could not take the lock ... after N tries"),
/// before it changes anything. The tray matches those sentences, so a changed wording only makes it fail with the CLI's own line.
/// </summary>
public static class LockText
{
    private static readonly string[] Markers =
    [
        "another benchbar run is active",
        "another benchbar run is starting",
        "another benchbar run keeps taking it",
        "could not take the lock",
    ];

    /// <summary>True when any of the texts is the CLI's "the lock is held" line.</summary>
    public static bool IsHeld(params string?[] texts) =>
        texts.Any(t => t is { Length: > 0 } && Markers.Any(m => t.Contains(m, StringComparison.OrdinalIgnoreCase)));
}
