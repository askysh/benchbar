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
            title = String(localized: "\(name) crashed")
            if let exitCode {
                body = String(localized: "honcho exited with code \(exitCode). launchd is restarting it.")
            } else {
                body = String(localized: "honcho stopped unexpectedly. launchd is restarting it.")
            }
        case .crashGuardTripped:
            kind = "paused"
            title = String(localized: "\(name) keeps crashing")
            body = String(localized: "3 crashes in 10 minutes, so automatic restarts are paused. Check the logs, then press Start.")
        case .recovered:
            kind = "recovered"
            title = String(localized: "\(name) is running again")
            body = String(localized: "\(url) is back.")
        }
        // one identifier per bench and kind: a new crash replaces the old banner
        return AlertContent(identifier: "benchbar.\(kind).\(benchPath)", title: title, body: body, thread: benchPath)
    }
}

/// What the notification center is asked to show: plain values, so a fake
/// center in a test sees the same thing the system does.
nonisolated struct OutgoingNotice: Equatable, Sendable {
    var identifier: String
    var title: String
    var body: String
    var thread: String
    /// The bench a click opens in the popover.
    var bench: String
    var sound: Bool
}

/// The three things BenchBar needs from the notification center.
nonisolated protocol NotificationCentering: Sendable {
    func permission() async -> Notifier.Permission
    /// Shows the system's question. Returns when the person has answered.
    func requestPermission() async
    func add(_ notice: OutgoingNotice) async throws
}

nonisolated struct SystemNotificationCenter: NotificationCentering {
    func permission() async -> Notifier.Permission {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        case .notDetermined: .notAsked
        @unknown default: .denied
        }
    }

    func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func add(_ notice: OutgoingNotice) async throws {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.threadIdentifier = notice.thread
        content.userInfo = [Notifier.benchKey: notice.bench]
        if notice.sound { content.sound = .default }
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil))
    }
}

/// Posts crash, crash guard and recovery notifications, and opens the
/// popover when one is clicked.
///
/// The system's permission question comes once, with the first notice that
/// has something to say (a crash), not at launch: the person has then seen
/// what BenchBar does. A notice is sent only when the switch is on and the
/// permission is given; a refused or failed send is logged and shown in
/// Settings, never dropped silently.
@Observable
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated enum Permission: Equatable, Sendable {
        case notAsked, allowed, denied
    }

    /// What became of one notice.
    nonisolated enum Delivery: Equatable, Sendable {
        case sent
        case switchedOff
        case notAllowed
        case failed(String)
    }

    nonisolated static let benchKey = "bench"

    private(set) var permission: Permission = .notAsked
    /// The last send the system refused, for Settings; nil after a send that worked.
    private(set) var lastSendError: String?

    /// Called with the bench path when the user clicks a notification.
    @ObservationIgnored var onOpen: ((String) -> Void)?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let center: any NotificationCentering

    init(settings: AppSettings, center: any NotificationCentering = SystemNotificationCenter()) {
        self.settings = settings
        self.center = center
        super.init()
    }

    /// Becomes the delegate (so clicks reach us and banners show while the
    /// popover is open) and reads the permission. It asks for nothing.
    @discardableResult
    func start(registerDelegate: Bool = true) -> Task<Void, Never> {
        if registerDelegate { UNUserNotificationCenter.current().delegate = self }
        return Task { await refresh() }
    }

    /// The system's question while it is on screen, so a second notice that arrives
    /// before the answer waits for it instead of reading "not asked yet" and being dropped.
    @ObservationIgnored private var question: Task<Void, Never>?

    func requestPermission() async {
        if let running = question {
            await running.value
            await refresh()
            return
        }
        settings.askedForNotifications = true
        let center = center
        let running = Task { await center.requestPermission() }
        question = running
        await running.value
        question = nil
        await refresh()
    }

    func refresh() async {
        permission = await center.permission()
    }

    func post(_ alert: BenchAlert, bench: BenchModel) {
        let text = AlertContent.make(alert, benchPath: bench.path, name: bench.name,
                                     url: bench.status?.webURL ?? bench.summary.webURL)
        let notice = OutgoingNotice(identifier: text.identifier, title: text.title, body: text.body, thread: text.thread,
                                    bench: bench.path, sound: alert != .recovered)
        Task { await deliver(notice) }
    }

    /// The one way out for every notice (bench alerts and room notices).
    @discardableResult
    func deliver(_ notice: OutgoingNotice) async -> Delivery {
        guard settings.notificationsEnabled else { return .switchedOff }
        await refresh()
        if permission == .notAsked && (!settings.askedForNotifications || question != nil) {
            await requestPermission()
        }
        guard permission == .allowed else {
            Log.poll.info("notification not sent: permission is \(String(describing: self.permission), privacy: .public)")
            return .notAllowed
        }
        do {
            try await center.add(notice)
            lastSendError = nil
            return .sent
        } catch {
            let message = error.localizedDescription
            Log.poll.error("notification not sent: \(message, privacy: .public)")
            lastSendError = message
            return .failed(message)
        }
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
