using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>One row of <c>doctor --prerequisites --json</c> (macos Prerequisite): what this machine needs before an install.</summary>
public sealed record Prerequisite(string Id, string Label, CheckLevel Level, string Message, string? FixCommand);

/// <summary>
/// <c>doctor --prerequisites --json</c>: read only, no bench needed. A <c>fail</c> stops an install, a <c>warn</c> does not (macos
/// PrerequisiteReport.canContinue). The CLI exits 1 on a fail and still prints the document.
/// </summary>
public sealed record PrerequisiteReport(IReadOnlyList<Prerequisite> Checks)
{
    public IReadOnlyList<Prerequisite> NeedsAttention => Checks.Where(c => c.Level != CheckLevel.Ok).OrderBy(c => c.Level == CheckLevel.Fail ? 0 : 1).ToList();

    public bool CanContinue => Checks.All(c => c.Level != CheckLevel.Fail);

    public static string[] Args(string benchDir) => ["doctor", "--prerequisites", "--json", "--bench-dir", benchDir];

    public static PrerequisiteReport Parse(JsonObject o)
    {
        if (o["prerequisites"] is not JsonArray array) throw new FormatException("doctor --prerequisites: the document has no prerequisites");
        var checks = new List<Prerequisite>();
        foreach (var c in array.OfType<JsonObject>())
        {
            var id = JsonRead.Str(c, "id");
            if (string.IsNullOrEmpty(id)) continue;
            var fix = JsonRead.Str(c, "fix_command");
            checks.Add(new Prerequisite(id, JsonRead.Str(c, "label") ?? id, BenchJson.ParseLevel(JsonRead.Str(c, "level")), JsonRead.Str(c, "message") ?? "",
                string.IsNullOrWhiteSpace(fix) ? null : fix));
        }
        return new PrerequisiteReport(checks);
    }
}

/// <summary>What asking for the prerequisites found: the report, or why there is none (the row then says nothing is known, never that all is well).</summary>
public sealed record PrerequisiteResult(PrerequisiteReport? Report, string? Error);
