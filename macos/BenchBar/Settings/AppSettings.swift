import Foundation
import Observation

/// User preferences, stored in UserDefaults (~/Library/Preferences/com.akashmishra.benchbar.plist).
///
/// @Observable makes SwiftUI views that read a property redraw when it
/// changes; didSet writes the value through to UserDefaults.
@Observable
final class AppSettings {
    enum Key {
        static let cliPath = "cliPath"
        static let askedForCLI = "askedForCLI"
        static let runnerID = "runnerID"
        static let speedEnabled = "speedEnabled"
        static let notificationsEnabled = "notificationsEnabled"
        static let selectedBench = "selectedBench"
        static let askedForNotifications = "askedForNotifications"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Absolute path to benchbar chosen by the user; empty means "search".
    var cliPath: String { didSet { defaults.set(cliPath, forKey: Key.cliPath) } }
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.runnerID: "bench",
            Key.speedEnabled: true,
            Key.notificationsEnabled: true,
        ])
        cliPath = defaults.string(forKey: Key.cliPath) ?? ""
        askedForCLI = defaults.bool(forKey: Key.askedForCLI)
        runnerID = defaults.string(forKey: Key.runnerID) ?? "bench"
        speedEnabled = defaults.bool(forKey: Key.speedEnabled)
        notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        selectedBench = defaults.string(forKey: Key.selectedBench) ?? ""
        askedForNotifications = defaults.bool(forKey: Key.askedForNotifications)
    }
}
