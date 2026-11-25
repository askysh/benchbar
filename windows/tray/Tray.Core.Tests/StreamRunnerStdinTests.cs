using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>
/// The line that <see cref="SystemStreamRunner"/> sends on stdin, through a real child process (Windows PowerShell, which every Windows runner has;
/// no WSL): the exact bytes, and a child that ends without reading. The scripted runner of the other tests records a string, so it cannot see a
/// carriage return that the platform's line end adds.
/// </summary>
public class StreamRunnerStdinTests
{
    private static readonly TimeSpan Limit = TimeSpan.FromSeconds(60);

    private static string PowerShell() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");

    /// <summary>A child that copies its stdin to memory and prints the bytes as lower case hex, so the test sees every byte and not a decoded text.</summary>
    private static readonly string[] EchoBytes =
    [
        "-NoProfile", "-NonInteractive", "-Command",
        "$m = New-Object IO.MemoryStream; [Console]::OpenStandardInput().CopyTo($m); Write-Output (($m.ToArray() | ForEach-Object { $_.ToString('x2') }) -join ' ')",
    ];

    private static async Task<(StreamResult Result, List<string> Lines)> Run(string[] args, string? stdin, CancellationToken? ct = null)
    {
        var lines = new List<string>();
        var result = await new SystemStreamRunner().RunAsync(PowerShell(), args, null, l => { lock (lines) lines.Add(l); }, Limit, ct ?? TestContext.Current.CancellationToken, stdin).ConfigureAwait(false);
        return (result, lines);
    }

    [Fact]
    public async Task TheLineOnStdinIsTheTextAndOneLineFeedAndNothingElse()
    {
        var (result, lines) = await Run(EchoBytes, "482913");
        Assert.Equal(0, result.ExitCode);
        // "482913" then 0a: no 0d (the platform's line end is 0d 0a), no byte order mark (ef bb bf)
        Assert.Equal("34 38 32 39 31 33 0a", Assert.Single(lines).Trim());
    }

    [Fact]
    public async Task ANonAsciiLineIsUtf8WithoutAByteOrderMark()
    {
        var (_, lines) = await Run(EchoBytes, "é");
        Assert.Equal("c3 a9 0a", Assert.Single(lines).Trim());
    }

    [Fact]
    public async Task TheLineIsInNoArgumentAndNoVariableOfTheChild()
    {
        // the child prints its own command line and every variable of its environment, and reads stdin: the code must be only in what it read
        var (_, lines) = await Run(["-NoProfile", "-NonInteractive", "-Command",
            "$in = [Console]::In.ReadLine(); Write-Output ('read=' + $in); Write-Output ('cmd=' + [Environment]::CommandLine); Write-Output ('env=' + ((Get-ChildItem Env: | ForEach-Object { $_.Name + '=' + $_.Value }) -join ';'))"], "907314");
        Assert.Contains("read=907314", lines);
        Assert.DoesNotContain(lines.Where(l => !l.StartsWith("read=", StringComparison.Ordinal)), l => l.Contains("907314"));
    }

    [Fact]
    public async Task NoLineMeansAnEmptyInputThatIsClosedAtOnce()
    {
        var (result, lines) = await Run(EchoBytes, null);
        Assert.Equal(0, result.ExitCode);
        Assert.Equal("", Assert.Single(lines).Trim());
    }

    [Fact]
    public async Task AChildThatEndsWithoutReadingIsNotAnException()
    {
        // far more than a pipe holds, so the write meets a pipe that nobody reads: IOException, which is caught
        var big = new string('x', 4 * 1024 * 1024);
        var (result, _) = await Run(["-NoProfile", "-NonInteractive", "-Command", "[Console]::Error.WriteLine('[FAIL] The room code is 6 digits.'); exit 3"], big);
        Assert.Equal(3, result.ExitCode);
        Assert.Equal("[FAIL] The room code is 6 digits.", result.Error); // the child's own sentence comes back
    }

    [Fact]
    public async Task CancellingDuringTheWriteKillsTheChildAndStopsTheCall()
    {
        using var cts = new CancellationTokenSource();
        var big = new string('x', 16 * 1024 * 1024);
        var run = Run(["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 120"], big, cts.Token);
        await Task.Delay(1500, TestContext.Current.CancellationToken);
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => run);
    }

    // --- the sentence of a refusal ---

    [Fact]
    public void TheReasonIsTheFirstFailLineOfAMixedStderr()
    {
        string[] lines =
        [
            "Room      Test Room (host: Test Host)",
            "Address   127.0.0.1:38999",
            "Host key  7fdc 34a6 ba8c 6ac7",
            "[FAIL] That code didn't work.",
            "Aborting. Check it with Test Host and run the command again.",
            "[FAIL] a later line",
        ];
        Assert.Equal("[FAIL] That code didn't work.", SystemStreamRunner.PickError(lines));
    }

    [Fact]
    public void WithNoFailLineTheFirstLineIsTheSentenceAsItWasBefore()
    {
        Assert.Equal("cannot run wsl.exe", SystemStreamRunner.PickError(["cannot run wsl.exe", "second line", "third line"]));
        Assert.Null(SystemStreamRunner.PickError([]));
    }

    [Fact]
    public void TheGenericCommandFailedLineIsNotTheReasonWhenAnotherLineSaysMore()
    {
        // benchbar run ends a failed command with "[FAIL] Command failed (exit N): ..." after what the command said
        Assert.Equal("cannot open the file", SystemStreamRunner.PickError(["cannot open the file", "[FAIL] Command failed (exit 1): cat x"]));
        Assert.Equal("[FAIL] The site is gone.", SystemStreamRunner.PickError(["cannot open the file", "[FAIL] Command failed (exit 1): cat x", "[FAIL] The site is gone."]));
        Assert.Equal("[FAIL] Command failed (exit 1): cat x", SystemStreamRunner.PickError(["[FAIL] Command failed (exit 1): cat x"]));
    }
}
