import Foundation

/// The result envelope of a CLI run (docs/json-schema.md, "The result envelope"): the fields the last
/// stdout line of every command carries under --json, --jsonl and --for-agent. One decoder for the done
/// line of a stream, the document of a command that changed things and the document of a read, so no
/// caller parses `exit`, `warnings` or `next_actions` on its own. Every field is read on its own: a field
/// of another type (a newer CLI) is dropped and never costs the fields around it.
nonisolated struct ResultEnvelope: Sendable, Equatable {
    struct Change: Sendable, Equatable {
        var kind: String
        var name: String
        var detail: String
    }

    struct NextAction: Sendable, Equatable {
        var command: String
        var why: String
        /// Every word of the command is quoted for the shell: a program may split it.
        var quoted: Bool
    }

    /// The exit code the process ended with; nil when no line had the envelope.
    var exit: Int?
    var error: String?
    var errorID: String?
    var changed: [Change] = []
    var warnings: [String] = []
    var nextActions: [NextAction] = []
    /// The inputs a non interactive refusal lacked (`--yes`, `ADMIN_PASSWORD`, ...).
    var missing: [String] = []

    /// The run ended with exit 0.
    var succeeded: Bool { exit == 0 }

    /// The envelope of one JSON object; nil when it has no integer `exit`.
    init?(object: [String: Any]) {
        guard let code = object["exit"] as? Int else { return nil }
        exit = code
        error = object["error"] as? String
        errorID = object["error_id"] as? String
        warnings = (object["warnings"] as? [Any])?.compactMap { $0 as? String } ?? []
        missing = (object["missing"] as? [Any])?.compactMap { $0 as? String } ?? []
        changed = (object["changed"] as? [Any])?.compactMap { item in
            guard let o = item as? [String: Any], let kind = o["kind"] as? String else { return nil }
            return Change(kind: kind, name: o["name"] as? String ?? "", detail: o["detail"] as? String ?? "")
        } ?? []
        nextActions = (object["next_actions"] as? [Any])?.compactMap { item in
            // an older reader's shape, a bare string, still reads
            if let text = item as? String { return NextAction(command: text, why: "", quoted: false) }
            guard let o = item as? [String: Any], let command = o["command"] as? String else { return nil }
            return NextAction(command: command, why: o["why"] as? String ?? "", quoted: o["quoted"] as? Bool ?? false)
        } ?? []
    }

    /// An envelope with nothing in it: no line of the output had one.
    init() {}

    /// The last line of `stdout` that is a JSON object with an `exit`; an empty envelope (`exit` nil) if there is none.
    static func parse(_ stdout: String) -> ResultEnvelope {
        for line in stdout.split(separator: "\n").reversed() {
            guard line.first == "{",
                  let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let envelope = ResultEnvelope(object: object) else { continue }
            return envelope
        }
        return ResultEnvelope()
    }
}

extension CommandOutput {
    /// What the CLI said about the run itself, in its last JSON line.
    nonisolated var envelope: ResultEnvelope { ResultEnvelope.parse(stdout) }
}
