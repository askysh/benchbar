import Foundation
import Observation

/// What the BenchBar window shows beyond the popover: each bench's apps,
/// the profiles, and the outcome of the last change. Every change goes
/// through `BenchStore.runChange`, so it takes the one change slot the
/// CLI's lock needs, and the app never runs bench, git or brew itself.
@Observable
final class Workbench {
    let store: BenchStore

    private(set) var apps: [String: AppList] = [:]
    private(set) var appsError: [String: String] = [:]
    private(set) var loadingApps: Set<String> = []
    private(set) var checkingRemotes: Set<String> = []
    private(set) var profiles: [ProfileInfo] = []
    private(set) var profilesError: String?
    /// Each site's backups, keyed by `backupKey(bench, site)`; read on the Sites tab.
    private(set) var backups: [String: SiteBackupList] = [:]
    /// `lock check --json` per bench path, and why it failed.
    private(set) var lockChecks: [String: LockCheck] = [:]
    private(set) var lockErrors: [String: String] = [:]
    private(set) var checkingLock: Set<String> = []
    /// What `commands --json` says this CLI has, read once per session (a failed read is kept).
    private(set) var commandState = CommandCatalogState.unread
    /// `autostart` per bench path: nil until read, and for a bench or a CLI without the command.
    private(set) var autostartOn: [String: Bool] = [:]
    /// Why the last acknowledge, services only or autostart call failed, per bench path, for the page it came from.
    private(set) var parityError: [String: String] = [:]
    /// Each site's snapshots, keyed by `backupKey(bench, site)`; read when the Snapshots sheet opens and after a change to them.
    var snapshotLists: [String: SiteSnapshotList] = [:]
    /// `benchbar history --json`, newest first, and why it could not be read.
    var history: [HistoryEntry] = []
    var historyError: String?
    var loadingHistory = false
    /// `lease list --json` per bench path: who holds the bench or one of its sites.
    var leases: [String: [LeaseInfo]] = [:]
    /// The runs of each bench that go on now (`op list --running`), and the ones seen running that have ended since (`op status`).
    var runningOps: [String: [OpRecord]] = [:]
    var endedOps: [String: [OpRecord]] = [:]
    /// The commands `run` allows, from the CLI (read once per session; the documented list when the CLI's cannot be read).
    var runCommands: [RunCommandInfo]?
    /// The last change's outcome, for the banner at the top of the pane.
    var result: ChangeResult?
    /// The change a lease refused, to run again as a person's explicit "Break lease" (never on its own).
    var leaseRetry: LeaseRetry?
    @ObservationIgnored private let appCalls = OnDemandCalls()
    @ObservationIgnored private let autostartCalls = OnDemandCalls()
    /// The live read of site lists that were never read, once per stamp.
    @ObservationIgnored private let unknownSiteCalls = OnDemandCalls()

    nonisolated struct ChangeResult: Equatable, Sendable {
        var title: String
        var error: String?
        /// Where the banner shows: a bench's path, or `Workbench.profilesScope`.
        var scope: String = ""
        /// What a change that worked has to say (what a pull neutralised); the banner shows it under the title.
        var note: String?
        /// The change was refused because a lease holds the bench or site: who holds it and until when.
        var lease: LeaseRefusal?
        var succeeded: Bool { error == nil }
    }

    /// What a lease refused, kept so the person can run the same change again with `--break-lease`.
    struct LeaseRetry {
        var title: String
        var bench: BenchModel
        var work: (CLIClient) async throws(CLIError) -> Void
    }

    static let profilesScope = "profiles"

    init(store: BenchStore) {
        self.store = store
    }

    // MARK: apps

    /// `app list --json` now: the Refresh button, and after a change to the
    /// apps. `liveSites: false` reads the cached site lists (no MariaDB needed).
    func loadApps(_ bench: BenchModel, liveSites: Bool = false) async {
        await askApps(bench, liveSites: liveSites, force: true)
    }

