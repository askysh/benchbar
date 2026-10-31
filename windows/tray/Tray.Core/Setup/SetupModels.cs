using System.Text.Json;
using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>The state of one step of <c>benchbar.exe setup check --json</c>.</summary>
public enum SetupStatus { Unknown, Ok, Missing, Warn, Fail }

/// <summary>The step ids of the contract, in order, and the actions the shim runs.</summary>
public static class SetupIds
{
    public const string WindowsBuild = "windows_build";
    public const string Virtualization = "virtualization";
    public const string WslFeature = "wsl_feature";
    public const string Reboot = "reboot";
    public const string WslVersion = "wsl_version";
    public const string Distro = "distro";
    public const string DistroUser = "distro_user";
    public const string Systemd = "systemd";
    public const string Cli = "cli";
    public const string Linger = "linger";
    public const string Keepalive = "keepalive";
    public const string WslConfig = "wslconfig";
    public const string ShimPath = "shim_path";

    public const string ActionReboot = "reboot";
    public const string ActionWslEnable = "wsl_enable";
    public const string ActionDistroUser = "distro_user";
    public const string ActionSystemd = "systemd";

    /// <summary>The <c>error_id</c> of a done line: the action must restart the distro and the distro runs. Ask, then run again with <c>--force</c>.</summary>
    public const string ErrorDistroRunning = "distro_running";
}

/// <summary>One row of the Check Your PC page.</summary>
public sealed record SetupStepInfo(string Id, SetupStatus Status, string Title, string Detail, string? Action, bool NeedsAdmin, bool Blocking = true)
{
    /// <summary>The steps that are advice only: they never block the PC being ready, and an older shim does not say so.</summary>
    public static bool IsAdvisoryId(string id) => id is SetupIds.Linger or SetupIds.Keepalive or SetupIds.WslConfig or SetupIds.ShimPath;

    /// <summary>This step stops the wizard from going on: a blocking step that is not done (a warning counts as done), or one that was not looked at.</summary>
    public bool StopsTheWizard => Blocking && (!IsSatisfied || NotChecked);

    /// <summary>A blocking step the page cannot fix with a button (Windows too old, virtualization off, a WSL 1 distro): the person has to act.</summary>
    public bool NeedsManualFix => Blocking && !IsSatisfied && !Waits && Action is not { Length: > 0 };

    /// <summary>Advice with a command to run by hand: a non blocking warning the page has no button for.</summary>
    public bool HasAdviceCommand => !Blocking && Status == SetupStatus.Warn && Action is not { Length: > 0 } && !Waits;

    /// <summary>
    /// What the Copy button puts on the clipboard: the command at the end of the detail ("message: benchbar.exe path install") when
    /// it looks like one, else the whole detail.
    /// </summary>
    public string CopyText
    {
        get
        {
            var cut = Detail.LastIndexOf(": ", StringComparison.Ordinal);
            if (cut < 0) return Detail;
            var tail = Detail[(cut + 2)..].Trim();
            return tail.StartsWith("benchbar.exe ", StringComparison.OrdinalIgnoreCase) || tail.StartsWith("wsl.exe ", StringComparison.OrdinalIgnoreCase)
                || tail.StartsWith("wsl ", StringComparison.OrdinalIgnoreCase) || tail.StartsWith("setx ", StringComparison.OrdinalIgnoreCase)
                ? tail
                : Detail;
        }
    }

    public bool IsOk => Status is SetupStatus.Ok;

    /// <summary>Done or only advice: the page may continue past it.</summary>
    public bool IsSatisfied => Status is SetupStatus.Ok or SetupStatus.Warn;

    /// <summary>An earlier step blocks this one: the shim writes "waits for ID" in the detail.</summary>
    public bool Waits => Detail.StartsWith("waits for", StringComparison.OrdinalIgnoreCase);

    /// <summary>Not looked at because the distro is stopped and the check ran without --probe.</summary>
    public bool NotChecked => Detail.StartsWith("not checked", StringComparison.OrdinalIgnoreCase);
}

/// <summary><c>setup check --json</c>.</summary>
public sealed record SetupReport(string? Distro, bool Ready, bool RebootPending, IReadOnlyList<SetupStepInfo> Steps)
{
    public SetupStepInfo? Step(string id) => Steps.FirstOrDefault(s => s.Id == id);

    /// <summary>The first step that is not done and has something the page can run for it.</summary>
    public SetupStepInfo? NextActionable => Steps.FirstOrDefault(s => !s.IsSatisfied && !s.Waits && s.Action is { Length: > 0 });

    /// <summary>The first step that is not done, whether or not it has an action (a step that waits has none).</summary>
    public SetupStepInfo? FirstBlocking => Steps.FirstOrDefault(s => s.StopsTheWizard);

    /// <summary>
    /// The wizard may go on: there are steps, and none that is blocking is open. The shim's <c>ready</c> says the same; this is read
    /// from the steps so an advisory row (<c>blocking: false</c>) can never hold Continue back.
    /// </summary>
    public bool CanContinue => Steps.Count > 0 && !Steps.Any(s => s.StopsTheWizard);

    /// <summary>A blocking step is open: the PC is not set up.</summary>
    public bool HasBlockingFailure => Steps.Any(s => s.StopsTheWizard);

