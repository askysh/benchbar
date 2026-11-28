using System.Windows.Threading;
using BenchBar.Tray.Core;
using Xunit;
using static BenchBar.Tray.Tests.PageKit;

namespace BenchBar.Tray.Tests;

/// <summary>
/// The guest model tells the Sharing tab that it changed from whatever thread its call ended on. When the window is gone and its dispatcher
/// has shut down, that must not throw into the model's caller.
/// </summary>
public class SharingDispatcherTests
{
    [Fact]
    public void AChangeThatArrivesAfterTheDispatcherShutDownIsDroppedAndThrowsNothing() => Sta.Run(() =>
    {
        var kit = new PageKit();
        var guest = new ShareGuestModel(kit.Services.Cli, kit.Services.Commands);
        var view = new SharingView(kit.Services, bench => new ShareModel(kit.Services.Cli, bench), () => guest);
        view.Bind(new BenchContext(Bench(), null));
        Wait(view.Pending);

        Dispatcher.CurrentDispatcher.InvokeShutdown();
        Assert.True(Dispatcher.CurrentDispatcher.HasShutdownStarted);

        // a call that ended on a pool thread after the window closed raises Changed there
        var raised = Task.Run(guest.ClearLook);
        Assert.True(raised.Wait(TimeSpan.FromSeconds(10)), "the change was not delivered or dropped in time");
        Assert.True(raised.IsCompletedSuccessfully);
    });
}
