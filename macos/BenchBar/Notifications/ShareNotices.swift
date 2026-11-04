import Foundation
import UserNotifications

/// Posts the host's room notices. Kept apart from Notifier (bench crashes)
/// and given only words built by HostAmbient or the setup sheet, none of
/// which can hold the room code.
enum ShareNotices {
    static let enabledKey = "notificationsEnabled"

    static func post(title: String, body: String, bench: String, identifier: String? = nil) {
        // the same switch the bench notifications obey (AppSettings.notificationsEnabled)
        if UserDefaults.standard.object(forKey: enabledKey) as? Bool == false { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = bench
        content.userInfo = [Notifier.benchKey: bench]
        content.sound = .default
        let id = identifier ?? "benchbar.share.\(UUID().uuidString)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
