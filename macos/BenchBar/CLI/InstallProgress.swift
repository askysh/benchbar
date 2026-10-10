import Foundation

/// What an install or adopt stream has told so far, kept as the list the
/// wizard draws: the plan's steps in order, the nested steps under their
/// parent, the latest progress line and the end. Pure: events in, rows out.
nonisolated struct InstallProgress: Equatable, Sendable {
    nonisolated struct Row: Equatable, Sendable {
        /// `parent/id`: a section id such as `plan` repeats under two phases.
        var key: String
        var id: String
        var parent: String?
        var name: String
        var n: Int?
        /// nil: not started yet.
        var status: InstallStepStatus?
        var secs: Int?
        var message: String?
        var command: String?
        /// The plan marked it as privileged: it asks for the Mac's password.
        var sudo = false
        /// The plan said there was nothing to do for it.
        var alreadyDone = false

        static func key(_ id: String, parent: String?) -> String { "\(parent ?? "")/\(id)" }
    }

    private(set) var plan: InstallPlan?
    private(set) var rows: [Row] = []
    private(set) var progress: InstallProgressLine?
    private(set) var done: InstallDone?

    var log: String? { done?.log ?? plan?.log }
    var topLevel: [Row] { rows.filter { $0.parent == nil } }

    func children(of id: String) -> [Row] { rows.filter { $0.parent == id } }

    /// The step that failed: the last failed row, a nested one before its parent.
    var failedStep: Row? {
        rows.last { $0.status == .failed && $0.parent != nil } ?? rows.last { $0.status == .failed }
    }

    /// The steps that were skipped and carry a command to run by hand.
    var skippedWithCommand: [SkippedStep] {
        if let done, !done.skipped.isEmpty { return done.skipped.filter { $0.command != nil } }
        return rows.filter { $0.status == .skipped && $0.command != nil }.map { SkippedStep(id: $0.id, command: $0.command) }
    }

    /// The top level step that runs now.
    var running: Row? { topLevel.last { $0.status == .running } }

    /// The progress line belongs to a step still running (the line names a
    /// nested step or the top level one).
    func progress(for row: Row) -> InstallProgressLine? {
        guard let progress, row.status == .running else { return nil }
        if progress.step == row.id { return progress }
        // the line of a nested step shows under its running parent
        if row.parent == nil, children(of: row.id).contains(where: { $0.id == progress.step }) { return progress }
        // a step the stream never announced: under the top level step that runs
        if row.parent == nil, row.id == running?.id, !rows.contains(where: { $0.id == progress.step }) { return progress }
        return nil
    }

    mutating func apply(_ event: InstallEvent) {
        switch event {
        case .plan(let plan):
            self.plan = plan
            rows = plan.steps.map {
                Row(key: Row.key($0.id, parent: nil), id: $0.id, parent: nil, name: $0.name, n: $0.n, status: nil,
                    sudo: $0.sudo, alreadyDone: !$0.willRun)
            }
        case .step(let step):
            let key = Row.key(step.id, parent: step.parent)
            if let i = rows.firstIndex(where: { $0.key == key }) {
                rows[i].status = step.status
                rows[i].name = step.name
                if let secs = step.secs { rows[i].secs = secs }
                if let message = step.message, !message.isEmpty { rows[i].message = message }
                if let command = step.command { rows[i].command = command }
                if step.status.isFinal { rows[i].alreadyDone = false }
            } else {
                var row = Row(key: key, id: step.id, parent: step.parent, name: step.name, n: step.n, status: step.status,
                              secs: step.secs, message: step.message, command: step.command)
                row.alreadyDone = false
                insert(row)
            }
            if step.status.isFinal, progress?.step == step.id { progress = nil }
        case .progress(let line):
            progress = line
        case .done(let done):
            self.done = done
            progress = nil
            // a run ended by a signal (Stop) sends no end line for the steps
            // that ran: they stop spinning, as stopped, or failed otherwise
            for i in rows.indices where rows[i].status == .running {
                rows[i].status = done.exit >= 128 ? .stopped : (done.exit == 0 ? .done : .failed)
            }
        }
    }

    /// A nested step goes after its parent's last child; a top level step at the end.
    private mutating func insert(_ row: Row) {
        guard let parent = row.parent, let p = rows.lastIndex(where: { $0.id == parent && $0.parent == nil }) else {
            rows.append(row)
            return
        }
        var at = p + 1
        while at < rows.count, rows[at].parent == parent { at += 1 }
        rows.insert(row, at: at)
    }
}

/// Words for the install page.
nonisolated enum InstallText {
    /// The CLI names the sections of a phase script in capitals (PYTHON,
    /// BUILD DEPS): "Python", "Build deps". Any other name stays as it is.
    static func sentenceCase(_ name: String) -> String {
        guard name.contains(where: \.isLetter), name == name.uppercased() else { return name }
        let words = name.replacingOccurrences(of: "_", with: " ").lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// "41 s", "1 min 35 s", "1 h 05 min".
    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min \(String(format: "%02d", s % 60)) s" }
        return "\(s / 3600) h \(String(format: "%02d", (s % 3600) / 60)) min"
    }

    /// "download wkhtmltopdf (about 50 MB), 10 s, 30 MB of 50 MB".
    static func progress(_ line: InstallProgressLine) -> String {
        var parts = [line.label, duration(line.elapsed)]
        if let bytes = line.bytes {
            let have = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            if let total = line.total, total > 0 {
                parts.append("\(have) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
            } else {
                parts.append(have)
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
