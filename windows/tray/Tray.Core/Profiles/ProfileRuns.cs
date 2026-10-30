using System.Text.Json.Nodes;

namespace BenchBar.Tray.Core;

public enum ProfileRunPhase { Idle, Loading, Ready, Running, Done, Failed }

/// <summary>
/// Shared by the profile sheets: a phase, the failure line, and <see cref="Changed"/>, raised on the thread that awaited (the UI thread
/// in the app). Every call goes through <see cref="ICliClient"/>; a Windows path goes through <see cref="IWslHost"/> first.
/// </summary>
public abstract class ProfileRun
{
    protected ProfileRun(ICliClient cli, IWslHost wsl)
    {
        Cli = cli;
        Wsl = wsl;
    }

    protected ICliClient Cli { get; }

    protected IWslHost Wsl { get; }

    public event Action? Changed;

    public ProfileRunPhase Phase { get; protected set; } = ProfileRunPhase.Idle;

    /// <summary>Why the last step failed, in the CLI's own words when it gave one.</summary>
    public string? Error { get; protected set; }

    public bool IsBusy => Phase is ProfileRunPhase.Loading or ProfileRunPhase.Running;

    protected void Raise() => Changed?.Invoke();

    protected void Fail(string? message)
    {
        Error = message ?? "The command failed.";
        Phase = ProfileRunPhase.Failed;
        Raise();
    }

    /// <summary>The CLI's sentence for a refused call that still printed a document (<c>{"error": ...}</c>).</summary>
    protected static void ThrowIfRefusal(JsonObject o)
    {
        if (JsonRead.Str(o, "error") is { Length: > 0 } error) throw new FormatException(error);
    }

    /// <summary><c>--expect DIGEST</c> when the plan's digest is 64 hex characters: the CLI then refuses content that changed since.</summary>
    public static string[] ExpectArgs(string? digest) =>
        digest is { Length: 64 } && digest.All(Uri.IsHexDigit) ? ["--expect", digest] : [];
}

/// <summary>Import: review (fetch, parse, check), then Add Profile. A Windows file path is converted with <c>wslpath</c> first.</summary>
public sealed class ProfileImportRun : ProfileRun
{
    private (string Source, string? Name)? _reviewed;
    private string? _linuxSource;

    public ProfileImportRun(ICliClient cli, IWslHost wsl, string source = "") : base(cli, wsl) => Source = source;

    public string Source { get; set; }

    public string SaveAs { get; set; } = "";

    public ProfileImportPlan? Plan { get; private set; }

    public ProfileImportResult? Result { get; private set; }

    public string TrimmedSource => Source.Trim();

    public string? AsName => SaveAs.Trim() is { Length: > 0 } n ? n : null;

    public bool SourceValid => ProfileSourceRule.IsImportSource(TrimmedSource);

    public bool NameValid => AsName is null || ProfileName.IsValid(AsName);

    public bool CanReview => SourceValid && NameValid && !IsBusy;

    /// <summary>Only the plan that matches what the fields say now can be added.</summary>
    public bool CanAdd => Phase == ProfileRunPhase.Ready && Plan is not null && _reviewed == (TrimmedSource, AsName);

    public static string[] ImportArgs(string source, string? asName) =>
        ["profile", "import", source, .. (asName is null ? Array.Empty<string>() : ["--as", asName])];

    public static string[] PlanArgs(string source, string? asName) => [.. ImportArgs(source, asName), "--plan", "--json"];

    public static string[] AddArgs(string source, string? asName, string? digest) => [.. ImportArgs(source, asName), .. ExpectArgs(digest), "--yes", "--json"];

    public async Task ReviewAsync(CancellationToken ct = default)
    {
        if (!CanReview) return;
        var wanted = (TrimmedSource, AsName);
        Phase = ProfileRunPhase.Loading;
        Error = null;
        Plan = null;
        Raise();
        var converted = await Wsl.ToLinuxPathAsync(wanted.Item1, ct).ConfigureAwait(true);
        if (!converted.Ok)
        {
            Fail(converted.Error);
            return;
        }
        var source = ProfileSourceRule.IsImportUrl(wanted.Item1) ? wanted.Item1 : converted.Path!;
        var result = await Cli.RunJsonAsync(PlanArgs(source, wanted.Item2), null, CliTimeouts.Plan, ProfileImportPlan.Parse, ct).ConfigureAwait(true);
        if (result.Value is not { } plan)
        {
            Fail(result.Error);
            return;
        }
        Plan = plan;
        _reviewed = wanted;
        _linuxSource = source;
        Phase = ProfileRunPhase.Ready;
        Raise();
    }