    /// The Apps page is on screen: the list is read (cached site lists)
    /// unless there is one from this window session and nothing was done to
    /// the bench since. A cache that was never filled is filled once by
    /// asking bench, so the page does not say an app is on no site.
    func showApps(_ bench: BenchModel) async {
        guard store.pageMayAsk(about: bench) else { return }
        await askApps(bench, liveSites: false, force: false)
        if apps[bench.path]?.sitesKnown == false {
            await askApps(bench, liveSites: true, force: false, calls: unknownSiteCalls)
        }
    }

    private func askApps(_ bench: BenchModel, liveSites: Bool, force: Bool, calls: OnDemandCalls? = nil) async {
        guard let client = store.cliClient else { return }
        await (calls ?? appCalls).ask(bench.path, force: force, stamp: { store.stamp(for: bench) }) {
            self.loadingApps.insert(bench.path)
            defer { self.loadingApps.remove(bench.path) }
            do {
                self.apps[bench.path] = try await client.apps(bench: bench.path, liveSites: liveSites)
                self.appsError[bench.path] = nil
            } catch {
                self.appsError[bench.path] = error.localizedDescription
            }
        }
    }

    /// The reviewed plan of an app add (one app or several), read only. Nothing is changed and no
    /// change slot is taken; the person looks at it before `addApp`.
    func addAppPlan(_ entries: [AppAddEntry], on bench: BenchModel) async -> Result<AppAddPlan, ChangeError> {
        guard let client = store.cliClient else { return .failure(ChangeError(message: String(localized: "The benchbar command line tool is not available."))) }
        do {
            return .success(try await client.addAppPlan(entries, bench: bench.path))
        } catch {
            return .failure(ChangeError(message: error.localizedDescription))
        }
    }

    /// Runs the plan the person saw, by its token. Returns the CLI's message
    /// when it failed (a stale token among them), nil when it worked.
    @discardableResult
    func addApp(_ entries: [AppAddEntry], token: String, on bench: BenchModel) async -> String? {
        let error = await change(String(localized: "Add \(AppAddBatch.title(entries.map(\.displayName)))"), on: bench) { client throws(CLIError) in
            try await client.addApp(entries, token: token, bench: bench.path)
        }
        await loadApps(bench, liveSites: true)
        return error
    }

    func installApp(_ app: String, site: String, on bench: BenchModel) async {
        await change(String(localized: "Install \(app) on \(site)"), on: bench) { client throws(CLIError) in
            try await client.installApp(app, site: site, bench: bench.path)
        }
        await loadApps(bench, liveSites: true)
    }

    /// The plan of an update, read only (git fetch touches only the app's .git).
    func updatePlan(_ app: String, on bench: BenchModel) async -> Result<AppUpdatePlan, ChangeError> {
        guard let client = store.cliClient else { return .failure(ChangeError(message: String(localized: "The benchbar command line tool is not available."))) }
        do {
            return .success(try await client.updatePlan(app: app, bench: bench.path))
        } catch {
            return .failure(ChangeError(message: error.localizedDescription))
        }
    }

    func updateApp(_ app: String, on bench: BenchModel) async {
        await change(String(localized: "Update \(app)"), on: bench) { client throws(CLIError) in
            try await client.updateApp(app, bench: bench.path)
        }
        await loadApps(bench, liveSites: true)
    }

    /// Sets an app's focus pin. Not a change to the bench (no change slot,
    /// no banner): the CLI writes one key of the bench's state, then the
    /// list is read again from the cached site lists.
    func setFocus(_ pin: FocusPin, app: String, on bench: BenchModel) async {
        guard let client = store.cliClient else { return }
        do {
            try await client.setAppFocus(app, pin: pin, bench: bench.path)
        } catch {
            appsError[bench.path] = error.localizedDescription
            return
        }
        // a list read before the pin is old now, even one still under way
        bench.markChanged()
        await loadApps(bench)
    }

