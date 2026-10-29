using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

public class ToastPolicyTests
{
    private static BenchStatus Bench(BenchState state, string? reason = null, string path = "/home/a/frappe-bench", string name = "frappe-bench") =>
        new(name, path, state, reason, null, "a.localhost") { RawState = state.ToString().ToLowerInvariant() };

    private static TraySnapshot Snap(params BenchStatus[] benches) => new(benches);

    private static ToastPolicy Seeded(BenchStatus? first = null)
    {
        var policy = new ToastPolicy();
        Assert.Empty(policy.Observe(Snap(first ?? Bench(BenchState.Running))));
        return policy;
    }

    [Theory]
    [InlineData(BenchState.Crashed, null)]
    [InlineData(BenchState.Paused, "crash")]
    [InlineData(BenchState.Paused, "port_conflict")]
    [InlineData(BenchState.Paused, "broken")]
    public void AStateFoundAtLaunchOnlySeedsAndNeverToasts(BenchState state, string? reason)
    {
        var policy = new ToastPolicy();
        Assert.Empty(policy.Observe(Snap(Bench(state, reason))));
        Assert.Empty(policy.Observe(Snap(Bench(state, reason)))); // and it is not news a poll later either
    }

    [Fact]
    public void ACrashToastsOnceWithTheRestartLine()
    {
        var policy = Seeded();
        var toast = Assert.Single(policy.Observe(Snap(Bench(BenchState.Crashed, "crash"))));
        Assert.Equal("frappe-bench crashed", toast.Title);
        Assert.Equal("It restarts on its own in about 20 seconds.", toast.Body);
        Assert.Equal(AlertKind.Crashed, toast.Kind);
        Assert.Equal("/home/a/frappe-bench", toast.BenchPath);

        Assert.Empty(policy.Observe(Snap(Bench(BenchState.Crashed, "crash")))); // a poll that changed nothing
        Assert.Empty(policy.Observe(Snap(Bench(BenchState.Crashed, "crash"))));
    }

    [Fact]
    public void TheCrashGuardToastsWithUpAsTheFix()
    {
        var policy = Seeded();
        var toast = Assert.Single(policy.Observe(Snap(Bench(BenchState.Paused, "crash"))));
        Assert.Equal("frappe-bench paused after repeated crashes", toast.Title);
        Assert.Equal("benchbar up --bench-dir /home/a/frappe-bench", toast.Body);
    }

    [Fact]
    public void APortConflictToastsWithDoctorAsTheFix()
    {
        var policy = Seeded();
        var toast = Assert.Single(policy.Observe(Snap(Bench(BenchState.Paused, "port_conflict"))));
        Assert.Equal("frappe-bench has a port conflict", toast.Title);
        Assert.Equal("benchbar doctor --bench-dir /home/a/frappe-bench", toast.Body);
    }

    [Fact]
    public void ABrokenBenchToastsNeedsRepairWithDoctorAsTheFix()
    {
        var policy = Seeded();
        var toast = Assert.Single(policy.Observe(Snap(Bench(BenchState.Paused, "broken"))));
        Assert.Equal("frappe-bench needs repair", toast.Title);
        Assert.Equal("benchbar doctor --bench-dir /home/a/frappe-bench", toast.Body);
    }

    [Fact]
    public void AnUnknownAnswerNeverResetsTheMemory()
    {
        var policy = Seeded();
        Assert.Single(policy.Observe(Snap(Bench(BenchState.Crashed))));

        // the CLI did not answer for this bench, or at all, or the distro stopped
        Assert.Empty(policy.Observe(Snap(Bench(BenchState.Unknown))));
        Assert.Empty(policy.Observe(Snap()));
        Assert.Empty(policy.Observe(new TraySnapshot([], DistroStopped: true, Distro: "Ubuntu-24.04")));
        Assert.Empty(policy.Observe(new TraySnapshot([Bench(BenchState.Unknown)], Problem: "benchbar.exe was not found.")));

        Assert.Empty(policy.Observe(Snap(Bench(BenchState.Crashed)))); // crashed, unknown, crashed: one toast in all
    }

    [Fact]
    public void ACrashAfterARecoveryIsNewNews()
    {
        var policy = Seeded();
        Assert.Single(policy.Observe(Snap(Bench(BenchState.Crashed))));
        Assert.Empty(policy.Observe(Snap(Bench(BenchState.Running))));
        Assert.Single(policy.Observe(Snap(Bench(BenchState.Crashed))));
    }

    [Fact]
    public void CrashedToPausedIsAChangeAndToastsOnce()
    {
        var policy = Seeded();
        Assert.Single(policy.Observe(Snap(Bench(BenchState.Crashed))));
        var toast = Assert.Single(policy.Observe(Snap(Bench(BenchState.Paused, "crash"))));
        Assert.Equal(AlertKind.PausedAfterCrashes, toast.Kind);
        Assert.Empty(policy.Observe(Snap(Bench(BenchState.Paused, "crash"))));
    }

    [Fact]
    public void StoppingOrPausingWithoutAKnownReasonIsNotAnAlert()
    {
        var policy = Seeded();
        Assert.Empty(policy.Observe(Snap(Bench(BenchState.Stopped, "manual"))));
        Assert.Empty(policy.Observe(Snap(Bench(BenchState.Starting))));
        Assert.Empty(policy.Observe(Snap(Bench(BenchState.Paused, null))));
        Assert.Empty(policy.Observe(Snap(Bench(BenchState.Paused, "something_new"))));
    }

    [Fact]
    public void EachBenchHasItsOwnMemory()
    {
        var policy = Seeded();
        var a = Bench(BenchState.Crashed, path: "/a", name: "a");
        var b = Bench(BenchState.Running, path: "/b", name: "b");
        var toast = Assert.Single(policy.Observe(Snap(a, b)));
        Assert.Equal("a crashed", toast.Title);

        var toasts = policy.Observe(Snap(a, Bench(BenchState.Paused, "broken", path: "/b", name: "b")));
        Assert.Equal("b needs repair", Assert.Single(toasts).Title);
    }

    [Fact]
    public void ASettingTurnsToastsOffAndTurningThemOnLaterDoesNotReplayOldNews()
    {
        var policy = Seeded();
        policy.Enabled = false;
        Assert.Empty(policy.Observe(Snap(Bench(BenchState.Crashed))));
        policy.Enabled = true;
        Assert.Empty(policy.Observe(Snap(Bench(BenchState.Crashed))));
        Assert.Single(policy.Observe(Snap(Bench(BenchState.Paused, "crash"))));
    }

    [Fact]
    public void TheSeedWaitsForRealData()
    {
        var policy = new ToastPolicy();
        // launched with the distro stopped: nothing was learned, so the first real snapshot still only seeds
        Assert.Empty(policy.Observe(new TraySnapshot([], DistroStopped: true, Distro: "Ubuntu-24.04")));
        Assert.Empty(policy.Observe(Snap(Bench(BenchState.Crashed))));
        Assert.Single(policy.Observe(Snap(Bench(BenchState.Paused, "crash"))));
    }

    [Fact]
    public void APathWithSpacesIsQuotedInTheFix()
    {
        var policy = Seeded();
        var toast = Assert.Single(policy.Observe(Snap(Bench(BenchState.Paused, "crash", path: "/home/a/my bench"))));
        Assert.Equal("benchbar up --bench-dir '/home/a/my bench'", toast.Body);
    }
}
