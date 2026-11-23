using System.Globalization;
using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

/// <summary>One scratch bench of <c>bench gc --dry-run --json</c>: when it expires, how many sites it holds, who marked it and when.</summary>
public sealed record ScratchBench(string Bench, DateTimeOffset? Until, int Sites, string Why, string MarkedBy, DateTimeOffset? MarkedAt);

/// <summary>The plan of <c>bench gc</c>: the benches that expired (what an apply removes), the ones still waiting and the ones kept (the default bench).</summary>
public sealed record GcPlan(IReadOnlyList<ScratchBench> Expired, IReadOnlyList<ScratchBench> Pending, IReadOnlyList<ScratchBench> Skipped, string? Token);

/// <summary>One database of <c>db orphans --json</c> and the archived site folder that names it, if any.</summary>
public sealed record OrphanDatabase(string Name, string? ArchivedSite);

public sealed record OrphanList(int Checked, string Note, IReadOnlyList<OrphanDatabase> Orphans);

public static class TidyJson
{
    public static GcPlan ParseGc(JsonObject o)
    {
        if (o["expired"] is not JsonArray) throw new FormatException("The document has no expired list.");
        return new GcPlan(Rows(o, "expired"), Rows(o, "pending"), Rows(o, "skipped"), JsonRead.Str(o, "token"));
    }

    private static List<ScratchBench> Rows(JsonObject o, string key) =>
        (o[key] as JsonArray ?? []).OfType<JsonObject>().Where(r => JsonRead.Str(r, "bench") is { Length: > 0 }).Select(r => new ScratchBench(
            JsonRead.Str(r, "bench")!, Time(JsonRead.Str(r, "scratch_until_iso")), JsonRead.Int(r, "sites") ?? 0, JsonRead.Str(r, "why") ?? "",
            JsonRead.Str(r, "marked_by") ?? "unknown", Time(JsonRead.Str(r, "marked_at")))).ToList();

    private static DateTimeOffset? Time(string? text) =>
        DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var t) ? t : null;

    public static OrphanList ParseOrphans(JsonObject o)
    {
        if (o["orphans"] is not JsonArray array) throw new FormatException("The document has no orphans list.");
        return new OrphanList(JsonRead.Int(o, "checked") ?? 0, JsonRead.Str(o, "note") ?? "", array.OfType<JsonObject>()
            .Where(d => JsonRead.Str(d, "name") is { Length: > 0 })
            .Select(d => new OrphanDatabase(JsonRead.Str(d, "name")!, JsonRead.Str(d, "archived_site") is { Length: > 0 } s ? s : null)).ToList());
    }
}

/// <summary>The exact arguments and plan sheets of the tidy commands. A bench is named by its path, which the CLI takes as the first word.</summary>
public static class TidyCommands
{
    public const int MaxDays = 90;

    public static readonly string[] GcRead = ["bench", "gc", "--dry-run", "--json"];

    public static readonly string[] OrphansRead = ["db", "orphans", "--json"];

    /// <summary>The CLI allows removing data to a person only: these calls run as the person (the click and the typed name are that decision).</summary>
    private static void AsPerson(SecretEnvironment env) => env.Set(SetupEnv.NonInteractive, "0");

    public static string FolderName(string path) => path.TrimEnd('/', '\\') is { } t && t.LastIndexOfAny(['/', '\\']) is var i and >= 0 ? t[(i + 1)..] : path.TrimEnd('/', '\\');

    /// <summary>Whole days from 1 to 90, or null when the text is fine. The CLI refuses anything else, so it is not sent.</summary>
    public static string? TtlProblem(string? text) =>
        Days(text) is null ? $"Whole days from 1 to {MaxDays}." : null;

    public static int? Days(string? text) =>
        text is not null && text.Trim() is { Length: > 0 and <= 3 } t && t.All(char.IsAsciiDigit) && int.Parse(t, CultureInfo.InvariantCulture) is >= 1 and <= MaxDays and var d ? d : null;

    /// <summary>Marking asks nothing more here: the click is the CLI's question, and <c>--yes</c> says so.</summary>
    public static string[] Scratch(string bench, int days) => ["bench", "scratch", bench, "--ttl", days.ToString(CultureInfo.InvariantCulture), "--yes", "--json"];

    public static string[] ClearScratch(string bench) => ["bench", "scratch", bench, "--clear", "--yes", "--json"];

    public static PlanReviewRequest GcReview() => PlanReviewRequest.Tokened("Remove expired scratch benches", ["bench", "gc"]) with
    {
        ConfirmLabel = "Remove Benches",
        CanStop = false,
        ConfigureEnv = AsPerson,
        Summary = "Backs up each site of every expired scratch bench, drops its database and moves the bench folder aside. Nothing is deleted, and the default bench is never touched.",
        Describe = plan => TidyJson.ParseGc(plan.Raw).Expired.Select(b => $"{b.Bench}: {TidyText.Sites(b.Sites)}, marked scratch by {b.MarkedBy}").ToList(),
        ExplainFailure = ShareText.RootPasswordHelp,
    };