    public async Task AddAsync(CancellationToken ct = default)
    {
        if (!CanAdd || Plan is not { } plan || _linuxSource is null) return;
        Phase = ProfileRunPhase.Running;
        Error = null;
        Raise();
        var result = await Cli.RunJsonAsync(AddArgs(_linuxSource, AsName, plan.Digest), null, CliTimeouts.Plan, ProfileImportResult.Parse, ct).ConfigureAwait(true);
        if (result.Value is not { } added || !result.Ok)
        {
            Fail(result.Error);
            return;
        }
        Result = added;
        Phase = ProfileRunPhase.Done;
        Raise();
    }
}

/// <summary>Export: read the plan, pick a branch per app, write the file. The file may be a Windows path.</summary>
public sealed class ProfileExportRun : ProfileRun
{
    public ProfileExportRun(ICliClient cli, IWslHost wsl, string name) : base(cli, wsl) => Name = name;

    public string Name { get; }

    public ProfileExportPlan? Plan { get; private set; }

    public ProfileExportChoices? Choices { get; private set; }

    public ProfileExportResult? Result { get; private set; }

    /// <summary>The Windows (or Linux) path the person chose, shown and opened afterwards.</summary>
    public string? ChosenFile { get; private set; }

    public string? Problem => Plan is { } plan ? Choices?.Problem(plan) : null;

    public bool CanExport => Phase == ProfileRunPhase.Ready && Plan is not null && Problem is null;

    public static string[] PlanArgs(string name) => ["profile", "export", name, "--plan", "--json"];

    public static string[] ExportArgs(string name, string file, IEnumerable<string> choices, string? digest) =>
        ["profile", "export", name, "--out", file, .. choices, .. ExpectArgs(digest), "--yes", "--json"];

    public async Task LoadAsync(CancellationToken ct = default)
    {
        Phase = ProfileRunPhase.Loading;
        Error = null;
        Raise();
        var result = await Cli.RunJsonAsync(PlanArgs(Name), null, CliTimeouts.Plan, ProfileExportPlan.Parse, ct).ConfigureAwait(true);
        if (result.Value is not { } plan)
        {
            Fail(result.Error);
            return;
        }
        Plan = plan;
        Choices = new ProfileExportChoices(plan);
        Phase = ProfileRunPhase.Ready;
        Raise();
    }

    public void Touched() => Raise();

    public async Task ExportAsync(string file, CancellationToken ct = default)
    {
        if (!CanExport || Plan is not { } plan || Choices is not { } choices) return;
        Phase = ProfileRunPhase.Running;
        Error = null;
        Raise();
        var converted = await Wsl.ToLinuxPathAsync(file, ct).ConfigureAwait(true);
        if (!converted.Ok)
        {
            Fail(converted.Error);
            return;
        }
        var result = await Cli.RunJsonAsync(ExportArgs(Name, converted.Path!, choices.Arguments(plan), plan.Digest), null, CliTimeouts.Plan, o =>
        {
            ThrowIfRefusal(o);
            return ProfileExportResult.Parse(o);
        }, ct).ConfigureAwait(true);
        if (result.Value is not { } exported || !result.Ok)
        {
            // the plan is still good: back to the choices, with the CLI's sentence above them
            Error = result.Error ?? "The profile was not exported.";
            Phase = ProfileRunPhase.Ready;
            Raise();
            return;
        }
        Result = exported;
        ChosenFile = file;
        Phase = ProfileRunPhase.Done;
        Raise();
    }
}

/// <summary>Update: fetch the source and show what changed, then apply exactly that.</summary>
public sealed class ProfileUpdateRun : ProfileRun
{
    public ProfileUpdateRun(ICliClient cli, IWslHost wsl, string name) : base(cli, wsl) => Name = name;

