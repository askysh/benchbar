using System.Windows.Threading;
using BenchBar.Tray.Core;

namespace BenchBar.Tray.Wpf;

/// <summary>One pending one shot callback on a WPF DispatcherTimer (Stop, set Interval, Start).</summary>
internal sealed class DispatcherFrameClock : IFrameClock
{
    private readonly DispatcherTimer _timer = new(DispatcherPriority.Normal);
    private Action? _tick;

    public DispatcherFrameClock() => _timer.Tick += OnTick;

    public void Schedule(TimeSpan delay, Action tick)
    {
        _timer.Stop();
        _tick = tick;
        _timer.Interval = delay <= TimeSpan.Zero ? TimeSpan.FromMilliseconds(1) : delay;
        _timer.Start();
    }

    public void Cancel()
    {
        _timer.Stop();
        _tick = null;
    }

    private void OnTick(object? sender, EventArgs e)
    {
        _timer.Stop();
        var tick = _tick;
        _tick = null;
        tick?.Invoke();
    }
}
