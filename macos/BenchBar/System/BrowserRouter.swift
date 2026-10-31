import AppKit

/// What Open as needs from the browser, so tests need none.
protocol BrowserOpening {
    func open(_ url: URL)
}

/// Picks the browser a switch opens in: the supported browser that was
/// frontmost last (the one whose cookies are being tested), else the default
/// browser if it runs, else the first supported browser that runs, and only
/// then the default browser. It reads no tab and sends no Apple Events.
final class BrowserRouter: BrowserOpening {
    nonisolated static let safari = "com.apple.Safari"
    nonisolated static let firefox = "org.mozilla.firefox"
    /// Safari, then the Chromium family and Arc, then Firefox.
    nonisolated static let supported = [safari, "com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser",
                                         "com.microsoft.edgemac", firefox]

    private(set) var testingBrowser: String?

    init() {
        testingBrowser = NSWorkspace.shared.frontmostApplication?.bundleIdentifier.flatMap(Self.supportedID)
        // lives as long as the app: the router is made once, when Open as is first used
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                if let id, let known = Self.supportedID(id) { self?.testingBrowser = known }
            }
        }
    }

    nonisolated static func supportedID(_ bundleID: String) -> String? {
        supported.contains(bundleID) ? bundleID : nil
    }

    func open(_ url: URL) {
        if let id = runningTestingBrowser, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// The testing browser, only while it runs.
    private var runningTestingBrowser: String? {
        Self.browser(testing: testingBrowser, running: Set(Self.supported.filter(isRunning)), defaultBrowser: Self.defaultBrowserID())
    }

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: pure

    /// The tested browser while it runs, else the default browser if it runs,
    /// else the first supported one that runs (in `supported` order), else nil
    /// for the default browser: a Safari left open in the background must not
    /// win over a Chrome the person set as default.
    nonisolated static func browser(testing: String?, running: Set<String>, defaultBrowser: String? = nil) -> String? {
        if let testing, running.contains(testing) { return testing }
        if let defaultBrowser, running.contains(defaultBrowser) { return defaultBrowser }
        return supported.first(where: running.contains)
    }

    nonisolated static func defaultBrowserID() -> String? {
        guard let probe = URL(string: "http://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }
}
