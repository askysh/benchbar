using System.Diagnostics;
using System.Globalization;

namespace BenchBar.Tray.Harness;

internal static class Program
{
    private const string Usage = """
        BenchBarTray.Harness: measures the WinUI and WPF tray shells of the Windows tray spike.

          measure     --winui <exe> --wpf <exe> --fixtures <dir> --out <dir>
                      [--winui-dir <dir>] [--wpf-dir <dir>] [--winui-fd-dir <dir>] [--wpf-fd-dir <dir>]
                      [--runs-rest 5] [--runs-cpu 5] [--runs-click 20] [--runs-logon 5]
                      [--rest-seconds 60] [--cpu-seconds 60] [--quick]
          screenshots --winui <exe> --wpf <exe> --fixtures <dir> --out <dir>

        --quick: 2 runs, 10 second windows, 5 clicks (a smoke test).
        The fixtures folder holds the scenario folders rest, load and crash.
        """;

    private static readonly CancellationTokenSource Interrupt = new();

    private static async Task<int> Main(string[] args)
    {
        Screen.MakeDpiAware();
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            Interrupt.Cancel();
            ShellRun.KillAll();
        };
        AppDomain.CurrentDomain.ProcessExit += (_, _) => ShellRun.KillAll();

        Options opts;
        try
        {
            opts = Options.Parse(args);
        }
        catch (ArgumentException ex)
        {
            Console.Error.WriteLine(ex.Message);
            Console.Error.WriteLine(Usage);
            return 2;
        }

        try
        {
            return opts.Command switch
            {
                "measure" => await new Measure(opts, Interrupt.Token).RunAsync(),
                "screenshots" => await new Screenshots(opts, Interrupt.Token).RunAsync(),
                _ => Fail($"unknown command '{opts.Command}'"),
            };
        }
        catch (ArgumentException ex)
        {
            return Fail(ex.Message);
        }
        finally
        {
            ShellRun.KillAll();
        }
    }

    private static int Fail(string message)
    {
        Console.Error.WriteLine(message);
        Console.Error.WriteLine(Usage);
        return 2;
    }
}

internal sealed class Options
{
    private static readonly HashSet<string> Flags = ["quick"];

    private readonly Dictionary<string, string> _values = new(StringComparer.Ordinal);
    private readonly HashSet<string> _flags = [];

    public string Command { get; private init; } = "";
    public bool Quick => _flags.Contains("quick");

    public static Options Parse(string[] args)
    {
        if (args.Length == 0) throw new ArgumentException("no command given");
        var o = new Options { Command = args[0] };
        for (int i = 1; i < args.Length; i++)
        {
            string a = args[i];
            if (!a.StartsWith("--", StringComparison.Ordinal)) throw new ArgumentException($"unexpected argument '{a}'");
            string name = a[2..];
            if (Flags.Contains(name))
            {
                o._flags.Add(name);
                continue;
            }
            if (i + 1 >= args.Length) throw new ArgumentException($"option '{a}' needs a value");
            o._values[name] = args[++i];
        }
        return o;
    }

    public string? Get(string name) => _values.GetValueOrDefault(name);

    public string Require(string name) =>
        Get(name) ?? throw new ArgumentException($"missing required option --{name}");

    public int Int(string name, int fallback)
    {
        string? v = Get(name);
        if (v is null) return fallback;
        if (!int.TryParse(v, NumberStyles.None, CultureInfo.InvariantCulture, out int n) || n < 1)
            throw new ArgumentException($"option --{name} needs a positive integer, got '{v}'");
        return n;
    }
}

/// <summary>Shared by the two commands: argument checks and the start-up handshake.</summary>
internal abstract class ShellCommand
{
    protected readonly CancellationToken Ct;
    protected readonly string FixturesRoot;
    protected readonly string OutDir;
    protected readonly ShellResults[] Shells;

    protected ShellCommand(Options o, CancellationToken ct)
    {
        Ct = ct;
        FixturesRoot = Path.GetFullPath(o.Require("fixtures"));
        OutDir = Path.GetFullPath(o.Require("out"));
        string winui = Path.GetFullPath(o.Require("winui"));
        string wpf = Path.GetFullPath(o.Require("wpf"));
        foreach (string exe in new[] { winui, wpf })
        {
            if (!File.Exists(exe)) throw new ArgumentException($"shell not found: {exe}");
        }
        if (!Directory.Exists(FixturesRoot)) throw new ArgumentException($"fixtures folder not found: {FixturesRoot}");

        Shells =
        [
            new ShellResults("WinUI", winui, DirOf(o, "winui-dir", winui), Dir(o, "winui-fd-dir")),
            new ShellResults("WPF", wpf, DirOf(o, "wpf-dir", wpf), Dir(o, "wpf-fd-dir")),
        ];
    }

    private static string? Dir(Options o, string name) => o.Get(name) is { } d ? Path.GetFullPath(d) : null;

    private static string DirOf(Options o, string name, string exe) =>
        Dir(o, name) ?? Path.GetDirectoryName(exe)!;

