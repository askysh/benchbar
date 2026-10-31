using System.Runtime.InteropServices;
using System.Security;

namespace BenchBar.Tray.Core;

/// <summary>
/// A password held in memory only. It prints as a word, never as itself, so a log line, an exception message or a
/// failed test cannot show it. The text is read back (<see cref="Reveal"/>) only to place it in the environment of the
/// one child process that needs it; nothing here writes it to config, a log or an exception.
/// </summary>
public sealed class Secret : IDisposable
{
    private SecureString? _value;

    private Secret(SecureString value) => _value = value;

    public static Secret Empty() => new(new SecureString());

    /// <summary>A copy of a <see cref="SecureString"/> (a PasswordBox's), so disposing the box does not empty this one.</summary>
    public static Secret From(SecureString value)
    {
        var copy = value.Copy();
        copy.MakeReadOnly();
        return new Secret(copy);
    }

    public static Secret From(string text)
    {
        var secure = new SecureString();
        foreach (var c in text) secure.AppendChar(c);
        secure.MakeReadOnly();
        return new Secret(secure);
    }

    public bool IsEmpty => _value is null || _value.Length == 0;

    public int Length => _value?.Length ?? 0;

    /// <summary>The text. Only for <see cref="SecretEnvironment"/> and for comparing two entries of a form.</summary>
    public string Reveal()
    {
        if (_value is null || _value.Length == 0) return "";
        var ptr = Marshal.SecureStringToGlobalAllocUnicode(_value);
        try
        {
            return Marshal.PtrToStringUni(ptr) ?? "";
        }
        finally
        {
            Marshal.ZeroFreeGlobalAllocUnicode(ptr);
        }
    }

    public bool SameAs(Secret other) => string.Equals(Reveal(), other.Reveal(), StringComparison.Ordinal);

    public override string ToString() => IsEmpty ? "empty" : "hidden";

    public void Dispose()
    {
        _value?.Dispose();
        _value = null;
    }
}

/// <summary>
/// The environment of one child process: names to values, where a value that is a password is held as a
/// <see cref="Secret"/> until the process starts. Its <see cref="ToString"/> lists names only.
/// </summary>
public sealed class SecretEnvironment
{
    private readonly Dictionary<string, string> _plain = [];
    private readonly Dictionary<string, Secret> _secrets = [];

    public SecretEnvironment Set(string name, string value)
    {
        _plain[name] = value;
        return this;
    }

    public SecretEnvironment Set(string name, Secret? secret)
    {
        if (secret is { IsEmpty: false }) _secrets[name] = secret;
        return this;
    }

    public IReadOnlyCollection<string> Names => [.. _plain.Keys, .. _secrets.Keys];

    /// <summary>The values to hide in anything the child prints back.</summary>
    public IReadOnlyList<Secret> Secrets => [.. _secrets.Values];

    /// <summary>Builds the dictionary handed to the process. Call it at the last moment and do not keep the result.</summary>
    public Dictionary<string, string> Materialize()
    {
        var all = new Dictionary<string, string>(_plain);
        foreach (var (name, secret) in _secrets) all[name] = secret.Reveal();
        return all;
    }

    public override string ToString() => "environment(" + string.Join(", ", Names.Order()) + ")";
}

/// <summary>Replaces every occurrence of a password in a line a child printed, in case a tool echoes its input.</summary>
public sealed class Redactor(IEnumerable<Secret> secrets)
{
    private readonly List<Secret> _secrets = secrets.Where(s => !s.IsEmpty).ToList();

    public static Redactor None { get; } = new([]);

    public string Clean(string line)
    {
        foreach (var secret in _secrets)
        {
            var text = secret.Reveal();
            if (text.Length >= 3) line = line.Replace(text, "***", StringComparison.Ordinal);
        }
        return line;
    }
}
