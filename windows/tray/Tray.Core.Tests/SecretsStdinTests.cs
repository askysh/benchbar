using System.Text;
using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

/// <summary>
/// The passwords of an install or adopt go on the CLI's standard input (<c>--secrets-stdin</c>, askysh/benchbar#167) when
/// <c>commands --json</c> lists the flag for the command, and in the environment of an older CLI as before. The real child
/// (Windows PowerShell, as in <see cref="StreamRunnerStdinTests"/>) shows the exact bytes and that its environment has no password.
/// </summary>
public class SecretsStdinTests
{
    private const string Admin = "ad min#1\"q";
    private const string Root = "rootpw é=1";
    private const string Sudo = "sudo=pw\\x";

    private static InstallSecrets Secrets() => new(Secret.From(Admin), Secret.From(Sudo), Secret.From(Root));

    private static InstallRequest Request() => new("/home/u/bench", "v15-lts", "minimal", "site.localhost");

    private static string Catalogue(bool install, bool adopt) =>
        "{\"schema_version\":1,\"commands\":[" +
        "{\"name\":\"install\",\"usage\":\"\",\"summary\":\"\",\"mutating\":true,\"flags\":[" + (install ? "{\"name\":\"--secrets-stdin\",\"value\":null,\"help\":\"\"}" : "") + "]}," +
        "{\"name\":\"adopt\",\"usage\":\"\",\"summary\":\"\",\"mutating\":true,\"flags\":[" + (adopt ? "{\"name\":\"--secrets-stdin\",\"value\":null,\"help\":\"\"}" : "") + "]}]}";

    private static (ShimSetupService Service, RecordingStream Stream, CapturingProcessRunner Runner) Make(string commandsJson)
    {
        var runner = new CapturingProcessRunner { Next = new ProcessResult(0, commandsJson, "") };
        var stream = new RecordingStream();
        return (new ShimSetupService(runner, stream, () => @"C:\x\benchbar.exe"), stream, runner);
    }

    private static readonly string ExpectedList =
        "ADMIN_PASSWORD=" + Admin + "\nBENCHBAR_SUDO_PASSWORD=" + Sudo + "\nMARIADB_ROOT_PASSWORD=" + Root + "\n";

    [Fact]
    public async Task AnInstallSendsThePasswordsOnStdinWhenTheCliListsTheFlag()
    {
        var (service, stream, runner) = Make(Catalogue(install: true, adopt: true));
        await service.InstallAsync(Request(), Secrets(), _ => { }, TestContext.Current.CancellationToken);
        Assert.Equal(["commands", "--json"], runner.Runs.Single().Args);
        var run = Assert.Single(stream.Runs);
        Assert.Equal("--secrets-stdin", run.Args[^1]);
        Assert.Equal(ExpectedList, Assert.Single(stream.Stdins)); // the runner adds the LF that ends the list
        foreach (var name in new[] { "ADMIN_PASSWORD", "MARIADB_ROOT_PASSWORD", "BENCHBAR_SUDO_PASSWORD" }) Assert.DoesNotContain(name, run.Env.Keys);
        Assert.Equal("env", run.Env["BENCHBAR_SUDO"]); // the mode is not a secret and stays a variable
        Assert.DoesNotContain(run.Env.Values, v => v.Contains("pw") || v.Contains(Admin));
        Assert.DoesNotContain(run.Args, a => a.Contains(Admin) || a.Contains(Root) || a.Contains(Sudo));
    }

    [Fact]
    public async Task AnAdoptSendsThemTooOnlyWhenTheCliListsTheFlagForAdopt()
    {
        var (service, stream, _) = Make(Catalogue(install: true, adopt: true));
        await service.AdoptAsync("/home/u/bench", new InstallSecrets(null, Secret.From(Sudo)), _ => { }, TestContext.Current.CancellationToken);
        Assert.Equal(["adopt", "/home/u/bench", "--yes", "--json", "--secrets-stdin"], Assert.Single(stream.Runs).Args);
        Assert.Equal("BENCHBAR_SUDO_PASSWORD=" + Sudo + "\n", Assert.Single(stream.Stdins));

        var (older, olderStream, _) = Make(Catalogue(install: true, adopt: false));
        await older.AdoptAsync("/home/u/bench", new InstallSecrets(null, Secret.From(Sudo)), _ => { }, TestContext.Current.CancellationToken);
        var run = Assert.Single(olderStream.Runs);
        Assert.DoesNotContain("--secrets-stdin", run.Args);
        Assert.Equal(Sudo, run.Env["BENCHBAR_SUDO_PASSWORD"]);
        Assert.Null(Assert.Single(olderStream.Stdins));
    }

    [Theory]
    [InlineData("")] // a CLI too old to have commands
    [InlineData("not json")]
    [InlineData("{\"schema_version\":1,\"commands\":[]}")]
    public async Task AnOlderCliKeepsTheEnvironmentPath(string commandsOutput)
    {
        var (service, stream, _) = Make(commandsOutput);
        await service.InstallAsync(Request(), Secrets(), _ => { }, TestContext.Current.CancellationToken);
        var run = Assert.Single(stream.Runs);
        Assert.DoesNotContain("--secrets-stdin", run.Args);
        Assert.Equal(Admin, run.Env["ADMIN_PASSWORD"]);
        Assert.Equal(Root, run.Env["MARIADB_ROOT_PASSWORD"]);
        Assert.Equal(Sudo, run.Env["BENCHBAR_SUDO_PASSWORD"]);
        Assert.Null(Assert.Single(stream.Stdins));
    }

