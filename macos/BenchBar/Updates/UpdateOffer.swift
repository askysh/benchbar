import AppKit
import Observation
import SwiftUI

/// The newer release BenchBar offers, and Update Now.
///
/// Checks GitHub at most once a day (on launch, on wake, and an hourly
/// look at the clock), only while "Check for updates automatically" is on
/// and never in a Sparkle build, which checks on its own. The manual Check
/// for Updates in About feeds the same offer. What was seen is kept in
/// UserDefaults, so the menu item is there right after launch.
@Observable
final class UpdateOffer {
    enum Key {
        static let lastCheck = "updates.lastCheck"
        static let latestSeen = "updates.latestSeen"
        static let latestPage = "updates.latestPage"
        static let dismissed = "updates.dismissedVersion"
    }

    /// A release newer than this app, nil when there is none.
    private(set) var version: String?
    private(set) var page: URL?
    private(set) var dismissedVersion: String?
    /// Why Update Now could not open Terminal.
    var error: String?

    var showsBanner: Bool { UpdateSchedule.showsBanner(offer: version, dismissed: dismissedVersion) }

    let currentVersion: String
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetch: UpdateCheck.Fetch
    @ObservationIgnored private let sparkle: Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var checking = false

    /// The benchbar the app runs, for the plan. Set by the app delegate.
    @ObservationIgnored var cliPath: () -> String? = { nil }
    @ObservationIgnored var environment: (String?) -> UpdatePlan.Environment = { UpdatePlan.Environment.live(cliPath: $0) }
    @ObservationIgnored var runInTerminal: (String, String) throws -> Void = { try Workspace.runInTerminal(name: $0, contents: $1) }
    @ObservationIgnored var quit: () -> Void = { NSApp.terminate(nil) }
    @ObservationIgnored var copy: (String) -> Void = { Workspace.copy($0) }
    @ObservationIgnored var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    init(settings: AppSettings, currentVersion: String = BenchBarLinks.appVersion, defaults: UserDefaults = .standard,
         sparkle: Bool = Updater.isAvailable, fetch: @escaping UpdateCheck.Fetch = UpdateCheck.liveFetch,
         now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.sparkle = sparkle
        self.fetch = fetch
        self.now = now
        dismissedVersion = defaults.string(forKey: Key.dismissed)
        refresh()
    }

    var plan: UpdatePlan { UpdatePlan.make(environment(cliPath())) }

    /// Launch, wake and an hourly timer; each only checks when one is due.
    func startAutomaticChecks() {
        guard !sparkle else { return }
        Task { await checkIfDue() }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkSoon() }
            })
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSoon() }
        }
    }

    private func checkSoon() { Task { await checkIfDue() } }

    /// One automatic check when it is due. A failure (offline, rate
    /// limited) is quiet and tried again at the next wake or hour.
    func checkIfDue() async {
        let last = defaults.object(forKey: Key.lastCheck) as? Date
        guard !checking, UpdateSchedule.isDue(now: now(), lastCheck: last, automatic: settings.checkUpdatesAutomatically, sparkle: sparkle) else { return }
        checking = true
        defer { checking = false }
        do throws(UpdateCheckError) {
            let data = try await fetch(UpdateCheck.request(appVersion: currentVersion))
            record(try UpdateCheck.parse(data, current: currentVersion))
            defaults.set(now(), forKey: Key.lastCheck)
        } catch {
            return
        }
    }

    /// What a check found, automatic or from the About pane.
    func record(_ status: UpdateStatus) {
        switch status {
        case .available(let version, let page):
            defaults.set(version, forKey: Key.latestSeen)
            defaults.set(page.absoluteString, forKey: Key.latestPage)
        case .upToDate(let latest):
            defaults.set(latest, forKey: Key.latestSeen)
            defaults.removeObject(forKey: Key.latestPage)
        }
        refresh()
    }

    private func refresh() {
        version = UpdateSchedule.offer(current: currentVersion, latestSeen: defaults.string(forKey: Key.latestSeen))
        page = version.flatMap { v in
            defaults.string(forKey: Key.latestPage).flatMap(URL.init(string:))
                ?? URL(string: "https://github.com/askysh/benchbar/releases/tag/v\(v)")
        }
    }

    /// Hides the banner for this version; the menu item stays.
    func dismiss() {
        dismissedVersion = version
        defaults.set(version, forKey: Key.dismissed)
    }

    /// Terminal runs the installer from a `.command` file (no Apple Events,
    /// so no Automation prompt), then BenchBar quits so the installer can
    /// replace it; the script opens it again at the end.
    func updateNow() {
        guard let version else { return }
        let plan = plan
        do {
            try runInTerminal("update-benchbar", plan.script(from: currentVersion, to: version))
        } catch {
            self.error = "Could not open Terminal: \(error.localizedDescription). Copy the command and run it yourself."
            return
        }
        error = nil
        // a moment for Terminal to take the file; the installer only
        // replaces the app after its git pull and download
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [quit] in quit() }
    }

    func copyCommand() { copy(plan.command) }

    func openReleaseNotes() { openURL(page ?? BenchBarLinks.releases) }

    /// The menu bar menu's "Update to X…": what happens, then the choice.
    func confirmFromMenu() {
        guard let version else { return }
        let alert = NSAlert()
        alert.messageText = "Update BenchBar to \(version)?"
        alert.informativeText = UpdateBanner.explanation(plan)
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Release Notes")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: updateNow()
        case .alertThirdButtonReturn: copyCommand()
        case NSApplication.ModalResponse(rawValue: 1003): openReleaseNotes()  // the fourth button
        default: break
        }
    }
}

/// The banner on top of the BenchBar window while a newer release is offered.
struct UpdateBanner: View {
    let offer: UpdateOffer

    static func explanation(_ plan: UpdatePlan) -> String {
        var text = "Terminal opens and runs the installer. BenchBar quits while it is replaced and opens again at the end; your benches keep running."
        if !plan.notes.isEmpty { text += "\n\n" + plan.notes.joined(separator: "\n\n") }
        return text
    }

    var body: some View {
        if let version = offer.version, offer.showsBanner {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("BenchBar \(version) is available").font(.callout.weight(.medium))
                    Text(Self.explanation(offer.plan)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = offer.error {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    HStack {
                        Button("Update Now") { offer.updateNow() }
                        Button("Copy Command") { offer.copyCommand() }
                            .help(offer.plan.command)
                        Button("Release Notes") { offer.openReleaseNotes() }
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
                Spacer()
                Button { offer.dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Hide until the next version")
            }
            .padding(10)
            .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
