import Foundation
import Observation

/// One bench's log in the viewer: the tailer feeding a capped buffer, the
/// filter and search, and whether the view follows the end.
@Observable
final class LogViewModel {
    let benchName: String
    let benchPath: String
    private(set) var buffer = LogBuffer()
    var query = LogQuery() {
        didSet {
            guard oldValue != query else { return }
            // the CLI reads the process itself (worker.log has no honcho prefix to filter on): a change of process reads again
            if oldValue.process != query.process, fetch != nil, usesCLI || sinceRestart || oldValue.process == "worker" { restart() }
            currentMatch = nil
            changes += 1
        }
    }
    /// Stick to the bottom as lines arrive; turned off when the user scrolls up.
    var follow = true
    var showPrevious = false { didSet { if oldValue != showPrevious { restart() } } }
    /// Only the lines since the bench's last start, read through `benchbar logs --json --since-restart`.
    var sinceRestart = false { didSet { if oldValue != sinceRestart { restart() } } }
    /// Why the CLI read failed (no recorded start, an old CLI), shown above the text; the file reads need no CLI.
    private(set) var note: String?
    private(set) var currentMatch: Int?
    /// Bumped on every change the text view must redraw for (not per line).
    /// New lines are not a change: the view appends what follows the last
    /// line it drew (`visible(after:)`), so drawing never writes to the model.
    private(set) var changes = 0

    /// One read of the log through the CLI; nil in a test of the file tail and when the app has no CLI.
    @ObservationIgnored var fetch: ((LogRequest) async throws -> LogChunk)?
    @ObservationIgnored private var tailer: LogTailer?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var cursor = LogCursor()
    /// How long the CLI source waits between reads.
    @ObservationIgnored var pollInterval: Duration = .seconds(2)
    @ObservationIgnored private let capacity: Int

    init(benchName: String, benchPath: String, capacity: Int = 5000) {
        self.benchName = benchName
        self.benchPath = benchPath
        self.capacity = capacity
        buffer = LogBuffer(capacity: capacity)
    }

    /// The CLI reads the log (`--since-restart`, `--process worker`) instead of the app tailing the file itself.
    var usesCLI: Bool { fetch != nil && (sinceRestart || query.process == "worker") }

    /// What the view filters on: when the CLI read one process already, its lines are all shown.
    private var effectiveQuery: LogQuery { usesCLI ? LogQuery(process: nil, search: query.search) : query }

    var fileURL: URL {
        URL(fileURLWithPath: benchPath).appendingPathComponent(showPrevious ? "logs/bench.previous.log" : "logs/bench.log")
    }

    var visible: [LogLine] { effectiveQuery.visible(buffer.lines) }
    /// The visible lines that came after line `id`, oldest first. The
    /// buffer's ids grow by one per line, so this is an index, not a search.
    func visible(after id: Int) -> [LogLine] {
        let lines = buffer.lines
        guard let first = lines.first?.id else { return [] }
        let start = max(0, id - first + 1)
        guard start < lines.count else { return [] }
        return effectiveQuery.visible(Array(lines[start...]))
    }
    var matches: [Int] { query.matches(in: visible) }
    var searchSummary: String {
        SearchText.describe(current: currentMatch, total: matches.count, searching: !query.search.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    /// The line id of the current match, for the view to scroll to.
    var currentMatchID: Int? {
        guard let currentMatch, currentMatch < matches.count else { return nil }
        return matches[currentMatch]
    }

    func start() {
        restart()
    }

    func stop() {
        tailer?.stop()
        tailer = nil
        poll?.cancel()
        poll = nil
    }

    func step(forward: Bool) {
        currentMatch = SearchText.step(currentMatch, total: matches.count, forward: forward)
        follow = false
        changes += 1
    }

    func clear() {
        buffer.clear()
        changes += 1
    }

    private func restart() {
        stop()
        buffer = LogBuffer(capacity: capacity)
        currentMatch = nil
        note = nil
        cursor = LogCursor()
        if usesCLI {
            startPolling()
            changes += 1
            return
        }
        let tailer = LogTailer(url: fileURL, onLines: { [weak self] chunk in
            self?.buffer.append(chunk)
        }, onReset: { [weak self] in
            // the runner started a new log: keep what was shown, mark the cut
            self?.buffer.append("--- log restarted ---\n")
        })
        self.tailer = tailer
        tailer.start()
        changes += 1
    }
}

extension LogViewModel {
    /// The first read is everything since the start (or the tail of the file); then only what is newer than the last line.
    private func startPolling() {
        guard let fetch else { return }
        let request = LogRequest(process: query.process, previous: showPrevious, sinceRestart: sinceRestart)
        poll = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                var next = request
                if !first, let time = cursor.time { next.since = time; next.sinceRestart = false }
                do {
                    let chunk = try await fetch(next)
                    guard !Task.isCancelled else { return }
                    note = nil
                    let lines = cursor.take(chunk)
                    if !lines.isEmpty { buffer.append(lines.joined(separator: "\n") + "\n") }
                    first = false
                } catch {
                    guard !Task.isCancelled else { return }
                    note = error.localizedDescription
                }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }
}
