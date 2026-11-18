import AppKit

/// One BenchBar at a time. Launch Services refuses a second launch of the
/// same bundle path, but a Homebrew cask copy, a DMG copy, a copy in
/// ~/Applications and a build from Xcode are other paths: two of them run
/// two stores, two sets of folder watchers and status polls, and (with the
/// lab on) two share pollers on the same room.
nonisolated enum SingleInstance {
    /// A process with this app's bundle id.
    struct Other: Equatable, Sendable {
        var pid: Int32
        var isTerminated: Bool
    }

    /// The running copy to hand over to, nil when this copy goes on.
    static func copyToHandOverTo(others: [Other], mine: Int32) -> Other? {
        others.first { $0.pid != mine && !$0.isTerminated }
    }

    /// True when another copy runs: it is brought to the front (opening it
    /// again shows its window) and this process should exit. Never under the
    /// tests, which run inside the app (TEST_HOST), and not with
    /// BENCHBAR_ALLOW_SECOND_COPY=1 (a build under test next to the installed app).
    @MainActor
    static func yieldToRunningCopy(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard environment["XCTestConfigurationFilePath"] == nil, environment["BENCHBAR_ALLOW_SECOND_COPY"] != "1",
              let id = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .map { Other(pid: $0.processIdentifier, isTerminated: $0.isTerminated) }
        let mine = ProcessInfo.processInfo.processIdentifier
        guard let target = copyToHandOverTo(others: others, mine: mine),
              let running = NSRunningApplication(processIdentifier: target.pid) else { return false }
        Log.app.info("another BenchBar runs (pid \(target.pid, privacy: .public)): handing over")
        if let url = running.bundleURL {
            // opening a running app again is the reopen event: its window shows
            let done = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in done.signal() }
            _ = done.wait(timeout: .now() + 2)
        } else {
            running.activate()
        }
        return true
    }
}
