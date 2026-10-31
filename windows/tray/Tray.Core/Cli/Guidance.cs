namespace BenchBar.Tray.Core;

/// <summary>What a typed confirmation asks: the dialog's text and the exact text the person must type (a site name to drop).</summary>
public sealed record TypedConfirmRequest(string Title, string Message, string Expected, string ConfirmLabel = "Drop");

/// <summary>The rule of the typed confirmation, apart from the dialog. The CLI checks the name again (<c>--confirm-site</c>).</summary>
public static class TypedConfirm
{
    /// <summary>True when the typed text is the expected text. Case and inner spaces count; surrounding spaces do not.</summary>
    public static bool Matches(string expected, string? typed) =>
        expected.Length > 0 && typed is not null && string.Equals(typed.Trim(), expected, StringComparison.Ordinal);
}

public enum GuidanceAction { Start, ViewHealth, ReviewPortConflict, Repair, SetUpManagement }

/// <summary>
/// Why a bench is not running, in one line, and at most one thing to do next (macos BenchGuidance.swift). Pure: the state, the stop
/// reason and whether the bench is managed or has a port conflict go in. The tray's action for the button lives with the page.
/// </summary>
public sealed record BenchGuidance(string Reason, GuidanceAction? Action)
{
    public string? ActionTitle => Action is { } a ? Title(a) : null;

    public static string Title(GuidanceAction action) => action switch
    {
        GuidanceAction.Start => "Start",
        GuidanceAction.ViewHealth => "View Health...",
        GuidanceAction.ReviewPortConflict => "Review Port Conflict...",
        GuidanceAction.Repair => "Repair...",
        _ => "Set Up Management...",
    };

    /// <summary>The same reason without <paramref name="shown"/> as its action: a button next to the line already offers it.</summary>
    public BenchGuidance Without(GuidanceAction shown) => Action == shown ? this with { Action = null } : this;

    /// <summary>Null while the bench runs, while an action is under way, or when its state is not known: nothing to say.</summary>
    public static BenchGuidance? Make(BenchState state, string? stopReason, bool needsService = false, bool portConflict = false, bool pending = false)
    {
        if (pending) return null;
        if (needsService) return new("BenchBar does not manage this bench yet, so it cannot start it.", GuidanceAction.SetUpManagement);
        if (portConflict) return new("Another program holds one of its ports.", GuidanceAction.ReviewPortConflict);
        var reason = stopReason?.Trim().ToLowerInvariant();
        switch (state)
        {
            case BenchState.Crashed:
                return new("It crashed and is being restarted.", GuidanceAction.ViewHealth);
            case BenchState.Paused:
                return reason switch
                {
                    "broken" => new("Its environment is broken, so automatic restarts are paused.", GuidanceAction.Repair),
                    "port_conflict" => new("Another program holds one of its ports.", GuidanceAction.ReviewPortConflict),
                    "manual" => new("You stopped it.", GuidanceAction.Start),
                    _ => new("It crashed three times in ten minutes, so restarts are paused.", GuidanceAction.ViewHealth),
                };
            case BenchState.Stopped:
                return reason switch
                {
                    "broken" => new("Its environment is broken, so it cannot start.", GuidanceAction.Repair),
                    "port_conflict" => new("Another program held one of its ports when it started.", GuidanceAction.ReviewPortConflict),
                    "manual" => new("You stopped it.", GuidanceAction.Start),
                    _ => new("It has not been started yet.", GuidanceAction.Start),
                };
            default:
                return null;
        }
    }

    public static BenchGuidance? For(BenchStatus bench, bool needsService = false, bool portConflict = false, bool pending = false) =>
        Make(bench.State, bench.StopReason, needsService, portConflict, pending);
}
