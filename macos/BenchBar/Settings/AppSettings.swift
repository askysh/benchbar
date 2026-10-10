import AppKit
import Observation

/// User preferences, stored in UserDefaults (~/Library/Preferences/com.akashmishra.benchbar.plist).
///
/// @Observable makes SwiftUI views that read a property redraw when it
/// changes; didSet writes the value through to UserDefaults.
@Observable
final class AppSettings {
    enum Key {
        static let cliPath = "cliPath"
        static let scanFolder = "scanFolder"
        static let askedForCLI = "askedForCLI"
        static let runnerID = "runnerID"
        static let speedEnabled = "speedEnabled"
        static let notificationsEnabled = "notificationsEnabled"
        static let selectedBench = "selectedBench"
        static let askedForNotifications = "askedForNotifications"
        static let editorBundleID = "editorBundleID"
        static let checkUpdatesAutomatically = "checkUpdatesAutomatically"
        static let walkthroughSeen = "walkthroughSeen"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let findEditors: () -> [Editor]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Absolute path to benchbar chosen by the user; empty means "search".
    var cliPath: String { didSet { defaults.set(cliPath, forKey: Key.cliPath) } }
    var scanFolder: String { didSet { defaults.set(scanFolder, forKey: Key.scanFolder) } }
    /// The file picker for the CLI is shown at most once automatically.
    var askedForCLI: Bool { didSet { defaults.set(askedForCLI, forKey: Key.askedForCLI) } }
    /// Built in ("bench", "cup") or a custom runner folder name.
    var runnerID: String { didSet { defaults.set(runnerID, forKey: Key.runnerID) } }
    /// Off: the running animation keeps one steady speed.
    var speedEnabled: Bool { didSet { defaults.set(speedEnabled, forKey: Key.speedEnabled) } }
    var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) } }
    /// Path of the bench shown in the menu bar when there are several.
    var selectedBench: String { didSet { defaults.set(selectedBench, forKey: Key.selectedBench) } }
    var askedForNotifications: Bool { didSet { defaults.set(askedForNotifications, forKey: Key.askedForNotifications) } }
    /// Open in Editor: a bundle id from `Editors.known`; empty means the first installed.
    var editorBundleID: String { didSet { defaults.set(editorBundleID, forKey: Key.editorBundleID) } }
    /// Ask GitHub for the latest release once a day (UpdateOffer).
    var checkUpdatesAutomatically: Bool { didSet { defaults.set(checkUpdatesAutomatically, forKey: Key.checkUpdatesAutomatically) } }

    /// The walkthrough has been shown once on its own (never again after that).
    var walkthroughSeen: Bool { didSet { defaults.set(walkthroughSeen, forKey: Key.walkthroughSeen) } }

    /// The editors that are installed. Launch Services answers from disk, so
    /// it is asked once at launch and again when any app launches or quits
    /// (an editor installed since is found when it first runs), never from
    /// a view body.
    private(set) var installedEditors: [Editor] = []

    /// The editor Open in Editor uses right now, nil when none is installed.
    var editor: Editor? { Editors.choice(preferred: editorBundleID, installed: installedEditors) }

    init(defaults: UserDefaults = .standard, findEditors: @escaping () -> [Editor] = Editors.installedNow) {
        self.defaults = defaults
        self.findEditors = findEditors
        defaults.register(defaults: [
            Key.runnerID: "bench",
            Key.speedEnabled: true,
            Key.notificationsEnabled: true,
            Key.checkUpdatesAutomatically: true,
        ])
        cliPath = defaults.string(forKey: Key.cliPath) ?? ""
        scanFolder = defaults.string(forKey: Key.scanFolder) ?? ""
        askedForCLI = defaults.bool(forKey: Key.askedForCLI)
        runnerID = defaults.string(forKey: Key.runnerID) ?? "bench"
        speedEnabled = defaults.bool(forKey: Key.speedEnabled)
        notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        selectedBench = defaults.string(forKey: Key.selectedBench) ?? ""
        askedForNotifications = defaults.bool(forKey: Key.askedForNotifications)
        editorBundleID = defaults.string(forKey: Key.editorBundleID) ?? ""
        checkUpdatesAutomatically = defaults.bool(forKey: Key.checkUpdatesAutomatically)
        walkthroughSeen = defaults.bool(forKey: Key.walkthroughSeen)
        installedEditors = findEditors()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshEditors() }
            })
        }
    }

    /// Looks again; the views redraw only when the list changed.
    func refreshEditors() {
        let found = findEditors()
        if found != installedEditors { installedEditors = found }
    }
}
