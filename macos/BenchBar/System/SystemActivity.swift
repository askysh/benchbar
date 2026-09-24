import AppKit

/// Why the app should be idle right now. Pure, so it is easy to test: each
/// reason is set and cleared by its own pair of notifications, and the app
/// is active only when no reason is left.
nonisolated struct ActivityGate: Equatable, Sendable {
    enum Reason: Hashable, Sendable {
        case systemSleep, screenSleep, screenLocked, sessionInactive
    }

    private(set) var reasons: Set<Reason> = []

    var isActive: Bool { reasons.isEmpty }

    /// Returns true when this flips the gate between active and idle.
    mutating func set(_ reason: Reason, idle: Bool) -> Bool {
        let wasActive = isActive
        if idle { reasons.insert(reason) } else { reasons.remove(reason) }
        return wasActive != isActive
    }
}

/// Watches sleep, screen sleep, screen lock, fast user switching and the
/// Reduce Motion setting, and reports changes.
final class SystemActivityMonitor {
    /// Called with true on wake (all reasons cleared), false on the first idle reason.
    var onActiveChange: ((Bool) -> Void)?
    var onReduceMotionChange: ((Bool) -> Void)?

    private(set) var gate = ActivityGate()
    private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    var isActive: Bool { gate.isActive }

    func start() {
        guard tokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, ActivityGate.Reason, Bool)] = [
            (NSWorkspace.willSleepNotification, .systemSleep, true),
            (NSWorkspace.didWakeNotification, .systemSleep, false),
            (NSWorkspace.screensDidSleepNotification, .screenSleep, true),
            (NSWorkspace.screensDidWakeNotification, .screenSleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false),
        ]
        for (name, reason, idle) in pairs {
            observe(workspace, name) { $0.update(reason, idle: idle) }
        }
        // screen lock has no NSWorkspace notification; loginwindow posts these
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.update(.screenLocked, idle: true) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.update(.screenLocked, idle: false) }

        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { monitor in
            let now = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            guard now != monitor.reduceMotion else { return }
            monitor.reduceMotion = now
            monitor.onReduceMotionChange?(now)
        }
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }

    private func update(_ reason: ActivityGate.Reason, idle: Bool) {
        if gate.set(reason, idle: idle) {
            onActiveChange?(gate.isActive)
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handle: @escaping @MainActor (SystemActivityMonitor) -> Void) {
        // queue .main delivers on the main thread; assumeIsolated tells Swift so
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handle(self)
            }
        }
        tokens.append((center, token))
    }
}