    public static SetupReport Empty { get; } = new(null, false, false, []);
}

/// <summary>One JSON line of <c>setup run ACTION --jsonl</c>.</summary>
public abstract record SetupEvent
{
    public sealed record Step(string Id, string Status, string Message) : SetupEvent;

    public sealed record Log(string Line) : SetupEvent;

    public sealed record Done(int Exit, bool Changed, bool RebootRequired, bool Cancelled,
        IReadOnlyList<string> Warnings, IReadOnlyList<string> NextActions, bool UserExisted = false, string? ErrorId = null) : SetupEvent;
}

/// <summary>Parsing of the shim's setup JSON. Tolerant: unknown fields are ignored, a line it does not know is null.</summary>
public static class SetupJson
{
    public static SetupStatus ParseStatus(string? value) => value?.Trim().ToLowerInvariant() switch
    {
        "ok" => SetupStatus.Ok,
        "missing" => SetupStatus.Missing,
        "warn" => SetupStatus.Warn,
        "fail" => SetupStatus.Fail,
        _ => SetupStatus.Unknown,
    };

    /// <summary><c>setup check --json</c>. Malformed JSON throws <see cref="JsonException"/>; a newer schema is refused.</summary>
    public static SetupReport ParseCheck(string json)
    {
        if (JsonNode.Parse(json) is not JsonObject root) throw new JsonException("setup check: not a JSON object");
        JsonRead.RefuseNewerSchema(root);
        var steps = new List<SetupStepInfo>();
        if (root["steps"] is JsonArray array)
        {
            foreach (var item in array.OfType<JsonObject>())
            {
                var id = JsonRead.Str(item, "id");
                if (string.IsNullOrEmpty(id)) continue;
                steps.Add(new SetupStepInfo(
                    id,
                    ParseStatus(JsonRead.Str(item, "status")),
                    JsonRead.Str(item, "title") ?? id,
                    JsonRead.Str(item, "detail") ?? "",
                    JsonRead.Str(item, "action") is { Length: > 0 } a ? a : null,
                    JsonRead.Bool(item, "needs_admin"),
                    item["blocking"] is JsonValue b && b.TryGetValue<bool>(out var blocking) ? blocking : !SetupStepInfo.IsAdvisoryId(id)));
            }
        }
        return new SetupReport(JsonRead.Str(root, "distro"), JsonRead.Bool(root, "ready"), JsonRead.Bool(root, "reboot_pending"), steps);
    }

    /// <summary>One line of the stream; null for text, a broken line or an event this reader does not know.</summary>
    public static SetupEvent? ParseLine(string line)
    {
        if (!JsonRead.TryObject(line, out var obj)) return null;
        JsonRead.RefuseNewerSchema(obj);
        switch (JsonRead.Str(obj, "event"))
        {
            case "step":
                return new SetupEvent.Step(JsonRead.Str(obj, "id") ?? "", JsonRead.Str(obj, "status") ?? "", JsonRead.Str(obj, "message") ?? "");
            case "log":
                return new SetupEvent.Log(JsonRead.Str(obj, "line") ?? "");
            case "done":
                return new SetupEvent.Done(
                    JsonRead.Int(obj, "exit") ?? 1,
                    JsonRead.Bool(obj, "changed"),
                    JsonRead.Bool(obj, "reboot_required"),
                    JsonRead.Bool(obj, "cancelled"),
                    JsonRead.Strings(obj, "warnings"),
                    JsonRead.Strings(obj, "next_actions"),
                    JsonRead.Bool(obj, "user_existed"),
                    JsonRead.Str(obj, "error_id") is { Length: > 0 } errorId ? errorId : null);
            default:
                return null;
        }
    }
}

/// <summary>The schema is newer than this tray reads.</summary>
public sealed class UnsupportedSchemaException(int found) : SourceProblemException($"benchbar.exe speaks schema {found}, which this BenchBar does not read. Update BenchBar.");

/// <summary>Small readers over <see cref="JsonObject"/>: a missing or wrongly typed member is null or false, never an exception.</summary>
internal static class JsonRead
{
    public const int SupportedSchema = 1;

    public static string? Str(JsonObject o, string key) => o[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    public static bool Bool(JsonObject o, string key) => o[key] is JsonValue v && v.TryGetValue<bool>(out var b) && b;

    public static int? Int(JsonObject o, string key)
    {
        if (o[key] is not JsonValue v) return null;
        if (v.TryGetValue<int>(out var i)) return i;
        return v.TryGetValue<double>(out var d) ? (int)Math.Round(d) : null;
    }

    public static IReadOnlyList<string> Strings(JsonObject o, string key) =>
        o[key] is JsonArray a ? a.Select(n => n is JsonValue v && v.TryGetValue<string>(out var s) ? s : null).OfType<string>().ToList() : [];

    public static bool TryObject(string line, out JsonObject obj)
    {
        obj = [];
        var text = line.Trim();
        if (text.Length == 0 || text[0] != '{') return false;
        try
        {
            if (JsonNode.Parse(text) is not JsonObject parsed) return false;
            obj = parsed;
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    public static void RefuseNewerSchema(JsonObject o)
    {
        if (Int(o, "schema_version") is { } v && v > SupportedSchema) throw new UnsupportedSchemaException(v);
    }
}
