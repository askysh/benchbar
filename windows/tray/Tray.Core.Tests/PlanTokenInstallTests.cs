using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>
/// UI-15 on Windows (part of #164, builds on #315): the install the person reviewed runs with <c>--apply TOKEN</c>; a stale refusal
/// changed nothing and goes back to Review; a retry after a failure passes no token; an older CLI without a token keeps the old call.
/// </summary>
public class PlanTokenInstallTests
{
    private const string PlanToken = "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd";

    private sealed class Capturing(FixtureSetupService inner) : DelegatingSetup(inner)
    {
        public List<string?> Tokens { get; } = [];

        public Func<InstallRequest, InstallRunResult?>? Replace { get; set; }

        public Func<InstallPlan, InstallPlan> Plan { get; set; } = p => p;

        public override async Task<PlanResult> PlanInstallAsync(InstallRequest request, Secret admin, CancellationToken ct)
        {
            var result = await base.PlanInstallAsync(request, admin, ct);
            return result.Plan is { } plan ? result with { Plan = Plan(plan) } : result;
        }

        public override Task<InstallRunResult> InstallAsync(InstallRequest request, InstallSecrets secrets, Action<InstallEvent> onEvent, CancellationToken ct)
        {
            Tokens.Add(request.ApplyToken);
            if (Replace?.Invoke(request) is { } replaced)
            {
                if (replaced.Done is { } done) onEvent(new InstallEvent.Done(done));
                return Task.FromResult(replaced);
            }
            return base.InstallAsync(request, secrets, onEvent, ct);
        }
    }

    private static InstallRunResult Stale()
    {
        var done = new InstallDone(1, null, null, null, [], "Review a fresh plan: benchbar install --dry-run --json, then pass its token.", null,
            "The install plan changed since it was shown. Nothing was changed.", null);
        return new InstallRunResult(1, done, null);
    }

    private static async Task<(WizardModel Model, Capturing Setup)> ReviewedAsync()
    {
        var fixture = new SetupFixture();
        fixture.Check("check.json", ready: true);
        var setup = new Capturing(fixture.Service);
        var model = new WizardModel(setup, new FakeWizardHost());
        await model.ChooseNewBench();
        await model.ContinueFromCheckAsync();
        model.SetAdminPassword(Secret.From("admin-pass"));
        await model.ReviewAsync();
        model.SetPassword(Secret.From("linux-pass"));
        return (model, setup);
    }

    [Fact]
    public void ThePlanLineTokenIsRead()
    {
        var line = File.ReadAllLines(Path.Combine(Fixtures.Dir("setup"), "plan.jsonl"))[0];
        var plan = ((InstallEvent.Plan)InstallJson.ParseLine(line)!).Value;
        Assert.Equal(PlanToken, plan.Token);
    }

    [Fact]
    public async Task TheInstallPassesTheTokenOfTheReviewedPlan()
    {
        var stream = new RecordingStream { Lines = File.ReadAllLines(Path.Combine(Fixtures.Dir("setup"), "install.jsonl")) };
        var request = new InstallRequest("/home/a/b", "v15-lts", "minimal", "linuxdev.localhost") { ApplyToken = PlanToken };
        await Service(stream).InstallAsync(request, new InstallSecrets(Secret.From("a"), Secret.From("b")), _ => { }, CancellationToken.None);
        Assert.Equal(["install", "--yes", "--json", "--apply", PlanToken, "--bench-dir", "/home/a/b", "--profile", "v15-lts", "--bundle", "minimal", "--site", "linuxdev.localhost"], stream.Runs[0].Args);
        Assert.DoesNotContain(request.Flags, a => a == "--apply"); // the plan call never carries it
    }

    [Fact]
    public async Task WithoutATokenTheCallIsTheOldOne()
    {
        var stream = new RecordingStream { Lines = File.ReadAllLines(Path.Combine(Fixtures.Dir("setup"), "install.jsonl")) };
        await Service(stream).InstallAsync(new InstallRequest("/home/a/b", "v15-lts", "minimal", "s.localhost"), new InstallSecrets(Secret.From("a"), Secret.From("b")), _ => { }, CancellationToken.None);
        Assert.Equal(["install", "--yes", "--json", "--bench-dir", "/home/a/b", "--profile", "v15-lts", "--bundle", "minimal", "--site", "s.localhost"], stream.Runs[0].Args);
    }

    [Fact]
    public async Task TheFirstRunFromReviewCarriesTheToken()
    {
        var (model, setup) = await ReviewedAsync();
        await model.StartInstallAsync();
        Assert.Equal(InstallPhase.Succeeded, model.Phase);
        Assert.Equal([PlanToken], setup.Tokens);
    }

    [Fact]
    public async Task AnOlderCliWithoutATokenKeepsTheOldCall()
    {
        var (model, setup) = await ReviewedAsync();
        setup.Plan = p => p with { Token = null };
        // ReviewAsync only runs from New Bench: go back and ask again
        model.Back();
        await model.ReviewAsync();
        await model.StartInstallAsync();
        Assert.Equal([(string?)null], setup.Tokens);
    }

    [Fact]
    public async Task AStaleRefusalGoesBackToReviewWithNothingChangedAndReviewAgainAsksForANewPlan()
    {
        var (model, setup) = await ReviewedAsync();
        setup.Replace = _ => setup.Tokens.Count == 1 ? Stale() : null;

        await model.StartInstallAsync();

        Assert.Equal(WizardPage.Review, model.Page);
        Assert.Equal(InstallPhase.Idle, model.Phase);
        Assert.Null(model.Failure);
        Assert.Null(model.Plan);
        Assert.False(model.CanInstall);
        Assert.Contains("Nothing was changed", model.StaleMessage);
        Assert.True(model.CanReviewAgain);

        await model.ReviewAgainAsync();
        Assert.Equal(WizardPage.Review, model.Page);
        Assert.Null(model.StaleMessage);
        Assert.NotNull(model.Plan);
        Assert.True(model.CanInstall);

        await model.StartInstallAsync();
        Assert.Equal(InstallPhase.Succeeded, model.Phase);
        Assert.Equal([PlanToken, PlanToken], setup.Tokens);
    }

    [Fact]
    public async Task ARetryAfterAFailedInstallPassesNoToken()
    {
        var (model, setup) = await ReviewedAsync();
        var failed = new InstallDone(1, null, null, null, [], null, null, "apt failed", null);
        setup.Replace = _ => setup.Tokens.Count == 1 ? new InstallRunResult(1, failed, null) : null;

        await model.StartInstallAsync();
        Assert.Equal(InstallPhase.Failed, model.Phase);
        Assert.Null(model.StaleMessage);

        await model.RetryAsync();
        Assert.Equal(InstallPhase.Succeeded, model.Phase);
        Assert.Equal([PlanToken, null], setup.Tokens);
    }

    [Fact]
    public async Task AStaleLookingLineOnARetryIsAnOrdinaryFailure()
    {
        var (model, setup) = await ReviewedAsync();
        var failed = new InstallDone(1, null, null, null, [], null, null, "apt failed", null);
        setup.Replace = _ => setup.Tokens.Count == 1 ? new InstallRunResult(1, failed, null) : Stale();
        await model.StartInstallAsync();
        await model.RetryAsync();
        Assert.Equal(WizardPage.Install, model.Page);
        Assert.Equal(InstallPhase.Failed, model.Phase);
        Assert.Null(model.StaleMessage);
    }

    private static ShimSetupService Service(RecordingStream stream) => new(new CapturingProcessRunner(), stream, () => @"C:\x\benchbar.exe");
}
