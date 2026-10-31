using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>One step of a plan. <see cref="Id"/> is the step's <c>id</c> or <c>kind</c>; <see cref="Sudo"/> marks a privileged one.</summary>
public sealed record PlanStepInfo(string Id, string Name, string? Command, string? Note, bool Sudo, bool WillRun);

/// <summary>
/// A plan as the sheet needs it, read from any of the CLI's plan documents (<c>site add</c>, <c>app add</c>, <c>site restore</c>,
/// <c>service</c>, <c>install</c>, <c>ports plan</c> entries): steps, what they touch, warnings, errors, the token. The fields only
/// one command has stay in <see cref="Raw"/>.
/// </summary>
public sealed record PlanDocument(IReadOnlyList<PlanStepInfo> Steps, IReadOnlyList<string> Touches, IReadOnlyList<string> Warnings,
    IReadOnlyList<string> Errors, IReadOnlyList<string> Needs, string? Token, bool CanApply, bool HasChanges, JsonObject Raw)
{
    /// <summary>The steps that ask for the Linux password and will run.</summary>
    public int SudoSteps => Steps.Count(s => s.Sudo && s.WillRun);

    public static PlanDocument FromJson(JsonObject o)
    {
        var steps = new List<PlanStepInfo>();
        if (o["steps"] is JsonArray array)
        {
            foreach (var s in array.OfType<JsonObject>())
            {
                var id = JsonRead.Str(s, "id") ?? JsonRead.Str(s, "kind") ?? "";
                var name = JsonRead.Str(s, "name") ?? JsonRead.Str(s, "title") ?? id;
                if (name.Length == 0) continue;
                var willRun = !(s["will_run"] is JsonValue w && w.TryGetValue<bool>(out var run)) || run;
                steps.Add(new PlanStepInfo(id, name, JsonRead.Str(s, "command"), JsonRead.Str(s, "note"),
                    JsonRead.Bool(s, "sudo") || JsonRead.Bool(s, "needs_sudo"), willRun));
            }
        }
        var errors = new List<string>(JsonRead.Strings(o, "errors"));
        var canApply = !(o["can_apply"] is JsonValue c && c.TryGetValue<bool>(out var can)) || can;
        var changes = !(o["changes"] is JsonValue h && h.TryGetValue<bool>(out var has)) || has;
        if (steps.Count == 0 && o["entries"] is JsonArray)
        {
            // ports plan: one entry per bench becomes one step, and a blocked bench is an error
            var entries = PortsJson.ParsePlan(o).Entries;
            foreach (var e in entries)
            {
                var what = e.ChangesPorts ? $"web port {e.Current.Web} to {e.Proposed.Web}" : e.ServiceInstalled ? "no change" : "set up the service files";
                steps.Add(new PlanStepInfo(e.Path, $"{e.Name}: {what}", null, e.Conflicts.Count > 0 ? string.Join("; ", e.Conflicts) : null,
                    false, e.NeedsSetup)); // ports apply runs nothing as root on Linux
                if (e.Blocked is { } blocked) errors.Add($"{e.Name}: {blocked}");
            }
            changes = entries.Any(e => e.NeedsSetup);
        }
        return new PlanDocument(steps, JsonRead.Strings(o, "touches"), JsonRead.Strings(o, "warnings"), errors, JsonRead.Strings(o, "needs"),
            JsonRead.Str(o, "token"), canApply && errors.Count == 0, changes, o);
    }
}

/// <summary>
/// Recognises the CLI's refusal of an old plan token by its exact wording (lib/frappe-local: sites.sh, site-restore.sh, app-plan.sh,
/// port-management.sh, profiles.sh): "The site add plan changed since it was shown", "The port plan changed.", "The update changed since
/// it was reviewed". A line that only mentions a stale lock or the word "changed" is not a refusal.
/// </summary>
public static partial class PlanStale
{
    [System.Text.RegularExpressions.GeneratedRegex(@"\b(plan|update|export)\b[^.\n]*\bchanged since it was (shown|reviewed)\b|\bThe port plan changed\.|\bchanged since it was reviewed\. Nothing was",
        System.Text.RegularExpressions.RegexOptions.IgnoreCase)]
    private static partial System.Text.RegularExpressions.Regex Refusal();

    public static bool Looks(string? text) => text is not null && Refusal().IsMatch(text);
}

/// <summary>
/// What the plan sheet needs to know about one command. Build it with <see cref="Tokened"/> for the usual pair
/// (<c>CMD --dry-run --json</c>, then <c>CMD --apply TOKEN --yes --jsonl</c>), or fill the two argument lists yourself.
/// </summary>
public sealed record PlanReviewRequest(string Title, IReadOnlyList<string> PlanArgs, Func<PlanDocument, IReadOnlyList<string>> ApplyArgs)
{
    public string ConfirmLabel { get; init; } = "Apply";

    /// <summary>Whether Stop is offered while the apply runs. Only for a run that is safe to kill part way (a clone, not a restore).</summary>
    public bool CanStop { get; init; }

    /// <summary>False for plans the CLI prints without a token (<c>adopt</c>, <c>app update</c>, <c>site drop</c>): the sheet then confirms without one.</summary>
    public bool RequiresToken { get; init; } = true;

    /// <summary>The apply uses <c>sudo</c>: when the plan has sudo steps, ask for the Linux password and run with <c>BENCHBAR_SUDO=env</c>.</summary>
    public bool UsesSudoEnv { get; init; }

    /// <summary>Adds the command's own secrets (an admin password) to the environment of the plan and apply calls.</summary>
    public Action<SecretEnvironment>? ConfigureEnv { get; init; }

    public TimeSpan PlanTimeout { get; init; } = CliTimeouts.Plan;

    public TimeSpan ApplyTimeout { get; init; } = CliTimeouts.Apply;

    /// <summary>Shown above the steps: what this will do, in a line.</summary>
    public string? Summary { get; init; }

    /// <summary><c>baseArgs --dry-run --json</c> to plan, <c>baseArgs --apply TOKEN --yes --jsonl</c> to apply.</summary>
    public static PlanReviewRequest Tokened(string title, IReadOnlyList<string> baseArgs) => new(
        title, [.. baseArgs, "--dry-run", "--json"], plan => [.. baseArgs, "--apply", plan.Token ?? "", "--yes", "--jsonl"]);
}

/// <summary>The sheet's answer to its caller.</summary>
public sealed record PlanOutcome(bool Applied, bool Cancelled, CliDone? Done)
{
    public static PlanOutcome None { get; } = new(false, false, null);
}
