import Foundation

/// Posts the host's room notices. Kept apart from Notifier (bench crashes)
/// and given only words built by HostAmbient or the setup sheet, none of
/// which can hold the room code. They go through the same Notifier, so the
/// same switch, permission check and error handling apply.
enum ShareNotices {
    /// Set by the app delegate at launch.
    static var notifier: Notifier?

    static func post(title: String, body: String, bench: String, identifier: String? = nil) {
        let id = identifier ?? "benchbar.share.\(UUID().uuidString)"
        let notice = OutgoingNotice(identifier: id, title: title, body: body, thread: bench, bench: bench, sound: true)
        guard let notifier else { return }
        Task { await notifier.deliver(notice) }
    }
}