    /// Fetches the focus apps' dependencies (the only fetch the app asks
    /// for: its doctor runs stay read only), then reads the list again.
    func checkRemotes(_ bench: BenchModel) async {
        guard let client = store.cliClient, !checkingRemotes.contains(bench.path) else { return }
        checkingRemotes.insert(bench.path)
        defer { checkingRemotes.remove(bench.path) }
        do {
            try await client.checkRemotes(bench: bench.path)
        } catch {
            appsError[bench.path] = error.localizedDescription
            return
        }
        bench.markChanged()
        await loadApps(bench)
    }

    // MARK: sites

    /// The reviewed plan of a site add, read only. Nothing is created and no
    /// change slot is taken; the person looks at it before `addSite`.
    func addSitePlan(_ name: String, on bench: BenchModel) async -> Result<SiteAddPlan, ChangeError> {
        guard let client = store.cliClient else { return .failure(ChangeError(message: String(localized: "The benchbar command line tool is not available."))) }
        do {
            return .success(try await client.addSitePlan(name, bench: bench.path))
        } catch {
            return .failure(ChangeError(message: error.localizedDescription))
        }
    }

    /// Runs the plan the person saw, by its token. Returns the CLI's message
    /// when it failed (a stale token among them), nil when it worked.
    @discardableResult
    func addSite(_ name: String, adminPassword: String, token: String, on bench: BenchModel) async -> String? {
        await change(String(localized: "Add site \(name)"), on: bench) { client throws(CLIError) in
            try await client.addSite(name, adminPassword: adminPassword, token: token, bench: bench.path)
        }
    }

    func setDefaultSite(_ name: String, on bench: BenchModel) async {
        await change(String(localized: "Make \(name) the default site"), on: bench) { client throws(CLIError) in
            try await client.setDefaultSite(name, bench: bench.path)
        }
    }

    /// The per site Open as opt-in. The caller has shown the alert for `on`.
    func setOpenAs(_ on: Bool, site: String, on bench: BenchModel) async {
        await change(on ? String(localized: "Allow Open as on \(site)") : String(localized: "Turn off Open as on \(site)"), on: bench) { client throws(CLIError) in
            try await client.setOpenAs(on, site: site, bench: bench.path)
        }
    }

    // MARK: lockfile

    /// Compares the bench with its remembered lockfile. Read only; nothing
    /// to do for a bench without one.
    func checkLock(_ bench: BenchModel) async {
        guard bench.summary.lockFile != nil, let client = store.cliClient, !checkingLock.contains(bench.path) else { return }
        checkingLock.insert(bench.path)
        defer { checkingLock.remove(bench.path) }
        do {
            lockChecks[bench.path] = try await client.lockCheck(bench: bench.path)
            lockErrors[bench.path] = nil
        } catch {
            // an old "In sync" must not stand for a check that failed
            lockChecks[bench.path] = nil
            lockErrors[bench.path] = error.localizedDescription
        }
    }

    // MARK: backups and drop

    static func backupKey(_ bench: String, _ site: String) -> String { bench + "\n" + site }

    func backups(of site: String, on bench: BenchModel) -> SiteBackupList? {
        backups[Self.backupKey(bench.path, site)]
    }

    /// `site backups --json` for every site of the bench. Read only; a site
    /// that fails (an older CLI) just shows no backup line.
    func loadBackups(_ bench: BenchModel) async {
        guard let client = store.cliClient else { return }
        for row in bench.siteRows {
            if let list = try? await client.siteBackups(row.name, bench: bench.path) {
                backups[Self.backupKey(bench.path, row.name)] = list
            }
        }
    }

    /// The change slot's text while `site` is backed up.
    nonisolated static func backupActivity(_ site: String, withFiles: Bool) -> String {
        withFiles ? String(localized: "Back up \(site) with files") : String(localized: "Back up \(site)")
    }

    /// Whether the bench's activity text is a backup of exactly `site`: `shop`
    /// is not `shop2`, which a prefix test could not tell apart.
    nonisolated static func isBackingUp(_ site: String, activity: String?) -> Bool {
        guard let activity else { return false }
        return activity == backupActivity(site, withFiles: false) || activity == backupActivity(site, withFiles: true)
    }

