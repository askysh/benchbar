using System.Globalization;
using BenchBar.Tray.Core;
using Xunit;
using static Tray.Core.Tests.CliFixture;

namespace Tray.Core.Tests;

/// <summary>
/// The sizes of the Sharing page (the free space the copy needs, the size in the plan summary) follow the culture of the person, not the
/// invariant one: "1,5 GB" under de-DE, "1.5 GB" under the invariant culture. The rest of the words do not depend on it.
/// </summary>
public class ShareCultureTests
{
    private static void Under(string culture, Action check)
    {
        var before = (CultureInfo.CurrentCulture, CultureInfo.CurrentUICulture);
        try
        {
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo(culture);
            check();
        }
        finally
        {
            (CultureInfo.CurrentCulture, CultureInfo.CurrentUICulture) = before;
        }
    }

    private static string Summary(double gb)
    {
        SynchronizationContext.SetSynchronizationContext(null);
        var (client, _) = Scripted();
        var model = new ShareModel(client, "/home/akash/frappe-bench");
        var plan = new ShareSetupPlan("one.localhost", gb, 3, null, new Dictionary<string, int> { ["User"] = 5 });
        return model.SetupReview(new ShareSetupRequest("one.localhost", ["a@example.com"], true, false), plan).Summary!;
    }

    [Fact]
    public void TheSizeNeededUsesTheCommaOfAGermanPc() => Under("de-DE", () =>
    {
        Assert.Equal("Needs about 1,5 GB free", ShareText.NeedsDisk(1.5));
        Assert.StartsWith("Makes a hardened copy of one.localhost in share.localhost, about 1,5 GB and 3 min.", Summary(1.5));
    });

    [Fact]
    public void TheSizeNeededUsesTheDotOfTheInvariantCulture() => Under("", () =>
    {
        Assert.Equal("Needs about 1.5 GB free", ShareText.NeedsDisk(1.5));
        Assert.StartsWith("Makes a hardened copy of one.localhost in share.localhost, about 1.5 GB and 3 min.", Summary(1.5));
    });

    [Fact]
    public void TheWholeNumbersAndTheCountsDoNotChangeWithTheCulture() => Under("de-DE", () =>
    {
        Assert.Equal("Needs about 12,0 GB free", ShareText.NeedsDisk(12));
        Assert.Equal("2 h 1 min", ShareText.Countdown(7260));
        Assert.Equal("Sharing on your network · 3 online · 59 min left", ShareText.Indicator(ShareStatus.Parse(Doc("share-status-on.json")) with { DevicesOnline = 3 }));
    });
}
