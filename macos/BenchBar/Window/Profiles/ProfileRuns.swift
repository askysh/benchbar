import Foundation
import Observation

/// The state behind each profile sharing sheet. Profiles live in
/// ~/.config/benchbar, not in a bench, so these runs call the CLI directly
/// instead of taking a bench's change slot; nothing here installs an app
/// or touches a bench.
nonisolated enum ProfileRunPhase: Equatable, Sendable {
    case idle, loading, ready, running, done, failed(String)

    var isBusy: Bool { self == .loading || self == .running }

    /// The scaffold's phase, in the sheet's own words. `idle` is what the
    /// sheet shows before its run starts: the form, or the plan being read.
    /// Done without a result shows the content as it is.
    func sheetPhase(idle: SheetPhase = .ready, loading: String, running: String,
                    done: SheetResult?, failedTitle: String? = nil) -> SheetPhase {
        switch self {
        case .idle: return idle
        case .loading: return .loading(loading)
        case .ready: return .ready
        case .running: return .running(running)
        case .done: return done.map { SheetPhase.done($0) } ?? .ready
        case .failed(let message): return .failed(message, title: failedTitle)
        }
    }
}

private let noCLI = "The benchbar command line tool is not available."

/// Export: the plan first, the user's choices, then the file.
@Observable
final class ProfileExportRun {
    let name: String
    let workbench: Workbench
    private(set) var phase: ProfileRunPhase = .idle
    private(set) var plan: ProfileExportPlan?
    private(set) var result: ProfileExportResult?
    var choices = ProfileExportChoices()

    func branch(_ app: ProfileExportPlan.App) -> String { choices.branches[app.name] ?? app.exportedBranch }
    func setBranch(_ app: String, _ branch: String) { choices.branches[app] = branch }
    func setKeep(_ app: String, _ keep: Bool) { choices.keep[app] = keep }

    init(name: String, workbench: Workbench) {
        self.name = name
        self.workbench = workbench
    }

    var problem: String? { plan.flatMap { choices.problem(in: $0) } }
    var canExport: Bool { phase == .ready && plan != nil && problem == nil }

    func load() async {
        guard let client = workbench.store.cliClient else { phase = .failed(noCLI); return }
        phase = .loading
        do {
            let loaded = try await client.profileExportPlan(name)
            plan = loaded
            choices = ProfileExportChoices(plan: loaded)
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func export(to file: String) async {
        guard canExport, let plan, let client = workbench.store.cliClient else { return }
        phase = .running
        do {
            result = try await client.exportProfile(name, to: file, choices: choices.arguments(for: plan) + CLIClient.expectArguments(plan.digest))
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Import: review (fetch, parse, check), then Add Profile.
@Observable
final class ProfileImportRun {
    let workbench: Workbench
    var source: String
    var saveAs = ""
    private(set) var phase: ProfileRunPhase = .idle
    private(set) var plan: ProfileImportPlan?
    private(set) var result: ProfileImportResult?

    init(source: String = "", workbench: Workbench) {
        self.source = source
        self.workbench = workbench
    }

    var trimmedSource: String { source.trimmingCharacters(in: .whitespacesAndNewlines) }
    var asName: String? {
        let name = saveAs.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
    var sourceValid: Bool { ProfileSourceRule.isImportSource(trimmedSource) }
    var nameValid: Bool { asName.map(ProfileName.isValid) ?? true }
    var canReview: Bool { sourceValid && nameValid && !phase.isBusy }
    /// Only the plan that matches what the fields say now can be added.
    var canAdd: Bool { phase == .ready && plan != nil && reviewed == Reviewed(source: trimmedSource, name: asName) }

    private struct Reviewed: Equatable { var source: String; var name: String? }
    private var reviewed: Reviewed?

    func review() async {
        guard canReview else { return }
        guard let client = workbench.store.cliClient else { phase = .failed(noCLI); return }
        let wanted = Reviewed(source: trimmedSource, name: asName)
        phase = .loading
        plan = nil
        do {
            plan = try await client.profileImportPlan(wanted.source, as: wanted.name)
            reviewed = wanted
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func add() async {
        guard canAdd, let reviewed, let client = workbench.store.cliClient else { return }
        phase = .running
        do {
            result = try await client.importProfile(reviewed.source, as: reviewed.name, expect: plan?.digest)
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
        await workbench.loadProfiles()
    }
}

/// Subscribe: one git URL, cloned on the user's click.
@Observable
final class ProfileSubscribeRun {
    let workbench: Workbench
    var repo: String
    private(set) var phase: ProfileRunPhase = .idle
    private(set) var result: ProfileSubscribeResult?

    init(repo: String = "", workbench: Workbench) {
        self.repo = repo
        self.workbench = workbench
    }

    var trimmedRepo: String { repo.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSubscribe: Bool { ProfileSourceRule.isGitURL(trimmedRepo) && !phase.isBusy && phase != .done }

    func subscribe() async {
        guard canSubscribe else { return }
        guard let client = workbench.store.cliClient else { phase = .failed(noCLI); return }
        phase = .running
        do {
            result = try await client.subscribeProfiles(trimmedRepo)
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
        await workbench.loadProfiles()
    }
}

/// Update: the plan with its diff, then apply. Never automatic.
@Observable
final class ProfileUpdateRun {
    let name: String
    let workbench: Workbench
    private(set) var phase: ProfileRunPhase = .idle
    private(set) var plan: ProfileUpdatePlan?

    init(name: String, workbench: Workbench) {
        self.name = name
        self.workbench = workbench
    }

    var canApply: Bool { phase == .ready && plan?.hasChanges == true }

    func load() async {
        guard let client = workbench.store.cliClient else { phase = .failed(noCLI); return }
        phase = .loading
        do {
            plan = try await client.profileUpdatePlan(name)
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func apply() async {
        guard canApply, let client = workbench.store.cliClient else { return }
        phase = .running
        do {
            plan = try await client.updateProfile(name, expect: plan?.digest)
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
        await workbench.loadProfiles()
    }
}

/// Check Access: can this Mac reach every repository of the profile?
@Observable
final class ProfileCheckRun {
    let name: String
    let workbench: Workbench
    private(set) var phase: ProfileRunPhase = .idle
    private(set) var check: ProfileCheck?

    init(name: String, workbench: Workbench) {
        self.name = name
        self.workbench = workbench
    }

    func load() async {
        guard let client = workbench.store.cliClient else { phase = .failed(noCLI); return }
        phase = .loading
        do {
            check = try await client.checkProfile(name)
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

extension Workbench {
    /// Remove, after the user confirmed: the outcome goes to the pane's banner.
    func removeProfile(_ name: String) async {
        guard let client = store.cliClient else {
            result = ChangeResult(title: "Remove \(name)", error: noCLI, scope: Self.profilesScope)
            return
        }
        do {
            let removed = try await client.removeProfile(name)
            result = ChangeResult(title: "Remove \(name), moved to \(removed.movedTo)", error: nil, scope: Self.profilesScope)
        } catch {
            result = ChangeResult(title: "Remove \(name)", error: error.localizedDescription, scope: Self.profilesScope)
        }
        await loadProfiles()
    }
}