    protected string Scenario(string name)
    {
        string dir = Path.Combine(FixturesRoot, name);
        if (!Directory.Exists(dir)) throw new ArgumentException($"scenario folder not found: {dir}");
        return dir;
    }

    protected static void Log(string text) =>
        Console.WriteLine($"[{DateTime.Now:HH:mm:ss}] {text}");

    /// <summary>Waits for hello and icon-added. Returns the icon-added QPC, or null after recording a failure.</summary>
    protected async Task<long?> ReadyAsync(ShellRun run, ShellResults s, string what)
    {
        var timeout = TimeSpan.FromSeconds(30);
        Msg? hello = await run.WaitForAsync("hello", timeout, Ct);
        if (hello is null)
        {
            s.Failures.Add($"{what}: {run.WhyNot("hello", Ct)}");
            return null;
        }
        Msg? icon = await run.WaitForAsync("icon-added", timeout, Ct);
        if (icon?.GetLong("qpc") is not { } qpc)
        {
            s.Failures.Add($"{what}: {(icon is null ? run.WhyNot("icon-added", Ct) : "icon-added without qpc")}");
            return null;
        }
        return qpc;
    }

    protected static double QpcMs(long from, long to) => (to - from) * 1000.0 / Stopwatch.Frequency;
}

internal sealed class Measure : ShellCommand
{
    private readonly RunInfo _info;

    public Measure(Options o, CancellationToken ct) : base(o, ct)
    {
        bool q = o.Quick;
        _info = new RunInfo
        {
            Quick = q,
            RunsRest = o.Int("runs-rest", q ? 2 : 5),
            RunsCpu = o.Int("runs-cpu", q ? 2 : 5),
            RunsClick = o.Int("runs-click", q ? 5 : 20),
            RunsLogon = o.Int("runs-logon", q ? 2 : 5),
            RestSeconds = o.Int("rest-seconds", q ? 10 : 60),
            CpuSeconds = o.Int("cpu-seconds", q ? 10 : 60),
            CpuWarmupSeconds = q ? 3 : 10,
        };
        _ = Scenario("rest");
        _ = Scenario("load");
    }

    public async Task<int> RunAsync()
    {
        Directory.CreateDirectory(OutDir);
        foreach (ShellResults s in Shells)
        {
            s.Size = Stats.Measure(s.Dir);
            s.FdSize = Stats.Measure(s.FdDir);
        }

        try
        {
            await RunRest();
            await RunCpu();
            foreach (ShellResults s in Shells) await RunClick(s);
            await RunLogon(cold: false);
            await RunLogon(cold: true);
        }
        catch (OperationCanceledException)
        {
            _info.Interrupted = true;
            Log("interrupted, writing what was measured");
        }

        WriteReports();
        bool failed = _info.Interrupted || Shells.Any(s => s.Failures.Count > 0);
        Log(failed ? "finished with failures" : "finished");
        return failed ? 1 : 0;
    }

    private void WriteReports()
    {
        var machine = Report.MachineInfo();
        (List<string> lines, string outcome) = Verdict.Apply(Shells[0], Shells[1]);
        Report.WriteJson(Path.Combine(OutDir, "results.json"), _info, machine, Shells, outcome);
        File.WriteAllText(Path.Combine(OutDir, "results.md"), Report.Markdown(_info, machine, Shells, lines));
        Log($"wrote {Path.Combine(OutDir, "results.md")} and results.json");
    }

    private async Task RunRest()
    {
        for (int i = 1; i <= _info.RunsRest; i++)
        {
            foreach (ShellResults s in Shells)
            {
                string what = $"rest run {i}";
                Log($"{s.Name} {what}");
                using var run = new ShellRun(s.Name, s.Exe, Scenario("rest"), null);
                run.Start();
                if (await ReadyAsync(run, s, what) is null) continue;
                await Task.Delay(TimeSpan.FromSeconds(_info.RestSeconds), Ct);
                if (run.HasExited)
                {
                    s.Failures.Add($"{what}: shell exited during the rest window");
                    continue;
                }
                run.Process.Refresh();
                s.PrivateBytes.Add(run.Process.PrivateMemorySize64);
                s.WorkingSetBytes.Add(run.Process.WorkingSet64);
                run.Quit();
            }
        }
    }

    private async Task RunCpu()
    {
        for (int i = 1; i <= _info.RunsCpu; i++)
        {
            foreach (ShellResults s in Shells)
            {
                string what = $"cpu run {i}";
                Log($"{s.Name} {what}");
                using var run = new ShellRun(s.Name, s.Exe, Scenario("load"), null);
                run.Start();
                if (await ReadyAsync(run, s, what) is null) continue;
                await Task.Delay(TimeSpan.FromSeconds(_info.CpuWarmupSeconds), Ct);
                try
                {
                    run.Process.Refresh();
                    TimeSpan t1 = run.Process.TotalProcessorTime;
                    long w1 = Stopwatch.GetTimestamp();
                    await Task.Delay(TimeSpan.FromSeconds(_info.CpuSeconds), Ct);
                    run.Process.Refresh();
                    TimeSpan t2 = run.Process.TotalProcessorTime;
                    long w2 = Stopwatch.GetTimestamp();
                    s.CpuPercent.Add((t2 - t1).TotalMilliseconds / QpcMs(w1, w2) * 100.0);
                }
                catch (InvalidOperationException)
                {
                    s.Failures.Add($"{what}: shell exited during the cpu window");
                    continue;
                }
                run.Quit();
            }
        }
    }

