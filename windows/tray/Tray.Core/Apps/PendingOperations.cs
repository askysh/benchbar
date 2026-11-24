namespace BenchBar.Tray.Core;

/// <summary>One step an unfinished run still has to do (<c>status --json</c>, <c>pending_operations[].steps[]</c>).</summary>
public sealed record PendingStep(string Kind, string Target, string Name);

/// <summary>
/// An <c>app update</c> or planned <c>app add</c> that stopped part way (<c>status --json</c>, <c>pending_operations[]</c>), one per app.
/// The CLI keeps a record of the steps not done; running the same command again does exactly those, and
/// <c>app update NAME --discard-pending</c> drops the record without running anything.
/// </summary>
public sealed record PendingOperation(string Op, string App, string? Branch, string? From, string? To, IReadOnlyList<PendingStep> Steps,
    string? FailedStep, string? Reason, string? UpdatedAt)
{
    public const string UpdateOp = "app_update";
    public const string AddOp = "app_add";

    public bool IsUpdate => Op == UpdateOp;

    public bool IsAdd => Op == AddOp;

    /// <summary>Only the two operations the CLI writes can be finished from here; a record of another kind can still be discarded.</summary>
    public bool CanResume => IsUpdate || IsAdd;

    /// <summary>"app update" or "app add", the words of the CLI's own doctor line.</summary>
    public string Command => IsAdd ? "app add" : "app update";

    /// <summary>
    /// The sentence of doctor's <c>app_update_pending</c> and <c>app_add_pending</c> checks:
    /// "app update of acme_crm did not finish: stopped at migrate (reason); 2 step(s) left (migrate, build)".
    /// </summary>
    public string Message
    {
        get
        {
            var kinds = string.Join(", ", Steps.Select(s => s.Kind));
            var text = UiText.Format("PendingDidNotFinish", Command, App);
            if (FailedStep is { Length: > 0 } failed) text = UiText.Format("PendingStoppedAt", text, failed);
            if (Reason is { Length: > 0 } reason) text = UiText.Format("PendingReason", text, reason);
            text = UiText.Format("PendingStepsLeft", text, Steps.Count);
            return kinds.Length > 0 ? UiText.Format("PendingKinds", text, kinds) : text;
        }
    }

    /// <summary>The command that finishes it, as doctor prints it (<c>fix_command</c>).</summary>
    public string FixLine(string bench) => $"benchbar {Command} {App} --bench-dir {bench}";

    /// <summary>The command that drops the record and stops; nothing it lists runs.</summary>
    public string DiscardLine(string bench) => $"benchbar app update {App} --discard-pending --bench-dir {bench}";

    public string ResumeLabel => IsAdd ? UiText.Get("PendingFinishAdd") : UiText.Get("PendingFinishUpdate");

    /// <summary>The same app has one record, so op and app identify it.</summary>
    public string Key => Op + "\t" + App;
}

internal static class PendingJson
{
    /// <summary>The array of <c>pending_operations</c>; a record without an app is skipped, and a missing array is none.</summary>
    public static IReadOnlyList<PendingOperation> Parse(IEnumerable<PendingDto>? records)
    {
        var list = new List<PendingOperation>();
        foreach (var r in records ?? [])
        {
            if (string.IsNullOrEmpty(r.App)) continue;
            var steps = (r.Steps ?? []).Where(s => !string.IsNullOrEmpty(s.Kind)).Select(s => new PendingStep(s.Kind!, s.Target ?? "", s.Name ?? s.Kind!)).ToList();
            list.Add(new PendingOperation(r.Op ?? "", r.App, r.Branch, r.From, r.To, steps, r.FailedStep, r.Reason, r.UpdatedAt));
        }
        return list;
    }
}
