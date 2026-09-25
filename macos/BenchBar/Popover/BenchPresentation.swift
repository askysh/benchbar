import Foundation

/// Which of Start, Stop and Restart make sense right now. Pure, so the
/// rules are tested without a popover.
nonisolated struct BenchControls: Equatable, Sendable {
    var canStart = false
    var canStop = false
    var canRestart = false
    /// An action is running: show a spinner on its button.
    var busy: CLIClient.Action?

    static let none = BenchControls()

    static func make(state: BenchState, reason: StopReason?, pending: CLIClient.Action?,
                     needsService: Bool, cliReady: Bool) -> BenchControls {
        guard cliReady, !needsService else { return .none }
        if let pending { return BenchControls(busy: pending) }
        // a bench with a missing env needs repair; starting it would only fail again
        let broken = reason == .broken
        switch state {
        case .stopped:
            return BenchControls(canStart: !broken)
        case .starting, .running:
            return BenchControls(canStop: true, canRestart: true)
        case .crashed:
            // launchd is retrying: stop it, or restart with a clean slate
            return BenchControls(canStop: true, canRestart: true)
        case .paused:
            // up clears the crash history and tries again
            return BenchControls(canStart: !broken)
        case .unknown:
            return BenchControls(canStart: true, canStop: true)
        }
    }
}

/// Words for the popover.
nonisolated enum BenchText {
    static func headline(_ state: BenchState, reason: StopReason?, exitCode: Int?) -> String {
        switch state {
        case .stopped:
            return reason == .broken ? "Stopped: needs repair" : "Stopped"
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case .crashed:
            if let exitCode { return "Crashed (exit \(exitCode)), restarting" }
            return "Crashed, restarting"
        case .paused:
            switch reason {
            case .broken: return "Paused: needs repair"
            case .manual: return "Stopped"
            default: return "Paused after repeated crashes"
            }
        case .unknown:
            return "State unknown"
        }
    }

    /// "45s", "12m", "3h 05m", "2d 4h".
    static func uptime(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let minutes = seconds / 60, hours = minutes / 60, days = hours / 24
        if days > 0 { return "\(days)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h " + String(format: "%02dm", minutes % 60) }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    /// A CLI command line for a bench, as the user would type it.
    static func command(_ words: String, bench: String) -> String {
        "benchbar \(words) --bench-dir \(Shell.quote(bench))"
    }
}

extension DoctorReport {
    /// Checks worth reading first: fail, then warn, then anything unknown.
    nonisolated var needsAttention: [DoctorCheck] {
        checks.filter { $0.level != .ok }.sorted { Self.rank($0.level) < Self.rank($1.level) }
    }

    nonisolated var passing: [DoctorCheck] {
        checks.filter { $0.level == .ok }
    }

    nonisolated private static func rank(_ level: CheckLevel) -> Int {
        switch level {
        case .fail: 0
        case .warn: 1
        case .unknown: 2
        case .ok: 3
        }
    }
}

nonisolated enum Shell {
    /// Single quotes a word for zsh or bash: 'it'\''s'.
    static func quote(_ word: String) -> String {
        if !word.isEmpty, word.allSatisfy({ $0.isLetter || $0.isNumber || "/._-+=:@".contains($0) }) {
            return word
        }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The script "Open logs" runs in Terminal: benchbar logs follows the log
/// with tail -f when it has a terminal.
nonisolated enum LogsScript {
    static func contents(cli: String, bench: String, lines: Int = 200) -> String {
        """
        #!/bin/zsh
        # Opened by BenchBar: follows the bench log. Close the window to stop.
        clear
        exec \(Shell.quote(cli)) logs -n\(lines) --bench-dir \(Shell.quote(bench))

        """
    }
}

/// What the menu bar runner shows when there is more than one bench: the
/// worst state wins, so a crash anywhere is never hidden behind a bench
/// that runs fine. Pure, so the order is tested without an app.
nonisolated enum BenchAggregate {
    ///   any crashed or paused bench   stumbles
    ///   else any starting             walks
    ///   else any running              runs
    ///   else                          sleeps (unknown until something is known)
    static func state(_ states: [BenchState]) -> BenchState {
        let known = states.filter { $0 != .unknown }
        if known.isEmpty { return .unknown }
        if known.contains(.crashed) { return .crashed }
        if known.contains(.paused) { return .paused }
        if known.contains(.starting) { return .starting }
        if known.contains(.running) { return .running }
        return .stopped
    }

    /// Benches that are up (running or starting), for the count in the header.
    static func upCount(_ states: [BenchState]) -> Int {
        states.filter { $0 == .running || $0 == .starting }.count
    }

    /// "2 of 3 up", "none up".
    static func upText(_ states: [BenchState]) -> String {
        let up = upCount(states)
        return up == 0 ? "none up" : "\(up) of \(states.count) up"
    }
}

/// One line of the sites list in the popover.
nonisolated struct SiteRow: Equatable, Sendable, Identifiable {
    var name: String
    var isDefault: Bool
    var url: String
    var needsHosts: Bool

    var id: String { name }

    /// The default site first, then by name. Without sites from the CLI (a
    /// CLI older than 0.4) the bench's own site is the only row.
    static func make(sites: [SiteInfo]?, defaultSite: String, port: Int) -> [SiteRow] {
        let infos = sites ?? [SiteInfo(name: defaultSite, isDefault: true, hostsEntry: true, pingCode: nil)]
        return infos
            .map { SiteRow(name: $0.name, isDefault: $0.isDefault, url: "http://\($0.name):\(port)", needsHosts: !$0.hostsEntry) }
            .sorted { ($0.isDefault ? 0 : 1, $0.name) < ($1.isDefault ? 0 : 1, $1.name) }
    }

    /// The command that adds every missing hosts line, when one is missing.
    static func hostsFix(_ rows: [SiteRow], bench: String) -> String? {
        rows.contains(where: \.needsHosts) ? BenchText.command("site hosts", bench: bench) : nil
    }
}