    /// Backs up a site in the change slot. Returns the new backup, nil when
    /// it failed (the banner says why).
    @discardableResult
    func backUpSite(_ site: String, withFiles: Bool, on bench: BenchModel) async -> SiteBackup? {
        var made: SiteBackup?
        await change(Self.backupActivity(site, withFiles: withFiles), on: bench) { client throws(CLIError) in
            made = try await client.backupSite(site, withFiles: withFiles, bench: bench.path).backup
        }
        if let client = store.cliClient, let list = try? await client.siteBackups(site, bench: bench.path) {
            backups[Self.backupKey(bench.path, site)] = list
        }
        return made
    }

    func dropPlan(_ site: String, newDefault: String?, on bench: BenchModel) async -> Result<SiteDropPlan, ChangeError> {
        guard let client = store.cliClient else { return .failure(ChangeError(message: String(localized: "The benchbar command line tool is not available."))) }
        do {
            return .success(try await client.dropPlan(site: site, newDefault: newDefault, bench: bench.path))
        } catch {
            return .failure(ChangeError(message: error.localizedDescription))
        }
    }

    /// Drops the site in the change slot; `confirm` is what the user typed.
    func dropSite(_ site: String, confirm: String, newDefault: String?, on bench: BenchModel) async -> Result<SiteDropResult, ChangeError> {
        var dropped: SiteDropResult?
        await change(String(localized: "Drop site \(site)"), on: bench) { client throws(CLIError) in
            dropped = try await client.dropSite(site, confirm: confirm, newDefault: newDefault, bench: bench.path)
        }
        if let dropped {
            backups[Self.backupKey(bench.path, site)] = nil
            return .success(dropped)
        }
        return .failure(ChangeError(message: result?.error ?? String(localized: "The site was not dropped.")))
    }

    // MARK: restore and pull

    /// The reviewed plan of a restore, read only. Nothing is backed up or restored
    /// and no change slot is taken; the person looks at it before `restoreSite`.
    func restorePlan(_ request: SiteRestoreRequest, on bench: BenchModel) async -> Result<SiteRestorePlan, ChangeError> {
        guard let client = store.cliClient else { return .failure(ChangeError(message: String(localized: "The benchbar command line tool is not available."))) }
        do {
            return .success(try await client.restorePlan(request, bench: bench.path))
        } catch {
            return .failure(ChangeError(message: error.localizedDescription))
        }
    }

    /// Runs the plan the person saw, by its token. Returns the CLI's message when it failed
    /// (a stale token among them), nil when it worked. An existing site is backed up with its
    /// files first by the CLI, so its backup list is read again either way.
    @discardableResult
    func restoreSite(_ request: SiteRestoreRequest, token: String, on bench: BenchModel) async -> String? {
        let title = request.asNew ? String(localized: "Copy \(request.fromSite) to \(request.target)") : String(localized: "Restore \(request.target)")
        let error = await change(title, on: bench) { client throws(CLIError) in
            try await client.restoreSite(request, token: token, bench: bench.path)
        }
        await loadBackups(bench)
        return error
    }

    /// The plan of a pull (`pull --dry-run --json`), read only: the server and the bench are
    /// checked, nothing is downloaded or written.
    func pullPlan(_ request: PullRequest, on bench: BenchModel) async -> Result<PullPlan, ChangeError> {
        guard let client = store.cliClient else { return .failure(ChangeError(message: String(localized: "The benchbar command line tool is not available."))) }
        do {
            return .success(try await client.pullPlan(request, bench: bench.path))
        } catch {
            return .failure(ChangeError(message: error.localizedDescription))
        }
    }

