import Foundation

// The JSON lines of `benchbar install --json` and `benchbar adopt PATH
// --json` (docs/json-schema.md, 0.8): one decoder for both. A line that is
// not an event this reader knows is ignored, an unknown field is ignored,
// an unknown step status reads as `.unknown`, and a schema_version above 1
// is refused like everywhere else.

nonisolated enum InstallStepStatus: String, Codable, Sendable {
    case running, done, unchanged, skipped, warning, failed, unknown
    /// The app's own word, never in the stream: the run ended (Stop, a
    /// signal) while the step still ran, so no end line came for it.
    case stopped

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InstallStepStatus(rawValue: raw) ?? .unknown
    }

    /// The step has ended, one way or another.
    var isFinal: Bool { self != .running && self != .unknown }
}

/// One step of the plan: the two privileged ones first (`n` nil), then the
/// numbered steps of the terminal output.
nonisolated struct InstallPlanStep: Codable, Sendable, Equatable, Identifiable {
    var n: Int?
    var id: String
    var name: String
    var sudo: Bool
    /// False when there is nothing to do: the package is in place, the line is in /etc/hosts.
    var willRun: Bool

    enum CodingKeys: String, CodingKey {
        case n, id, name, sudo
        case willRun = "will_run"
    }

    init(n: Int? = nil, id: String, name: String, sudo: Bool = false, willRun: Bool = true) {
        self.n = n
        self.id = id
        self.name = name
        self.sudo = sudo
        self.willRun = willRun
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        n = try c.decodeIfPresent(Int.self, forKey: .n)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        sudo = try c.decodeIfPresent(Bool.self, forKey: .sudo) ?? false
        willRun = try c.decodeIfPresent(Bool.self, forKey: .willRun) ?? true
    }
}

/// The `plan` line, first in every stream. `install` fills the bench
/// choices; `adopt` adds `ports_move`.
nonisolated struct InstallPlan: Codable, Sendable, Equatable {
    var bench: String
    var site: String
    var profile: String?
    var teamProfile: String?
    var bundle: String?
    var portOffset: Int?
    var portsMove: Bool?
    var webURL: String?
    var dryRun: Bool
    /// `terminal`, or `gui` under BENCHBAR_SUDO=gui.
    var sudoMode: String?
    var steps: [InstallPlanStep]
    var log: String?

    enum CodingKeys: String, CodingKey {
        case bench, site, profile, bundle, steps, log
        case teamProfile = "team_profile"
        case portOffset = "port_offset"
        case portsMove = "ports_move"
        case webURL = "web_url"
        case dryRun = "dry_run"
        case sudoMode = "sudo_mode"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bench = try c.decodeIfPresent(String.self, forKey: .bench) ?? ""
        site = try c.decodeIfPresent(String.self, forKey: .site) ?? ""
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
        teamProfile = try c.decodeIfPresent(String.self, forKey: .teamProfile)
        bundle = try c.decodeIfPresent(String.self, forKey: .bundle)
        portOffset = try c.decodeIfPresent(Int.self, forKey: .portOffset)
        portsMove = try c.decodeIfPresent(Bool.self, forKey: .portsMove)
        webURL = try c.decodeIfPresent(String.self, forKey: .webURL)
        dryRun = try c.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        sudoMode = try c.decodeIfPresent(String.self, forKey: .sudoMode)
        steps = try c.decodeIfPresent([InstallPlanStep].self, forKey: .steps) ?? []
        log = try c.decodeIfPresent(String.self, forKey: .log)
    }

    init(bench: String, site: String, profile: String? = nil, teamProfile: String? = nil, bundle: String? = nil,
         portOffset: Int? = nil, portsMove: Bool? = nil, webURL: String? = nil, dryRun: Bool = false,
         sudoMode: String? = nil, steps: [InstallPlanStep] = [], log: String? = nil) {
        self.bench = bench
        self.site = site
        self.profile = profile
        self.teamProfile = teamProfile
        self.bundle = bundle
        self.portOffset = portOffset
        self.portsMove = portsMove
        self.webURL = webURL
        self.dryRun = dryRun
        self.sudoMode = sudoMode
        self.steps = steps
        self.log = log
    }

    /// The steps that ask for the Mac's password, and that will run.
    var privilegedSteps: [InstallPlanStep] { steps.filter(\.sudo) }
}

