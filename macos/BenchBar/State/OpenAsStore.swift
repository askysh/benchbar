import Foundation
import Observation

/// A user pinned in the "Open as…" menu of one site. `fullName` is kept so
/// a pin without a label still reads as a person.
nonisolated struct PinnedUser: Codable, Equatable, Sendable {
    var user: String
    var label: String?
    var fullName: String? = nil
}

/// A user the app switched to, newest first in `OpenAsStore.recents`.
nonisolated struct RecentUser: Equatable, Sendable {
    var user: String
    var fullName: String?
}

/// Pins, recents and live sessions for "Open as…".
///
/// The session ids live in this object's memory only: not in UserDefaults,
/// not in a log, not in an error message. Quitting the app forgets them, and
/// the next switch asks the CLI for a new session.
@Observable
final class OpenAsStore {
    nonisolated static let maxPins = 9
    nonisolated static let maxRecents = 2
    nonisolated static let pinsKey = "openAsPins"
    nonisolated static let administrator = "Administrator"

    private struct Session {
        var base: String
        var sid: String
        var homePath: String
    }

    private(set) var pins: [String: [PinnedUser]]
    private(set) var recentsBySite: [String: [RecentUser]] = [:]
    /// Switches running per site ("<bench>|<site>"): the menu shows a spinner while it is above 0.
    /// A count, not a flag: with two switches on one site, the first to end must not stop the spinner.
    private(set) var switchingCount: [String: Int] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let browser: any BrowserOpening
    @ObservationIgnored private let checkSession: @Sendable (URL, String) async -> String?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var sessions: [String: Session] = [:]
    @ObservationIgnored private var lastMillis = 0
    @ObservationIgnored private var errorsByBench: [String: String] = [:]

    /// `checkSession(siteURL, sid)` answers with the user the id belongs to, nil when nothing answered.
    init(defaults: UserDefaults = .standard,
         browser: any BrowserOpening = BrowserRouter(),
         checkSession: @escaping @Sendable (URL, String) async -> String? = OpenAsStore.probeSession,
         clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.browser = browser
        self.checkSession = checkSession
        self.clock = clock
        pins = defaults.data(forKey: Self.pinsKey)
            .flatMap { try? JSONDecoder().decode([String: [PinnedUser]].self, from: $0) } ?? [:]
    }

    nonisolated static func probeSession(siteURL: URL, sid: String) async -> String? {
        guard let host = siteURL.host else { return nil }
        return await SessionProbe.loggedUser(sessionID: sid, site: host, port: siteURL.port ?? 80)
    }

    nonisolated static func siteKey(bench: String, site: String) -> String { "\(bench)|\(site)" }

    func isSwitching(bench: String, site: String) -> Bool {
        (switchingCount[Self.siteKey(bench: bench, site: site)] ?? 0) > 0
    }

    /// What `bench.lastError` becomes after a switch on `bench`. A failure
    /// replaces it; a success clears only the error an earlier switch put there,
    /// so an unrelated one (a failed start) stays.
    func lastError(afterSwitchOn bench: String, current: String?, error: String?) -> String? {
        let mine = errorsByBench[bench]
        errorsByBench[bench] = error
        if let error { return error }
        return current == mine ? nil : current
    }

    // MARK: pins

    func pins(bench: String, site: String) -> [PinnedUser] {
        pins[Self.siteKey(bench: bench, site: site)] ?? []
    }

    func isPinned(_ user: String, bench: String, site: String) -> Bool {
        pins(bench: bench, site: site).contains { $0.user == user }
    }

    /// False when the site already has nine pins (or the user is Administrator, always in the menu).
    @discardableResult
    func pin(_ user: String, fullName: String?, bench: String, site: String) -> Bool {
        let key = Self.siteKey(bench: bench, site: site)
        var list = pins[key] ?? []
        if list.contains(where: { $0.user == user }) { return true }
        guard user != Self.administrator, list.count < Self.maxPins else { return false }
        list.append(PinnedUser(user: user, label: nil, fullName: fullName))
        pins[key] = list
        savePins()
        return true
    }

    /// Forgets the pins of benches and sites that are gone. `sitesByBench`
    /// holds the sites of each bench that is still listed, nil for a bench
    /// whose sites are not known now (its pins stay); a bench not in it is gone.
    func prune(keeping sitesByBench: [String: Set<String>?]) {
        let kept = pins.filter { key, _ in
            guard let split = key.lastIndex(of: "|") else { return false }
            guard let sites = sitesByBench[String(key[..<split])] else { return false }
            return sites?.contains(String(key[key.index(after: split)...])) ?? true
        }
        guard kept.count != pins.count else { return }
        pins = kept
        savePins()
    }

