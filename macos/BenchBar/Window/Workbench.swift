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
    private(set) var profiles: [ProfileInfo] = []
    private(set) var profilesError: String?
    /// The last change's outcome, for the banner at the top of the pane.
    var result: ChangeResult?

    nonisolated struct ChangeResult: Equatable, Sendable {
        var title: String
        var error: String?
        var succeeded: Bool { error == nil }
    }

    init(store: BenchStore) {
        self.store = store
    }

    // MARK: apps

    /// `liveSites: false` reads the cached site lists (no MariaDB needed).
    func loadApps(_ bench: BenchModel, liveSites: Bool = false) async {
        guard let client = store.cliClient, !loadingApps.contains(bench.path) else { return }
        loadingApps.insert(bench.path)
        defer { loadingApps.remove(bench.path) }
        do {
            apps[bench.path] = try await client.apps(bench: bench.path, liveSites: liveSites)
            appsError[bench.path] = nil
        } catch {
            appsError[bench.path] = error.localizedDescription
        }
    }

    func addApp(_ source: String, branch: String, site: String?, on bench: BenchModel) async {
        let name = source.trimmingCharacters(in: .whitespaces)
        await change("Add \(AppSource.displayName(name))", on: bench) { client throws(CLIError) in
            try await client.addApp(name, branch: branch.trimmingCharacters(in: .whitespaces), site: site, bench: bench.path)
        }
        await loadApps(bench, liveSites: true)
    }

    func installApp(_ app: String, site: String, on bench: BenchModel) async {
        await change("Install \(app) on \(site)", on: bench) { client throws(CLIError) in
            try await client.installApp(app, site: site, bench: bench.path)
        }
        await loadApps(bench, liveSites: true)
    }

    /// The plan of an update, read only (git fetch touches only the app's .git).
    func updatePlan(_ app: String, on bench: BenchModel) async -> Result<AppUpdatePlan, ChangeError> {
        guard let client = store.cliClient else { return .failure(ChangeError(message: "The benchbar command line tool is not available.")) }
        do {
            return .success(try await client.updatePlan(app: app, bench: bench.path))
        } catch {
            return .failure(ChangeError(message: error.localizedDescription))
        }
    }

    func updateApp(_ app: String, on bench: BenchModel) async {
        await change("Update \(app)", on: bench) { client throws(CLIError) in
            try await client.updateApp(app, bench: bench.path)
        }
        await loadApps(bench, liveSites: true)
    }

    // MARK: sites

    func addSite(_ name: String, adminPassword: String, on bench: BenchModel) async {
        await change("Add site \(name)", on: bench) { client throws(CLIError) in
            try await client.addSite(name, adminPassword: adminPassword, bench: bench.path)
        }
    }

    func setDefaultSite(_ name: String, on bench: BenchModel) async {
        await change("Make \(name) the default site", on: bench) { client throws(CLIError) in
            try await client.setDefaultSite(name, bench: bench.path)
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
        await change("Create team profile \(name)", on: bench) { client throws(CLIError) in
            try await client.createProfile(name, fromBench: bench.path)
        }
        await loadProfiles()
    }

    // MARK: -

    nonisolated struct ChangeError: Error, Equatable, Sendable {
        var message: String
    }

    private func change(_ title: String, on bench: BenchModel,
                        _ work: (CLIClient) async throws(CLIError) -> Void) async {
        let error = await store.runChange(title, on: bench, work)
        result = ChangeResult(title: title, error: error)
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
