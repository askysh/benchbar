import Foundation

// The pure half of the log viewer: parse honcho's lines, keep a capped
// buffer, filter and search. No files, no clock, no UI, so every rule is
// a unit test (LogModelTests).

/// One line of logs/bench.log.
nonisolated struct LogLine: Equatable, Sendable, Identifiable {
    /// Grows by one per line for the life of the viewer; stable across filters.
    let id: Int
    let text: String
    /// The honcho process ("web", "worker", "socketio", "schedule",
    /// "redis_queue", "redis_cache", "system"); a line without a prefix
    /// (a traceback, a wrapped message) belongs to the process above it.
    let process: String?
    /// ERROR, CRITICAL, an exception or a traceback: tinted in the view.
    let isError: Bool
}

nonisolated enum LogParser {
    /// honcho writes "HH:MM:SS <name>.<n>   | text" ("system | ..." has no number).
    static func process(of line: String) -> String? {
        let scalars = Array(line.utf8)
        // "HH:MM:SS " is 9 bytes
        guard scalars.count > 10, scalars[2] == UInt8(ascii: ":"), scalars[5] == UInt8(ascii: ":"),
              scalars[8] == UInt8(ascii: " ") else { return nil }
        let rest = line.dropFirst(9)
        guard let bar = rest.firstIndex(of: "|") else { return nil }
        let name = rest[..<bar].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains(" ") else { return nil }
        let base = name.split(separator: ".").first.map(String.init) ?? name
        return base.allSatisfy { $0.isLetter || $0 == "_" } ? base : nil
    }

    static let errorMarkers = ["ERROR", "CRITICAL", "Traceback (most recent call last)", "Exception:", "Error:"]

    static func looksLikeError(_ line: String) -> Bool {
        errorMarkers.contains { line.contains($0) }
    }
}

/// The last `capacity` lines, built from chunks of text as they are read.
/// A chunk may end in the middle of a line; that part waits for the next.
nonisolated struct LogBuffer: Sendable {
    let capacity: Int
    private(set) var lines: [LogLine] = []
    private var nextID = 0
    private var partial = ""
    private var lastProcess: String?
    /// Inside a traceback: unprefixed lines after "Traceback" stay red.
    private var inTraceback = false

    init(capacity: Int = 5000) {
        self.capacity = capacity
    }

    /// Adds the complete lines of `chunk`; returns the lines added.
    @discardableResult
    mutating func append(_ chunk: String) -> [LogLine] {
        let text = partial + chunk
        var pieces = text.components(separatedBy: "\n")
        partial = pieces.removeLast()
        var added: [LogLine] = []
        for raw in pieces {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let process = LogParser.process(of: line)
            if process != nil {
                lastProcess = process
                inTraceback = line.contains("Traceback (most recent call last)")
            } else if line.contains("Traceback (most recent call last)") {
                inTraceback = true
            }
            let isError = LogParser.looksLikeError(line) || (process == nil && inTraceback)
            added.append(LogLine(id: nextID, text: line, process: process ?? lastProcess, isError: isError))
            nextID += 1
        }
        lines.append(contentsOf: added)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
        return added
    }

    /// Empties the view (the file is not touched); ids keep counting.
    mutating func clear() {
        lines.removeAll()
        partial = ""
        inTraceback = false
    }
}

/// What the viewer shows: one process or all, and a search.
nonisolated struct LogQuery: Equatable, Sendable {
    var process: String?
    var search = ""

    func shows(_ line: LogLine) -> Bool {
        process == nil || line.process == process
    }

    func visible(_ lines: [LogLine]) -> [LogLine] {
        process == nil ? lines : lines.filter(shows)
    }

    /// The visible lines that contain the search (case insensitive), in order.
    func matches(in lines: [LogLine]) -> [Int] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return lines.filter { $0.text.range(of: needle, options: .caseInsensitive) != nil }.map(\.id)
    }

    /// The processes offered in the filter, in Procfile order.
    static let processes = ["web", "worker", "socketio", "schedule", "redis_queue", "redis_cache"]
}

/// "3 of 12", "no matches", or nothing without a search.
nonisolated enum SearchText {
    static func describe(current: Int?, total: Int, searching: Bool) -> String {
        guard searching else { return "" }
        guard total > 0 else { return "no matches" }
        if let current { return "\(current + 1) of \(total)" }
        return "\(total) matches"
    }

    /// The next (or previous) match index, wrapping around.
    static func step(_ current: Int?, total: Int, forward: Bool) -> Int? {
        guard total > 0 else { return nil }
        guard let current else { return forward ? 0 : total - 1 }
        return forward ? (current + 1) % total : (current - 1 + total) % total
    }
}
