using System.Globalization;
using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>
/// Tray tidy surfaces (issue 183): <c>bench gc</c> and scratch benches, <c>bench forget</c> and <c>bench remove</c>, <c>db orphans</c> and
/// <c>uninstall-service</c> for one bench. The fixtures are the CLI's documents (the plans are hand shaped from lifecycle.sh).
/// </summary>
public class TidyTests
{
    private const string Scratch = "/home/akash/scratch-qa";

    // --- gc and scratch benches ---

    [Fact]
    public void TheGcPlanListsWhatExpiredWhatIsPendingAndWhatIsKept()
    {
        var gc = TidyJson.ParseGc(CliFixture.Doc("bench-gc-plan.json"));
        var expired = Assert.Single(gc.Expired);
        Assert.Equal(Scratch, expired.Bench);
        Assert.Equal(2, expired.Sites);
        Assert.Equal("person", expired.MarkedBy);
        Assert.Equal(DateTimeOffset.Parse("2026-11-18T10:26:40Z", CultureInfo.InvariantCulture), expired.Until);
        Assert.Equal("/home/akash/scratch-next", Assert.Single(gc.Pending).Bench);
        Assert.Equal("it is the default bench", Assert.Single(gc.Skipped).Why);
        Assert.Null(gc.Skipped[0].MarkedAt); // an empty time is no time
        Assert.Equal("1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f809", gc.Token);
        Assert.Empty(TidyJson.ParseGc(CliFixture.Doc("bench-gc-plan-empty.json")).Expired);
        Assert.Throws<FormatException>(() => TidyJson.ParseGc(new JsonObject()));
    }

    [Fact]
    public void GcReadsItsPlanAtOnceAndAppliesThatPlansTokenAsThePerson()
    {
        Assert.Equal(["bench", "gc", "--dry-run", "--json"], TidyCommands.GcRead);
        var request = TidyCommands.GcReview();
        Assert.Equal(["bench", "gc", "--dry-run", "--json"], request.PlanArgs);
        var plan = PlanDocument.FromJson(CliFixture.Doc("bench-gc-plan.json"));
        Assert.Equal(["bench", "gc", "--apply", plan.Token!, "--yes", "--jsonl"], request.ApplyArgs(plan));
        var env = new SecretEnvironment();
        request.ConfigureEnv!(env);
        Assert.Equal("0", env.Materialize()[SetupEnv.NonInteractive]); // gc deletes data: the CLI allows it to a person only
        var lines = request.Describe!(plan);
        Assert.Contains(lines, l => l.Contains(Scratch) && l.Contains("2 sites") && l.Contains("person"));
        Assert.DoesNotContain(lines, l => l.Contains("scratch-next"));
    }

    [Fact]
    public void ScratchTakesWholeDaysFromOneToNinetyAndIsRunAsTheClick()
    {
        Assert.Equal(["bench", "scratch", Scratch, "--ttl", "3", "--yes", "--json"], TidyCommands.Scratch(Scratch, 3));
        Assert.Equal(["bench", "scratch", Scratch, "--clear", "--yes", "--json"], TidyCommands.ClearScratch(Scratch));
        Assert.Null(TidyCommands.TtlProblem("7"));
        Assert.Null(TidyCommands.TtlProblem(" 90 "));
        foreach (var bad in new[] { "", "0", "91", "-1", "2.5", "a", "007x" }) Assert.NotNull(TidyCommands.TtlProblem(bad));
        Assert.Equal(3, TidyCommands.Days(" 3 "));
    }

    // --- forget and remove ---