    /// Copies the site by the token of the plan the person saw. Returns the CLI's message when it
    /// failed (a plan that changed since it was shown among them).
    @discardableResult
    func pull(_ request: PullRequest, reviewed: PullPlan? = nil, on bench: BenchModel) async -> String? {
        var ran: PullRun?
        let title = String(localized: "Pull \(request.name)")
        let token = reviewed?.token
        let error = await change(title, on: bench) { client throws(CLIError) in
            ran = try await client.pull(request, token: token, bench: bench.path)
        }
        if let ran, error == nil {
            let neutralised = ran.done.neutralised?.summary ?? ""
            // a CLI with a token has already refused a changed plan; only an older one is told after the run
            let changed = token != nil ? [] : (reviewed.flatMap { reviewed in ran.plan.map { $0.differences(from: reviewed) } } ?? [])
            result?.note = [neutralised.isEmpty ? nil : String(localized: "Neutralised: \(neutralised)."),
                            String(localized: "Log in as Administrator. Its password is production's unless you set one in Terminal. If \(request.name) does not open, Sites has Add Hosts Lines."),
                            changed.isEmpty ? nil : String(localized: "The run differed from the plan you reviewed: \(changed.joined(separator: "; "))."),
                            ran.done.warnings.isEmpty ? nil : ran.done.warnings.joined(separator: " ")].compactMap { $0 }.joined(separator: " ")
        }
        return error
    }

    /// Drops the record of an update or add that stopped part way (`app update NAME --discard-pending`).
    /// None of its steps run. The change reads the status again, so the record leaves the page.
    func discardPending(_ operation: PendingOperation, on bench: BenchModel) async {
        await change(operation.isUpdate ? String(localized: "Drop the unfinished update of \(operation.app)") : String(localized: "Drop the unfinished add of \(operation.app)"), on: bench) { client throws(CLIError) in
            try await client.discardPending(operation.app, bench: bench.path)
        }
    }

    // MARK: commands, services, autostart, acknowledgements

    /// The CLI's command list, asked once: a button of a newer command shows only when it is listed.
    func loadCommands() async {
        guard commandState == .unread, let client = store.cliClient else { return }
        do {
            commandState = .known(try await client.commands())
        } catch {
            commandState = .failed(error.localizedDescription)
        }
    }

    /// Whether the bench comes back after a login: `autostart` of `status --json` (CLI 0.9), which the window reads anyway.
    /// A CLI whose status has no such field is asked in words (`benchbar autostart`) once the Overview shows it.
    func autostartSetting(for bench: BenchModel) -> Bool? { bench.status?.autostart ?? autostartOn[bench.path] }

    /// The fallback read for a CLI older than 0.9, whose status has no `autostart` and whose command prints text only.
    func showAutostart(_ bench: BenchModel) async {
        guard bench.status?.autostart == nil, commandState.catalog?.has("autostart") == true, !bench.needsService, store.pageMayAsk(about: bench),
              let client = store.cliClient else { return }
        await autostartCalls.ask(bench.path, force: false, stamp: { store.stamp(for: bench) }) {
            self.autostartOn[bench.path] = (try? await client.autostart(bench: bench.path)) ?? nil
        }
    }

    /// The switch, on a click: `autostart on` or `off` writes one line of the bench's state and its agent file.
    func setAutostart(_ on: Bool, on bench: BenchModel) async {
        parityError[bench.path] = nil
        let error = await change(on ? String(localized: "Start \(bench.name) after login") : String(localized: "Do not start \(bench.name) after login"), on: bench) { client throws(CLIError) in
            try await client.setAutostart(on, bench: bench.path)
        }
        // the status is read again after the change and says it; the remembered value serves a CLI without the field
        if error == nil { autostartOn[bench.path] = on } else { autostartOn[bench.path] = nil }
    }

    /// Start Services Only (`up --services-only`) or Stop Services (`down`) on a stopped bench: no plan, the click is the decision.
    func setServices(_ start: Bool, on bench: BenchModel) async {
        await change(start ? String(localized: "Start the services of \(bench.name)") : String(localized: "Stop the services of \(bench.name)"), on: bench) { client throws(CLIError) in
            if start { try await client.startServicesOnly(bench: bench.path) } else { try await client.stopServices(bench: bench.path) }
        }
    }

