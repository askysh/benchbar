import Foundation

/// A secret held in memory only: it prints as a word, never as itself, so
/// no log line or test failure can show it.
nonisolated struct Secret: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var value = ""
    init(_ value: String = "") { self.value = value }
    var isEmpty: Bool { value.isEmpty }
    var description: String { isEmpty ? "empty" : "hidden" }
    var debugDescription: String { description }
}

/// A profile the New Bench page offers.
nonisolated struct ProfileChoice: Equatable, Sendable, Identifiable {
    var name: String
    var label: String
    /// "Python 3.11, Node 22, MariaDB 10.11", what the profile brings.
    var versions: String?
    var isTeam: Bool

    var id: String { name }

    /// The built in v15-lts and v16-lts, then the valid team profiles that no
    /// earlier file hides. A profile the CLI cannot install from is not offered.
    static func choices(from profiles: [ProfileInfo]) -> [ProfileChoice] {
        profiles.filter { $0.valid && $0.shadowedBy == nil && ($0.kind == "builtin" || $0.isTeam) }
            .map { info in
                let parts = [info.python.map { "Python \($0)" }, info.node.map { "Node \($0)" }, info.mariadb.map { "MariaDB \($0)" }]
                    .compactMap { $0 }
                return ProfileChoice(name: info.name, label: info.label ?? info.name,
                                     versions: parts.isEmpty ? nil : parts.joined(separator: ", "), isTeam: info.isTeam)
            }
    }
}