    public string Name { get; }

    public ProfileUpdatePlan? Plan { get; private set; }

    public bool CanApply => Phase == ProfileRunPhase.Ready && Plan is { HasChanges: true };

    public static string[] PlanArgs(string name) => ["profile", "update", name, "--plan", "--json"];

    public static string[] ApplyArgs(string name, string? digest) => ["profile", "update", name, .. ExpectArgs(digest), "--yes", "--json"];

    public async Task LoadAsync(CancellationToken ct = default)
    {
        Phase = ProfileRunPhase.Loading;
        Error = null;
        Raise();
        var result = await Cli.RunJsonAsync(PlanArgs(Name), null, CliTimeouts.Plan, ProfileUpdatePlan.Parse, ct).ConfigureAwait(true);
        if (result.Value is not { } plan)
        {
            Fail(result.Error);
            return;
        }
        Plan = plan;
        Phase = ProfileRunPhase.Ready;
        Raise();
    }

    public async Task ApplyAsync(CancellationToken ct = default)
    {
        if (!CanApply || Plan is not { } plan) return;
        Phase = ProfileRunPhase.Running;
        Error = null;
        Raise();
        var result = await Cli.RunJsonAsync(ApplyArgs(Name, plan.Digest), null, CliTimeouts.Plan, ProfileUpdatePlan.Parse, ct).ConfigureAwait(true);
        if (result.Value is not { } applied || !result.Ok)
        {
            Fail(result.Error);
            return;
        }
        if (applied.Applied == false)
        {
            Fail($"{Name} could not be updated. Nothing was changed.");
            return;
        }
        Phase = ProfileRunPhase.Done;
        Raise();
    }
}

/// <summary>Check Access: <c>git ls-remote</c> per repository, with the person's own credentials.</summary>
public sealed class ProfileCheckRun : ProfileRun
{
    public ProfileCheckRun(ICliClient cli, IWslHost wsl, string name) : base(cli, wsl) => Name = name;

    public string Name { get; }

    public ProfileCheck? Check { get; private set; }

    public static string[] Args(string name) => ["profile", "check", name, "--json"];

    public async Task LoadAsync(CancellationToken ct = default)
    {
        if (IsBusy) return;
        Phase = ProfileRunPhase.Loading;
        Error = null;
        Raise();
        var result = await Cli.RunJsonAsync(Args(Name), null, CliTimeouts.Plan, ProfileCheck.Parse, ct).ConfigureAwait(true);
        if (result.Value is not { } check)
        {
            Fail(result.Error);
            return;
        }
        Check = check;
        Phase = ProfileRunPhase.Done;
        Raise();
    }
}

/// <summary>Subscribe: clone a team's repository into <c>~/.config/benchbar/sources</c> and read only its .toml files.</summary>
public sealed class ProfileSubscribeRun : ProfileRun
{
    public ProfileSubscribeRun(ICliClient cli, IWslHost wsl, string repo = "") : base(cli, wsl) => Repo = repo;

    public string Repo { get; set; }

    public string TrimmedRepo => Repo.Trim();

    public ProfileSubscribeResult? Result { get; private set; }

    public bool CanSubscribe => ProfileSourceRule.IsGitUrl(TrimmedRepo) && !IsBusy && Phase != ProfileRunPhase.Done;

    public static string[] Args(string repo) => ["profile", "subscribe", repo, "--yes", "--json"];

    public async Task SubscribeAsync(CancellationToken ct = default)
    {
        if (!CanSubscribe) return;
        Phase = ProfileRunPhase.Running;
        Error = null;
        Raise();
        var result = await Cli.RunJsonAsync(Args(TrimmedRepo), null, CliTimeouts.Apply, ProfileSubscribeResult.Parse, ct).ConfigureAwait(true);
        if (result.Value is not { } subscribed || !result.Ok)
        {
            // back to the form so the address can be fixed
            Error = result.Error ?? "The repository was not added.";
            Phase = ProfileRunPhase.Failed;
            Raise();
            return;
        }
        Result = subscribed;
        Phase = ProfileRunPhase.Done;
        Raise();
    }
}
