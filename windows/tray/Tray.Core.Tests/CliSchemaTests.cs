using BenchBar.Tray.Core;
using Xunit;

namespace Tray.Core.Tests;

public class CliSchemaTests
{
    [Theory]
    [InlineData("status --json")]
    [InlineData("doctor --json")]
    [InlineData("setup check --json")]
    [InlineData("scan --json")]
    [InlineData("site list --json")]
    [InlineData("site backups macdev --json")]
    public void Reads_are_read_only(string args) => Assert.True(CliSchema.IsReadOnly(args.Split(' ')));

    [Theory]
    [InlineData("doctor --ack redis_6379 --json")]
    [InlineData("doctor --unack redis_6379 --json")]
    [InlineData("setup run --json")]
    [InlineData("site add demo --dry-run --json")]
    [InlineData("repair --yes --json")]
    [InlineData("up --json")]
    public void Changes_are_not_read_only(string args) => Assert.False(CliSchema.IsReadOnly(args.Split(' ')));
}
