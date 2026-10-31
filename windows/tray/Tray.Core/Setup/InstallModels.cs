using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>What the New Bench page chose, as the flags <c>install</c> takes. No password here: it goes in the environment.</summary>
public sealed record InstallRequest(string BenchDir, string Profile, string Bundle, string Site)
{
    public string[] Flags => ["--bench-dir", BenchDir, "--profile", Profile, "--bundle", Bundle, "--site", Site];
}

public enum InstallStepStatus { Unknown, Running, Done, Unchanged, Skipped, Warning, Failed, Stopped }

/// <summary>One step of the plan (<c>plan.steps[]</c>); the privileged ones are <see cref="Sudo"/>.</summary>
public sealed record InstallPlanStep(int? N, string Id, string Name, bool Sudo, bool WillRun);

/// <summary>Something the plan found in the way (<c>plan.blockers[]</c>): a port in use, a missing tool. It says what to do in <see cref="Fix"/>.</summary>
public sealed record PlanBlocker(string Id, string Message, string? Fix)
{
    /// <summary>The fix is a command to copy (see <see cref="FixCommand"/>).</summary>
    public bool FixIsCommand => Fix is { Length: > 0 } fix && FixCommand.IsCommand(fix);
}

/// <summary>The <c>plan</c> line of <c>install --json</c>.</summary>
public sealed record InstallPlan(string Bench, string Site, string? Profile, string? Bundle, string? WebUrl, string? SudoMode,
    bool DryRun, IReadOnlyList<InstallPlanStep> Steps, string? Log, IReadOnlyList<PlanBlocker>? PlanBlockers = null)
{
    /// <summary>What the plan found in the way; empty when nothing.</summary>
    public IReadOnlyList<PlanBlocker> Blockers => PlanBlockers ?? [];

    /// <summary>The steps that ask for the Linux password, and will run.</summary>
    public IReadOnlyList<InstallPlanStep> PrivilegedSteps => Steps.Where(s => s.Sudo && s.WillRun).ToList();
}

/// <summary>A <c>step</c> line: a step starts (running) and ends (the final status).</summary>
public sealed record InstallStep(int? N, string Id, string? Parent, string Name, InstallStepStatus Status, int? Secs, string? Message, string? Command);

/// <summary>A <c>progress</c> line.</summary>
public sealed record InstallProgress(string Step, string Label, int Elapsed);

/// <summary>The <c>done</c> line, always the last. <see cref="ErrorId"/> is the stable id of a refusal (<c>sudo_password_wrong</c>).</summary>
public sealed record InstallDone(int Exit, string? Bench, string? Site, string? Url, IReadOnlyList<string> Skipped, string? Fix, string? Log, string? Error, string? ErrorId)
{
    public bool WrongSudoPassword => ErrorId == InstallErrors.SudoPasswordWrong
        || (Error?.Contains(InstallErrors.SudoPasswordWrong, StringComparison.Ordinal) ?? false)
        || (Fix?.Contains(InstallErrors.SudoPasswordWrong, StringComparison.Ordinal) ?? false);
}

public static class InstallErrors
{
    public const string SudoPasswordWrong = "sudo_password_wrong";
}

/// <summary>An event of the <c>install --json</c> and <c>adopt --json</c> stream.</summary>
public abstract record InstallEvent
{
    public sealed record Plan(InstallPlan Value) : InstallEvent;

    public sealed record Step(InstallStep Value) : InstallEvent;

    public sealed record Progress(InstallProgress Value) : InstallEvent;

    public sealed record Done(InstallDone Value) : InstallEvent;
}

public static class InstallJson
{
    public static InstallStepStatus ParseStatus(string? value) => value?.Trim().ToLowerInvariant() switch
    {
        "running" => InstallStepStatus.Running,
        "done" => InstallStepStatus.Done,
        "unchanged" => InstallStepStatus.Unchanged,
        "skipped" => InstallStepStatus.Skipped,
        "warning" => InstallStepStatus.Warning,
        "failed" => InstallStepStatus.Failed,
        _ => InstallStepStatus.Unknown,
    };

