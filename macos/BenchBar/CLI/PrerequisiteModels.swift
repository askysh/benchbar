import Foundation

/// One check of `benchbar doctor --prerequisites --json` (0.8): what a Mac
/// needs before `install`. Same fields as a doctor check, plus the facts
/// two checks carry.
nonisolated struct Prerequisite: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var label: String
    var level: CheckLevel
    var message: String
    var fixCommand: String?
    /// `disk_free`
    var freeGB: Double?
    /// `default_ports`: the port block a new bench would get.
    var portOffset: Int?

    enum CodingKeys: String, CodingKey {
        case id, label, level, message
        case fixCommand = "fix_command"
        case freeGB = "free_gb"
        case portOffset = "port_offset"
    }

    init(id: String, label: String, level: CheckLevel, message: String, fixCommand: String? = nil,
         freeGB: Double? = nil, portOffset: Int? = nil) {
        self.id = id
        self.label = label
        self.level = level
        self.message = message
        self.fixCommand = fixCommand
        self.freeGB = freeGB
        self.portOffset = portOffset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        level = try c.decodeIfPresent(CheckLevel.self, forKey: .level) ?? .unknown
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        fixCommand = try c.decodeIfPresent(String.self, forKey: .fixCommand)
        freeGB = try c.decodeIfPresent(Double.self, forKey: .freeGB)
        portOffset = try c.decodeIfPresent(Int.self, forKey: .portOffset)
    }
}

nonisolated struct PrerequisiteReport: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var cliVersion: String?
    var bench: String?
    var prerequisites: [Prerequisite]
    var summary: DoctorSummary?

    enum CodingKeys: String, CodingKey {
        case bench, prerequisites, summary
        case schemaVersion = "schema_version"
        case cliVersion = "cli_version"
    }

    func check(_ id: String) -> Prerequisite? { prerequisites.first { $0.id == id } }

    var failing: [Prerequisite] { prerequisites.filter { $0.level == .fail } }

    /// Continue is possible when nothing fails (a warning does not stop an install).
    var canContinue: Bool { failing.isEmpty }

    /// The port block to prefill, when the default ports are taken.
    var portOffsetToUse: Int? {
        guard let check = check("default_ports"), check.level == .warn else { return nil }
        return check.portOffset
    }

    /// The chosen folder's own warning or failure, for the New Bench page.
    var folderProblem: Prerequisite? {
        guard let check = check("bench_folder"), check.level != .ok else { return nil }
        return check
    }

    /// The runner wakes up as rows pass: asleep while none does, starting
    /// while some do, running when every row is ok.
    var runnerState: BenchState {
        PrerequisiteRows.runnerState(prerequisites)
    }
}

/// The Check Your Mac page: one row per check, and what its button does.
nonisolated struct PrerequisiteRow: Equatable, Sendable, Identifiable {
    enum Action: Equatable, Sendable {
        case none
        /// The one command the app starts that is not benchbar: opens Apple's dialog.
        case installCommandLineTools
        /// A command the app never runs: shown with Copy and Check Again.
        /// `note` is the step before it, in words.
        case copy(String, note: String? = nil)
        /// What to do in words (CleanMyMac's Ignore List, free disk space):
        /// shown as text, with nothing to copy.
        case advice(String)
    }

    var id: String
    var label: String
    var message: String
    var level: CheckLevel
    var action: Action

    static func make(_ check: Prerequisite) -> PrerequisiteRow {
        let action: Action
        if check.level == .ok {
            action = .none
        } else if check.id == "command_line_tools", check.level == .fail {
            action = .installCommandLineTools
        } else if check.id == "default_ports" {
            // its fix ("the new bench gets port block 1 (--port-offset 1)") is
            // what the New Bench page does by itself, not a command to copy
            action = .none
        } else if let fix = check.fixCommand, !fix.isEmpty {
            action = FixText.action(fix)
        } else {
            action = .none
        }
        return PrerequisiteRow(id: check.id, label: check.label, message: check.message, level: check.level, action: action)
    }
}

/// A prerequisite's `fix_command` is a command or a sentence: Mole's, with no
/// whitelist file yet, is both ("run 'mo clean --whitelist' and save once
/// (...), then: echo ... >> ~/.config/mole/whitelist").
nonisolated enum FixText {
    /// The first words of the fixes that are commands; any other fix is advice.
    static let commandNames: Set<String> = ["echo", "xcode-select", "brew", "benchbar", "curl", "sudo", "mo", "mole", "git", "mkdir", "open"]

    static func isCommand(_ text: String) -> Bool {
        guard let first = text.split(separator: " ").first else { return false }
        return first.hasPrefix("/") || commandNames.contains(String(first))
    }

    static func action(_ fix: String) -> PrerequisiteRow.Action {
        if let then = fix.range(of: ", then: "), isCommand(String(fix[then.upperBound...])) {
            return .copy(String(fix[then.upperBound...]), note: sentence(String(fix[..<then.lowerBound])) + ", then:")
        }
        if isCommand(fix) { return .copy(fix) }
        let text = sentence(fix)
        return .advice(text.hasSuffix(".") ? text : text + ".")
    }

    /// The CLI's fix starts lowercase ("free space on ..."): a sentence does not.
    private static func sentence(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}

nonisolated enum PrerequisiteRows {
    static func rows(_ report: PrerequisiteReport?) -> [PrerequisiteRow] {
        (report?.prerequisites ?? []).map(PrerequisiteRow.make)
    }

    /// sleeping (stopped) with no row ok or no answer, starting with some,
    /// running with all.
    static func runnerState(_ checks: [Prerequisite]) -> BenchState {
        let passing = checks.filter { $0.level == .ok }.count
        if checks.isEmpty || passing == 0 { return .stopped }
        return passing == checks.count ? .running : .starting
    }

    /// The page polls only while Command Line Tools are missing: Apple's
    /// installer finishes on its own, the row should notice.
    static func shouldPoll(_ report: PrerequisiteReport?) -> Bool {
        report?.check("command_line_tools")?.level == .fail
    }
}

/// `xcode-select --install`: the single command the app starts that is not
/// benchbar. It only opens Apple's installer dialog.
nonisolated enum CommandLineTools {
    static let executable = URL(fileURLWithPath: "/usr/bin/xcode-select")
    static let arguments = ["--install"]

    /// nil when the dialog opened. xcode-select exits 1 with a sentence when
    /// the tools are already there or an install is under way.
    static func install(runner: any CommandRunning = SubprocessRunner()) async -> String? {
        do {
            let output = try await runner.run(executable: executable, arguments: arguments, environment: [:], timeout: .seconds(20))
            guard output.exitCode != 0 else { return nil }
            let text = (output.stderr + "\n" + output.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "xcode-select --install failed (exit code \(output.exitCode))." : text
        } catch {
            return error.localizedDescription
        }
    }
}