    [Fact]
    public async Task ACommandsCallThatFailsKeepsTheEnvironmentPath()
    {
        var runner = new CapturingProcessRunner { Next = new ProcessResult(127, "", "benchbar: command not found") };
        var stream = new RecordingStream();
        await new ShimSetupService(runner, stream, () => @"C:\x\benchbar.exe").InstallAsync(Request(), Secrets(), _ => { }, TestContext.Current.CancellationToken);
        Assert.Equal(Admin, Assert.Single(stream.Runs).Env["ADMIN_PASSWORD"]);
    }

    [Fact]
    public async Task APasswordWithALineBreakStaysOnTheEnvironmentPath()
    {
        // one line each: the CLI would read the rest as another line; the environment path has the CLI's own refusal for it
        var (service, stream, _) = Make(Catalogue(install: true, adopt: true));
        await service.InstallAsync(Request(), new InstallSecrets(Secret.From("a\nb"), null), _ => { }, TestContext.Current.CancellationToken);
        var run = Assert.Single(stream.Runs);
        Assert.DoesNotContain("--secrets-stdin", run.Args);
        Assert.Equal("a\nb", run.Env["ADMIN_PASSWORD"]);
    }

    [Fact]
    public async Task NoPasswordAtAllSendsNoList()
    {
        // an empty list is refused by the CLI
        var (service, stream, _) = Make(Catalogue(install: true, adopt: true));
        await service.AdoptAsync("/home/u/bench", new InstallSecrets(null, null), _ => { }, TestContext.Current.CancellationToken);
        Assert.DoesNotContain("--secrets-stdin", Assert.Single(stream.Runs).Args);
    }

    [Fact]
    public async Task WhatTheChildPrintsBackHidesEveryPassword()
    {
        var (service, stream, _) = Make(Catalogue(install: true, adopt: true));
        stream.Result = new StreamResult(1, "stderr " + Sudo + " " + Root);
        var result = await service.InstallAsync(Request(), Secrets(), _ => { }, TestContext.Current.CancellationToken);
        var shown = result.Error ?? "";
        Assert.DoesNotContain(Root, shown);
        Assert.DoesNotContain(Sudo, shown);
    }

    // ---- through the real runner

    private static string PowerShell() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");

    [Fact]
    public async Task TheRealChildGetsTheExactBytesAndNoPasswordInItsEnvironment()
    {
        var env = SetupEnv.ForInstall(Secrets(), viaStdin: true);
        // the child prints the bytes of its stdin as hex, and every variable of its environment and its command line
        var script = "$m = New-Object IO.MemoryStream; [Console]::OpenStandardInput().CopyTo($m); " +
                     "Write-Output ('bytes=' + (($m.ToArray() | ForEach-Object { $_.ToString('x2') }) -join ' ')); " +
                     "Write-Output ('env=' + ((Get-ChildItem Env: | ForEach-Object { $_.Name + '=' + $_.Value }) -join ';')); " +
                     "Write-Output ('cmd=' + [Environment]::CommandLine)";
        var lines = new List<string>();
        var result = await new SystemStreamRunner().RunAsync(PowerShell(), ["-NoProfile", "-NonInteractive", "-Command", script], env.Materialize(),
            l => { lock (lines) lines.Add(l); }, TimeSpan.FromSeconds(60), TestContext.Current.CancellationToken, env.MaterializeStdin());
        Assert.Equal(0, result.ExitCode);

        // the list, UTF-8 with no byte order mark, LF only, and the empty line that ends it (the runner's own LF)
        var bytes = new UTF8Encoding(false).GetBytes(ExpectedList + "\n");
        var expected = string.Join(' ', bytes.Select(b => b.ToString("x2")));
        Assert.Equal("bytes=" + expected, Assert.Single(lines, l => l.StartsWith("bytes=", StringComparison.Ordinal)).Trim());
        Assert.DoesNotContain((byte)0x0d, bytes);
        Assert.False(bytes.Length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf, "a byte order mark");
        Assert.EndsWith("0a 0a", expected);

        var rest = string.Join("\n", lines.Where(l => !l.StartsWith("bytes=", StringComparison.Ordinal)));
        foreach (var name in new[] { "ADMIN_PASSWORD", "MARIADB_ROOT_PASSWORD", "BENCHBAR_SUDO_PASSWORD" }) Assert.DoesNotContain(name + "=", rest);
        foreach (var secret in new[] { Admin, Root, Sudo }) Assert.DoesNotContain(secret, rest);
        Assert.Contains("BENCHBAR_SUDO=env", rest);
    }

    [Fact]
    public void TheEnvironmentPathStillPutsThemInTheEnvironment()
    {
        var env = SetupEnv.ForInstall(Secrets());
        Assert.Null(env.MaterializeStdin());
        var all = env.Materialize();
        Assert.Equal(Admin, all["ADMIN_PASSWORD"]);
        Assert.Equal(Root, all["MARIADB_ROOT_PASSWORD"]);
        Assert.Equal(Sudo, all["BENCHBAR_SUDO_PASSWORD"]);
    }
}