    /// <summary>One line of the stream; null for a line this reader does not know. A schema above 1 throws.</summary>
    public static InstallEvent? ParseLine(string line)
    {
        if (!JsonRead.TryObject(line, out var o)) return null;
        JsonRead.RefuseNewerSchema(o);
        switch (JsonRead.Str(o, "event"))
        {
            case "plan":
                return new InstallEvent.Plan(ParsePlan(o));
            case "step":
                var id = JsonRead.Str(o, "id");
                if (string.IsNullOrEmpty(id)) return null;
                return new InstallEvent.Step(new InstallStep(JsonRead.Int(o, "n"), id, JsonRead.Str(o, "parent"), JsonRead.Str(o, "name") ?? id,
                    ParseStatus(JsonRead.Str(o, "status")), JsonRead.Int(o, "secs"), JsonRead.Str(o, "message"), JsonRead.Str(o, "command")));
            case "progress":
                return new InstallEvent.Progress(new InstallProgress(JsonRead.Str(o, "step") ?? "", JsonRead.Str(o, "label") ?? "", JsonRead.Int(o, "elapsed") ?? 0));
            case "done":
                return new InstallEvent.Done(ParseDone(o));
            default:
                return null;
        }
    }

    private static InstallPlan ParsePlan(JsonObject o)
    {
        var steps = new List<InstallPlanStep>();
        if (o["steps"] is JsonArray array)
        {
            foreach (var s in array.OfType<JsonObject>())
            {
                var id = JsonRead.Str(s, "id");
                if (string.IsNullOrEmpty(id)) continue;
                var willRun = !(s["will_run"] is JsonValue w && w.TryGetValue<bool>(out var run)) || run;
                steps.Add(new InstallPlanStep(JsonRead.Int(s, "n"), id, JsonRead.Str(s, "name") ?? id, JsonRead.Bool(s, "sudo"), willRun));
            }
        }
        var blockers = new List<PlanBlocker>();
        if (o["blockers"] is JsonArray found)
        {
            foreach (var item in found)
            {
                if (item is JsonObject b)
                {
                    var message = JsonRead.Str(b, "message") ?? JsonRead.Str(b, "error");
                    var fix = JsonRead.Str(b, "fix");
                    if (message is not { Length: > 0 } && fix is not { Length: > 0 }) continue;
                    blockers.Add(new PlanBlocker(JsonRead.Str(b, "id") ?? "", message ?? fix!, message is { Length: > 0 } ? fix : null));
                }
                else if (item is JsonValue v && v.TryGetValue<string>(out var text) && text.Length > 0) blockers.Add(new PlanBlocker("", text, null));
            }
        }
        return new InstallPlan(
            JsonRead.Str(o, "bench") ?? "", JsonRead.Str(o, "site") ?? "", JsonRead.Str(o, "profile"), JsonRead.Str(o, "bundle"),
            JsonRead.Str(o, "web_url"), JsonRead.Str(o, "sudo_mode"), JsonRead.Bool(o, "dry_run"), steps, JsonRead.Str(o, "log"), blockers);
    }

    private static InstallDone ParseDone(JsonObject o)
    {
        var skipped = new List<string>();
        if (o["skipped"] is JsonArray sk)
        {
            foreach (var item in sk.OfType<JsonObject>())
            {
                if (JsonRead.Str(item, "command") is { Length: > 0 } cmd) skipped.Add(cmd);
                else if (JsonRead.Str(item, "id") is { Length: > 0 } sid) skipped.Add(sid);
            }
        }
        return new InstallDone(
            JsonRead.Int(o, "exit") ?? 1, JsonRead.Str(o, "bench"), JsonRead.Str(o, "site"), JsonRead.Str(o, "url"), skipped,
            JsonRead.Str(o, "fix"), JsonRead.Str(o, "log"), JsonRead.Str(o, "error"),
            JsonRead.Str(o, "error_id") ?? JsonRead.Str(o, "code"));
    }
}
