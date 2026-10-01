import Foundation
import os

/// The app's log, under its bundle id: `log stream --level info --predicate
/// 'subsystem == "com.akashmishra.benchbar"'` shows it live.
nonisolated enum Log {
    /// Every process the app starts, one `.info` line each ("cli: status
    /// (utility)"), so the calls the app makes at rest can be counted.
    static let cli = logger("cli")
    /// When and why the store refreshes, samples and switches modes.
    static let poll = logger("poll")

    /// Silent in the test host: it is a BenchBar process with the same
    /// subsystem, and its fake CLI calls would count next to a running app.
    private static func logger(_ category: String) -> Logger {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return Logger(.disabled) }
        return Logger(subsystem: "com.akashmishra.benchbar", category: category)
    }
}