/// A `step` line: a step starts (`running`) and ends (the final status).
/// A step with a `parent` is a section of that phase script or an action
/// of the service step.
nonisolated struct InstallStep: Codable, Sendable, Equatable {
    var n: Int?
    var id: String
    var parent: String?
    var name: String
    var status: InstallStepStatus
    /// Seconds, on the end of a step.
    var secs: Int?
    /// The CLI's `[FAIL]` or `[WARN]` line, for failed, skipped and warning.
    var message: String?
    /// What to run by hand, for a skipped privileged step.
    var command: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        n = try c.decodeIfPresent(Int.self, forKey: .n)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        status = try c.decodeIfPresent(InstallStepStatus.self, forKey: .status) ?? .unknown
        // a number, whole or with a fraction
        if let whole = try? c.decodeIfPresent(Int.self, forKey: .secs) {
            secs = whole
        } else {
            secs = (try? c.decodeIfPresent(Double.self, forKey: .secs)).map { Int($0.rounded()) }
        }
        message = try c.decodeIfPresent(String.self, forKey: .message)
        command = try c.decodeIfPresent(String.self, forKey: .command)
    }

    init(n: Int? = nil, id: String, parent: String? = nil, name: String, status: InstallStepStatus,
         secs: Int? = nil, message: String? = nil, command: String? = nil) {
        self.n = n
        self.id = id
        self.parent = parent
        self.name = name
        self.status = status
        self.secs = secs
        self.message = message
        self.command = command
    }
}

/// A `progress` line: every 10 seconds while a long command runs.
nonisolated struct InstallProgressLine: Codable, Sendable, Equatable {
    var step: String
    var label: String
    var elapsed: Int
    var bytes: Int64?
    var total: Int64?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        step = try c.decodeIfPresent(String.self, forKey: .step) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        elapsed = (try? c.decodeIfPresent(Int.self, forKey: .elapsed)) ?? 0
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes)
        total = try c.decodeIfPresent(Int64.self, forKey: .total)
    }

    init(step: String, label: String, elapsed: Int, bytes: Int64? = nil, total: Int64? = nil) {
        self.step = step
        self.label = label
        self.elapsed = elapsed
        self.bytes = bytes
        self.total = total
    }
}

/// A privileged step that was skipped, with what to run by hand.
nonisolated struct SkippedStep: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var command: String?
}

/// The `done` line: always the last, also after a failure or a signal.
nonisolated struct InstallDone: Codable, Sendable, Equatable {
    var exit: Int
    var bench: String?
    var site: String?
    /// Null unless `exit` is 0.
    var url: String?
    var skipped: [SkippedStep]
    var fix: String?
    var log: String?
    /// Only for a refusal before the plan.
    var error: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exit = try c.decodeIfPresent(Int.self, forKey: .exit) ?? 1
        bench = try c.decodeIfPresent(String.self, forKey: .bench)
        site = try c.decodeIfPresent(String.self, forKey: .site)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        skipped = try c.decodeIfPresent([SkippedStep].self, forKey: .skipped) ?? []
        fix = try c.decodeIfPresent(String.self, forKey: .fix)
        log = try c.decodeIfPresent(String.self, forKey: .log)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    init(exit: Int, bench: String? = nil, site: String? = nil, url: String? = nil, skipped: [SkippedStep] = [],
         fix: String? = nil, log: String? = nil, error: String? = nil) {
        self.exit = exit
        self.bench = bench
        self.site = site
        self.url = url
        self.skipped = skipped
        self.fix = fix
        self.log = log
        self.error = error
    }
}

nonisolated enum InstallEvent: Equatable, Sendable {
    case plan(InstallPlan)
    case step(InstallStep)
    case progress(InstallProgressLine)
    case done(InstallDone)

    /// One line of the stream. nil for a line that is not an event this
    /// reader knows (an unknown event, text, a broken line); throws only
    /// for a schema_version above 1.
    static func decode(_ line: String) throws(CLIError) -> InstallEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? String else { return nil }
        if let version = object["schema_version"] as? Int, version > BenchJSON.supportedSchema {
            throw .unsupportedSchema(found: version, supported: BenchJSON.supportedSchema)
        }
        let decoder = JSONDecoder()
        switch event {
        case "plan": return (try? decoder.decode(InstallPlan.self, from: data)).map(InstallEvent.plan)
        case "step": return (try? decoder.decode(InstallStep.self, from: data)).map(InstallEvent.step)
        case "progress": return (try? decoder.decode(InstallProgressLine.self, from: data)).map(InstallEvent.progress)
        case "done": return (try? decoder.decode(InstallDone.self, from: data)).map(InstallEvent.done)
        default: return nil
        }
    }

    /// Every event of a whole stream (a fixture, a log): unknown lines skipped.
    static func decodeAll(_ text: String) throws(CLIError) -> [InstallEvent] {
        var events: [InstallEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let event = try decode(String(line)) { events.append(event) }
        }
        return events
    }
}
