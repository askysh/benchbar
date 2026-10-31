using System.Text.Json.Nodes;
using BenchBar.Tray.Core;
using Xunit;
using static Tray.Core.Tests.CliFixture;

namespace Tray.Core.Tests;

/// <summary>The Sites tab: names, rows, the menu, the exact CLI arguments and the documents it reads.</summary>
public class SitesModelTests
{
    private const string Bench = "/home/akash/frappe-bench";
    private static readonly TimeSpan Short = TimeSpan.FromSeconds(5);


    private static BenchStatus Status(BenchState state = BenchState.Running, params (string Name, bool Default)[] sites) =>
        new("frappe-bench", Bench, state, null, "http://one.localhost:8000", "one.localhost")
        {
            Sites = sites.Select(s => new SiteInfo(s.Name, s.Default)).ToList(),
        };

    // --- names ---

    [Theory]
    [InlineData("one.localhost", true)]
    [InlineData("qa-1.localhost", true)]
    [InlineData("1site", true)]
    [InlineData("", false)]
    [InlineData("One.localhost", false)]
    [InlineData("-lead", false)]
    [InlineData(".lead", false)]
    [InlineData("a b", false)]
    [InlineData("a_b", false)]
    [InlineData("a;rm", false)]
    public void ASiteNameFollowsTheCliRule(string name, bool valid) => Assert.Equal(valid, SiteNames.IsValid(name));

    [Theory]
    [InlineData("one.localhost", true)]
    [InlineData("localhost", true)]
    [InlineData("mysite", false)]
    [InlineData("mysite.test", false)]
    [InlineData("notlocalhost", false)]
    public void WindowsFindsOnlyLocalhostNames(string name, bool resolves) => Assert.Equal(resolves, SiteNames.ResolvesOnWindows(name));

    [Fact]
    public void ASuggestedNameEndsInLocalhost()
    {
        Assert.Equal("mysite.localhost", SiteNames.WithLocalhost("mysite"));
        Assert.Equal("mysite.test.localhost", SiteNames.WithLocalhost("mysite.test"));
        Assert.Equal("one.localhost", SiteNames.WithLocalhost("one.localhost"));
    }

    // --- rows ---

    [Fact]
    public void RowsCarryTheDefaultBadgeTheAddressAndOpenOrSetUp()
    {
        var rows = SiteRows.From(Status(BenchState.Running, ("one.localhost", true), ("two.localhost", false), ("mysite", false)));
        Assert.Equal(["one.localhost", "two.localhost", "mysite"], rows.Select(r => r.Name));
        Assert.Equal([true, false, false], rows.Select(r => r.IsDefault));
        Assert.Equal("http://two.localhost:8000", rows[1].Url);
        Assert.Equal(["Open", "Open", "Set Up..."], rows.Select(r => r.ActionLabel));
        Assert.Equal([true, true, false], rows.Select(r => r.CanOpen));
        Assert.True(rows[2].NeedsSetUp);
    }

    [Fact]
    public void ASiteOpensOnlyWhileTheBenchRuns()
    {
        var stopped = SiteRows.From(Status(BenchState.Stopped, ("one.localhost", true)));
        Assert.False(stopped[0].CanOpen);
        Assert.Equal("Open", stopped[0].ActionLabel);
    }

    [Fact]
    public void TheAddressKeepsTheSchemeAndPortOfTheBench()
    {
        Assert.Equal("http://qa.localhost:8003", SiteRows.UrlFor("http://one.localhost:8003", "qa.localhost"));
        Assert.Equal("https://qa.localhost", SiteRows.UrlFor("https://one.localhost", "qa.localhost"));
        Assert.Null(SiteRows.UrlFor(null, "qa.localhost"));
        Assert.Null(SiteRows.UrlFor("not a url", "qa.localhost"));
    }

    // --- menu ---

    [Fact]
    public void TheMenuOffersMakeDefaultOnlyOnASiteThatIsNotTheDefault()
    {
        var other = new SiteRowInfo("two.localhost", false, null, true, false);
        var main = other with { Name = "one.localhost", IsDefault = true };
        Assert.Equal(["Make Default", "Back Up", "Back Up with Files", "Backups...", "Restore...", "Open Console", "Open Database", "Drop Site..."],
            SiteMenu.For(other, onlySite: false).Select(i => i.Label));
        Assert.Equal(["Back Up", "Back Up with Files", "Backups...", "Restore...", "Open Console", "Open Database", "Drop Site..."],
            SiteMenu.For(main, onlySite: false).Select(i => i.Label));
    }