    func unpin(_ user: String, bench: String, site: String) {
        let key = Self.siteKey(bench: bench, site: site)
        pins[key]?.removeAll { $0.user == user }
        if pins[key]?.isEmpty == true { pins[key] = nil }
        savePins()
    }

    func setLabel(_ label: String, for user: String, bench: String, site: String) {
        let key = Self.siteKey(bench: bench, site: site)
        guard let index = pins[key]?.firstIndex(where: { $0.user == user }) else { return }
        // stored as typed: trimming on every keystroke would eat the space of "NE Pune";
        // OpenAsMenuModel.label trims when it reads
        pins[key]?[index].label = label.trimmingCharacters(in: .whitespaces).isEmpty ? nil : label
        savePins()
    }

    private func savePins() {
        defaults.set(try? JSONEncoder().encode(pins), forKey: Self.pinsKey)
    }

    // MARK: recents

    func recents(bench: String, site: String) -> [RecentUser] {
        recentsBySite[Self.siteKey(bench: bench, site: site)] ?? []
    }

    /// The user the last switch made, as the row subtitle names them.
    func currentLabel(bench: String, site: String) -> String? {
        recents(bench: bench, site: site).first.map { OpenAsMenuModel.label(for: $0.user, fullName: $0.fullName, pins: pins(bench: bench, site: site)) }
    }

    private func recordRecent(_ user: String, fullName: String?, key: String) {
        var list = recentsBySite[key] ?? []
        list.removeAll { $0.user == user }
        list.insert(RecentUser(user: user, fullName: fullName), at: 0)
        recentsBySite[key] = Array(list.prefix(Self.maxRecents))
    }

    // MARK: switching

    /// Opens `site` signed in as `user` in the testing browser. Returns the
    /// error text, nil on success. It takes no slot of the store's change
    /// lock: opening a browser changes no bench.
    ///
    /// A session this app created is reused while the site still says it
    /// belongs to `user`; a logged out, expired or flushed one is replaced.
    func switchTo(user: String, bench: String, site: String, siteURL: String, path: String?,
                  fullName: String? = nil, client: any OpenAsCLI) async -> String? {
        let siteKey = Self.siteKey(bench: bench, site: site)
        let sessionKey = "\(siteKey)|\(user)"
        switchingCount[siteKey, default: 0] += 1
        defer {
            let left = (switchingCount[siteKey] ?? 1) - 1
            switchingCount[siteKey] = left > 0 ? left : nil
        }

        let link: URL
        var name = fullName
        if let session = sessions[sessionKey], let probeURL = URL(string: session.base),
           await checkSession(probeURL, session.sid) == user,
           let reused = OpenAsLink.url(base: session.base, path: path ?? session.homePath, sid: session.sid, millis: nextMillis()) {
            link = reused
        } else {
            sessions[sessionKey] = nil
            let result: OpenAsResult
            do throws(CLIError) {
                result = try await client.openAs(bench: bench, site: site, user: user, path: path)
            } catch {
                return OpenAsLink.scrub(error.localizedDescription)
            }
            guard let text = result.url, let url = URL(string: text), let sid = OpenAsLink.sessionID(in: text) else {
                return "benchbar did not return a sign-in link for \(user)."
            }
            sessions[sessionKey] = Session(base: siteURL, sid: sid, homePath: result.userType == "Website User" ? "/" : "/app")
            name = result.fullName ?? fullName
            link = url
        }

        recordRecent(user, fullName: name, key: siteKey)
        browser.open(link)
        return nil
    }

    /// Milliseconds since 1970, strictly increasing: two links in the same
    /// millisecond would still differ, and a browser would not reuse a cached 301.
    private func nextMillis() -> Int {
        lastMillis = max(Int(clock().timeIntervalSince1970 * 1000), lastMillis + 1)
        return lastMillis
    }
}

extension BenchStore {
    /// "Open as…" for one site row. A failure lands on the bench like any
    /// other action's and is also returned; an unrelated error already there stays.
    @discardableResult
    func switchUser(_ user: String, fullName: String? = nil, on bench: BenchModel, row: SiteRow, path: String? = nil) async -> String? {
        guard let client = cliClient else {
            bench.lastError = Self.noCLIMessage
            return Self.noCLIMessage
        }
        let error = await openAs.switchTo(user: user, bench: bench.path, site: row.name, siteURL: row.url, path: path,
                                          fullName: fullName, client: client)
        bench.lastError = openAs.lastError(afterSwitchOn: bench.path, current: bench.lastError, error: error)
        return error
    }
}