    private async Task RunClick(ShellResults s)
    {
        Log($"{s.Name} click session, {_info.RunsClick} opens");
        const string what = "click session";
        using var run = new ShellRun(s.Name, s.Exe, Scenario("rest"), null);
        run.Start();
        if (await ReadyAsync(run, s, what) is null) return;
        await Task.Delay(TimeSpan.FromSeconds(3), Ct);

        for (int i = 1; i <= _info.RunsClick; i++)
        {
            long t0 = Stopwatch.GetTimestamp();
            run.Send("open-flyout");
            Msg? rendered = await run.WaitForAsync("flyout-rendered", TimeSpan.FromSeconds(10), Ct);
            if (rendered?.GetLong("qpc") is not { } qpc)
            {
                // A late reply would skew the next sample, so the session ends here.
                s.Failures.Add($"{what}, open {i}: {(rendered is null ? run.WhyNot("flyout-rendered", Ct) : "flyout-rendered without qpc")}");
                return;
            }
            s.Clicks.Add(new ClickSample(QpcMs(t0, qpc), rendered.Get("cold") == "true"));

            run.Send("hide-flyout");
            if (await run.WaitForAsync("flyout-hidden", TimeSpan.FromSeconds(5), Ct) is null)
            {
                s.Failures.Add($"{what}, open {i}: {run.WhyNot("flyout-hidden", Ct)}");
                return;
            }
            await Task.Delay(500, Ct);
        }
        run.Quit();
    }

    private async Task RunLogon(bool cold)
    {
        string kind = cold ? "cold" : "warm";
        for (int i = 1; i <= _info.RunsLogon; i++)
        {
            foreach (ShellResults s in Shells)
            {
                string what = $"logon {kind} run {i}";
                Log($"{s.Name} {what}");
                if (cold) _info.ColdMethod = ColdCache.Prepare();
                using var run = new ShellRun(s.Name, s.Exe, Scenario("rest"), null);
                long t0 = run.Start();
                if (await ReadyAsync(run, s, what) is not { } icon) continue;
                (cold ? s.LogonColdMs : s.LogonWarmMs).Add(QpcMs(t0, icon));
                run.Quit();
            }
        }
    }
}

internal sealed class Screenshots(Options o, CancellationToken ct) : ShellCommand(o, ct)
{
    public async Task<int> RunAsync()
    {
        Directory.CreateDirectory(OutDir);
        string rest = Scenario("rest");
        bool failed = false;
        try
        {
            foreach (ShellResults s in Shells)
            {
                foreach (string theme in new[] { "light", "dark" })
                {
                    string what = $"screenshot {theme}";
                    Log($"{s.Name} {what}");
                    using var run = new ShellRun(s.Name, s.Exe, rest, theme);
                    run.Start();
                    if (await ReadyAsync(run, s, what) is null) continue;

                    run.Send("open-flyout");
                    Msg? rendered = await run.WaitForAsync("flyout-rendered", TimeSpan.FromSeconds(10), Ct);
                    if (rendered is null)
                    {
                        s.Failures.Add($"{what}: {run.WhyNot("flyout-rendered", Ct)}");
                        continue;
                    }
                    await Task.Delay(700, Ct);

                    if (!TryRect(rendered.Get("rect"), out int l, out int t, out int w, out int h))
                    {
                        s.Failures.Add($"{what}: bad rect '{rendered.Get("rect")}'");
                        continue;
                    }
                    byte[]? pixels = Screen.Capture(l, t, w, h);
                    if (pixels is null)
                    {
                        s.Failures.Add($"{what}: screen capture failed");
                        continue;
                    }
                    string file = Path.Combine(OutDir, $"flyout-{s.Name.ToLowerInvariant()}-{theme}.png");
                    Png.WriteBgra(file, w, h, pixels);
                    Log($"wrote {file} ({w}x{h})");
                    run.Quit();
                }
            }
        }
        catch (OperationCanceledException)
        {
            Log("interrupted");
            failed = true;
        }

        foreach (ShellResults s in Shells)
        {
            foreach (string f in s.Failures)
            {
                Console.Error.WriteLine($"{s.Name}: {f}");
                failed = true;
            }
        }
        return failed ? 1 : 0;
    }

    private static bool TryRect(string? text, out int left, out int top, out int width, out int height)
    {
        left = top = width = height = 0;
        string[] p = (text ?? "").Split(',');
        if (p.Length != 4) return false;
        var v = new int[4];
        for (int i = 0; i < 4; i++)
        {
            if (!int.TryParse(p[i], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out v[i])) return false;
        }
        left = v[0];
        top = v[1];
        width = v[2] - v[0];
        height = v[3] - v[1];
        return width is > 0 and <= 8000 && height is > 0 and <= 8000;
    }
}