    [Fact]
    public void ForgetAndRemoveShowTheirPlanThenApplyThatToken()
    {
        var forget = TidyCommands.ForgetReview(Scratch);
        Assert.Equal(["bench", "forget", Scratch, "--dry-run", "--json"], forget.PlanArgs);
        var plan = PlanDocument.FromJson(CliFixture.Doc("bench-forget-plan.json"));
        Assert.Equal(["bench", "forget", Scratch, "--apply", plan.Token!, "--yes", "--jsonl"], forget.ApplyArgs(plan));
        Assert.Contains(TidyCommands.Kept(plan), l => l.Contains("the bench folder with its sites and apps"));

        var remove = TidyCommands.RemoveReview(Scratch + "/");
        Assert.Equal(["bench", "remove", Scratch + "/", "--dry-run", "--json"], remove.PlanArgs);
        var removePlan = PlanDocument.FromJson(CliFixture.Doc("bench-remove-plan.json"));
        // the CLI wants the folder name repeated, then the token of the plan it was shown
        Assert.Equal(["bench", "remove", Scratch + "/", "--confirm-bench", "scratch-qa", "--apply", removePlan.Token!, "--yes", "--jsonl"], remove.ApplyArgs(removePlan));
        var env = new SecretEnvironment();
        remove.ConfigureEnv!(env);
        Assert.Equal("0", env.Materialize()[SetupEnv.NonInteractive]);
        Assert.False(remove.CanStop);
        Assert.Equal(5, removePlan.Steps.Count);
        var lines = remove.Describe!(removePlan);
        Assert.Contains(lines, l => l.Contains("2 sites") && l.Contains("qa.localhost"));
        Assert.Contains(lines, l => l.Contains("/home/akash/.benchbar-trash"));
    }

    [Fact]
    public void TheDefaultBenchPlanCannotBeApplied()
    {
        var plan = PlanDocument.FromJson(CliFixture.Doc("bench-remove-default.json"));
        Assert.False(plan.CanApply);
        Assert.Contains("is the default bench", Assert.Single(plan.Errors));
    }

    [Fact]
    public void TheFolderNameIsTheLastPartOfThePath()
    {
        Assert.Equal("scratch-qa", TidyCommands.FolderName(Scratch));
        Assert.Equal("scratch-qa", TidyCommands.FolderName(Scratch + "//"));
        Assert.Equal("bench", TidyCommands.FolderName("bench"));
    }

    // --- db orphans ---

    [Fact]
    public void OrphanDatabasesAreReadWithTheArchivedSiteThatNamesThem()
    {
        Assert.Equal(["db", "orphans", "--json"], TidyCommands.OrphansRead);
        var list = TidyJson.ParseOrphans(CliFixture.Doc("db-orphans.json"));
        Assert.Equal(3, list.Checked);
        Assert.Equal(["_7f3a9c1e5b2d4a60", "_c2d4e6f8a0b1c3d5"], list.Orphans.Select(o => o.Name));
        Assert.Equal("/home/akash/scratch-qa/archived/sites/old.localhost", list.Orphans[0].ArchivedSite);
        Assert.Null(list.Orphans[1].ArchivedSite);
        Assert.Contains("benchbar does not drop them", list.Note);
        Assert.Equal("_7f3a9c1e5b2d4a60, named by the archived site old.localhost", TidyText.Orphan(list.Orphans[0]));
        Assert.Equal("_c2d4e6f8a0b1c3d5", TidyText.Orphan(list.Orphans[1]));
        Assert.Equal("1 database of 3 has no site in any bench benchbar knows.", TidyText.OrphanSummary(new OrphanList(3, "", [list.Orphans[0]])));
        Assert.Equal("No orphan database among 3 of frappe's shape.", TidyText.OrphanSummary(new OrphanList(3, "", [])));
    }

    // --- uninstall-service for one bench ---

    [Fact]
    public void RemovingTheServiceOfOneBenchPreviewsAsTextAndNeverPassesAll()
    {
        var request = TidyCommands.UninstallServiceReview("/home/akash/frappe-bench", "frappe-bench");
        Assert.True(request.PlanIsText);
        Assert.False(request.RequiresToken);
        Assert.Equal(["uninstall-service", "--bench-dir", "/home/akash/frappe-bench", "--dry-run", "--yes"], request.PlanArgs);
        Assert.Equal(["uninstall-service", "--bench-dir", "/home/akash/frappe-bench", "--yes"], request.ApplyArgs(PlanDocument.FromText(["[OK] dry-run"])));
        Assert.DoesNotContain("--all", request.PlanArgs);
    }
}
