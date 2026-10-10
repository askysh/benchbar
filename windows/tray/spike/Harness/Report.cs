using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;

namespace BenchBar.Tray.Harness;

internal sealed class RunInfo
{
    public bool Quick { get; init; }
    public DateTimeOffset Started { get; init; } = DateTimeOffset.Now;
    public int RunsRest { get; init; }
    public int RunsCpu { get; init; }
    public int RunsClick { get; init; }
    public int RunsLogon { get; init; }
    public int RestSeconds { get; init; }
    public int CpuSeconds { get; init; }
    public int CpuWarmupSeconds { get; init; }
    public string ColdMethod { get; set; } = "not measured";
    public bool Interrupted { get; set; }
}

internal static class Report
{
    public const string ClickNote = "the shell's own open flyout entry point over the harness pipe; a synthesized click is not used because Windows 11 puts a new icon in the overflow area";
    public const string PublishNote = "self contained, ReadyToRun, not trimmed, x64 for the measured builds (winui-sc, wpf-sc); framework dependent builds are sized only";

    private static string F(double v, string format) => v.ToString(format, CultureInfo.InvariantCulture);

    public static Dictionary<string, string> MachineInfo()
    {
        string cpu = "unknown";
        try
        {
            using RegistryKey? k = Registry.LocalMachine.OpenSubKey(@"HARDWARE\DESCRIPTION\System\CentralProcessor\0");
            cpu = (k?.GetValue("ProcessorNameString") as string)?.Trim() ?? cpu;
        }
        catch (Exception)
        {
            // Keep "unknown".
        }

        var mem = new Native.MemoryStatusEx { Length = (uint)Marshal.SizeOf<Native.MemoryStatusEx>() };
        string ram = Native.GlobalMemoryStatusEx(ref mem) ? F(mem.TotalPhys / 1073741824.0, "0.0") + " GB" : "unknown";
        uint dpi = Native.GetDpiForSystem();

        return new Dictionary<string, string>
        {
            ["cpu"] = cpu,
            ["logical_cores"] = Environment.ProcessorCount.ToString(CultureInfo.InvariantCulture),
            ["ram"] = ram,
            ["os"] = RuntimeInformation.OSDescription,
            ["os_build"] = Environment.OSVersion.Version.ToString(),
            ["primary_monitor_dpi"] = dpi.ToString(CultureInfo.InvariantCulture),
            ["elevated"] = ColdCache.IsElevated() ? "true" : "false",
            ["dotnet_runtime"] = RuntimeInformation.FrameworkDescription,
        };
    }

    // ---------- JSON ----------

