import AppKit
import Observation
import UserNotifications

/// The words of one notification. Pure, so they are tested without the
/// notification center.
nonisolated struct AlertContent: Equatable, Sendable {
    var identifier: String
    var title: String
    var body: String
    /// Notifications for one bench group together in Notification Center.
    var thread: String

    static func make(_ alert: BenchAlert, benchPath: String, name: String, url: String) -> AlertContent {
        let title: String
        let body: String
        let kind: String
        switch alert {
        case .crashed(let exitCode):
            kind = "crashed"
            title = "\(name) crashed"
            if let exitCode {
                body = "honcho exited with code \(exitCode). launchd is restarting it."
            } else {
                body = "honcho stopped unexpectedly. launchd is restarting it."
            }
        case .crashGuardTripped:
            kind = "paused"
            title = "\(name) keeps crashing"
            body = "3 crashes in 10 minutes, so automatic restarts are paused. Check the logs, then press Start."
        case .recovered:
            kind = "recovered"
            title = "\(name) is running again"
            body = "\(url) is back."
        }
        // one identifier per bench and kind: a new crash replaces the old banner
        return AlertContent(identifier: "benchbar.\(kind).\(benchPath)", title: title, body: body, thread: benchPath)
    }
}

/// Posts crash, crash guard and recovery notifications, and opens the
/// popover when one is clicked.
@Observable
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Permission: Equatable {
        case notAsked, allowed, denied
    }

    nonisolated static let benchKey = "bench"

    private(set) var permission: Permission = .notAsked

    /// Called with the bench path when the user clicks a notification.
    @ObservationIgnored var onOpen: ((String) -> Void)?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var center: UNUserNotificationCenter { .current() }

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
    }

    /// Becomes the delegate (so clicks reach us and banners show while the
    /// popover is open) and asks for permission once, on first run.
    func start() {
        center.delegate = self
        Task {
            if !settings.askedForNotifications && settings.notificationsEnabled {
                await requestPermission()
            } else {
                await refresh()
            }
        }
    }

    func requestPermission() async {
        settings.askedForNotifications = true
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await refresh()
    }

    func refresh() async {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral: permission = .allowed
        case .denied: permission = .denied
        case .notDetermined: permission = .notAsked
        @unknown default: permission = .denied
        }
    }

    func post(_ alert: BenchAlert, bench: BenchModel) {
        guard settings.notificationsEnabled else { return }
        let text = AlertContent.make(alert, benchPath: bench.path, name: bench.name,
                                     url: bench.status?.webURL ?? bench.summary.webURL)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.threadIdentifier = text.thread
        content.userInfo = [Self.benchKey: bench.path]
        if alert != .recovered { content.sound = .default }
        center.add(UNNotificationRequest(identifier: text.identifier, content: content, trigger: nil))
    }

    /// System Settings, Notifications, BenchBar.
    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.akashmishra.benchbar"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show the banner even while BenchBar is the active app (popover open).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let path = response.notification.request.content.userInfo[Self.benchKey] as? String else { return }
        await MainActor.run { self.onOpen?(path) }
    }
}