    public static PlanReviewRequest ForgetReview(string bench) => PlanReviewRequest.Tokened("Forget " + FolderName(bench), ["bench", "forget", bench]) with
    {
        ConfirmLabel = "Forget Bench",
        Summary = "Takes the bench out of benchbar's list and backs up and removes its service files. The folder, its sites, apps, databases and hosts lines stay.",
        Describe = Kept,
    };

    /// <summary>
    /// Remove: the plan by <c>--dry-run --json</c>, the apply by <c>--confirm-bench NAME --apply TOKEN --yes --jsonl</c>. The CLI wants the folder
    /// name repeated and allows it to a person only; the dialog before the sheet is the person typing that name.
    /// </summary>
    public static PlanReviewRequest RemoveReview(string bench) =>
        new("Remove " + FolderName(bench), [.. new[] { "bench", "remove", bench }, "--dry-run", "--json"],
            plan => ["bench", "remove", bench, "--confirm-bench", FolderName(bench), "--apply", plan.Token ?? "", "--yes", "--jsonl"])
        {
            ConfirmLabel = "Remove Bench",
            CanStop = false,
            ConfigureEnv = AsPerson,
            Summary = "Backs up each site with its files, drops its database, takes the bench out of benchbar's list and moves the folder to a trash folder next to it. Nothing is deleted.",
            Describe = plan => [.. Sites(plan), .. Kept(plan), .. Trash(plan)],
            ExplainFailure = ShareText.RootPasswordHelp,
        };

    public static IReadOnlyList<string> Kept(PlanDocument plan) =>
        JsonRead.Strings(plan.Raw, "keeps") is { Count: > 0 } keeps ? ["Kept: " + string.Join(", ", keeps) + "."] : [];

    private static IReadOnlyList<string> Sites(PlanDocument plan)
    {
        var names = (plan.Raw["sites"] as JsonArray ?? []).OfType<JsonObject>().Select(s => JsonRead.Str(s, "name")).OfType<string>().ToList();
        return names.Count == 0 ? ["Sites: none."] : [$"Sites: {TidyText.Sites(names.Count)}, {string.Join(", ", names)}. Each is backed up, then its database is dropped."];
    }

    private static IReadOnlyList<string> Trash(PlanDocument plan) =>
        JsonRead.Str(plan.Raw, "trash_in") is { Length: > 0 } trash ? [$"The folder moves to {trash}. Empty it yourself when you are sure."] : [];

    /// <summary>
    /// <c>uninstall-service</c> for this one bench (never <c>--all</c>): the dry run is shown as text, the apply runs after a yes. It stops the bench and
    /// removes its agent, runner and Procfile.lean, each backed up first; the bench, its sites and databases are not touched.
    /// </summary>
    public static PlanReviewRequest UninstallServiceReview(string bench, string name) =>
        new("Remove the service of " + name, ["uninstall-service", "--bench-dir", bench, "--dry-run", "--yes"], _ => ["uninstall-service", "--bench-dir", bench, "--yes"])
        {
            ConfirmLabel = "Remove Service",
            RequiresToken = false,
            PlanIsText = true,
            Summary = $"Stops {name} and removes its background service: the unit, the runner and Procfile.lean, each backed up first. The bench, its sites, apps and databases are not touched.",
        };
}

/// <summary>The words of the tidy surfaces, kept out of the views so a test can read them.</summary>
public static class TidyText
{
    public static string Sites(int n) => n == 1 ? "1 site" : $"{n} sites";

    public static string Orphan(OrphanDatabase d) => d.ArchivedSite is { } site ? $"{d.Name}, named by the archived site {site[(site.LastIndexOf('/') + 1)..]}" : d.Name;

    public static string OrphanSummary(OrphanList list) => list.Orphans.Count == 0
        ? $"No orphan database among {list.Checked} of frappe's shape."
        : $"{list.Orphans.Count} {(list.Orphans.Count == 1 ? "database" : "databases")} of {list.Checked} {(list.Orphans.Count == 1 ? "has" : "have")} no site in any bench benchbar knows.";

    /// <summary>"expired 5 days ago", or "expires 2026-11-30" for a bench that waits.</summary>
    public static string Expiry(ScratchBench b, DateTimeOffset now) => b.Until is not { } t ? "no time known"
        : t > now ? "expires " + t.UtcDateTime.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) : "expired " + ActivityText.Age(t, now);
}
