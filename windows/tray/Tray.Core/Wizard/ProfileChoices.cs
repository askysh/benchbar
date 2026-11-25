namespace BenchBar.Tray.Core;

/// <summary>
/// One line of the profile picker on the New Bench page. <see cref="Refusal"/> is the CLI's own reason when it will not install the
/// profile here (the Linux profile gate: <c>Profile NAME is not supported on Linux yet: ...</c>); such a line is shown but cannot be chosen.
/// </summary>
public sealed record ProfileChoice(string Name, string Label, string? Versions, bool IsTeam, string? Refusal = null)
{
    public bool Enabled => Refusal is null;

    /// <summary>The profile list already carried the gate's answer (<c>linux_supported</c>), so no dry run of this profile is needed.</summary>
    public bool Answered { get; init; }

    /// <summary>"v16-lts  Frappe/ERPNext v16 LTS", "acme  Acme ERP (team)": what the list shows.</summary>
    public string Text
    {
        get
        {
            var label = Label.Length == 0 || Label == Name ? "" : "  " + Label;
            return Name + label + (IsTeam ? UiText.Get("WizardProfileTeam") : "") + (Enabled ? "" : UiText.Get("WizardProfileNotAvailable"));
        }
    }

    /// <summary>The line under the picker for this profile: what it brings, or why it is off.</summary>
    public string Detail => Refusal ?? Versions ?? "";
}

/// <summary>What the profile gate said about one profile: a reason when the CLI refused it, null when it did not.</summary>
public sealed record ProfileGate(string Profile, string? Refusal);

/// <summary>The built in and team profiles of <c>profile list --json</c> that the picker offers, and how the gate's answers mark them.</summary>
public static class ProfileChoices
{
    /// <summary>The one profile offered when the list could not be read: the wizard's old fixed choice.</summary>
    public static ProfileChoice Fallback { get; } = new(WizardModel.DefaultProfile, UiText.Get("WizardProfileFallbackLabel"), null, false);

    /// <summary>
    /// The built in profiles, then the valid team profiles that no earlier file hides (the Mac app's rule). An invalid file or a
    /// shadowed one is not offered: <c>install --profile NAME</c> would refuse it, or take the other file. A profile whose list entry
    /// has <c>linux_supported</c> is answered: it is off with the CLI's reason when false, and needs no dry run.
    /// </summary>
    public static IReadOnlyList<ProfileChoice> From(IReadOnlyList<ProfileInfo> profiles) =>
        profiles.Where(p => p.Valid && p.ShadowedBy is null && (p.Kind == "builtin" || p.IsTeam))
            .Select(p => new ProfileChoice(p.Name, p.Label ?? p.Name, p.Versions.Length == 0 ? null : p.Versions, p.IsTeam,
                p.LinuxSupported == false ? Unsupported(p.UnsupportedReason) : null) { Answered = p.LinuxSupported is not null })
            .ToList();

    /// <summary>"Not supported on Linux yet: it needs MariaDB 12.0, ..." from the CLI's reasons.</summary>
    public static string Unsupported(string? reason) =>
        string.IsNullOrWhiteSpace(reason) ? UiText.Get("WizardUnsupported") : UiText.Format("WizardUnsupportedWhy", reason.Trim().TrimEnd('.'));

    /// <summary>The choices with the gate's dry run answers applied (the fallback for a CLI whose list has no <c>linux_supported</c>). A profile with no answer keeps what it has.</summary>
    public static IReadOnlyList<ProfileChoice> Apply(IReadOnlyList<ProfileChoice> choices, IReadOnlyDictionary<string, string?> refusals) =>
        choices.Select(c => refusals.TryGetValue(c.Name, out var why) ? c with { Refusal = why is { Length: > 0 } ? why : null } : c).ToList();

    /// <summary>
    /// Reads the gate's answer from the stream of <c>install --dry-run --json --profile NAME</c>. A plan line means the CLI took the
    /// profile (its blockers are about this machine, not the profile). A <c>done</c> that failed before any plan carries the refusal in
    /// <c>error</c>. Anything else (no output, a timeout) is no answer: the profile stays on offer and the Review page's own plan says more.
    /// </summary>
    public static ProfileGate Read(string profile, InstallPlan? plan, InstallDone? done)
    {
        if (plan is not null) return new ProfileGate(profile, null);
        return new ProfileGate(profile, done is { Exit: not 0, Error: { Length: > 0 } error } ? error : null);
    }
}