    public static void WriteJson(string path, RunInfo info, Dictionary<string, string> machine, IReadOnlyList<ShellResults> shells, string verdictOutcome)
    {
        using var stream = File.Create(path);
        using var w = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true });
        w.WriteStartObject();
        w.WriteBoolean("quick", info.Quick);
        w.WriteBoolean("interrupted", info.Interrupted);
        w.WriteString("started", info.Started);

        w.WriteStartObject("machine");
        foreach ((string k, string v) in machine) w.WriteString(k, v);
        w.WriteEndObject();

        w.WriteStartObject("method");
        w.WriteString("cold_method", info.ColdMethod);
        w.WriteString("click_method", ClickNote);
        w.WriteString("publish_mode", PublishNote);
        w.WriteNumber("runs_rest", info.RunsRest);
        w.WriteNumber("runs_cpu", info.RunsCpu);
        w.WriteNumber("runs_click", info.RunsClick);
        w.WriteNumber("runs_logon", info.RunsLogon);
        w.WriteNumber("rest_seconds", info.RestSeconds);
        w.WriteNumber("cpu_seconds", info.CpuSeconds);
        w.WriteNumber("cpu_warmup_seconds", info.CpuWarmupSeconds);
        w.WriteEndObject();

        w.WriteStartObject("shells");
        foreach (ShellResults s in shells)
        {
            w.WriteStartObject(s.Name);
            w.WriteString("exe", s.Exe);
            WriteSize(w, "size_sc", s.Size);
            WriteSize(w, "size_fd", s.FdSize);
            WriteDoubles(w, "private_bytes", s.PrivateBytes);
            WriteDoubles(w, "working_set_bytes", s.WorkingSetBytes);
            WriteDoubles(w, "cpu_percent", s.CpuPercent);
            WriteDoubles(w, "achieved_fps", s.AchievedFps);
            w.WriteStartArray("click");
            foreach (ClickSample c in s.Clicks)
            {
                w.WriteStartObject();
                w.WriteNumber("ms", c.Ms);
                w.WriteBoolean("cold", c.Cold);
                w.WriteEndObject();
            }
            w.WriteEndArray();
            WriteDoubles(w, "logon_warm_ms", s.LogonWarmMs);
            WriteDoubles(w, "logon_cold_ms", s.LogonColdMs);

            w.WriteStartObject("median");
            WriteMedian(w, "private_bytes", s.Rest);
            WriteMedian(w, "working_set_bytes", s.WorkingSet);
            WriteMedian(w, "cpu_percent", s.Cpu);
            WriteMedian(w, "click_ms", s.Click);
            WriteMedian(w, "logon_warm_ms", s.LogonWarm);
            WriteMedian(w, "logon_cold_ms", s.LogonCold);
            w.WriteEndObject();

            w.WriteStartArray("failures");
            foreach (string f in s.Failures) w.WriteStringValue(f);
            w.WriteEndArray();
            w.WriteEndObject();
        }
        w.WriteEndObject();

        w.WriteString("verdict", verdictOutcome);
        w.WriteEndObject();
    }

    private static void WriteDoubles(Utf8JsonWriter w, string name, List<double> values)
    {
        w.WriteStartArray(name);
        foreach (double v in values) w.WriteNumberValue(v);
        w.WriteEndArray();
    }

    private static void WriteMedian(Utf8JsonWriter w, string name, Summary? s)
    {
        if (s is null) w.WriteNull(name);
        else w.WriteNumber(name, s.Median);
    }

    private static void WriteSize(Utf8JsonWriter w, string name, DirSize? size)
    {
        if (size is null)
        {
            w.WriteNull(name);
            return;
        }
        w.WriteStartObject(name);
        w.WriteString("dir", size.Dir);
        w.WriteNumber("bytes", size.Bytes);
        w.WriteNumber("files", size.Files);
        w.WriteEndObject();
    }

    // ---------- Markdown ----------

    public static string Markdown(RunInfo info, Dictionary<string, string> machine, IReadOnlyList<ShellResults> shells, List<string> verdictLines)
    {
        var sb = new StringBuilder();
        sb.AppendLine("# Windows tray shell spike: results");
        sb.AppendLine();
        if (info.Quick)
            sb.AppendLine("> Quick smoke run (few runs, short windows). Not for the decision.").AppendLine();
        if (info.Interrupted)
            sb.AppendLine("> Interrupted: only the samples taken before the interrupt are listed.").AppendLine();

        sb.AppendLine("## Verdict").AppendLine();
        sb.AppendLine("Rule (windows/tray/DECISIONS.md): choose the shell with the lower private bytes at rest and CPU while animating, unless click to flyout is above 150 ms or logon to icon is above 2 s for that shell. A difference under 10% of the larger value is a tie. On an overall tie, deployment friction: decided by the lead.");
        sb.AppendLine();
        sb.AppendLine("The gate uses the median over the warm opens for click to flyout (the cold first open is listed apart and does not gate), and the cold median for logon to icon when it was measured, else the warm one.");
        sb.AppendLine();
        foreach (string line in verdictLines) sb.AppendLine(line);
        sb.AppendLine();

        sb.AppendLine("## Machine").AppendLine();
        foreach ((string k, string v) in machine) sb.AppendLine($"- {k}: {v}");
        sb.AppendLine();

        sb.AppendLine("## Method").AppendLine();
        sb.AppendLine($"- Publish mode: {PublishNote}.");
        sb.AppendLine($"- Click to flyout: {ClickNote}.");
        sb.AppendLine($"- Logon to icon, cold: {info.ColdMethod}.");
        sb.AppendLine("- Logon to icon, warm: QPC before Process.Start to QPC when Shell_NotifyIcon(NIM_ADD) returned success, reported by the shell.");
        sb.AppendLine($"- Runs: rest {info.RunsRest} x {info.RestSeconds} s, cpu {info.RunsCpu} x {info.CpuSeconds} s after a {info.CpuWarmupSeconds} s warm up, click {info.RunsClick} opens per shell, logon {info.RunsLogon} warm and {info.RunsLogon} cold. Rest, cpu and logon runs alternate the shells run by run; the click opens are one session per shell, WinUI then WPF. Private bytes are read the rest time after icon-added. Medians use the mean of the two middle values for an even count.");
        sb.AppendLine();

        string Row(Func<ShellResults, Summary?> pick, Func<double, string> fmt, Func<ShellResults, string> first)
        {
            var rows = new StringBuilder();
            foreach (ShellResults s in shells)
            {
                Summary? m = pick(s);
                rows.AppendLine(m is null
                    ? $"| {s.Name} | - | - | - | 0 |{first(s)}"
                    : $"| {s.Name} | {fmt(m.Median)} | {fmt(m.Min)} | {fmt(m.Max)} | {m.N} |{first(s)}");
            }
            return rows.ToString();
        }
        string Mb(double b) => F(b / 1048576.0, "0.0");
        const string Head = "| Shell | median | min | max | n |";

        sb.AppendLine("## Private bytes at rest (MB)").AppendLine();
        sb.AppendLine(Head).AppendLine("|---|---|---|---|---|");
        sb.Append(Row(s => s.Rest, Mb, _ => ""));
        sb.AppendLine();

        sb.AppendLine("## Working set at rest (MB)").AppendLine();
        sb.AppendLine(Head).AppendLine("|---|---|---|---|---|");
        sb.Append(Row(s => s.WorkingSet, Mb, _ => ""));
        sb.AppendLine();

        sb.AppendLine("## CPU while animating (% of one core)").AppendLine();
        sb.AppendLine(Head).AppendLine("|---|---|---|---|---|");
        sb.Append(Row(s => s.Cpu, v => F(v, "0.00"), _ => ""));
        sb.AppendLine();

        sb.AppendLine("## Achieved frame rate while animating (frames per second, target 30)").AppendLine();
        sb.AppendLine(Head).AppendLine("|---|---|---|---|---|");
        sb.Append(Row(s => s.Fps, v => F(v, "0.0"), _ => ""));
        sb.AppendLine();

        sb.AppendLine("## Click to flyout (ms)").AppendLine();
        sb.AppendLine(Head.TrimEnd() + " first open (cold) |").AppendLine("|---|---|---|---|---|---|");
        sb.Append(Row(s => s.Click, v => F(v, "0.0"), s =>
            s.Clicks.Count == 0 ? " - |" : $" {F(s.Clicks[0].Ms, "0.0")}{(s.Clicks[0].Cold ? "" : " (not reported cold)")} |"));
        sb.AppendLine();

        sb.AppendLine("## Logon to icon, warm (ms)").AppendLine();
        sb.AppendLine(Head).AppendLine("|---|---|---|---|---|");
        sb.Append(Row(s => s.LogonWarm, v => F(v, "0"), _ => ""));
        sb.AppendLine();

        sb.AppendLine($"## Logon to icon, cold (ms), method: {info.ColdMethod}").AppendLine();
        sb.AppendLine(Head).AppendLine("|---|---|---|---|---|");
        sb.Append(Row(s => s.LogonCold, v => F(v, "0"), _ => ""));
        sb.AppendLine();

        sb.AppendLine("## Size on disk").AppendLine();
        sb.AppendLine("| Shell | self contained (sc) MB | files | framework dependent (fd) MB | files |").AppendLine("|---|---|---|---|---|");
        foreach (ShellResults s in shells)
        {
            string sc = s.Size is null ? "- | -" : $"{Mb(s.Size.Bytes)} | {s.Size.Files}";
            string fd = s.FdSize is null ? "- | -" : $"{Mb(s.FdSize.Bytes)} | {s.FdSize.Files}";
            sb.AppendLine($"| {s.Name} | {sc} | {fd} |");
        }
        sb.AppendLine();

        sb.AppendLine("## Failures").AppendLine();
        bool any = false;
        foreach (ShellResults s in shells)
        {
            foreach (string f in s.Failures)
            {
                sb.AppendLine($"- {s.Name}: {f}");
                any = true;
            }
        }
        if (!any) sb.AppendLine("None.");
        return sb.ToString();
    }
}
