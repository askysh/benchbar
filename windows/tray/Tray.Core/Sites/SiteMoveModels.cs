using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>What the address does: the name stays (its hosts line is kept) and the port is the other bench's.</summary>
public sealed record SiteMoveAddress(string Line, string UrlBefore, string UrlAfter, bool PortChanges);

/// <summary>
/// The fields of <c>site move --dry-run --json</c> that <see cref="PlanDocument"/> keeps in its raw document: the apps, what stays, the new
/// address and the suggestions. Steps, errors, needs, the token and <c>can_apply</c> are read by <see cref="PlanDocument"/>. Every field is read
/// on its own, so a newer CLI's extra field or a missing list never costs the rest.
/// </summary>
public sealed record SiteMovePlan(string Bench, string Site, string ToBench, IReadOnlyList<string> Apps, IReadOnlyList<string> MissingApps, bool Migrate,
    IReadOnlyList<string> Stays, SiteMoveAddress? Address, IReadOnlyList<CliNextAction> NextActions);

public static class SiteMoveJson
{
    public static SiteMovePlan Read(PlanDocument doc)
    {
        var o = doc.Raw;
        var address = o["hosts"] as JsonObject is { } h
            ? new SiteMoveAddress(JsonRead.Str(h, "line") ?? "", JsonRead.Str(h, "url_before") ?? "", JsonRead.Str(h, "url_after") ?? "", JsonRead.Bool(h, "port_changes"))
            : null;
        var next = ResultEnvelope.Next(o);
        var migrate = o["migrate"] is not JsonValue m || !m.TryGetValue<bool>(out var on) || on;
        return new SiteMovePlan(JsonRead.Str(o, "bench") ?? "", JsonRead.Str(o, "site") ?? "", JsonRead.Str(o, "to_bench") ?? "", JsonRead.Strings(o, "apps"),
            JsonRead.Strings(o, "missing_apps"), migrate, JsonRead.Strings(o, "stays"), address, next);
    }
}

/// <summary>What the dialog asks for: the site, the bench it goes to and the one option. The same arguments make the plan and the apply, because <c>--no-migrate</c> is part of what the token stands for.</summary>
public sealed record SiteMoveRequest(string Site, string Target, bool NoMigrate, string Bench)
{
    /// <summary>The base of the plan: <see cref="PlanReviewRequest.Tokened"/> appends <c>--dry-run --json</c>, then <c>--apply TOKEN --yes --jsonl</c>.</summary>
    public string[] Base => ["site", "move", Site, "--to-bench", Target, .. NoMigrate ? new[] { "--no-migrate" } : [], "--bench-dir", Bench];
}

/// <summary>The gating of the entry and the rules of the move sheet, kept out of the views so a test can read them.</summary>
public static class SiteMoveRules
{
    public const string StopPrefix = "Stop the bench first";

    /// <summary>The entry shows when the CLI lists <c>site move</c> and another bench is registered.</summary>
    public static bool Offered(CommandCatalogue? catalogue, int others) => catalogue?.Has("site move") == true && others > 0;

    /// <summary>The benches a site can go to: every registered bench but this one.</summary>
    public static IReadOnlyList<BenchStatus> Targets(IReadOnlyList<BenchStatus> benches, string sourcePath) => benches.Where(b => b.Path != sourcePath).ToList();

    /// <summary>The plan's suggestion is <c>benchbar down --bench-dir SRC</c>.</summary>
    public static bool IsStop(string command)
    {
        var words = command.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return words.Contains("down") && words.Any(w => w == "benchbar" || w.EndsWith("/benchbar", StringComparison.Ordinal));
    }

    /// <summary>The source is running: the CLI says so as an error and as a <c>benchbar down</c> suggestion.</summary>
    public static bool NeedsStop(PlanDocument doc) =>
        SiteMoveJson.Read(doc).NextActions.Any(a => IsStop(a.Command)) || doc.Errors.Any(e => e.StartsWith(StopPrefix, StringComparison.Ordinal));
}

public static class SiteMoveText
{
    public static IReadOnlyList<string> Facts(SiteMovePlan plan)
    {
        var lines = new List<string> { UiText.Format("ProfileLineFrom", plan.Bench), UiText.Format("MoveTo", plan.ToBench) };
        if (plan.Apps.Count > 0) lines.Add(UiText.Format("MoveApps", string.Join(", ", plan.Apps)));
        if (plan.Address is { } a)
            lines.Add(a.PortChanges ? UiText.Format("MoveAddressChanges", a.UrlBefore, a.UrlAfter) : UiText.Format("MoveAddressSame", a.UrlAfter));
        lines.Add(plan.Migrate ? UiText.Get("MoveMigrateRuns") : UiText.Get("MoveMigrateSkipped"));
        foreach (var stays in plan.Stays) lines.Add(UiText.Format("MoveStays", stays));
        lines.Add(UiText.Get("MoveLeftAlone"));
        return lines;
    }
}

public static class SiteMoveCommands
{
    /// <summary>The tray's own stop, <c>down</c> for this bench: the answer to the CLI's "Stop the bench first". The CLI's suggestion text is never run.</summary>
    public static async Task<bool> StopBench(ICliClient cli, string bench) =>
        (await cli.RunStreamAsync(OverviewArgs.StopServices(bench), null, CliTimeouts.Apply, _ => { }).ConfigureAwait(false)).Ok;

    /// <summary>
    /// The sheet of a move. No <c>BENCHBAR_NONINTERACTIVE=0</c>: the CLI has no agent refusal for <c>site move</c>. It drops the site in the source,
    /// so Move waits for the site's name and is never the default button; <see cref="PlanReviewRequest.CanStop"/> is off, a move is not safe to kill.
    /// </summary>
    public static PlanReviewRequest Review(SiteMoveRequest request, Func<Task<bool>> stop) =>
        PlanReviewRequest.Tokened(UiText.Format("SiteMoveTitle", request.Site), request.Base) with
        {
            ConfirmLabel = UiText.Get("MoveConfirm"),
            CanStop = false,
            RefreshLabel = UiText.Get("RepairReviewAgain"),
            ConfirmName = request.Site,
            Summary = UiText.Format("MoveSummary", request.Site, TidyCommands.FolderName(request.Target)),
            Describe = plan => SiteMoveText.Facts(SiteMoveJson.Read(plan)),
            Allows = plan => plan.Needs.Count == 0 && plan.Steps.Count > 0,
            BlockedBy = plan => SiteMoveRules.NeedsStop(plan)
                ? new PlanResolver(UiText.Get("MoveStopBench"), stop, UiText.Get("MoveNotStopped")) : null,
        };
}
