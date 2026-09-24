import Foundation
import Observation
import ServiceManagement

/// Launch at login for the app itself, with SMAppService.mainApp (macOS 13+).
/// Bench agents are separate: the CLI owns those plists.
@Observable
final class LaunchAtLogin {
    enum Status: Equatable {
        case enabled
        case disabled
        /// Registered, but the user has to allow it in System Settings, Login Items.
        case requiresApproval
        /// macOS cannot find the app, for example when it runs from a disk image.
        case notFound
    }

    private(set) var status: Status = .disabled
    private(set) var lastError: String?

    init() { refresh() }

    var isOn: Bool { status == .enabled || status == .requiresApproval }

    func refresh() {
        status = Self.map(SMAppService.mainApp.status)
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func map(_ status: SMAppService.Status) -> Status {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .disabled
        @unknown default: .disabled
        }
    }
}