/// The first run wizard as a value: pages, the events that arrive (a click,
/// an answer from the CLI, a line of the install stream) and the effects
/// they ask for. No I/O and no clock, like BenchStateMachine, so every
/// transition is a unit test. `WizardRun` does the I/O.
nonisolated struct WizardState: Equatable, Sendable {
    enum Page: String, Equatable, Sendable { case welcome, cliOnly, check, newBench, review, install, done }

    struct Form: Equatable, Sendable {
        var folder: String
        var profile = "v15-lts"
        var bundle = "minimal"
        var site = "macdev"
        /// The text of the port offset field.
        var portOffset = ""
        var portOffsetEdited = false
        var adminPassword = Secret()
    }

    struct Failure: Equatable, Sendable {
        /// The step that failed, in the CLI's words.
        var step: String?
        var message: String
        var fix: String?
        var log: String?
    }

    enum InstallPhase: Equatable, Sendable {
        case idle
        case running
        case succeeded
        case failed(Failure)
        /// Exit 2: MariaDB has a root password that nothing here knows.
        case needsRootPassword(fix: String?)
        /// The Stop button ended the run.
        case stopped
    }

    /// The one primary button of the page: the label and whether it works now.
    struct Primary: Equatable, Sendable {
        var title: String
        var enabled: Bool
    }

    enum Event: Equatable, Sendable {
        case chooseNewBench, chooseExistingBench, chooseCLIOnly
        /// Return.
        case primary
        /// Esc, and the Back or Cancel button.
        case back
        case checkAgain
        case prerequisites(PrerequisiteReport)
        case prerequisitesFailed(String)
        case profiles(ProfileList)
        case profilesFailed(String)
        /// The folder field changed (every keystroke): no check yet.
        case setFolder(String)
        /// The folder was chosen, or the field was left: check it.
        case commitFolder
        case setProfile(String)
        case setBundle(String)
        case setSite(String)
        case setPortOffset(String)
        case setAdminPassword(String)
        case setRootPassword(String)
        case planned(InstallPlan)
        case planFailed(String)
        case install(InstallEvent)
        /// The install process ended. `error` when it could not run at all.
        case installEnded(exitCode: Int32, error: String?)
        case stop
        case retry
        /// The Done page's Done button.
        case finish
    }

    enum Effect: Equatable, Sendable {
        case checkPrerequisites(folder: String)
        case loadProfiles
        case planInstall(InstallRequest)
        case startInstall(InstallRequest, withRootPassword: Bool)
        case stopInstall
        /// Find Benches and its folder scan (the existing adoption flow).
        case openFindBenches
        case openSite(String)
        /// Esc on the first page: back to the first bench, when there is one.
        case leave
        /// The wizard is over: read the bench list again and show the new bench.
        case finished
    }

    private(set) var page: Page = .welcome
    private(set) var form: Form
    private(set) var rootPassword = Secret()

    private(set) var prerequisites: PrerequisiteReport?
    private(set) var checking = false
    private(set) var checkError: String?

    private(set) var profiles: [ProfileInfo] = []
    private(set) var bundles: [AppBundle] = []
    private(set) var profilesLoaded = false
    private(set) var profilesError: String?

    private(set) var plan: InstallPlan?
    private(set) var planning = false
    private(set) var planError: String?

    private(set) var progress = InstallProgress()
    private(set) var installPhase: InstallPhase = .idle
    private(set) var stopRequested = false

    init(home: String = NSHomeDirectory()) {
        form = Form(folder: home + "/frappe-bench")
    }

    /// A page already on screen, for the snapshots and the tests.
    init(home: String = NSHomeDirectory(), page: Page) {
        self.init(home: home)
        self.page = page
    }

    // MARK: what the pages show

    var profileChoices: [ProfileChoice] { ProfileChoice.choices(from: profiles) }

    /// The port field exists only when the default ports are taken.
    var showsPortField: Bool { prerequisites?.portOffsetToUse != nil }

    var resolvedFolder: String { (form.folder.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath }

    var siteProblem: String? {
        form.site.isEmpty || SiteName.isValid(form.site) ? nil : SiteName.rule
    }

    var portOffsetValue: Int? {
        showsPortField ? Int(form.portOffset.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 ? $0 : nil } : nil
    }

    /// Why Review is not possible yet, nil when it is.
    var formProblem: String? {
        if resolvedFolder.isEmpty || !resolvedFolder.hasPrefix("/") { return "Choose a folder for the bench." }
        if prerequisites?.check("bench_folder")?.level == .fail { return prerequisites?.check("bench_folder")?.message }
        if !profilesLoaded { return "Reading the profiles…" }
        if !profileChoices.contains(where: { $0.name == form.profile }) { return "Choose a profile." }
        if !bundles.contains(where: { $0.name == form.bundle }) { return "Choose a bundle." }
        if form.site.isEmpty || !SiteName.isValid(form.site) { return SiteName.rule }
        if form.adminPassword.isEmpty { return "Choose the Administrator password." }
        if showsPortField, portOffsetValue == nil { return "The port offset is a whole number." }
        return nil
    }

    var request: InstallRequest {
        InstallRequest(benchDir: resolvedFolder, profile: form.profile, bundle: form.bundle, site: form.site, portOffset: portOffsetValue)
    }

    var canContinueFromCheck: Bool { !checking && (prerequisites?.canContinue ?? false) }

    /// Poll the prerequisites only on the page that shows them, while Command
    /// Line Tools are missing.
    var shouldPoll: Bool { page == .check && PrerequisiteRows.shouldPoll(prerequisites) }

    /// The runner of the Check Your Mac page.
    var runnerState: BenchState { prerequisites?.runnerState ?? .stopped }

    var isInstalling: Bool { page == .install && installPhase == .running }

    /// The address from the `done` line.
    var siteURL: String? { progress.done?.url }

    /// Privileged steps that were skipped, with what to run by hand.
    var skippedCommands: [SkippedStep] { progress.skippedWithCommand }

    var primary: Primary? {
        switch page {
        case .welcome: return Primary(title: "Set Up a New Bench", enabled: true)
        case .cliOnly: return Primary(title: "Done", enabled: true)
        case .check: return Primary(title: "Continue", enabled: canContinueFromCheck)
        case .newBench: return Primary(title: "Review", enabled: formProblem == nil)
        case .review: return Primary(title: "Install", enabled: plan != nil && !planning)
        case .install:
            switch installPhase {
            case .failed: return Primary(title: "Retry", enabled: true)
            case .needsRootPassword: return Primary(title: "Retry", enabled: !rootPassword.isEmpty)
            case .stopped: return Primary(title: "Run Again", enabled: true)
            case .idle, .running, .succeeded: return nil
            }
        case .done: return siteURL.map { _ in Primary(title: "Open Site", enabled: true) }
        }
    }

    /// The label of the Back button, nil when the page has none.
    var backTitle: String? {
        switch page {
        case .welcome: return "Cancel"
        case .cliOnly, .check, .newBench, .review: return "Back"
        case .install: return isInstalling ? nil : "Back"
        case .done: return "Done"
        }
    }

    // MARK: events

    @discardableResult
    mutating func send(_ event: Event) -> [Effect] {
        switch event {
        case .chooseNewBench: return startCheck()
        case .chooseExistingBench: return [.openFindBenches]
        case .chooseCLIOnly:
            if page == .welcome { page = .cliOnly }
            return []
        case .primary: return primaryAction()
        case .back: return goBack()
        case .checkAgain:
            guard page == .check || page == .newBench else { return [] }
            checking = true
            checkError = nil
            return [.checkPrerequisites(folder: resolvedFolder)]
        case .prerequisites(let report):
            checking = false
            checkError = nil
            prerequisites = report
            if !form.portOffsetEdited { form.portOffset = report.portOffsetToUse.map(String.init) ?? "" }
            return []
        case .prerequisitesFailed(let message):
            checking = false
            checkError = message
            return []
        case .profiles(let list):
            profiles = list.profiles
            bundles = list.bundles ?? []
            profilesLoaded = true
            profilesError = nil
            chooseDefaults()
            return []
        case .profilesFailed(let message):
            profilesError = message
            return []
        case .setFolder(let folder):
            form.folder = folder
            return []
        case .commitFolder:
            guard page == .newBench else { return [] }
            checking = true
            return [.checkPrerequisites(folder: resolvedFolder)]
        case .setProfile(let name): form.profile = name; return []
        case .setBundle(let name): form.bundle = name; return []
        case .setSite(let name): form.site = name; return []
        case .setPortOffset(let text):
            form.portOffset = text
            form.portOffsetEdited = true
            return []
        case .setAdminPassword(let text): form.adminPassword = Secret(text); return []
        case .setRootPassword(let text): rootPassword = Secret(text); return []
        case .planned(let plan):
            guard page == .review, planning else { return [] }
            self.plan = plan
            planning = false
            planError = nil
            return []
        case .planFailed(let message):
            guard page == .review, planning else { return [] }
            planning = false
            planError = message
            return []
        case .install(let event):
            guard page == .install else { return [] }
            progress.apply(event)
            return []
        case .installEnded(let code, let error): return installEnded(code, error)
        case .stop:
            guard isInstalling, !stopRequested else { return [] }
            stopRequested = true
            return [.stopInstall]
        case .retry: return retry()
        case .finish:
            guard page == .done else { return [] }
            return [.finished]
        }
    }

    // MARK: pages

    private mutating func startCheck() -> [Effect] {
        guard page == .welcome else { return [] }
        page = .check
        checking = true
        checkError = nil
        return [.checkPrerequisites(folder: resolvedFolder)]
    }

    private mutating func primaryAction() -> [Effect] {
        guard let primary, primary.enabled else { return [] }
        switch page {
        case .welcome: return startCheck()
        case .cliOnly:
            page = .welcome
            return []
        case .check:
            page = .newBench
            return profilesLoaded ? [] : [.loadProfiles]
        case .newBench:
            page = .review
            plan = nil
            planError = nil
            planning = true
            return [.planInstall(request)]
        case .review: return beginInstall(withRootPassword: false)
        case .install:
            if case .stopped = installPhase { return beginInstall(withRootPassword: !rootPassword.isEmpty) }
            return retry()
        case .done:
            return siteURL.map { [.openSite($0)] } ?? []
        }
    }

    private mutating func goBack() -> [Effect] {
        switch page {
        case .welcome: return [.leave]
        case .cliOnly, .check:
            page = .welcome
            return []
        case .newBench:
            page = .check
            return []
        case .review:
            page = .newBench
            planning = false
            return []
        case .install:
            guard !isInstalling else { return [] }
            resetInstall()
            page = .newBench
            return []
        case .done: return [.finished]
        }
    }

    private mutating func beginInstall(withRootPassword: Bool) -> [Effect] {
        page = .install
        resetInstall()
        installPhase = .running
        return [.startInstall(request, withRootPassword: withRootPassword)]
    }

    private mutating func retry() -> [Effect] {
        switch installPhase {
        case .failed, .stopped:
            return beginInstall(withRootPassword: !rootPassword.isEmpty)
        case .needsRootPassword:
            guard !rootPassword.isEmpty else { return [] }
            return beginInstall(withRootPassword: true)
        case .idle, .running, .succeeded:
            return []
        }
    }

    private mutating func resetInstall() {
        progress = InstallProgress()
        installPhase = .idle
        stopRequested = false
    }

    private mutating func installEnded(_ code: Int32, _ error: String?) -> [Effect] {
        guard page == .install, installPhase == .running else { return [] }
        if stopRequested {
            installPhase = .stopped
            return []
        }
        guard let done = progress.done else {
            let message = error ?? "benchbar install ended without a result (exit code \(code))."
            installPhase = .failed(Failure(step: progress.failedStep?.name, message: message, fix: nil, log: progress.log))
            return []
        }
        switch done.exit {
        case 0:
            installPhase = .succeeded
            page = .done
        case 2:
            installPhase = .needsRootPassword(fix: done.fix)
        default:
            let step = progress.failedStep
            let message = step?.message ?? done.error ?? done.fix ?? "benchbar install failed (exit \(done.exit))."
            installPhase = .failed(Failure(step: step?.name, message: message, fix: done.fix, log: done.log ?? progress.log))
        }
        return []
    }

    /// The first built in profile and the first bundle when the saved choice is not on offer.
    private mutating func chooseDefaults() {
        let names = profileChoices.map(\.name)
        if !names.contains(form.profile), let first = names.first { form.profile = first }
        let bundleNames = bundles.map(\.name)
        if !bundleNames.contains(form.bundle), let first = bundleNames.first { form.bundle = first }
    }
}