    /// Acknowledge (or Undo) one warning of this bench's doctor report, then ask doctor again. A click only.
    func acknowledge(_ check: DoctorCheck, on: Bool, bench: BenchModel) async {
        parityError[bench.path] = nil
        guard let client = store.cliClient else { return }
        do {
            try await client.acknowledge(check.id, on: on, bench: bench.path)
        } catch {
            parityError[bench.path] = error.localizedDescription
            return
        }
        await store.runDoctor(on: bench)
    }

    /// The plan of installing or refreshing the background service, read only.
    func servicePlan(on bench: BenchModel) async -> Result<ServiceInstallPlan, ChangeError> {
        guard let client = store.cliClient else { return .failure(ChangeError(message: String(localized: "The benchbar command line tool is not available."))) }
        do {
            return .success(try await client.servicePlan(bench: bench.path))
        } catch {
            return .failure(ChangeError(message: error.localizedDescription))
        }
    }

    /// Runs the service plan the person saw, by its token. The CLI's message when it failed (a stale token among them), nil when it worked.
    @discardableResult
    func installService(token: String, refresh: Bool, on bench: BenchModel) async -> String? {
        await change(refresh ? String(localized: "Refresh the service of \(bench.name)") : String(localized: "Install the service of \(bench.name)"), on: bench) { client throws(CLIError) in
            try await client.installService(token: token, bench: bench.path)
        }
    }

    // MARK: profiles

    func loadProfiles() async {
        guard let client = store.cliClient else { return }
        do {
            profiles = try await client.profiles().profiles
            profilesError = nil
        } catch {
            profilesError = error.localizedDescription
        }
    }

    func createProfile(_ name: String, from bench: BenchModel) async {
        await change(String(localized: "Create team profile \(name)"), on: bench, scope: Self.profilesScope) { client throws(CLIError) in
            try await client.createProfile(name, fromBench: bench.path)
        }
        await loadProfiles()
    }

    // MARK: -

    nonisolated struct ChangeError: Error, Equatable, Sendable {
        var message: String
    }

    @discardableResult
    func change(_ title: String, on bench: BenchModel, scope: String? = nil,
                _ work: @escaping (CLIClient) async throws(CLIError) -> Void) async -> String? {
        let error = await store.runChange(title, on: bench, work)
        var outcome = ChangeResult(title: title, error: error, scope: scope ?? bench.path)
        leaseRetry = nil
        if let error, let refusal = LeaseRefusal.parse(error) {
            outcome.lease = refusal
            leaseRetry = LeaseRetry(title: title, bench: bench, work: work)
        }
        result = outcome
        return error
    }

    /// Runs the change a lease refused again with `--break-lease`. Only a click on "Break Lease" after the app's own
    /// alert calls this: the CLI allows it to a person, and the holder is named in the alert and in the history.
    func breakLease() async {
        guard let retry = leaseRetry else { return }
        leaseRetry = nil
        let work = retry.work
        let error = await store.runChange(retry.title, on: retry.bench) { client throws(CLIError) in
            try await work(client.breakingLease())
        }
        result = ChangeResult(title: retry.title, error: error, scope: retry.bench.path)
    }
}

/// Words for app sources.
nonisolated enum AppSource {
    /// "https://github.com/acme/acme_erp.git" -> "acme_erp"; a registry name stays.
    static func displayName(_ source: String) -> String {
        var s = source.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        if let slash = s.lastIndex(where: { $0 == "/" || $0 == ":" }) { s = String(s[s.index(after: slash)...]) }
        return s.isEmpty ? source : s
    }

    /// A git URL (https, ssh or scp style), as opposed to a registry name.
    static func isURL(_ source: String) -> Bool {
        let s = source.trimmingCharacters(in: .whitespaces)
        return s.contains("://") || (s.contains("@") && s.contains(":"))
    }

    /// Site names that do not have the app yet.
    static func sitesWithout(_ app: AppInfo, among sites: [String]) -> [String] {
        sites.filter { !app.sites.contains($0) }
    }
}