    [Fact]
    public void TheOnlySiteCannotBeDroppedAndNothingOfferedIsAHostsAction()
    {
        var row = new SiteRowInfo("one.localhost", true, null, true, false);
        var items = SiteMenu.For(row, onlySite: true);
        Assert.False(items.Single(i => i.Action == SiteAction.Drop).Enabled);
        Assert.True(items.Single(i => i.Action == SiteAction.Drop).Destructive);
        Assert.All(items.Where(i => i.Action != SiteAction.Drop), i => Assert.True(i.Enabled));
        Assert.DoesNotContain(items, i => i.Label.Contains("hosts", StringComparison.OrdinalIgnoreCase));
    }

    // --- exact arguments ---

    [Fact]
    public void EveryActionRunsExactlyTheseArguments()
    {
        Assert.Equal(["site", "default", "two.localhost", "--jsonl", "--bench-dir", Bench], SiteCommands.MakeDefault("two.localhost", Bench));
        Assert.Equal(["site", "backup", "one.localhost", "--json", "--bench-dir", Bench], SiteCommands.BackUp("one.localhost", false, Bench));
        Assert.Equal(["site", "backup", "one.localhost", "--with-files", "--json", "--bench-dir", Bench], SiteCommands.BackUp("one.localhost", true, Bench));
        Assert.Equal(["site", "backups", "one.localhost", "--json", "--bench-dir", Bench], SiteCommands.Backups("one.localhost", Bench));
        Assert.Equal(["site", "add", "qa1.localhost", "--bench-dir", Bench], SiteCommands.Add("qa1.localhost", Bench));
        Assert.Equal(["site", "drop", "two.localhost", "--confirm-site", "two.localhost", "--dry-run", "--json", "--bench-dir", Bench],
            SiteCommands.DropPlan("two.localhost", null, Bench));
        Assert.Equal(["site", "drop", "one.localhost", "--confirm-site", "one.localhost", "--new-default", "two.localhost", "--dry-run", "--json", "--bench-dir", Bench],
            SiteCommands.DropPlan("one.localhost", "two.localhost", Bench));
        Assert.Equal(["site", "drop", "two.localhost", "--confirm-site", "two.localhost", "--json", "--bench-dir", Bench],
            SiteCommands.Drop("two.localhost", "two.localhost", null, Bench));
    }

    [Fact]
    public void ARestoreNamesTheStampAndAsksForFilesOnlyWhenTheSetHasThem()
    {
        var plain = new SiteBackup("20260920_080000", null, null, "/b/db.gz", null, null, null, 1, false, false, false);
        var full = plain with { Stamp = "20260929_101500", WithFiles = true };
        Assert.Equal(["site", "restore", "one.localhost", "--from", "20260920_080000", "--bench-dir", Bench], SiteCommands.Restore("one.localhost", plain, Bench));
        Assert.Equal(["site", "restore", "one.localhost", "--from", "20260929_101500", "--with-files", "--bench-dir", Bench], SiteCommands.Restore("one.localhost", full, Bench));
    }

    // --- documents ---

    [Fact]
    public void BackupsAreReadWithTheirPartsSizeAndFlags()
    {
        var list = SiteJson.ParseList(Doc("sites-backups.json"));
        Assert.Equal("one.localhost", list.Site);
        Assert.EndsWith("/private/backups", list.Folder);
        Assert.Equal(["20260929_101500", "20260920_080000"], list.Backups.Select(b => b.Stamp));
        var first = list.Backups[0];
        Assert.Equal(5242880, first.SizeBytes);
        Assert.True(first.WithFiles);
        Assert.NotNull(first.Files);
        Assert.NotNull(first.PrivateFiles);
        Assert.Null(first.Config);
        Assert.Equal(new DateTimeOffset(2026, 9, 29, 4, 45, 0, TimeSpan.Zero), first.Time);
        Assert.True(first.CanRestore);
        Assert.True(list.Backups[1].Encrypted);
        Assert.False(list.Backups[1].CanRestore);
        Assert.Contains("encrypted", list.Backups[1].WhyNotRestorable);
    }

    [Fact]
    public void ABackupSummaryReadsWhenSizeAndFiles()
    {
        var first = SiteJson.ParseList(Doc("sites-backups.json")).Backups[0];
        Assert.Equal("Sep 29 2026 04:45, 5.0 MB, with files", first.Summary(TimeZoneInfo.Utc));
        Assert.Equal("Sep 29 2026 10:15, 5.0 MB, with files", first.Summary(TimeZoneInfo.CreateCustomTimeZone("ist", TimeSpan.FromHours(5.5), "ist", "ist")));
        Assert.Equal("1.0 KB", ByteSize.Format(1024));
        Assert.Equal("12 B", ByteSize.Format(12));
        Assert.Equal("3.0 GB", ByteSize.Format(3L * 1024 * 1024 * 1024));
    }

    [Fact]
    public void ADocumentWithoutBackupsOrStampsIsRefused()
    {
        Assert.Empty(SiteJson.ParseList(Doc("sites-backups-empty.json")).Backups);
        Assert.Throws<FormatException>(() => SiteJson.ParseList(new JsonObject { ["site"] = "x" }));
        Assert.Throws<FormatException>(() => SiteJson.ParseBackup(new JsonObject { ["size_bytes"] = 1 }));
    }

    [Fact]
    public void ABackupResultCarriesTheNewSet()
    {
        var result = SiteJson.ParseBackupResult(Doc("sites-backup.json"));
        Assert.Equal("one.localhost", result.Site);
        Assert.Equal("20261030_120000", result.Backup!.Stamp);
        Assert.Equal(2097152, result.Backup.SizeBytes);
        Assert.Null(SiteJson.ParseBackupResult(new JsonObject { ["site"] = "x", ["backup"] = null }).Backup);
    }

    [Fact]
    public void ADropPlanAndItsResultAreRead()
    {
        var plan = SiteJson.ParseDropPlan(Doc("sites-drop-plan-default.json"));
        Assert.True(plan.IsDefault);
        Assert.Equal("two.localhost", plan.NewDefault);
        Assert.Equal(2, plan.Steps.Count);
        Assert.StartsWith("Make two.localhost the default", plan.Steps[0].Title);
        Assert.False(plan.Steps[0].NeedsPassword);
        Assert.Throws<FormatException>(() => SiteJson.ParseDropPlan(new JsonObject()));

        var result = SiteJson.ParseDropResult(Doc("sites-drop-result.json"));
        Assert.True(result.Dropped);
        Assert.EndsWith("archived/sites/two.localhost", result.ArchivedPath);
        Assert.Equal("20261030_121500", result.Backup!.Stamp);
        Assert.Null(result.NewDefault);
    }

    [Fact]
    public void ADropIsBlockedOnTheOnlySiteAndListsTheSuccessors()
    {
        var one = new SiteRowInfo("one.localhost", true, null, true, false);
        var two = one with { Name = "two.localhost", IsDefault = false };
        Assert.NotNull(SiteDropRules.Blocker([one], "one.localhost"));
        Assert.Null(SiteDropRules.Blocker([one, two], "one.localhost"));
        Assert.Equal(["two.localhost"], SiteDropRules.Successors([one, two], "one.localhost"));
    }

    // --- through the client ---

    [Fact]
    public async Task TheBackupCallRunsItsArgumentsAndReadsTheDocument()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("site", "backup").Print(CliFixture.Lines("sites-backup.json"));
        var result = await client.RunJsonAsync(SiteCommands.BackUp("one.localhost", true, Bench), null, Short, SiteJson.ParseBackupResult, TestContext.Current.CancellationToken);
        Assert.True(result.Ok);
        Assert.Equal("20261030_120000", result.Value!.Backup!.Stamp);
        Assert.Equal(SiteCommands.BackUp("one.localhost", true, Bench), runner.Runs.Single().Args);
    }

    [Fact]
    public async Task AFailedDefaultChangeReportsTheCliError()
    {
        var (client, runner) = CliFixture.Scripted();
        runner.On("site", "default").Print(CliFixture.Lines("sites-default-fail.jsonl")).Fail(1);
        var result = await client.RunStreamAsync(SiteCommands.MakeDefault("two.localhost", Bench), null, Short, _ => { }, TestContext.Current.CancellationToken);
        Assert.False(result.Ok);
        Assert.Equal("two.localhost is not a site of this bench.", result.Problem);
    }
}
